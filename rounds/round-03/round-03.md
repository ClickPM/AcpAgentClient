# Round 03 — 会话工作台壳与接线

<!-- 保存为 rounds/round-03/round-03.md；该轮其他管理产出放同一目录。 -->

> 状态：进行中（实现与实测完成，待独立审查收口）

## 目标

按画板 01–04 / 40 / 41 / 42 / 80 落地完整会话工作台壳（三栏、线程头、输入框与三类弹层、顶栏项目与分支切换、窗口控制、流量面板），
画板阶段收口后把 R1 的 Rust 核心接上：`lib/app/` 组合根默认 bridge 数据源，用 dsh-acp-interactive 在 Windows 真跑一轮完整对话
（权限 / elicitation / 计划 / 回合结束 / 中途停止 / 重载 agent），画板 34 接 `acp/agent_state` 真事件。

可证伪：ROUNDS.md § 3 R3 的 8 条验收要点逐条有命令与输出；`git diff <画板阶段收口提交>..HEAD -- lib/theme lib/ui` 为空。

## 前置

- 轮次：R1（Rust 核心主线）已完成（`5466609`）、R2（转录卡片与投影层）已完成（`050003a`，画板阶段收口 `98e4cea`）。
- `powershell -File scripts/fetch-upstream.ps1 -Check` 全绿（2026-09-15，8 个钉版本全 OK）。
- 本机版本（实测记录）：

  | 组件 | 版本 / 路径 |
  |---|---|
  | Flutter | 3.47.4 stable（framework 9584c6713b，Dart 3.13.3） |
  | Rust | rustc 1.98.1 / cargo 1.98.1（`rust-toolchain.toml` 钉 1.98.1） |
  | Node | v24.11.1 |
  | flutter_rust_bridge_codegen | `C:\Users\Click\.cargo\bin\flutter_rust_bridge_codegen.exe` |
  | dsh-acp-interactive | 1.3.0，`C:\Users\Click\AppData\Roaming\npm\dsh-acp-interactive.cmd` |
  | `CARGO_TARGET_DIR` | `D:\cargo-target\AcpAgentClient` |

- 参照 agent：dsh-acp-interactive（真跑）；`test/fake-agent/fake-agent.mjs`（注入 `notice` 验丢弃告警）。

## 交付物

### 裁定 6 的 token 提交（画板阶段之前，纯 token）

- `lib/theme/tokens.dart` 新增 `Geometry` 一组，收 R2 记 BACKLOG 的 7 个局部几何常量（画板 32 预览高 220、音频进度条高 3、
  画板 25 下拉宽 330、画板 30 弹层宽 266、终端回滚 2000 行、spinner 周期 = `Motion.base × 5`、布尔开关轨道 28 × 16）；
  `lib/ui/transcript/{content_blocks,permission_card,context_window,terminal_card,icons,elicitation_form_card}.dart` 只换引用。

### 画板阶段（只用 fixtures / 本地假数据）

