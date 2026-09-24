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
    if !(path.is_absolute() && !has_parent && path.starts_with(cwd)) {
        return Err(FsError::OutsideWorkspace(path.to_path_buf()));
    }
    // 词法在里面还不够：cwd 之下通往 path 的每一级已存在的分量都不能是链接 / 联接，否则 `std::fs` 跟过去就读写到
    // 工作区外（审查 finding，2026-09-16；与 `list_dir` 的 [`entry_is_dir`] 同一判断）。不存在的尾段（要新建的文件
    // 与父目录）不用看。
    let mut cur = cwd.to_path_buf();
    if let Ok(rel) = path.strip_prefix(cwd) {
        for component in rel.components() {
            cur.push(component);
            match std::fs::symlink_metadata(&cur) {
                Ok(meta) if is_link(&meta) => return Err(FsError::OutsideWorkspace(path.to_path_buf())),
                Ok(_) => {}
                Err(_) => break,
            }
        }
    }
    Ok(())
}

/// [`ensure_inside`] 之后**用解析过的真实路径**再判一次边界，并把它交给调用方去开。
/// 为什么还要这一步：`ensure_inside` 是「检查」、`std::fs::read` 是「打开」，两者之间有窗口——agent 在工作区里
/// 本来就有写权限，把中途某一级换成指向外面的链接，打开时就跟出去了（审查 finding，2026-09-22）。
/// 这里做的是**把窗口收窄**：边界判定与打开之间只剩一次 `canonicalize`，而且末段链接是在解析后判的
/// （逐级 `symlink_metadata` 走完之后才建出来的那条，词法检查看不见，canonicalize 看得见）。
/// **没有收干净的**：canonicalize 与 open 之间把解出来的某一级目录换成链接，照样跟得出去——真要堵死得逐级
/// 用目录句柄打开（`openat` / `FILE_FLAG_OPEN_REPARSE_POINT` 逐级校验），std 没有这套 API，
/// 手写要 `unsafe`（规则 6），所有者裁定 2026-09-23 不再追（原条目在 rounds/BACKLOG-CLOSED.md）。威胁模型也要说清楚：agent 是本机子进程、跟用户同权限，
/// 绕开这两个回调直接读写本来就没人拦，这道边界防的是「实现得糙的 agent」，不是有敌意的进程。
/// 还不存在的路径（`fs/write_text_file` 要新建的那种）没有可解的东西，原样返回，仍由 [`ensure_inside`]
/// 的逐级检查兜住。cwd 自己解不开（被删 / 无权限）时同样退回词法结论，不把正常的读写挡掉。
fn resolve_inside(cwd: &Path, path: &Path) -> Result<PathBuf> {
    ensure_inside(cwd, path)?;
    let Ok(root) = std::fs::canonicalize(cwd) else {
        return Ok(path.to_path_buf());
    };
    match std::fs::canonicalize(path) {
        Ok(real) if real.starts_with(&root) => Ok(real),
        Ok(real) => Err(FsError::OutsideWorkspace(real)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(path.to_path_buf()),
        Err(e) => Err(FsError::Io(format!("{}: {e}", path.display()))),
    }
}

/// 符号链接，或 Windows 的目录联接 / 挂载点（对联接 `is_symlink()` 是 false，只能看 `FILE_ATTRIBUTE_REPARSE_POINT`）。
/// 传入的 metadata 必须来自 `symlink_metadata` / `DirEntry::metadata`（不跟随链接）。
fn is_link(meta: &std::fs::Metadata) -> bool {
    if meta.file_type().is_symlink() {
        return true;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        /// `winnt.h`。
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
        if meta.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return true;
        }
    }
    false
}

