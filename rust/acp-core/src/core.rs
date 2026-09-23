//! `Core`：进程内唯一的核心实例。持有 tokio runtime、数据目录、事件出口、settings、终端表与 agent 连接表。
//! 对外的 async 方法都要在 [`Core::runtime`] 上跑（桥层 `runtime().spawn(...)`，acp-smoke `block_on`）。

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use base64::prelude::*;
use registry::manifest::AuthStatus;
use registry::{CancelToken, RegistryDirs};
use serde_json::{Value, json};
use settings::index::{IndexStore, SessionEntry};
use settings::ui_state::{UiState, UiStateStore};
use settings::{AgentServer, SettingsStore};

use crate::agent::AgentConnection;
use crate::command::LaunchSpec;
use crate::error::{CoreError, Result};
use crate::events::{EventChannel, EventSink};
use crate::log::LoggingSink;
use crate::terminal_auth;

pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");

pub struct Core {
    data_dir: PathBuf,
    sink: Arc<dyn EventSink>,
    runtime: tokio::runtime::Runtime,
    ping_seq: AtomicU64,
    settings: SettingsStore,
    index: IndexStore,
    ui_state: UiStateStore,
    terminals: Arc<pty::TerminalManager>,
    agents: Mutex<HashMap<String, Arc<AgentConnection>>>,
    /// 收尾令牌：`core_shutdown` 一开始就置位。之后的 `agent_connect` 一律回 `cancelled`，还在握手的那些中止握手、结束进程树。
    closing: CancelToken,
    /// 在途的 `agent_connect` 各持一把读锁，`core_shutdown` 拿写锁 = 等它们全部落定：握手赢了的已经插进连接表（随后一起断开），
    /// 被中止的已经结束进程树。不等的话，关窗那一刻还在握手的 agent 不在表里，进程退出后留成孤儿（BACKLOG P0）。
    connect_gate: tokio::sync::RwLock<()>,
    /// 文件面板的目录监视（R4），按项目根去重；drop 即停。
    watchers: Mutex<HashMap<PathBuf, fs::watch::DirWatcher>>,
    // ---- R5：registry / 安装 / 受管 Node / 日志（编排在 registry_ops.rs）
    registry_dirs: RegistryDirs,
    registry_index: registry::index::IndexStore,
    http: registry::HttpClient,
    /// 正在跑的安装任务（agentId → 取消令牌）。
    installs: Mutex<HashMap<String, Arc<CancelToken>>>,
    node_download: Mutex<Option<Arc<CancelToken>>>,
    log_path: PathBuf,
}

impl std::fmt::Debug for Core {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Core")
            .field("data_dir", &self.data_dir)
            .finish_non_exhaustive()
    }
}

pub(crate) fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    match m.lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    }
}

/// 当前时间（Unix 毫秒）。
pub fn now_ms() -> i64 {
    settings::index::now_ms()
}

/// 终端字节 → `acp/terminal_output`：`{terminalId, source, bytes}`（base64）与 `{terminalId, source, exitStatus}`。
struct TerminalEvents {
    sink: Arc<dyn EventSink>,
}

impl pty::TerminalSink for TerminalEvents {
    fn output(&self, terminal_id: &str, source: pty::TerminalSource, bytes: &[u8]) {
        let payload = json!({
            "terminalId": terminal_id,
            "source": source.as_str(),
            "bytes": BASE64_STANDARD.encode(bytes),
        });
        self.sink.emit(EventChannel::TerminalOutput, payload.to_string());
    }

    fn exited(&self, terminal_id: &str, source: pty::TerminalSource, status: &pty::ExitStatus) {
        let payload = json!({
            "terminalId": terminal_id,
            "source": source.as_str(),
            "exitStatus": exit_status_json(status),
        });
        self.sink.emit(EventChannel::TerminalOutput, payload.to_string());
    }
}

fn exit_status_json(status: &pty::ExitStatus) -> Value {
    json!({ "exitCode": status.exit_code, "signal": status.signal })
}

