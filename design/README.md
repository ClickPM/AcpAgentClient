# 画板索引

> **设计稿是功能边界**（CLAUDE.md 规则 3）：设计稿没有的功能一律不做。清单与计数以本文为准。
> 设计工具是 **Claude Design**（所有者裁定 2026-09-14，替代 2026-09-12 裁定的 Figma Make）。产物是每画板一个 `.dc.html` 文件加一份 `canvas.json` 布局清单，**源文件与每画板一张 PNG 快照都入库**：`.dc.html` 是设计的唯一事实来源，PNG 是审查与验收的基准。画布（claude.ai/design，或 Claude Code 内 `/design` 发布的画布）上的后续改动不影响已开工轮次；改设计走「先拉回 `.dc.html`、重导 PNG、更新本索引，再进轮次」。
> **画板编号只增不改、不重排**；废弃的画板留「已废弃」占位。
> **看画板之前先看 [`DIVERGENCE.md`](DIVERGENCE.md)**：那里逐条记着实现与画板不一致的地方（实现先行 / 画板画错 / 实现有意少做），这几处以实现为准、PNG 不再是验收基准；按所有者裁定 2026-09-20 **不要求回补设计稿**。

## 约定

- 每个设计轮一个目录 `design/round-NN/`：
  - `input/`：整个目录交给 Claude Design。含 `design-prompt.md` 设计简报（风格与 token 约束，以及对 `docs/acp-projection.md` 可投影面的覆盖要求）、附件（原型与截图副本、参考文档快照）、预排的 `canvas.json` 与用法说明 `README.md`。
  - `NN-<画板短名>.dc.html`：画板源，一画板一文件，文件名即画板身份，编号与下表一致；文件名只用字母、数字、连字符与下划线。
  - `canvas.json`：画布布局清单，记各画板的位置与 frame 尺寸。桌面画板的 frame 尺寸在首轮 `design-prompt.md` 里定一次，后续画板沿用。
  - `NN-<画板短名>.png`：画板快照，由 `scripts/render-design.ps1` 从同名 `.dc.html` 渲染（headless Edge，scale 1，尺寸 = 文件内的 `$preview`），编号与 `.dc.html` 一致。画布自带的 PNG 导出件不作基准，它的字体度量与浏览器不同，会出现假换行。
  - `support.js`：Claude Design 的画板运行时，与 `.dc.html` 同目录才能直接用浏览器打开；每轮一份副本。
  - `input/revision-NN.md`：入库之后对画板的修订简报（新增单张画板、给既有画板补一态），编号只增；缺号是别的会话占用未提交，不回填。出稿后同样走「拉回 `.dc.html` → 重渲 PNG → 更新下表与变更记录」，实现在轮次或迭代里做并记进「状态」列（画板 05 / 06 / 43 / 07 / 08 都是这条路）。
- **首个设计轮先出 `00-tokens` 画板**（色阶 / 字阶 / 间距 / 圆角 / 动效时长），页面画板都从它取值。
- token 提炼：只从 `00-tokens` 画板的 `.dc.html`（`<helmet><style>` 与内联样式）提炼到 `lib/theme/tokens.dart`，不从页面画板反推；该文件是样式唯一来源，每次设计轮结束时同步更新并在下表「token 变更」列记一句。
- `.dc.html` 是 HTML 加内联样式，**只作设计源，不复用为代码**；组件全部从画板手写（CLAUDE.md 规则 1 / 3）。
- 画布上 Save 过的改动，先读回仓库覆盖 `design/round-NN/` 里的源文件，再跑 `scripts/render-design.ps1` 重渲染 PNG；不在画布与仓库两边各改一份。
- 每张画板的实现轮次与 widget 文件见仓库根 `ROUNDS.md` § 2；实现轮收口时把下表「状态」改为 `已实现（R<N>）`。
- `design/brand/` 放应用图标与应用内标记的来源（`app-icon.svg`、参考位图、说明），**不是画板**：不进下表、不走 `render-design.ps1`；`.ico` 用 `scripts/render-icon.ps1` 重出，应用内标记在 `lib/ui/shell/app_logo.dart` 里按同一几何拼（所有者裁定 2026-09-17）。

## 画板

