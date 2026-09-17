//! ACP 请求的落地：能力声明、会话表、生命周期五命令、一轮 prompt 的事件流。
//!
//! Derived from zed-industries/zed crates/eval_cli/src/main.rs @ d9e1c024f393832765a03f4de204d6c8cd9abcb2 (GPL-3.0-or-later)
//! （参考转写：`Project::local` + `create_worktree` + `NativeAgent::new` + `NativeAgentConnection` 的
//! 引导顺序、以及「先给所有 provider 跑一遍 authenticate 再找模型」这一步照 eval CLI；其余是本项目的。）
//!
//! 与 Zed 自己用 `NativeAgentConnection::prompt` 的路子有一处**刻意的不同**：那条路把 `ThreadEvent`
//! 写进进程内的 `AcpThread` 实体（Zed 的 UI 从那里渲染），而我们要的是把同一批事件**发到线上**去，
//! 让前端做投影。`handle_thread_events` 是 crate 私有的，也不可能一份事件流喂两个消费者，所以这里
//! 直接拿 `Entity<Thread>` 调 `Thread::send` / `Thread::replay`，自己消费事件流。
//!
//! 由此带来的两个已知取舍（记 rounds/BACKLOG.md）：
//! - `AcpThread` 实体仍然要**持有**（终端、子代理、释放会话都挂在它上面），但它的转录内容不再被填充。
//!   我们只用它的三件事：`create_terminal` 的落点、`session_id`、以及 `available_commands` 事件。
//! - Zed 的斜杠命令（`/compact`、MCP prompt、skill）在 `NativeAgentConnection::prompt` 里分流，
//!   这条路上没有；`session/prompt` 一律当普通消息发给模型。命令列表照常投影（前端能看到），
//!   但点了不会走 Zed 的特殊分支。

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use acp_thread::{AcpThread, AgentConnection as _};
use agent::{NativeAgent, NativeAgentConnection, Templates, Thread, ThreadEvent, ThreadStore};
use agent_client_protocol::schema::v1 as acp;
use agent_client_protocol::{Client, ConnectionTo, JsonRpcResponse, Responder};
use anyhow::{Context as _, Result, anyhow};
use futures::StreamExt as _;
use gpui::{AppContext as _, AsyncApp, Entity, Subscription, UpdateGlobal as _};
use language_model::LanguageModelRegistry;
use project::Project;
use settings::SettingsStore;
use util::path_list::PathList;

use crate::bridge::Incoming;
use crate::headless::AgentAppState;
use crate::translate;

/// 模型选择器在 ACP 侧的 config option id（画板 40 的模型下拉）。
const MODEL_CONFIG_ID: &str = "model";
/// 终端输出的轮询间隔：`acp_thread::Terminal` 只给全量快照，没有增量事件，只能定时差。
const TERMINAL_POLL_INTERVAL: Duration = Duration::from_millis(100);

pub struct Agent {
    state: Arc<AgentAppState>,
    /// 要读的 Zed `settings.json`（`--zed-settings`，默认是 `paths::settings_file()`）。
    settings_path: PathBuf,
    connection: ConnectionTo<Client>,
    /// [`Agent::warm_up`] 在 dispatcher 跑起来之前填好；之后只读。
    native: RefCell<Option<Native>>,
    sessions: RefCell<HashMap<acp::SessionId, Rc<SessionEntry>>>,
    projects: RefCell<HashMap<PathBuf, Entity<Project>>>,
}

#[derive(Clone)]
struct Native {
    connection: Rc<NativeAgentConnection>,
    thread_store: Entity<ThreadStore>,
}

struct SessionEntry {
    /// 会话的工作目录：diff 的相对路径要拼成绝对路径时用（见 `translate::diff_content`）。
    cwd: PathBuf,
    /// 必须一直持有：`NativeAgent` 用 `observe_release` 监视它，掉了会话就被释放掉。
    acp_thread: Entity<AcpThread>,
    thread: Entity<Thread>,
    /// 把 title / 用量 / 命令表的变化转成 `session/update` 的订阅；随会话一起丢弃。
    #[allow(dead_code)]
    subscriptions: Vec<Subscription>,
    /// 已经在推输出的终端。Zed 会在后续的 `tool_call_update` 里重复带同一个 terminal 内容块，
    /// 没有这个集合就会起一堆重复的泵、把同一段输出发好几遍。跟着会话走，会话关掉就整份丢掉。
    pumped_terminals: RefCell<HashSet<acp::TerminalId>>,
    /// 还没收尾的编辑 diff，按工具调用 id 索引（见 `UpdateDiff` 那一支的注释）。同样跟着会话走：
    /// 一条工具调用被取消、永远等不到终态时，它那份 diff 也随会话一起释放。
    diffs: RefCell<HashMap<acp::ToolCallId, Entity<acp_thread::Diff>>>,
}

impl Agent {
    pub fn new(
        state: Arc<AgentAppState>,
        settings_path: PathBuf,
        connection: ConnectionTo<Client>,
    ) -> Rc<Self> {
        Rc::new(Self {
            state,
            settings_path,
            connection,
            native: RefCell::new(None),
            sessions: RefCell::new(HashMap::new()),
            projects: RefCell::new(HashMap::new()),
        })
    }