impl Core {
    /// 建核心：校验并创建数据目录（docs/design.md § 10），起 tokio 多线程 runtime，然后发一条 `acp/agent_state: core_ready`。
    pub fn new(data_dir: impl AsRef<Path>, sink: Arc<dyn EventSink>) -> Result<Self> {
        let data_dir = data_dir.as_ref();
        if data_dir.as_os_str().is_empty() || !data_dir.is_absolute() {
            return Err(CoreError::InvalidDataDir(
                data_dir.to_string_lossy().into_owned(),
            ));
        }
        std::fs::create_dir_all(data_dir)
            .map_err(|e| CoreError::InvalidDataDir(format!("{}: {e}", data_dir.display())))?;
        // 事件先过一遍日志（`logs/acp-<日期>.log`，docs/design.md § 10），再到桥的 sink。
        let logging = Arc::new(LoggingSink::new(sink, data_dir.join("logs")));
        let log_path = logging.log_path().to_path_buf();
        // 每次起核心写一行版本与构建信息（R8）。sidecar 那半段是装机排障的第一问：随包了没有。
        logging.banner(&format!(
            "core   {} {} ({}, {}/{}) data={} sidecar={}",
            crate::capabilities::CLIENT_NAME,
            env!("CARGO_PKG_VERSION"),
            if cfg!(debug_assertions) { "debug" } else { "release" },
            std::env::consts::OS,
            std::env::consts::ARCH,
            data_dir.display(),
            crate::builtin::sidecar_path()
                .map(|p| p.display().to_string())
                .unwrap_or_else(|| "none".to_owned()),
        ));
        let sink: Arc<dyn EventSink> = logging;
        // SDK 的 dispatch 链在 debug 构建里每条入站消息要约 0.5 MiB 栈（Zed 实测），worker 栈给足。
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .thread_name("acp-core")
            .thread_stack_size(8 * 1024 * 1024)
            .enable_all()
            .build()?;
        let terminals = Arc::new(pty::TerminalManager::new(Arc::new(TerminalEvents { sink: sink.clone() })));
        let registry_dirs = RegistryDirs::new(data_dir);
        let http = registry::download::client();
        let registry_index = registry::index::IndexStore::new(registry_dirs.clone(), http.clone());
        let core = Self {
            data_dir: data_dir.to_path_buf(),
            settings: SettingsStore::new(data_dir.to_path_buf()),
            index: IndexStore::new(data_dir.to_path_buf()),
            ui_state: UiStateStore::new(data_dir.to_path_buf()),
            sink,
            runtime,
            ping_seq: AtomicU64::new(0),
            terminals,
            agents: Mutex::new(HashMap::new()),
            closing: CancelToken::default(),
            connect_gate: tokio::sync::RwLock::new(()),
            watchers: Mutex::new(HashMap::new()),
            registry_dirs,
            registry_index,
            http,
            installs: Mutex::new(HashMap::new()),
            node_download: Mutex::new(None),
            log_path,
        };
        core.announce_ready();
        Ok(core)
    }

    pub fn data_dir(&self) -> &Path {
        &self.data_dir
    }

    pub fn runtime(&self) -> &tokio::runtime::Runtime {
        &self.runtime
    }

    pub fn terminals(&self) -> &Arc<pty::TerminalManager> {
        &self.terminals
    }

    pub fn settings(&self) -> &SettingsStore {
        &self.settings
    }

    pub fn index(&self) -> &IndexStore {
        &self.index
    }

    pub fn registry_dirs(&self) -> &RegistryDirs {
        &self.registry_dirs
    }

    pub fn registry_index(&self) -> &registry::index::IndexStore {
        &self.registry_index
    }

    pub fn http(&self) -> &registry::HttpClient {
        &self.http
    }

    pub fn log_path(&self) -> &Path {
        &self.log_path
    }

    pub(crate) fn terminal_manager(&self) -> Arc<pty::TerminalManager> {
        self.terminals.clone()
    }

    pub(crate) fn event_sink(&self) -> Arc<dyn EventSink> {
        self.sink.clone()
    }

    pub(crate) fn installs(&self) -> &Mutex<HashMap<String, Arc<CancelToken>>> {
        &self.installs
    }

    pub(crate) fn node_download_token(&self) -> &Mutex<Option<Arc<CancelToken>>> {
        &self.node_download
    }

    pub(crate) fn agents(&self) -> &Mutex<HashMap<String, Arc<AgentConnection>>> {
        &self.agents
    }

    /// `{dataDir, coreVersion, logPath}`。
    pub fn describe(&self) -> Value {
        json!({
            "dataDir": self.data_dir.to_string_lossy(),
            "coreVersion": CORE_VERSION,
            "logPath": self.log_path.to_string_lossy(),
        })
    }

    /// 主动向 `acp/agent_state` 推一条 `core_ready`（R0 验收第 2 项）。`agentId` 为 null 表示核心自身。
    pub fn announce_ready(&self) {
        let payload = json!({
            "agentId": null,
            "state": "core_ready",
            "dataDir": self.data_dir.to_string_lossy(),
            "coreVersion": CORE_VERSION,
            "droppedUpdates": 0,
        });
        self.emit(EventChannel::AgentState, payload);
    }

    /// 往返命令：回 `{pong, sequence, coreVersion}`。
    pub fn ping(&self, echo: &str) -> Result<Value> {
        let sequence = self.ping_seq.fetch_add(1, Ordering::Relaxed) + 1;
        Ok(json!({
            "pong": echo,
            "sequence": sequence,
            "coreVersion": CORE_VERSION,
        }))
    }

    pub(crate) fn emit(&self, channel: EventChannel, payload: Value) {
        self.sink.emit(channel, payload.to_string());
    }

    fn agent(&self, agent_id: &str) -> Result<Arc<AgentConnection>> {
        lock(&self.agents)
            .get(agent_id)
            .cloned()
            .ok_or_else(|| CoreError::NotConnected(agent_id.to_string()))
    }

    // ---- 连接与会话（docs/design.md § 3 命令）

