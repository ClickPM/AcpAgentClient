# Iteration 08 — 等你处理：后台 / 换走的会话挂着权限或表单请求时看得见（画板 09）

<!-- 保存为 iterations/iteration-NN.md。一个迭代一个文件、一项一行；流程正本见 iterations/README.md，不在这里复述。 -->

> 状态：进行中（1 项待合并；合并时机由所有者定）　起止：2026-09-23 –　基线：`main` = `34e66be`（本分支开出时；编号 08 是因为 `main` 上 05–07 已被别的会话占用）

BACKLOG P1「数据一致性」两条合在一起做：「换项目放下的会话挂着请求，界面上没痕迹」与「后台会话挂起的权限 / 表单请求，界面上没痕迹」。
两条根因相同（挂起队列只在当前会话的停靠条上露出来），差在请求所属会话在不在侧栏里，所以分两处提示：侧栏条目（当前工作区）与项目切换器（按工作区汇总）。
所有者 2026-09-23 让 Claude Design 按简报 `design/round-design/input/revision-07.md` 出稿（新增画板 09、改画板 06 / 08 各一处），出稿后下令按稿实现。

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | board | 画板 09「等你处理」：侧栏条目在「N 条消息」后出 `▲ 待授权` / `ⓘ 待输入`（warning 色；亮点撤掉只留底线，行高仍 58；当前会话也显示），项目切换器在跑数徽标左边并排一枚等你数徽标（按会话计数，当前工作区也挂，触发钮 tooltip 整句为 0 的段省略）；「等你处理」与「运行中」互斥，在跑数不再含等你的会话。派生挪进 `lib/projection/session_activity.dart`（`session_controller.dart` 已到 897 / 900 行门）；画板 09 入库 + 画板 06 / 08 文字修订 + PNG 重渲 | BACKLOG P1「数据一致性」第 1、2 条；所有者 2026-09-23 | `claude/permission-request-badge-missing-c4a919`（实现 `586fd86`） | validate 全绿 | 1 轮（cursor），0 条 | 待合并 |

## 收口

- 构建 / 手测：未做。手测项：开两条会话并跑，后台那条遇到权限请求时侧栏那一行出「待授权」、扫掠停下、行高不跳，前台那条照常扫掠；点进去回应之后标记淡出、扫掠从左端重新进入；表单请求（elicitation）出「待输入」；换到另一个项目后，原项目那条卡在授权上的会话让顶栏项目钮出 warning 色徽标，打开切换器那一行有等你徽标（与在跑徽标并排时等你在左），tooltip 文案对；切回去之后侧栏那一行带着标记；Stop / agent 退出后标记撤掉；深色主题下标记与徽标的颜色能接受。
- 发版：—
- 移出项去向：—
- 设计稿补注记：无新增偏离（画板 09 的切换器样张已按画板 41 把对勾画在右侧，与实现一致）。
- BACKLOG：P1「数据一致性」两条已压成一行剪到 `rounds/BACKLOG-CLOSED.md`（写 `→ iteration-08`），合计 8 → 6（P0 5 / P1 1，按真实条数核过）。

## 备注

### 实现要点

