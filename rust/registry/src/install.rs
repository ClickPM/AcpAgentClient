//! 安装：npx 型（`npm install` 到 `agents/<id>/`，读 `package.json` 的 `bin`）与 binary 型（下载 → sha256 → 解压到
//! `agents/<id>/<version>/`，记 cmd / args / env）；Remove 只删 `agents/<id>/`。
//! Derived from zed-industries/zed crates/project/src/agent_server_store.rs @ d9e1c024f393832765a03f4de204d6c8cd9abcb2 (GPL-3.0-or-later)
//! （`LocalRegistryNpxAgent::get_command` / `LocalRegistryArchiveAgent::get_command` / `bounded_npm_package_spec` /
//! `read_package_executable`；去 gpui，`Task` 换 tokio；写 settings 与首次握手在 acp-core。）

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::Deserialize;

use crate::index::{BinaryTarget, PackageDistribution, RegistryEntry};
use crate::manifest::{AuthStatus, InstallManifest};
use crate::node::NodeRuntime;
use crate::{CancelToken, Progress, ProgressSink, RegistryDirs, RegistryError, Result, archive, download, sanitize_path_component};

/// `pkg@1.2.3` → (`pkg`, `pkg@0.0.0 - 1.2.3`)：照 Zed，把版本当上限而不是精确钉，让 npm 在 min-release-age 之类的
/// 安全设置下仍能装到一个能用的版本；实际装到的版本读 package.json 回填。没有版本或版本不是 semver 的原样返回。
pub fn bounded_npm_package_spec(package_spec: &str) -> (String, String) {
    let Some((name, version)) = package_spec.rsplit_once('@') else {
        return (package_spec.to_string(), package_spec.to_string());
    };
    if name.is_empty() {
        return (package_spec.to_string(), package_spec.to_string());
    }
    let is_semver = version.split('.').count() == 3 && version.split('.').all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()));
    if !is_semver {
        return (name.to_string(), package_spec.to_string());
    }
    (name.to_string(), format!("{name}@0.0.0 - {version}"))
}

#[derive(Deserialize)]
#[serde(untagged)]
enum Bin {
    Path(String),
    Named(HashMap<String, String>),
}

#[derive(Deserialize)]
struct PackageJson {
    #[serde(default)]
    bin: Option<Bin>,
    #[serde(default)]
    version: Option<String>,
}

/// `node_modules/<name>/package.json` 的 `bin`（单个或按名字选 unscoped 名）→ 可执行脚本的绝对路径 + 版本。
pub fn read_package_executable(node_modules: &Path, name: &str) -> Result<(PathBuf, Option<String>)> {
    let package_dir = node_modules.join(name);
    let package_json = package_dir.join("package.json");
    let text = std::fs::read_to_string(&package_json).map_err(|e| RegistryError::Npm(format!("读 {}：{e}", package_json.display())))?;
    let parsed: PackageJson = serde_json::from_str(&text).map_err(|e| RegistryError::Npm(format!("解析 {}：{e}", package_json.display())))?;
    let relative = match parsed.bin {
        Some(Bin::Path(p)) => p,
        Some(Bin::Named(bins)) => {
            let unscoped = name.rsplit('/').next().unwrap_or(name);
            let picked = if bins.len() == 1 { bins.values().next() } else { bins.get(unscoped) };
            picked.cloned().ok_or_else(|| RegistryError::Npm(format!("npm 包 {name} 没有名为 {unscoped} 的可执行入口")))?
        }
        None => return Err(RegistryError::Npm(format!("npm 包 {name} 没有声明 bin"))),
    };
    Ok((package_dir.join(relative), parsed.version))
}

fn emit(sink: &dyn ProgressSink, agent_id: &str, kind: &'static str, step: &'static str, detail: Option<String>) {
    let mut p = Progress::new(Some(agent_id), kind, step);
    p.detail = detail;
    sink.progress(p);
}