    /// 按 settings 拉起 agent 并完成 `initialize`；已有连接先断开。返回 `{agentId, initialize}`。
    /// `core_shutdown` 开始之后回 `cancelled`；握手途中撞上收尾也回 `cancelled`，进程树已经结束。
    pub async fn agent_connect(&self, agent_id: &str, cwd: Option<PathBuf>) -> Result<Value> {
        // 整个调用期间持读锁（见 `connect_gate`）。顺序不能反：先拿锁再看令牌，看到「未置位」时收尾就一定还没拿到写锁、
        // 会等这把读锁放掉；反过来的话，看完令牌到拿锁之间收尾可能已经走完，这条连接就没人等了。
        let _in_flight = self.connect_gate.read().await;
        self.closing.check()?;
        let server = match self.settings.get(agent_id)? {
            Some(server) => server,
            // settings 里没有就看内置条目（R7 的 sidecar；sidecar 不在时照样报 AgentNotConfigured）。
            None => crate::builtin::agents(&self.data_dir)
                .remove(agent_id)
                .ok_or_else(|| CoreError::AgentNotConfigured(agent_id.to_string()))?,
        };
        // registry 型：安装记录 + Node（R5）；custom 型：settings 里的 command / args / env。
        let launch = match &server {
            AgentServer::Registry { env, .. } => self.registry_launch(agent_id, env).await?,
            AgentServer::Custom { .. } => LaunchSpec::from_server(agent_id, &server)?,
        };
        let previous = lock(&self.agents).remove(agent_id);
        if let Some(previous) = previous {
            previous.disconnect().await;
        }
        let connection =
            AgentConnection::connect(agent_id.to_string(), launch, cwd, self.sink.clone(), self.terminals.clone(), Some(&self.closing)).await?;
        lock(&self.agents).insert(agent_id.to_string(), connection.clone());
        Ok(json!({ "agentId": agent_id, "initialize": connection.initialize }))
    }

    pub async fn agent_disconnect(&self, agent_id: &str) -> Result<Value> {
        let connection = lock(&self.agents)
            .remove(agent_id)
            .ok_or_else(|| CoreError::NotConnected(agent_id.to_string()))?;
        connection.disconnect().await;
        Ok(json!({ "agentId": agent_id, "exit": connection.shared().exit_info().map(|e| json!({"code": e.code})) }))
    }

    pub async fn session_new(&self, agent_id: &str, cwd: PathBuf) -> Result<Value> {
        if !cwd.is_absolute() {
            return Err(CoreError::InvalidArgument(format!("cwd must be absolute: {}", cwd.display())));
        }
        let result = self.agent(agent_id)?.session_new(cwd).await;
        // 认证状态是本地态（docs/design.md § 5 第 5 条）：成功 = 已登录，-32000 = 需要认证；只对 registry 型的安装记录生效。
        match &result {
            Ok(_) => self.record_auth_status(agent_id, AuthStatus::Authenticated),
            Err(CoreError::AuthRequired { .. }) => self.record_auth_status(agent_id, AuthStatus::NeedsAuth),
            Err(_) => {}
        }
        result
    }

    /// `session/list`（R6）：`cwd` 过滤（给了就必须是绝对路径）+ cursor 分页。侧栏不直接消费它——
    /// 本地索引才是侧栏的事实来源，这条只用来校对存在性与补标题（docs/design.md § 3 末条）。
    pub async fn session_list(&self, agent_id: &str, cwd: Option<PathBuf>, cursor: Option<String>) -> Result<Value> {
        if let Some(cwd) = &cwd
            && !cwd.is_absolute()
        {
            return Err(CoreError::InvalidArgument(format!("cwd must be absolute: {}", cwd.display())));
        }
        self.agent(agent_id)?.session_list(cwd, cursor).await
    }

    /// `session/load`（R6）：整段历史经 `acp/session_update` 重放完本命令才返回。
    pub async fn session_load(&self, agent_id: &str, session_id: &str, cwd: PathBuf) -> Result<Value> {
        Self::require_absolute(&cwd)?;
        self.agent(agent_id)?.session_load(session_id, cwd).await
    }

    /// `session/resume`（R6）：只恢复上下文，不重放。
    pub async fn session_resume(&self, agent_id: &str, session_id: &str, cwd: PathBuf) -> Result<Value> {
        Self::require_absolute(&cwd)?;
        self.agent(agent_id)?.session_resume(session_id, cwd).await
    }

    /// `session/close`（R6）。
    pub async fn session_close(&self, agent_id: &str, session_id: &str) -> Result<Value> {
        self.agent(agent_id)?.session_close(session_id).await
    }

    /// `session/delete`（R6）：只管 agent 侧；本地索引由前端在成功后再删（`session_index_remove`）。
    pub async fn session_delete(&self, agent_id: &str, session_id: &str) -> Result<Value> {
        self.agent(agent_id)?.session_delete(session_id).await
    }

    fn require_absolute(cwd: &Path) -> Result<()> {
        if cwd.is_absolute() {
            Ok(())
        } else {
            Err(CoreError::InvalidArgument(format!("cwd must be absolute: {}", cwd.display())))
        }
    }

    pub async fn session_prompt(&self, agent_id: &str, session_id: &str, prompt: Value) -> Result<Value> {
        self.agent(agent_id)?.session_prompt(session_id, prompt).await
    }

    pub fn session_cancel(&self, agent_id: &str, session_id: &str) -> Result<Value> {
        self.agent(agent_id)?.session_cancel(session_id)
    }

    pub async fn session_set_mode(&self, agent_id: &str, session_id: &str, mode_id: &str) -> Result<Value> {
        self.agent(agent_id)?.session_set_mode(session_id, mode_id).await
    }

    pub async fn session_set_config_option(&self, agent_id: &str, session_id: &str, config_id: &str, value: Value) -> Result<Value> {
        self.agent(agent_id)?
            .session_set_config_option(session_id, config_id, value)
            .await
    }

    pub fn acp_respond(&self, agent_id: &str, request_id: &str, response: Value) -> Result<Value> {
        self.agent(agent_id)?.respond(request_id, response)
    }

