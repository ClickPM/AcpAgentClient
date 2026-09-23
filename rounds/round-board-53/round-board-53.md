# Round board-53 — 画板 53「Registry 升级态」+ 画板 50 检查更新：registry 型 agent 的版本检查与升级

<!-- 画板 53 与画板 08 / 43 同类：R8 之后的单画板轮，登记在 ROUNDS.md § 7 进度表。走轮次而非迭代：新增核心命令、改 registry_list 与 registry/progress 的载荷，属改 docs/design.md § 3 契约（iterations/README.md § 0）。 -->

> 状态：进行中

## 目标

registry 型（npx / binary）agent 装好之后能看出「registry 有新版本」并手动升级：画板 50 标题行有检查时间与手动检查，条目出 `旧 → 新` + `可升级` + `Update`；升级时新版本装在旧版旁边，新版本通过（npx 握手）才切换，失败 / 取消时旧版本原样可用；正在运行的连接不打断，条目提示「重载后生效」。可证伪：把安装记录的 `version` 改成旧值 → 面板出可升级态 → 点 Update → 升级完成后 `install.json` 指向新目录、agent 能拉起、旧目录在不被占用时清掉。

## 前置

- `scripts/fetch-upstream.ps1 -Check` 九条全 OK（2026-09-23 本 worktree 实测；`vendor/upstream` 是指向主副本的目录联接）。
- 分支 `registry-upgrade`，worktree `D:\variFlight_work\AcpAgentClient-upgrade`，从 `main@8b56dbc` 开出。
- 设计稿已入库（`458815d`）：`design/round-design/53-registry-upgrade.dc.html` + PNG（1200 × 700）、`50-registry.dc.html` + PNG（三处改动，1440 × 1005），`canvas.json` 与 `design/README.md` 已更新；简报 `design/round-design/input/revision-06.md`。
- 所有者裁定（2026-09-23，按推荐项）：手动升级不做自动升级；判据「安装记录里的 registry 版本 ≠ registry.json 当前版本」只判不等；新版本并排装、通过才切换；不打断运行中的连接；提示只在 Agents 面板条目上；检查时机 = 启动 + 打开 Agents 面板（1 小时节流）+ 手动。

## 设计要点（开工前定下，实现照此）

1. **可升级判据**比 `install.json` 的 `version`（安装那一刻的 registry 版本），不比 `installedVersion`（npm 实际装到的；有界规格 `0.0.0 - X` 在 min-release-age 下可能偏低，拿它比会永远提示有更新）。registry 条目本平台不可装（uvx / 无 target）时不出。
2. **npx 改为按版本分目录**：新装与升级都装到 `agents/<id>/<version>/`（与 binary 同形）。**目录里先写一个 `package.json`**：npm 的 prefix 从 cwd 往上找最近的 `package.json` / `node_modules`，旧布局（`agents/<id>/node_modules`）下不写它，npm 会把新版本装回上一级、就地覆盖旧版。老安装记录里是绝对路径，照样能拉起，不迁移。
3. **并排装、通过才切换**：目标目录与当前目录撞名（版本号 sanitize 后相同）时加后缀；npx 装完用新拉起参数做一次握手，通过才写 `install.json`；binary 与首次安装一致不握手（解压成功即切换）。失败 / 取消只删新目录，旧 `install.json`、settings 条目与 env、认证状态都不动；认证状态与 settings env 继承。
4. **握手的临时连接不发 `acp/agent_state`**：它与正在运行的连接同一个 agentId，事件会让前端把运行中的连接当成已退出；流量（`acp/traffic`）照发。
5. **不打断运行中的连接**：核心每个 agent 一条连接，所以升级后运行中的连接仍是旧版，`registry_list` 带 `reloadPending`（运行中那条的版本）；`install.json` 记 `previousVersion`（连续升级两次不重载时保留最早那个）。前端在该 agent 重连 / 退出时重读列表把提示撤掉。
6. **旧目录清理**：只删「不被在用的拉起入口所在」的目录——升级成功且没有运行中连接时当场清；有连接时推迟到下次启动（启动时后台扫一遍，扫某个 agent 时占住它的安装槽，免得和紧接着的安装 / 升级撞上）。只删 `agents/<id>/` 下的子目录（旧版本目录、`.staging-*`）与旧布局根上的 `package.json` / `package-lock.json`；拉起入口不在 `agents/<id>/` 之下时整个 agent 不扫。
7. **进度载荷**：`registry/progress` 加 `upgrade: bool`；npx 升级的步骤是 `resolve → handshake` 两步（没有 `write_settings`，那一条升级前就有）。
8. `registry_install` 对已安装且完整的条目拒绝（改走 `registry_update`）：否则首装的回滚会连旧版一起删。

