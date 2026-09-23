//! `agents/<id>/install.json`：一次安装的记录（怎么拉起 + 认证状态）。settings.json 里只有 Zed 同形的
//! `{type: "registry"}` 条目，拉起参数不进 settings（docs/design.md § 6 第 3 条）。写走临时文件 + rename（规则 7）。

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{RegistryDirs, RegistryError, Result};

pub const MANIFEST_FILE: &str = "install.json";

/// 安装记录「读 → 改 → 写」的进程内串行化：`session/new` 结果的认证状态回写（[`InstallManifest::set_auth_status`]）与
/// 升级切换（[`InstallManifest::switch_to`]）会同时写同一份 `install.json`；不串起来，后写的一方会拿自己读到的旧记录
/// 整份盖掉对方——升级被静默撤销（下次启动清扫再把新版本目录删掉），或登录结果被切换盖回旧值（round-board-53 审查第 2 轮）。
static WRITES: Mutex<()> = Mutex::new(());

fn writes() -> MutexGuard<'static, ()> {
    match WRITES.lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    }
}

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
    /// 升级那一刻正在运行的连接的版本（画板 53「已升级 · 待重载」）：连续升级两次都没重载时保留最早那个；升级时没有连接则为空。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previous_version: Option<String>,
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

    /// 改认证状态并落盘（没有安装记录时什么都不做）。与升级切换串行（见 [`WRITES`]）。
    pub fn set_auth_status(dirs: &RegistryDirs, agent_id: &str, status: AuthStatus) -> Result<bool> {
        let _writing = writes();
        let Some(mut manifest) = Self::load(dirs, agent_id)? else { return Ok(false) };
        if manifest.auth_status == status {
            return Ok(true);
        }
        manifest.auth_status = status;
        manifest.save(dirs)?;
        Ok(true)
    }

    /// 升级切换：在与 [`Self::set_auth_status`] 同一把锁里，把磁盘上此刻的认证状态带进 `next` 再写盘——升级在途时
    /// 运行中的连接照常 `session/new`，那期间记下的登录结果不能被升级开始时读到的旧值盖回去。
    pub fn switch_to(dirs: &RegistryDirs, mut next: InstallManifest) -> Result<()> {
        let _writing = writes();
        if let Some(disk) = Self::load(dirs, &next.id)? {
            next.auth_status = disk.auth_status;
        }
        next.save(dirs)
    }

    /// 已安装 = 有记录且拉起用的程序 / 目录还在。
    pub fn is_intact(&self) -> bool {
        self.entry_path().is_some_and(|p| p.is_file())
    }

    /// 拉起入口：npx 型是 `args[0]` 的脚本（`command` 固定是 `node`），binary 型是 `command`。判「在用」与清旧目录都按它。
    pub fn entry_path(&self) -> Option<PathBuf> {
        let entry = if self.kind == "npx" { self.args.first()? } else { &self.command };
        Some(PathBuf::from(entry))
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
            previous_version: None,
        };
        m.save(&dirs).expect("save");
        assert_eq!(InstallManifest::load(&dirs, "x").expect("load"), Some(m.clone()));
        assert!(InstallManifest::set_auth_status(&dirs, "x", AuthStatus::NeedsAuth).expect("set"));
        assert_eq!(InstallManifest::load(&dirs, "x").expect("load").expect("some").auth_status, AuthStatus::NeedsAuth);
        let v = InstallManifest::load(&dirs, "x").expect("load").expect("some").to_json();
        assert_eq!(v["authStatus"], "needs_auth");
        // 升级切换带的是磁盘上此刻的认证状态，不是调用方手里那份旧值（审查第 2 轮）。
        let mut next = InstallManifest::load(&dirs, "x").expect("load").expect("some");
        next.version = "2.0.0".into();
        next.auth_status = AuthStatus::Unknown;
        InstallManifest::switch_to(&dirs, next).expect("switch");
        let switched = InstallManifest::load(&dirs, "x").expect("load").expect("some");
        assert_eq!((switched.version.as_str(), switched.auth_status), ("2.0.0", AuthStatus::NeedsAuth));
        std::fs::write(InstallManifest::path(&dirs, "x"), "{ broken").expect("write");
        assert!(matches!(InstallManifest::load(&dirs, "x"), Err(RegistryError::Json(_))));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
