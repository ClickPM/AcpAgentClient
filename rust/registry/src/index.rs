//! 官方 registry 的索引：`registry.json` 拉取（1 小时节流）、磁盘缓存、图标按需拉取、按平台过滤 binary target。
//! Derived from zed-industries/zed crates/project/src/agent_registry_store.rs @ d9e1c024f393832765a03f4de204d6c8cd9abcb2 (GPL-3.0-or-later)
//! （复制后去 gpui：`Entity` / `Task` 换 tokio，`fs::Fs` 换 `tokio::fs`，`http_client` 换 reqwest；结构体对照官方
//! `agent.schema.json`——比 Zed 多认 `uvx`（只用来显示「暂不支持」）与 `license` / `authors`。）

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::{RegistryDirs, RegistryError, Result};

pub const REGISTRY_URL: &str = "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json";
/// 1 小时节流（docs/design.md § 6 第 1 条）。
pub const REFRESH_THROTTLE: Duration = Duration::from_secs(60 * 60);
const REGISTRY_FETCH_TIMEOUT: Duration = Duration::from_secs(30);
const ICON_FETCH_TIMEOUT: Duration = Duration::from_secs(10);
/// 图标并发拉取的上限（41 个条目一次全开会被 GitHub raw 限流）。
const ICON_CONCURRENCY: usize = 6;

/// `registry.json` 顶层（`registry.schema.json`）。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct RegistryIndex {
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub agents: Vec<RegistryEntry>,
}

/// 一个 agent（`agent.schema.json`）。未知字段忽略。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RegistryEntry {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub description: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub website: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub license: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub authors: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(default)]
    pub distribution: Distribution,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct Distribution {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub binary: Option<BTreeMap<String, BinaryTarget>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub npx: Option<PackageDistribution>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uvx: Option<PackageDistribution>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BinaryTarget {
    pub archive: String,
    pub cmd: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PackageDistribution {
    pub package: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
}

/// 本平台能怎么装（照 Zed：binary 与 npx 都有时，本平台有 binary target 就用 binary，否则 npx）。
#[derive(Debug, Clone, PartialEq)]
pub enum Resolved {
    Npx(PackageDistribution),
    Binary(BinaryTarget),
    /// 只有 uvx（BACKLOG 既定不做）。
    Uvx,
    /// 只有 binary 但没有本平台的 target。
    Unsupported,
}

impl Resolved {
    pub fn kind(&self) -> &'static str {
        match self {
            Resolved::Npx(_) => "npx",
            Resolved::Binary(_) => "binary",
            Resolved::Uvx => "uvx",
            Resolved::Unsupported => "none",
        }
    }
}

/// 当前平台在 registry 里的键（`darwin-aarch64` 等六个）。
pub fn current_platform_key() -> Option<&'static str> {
    Some(match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => "darwin-aarch64",
        ("macos", "x86_64") => "darwin-x86_64",
        ("linux", "aarch64") => "linux-aarch64",
        ("linux", "x86_64") => "linux-x86_64",
        ("windows", "aarch64") => "windows-aarch64",
        ("windows", "x86_64") => "windows-x86_64",
        _ => return None,
    })
}

impl RegistryEntry {
    pub fn resolve(&self, platform: Option<&str>) -> Resolved {
        let binary = self
            .distribution
            .binary
            .as_ref()
            .filter(|targets| !targets.is_empty())
            .map(|targets| platform.and_then(|p| targets.get(p)).cloned());
        match (binary, self.distribution.npx.as_ref()) {
            (Some(Some(target)), _) => Resolved::Binary(target),
            (_, Some(npx)) => Resolved::Npx(npx.clone()),
            (Some(None), None) => Resolved::Unsupported,
            (None, None) if self.distribution.uvx.is_some() => Resolved::Uvx,
            (None, None) => Resolved::Unsupported,
        }
    }

    /// 图标 URL：条目给了绝对地址就用它，相对路径按官方仓库的 raw 地址拼。
    pub fn icon_url(&self) -> Option<String> {
        let icon = self.icon.as_ref()?;
        if icon.starts_with("https://") || icon.starts_with("http://") {
            return Some(icon.clone());
        }
        let relative = icon.trim_start_matches("./");
        Some(format!("https://raw.githubusercontent.com/agentclientprotocol/registry/main/{}/{relative}", self.id))
    }
}

#[derive(Debug, Default)]
struct IndexState {
    index: Option<RegistryIndex>,
    /// 缓存文件的修改时间（Unix 毫秒），前端显示「上次刷新」。
    cached_at: Option<i64>,
    last_refresh: Option<Instant>,
    fetching: bool,
    fetch_error: Option<String>,
}

/// 索引持有者：进程内一份，缓存在 `registry-cache/registry.json`。
pub struct IndexStore {
    dirs: RegistryDirs,
    http: reqwest::Client,
    state: Mutex<IndexState>,
}

impl std::fmt::Debug for IndexStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("IndexStore").field("dirs", &self.dirs).finish_non_exhaustive()
    }
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    match m.lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    }
}