- **判定只有一处**：`SessionActivity`（纯 Dart，投影层）每次从会话表与挂起队列现算——`awaiting` = `PendingQueue.firstBySession()`（每条会话最早到的那一项，requestScope 不算），`running` = 有在途 prompt 且不在 `awaiting` 里；按工作区的两张计数表用调用方给的 `workspaceKey`（`WorkspaceState.normalizeCwd`），没记 cwd 的只进合计。侧栏、顶栏、切换器三处都从同一个 `activity` 取，互斥由它保证。
- **为什么挪出 `session_controller.dart`**：它已经 897 行（行数门 900），原来画板 06 / 08 C 那几个 getter（`runningSessionIds` / `runningByWorkspace` / `runningTotal` / `runningWorkspaceCount`）本来就是纯投影派生，挪进投影层之后控制器只剩一个 `activity` getter，现在 870 行；依赖方向门不受影响（`../projection/` 不在门的检查范围里）。
- **侧栏行**：`_inFlight = running || awaiting != null` 决定 58 行高与轨道带；等你时轨道带画 `_SweepPainter.trackOnly()`（只有 `sweep.track` 底线，reduced-motion 的静态 accent 线同样不画），回应后换回一只新的 `_SessionSweepLine`，亮点自然从左端外进入新周期。标记 `_SessionAwaitingMark` 与绿点同一套 opacity 动效，淡出期间仍画消失前的那一种；它不包 `Flexible`，挤的是前面的时间与条数。
- **徽标**：`RunningBadge` 的外壳抽成 `_CountBadge`，新增 `AwaitingBadge`（`alertTriangle` + warning / warningSoft）与并排用的 `ActivityBadges`（等你在左、在跑在右，间距 4，为 0 的不占位；切换器行内各挂各的 tooltip，触发钮那边整句挂在钮上，沿用 DIVERGENCE 第 15 条②的做法）。`TopBar` 的 `runningWorkspaces` 改名 `activeWorkspaces`（口径变成「有在跑或等你会话的工作区」）。
- **token**：画板 09 不新增设计 token；`tokens.dart` 收一组 `AwaitingMark` 并给 `Badge` 补 `warningBg` / `warningFg` / `pairGap`，全部引用既有值（深色随 `Semantic.warning` / `warningSoft` 走画板 07 的对位）。
- **设计稿**：画布交回的 09 的 `$preview` 只写了宽，高度取画布 `delivery/canvas.json` 的 frame 1713 补上再渲 PNG；06 / 08 没有整份拉回（本地可能比画布新），只按简报改了三处文字。

### 验证

- `powershell -File scripts/validate.ps1`：第三次 **VALIDATE OK**（16 项全绿，`flutter test` 473 条全过，`flutter analyze` 的 16 条 info 与基线同数、无新增）。前两次：第一次唯一红的是 fetch-upstream -Check（本 worktree 的 `vendor/upstream` 是空目录，按惯例换成指向主副本的目录联接后全绿）；第二次红在 `rust/acp-core/tests/scripted.rs` 的 `owned_terminals_are_released_when_the_agent_disconnects`（`disconnect().await` 之后立刻断言终端已释放），本分支 `rust/` 零改动，那一轮日志里有别的会话同时在用共享 cargo target 的「waiting for file lock」，单独重跑与第三次全量都过——判为既有的时序偶发，已另开任务跟进，不在本迭代修。
- 新增用例：`test/projection/session_activity_test.dart` 6 条（互斥、最早那一项定种类且先到的了结后换种类、按工作区计数与没记 cwd 的只进合计、requestScope 不算、回应后回到在跑、`$/cancel_request` / `session/cancel` / agent 退出三条了结路径）；`test/ui/sidebar_awaiting_test.dart` 3 条（整壳：后台会话挂权限请求 → 侧栏「待授权」、亮点停、行高 58、顶栏等你徽标与 tooltip，回应后复原；会话项给了在跑也以等你为准；切换器两枚徽标的挂行、tooltip 与左右顺序）；`test/app/running_badge_test.dart` 加 1 条（换项目之后原工作区那条卡在授权上的会话计在等你数里、回应后回到在跑），原有 08 C 用例改走 `activity`。
- gallery：新增 `09-awaiting-you` 对照页，与 `design/round-design/09-awaiting-you.png` 逐段对过（①–④ 分帧、悬浮、列表全景、徽标三态、触发钮、切换器弹层）。

### 审查（1 轮，cursor CLI + `grok-4.7-high-fast`）

- `-Scope since -Base 34e66be`（本分支基线），结果 `.claude/reviews/20260923-142715-review.out.md`：**0 条**。审查器逐条核对了互斥在回应、`$/cancel_request`、`session/cancel`（权限与 elicitation 都标掉）、agent 退出、`resetForReplay` 的 `forgetSession`、`Sessions.forget` 这些了结路径上都成立，以及等你标记淡出保留旧种类、回到在跑时换一只新的扫掠线从新周期开始。无整改，不复审。
