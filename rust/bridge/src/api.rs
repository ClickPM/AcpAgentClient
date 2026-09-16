//! 桥命令与事件流（docs/design.md § 3）。R0 打通 `core_init` / `ping` 与五条事件流的注册；
//! R1 加连接 / 会话 / 认证 / 设置命令；R3 加工作区文件、git、项目与会话索引；
//! R4 加查看器读文件、目录监视（流命令）、git 状态、本地 shell 与终端控制、退出收尾；
//! R5 加 registry / 受管 Node / 设置页命令与第六条事件流 `registry/progress`。
//! 返回值一律 JSON `String`，结构化入参也是 JSON `String`（桥上不做类型镜像）。
//! 本模块是 frb 的扫描入口（flutter_rust_bridge.yaml `rust_input: crate::api`），只放要暴露给 Dart 的东西。
//!
//! 线程模型：frb 的 `async fn` 跑在 frb 自己的执行器上；核心的 future 必须在 `Core` 的 tokio runtime 上跑，
//! 所以每条命令都是 `runtime().spawn(...)` 再 `await` 那个 JoinHandle（JoinHandle 也把 panic 拦成 `Err`）。

use std::future::Future;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::sync::Arc;

use acp_core::core::Core;
use acp_core::events::{EventChannel, EventSink};
use flutter_rust_bridge::frb;
use serde_json::Value;

use crate::frb_generated::StreamSink;
use crate::runtime::{core_cell, sinks};

/// 跨桥的错误形状：Dart 侧作为 `BridgeError` 异常抛出。`code` 是 `CoreError::code()` 的稳定短码。
#[derive(Debug, Clone)]
pub struct BridgeError {
    pub code: String,
    pub message: String,
}

impl BridgeError {
    fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.to_string(),
            message: message.into(),
        }
    }
}

impl From<acp_core::error::CoreError> for BridgeError {
    fn from(e: acp_core::error::CoreError) -> Self {
        BridgeError::new(e.code(), e.to_string())
    }
}

fn core() -> Result<Arc<Core>, BridgeError> {
    let guard = core_cell()
        .read()
        .map_err(|_| BridgeError::new("poisoned", "core lock poisoned"))?;
    guard
        .as_ref()
        .cloned()
        .ok_or_else(|| BridgeError::new("not_initialized", "call core_init(data_dir) first"))
}

/// panic 不得穿过 FFI（docs/design.md § 12）：frb 自己也会 catch_unwind，这里再兜一层，统一成 `Result`。
fn guarded<T>(f: impl FnOnce() -> Result<T, BridgeError>) -> Result<T, BridgeError> {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(r) => r,
        Err(payload) => {
            let msg = payload
                .downcast_ref::<&str>()
                .map(|s| (*s).to_string())
                .or_else(|| payload.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "panic without message".to_string());
            Err(BridgeError::new("panic", msg))
        }
    }
}

/// 在核心的 runtime 上跑一条命令；结果 JSON 转成字符串。
async fn on_core<F, Fut>(f: F) -> Result<String, BridgeError>
where
    F: FnOnce(Arc<Core>) -> Fut,
    Fut: Future<Output = acp_core::error::Result<Value>> + Send + 'static,
{
    let core = guarded(core)?;
    let handle = core.runtime().spawn(f(core.clone()));
    match handle.await {
        Ok(Ok(value)) => Ok(value.to_string()),
        Ok(Err(e)) => Err(e.into()),
        Err(join) => Err(BridgeError::new("panic", join.to_string())),
    }
}

