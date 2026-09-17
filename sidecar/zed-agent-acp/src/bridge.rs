//! stdio 上的 ACP 传输，以及「tokio 世界 ↔ gpui 世界」的两条单向通道。
//!
//! 为什么要桥：gpui 的 `App` 只活在主线程且不是 `Send`，而 ACP SDK 的 handler 必须是 `Send`
//! （`Builder::on_receive_request` 的 `F: ... + Send`）。所以：
//! - 传输跑在一条**专用 OS 线程**上（`futures::executor::block_on`；`Stdio` 用 `blocking::Unblock`
//!   包 std 的 stdin / stdout，不需要 tokio reactor）；
//! - handler 只做一件事：把 `(请求, Responder)` 塞进 mpsc 就返回 —— 绝不在 handler 里 await 业务，
//!   否则会卡住 SDK 的 dispatch 循环（SDK 文档原话：notification handler 会阻塞后续消息处理）；
//! - gpui 前台的 dispatcher 取出来，每条**各自 spawn 一个前台任务**执行，这样一次长 `session/prompt`
//!   不会挡住随后的 `session/cancel`；
//! - 反方向（`session/update` 通知、`session/request_permission` / `elicitation/create` 反向请求）
//!   直接在 gpui 侧持有 `ConnectionTo<Client>` 调用：它内部是 mpsc sender，`Send` 且发送是同步的。
//!
//! 生命周期：stdin 关闭 → `connect_with` 的 main_fn 等到 `incoming_closed()` 而返回 → 传输 future 结束
//! → handler（连同 mpsc sender）被丢弃 → dispatcher 的循环自然退出 → `cx.quit()`。
//! 这也是主进程 `agent_disconnect` 关 stdin 后我们该退出的路径。
//! **那一等不能省**：传输关闭不会自动取消 main_fn，只等 shutdown 信号会成环、sidecar 变孤儿进程
//! （详见 `run_transport` 里那段注释）。

use std::sync::Arc;
use std::sync::atomic::{AtomicU8, Ordering};

use agent_client_protocol::schema::v1 as acp;
use agent_client_protocol::{Agent, Client, ConnectionTo, Responder, Stdio};
use futures::StreamExt as _;
use futures::channel::{mpsc, oneshot};
use gpui::App;

use crate::headless::AgentAppState;
use crate::session;

/// 一条从客户端来的消息：请求带着它的 `Responder`，通知不带。
///
/// `InitializeRequest` 里嵌着整份 `ClientCapabilities`，比其余变体大一个量级（clippy
/// `large_enum_variant`：1096 vs 368 字节），装箱后整个枚举按第二大的算 —— 它每条消息都要过一次
/// mpsc，不值得为一次性的 initialize 把每条都撑大。
pub enum Incoming {
    Initialize(Box<acp::InitializeRequest>, Responder<acp::InitializeResponse>),
    Authenticate(acp::AuthenticateRequest, Responder<acp::AuthenticateResponse>),
    NewSession(acp::NewSessionRequest, Responder<acp::NewSessionResponse>),
    LoadSession(acp::LoadSessionRequest, Responder<acp::LoadSessionResponse>),
    ResumeSession(acp::ResumeSessionRequest, Responder<acp::ResumeSessionResponse>),
    CloseSession(acp::CloseSessionRequest, Responder<acp::CloseSessionResponse>),
    ListSessions(acp::ListSessionsRequest, Responder<acp::ListSessionsResponse>),
    DeleteSession(acp::DeleteSessionRequest, Responder<acp::DeleteSessionResponse>),
    Prompt(acp::PromptRequest, Responder<acp::PromptResponse>),
    SetSessionMode(acp::SetSessionModeRequest, Responder<acp::SetSessionModeResponse>),
    SetSessionConfigOption(
        acp::SetSessionConfigOptionRequest,
        Responder<acp::SetSessionConfigOptionResponse>,
    ),
    Cancel(acp::CancelNotification),
}