    pub async fn handle(self: &Rc<Self>, incoming: Incoming, cx: &mut AsyncApp) -> Result<()> {
        match incoming {
            Incoming::Initialize(request, responder) => {
                responder.respond(initialize_response(&request)).ok();
                Ok(())
            }
            Incoming::Authenticate(_request, responder) => {
                // Zed 内置 agent 不做 ACP 层认证：模型密钥来自 Zed 的 settings.json / 环境变量
                // （docs/design.md § 8，所有者裁定 2026-09-15），`authMethods` 也是空的。
                responder.respond(acp::AuthenticateResponse::new()).ok();
                Ok(())
            }
            Incoming::NewSession(request, responder) => {
                let result = self.new_session(request, cx).await;
                respond(responder, result)
            }
            Incoming::LoadSession(request, responder) => {
                let result = self.load_session(request, true, cx).await.map(|options| {
                    let mut response = acp::LoadSessionResponse::new();
                    response.config_options = options;
                    response
                });
                respond(responder, result)
            }
            Incoming::ResumeSession(request, responder) => {
                // resume = load 的「不重放」版本（R6 的口径）：会话照样恢复成可用，但不再把历史推一遍。
                let load =
                    acp::LoadSessionRequest::new(request.session_id.clone(), request.cwd.clone());
                let result = self.load_session(load, false, cx).await.map(|options| {
                    let mut response = acp::ResumeSessionResponse::new();
                    response.config_options = options;
                    response
                });
                respond(responder, result)
            }
            Incoming::CloseSession(request, responder) => {
                // 丢掉 `AcpThread` 的强引用 = 让 `NativeAgent` 释放这条会话（它 observe_release 着）。
                self.sessions.borrow_mut().remove(&request.session_id);
                responder.respond(acp::CloseSessionResponse::new()).ok();
                Ok(())
            }
            Incoming::ListSessions(request, responder) => {
                let result = self.list_sessions(request, cx).await;
                respond(responder, result)
            }
            Incoming::DeleteSession(request, responder) => {
                let result = self.delete_session(request, cx).await;
                respond(responder, result)
            }
            Incoming::Prompt(request, responder) => {
                let result = self.prompt(request, cx).await;
                respond(responder, result)
            }
            Incoming::SetSessionMode(request, responder) => {
                // 我们不声明 modes（`NewSessionResponse.modes` 恒为 None），所以任何 mode id 都无效。
                let error = acp::Error::invalid_params().data(serde_json::json!({
                    "detail": format!("unknown mode `{}`", request.mode_id)
                }));
                responder.respond_with_error(error).ok();
                Ok(())
            }
            Incoming::SetSessionConfigOption(request, responder) => {
                let result = self.set_config_option(request, cx).await;
                respond(responder, result)
            }
            Incoming::Cancel(notification) => {
                self.cancel(&notification.session_id, cx);
                Ok(())
            }
        }
    }

    // ------------------------------------------------------------------ 引导

    /// 把 Zed 的 `settings.json` 读进 settings store（**只读**，规则 7）、给所有 provider 跑一遍
    /// `authenticate`、建 `NativeAgent`。
    ///
    /// **在 dispatcher 处理第一条消息之前跑一次**，不做惰性初始化：惰性版本里两条并发的请求
    /// （比如 `session/new` 与 `session/list`）会各自越过「还没建」的判断、各建一个 `NativeAgent`，
    /// 后一个把前一个覆盖掉 —— 于是先建的那条会话在后来的 `connection.thread(&id)` 里查不到，
    /// 报「no Zed thread registered」。这里没有 async 互斥原语可用，直接去掉并发窗口最省事。
    /// 代价：`initialize` 的往返里多了这一两秒（`--selftest` 实测整个引导 2.1 s）。
    pub async fn warm_up(self: &Rc<Self>, cx: &mut AsyncApp) {
        apply_zed_settings(&self.state, &self.settings_path, cx).await;
        authenticate_providers(cx).await;

        let native = cx.update(|cx| {
            // `agent_ui::init` 已经建过全局 ThreadStore，跟它共用同一个。
            let thread_store =
                ThreadStore::try_global(cx).unwrap_or_else(|| cx.new(ThreadStore::new));
            let agent = NativeAgent::new(
                thread_store.clone(),
                Templates::new(),
                self.state.fs.clone(),
                cx,
            );
            Native {
                connection: Rc::new(NativeAgentConnection(agent)),
                thread_store,
            }
        });
        *self.native.borrow_mut() = Some(native);
    }

    fn native(self: &Rc<Self>) -> Result<Native> {
        self.native
            .borrow()
            .clone()
            .ok_or_else(|| anyhow!("agent is not initialized yet"))
    }

    async fn project_for(
        self: &Rc<Self>,
        cwd: &std::path::Path,
        cx: &mut AsyncApp,
    ) -> Result<Entity<Project>> {
        if let Some(project) = self.projects.borrow().get(cwd) {
            return Ok(project.clone());
        }
        let project = cx.update(|cx| {
            Project::local(
                self.state.client.clone(),
                self.state.node_runtime.clone(),
                self.state.user_store.clone(),
                self.state.languages.clone(),
                self.state.fs.clone(),
                None,
                project::LocalProjectFlags {
                    // 客户端已经替用户选了这个目录（画板 41 的项目切换），不再要一次 Zed 的信任确认。
                    init_worktree_trust: false,
                    ..Default::default()
                },
                cx,
            )
        });

        let worktree = project
            .update(cx, |project, cx| project.create_worktree(cwd, true, cx))
            .await
            .with_context(|| format!("creating worktree for {}", cwd.display()))?;
        let scan = worktree.update(cx, |tree, _cx| {
            tree.as_local().map(|local| local.scan_complete())
        });
        if let Some(scan) = scan {
            scan.await;
        }

        self.projects
            .borrow_mut()
            .insert(cwd.to_path_buf(), project.clone());
        Ok(project)
    }

    // ------------------------------------------------------- 会话生命周期

