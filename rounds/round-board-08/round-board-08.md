# Round board-08 — 画板 08「交互增强」：回合折叠 + 跨工作区在跑数

<!-- 画板 08 与画板 43 / 07 同类：R8 之后的单画板轮，登记在 ROUNDS.md § 7 进度表。 -->

> 状态：进行中

## 目标

落地画板 08 的 B（回合结束后过程折叠为一行摘要）与 C（工作区切换器里的在跑会话数徽标），外加画板 70 新增的「转录」分组里那一个全局开关。**A 段（token 速度标签）已在设计阶段整段删除，不做**（所有者裁定 2026-09-22，理由记 `design/README.md` 变更记录与 `design/round-design/input/revision-04.md` § 0）。

## 前置

- `scripts/fetch-upstream.ps1 -Check` 九条全 OK（2026-09-22 本 worktree 实测；`vendor/upstream` 是指向主副本的目录联接）。
- 分支已快进到 `main`（`29d1810`）。
- 设计稿已入库：`design/round-design/08-interaction-upgrades.dc.html` + PNG（1440 × 1586）、`70-settings.dc.html` + PNG（1440 × 1110），`canvas.json` 与 `design/README.md` 已更新。
- 依赖既有能力：`TurnEntry` 轮边界（R2）、`transcript_jump.dart`（2026-09-22 main 直改）、画板 43 时间线（`session-timeline`）、画板 06 的 `runningSessionIds`、画板 41 项目切换器（R3）。

## 交付物

**tokens**
- `lib/theme/tokens.dart`：新增 `Fold`（摘要行容器 / 悬浮底色）与 `Badge`（在跑数徽标几何与配色）两组，按画板 08 的「本画板新增 token」表。画板 00 不改。

**B · 回合折叠**
- `lib/projection/entries.dart`：`TurnEntry` 加 `model`（回合开始时的模型名快照）。
- `lib/projection/session_store.dart`：`startTurn` 时取 `configOptions` 里 `category == 'model'` 的当前选项显示名写进 `TurnEntry.model`。
- `lib/projection/turn_fold.dart`（新）：纯 Dart 的折叠分组规则——把一轮的条目分成「不折叠的头尾」与「折叠块」，算出条数 / 工具调用数 / 失败数，并判定该轮是否自动折叠。
- `lib/ui/transcript/turn_fold_row.dart`（新）：画板 08 B 的摘要行 widget（两行 / 单行两态、chevron、hover、整行可点、语义可及性）。
- `lib/ui/transcript/transcript_list.dart`：`buildRows` 产出 `TurnFoldRow`，折叠态跳过被折叠的条目。
- `lib/app/transcript_folds.dart`（新）：全局开关 + 每回合展开态（展开态用 `Expando` 按 `TurnEntry` 实例记，会话重开自然回到默认折叠）。**落地时与下面的「转录偏好控制器」合成了这一个文件**：两者都是「回合折叠」这一件事的状态，分两个 notifier 只会让转录列表多听一路。
- `lib/app/workbench_screen.dart` / `workbench_controller.dart`：接线 + 时间线跳转前先展开目标所在回合。

**全局开关（画板 70「转录」分组）**
- `rust/settings/src/lib.rs`：`settings.json` 新增 `transcript` 段（`collapse_finished_turns`）。
- `rust/acp-core` + `rust/bridge/src/api.rs`：`transcript_prefs_get` / `transcript_prefs_set`，frb 重新生成（生成物入库）。
- `lib/ui/settings/settings_page.dart`：新增「转录」分组（放最前），复用 `MenuToggle`。

**C · 在跑数徽标**
- `lib/app/session_controller.dart`：`runningByWorkspace`（按归一化 cwd 分组的在跑会话数）与合计。
- `lib/ui/shell/running_badge.dart`（新）：徽标 widget（循环箭头 + 数字，> 99 显示 `99+`，0 不渲染）。
- `lib/ui/shell/topbar.dart`：项目触发钮上的合计徽标 + tooltip。
- `lib/ui/popovers/topbar_popovers.dart`：`ProjectSwitcherPopover` 每行的徽标 + 行内 tooltip。

**测试**
- `test/projection/turn_fold_test.dart`、`test/ui/turn_fold_test.dart`、`test/app/running_badge_test.dart`、`test/app/transcript_prefs_test.dart`；Rust 侧 `rust/settings/src/lib.rs` 的 `transcript_round_trip_and_defaults`。

