//! git CLI 子进程薄封装（docs/design.md § 2 / § 9，所有者裁定 2026-09-15：不引 `git2` / `gix`）。
//! 只读 + 两个写操作（`git switch` / `git switch -c`），都在用户自己的工作区里，不碰 `.git` 内部文件（CLAUDE.md 规则 7）。
//! 找不到 `git` 可执行文件、或目录不是仓库时，返回的 [`BranchList`] 里 `available` / `is_repo` 为 false，
//! 前端据此把顶栏的分支区整块隐藏。
//!
//! Windows（规则 9）：一律用 `-C <path>` 传目录、参数直接进 `Command`（不过 shell），
//! 所以路径里的空格与中文不需要引号处理。

use std::path::Path;
use std::process::Command;

use serde::Serialize;

use crate::{FsError, Result};

/// 一条本地分支（画板 41 的两行菜单项）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Branch {
    pub name: String,
    pub author: String,
    /// `committerdate:relative`，例如 `3 days ago`。
    pub when: String,
    pub subject: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BranchList {
    /// 本机能不能找到 `git`。
    pub available: bool,
    /// 目录是不是 git 工作区。
    pub is_repo: bool,
    /// 当前分支；detached HEAD 时是 `HEAD`。
    pub current: Option<String>,
    pub branches: Vec<Branch>,
}

impl BranchList {
    fn unavailable() -> Self {
        Self { available: false, is_repo: false, current: None, branches: Vec::new() }
    }

    fn not_a_repo() -> Self {
        Self { available: true, is_repo: false, current: None, branches: Vec::new() }
    }
}

/// `git diff` 的结果（输入框 `+` 的 Branch Diff）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Diff {
    pub available: bool,
    pub is_repo: bool,
    /// 实际跑的参数（放进 embedded resource 的说明里，让用户知道 diff 的口径）。
    pub command: String,
    pub text: String,
    /// 超过 [`DIFF_LIMIT`] 字节时截断。
    pub truncated: bool,
}

/// Branch Diff 的输出上限：超出截断（整份 diff 进 prompt 会顶爆上下文）。
pub const DIFF_LIMIT: usize = 200 * 1024;

/// `for-each-ref` 的字段分隔符：用 `\x1f`（单元分隔符），提交主题里不会出现。
const SEP: char = '\u{1f}';

struct Output {
    ok: bool,
    stdout: String,
    stderr: String,
}

/// 跑一条 git 命令。`Ok(None)` = 本机没有 `git`。
fn git(cwd: &Path, args: &[&str]) -> Result<Option<Output>> {
    let mut command = Command::new("git");
    // `core.quotepath=false`：否则含中文的路径在 diff / status 里是 `"è¯´..."` 这种八进制转义，
    // 用户看不懂，塞进 prompt 的 Branch Diff 也读不出来（R3 实测）。只对本次调用生效，不改用户配置（规则 7）。
    command.arg("-c").arg("core.quotepath=false");
    command.arg("-C").arg(cwd);
    for a in args {
        command.arg(a);
    }
    match command.output() {
        Ok(out) => Ok(Some(Output {
            ok: out.status.success(),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        })),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(FsError::Io(format!("git: {e}"))),
    }
}

fn is_repo(cwd: &Path) -> Result<Option<bool>> {
    match git(cwd, &["rev-parse", "--is-inside-work-tree"])? {
        None => Ok(None),
        Some(out) => Ok(Some(out.ok && out.stdout.trim() == "true")),
    }
}

fn current_branch(cwd: &Path) -> Result<Option<String>> {
    let Some(out) = git(cwd, &["rev-parse", "--abbrev-ref", "HEAD"])? else {
        return Ok(None);
    };
    if !out.ok {
        return Ok(None);
    }
    let name = out.stdout.trim().to_string();
    Ok(if name.is_empty() { None } else { Some(name) })
}

/// 本地分支列表 + 当前分支（画板 41 的分支切换弹层）。
pub fn branches(cwd: &Path) -> Result<BranchList> {
    match is_repo(cwd)? {
        None => return Ok(BranchList::unavailable()),
        Some(false) => return Ok(BranchList::not_a_repo()),
        Some(true) => {}
    }
    let format = format!("--format=%(refname:short){SEP}%(authorname){SEP}%(committerdate:relative){SEP}%(contents:subject)");
    let Some(out) = git(cwd, &["for-each-ref", "--sort=-committerdate", &format, "refs/heads"])? else {
        return Ok(BranchList::unavailable());
    };
    let mut branches = Vec::new();
    if out.ok {
        for line in out.stdout.lines() {
            if line.trim().is_empty() {
                continue;
            }
            let mut parts = line.split(SEP);
            let name = parts.next().unwrap_or_default().to_string();
            if name.is_empty() {
                continue;
            }
            branches.push(Branch {
                name,
                author: parts.next().unwrap_or_default().to_string(),
                when: parts.next().unwrap_or_default().to_string(),
                subject: parts.next().unwrap_or_default().to_string(),
            });
        }
    }
    Ok(BranchList { available: true, is_repo: true, current: current_branch(cwd)?, branches })
}