    async fn new_session(
        self: &Rc<Self>,
        request: acp::NewSessionRequest,
        cx: &mut AsyncApp,
    ) -> Result<acp::NewSessionResponse> {
        let native = self.native()?;
        let project = self.project_for(&request.cwd, cx).await?;
        // `request.mcp_servers` 不接：`initialize` 里 `mcpCapabilities` 三项全是 false，客户端不该发；
        // Zed 自己的 MCP server 来自它的 settings.json，照常生效。`additional_directories` 同理
        // （我们不声明 `sessionCapabilities.additionalDirectories`，一个会话一个 cwd）。
        if !request.mcp_servers.is_empty() || !request.additional_directories.is_empty() {
            log::warn!(
                "session/new 带了 {} 个 mcpServers 与 {} 个 additionalDirectories，都没有声明过，忽略",
                request.mcp_servers.len(),
                request.additional_directories.len()
            );
        }

        let acp_thread = cx
            .update(|cx| {
                native
                    .connection
                    .clone()
                    .new_session(project, PathList::new(std::slice::from_ref(&request.cwd)), cx)
            })
            .await
            .context("creating a Zed agent thread")?;

        let session_id = acp_thread.read_with(cx, |thread, _cx| thread.session_id().clone());
        self.register(session_id.clone(), request.cwd.clone(), acp_thread, &native, cx)?;

        let mut response = acp::NewSessionResponse::new(session_id.clone());
        response.config_options = self.config_options(&session_id, cx)?;
        Ok(response)
    }

    /// `session/load`（`replay = true`）与 `session/resume`（`replay = false`）共用这一条。
    async fn load_session(
        self: &Rc<Self>,
        request: acp::LoadSessionRequest,
        replay: bool,
        cx: &mut AsyncApp,
    ) -> Result<Option<Vec<acp::SessionConfigOption>>> {
        let native = self.native()?;
        let project = self.project_for(&request.cwd, cx).await?;
        let session_id = request.session_id.clone();

        let already_open = self.sessions.borrow().contains_key(&session_id);
        if !already_open {
            let acp_thread = cx
                .update(|cx| {
                    native.connection.clone().load_session(
                        session_id.clone(),
                        project,
                        PathList::new(std::slice::from_ref(&request.cwd)),
                        None,
                        cx,
                    )
                })
                .await
                .with_context(|| format!("loading Zed agent thread {session_id}"))?;
            self.register(session_id.clone(), request.cwd.clone(), acp_thread, &native, cx)?;
        }

        if replay {
            let entry = self.session(&session_id)?;
            let events = entry.thread.update(cx, |thread, cx| thread.replay(cx));
            // 重放走和实时一模一样的翻译，前端的投影层因此不需要分两条路（R6 的等价性判据）。
            self.pump(&session_id, entry, events, cx).await?;
        }

        self.config_options(&session_id, cx)
    }

    async fn list_sessions(
        self: &Rc<Self>,
        request: acp::ListSessionsRequest,
        cx: &mut AsyncApp,
    ) -> Result<acp::ListSessionsResponse> {
        let native = self.native()?;
        // 刚建好的 ThreadStore 是空的，第一次读要等它把 threads.db 扫完。
        let reload = native
            .thread_store
            .read_with(cx, |store, _cx| store.reload_task());
        reload.await;

        let entries = native
            .thread_store
            .read_with(cx, |store, _cx| store.entries().collect::<Vec<_>>());
        let sessions = entries
            .into_iter()
            // `cwd` 过滤：Zed 的 thread 记的是一组 folder paths，只要包含请求的 cwd 就算命中。
            .filter(|entry| {
                request
                    .cwd
                    .as_ref()
                    .is_none_or(|cwd| entry.folder_paths.paths().iter().any(|path| path == cwd))
            })
            .map(|entry| {
                let cwd = entry
                    .folder_paths
                    .paths()
                    .first()
                    .cloned()
                    .or_else(|| request.cwd.clone())
                    .unwrap_or_default();
                acp::SessionInfo::new(entry.id.clone(), cwd)
                    .title(Some(entry.title.to_string()))
                    .updated_at(Some(entry.updated_at.to_rfc3339()))
            })
            .collect::<Vec<_>>();

        // Zed 的 ThreadStore 一次把全部条目读进内存，没有游标可给；`next_cursor` 恒为 None。
        Ok(acp::ListSessionsResponse::new(sessions))
    }

    async fn delete_session(
        self: &Rc<Self>,
        request: acp::DeleteSessionRequest,
        cx: &mut AsyncApp,
    ) -> Result<acp::DeleteSessionResponse> {
        let native = self.native()?;
        // 先放掉本地的会话实体，再删库：不然 `NativeAgent` 的保存 worker 可能把刚删掉的线程又写回去。
        self.sessions.borrow_mut().remove(&request.session_id);
        native
            .thread_store
            .update(cx, |store, cx| {
                store.delete_thread(request.session_id.clone(), cx)
            })
            .await
            .with_context(|| format!("deleting Zed agent thread {}", request.session_id))?;
        Ok(acp::DeleteSessionResponse::new())
    }

    fn cancel(self: &Rc<Self>, session_id: &acp::SessionId, cx: &mut AsyncApp) {
        let Ok(entry) = self.session(session_id) else {
            return;
        };
        entry
            .thread
            .update(cx, |thread, cx| thread.cancel(cx))
            .detach();
    }