fn parse_json(name: &str, text: &str) -> Result<Value, BridgeError> {
    serde_json::from_str(text).map_err(|e| BridgeError::new("invalid_argument", format!("{name}: not valid JSON: {e}")))
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// 初始化核心。`data_dir` 是 docs/design.md § 10 的数据目录（Windows：%APPDATA%/AcpAgentClient）。
/// 幂等：热重启后再次调用只重发一条 `acp/agent_state: core_ready`。返回 JSON `{dataDir, coreVersion, logPath}`。
pub fn core_init(data_dir: String) -> Result<String, BridgeError> {
    guarded(|| {
        let sink: Arc<dyn EventSink> = sinks().clone();
        let mut guard = core_cell()
            .write()
            .map_err(|_| BridgeError::new("poisoned", "core lock poisoned"))?;
        let core = match guard.as_ref() {
            Some(existing) => {
                existing.announce_ready();
                existing.clone()
            }
            None => {
                let created = Arc::new(Core::new(data_dir, sink)?);
                *guard = Some(created.clone());
                created
            }
        };
        Ok(core.describe().to_string())
    })
}

/// R0 往返命令：Dart 调过来、核心回 JSON `{pong, sequence, coreVersion}`。
pub async fn ping(echo: String) -> Result<String, BridgeError> {
    guarded(|| Ok(core()?.ping(&echo)?.to_string()))
}

// ---- 连接与会话（R1）

/// 按 settings.json 的 `agent_servers[agent_id]` 拉起 agent 并完成 `initialize`；已连接的先断开。
/// `cwd` 是 agent 进程的工作目录（可选）。返回 `{agentId, initialize}`（`initialize` 是 InitializeResponse 原样 JSON）。
pub async fn agent_connect(agent_id: String, cwd: Option<String>) -> Result<String, BridgeError> {
    on_core(|core| async move { core.agent_connect(&agent_id, cwd.map(PathBuf::from)).await }).await
}

/// 关掉 agent（先关 stdin 等它自己退，超时结束进程树）。退出事件仍经 `acp/agent_state: exited` 推出。
pub async fn agent_disconnect(agent_id: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.agent_disconnect(&agent_id).await }).await
}

/// `session/new`。回 `-32000` 时抛 `auth_required`（authMethods 已经 `acp/agent_state: auth_required` 推出）。
/// 返回 NewSessionResponse 原样 JSON。
pub async fn session_new(agent_id: String, cwd: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.session_new(&agent_id, PathBuf::from(cwd)).await }).await
}

/// `session/prompt`。`prompt` 是 `ContentBlock[]` 的 JSON 字符串；本轮的 `session/update` 经事件流推出，
/// 本函数在回合结束时返回 PromptResponse 原样 JSON（stopReason + usage）。
pub async fn session_prompt(agent_id: String, session_id: String, prompt: String) -> Result<String, BridgeError> {
    let prompt = parse_json("prompt", &prompt)?;
    on_core(|core| async move { core.session_prompt(&agent_id, &session_id, prompt).await }).await
}

/// `session/cancel`：挂起的权限请求由核心自动回 `cancelled`；未完成的工具卡由前端本地标 cancelled（核心不伪造状态）。
/// 返回 `{cancelledRequestIds}`。
pub async fn session_cancel(agent_id: String, session_id: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.session_cancel(&agent_id, &session_id) }).await
}

/// `session/set_mode`（老 agent 的回退；configOptions 优先）。
pub async fn session_set_mode(agent_id: String, session_id: String, mode_id: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.session_set_mode(&agent_id, &session_id, &mode_id).await }).await
}

/// `session/set_config_option`。`value` 是 `SessionConfigOptionValue` 的 JSON（`{"type":"select","value":"x"}` /
/// `{"type":"boolean","value":true}`）。返回全量 configOptions（SetSessionConfigOptionResponse 原样 JSON）。
pub async fn session_set_config_option(
    agent_id: String,
    session_id: String,
    config_id: String,
    value: String,
) -> Result<String, BridgeError> {
    let value = parse_json("value", &value)?;
    on_core(|core| async move { core.session_set_config_option(&agent_id, &session_id, &config_id, value).await }).await
}