/// npx 型：`resolve` 一步（`npm install` 到 `agents/<id>/`）。返回的记录还没写盘、还没握手——那是 acp-core 的 `write_settings` /
/// `handshake` 两步。失败时把半截的 `node_modules` 留着（下次 `npm install` 会续），只报错。
pub async fn install_npx(
    dirs: &RegistryDirs,
    entry: &RegistryEntry,
    npx: &PackageDistribution,
    node: &NodeRuntime,
    cancel: Arc<CancelToken>,
    sink: &dyn ProgressSink,
) -> Result<InstallManifest> {
    let agent_dir = dirs.agent_dir(&entry.id);
    std::fs::create_dir_all(&agent_dir)?;
    let (package_name, spec) = bounded_npm_package_spec(&npx.package);
    emit(sink, &entry.id, "npx", "resolve", Some(npx.package.clone()));
    cancel.check()?;
    let args: Vec<String> = vec![
        "install".into(),
        spec.clone(),
        "--save-exact".into(),
        "--no-audit".into(),
        "--no-fund".into(),
        "--loglevel".into(),
        "error".into(),
    ];
    node.run_npm(&agent_dir, &args, &cancel).await?;
    cancel.check()?;
    let (executable, installed_version) = read_package_executable(&agent_dir.join("node_modules"), &package_name)?;
    if !executable.is_file() {
        return Err(RegistryError::Npm(format!("npm 装完了但找不到入口 {}", executable.display())));
    }
    let mut manifest_args = vec![executable.to_string_lossy().into_owned()];
    manifest_args.extend(npx.args.iter().cloned());
    Ok(InstallManifest {
        id: entry.id.clone(),
        kind: "npx".into(),
        version: entry.version.clone(),
        installed_version,
        package: Some(package_name),
        package_spec: Some(spec),
        command: "node".into(),
        args: manifest_args,
        env: npx.env.clone(),
        dir: agent_dir.to_string_lossy().into_owned(),
        installed_at: crate::now_ms(),
        auth_status: AuthStatus::Unknown,
        agent_info: None,
        verify_note: None,
    })
}

/// binary 型：download → verify → extract 三步（画板 51），解到 `agents/<id>/<version>/`。
/// 中途失败 / 取消清掉 staging；`cmd` 必须是 `./` 或 `.\` 开头的相对路径且不含 `..`（照 Zed）。
pub async fn install_binary(
    dirs: &RegistryDirs,
    entry: &RegistryEntry,
    target: &BinaryTarget,
    http: &reqwest::Client,
    cancel: Arc<CancelToken>,
    sink: &dyn ProgressSink,
) -> Result<InstallManifest> {
    let agent_dir = dirs.agent_dir(&entry.id);
    std::fs::create_dir_all(&agent_dir)?;
    let kind = archive::kind_for_url(&target.archive)?;
    let version_dir = agent_dir.join(sanitize_path_component(if entry.version.is_empty() { "unversioned" } else { &entry.version }));
    let staging = agent_dir.join(format!(".staging-{}", crate::now_ms()));
    std::fs::create_dir_all(&staging)?;
    let result: Result<(String, Option<String>)> = async {
        // ---- download
        let file_name = kind.file_name(&sanitize_path_component(&entry.id));
        let archive_path = staging.join(&file_name);
        let detail = file_name.clone();
        let agent_id = entry.id.clone();
        let actual = download::download_to_file(http, &target.archive, &archive_path, &cancel, |done, total| {
            sink.progress(Progress::new(Some(&agent_id), "binary", "download").detail(detail.clone()).bytes(done, total));
        })
        .await?;
        cancel.check()?;
        // ---- verify
        let verify_note = match &target.sha256 {
            Some(expected) => {
                emit(sink, &entry.id, "binary", "verify", Some(format!("sha256 {}…", &expected[..expected.len().min(12)])));
                if !download::sha256_matches(&actual, expected) {
                    return Err(RegistryError::Verify { expected: expected.clone(), actual });
                }
                Some("已校验".to_string())
            }
            None => {
                emit(sink, &entry.id, "binary", "verify", Some("registry 条目没给 sha256，跳过校验".into()));
                Some(format!("条目没给 sha256，跳过校验；实际 {actual}"))
            }
        };
        cancel.check()?;
        // ---- extract
        emit(sink, &entry.id, "binary", "extract", Some(version_dir.to_string_lossy().into_owned()));
        let extracted = staging.join("extracted");
        std::fs::create_dir_all(&extracted)?;
        archive::extract(&kind, &archive_path, &extracted).await?;
        let _ = std::fs::remove_file(&archive_path);
        let cmd_path = resolve_cmd(&extracted, &target.cmd)?;
        if !cmd_path.is_file() {
            return Err(RegistryError::Unsupported(format!("解压后找不到 {}（{}）", target.cmd, cmd_path.display())));
        }
        archive::make_executable(&cmd_path)?;
        let _ = std::fs::remove_dir_all(&version_dir);
        std::fs::rename(&extracted, &version_dir)?;
        let final_cmd = resolve_cmd(&version_dir, &target.cmd)?;
        Ok((final_cmd.to_string_lossy().into_owned(), verify_note))
    }
    .await;
    let _ = std::fs::remove_dir_all(&staging);
    let (command, verify_note) = result?;
    Ok(InstallManifest {
        id: entry.id.clone(),
        kind: "binary".into(),
        version: entry.version.clone(),
        installed_version: Some(entry.version.clone()),
        package: None,
        package_spec: None,
        command,
        args: target.args.clone(),
        env: target.env.clone(),
        dir: version_dir.to_string_lossy().into_owned(),
        installed_at: crate::now_ms(),
        auth_status: AuthStatus::Unknown,
        agent_info: None,
        verify_note,
    })
}

