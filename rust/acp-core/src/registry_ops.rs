//! registry 面板 / 认证状态 / 设置页背后的编排（docs/design.md § 5 / § 6，R5）：把 `rust/registry` 的安装步骤、
//! settings.json 的写入与首次 `initialize` 握手串成画板 51 的三步，进度经 `registry/progress` 推出；Remove、受管 Node、
//! 从 Zed 导入、registry 型的拉起也在这里。安装任务在核心的 runtime 上后台跑，命令立即返回，取消经 [`CancelToken`]。
//! 画板 53 的升级（`registry_update`）也在这里：新版本装在旧版旁边，通过了才切换安装记录，旧目录在不被占用时清掉。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use registry::index::{Resolved, RegistryEntry, current_platform_key};
use registry::manifest::{AuthStatus, InstallManifest};
use registry::{CancelToken, Progress, ProgressSink, RegistryError};
use serde_json::{Value, json};
use settings::AgentServer;

use crate::agent::AgentConnection;
use crate::command::LaunchSpec;
use crate::core::{Core, lock};
use crate::error::{CoreError, Result};
use crate::events::{EventChannel, EventSink};

/// Remove 时等正在跑的安装任务退出的时间。
const CANCEL_GRACE: Duration = Duration::from_secs(5);
/// 回滚删 `agents/<id>/` 的重试次数与间隔（合计 5 s，与 [`CANCEL_GRACE`] 同量级：`kill_tree` 通常一秒内结束）。
const ROLLBACK_ATTEMPTS: u32 = 20;
const ROLLBACK_RETRY: Duration = Duration::from_millis(250);

/// `registry/progress` 事件出口。
pub struct ProgressEvents {
    sink: Arc<dyn EventSink>,
}

impl ProgressSink for ProgressEvents {
    fn progress(&self, progress: Progress) {
        self.sink.emit(EventChannel::RegistryProgress, progress.to_json().to_string());
    }
}

/// 升级的进度出口：每条打上 `upgrade: true`（画板 53 据此画两步清单与「升级失败」）。
struct UpgradeProgress<'a>(&'a dyn ProgressSink);

impl ProgressSink for UpgradeProgress<'_> {
    fn progress(&self, mut progress: Progress) {
        progress.upgrade = true;
        self.0.progress(progress);
    }
}

/// 升级握手的事件出口：只拦 `acp/agent_state`。那条临时连接与正在运行的连接是同一个 agentId，它的
/// `spawned` / `initialized` / `exited` 发出去，前端会把运行中的那条当成刚退出；流量等其余事件照发。
struct WithoutAgentState(Arc<dyn EventSink>);

impl EventSink for WithoutAgentState {
    fn emit(&self, channel: EventChannel, payload: String) {
        if channel != EventChannel::AgentState {
            self.0.emit(channel, payload);
        }
    }
}

/// 条目在本平台的分发方式（进度事件的 `kind`）。
fn distribution_kind(entry: &RegistryEntry) -> &'static str {
    match entry.resolve(current_platform_key()) {
        Resolved::Binary(_) => "binary",
        _ => "npx",
    }
}

impl Core {
    fn progress_sink(&self) -> ProgressEvents {
        ProgressEvents { sink: self.event_sink() }
    }

    // ---- 列表与刷新

    /// `registry_list`：registry 条目（带本地安装 / 认证状态）+ settings 里的 custom 条目，已安装的排前面；
    /// 另带拉取状态、Node 状态与几个路径（数据目录、日志、Zed settings）。
    pub async fn registry_list(&self) -> Result<Value> {
        let snap = self.registry_index().snapshot();
        let mut settings = self.settings().load()?;
        // 内置 sidecar（R7）与 custom 型条目一起列，只是多带一个 `builtin` 标记让前端关掉 Remove。
        crate::builtin::merge_into(&mut settings, self.data_dir());
        let platform = current_platform_key();
        let installing: Vec<String> = lock(self.installs()).keys().cloned().collect();
        let dirs = self.registry_dirs();
        let mut agents: Vec<(bool, Value)> = Vec::new();
        for entry in &snap.agents {
            let resolved = entry.resolve(platform);
            let manifest = InstallManifest::load(dirs, &entry.id).ok().flatten().filter(|m| m.is_intact());
            let installed = manifest.is_some();
            let installable = !matches!(resolved, Resolved::Unsupported | Resolved::Uvx);
            let package = match &resolved {
                Resolved::Npx(npx) => Some(npx.package.clone()),
                _ => None,
            };
            // 画板 53：安装那一刻的 registry 版本 ≠ 当前版本就可升级。比 `version` 不比 `installedVersion`（npm 有界规格在
            // min-release-age 下可能装到更低的版本，拿它比会一直提示有更新）；只判不等不比大小；本平台装不了的不出。
            let update_available = manifest.as_ref().filter(|m| installable && m.version != entry.version).map(|_| entry.version.clone());
            let reload_pending = manifest.as_ref().and_then(|m| self.reload_pending(m));
            agents.push((
                installed,
                json!({
                    "id": entry.id,
                    "name": entry.name,
                    "version": entry.version,
                    "description": entry.description,
                    "repository": entry.repository,
                    "website": entry.website,
                    "license": entry.license,
                    "iconSvg": self.registry_index().icon_svg(&entry.id),
                    "distribution": resolved.kind(),
                    "supported": installable,
                    "package": package,
                    "installed": manifest.as_ref().map(InstallManifest::to_json),
                    "installing": installing.contains(&entry.id),
                    "updateAvailable": update_available,
                    "reloadPending": reload_pending,
                    "custom": Value::Null,
                }),
            ));
        }
        for (id, server) in &settings.agent_servers {
            if let AgentServer::Custom { path, args, env, extra } = server {
                // `extra` 是 Zed 同形字段的原样保留处；内置条目在这里放 `builtin` / `name`（crate::builtin）。
                let builtin = extra.get("builtin").and_then(Value::as_bool).unwrap_or(false);
                let name = extra.get("name").and_then(Value::as_str).unwrap_or(id.as_str());
                // custom 型没有 registry 缓存的 `icon.svg`，条目自带时就用它（内置 sidecar 随包带了 Zed 的标志）。
                let icon = extra.get("iconSvg").and_then(Value::as_str);
                agents.push((
                    true,
                    json!({
                        "id": id,
                        "name": name,
                        "version": "",
                        "description": "",
                        "iconSvg": icon,
                        "distribution": "custom",
                        "supported": true,
                        "installed": Value::Null,
                        "installing": false,
                        "builtin": builtin,
                        "custom": { "command": path, "args": args, "env": env },
                    }),
                ));
            }
        }
        // 已安装 / custom 排前面，其余保持 registry 顺序（画板 50）。
        agents.sort_by_key(|(installed, _)| !installed);
        let node = registry::node::status(dirs).await;
        let zed_path = settings::zed_import::zed_settings_path().filter(|p| p.is_file());
        Ok(json!({
            "agents": agents.into_iter().map(|(_, v)| v).collect::<Vec<_>>(),
            "fetching": snap.fetching,
            "fetchError": snap.fetch_error,
            "fetchedAt": snap.cached_at,
            "node": serde_json::to_value(node)?,
            "paths": {
                "dataDir": self.data_dir().to_string_lossy(),
                "logPath": self.log_path().to_string_lossy(),
                "zedSettingsPath": zed_path.map(|p| p.to_string_lossy().into_owned()),
            },
        }))
    }

