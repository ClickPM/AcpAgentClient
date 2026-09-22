//! Node 运行时：系统 Node ≥ 22 的检测，缺失时下载受管 Node v24.11.0 到数据目录 `node/`（docs/design.md § 6 第 4 条）。
//! Derived from zed-industries/zed crates/node_runtime/src/node_runtime.rs @ d9e1c024f393832765a03f4de204d6c8cd9abcb2 (GPL-3.0-or-later)
//! （参考转写 `SystemNodeRuntime::detect` / `ManagedNodeRuntime::install_if_needed` / `npm_command_env`：nodejs.org 官方包、
//! 按平台取 zip / tar.gz、装好后以 `node --version` 自检、npm 用受管目录里的 `npm-cli.js` 并带空的 npmrc；
//! 不直接链接 Zed 的 crate 的理由见 R5 任务卡「偏离」。）

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde::Serialize;

use crate::{CancelToken, Progress, ProgressSink, RegistryDirs, RegistryError, Result, archive, command, download, resolve_program};

pub const MANAGED_VERSION: &str = "v24.11.0";
pub const MIN_MAJOR: u64 = 22;
pub const MIN_VERSION: &str = "22.0.0";

/// 一份可用的 Node（系统的或受管的）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NodeInfo {
    pub version: String,
    pub path: String,
}

/// `node_status` 的结果。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct NodeStatus {
    pub system: Option<NodeInfo>,
    /// 系统 Node 在但不可用（版本不够 / 跑不起来）时的说明。
    pub system_error: Option<String>,
    pub managed: Option<NodeInfo>,
    pub min_version: &'static str,
}

/// 拉起 npx 型 agent / 跑 npm 用的一份 Node。
#[derive(Debug, Clone)]
pub struct NodeRuntime {
    pub node: PathBuf,
    pub npm: Npm,
    pub managed: bool,
}

#[derive(Debug, Clone)]
pub enum Npm {
    /// 系统的 `npm`（Windows 上是 `npm.cmd`）。
    System(PathBuf),
    /// 受管：`node <npm-cli.js> …`，带受管目录里的 cache 与空 npmrc（不碰用户的 `~/.npmrc`）。
    ManagedCli { cli: PathBuf, root: PathBuf },
}

fn parse_major(version: &str) -> Option<u64> {
    version.trim().trim_start_matches('v').split('.').next()?.parse().ok()
}

