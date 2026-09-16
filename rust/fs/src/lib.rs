//! `fs/read_text_file`、`fs/write_text_file`（docs/design.md § 7），工作区文件树 / 搜索 / 查看器读文件 / 目录监视（[`watch`]），
//! 以及 git CLI 子进程薄封装（分支 / 切换 / 新建 / Branch Diff / 状态徽章，见 [`git`]）。
//! R3 落 `list_dir` / `search` 与 git；R4 落 `fs/*` 回调、`read_file`、`notify` 与 `git status`。
//! 写文件一律「临时文件 + rename」（CLAUDE.md 规则 7）。

use std::fmt;
use std::path::{Path, PathBuf};

use serde::Serialize;

pub mod git;
pub mod watch;

#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum FsError {
    /// 路径不是绝对路径，或不在会话工作目录之内。
    OutsideWorkspace(PathBuf),
    /// 文件不存在（`fs/read_text_file` 回 `-32002` resource not found）。
    NotFound(PathBuf),
    /// 入参不合规范（例如从文件末尾之后开始读；回 `-32602` invalid params）。
    InvalidParams(String),
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
            FsError::NotFound(p) => write!(f, "fs: not found: {}", p.display()),
            FsError::InvalidParams(e) => write!(f, "fs: invalid params: {e}"),
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

/// `fs/read_text_file`（docs/design.md § 7）：`line` / `limit` 都是 1-based；`line` 缺省从第一行起、`limit` 缺省到文件尾。
/// 行的口径照 Zed `acp_thread.rs::read_text_file`：按 `\n` 切成「行」（文件末尾的换行之后算一个空行），
/// 起点落在最后一行之后 → invalid params「Attempting to read beyond the end of the file」；返回的片段保留每行自己的换行。
/// 文件不存在 → [`FsError::NotFound`]（agent 侧收到 `-32002`）。不是合法 UTF-8 的字节按 lossy 解码。
pub fn read_text_file(cwd: &Path, path: &Path, line: Option<u32>, limit: Option<u32>) -> Result<String> {
    ensure_inside(cwd, path)?;
    let bytes = match std::fs::read(path) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Err(FsError::NotFound(path.to_path_buf())),
        Err(e) => return Err(FsError::Io(format!("{}: {e}", path.display()))),
    };
    let text = String::from_utf8_lossy(&bytes);
    slice_lines(&text, line, limit)
}

/// 纯函数便于测试：`text` 按 1-based 的 `line` / `limit` 取行。
pub fn slice_lines(text: &str, line: Option<u32>, limit: Option<u32>) -> Result<String> {
    // Zed：args 是 1-based，转 0-based；`line: 0` 与缺省同义。
    let start = line.unwrap_or_default().saturating_sub(1) as usize;
    let rows: Vec<&str> = text.split('\n').collect();
    let last_row = rows.len() - 1;
    if start > last_row {
        return Err(FsError::InvalidParams(format!(
            "Attempting to read beyond the end of the file, line {}:{}",
            last_row + 1,
            rows[last_row].len()
        )));
    }
    let end = match limit {
        Some(n) => start.saturating_add(n as usize).min(rows.len()),
        None => rows.len(),
    };
    // 逐行拼回：除最后一行外每行带自己的 `\n`；切到文件尾时最后那个尾块不补换行。
    let mut out = String::new();
    for (i, row) in rows[start..end].iter().enumerate() {
        out.push_str(row);
        if start + i < last_row {
            out.push('\n');
        }
    }
    Ok(out)
}

/// `fs/write_text_file`（docs/design.md § 7）：不存在则创建（规范 MUST），父目录不存在一并创建；临时文件 + rename（规则 7）。
pub fn write_text_file(cwd: &Path, path: &Path, content: &str) -> Result<()> {
    ensure_inside(cwd, path)?;
    write_atomic(path, content.as_bytes())
}

/// 临时文件 + rename：同目录写 `<name>.tmp-<pid>-<nanos>` 再原子替换；目标目录不存在时创建。
/// （与 `rust/settings` 的同名函数一个口径；fs 不依赖 settings，各自一份。）
pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let dir = path.parent().ok_or_else(|| FsError::Io(format!("{} has no parent", path.display())))?;
    std::fs::create_dir_all(dir).map_err(|e| FsError::Io(format!("{}: {e}", dir.display())))?;
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let file_name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let tmp = dir.join(format!("{file_name}.tmp-{}-{nanos}", std::process::id()));
    std::fs::write(&tmp, bytes).map_err(|e| FsError::Io(format!("{}: {e}", tmp.display())))?;
    if let Err(e) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(FsError::Io(format!("rename {} -> {}: {e}", tmp.display(), path.display())));
    }
    Ok(())
}