    /// `registry_refresh`：联网拉一次（1 小时节流，`force` 跳过），失败不清缓存、错误进 `fetchError`；返回列表。
    pub async fn registry_refresh(&self, force: bool) -> Result<Value> {
        let _ = self.registry_index().refresh(force).await;
        self.registry_list().await
    }

    // ---- 安装 / 取消 / 移除

    /// `registry_install`：后台起安装任务，立即返回 `{agentId, started}`；进度与结果都走 `registry/progress`。
    /// 已经装好的条目拒绝（有新版本走 `registry_update`）：首装失败的回滚会删掉整个 `agents/<id>/`，连旧版一起。
    pub fn registry_install(self: &Arc<Self>, agent_id: &str) -> Result<Value> {
        let entry = self
            .registry_index()
            .entry(agent_id)
            .ok_or_else(|| CoreError::InvalidArgument(format!("registry 里没有 `{agent_id}`（先刷新列表）")))?;
        if InstallManifest::load(self.registry_dirs(), agent_id).ok().flatten().is_some_and(|m| m.is_intact()) {
            return Err(CoreError::InvalidArgument(format!("`{agent_id}` 已经装好了；registry 有新版本时用升级（registry_update）")));
        }
        let token = self.claim_install_slot(agent_id)?;
        let core = self.clone();
        let id = agent_id.to_string();
        self.runtime().spawn(async move {
            let result = core.run_install(&entry, token.clone()).await;
            lock(core.installs()).remove(&id);
            core.finish_install(&id, distribution_kind(&entry), false, result);
        });
        Ok(json!({ "agentId": agent_id, "started": true }))
    }

    /// 占住一个 agent 的安装槽（安装 / 升级 / 启动清扫共用）：已被占 → 「正在安装」。
    fn claim_install_slot(&self, agent_id: &str) -> Result<Arc<CancelToken>> {
        let token = CancelToken::new();
        let mut installs = lock(self.installs());
        if installs.contains_key(agent_id) {
            return Err(CoreError::InvalidArgument(format!("`{agent_id}` 正在安装")));
        }
        installs.insert(agent_id.to_string(), token.clone());
        Ok(token)
    }

    /// 安装 / 升级任务的收尾事件：done / cancelled / failed（带错误文案）。
    fn finish_install(&self, agent_id: &str, kind: &'static str, upgrade: bool, result: Result<()>) {
        let mut p = match result {
            Ok(()) => Progress::new(Some(agent_id), kind, "done"),
            Err(e) => {
                let step = if matches!(e, CoreError::Registry(RegistryError::Cancelled)) { "cancelled" } else { "failed" };
                let mut p = Progress::new(Some(agent_id), kind, step);
                p.error = Some(e.to_string());
                p
            }
        };
        p.upgrade = upgrade;
        self.progress_sink().progress(p);
    }