## 交付物

**核心（Rust）**
- `rust/registry/src/install.rs`：`version_dir`（按版本取新目录、撞名加后缀）、`install_npx` / `install_binary` 改为装到调用方给的目录（npx 先写 `package.json`）、`sweep_stale`（按在用入口清旧目录）。
- `rust/registry/src/manifest.rs`：`previousVersion` 字段；`entry_path()`（npx = `args[0]`，binary = `command`）。
- `rust/registry/src/lib.rs`：`Progress.upgrade`。
- `rust/acp-core/src/registry_ops.rs`：`registry_list` 加 `updateAvailable` / `reloadPending`；`registry_update`（后台任务，进度同 `registry/progress`）；`registry_install` 拒绝已安装；启动时的旧目录清扫；握手用过滤掉 `acp/agent_state` 的 sink。
- `rust/bridge/src/api.rs`：`registry_update`；`core_init` 新建核心后起清扫。frb 重新生成（生成物入库）。
- `docs/design.md` § 3 命令 / 事件载荷、§ 6 第 3 条与新增第 7 条。

**前端（Dart）**
- `lib/projection/registry.dart`：`updateAvailable` / `reloadPending`、`InstallProgress.upgrade` 与 npx 升级两步、状态判定（有新版本 / 升级中 / 升级失败 / 待重载）。
- `lib/ui/registry/registry_entry.dart`：版本「旧 → 新」、芯片组合、`Update`、升级中 / 升级失败 / 待重载的说明行。
- `lib/ui/registry/registry_panel.dart`：标题行「检查于 N 分钟前」+ 刷新按钮 / 「检查中…」+ spinner；标题行拆成 `RegistryPanelHeader`（画板 53 顶部样张复用）。
- `lib/app/agents_state.dart`：`upgrade` / `checkForUpdates`；失败态的「重试」按升级 / 安装分流。
- `lib/app/shell_state.dart` + `workbench_controller.dart` + `workbench_screen.dart`：打开 Agents 标签时节流刷新；agent 重连 / 退出时撤「待重载」；接线。
- `lib/app/core_bridge.dart`、`test/app/fake_core.dart`：`registryUpdate`。
- `lib/gallery/boards/agent_boards.dart`：画板 50 的 Codex 行 + 检查时间；新增画板 53 页。
- `lib/app/headless_run.dart`：`ACP_R5_UPGRADE`（验收 7 的真跑口子）。

## 验收

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | Rust 单测 | 版本目录撞名加后缀；npx 目标目录先有 `package.json`；`sweep_stale` 只删不在用的、入口不在 agent 目录下时不扫；`updateAvailable` / `reloadPending` 判定；已安装时 `registry_install` 拒绝；binary 升级全链路（本地 HTTP）切换后旧目录清掉、失败时旧版不动 |
| 2 | Dart 投影单测 | `updateAvailable` / `reloadPending` / `upgrade` 解析；npx 升级两步；升级失败 = 已安装 + failed |
| 3 | widget 测试 | 五态（有新版本 / 升级中 / 升级失败 / 待重载 / 需要认证 + 有新版本）的芯片、按钮、说明行；标题行检查时间 / 检查中 / 从没拉成功过不显示时间 |
| 4 | 接线测试 | Update → `registry_update`；升级失败的「重试」→ `registry_update`、首装失败的「重试」→ `registry_install`；刷新按钮 → `registry_refresh(force)`；打开 Agents 标签 → `registry_refresh`（不 force） |
| 5 | gallery | `50-registry` / `53-registry-upgrade` 出图，与 PNG 逐段对照 |
| 6 | `scripts/validate.ps1` | 全绿 |
| 7 | Windows 真跑（规则 9） | 无头 `ACP_R5_*` 在独立数据目录：装 npx agent → 改 `install.json` 的 `version` 成旧值 → 列表出 `updateAvailable` → `ACP_R5_UPGRADE` 升级 → 新目录、握手、旧目录清掉；再造一份**旧布局**（根上 `node_modules`）重跑，npm 不装回上一级、旧布局文件清掉；连着 agent 时升级 → `reloadPending` → Reload 后消失 |

## 禁止

- 不改 `lib/theme/tokens.dart`（画板 53 无新 token）。
- 不做自动升级、侧栏徽标、会话横幅、「可升级」过滤标签、「全部升级」（裁定）。
- 不改 `vendor/upstream/`（规则 4）；不碰 sidecar。

## 代码审查

- 审查方式：
- 审查器与模型：
- 审查范围与基准提交：
- findings 处理：
- 结论：

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-board-53/BLOCKED.md`，停下呼人。禁止放宽验收标准自我通过。

## 本轮实测