    // ---- 认证（docs/design.md § 5）

    pub async fn authenticate(&self, agent_id: &str, method_id: &str) -> Result<Value> {
        self.agent(agent_id)?.authenticate(method_id).await
    }

    /// terminal 型认证：在 pty 里重拉同一个 agent 程序（附加方法的 args / env），等它退出，然后自动重试 `session/new`。
    /// 返回 `{terminalId, exitStatus, session}`；重试仍要认证时返回 `auth_required` 错误（事件已推出）。
    pub async fn terminal_auth_run(&self, agent_id: &str, method_id: &str, cwd: PathBuf) -> Result<Value> {
        let connection = self.agent(agent_id)?;
        let method = connection
            .auth_method(method_id)
            .ok_or_else(|| CoreError::InvalidArgument(format!("agent `{agent_id}` has no auth method `{method_id}`")))?;
        let spawn = terminal_auth::terminal_auth_spawn(&connection.launch, &method)
            .ok_or_else(|| CoreError::InvalidArgument(format!("auth method `{method_id}` is not a terminal method; use authenticate")))?;
        let mut spec = pty::SpawnSpec::new(spawn.program.clone());
        spec.args = spawn.args.clone();
        spec.env = spawn.env.clone();
        spec.cwd = Some(cwd.clone());
        let terminal_id = self.terminals.spawn(spec, pty::TerminalSource::Auth)?;
        connection.shared().emit_state(
            "authenticating",
            json!({
                "methodId": method_id,
                "terminalId": terminal_id,
                "label": spawn.label,
                "program": spawn.program,
                "args": spawn.args,
            }),
        );
        let terminals = self.terminals.clone();
        let wait_id = terminal_id.clone();
        let status = tokio::task::spawn_blocking(move || terminals.wait(&wait_id))
            .await
            .map_err(|e| CoreError::Pty(format!("wait task failed: {e}")))??;
        let _ = self.terminals.release(&terminal_id);
        let session = connection.session_new(cwd).await;
        match &session {
            Ok(_) => self.record_auth_status(agent_id, AuthStatus::Authenticated),
            Err(CoreError::AuthRequired { .. }) => self.record_auth_status(agent_id, AuthStatus::NeedsAuth),
            Err(_) => {}
        }
        let session = session?;
        Ok(json!({
            "terminalId": terminal_id,
            "exitStatus": exit_status_json(&status),
            "session": session,
        }))
    }

    /// 往终端写键盘输入（terminal auth 的可见终端；R4 的本地 shell 同一条命令）。
    /// ConPTY 的 `write_all` 会阻塞（子进程不读 stdin 时），走 `spawn_blocking`（审查 finding，2026-09-16）。
    pub async fn terminal_write(&self, terminal_id: &str, bytes: &[u8]) -> Result<Value> {
        let terminals = self.terminals.clone();
        let id = terminal_id.to_string();
        let data = bytes.to_vec();
        let written = data.len();
        tokio::task::spawn_blocking(move || terminals.write(&id, &data))
            .await
            .map_err(|e| CoreError::Pty(format!("write task failed: {e}")))??;
        Ok(json!({ "terminalId": terminal_id, "written": written }))
    }

    // ---- 本地交互 shell（R4，画板 61；docs/design.md § 3「本地 shell」，所有者裁定 2026-09-15）

    /// 开一个本地 shell（系统默认：Windows 上 pwsh → powershell → cmd；其他平台 `$SHELL`），输出走 `acp/terminal_output`
    /// （source = local）。返回 `{terminalId, cwd, program}`。
    pub async fn terminal_open(&self, cwd: PathBuf, cols: u16, rows: u16) -> Result<Value> {
        if !cwd.is_absolute() {
            return Err(CoreError::InvalidArgument(format!("cwd must be absolute: {}", cwd.display())));
        }
        let terminals = self.terminals.clone();
        let cwd_for_spec = cwd.clone();
        let (program, terminal_id) = tokio::task::spawn_blocking(move || {
            let (program, kind) = pty::shell::default_shell();
            let mut spec = pty::SpawnSpec::new(program.clone());
            spec.args = pty::shell::interactive_args(kind);
            spec.cwd = Some(cwd_for_spec);
            spec.cols = cols.max(1);
            spec.rows = rows.max(1);
            terminals.spawn(spec, pty::TerminalSource::Local).map(|id| (program, id))
        })
        .await
        .map_err(|e| CoreError::Pty(format!("spawn task failed: {e}")))??;
        Ok(json!({ "terminalId": terminal_id, "cwd": cwd.to_string_lossy(), "program": program }))
    }

    /// 视口尺寸变化（xterm 报出的列 × 行）。
    pub fn terminal_resize(&self, terminal_id: &str, cols: u16, rows: u16) -> Result<Value> {
        self.terminals.resize(terminal_id, rows.max(1), cols.max(1))?;
        Ok(json!({ "terminalId": terminal_id, "cols": cols, "rows": rows }))
    }

    /// 结束进程但不释放（终端卡的停止方块 → `terminal/kill` 语义；输出与退出码仍可读）。
    /// `pty::TerminalManager::kill` 要等进程真的退出，走 `spawn_blocking`。
    pub async fn terminal_kill(&self, terminal_id: &str) -> Result<Value> {
        let terminals = self.terminals.clone();
        let id = terminal_id.to_string();
        tokio::task::spawn_blocking(move || terminals.kill(&id))
            .await
            .map_err(|e| CoreError::Pty(format!("kill task failed: {e}")))??;
        Ok(json!({ "terminalId": terminal_id }))
    }