    async fn run_install(self: &Arc<Self>, entry: &RegistryEntry, token: Arc<CancelToken>) -> Result<()> {
        let dirs = self.registry_dirs();
        let sink = self.progress_sink();
        // 首装没有在用的入口：目标就是 `agents/<id>/<version>/`。
        let target = registry::install::version_dir(dirs, &entry.id, &entry.version, &[]);
        match entry.resolve(current_platform_key()) {
            Resolved::Npx(npx) => {
                let node = registry::node::locate(dirs).await?;
                let mut manifest = registry::install::install_npx(entry, &npx, &node, &target, token.clone(), &sink).await?;
                token.check()?;
                sink.progress(Progress::new(Some(&entry.id), "npx", "write_settings"));
                let (settings_env, settings_created) = self.write_registry_settings(&entry.id)?;
                // 从这里起是「提交点」：settings 与 install.json 都落了盘。之后不再 `token.check()` 把装好的结果报成 cancelled；
                // 握手失败或取消则回滚成没装过（审查 P2，2026-09-16），别留下一个显示已安装却拉不起来的条目。
                let committed: Result<()> = async {
                    manifest.save(dirs)?;
                    sink.progress(Progress::new(Some(&entry.id), "npx", "handshake"));
                    let launch = LaunchSpec::from_registry(&manifest, Some(&node), &settings_env)?;
                    // 首次拉起并 initialize：拿 agentInfo（展示名 / 版本）。与取消赛跑是安全的：connect 的 future 被丢掉时，
                    // 它持有的 kill 通道发送端随之析构，exit_watcher 立刻结束子进程树（agent.rs），不留孤儿。
                    let connection = tokio::select! {
                        connected = AgentConnection::connect(entry.id.clone(), launch, None, self.event_sink(), self.terminal_manager()) => connected?,
                        _ = token.cancelled() => return Err(RegistryError::Cancelled.into()),
                    };
                    manifest.agent_info = connection.initialize.get("agentInfo").cloned();
                    manifest.installed_version = manifest
                        .installed_version
                        .clone()
                        .or_else(|| manifest.agent_info.as_ref().and_then(|i| i.get("version")).and_then(Value::as_str).map(str::to_string));
                    connection.disconnect().await;
                    manifest.save(dirs)?;
                    Ok(())
                }
                .await;
                if committed.is_err() {
                    self.rollback_install(&entry.id, settings_created).await;
                }
                committed
            }
            Resolved::Binary(binary) => {
                let manifest = registry::install::install_binary(dirs, entry, &binary, &target, self.http(), token.clone(), &sink).await?;
                token.check()?;
                self.write_registry_settings(&entry.id)?;
                manifest.save(dirs)?;
                Ok(())
            }
            Resolved::Uvx => Err(uvx_unsupported()),
            Resolved::Unsupported => Err(platform_unsupported()),
        }
    }

    // ---- 升级（画板 53）

    /// `registry_update`：后台把已安装条目升到 registry 当前版本，立即返回 `{agentId, started}`；进度同 `registry/progress`
    /// （每条带 `upgrade: true`）。新版本装在旧版旁边，npx 握手通过 / binary 解压成功才切换安装记录；失败或取消只删新目录，
    /// 旧的安装记录、settings 条目与 env、认证状态都不动。正在运行的连接不打断（`registry_list` 的 `reloadPending`）。
    pub fn registry_update(self: &Arc<Self>, agent_id: &str) -> Result<Value> {
        let entry = self
            .registry_index()
            .entry(agent_id)
            .ok_or_else(|| CoreError::InvalidArgument(format!("registry 里没有 `{agent_id}`（先刷新列表）")))?;
        let current = InstallManifest::load(self.registry_dirs(), agent_id)?
            .filter(InstallManifest::is_intact)
            .ok_or_else(|| CoreError::InvalidArgument(format!("`{agent_id}` 还没安装")))?;
        if current.version == entry.version {
            return Err(CoreError::InvalidArgument(format!("`{agent_id}` 已是 registry 当前版本 {}", entry.version)));
        }
        let token = self.claim_install_slot(agent_id)?;
        let core = self.clone();
        let id = agent_id.to_string();
        self.runtime().spawn(async move {
            let result = core.run_upgrade(&entry, &current, token).await;
            lock(core.installs()).remove(&id);
            core.finish_install(&id, distribution_kind(&entry), true, result);
        });
        Ok(json!({ "agentId": agent_id, "started": true }))
    }