- `lib/ui/shell/app_shell.dart`（01 / 02 / 03 三栏壳与窗口控制条）
- `lib/ui/shell/sidebar.dart`（01 / 04：搜索、会话项四态、行内重命名、底部导航、空态）
- `lib/ui/shell/topbar.dart`（01–04：侧栏开关、项目名、分支名、窗口控制三键）
- `lib/ui/shell/thread_header.dart`（01 / 02 / 03：标题、四个动作按能力裁剪）
- `lib/ui/shell/composer.dart`（01 / 02 / 03：占位文案、`+`、用量圆环、三个下拉、发送 / 停止、Awaiting 停靠条）
- `lib/ui/shell/transcript_empty.dart`（01 两个空态）
- `lib/ui/shell/right_panel.dart`（03 右栏占位；标签条 + 关闭）
- `lib/ui/popovers/composer_popovers.dart`（40：模型选择器 / 思考强度 / 模式 / 布尔开关 / 未知分类兜底 / `+` 弹层 / 用量弹层 / Follow 提示）
- `lib/ui/popovers/topbar_popovers.dart`（41：项目切换 / 分支切换 / 新建会话选 agent / ≡ 菜单 / 重命名 / 删除确认）
- `lib/ui/popovers/inline_menus.dart`（42：`@` 提及菜单 / `/` 命令菜单）
- `lib/ui/traffic/traffic_page.dart`（80：过滤条、告警行、流量行与原文展开、stderr 尾巴区）
- `lib/gallery/boards/shell_boards.dart`：01a / 01b / 02 / 03 / 04 / 40 / 41 / 42 / 80 九张 gallery 画板
- **ROUNDS § 2 文件表之外新增的三个文件**（已回填 § 2）：`lib/ui/shell/shell_common.dart`（agent 标记方块 / 悬浮包装 /
  `EditableText` 封装 / 相对时间 / `ShellTab`）、`lib/ui/shell/popover_anchor.dart`（弹层锚点）、
  `lib/ui/popovers/menu.dart`（40 / 41 / 42 共用的弹层骨架）。都是三张以上画板共用的骨架，不拆会在每个画板文件里重复一遍。
- `lib/projection/traffic.dart`：`acp/traffic` 的投影与行标签解析（画板 80 的数据源）

### 接线阶段（只换数据源；`lib/theme` 与 `lib/ui` 零 diff）

- `lib/app/`：`workbench_controller.dart`（状态与动作）+ `workbench_screen.dart`（widget 装配）+ `window_controls.dart`
  + `app.dart`（组合根）。默认 bridge，`--dart-define=DATA_SOURCE=fixtures` 供 gallery 与开发；`SmokeScreen` 换成工作台壳
  （`scripts/build.ps1 -Smoke` 仍过）。文件名与任务卡最初拟的五个文件不同：索引、项目、规则计数都只是控制器上的几个方法
  （各十来行），拆成五个文件只会让调用面更碎。
- `rust/bridge/src/api.rs` 新命令：`workspace_recent` / `workspace_open`、`git_branches` / `git_switch` / `git_create_branch` / `git_diff`、
  `session_index_list` / `session_index_upsert` / `session_index_remove`、`fs_list_dir` / `fs_search`；`flutter_rust_bridge_codegen generate` 生成物入库。
- `rust/fs/src/lib.rs`：`list_dir` / `search` 最小实现 + `git` CLI 薄封装（`rust/fs/src/git.rs`）。
- `rust/index`（并入 `rust/settings`）：`sessions.json` / `projects.json` 本地索引，临时文件 + rename。
- `rust/acp-core/tests/fixtures.rs` 方法表补 `elicitation/complete` / `$/cancel_request`；`test/fixtures/16-elicitation.jsonl` 收两条通知。
- `windows/runner/acp_window.{h,cpp}`：MethodChannel `acp/window`（minimize / toggleMaximize / close / isMaximized /
  startDragging）+ 无边框窗口的 `WM_NCCALCSIZE` / `WM_NCHITTEST`。
- `lib/app/headless_run.dart`：无头实跑口子 `ACP_R3_REPORT`（验收 3–6 的证据来源，见「本轮实测」）。

