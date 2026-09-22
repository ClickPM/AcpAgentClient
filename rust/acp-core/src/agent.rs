//! 一条 agent 连接：拉起子进程、rust-sdk Client 角色、agent → client 的请求队列、`acp/traffic` 行 tap、
//! 退出监视与 stderr 尾巴（docs/design.md § 3 的事件与命令在这里落地）。
//! Derived from zed-industries/zed crates/agent_servers/src/acp.rs @ d9e1c024f393832765a03f4de204d6c8cd9abcb2 (GPL-3.0-or-later)
//! （转写：stdin / stdout 行 tap 与 stderr 单独一路、`initialize` 与进程退出赛跑、`AuthRequired` 映射、cancel 语义、
//! 退出时带 stderr 尾巴；去掉 gpui 前台桥、AcpThread 与会话实体——本项目只做投影，会话状态在前端。）
//!
//! 线程模型：所有 future 跑在 `Core` 的 tokio 多线程 runtime 上；SDK 的 handler 必须 `Send`，
//! 共享状态全在 [`Shared`]（`Arc` + `Mutex`）。handler 只做「入队 + 发事件」，不阻塞 SDK 的 dispatch 循环。

use std::collections::{HashMap, HashSet, VecDeque};
use std::future::Future;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::schema::v1 as acp;
use agent_client_protocol::{Agent, Client, ConnectTo, ConnectionTo, Lines, Responder, UntypedMessage, is_incoming_transport_closed};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{oneshot, watch};

use crate::capabilities;
use crate::command::{self, LaunchSpec};
use crate::error::{CoreError, Result};
use crate::events::{EventChannel, EventSink};
use crate::redact;

/// stderr 尾巴的上限（随 `exited` 事件带出）。
const STDERR_TAIL_LIMIT: usize = 8 * 1024;
/// `agent_disconnect` 关掉 stdin 后等 agent 自行退出的时间；超时就结束进程树。
const DISCONNECT_GRACE: Duration = Duration::from_secs(3);
/// 进程退出后留给 stderr 读任务收尾的时间。
const STDERR_SETTLE: Duration = Duration::from_millis(200);
/// 请求因「传输已关闭」失败时，等退出监视补上退出码与 stderr 尾巴的时间（进程死亡先于 SDK 报错被观察到的窗口）。
const EXIT_INFO_GRACE: Duration = Duration::from_secs(2);

pub const METHOD_SESSION_UPDATE: &str = "session/update";
pub const METHOD_REQUEST_PERMISSION: &str = "session/request_permission";
pub const METHOD_ELICITATION_CREATE: &str = "elicitation/create";
pub const METHOD_ELICITATION_COMPLETE: &str = "elicitation/complete";
pub const METHOD_CANCEL_REQUEST: &str = "$/cancel_request";

/// `acp/traffic.direction`。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    /// agent → 客户端（agent 的 stdout）。
    In,
    /// 客户端 → agent（agent 的 stdin）。
    Out,
    Stderr,
}

impl Direction {
    pub fn as_str(self) -> &'static str {
        match self {
            Direction::In => "in",
            Direction::Out => "out",
            Direction::Stderr => "stderr",
        }
    }
}

/// 进程退出信息（`acp/agent_state: exited`）。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ExitInfo {
    pub code: Option<i32>,
    pub stderr_tail: String,
    pub transport_error: Option<String>,
}

struct Pending {
    method: String,
    session_id: Option<String>,
    responder: Responder<Value>,
}

#[derive(Debug, Default)]
struct SessionState {
    cwd: PathBuf,
    /// 发出 `session/cancel` 后到本轮 `session/prompt` 返回之前为 true：期间到达的权限请求自动回 `cancelled`。
    cancel_pending: bool,
}

/// 连接的共享状态：handler、tap、退出监视与命令侧都持有 `Arc<Shared>`。
pub struct Shared {
    agent_id: String,
    sink: Arc<dyn EventSink>,
    dropped_updates: AtomicU64,
    pending: Mutex<HashMap<String, Pending>>,
    sessions: Mutex<HashMap<String, SessionState>>,
    auth_methods: Mutex<Vec<acp::AuthMethod>>,
    stderr_tail: Mutex<VecDeque<u8>>,
    transport_error: Mutex<Option<String>>,
    exit: watch::Sender<Option<ExitInfo>>,
    /// 有子进程时退出由进程监视决定；无子进程（测试传输）时由传输结束决定。
    has_process: bool,
    /// 终端表（核心共享）与本连接经 `terminal/create` 建的终端 id（R4）：agent 只许碰自己建的；断开 / 退出时一并释放。
    terminals: Arc<pty::TerminalManager>,
    owned_terminals: Mutex<HashSet<String>>,
}

impl std::fmt::Debug for Shared {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Shared").field("agent_id", &self.agent_id).finish_non_exhaustive()
    }
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    match m.lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    }
}

impl Shared {
    fn new(agent_id: String, sink: Arc<dyn EventSink>, has_process: bool, terminals: Arc<pty::TerminalManager>) -> Self {
        Self {
            agent_id,
            sink,
            dropped_updates: AtomicU64::new(0),
            pending: Mutex::new(HashMap::new()),
            sessions: Mutex::new(HashMap::new()),
            auth_methods: Mutex::new(Vec::new()),
            stderr_tail: Mutex::new(VecDeque::new()),
            transport_error: Mutex::new(None),
            exit: watch::Sender::new(None),
            has_process,
            terminals,
            owned_terminals: Mutex::new(HashSet::new()),
        }
    }

    /// 本连接建过、还没 release 的终端 id（测试 / 排查）。
    pub fn owned_terminal_ids(&self) -> Vec<String> {
        lock(&self.owned_terminals).iter().cloned().collect()
    }

    /// 核心共享的终端表（测试用）。
    pub fn terminal_manager(&self) -> Arc<pty::TerminalManager> {
        self.terminals.clone()
    }

    /// 把一个已建的终端记到本连接名下（测试用：不经 agent 发 `terminal/create` 也能验断开时的释放）。
    pub fn adopt_terminal(&self, terminal_id: &str) {
        lock(&self.owned_terminals).insert(terminal_id.to_string());
    }

    /// 断开 / 退出：agent 建的终端全部释放（还在跑的先 kill）。规范说 agent MUST release，但它死了就轮到我们。
    fn release_owned_terminals(&self) {
        let ids: Vec<String> = lock(&self.owned_terminals).drain().collect();
        for id in ids {
            let _ = self.terminals.release(&id);
        }
    }

    pub fn agent_id(&self) -> &str {
        &self.agent_id
    }

    pub fn dropped_updates(&self) -> u64 {
        self.dropped_updates.load(Ordering::Relaxed)
    }