impl Incoming {
    /// 只用于日志。
    pub fn method(&self) -> &'static str {
        match self {
            Incoming::Initialize(..) => "initialize",
            Incoming::Authenticate(..) => "authenticate",
            Incoming::NewSession(..) => "session/new",
            Incoming::LoadSession(..) => "session/load",
            Incoming::ResumeSession(..) => "session/resume",
            Incoming::CloseSession(..) => "session/close",
            Incoming::ListSessions(..) => "session/list",
            Incoming::DeleteSession(..) => "session/delete",
            Incoming::Prompt(..) => "session/prompt",
            Incoming::SetSessionMode(..) => "session/set_mode",
            Incoming::SetSessionConfigOption(..) => "session/set_config_option",
            Incoming::Cancel(..) => "session/cancel",
        }
    }
}

/// 只启动无头环境、报一次可用模型数就退出；用来在没有 ACP 客户端的情况下验证启动链路（任务卡验收 1）。
pub fn selftest(
    state: Arc<AgentAppState>,
    settings_path: std::path::PathBuf,
    exit: Arc<AtomicU8>,
    cx: &mut App,
) {
    cx.spawn(async move |cx| {
        let report = session::selftest_report(&state, &settings_path, cx).await;
        match report {
            Ok(report) => {
                println!("{report}");
                exit.store(0, Ordering::SeqCst);
            }
            Err(error) => {
                eprintln!("selftest failed: {error:#}");
                exit.store(1, Ordering::SeqCst);
            }
        }
        cx.update(|cx| cx.quit());
    })
    .detach();
}

/// 在 stdin / stdout 上说 ACP，直到对端关闭。
pub fn serve(
    state: Arc<AgentAppState>,
    settings_path: std::path::PathBuf,
    exit: Arc<AtomicU8>,
    cx: &mut App,
) {
    let (incoming_tx, mut incoming_rx) = mpsc::unbounded::<Incoming>();
    let (connection_tx, connection_rx) = oneshot::channel::<ConnectionTo<Client>>();
    let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();
    let (done_tx, done_rx) = oneshot::channel::<Result<(), acp::Error>>();

    let spawned = std::thread::Builder::new()
        .name("acp-stdio".to_owned())
        .spawn(move || {
            let outcome = futures::executor::block_on(run_transport(
                incoming_tx,
                connection_tx,
                shutdown_rx,
            ));
            if let Err(error) = &outcome {
                log::warn!("ACP transport ended with error: {error}");
            }
            let _ = done_tx.send(outcome);
        });
    if let Err(error) = spawned {
        eprintln!("zed-agent-acp: 起不来 ACP 传输线程：{error}");
        exit.store(1, Ordering::SeqCst);
        cx.quit();
        return;
    }

    cx.spawn(async move |cx| {
        let Ok(connection) = connection_rx.await else {
            eprintln!("zed-agent-acp: ACP 连接句柄没到就断了");
            exit.store(1, Ordering::SeqCst);
            cx.update(|cx| cx.quit());
            return;
        };
        let agent = session::Agent::new(state, settings_path, connection);
        // 先把 Zed 的 settings 读进来、provider 认证一遍、建好 NativeAgent，再开始收消息：
        // 理由见 `Agent::warm_up` 的注释（惰性初始化会被并发请求撞出两个 NativeAgent）。
        agent.warm_up(cx).await;

        while let Some(incoming) = incoming_rx.next().await {
            let agent = agent.clone();
            cx.spawn(async move |cx| {
                let method = incoming.method();
                if let Err(error) = agent.handle(incoming, cx).await {
                    // handle() 自己已经把错误回给了对端；这里只留一行排查用的日志。
                    log::debug!("{method} finished with error: {error}");
                }
            })
            .detach();
        }

        // 到这里说明所有 handler（连同 sender）都没了 = 传输结束。
        let _ = shutdown_tx.send(());
        let code = match done_rx.await {
            Ok(Ok(())) => 0,
            Ok(Err(_)) | Err(_) => 1,
        };
        exit.store(code, Ordering::SeqCst);
        cx.update(|cx| cx.quit());
    })
    .detach();
}

