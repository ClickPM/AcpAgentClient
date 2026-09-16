//! registry 面板 / 认证状态 / 设置页背后的编排（docs/design.md § 5 / § 6，R5）：把 `rust/registry` 的安装步骤、
//! settings.json 的写入与首次 `initialize` 握手串成画板 51 的三步，进度经 `registry/progress` 推出；Remove、受管 Node、
//! 从 Zed 导入、registry 型的拉起也在这里。安装任务在核心的 runtime 上后台跑，命令立即返回，取消经 [`CancelToken`]。

use std::collections::BTreeMap;
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

impl Core {
    fn progress_sink(&self) -> ProgressEvents {
        ProgressEvents { sink: self.event_sink() }
    }

    // ---- 列表与刷新

    /// `registry_list`：registry 条目（带本地安装 / 认证状态）+ settings 里的 custom 条目，已安装的排前面；
    /// 另带拉取状态、Node 状态与几个路径（数据目录、日志、Zed settings）。
    pub async fn registry_list(&self) -> Result<Value> {
        let snap = self.registry_index().snapshot();
        let settings = self.settings().load()?;
        let platform = current_platform_key();
        let installing: Vec<String> = lock(self.installs()).keys().cloned().collect();
        let dirs = self.registry_dirs();
        let mut agents: Vec<(bool, Value)> = Vec::new();
        for entry in &snap.agents {
            let resolved = entry.resolve(platform);
            let manifest = InstallManifest::load(dirs, &entry.id).ok().flatten().filter(|m| m.is_intact());
            let installed = manifest.is_some();
            let package = match &resolved {
                Resolved::Npx(npx) => Some(npx.package.clone()),
                _ => None,
            };
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
                    "supported": !matches!(resolved, Resolved::Unsupported | Resolved::Uvx),
                    "package": package,
                    "installed": manifest.as_ref().map(InstallManifest::to_json),
                    "installing": installing.contains(&entry.id),
                    "custom": Value::Null,
                }),
            ));
        }
        for (id, server) in &settings.agent_servers {
            if let AgentServer::Custom { path, args, env, .. } = server {
                agents.push((
                    true,
                    json!({
                        "id": id,
                        "name": id,
                        "version": "",
                        "description": "",
                        "distribution": "custom",
                        "supported": true,
                        "installed": Value::Null,
                        "installing": false,
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
    pub fn registry_install(self: &Arc<Self>, agent_id: &str) -> Result<Value> {
        let entry = self
            .registry_index()
            .entry(agent_id)
            .ok_or_else(|| CoreError::InvalidArgument(format!("registry 里没有 `{agent_id}`（先刷新列表）")))?;
        let token = CancelToken::new();
        {
            let mut installs = lock(self.installs());
            if installs.contains_key(agent_id) {
                return Err(CoreError::InvalidArgument(format!("`{agent_id}` 正在安装")));
            }
            installs.insert(agent_id.to_string(), token.clone());
        }
        let core = self.clone();
        let id = agent_id.to_string();
        self.runtime().spawn(async move {
            let kind = match entry.resolve(current_platform_key()) {
                Resolved::Binary(_) => "binary",
                _ => "npx",
            };
            let result = core.run_install(&entry, token.clone()).await;
            lock(core.installs()).remove(&id);
            let sink = core.progress_sink();
            match result {
                Ok(()) => sink.progress(Progress::new(Some(&id), kind, "done")),
                Err(e) => {
                    let step = if matches!(e, CoreError::Registry(RegistryError::Cancelled)) { "cancelled" } else { "failed" };
                    let mut p = Progress::new(Some(&id), kind, step);
                    p.error = Some(e.to_string());
                    sink.progress(p);
                }
            }
        });
        Ok(json!({ "agentId": agent_id, "started": true }))
    }

    async fn run_install(self: &Arc<Self>, entry: &RegistryEntry, token: Arc<CancelToken>) -> Result<()> {
        let dirs = self.registry_dirs();
        let sink = self.progress_sink();
        match entry.resolve(current_platform_key()) {
            Resolved::Npx(npx) => {
                let node = registry::node::locate(dirs).await?;
                let mut manifest = registry::install::install_npx(dirs, entry, &npx, &node, token.clone(), &sink).await?;
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
                        connected = AgentConnection::connect(entry.id.clone(), launch, None, self.event_sink()) => connected?,
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
            Resolved::Binary(target) => {
                let manifest = registry::install::install_binary(dirs, entry, &target, self.http(), token.clone(), &sink).await?;
                token.check()?;
                self.write_registry_settings(&entry.id)?;
                manifest.save(dirs)?;
                Ok(())
            }
            Resolved::Uvx => Err(RegistryError::Unsupported("registry 条目声明的安装方式是 uvx，本版本暂不支持".into()).into()),
            Resolved::Unsupported => Err(RegistryError::Unsupported("registry 条目没有本平台可用的分发方式".into()).into()),
        }
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