/// `./dist-package\cursor-agent.cmd` / `./kilo.exe` → 解压目录下的绝对路径。
fn resolve_cmd(root: &Path, cmd: &str) -> Result<PathBuf> {
    if cmd.contains("..") {
        return Err(RegistryError::Unsupported(format!("cmd 不能含 `..`：{cmd}")));
    }
    let relative = cmd.strip_prefix("./").or_else(|| cmd.strip_prefix(".\\")).ok_or_else(|| {
        RegistryError::Unsupported(format!("cmd 必须是 `./` 开头的相对路径：{cmd}"))
    })?;
    let mut path = root.to_path_buf();
    for part in relative.split(['/', '\\']).filter(|p| !p.is_empty()) {
        path.push(part);
    }
    Ok(path)
}

/// Remove：只删自己写的 `agents/<id>/`（规则 7），不存在也算成功。
pub fn remove(dirs: &RegistryDirs, agent_id: &str) -> Result<bool> {
    let dir = dirs.agent_dir(agent_id);
    // 只删 agents/ 之下的东西：sanitize 已保证 id 不含分隔符，这里再核一次父目录。
    if dir.parent() != Some(dirs.agents_dir().as_path()) {
        return Err(RegistryError::Unsupported(format!("拒绝删除 {}", dir.display())));
    }
    if !dir.exists() {
        return Ok(false);
    }
    std::fs::remove_dir_all(&dir)?;
    Ok(true)
}