async fn run_transport(
    incoming_tx: mpsc::UnboundedSender<Incoming>,
    connection_tx: oneshot::Sender<ConnectionTo<Client>>,
    shutdown_rx: oneshot::Receiver<()>,
) -> Result<(), acp::Error> {
    // 每个 handler 各拿一份 sender：SDK 要求 handler 是 `Send` 且相互独立。
    macro_rules! forward {
        ($tx:ident, $variant:ident) => {
            forward!($tx, $variant, |request| request)
        };
        ($tx:ident, $variant:ident, |$req:ident| $wrap:expr) => {{
            let tx = $tx.clone();
            move |$req, responder: Responder<_>, _cx: ConnectionTo<Client>| {
                let tx = tx.clone();
                let payload = $wrap;
                async move {
                    // sender 断了只可能是 gpui 侧已经在退出，静默丢弃即可（对端会看到连接关闭）。
                    let _ = tx.unbounded_send(Incoming::$variant(payload, responder));
                    Ok(())
                }
            }
        }};
    }

    Agent
        .builder()
        .name("zed-agent-acp")
        .on_receive_request(
            forward!(incoming_tx, Initialize, |request| Box::new(request)),
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            forward!(incoming_tx, Authenticate),
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            forward!(incoming_tx, NewSession),
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            forward!(incoming_tx, LoadSession),
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            forward!(incoming_tx, ResumeSession),
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            forward!(incoming_tx, CloseSession),
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            forward!(incoming_tx, ListSessions),
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            forward!(incoming_tx, DeleteSession),
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            forward!(incoming_tx, Prompt),
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            forward!(incoming_tx, SetSessionMode),
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            forward!(incoming_tx, SetSessionConfigOption),
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_notification(
            {
                let tx = incoming_tx.clone();
                move |notification: acp::CancelNotification, _cx: ConnectionTo<Client>| {
                    let tx = tx.clone();
                    async move {
                        let _ = tx.unbounded_send(Incoming::Cancel(notification));
                        Ok(())
                    }
                }
            },
            agent_client_protocol::on_receive_notification!(),
        )
        .connect_with(Stdio::new(), async move |connection: ConnectionTo<Client>| {
            let _ = connection_tx.send(connection.clone());
            // 连接活到 dispatcher 说该收了，**或者 stdin 先到 EOF**。
            //
            // `incoming_closed()` 这一路是承重的：rust-sdk 明写着传输关闭并不会取消
            // `connect_with` 的这个 future（`jsonrpc.rs` 的 `ConnectionTo::incoming_closed` 文档：
            // 「It does not automatically cancel the future passed to `Builder::connect_with`」）。
            // 只等 `shutdown_rx` 就成了一个环：dispatcher 要等所有 `incoming_tx` 被丢掉才会发 shutdown，
            // 而那些 sender 被 handler 握着、要等这个 future 返回才丢得掉。于是 stdin EOF 推不动任何一环，
            // sidecar 永远不退 —— 主进程 `agent_disconnect` 关了 stdin 也没用，主进程整个没了它就成了
            // 孤儿进程（所有者手测 2026-09-17：两个 `zed-agent-acp.exe` 活过了父进程，各占 ~45 MB；
            // 直接拿它做实验：关了 stdin 之后 10 s 仍不退，握手与不握手都一样）。
            //
            // 走这一路同时把「主进程崩了 / 被强杀」一并盖住：管道随父进程一起断，stdin 照样到 EOF。
            let closed = connection.incoming_closed();
            futures::pin_mut!(closed);
            futures::future::select(shutdown_rx, closed).await;
            Ok(())
        })
        .await
}