    fn register(
        self: &Rc<Self>,
        session_id: acp::SessionId,
        cwd: PathBuf,
        acp_thread: Entity<AcpThread>,
        native: &Native,
        cx: &mut AsyncApp,
    ) -> Result<()> {
        let thread = cx
            .update(|cx| native.connection.thread(&session_id, cx))
            .ok_or_else(|| anyhow!("no Zed thread registered for {session_id}"))?;

        let subscriptions = cx.update(|cx| {
            vec![
                cx.subscribe(&acp_thread, {
                    let this = self.clone();
                    let session_id = session_id.clone();
                    move |_thread, event, _cx| {
                        if let acp_thread::AcpThreadEvent::AvailableCommandsUpdated(commands) =
                            event
                        {
                            this.notify(
                                &session_id,
                                acp::SessionUpdate::AvailableCommandsUpdate(
                                    acp::AvailableCommandsUpdate::new(commands.clone()),
                                ),
                            );
                        }
                    }
                }),
                cx.subscribe(&thread, {
                    let this = self.clone();
                    let session_id = session_id.clone();
                    move |thread, _event: &agent::TitleUpdated, cx| {
                        if let Some(title) = thread.read(cx).title() {
                            this.notify(
                                &session_id,
                                acp::SessionUpdate::SessionInfoUpdate(
                                    acp::SessionInfoUpdate::new().title(Some(title.to_string())),
                                ),
                            );
                        }
                    }
                }),
                cx.subscribe(&thread, {
                    let this = self.clone();
                    let session_id = session_id.clone();
                    move |_thread, event: &agent::TokenUsageUpdated, _cx| {
                        if let Some(usage) = &event.0 {
                            this.notify(
                                &session_id,
                                acp::SessionUpdate::UsageUpdate(acp::UsageUpdate::new(
                                    usage.used_tokens,
                                    usage.max_tokens,
                                )),
                            );
                        }
                    }
                }),
            ]
        });

        self.sessions.borrow_mut().insert(
            session_id,
            Rc::new(SessionEntry {
                cwd,
                acp_thread,
                thread,
                subscriptions,
                pumped_terminals: RefCell::new(HashSet::new()),
                diffs: RefCell::new(HashMap::new()),
            }),
        );
        Ok(())
    }

    fn session(self: &Rc<Self>, session_id: &acp::SessionId) -> Result<Rc<SessionEntry>> {
        self.sessions
            .borrow()
            .get(session_id)
            .cloned()
            .ok_or_else(|| anyhow!("unknown session `{session_id}`"))
    }

    // ------------------------------------------------------------ 模型选择

    fn config_options(
        self: &Rc<Self>,
        session_id: &acp::SessionId,
        cx: &mut AsyncApp,
    ) -> Result<Option<Vec<acp::SessionConfigOption>>> {
        let entry = self.session(session_id)?;
        Ok(cx.update(|cx| {
            let registry = LanguageModelRegistry::read_global(cx);
            let options = registry
                .available_models(cx)
                .map(|model| {
                    acp::SessionConfigSelectOption::new(
                        acp::SessionConfigValueId::new(model_value_id(
                            model.provider_id().0.as_ref(),
                            model.id().0.as_ref(),
                        )),
                        model.name().0.to_string(),
                    )
                })
                .collect::<Vec<_>>();
            if options.is_empty() {
                return None;
            }
            let current = entry
                .thread
                .read(cx)
                .model()
                .map(|model| model_value_id(model.provider_id().0.as_ref(), model.id().0.as_ref()))
                .unwrap_or_else(|| options[0].value.to_string());
            Some(vec![
                acp::SessionConfigOption::new(
                    acp::SessionConfigId::new(MODEL_CONFIG_ID),
                    "Model",
                    acp::SessionConfigKind::Select(acp::SessionConfigSelect::new(
                        acp::SessionConfigValueId::new(current),
                        acp::SessionConfigSelectOptions::Ungrouped(options),
                    )),
                )
                .category(Some(acp::SessionConfigOptionCategory::Model)),
            ])
        }))
    }

    async fn set_config_option(
        self: &Rc<Self>,
        request: acp::SetSessionConfigOptionRequest,
        cx: &mut AsyncApp,
    ) -> Result<acp::SetSessionConfigOptionResponse> {
        let entry = self.session(&request.session_id)?;
        if request.config_id.to_string() != MODEL_CONFIG_ID {
            anyhow::bail!("unknown config option `{}`", request.config_id);
        }
        let acp::SessionConfigOptionValue::ValueId { value } = &request.value else {
            anyhow::bail!("config option `{MODEL_CONFIG_ID}` expects a value id");
        };
        let wanted = value.to_string();

        cx.update(|cx| {
            let model = LanguageModelRegistry::read_global(cx)
                .available_models(cx)
                .find(|model| {
                    model_value_id(model.provider_id().0.as_ref(), model.id().0.as_ref()) == wanted
                })
                .ok_or_else(|| anyhow!("unknown model `{wanted}`"))?;
            // 只改这一条线程的模型，**不**像 Zed 的 `NativeAgentModelSelector::select_model` 那样
            // 顺手回写用户的 settings.json（CLAUDE.md 规则 7：不动用户数据）。
            entry
                .thread
                .update(cx, |thread, cx| thread.set_model(model, cx));
            anyhow::Ok(())
        })?;

        let options = self
            .config_options(&request.session_id, cx)?
            .unwrap_or_default();
        Ok(acp::SetSessionConfigOptionResponse::new(options))
    }

    // ---------------------------------------------------------------- 一轮