/// 快照（给 `registry_list` 用）。
#[derive(Debug, Clone, Default)]
pub struct IndexSnapshot {
    pub agents: Vec<RegistryEntry>,
    pub cached_at: Option<i64>,
    pub fetching: bool,
    pub fetch_error: Option<String>,
}

impl IndexStore {
    /// 建好就读一次磁盘缓存（不联网；联网是 [`refresh`](Self::refresh) 的事）。
    pub fn new(dirs: RegistryDirs, http: reqwest::Client) -> Self {
        let store = Self { dirs, http, state: Mutex::new(IndexState::default()) };
        store.load_cached();
        store
    }

    pub fn cache_path(&self) -> PathBuf {
        self.dirs.cache_dir().join("registry.json")
    }

    pub fn icon_path(&self, agent_id: &str) -> PathBuf {
        self.dirs.icons_dir().join(format!("{}.svg", crate::sanitize_path_component(agent_id)))
    }

    /// 缓存的 `icon.svg` 内容（没有 / 读不动 → None）。
    pub fn icon_svg(&self, agent_id: &str) -> Option<String> {
        std::fs::read_to_string(self.icon_path(agent_id)).ok().filter(|s| !s.trim().is_empty())
    }

    fn load_cached(&self) {
        let path = self.cache_path();
        let Ok(bytes) = std::fs::read(&path) else { return };
        let Ok(index) = serde_json::from_slice::<RegistryIndex>(&bytes) else { return };
        let cached_at = std::fs::metadata(&path)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_millis() as i64);
        let mut state = lock(&self.state);
        state.index = Some(index);
        state.cached_at = cached_at;
    }

    pub fn snapshot(&self) -> IndexSnapshot {
        let state = lock(&self.state);
        IndexSnapshot {
            agents: state.index.as_ref().map(|i| i.agents.clone()).unwrap_or_default(),
            cached_at: state.cached_at,
            fetching: state.fetching,
            fetch_error: state.fetch_error.clone(),
        }
    }

    pub fn entry(&self, agent_id: &str) -> Option<RegistryEntry> {
        lock(&self.state).index.as_ref()?.agents.iter().find(|a| a.id == agent_id).cloned()
    }

    /// 上次成功刷新距今不足 [`REFRESH_THROTTLE`] 时不联网（`force` 跳过节流）。返回是否真的拉了。
    /// 拉取失败不清缓存：断网时列表仍可显示（验收 6），错误留在 `fetch_error`。
    pub async fn refresh(&self, force: bool) -> Result<bool> {
        {
            let mut state = lock(&self.state);
            let stale = state.last_refresh.map(|t| t.elapsed() >= REFRESH_THROTTLE).unwrap_or(true);
            if (!force && !stale) || state.fetching {
                return Ok(false);
            }
            state.fetching = true;
            state.fetch_error = None;
        }
        let result = self.fetch_and_cache().await;
        let mut state = lock(&self.state);
        state.fetching = false;
        match result {
            Ok((index, cached_at)) => {
                state.index = Some(index);
                state.cached_at = Some(cached_at);
                state.last_refresh = Some(Instant::now());
                Ok(true)
            }
            Err(e) => {
                state.fetch_error = Some(e.to_string());
                Err(e)
            }
        }
    }

    async fn fetch_and_cache(&self) -> Result<(RegistryIndex, i64)> {
        let response = self
            .http
            .get(REGISTRY_URL)
            .timeout(REGISTRY_FETCH_TIMEOUT)
            .send()
            .await
            .map_err(|e| RegistryError::Http(format!("拉取 registry.json：{e}")))?;
        let status = response.status();
        let body = response.bytes().await.map_err(|e| RegistryError::Http(format!("读 registry.json：{e}")))?;
        if !status.is_success() {
            return Err(RegistryError::Http(format!("registry.json 返回 {}", status.as_u16())));
        }
        let index: RegistryIndex = serde_json::from_slice(&body).map_err(|e| RegistryError::Json(format!("解析 registry.json：{e}")))?;
        std::fs::create_dir_all(self.dirs.icons_dir())?;
        settings::write_atomic(&self.cache_path(), &body)?;
        self.fetch_icons(&index).await;
        Ok((index, crate::now_ms()))
    }

    /// 图标按需：没缓存过的才拉，失败只记日志级别的忽略（图标缺失退回单色占位）。有界并发。
    async fn fetch_icons(&self, index: &RegistryIndex) {
        let mut pending: Vec<(String, String, PathBuf)> = index
            .agents
            .iter()
            .filter_map(|a| a.icon_url().map(|url| (a.id.clone(), url, self.icon_path(&a.id))))
            .filter(|(_, _, path)| !path.is_file())
            .collect();
        while !pending.is_empty() {
            let batch: Vec<_> = pending.drain(..pending.len().min(ICON_CONCURRENCY)).collect();
            let mut tasks = Vec::new();
            for (id, url, path) in batch {
                let http = self.http.clone();
                tasks.push(tokio::spawn(async move {
                    let _ = download_icon(&http, &url, &path).await.map_err(|e| eprintln!("[registry] icon {id}: {e}"));
                }));
            }
            for task in tasks {
                let _ = task.await;
            }
        }
    }
}