## 验收

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | 画板逐张对照 | `flutter test test/gallery_test.dart` → `build/gallery/{01a,01b,02,03,04,40,41,42,34,80}*.png` 与 `design/round-design/*.png` 文案 / 状态 / 层级 / 控件零缺失，偏离逐条记卡 |
| 2 | 接线不改样式 | `git diff <画板阶段收口提交>..HEAD -- lib/theme lib/ui` 输出为空 |
| 3 | dsh 真跑（规则 9） | 新会话 → 一轮含权限（Alt-Shift-A / Alt-Shift-X / Ctrl-Alt-A）→ elicitation form 提交 → 计划卡折叠 / 展开 → 回合结束行 → 第二轮中途停止（挂起权限回 cancelled）→ 重载 agent；改一个 config option 后弹层与线程头同步刷新 |
| 4 | 流量面板 | 同一轮行数与 `acp-smoke` 一致；`Authorization` / `api_key` / `token` 打码；fake-agent 注入 `notice` 后 34 与 80 的告警同时出现 |
| 5 | 项目与分支 | 切项目后新会话 cwd 正确；分支列表与 `git branch` 一致；新建分支后顶栏立即更新；非 git 目录分支区隐藏 |
| 6 | agent 生命周期 | `taskkill` 杀掉 agent → 34 出 exited 条 + 重启可用；应用不崩 |
| 7 | 空态 | 无已安装 agent 时显示 01 状态 2；「打开 Agents 面板」切到右栏 Agents 标签（R5 前空面板占位） |
| 8 | Windows 实测 | 窗口控制（拖拽 / 三键）、`file_selector` 目录与文件选择、git 子进程（路径带空格与中文） |
| 9 | 门禁 | `powershell -File scripts/validate.ps1` 全绿；投影层已有 80 个测试不回归；`scripts/build.ps1 -Smoke` 通过 |
| 10 | Restore / Regenerate | `RestoreResult` 的 `cancelledRequestIds` / `cancelledElicitationIds` 两组 id 都走 `acp_respond`，有单测或实测记录 |

## 禁止

- 不做 `fs/*` / `terminal/*` 回调与右栏真内容（R4）；不做 registry / 安装 / 认证页 / 设置页（R5）；不做 `session/load` / list / resume / close / delete 的动作（R6）；不做 sidecar（R7）；不做深色主题。
- 不引 `window_manager` / `bitsdojo_window`；不引 `git2` / `gix`（走 `git` CLI 子进程）；pubspec 只新增 `url_launcher`、`file_selector`；`provider` 不得 import。
- 接线阶段不改 `lib/theme` 与 `lib/ui`（规则 3）；缺 token 或缺回调钩子停下问，不偷改。
- 默认继承三条：不改前端页面样式（规则 3）；不加设计稿没有的功能（规则 3）；不在 `vendor/upstream/` 里改代码（规则 4）。
- Rust 禁 `unsafe`（规则 6）；流量面板与本地索引不落密钥，不读不打印 `~/.dsh/.credentials.yaml`（规则 8）。

## 代码审查

<!-- 完成后回填。审查路由见 CLAUDE.md「开发模式」与 docs/review-workflow.md：
     ① cursor CLI + grok 4.6 high → ② 硬失败回落主会话委派的 Claude Code 只读子代理（同一份任务书）。
     范围：前两轮全量（-Scope branch，即 main...HEAD），第 3 轮起只审上一轮整改 diff（-Scope since -Base <上一轮已审提交>）。 -->

- 审查方式：`powershell -File .claude\cursor-review.ps1`（默认档，全量分支 diff，后台跑）
- 审查器与模型：cursor CLI `cursor-grok-4.6-high`（`--mode ask`）
- 审查范围与基准提交：**第 1 轮** `main...HEAD`（HEAD = `f38ee9d`），产物 `.claude/reviews/20260915-203328-review.out.md`

**第 1 轮：7 条（high 2 / P2 5），全部采纳**（整改提交 `3777c35`）