// ---------------------------------------------------------------- 查看器读文件（画板 60，`fs_read`）

/// 查看器一次最多拿的字节数：更大的文件只给前一段并标 `truncated`（超大文件整份进 Dart 没有意义）。
pub const READ_FILE_LIMIT: usize = 2 * 1024 * 1024;

/// 二进制判定只看开头这么多字节里有没有 NUL。
const BINARY_SNIFF: usize = 8 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileContent {
    pub path: String,
    /// 文本内容（二进制文件为空串；超限时是按字符边界截断的前一段）。
    pub text: String,
    /// 整个文件的字节数。
    pub size: u64,
    /// 行数（按 `\n` 计；空文件 0；末尾没有换行的最后一行也算一行）。
    pub lines: usize,
    pub binary: bool,
    pub truncated: bool,
}

/// 读一个文件给查看器（`fs_read`）。`path` 必须在 `root` 之内。
pub fn read_file(root: &Path, path: &Path) -> Result<FileContent> {
    ensure_inside(root, path)?;
    let meta = match std::fs::metadata(path) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Err(FsError::NotFound(path.to_path_buf())),
        Err(e) => return Err(FsError::Io(format!("{}: {e}", path.display()))),
    };
    if meta.is_dir() {
        return Err(FsError::InvalidParams(format!("{} is a directory", path.display())));
    }
    use std::io::Read;
    let mut file = std::fs::File::open(path).map_err(|e| FsError::Io(format!("{}: {e}", path.display())))?;
    let mut bytes = Vec::with_capacity((meta.len() as usize).min(READ_FILE_LIMIT + 1));
    file.by_ref()
        .take(READ_FILE_LIMIT as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| FsError::Io(format!("{}: {e}", path.display())))?;
    let truncated = bytes.len() > READ_FILE_LIMIT;
    if truncated {
        bytes.truncate(READ_FILE_LIMIT);
    }
    let binary = bytes[..bytes.len().min(BINARY_SNIFF)].contains(&0);
    let text = if binary {
        String::new()
    } else {
        match String::from_utf8(bytes) {
            Ok(s) => s,
            Err(e) => {
                // 截断切在多字节字符中间会走到这里：只保留合法前缀（文件本身不是 UTF-8 也一样，不猜编码）。
                let valid = e.utf8_error().valid_up_to();
                let mut bytes = e.into_bytes();
                bytes.truncate(valid);
                String::from_utf8(bytes).unwrap_or_default()
            }
        }
    };
    let lines = if binary || text.is_empty() {
        0
    } else {
        text.matches('\n').count() + usize::from(!text.ends_with('\n'))
    };
    Ok(FileContent {
        path: path.to_string_lossy().into_owned(),
        text,
        size: meta.len(),
        lines,
        binary,
        truncated,
    })
}

// ---------------------------------------------------------------- 目录列举与按名搜索（R3）

/// 不进列举与搜索的目录名：版本库内部、包管理与构建产物。搜索的深度与总量都有上限，防止在大仓库上卡住。
/// 符号链接与 Windows 的目录联接一律当文件（不递归进去），见 [`list_dir`]。
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

