//! 项目目录的监视（画板 60 的文件树刷新；docs/design.md § 2「文件面板：`std::fs` + `notify`；不做索引服务」）。
//! `notify` 的原始事件在后台线程里去抖：一个窗口内所有变化归并成「受影响的目录」集合（每条变化路径的父目录；
//! 目录本身被建 / 删时也是它的父目录），再一次性交给回调。`IGNORED_DIRS`（`.git` / `node_modules` / `target` …）之下的
//! 变化整个跳过——那些目录本来就不进树，且 git 操作会在 `.git` 下打出成百条事件。
//! 回调另带一个 `git` 标志：`.git` 目录下有变化（切分支、提交、暂存）时为 true，前端据此刷新状态徽章而不重列树。
//! 两类 `.git` 事件不算：其下的 `*.lock`（git 每条命令都会建了又删的临时锁，`index.lock` 等）、以及落在 `.git`
//! 目录自己身上的（Windows 在目录里建删文件时会给该目录报一条 Modified）。两者都不是状态变化——真正的变化落在
//! 锁改名过去的那个文件上（`index` / `HEAD` / `refs/…`），事件另有。尤其 `git status` 自己就会建删一次
//! `index.lock`（连带一条 `.git` 的 Modified），而前端收到 `git` 标志的反应正是再跑一次 `git status`：不滤掉，
//! 徽章刷新会对着自己的锁文件无限空转（2026-09-22 实测：仓库零改动时每秒起 2–6 个 `git.exe`，风扇常转）。

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::Duration;

use notify::{RecursiveMode, Watcher};

use crate::{FsError, IGNORED_DIRS, Result};

/// 去抖窗口：第一条事件到达后再等这么久，把这段时间里的事件合并成一批。
pub const DEBOUNCE: Duration = Duration::from_millis(250);

/// 一批归并后的变化。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Changes {
    /// 内容有变化的目录（绝对路径，去重排序）。
    pub dirs: Vec<PathBuf>,
    /// `.git` 之下有变化：分支 / 暂存 / 提交状态可能变了。
    pub git: bool,
}

/// 一个监视器：drop 即停止（`notify` 的 watcher 随之 drop，后台线程在通道关闭后退出）。
pub struct DirWatcher {
    root: PathBuf,
    _watcher: notify::RecommendedWatcher,
}

impl std::fmt::Debug for DirWatcher {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DirWatcher").field("root", &self.root).finish_non_exhaustive()
    }
}

impl DirWatcher {
    /// 递归监视 `root`；每批变化经 `on_changes` 回调（在后台线程上调用，实现必须非阻塞且不能 panic）。
    /// 回调返回 false 表示接收方已经不要了（例如 Dart 侧取消了流），监视线程随之退出。
    pub fn start(root: &Path, on_changes: impl Fn(Changes) -> bool + Send + 'static) -> Result<Self> {
        if !root.is_absolute() || !root.is_dir() {
            return Err(FsError::InvalidParams(format!("watch root must be an absolute directory: {}", root.display())));
        }
        let (tx, rx) = mpsc::channel::<notify::Result<notify::Event>>();
        let mut watcher = notify::recommended_watcher(move |event| {
            let _ = tx.send(event);
        })
        .map_err(|e| FsError::Io(format!("notify: {e}")))?;
        watcher
            .watch(root, RecursiveMode::Recursive)
            .map_err(|e| FsError::Io(format!("notify watch {}: {e}", root.display())))?;
        let root_owned = root.to_path_buf();
        std::thread::Builder::new()
            .name(format!("fs-watch {}", root.display()))
            .spawn(move || debounce_loop(&root_owned, rx, on_changes))
            .map_err(|e| FsError::Io(format!("watch thread: {e}")))?;
        Ok(Self { root: root.to_path_buf(), _watcher: watcher })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }
}