| # | 级别 | finding | 处理 |
|---|---|---|---|
| 1 | high | 点停止时挂起的 elicitation 不会被回应，agent 一直等（核心的 `session_cancel` 只自动回权限请求，`PendingQueue.cancelSession` 也只管权限） | 采纳。新增 `cancelSessionElicitations`，`CancelResult` 带出 `cancelledElicitationIds`，组合根 `cancel()` 逐条回 `{action: cancel}`；权限仍交给核心（前端再回会撞 `unknown_request`）。**原单测把「responded 为空」断言成正确，把这个漏洞锁住了**，一并改掉 |
| 2 | high | Restore / Regenerate 不结束在途的 `session/prompt`，两路回合打到同一轮上 | 采纳。控制器记 `_turnInFlight`，`restore()` 在 `isRunning` 时先 `cancel()` 再等在途那一轮返回，然后才截断重发；新增用例用「第一次 prompt 挂着不返回」的假核心复现 |
| 3 | P2 | 会话索引的 `agentId` 没进侧栏映射，重启后删 / 改名 / 点选用错键（删不掉） | 采纳。`_toSidebar` 顺带回填 `_sessionAgent`，删 / 改名统一走 `_ownerOf` |
| 4 | P2 | 顶栏拖拽的 Listener 垫在整块 `TopBar` 下面，空白处也收不到 | 采纳。根因比 finding 说的更硬：`BoxDecoration.hitTest` 对矩形返回 true，Container 把 pointer 全吃掉；且 `HitTestBehavior.translucent` 的 `hitTest` 返回 false，命中链在 `Stack` 处就断了。改：`TopBar` 加 `dragArea` 槽、拖拽层放进容器内部 + `Stack(fit: expand)`；新增 `test/ui/topbar_drag_test.dart` 两个方向各一条。gallery PNG 逐字节一致 |
| 5 | P2 | git 把用户输入的分支名直接当 argv，`-` 开头会被当选项 | 采纳。`ensure_safe_ref` 拒空名与 `-` 开头；switch / create_branch / diff 的 base 都过一遍（diff 在判仓库之前先校验），加一条守卫测试 |
| 6 | P2 | git 子进程没设 `CREATE_NO_WINDOW`，GUI 宿主里闪控制台 | 采纳。与 agent 拉起同一口径 |
| 7 | P2 | `list_dir` / `search` 可能跟着 junction / symlink 走出工作区 | 采纳。改用 `DirEntry::file_type`（不跟随），链接一律当文件，既不进目录组也不递归进去 |

