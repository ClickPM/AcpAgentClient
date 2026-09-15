//! registry.json 拉取 / 缓存 / 图标、npx 与 binary 安装、受管 Node（docs/design.md § 6）。
//! R0 只定结构与 `Result` 边界；R5 复制 Zed `agent_registry_store.rs` / `agent_server_store.rs` 后填实
//! （复制进来的文件按 CLAUDE.md 规则 5 在文件头标来源路径与 commit，validate.ps1 会核对）。

use std::fmt;
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum RegistryError {
    NotImplemented(&'static str),
}

impl fmt::Display for RegistryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RegistryError::NotImplemented(round) => write!(f, "registry: not implemented until {round}"),
        }
    }
}

impl std::error::Error for RegistryError {}

pub type Result<T> = std::result::Result<T, RegistryError>;

/// registry 缓存与安装目录的持有者（`registry-cache/`、`agents/`、`node/` 都在数据目录下，§ 10）。
#[derive(Debug, Clone)]
pub struct RegistryStore {
    pub data_dir: PathBuf,
}

impl RegistryStore {
    pub fn new(data_dir: PathBuf) -> Self {
        Self { data_dir }
    }

    /// 拉取或读缓存（1 小时节流）。R5。
    pub fn refresh(&self) -> Result<()> {
        Err(RegistryError::NotImplemented("R5"))
    }
}