    pub fn auth_methods(&self) -> Vec<acp::AuthMethod> {
        lock(&self.auth_methods).clone()
    }

    pub fn exit_info(&self) -> Option<ExitInfo> {
        self.exit.borrow().clone()
    }

    pub fn pending_request_ids(&self) -> Vec<String> {
        lock(&self.pending).keys().cloned().collect()
    }

    /// 等进程退出（无子进程时 = 传输结束）。
    pub async fn wait_exit(&self) -> ExitInfo {
        let mut rx = self.exit.subscribe();
        match rx.wait_for(|e| e.is_some()).await {
            Ok(guard) => guard.clone().unwrap_or_default(),
            Err(_) => ExitInfo::default(),
        }
    }

    fn emit(&self, channel: EventChannel, payload: Value) {
        self.sink.emit(channel, payload.to_string());
    }

    /// `acp/agent_state`：`{agentId, state, droppedUpdates, ...extra}`。
    pub(crate) fn emit_state(&self, state: &str, extra: Value) {
        let mut payload = json!({
            "agentId": self.agent_id,
            "state": state,
            "droppedUpdates": self.dropped_updates(),
        });
        if let (Value::Object(target), Value::Object(source)) = (&mut payload, extra) {
            target.extend(source);
        }
        self.emit(EventChannel::AgentState, payload);
    }

    /// `acp/traffic`：脱敏后的原始行（规则 8）。
    fn emit_traffic(&self, direction: Direction, line: &str) {
        self.emit_traffic_redacted(direction, redact::redact_line(line));
    }

    /// 调用方已经脱敏过的行（stderr 那一路只脱敏一次，尾巴与 traffic 共用）。
    fn emit_traffic_redacted(&self, direction: Direction, line: String) {
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        self.emit(
            EventChannel::Traffic,
            json!({
                "agentId": self.agent_id,
                "direction": direction.as_str(),
                "line": line,
                "ts": ts,
            }),
        );
    }

    fn push_stderr(&self, bytes: &[u8]) {
        let mut tail = lock(&self.stderr_tail);
        tail.extend(bytes.iter().copied());
        tail.push_back(b'\n');
        while tail.len() > STDERR_TAIL_LIMIT {
            tail.pop_front();
        }
    }

    fn stderr_tail_string(&self) -> String {
        let mut tail = lock(&self.stderr_tail);
        String::from_utf8_lossy(tail.make_contiguous()).into_owned()
    }

    /// 记 / 更新会话的 cwd。已经在账上的只改 cwd，不碰 `cancel_pending`——
    /// 那是回合级的标志，`session/load` / `resume` 不该把它清掉（R6）。
    fn record_session(&self, session_id: &str, cwd: PathBuf) {
        let mut sessions = lock(&self.sessions);
        match sessions.get_mut(session_id) {
            Some(existing) => existing.cwd = cwd,
            None => {
                sessions.insert(
                    session_id.to_string(),
                    SessionState {
                        cwd,
                        cancel_pending: false,
                    },
                );
            }
        }
    }

    pub fn session_cwd(&self, session_id: &str) -> Option<PathBuf> {
        lock(&self.sessions).get(session_id).map(|s| s.cwd.clone())
    }

    /// `session/close` / `session/delete` 之后忘掉这个会话：之后 agent 再拿这个 id 调 `fs/*` 或 `terminal/*`
    /// 就越界了（`session_cwd_or_error` 会回 `-32602`），不能继续用陈旧的 cwd 放行（R6）。
    fn forget_session(&self, session_id: &str) {
        lock(&self.sessions).remove(session_id);
    }

    fn set_cancel_pending(&self, session_id: &str, value: bool) {
        if let Some(session) = lock(&self.sessions).get_mut(session_id) {
            session.cancel_pending = value;
        }
    }

    fn is_cancel_pending(&self, session_id: &str) -> bool {
        lock(&self.sessions).get(session_id).is_some_and(|s| s.cancel_pending)
    }

    fn take_pending(&self, request_id: &str) -> Option<Pending> {
        lock(&self.pending).remove(request_id)
    }

    /// 进程退出（或传输结束）：记状态、清队列（应答不到了）、发 `exited`。只生效一次。
    fn finish(&self, code: Option<i32>) {
        let info = ExitInfo {
            code,
            stderr_tail: self.stderr_tail_string(),
            transport_error: lock(&self.transport_error).clone(),
        };
        let first = self.exit.send_if_modified(|slot| {
            if slot.is_some() {
                return false;
            }
            *slot = Some(info.clone());
            true
        });
        if !first {
            return;
        }
        lock(&self.pending).clear();
        self.release_owned_terminals();
        self.emit_state(
            "exited",
            json!({
                "code": info.code,
                "stderrTail": info.stderr_tail,
                "transportError": info.transport_error,
            }),
        );
    }

    fn exited_error(&self, info: ExitInfo) -> CoreError {
        CoreError::Exited {
            agent_id: self.agent_id.clone(),
            code: info.code,
            stderr_tail: info.stderr_tail,
        }
    }

    // ---- agent → client 请求（handler 在 SDK dispatch 循环里跑，只入队 + 发事件）

    fn enqueue(&self, method: &str, session_id: Option<String>, params: Value, responder: Responder<Value>) {
        let request_id = responder.id().to_string();
        lock(&self.pending).insert(
            request_id.clone(),
            Pending {
                method: method.to_string(),
                session_id,
                responder,
            },
        );
        self.emit(
            EventChannel::ClientRequest,
            json!({
                "agentId": self.agent_id,
                "requestId": request_id,
                "method": method,
                "params": params,
            }),
        );
    }

    fn on_permission(
        &self,
        request: acp::RequestPermissionRequest,
        responder: Responder<acp::RequestPermissionResponse>,
    ) -> std::result::Result<(), acp::Error> {
        let session_id = request.session_id.0.to_string();
        if self.is_cancel_pending(&session_id) {
            // 发出 cancel 后挂起的权限请求 MUST 回 cancelled（docs/acp-projection.md § 3.1）。
            return responder.respond(acp::RequestPermissionResponse::new(acp::RequestPermissionOutcome::Cancelled));
        }
        let params = serde_json::to_value(&request)?;
        self.enqueue(METHOD_REQUEST_PERMISSION, Some(session_id), params, responder.erase_to_json());
        Ok(())
    }

