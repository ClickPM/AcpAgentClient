//! Zed 兼容的 `agent_servers` 设置（docs/design.md § 6 第 5 条、§ 10）：
//! `%APPDATA%/AcpAgentClient/settings.json`，`type: registry | custom`，从 Zed `settings.json` 导入。
//! R1 最小实现（只 `custom` 型）；R5 补齐。写文件一律「临时文件 + rename」（CLAUDE.md 规则 7）。
//! R0 只定结构与 `Result` 边界。

use std::collections::BTreeMap;
use std::fmt;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

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

/// 与 Zed 同 schema 的 `command` 块。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct CustomCommand {
    pub path: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
}

/// `agent_servers` 的一条。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AgentServer {
    Registry {
        #[serde(default)]
        env: BTreeMap<String, String>,
    },
    Custom {
        command: CustomCommand,
        #[serde(default)]
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

    pub fn load(&self) -> Result<Settings> {
        Err(SettingsError::NotImplemented("R1"))
    }

    pub fn save(&self, _settings: &Settings) -> Result<()> {
        Err(SettingsError::NotImplemented("R1"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agent_server_schema_matches_zed_shape() {
        let json = r#"{"agent_servers":{"dsh":{"type":"custom","command":{"path":"dsh-acp","args":["--acp"]}}}}"#;
        let s: Settings = serde_json::from_str(json).expect("parse");
        assert!(matches!(s.agent_servers.get("dsh"), Some(AgentServer::Custom { .. })));
    }
}
