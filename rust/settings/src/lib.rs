//! Zed 兼容的 `agent_servers` 设置（docs/design.md § 6 第 5 条、§ 10）：
//! `%APPDATA%/AcpAgentClient/settings.json`，`type: registry | custom`，从 Zed `settings.json` 导入（R5）。
//! R1 最小实现：读 / 写 / 按 agent 覆盖；只 `custom` 型会被拉起，`registry` 型 R5 填实。
//! R3 另加本地索引（`sessions.json` / `projects.json`，见 [`index`]）。
//! 写文件一律「临时文件 + rename」（CLAUDE.md 规则 7）；文件不存在视为空设置，不自动创建。

use std::collections::BTreeMap;
use std::fmt;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub mod index;
pub mod ui_state;

#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum SettingsError {
    Io(String),
    Json(String),
    NotImplemented(&'static str),
}

impl fmt::Display for SettingsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SettingsError::Io(e) => write!(f, "settings: io: {e}"),
            SettingsError::Json(e) => write!(f, "settings: json: {e}"),
            SettingsError::NotImplemented(round) => write!(f, "settings: not implemented until {round}"),
        }
    }
}

impl std::error::Error for SettingsError {}

pub type Result<T> = std::result::Result<T, SettingsError>;

/// `agent_servers` 的一条，与钉版本 Zed `crates/settings_content/src/agent.rs` 的 `CustomAgentServerSettings` 同形：
/// `custom` 是扁平的 `command`（程序路径字符串）+ `args` + `env`；Zed 另有 `default_mode` / `default_config_options` 等字段，
/// R5 按需补，未知字段 serde 默认忽略。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AgentServer {
    Registry {
        #[serde(default)]
        env: BTreeMap<String, String>,
    },
    Custom {
        #[serde(rename = "command")]
        path: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        args: Vec<String>,
        #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
        env: BTreeMap<String, String>,
    },
}

/// `settings.json` 的顶层。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct Settings {
    #[serde(default)]
    pub agent_servers: BTreeMap<String, AgentServer>,
}

/// 数据目录里的 settings 文件。
#[derive(Debug, Clone)]
pub struct SettingsStore {
    pub path: PathBuf,
}

impl SettingsStore {
    pub fn new(data_dir: PathBuf) -> Self {
        Self { path: data_dir.join("settings.json") }
    }

    /// 文件不存在 → 空设置；存在但不是合法 JSON → `Json` 错误（不覆盖、不修复）。
    pub fn load(&self) -> Result<Settings> {
        match std::fs::read_to_string(&self.path) {
            Ok(text) => serde_json::from_str(&text).map_err(|e| SettingsError::Json(format!("{}: {e}", self.path.display()))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Settings::default()),
            Err(e) => Err(SettingsError::Io(format!("{}: {e}", self.path.display()))),
        }
    }

    /// 临时文件 + rename（规则 7）：先写同目录的 `settings.json.tmp-<pid>-<nanos>`，再原子替换。
    pub fn save(&self, settings: &Settings) -> Result<()> {
        let text = serde_json::to_string_pretty(settings).map_err(|e| SettingsError::Json(e.to_string()))?;
        write_atomic(&self.path, text.as_bytes())
    }

    pub fn get(&self, agent_id: &str) -> Result<Option<AgentServer>> {
        Ok(self.load()?.agent_servers.get(agent_id).cloned())
    }

    /// 覆盖一条并落盘，返回落盘后的全量设置。
    pub fn upsert(&self, agent_id: &str, server: AgentServer) -> Result<Settings> {
        let mut settings = self.load()?;
        settings.agent_servers.insert(agent_id.to_string(), server);
        self.save(&settings)?;
        Ok(settings)
    }
}

/// 临时文件 + rename。目标目录不存在时创建（数据目录由核心保证存在，这里兜底）。
pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let dir = path.parent().ok_or_else(|| SettingsError::Io(format!("{} has no parent", path.display())))?;
    std::fs::create_dir_all(dir).map_err(|e| SettingsError::Io(format!("{}: {e}", dir.display())))?;
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let file_name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let tmp = dir.join(format!("{file_name}.tmp-{}-{nanos}", std::process::id()));
    let io = |e: std::io::Error| SettingsError::Io(format!("{}: {e}", tmp.display()));
    std::fs::write(&tmp, bytes).map_err(io)?;
    if let Err(e) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(SettingsError::Io(format!("rename {} -> {}: {e}", tmp.display(), path.display())));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("acp-settings-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn agent_server_schema_matches_zed_shape() {
        // 形状照 Zed settings.json 的真实条目（command 是字符串，args / env 在顶层，未知字段忽略）。
        let json = r#"{"agent_servers":{
            "dsh":{"type":"custom","command":"dsh-acp","args":["--acp"],"env":{"A":"1"},"default_mode":"ask"},
            "claude":{"type":"registry","env":{}}
        }}"#;
        let s: Settings = serde_json::from_str(json).expect("parse");
        match s.agent_servers.get("dsh") {
            Some(AgentServer::Custom { path, args, env }) => {
                assert_eq!(path, "dsh-acp");
                assert_eq!(args, &vec!["--acp".to_string()]);
                assert_eq!(env.get("A").map(String::as_str), Some("1"));
            }
            other => panic!("unexpected: {other:?}"),
        }
        assert!(matches!(s.agent_servers.get("claude"), Some(AgentServer::Registry { .. })));
        let back = serde_json::to_value(&s).expect("serialize");
        assert_eq!(back["agent_servers"]["dsh"]["command"], "dsh-acp");
    }

    #[test]
    fn missing_file_is_empty_and_upsert_round_trips() {
        let dir = temp_dir("roundtrip");
        let store = SettingsStore::new(dir.clone());
        assert_eq!(store.load().expect("empty"), Settings::default());
        assert!(!store.path.exists(), "load must not create the file");

        let server = AgentServer::Custom {
            path: "C:/tools/agent.cmd".into(),
            args: vec!["--acp".into()],
            env: BTreeMap::from([("K".to_string(), "v".to_string())]),
        };
        let after = store.upsert("dsh", server.clone()).expect("upsert");
        assert_eq!(after.agent_servers.get("dsh"), Some(&server));
        assert_eq!(store.get("dsh").expect("get"), Some(server));
        assert_eq!(store.get("nope").expect("get"), None);
        // 没有残留的临时文件。
        let leftovers: Vec<_> = std::fs::read_dir(&dir)
            .expect("dir")
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains(".tmp-"))
            .collect();
        assert!(leftovers.is_empty(), "temp files left behind: {leftovers:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn corrupt_file_is_reported_not_overwritten() {
        let dir = temp_dir("corrupt");
        std::fs::create_dir_all(&dir).expect("mkdir");
        let store = SettingsStore::new(dir.clone());
        std::fs::write(&store.path, "{ not json").expect("write");
        assert!(matches!(store.load(), Err(SettingsError::Json(_))));
        assert!(matches!(store.upsert("x", AgentServer::Registry { env: BTreeMap::new() }), Err(SettingsError::Json(_))));
        assert_eq!(std::fs::read_to_string(&store.path).expect("read"), "{ not json");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