    /// 关掉一个终端（认证页的停止方块与 R4 的本地 shell 标签同一条命令）：还在跑就先 kill，然后释放句柄。
    /// 退出事件仍经 `acp/terminal_output` 推出；`terminal_auth_run` 那边等到退出后照常重试 `session/new`。
    pub fn terminal_close(&self, terminal_id: &str) -> Result<Value> {
        self.terminals.release(terminal_id)?;
        Ok(json!({ "terminalId": terminal_id, "closed": true }))
    }

    /// 应用退出前的收尾：全部终端释放（还在跑的 kill）、全部 agent 断开（各自最多等 `DISCONNECT_GRACE` 后结束进程树）、
    /// 监视器停掉。还在握手的 `agent_connect` 中止并结束进程树，等它们落定才返回；之后的 `agent_connect` 回 `cancelled`。
    /// 返回 `{terminals, agents}` 计数（agents 只数连接表里断开的，被中止的握手不算）。
    pub async fn core_shutdown(&self) -> Result<Value> {
        self.closing.cancel();
        let terminal_ids = self.terminals.ids();
        for id in &terminal_ids {
            let _ = self.terminals.release(id);
        }
        lock(&self.watchers).clear();
        // 已连上的先开始断开，与下面等在途握手并行：两段各自的宽限期不叠加，Dart 那头只等 8 秒。
        let mut tasks = self.disconnect_all();
        // 在途的 `agent_connect` 落定：被中止的已结束进程树；赢了赛跑的已插进连接表，再清一遍。
        drop(self.connect_gate.write().await);
        tasks.extend(self.disconnect_all());
        let count = tasks.len();
        for t in tasks {
            let _ = t.await;
        }
        Ok(json!({ "terminals": terminal_ids.len(), "agents": count }))
    }

    /// 清空连接表，每条连接起一个断开任务。
    fn disconnect_all(&self) -> Vec<tokio::task::JoinHandle<()>> {
        let agents: Vec<Arc<AgentConnection>> = lock(&self.agents).drain().map(|(_, c)| c).collect();
        agents
            .into_iter()
            .map(|connection| tokio::spawn(async move { connection.disconnect().await }))
            .collect()
    }

    // ---- 设置

    pub fn agent_settings_get(&self) -> Result<Value> {
        let mut settings = self.settings.load()?;
        // 内置 sidecar（R7）并进结果但**不落盘**：它的路径跟着应用可执行文件走（crate::builtin）。
        crate::builtin::merge_into(&mut settings, &self.data_dir);
        Ok(serde_json::to_value(settings)?)
    }

    /// `server` 是 `agent_servers` 一条的 JSON（`{type: "custom", command, args, env}`）；返回落盘后的全量设置。
    pub fn agent_settings_set(&self, agent_id: &str, server: Value) -> Result<Value> {
        if agent_id.trim().is_empty() {
            return Err(CoreError::InvalidArgument("agent id is empty".into()));
        }
        // 内置 sidecar（R7）的 command / args 是按可执行文件位置**合成**的，写进 settings.json 之后
        // 用户条目优先，合成的 `--user-data-dir` / `--zed-settings` 就不再生效，换台机器或挪个位置
        // 那条绝对路径还会失效；设置页因此对它禁用「编辑」。这里再挡一道（审查 finding P2，2026-09-17）。
        // 用户自己在 settings.json 里手写过同名条目时不挡 —— 那条是他自己的，编辑照常。
        if crate::builtin::rejects_settings_write(
            agent_id,
            self.settings.get(agent_id)?.is_some(),
            crate::builtin::sidecar_path().is_some(),
        ) {
            return Err(CoreError::InvalidArgument(format!(
                "`{agent_id}` 是随包分发的内置 agent，它的拉起参数按可执行文件位置合成，不写进 settings.json"
            )));
        }
        let mut server: AgentServer =
            serde_json::from_value(server).map_err(|e| CoreError::InvalidArgument(format!("agent server entry: {e}")))?;
        // 设置页只编辑 command / args / env：来的条目没带 Zed 字段（`default_config_options` 等）时沿用旧条目的，
        // 别把从 Zed 导入的默认配置写空（审查 P2，2026-09-16）。
        if let AgentServer::Custom { extra, .. } = &mut server
            && extra.is_empty()
            && let Some(AgentServer::Registry { extra: old, .. } | AgentServer::Custom { extra: old, .. }) = self.settings.get(agent_id)?
        {
            *extra = old;
        }
        Ok(serde_json::to_value(self.settings.upsert(agent_id, server)?)?)
    }

    // ---- 工作区文件与 git（R3；docs/design.md § 3「文件面板与 git」）
    //
    // 这些都是阻塞式的文件系统 / 子进程调用，放 `spawn_blocking`：桥层的命令跑在本 runtime 的 worker 上，
    // 直接同步走会占住 worker（`git` 在大仓库上能跑几百毫秒）。

    /// 列一层目录（`fs_list_dir`）。`root` 是当前项目，`path` 必须在它之内。
    pub async fn fs_list_dir(&self, root: PathBuf, path: PathBuf) -> Result<Value> {
        blocking(move || Ok(serde_json::to_value(fs::list_dir(&root, &path)?)?)).await
    }