/// 回应 `acp/client_request`（`session/request_permission` / `elicitation/create`）。`request_id` 原样回传事件里的值，
/// `response` 是对应 Response 的 JSON 字符串。
pub async fn acp_respond(agent_id: String, request_id: String, response: String) -> Result<String, BridgeError> {
    let response = parse_json("response", &response)?;
    on_core(|core| async move { core.acp_respond(&agent_id, &request_id, response) }).await
}

// ---- 认证（docs/design.md § 5）

/// agent 型认证：`authenticate(methodId)`，agent 自己开浏览器；成功后由前端重试 `session_new`。
pub async fn authenticate(agent_id: String, method_id: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.authenticate(&agent_id, &method_id).await }).await
}

/// terminal 型认证：在可见终端（pty）里跑方法给的命令，输出经 `acp/terminal_output`（source = auth）推出，
/// 键盘输入走 `terminal_write`；进程退出后核心自动重试 `session/new`。返回 `{terminalId, exitStatus, session}`。
pub async fn terminal_auth_run(agent_id: String, method_id: String, cwd: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.terminal_auth_run(&agent_id, &method_id, PathBuf::from(cwd)).await }).await
}

/// 往终端写键盘输入（UTF-8 文本原样写进 pty）。R4 的本地 shell 四命令之一，terminal auth 需要它所以 R1 先出。
pub async fn terminal_write(terminal_id: String, data: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.terminal_write(&terminal_id, data.as_bytes()).await }).await
}

// ---- 本地交互 shell 与终端控制（R4，画板 61；docs/design.md § 3「本地 shell」）

/// 开一个本地 shell（系统默认 shell）：输出经 `acp/terminal_output`（source = local）推出。
/// `cols` / `rows` 是初始尺寸（之后由 `terminal_resize` 跟着视口走）。返回 `{terminalId, cwd, program}`。
pub async fn terminal_open(cwd: String, cols: u16, rows: u16) -> Result<String, BridgeError> {
    on_core(|core| async move { core.terminal_open(PathBuf::from(cwd), cols, rows).await }).await
}

/// 视口尺寸变化（xterm 报出的列 × 行）。
pub async fn terminal_resize(terminal_id: String, cols: u16, rows: u16) -> Result<String, BridgeError> {
    on_core(|core| async move { core.terminal_resize(&terminal_id, cols, rows) }).await
}

/// 结束终端里的进程但不释放（画板 23 的停止方块 = `terminal/kill` 语义；退出状态仍经 `acp/terminal_output` 推出）。
/// agent 建的终端也可以用它停（agent 的 `terminal/wait_for_exit` 会随之返回）。
pub async fn terminal_kill(terminal_id: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.terminal_kill(&terminal_id).await }).await
}

/// 关掉一个终端（认证页的停止方块与本地 shell 标签同一条命令）：还在跑就先结束进程，然后释放句柄；退出事件仍经 `acp/terminal_output` 推出。
pub async fn terminal_close(terminal_id: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.terminal_close(&terminal_id) }).await
}

/// 应用退出前的收尾：释放全部终端（还在跑的先结束）、断开全部 agent（超时结束进程树）、停掉目录监视。
/// 返回 `{terminals, agents}`。Dart 侧在 `AppLifecycleListener.onExitRequested` 里等它回来再放行退出。
pub async fn core_shutdown() -> Result<String, BridgeError> {
    on_core(|core| async move { core.core_shutdown().await }).await
}

// ---- 设置

/// 读 `settings.json`（不存在 → `{agent_servers: {}}`）。
pub async fn agent_settings_get() -> Result<String, BridgeError> {
    on_core(|core| async move { core.agent_settings_get() }).await
}

/// 覆盖 `agent_servers[agent_id]`（`server` 是 `{type: "custom", command, args, env}` 的 JSON），临时文件 + rename 落盘；
/// 返回落盘后的全量设置。
pub async fn agent_settings_set(agent_id: String, server: String) -> Result<String, BridgeError> {
    let server = parse_json("server", &server)?;
    on_core(|core| async move { core.agent_settings_set(&agent_id, server) }).await
}