/// `git switch <name>`。失败时把 git 自己的 stderr 原样带出（例如「本地有未提交改动」）。
pub fn switch(cwd: &Path, name: &str) -> Result<BranchList> {
    run_switch(cwd, &["switch", name])
}

/// `git switch -c <name>`（从当前 HEAD 拉一条新分支）。
pub fn create_branch(cwd: &Path, name: &str) -> Result<BranchList> {
    run_switch(cwd, &["switch", "-c", name])
}

fn run_switch(cwd: &Path, args: &[&str]) -> Result<BranchList> {
    let Some(out) = git(cwd, args)? else {
        return Err(FsError::GitUnavailable);
    };
    if !out.ok {
        let msg = if out.stderr.trim().is_empty() { out.stdout } else { out.stderr };
        return Err(FsError::Git(msg.trim().to_string()));
    }
    branches(cwd)
}

/// `git diff`：给了 `base` 就是 `git diff <base>...HEAD`（三点：与共同祖先比），否则是工作区相对 HEAD 的改动。
pub fn diff(cwd: &Path, base: Option<&str>) -> Result<Diff> {
    match is_repo(cwd)? {
        None => {
            return Ok(Diff {
                available: false,
                is_repo: false,
                command: String::new(),
                text: String::new(),
                truncated: false,
            });
        }
        Some(false) => {
            return Ok(Diff {
                available: true,
                is_repo: false,
                command: String::new(),
                text: String::new(),
                truncated: false,
            });
        }
        Some(true) => {}
    }
    let range = base.map(|b| format!("{b}...HEAD"));
    let args: Vec<&str> = match range.as_deref() {
        Some(r) => vec!["diff", r],
        None => vec!["diff", "HEAD"],
    };
    let Some(out) = git(cwd, &args)? else {
        return Err(FsError::GitUnavailable);
    };
    if !out.ok {
        let msg = if out.stderr.trim().is_empty() { out.stdout } else { out.stderr };
        return Err(FsError::Git(msg.trim().to_string()));
    }
    let mut text = out.stdout;
    let truncated = text.len() > DIFF_LIMIT;
    if truncated {
        // 按字符边界截断，别把多字节字符切一半。
        let mut end = DIFF_LIMIT;
        while end > 0 && !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
    }
    Ok(Diff {
        available: true,
        is_repo: true,
        command: format!("git diff {}", args[1..].join(" ")),
        text,
        truncated,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 本仓库自己就是 git 工作区：分支列表里至少有当前分支，且 `current` 在列表里。
    #[test]
    fn branches_of_this_repo() {
        let cwd = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        let list = branches(&cwd).expect("branches");
        if !list.available {
            eprintln!("git not on PATH; skipping");
            return;
        }
        assert!(list.is_repo, "repo root should be a work tree");
        let current = list.current.clone().expect("current branch");
        assert!(list.branches.iter().any(|b| b.name == current), "current {current} not in {:?}", list.branches);
    }

    /// 规则 9：路径含空格与中文时也要能工作（`-C <path>` 走参数、不过 shell，所以不需要引号处理）。
    #[test]
    fn works_with_spaces_and_non_ascii_in_path() {
        let dir = std::env::temp_dir().join(format!("acp git 仓库 测试-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("mkdir");
        let run = |args: &[&str]| {
            Command::new("git").arg("-C").arg(&dir).args(args).output()
        };
        let Ok(init) = run(&["init", "-q", "-b", "main"]) else {
            eprintln!("git not on PATH; skipping");
            let _ = std::fs::remove_dir_all(&dir);
            return;
        };
        assert!(init.status.success(), "git init failed: {}", String::from_utf8_lossy(&init.stderr));
        // 提交需要身份；只设仓库级配置，不碰用户的全局配置（规则 7）。
        let _ = run(&["config", "user.name", "acp-test"]);
        let _ = run(&["config", "user.email", "acp-test@example.invalid"]);
        std::fs::write(dir.join("说明.md"), "内容").expect("write");
        let _ = run(&["add", "-A"]);
        let commit = run(&["commit", "-q", "-m", "初始提交"]).expect("commit");
        assert!(commit.status.success(), "git commit failed: {}", String::from_utf8_lossy(&commit.stderr));

        let list = branches(&dir).expect("branches");
        assert!(list.is_repo);
        assert_eq!(list.current.as_deref(), Some("main"));
        assert!(list.branches.iter().any(|b| b.name == "main"));

        let after = create_branch(&dir, "功能/新分支").expect("create branch");
        assert_eq!(after.current.as_deref(), Some("功能/新分支"));
        assert!(after.branches.iter().any(|b| b.name == "功能/新分支"));

        std::fs::write(dir.join("说明.md"), "改过的内容").expect("write");
        let d = diff(&dir, None).expect("diff");
        assert!(d.is_repo && !d.truncated);
        assert!(d.text.contains("说明.md"), "diff should mention the changed file: {}", d.text);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 不是仓库的目录：`is_repo` 为 false，前端据此隐藏分支区。
    #[test]
    fn non_repo_dir_reports_not_a_repo() {
        let dir = std::env::temp_dir().join(format!("acp-git-nonrepo-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("mkdir");
        let list = branches(&dir).expect("branches");
        if list.available {
            assert!(!list.is_repo);
            assert!(list.branches.is_empty());
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