    /// 按名字子串搜索（`fs_search`，`@` 提及用）。
    pub async fn fs_search(&self, root: PathBuf, query: String, limit: usize) -> Result<Value> {
        blocking(move || Ok(serde_json::to_value(fs::search(&root, &query, limit)?)?)).await
    }

    /// 查看器读文件（`fs_read`，R4）：`{path, text, size, lines, binary, truncated}`。
    pub async fn fs_read(&self, root: PathBuf, path: PathBuf) -> Result<Value> {
        blocking(move || Ok(serde_json::to_value(fs::read_file(&root, &path)?)?)).await
    }

    /// 监视项目目录（`fs_watch`，R4）：每批变化以 `{root, dirs: [绝对路径…], git}` 的 JSON 交给 `deliver`；
    /// `deliver` 返回 false（接收方已取消）时停止。同一 root 再次调用替换旧监视器。返回 `{root}`。
    pub fn fs_watch(&self, root: PathBuf, deliver: impl Fn(String) -> bool + Send + 'static) -> Result<Value> {
        let root_key = root.clone();
        let root_for_payload = root.to_string_lossy().into_owned();
        let watcher = fs::watch::DirWatcher::start(&root, move |changes| {
            let payload = json!({
                "root": root_for_payload,
                "dirs": changes.dirs.iter().map(|d| d.to_string_lossy().into_owned()).collect::<Vec<_>>(),
                "git": changes.git,
            });
            deliver(payload.to_string())
        })?;
        lock(&self.watchers).insert(root_key, watcher);
        Ok(json!({ "root": root.to_string_lossy() }))
    }

    /// 停掉某个根的监视（`fs_unwatch`）。没在监视也不报错。
    pub fn fs_unwatch(&self, root: PathBuf) -> Result<Value> {
        let removed = lock(&self.watchers).remove(&root).is_some();
        Ok(json!({ "root": root.to_string_lossy(), "removed": removed }))
    }

    /// 文件树的 git 状态徽章（`git_status`，R4）：`{available, isRepo, root, entries: [{path, badge, code}]}`。
    pub async fn git_status(&self, cwd: PathBuf) -> Result<Value> {
        blocking(move || Ok(serde_json::to_value(fs::git::status(&cwd)?)?)).await
    }

    /// 本地分支列表（`git_branches`）。找不到 `git` 或目录不是仓库时不报错，`available` / `isRepo` 为 false。
    pub async fn git_branches(&self, cwd: PathBuf) -> Result<Value> {
        blocking(move || Ok(serde_json::to_value(fs::git::branches(&cwd)?)?)).await
    }

    /// `git switch <branch>`（`git_switch`）；返回切换后的分支列表。
    pub async fn git_switch(&self, cwd: PathBuf, branch: String) -> Result<Value> {
        blocking(move || Ok(serde_json::to_value(fs::git::switch(&cwd, &branch)?)?)).await
    }

    /// `git switch -c <branch>`（`git_create_branch`）；返回切换后的分支列表。
    pub async fn git_create_branch(&self, cwd: PathBuf, branch: String) -> Result<Value> {
        blocking(move || Ok(serde_json::to_value(fs::git::create_branch(&cwd, &branch)?)?)).await
    }

    /// `git diff`（`git_diff`，输入框 `+` 的 Branch Diff）。
    pub async fn git_diff(&self, cwd: PathBuf, base: Option<String>) -> Result<Value> {
        blocking(move || Ok(serde_json::to_value(fs::git::diff(&cwd, base.as_deref())?)?)).await
    }

    // ---- 项目与会话的本地索引（R3；docs/design.md § 10）

    /// 最近项目列表（`workspace_recent`）。
    pub fn workspace_recent(&self) -> Result<Value> {
        Ok(json!({ "projects": serde_json::to_value(self.index.projects())? }))
    }

    /// 打开一个本地目录作为项目（`workspace_open`）：写进最近列表并返回它与全量列表。
    pub fn workspace_open(&self, path: PathBuf) -> Result<Value> {
        let (project, projects) = self.index.open_project(&path)?;
        Ok(json!({
            "project": serde_json::to_value(project)?,
            "projects": serde_json::to_value(projects)?,
        }))
    }

    /// 会话索引全量（`session_index_list`），按 `updatedAt` 倒序。
    pub fn session_index_list(&self) -> Result<Value> {
        Ok(json!({ "sessions": serde_json::to_value(self.index.sessions())? }))
    }

    /// 新增 / 更新一条会话索引（`session_index_upsert`）；返回全量列表。
    pub fn session_index_upsert(&self, entry: Value) -> Result<Value> {
        let entry: SessionEntry =
            serde_json::from_value(entry).map_err(|e| CoreError::InvalidArgument(format!("session index entry: {e}")))?;
        if entry.agent_id.trim().is_empty() || entry.session_id.trim().is_empty() {
            return Err(CoreError::InvalidArgument("session index entry needs agentId and sessionId".into()));
        }
        Ok(json!({ "sessions": serde_json::to_value(self.index.upsert_session(entry)?)? }))
    }