/// 删掉 `agent_servers[agent_id]`（custom 型从设置页删除；registry 型请走 `registry_remove`，它还会清 `agents/<id>/`）。
/// 已连接的先断开。返回落盘后的全量设置。
pub async fn agent_settings_remove(agent_id: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.agent_settings_remove(&agent_id).await }).await
}

/// 从 Zed 的 `settings.json` 导入 `agent_servers`（JSONC，同名不覆盖）。返回 `{report: {path, imported, skipped, invalid}, settings}`；
/// 找不到 Zed 的文件时抛 `settings`。
pub async fn agent_settings_import_zed() -> Result<String, BridgeError> {
    on_core(|core| async move { core.agent_settings_import_zed() }).await
}

/// 开发期排查：每个已连接 agent 的 droppedUpdates / 退出状态 / 挂起请求。
pub async fn agents_status() -> Result<String, BridgeError> {
    on_core(|core| async move { Ok(core.agents_status()) }).await
}

// ---- registry 与受管 Node（R5；docs/design.md § 3「registry、Node 与设置」，§ 6）

/// registry 列表：`{agents: [{id, name, version, description, repository?, website?, iconSvg?, distribution, supported, package?,
/// installed: {kind, version, installedVersion?, command, args, env, authStatus, agentInfo?, installedAt} | null, installing, custom: {command, args, env} | null}],
/// fetching, fetchError?, fetchedAt?, node: {system?, systemError?, managed?, minVersion}, paths: {dataDir, logPath, zedSettingsPath?}}`。
/// 只读缓存，不联网（联网是 `registry_refresh`）；已安装 / custom 条目排前面。
pub async fn registry_list() -> Result<String, BridgeError> {
    on_core(|core| async move { core.registry_list().await }).await
}

/// 联网拉 `registry.json`（1 小时节流，`force` 跳过）并顺手补图标；失败不清缓存、错误进 `fetchError`。返回同 `registry_list`。
pub async fn registry_refresh(force: bool) -> Result<String, BridgeError> {
    on_core(|core| async move { core.registry_refresh(force).await }).await
}

/// 后台安装一个 registry 条目（npx：resolve / write_settings / handshake；binary：download / verify / extract），立即返回
/// `{agentId, started}`；进度与收尾（done / failed / cancelled）经 `registry/progress` 推出。已在安装中抛 `invalid_argument`。
pub async fn registry_install(agent_id: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.registry_install(&agent_id) }).await
}

/// 取消正在跑的安装；返回 `{agentId, cancelled}`（没有在装的 `cancelled: false`）。
pub async fn registry_cancel_install(agent_id: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.registry_cancel_install(&agent_id) }).await
}

/// Remove：取消安装、断开连接、删 settings 条目、只删 `agents/<id>/`（规则 7）。返回同 `registry_list` 再加 `removed`。
pub async fn registry_remove(agent_id: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.registry_remove(&agent_id).await }).await
}

/// Node 状态：`{system: {version, path}?, systemError?, managed: {version, path}?, minVersion}`。
pub async fn node_status() -> Result<String, BridgeError> {
    on_core(|core| async move { core.node_status().await }).await
}

/// 下载受管 Node v24.11.0 到数据目录 `node/`（进度 `agentId: null`，步骤 node_download / node_extract），完成后返回 Node 状态。
pub async fn node_download() -> Result<String, BridgeError> {
    on_core(|core| async move { core.node_download().await }).await
}

// ---- 工作区文件与 git（R3；docs/design.md § 3「文件面板与 git」）

/// 列一层目录。`root` 是当前项目目录，`path` 必须在它之内（越界报 `fs`）。
/// 返回 `{path, entries: [{name, path, parent, isDir, size}]}`，目录在前、各自按名排序。
pub async fn fs_list_dir(root: String, path: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.fs_list_dir(PathBuf::from(root), PathBuf::from(path)).await }).await
}