/// `fs/read_text_file`（docs/design.md § 7）：`line` / `limit` 都是 1-based；`line` 缺省从第一行起、`limit` 缺省到文件尾。
/// 行的口径照 Zed `acp_thread.rs::read_text_file`：按 `\n` 切成「行」（文件末尾的换行之后算一个空行），
/// 起点落在最后一行之后 → invalid params「Attempting to read beyond the end of the file」；返回的片段保留每行自己的换行。
/// 文件不存在 → [`FsError::NotFound`]（agent 侧收到 `-32002`）。不是合法 UTF-8 的字节按 lossy 解码。
/// 按行流式读（[`read_lines`]），回给 agent 的内容超过 [`READ_TEXT_FILE_LIMIT`] 回 invalid params。
pub fn read_text_file(cwd: &Path, path: &Path, line: Option<u32>, limit: Option<u32>) -> Result<String> {
    let real = resolve_inside(cwd, path)?;
    let file = match std::fs::File::open(&real) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Err(FsError::NotFound(path.to_path_buf())),
        Err(e) => return Err(FsError::Io(format!("{}: {e}", path.display()))),
    };
    let reader = std::io::BufReader::with_capacity(READ_TEXT_CHUNK, file);
    read_lines(reader, line, limit, READ_TEXT_FILE_LIMIT).map_err(|e| match e {
        FsError::Io(msg) => FsError::Io(format!("{}: {msg}", path.display())),
        other => other,
    })
}

/// `fs/read_text_file` 一次最多回给 agent 的字节数（BACKLOG P0，2026-09-24）。原先整份读进内存再切行，
/// 几个 GB 的日志 / 数据导出能把宿主进程的内存吃爆（分配失败时 Rust 直接 abort，Flutter 一起没）。
/// 比查看器的 [`READ_FILE_LIMIT`] 宽：agent 的编辑工具常见「整份读 → 改 → 整份写回」，几 MB 的锁文件 / 打包产物要读得动；
/// 再大的整份读对 agent 也没用（远超任何上下文窗口），超限回 invalid params，叫它带 `line` / `limit` 分段读。
pub const READ_TEXT_FILE_LIMIT: usize = 16 * 1024 * 1024;

/// [`read_text_file`] 的读缓冲：跳过前面的行时只占这一块，文件再大也一样。
const READ_TEXT_CHUNK: usize = 64 * 1024;

/// `reader` 按 1-based 的 `line` / `limit` 取行（口径见 [`read_text_file`]）。流式：先只数不存地跳过 `line` 之前的换行，
/// 再收 `limit` 行（缺省到文件尾），收的字节超过 `cap` 就回 invalid params——峰值内存由 `cap` 压住，不再是文件大小。
/// 按 `\n` 切段后再 lossy 解码与整份解码结果一样：`\n` 不会是多字节字符的一部分。
fn read_lines(mut reader: impl std::io::BufRead, line: Option<u32>, limit: Option<u32>, cap: usize) -> Result<String> {
    let io = |e: std::io::Error| FsError::Io(e.to_string());
    // Zed：args 是 1-based，转 0-based；`line: 0` 与缺省同义。
    let start = line.unwrap_or_default().saturating_sub(1) as usize;
    // 当前所在的行（0-based）与这一行已经读过的字节数（报「读过了文件尾」时用）。
    let mut row = 0usize;
    let mut row_len = 0usize;
    while row < start {
        let buf = reader.fill_buf().map_err(io)?;
        if buf.is_empty() {
            return Err(FsError::InvalidParams(format!(
                "Attempting to read beyond the end of the file, line {}:{row_len}",
                row + 1
            )));
        }
        let n = match buf.iter().position(|&b| b == b'\n') {
            Some(at) => {
                row += 1;
                row_len = 0;
                at + 1
            }
            None => {
                row_len += buf.len();
                buf.len()
            }
        };
        reader.consume(n);
    }
    // 每行带自己的 `\n`；文件的最后一行本来就没有换行，读到文件尾就停。
    let mut out: Vec<u8> = Vec::new();
    let mut rows_left = limit.map(|n| n as usize);
    while rows_left != Some(0) {
        let buf = reader.fill_buf().map_err(io)?;
        if buf.is_empty() {
            break;
        }
        let (n, row_ended) = match buf.iter().position(|&b| b == b'\n') {
            Some(at) => (at + 1, true),
            None => (buf.len(), false),
        };
        if out.len() + n > cap {
            return Err(FsError::InvalidParams(format!(
                "content exceeds {cap} bytes; read it in pieces with line / limit"
            )));
        }
        out.extend_from_slice(&buf[..n]);
        reader.consume(n);
        if row_ended && let Some(left) = rows_left.as_mut() {
            *left -= 1;
        }
    }
    Ok(match String::from_utf8(out) {
        Ok(s) => s,
        Err(e) => String::from_utf8_lossy(e.as_bytes()).into_owned(),
    })
}