    /// 窗口 UI 状态（`ui_state_get`）：两栏被拖出来的宽度与文件面板树列的宽度 / 收起态。没存过的字段返回 null，
    /// 缺省宽度与夹取范围都在前端的 token 里，核心不复制一份（docs/design.md § 10）。
    /// 外观设置（四个字体轴）。读不出来不报错，回四个 null——字体读失败不该挡住启动。
    ///
    /// 不走 [`Self::agent_settings_get`]：那个会把内置 sidecar 合进结果，外观不需要也不该沾那一层。
    pub fn appearance_get(&self) -> Result<Value> {
        Ok(serde_json::to_value(self.settings.appearance())?)
    }

    /// 整段覆盖外观设置；返回落盘后的外观。family 名的形状校验在 settings crate 里（[`settings::Appearance::sanitized`]）。
    pub fn appearance_set(&self, patch: Value) -> Result<Value> {
        let patch: settings::Appearance =
            serde_json::from_value(patch).map_err(|e| CoreError::InvalidArgument(format!("appearance: {e}")))?;
        Ok(serde_json::to_value(self.settings.set_appearance(patch)?)?)
    }

    /// 转录偏好（画板 70「转录」/ 画板 08 B 的全局开关）。与外观同口径：读不出来不报错，回空，
    /// 由前端落到默认值上（「默认开」写在 `lib/app/transcript_folds.dart`，核心不复制一份）。
    pub fn transcript_prefs_get(&self) -> Result<Value> {
        Ok(serde_json::to_value(self.settings.transcript())?)
    }

    /// 整段覆盖转录偏好；返回落盘后的值。
    pub fn transcript_prefs_set(&self, patch: Value) -> Result<Value> {
        let patch: settings::Transcript =
            serde_json::from_value(patch).map_err(|e| CoreError::InvalidArgument(format!("transcript: {e}")))?;
        Ok(serde_json::to_value(self.settings.set_transcript(patch)?)?)
    }

    pub fn ui_state_get(&self) -> Result<Value> {
        Ok(serde_json::to_value(self.ui_state.load())?)
    }

    /// 合并写窗口 UI 状态（`ui_state_set`）：只覆盖给到的字段；返回落盘后的全量状态。
    pub fn ui_state_set(&self, patch: Value) -> Result<Value> {
        let patch: UiState =
            serde_json::from_value(patch).map_err(|e| CoreError::InvalidArgument(format!("ui state: {e}")))?;
        Ok(serde_json::to_value(self.ui_state.merge(patch)?)?)
    }

    /// 移除一条会话索引（`session_index_remove`）；返回全量列表。向 agent 发 `session/delete` 是 R6 的事。
    pub fn session_index_remove(&self, agent_id: &str, session_id: &str) -> Result<Value> {
        Ok(json!({ "sessions": serde_json::to_value(self.index.remove_session(agent_id, session_id)?)? }))
    }

    /// 连接表里每个 agent 的 `droppedUpdates` 与退出状态（开发期排查）。
    pub fn agents_status(&self) -> Value {
        let agents = lock(&self.agents);
        let mut out = serde_json::Map::new();
        for (id, connection) in agents.iter() {
            let shared = connection.shared();
            out.insert(
                id.clone(),
                json!({
                    "droppedUpdates": shared.dropped_updates(),
                    "exited": shared.exit_info().map(|e| json!({"code": e.code})),
                    "pendingRequests": shared.pending_request_ids(),
                }),
            );
        }
        Value::Object(out)
    }
}

