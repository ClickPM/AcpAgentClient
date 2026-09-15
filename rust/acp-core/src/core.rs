//! `Core`：进程内唯一的核心实例。持有 tokio runtime、数据目录、事件出口、settings、终端表与 agent 连接表。
//! 对外的 async 方法都要在 [`Core::runtime`] 上跑（桥层 `runtime().spawn(...)`，acp-smoke `block_on`）。

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};
use settings::{AgentServer, SettingsStore};

use crate::agent::AgentConnection;
use crate::command::LaunchSpec;
use crate::error::{CoreError, Result};
use crate::events::{EventChannel, EventSink};
use crate::terminal_auth;

pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");

pub struct Core {
    data_dir: PathBuf,
    sink: Arc<dyn EventSink>,
    runtime: tokio::runtime::Runtime,
    ping_seq: AtomicU64,
    settings: SettingsStore,
    terminals: Arc<pty::TerminalManager>,
    agents: Mutex<HashMap<String, Arc<AgentConnection>>>,
}

impl std::fmt::Debug for Core {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Core")
            .field("data_dir", &self.data_dir)
            .finish_non_exhaustive()
    }
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    match m.lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    }
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
            "bytes": base64_encode(bytes),
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

/// 标准 base64（带 `=` 填充）。只有这一处用到，不为它引库。
pub fn base64_encode(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = chunk.get(1).copied().unwrap_or(0) as u32;
        let b2 = chunk.get(2).copied().unwrap_or(0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(TABLE[((n >> 18) & 63) as usize] as char);
        out.push(TABLE[((n >> 12) & 63) as usize] as char);
        out.push(if chunk.len() > 1 { TABLE[((n >> 6) & 63) as usize] as char } else { '=' });
        out.push(if chunk.len() > 2 { TABLE[(n & 63) as usize] as char } else { '=' });
    }
    out
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
        // SDK 的 dispatch 链在 debug 构建里每条入站消息要约 0.5 MiB 栈（Zed 实测），worker 栈给足。
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .thread_name("acp-core")
            .thread_stack_size(8 * 1024 * 1024)
            .enable_all()
            .build()?;
        let terminals = Arc::new(pty::TerminalManager::new(Arc::new(TerminalEvents { sink: sink.clone() })));
        let core = Self {
            data_dir: data_dir.to_path_buf(),
            settings: SettingsStore::new(data_dir.to_path_buf()),
            sink,
            runtime,
            ping_seq: AtomicU64::new(0),
            terminals,
            agents: Mutex::new(HashMap::new()),
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

    /// `{dataDir, coreVersion}`。
    pub fn describe(&self) -> Value {
        json!({
            "dataDir": self.data_dir.to_string_lossy(),
            "coreVersion": CORE_VERSION,
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
    pub async fn agent_connect(&self, agent_id: &str, cwd: Option<PathBuf>) -> Result<Value> {
        let server = self
            .settings
            .get(agent_id)?
            .ok_or_else(|| CoreError::AgentNotConfigured(agent_id.to_string()))?;
        let launch = LaunchSpec::from_server(agent_id, &server)?;
        let previous = lock(&self.agents).remove(agent_id);
        if let Some(previous) = previous {
            previous.disconnect().await;
        }
        let connection = AgentConnection::connect(agent_id.to_string(), launch, cwd, self.sink.clone()).await?;
        lock(&self.agents).insert(agent_id.to_string(), connection.clone());
        Ok(json!({ "agentId": agent_id, "initialize": connection.initialize }))
    }

    /// 测试 / 嵌入用：接管一条已连好的连接。
    pub fn adopt_connection(&self, connection: Arc<AgentConnection>) {
        lock(&self.agents).insert(connection.agent_id().to_string(), connection);
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
        self.agent(agent_id)?.session_new(cwd).await
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
        let session = connection.session_new(cwd).await?;
        Ok(json!({
            "terminalId": terminal_id,
            "exitStatus": exit_status_json(&status),
            "session": session,
        }))
    }

    /// 往终端写键盘输入（terminal auth 的可见终端；R4 的本地 shell 同一条命令）。
    pub fn terminal_write(&self, terminal_id: &str, bytes: &[u8]) -> Result<Value> {
        self.terminals.write(terminal_id, bytes)?;
        Ok(json!({ "terminalId": terminal_id, "written": bytes.len() }))
    }

    // ---- 设置

    pub fn agent_settings_get(&self) -> Result<Value> {
        Ok(serde_json::to_value(self.settings.load()?)?)
    }

    /// `server` 是 `agent_servers` 一条的 JSON（`{type: "custom", command, args, env}`）；返回落盘后的全量设置。
    pub fn agent_settings_set(&self, agent_id: &str, server: Value) -> Result<Value> {
        if agent_id.trim().is_empty() {
            return Err(CoreError::InvalidArgument("agent id is empty".into()));
        }
        let server: AgentServer =
            serde_json::from_value(server).map_err(|e| CoreError::InvalidArgument(format!("agent server entry: {e}")))?;
        Ok(serde_json::to_value(self.settings.upsert(agent_id, server)?)?)
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
    fn relative_data_dir_is_rejected() {
        let sink = Arc::new(RecordingSink::default());
        let err = Core::new("relative/dir", sink).expect_err("must fail");
        assert_eq!(err.code(), "invalid_data_dir");
    }

    #[test]
    fn base64_matches_reference_vectors() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
        assert_eq!(base64_encode(b"foobar"), "Zm9vYmFy");
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
        let _ = std::fs::remove_dir_all(&dir);
    }
}