/// 按名字子串搜索（`@` 提及）。返回 `{files, directories, truncated}`；`query` 为空时不遍历、直接回空。
pub async fn fs_search(root: String, query: String, limit: u32) -> Result<String, BridgeError> {
    on_core(|core| async move { core.fs_search(PathBuf::from(root), query, limit as usize).await }).await
}

/// 查看器读文件（画板 60，R4）：`{path, text, size, lines, binary, truncated}`；超过 2 MiB 只给前一段并标 `truncated`，
/// 含 NUL 的按二进制处理（`text` 为空）。`path` 必须在 `root` 之内。
pub async fn fs_read(root: String, path: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.fs_read(PathBuf::from(root), PathBuf::from(path)).await }).await
}

/// 监视项目目录（R4）：流命令——每批去抖后的变化推一条 `{root, dirs: [绝对路径…], git}`（`dirs` 是内容变了的目录，
/// `git` = `.git` 之下有变化）；Dart 侧取消流即停止。同一 `root` 再次调用替换旧监视器。
#[frb(sync)]
pub fn fs_watch(root: String, sink: StreamSink<String>) -> Result<(), BridgeError> {
    guarded(|| {
        core()?.fs_watch(PathBuf::from(root), move |payload| sink.add(payload).is_ok())?;
        Ok(())
    })
}

/// 停掉某个根的监视；没在监视也不报错。返回 `{root, removed}`。
pub async fn fs_unwatch(root: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.fs_unwatch(PathBuf::from(root)) }).await
}

/// 文件树的 git 状态徽章（画板 60，所有者裁定 2026-09-15）：`{available, isRepo, root, entries: [{path, badge, code}]}`。
/// 非仓库 / 无 git 不报错，`entries` 为空。
pub async fn git_status(cwd: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.git_status(PathBuf::from(cwd)).await }).await
}

/// 本地分支列表：`{available, isRepo, current, branches: [{name, author, when, subject}]}`。
/// 找不到 `git`（`available: false`）或目录不是仓库（`isRepo: false`）都不是错误——前端据此把顶栏分支区整块隐藏。
pub async fn git_branches(cwd: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.git_branches(PathBuf::from(cwd)).await }).await
}

/// `git switch <branch>`；返回切换后的分支列表。git 报错（例如有未提交改动）时抛 `fs`，消息是 git 自己的 stderr。
pub async fn git_switch(cwd: String, branch: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.git_switch(PathBuf::from(cwd), branch).await }).await
}

/// `git switch -c <branch>`（从当前 HEAD 拉）；返回切换后的分支列表。
pub async fn git_create_branch(cwd: String, branch: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.git_create_branch(PathBuf::from(cwd), branch).await }).await
}

/// `git diff`：给了 `base` 就是 `git diff <base>...HEAD`，否则是工作区相对 HEAD 的改动。
/// 返回 `{available, isRepo, command, text, truncated}`；输出超过 200 KiB 截断（整份 diff 进 prompt 会顶爆上下文）。
pub async fn git_diff(cwd: String, base: Option<String>) -> Result<String, BridgeError> {
    on_core(|core| async move { core.git_diff(PathBuf::from(cwd), base).await }).await
}

// ---- 项目与会话的本地索引（R3；docs/design.md § 10。时间戳一律 Unix 毫秒）

/// 最近项目列表：`{projects: [{path, name, openedAt}]}`（按 `openedAt` 倒序）。
pub async fn workspace_recent() -> Result<String, BridgeError> {
    on_core(|core| async move { core.workspace_recent() }).await
}

/// 打开一个本地目录作为项目（`session/new` 的 cwd）：写进最近列表，返回 `{project, projects}`。
/// 目录不存在或不是目录时抛 `settings`。
pub async fn workspace_open(path: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.workspace_open(PathBuf::from(path)) }).await
}

/// 会话索引全量：`{sessions: [{agentId, sessionId, title?, cwd?, createdAt, updatedAt, messageCount}]}`。
pub async fn session_index_list() -> Result<String, BridgeError> {
    on_core(|core| async move { core.session_index_list() }).await
}