/// 跑 `node --version`，返回 `vX.Y.Z`。
async fn node_version(node: &Path) -> Result<String> {
    let output = command(node).arg("--version").output().await.map_err(|e| RegistryError::Node(format!("{}: {e}", node.display())))?;
    if !output.status.success() {
        return Err(RegistryError::Node(format!("{} --version 退出 {:?}", node.display(), output.status.code())));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn managed_layout(dirs: &RegistryDirs) -> (PathBuf, PathBuf, PathBuf) {
    let (os, arch) = platform_names();
    let root = dirs.node_dir().join(format!("node-{MANAGED_VERSION}-{os}-{arch}"));
    let (node, npm_cli) = if cfg!(windows) {
        (root.join("node.exe"), root.join("node_modules").join("npm").join("bin").join("npm-cli.js"))
    } else {
        (root.join("bin").join("node"), root.join("lib").join("node_modules").join("npm").join("bin").join("npm-cli.js"))
    };
    (root, node, npm_cli)
}

/// nodejs.org 的平台命名（`win` / `darwin` / `linux` × `x64` / `arm64`）。
fn platform_names() -> (&'static str, &'static str) {
    let os = match std::env::consts::OS {
        "windows" => "win",
        "macos" => "darwin",
        other => other,
    };
    let arch = match std::env::consts::ARCH {
        "x86_64" => "x64",
        "aarch64" => "arm64",
        other => other,
    };
    (os, arch)
}

/// 系统 Node 的一次探测结果：`(可用的那份, 不可用的说明)`。
type SystemNode = (Option<NodeInfo>, Option<String>);

/// 系统 Node 的探测缓存。PATH 上的 `node` 在客户端一次运行里不会变，而 `node --version` 在 Windows 上
/// 是一次 ~30ms 的进程冷启动，每条 `agent_connect`（→ `registry_launch` → [`locate`]）都要付一遍。
/// [`locate`] 读这份缓存，[`status`]（画板 51 的 Node 状态与它的刷新）仍每次实探并回填——
/// 用户中途装了 Node，刷一下状态就能被下一次拉起认出来。
static SYSTEM_NODE: Mutex<Option<SystemNode>> = Mutex::new(None);

/// 实探 PATH 上的 `node`：跑得起来且 ≥ 22 才算可用，否则给一句说明（画板 51 显示它）。
async fn probe_system() -> SystemNode {
    let node = resolve_program("node");
    if !node.is_file() {
        return (None, None);
    }
    match node_version(&node).await {
        Ok(version) => {
            if parse_major(&version).unwrap_or(0) >= MIN_MAJOR {
                (Some(NodeInfo { version, path: node.to_string_lossy().into_owned() }), None)
            } else {
                (None, Some(format!("{version} · {}（需要 ≥ {MIN_MAJOR}）", node.display())))
            }
        }
        Err(e) => (None, Some(e.to_string())),
    }
}

/// 锁只在取 / 放的一瞬间持有，不跨 await（中毒的锁按「没缓存」处理，退化成每次实探）。
fn cached_system() -> Option<SystemNode> {
    SYSTEM_NODE.lock().ok().and_then(|slot| slot.clone())
}

fn store_system(probed: &SystemNode) {
    if let Ok(mut slot) = SYSTEM_NODE.lock() {
        *slot = Some(probed.clone());
    }
}

/// 系统 Node（PATH 上的 `node`）与受管 Node 各查一次。总是实探，顺带把系统那份回填进缓存。
pub async fn status(dirs: &RegistryDirs) -> NodeStatus {
    let probed = probe_system().await;
    store_system(&probed);
    let (system, system_error) = probed;
    let mut status = NodeStatus { system, system_error, min_version: MIN_VERSION, ..Default::default() };
    let (_, managed_node, _) = managed_layout(dirs);
    if managed_node.is_file()
        && let Ok(version) = node_version(&managed_node).await
    {
        status.managed = Some(NodeInfo { version, path: managed_node.to_string_lossy().into_owned() });
    }
    status
}

/// 优先系统 Node ≥ 22，再受管 Node；都没有报 `Node`（前端据此出画板 51 的受管 Node 提示卡）。
/// 系统那份走缓存；受管那份只在系统 Node 用不上时才探——常见路径上因此一个子进程都不拉。
pub async fn locate(dirs: &RegistryDirs) -> Result<NodeRuntime> {
    // 缓存命中也复核一下那条路径还在不在：用户中途卸载 / nvm 切走了 Node，别拿过期路径去拉子进程
    // （审查 P3，2026-09-22）。不可用那一档（None）仍只由 [`status`] 刷新。
    let cached = cached_system().filter(|(system, _)| system.as_ref().is_none_or(|s| Path::new(&s.path).is_file()));
    let (system, system_error) = match cached {
        Some(hit) => hit,
        None => {
            let probed = probe_system().await;
            store_system(&probed);
            probed
        }
    };
    if let Some(system) = system {
        let npm = resolve_program("npm");
        if npm.is_file() {
            return Ok(NodeRuntime { node: PathBuf::from(system.path), npm: Npm::System(npm), managed: false });
        }
    }
    let (root, managed_node, cli) = managed_layout(dirs);
    if managed_node.is_file() && node_version(&managed_node).await.is_ok() {
        return Ok(NodeRuntime { node: managed_node, npm: Npm::ManagedCli { cli, root }, managed: true });
    }
    Err(RegistryError::Node(match system_error {
        Some(e) => format!("系统 Node 不可用（{e}），也没有受管 Node"),
        None => format!("未检测到 Node ≥ {MIN_MAJOR}，也没有受管 Node"),
    }))
}

impl NodeRuntime {
    /// 拉起 npx 型 agent 时给它的环境：PATH 前面插 node 所在目录（agent 自己再拉 npm / npx 时用同一份 Node）。
    pub fn env_overrides(&self) -> Vec<(String, String)> {
        let mut out = Vec::new();
        if let Some(dir) = self.node.parent() {
            let existing = std::env::var_os("PATH").unwrap_or_default();
            let joined = std::env::join_paths(std::iter::once(dir.to_path_buf()).chain(std::env::split_paths(&existing)))
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_else(|_| existing.to_string_lossy().into_owned());
            out.push(("PATH".to_string(), joined));
        }
        out
    }

    /// `npm <subcommand> <args…>`，在 `cwd` 里跑；失败时错误带输出尾巴。取消时结束 npm。
    pub async fn run_npm(&self, cwd: &Path, args: &[String], cancel: &CancelToken) -> Result<String> {
        let mut cmd = match &self.npm {
            Npm::System(npm) => {
                let mut c = command(npm);
                c.args(args);
                c
            }
            Npm::ManagedCli { cli, root } => {
                let cache = root.join("cache");
                let _ = std::fs::create_dir_all(&cache);
                let blank_user = root.join("blank_user_npmrc");
                let blank_global = root.join("blank_global_npmrc");
                let _ = std::fs::write(&blank_user, b"");
                let _ = std::fs::write(&blank_global, b"");
                let mut c = command(&self.node);
                c.arg(cli).args(args).arg("--cache").arg(&cache).arg("--userconfig").arg(&blank_user).arg("--globalconfig").arg(&blank_global);
                c
            }
        };
        cmd.current_dir(cwd);
        for (k, v) in self.env_overrides() {
            cmd.env(k, v);
        }
        let mut child = cmd.spawn().map_err(|e| RegistryError::Npm(format!("拉不起 npm：{e}")))?;
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        // stdout 与 stderr 并发读：顺序读会在 npm 往另一路灌满管道缓冲时死锁。
        let read = async { tokio::join!(read_all(stdout), read_all(stderr)) };
        // 取消分支不碰 child（两个分支同时可变借用编不过），select 出来再结束进程树。
        let outcome = tokio::select! {
            r = async { let output = read.await; (child.wait().await, output) } => Some(r),
            _ = cancel.cancelled() => None,
        };
        let Some((status, (out, err))) = outcome else {
            kill_tree(&mut child).await;
            return Err(RegistryError::Cancelled);
        };
        let status = status.map_err(|e| RegistryError::Npm(format!("等 npm 退出：{e}")))?;
        if !status.success() {
            let combined = if err.trim().is_empty() { out } else { err };
            return Err(RegistryError::Npm(crate::tail(&combined, 4096)));
        }
        Ok(out)
    }
}

async fn read_all<R: tokio::io::AsyncRead + Unpin>(reader: Option<R>) -> String {
    let mut out = String::new();
    if let Some(mut r) = reader {
        let _ = tokio::io::AsyncReadExt::read_to_string(&mut r, &mut out).await;
    }
    out
}

/// 结束整棵进程树（`npm.cmd` 是 `cmd.exe` 包装，杀它不带 node 子进程；照 acp-core 的做法用 `taskkill /T`）。
pub async fn kill_tree(child: &mut tokio::process::Child) {
    #[cfg(windows)]
    if let Some(pid) = child.id() {
        let _ = command("taskkill").args(["/F", "/T", "/PID", &pid.to_string()]).output().await;
    }
    let _ = child.start_kill();
    let _ = child.wait().await;
}

/// 受管 Node：下载 nodejs.org 的官方包到 `node/`，解压，`node --version` 自检。已经好的直接返回。
pub async fn download_managed(dirs: &RegistryDirs, http: &reqwest::Client, cancel: Arc<CancelToken>, sink: &dyn ProgressSink) -> Result<NodeInfo> {
    let (root, node, _) = managed_layout(dirs);
    if node.is_file()
        && let Ok(version) = node_version(&node).await
    {
        sink.progress(Progress::new(None, "node", "done"));
        return Ok(NodeInfo { version, path: node.to_string_lossy().into_owned() });
    }
    let (os, arch) = platform_names();
    let ext = if cfg!(windows) { "zip" } else { "tar.gz" };
    let file_name = format!("node-{MANAGED_VERSION}-{os}-{arch}.{ext}");
    let url = format!("https://nodejs.org/dist/{MANAGED_VERSION}/{file_name}");
    let node_dir = dirs.node_dir();
    let staging = node_dir.join(format!(".staging-{}", crate::now_ms()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&staging)?;
    let result: Result<NodeInfo> = async {
        let archive_path = staging.join(&file_name);
        let detail = file_name.clone();
        download::download_to_file(http, &url, &archive_path, &cancel, |done, total| {
            sink.progress(Progress::new(None, "node", "node_download").detail(detail.clone()).bytes(done, total));
        })
        .await?;
        cancel.check()?;
        sink.progress(Progress::new(None, "node", "node_extract").detail(root.to_string_lossy().into_owned()));
        let kind = if cfg!(windows) { archive::ArchiveKind::Zip } else { archive::ArchiveKind::TarGz };
        archive::extract(&kind, &archive_path, &node_dir).await?;
        let _ = std::fs::remove_file(&archive_path);
        let version = node_version(&node).await.map_err(|e| RegistryError::Node(format!("受管 Node 自检失败：{e}")))?;
        Ok(NodeInfo { version, path: node.to_string_lossy().into_owned() })
    }
    .await;
    let _ = std::fs::remove_dir_all(&staging);
    match result {
        Ok(info) => {
            sink.progress(Progress::new(None, "node", "done"));
            Ok(info)
        }
        Err(e) => {
            let _ = std::fs::remove_dir_all(&root);
            let step = if matches!(e, RegistryError::Cancelled) { "cancelled" } else { "failed" };
            let mut p = Progress::new(None, "node", step);
            p.error = Some(e.to_string());
            sink.progress(p);
            Err(e)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_major_versions() {
        assert_eq!(parse_major("v24.11.1"), Some(24));
        assert_eq!(parse_major("22.0.0"), Some(22));
        assert_eq!(parse_major("garbage"), None);
    }

    /// 本机有系统 Node（R5 前置）：状态应报出来且 ≥ 22；受管目录不存在时 managed 为 None。
    #[tokio::test]
    async fn system_node_is_detected_when_present() {
        let dir = std::env::temp_dir().join(format!("acp-registry-node-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let s = status(&RegistryDirs::new(&dir)).await;
        assert!(s.managed.is_none());
        if resolve_program("node").is_file() {
            assert!(s.system.is_some() || s.system_error.is_some());
        }
    }

    /// 缓存里的系统 Node 路径已经不在了（卸载 / nvm 切走）：`locate` 不能拿它去拉子进程，要重探并回填
    /// （审查 P3，2026-09-22）。缓存是进程级静态量，别的用例可能并发回填，所以只断言「不是那条过期路径」。
    #[tokio::test]
    async fn locate_reprobes_when_cached_system_node_is_gone() {
        let dir = std::env::temp_dir().join(format!("acp-registry-node-stale-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let stale = dir.join("gone").join("node.exe");
        let stale_path = stale.to_string_lossy().into_owned();
        store_system(&(Some(NodeInfo { version: "v99.0.0".into(), path: stale_path.clone() }), None));

        // 本机没有可用 Node 时 locate 照常报错（Err），那也不是拿过期路径；有的话拿到的必须是重探出来的那份。
        if let Ok(runtime) = locate(&RegistryDirs::new(&dir)).await {
            assert_ne!(runtime.node, stale, "过期路径不能被拿去拉子进程");
        }
        let cached = cached_system().expect("重探之后缓存应被回填");
        assert!(cached.0.as_ref().is_none_or(|s| s.path != stale_path), "过期路径不该还留在缓存里");
    }
}