    async fn prompt(
        self: &Rc<Self>,
        request: acp::PromptRequest,
        cx: &mut AsyncApp,
    ) -> Result<acp::PromptResponse> {
        let entry = self.session(&request.session_id)?;
        let path_style = entry
            .thread
            .read_with(cx, |thread, cx| thread.project().read(cx).path_style(cx));
        let content = request
            .prompt
            .into_iter()
            .map(|block| agent::UserMessageContent::from_content_block(block, path_style))
            .collect::<Vec<_>>();

        let events = entry.thread.update(cx, |thread, cx| {
            thread.send(acp_thread::ClientUserMessageId::new(), content, cx)
        })?;

        let stop_reason = self
            .pump(&request.session_id, entry.clone(), events, cx)
            .await?;
        let mut response = acp::PromptResponse::new(stop_reason);
        if let Some(usage) = entry
            .thread
            .read_with(cx, |thread, _cx| thread.latest_token_usage())
        {
            response.usage = Some(acp::Usage::new(
                usage.used_tokens,
                usage.input_tokens,
                usage.output_tokens,
            ));
        }
        Ok(response)
    }

    /// 把一条 `ThreadEvent` 流抽干，边抽边翻译成 `session/update`；返回这一轮的 `stopReason`。
    ///
    /// 事件流结束而没有 `Stop` 时按 `end_turn` 收尾，与 Zed 的 `handle_thread_events` 一致。
    async fn pump(
        self: &Rc<Self>,
        session_id: &acp::SessionId,
        entry: Rc<SessionEntry>,
        mut events: futures::channel::mpsc::UnboundedReceiver<Result<ThreadEvent>>,
        cx: &mut AsyncApp,
    ) -> Result<acp::StopReason> {
        // 事件流活着期间必须按住会话条目：它一掉，`AcpThread` 就被释放，正在跑的工具会失去落点。
        while let Some(event) = events.next().await {
            match event? {
                ThreadEvent::UserMessage(message) => {
                    for content in message.content.iter() {
                        let block: acp::ContentBlock = content.clone().into();
                        self.notify(
                            session_id,
                            acp::SessionUpdate::UserMessageChunk(acp::ContentChunk::new(block)),
                        );
                    }
                }
                ThreadEvent::AgentText(text) => self.notify(
                    session_id,
                    acp::SessionUpdate::AgentMessageChunk(acp::ContentChunk::new(text_block(text))),
                ),
                ThreadEvent::AgentThinking(text) => self.notify(
                    session_id,
                    acp::SessionUpdate::AgentThoughtChunk(acp::ContentChunk::new(text_block(text))),
                ),
                ThreadEvent::ToolCall(mut tool_call) => {
                    // 工具调用第一条就带终端的情况（重放时会遇到）：和更新那一支同样处理。
                    let meta = self.attach_terminals(
                        session_id,
                        &entry,
                        &tool_call.tool_call_id,
                        &tool_call.content,
                        cx,
                    );
                    if meta.is_some() {
                        tool_call.meta = meta;
                    }
                    self.notify(session_id, acp::SessionUpdate::ToolCall(tool_call))
                }
                ThreadEvent::ToolCallUpdate(update) => {
                    self.forward_tool_call_update(session_id, &entry, update, cx)
                }
                ThreadEvent::ToolCallAuthorization(authorization) => {
                    self.request_permission(session_id, authorization, cx);
                }
                ThreadEvent::ToolCallAuthorizationResolved { .. } => {
                    // 这条是 Zed UI 用来收起自己那张卡的；线上那张卡由 `session/request_permission`
                    // 的**响应**收尾，再发一条只会让前端多一次无主的状态跳变。
                }
                ThreadEvent::Elicitation(request) => {
                    self.request_elicitation(session_id, request, cx);
                }
                ThreadEvent::SubagentSpawned(subagent_id) => {
                    // 子代理在 Zed 里是**另一条会话**，它的事件不经过本轮的流。前端的子代理卡（画板 24）
                    // 只认 `_meta` 识别键，而 § 4 的清单里没有 Zed 的键，所以这里只记日志、不投影。
                    log::debug!("subagent {subagent_id} spawned under {session_id}");
                }
                ThreadEvent::Retry(status) => {
                    log::info!(
                        "retrying ({}/{}) after: {}",
                        status.attempt,
                        status.max_attempts,
                        status.last_error
                    );
                }
                ThreadEvent::ContextCompaction(_) | ThreadEvent::ContextCompactionUpdate(_) => {
                    // 压缩卡（画板 33）走 unstable 的 `compaction_update`，而 zed 钉版本的
                    // agent-client-protocol 2.0.0 的 `unstable` 伞里没有 `unstable_session_compaction`
                    // （规则 10 不许单独改特性集），编不出那个变体。记 BACKLOG，不硬凑。
                }
                ThreadEvent::Stop(stop_reason) => return Ok(stop_reason),
            }
        }
        Ok(acp::StopReason::EndTurn)
    }

