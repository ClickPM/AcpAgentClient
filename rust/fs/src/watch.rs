//! 项目目录的监视（画板 60 的文件树刷新；docs/design.md § 2「文件面板：`std::fs` + `notify`；不做索引服务」）。
//! `notify` 的原始事件在后台线程里去抖：一个窗口内所有变化归并成「受影响的目录」集合（每条变化路径的父目录；
//! 目录本身被建 / 删时也是它的父目录），再一次性交给回调。`IGNORED_DIRS`（`.git` / `node_modules` / `target` …）之下的
//! 变化整个跳过——那些目录本来就不进树，且 git 操作会在 `.git` 下打出成百条事件。
//! 回调另带一个 `git` 标志：`.git` 目录下有变化（切分支、提交、暂存）时为 true，前端据此刷新状态徽章而不重列树。

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
        let root_owned = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
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

/// 按相对 root 的第一层分量归类：`.git` → git；其他忽略目录 → 跳过；其余 → 进树。
fn classify(root: &Path, path: &Path) -> Class {
    let Ok(rel) = path.strip_prefix(root) else {
        return Class::Tracked;
    };
    for component in rel.components() {
        let name = component.as_os_str().to_string_lossy();
        if name == ".git" {
            return Class::Git;
        }
        if IGNORED_DIRS.contains(&name.as_ref()) {
            return Class::Ignored;
        }
    }
    Class::Tracked
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

    #[test]
    fn rejects_relative_or_missing_root() {
        assert!(matches!(DirWatcher::start(Path::new("relative"), |_| true), Err(FsError::InvalidParams(_))));
        let missing = std::env::temp_dir().join("acp-fs-watch-missing-dir-that-does-not-exist");
        assert!(matches!(DirWatcher::start(&missing, |_| true), Err(FsError::InvalidParams(_))));
    }

    #[test]
    fn classify_by_first_component() {
        let root = Path::new(if cfg!(windows) { r"D:\ws" } else { "/ws" });
        assert!(matches!(classify(root, &root.join(".git").join("index")), Class::Git));
        assert!(matches!(classify(root, &root.join("target").join("debug").join("x")), Class::Ignored));
        assert!(matches!(classify(root, &root.join("src").join("lib.rs")), Class::Tracked));
        assert!(matches!(classify(root, &root.join("src").join("node_modules").join("y")), Class::Ignored));
    }
}
