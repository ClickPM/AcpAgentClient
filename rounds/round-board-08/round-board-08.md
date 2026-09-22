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
- `lib/app/transcript_folds.dart`（新）：折叠态持有者（每会话每回合，会话生命周期内记住；默认值来自全局开关）。
- `lib/app/workbench_screen.dart` / `workbench_controller.dart`：接线 + 时间线跳转前先展开目标所在回合。

**全局开关（画板 70「转录」分组）**
- `rust/settings/src/lib.rs`：`settings.json` 新增 `transcript` 段（`collapse_finished_turns`）。
- `rust/acp-core` + `rust/bridge/src/api.rs`：`transcript_prefs_get` / `transcript_prefs_set`，frb 重新生成（生成物入库）。
- `lib/app/transcript_prefs.dart`（新）：控制器，与 `AppearanceController` 同形。
- `lib/ui/settings/settings_page.dart`：新增「转录」分组（放最前），复用 `MenuToggle`。

**C · 在跑数徽标**
- `lib/app/session_controller.dart`：`runningByWorkspace`（按归一化 cwd 分组的在跑会话数）与合计。
- `lib/ui/shell/running_badge.dart`（新）：徽标 widget（循环箭头 + 数字，> 99 显示 `99+`，0 不渲染）。
- `lib/ui/shell/topbar.dart`：项目触发钮上的合计徽标 + tooltip。
- `lib/ui/popovers/topbar_popovers.dart`：`ProjectSwitcherPopover` 每行的徽标 + 行内 tooltip。

**测试**
- `test/projection/turn_fold_test.dart`、`test/ui/turn_fold_row_test.dart`、`test/app/running_badge_test.dart`、`test/app/transcript_folds_test.dart`（文件名以最终落地为准）。

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

<!-- 完成后回填 -->