/// 这一项算不算「可以进去的目录」。链接一律不算：
/// Unix 的符号链接 `is_symlink()` 为 true；**Windows 的目录联接（junction / mount point）`is_symlink()` 是 false、
/// `is_dir()` 是 true**，只能看 `FILE_ATTRIBUTE_REPARSE_POINT`（审查第 2 轮 finding P2，2026-09-15）。
/// `DirEntry::metadata` 不跟随链接，拿到的就是链接本身的属性。
fn entry_is_dir(meta: &std::fs::Metadata) -> bool {
    if !meta.is_dir() {
        return false;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        /// `winnt.h`。
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
        if meta.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return false;
        }
    }
    !meta.file_type().is_symlink()
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
        // 链接（含 Windows 的目录联接）一律当文件：既不进目录组、也不会被 `search` 递归进去。
        // `ensure_inside` 只是词法检查，跟进去就会把工作区外面的东西列出来、再被加成 `resource_link`。
        let meta = match item.metadata() {
            Ok(m) => m,
            // 悬空链接 / 权限不足：跳过而不是整次失败。
            Err(_) => continue,
        };
        let is_dir = entry_is_dir(&meta);
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
            // 同 `list_dir`：不跟随链接 / junction，免得搜出工作区外面的路径。
            let Ok(meta) = item.metadata() else { continue };
            let is_dir = entry_is_dir(&meta);
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

    /// Windows 的目录联接（junction）：`is_symlink()` 是 false、`is_dir()` 是 true，
    /// 只能靠 `FILE_ATTRIBUTE_REPARSE_POINT` 认出来。不认就会把工作区外面的东西列出来 / 搜出来
    /// （审查第 2 轮 finding P2，2026-09-15）。
    #[cfg(windows)]
    #[test]
    fn junctions_are_not_followed_out_of_the_workspace() {
        let dir = sandbox("junction");
        let outside = std::env::temp_dir().join(format!("acp-fs-outside-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&outside);
        std::fs::create_dir_all(&outside).expect("mkdir");
        std::fs::write(outside.join("工作区外的秘密.txt"), "x").expect("write");

        let link = dir.join("link-out");
        let status = std::process::Command::new("cmd")
            .args(["/c", "mklink", "/J"])
            .arg(&link)
            .arg(&outside)
            .output()
            .expect("mklink");
        if !status.status.success() {
            eprintln!("mklink /J failed; skipping: {}", String::from_utf8_lossy(&status.stderr));
            let _ = std::fs::remove_dir_all(&dir);
            let _ = std::fs::remove_dir_all(&outside);
            return;
        }

        let listing = list_dir(&dir, &dir).expect("list");
        let entry = listing.entries.iter().find(|e| e.name == "link-out").expect("junction listed");
        assert!(!entry.is_dir, "junction 必须当文件，否则 @ 提及会把它当目录点进去");

        // 搜索不能跟进去：外面那个文件名一条都不该出现。
        let r = search(&dir, "秘密", 10).expect("search");
        assert!(r.files.is_empty() && r.directories.is_empty(), "不该搜出工作区外面的东西: {r:?}");

        // 联接本身按名字还是搜得到（它就在工作区里）。
        let hit = search(&dir, "link-out", 10).expect("search");
        assert_eq!(hit.files.len(), 1);
        assert!(hit.directories.is_empty());

        let _ = std::fs::remove_dir_all(&link);
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&outside);
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

    // ---- R4：fs/read_text_file 的 1-based 行口径（照 Zed 的测试用例）

    #[test]
    fn slice_lines_is_one_based_and_keeps_newlines() {
        let text = "line 1\nline 2\nline 3\nline 4\nline 5\n";
        assert_eq!(slice_lines(text, None, None).expect("all"), text);
        assert_eq!(slice_lines(text, Some(3), None).expect("from 3"), "line 3\nline 4\nline 5\n");
        assert_eq!(slice_lines(text, None, Some(2)).expect("first 2"), "line 1\nline 2\n");
        assert_eq!(slice_lines(text, Some(2), Some(2)).expect("2..3"), "line 2\nline 3\n");
        // 第 6 行是文件末尾换行之后的空行：合法，读到空串。
        assert_eq!(slice_lines(text, Some(6), Some(2)).expect("tail"), "");
        // 第 7 行不存在。
        let err = slice_lines(text, Some(7), None).expect_err("beyond eof");
        assert!(matches!(err, FsError::InvalidParams(_)), "{err:?}");
        // `line: 0` 与缺省同义。
        assert_eq!(slice_lines(text, Some(0), Some(1)).expect("zero"), "line 1\n");
        // 末尾没有换行的文件：最后一行不补换行。
        let no_nl = "a\nb";
        assert_eq!(slice_lines(no_nl, None, None).expect("all"), "a\nb");
        assert_eq!(slice_lines(no_nl, Some(2), None).expect("last"), "b");
        assert_eq!(slice_lines(no_nl, Some(1), Some(1)).expect("first"), "a\n");
        assert!(slice_lines("", None, None).expect("empty").is_empty());
    }

    #[test]
    fn read_and_write_text_file_stay_inside_cwd_and_write_atomically() {
        let dir = sandbox("rw");
        // 不存在 → NotFound（agent 侧是 -32002）。
        let missing = dir.join("nope.txt");
        assert!(matches!(read_text_file(&dir, &missing, None, None), Err(FsError::NotFound(_))));
        // 相对路径 / cwd 之外 → OutsideWorkspace。
        assert!(matches!(read_text_file(&dir, Path::new("README.md"), None, None), Err(FsError::OutsideWorkspace(_))));
        let outside = std::env::temp_dir().join("acp-fs-outside.txt");
        assert!(matches!(write_text_file(&dir, &outside, "x"), Err(FsError::OutsideWorkspace(_))));
        assert!(!outside.exists());

        // 父目录不存在：一并创建（规范只说文件 MUST 创建，父目录是本项目的口径）。
        let nested = dir.join("new").join("deep").join("说明.md");
        write_text_file(&dir, &nested, "第一行\n第二行\n").expect("write");
        assert_eq!(std::fs::read_to_string(&nested).expect("read"), "第一行\n第二行\n");
        assert_eq!(read_text_file(&dir, &nested, Some(2), Some(1)).expect("line 2"), "第二行\n");
        // 覆盖已有文件，且没有残留的临时文件（临时文件 + rename）。
        write_text_file(&dir, &nested, "改过\n").expect("overwrite");
        assert_eq!(read_text_file(&dir, &nested, None, None).expect("read"), "改过\n");
        let leftovers: Vec<_> = std::fs::read_dir(nested.parent().expect("parent"))
            .expect("dir")
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.contains(".tmp-"))
            .collect();
        assert!(leftovers.is_empty(), "temp files left behind: {leftovers:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 临时文件的名字形状（`<name>.tmp-<pid>-<nanos>`）与 rename 的目标：写到一半失败不能留半个文件在目标名上。
    #[test]
    fn write_atomic_uses_temp_name_in_same_dir() {
        let dir = sandbox("atomic");
        let target = dir.join("a.txt");
        std::fs::write(&target, "old").expect("seed");
        // 目标是目录时 rename 失败：临时文件必须被清掉、旧内容不动。
        let blocked = dir.join("blocked");
        std::fs::create_dir_all(&blocked).expect("mkdir");
        let err = write_atomic(&blocked, b"x").expect_err("dir target");
        assert!(matches!(err, FsError::Io(_)));
        let leftovers: Vec<_> = std::fs::read_dir(&dir)
            .expect("dir")
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.contains(".tmp-"))
            .collect();
        assert!(leftovers.is_empty(), "temp files left behind: {leftovers:?}");
        assert_eq!(std::fs::read_to_string(&target).expect("read"), "old");
        write_atomic(&target, b"new").expect("write");
        assert_eq!(std::fs::read_to_string(&target).expect("read"), "new");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn read_file_reports_size_lines_binary_and_truncation() {
        let dir = sandbox("readfile");
        let text = dir.join("t.md");
        std::fs::write(&text, "# 标题\n\n正文\n").expect("write");
        let c = read_file(&dir, &text).expect("read");
        assert_eq!(c.lines, 3);
        assert_eq!(c.size, "# 标题\n\n正文\n".len() as u64);
        assert!(!c.binary && !c.truncated);
        assert_eq!(c.text, "# 标题\n\n正文\n");

        let no_nl = dir.join("n.txt");
        std::fs::write(&no_nl, "a\nb").expect("write");
        assert_eq!(read_file(&dir, &no_nl).expect("read").lines, 2);
        assert_eq!(read_file(&dir, &dir.join("scripts").join("validate.ps1")).expect("read").lines, 1);

        let bin = dir.join("b.bin");
        std::fs::write(&bin, [0x89, b'P', b'N', b'G', 0, 1, 2]).expect("write");
        let b = read_file(&dir, &bin).expect("read");
        assert!(b.binary);
        assert!(b.text.is_empty());
        assert_eq!(b.lines, 0);

        // 超限：只拿前一段，且不切坏多字节字符。
        let big = dir.join("big.txt");
        let unit = "汉字abc\n"; // 10 字节
        let repeats = READ_FILE_LIMIT / unit.len() + 5;
        std::fs::write(&big, unit.repeat(repeats)).expect("write");
        let t = read_file(&dir, &big).expect("read");
        assert!(t.truncated);
        assert!(t.text.len() <= READ_FILE_LIMIT);
        assert!(std::str::from_utf8(t.text.as_bytes()).is_ok());
        assert!(t.text.ends_with('\n') || t.text.ends_with('c') || t.text.ends_with('字') || t.text.ends_with('汉') || t.text.ends_with('a') || t.text.ends_with('b'));

        assert!(matches!(read_file(&dir, &dir.join("scripts")), Err(FsError::InvalidParams(_))));
        assert!(matches!(read_file(&dir, Path::new("relative.md")), Err(FsError::OutsideWorkspace(_))));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
