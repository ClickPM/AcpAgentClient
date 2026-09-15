//! `fs/read_text_file`、`fs/write_text_file`（docs/design.md § 7），工作区文件树与搜索，
//! 以及 git CLI 子进程薄封装（分支 / 切换 / 新建 / Branch Diff，见 [`git`]）。
//! R3 落 `list_dir` / `search` 与 git；R4 补 `fs/*` 回调与 `notify`。
//! 写文件一律「临时文件 + rename」（CLAUDE.md 规则 7）。

use std::fmt;
use std::path::{Path, PathBuf};

use serde::Serialize;

pub mod git;

#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum FsError {
    /// 路径不是绝对路径，或不在会话工作目录之内。
    OutsideWorkspace(PathBuf),
    Io(String),
    /// git 子进程返回非零，消息是它自己的 stderr。
    Git(String),
    /// 本机找不到 `git` 可执行文件。
    GitUnavailable,
    NotImplemented(&'static str),
}

impl fmt::Display for FsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            FsError::OutsideWorkspace(p) => write!(f, "fs: path outside workspace: {}", p.display()),
            FsError::Io(e) => write!(f, "fs: io: {e}"),
            FsError::Git(e) => write!(f, "git: {e}"),
            FsError::GitUnavailable => write!(f, "git: executable not found on PATH"),
            FsError::NotImplemented(round) => write!(f, "fs: not implemented until {round}"),
        }
    }
}

impl std::error::Error for FsError {}

pub type Result<T> = std::result::Result<T, FsError>;