    fn forward_tool_call_update(
        self: &Rc<Self>,
        session_id: &acp::SessionId,
        entry: &Rc<SessionEntry>,
        update: acp_thread::ToolCallUpdate,
        cx: &mut AsyncApp,
    ) {
        match update {
            acp_thread::ToolCallUpdate::UpdateFields(mut update) => {
                // Zed 的 terminal 工具走的就是这一支：它把 `ToolCallContent::Terminal(terminal_id)`
                // 放进 `fields.content`（`tools/terminal_tool.rs`），**不**走下面的 `UpdateTerminal`。
                // 客户端手上没有这个终端（它是 agent 进程内的），所以要顺带把 `_meta.terminal_info`
                // 挂上并开始推输出，否则前端只看得到一张空的终端卡（R7 实测）。
                if let Some(content) = update.fields.content.as_deref() {
                    let meta = self.attach_terminals(
                        session_id,
                        entry,
                        &update.tool_call_id,
                        content,
                        cx,
                    );
                    if meta.is_some() {
                        update.meta = meta;
                    }
                }
                let finished = matches!(
                    update.fields.status,
                    Some(acp::ToolCallStatus::Completed) | Some(acp::ToolCallStatus::Failed)
                );
                let tool_call_id = update.tool_call_id.clone();
                self.notify(session_id, acp::SessionUpdate::ToolCallUpdate(update));
                if finished {
                    self.flush_diff(session_id, entry, &tool_call_id, cx);
                }
            }
            acp_thread::ToolCallUpdate::UpdateDiff(diff) => {
                // 这条事件在编辑**开始**时就到了，那时 buffer 还是空的（R7 实测：oldText / newText
                // 都是空串）。所以记下这个 diff 实体，等工具调用收尾时再读一次发终稿。
                entry
                    .diffs
                    .borrow_mut()
                    .insert(diff.id.clone(), diff.diff.clone());
                self.emit_diff(session_id, entry, &diff.id, &diff.diff, cx);
            }
            acp_thread::ToolCallUpdate::UpdateTerminal(terminal) => {
                let (terminal_id, cwd) = terminal.terminal.read_with(cx, |terminal, _cx| {
                    (terminal.id().clone(), terminal.working_dir().clone())
                });
                // 先让前端把这条工具卡认成终端卡（画板 22），再开始推输出。
                let update = acp::ToolCallUpdate::new(
                    terminal.id.clone(),
                    acp::ToolCallUpdateFields::new().content(Some(vec![
                        acp::ToolCallContent::Terminal(acp::Terminal::new(terminal_id.clone())),
                    ])),
                )
                .meta(Some(translate::terminal_info_meta(
                    &terminal_id,
                    cwd.as_deref(),
                )));
                self.notify(session_id, acp::SessionUpdate::ToolCallUpdate(update));
                self.pump_terminal(
                    session_id.clone(),
                    terminal.id,
                    terminal_id,
                    terminal.terminal,
                    cx,
                );
            }
        }
    }

    /// 工具调用收尾时把它的 diff 再发一遍终稿（见 `UpdateDiff` 那一支的注释），并忘掉它。
    fn flush_diff(
        self: &Rc<Self>,
        session_id: &acp::SessionId,
        entry: &Rc<SessionEntry>,
        tool_call_id: &acp::ToolCallId,
        cx: &mut AsyncApp,
    ) {
        let Some(diff) = entry.diffs.borrow_mut().remove(tool_call_id) else {
            return;
        };
        self.emit_diff(session_id, entry, tool_call_id, &diff, cx);
    }

    fn emit_diff(
        self: &Rc<Self>,
        session_id: &acp::SessionId,
        entry: &Rc<SessionEntry>,
        tool_call_id: &acp::ToolCallId,
        diff: &Entity<acp_thread::Diff>,
        cx: &mut AsyncApp,
    ) {
        let Some(content) = cx.update(|cx| translate::diff_content(diff, &entry.cwd, cx)) else {
            return;
        };
        let update = acp::ToolCallUpdate::new(
            tool_call_id.clone(),
            acp::ToolCallUpdateFields::new().content(Some(vec![content])),
        );
        self.notify(session_id, acp::SessionUpdate::ToolCallUpdate(update));
    }

    /// 在一批 `ToolCallContent` 里找 `Terminal`，为**还没开始推**的那些起输出泵，并返回要挂在这条
    /// 更新上的 `_meta.terminal_info`。
    ///
    /// `_meta` 的 `terminal_info` 只有一个位置，而一条工具调用实际上只会带一个终端；多于一个时
    /// 只给第一个挂 info（其余仍会推输出，前端按 `terminal_id` 分桶），并记一行日志。
    fn attach_terminals(
        self: &Rc<Self>,
        session_id: &acp::SessionId,
        entry: &Rc<SessionEntry>,
        tool_call_id: &acp::ToolCallId,
        content: &[acp::ToolCallContent],
        cx: &mut AsyncApp,
    ) -> Option<acp::Meta> {
        let mut meta = None;
        for item in content {
            let acp::ToolCallContent::Terminal(terminal) = item else {
                continue;
            };
            let terminal_id = terminal.terminal_id.clone();
            if !entry.pumped_terminals.borrow_mut().insert(terminal_id.clone()) {
                continue;
            }
            let handle = entry
                .acp_thread
                .read_with(cx, |thread, _cx| thread.terminal(terminal_id.clone()));
            let handle = match handle {
                Ok(handle) => handle,
                Err(error) => {
                    log::warn!("terminal {terminal_id} not registered on the thread: {error}");
                    entry.pumped_terminals.borrow_mut().remove(&terminal_id);
                    continue;
                }
            };
            let cwd = handle.read_with(cx, |terminal, _cx| terminal.working_dir().clone());
            if meta.is_none() {
                meta = Some(translate::terminal_info_meta(&terminal_id, cwd.as_deref()));
            } else {
                log::debug!("tool call {tool_call_id} carries more than one terminal");
            }
            self.pump_terminal(
                session_id.clone(),
                tool_call_id.clone(),
                terminal_id,
                handle,
                cx,
            );
        }
        meta
    }