async fn download_icon(http: &reqwest::Client, url: &str, path: &Path) -> Result<()> {
    let response = http.get(url).timeout(ICON_FETCH_TIMEOUT).send().await?;
    if !response.status().is_success() {
        return Err(RegistryError::Http(format!("{url} 返回 {}", response.status().as_u16())));
    }
    let body = response.bytes().await?;
    // 只认 SVG（registry 要求 icon.svg）；别的内容类型不落盘，免得前端解析炸。
    let head = String::from_utf8_lossy(&body[..body.len().min(512)]);
    if !head.contains("<svg") {
        return Err(RegistryError::Unsupported(format!("{url} 不是 SVG")));
    }
    settings::write_atomic(path, &body)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(json: serde_json::Value) -> RegistryEntry {
        serde_json::from_value(json).expect("entry")
    }

    #[test]
    fn parses_pinned_registry_shapes() {
        // 形状照钉版本 registry 仓库的 cursor / codex-acp / kilo 三条。
        let cursor = entry(serde_json::json!({
            "id": "cursor", "name": "Cursor", "version": "2026.09.02", "description": "Cursor's coding agent",
            "website": "https://cursor.com/docs/cli/acp", "license": "proprietary",
            "distribution": {"binary": {
                "windows-x86_64": {"archive": "https://downloads.cursor.com/x/agent-cli-package.zip", "cmd": "./dist-package\\cursor-agent.cmd", "args": ["acp"]},
                "darwin-aarch64": {"archive": "https://downloads.cursor.com/x/agent-cli-package.tar.gz", "cmd": "./dist-package/cursor-agent", "args": ["acp"]}
            }}
        }));
        assert!(matches!(cursor.resolve(Some("windows-x86_64")), Resolved::Binary(t) if t.cmd == "./dist-package\\cursor-agent.cmd"));
        assert_eq!(cursor.resolve(Some("linux-x86_64")), Resolved::Unsupported);
        assert_eq!(cursor.icon_url(), None);

        let codex = entry(serde_json::json!({
            "id": "codex-acp", "name": "Codex", "version": "1.11.0", "description": "ACP adapter",
            "repository": "https://github.com/agentclientprotocol/codex-acp",
            "distribution": {"npx": {"package": "@agentclientprotocol/codex-acp@1.11.0"}},
            "preview": {"version": "1.11.0", "distribution": {"npx": {"package": "x"}}}
        }));
        assert!(matches!(codex.resolve(Some("windows-x86_64")), Resolved::Npx(p) if p.package == "@agentclientprotocol/codex-acp@1.11.0"));

        // binary + npx 同时有：本平台有 target 用 binary，没有回落 npx。
        let kilo = entry(serde_json::json!({
            "id": "kilo", "name": "Kilo", "version": "7.6.2", "description": "d", "icon": "./icon.svg",
            "distribution": {
                "binary": {"windows-x86_64": {"archive": "https://github.com/Kilo-Org/kilocode/releases/download/v7.6.2/kilo-windows-x64.zip", "cmd": "./kilo.exe", "args": ["acp"], "sha256": "bfc2daae05ef7e44584928aab87b53d5cedd9e19d32af4a01903e08d36900dcf"}},
                "npx": {"package": "@kilocode/cli@7.6.2", "args": ["acp"]}
            }
        }));
        assert!(matches!(kilo.resolve(Some("windows-x86_64")), Resolved::Binary(_)));
        assert!(matches!(kilo.resolve(Some("windows-aarch64")), Resolved::Npx(_)));
        assert_eq!(kilo.icon_url().as_deref(), Some("https://raw.githubusercontent.com/agentclientprotocol/registry/main/kilo/icon.svg"));

        let uvx = entry(serde_json::json!({"id": "fast-agent", "name": "fast", "version": "0.1.0", "description": "d", "distribution": {"uvx": {"package": "fast-agent"}}}));
        assert_eq!(uvx.resolve(Some("windows-x86_64")), Resolved::Uvx);
    }

    #[test]
    fn cached_index_loads_without_network() {
        let dir = std::env::temp_dir().join(format!("acp-registry-index-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let dirs = RegistryDirs::new(&dir);
        std::fs::create_dir_all(dirs.cache_dir()).expect("mkdir");
        std::fs::write(
            dirs.cache_dir().join("registry.json"),
            r#"{"version":"1.0.0","agents":[{"id":"a","name":"A","version":"1.0.0","description":"d","distribution":{"npx":{"package":"a@1.0.0"}}}]}"#,
        )
        .expect("write");
        let store = IndexStore::new(dirs, reqwest::Client::new());
        let snap = store.snapshot();
        assert_eq!(snap.agents.len(), 1);
        assert!(snap.cached_at.is_some());
        assert!(store.entry("a").is_some());
        assert!(store.entry("b").is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