/// 新增 / 更新一条会话索引（`entry` 是上面那个形状的 JSON 字符串）；返回全量列表。
/// `createdAt` 只在新增时写；`updatedAt` 省略或为 0 时由核心打当前时间。
pub async fn session_index_upsert(entry: String) -> Result<String, BridgeError> {
    let entry = parse_json("entry", &entry)?;
    on_core(|core| async move { core.session_index_upsert(entry) }).await
}

/// 移除一条会话索引；返回全量列表。向 agent 发 `session/delete` 是 R6 的事。
pub async fn session_index_remove(agent_id: String, session_id: String) -> Result<String, BridgeError> {
    on_core(|core| async move { core.session_index_remove(&agent_id, &session_id) }).await
}

/// 窗口 UI 状态：`{sidebarWidth?, rightPanelWidth?}`。没存过的字段是 null，缺省宽度在前端 token 里。
pub async fn ui_state_get() -> Result<String, BridgeError> {
    on_core(|core| async move { core.ui_state_get() }).await
}

/// 合并写窗口 UI 状态（`patch` 是上面那个形状的 JSON 字符串，只给要改的字段）；返回落盘后的全量状态。
pub async fn ui_state_set(patch: String) -> Result<String, BridgeError> {
    let patch = parse_json("patch", &patch)?;
    on_core(|core| async move { core.ui_state_set(patch) }).await
}

// 六个注册函数都是 `#[frb(sync)]`：frb 的 normal 任务跑在线程池上不保证先后，只有同步注册
// 才能保证 Dart 调 `core_init` 之前 sink 已就位（审查 finding，2026-09-15）。

/// `acp/session_update`：`{agentId, sessionId, update, _meta?}`，即 SessionNotification 原样 JSON 加 `agentId`。
#[frb(sync)]
pub fn session_update_stream(sink: StreamSink<String>) -> Result<(), BridgeError> {
    sinks().register(EventChannel::SessionUpdate, sink);
    Ok(())
}

/// `acp/client_request`：`{agentId, requestId, method, params}`；`requestId` 为 null 的是通知
/// （`elicitation/complete`、`$/cancel_request`），不需回应。
#[frb(sync)]
pub fn client_request_stream(sink: StreamSink<String>) -> Result<(), BridgeError> {
    sinks().register(EventChannel::ClientRequest, sink);
    Ok(())
}

/// `acp/agent_state`：core_ready / spawned / initialized / auth_required / authenticating / update_dropped / exited。
#[frb(sync)]
pub fn agent_state_stream(sink: StreamSink<String>) -> Result<(), BridgeError> {
    sinks().register(EventChannel::AgentState, sink);
    Ok(())
}

/// `acp/terminal_output`：`{terminalId, source, bytes}`（base64）或 `{terminalId, source, exitStatus}`。
#[frb(sync)]
pub fn terminal_output_stream(sink: StreamSink<String>) -> Result<(), BridgeError> {
    sinks().register(EventChannel::TerminalOutput, sink);
    Ok(())
}

/// `acp/traffic`：`{agentId, direction, line, ts}`，`line` 是脱敏后的原始 JSON-RPC 行（或 stderr 行）。
#[frb(sync)]
pub fn traffic_stream(sink: StreamSink<String>) -> Result<(), BridgeError> {
    sinks().register(EventChannel::Traffic, sink);
    Ok(())
}

/// `registry/progress`：`{agentId?, kind, step, done?, total?, detail?, error?}`（R5；`agentId` 为 null 是受管 Node）。
#[frb(sync)]
pub fn registry_progress_stream(sink: StreamSink<String>) -> Result<(), BridgeError> {
    sinks().register(EventChannel::RegistryProgress, sink);
    Ok(())
}

/// 未送达（Dart 未订阅或流已关闭）的事件计数，供开发期排查。
#[frb(sync)]
pub fn dropped_event_count() -> u64 {
    sinks().dropped()
}