    fn on_elicitation(
        &self,
        request: acp::CreateElicitationRequest,
        responder: Responder<acp::CreateElicitationResponse>,
    ) -> std::result::Result<(), acp::Error> {
        let params = serde_json::to_value(&request)?;
        // sessionScope 带 sessionId；requestScope 没有（认证阶段），队列里 session 为空。
        let session_id = params.get("sessionId").and_then(Value::as_str).map(str::to_string);
        // 与 `on_permission` 同一条规矩（审查 finding，2026-09-22）：cancel 期里到达的请求就地回掉，不进前端队列。
        // 规范只对权限请求写了 MUST（acp-projection.md § 3.1），但 elicitation 核心**不代答**——
        // 前端在发 cancel / close / delete 时是照着当时的队列快照逐条回的，这之后才到的那条没人认领：
        // agent 一直等着它，连后面的 `session/close` 都不处理（R6 修掉的双边挂死，只剩 elicitation 时原样回来）。
        // requestScope 的（无 sessionId）不在任何会话的 cancel 期里，照常入队。
        if let Some(sid) = &session_id
            && self.is_cancel_pending(sid)
        {
            return responder.respond(acp::CreateElicitationResponse::new(acp::ElicitationAction::Cancel));
        }
        self.enqueue(METHOD_ELICITATION_CREATE, session_id, params, responder.erase_to_json());
        Ok(())
    }

    /// 全部通知走这一个 handler：`session/update` 用 SDK 类型校验后 serde 直出；反序列化失败计数 + 告警
    /// （docs/design.md § 4 `notice` 裁定）；`elicitation/complete` 与 `$/cancel_request` 以 `requestId: null`
    /// 的 `acp/client_request` 转给前端（是通知，不需回应）；被撤回的请求由核心回 `-32800` 收尾。其他通知只留在 traffic。
    fn on_notification(&self, notification: UntypedMessage) {
        let (method, params) = notification.into_parts();
        match method.as_str() {
            METHOD_SESSION_UPDATE => match serde_json::from_value::<acp::SessionNotification>(params) {
                Ok(parsed) => match serde_json::to_value(&parsed) {
                    Ok(mut payload) => {
                        if let Value::Object(map) = &mut payload {
                            map.insert("agentId".to_string(), Value::String(self.agent_id.clone()));
                        }
                        self.emit(EventChannel::SessionUpdate, payload);
                    }
                    Err(e) => self.drop_update(&e.to_string()),
                },
                Err(e) => self.drop_update(&e.to_string()),
            },
            METHOD_CANCEL_REQUEST => {
                if let Some(id) = params.get("requestId") {
                    let key = serde_json::from_value::<acp::RequestId>(id.clone())
                        .map(|id| id.to_string())
                        .unwrap_or_else(|_| id.to_string());
                    if let Some(pending) = self.take_pending(&key) {
                        // agent 撤回了自己的请求：仍要给它一个 JSON-RPC 响应（-32800 request cancelled，照 Zed），
                        // 否则它若还在等这条请求就挂死；SDK 的 drop guard 只在 batch 目的地补槽（第 2 轮审查 finding）。
                        let _ = pending.responder.respond_with_error(acp::Error::request_cancelled());
                        // `requestId` 归一化成与队列键同形的字符串（协议原样可能是数字），前端直接比对（审查 finding）。
                        let mut params = params;
                        if let Value::Object(map) = &mut params {
                            map.insert("requestId".to_string(), Value::String(key));
                        }
                        self.forward_notification(&method, params);
                    }
                }
            }
            METHOD_ELICITATION_COMPLETE => self.forward_notification(&method, params),
            _ => {}
        }
    }

    fn forward_notification(&self, method: &str, params: Value) {
        self.emit(
            EventChannel::ClientRequest,
            json!({
                "agentId": self.agent_id,
                "requestId": Value::Null,
                "method": method,
                "params": params,
            }),
        );
    }

    fn drop_update(&self, error: &str) {
        self.dropped_updates.fetch_add(1, Ordering::Relaxed);
        self.emit_state(
            "update_dropped",
            json!({
                "method": METHOD_SESSION_UPDATE,
                "error": error,
            }),
        );
    }

    // ---- fs/* 与 terminal/* 回调（R4；docs/design.md § 7）。handler 里只起任务，文件 / 子进程 / 阻塞等待都在任务里做，
    //      不占 SDK 的 dispatch 循环。sessionId 不认识 → invalid params；路径越界 / 文件不存在 / 行号越界按 fs 的错误映射。

    fn session_cwd_or_error(&self, session_id: &acp::SessionId) -> std::result::Result<PathBuf, acp::Error> {
        let id = session_id.0.to_string();
        self.session_cwd(&id)
            .ok_or_else(|| acp::Error::invalid_params().data(format!("unknown session {id}")))
    }

    fn on_read_text_file(self: &Arc<Self>, request: acp::ReadTextFileRequest, responder: Responder<acp::ReadTextFileResponse>) {
        let shared = self.clone();
        tokio::spawn(async move {
            let cwd = match shared.session_cwd_or_error(&request.session_id) {
                Ok(cwd) => cwd,
                Err(e) => {
                    let _ = responder.respond_with_error(e);
                    return;
                }
            };
            let path = request.path.clone();
            let (line, limit) = (request.line, request.limit);
            let result = tokio::task::spawn_blocking(move || fs::read_text_file(&cwd, &path, line, limit)).await;
            match result {
                Ok(Ok(content)) => {
                    let _ = responder.respond(acp::ReadTextFileResponse::new(content));
                }
                Ok(Err(e)) => {
                    let _ = responder.respond_with_error(fs_error(e, &request.path));
                }
                Err(join) => {
                    let _ = responder.respond_with_error(acp::Error::internal_error().data(join.to_string()));
                }
            }
        });
    }

    fn on_write_text_file(self: &Arc<Self>, request: acp::WriteTextFileRequest, responder: Responder<acp::WriteTextFileResponse>) {
        let shared = self.clone();
        tokio::spawn(async move {
            let cwd = match shared.session_cwd_or_error(&request.session_id) {
                Ok(cwd) => cwd,
                Err(e) => {
                    let _ = responder.respond_with_error(e);
                    return;
                }
            };
            let path = request.path.clone();
            let content = request.content;
            let result = tokio::task::spawn_blocking(move || fs::write_text_file(&cwd, &path, &content)).await;
            match result {
                Ok(Ok(())) => {
                    let _ = responder.respond(acp::WriteTextFileResponse::default());
                }
                Ok(Err(e)) => {
                    let _ = responder.respond_with_error(fs_error(e, &request.path));
                }
                Err(join) => {
                    let _ = responder.respond_with_error(acp::Error::internal_error().data(join.to_string()));
                }
            }
        });
    }