/// 已安装条目的拉起参数（acp-core 据此建 `LaunchSpec`）：npx 型把 `node` 换成真实 Node 路径并合并 PATH；
/// `settings_env` 是 settings.json 里 registry 条目的 `env`，最后覆盖。
pub fn launch_parts(manifest: &InstallManifest, node: Option<&NodeRuntime>, settings_env: &BTreeMap<String, String>) -> Result<(String, Vec<String>, BTreeMap<String, String>)> {
    let mut env = manifest.env.clone();
    let program = if manifest.kind == "npx" {
        let node = node.ok_or_else(|| RegistryError::Node("npx 型 agent 需要 Node".into()))?;
        for (k, v) in node.env_overrides() {
            env.insert(k, v);
        }
        node.node.to_string_lossy().into_owned()
    } else {
        manifest.command.clone()
    };
    for (k, v) in settings_env {
        env.insert(k.clone(), v.clone());
    }
    Ok((program, manifest.args.clone(), env))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounds_npm_specs_like_zed() {
        assert_eq!(bounded_npm_package_spec("@agentclientprotocol/codex-acp@1.11.0"), ("@agentclientprotocol/codex-acp".into(), "@agentclientprotocol/codex-acp@0.0.0 - 1.11.0".into()));
        assert_eq!(bounded_npm_package_spec("pi-acp@0.0.33"), ("pi-acp".into(), "pi-acp@0.0.0 - 0.0.33".into()));
        assert_eq!(bounded_npm_package_spec("pi-acp"), ("pi-acp".into(), "pi-acp".into()));
        assert_eq!(bounded_npm_package_spec("pi-acp@latest"), ("pi-acp".into(), "pi-acp@latest".into()));
        assert_eq!(bounded_npm_package_spec("@scope/x"), ("@scope/x".into(), "@scope/x".into()));
    }

    #[test]
    fn reads_package_bin_in_both_shapes() {
        let dir = std::env::temp_dir().join(format!("acp-registry-bin-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let nm = dir.join("node_modules");
        std::fs::create_dir_all(nm.join("@scope").join("one")).expect("mkdir");
        std::fs::write(nm.join("@scope").join("one").join("package.json"), r#"{"name":"@scope/one","version":"1.2.3","bin":"dist/cli.js"}"#).expect("write");
        std::fs::create_dir_all(nm.join("two")).expect("mkdir");
        std::fs::write(nm.join("two").join("package.json"), r#"{"bin":{"two":"bin/two.js","other":"bin/other.js"}}"#).expect("write");
        std::fs::create_dir_all(nm.join("three")).expect("mkdir");
        std::fs::write(nm.join("three").join("package.json"), r#"{"version":"0.1.0"}"#).expect("write");
        let (p, v) = read_package_executable(&nm, "@scope/one").expect("one");
        assert!(p.ends_with(Path::new("@scope/one/dist/cli.js")), "{p:?}");
        assert_eq!(v.as_deref(), Some("1.2.3"));
        let (p, _) = read_package_executable(&nm, "two").expect("two");
        assert!(p.ends_with(Path::new("two/bin/two.js")), "{p:?}");
        assert!(matches!(read_package_executable(&nm, "three"), Err(RegistryError::Npm(_))));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn cmd_must_be_relative_and_inside() {
        let root = Path::new("D:/x/v1");
        assert!(resolve_cmd(root, "./dist-package\\cursor-agent.cmd").expect("ok").ends_with(Path::new("dist-package/cursor-agent.cmd")));
        assert!(resolve_cmd(root, "./kilo.exe").is_ok());
        assert!(matches!(resolve_cmd(root, "kilo.exe"), Err(RegistryError::Unsupported(_))));
        assert!(matches!(resolve_cmd(root, "./../x"), Err(RegistryError::Unsupported(_))));
    }

    #[test]
    fn remove_only_touches_own_agent_dir() {
        let dir = std::env::temp_dir().join(format!("acp-registry-remove-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let dirs = RegistryDirs::new(&dir);
        std::fs::create_dir_all(dirs.agent_dir("x").join("node_modules")).expect("mkdir");
        std::fs::create_dir_all(dirs.agent_dir("y")).expect("mkdir");
        std::fs::create_dir_all(dirs.node_dir()).expect("mkdir");
        assert!(remove(&dirs, "x").expect("remove"));
        assert!(!dirs.agent_dir("x").exists());
        assert!(dirs.agent_dir("y").exists(), "别的 agent 不动");
        assert!(dirs.node_dir().exists(), "node/ 不动");
        assert!(!remove(&dirs, "x").expect("idempotent"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// binary 安装全链路（本地 HTTP 服务代替 CDN）：下载 → sha256 → 系统 tar 解压 → cmd 落在 agents/<id>/<version>/。
    /// 顺带验篡改 sha256 → `Verify` 错误且 staging 被清掉（验收 2）。
    #[tokio::test]
    async fn binary_install_round_trip_and_sha_mismatch() {
        let base = std::env::temp_dir().join(format!("acp-registry-binary 安装-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let src = base.join("src");
        std::fs::create_dir_all(src.join("dist-package")).expect("mkdir");
        std::fs::write(src.join("dist-package").join("agent.cmd"), b"@echo off\r\n").expect("write");
        let zip = base.join("pkg.zip");
        let out = crate::command(archive::tar_program()).arg("-a").arg("-cf").arg(&zip).arg("-C").arg(&src).arg("dist-package").output().await.expect("tar");
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        let bytes = std::fs::read(&zip).expect("read");
        let sha = download::sha256_file(&zip).expect("sha");

        // 一个最小的 HTTP 服务：任何 GET 都回这份 zip。
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("addr");
        let served = bytes.clone();
        tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else { break };
                let body = served.clone();
                tokio::spawn(async move {
                    use tokio::io::{AsyncReadExt, AsyncWriteExt};
                    let mut buf = [0u8; 4096];
                    let _ = socket.read(&mut buf).await;
                    let head = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nContent-Type: application/zip\r\nConnection: close\r\n\r\n", body.len());
                    let _ = socket.write_all(head.as_bytes()).await;
                    let _ = socket.write_all(&body).await;
                    let _ = socket.shutdown().await;
                });
            }
        });
        let url = format!("http://{addr}/agent-cli-package.zip");
        let dirs = RegistryDirs::new(base.join("data"));
        let entry = RegistryEntry {
            id: "fake-cursor".into(),
            name: "Fake".into(),
            version: "2026.09.02".into(),
            description: String::new(),
            repository: None,
            website: None,
            license: None,
            authors: vec![],
            icon: None,
            distribution: Default::default(),
        };
        let http = download::client();
        let sink = crate::RecordingProgress::default();

        let ok_target = BinaryTarget { archive: url.clone(), cmd: "./dist-package\\agent.cmd".into(), args: vec!["acp".into()], sha256: Some(sha.to_uppercase()), env: BTreeMap::new() };
        let manifest = install_binary(&dirs, &entry, &ok_target, &http, CancelToken::new(), &sink).await.expect("install");
        assert!(Path::new(&manifest.command).is_file(), "{}", manifest.command);
        assert!(manifest.command.starts_with(&dirs.agent_dir("fake-cursor").join("2026.09.02").to_string_lossy().into_owned()));
        assert_eq!(manifest.args, vec!["acp".to_string()]);
        assert_eq!(manifest.verify_note.as_deref(), Some("已校验"));
        let steps: Vec<&str> = sink.take().iter().map(|p| p.step).collect();
        assert_eq!(steps.first().copied(), Some("download"));
        assert!(steps.contains(&"verify") && steps.last().copied() == Some("extract"), "{steps:?}");
        assert!(!std::fs::read_dir(dirs.agent_dir("fake-cursor")).expect("dir").any(|e| e.expect("e").file_name().to_string_lossy().starts_with(".staging")), "staging 清掉");

        let bad_target = BinaryTarget { sha256: Some("0".repeat(64)), ..ok_target.clone() };
        let err = install_binary(&dirs, &entry, &bad_target, &http, CancelToken::new(), &sink).await.expect_err("mismatch");
        assert!(matches!(err, RegistryError::Verify { .. }), "{err:?}");
        assert!(!std::fs::read_dir(dirs.agent_dir("fake-cursor")).expect("dir").any(|e| e.expect("e").file_name().to_string_lossy().starts_with(".staging")), "失败也清 staging");
        // 上一次装好的版本目录不受篡改那次影响。
        assert!(Path::new(&manifest.command).is_file());
        let _ = std::fs::remove_dir_all(&base);
    }
}