/// 会话工作目录的边界检查：路径必须是绝对路径、位于 `cwd` 之内，且不含 `..`
/// （`starts_with` 是按分量的词法比较，`<cwd>/../other` 也以 `<cwd>` 开头；审查 finding，2026-09-15）。
pub fn ensure_inside(cwd: &Path, path: &Path) -> Result<()> {
    let has_parent = path
        .components()
        .any(|c| matches!(c, std::path::Component::ParentDir));
    if path.is_absolute() && !has_parent && path.starts_with(cwd) {
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

// ---------------------------------------------------------------- 目录列举与按名搜索（R3）

/// 不进列举与搜索的目录名：版本库内部、包管理与构建产物。搜索的深度与总量都有上限，防止在大仓库上卡住。
pub const IGNORED_DIRS: &[&str] = &[".git", "node_modules", "target", "build", ".dart_tool", ".gradle", ".idea", ".vscode"];

/// 搜索最多访问的目录项数（含被跳过的）。
pub const SEARCH_VISIT_LIMIT: usize = 20_000;

/// 搜索最深进入的层数（相对 root）。
pub const SEARCH_DEPTH_LIMIT: usize = 12;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    /// 文件名（目录不带尾斜杠）。
    pub name: String,
    /// 绝对路径。
    pub path: String,
    /// 相对 root 的所在目录，末尾带 `/`（根目录下是空串）。画板 42 行尾的 mono 文字。
    pub parent: String,
    pub is_dir: bool,
    /// 文件字节数；目录为 null。
    pub size: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DirListing {
    pub path: String,
    pub entries: Vec<Entry>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchResult {
    pub files: Vec<Entry>,
    pub directories: Vec<Entry>,
    /// 命中数超过 limit 或访问量触顶：结果不完整。
    pub truncated: bool,
}

fn relative_parent(root: &Path, dir: &Path) -> String {
    match dir.strip_prefix(root) {
        Ok(rel) if rel.as_os_str().is_empty() => String::new(),
        Ok(rel) => format!("{}/", rel.to_string_lossy().replace('\\', "/")),
        Err(_) => String::new(),
    }
}

fn entry_of(root: &Path, dir: &Path, name: &str, is_dir: bool, size: Option<u64>) -> Entry {
    Entry {
        name: name.to_string(),
        path: dir.join(name).to_string_lossy().into_owned(),
        parent: relative_parent(root, dir),
        is_dir,
        size,
    }
}

/// 列一层目录（文件面板与 `@` 提及的起点）。目录在前、各自按名排序（大小写不敏感）。
/// `path` 必须在 `root` 之内（[`ensure_inside`]）。
pub fn list_dir(root: &Path, path: &Path) -> Result<DirListing> {
    ensure_inside(root, path)?;
    let read = std::fs::read_dir(path).map_err(|e| FsError::Io(format!("{}: {e}", path.display())))?;
    let mut entries = Vec::new();
    for item in read {
        let item = item.map_err(|e| FsError::Io(format!("{}: {e}", path.display())))?;
        let name = item.file_name().to_string_lossy().into_owned();
        let meta = match item.metadata() {
            Ok(m) => m,
            // 悬空链接 / 权限不足：跳过而不是整次失败。
            Err(_) => continue,
        };
        let is_dir = meta.is_dir();
        if is_dir && IGNORED_DIRS.contains(&name.as_str()) {
            continue;
        }
        entries.push(entry_of(root, path, &name, is_dir, if is_dir { None } else { Some(meta.len()) }));
    }
    entries.sort_by(|a, b| match (a.is_dir, b.is_dir) {
        (true, false) => std::cmp::Ordering::Less,
        (false, true) => std::cmp::Ordering::Greater,
        _ => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
    });
    Ok(DirListing { path: path.to_string_lossy().into_owned(), entries })
}

/// 按名字子串搜索（`@` 提及；大小写不敏感）。`query` 为空时返回空结果，不做全量遍历。
/// 广度优先，跳过 [`IGNORED_DIRS`]，受 [`SEARCH_DEPTH_LIMIT`] 与 [`SEARCH_VISIT_LIMIT`] 约束。
pub fn search(root: &Path, query: &str, limit: usize) -> Result<SearchResult> {
    let needle = query.trim().to_lowercase();
    if needle.is_empty() || limit == 0 {
        return Ok(SearchResult { files: Vec::new(), directories: Vec::new(), truncated: false });
    }
    let mut files: Vec<Entry> = Vec::new();
    let mut directories: Vec<Entry> = Vec::new();
    let mut truncated = false;
    let mut visited = 0usize;
    let mut queue: std::collections::VecDeque<(PathBuf, usize)> = std::collections::VecDeque::new();
    queue.push_back((root.to_path_buf(), 0));
    while let Some((dir, depth)) = queue.pop_front() {
        let Ok(read) = std::fs::read_dir(&dir) else { continue };
        for item in read.flatten() {
            visited += 1;
            if visited > SEARCH_VISIT_LIMIT {
                truncated = true;
                break;
            }
            let name = item.file_name().to_string_lossy().into_owned();
            let Ok(meta) = item.metadata() else { continue };
            let is_dir = meta.is_dir();
            if is_dir && IGNORED_DIRS.contains(&name.as_str()) {
                continue;
            }
            if name.to_lowercase().contains(&needle) {
                let entry = entry_of(root, &dir, &name, is_dir, if is_dir { None } else { Some(meta.len()) });
                let bucket = if is_dir { &mut directories } else { &mut files };
                if bucket.len() < limit {
                    bucket.push(entry);
                } else {
                    truncated = true;
                }
            }
            if is_dir && depth < SEARCH_DEPTH_LIMIT {
                queue.push_back((dir.join(&name), depth + 1));
            }
        }
        if visited > SEARCH_VISIT_LIMIT {
            break;
        }
    }
    // 浅的排前面，同深度按名字。
    let by_depth = |a: &Entry, b: &Entry| {
        a.parent
            .matches('/')
            .count()
            .cmp(&b.parent.matches('/').count())
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    };
    files.sort_by(by_depth);
    directories.sort_by(by_depth);
    Ok(SearchResult { files, directories, truncated })
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
        let escaped = cwd.join("..").join("other").join("x.txt");
        assert!(ensure_inside(cwd, &escaped).is_err(), "`..` must not escape the workspace");
    }

    fn sandbox(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("acp-fs-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("scripts")).expect("mkdir scripts");
        std::fs::create_dir_all(dir.join(".git")).expect("mkdir .git");
        std::fs::create_dir_all(dir.join("docs")).expect("mkdir docs");
        std::fs::write(dir.join("scripts").join("validate.ps1"), "x").expect("write");
        std::fs::write(dir.join("scripts").join("validate-all.ps1"), "xx").expect("write");
        std::fs::write(dir.join(".git").join("HEAD"), "ref: x").expect("write");
        std::fs::write(dir.join("docs").join("design.md"), "xyz").expect("write");
        std::fs::write(dir.join("README.md"), "r").expect("write");
        dir
    }

    #[test]
    fn list_dir_sorts_dirs_first_and_skips_ignored() {
        let dir = sandbox("list");
        let listing = list_dir(&dir, &dir).expect("list");
        let names: Vec<&str> = listing.entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["docs", "scripts", "README.md"], "dirs first, .git skipped");
        assert_eq!(listing.entries.last().expect("file").size, Some(1));
        assert!(list_dir(&dir, Path::new("relative")).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn search_matches_names_and_splits_files_and_dirs() {
        let dir = sandbox("search");
        let r = search(&dir, "validate", 10).expect("search");
        assert_eq!(r.files.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(), vec!["validate-all.ps1", "validate.ps1"]);
        assert_eq!(r.files[0].parent, "scripts/");
        assert!(r.directories.is_empty());

        let d = search(&dir, "doc", 10).expect("search");
        assert_eq!(d.directories.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(), vec!["docs"]);

        // .git 下的东西搜不出来。
        assert!(search(&dir, "HEAD", 10).expect("search").files.is_empty());
        // 空 query 不遍历。
        assert_eq!(search(&dir, "   ", 10).expect("search").files.len(), 0);
        // limit 触顶要报 truncated。
        let one = search(&dir, "validate", 1).expect("search");
        assert_eq!(one.files.len(), 1);
        assert!(one.truncated);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