    fn on_create_terminal(self: &Arc<Self>, request: acp::CreateTerminalRequest, responder: Responder<acp::CreateTerminalResponse>) {
        let shared = self.clone();
        tokio::spawn(async move {
            let session_cwd = match shared.session_cwd_or_error(&request.session_id) {
                Ok(cwd) => cwd,
                Err(e) => {
                    let _ = responder.respond_with_error(e);
                    return;
                }
            };
            // `cwd` 缺省是会话目录；给了就得是绝对路径（规范）。
            let cwd = match request.cwd {
                Some(p) if !p.is_absolute() => {
                    let _ = responder.respond_with_error(acp::Error::invalid_params().data(format!("cwd must be absolute: {}", p.display())));
                    return;
                }
                Some(p) => p,
                None => session_cwd,
            };
            let env: Vec<(String, String)> = request.env.into_iter().map(|v| (v.name, v.value)).collect();
            let terminals = shared.terminals.clone();
            let (command, args, limit) = (request.command, request.args, request.output_byte_limit);
            let spawned = tokio::task::spawn_blocking(move || {
                terminals.spawn_shell_command(&command, &args, env, Some(cwd), limit, pty::TerminalSource::Agent)
            })
            .await;
            match spawned {
                Ok(Ok(id)) => {
                    // 审查 finding（2026-09-16）：拉起期间这条连接可能已经 finish()（agent 退出 / 断开）并把 owned 集合
                    // 释放过一轮，之后没人再释放这条终端。exit 与登记在同一把锁下判：已退出就当场释放、回错误。
                    let registered = {
                        let mut owned = lock(&shared.owned_terminals);
                        if shared.exit_info().is_some() {
                            false
                        } else {
                            owned.insert(id.clone());
                            true
                        }
                    };
                    if !registered {
                        let _ = shared.terminals.release(&id);
                        let _ = responder.respond_with_error(
                            acp::Error::internal_error().data("agent connection closed while creating the terminal"),
                        );
                        return;
                    }
                    let _ = responder.respond(acp::CreateTerminalResponse::new(acp::TerminalId::new(id)));
                }
                Ok(Err(e)) => {
                    let _ = responder.respond_with_error(acp::Error::internal_error().data(e.to_string()));
                }
                Err(join) => {
                    let _ = responder.respond_with_error(acp::Error::internal_error().data(join.to_string()));
                }
            }
        });
    }

    /// agent 只许碰自己建的终端；release 过的 id 也算不认识（规范：release 后 id 失效）。
    fn owned_terminal(&self, terminal_id: &acp::TerminalId) -> std::result::Result<String, acp::Error> {
        let id = terminal_id.0.to_string();
        if lock(&self.owned_terminals).contains(&id) {
            Ok(id)
        } else {
            Err(acp::Error::invalid_params().data(format!("unknown terminal {id}")))
        }
    }

    fn on_terminal_output(self: &Arc<Self>, request: acp::TerminalOutputRequest, responder: Responder<acp::TerminalOutputResponse>) {
        let shared = self.clone();
        tokio::spawn(async move {
            let id = match shared.owned_terminal(&request.terminal_id) {
                Ok(id) => id,
                Err(e) => {
                    let _ = responder.respond_with_error(e);
                    return;
                }
            };
            // 最多 4 MiB 的缓冲要 lossy 解码 + 去 ANSI，不占 SDK 分发线程（审查 finding，2026-09-16）。
            let terminals = shared.terminals.clone();
            match tokio::task::spawn_blocking(move || terminals.output(&id)).await {
                Ok(Ok(out)) => {
                    let mut response = acp::TerminalOutputResponse::new(out.text, out.truncated);
                    if let Some(status) = out.exit {
                        response = response.exit_status(exit_status(&status));
                    }
                    let _ = responder.respond(response);
                }
                Ok(Err(e)) => {
                    let _ = responder.respond_with_error(acp::Error::internal_error().data(e.to_string()));
                }
                Err(join) => {
                    let _ = responder.respond_with_error(acp::Error::internal_error().data(join.to_string()));
                }
            }
        });
    }

    fn on_wait_for_terminal_exit(
        self: &Arc<Self>,
        request: acp::WaitForTerminalExitRequest,
        responder: Responder<acp::WaitForTerminalExitResponse>,
    ) {
        let shared = self.clone();
        tokio::spawn(async move {
            let id = match shared.owned_terminal(&request.terminal_id) {
                Ok(id) => id,
                Err(e) => {
                    let _ = responder.respond_with_error(e);
                    return;
                }
            };
            let terminals = shared.terminals.clone();
            match tokio::task::spawn_blocking(move || terminals.wait(&id)).await {
                Ok(Ok(status)) => {
                    let _ = responder.respond(acp::WaitForTerminalExitResponse::new(exit_status(&status)));
                }
                Ok(Err(e)) => {
                    let _ = responder.respond_with_error(acp::Error::internal_error().data(e.to_string()));
                }
                Err(join) => {
                    let _ = responder.respond_with_error(acp::Error::internal_error().data(join.to_string()));
                }
            }
        });
    }

    fn on_kill_terminal(self: &Arc<Self>, request: acp::KillTerminalRequest, responder: Responder<acp::KillTerminalResponse>) {
        let shared = self.clone();
        tokio::spawn(async move {
            let id = match shared.owned_terminal(&request.terminal_id) {
                Ok(id) => id,
                Err(e) => {
                    let _ = responder.respond_with_error(e);
                    return;
                }
            };
            // kill 要等进程真的退出（pty 层说明），不占 SDK 的分发线程。
            let terminals = shared.terminals.clone();
            match tokio::task::spawn_blocking(move || terminals.kill(&id)).await {
                Ok(Ok(())) => {
                    let _ = responder.respond(acp::KillTerminalResponse::default());
                }
                Ok(Err(e)) => {
                    let _ = responder.respond_with_error(acp::Error::internal_error().data(e.to_string()));
                }
                Err(join) => {
                    let _ = responder.respond_with_error(acp::Error::internal_error().data(join.to_string()));
                }
            }
        });
    }

    fn on_release_terminal(self: &Arc<Self>, request: acp::ReleaseTerminalRequest, responder: Responder<acp::ReleaseTerminalResponse>) {
        let shared = self.clone();
        tokio::spawn(async move {
            let id = match shared.owned_terminal(&request.terminal_id) {
                Ok(id) => id,
                Err(e) => {
                    let _ = responder.respond_with_error(e);
                    return;
                }
            };
            lock(&shared.owned_terminals).remove(&id);
            // release 对还在跑的进程先 kill，不占 SDK 分发线程。
            let terminals = shared.terminals.clone();
            match tokio::task::spawn_blocking(move || terminals.release(&id)).await {
                Ok(Ok(())) => {
                    let _ = responder.respond(acp::ReleaseTerminalResponse::default());
                }
                Ok(Err(e)) => {
                    let _ = responder.respond_with_error(acp::Error::internal_error().data(e.to_string()));
                }
                Err(join) => {
                    let _ = responder.respond_with_error(acp::Error::internal_error().data(join.to_string()));
                }
            }
        });
    }
}

