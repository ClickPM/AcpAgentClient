//! registry.json 拉取 / 缓存 / 图标、npx 与 binary 安装、受管 Node（docs/design.md § 6，R5）。
//!
//! - [`index`]：官方 registry 的索引（1 小时节流、磁盘缓存、图标按需、按平台过滤 binary target）；
//! - [`install`]：npx（`npm install` 到 `agents/<id>/`）与 binary（下载 → sha256 → 解压到 `agents/<id>/<version>/`）；
//! - [`node`]：系统 Node ≥ 22 的检测与受管 Node v24.11.0 的下载；
//! - [`archive`]：系统 `tar` 解压（Windows 10 1803+ 自带 bsdtar，zip 与 tar.gz 都认）；
//! - [`manifest`]：`agents/<id>/install.json`（安装记录 + 认证状态）；
//! - [`download`]：带进度与 sha256 的流式下载；[`Progress`] / [`ProgressSink`] / [`CancelToken`] 是安装流程的三个接口。
//!
//! 本 crate 不知道 settings.json 的 `agent_servers` 条目怎么写、也不做 `initialize` 握手——那两步在 acp-core 里编排。
//! 所有子进程（npm / node / tar）都不弹控制台窗口（Windows `CREATE_NO_WINDOW`），路径含空格与中文按 std 的引号规则走（规则 9）。

use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

pub mod archive;
pub mod download;
pub mod index;
pub mod install;
pub mod manifest;
pub mod node;

/// acp-core 只经这个别名持有 HTTP 客户端，不直接依赖 reqwest。
pub use reqwest::Client as HttpClient;

#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum RegistryError {
    /// 网络（含超时、非 2xx）。
    Http(String),
    Io(String),
    Json(String),
    /// registry 条目没有本平台可用的分发方式、uvx、不认识的压缩包后缀、`cmd` 不合规。
    Unsupported(String),
    /// sha256 不匹配。
    Verify { expected: String, actual: String },
    /// `npm install` 失败（值是 npm 的输出尾巴）。
    Npm(String),
    /// 找不到可用的 Node（系统 Node < 22 且没有受管 Node）。
    Node(String),
    /// 解压失败（值是 tar 的 stderr）。
    Archive(String),
    Cancelled,
    /// settings.json / install.json 读写。
    Settings(String),
}

impl fmt::Display for RegistryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RegistryError::Http(e) => write!(f, "网络错误：{e}"),
            RegistryError::Io(e) => write!(f, "io: {e}"),
            RegistryError::Json(e) => write!(f, "json: {e}"),
            RegistryError::Unsupported(e) => write!(f, "{e}"),
            RegistryError::Verify { expected, actual } => write!(f, "sha256 不匹配：期望 {expected}，实际 {actual}"),
            RegistryError::Npm(e) => write!(f, "{e}"),
            RegistryError::Node(e) => write!(f, "{e}"),
            RegistryError::Archive(e) => write!(f, "解压失败：{e}"),
            RegistryError::Cancelled => write!(f, "已取消"),
            RegistryError::Settings(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for RegistryError {}

impl From<std::io::Error> for RegistryError {
    fn from(e: std::io::Error) -> Self {
        RegistryError::Io(e.to_string())
    }
}

impl From<serde_json::Error> for RegistryError {
    fn from(e: serde_json::Error) -> Self {
        RegistryError::Json(e.to_string())
    }
}

impl From<reqwest::Error> for RegistryError {
    fn from(e: reqwest::Error) -> Self {
        RegistryError::Http(e.to_string())
    }
}

impl From<settings::SettingsError> for RegistryError {
    fn from(e: settings::SettingsError) -> Self {
        RegistryError::Settings(e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, RegistryError>;

/// `registry/progress` 的一条（docs/design.md § 3）：`agent_id` 为 `None` 是受管 Node。
#[derive(Debug, Clone, PartialEq)]
pub struct Progress {
    pub agent_id: Option<String>,
    /// npx / binary / node。
    pub kind: &'static str,
    /// resolve / write_settings / handshake / download / verify / extract / node_download / node_extract / done / failed / cancelled。
    pub step: &'static str,
    pub done: Option<u64>,
    pub total: Option<u64>,
    pub detail: Option<String>,
    pub error: Option<String>,
}

impl Progress {
    pub fn new(agent_id: Option<&str>, kind: &'static str, step: &'static str) -> Self {
        Self {
            agent_id: agent_id.map(str::to_string),
            kind,
            step,
            done: None,
            total: None,
            detail: None,
            error: None,
        }
    }

    pub fn detail(mut self, detail: impl Into<String>) -> Self {
        self.detail = Some(detail.into());
        self
    }

    pub fn bytes(mut self, done: u64, total: Option<u64>) -> Self {
        self.done = Some(done);
        self.total = total;
        self
    }

    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "agentId": self.agent_id,
            "kind": self.kind,
            "step": self.step,
            "done": self.done,
            "total": self.total,
            "detail": self.detail,
            "error": self.error,
        })
    }
}

/// 进度出口（acp-core 实现为 `registry/progress` 事件）。实现必须非阻塞。
pub trait ProgressSink: Send + Sync {
    fn progress(&self, progress: Progress);
}

/// 收集进度的测试用 sink。
#[derive(Debug, Default)]
pub struct RecordingProgress {
    items: std::sync::Mutex<Vec<Progress>>,
}

impl RecordingProgress {
    pub fn take(&self) -> Vec<Progress> {
        match self.items.lock() {
            Ok(mut g) => std::mem::take(&mut *g),
            Err(p) => std::mem::take(&mut *p.into_inner()),
        }
    }
}

impl ProgressSink for RecordingProgress {
    fn progress(&self, progress: Progress) {
        match self.items.lock() {
            Ok(mut g) => g.push(progress),
            Err(p) => p.into_inner().push(progress),
        }
    }
}

/// 协作式取消：下载在块与块之间、npm 在等待时检查它；取消后由各步自己清理临时目录。
#[derive(Debug, Default)]
pub struct CancelToken {
    cancelled: AtomicBool,
    notify: tokio::sync::Notify,
}

impl CancelToken {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        self.notify.notify_waiters();
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    /// 没取消 → `Ok(())`；取消了 → `Err(Cancelled)`。
    pub fn check(&self) -> Result<()> {
        if self.is_cancelled() { Err(RegistryError::Cancelled) } else { Ok(()) }
    }

    /// 等到取消（已取消则立即返回）。
    pub async fn cancelled(&self) {
        if self.is_cancelled() {
            return;
        }
        self.notify.notified().await;
    }
}

/// 数据目录下本 crate 管的几个位置（docs/design.md § 10）。
#[derive(Debug, Clone)]
pub struct RegistryDirs {
    pub data_dir: PathBuf,
}

impl RegistryDirs {
    pub fn new(data_dir: impl Into<PathBuf>) -> Self {
        Self { data_dir: data_dir.into() }
    }

    pub fn cache_dir(&self) -> PathBuf {
        self.data_dir.join("registry-cache")
    }

    pub fn icons_dir(&self) -> PathBuf {
        self.cache_dir().join("icons")
    }

    pub fn agents_dir(&self) -> PathBuf {
        self.data_dir.join("agents")
    }

    /// `agents/<id>/`；id 只允许 registry schema 的字符集（`^[a-z][a-z0-9-]*$`），其他字符换成 `-`，免得 id 里带路径分隔符。
    pub fn agent_dir(&self, agent_id: &str) -> PathBuf {
        self.agents_dir().join(sanitize_path_component(agent_id))
    }

    pub fn node_dir(&self) -> PathBuf {
        self.data_dir.join("node")
    }
}

/// 只留 `[A-Za-z0-9._-]`，其余换成 `-`；空串给 `unknown`（照 Zed `sanitize_path_component`）。
pub fn sanitize_path_component(input: &str) -> String {
    let sanitized: String = input
        .chars()
        .map(|c| match c {
            'a'..='z' | 'A'..='Z' | '0'..='9' | '.' | '_' | '-' => c,
            _ => '-',
        })
        .collect();
    if sanitized.is_empty() || sanitized == "." || sanitized == ".." {
        "unknown".to_string()
    } else {
        sanitized
    }
}

/// Windows `CREATE_NO_WINDOW`（processthreadsapi.h）：npm / node / tar 都在 GUI 宿主里跑，不能闪控制台。
#[cfg(windows)]
pub const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// 建一条不弹窗、三路管道的子进程命令。
pub fn command(program: impl AsRef<std::ffi::OsStr>) -> tokio::process::Command {
    let mut cmd = tokio::process::Command::new(program);
    cmd.stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);
    cmd
}

