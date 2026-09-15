//! 终端（docs/design.md § 7）：`terminal/*` 回调的实现方（portable-pty）、terminal auth 的可见终端、
//! 终端面板的本地 shell。R1 只够跑 terminal auth；R4 转写 Zed `acp_thread/terminal.rs` 的语义
//! （输出字节上限、截断落字符边界、kill 不释放、release 后输出留存跟卡走）。R0 只定结构与 `Result` 边界。

use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum PtyError {
    NotImplemented(&'static str),
}

impl fmt::Display for PtyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PtyError::NotImplemented(round) => write!(f, "pty: not implemented until {round}"),
        }
    }
}

impl std::error::Error for PtyError {}

pub type Result<T> = std::result::Result<T, PtyError>;

/// 终端输出的来源（`acp/terminal_output.source`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalSource {
    /// `terminal/*` 回调建的终端。
    Agent,
    /// terminal auth 的可见终端。
    Auth,
    /// 终端面板的本地 shell（R4）。
    Local,
}

impl TerminalSource {
    pub fn as_str(self) -> &'static str {
        match self {
            TerminalSource::Agent => "agent",
            TerminalSource::Auth => "auth",
            TerminalSource::Local => "local",
        }
    }
}

/// 拉起一个终端进程的参数（`terminal/create` 的形状）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpawnSpec {
    pub command: String,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
    pub cwd: Option<std::path::PathBuf>,
    pub output_byte_limit: Option<u64>,
}

/// 终端表。R1 起填实。
#[derive(Debug, Default)]
pub struct TerminalManager {}

impl TerminalManager {
    pub fn spawn(&self, _spec: SpawnSpec, _source: TerminalSource) -> Result<String> {
        Err(PtyError::NotImplemented("R1"))
    }
}