    async fn run_upgrade(self: &Arc<Self>, entry: &RegistryEntry, current: &InstallManifest, token: Arc<CancelToken>) -> Result<()> {
        let dirs = self.registry_dirs();
        let events = self.progress_sink();
        let sink = UpgradeProgress(&events);
        // 目标目录避开所有在用的入口：安装记录的，和正在运行的连接的（它可能还是更早的一版）。
        let mut in_use: Vec<PathBuf> = current.entry_path().into_iter().collect();
        if let Some(Some(live)) = self.live_entry(&entry.id) {
            in_use.push(live);
        }
        let target = registry::install::version_dir(dirs, &entry.id, &entry.version, &in_use);
        let staged: Result<InstallManifest> = async {
            let manifest = match entry.resolve(current_platform_key()) {
                Resolved::Npx(npx) => {
                    let node = registry::node::locate(dirs).await?;
                    let mut manifest = registry::install::install_npx(entry, &npx, &node, &target, token.clone(), &sink).await?;
                    token.check()?;
                    sink.progress(Progress::new(Some(&entry.id), "npx", "handshake"));
                    let launch = LaunchSpec::from_registry(&manifest, Some(&node), &self.registry_settings_env(&entry.id)?)?;
                    let quiet: Arc<dyn EventSink> = Arc::new(WithoutAgentState(self.event_sink()));
                    let connection = tokio::select! {
                        connected = AgentConnection::connect(entry.id.clone(), launch, None, quiet, self.terminal_manager()) => connected?,
                        _ = token.cancelled() => return Err(RegistryError::Cancelled.into()),
                    };
                    manifest.agent_info = connection.initialize.get("agentInfo").cloned();
                    manifest.installed_version = manifest
                        .installed_version
                        .clone()
                        .or_else(|| manifest.agent_info.as_ref().and_then(|i| i.get("version")).and_then(Value::as_str).map(str::to_string));
                    connection.disconnect().await;
                    manifest
                }
                Resolved::Binary(binary) => registry::install::install_binary(dirs, entry, &binary, &target, self.http(), token.clone(), &sink).await?,
                Resolved::Uvx => return Err(uvx_unsupported()),
                Resolved::Unsupported => return Err(platform_unsupported()),
            };
            // 切换之前最后一次认取消：之后就是写安装记录，不再把装好的结果报成 cancelled。
            token.check()?;
            Ok(manifest)
        }
        .await;
        let committed = match staged {
            Ok(manifest) => self.commit_upgrade(current, manifest),
            Err(e) => Err(e),
        };
        match committed {
            Ok(keep) => {
                // 旧版本的 node_modules 动辄几百 MB，删目录放到阻塞线程上，别占着 runtime 的工作线程。
                if let Some(keep) = keep {
                    let dirs = dirs.clone();
                    let id = entry.id.clone();
                    let _ = tokio::task::spawn_blocking(move || registry::install::sweep_stale(&dirs, &id, &keep)).await;
                }
                Ok(())
            }
            Err(e) => {
                // 只删本次的新目录（它避开了所有在用的入口）；握手子进程刚被结束时 Windows 上会占着文件，短等重试。
                remove_dir_retrying(&target).await;
                Err(e)
            }
        }
    }

    /// 切换：新安装记录继承认证状态，记下运行中那条连接的版本（`reloadPending` 用），写盘即切换。返回清旧目录时要留下的
    /// 入口——没有连接就只留新入口，有连接就连它的入口一起留（推迟到它断开后的下次启动），认不出连接的入口就先不清（`None`）。
    fn commit_upgrade(&self, current: &InstallManifest, mut next: InstallManifest) -> Result<Option<Vec<PathBuf>>> {
        let dirs = self.registry_dirs();
        let id = current.id.clone();
        next.auth_status = current.auth_status;
        // 连接在这里重新看一次：升级在途时用户可能 Reload 过（那时拉起的还是旧安装记录）。
        let (previous, keep) = switch_plan(current, &next, self.live_entry(&id));
        next.previous_version = previous;
        // settings 里的 registry 条目升级前就在（带用户的 env，不动）；被手动删了就补回，同名 custom 条目则报错不切换。
        self.write_registry_settings(&id)?;
        next.save(dirs)?;
        Ok(keep)
    }

    /// 画板 53「已升级 · 待重载」：该 agent 正连着，而那条连接的拉起入口已不是安装记录里的（升级切走了）→ 运行中那条的版本
    /// （安装记录的 `previousVersion`；没记下时是空串）。没连着、或认不出连接的入口 → None。
    fn reload_pending(&self, manifest: &InstallManifest) -> Option<String> {
        reload_pending_of(manifest, self.live_entry(&manifest.id))
    }

    /// 该 agent 当前连接的拉起入口：没连着 → `None`；连着 → `Some(入口)`，入口取程序与第一个参数里落在 `agents/<id>/` 之下
    /// 的那个（npx 是 `node <脚本>` 的脚本，binary 是程序本身）；两个都不在那下面 → `Some(None)`（认不出，不据此删任何东西）。
    fn live_entry(&self, agent_id: &str) -> Option<Option<PathBuf>> {
        let launch = lock(self.agents()).get(agent_id).map(|c| c.launch.clone())?;
        let agent_dir = self.registry_dirs().agent_dir(agent_id);
        Some(std::iter::once(&launch.program).chain(launch.args.first()).map(PathBuf::from).find(|p| p.starts_with(&agent_dir)))
    }

    /// settings 里 registry 条目的 `env`（拉起时最后覆盖）；没有条目 → 空。
    fn registry_settings_env(&self, agent_id: &str) -> Result<BTreeMap<String, String>> {
        Ok(match self.settings().get(agent_id)? {
            Some(AgentServer::Registry { env, .. }) => env,
            _ => BTreeMap::new(),
        })
    }

    /// 启动时清一遍各 agent 目录里不再用到的旧版本（升级时有连接在用而推迟的那些；画板 53）。后台跑，此时还没有任何连接，
    /// 在用的只有安装记录的入口；清某个 agent 时占住它的安装槽，这期间来的安装 / 升级直接报「正在安装」，不和清扫抢目录。
    pub fn sweep_stale_installs(self: &Arc<Self>) {
        let core = self.clone();
        self.runtime().spawn(async move {
            let Ok(entries) = std::fs::read_dir(core.registry_dirs().agents_dir()) else { return };
            let ids: Vec<String> = entries
                .flatten()
                .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .collect();
            for id in ids {
                if core.claim_install_slot(&id).is_err() {
                    continue;
                }
                let dirs = core.registry_dirs().clone();
                let agent = id.clone();
                let _ = tokio::task::spawn_blocking(move || {
                    if let Ok(Some(manifest)) = InstallManifest::load(&dirs, &agent)
                        && manifest.is_intact()
                    {
                        let in_use: Vec<PathBuf> = manifest.entry_path().into_iter().collect();
                        registry::install::sweep_stale(&dirs, &agent, &in_use);
                    }
                })
                .await;
                lock(core.installs()).remove(&id);
            }
        });
    }