| 编号 | 名称 | 页面 | 设计轮 | .dc.html | PNG | 画布 URL | 状态 | token 变更 |
|---|---|---|---|---|---|---|---|---|
| 00 | Token 表 | 全局 | round-design | `design/round-design/00-tokens.dc.html` | `design/round-design/00-tokens.png` | — | 已实现（R0）· 动效小节已接线（2026-09-17） | 首版 token 表（浅色 + 深色色阶、accent、语义色、字阶、圆角、间距、kbd、动效）；2026-09-17 动效小节补 6 个值：`motion.ease` / `motion.transition` / `motion.rise` / `motion.pop` / `motion.stagger` / `opacity.pending` |
| 01 | 工作台 · 新会话 | 会话工作台 | round-design | `design/round-design/01-workbench-empty.dc.html` | `design/round-design/01-workbench-empty.png` | — | 已实现（R3） | — |
| 02 | 工作台 · 进行中的一轮 | 会话工作台 | round-design | `design/round-design/02-workbench-running.dc.html` | `design/round-design/02-workbench-running.png` | — | 已实现（R3） | — |
| 03 | 工作台 · 回合结束 + 右栏展开 | 会话工作台 + 文件面板 | round-design | `design/round-design/03-workbench-done.dc.html` | `design/round-design/03-workbench-done.png` | — | 已实现（R3）· 右栏内容已实现（R4） | — |
| 04 | 侧栏与顶栏状态 | 会话工作台 | round-design | `design/round-design/04-sidebar-states.dc.html` | `design/round-design/04-sidebar-states.png` | — | 已实现（R3） | — |
| 05 | 转场规格 | 全局 | round-design | `design/round-design/05-motion.dc.html` | `design/round-design/05-motion.png` | — | 已实现（2026-09-17，main 直改） | —（规格值全部登记在画板 00） |
| 06 | 侧栏会话活动指示 | 会话工作台（侧栏） | round-design | `design/round-design/06-session-activity.dc.html` | `design/round-design/06-session-activity.png` | — | 已实现（2026-09-18，main 直改） | 新增 `Sweep`（track / focus / focusGradient / cycle / band / inset / bottom）与 `UnreadDot`（size / color / gap）两组；`Geometry` 补 `sidebarRowRunning` 58 与 `sidebarRowRunningContent` 50 |
| 07 | 深色 Token 对位表 | 全局 | round-design | `design/round-design/07-dark-tokens.dc.html` | `design/round-design/07-dark-tokens.png` | — | 已实现（2026-09-20，`dark-mode-toggle-implementation` 分支） | 颜色层拆成 `Theming.lightColors` / `Theming.darkColors` 两套（`ThemeColors` 29 项）；`Neutral` / `Accent` / `Semantic` / `Surface` / `Borders` / `Shadows` / `Overlays` 等全部改成 getter；新增 `AppTheme` 与 `Theming`，`Shadows` 补 `topHighlight`（深色弹层顶边 1px 提亮），`Sweep.focusGradient` 改为由 `focus` 现算 |
| 08 | 交互增强（回合折叠 / 跨工作区在跑数） | 会话工作台（转录 + 顶栏项目切换器） | round-design | `design/round-design/08-interaction-upgrades.dc.html` | `design/round-design/08-interaction-upgrades.png` | — | 已实现（2026-09-22，`claude/new-session-c0ff9d` 分支）·**A 段设计阶段已删除，不实现** | 新增 `Fold`（rowPadding / radius / bg / hover / secondLineIndent / lineGap / headerPadding / itemGap）与 `Badge`（accentBg / height / radius / padding / gap / iconSize / iconStroke / overflowAt）两组；`badge.accent.bg` 由 `Accent.base` 现算（照画板 07 对 `Sweep.focusGradient` 的做法），画板 00 不改 |
| 10 | Restore Checkpoint 分隔线 | 转录 | round-design | `design/round-design/10-checkpoint.dc.html` | `design/round-design/10-checkpoint.png` | — | **已废弃（2026-09-17）** | — |
| 11 | 用户消息气泡 | 转录 | round-design | `design/round-design/11-user-message.dc.html` | `design/round-design/11-user-message.png` | — | 已实现（R2） | — |
| 12 | 助手富文本正文 | 转录 | round-design | `design/round-design/12-assistant-text.dc.html` | `design/round-design/12-assistant-text.png` | — | 已实现（R2） | — |
| 13 | 代码块卡片 | 转录 | round-design | `design/round-design/13-code-block.dc.html` | `design/round-design/13-code-block.png` | — | 已实现（R2） | — |
| 14 | GFM 表格 | 转录 | round-design | `design/round-design/14-gfm-table.dc.html` | `design/round-design/14-gfm-table.png` | — | 已实现（R2） | — |
| 15 | Mermaid 图 | 转录 | round-design | `design/round-design/15-mermaid.dc.html` | `design/round-design/15-mermaid.png` | — | 已实现（R2） | — |
| 16 | 数学公式 | 转录 | round-design | `design/round-design/16-math.dc.html` | `design/round-design/16-math.png` | — | 已实现（R2） | — |
| 17 | 思考折叠块 | 转录 | round-design | `design/round-design/17-thinking.dc.html` | `design/round-design/17-thinking.png` | — | 已实现（R2） | — |
| 18 | 标准工具调用卡 | 转录 | round-design | `design/round-design/18-tool-call.dc.html` | `design/round-design/18-tool-call.png` | — | 已实现（R2） | — |
| 19 | 工具调用失败卡 | 转录 | round-design | `design/round-design/19-tool-failed.dc.html` | `design/round-design/19-tool-failed.png` | — | 已实现（R2） | — |
| 20 | 工具已取消卡 | 转录 | round-design | `design/round-design/20-tool-cancelled.dc.html` | `design/round-design/20-tool-cancelled.png` | — | 已实现（R2） | — |
| 21 | 文件差异对比卡 | 转录 | round-design | `design/round-design/21-diff-card.dc.html` | `design/round-design/21-diff-card.png` | — | 已实现（R2） | — |
| 22 | 嵌入式终端控制台卡 | 转录 | round-design | `design/round-design/22-terminal-card.dc.html` | `design/round-design/22-terminal-card.png` | — | 已实现（R2） | — |
| 23 | 终端进行中卡 | 转录 | round-design | `design/round-design/23-terminal-running.dc.html` | `design/round-design/23-terminal-running.png` | — | 已实现（R2） | — |
| 24 | 子代理委派卡 | 转录 | round-design | `design/round-design/24-subagent.dc.html` | `design/round-design/24-subagent.png` | — | 已实现（R2） | — |
| 25 | 权限授权卡 | 转录 | round-design | `design/round-design/25-permission.dc.html` | `design/round-design/25-permission.png` | — | 已实现（R2） | — |
| 26 | Awaiting Confirmation | 转录 + 输入框上方 | round-design | `design/round-design/26-awaiting.dc.html` | `design/round-design/26-awaiting.png` | — | 已实现（R2） | — |
| 27 | 表单模式交互卡 | 转录 | round-design | `design/round-design/27-elicitation-form.dc.html` | `design/round-design/27-elicitation-form.png` | — | 已实现（R2） | — |
| 28 | 链接跳转交互卡 | 转录 | round-design | `design/round-design/28-elicitation-url.dc.html` | `design/round-design/28-elicitation-url.png` | — | 已实现（R2） | — |
| 29 | 计划卡 | 转录 | round-design | `design/round-design/29-plan.dc.html` | `design/round-design/29-plan.png` | — | 已实现（R2） | — |
| 30 | 上下文窗口浮窗 | 输入框 | round-design | `design/round-design/30-context-window.dc.html` | `design/round-design/30-context-window.png` | — | 已实现（R2） | — |
| 31 | 回合态与结束 | 会话头 + 输入框 + 转录 | round-design | `design/round-design/31-turn-state.dc.html` | `design/round-design/31-turn-state.png` | — | 已实现（R2） | — |
| 32 | 非文本内容块 | 转录 | round-design | `design/round-design/32-content-blocks.dc.html` | `design/round-design/32-content-blocks.png` | — | 已实现（R2） | — |
| 33 | 上下文压缩卡 | 转录 | round-design | `design/round-design/33-compaction.dc.html` | `design/round-design/33-compaction.png` | — | 已实现（R2） | — |
| 34 | agent 状态与错误 | 会话头下 / 转录 | round-design | `design/round-design/34-agent-state.dc.html` | `design/round-design/34-agent-state.png` | — | 已实现（R2）· 已接线（R3） | — |
| 40 | 输入框弹层合集 | 会话工作台 | round-design | `design/round-design/40-composer-popovers.dc.html` | `design/round-design/40-composer-popovers.png` | — | 已实现（R3） | — |
| 41 | 顶栏与侧栏弹层合集 | 会话工作台 | round-design | `design/round-design/41-topbar-popovers.dc.html` | `design/round-design/41-topbar-popovers.png` | — | 已实现（R3） | — |
| 42 | 输入框内联菜单 | 会话工作台 | round-design | `design/round-design/42-inline-menus.dc.html` | `design/round-design/42-inline-menus.png` | — | 已实现（R3） | — |
| 43 | 会话时间线弹层 | 会话工作台 | round-design | `design/round-design/43-session-timeline.dc.html` | `design/round-design/43-session-timeline.png` | — | 已实现（2026-09-20，`session-timeline` 分支） | 新增 `Timeline` 一组（maxHeightFactor / width / rail / railWidth / railColumn / node / nodeColor / label / turnGap）；`TextStyles` 补 `labelTabular`（`label` 加等宽数字，标题行用） |
| 50 | Agents 面板（ACP Registry） | agent 管理 | round-design | `design/round-design/50-registry.dc.html` | `design/round-design/50-registry.png` | — | 已实现（R5） | — |
| 51 | Registry 条目状态 | agent 管理 | round-design | `design/round-design/51-registry-states.dc.html` | `design/round-design/51-registry-states.png` | — | 已实现（R5） | — |
| 52 | agent 认证 | agent 管理 | round-design | `design/round-design/52-auth.dc.html` | `design/round-design/52-auth.png` | — | 已实现（R5） | — |
| 60 | 文件面板 | 文件面板 | round-design | `design/round-design/60-files-panel.dc.html` | `design/round-design/60-files-panel.png` | — | 已实现（R4） | — |
| 61 | 终端面板 | 文件面板（右栏） | round-design | `design/round-design/61-terminal-panel.dc.html` | `design/round-design/61-terminal-panel.png` | — | 已实现（R4） | — |
| 70 | 设置 | 设置（2026-09-17 起是右栏的一个标签） | round-design | `design/round-design/70-settings.dc.html` | `design/round-design/70-settings.png` | — | 已实现（R5）· 2026-09-17 改为右栏标签（画板本身未改）· 2026-09-22 新增「转录」分组（已实现，随画板 08） | — |
| 80 | ACP 流量调试 | ACP 流量调试 | round-design | `design/round-design/80-traffic.dc.html` | `design/round-design/80-traffic.png` | — | 已实现（R3） | — |