    /// 把一个进程内终端的输出以 `_meta.terminal_output` 增量推给客户端，退出时补一条
    /// `_meta.terminal_exit`。任务随会话活着，命令结束就自己收尾。
    fn pump_terminal(
        self: &Rc<Self>,
        session_id: acp::SessionId,
        tool_call_id: acp::ToolCallId,
        terminal_id: acp::TerminalId,
        terminal: Entity<acp_thread::Terminal>,
        cx: &mut AsyncApp,
    ) {
        let this = self.clone();
        cx.spawn(async move |cx| {
            let mut tracker = translate::OutputTracker::default();
            let wait_for_exit = terminal.read_with(cx, |terminal, _cx| terminal.wait_for_exit());
            let mut exit = std::pin::pin!(futures::FutureExt::fuse(wait_for_exit));
            let exit_status = loop {
                let timer = cx.background_executor().timer(TERMINAL_POLL_INTERVAL);
                let finished = futures::select_biased! {
                    status = exit => Some(status),
                    _ = futures::FutureExt::fuse(timer) => None,
                };
                let snapshot = terminal.read_with(cx, |terminal, cx| terminal.current_output(cx));
                if let Some(delta) = tracker.delta(snapshot.output.trim_end()) {
                    this.notify_terminal_output(&session_id, &tool_call_id, &terminal_id, &delta);
                }
                if let Some(status) = finished {
                    break status;
                }
            };
            // 退出后再读一次：最后一段输出可能在退出那一刻才落进缓冲。
            let snapshot = terminal.read_with(cx, |terminal, cx| terminal.current_output(cx));
            if let Some(delta) = tracker.delta(snapshot.output.trim_end()) {
                this.notify_terminal_output(&session_id, &tool_call_id, &terminal_id, &delta);
            }
            let update = acp::ToolCallUpdate::new(tool_call_id, acp::ToolCallUpdateFields::new())
                .meta(Some(translate::terminal_exit_meta(
                    &terminal_id,
                    &exit_status,
                )));
            this.notify(&session_id, acp::SessionUpdate::ToolCallUpdate(update));
        })
        .detach();
    }

    fn notify_terminal_output(
        self: &Rc<Self>,
        session_id: &acp::SessionId,
        tool_call_id: &acp::ToolCallId,
        terminal_id: &acp::TerminalId,
        delta: &str,
    ) {
        let update =
            acp::ToolCallUpdate::new(tool_call_id.clone(), acp::ToolCallUpdateFields::new())
                .meta(Some(translate::terminal_output_meta(terminal_id, delta)));
        self.notify(session_id, acp::SessionUpdate::ToolCallUpdate(update));
    }

    fn request_permission(
        self: &Rc<Self>,
        session_id: &acp::SessionId,
        authorization: agent::ToolCallAuthorization,
        cx: &mut AsyncApp,
    ) {
        let options = translate::permission_options(&authorization.options);
        let connection = self.connection.clone();
        let session_id = session_id.clone();
        cx.spawn(async move |_cx| {
            let request = acp::RequestPermissionRequest::new(
                session_id,
                authorization.tool_call.clone(),
                options.clone(),
            );
            let selected = match connection.send_request(request).block_task().await {
                Ok(response) => match response.outcome {
                    acp::RequestPermissionOutcome::Selected(selected) => options
                        .iter()
                        .find(|option| option.option_id == selected.option_id)
                        .map(outcome_of),
                    acp::RequestPermissionOutcome::Cancelled => None,
                    // `RequestPermissionOutcome` 是 non_exhaustive：将来多出来的结果一律按「没选」
                    // 处理，下面会兜成拒绝这一次，绝不把 responder 丢掉。
                    _ => None,
                },
                Err(error) => {
                    log::warn!("session/request_permission failed: {error}");
                    None
                }
            };
            // 拿不到选择（取消 / 出错 / 选了个不存在的 id）时按「拒绝这一次」收尾：
            // 把 responder 丢掉会让工具调用永远挂着（CLAUDE.md「会让 agent 挂起」的那类缺陷）。
            let selected = selected.unwrap_or_else(|| {
                options
                    .iter()
                    .find(|option| option.kind == acp::PermissionOptionKind::RejectOnce)
                    .or_else(|| options.first())
                    .map(outcome_of)
                    .unwrap_or_else(|| acp_thread::SelectedPermissionOutcome {
                        option_id: acp::PermissionOptionId::new("reject"),
                        option_kind: acp::PermissionOptionKind::RejectOnce,
                        params: None,
                    })
            });
            authorization.response.send(selected).ok();
        })
        .detach();
    }

    fn request_elicitation(
        self: &Rc<Self>,
        session_id: &acp::SessionId,
        request: agent::ElicitationRequest,
        cx: &mut AsyncApp,
    ) {
        let connection = self.connection.clone();
        let session_id = session_id.clone();
        cx.spawn(async move |_cx| {
            let scope = acp::ElicitationSessionScope::new(session_id)
                .tool_call_id(Some(request.tool_call_id.clone()));
            let outgoing = acp::CreateElicitationRequest::new(
                acp::ElicitationMode::Form(acp::ElicitationFormMode::new(
                    scope,
                    request.schema.clone(),
                )),
                request.message.clone(),
            );
            let response = connection
                .send_request(outgoing)
                .block_task()
                .await
                .unwrap_or_else(|error| {
                    log::warn!("elicitation/create failed: {error}");
                    acp::CreateElicitationResponse::new(acp::ElicitationAction::Cancel)
                });
            request.response.send(response).ok();
        })
        .detach();
    }

    fn notify(self: &Rc<Self>, session_id: &acp::SessionId, update: acp::SessionUpdate) {
        if let Err(error) = self
            .connection
            .send_notification(acp::SessionNotification::new(session_id.clone(), update))
        {
            log::debug!("session/update dropped ({session_id}): {error}");
        }
    }
}

fn outcome_of(option: &acp::PermissionOption) -> acp_thread::SelectedPermissionOutcome {
    acp_thread::SelectedPermissionOutcome {
        option_id: option.option_id.clone(),
        option_kind: option.kind,
        params: None,
    }
}