/// `pty::ExitStatus` → 协议的 `TerminalExitStatus`。
fn exit_status(status: &pty::ExitStatus) -> acp::TerminalExitStatus {
    acp::TerminalExitStatus::new().exit_code(status.exit_code).signal(status.signal.clone())
}

/// fs 的错误 → JSON-RPC 错误：不存在 `-32002`、越界 / 行号不合法 `-32602`、其余 `-32603`。
fn fs_error(e: fs::FsError, path: &std::path::Path) -> acp::Error {
    match e {
        fs::FsError::NotFound(_) => acp::Error::resource_not_found(Some(path.display().to_string())),
        fs::FsError::OutsideWorkspace(_) | fs::FsError::InvalidParams(_) => acp::Error::invalid_params().data(e.to_string()),
        other => acp::Error::internal_error().data(other.to_string()),
    }
}

/// 一条已完成 `initialize` 的连接。
pub struct AgentConnection {
    shared: Arc<Shared>,
    connection: ConnectionTo<Agent>,
    shutdown: Mutex<Option<oneshot::Sender<()>>>,
    kill: Mutex<Option<oneshot::Sender<()>>>,
    pub launch: LaunchSpec,
    /// `InitializeResponse` 原样 JSON（agentInfo / agentCapabilities / authMethods）。
    pub initialize: Value,
}

impl std::fmt::Debug for AgentConnection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AgentConnection").field("agent_id", &self.shared.agent_id).finish_non_exhaustive()
    }
}

impl AgentConnection {
    /// 拉起子进程并完成 `initialize`。`cwd` 是 agent 进程的工作目录；`terminals` 是核心共享的终端表（`terminal/*` 回调用）。
    pub async fn connect(
        agent_id: String,
        launch: LaunchSpec,
        cwd: Option<PathBuf>,
        sink: Arc<dyn EventSink>,
        terminals: Arc<pty::TerminalManager>,
    ) -> Result<Arc<Self>> {
        let shared = Arc::new(Shared::new(agent_id, sink, true, terminals));
        let mut cmd = command::build_command(&launch, cwd.as_deref());
        let mut child = cmd.spawn().map_err(|e| CoreError::Spawn(format!("{}: {e}", launch.program)))?;
        let stdin = child.stdin.take().ok_or_else(|| CoreError::Spawn("stdin not piped".into()))?;
        let stdout = child.stdout.take().ok_or_else(|| CoreError::Spawn("stdout not piped".into()))?;
        let stderr = child.stderr.take().ok_or_else(|| CoreError::Spawn("stderr not piped".into()))?;
        shared.emit_state(
            "spawned",
            json!({
                "pid": child.id(),
                "program": launch.program,
                "args": launch.args,
                "cwd": cwd.as_ref().map(|p| p.to_string_lossy().into_owned()),
            }),
        );
        tokio::spawn(stderr_task(shared.clone(), stderr));
        let (kill_tx, kill_rx) = oneshot::channel();
        tokio::spawn(exit_watcher(shared.clone(), child, kill_rx));
        let transport = Lines::new(
            Box::pin(outgoing_sink(shared.clone(), stdin)),
            Box::pin(incoming_stream(shared.clone(), stdout)),
        );
        Self::connect_transport(shared, launch, transport, Some(kill_tx)).await
    }

    /// 测试入口：不拉进程，用任意 `ConnectTo<Client>` 传输（例如 SDK 的 `Channel`）；退出 = 传输结束。
    pub async fn connect_with_transport(
        agent_id: String,
        launch: LaunchSpec,
        sink: Arc<dyn EventSink>,
        transport: impl ConnectTo<Client> + 'static,
        terminals: Arc<pty::TerminalManager>,
    ) -> Result<Arc<Self>> {
        let shared = Arc::new(Shared::new(agent_id, sink, false, terminals));
        Self::connect_transport(shared, launch, transport, None).await
    }