/// 裸程序名 → PATH 里带扩展名的路径（Windows 按 PATHEXT；`npm` / `node` / `tar` 都靠它）。找不到原样返回。
pub fn resolve_program(program: &str) -> PathBuf {
    let path = Path::new(program);
    if path.is_absolute() || path.components().count() > 1 {
        return path.to_path_buf();
    }
    let Some(path_var) = std::env::var_os("PATH") else {
        return path.to_path_buf();
    };
    let candidates: Vec<String> = if !cfg!(windows) || path.extension().is_some() {
        vec![program.to_string()]
    } else {
        std::env::var("PATHEXT")
            .ok()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| ".COM;.EXE;.BAT;.CMD".to_string())
            .split(';')
            .map(str::trim)
            .filter(|e| e.starts_with('.'))
            .map(|e| format!("{program}{}", e.to_ascii_lowercase()))
            .collect()
    };
    for dir in std::env::split_paths(&path_var) {
        if dir.as_os_str().is_empty() {
            continue;
        }
        for name in &candidates {
            let candidate = dir.join(name);
            if candidate.is_file() {
                return candidate;
            }
        }
    }
    path.to_path_buf()
}

/// 输出尾巴（错误信息只带最后这么多字节，免得 npm 的整份日志进事件）。
pub fn tail(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.trim().to_string();
    }
    let mut start = text.len() - limit;
    while !text.is_char_boundary(start) {
        start += 1;
    }
    text[start..].trim().to_string()
}

/// 当前时间（Unix 毫秒）。
pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_keeps_registry_ids_and_rejects_separators() {
        assert_eq!(sanitize_path_component("codex-acp"), "codex-acp");
        assert_eq!(sanitize_path_component("../x/y"), "..-x-y");
        assert_eq!(sanitize_path_component(""), "unknown");
        assert_eq!(sanitize_path_component(".."), "unknown");
    }

    #[test]
    fn tail_respects_char_boundaries() {
        let s = "abc中文def";
        assert_eq!(tail(s, 4), "def");
        assert_eq!(tail(s, 100), s);
    }

    #[test]
    fn cancel_token_flags_and_checks() {
        let token = CancelToken::new();
        assert!(token.check().is_ok());
        token.cancel();
        assert!(matches!(token.check(), Err(RegistryError::Cancelled)));
    }
}