    /// settings.json 写 `{type: "registry"}`（已有 registry 条目时保留它的 env 与 Zed 字段；同名 custom 条目不覆盖）。
    /// 返回该条目的 `env`（拉起时最后覆盖）与「这条是本次新建的」（回滚时只删自己建的）。
    fn write_registry_settings(&self, agent_id: &str) -> Result<(BTreeMap<String, String>, bool)> {
        match self.settings().get(agent_id)? {
            Some(AgentServer::Registry { env, .. }) => Ok((env, false)),
            Some(AgentServer::Custom { .. }) => Err(CoreError::InvalidArgument(format!(
                "settings.json 里已有同名的 custom 条目 `{agent_id}`，先在设置页删掉它"
            ))),
            None => {
                self.settings().upsert(agent_id, AgentServer::Registry { env: BTreeMap::new(), extra: BTreeMap::new() })?;
                Ok((BTreeMap::new(), true))
            }
        }
    }

    /// 提交点之后失败或取消：回滚成没装过。先删 `install.json`（`is_intact` 立刻为假，列表不再显示已安装），再删本次新建的
    /// settings 条目（原有的带用户 env，不动），最后删 `agents/<id>/`。取消分支丢掉 connect 的 future 时握手拉起的子进程还在
    /// 另一个 task 里被 `kill_tree`，Windows 上它占着的文件会让 `remove_dir_all` 失败（审查第 2 轮 P2），所以短等重试；
    /// 重试用尽也不当成功——manifest 已删，状态是真的「未安装」，剩下的目录由下一次安装覆盖。
    async fn rollback_install(&self, agent_id: &str, settings_created: bool) {
        let dirs = self.registry_dirs();
        let _ = std::fs::remove_file(InstallManifest::path(dirs, agent_id));
        if settings_created {
            let _ = self.settings().remove(agent_id);
        }
        for attempt in 0..ROLLBACK_ATTEMPTS {
            if attempt > 0 {
                tokio::time::sleep(ROLLBACK_RETRY).await;
            }
            if registry::install::remove(dirs, agent_id).is_ok() {
                return;
            }
        }
    }

    /// `registry_cancel_install`。
    pub fn registry_cancel_install(&self, agent_id: &str) -> Result<Value> {
        let token = lock(self.installs()).get(agent_id).cloned();
        let cancelled = match token {
            Some(token) => {
                token.cancel();
                true
            }
            None => false,
        };
        Ok(json!({ "agentId": agent_id, "cancelled": cancelled }))
    }