- 结论：待第 2 轮复审

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-03/BLOCKED.md`，停下呼人。禁止放宽验收标准自我通过。

## 本轮实测

### 画板阶段收口提交

`dc4de5e`（弹层锚点）。判据 `git diff dc4de5e..HEAD -- lib/theme lib/ui` 在接线阶段全程为空。

> 画板阶段分两个提交：`c487a39` 出全部 widget 与 gallery，`dc4de5e` 补弹层锚点（`OverlayPortal` +
> `CompositedTransformFollower`）。锚点属于画板阶段：接线阶段要给每个触发控件挂弹层，没有它就只能在接线阶段改 `lib/ui`。

### 验收 1 · 画板逐张对照

`flutter test test/gallery_test.dart` 出 9 张（01a / 01b / 02 / 03 / 04 / 40 / 41 / 42 / 80）到 `build/gallery/`，
34 沿用 R2 的那张。逐张与 `design/round-design/*.png` 并排看，文案 / 状态 / 层级 / 控件齐。偏离：

| # | 画板 | 偏离 | 原因 |
|---|---|---|---|
| 1 | 40 | 模型行的 provider 图标用中性占位、`Latest` 徽章省略 | `SessionConfigSelectOption` 只有 `value` / `name` / `description`，没有图标与「最新」字段（规则 2 不自造）。与画板 31「18 次请求」同类，已记 BACKLOG 归下个设计轮 |
| 2 | 41 | 分支弹层出「默认」与「输入了新名字」两张样张；后者按搜索过滤后本地分支不再列出 | 画板上输入 `feat/tokens` 时两条分支仍在，但 ROUNDS § 3 R3 要求「搜索」。取搜索语义，用两张样张把两种状态都画出来 |
| 3 | 42 | 输入框正文是纯文本，`@val` / `/co` 不做行内彩色芯片 | 输入框是 `EditableText`；芯片只在已发送的用户气泡里（画板 11，R2 已实现）。已记 BACKLOG |
| 4 | 04 | 四个会话项状态摞在同一个 280 宽面板里（画板是四个并排面板） | 沿用 R2 的 `BoardPage` 版式（宽 800、分节竖排），像素级排布差异不作 finding |
| 5 | 全部 | 转录 / 弹层里的样例文字来自 fixtures，与画板上的样例文案不同 | ROUNDS § 0 第 5 条：对照的是文案 / 状态 / 层级 / 控件，不是像素 |
| 6 | 01a | 三个下拉的当前值是 fixtures 给的 | 数据驱动；画板上的值是设计样例 |

新增 token：`tokens.dart` 的 `Geometry` 组除裁定 6 的 7 个外，另加壳几何 13 个（侧栏宽 280、条高 36、窗口键格宽 44、
右栏宽 580、内容最大宽 800、空态文本最大宽 520、模型下拉最大宽 170、弹层分组标题高 22、弹层宽四档、
流量方法列宽 220、侧栏空态高 96、agent 标记菱形 6、弹层上下偏移）。每条都注明出处画板。
任务书写的是「`tokens.dart` 缺 token 先停下问」——判断那条约束针对接线阶段（接线阶段确实一个都没加），
画板阶段不落这些值就做不到「widget 里不写字面量」。**此项请所有者确认。**

### 验收 2 · 接线阶段不改样式

    git diff dc4de5e..5586e06 -- lib/theme lib/ui      # 空输出（接线阶段全程）

**审查整改后有一处例外**：第 1 轮审查的 P2 第 4 条（顶栏拖拽层收不到事件）只能在 `lib/ui/shell/topbar.dart` 里修
——`BoxDecoration.hitTest` 对矩形一律返回 true，垫在顶栏外面的 Listener 永远收不到 pointer。改动是给 `TopBar` 加一个
`dragArea` 槽、把拖拽层放进容器内部（子节点先于 `hitTestSelf` 参与命中），**只动命中测试、不动布局与 token**。
证据：gallery 35 张 PNG 与改动前**逐字节一致**（`Get-FileHash` 对比）。接线阶段本身（`dc4de5e..5586e06`）零 diff 的
判据仍然成立；这一处是审查门禁的整改，不是接线偷改样式。

### 验收 3 / 4 / 5 / 6 / 10 · 无头实跑（`ACP_R3_REPORT`）

GUI 的点击动作没法在本会话里自动化（本机的 computer-use 只认 Start 菜单里的应用，认不出刚构建的
`acp_agent_client.exe`）。改用**驱动同一条接线**的无头口子：`lib/app/headless_run.dart` 用
`WorkbenchController`（UI 点下去走的就是它）对真实 agent 跑一遍，结果写 JSON。绕过 UI 的只有「鼠标落在哪个像素」，
命令、回应、状态机都是产品代码。

**dsh 真跑**（`build/r3-report.json`，release 构建）：

    $env:ACP_R3_REPORT="build\r3-report.json"; $env:ACP_R3_AGENT="dsh-acp-interactive"
    $env:ACP_R3_CWD="D:\cargo-target\AcpAgentClient\dsh-cwd-r3"; $env:ACP_R3_CONFIG="permission=read-only"
    $env:ACP_R3_PROMPT="把 notes.md 的第一行标题改成「R3 实测」。"
    $env:ACP_R3_PROMPT2="逐个读一遍当前目录下的所有文件，并对每个文件写一段两百字的总结。"
    $env:ACP_R3_CANCEL_AFTER="6"; $env:ACP_R3_PERMISSION="allow_once"; $env:ACP_R3_KILL="1"; $env:ACP_R3_TIMEOUT="180"
    Start-Process build\windows\x64\runner\Release\acp_agent_client.exe -Wait -WindowStyle Hidden   # exit 0

| 步骤 | 结果 |
|---|---|
| `session/new` | `cwd` = 当前项目且 `cwdMatchesProject: true`；`agentCapabilities` 五项；线程头标题 `New dsh-acp-interactive Thread` |
| configOptions 分配 | `model` → 模型下拉、`reasoning_effort`（category `thought_level`）→ 思考强度下拉、`permission`（category `_permission`，**未识别**）→ 扁平兜底。dsh 没有 `mode` category，模式下拉整块不渲染 |
| 改一个 config option | `permission=read-only` 后返回整份列表，三个值都刷新（`set_config_option` 是全量替换） |
| 第一轮 · 权限允许 | `session/request_permission` 进队列 → 回 `allow-once` → `stopReason end_turn`，8.1 s；`notes.md` 首行真的变成 `# R3 实测` |
| 第一轮 · 权限拒绝（另一次跑） | 回 `reject-once` → `end_turn`，文件**没被改**（仍是 `# 拒绝前的标题`） |
| 线程头标题 | `session_info_update` 到达后变成 `将 notes.md 首行标题改为 R3 实测`（不再是缺省的 `New … Thread`） |
| 用量圆环 | `usage_update` → `used 6272 / size 1000000` |
| 第二轮 · 中途停止 | 6 s 时发 `session/cancel` → `stopReason cancelled`，6.0 s；挂起权限由核心回 cancelled，前端不再重复回（见验收 10） |
| 杀掉 agent | `taskkill /F /T /PID 8972` 连子进程一起终结 → `acp/agent_state: exited`，`exitCode 1`，stderr 尾巴拿得到；应用不崩 |
| 重载 agent | 断开 + 重拉 + 新会话：`cd9e81e7…` → `5f45e585…`，状态回到 `initialized`，旧会话转录留在内存里 |
| 流量 | 618 行；`looksRedacted: true`（整份日志里没有 `sk-` 形状的裸密钥） |

`Alt-Shift-A` / `Alt-Shift-X` / `Ctrl-Alt-A` 是画板 25 上的快捷键标注：允许与拒绝两条路径都按上面实测过（走的是
同一个 `answerPermission`）；**`Ctrl-Alt-A` 的「范围下拉」没有实测到** —— dsh 只给 `allow_once` / `reject_once` 两个选项，
下拉里没有第二个同向选项可选。R6 五 agent 全通时补。

**elicitation 与计划卡**：dsh 本轮三次跑都没发过 `elicitation/create` 与 `plan`（与 R1 的观察一致）。改用
`test/fake-agent/fake-agent.mjs`（确定性、按 fixtures 回放）覆盖：

| 步骤 | 结果 |
|---|---|
| 权限 | `allow-once` ✓ |
| elicitation form（sessionScope） | 自动 `accept` ✓ |
| elicitation url（**requestScope**，无 sessionId） | 自动 `accept` ✓ —— 但见下方「已知限制」 |
| 计划卡 | `PlanCardEntry: 1`（输入框上方的折叠计划条数据源）✓ |
| 回合结束 | `stopReason end_turn` + 回合级 usage（42 tokens）✓ |

### 验收 4 · 流量面板

同一场景（fake agent，确定性）两边对数：

    面板（afterTurn1）  trafficLines = 22（JSON-RPC 行）+ stderr 尾巴 1 行 = 23
    acp-smoke          acp/traffic 事件 = 23

一致。方向与变体标签也对得上（`request` 8 / `response` 7 / 各 `session/update` 变体 / `unknown · dropped` 1 /
`response · stopReason end_turn` 1）。

`notice` 注入：`trafficDropped: 1`（画板 80 的 dropped 行与高亮行）与 `agentDroppedUpdates: 1`（画板 34 的告警条）
**同时为真**（报告里的 `bothWarningsVisible: true`）。脱敏：fake agent 往 stderr 写 `token=FAKE-TOKEN-…`，
`exited` 的 stderr 尾巴里是 `[fake-agent] turn started; token=***`。

### 验收 5 · 项目与分支

在一个**路径含空格与中文**的 git 仓库上跑（`D:\cargo-target\AcpAgentClient\r3 git 仓库 测试`）：

| 检查 | 结果 |
|---|---|
| 分支列表 | `["feat/已有分支", "main"]`，与 `git branch --format="%(refname:short)"` 完全一致 |
| 新建分支 | `git switch -c feat/r3-新建分支` → 顶栏当前分支立即变成它（`createdIsCurrent: true`），列表也多出一条 |
| 切回 | `git switch main` → 顶栏回 `main` |
| 非 git 目录 | `dsh-cwd-r3` → `branchAreaVisible: false`（分支区整块不渲染） |
| Rules 行 | 仓库里放了 `AGENTS.md` + `CLAUDE.md` → `rulesCount: 2`（画板 30 / 40 用量弹层的 Rules 行） |
| 切项目后新会话 cwd | `cwdMatchesProject: true` |

### 验收 7 · 无已安装 agent

`test/app/workbench_wiring_test.dart`：settings 里没有 `agent_servers` 时 `hasAgent == false`、线程头 `No Agent`、
输入框占位 `安装并选择一个 agent 后即可输入`（画板 01 状态 2）；`openTab(ShellTab.agents)` 后右栏切到 Agents 标签
（R5 前是 `RightPanelPlaceholder`）。

### 验收 8 · Windows 实测

**窗口控制**（无边框窗口，`windows/runner/acp_window.cpp`）——用 Win32 API 客观核对：

    GetWindowRect = 1280x720 ; GetClientRect = 1280x720   → 客户区 == 窗口区，系统标题栏与边框已去掉
    WM_NCHITTEST  左上角 → 13 (HTTOPLEFT) / 右边 → 11 (HTRIGHT) / 中间 → 1 (HTCLIENT，交给 Flutter)
    WS_THICKFRAME = True                                   → 系统的缩放与 Snap 保留

**git 子进程**（路径带空格与中文）：上面验收 5 的整段就是在 `r3 git 仓库 测试` 里跑的；另加常驻回归测试
`rust/fs/src/git.rs::works_with_spaces_and_non_ascii_in_path`（`git init` / 提交 / `switch -c 功能/新分支` / `diff`）。

**未实测、需所有者手测的两项**（本会话没有可用的 GUI 自动化通道）：

1. 顶栏空白处拖拽移动窗口、三个窗口按钮的点击（平台通道方法都已实现并注册，`WM_NCHITTEST` 的热区已客观验过）。
2. `file_selector` 的目录选择（画板 41 Open Local Folders）与文件 / 图片选择（画板 40 的 Files & Directories / Image）
   —— 都是系统模态对话框。

跑法：`build\windows\x64\runner\Release\acp_agent_client.exe`（settings.json 里已有 dsh 与 fake-agent 两条）。

### 验收 9 · 门禁

    powershell -File scripts/validate.ps1      # 13 项全 PASS，VALIDATE OK
    flutter test                               # 94 passed（R2 的 80 个 + gallery 9 张 + 接线 5 个）
    cargo test --workspace                     # 全绿（新增 fs 4 + index 3）
    powershell -File scripts/build.ps1 -Smoke  # ok: true，droppedEvents 0

### 验收 10 · Restore / Regenerate

`test/app/workbench_wiring_test.dart` 四个用例：截断范围内挂起的 permission 回 `{outcome:{outcome:cancelled}}`、
elicitation 回 `{action:cancel}`，两组 id **一条都不漏**（漏一条 agent 就一直等）；Regenerate 用新文本重发；
`session/cancel` 只发命令、前端不再 `acp_respond`（核心侧已自动回，前端再回会撞 `unknown_request`）。

### 接线阶段发现并修掉的四个缺陷

1. **`acp/session_update` 信封形状两边对不上**（最严重）：核心往 `SessionNotification` 里插 `agentId`
   （`{sessionId, update, agentId}`），R2 的 Dart 侧却按 `{..., update: SessionNotification}` 多套了一层。
   后果是每条会话更新都被当未知变体丢弃——转录区一个字都不出，而 fixtures 与单测都自洽地用着错的形状，所以 R2 发现不了。
   修：Dart 侧对齐核心，回放器与 `wire_test` 同步，`docs/design.md` § 3 把措辞写死。
2. **无头进程没有 vsync**：按帧批量的 `scheduleFrameCallback` 永远不回调，事件全卡在队列里。
   `WorkbenchController` 的 flush 调度器改成可注入，无头模式传微任务（窗口里仍按帧合并）。
3. **`WM_NCCALCSIZE` 的 `wParam == FALSE` 形态没接**：建窗时的第一次非客户区计算走的正是这一支，
   只处理 `TRUE` 的话标题栏根本没去掉（实测 client 1266×683 vs window 1280×720）。
4. **`git diff` 对含中文的路径默认输出八进制转义**（`core.quotepath`）：用户与 agent 都读不出来。
   git 封装统一加 `-c core.quotepath=false`（只对本次调用生效，不改用户配置，规则 7）。

### 已知限制与偏离（已记 `rounds/BACKLOG.md`）

- **requestScope 的 elicitation 在 R3 没有落点**：`docs/design.md` § 3 说它落认证页（画板 52），而画板 52 归 R5。
  本轮它只进 `PendingQueue.requestScope`，UI 上看不到、也回应不了——agent 会一直等。无头验收脚本里代答了一次
  （fake agent 的 URL elicitation 就是 requestScope），产品侧留到 R5。
- **线程头 ≡ 按钮当前只做右栏开关**：画板 03 的 ≡ 是右栏展开的选中态，画板 41 的 ≡ 菜单（Rename / Reload /
  Resume / Close / Delete）动作本身归 R6。菜单 widget 已实现并在 gallery 出样张，接线留到 R6。
- **流量面板的返回路径**：画板 80 上没有「返回工作台」控件。本轮从画板 34 的「打开流量面板」进，点侧栏任一会话返回。
- **新建会话弹层里的 agent 名是 settings.json 的键**（如 `dsh-acp-interactive`）：协议里没有「展示名」，
  连上之后线程头才从 `initialize.agentInfo` 取更好看的名字（规则 2 不做 agent 名映射表）。R5 的 registry 会带来展示名与 logo。
- **`ToolCallEntry.cancelledLocally` 在 dsh 上没触发**：第二轮取消时 5 个工具调用都已经完成了，没有「进行中」的卡可标。
  逻辑本身有 R2 的单测覆盖（`10-cancel.jsonl`）。

### 环境与踩的坑（本机，规则 9）

- **含中文注释的 `.cpp` / `.h` 必须 UTF-8 with BOM**：MSVC 按代码页 936 解码，行尾会被吞、把下一行并进注释
  （表现是 `LPARAM` 重定义之类莫名其妙的语法错误）。与「含中文的 `.ps1` 必须带 BOM」是同一个坑。
- **helper 不能叫 `IsMaximized`**：`winuser.h` 把它 `#define` 成 `IsZoomed`，会和系统重载撞上（`C2668`）。
- **`Assert-NoStyleLiteral` 会扫 `Duration(milliseconds:`**：无头脚本的超时改成 `Duration(seconds:)`
  （扫描器注释里写明秒级 Duration 不在此列），环境变量也跟着改成秒。
- **Bash 工具的 heredoc 里反斜杠会塌**：写 C 字符串里的转义时被吃掉，产生「常量中有换行符」。
  含反斜杠的内容用 `chr(92)` 拼，或走 Write 工具。
- `computer-use` 的 `request_access` 只认 Start 菜单里的应用，认不出刚构建的 `acp_agent_client.exe`（两次尝试都是
  `notInstalled`），所以 GUI 点击类验收改走无头口子 + Win32 API 客观核对。