## 验收

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | 折叠分组规则 | 单测：最后一段连续 agent 文本不折叠、工具调用之间的 agent 文本进折叠块、用户消息与回合页脚不折叠、Plan 与压缩标记按画板归类、只有文本的回合无摘要行、含失败 / 取消 / 出错的回合不自动折叠 |
| 2 | 摘要行渲染 | 单测：两行态出模型名、无模型信息退化成单行、失败时首行末尾出「N 项失败」、整行可点（非只有 chevron）、`Semantics` 带 button + expanded |
| 3 | 自动折叠时机 | 单测：运行中的回合始终展开，`stop_reason` 到达后同帧折叠；手动展开后不被后续通知重新折叠 |
| 4 | 滚动锚点 | 单测：折叠 / 展开后该回合页脚在视口内的偏移不变（±0.5） |
| 5 | 时间线跳转 | 单测：目标条目在折叠块里时先展开该回合再滚，落点 = `Spacing.s16` ±0.5 |
| 6 | 全局开关 | Rust 单测：`transcript` 段读写往返 + 缺省不落键；Dart 单测：关掉后回合结束不自动折叠 |
| 7 | 在跑数 | 单测：按归一化 cwd 分组（分隔符 / 尾斜杠 / Windows 大小写）、合计含当前工作区、为 0 不渲染徽标、> 99 显示 `99+` |
| 8 | 画板对照 | gallery 出画板 08 B / C 与画板 70「转录」分组的对照图，与 `design/round-design/08-interaction-upgrades.png` / `70-settings.png` 逐项核对（文案 / 状态 / 层级 / 控件不缺） |
| 9 | 全量校验 | `powershell -File scripts/validate.ps1` 全绿（含行数门与依赖方向门）；`flutter analyze` 0 error 0 warning |
| 10 | 真跑（规则 9） | Windows 上用 fake-agent 无头跑一轮，确认回合结束折叠、展开态记忆、切项目后徽标计数正确 |

## 禁止

默认三条：不改前端页面样式（规则 3）；不加设计稿没有的功能（规则 3）；不在 `vendor/upstream/` 里改代码（规则 4）。本轮另加：

- **不做 A 段**：不加任何流式期间的 token / 速度显示，画板 31 的回合页脚零改动（不加平均速度）。
- 不给折叠做高度过渡 / 折叠动画；不在摘要行里放成本与耗时；不把摘要行做成只有 chevron 可点。
- 不自动折叠含失败 / 被取消 / 出错的回合。
- 徽标不旋转、不呼吸、不用红色、为 0 不占位；不让有在跑会话的工作区置顶或加粗；不在切换器里放扫掠线。
- 不改画板 43 的跳转规格本体，不改画板 06 的侧栏表达。
- 不顺带补画板 70 的「外观」小节设计稿（另记 BACKLOG）。

## 代码审查

<!-- 完成后回填 -->