/// `fs/write_text_file`（docs/design.md § 7）：不存在则创建（规范 MUST），父目录不存在一并创建；临时文件 + rename（规则 7）。
pub fn write_text_file(cwd: &Path, path: &Path, content: &str) -> Result<()> {
    let real = resolve_inside(cwd, path)?;
    write_atomic(&real, content.as_bytes())
}

/// 临时文件 + rename（规则 7）：同目录写 `<name>.tmp-<pid>-<nanos>` 再原子替换；目标目录不存在时创建。
/// 工作区里唯一的一份：settings / registry 的落盘也走这里。
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
    // 报回去的 `path` 仍是调用方给的那份写法（解析后的 Windows verbatim 形状不能进界面），只有真正开文件用 `real`。
    let real = resolve_inside(root, path)?;
    let meta = match std::fs::metadata(&real) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Err(FsError::NotFound(path.to_path_buf())),
        Err(e) => return Err(FsError::Io(format!("{}: {e}", path.display()))),
    };
    if meta.is_dir() {
        return Err(FsError::InvalidParams(format!("{} is a directory", path.display())));
    }
    use std::io::Read;
    let mut file = std::fs::File::open(&real).map_err(|e| FsError::Io(format!("{}: {e}", path.display())))?;
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
    meta.is_dir() && !is_link(meta)
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
        assert!(status.status.success(), "mklink /J failed: {}", String::from_utf8_lossy(&status.stderr));

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

    /// 工作区里的目录链接（Windows 用 `mklink /J` 建联接，其他平台用符号链接）指向工作区外：
    /// `fs/read_text_file`、`fs/write_text_file`、查看器的 `read_file` 都得拒绝，外面的文件一个字节都不能动。
    #[test]
    fn links_inside_the_workspace_do_not_escape_read_or_write() {
        let dir = sandbox("link-escape");
        let outside = std::env::temp_dir().join(format!("acp-fs-outside-rw-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&outside);
        std::fs::create_dir_all(&outside).expect("mkdir");
        std::fs::write(outside.join("secret.txt"), "outside").expect("write");
        let link = dir.join("link-out");
        let linked = {
            #[cfg(windows)]
            {
                std::process::Command::new("cmd")
                    .args(["/c", "mklink", "/J"])
                    .arg(&link)
                    .arg(&outside)
                    .output()
                    .map(|o| o.status.success())
                    .unwrap_or(false)
            }
            #[cfg(not(windows))]
            {
                std::os::unix::fs::symlink(&outside, &link).is_ok()
            }
        };
        // 这是越界回归用例：建不出链接就得红，不能「环境不行就 return」让断言一行都不跑（审查第 2 轮 finding，2026-09-16）。
        assert!(linked, "cannot create the directory link this regression test depends on: {}", link.display());

        let target = link.join("secret.txt");
        assert!(matches!(read_text_file(&dir, &target, None, None), Err(FsError::OutsideWorkspace(_))));
        assert!(matches!(read_file(&dir, &target), Err(FsError::OutsideWorkspace(_))));
        assert!(matches!(write_text_file(&dir, &target, "changed"), Err(FsError::OutsideWorkspace(_))));
        // 在链接之下新建同样拒绝：父目录就是链接。
        assert!(matches!(write_text_file(&dir, &link.join("new.txt"), "x"), Err(FsError::OutsideWorkspace(_))));
        assert_eq!(std::fs::read_to_string(outside.join("secret.txt")).expect("read"), "outside");
        assert!(!outside.join("new.txt").exists());
        // 工作区里正常的文件照常能写能读。
        write_text_file(&dir, &dir.join("ok.txt"), "fine").expect("write inside");
        assert_eq!(read_text_file(&dir, &dir.join("ok.txt"), None, None).expect("read inside"), "fine");

        let _ = std::fs::remove_dir_all(&link);
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&outside);
    }

    /// [`resolve_inside`]（审查 finding，2026-09-22）：边界判定用解析过的真实路径，读写也按那一份开。
    /// 三条——① 工作区内的普通文件解出来仍在工作区内，且解出来的那份不含任何链接分量（读写按它走，末段
    /// 再被换成链接也没用）；② 末段是指向外面的链接时报越界 —— **这一条由 `ensure_inside` 的逐级
    /// `symlink_metadata` 拦下**（末段也在它的循环里），`canonicalize` 那条越界分支只在「逐级检查走完之后
    /// 才建出链接」的竞态窗口里走得到，用例造不出那个窗口、不覆盖它（复审 P2，2026-09-22）；
    /// ③ 还不存在的路径原样返回——不然 `fs/write_text_file` 新建文件就废了。
    #[test]
    fn resolve_inside_uses_the_real_path_and_still_lets_new_files_through() {
        let dir = sandbox("resolve");
        let outside = std::env::temp_dir().join(format!("acp-fs-outside-resolve-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&outside);
        std::fs::create_dir_all(&outside).expect("mkdir");
        std::fs::write(outside.join("secret.txt"), "outside").expect("write");

        // ① 普通文件：解出来在工作区内，逐级都不是链接。
        let inside = dir.join("nested").join("deep.txt");
        std::fs::create_dir_all(inside.parent().expect("parent")).expect("mkdir");
        std::fs::write(&inside, "fine").expect("write");
        let real = resolve_inside(&dir, &inside).expect("resolve inside");
        let root = std::fs::canonicalize(&dir).expect("canonicalize cwd");
        assert!(real.starts_with(&root), "{} 不在 {} 之内", real.display(), root.display());
        let mut cur = root.clone();
        for component in real.strip_prefix(&root).expect("strip").components() {
            cur.push(component);
            let meta = std::fs::symlink_metadata(&cur).expect("metadata of a resolved component");
            assert!(!is_link(&meta), "解析出来的路径里还有链接分量: {}", cur.display());
        }

        // ② 末段是指向工作区外的链接：报越界。建不出链接就得红（与上面那条越界用例同口径）。
        let link = dir.join("secret-link.txt");
        let linked = {
            #[cfg(windows)]
            {
                std::process::Command::new("cmd")
                    .args(["/c", "mklink"])
                    .arg(&link)
                    .arg(outside.join("secret.txt"))
                    .output()
                    .map(|o| o.status.success())
                    .unwrap_or(false)
            }
            #[cfg(not(windows))]
            {
                std::os::unix::fs::symlink(outside.join("secret.txt"), &link).is_ok()
            }
        };
        // 文件符号链接在 Windows 上要开发者模式或管理员（本地开发前置已要求开发者模式，见 CLAUDE.md「本地开发」）。
        assert!(linked, "cannot create a file symlink here (Windows 要开开发者模式)");
        assert!(matches!(resolve_inside(&dir, &link), Err(FsError::OutsideWorkspace(_))));
        assert!(matches!(read_text_file(&dir, &link, None, None), Err(FsError::OutsideWorkspace(_))));

        // ③ 还不存在的路径：原样返回，新建照常。
        let fresh = dir.join("nested").join("fresh.txt");
        assert_eq!(resolve_inside(&dir, &fresh).expect("resolve fresh"), fresh);
        write_text_file(&dir, &fresh, "new").expect("write new file");
        assert_eq!(read_text_file(&dir, &fresh, None, None).expect("read new file"), "new");
        // 已存在的文件按解析后的路径写回去，内容与位置都对。
        write_text_file(&dir, &inside, "changed").expect("overwrite");
        assert_eq!(std::fs::read_to_string(&inside).expect("read"), "changed");

        let _ = std::fs::remove_file(&link);
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

    /// 不设上限、整段在内存里的 [`read_lines`]：R4 的行口径用例照旧跑在流式实现上。
    fn slice_lines(text: &str, line: Option<u32>, limit: Option<u32>) -> Result<String> {
        read_lines(text.as_bytes(), line, limit, usize::MAX)
    }

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
        // 读过文件尾的报错带最后一行的行号与长度（Zed 的措辞）。
        let err = slice_lines("a\nbcd", Some(4), None).expect_err("beyond eof");
        assert_eq!(err, FsError::InvalidParams("Attempting to read beyond the end of the file, line 2:3".into()));
    }

    /// BACKLOG P0（2026-09-24）：回给 agent 的内容按字节设上限，超了回 invalid params；
    /// 带 `line` / `limit` 读一小段不受文件大小影响。读缓冲只有 3 字节，行与多字节字符都会被切在块边界上。
    #[test]
    fn read_lines_streams_in_small_chunks_and_caps_the_result() {
        let text = "第一行\n第二行\nthird\n";
        let chunked = |line, limit, cap| read_lines(std::io::BufReader::with_capacity(3, text.as_bytes()), line, limit, cap);
        assert_eq!(chunked(Some(2), Some(1), usize::MAX).expect("line 2"), "第二行\n");
        assert_eq!(chunked(None, None, usize::MAX).expect("all"), text);
        assert_eq!(chunked(Some(3), None, usize::MAX).expect("tail"), "third\n");
        // 上限卡的是回出去的内容，不是文件：整份超限，只读最后一行不超。
        let cap = "third\n".len();
        let err = chunked(None, None, cap).expect_err("over cap");
        assert!(matches!(&err, FsError::InvalidParams(m) if m.contains("line / limit")), "{err:?}");
        assert_eq!(chunked(Some(3), Some(1), cap).expect("fits"), "third\n");
        // 正好等于上限可以。
        assert_eq!(chunked(None, None, text.len()).expect("exactly cap"), text);
        // 不是 UTF-8 的字节照旧 lossy（坏字节跨块边界也一样）。
        let bad: &[u8] = b"ab\xff\xfecd\nok";
        let lossy = read_lines(std::io::BufReader::with_capacity(3, bad), None, None, usize::MAX).expect("lossy");
        assert_eq!(lossy, String::from_utf8_lossy(bad));
    }

    /// 真文件走一遍：超过 [`READ_TEXT_FILE_LIMIT`] 的文件整份读回 invalid params，带 `line` / `limit` 能读到它的任意一段。
    #[test]
    fn read_text_file_refuses_whole_reads_over_the_limit() {
        let dir = sandbox("big");
        let big = dir.join("big.log");
        let row = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde\n"; // 64 字节一行
        let rows = READ_TEXT_FILE_LIMIT / row.len() + 16;
        {
            use std::io::Write;
            let mut f = std::io::BufWriter::new(std::fs::File::create(&big).expect("create"));
            for _ in 0..rows {
                f.write_all(row.as_bytes()).expect("write");
            }
            f.write_all(b"LAST").expect("write");
        }
        let err = read_text_file(&dir, &big, None, None).expect_err("over limit");
        assert!(matches!(err, FsError::InvalidParams(_)), "{err:?}");
        assert_eq!(read_text_file(&dir, &big, Some(2), Some(2)).expect("window"), row.repeat(2));
        let last = u32::try_from(rows + 1).expect("row count fits u32");
        assert_eq!(read_text_file(&dir, &big, Some(last), None).expect("last line"), "LAST");
        let _ = std::fs::remove_dir_all(&dir);
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