fn text_block(text: String) -> acp::ContentBlock {
    acp::ContentBlock::Text(acp::TextContent::new(text))
}

fn model_value_id(provider: &str, model: &str) -> String {
    format!("{provider}/{model}")
}

/// 读 Zed 的 `settings.json` 并应用；读不到就按默认值继续（**只读**，规则 7）。
async fn apply_zed_settings(
    state: &Arc<AgentAppState>,
    path: &std::path::Path,
    cx: &mut AsyncApp,
) {
    match state.fs.load(path).await {
        Ok(content) => cx.update(|cx| {
            SettingsStore::update_global(cx, |store, cx| {
                if let Err(error) = store.set_user_settings(&content, cx).result() {
                    log::warn!("Zed 的 settings.json 解析失败，按默认值继续：{error}");
                }
            });
        }),
        Err(error) => log::info!("没读到 Zed 的 settings.json（{}）：{error}", path.display()),
    }
}

/// 给所有 provider 跑一遍 `authenticate`（照 eval CLI）：密钥来自 settings 或环境变量，
/// 不跑这一步 `available_models` 会是空的。
///
/// 必须和 [`apply_zed_settings`] 分成两次 `cx.update`：gpui 要在两次之间把 `SettingsStore` 的
/// 全局观察者效应冲干净，provider 才注册得完（eval CLI 的原注释）。
async fn authenticate_providers(cx: &mut AsyncApp) {
    let tasks = cx.update(|cx| {
        LanguageModelRegistry::global(cx).update(cx, |registry, cx| {
            registry
                .providers()
                .iter()
                .map(|provider| provider.authenticate(cx))
                .collect::<Vec<_>>()
        })
    });
    futures::future::join_all(tasks).await;
}

/// 固定能力（docs/design.md § 8「initialize → 固定能力」）。
///
/// - `loadSession: true`：Zed 的线程本来就落在 threads.db 里，重放走 `Thread::replay`。
/// - `sessionCapabilities`：list / delete / resume / close 四项都支持；`fork` 与
///   `additionalDirectories` 不支持（一个会话一个 cwd）。
/// - `authMethods` 为空：模型密钥沿用 Zed 的 settings.json / 环境变量，不做额外的认证页
///   （所有者裁定 2026-09-15）。
/// - `promptCapabilities`：图片与嵌入式上下文走 `UserMessageContent::from_content_block`；音频那条
///   在 Zed 里被降级成 `[audio]` 占位文本，所以**不**声明 audio，免得前端以为能发。
/// - 协议版本**回我们真正会说的那个**（V1），不是把客户端要的原样回过去：`ProtocolVersion` 是个
///   `u16` 新类型，客户端要 2 我们也能鹦鹉学舌地回 2，然后按 V1 说话 —— 那是最难查的一类错。
///   规范就是「取双方都支持的最高版本」，我们只有 V1。
fn initialize_response(request: &acp::InitializeRequest) -> acp::InitializeResponse {
    // `ProtocolVersion` 挂在 `schema` 根上，不在 `schema::v1` 里。
    let version = request
        .protocol_version
        .min(agent_client_protocol::schema::ProtocolVersion::V1);
    let capabilities = acp::AgentCapabilities::new()
        .load_session(true)
        .prompt_capabilities(
            acp::PromptCapabilities::new()
                .image(true)
                .audio(false)
                .embedded_context(true),
        )
        .session_capabilities(
            acp::SessionCapabilities::new()
                .list(Some(acp::SessionListCapabilities::new()))
                .delete(Some(acp::SessionDeleteCapabilities::new()))
                .resume(Some(acp::SessionResumeCapabilities::new()))
                .close(Some(acp::SessionCloseCapabilities::new())),
        );
    acp::InitializeResponse::new(version)
        .agent_capabilities(capabilities)
        .agent_info(Some(acp::Implementation::new(
            "zed-agent-acp",
            env!("CARGO_PKG_VERSION"),
        )))
}

/// 把 `anyhow` 的失败折成 ACP 的 `-32603`，并且**一定**回一条响应：丢掉 responder 会让对端
/// 的请求永远挂着（R1 踩过一次）。
fn respond<T: JsonRpcResponse>(responder: Responder<T>, result: Result<T>) -> Result<()> {
    match result {
        Ok(response) => {
            responder.respond(response).ok();
            Ok(())
        }
        Err(error) => {
            let message = format!("{error:#}");
            responder
                .respond_with_error(
                    acp::Error::internal_error()
                        .data(serde_json::json!({ "detail": message.clone() })),
                )
                .ok();
            Err(anyhow!(message))
        }
    }
}

/// `--selftest`：不进 ACP 循环，只把无头环境跑起来、报一行可用模型情况（任务卡验收 1）。
pub async fn selftest_report(
    state: &Arc<AgentAppState>,
    path: &std::path::Path,
    cx: &mut AsyncApp,
) -> Result<String> {
    let loaded = state.fs.load(path).await.is_ok();
    apply_zed_settings(state, path, cx).await;
    authenticate_providers(cx).await;

    let models = cx.update(|cx| {
        LanguageModelRegistry::read_global(cx)
            .available_models(cx)
            .map(|model| format!("{}/{}", model.provider_id().0, model.id().0))
            .collect::<Vec<_>>()
    });

    Ok(format!(
        "zed-agent-acp selftest ok\n  settings: {}\n  models: {}\n  sample: {}",
        if loaded {
            path.display().to_string()
        } else {
            "(none)".to_owned()
        },
        models.len(),
        models.iter().take(3).cloned().collect::<Vec<_>>().join(", ")
    ))
}