- 审查方式：
- 审查器与模型：
- 审查范围与基准提交：
- findings 处理：
- 结论：

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-board-08/BLOCKED.md`，停下呼人。禁止放宽验收标准自我通过。

## 本轮实测

### 验收

| # | 结果 | 证据 |
|---|---|---|
| 1 | PASS | `test/projection/turn_fold_test.dart` 14 项：折叠范围（含「工具调用之间穿插的 agent 文本进折叠块，只有最后一段连续的不进」）、不自动折叠的四种回合、多轮各自一份、重放无轮边界、模型名快照三项 |
| 2 | PASS | `test/ui/turn_fold_test.dart`「摘要行」4 项：两行态出模型名、无模型信息退化成单行（摘要行下只有 2 个 `Text`）、`1 项失败` + 该回合保持展开、`matchesSemantics(isButton, hasExpandedState, hasTapAction)` 且点首行文字（非 chevron）能展开 |
| 3 | PASS | 同文件「折叠时机」3 项：运行中不出摘要行、`stop_reason` 到达后同帧收起、全局开关关掉后不自动折叠、手动展开后不被后续通知折回 |
| 4 | PASS | 同文件「滚动锚点」：长转录里折 / 展各一次，结论文本的视口 y 偏差 ≤ 0.5。**已验证会红** —— 把 `_anchorEpsilon` 临时改成 1e9（等于关掉校正）后这一项当场失败 |
| 5 | PASS | 同文件「时间线跳转」：`foldContaining` 找到目标所在的折叠块、`expand` 首次返回 true 且第二次返回 false（不多发一次通知）；接线在 `workbench_screen._jumpToEntry` |
| 6 | PASS | Rust `transcript_round_trip_and_defaults`（读写往返 / 与 `appearance` 段互不影响 / 全空不落键）+ Dart `test/app/transcript_prefs_test.dart` 6 项（含「读盘没回来就点了开关」与「读盘失败绝不落盘」两条反例） |
| 7 | PASS | `test/app/running_badge_test.dart` 4 项：三条会话分属两个工作区、换项目后原工作区那条仍在跑、同一目录的三种写法归一到同一个键、跑完即减、0 不渲染 / `99+`、切换器里 Recent 行也挂徽标 |
| 8 | PASS | `build/gallery/08-interaction-upgrades.png`（画板八段样张）与 `build/gallery/70-settings.png`（「转录」分组在最前，开关默认开）逐项对过 `design/round-design/08-interaction-upgrades.png` / `70-settings.png`：文案、状态、层级、控件不缺 |
| 9 | PASS | `scripts/validate.ps1` 16 项全绿（`flutter test` 389 项、`flutter analyze --no-fatal-infos` 0 error 0 warning、行数门与依赖方向门通过） |
| 10 | 部分 PASS · 余下待所有者手测 | `scripts/build.ps1 -Smoke`：`flutter build windows --release` 194.0s 成功，`acp_bridge.dll` 12,930,048 字节（新加的两个桥命令真的编进了 cdylib），smoke 往返 `ok: true` / `droppedEvents: 0`。**折叠、展开态记忆、切项目后的徽标计数是 UI 级行为，本机没有 GUI 自动化通道**（与 R3 的窗口拖拽同一情况），由 widget 单测覆盖，产品界面里的确认留所有者手测 |

### 踩到的坑

- **`Assert-NoStyleLiteral` 扫 `Duration(milliseconds:`**（规则 3 的动效时长字面量）。gallery 的假时钟本来一步 100ms，撞了门；改成一步 1 秒。
- **`TranscriptList` 要 Overlay 祖先**（里面的 `SelectableRegion`）。整窗画板由 `_window` 垫了一层，`BoardPage` 的分节里没有，08 的两段「转录里」样张自己垫。单测同理。
- **`FakeCore.sessionNew` 恒回 `sess_fake`**：C 的计数用例一开始三次「新建」其实是同一条会话，验不到分组；`_GatedCore` 覆写成递增 id 之后才真的有三条。
- **`_anchorAfter` 的循环被 analyzer 判 dead code**（首次迭代必然 return），改成直接取下一条。

### 与设计的偏离（都记了 `rounds/BACKLOG.md`，待所有者确认）

1. **权限卡与 elicitation 卡不折叠**。画板「折叠范围与例外」的两列都没列到它们；挂起的那张必须看得见，已回应的那张是「授权过什么」的记录，藏起来不合适。
2. **项目触发钮的 tooltip 整句替换**：有徽标时是「N 个会话在运行 · M 个工作区」，没有徽标时仍是 `Recent workspace`。画板要的是给徽标单独挂一条，但 `AcpTooltip` 是 `MouseRegion`，套两层会两条一起弹。
3. **切换器里当前工作区那一行的对勾在右侧**（画板 41 定的位置，徽标排它左边），画板 08 画在左侧；本次「行高、缩进、分隔线都不动」，所以沿用 41。
4. **徽标图标复用 `AcpIcons.rotateCw`**：画板画的是同一个 lucide 字形的 r=8 版本，11px 下差别在 1px 以内（ROUNDS § 0 第 5 条：像素级差异不作 finding），不为此再加一个近乎重复的图标常量。

### 已知限制

**回合折叠对 `session/load` 重放出来的历史不生效**：重放不带回轮边界（R6 裁定，`docs/design.md` § 3），历史里没有 `TurnEntry`，也就没有摘要行。折叠只对本次会话里真正跑过的回合生效。这与「重开会话回到默认折叠」是同一件事的两面，不额外补。