    /// `registry_remove`：正在安装的先取消并等它退出；断开连接；删 settings 条目；只删 `agents/<id>/`（规则 7）。返回列表。
    pub async fn registry_remove(&self, agent_id: &str) -> Result<Value> {
        // 锁的取值先绑到局部变量再 await：`if let` 的 scrutinee 临时值活到整个分支结束，guard 会跨过 await（future 不 Send）。
        let running = lock(self.installs()).get(agent_id).cloned();
        if let Some(token) = running {
            token.cancel();
            let deadline = tokio::time::Instant::now() + CANCEL_GRACE;
            while lock(self.installs()).contains_key(agent_id) && tokio::time::Instant::now() < deadline {
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            // 宽限期过了还没退出就不删：安装任务收尾还会写 install.json，先删目录会被它写回（审查 P2，2026-09-16）。
            if lock(self.installs()).contains_key(agent_id) {
                return Err(CoreError::InvalidArgument(format!("`{agent_id}` 的安装还没退出（已发取消），稍后再试")));
            }
        }
        let connection = lock(self.agents()).remove(agent_id);
        if let Some(connection) = connection {
            connection.disconnect().await;
        }
        let settings_removed = self.settings().get(agent_id)?.is_some();
        self.settings().remove(agent_id)?;
        let removed = registry::install::remove(self.registry_dirs(), agent_id)?;
        let mut list = self.registry_list().await?;
        if let Value::Object(map) = &mut list {
            map.insert("removed".into(), json!({ "agentId": agent_id, "files": removed, "settings": settings_removed }));
        }
        Ok(list)
    }

    // ---- Node

    pub async fn node_status(&self) -> Result<Value> {
        Ok(serde_json::to_value(registry::node::status(self.registry_dirs()).await)?)
    }

    /// `node_download`：下载受管 Node 到 `node/`（进度 `agentId: null`），完成后返回 Node 状态。
    pub async fn node_download(&self) -> Result<Value> {
        let token = {
            let mut slot = lock(self.node_download_token());
            if slot.as_ref().is_some_and(|t| !t.is_cancelled()) {
                return Err(CoreError::InvalidArgument("受管 Node 正在下载".into()));
            }
            let token = CancelToken::new();
            *slot = Some(token.clone());
            token
        };
        let result = registry::node::download_managed(self.registry_dirs(), self.http(), token, &self.progress_sink()).await;
        *lock(self.node_download_token()) = None;
        result?;
        self.node_status().await
    }

    // ---- 设置

    /// `agent_settings_remove`：只删 settings.json 的条目（custom 型从设置页删除；registry 型请走 `registry_remove`）。
    pub async fn agent_settings_remove(&self, agent_id: &str) -> Result<Value> {
        // 内置 sidecar 不在 settings.json 里，删了也只会在下次 `agent_settings_get` 又冒出来；
        // 与其装作删掉了，不如明确拒绝（画板 70「可见、不可删」）。用户自己在 settings 里写过同名条目时
        // 那条是可删的 —— 删完剩下的就是内置条目。
        if self.settings().get(agent_id)?.is_none() && crate::builtin::is_builtin(agent_id) {
            return Err(CoreError::InvalidArgument(format!("`{agent_id}` 是随包分发的内置 agent，不能删除")));
        }
        let connection = lock(self.agents()).remove(agent_id);
        if let Some(connection) = connection {
            connection.disconnect().await;
        }
        Ok(serde_json::to_value(self.settings().remove(agent_id)?)?)
    }

    /// `agent_settings_import_zed`：读 `%APPDATA%/Zed/settings.json` 的 `agent_servers`，同名不覆盖。返回导入报告 + 全量设置。
    pub fn agent_settings_import_zed(&self) -> Result<Value> {
        let path = settings::zed_import::zed_settings_path()
            .filter(|p| p.is_file())
            .ok_or_else(|| CoreError::Settings("找不到 Zed 的 settings.json".into()))?;
        let report = self.settings().import_zed(&path)?;
        Ok(json!({
            "report": serde_json::to_value(report)?,
            "settings": serde_json::to_value(self.settings().load()?)?,
        }))
    }

    // ---- registry 型的拉起与认证状态

    /// registry 型 → [`LaunchSpec`]：安装记录 + Node（npx 型）+ settings 的 `env`。未安装报 `registry`，缺 Node 报 `node_missing`。
    pub(crate) async fn registry_launch(&self, agent_id: &str, settings_env: &BTreeMap<String, String>) -> Result<LaunchSpec> {
        let dirs = self.registry_dirs();
        let manifest = InstallManifest::load(dirs, agent_id)?
            .filter(|m| m.is_intact())
            .ok_or_else(|| RegistryError::Unsupported(format!("`{agent_id}` 还没安装（settings 里是 registry 型，但 agents/{agent_id}/ 没有安装记录）")))?;
        let node = if manifest.kind == "npx" { Some(registry::node::locate(dirs).await?) } else { None };
        LaunchSpec::from_registry(&manifest, node.as_ref(), settings_env)
    }

    /// `session/new` 的结果回写认证状态（只对 registry 型的安装记录；custom 型没有记录，静默跳过）。
    pub(crate) fn record_auth_status(&self, agent_id: &str, status: AuthStatus) {
        let _ = InstallManifest::set_auth_status(self.registry_dirs(), agent_id, status);
    }
}

/// [`Core::reload_pending`] 的判定本体（`live` 是 [`Core::live_entry`] 的结果）。
fn reload_pending_of(manifest: &InstallManifest, live: Option<Option<PathBuf>>) -> Option<String> {
    let running = live??;
    if manifest.entry_path().as_ref() == Some(&running) {
        return None;
    }
    Some(manifest.previous_version.clone().unwrap_or_default())
}

/// 升级切换那一刻（`live` 同上）：新安装记录要记的 `previousVersion`，与清旧目录时要留下的入口（`None` = 这次先不清）。
fn switch_plan(current: &InstallManifest, next: &InstallManifest, live: Option<Option<PathBuf>>) -> (Option<String>, Option<Vec<PathBuf>>) {
    let previous = match &live {
        None => None,
        Some(Some(entry)) if current.entry_path().as_deref() == Some(entry.as_path()) => Some(current.version.clone()),
        // 运行中那条比当前安装记录还旧（连续升级两次都没重载）或认不出：保留最早记下的那个版本。
        Some(_) => current.previous_version.clone().or_else(|| Some(current.version.clone())),
    };
    let keep = match live {
        None => Some(next.entry_path().into_iter().collect()),
        Some(Some(entry)) => Some(next.entry_path().into_iter().chain(std::iter::once(entry)).collect()),
        Some(None) => None,
    };
    (previous, keep)
}

fn uvx_unsupported() -> CoreError {
    RegistryError::Unsupported("registry 条目声明的安装方式是 uvx，本版本暂不支持".into()).into()
}

fn platform_unsupported() -> CoreError {
    RegistryError::Unsupported("registry 条目没有本平台可用的分发方式".into()).into()
}

/// 删一个目录，Windows 上被刚结束的子进程占着时短等重试（与首装回滚同一套次数与间隔）；重试用尽就留着，下次清扫再删。
async fn remove_dir_retrying(dir: &Path) {
    for attempt in 0..ROLLBACK_ATTEMPTS {
        if attempt > 0 {
            tokio::time::sleep(ROLLBACK_RETRY).await;
        }
        if !dir.exists() || std::fs::remove_dir_all(dir).is_ok() {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};

    use super::*;
    use crate::events::RecordingSink;
    use registry::manifest::MANIFEST_FILE;

    fn manifest(dir: &Path, version: &str) -> InstallManifest {
        InstallManifest {
            id: "x".into(),
            kind: "binary".into(),
            version: version.into(),
            installed_version: Some(version.into()),
            package: None,
            package_spec: None,
            command: dir.join("dist-package").join("agent.cmd").to_string_lossy().into_owned(),
            args: vec![],
            env: BTreeMap::new(),
            dir: dir.to_string_lossy().into_owned(),
            installed_at: 1,
            auth_status: AuthStatus::Authenticated,
            agent_info: None,
            verify_note: None,
            previous_version: None,
        }
    }

    #[test]
    fn reload_pending_only_when_a_live_connection_runs_something_else() {
        let agent = PathBuf::from("D:/data/agents/x");
        let mut m = manifest(&agent.join("2.0.0"), "2.0.0");
        m.previous_version = Some("1.0.0".into());
        let older = Some(Some(agent.join("1.0.0").join("dist-package").join("agent.cmd")));
        assert_eq!(reload_pending_of(&m, None), None, "没连着");
        assert_eq!(reload_pending_of(&m, Some(None)), None, "认不出连接的入口");
        assert_eq!(reload_pending_of(&m, Some(m.entry_path())), None, "连接跑的就是安装记录里的");
        assert_eq!(reload_pending_of(&m, older.clone()), Some("1.0.0".into()));
        m.previous_version = None;
        assert_eq!(reload_pending_of(&m, older), Some(String::new()));
    }

    #[test]
    fn switch_plan_records_the_running_version_and_keeps_its_directory() {
        let agent = PathBuf::from("D:/data/agents/x");
        let mut current = manifest(&agent.join("2.0.0"), "2.0.0");
        let next = manifest(&agent.join("3.0.0"), "3.0.0");
        let next_entry = next.entry_path().expect("entry");
        // 没连着：不记旧版本，只留新入口。
        assert_eq!(switch_plan(&current, &next, None), (None, Some(vec![next_entry.clone()])));
        // 连着的就是当前这版：记它，连它的入口一起留。
        let running = current.entry_path().expect("entry");
        assert_eq!(switch_plan(&current, &next, Some(Some(running.clone()))), (Some("2.0.0".into()), Some(vec![next_entry.clone(), running])));
        // 连着的是更早的一版（升级两次都没重载）：保留最早记下的版本，留它的入口。
        current.previous_version = Some("1.0.0".into());
        let older = agent.join("1.0.0").join("dist-package").join("agent.cmd");
        assert_eq!(switch_plan(&current, &next, Some(Some(older.clone()))), (Some("1.0.0".into()), Some(vec![next_entry, older])));
        // 认不出连接的入口：这次不清。
        assert_eq!(switch_plan(&current, &next, Some(None)), (Some("1.0.0".into()), None));
    }

    /// 本地 HTTP 服务（阻塞线程，代替 CDN）：任何 GET 都回 `body`。端口在建核心之前就定下来，registry 缓存才能写进 URL。
    fn serve(body: Vec<u8>) -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        std::thread::spawn(move || {
            for mut socket in listener.incoming().flatten() {
                let mut buf = [0u8; 4096];
                let _ = socket.read(&mut buf);
                let head = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
                let _ = socket.write_all(head.as_bytes());
                let _ = socket.write_all(&body);
            }
        });
        format!("http://{addr}/agent.zip")
    }

    /// 一个只含 `dist-package/agent.cmd` 的 zip（系统 tar 打）与它的 sha256。
    fn agent_zip(base: &Path) -> (Vec<u8>, String) {
        let src = base.join("src");
        std::fs::create_dir_all(src.join("dist-package")).expect("mkdir");
        std::fs::write(src.join("dist-package").join("agent.cmd"), b"@echo off\r\n").expect("write");
        let zip = base.join("agent.zip");
        let out = std::process::Command::new(registry::archive::tar_program())
            .arg("-a")
            .arg("-cf")
            .arg(&zip)
            .arg("-C")
            .arg(&src)
            .arg("dist-package")
            .output()
            .expect("tar");
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        (std::fs::read(&zip).expect("read"), registry::download::sha256_file(&zip).expect("sha"))
    }

    /// registry.json 缓存（核心建起来时读它）：一个 binary 条目，本平台的 target 指向 `url`。
    fn write_registry_cache(data: &Path, version: &str, url: &str, sha: &str) {
        let platform = current_platform_key().expect("platform");
        let index = json!({
            "version": "1",
            "agents": [{
                "id": "fake-bin", "name": "Fake", "version": version, "description": "",
                "distribution": { "binary": { platform: { "archive": url, "cmd": "./dist-package\\agent.cmd", "args": ["acp"], "sha256": sha } } }
            }]
        });
        std::fs::create_dir_all(data.join("registry-cache")).expect("mkdir");
        std::fs::write(data.join("registry-cache").join("registry.json"), index.to_string()).expect("write");
    }

    /// 等这个 agent 的收尾进度（done / failed / cancelled）；返回收尾那一步与期间的全部进度。
    fn wait_finished(events: &RecordingSink) -> (String, Vec<Value>) {
        let mut seen: Vec<Value> = Vec::new();
        for _ in 0..600 {
            for (channel, payload) in events.take() {
                if channel == EventChannel::RegistryProgress {
                    seen.push(serde_json::from_str(&payload).expect("json"));
                }
            }
            let last = seen.iter().filter_map(|p| p["step"].as_str()).find(|s| matches!(*s, "done" | "failed" | "cancelled")).map(str::to_string);
            if let Some(step) = last {
                return (step, seen);
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        panic!("升级没有收尾：{seen:?}");
    }

    fn list_entry(core: &Core) -> Value {
        let list = core.runtime().block_on(core.registry_list()).expect("list");
        list["agents"].as_array().expect("agents").iter().find(|a| a["id"] == "fake-bin").cloned().expect("entry")
    }

    fn load(data: &Path) -> InstallManifest {
        InstallManifest::load(&registry::RegistryDirs::new(data), "fake-bin").expect("load").expect("manifest")
    }

    /// binary 型升级全链路（验收 1）：可升级判定 → 已安装时拒绝首装 → 升级（进度都带 upgrade）→ 安装记录切到新目录、认证状态
    /// 与 settings env 继承、旧目录清掉 → 同版本再升被拒；新版本坏了（sha256 不符）时旧版原样可用、新目录不留；
    /// 启动清扫删掉残留的旧目录、不动在用的那个。
    #[test]
    fn binary_upgrade_switches_only_after_success_and_sweeps_the_old_directory() {
        let base = std::env::temp_dir().join(format!("acp-core-upgrade-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let data = base.join("data");
        let agent_dir = data.join("agents").join("fake-bin");
        let (zip, sha) = agent_zip(&base);
        let url = serve(zip);

        // 先放一份「装好的 1.0.0」（已登录）与带用户 env 的 settings 条目；registry 当前是 2.0.0。
        let v1 = agent_dir.join("1.0.0");
        std::fs::create_dir_all(v1.join("dist-package")).expect("mkdir");
        std::fs::write(v1.join("dist-package").join("agent.cmd"), b"@echo off\r\n").expect("write");
        let mut old = manifest(&v1, "1.0.0");
        old.id = "fake-bin".into();
        std::fs::write(agent_dir.join(MANIFEST_FILE), serde_json::to_string(&old).expect("json")).expect("write");
        write_registry_cache(&data, "2.0.0", &url, &sha);
        let events = Arc::new(RecordingSink::default());
        let core = Arc::new(Core::new(&data, events.clone()).expect("core"));
        let env = BTreeMap::from([("K".to_string(), "V".to_string())]);
        core.settings().upsert("fake-bin", AgentServer::Registry { env: env.clone(), extra: BTreeMap::new() }).expect("settings");

        let entry = list_entry(&core);
        assert_eq!(entry["updateAvailable"], "2.0.0");
        assert_eq!(entry["reloadPending"], Value::Null);
        assert!(core.registry_install("fake-bin").is_err(), "已安装时拒绝首装");

        core.registry_update("fake-bin").expect("start");
        let (step, seen) = wait_finished(&events);
        assert_eq!(step, "done", "{seen:?}");
        assert!(seen.iter().all(|p| p["upgrade"] == true), "{seen:?}");
        let steps: Vec<&str> = seen.iter().filter_map(|p| p["step"].as_str()).collect();
        assert!(steps.contains(&"download") && steps.contains(&"verify") && steps.contains(&"extract"), "{steps:?}");

        let upgraded = load(&data);
        assert_eq!(upgraded.version, "2.0.0");
        assert!(Path::new(&upgraded.command).starts_with(agent_dir.join("2.0.0")), "{}", upgraded.command);
        assert!(upgraded.is_intact());
        assert_eq!(upgraded.auth_status, AuthStatus::Authenticated, "认证状态继承");
        assert_eq!(upgraded.previous_version, None, "升级时没有连接");
        assert!(!v1.exists(), "旧目录不在用了就清掉");
        assert!(matches!(core.settings().get("fake-bin").expect("get"), Some(AgentServer::Registry { env: e, .. }) if e == env), "settings env 不动");
        assert_eq!(list_entry(&core)["updateAvailable"], Value::Null);
        assert!(core.registry_update("fake-bin").is_err(), "已是当前版本");
        drop(core);

        // registry 发了 3.0.0 但包是坏的（sha256 不符）：升级失败，2.0.0 原样可用，3.0.0 目录不留。
        write_registry_cache(&data, "3.0.0", &url, &"0".repeat(64));
        // 顺带放一个残留的旧目录，看启动清扫。
        let stale = agent_dir.join("0.9.0");
        std::fs::create_dir_all(&stale).expect("mkdir");
        let core = Arc::new(Core::new(&data, events.clone()).expect("core"));
        core.sweep_stale_installs();
        for _ in 0..200 {
            if !stale.exists() && lock(core.installs()).is_empty() {
                break;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        assert!(!stale.exists(), "启动清扫删掉不在用的旧目录");
        assert!(Path::new(&upgraded.command).is_file(), "在用的留着");

        core.registry_update("fake-bin").expect("start");
        let (step, seen) = wait_finished(&events);
        assert_eq!(step, "failed", "{seen:?}");
        assert!(seen.last().is_some_and(|p| p["upgrade"] == true));
        let after = load(&data);
        assert_eq!(after.version, "2.0.0", "失败不切换");
        assert!(after.is_intact());
        assert!(!agent_dir.join("3.0.0").exists(), "新目录删掉");
        let names: Vec<String> = std::fs::read_dir(&agent_dir).expect("dir").map(|e| e.expect("e").file_name().to_string_lossy().into_owned()).collect();
        assert!(!names.iter().any(|n| n.starts_with(".staging")), "{names:?}");
        assert_eq!(list_entry(&core)["updateAvailable"], "3.0.0", "失败之后仍可升级");
        drop(core);
        let _ = std::fs::remove_dir_all(&base);
    }
}