/// 把阻塞调用挪到 tokio 的阻塞线程池；线程池关闭（runtime 正在析构）时报 Transport。
async fn blocking<F>(f: F) -> Result<Value>
where
    F: FnOnce() -> Result<Value> + Send + 'static,
{
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|e| CoreError::Transport(format!("blocking task: {e}")))?
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::events::RecordingSink;

    #[test]
    fn new_core_announces_ready_and_pings() {
        let sink = Arc::new(RecordingSink::default());
        let dir = std::env::temp_dir().join(format!("acp-core-test-{}", std::process::id()));
        let core = Core::new(&dir, sink.clone()).expect("core");
        let events = sink.take();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].0, EventChannel::AgentState);
        let v: Value = serde_json::from_str(&events[0].1).expect("json");
        assert_eq!(v["state"], "core_ready");
        assert!(v["agentId"].is_null());

        let p1 = core.ping("a").expect("ping");
        let p2 = core.ping("b").expect("ping");
        assert_eq!(p1["pong"], "a");
        assert_eq!(p1["sequence"], 1);
        assert_eq!(p2["sequence"], 2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn startup_banner_records_version_and_paths() {
        // R8：画板 70 没有版本位，版本与构建信息只进日志（docs/design.md § 10）。
        let sink = Arc::new(RecordingSink::default());
        let dir = std::env::temp_dir().join(format!("acp-core-banner-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let core = Core::new(&dir, sink).expect("core");
        let log = core.log_path().to_path_buf();
        // 写盘在独立线程上：放掉 core 让 sender 析构、线程收尾，再读。
        drop(core);
        let mut text = String::new();
        for _ in 0..40 {
            if let Ok(s) = std::fs::read_to_string(&log)
                && s.contains(crate::capabilities::CLIENT_NAME)
            {
                text = s;
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        let first = text.lines().next().unwrap_or_default();
        assert!(first.contains(env!("CARGO_PKG_VERSION")), "no version in banner: {first}");
        assert!(first.contains(&dir.display().to_string()), "no data dir in banner: {first}");
        assert!(first.contains("sidecar="), "no sidecar field in banner: {first}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn relative_data_dir_is_rejected() {
        let sink = Arc::new(RecordingSink::default());
        let err = Core::new("relative/dir", sink).expect_err("must fail");
        assert_eq!(err.code(), "invalid_data_dir");
    }


    #[test]
    fn unconfigured_or_unconnected_agent_errors() {
        let sink = Arc::new(RecordingSink::default());
        let dir = std::env::temp_dir().join(format!("acp-core-agents-{}", std::process::id()));
        let core = Core::new(&dir, sink).expect("core");
        let err = core.runtime().block_on(core.agent_connect("nope", None)).expect_err("not configured");
        assert_eq!(err.code(), "agent_not_configured");
        let err = core.session_cancel("nope", "s").expect_err("not connected");
        assert_eq!(err.code(), "not_connected");
        let settings = core
            .agent_settings_set("x", json!({"type": "custom", "command": "agent.cmd", "args": ["--acp"]}))
            .expect("set");
        assert_eq!(settings["agent_servers"]["x"]["command"], "agent.cmd");
        assert!(core.agent_settings_set("", json!({"type": "custom", "command": "a"})).is_err());
        // 从 Zed 导入的 extra 字段：设置页只回写 command / args / env，旧条目的 default_config_options 要留下。
        core.agent_settings_set("z", json!({"type": "custom", "command": "z.cmd", "default_config_options": {"model": "fast"}}))
            .expect("set with extra");
        let settings = core.agent_settings_set("z", json!({"type": "custom", "command": "z2.cmd", "args": ["--acp"]})).expect("edit");
        assert_eq!(settings["agent_servers"]["z"]["command"], "z2.cmd");
        assert_eq!(settings["agent_servers"]["z"]["default_config_options"]["model"], "fast");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 录到的 `acp/agent_state` 里某个 agent 的状态序列（边读边清空 sink，所以累积到 `seen`）。
    fn states_of(sink: &RecordingSink, seen: &mut Vec<Value>, agent_id: &str) -> Vec<String> {
        seen.extend(
            sink.take()
                .into_iter()
                .filter(|(c, _)| *c == EventChannel::AgentState)
                .filter_map(|(_, p)| serde_json::from_str::<Value>(&p).ok()),
        );
        seen.iter()
            .filter(|v| v["agentId"] == agent_id)
            .filter_map(|v| v["state"].as_str().map(str::to_string))
            .collect()
    }

    #[test]
    fn shutdown_kills_an_agent_still_in_its_handshake() {
        // 关窗那一刻 agent 还在握手（BACKLOG P0「退出时 agent 的子进程没回收」）：这条连接还不在连接表里，
        // `core_shutdown` 要中止它、等进程树结束再返回，不能清完空表就放行。「agent」是个永远不回 `initialize` 的长命令，
        // 输出丢进 nul，免得非 JSON 行先把传输弄断。
        let sink = Arc::new(RecordingSink::default());
        let dir = std::env::temp_dir().join(format!("acp-core-shutdown-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let core = Arc::new(Core::new(&dir, sink.clone()).expect("core"));
        let (command, args) = if cfg!(windows) {
            ("cmd", json!(["/c", "ping -n 30 127.0.0.1 > nul"]))
        } else {
            ("sh", json!(["-c", "exec sleep 30"]))
        };
        core.agent_settings_set("mute", json!({"type": "custom", "command": command, "args": args}))
            .expect("set");
        let task = {
            let core = core.clone();
            async move { core.agent_connect("mute", None).await }
        };
        let connecting = core.runtime().spawn(task);

        // 等到进程拉起：此刻它在等 `initialize` 的回应，连接表还是空的。
        let mut seen = Vec::new();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
        while !states_of(&sink, &mut seen, "mute").iter().any(|s| s == "spawned") {
            assert!(std::time::Instant::now() < deadline, "agent never spawned: {seen:?}");
            std::thread::sleep(std::time::Duration::from_millis(20));
        }

        let started = std::time::Instant::now();
        let summary = core.runtime().block_on(core.core_shutdown()).expect("shutdown");
        let elapsed = started.elapsed();
        // 握手被中止：不等 `DISCONNECT_GRACE`，更不会等满那条 30 秒的命令。
        assert!(elapsed < std::time::Duration::from_secs(10), "shutdown took {elapsed:?}");
        assert_eq!(summary["agents"], 0, "{summary}");
        let err = core.runtime().block_on(connecting).expect("join").expect_err("handshake aborted");
        assert_eq!(err.code(), "cancelled");
        // `exited` 在唤醒等待者之后才发，给它一点时间。
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !states_of(&sink, &mut seen, "mute").iter().any(|s| s == "exited") {
            assert!(std::time::Instant::now() < deadline, "agent never exited: {seen:?}");
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        // 收尾之后的连接一律拒绝，不再拉起进程。
        let spawned_before = states_of(&sink, &mut seen, "mute").iter().filter(|s| *s == "spawned").count();
        let err = core.runtime().block_on(core.agent_connect("mute", None)).expect_err("closing");
        assert_eq!(err.code(), "cancelled");
        let spawned_after = states_of(&sink, &mut seen, "mute").iter().filter(|s| *s == "spawned").count();
        assert_eq!(spawned_after, spawned_before, "a connect after shutdown spawned a process");
        drop(core);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