/// 收原始事件、按 [`DEBOUNCE`] 归并、回调。通道关闭（watcher 被 drop）或回调说不要了就退出。
fn debounce_loop(root: &Path, rx: mpsc::Receiver<notify::Result<notify::Event>>, on_changes: impl Fn(Changes) -> bool) {
    loop {
        // 阻塞等第一条。
        let first = match rx.recv() {
            Ok(ev) => ev,
            Err(_) => return,
        };
        let mut batch = Changes::default();
        let mut dirs = BTreeSet::new();
        fold(root, first, &mut dirs, &mut batch);
        // 去抖窗口内继续收。
        let deadline = std::time::Instant::now() + DEBOUNCE;
        loop {
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            if left.is_zero() {
                break;
            }
            match rx.recv_timeout(left) {
                Ok(ev) => fold(root, ev, &mut dirs, &mut batch),
                Err(mpsc::RecvTimeoutError::Timeout) => break,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }
        batch.dirs = dirs.into_iter().collect();
        if (!batch.dirs.is_empty() || batch.git) && !on_changes(batch) {
            return;
        }
    }
}

/// 把一条原始事件折进批：每条路径取父目录；`.git` 之下只打 git 标志；其他 [`IGNORED_DIRS`] 之下的整条跳过。
fn fold(root: &Path, event: notify::Result<notify::Event>, dirs: &mut BTreeSet<PathBuf>, batch: &mut Changes) {
    let Ok(event) = event else {
        // 监视器自身的错误（例如缓冲溢出）：保守起见让前端整棵重列。
        dirs.insert(root.to_path_buf());
        return;
    };
    for path in event.paths {
        match classify(root, &path) {
            Class::Git => batch.git = true,
            Class::Ignored => {}
            Class::Tracked => {
                let dir = path.parent().unwrap_or(root).to_path_buf();
                dirs.insert(if dir.starts_with(root) { dir } else { root.to_path_buf() });
            }
        }
    }
}

enum Class {
    Tracked,
    Git,
    Ignored,
}

/// 逐层看相对 root 的路径分量：`.git` → git（目录自己身上的事件与其下的 `*.lock` 跳过，见模块头注）；
/// 其他忽略目录 → 跳过；其余 → 进树。任何一层命中都算，所以嵌套的 `node_modules` 同样被跳过。
fn classify(root: &Path, path: &Path) -> Class {
    let Ok(rel) = path.strip_prefix(root) else {
        return Class::Tracked;
    };
    for component in rel.components() {
        let name = component.as_os_str().to_string_lossy();
        if name == ".git" {
            let dir_itself = rel.file_name().is_some_and(|n| n == ".git");
            return if dir_itself || is_lock_file(path) { Class::Ignored } else { Class::Git };
        }
        if IGNORED_DIRS.contains(&name.as_ref()) {
            return Class::Ignored;
        }
    }
    Class::Tracked
}

/// git 的临时锁文件：`index.lock`、`HEAD.lock`、`refs/heads/x.lock` …（扩展名一律是 `lock`）。
fn is_lock_file(path: &Path) -> bool {
    matches!(path.extension(), Some(ext) if ext == "lock")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    fn temp(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("acp-fs-watch-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("src")).expect("mkdir");
        std::fs::create_dir_all(dir.join(".git")).expect("mkdir");
        std::fs::create_dir_all(dir.join("node_modules").join("x")).expect("mkdir");
        dir
    }

    fn wait_for(batches: &Arc<Mutex<Vec<Changes>>>, pred: impl Fn(&[Changes]) -> bool) -> bool {
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while std::time::Instant::now() < deadline {
            if pred(&batches.lock().expect("lock")) {
                return true;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        false
    }

    /// 规则 9 的实测点：Windows 的 ReadDirectoryChangesW 经 notify 报出「文件在哪个目录下变了」，
    /// `.git` 只打标志，`node_modules` 之下的整条跳过。
    #[test]
    fn reports_parent_dirs_and_git_flag_but_skips_ignored() {
        let dir = temp("basic");
        let batches: Arc<Mutex<Vec<Changes>>> = Arc::new(Mutex::new(Vec::new()));
        let sink = batches.clone();
        let watcher = DirWatcher::start(&dir, move |c| {
            sink.lock().expect("lock").push(c);
            true
        })
        .expect("start");
        assert_eq!(watcher.root(), dir.as_path());
        // 监视器就位需要一点时间（Windows 上 ReadDirectoryChangesW 是异步挂起的）。
        std::thread::sleep(Duration::from_millis(200));

        std::fs::write(dir.join("src").join("a.rs"), "fn main() {}").expect("write");
        assert!(
            wait_for(&batches, |b| b.iter().any(|c| c.dirs.iter().any(|d| d.ends_with("src")))),
            "src change never reported: {:?}",
            batches.lock().expect("lock")
        );

        std::fs::write(dir.join(".git").join("HEAD"), "ref: refs/heads/main").expect("write");
        assert!(wait_for(&batches, |b| b.iter().any(|c| c.git)), "git flag never set");
        // `.git` 下的路径不进 dirs。
        assert!(batches.lock().expect("lock").iter().all(|c| c.dirs.iter().all(|d| !d.to_string_lossy().contains(".git"))));

        let before = batches.lock().expect("lock").len();
        std::fs::write(dir.join("node_modules").join("x").join("index.js"), "//").expect("write");
        std::thread::sleep(DEBOUNCE * 3);
        let after = batches.lock().expect("lock");
        assert!(after[before..].iter().all(|c| c.dirs.is_empty() && !c.git), "ignored dir leaked: {:?}", &after[before..]);
        drop(after);

        drop(watcher);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 2026-09-22 的空转：`git status` 自己建删 `.git/index.lock`，锁文件的事件不得打 `git` 标志，
    /// 否则前端刷新徽章 → 再跑 `git status` → 再来一批事件，无限循环。锁改名成真文件（`index`）时照常打。
    #[test]
    fn git_lock_files_do_not_set_the_git_flag() {
        let dir = temp("lock");
        let batches: Arc<Mutex<Vec<Changes>>> = Arc::new(Mutex::new(Vec::new()));
        let sink = batches.clone();
        let watcher = DirWatcher::start(&dir, move |c| {
            sink.lock().expect("lock").push(c);
            true
        })
        .expect("start");
        std::thread::sleep(Duration::from_millis(200));

        // 模拟 `git status`：建锁、写、删锁，来三轮。
        let lock = dir.join(".git").join("index.lock");
        for _ in 0..3 {
            std::fs::write(&lock, "DIRC").expect("write lock");
            std::fs::remove_file(&lock).expect("remove lock");
            std::thread::sleep(Duration::from_millis(50));
        }
        std::thread::sleep(DEBOUNCE * 3);
        {
            let got = batches.lock().expect("lock");
            assert!(got.iter().all(|c| !c.git && c.dirs.is_empty()), "lock file leaked as a change: {:?}", *got);
        }

        // 锁改名成真文件才是一次变化。
        std::fs::write(&lock, "DIRC").expect("write lock");
        std::fs::rename(&lock, dir.join(".git").join("index")).expect("rename");
        assert!(wait_for(&batches, |b| b.iter().any(|c| c.git)), "index rename never set the git flag");

        drop(watcher);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 用真的 git 再证一次：稳态仓库上连跑 `git status`（与 `git_status` 同参数）不得打 `git` 标志。
    /// git 不在 PATH 时跳过（与 git.rs 的测试同一口径）；屏蔽用户的全局配置，免得 fsmonitor 之类介入。
    #[test]
    fn real_git_status_does_not_set_the_git_flag() {
        let dir = temp("real-git");
        let _ = std::fs::remove_dir_all(dir.join(".git"));
        let run = |args: &[&str]| {
            std::process::Command::new("git")
                .arg("-C")
                .arg(&dir)
                .args(args)
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .env("GIT_CONFIG_GLOBAL", dir.join("no-global-gitconfig"))
                .output()
        };
        let Ok(init) = run(&["init", "-q"]) else {
            eprintln!("git not on PATH; skipping");
            return;
        };
        assert!(init.status.success(), "git init: {}", String::from_utf8_lossy(&init.stderr));
        std::fs::write(dir.join("src").join("a.rs"), "fn main() {}").expect("write");
        // racy git：文件 mtime 与索引 mtime 同一秒时，git 每次 status 都会补写一回索引（改名 `index.lock → index`，
        // 那是真变化，照常打标志），直到时钟跨过整秒——让文件比索引老一秒，稳态才是「只建删锁」。
        std::thread::sleep(Duration::from_millis(1100));
        assert!(run(&["add", "."]).expect("git").status.success());
        let commit = run(&["-c", "user.name=acp", "-c", "user.email=acp@test", "commit", "-q", "-m", "init"]).expect("git");
        assert!(commit.status.success(), "git commit: {}", String::from_utf8_lossy(&commit.stderr));
        // 再跑一次 status 让索引的 stat 信息落定，之后才开监视。
        let status_args = ["status", "--porcelain=v1", "-z", "--untracked-files=all"];
        assert!(run(&status_args).expect("git").status.success());

        let batches: Arc<Mutex<Vec<Changes>>> = Arc::new(Mutex::new(Vec::new()));
        let sink = batches.clone();
        let watcher = DirWatcher::start(&dir, move |c| {
            sink.lock().expect("lock").push(c);
            true
        })
        .expect("start");
        std::thread::sleep(Duration::from_millis(200));

        for _ in 0..3 {
            assert!(run(&status_args).expect("git").status.success());
        }
        std::thread::sleep(DEBOUNCE * 3);
        {
            let got = batches.lock().expect("lock");
            assert!(got.iter().all(|c| !c.git && c.dirs.is_empty()), "git status reported as a change: {:?}", *got);
        }

        drop(watcher);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn rejects_relative_or_missing_root() {
        assert!(matches!(DirWatcher::start(Path::new("relative"), |_| true), Err(FsError::InvalidParams(_))));
        let missing = std::env::temp_dir().join("acp-fs-watch-missing-dir-that-does-not-exist");
        assert!(matches!(DirWatcher::start(&missing, |_| true), Err(FsError::InvalidParams(_))));
    }

    #[test]
    fn classify_by_components() {
        let root = Path::new(if cfg!(windows) { r"D:\ws" } else { "/ws" });
        assert!(matches!(classify(root, &root.join(".git").join("index")), Class::Git));
        assert!(matches!(classify(root, &root.join(".git").join("HEAD")), Class::Git));
        // git 的临时锁与 `.git` 目录自己身上的事件不算 `.git` 的变化（模块头注：否则 `git status` 会把徽章刷新推成死循环）。
        assert!(matches!(classify(root, &root.join(".git").join("index.lock")), Class::Ignored));
        assert!(matches!(classify(root, &root.join(".git").join("refs").join("heads").join("main.lock")), Class::Ignored));
        assert!(matches!(classify(root, &root.join(".git")), Class::Ignored));
        assert!(matches!(classify(root, &root.join("sub").join(".git")), Class::Ignored));
        assert!(matches!(classify(root, &root.join("target").join("debug").join("x")), Class::Ignored));
        assert!(matches!(classify(root, &root.join("src").join("lib.rs")), Class::Tracked));
        assert!(matches!(classify(root, &root.join("src").join("node_modules").join("y")), Class::Ignored));
    }
}