    async fn connect_transport(
        shared: Arc<Shared>,
        launch: LaunchSpec,
        transport: impl ConnectTo<Client> + 'static,
        kill: Option<oneshot::Sender<()>>,
    ) -> Result<Arc<Self>> {
        let (conn_tx, conn_rx) = oneshot::channel::<ConnectionTo<Agent>>();
        let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();
        let permission_shared = shared.clone();
        let elicitation_shared = shared.clone();
        let notification_shared = shared.clone();
        let read_shared = shared.clone();
        let write_shared = shared.clone();
        let create_shared = shared.clone();
        let output_shared = shared.clone();
        let wait_shared = shared.clone();
        let kill_shared = shared.clone();
        let release_shared = shared.clone();
        let io = Client
            .builder()
            .name("acp-agent-client")
            .on_receive_request(
                async move |request: acp::RequestPermissionRequest,
                            responder: Responder<acp::RequestPermissionResponse>,
                            _cx: ConnectionTo<Agent>| { permission_shared.on_permission(request, responder) },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: acp::CreateElicitationRequest,
                            responder: Responder<acp::CreateElicitationResponse>,
                            _cx: ConnectionTo<Agent>| { elicitation_shared.on_elicitation(request, responder) },
                agent_client_protocol::on_receive_request!(),
            )
            // fs/* 与 terminal/*（R4）：handler 只起任务，立刻返回。
            .on_receive_request(
                async move |request: acp::ReadTextFileRequest, responder: Responder<acp::ReadTextFileResponse>, _cx: ConnectionTo<Agent>| {
                    read_shared.on_read_text_file(request, responder);
                    Ok(())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: acp::WriteTextFileRequest, responder: Responder<acp::WriteTextFileResponse>, _cx: ConnectionTo<Agent>| {
                    write_shared.on_write_text_file(request, responder);
                    Ok(())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: acp::CreateTerminalRequest, responder: Responder<acp::CreateTerminalResponse>, _cx: ConnectionTo<Agent>| {
                    create_shared.on_create_terminal(request, responder);
                    Ok(())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: acp::TerminalOutputRequest, responder: Responder<acp::TerminalOutputResponse>, _cx: ConnectionTo<Agent>| {
                    output_shared.on_terminal_output(request, responder);
                    Ok(())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: acp::WaitForTerminalExitRequest,
                            responder: Responder<acp::WaitForTerminalExitResponse>,
                            _cx: ConnectionTo<Agent>| {
                    wait_shared.on_wait_for_terminal_exit(request, responder);
                    Ok(())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: acp::KillTerminalRequest, responder: Responder<acp::KillTerminalResponse>, _cx: ConnectionTo<Agent>| {
                    kill_shared.on_kill_terminal(request, responder);
                    Ok(())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: acp::ReleaseTerminalRequest, responder: Responder<acp::ReleaseTerminalResponse>, _cx: ConnectionTo<Agent>| {
                    release_shared.on_release_terminal(request, responder);
                    Ok(())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_notification(
                async move |notification: UntypedMessage, _cx: ConnectionTo<Agent>| {
                    notification_shared.on_notification(notification);
                    Ok(())
                },
                agent_client_protocol::on_receive_notification!(),
            )
            .connect_with(transport, async move |connection: ConnectionTo<Agent>| {
                let _ = conn_tx.send(connection);
                // 连接活到 `agent_disconnect`（或传输自己结束）。
                let _ = shutdown_rx.await;
                Ok(())
            });
        let io_shared = shared.clone();
        tokio::spawn(async move {
            if let Err(e) = io.await {
                *lock(&io_shared.transport_error) = Some(e.to_string());
            }
            if !io_shared.has_process {
                io_shared.finish(None);
            }
        });

        let connection = tokio::select! {
            handle = conn_rx => handle.map_err(|_| CoreError::Transport("connection handle never arrived".into()))?,
            exit = shared.wait_exit() => return Err(shared.exited_error(exit)),
        };
        let shutdown = Mutex::new(Some(shutdown_tx));
        let kill = Mutex::new(kill);
        let request = acp::InitializeRequest::new(ProtocolVersion::V1)
            .client_capabilities(capabilities::client_capabilities(&shared.agent_id))
            .client_info(capabilities::client_info());
        let response = match race_exit(&shared, connection.send_request(request).block_task()).await {
            Ok(response) => response,
            Err(e) => {
                disconnect(&shared, &shutdown, &kill).await;
                return Err(e);
            }
        };
        if response.protocol_version < ProtocolVersion::V1 {
            disconnect(&shared, &shutdown, &kill).await;
            return Err(CoreError::Transport(format!("unsupported protocol version {:?}", response.protocol_version)));
        }
        *lock(&shared.auth_methods) = response.auth_methods.clone();
        let initialize = serde_json::to_value(&response)?;
        shared.emit_state("initialized", json!({ "initialize": initialize }));
        Ok(Arc::new(Self {
            shared,
            connection,
            shutdown,
            kill,
            launch,
            initialize,
        }))
    }

    pub fn agent_id(&self) -> &str {
        &self.shared.agent_id
    }

    pub fn shared(&self) -> &Arc<Shared> {
        &self.shared
    }

    pub fn auth_method(&self, method_id: &str) -> Option<acp::AuthMethod> {
        self.shared.auth_methods().into_iter().find(|m| m.id().0.as_ref() == method_id)
    }

    pub async fn session_new(&self, cwd: PathBuf) -> Result<Value> {
        let request = acp::NewSessionRequest::new(cwd.clone());
        let response = race_exit(&self.shared, self.connection.send_request(request).block_task()).await?;
        self.shared.record_session(response.session_id.0.as_ref(), cwd);
        Ok(serde_json::to_value(&response)?)
    }

    /// `session/list`（`cwd` 过滤 + cursor 分页）。返回 `ListSessionsResponse` 原样 JSON
    /// （`{sessions: [{sessionId, cwd, title?, updatedAt?, …}], nextCursor?}`）。能力门在前端（规则 2 不特判）。
    pub async fn session_list(&self, cwd: Option<PathBuf>, cursor: Option<String>) -> Result<Value> {
        let mut request = acp::ListSessionsRequest::new();
        request.cwd = cwd;
        request.cursor = cursor;
        let response = race_exit(&self.shared, self.connection.send_request(request).block_task()).await?;
        Ok(serde_json::to_value(&response)?)
    }

    /// `session/load`：agent **MUST** 用 `session/update` 把整段历史重放完再返回（acp-projection.md § 5），
    /// 所以本函数返回时重放已经全部经 `acp/session_update` 推给前端了。返回 `LoadSessionResponse`（modes + configOptions）。
    pub async fn session_load(&self, session_id: &str, cwd: PathBuf) -> Result<Value> {
        let request = acp::LoadSessionRequest::new(acp::SessionId::new(session_id), cwd.clone());
        // 重放期间到达的 `fs/*` / `terminal/*` 回调也要能过越界判定，所以 cwd 在**请求之前**就得记上；
        // 请求失败且这个会话本来不在账上时撤回，免得留一个能放行 fs 越界判定的陈旧条目。
        self.attach_session(session_id, cwd, self.connection.send_request(request).block_task())
            .await
    }

    /// `session/resume`：只恢复上下文，**MUST NOT** 重放（acp-projection.md § 5）。返回 `ResumeSessionResponse`。
    pub async fn session_resume(&self, session_id: &str, cwd: PathBuf) -> Result<Value> {
        let request = acp::ResumeSessionRequest::new(acp::SessionId::new(session_id), cwd.clone());
        self.attach_session(session_id, cwd, self.connection.send_request(request).block_task())
            .await
    }

    /// load / resume 共用：先记 cwd 再发请求，失败且原先不在账上就撤回。
    async fn attach_session<T, F>(&self, session_id: &str, cwd: PathBuf, request: F) -> Result<Value>
    where
        T: serde::Serialize,
        F: Future<Output = std::result::Result<T, acp::Error>>,
    {
        let previous = self.shared.session_cwd(session_id);
        self.shared.record_session(session_id, cwd);
        match race_exit(&self.shared, request).await {
            Ok(response) => Ok(serde_json::to_value(&response)?),
            Err(e) => {
                // 失败就把记账退回原样：本来不在账上的删掉，本来在的把 cwd 还回去，
                // 免得留一个「这个会话可以读写那个目录」的陈旧条目。
                match previous {
                    Some(cwd) => self.shared.record_session(session_id, cwd),
                    None => self.shared.forget_session(session_id),
                }
                Err(e)
            }
        }
    }

    /// `session/close`：等价于先 cancel 再释放。**发请求之前**先把这个会话挂起的权限请求回 `cancelled`——
    /// agent 挂在那条请求上时连 `session/close` 都不会处理（R6 审查 finding high）。成功后本地忘掉这个会话（cwd 记账）。
    /// 返回 CloseSessionResponse 原样 JSON 再加 `cancelledRequestIds`。
    pub async fn session_close(&self, session_id: &str) -> Result<Value> {
        // 先置 cancel 期再排空队列：agent 在读到 close 之前可能又发一条权限请求，
        // 不置标志的话它进队列没人回，客户端等 CloseSessionResponse、agent 等权限回应，双方挂死
        // （审查第 2 轮 P2）。成功后 `forget_session` 会把标志随会话一起丢掉。
        self.shared.set_cancel_pending(session_id, true);
        let cancelled = self.cancel_pending_permissions(session_id)?;
        let request = acp::CloseSessionRequest::new(acp::SessionId::new(session_id));
        let response = race_exit(&self.shared, self.connection.send_request(request).block_task()).await?;
        self.shared.forget_session(session_id);
        Ok(with_cancelled(serde_json::to_value(&response)?, cancelled))
    }

    /// `session/delete`：agent 侧删除会话。同样先收挂起的权限请求。
    /// 成功后本地忘掉这个会话（本地索引由前端删，核心不碰）。
    pub async fn session_delete(&self, session_id: &str) -> Result<Value> {
        self.shared.set_cancel_pending(session_id, true);
        let cancelled = self.cancel_pending_permissions(session_id)?;
        let request = acp::DeleteSessionRequest::new(acp::SessionId::new(session_id));
        let response = race_exit(&self.shared, self.connection.send_request(request).block_task()).await?;
        self.shared.forget_session(session_id);
        Ok(with_cancelled(serde_json::to_value(&response)?, cancelled))
    }

    /// `prompt` 是 `ContentBlock[]` 的 JSON。返回 `PromptResponse`（stopReason + usage）。
    pub async fn session_prompt(&self, session_id: &str, prompt: Value) -> Result<Value> {
        let blocks: Vec<acp::ContentBlock> = serde_json::from_value(prompt)
            .map_err(|e| CoreError::InvalidArgument(format!("prompt must be a ContentBlock array: {e}")))?;
        // 回合开始先清 cancel 期：落在回合之外的 cancel（连点停止、收尾补发）不能把下一回合的权限请求静默回 cancelled（审查 finding）。
        self.shared.set_cancel_pending(session_id, false);
        let request = acp::PromptRequest::new(acp::SessionId::new(session_id), blocks);
        let result = race_exit(&self.shared, self.connection.send_request(request).block_task()).await;
        // 本轮结束（不论怎么结束），cancel 期结束。
        self.shared.set_cancel_pending(session_id, false);
        let response = result?;
        Ok(serde_json::to_value(&response)?)
    }

    /// 把某个会话挂起的 `session/request_permission` 全部以 `cancelled` 回掉（acp-projection.md § 3.1）。
    /// cancel / close / delete 三条路共用：不回的话 agent 会一直挂在那条 JSON-RPC 上，
    /// 连后面的 `session/close` 都不处理（R6 审查 finding high）。elicitation 由前端回（核心不代答，见 api.rs 的契约）。
    fn cancel_pending_permissions(&self, session_id: &str) -> Result<Vec<String>> {
        let to_cancel: Vec<Pending> = {
            let mut pending = lock(&self.shared.pending);
            let ids: Vec<String> = pending
                .iter()
                .filter(|(_, p)| p.method == METHOD_REQUEST_PERMISSION && p.session_id.as_deref() == Some(session_id))
                .map(|(id, _)| id.clone())
                .collect();
            ids.into_iter().filter_map(|id| pending.remove(&id)).collect()
        };
        let cancelled = serde_json::to_value(acp::RequestPermissionResponse::new(acp::RequestPermissionOutcome::Cancelled))?;
        let mut auto_cancelled = Vec::new();
        for p in to_cancel {
            let id = p.responder.id().to_string();
            let _ = p.responder.respond(cancelled.clone());
            auto_cancelled.push(id);
        }
        Ok(auto_cancelled)
    }

    /// 发 `session/cancel`；挂起的权限请求立刻回 `cancelled`，之后到本轮结束前到达的也自动回 `cancelled`。
    pub fn session_cancel(&self, session_id: &str) -> Result<Value> {
        self.shared.set_cancel_pending(session_id, true);
        let auto_cancelled = self.cancel_pending_permissions(session_id)?;
        self.connection
            .send_notification(acp::CancelNotification::new(acp::SessionId::new(session_id)))
            .map_err(|e| CoreError::Transport(e.to_string()))?;
        Ok(json!({ "cancelledRequestIds": auto_cancelled }))
    }

    pub async fn session_set_mode(&self, session_id: &str, mode_id: &str) -> Result<Value> {
        let request = acp::SetSessionModeRequest::new(acp::SessionId::new(session_id), acp::SessionModeId::new(mode_id));
        let response = race_exit(&self.shared, self.connection.send_request(request).block_task()).await?;
        Ok(serde_json::to_value(&response)?)
    }

    /// `value` 是 `SessionConfigOptionValue` 的 JSON（`{type, value}`；无 `type` 视为 select 的 value id）。
    pub async fn session_set_config_option(&self, session_id: &str, config_id: &str, value: Value) -> Result<Value> {
        let mut params = json!({ "sessionId": session_id, "configId": config_id });
        if let Value::Object(target) = &mut params {
            match value {
                Value::Object(fields) => target.extend(fields),
                other => {
                    target.insert("value".to_string(), other);
                }
            }
        }
        let request: acp::SetSessionConfigOptionRequest = serde_json::from_value(params)
            .map_err(|e| CoreError::InvalidArgument(format!("config option value: {e}")))?;
        let response = race_exit(&self.shared, self.connection.send_request(request).block_task()).await?;
        Ok(serde_json::to_value(&response)?)
    }

    pub async fn authenticate(&self, method_id: &str) -> Result<Value> {
        let request = acp::AuthenticateRequest::new(acp::AuthMethodId::new(method_id));
        let response = race_exit(&self.shared, self.connection.send_request(request).block_task()).await?;
        Ok(serde_json::to_value(&response)?)
    }

    /// 回应队列里的 `session/request_permission` / `elicitation/create`。`response` 是对应 Response 的 JSON，先按类型校验再回。
    pub fn respond(&self, request_id: &str, response: Value) -> Result<Value> {
        let pending = self
            .shared
            .take_pending(request_id)
            .ok_or_else(|| CoreError::UnknownRequest(request_id.to_string()))?;
        let method = pending.method.clone();
        let validation = match method.as_str() {
            METHOD_REQUEST_PERMISSION => serde_json::from_value::<acp::RequestPermissionResponse>(response.clone()).map(|_| ()),
            METHOD_ELICITATION_CREATE => serde_json::from_value::<acp::CreateElicitationResponse>(response.clone()).map(|_| ()),
            _ => Ok(()),
        };
        if let Err(e) = validation {
            // 校验失败把请求放回队列，让前端改正后再回。
            lock(&self.shared.pending).insert(request_id.to_string(), pending);
            return Err(CoreError::InvalidArgument(format!("{request_id}: response does not match {method}: {e}")));
        }
        pending
            .responder
            .respond(response)
            .map_err(|e| CoreError::Transport(e.to_string()))?;
        Ok(json!({ "requestId": request_id, "method": method }))
    }

    /// 关 stdin 让 agent 自行退出；超时结束进程树。幂等。
    pub async fn disconnect(&self) {
        disconnect(&self.shared, &self.shutdown, &self.kill).await;
    }
}

/// 把 `cancelledRequestIds` 并进响应 JSON（响应本身可能是 `{}` 或 `{"_meta": …}`）。
fn with_cancelled(mut response: Value, cancelled: Vec<String>) -> Value {
    let ids = Value::Array(cancelled.into_iter().map(Value::String).collect());
    match &mut response {
        Value::Object(map) => {
            map.insert("cancelledRequestIds".to_string(), ids);
            response
        }
        _ => json!({ "response": response, "cancelledRequestIds": ids }),
    }
}

/// 请求与进程退出赛跑：agent 死了不让调用方挂着。
async fn race_exit<T, F>(shared: &Shared, request: F) -> Result<T>
where
    F: Future<Output = std::result::Result<T, acp::Error>>,
{
    if let Some(exit) = shared.exit_info() {
        return Err(shared.exited_error(exit));
    }
    let result = tokio::select! {
        result = request => result,
        exit = shared.wait_exit() => return Err(shared.exited_error(exit)),
    };
    match result {
        Ok(value) => Ok(value),
        Err(e) if is_incoming_transport_closed(&e) => {
            // agent 的 stdout 先关、进程随后才被 wait 到：把退出码与 stderr 尾巴等出来再报，前端拿到的是 `exited` 而不是一句「传输关闭」。
            match tokio::time::timeout(EXIT_INFO_GRACE, shared.wait_exit()).await {
                Ok(exit) => Err(shared.exited_error(exit)),
                Err(_) => Err(CoreError::Transport(e.to_string())),
            }
        }
        Err(e) => Err(map_acp_error(shared, e)),
    }
}

/// `-32000` → `acp/agent_state: auth_required(authMethods)` + [`CoreError::AuthRequired`]；其他原样带出。
fn map_acp_error(shared: &Shared, error: acp::Error) -> CoreError {
    if error.code == acp::ErrorCode::AuthRequired {
        shared.emit_state(
            "auth_required",
            json!({
                "authMethods": shared.auth_methods(),
                "message": error.message,
            }),
        );
        return CoreError::AuthRequired {
            agent_id: shared.agent_id.clone(),
            message: error.message,
        };
    }
    let value = serde_json::to_value(&error).unwrap_or(Value::Null);
    CoreError::Acp {
        code: value.get("code").and_then(Value::as_i64).unwrap_or(-32603),
        message: error.message,
        data: error.data,
    }
}

async fn disconnect(shared: &Shared, shutdown: &Mutex<Option<oneshot::Sender<()>>>, kill: &Mutex<Option<oneshot::Sender<()>>>) {
    if let Some(tx) = lock(shutdown).take() {
        let _ = tx.send(());
    }
    if shared.exit_info().is_some() {
        return;
    }
    if tokio::time::timeout(DISCONNECT_GRACE, shared.wait_exit()).await.is_err() {
        if let Some(kill) = lock(kill).take() {
            let _ = kill.send(());
        }
        if tokio::time::timeout(DISCONNECT_GRACE, shared.wait_exit()).await.is_err() {
            // kill 之后仍等不到退出（典型是 `.cmd` 包装的孙进程还攥着 stdout）：这条连接对核心已经结束，
            // 就地收尾 —— 清挂起表、放终端、发 `exited`。不收的话它会在**新连接**跑起来之后才迟到，前端按
            // agentId 认领，把新连接刚挂起的权限 / elicitation 请求全标成 withdrawn、agent 从此干等
            // （审查 finding，2026-09-22）。`finish` 只生效一次：进程真退出时那一下就是空转。
            shared.finish(None);
        }
    }
}

// ---- 传输：stdin / stdout 行 tap（转写 Zed acp.rs 的 tapped_incoming / tapped_outgoing）

fn outgoing_sink(shared: Arc<Shared>, stdin: tokio::process::ChildStdin) -> impl futures::Sink<String, Error = std::io::Error> + Send + 'static {
    futures::sink::unfold((stdin, shared), |(mut stdin, shared), line: String| async move {
        shared.emit_traffic(Direction::Out, &line);
        stdin.write_all(line.as_bytes()).await?;
        stdin.write_all(b"\n").await?;
        stdin.flush().await?;
        Ok::<_, std::io::Error>((stdin, shared))
    })
}

fn incoming_stream(shared: Arc<Shared>, stdout: tokio::process::ChildStdout) -> impl futures::Stream<Item = std::io::Result<String>> + Send + 'static {
    let lines = BufReader::new(stdout).lines();
    futures::stream::unfold((lines, shared, false), |(mut lines, shared, failed)| async move {
        if failed {
            return None;
        }
        match lines.next_line().await {
            Ok(Some(line)) => {
                shared.emit_traffic(Direction::In, &line);
                Some((Ok(line), (lines, shared, false)))
            }
            Ok(None) => None,
            Err(e) => Some((Err(e), (lines, shared, true))),
        }
    })
}

/// stderr 单独一路：逐行进 traffic，并保留尾巴。
async fn stderr_task(shared: Arc<Shared>, stderr: tokio::process::ChildStderr) {
    let mut reader = BufReader::new(stderr);
    let mut buf = Vec::new();
    loop {
        buf.clear();
        match reader.read_until(b'\n', &mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(_) => {
                while matches!(buf.last(), Some(b'\n' | b'\r')) {
                    buf.pop();
                }
                // 先脱敏再进尾巴：尾巴会随 `exited` 事件与 `CoreError::Exited` 文案到前端与日志（规则 8；审查 finding）。
                let line = redact::redact_line(&String::from_utf8_lossy(&buf));
                shared.push_stderr(line.as_bytes());
                shared.emit_traffic_redacted(Direction::Stderr, line);
            }
        }
    }
}

/// 等子进程退出（或收到 kill 信号后结束进程树），然后 `finish`。
async fn exit_watcher(shared: Arc<Shared>, mut child: tokio::process::Child, kill_rx: oneshot::Receiver<()>) {
    let waited = tokio::select! {
        status = child.wait() => Some(status),
        _ = kill_rx => None,
    };
    let status = match waited {
        Some(status) => status,
        None => {
            command::kill_tree(&mut child).await;
            child.wait().await
        }
    };
    let code = status.ok().and_then(|s| s.code());
    tokio::time::sleep(STDERR_SETTLE).await;
    shared.finish(code);
}