状态取值：`待实现` / `已实现（R<N>）` / `已废弃`。

## 变更记录（入库后对 `.dc.html` 的改动，PNG 已用 `scripts/render-design.ps1` 重渲染）

- 2026-09-22 新增画板 08「交互增强」（画布上原有三段，本次修订后第一次入库并渲 PNG，1440 × 1586），并给画板 70 加「转录」分组（frame 900 → 1010，`$preview` 1005 → 1110）。起因是三条交互诉求，做过协议核查后所有者裁定：**A「回复中的 token 速度标签」整段删除不做** —— 流式期间协议给不出输出 token（`usage_update.used` 是会话级上下文占用而非输出 token，四家 agent 口径还各不相同：claude-agent-acp 每个 `message_delta` 发一次、codex-acp 每次 response 完成发一次、dsh-acp-interactive 的 `used` 不含 output、pi-acp 根本不发；`session/update` 里也没有时间戳），回合级真值只有 `PromptResponse.usage`，回合结束才到，那是画板 31 页脚已经在做的事，**画板 31 因此零改动、不加平均速度**。保留的 B（回合折叠）与 C（在跑数徽标）**段落字母不重排**。B 的三处收口：「最终助手文本」= 该回合最后一段连续的 agent 文本，工具调用之间穿插的文本进折叠块；摘要行第二行的模型名取回合开始时的快照、中途换模型不改（原「模型 A → 模型 B」一行删去），agent 没有 model 配置时退化成单行；画板 43 的时间线跳到折叠块里的目标时先展开该回合再滚（画板 43 本身不改）。C 的口径改写：徽标挂「本次运行里打开过、内存里还有在跑会话」的工作区，不分 This Window 与 Recent Projects —— 原来的「Recent Projects 恒无徽标」配上本应用一个窗口只开一个工作区，会让触发钮的合计恒等于当前工作区的数，等于白做；弹层样张据此重画（This Window 一行、Recent Projects 里一行带徽标）。画板自带「本画板新增 token」表（`badge.*` 2 项 + `fold.*` 2 项），画板 00 不改，实现回写 `tokens.dart`。简报 `design/round-design/input/revision-05.md`。**顺带补齐**：`canvas.json` 里一直缺画板 07 的条目（2026-09-20 入库时漏登），本次与 08 一起补上。
- 2026-09-20 新增画板 07「深色 Token 对位表」（画布上已有，本次整份拉回入库并渲 PNG，1440 × 1760）。它是画板 00 深色区的完整版本：**一个浅色 token 名对应且只对应一个深色值**，中性 10 + 强调 6 + 语义 8 + popover 表面 1 + 阴影 1 共 26 项全部填满，无深色专有 token；另加「跟随派生」「代码高亮」「终端 ANSI」三小节说明不新增 token 的那些。相对画板 00 的深色区有两处变动：补 `d.strong` #f0f0f4，原第 10 档 `d.accent` 挪进强调色小节并改名 `d.accent.base`（画板 00 未改，gallery 的画板 00 对照页仍按旧表排）。实现按本表落地，**切换按钮本身画板上没有**（所有者 2026-09-20 指图放在侧栏标题条右端），见 [`DIVERGENCE.md`](DIVERGENCE.md) A 节第 2 条。画板自己写明的后续三张深色页面画板（90 工作台整屏 / 91 转录卡片合集 / 92 弹层与叠色）与画板 70「外观」小节都还没出。
- 2026-09-20 新增画板 43「会话时间线弹层」，并给画板 01 / 02 / 03 的会话头在 reload 与 ≡ 之间插入一个 history 按钮（01 的「尚无已安装 agent」态不画它，显示条件与 reload 同规则）。起因是一条会话跑到几十轮之后只能靠滚轮翻，找不到第 7 轮问的那句在哪；参照 pi 桌面版右侧的会话树，只取信息结构、视觉按本项目风格重做。简报 `design/round-design/input/revision-03.md`。画板自带「本画板新增 token」表（`timeline.*` 七项），已按表回写`lib/theme/tokens.dart`（画板 00 未改，这组值只服务画板 43）。**画布上的 01 / 02 / 03 是旧版**（缺 `4e59ef3` 那次本地整改的六处 32→36 与分栏把手注脚），所以这三张没有整份拉回来，只把 history 那个 span 按画布的写法插进本地文件再重渲 PNG。
- 2026-09-15 画板 40：`+` 弹层删去 Symbols 与 Selection 两行。需要 LSP 与编辑器选区，与 `docs/requirements.md`「不做」冲突；所有者裁定，见 `ROUNDS.md` § 6。
- 2026-09-15 画板 42：`/` 命令菜单合并为单组（保留 Commands 标题），去掉 Skills 分组标题与右侧的 built-in / 项目名来源标签；`<path>` 参数提示保留。`AvailableCommand` 只有 name / description / input，没有分组与来源字段；所有者裁定，见 `ROUNDS.md` § 6。
- 2026-09-18 新增画板 06「侧栏会话活动指示」。起因是会话在后台跑时侧栏看不出哪条在动、哪条已经跑完。A 组是运行中会话项底边的扫掠亮点线（1px 常亮底线 + 96px accent 亮点匀速单向掠过，`sweep.cycle` 1400ms · linear，**全系统唯一允许用 linear 的动效**；行高 48 → 58 不做过渡），B 组是回合结束后「N 条消息」之后的 6px success 绿点（只做 opacity，会话被查看后淡出且不留占位）；D 表规定两者严格互斥，取消与失败侧栏一律不表达。画板自带「本画板新增 token」表，已按表回写 `lib/theme/tokens.dart`（画板 00 未改，这组值只服务画板 06）。
- 2026-09-17 画板 10「Restore Checkpoint 分隔线」废弃（所有者裁定）：我们没有 git checkpoint（Zed 那条线恢复的是项目文件），它点下去与画板 11 用户气泡上的 Restore 是同一个动作；源文件与 PNG 留档，实现已删除 `lib/ui/transcript/checkpoint_divider.dart`。
- **实现先行、设计稿待补** → **已整体改为不补稿**（所有者裁定 2026-09-20）：这些条目连同结论移到 [`DIVERGENCE.md`](DIVERGENCE.md)，按「实现已超越画板 / 画板画错 / 实现有意少做」分三节记着，那几处**以实现为准、PNG 不再是它们的验收基准**（CLAUDE.md 规则 3）。看画板之前先看那份清单。
- 2026-09-17 新增画板 05「转场规格」，并给画板 00 的动效小节补 6 个值。起因是新建 / 切换会话与重载 agent 都是硬切、重载的等待期界面完全不动；原来全套动效资产只有两行时长，不足以实现。简报 `design/round-design/input/revision-02.md`。**画板 05 是纯静态规格图**：分帧只作示意，曲线与数值一律以规格表为准（例：A 组 `t=100ms` 那帧画的是视觉中点，按 `motion.ease` 实际已走完约 87%）。画板 00 的改动只在动效小节，`$preview` 高度由 924 收到 900（与 frame 一致），其余区域零改动。

## 页面与画板的对应

按 `docs/design.md` § 9 的页面清单：会话工作台、agent 管理、文件面板、设置、ACP 流量调试。每个页面至少一张画板；会话工作台需覆盖 `docs/acp-projection.md` 列出的 15 个 `session/update` 变体、权限请求、elicitation（form / url）、终端、5 种内容块、多计划载荷与压缩卡片。
