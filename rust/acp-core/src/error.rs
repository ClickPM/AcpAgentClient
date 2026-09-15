//! 核心的错误边界：所有对外函数返回 [`Result`]，桥层把 [`CoreError`] 翻成 Dart 异常。

use std::fmt;

use serde_json::Value;

#[derive(Debug, Clone, PartialEq)]
#[non_exhaustive]
pub enum CoreError {
    /// 传入的数据目录不可用（非绝对路径、建不出来）。
    InvalidDataDir(String),
    /// 文件系统错误。
    Io(String),
    /// JSON 编解码错误。
    Json(String),
    /// 该功能在后续轮次实现（值是轮次号，例如 "R4"）。
    NotImplemented(&'static str),
    /// settings.json 读写失败。
    Settings(String),
    /// settings 里没有这个 agent。
    AgentNotConfigured(String),
    /// 该 agent 没连接（或已断开）。
    NotConnected(String),
    /// 子进程拉不起来。
    Spawn(String),
    /// agent 进程已退出（退出码与 stderr 尾巴随 `acp/agent_state: exited` 一起给了前端）。
    Exited { agent_id: String, code: Option<i32>, stderr_tail: String },
    /// `session/new` / `session/prompt` 回 `-32000`：走认证流程（authMethods 已经 `acp/agent_state: auth_required` 推出）。
    AuthRequired { agent_id: String, message: String },
    /// agent 回的其他 JSON-RPC 错误，原样带出。
    Acp { code: i64, message: String, data: Option<Value> },
    /// `acp_respond` 对应的请求不在队列里（已回应、已被 agent 撤回、或 id 写错）。
    UnknownRequest(String),
    /// 入参形状不对（JSON 解不开、不是数组等）。
    InvalidArgument(String),
    /// 终端（pty）错误。
    Pty(String),
    /// 传输层错误（连接句柄丢失、发送失败）。
    Transport(String),
}

impl CoreError {
    /// 稳定的短码，桥层原样带给 Dart（`BridgeError.code`）。
    pub fn code(&self) -> &'static str {
        match self {
            CoreError::InvalidDataDir(_) => "invalid_data_dir",
            CoreError::Io(_) => "io",
            CoreError::Json(_) => "json",
            CoreError::NotImplemented(_) => "not_implemented",
            CoreError::Settings(_) => "settings",
            CoreError::AgentNotConfigured(_) => "agent_not_configured",
            CoreError::NotConnected(_) => "not_connected",
            CoreError::Spawn(_) => "spawn",
            CoreError::Exited { .. } => "exited",
            CoreError::AuthRequired { .. } => "auth_required",
            CoreError::Acp { .. } => "acp",
            CoreError::UnknownRequest(_) => "unknown_request",
            CoreError::InvalidArgument(_) => "invalid_argument",
            CoreError::Pty(_) => "pty",
            CoreError::Transport(_) => "transport",
        }
    }
}

impl fmt::Display for CoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CoreError::InvalidDataDir(p) => write!(f, "invalid data dir: {p}"),
            CoreError::Io(e) => write!(f, "io error: {e}"),
            CoreError::Json(e) => write!(f, "json error: {e}"),
            CoreError::NotImplemented(round) => write!(f, "not implemented until {round}"),
            CoreError::Settings(e) => write!(f, "{e}"),
            CoreError::AgentNotConfigured(id) => write!(f, "agent `{id}` is not in settings.json agent_servers"),
            CoreError::NotConnected(id) => write!(f, "agent `{id}` is not connected"),
            CoreError::Spawn(e) => write!(f, "failed to spawn agent: {e}"),
            CoreError::Exited { agent_id, code, stderr_tail } => {
                write!(f, "agent `{agent_id}` exited (code {code:?})")?;
                if !stderr_tail.is_empty() {
                    write!(f, ": {}", stderr_tail.trim_end())?;
                }
                Ok(())
            }
            CoreError::AuthRequired { agent_id, message } => write!(f, "agent `{agent_id}` requires authentication: {message}"),
            CoreError::Acp { code, message, .. } => write!(f, "agent error {code}: {message}"),
            CoreError::UnknownRequest(id) => write!(f, "no pending client request with id {id}"),
            CoreError::InvalidArgument(e) => write!(f, "invalid argument: {e}"),
            CoreError::Pty(e) => write!(f, "{e}"),
            CoreError::Transport(e) => write!(f, "transport error: {e}"),
        }
    }
}

impl std::error::Error for CoreError {}

impl From<std::io::Error> for CoreError {
    fn from(e: std::io::Error) -> Self {
        CoreError::Io(e.to_string())
    }
}

impl From<serde_json::Error> for CoreError {
    fn from(e: serde_json::Error) -> Self {
        CoreError::Json(e.to_string())
    }
}

impl From<settings::SettingsError> for CoreError {
    fn from(e: settings::SettingsError) -> Self {
        CoreError::Settings(e.to_string())
    }
}

impl From<pty::PtyError> for CoreError {
    fn from(e: pty::PtyError) -> Self {
        CoreError::Pty(e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, CoreError>;
