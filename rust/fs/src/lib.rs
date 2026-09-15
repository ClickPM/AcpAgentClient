//! `fs/read_text_file`、`fs/write_text_file`（docs/design.md § 7），工作区文件树与搜索，
//! 以及 git CLI 子进程薄封装（分支 / 切换 / 新建 / 状态徽章 / Branch Diff）。
//! R3 拉进 `fs_list_dir` / `fs_search` 与 git；R4 补回调与 `notify`。R0 只定结构与 `Result` 边界。
//! 写文件一律「临时文件 + rename」（CLAUDE.md 规则 7）。

use std::fmt;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum FsError {
    /// 路径不是绝对路径，或不在会话工作目录之内。
    OutsideWorkspace(PathBuf),
    NotImplemented(&'static str),
}

impl fmt::Display for FsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            FsError::OutsideWorkspace(p) => write!(f, "fs: path outside workspace: {}", p.display()),
            FsError::NotImplemented(round) => write!(f, "fs: not implemented until {round}"),
        }
    }
}

impl std::error::Error for FsError {}

pub type Result<T> = std::result::Result<T, FsError>;

/// 会话工作目录的边界检查：路径必须是绝对路径且位于 `cwd` 之内。
pub fn ensure_inside(cwd: &Path, path: &Path) -> Result<()> {
    if path.is_absolute() && path.starts_with(cwd) {
        Ok(())
    } else {
        Err(FsError::OutsideWorkspace(path.to_path_buf()))
    }
}

/// `fs/read_text_file`：`line` / `limit` 是 1-based。R4。
pub fn read_text_file(cwd: &Path, path: &Path, _line: Option<u32>, _limit: Option<u32>) -> Result<String> {
    ensure_inside(cwd, path)?;
    Err(FsError::NotImplemented("R4"))
}

/// `fs/write_text_file`：不存在则创建；临时文件 + rename。R4。
pub fn write_text_file(cwd: &Path, path: &Path, _content: &str) -> Result<()> {
    ensure_inside(cwd, path)?;
    Err(FsError::NotImplemented("R4"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inside_check() {
        let cwd = if cfg!(windows) { Path::new(r"D:\ws") } else { Path::new("/ws") };
        let inside = cwd.join("a").join("b.txt");
        assert!(ensure_inside(cwd, &inside).is_ok());
        assert!(ensure_inside(cwd, Path::new("relative.txt")).is_err());
        let outside = if cfg!(windows) { Path::new(r"D:\other\x.txt") } else { Path::new("/other/x.txt") };
        assert!(ensure_inside(cwd, outside).is_err());
    }
}
