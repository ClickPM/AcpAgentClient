//! `agents/<id>/install.json`：一次安装的记录（怎么拉起 + 认证状态）。settings.json 里只有 Zed 同形的
//! `{type: "registry"}` 条目，拉起参数不进 settings（docs/design.md § 6 第 3 条）。写走临时文件 + rename（规则 7）。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{RegistryDirs, RegistryError, Result};

pub const MANIFEST_FILE: &str = "install.json";

/// 认证状态（本地态，docs/design.md § 5 第 5 条）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum AuthStatus {
    #[default]
    Unknown,
    NeedsAuth,
    Authenticated,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallManifest {
    pub id: String,
    /// npx / binary。
    pub kind: String,
    /// registry 条目的版本（npx 型实际装到的版本在 `installed_version`）。
    pub version: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub installed_version: Option<String>,
    /// npx：包名与 npm 规格。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub package: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub package_spec: Option<String>,
    /// 拉起：npx 型 `command` 固定写 `node`（拉起时换成系统 / 受管 Node 的绝对路径），binary 型是解压后的绝对路径。
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    /// 安装目录（`agents/<id>/` 或 `agents/<id>/<version>/`）。
    pub dir: String,
    #[serde(default)]
    pub installed_at: i64,
    #[serde(default)]
    pub auth_status: AuthStatus,
    /// 首次握手拿到的 `agentInfo`（展示名 / 版本）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_info: Option<Value>,
    /// sha256 校验的结果说明（「已校验」/「条目没给 sha256，跳过」）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub verify_note: Option<String>,
}

impl InstallManifest {
    pub fn path(dirs: &RegistryDirs, agent_id: &str) -> PathBuf {
        dirs.agent_dir(agent_id).join(MANIFEST_FILE)
    }

    /// 没有文件 → `Ok(None)`；文件坏了 → `Err`（不静默当未安装，免得覆盖掉一份看不懂的记录）。
    pub fn load(dirs: &RegistryDirs, agent_id: &str) -> Result<Option<Self>> {
        let path = Self::path(dirs, agent_id);
        match std::fs::read_to_string(&path) {
            Ok(text) => serde_json::from_str(&text).map(Some).map_err(|e| RegistryError::Json(format!("{}: {e}", path.display()))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(RegistryError::Io(format!("{}: {e}", path.display()))),
        }
    }

    pub fn save(&self, dirs: &RegistryDirs) -> Result<()> {
        let path = Self::path(dirs, &self.id);
        let text = serde_json::to_string_pretty(self)?;
        fs::write_atomic(&path, text.as_bytes())?;
        Ok(())
    }

    /// 改认证状态并落盘（没有安装记录时什么都不做）。
    pub fn set_auth_status(dirs: &RegistryDirs, agent_id: &str, status: AuthStatus) -> Result<bool> {
        let Some(mut manifest) = Self::load(dirs, agent_id)? else { return Ok(false) };
        if manifest.auth_status == status {
            return Ok(true);
        }
        manifest.auth_status = status;
        manifest.save(dirs)?;
        Ok(true)
    }

    /// 已安装 = 有记录且拉起用的程序 / 目录还在。
    pub fn is_intact(&self) -> bool {
        if self.kind == "npx" {
            self.args.first().map(|exe| Path::new(exe).is_file()).unwrap_or(false)
        } else {
            Path::new(&self.command).is_file()
        }
    }

    pub fn to_json(&self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_round_trips_and_tracks_auth_status() {
        let dir = std::env::temp_dir().join(format!("acp-registry-manifest-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let dirs = RegistryDirs::new(&dir);
        assert_eq!(InstallManifest::load(&dirs, "x").expect("load"), None);
        assert!(!InstallManifest::set_auth_status(&dirs, "x", AuthStatus::Authenticated).expect("noop"));
        let m = InstallManifest {
            id: "x".into(),
            kind: "npx".into(),
            version: "1.0.0".into(),
            installed_version: Some("1.0.0".into()),
            package: Some("x".into()),
            package_spec: Some("x@1.0.0".into()),
            command: "node".into(),
            args: vec!["D:/agents/x/node_modules/x/bin.js".into()],
            env: BTreeMap::new(),
            dir: dirs.agent_dir("x").to_string_lossy().into_owned(),
            installed_at: 1,
            auth_status: AuthStatus::Unknown,
            agent_info: None,
            verify_note: None,
        };
        m.save(&dirs).expect("save");
        assert_eq!(InstallManifest::load(&dirs, "x").expect("load"), Some(m.clone()));
        assert!(InstallManifest::set_auth_status(&dirs, "x", AuthStatus::NeedsAuth).expect("set"));
        assert_eq!(InstallManifest::load(&dirs, "x").expect("load").expect("some").auth_status, AuthStatus::NeedsAuth);
        let v = InstallManifest::load(&dirs, "x").expect("load").expect("some").to_json();
        assert_eq!(v["authStatus"], "needs_auth");
        std::fs::write(InstallManifest::path(&dirs, "x"), "{ broken").expect("write");
        assert!(matches!(InstallManifest::load(&dirs, "x"), Err(RegistryError::Json(_))));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
