# Round design — 设计轮：用 Claude Design 出全套设计稿

<!-- 保存为 rounds/round-design/round-design.md；该轮其他管理产出放同一目录。 -->

> 状态：已完成（2026-09-14 立项，同日两轮审核后收口并入库，尚未提交；ROUNDS.md 尚未建立，本轮边界以 `docs/design.md` § 9 五个页面 + `docs/acp-projection.md` 全部投影面为准）

## 目标

产出一份可直接喂给 Claude Design 的简报与原料，所有者跑一次（或按画布分页分几次）Claude Design 即得到 40 张画板：覆盖 `docs/acp-projection.md` 的全部投影面与 `docs/design.md` § 9 的五个页面，且任何画板都不含原型的演示入口。可证伪：`design/round-design/materials.md` § 4 覆盖矩阵每行有画板，§ 2 黑名单在设计稿里 0 命中。

## 前置

- `prototype/index.html` 已完成（所有者 2026-09-14），是交互与信息层级的唯一来源。
- 文档已于 2026-09-14 切回 Claude Design（`design/README.md`、`docs/research.md` § 10）。
- 本轮不碰代码，不需要 `scripts/fetch-upstream.ps1 -Check`；Zed One Light 色板取自已有的 `vendor/upstream/zed`。
- 所有者的风格裁定（2026-09-14）：Notion 风；圆角不大；按钮无边框、悬浮出深色容器；颜色收敛、同一色系（Zed 做法）。

## 交付物

- `design/round-design/input/`：交给 Claude Design 的输入包。`design-prompt.md` 简报（风格系统、结构来源、黑名单、画板清单、产出要求）、`canvas.json`（40 张画板的分页布局与 frame）、`prototype/`（原型与两张截图的副本）、`reference/`（22 项交互表节选、可投影清单快照）、`README.md`（用法与文件清单）。
- `design/round-design/materials.md`：来源清单、黑名单、画板清单（编号锁定）、覆盖矩阵、审核清单、疑点。
- 所有者出稿并审核收口后：`design/round-design/{NN-*.dc.html, canvas.json, NN-*.png}` 入库，`design/README.md` 索引填齐 40 行。

## 验收

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | 简报、原料、布局三处画板清单一致 | `input/design-prompt.md` § 5、`materials.md` § 3、`input/canvas.json` 的编号、文件名、名称逐行相同 |
| 2 | 覆盖矩阵全映射 | `materials.md` § 4 每行至少一个画板号，且都在 § 3 清单内 |
| 3 | 黑名单零出现 | 设计稿入库后 `grep -rn "载入投影样例\|清空会话\|全部展开\|投影来源\|投影清单" design/round-design/*.dc.html` 为 0 行 |
| 4 | 画板数与编号 | `ls design/round-design/*.dc.html` 共 40 个，编号集合 = § 3 |
| 5 | 风格硬约束与 token 一致性 | `materials.md` § 5 第 4 到 6 条逐项过，无 high |
| 6 | 索引与 PNG | `design/README.md` 表 40 行、每行有 `.dc.html` 与 PNG 路径、状态 `待实现`；PNG 尺寸与 frame 一致 |

## 禁止

- 不写 `lib/`、`rust/` 任何代码；不建 `tokens.dart`（那是 R2 前的接线）。
- 不改 `prototype/index.html`。
- 不新增简报 § 5 之外的页面 / 面板 / 功能；缺的进 `rounds/BACKLOG.md` 等裁定。
- 不引入 Figma / Figma Make 任何环节。
- 默认继承：不改前端页面样式（规则 3）；不加设计稿没有的功能（规则 3）；不在 `vendor/upstream/` 里改代码（规则 4）。

## 代码审查

本轮无代码，审查形式是**设计稿审核**：审查者 = 主会话（Claude Code），依据 = `materials.md` § 5，时机 = 所有者提供画布链接后；不走 cursor。

- 审查方式：设计稿审核（materials.md § 5）
- 审查器与模型：主会话 Claude Code
- 审查范围与基准：所有者 2026-09-14 提供的导出包 `设计系统文档审核.zip`（40 张 `.dc.html` + `support.js` + `uploads/` 输入包副本），逐条对 materials.md § 5 的 10 项。审核在包的解压副本上做，**未改动设计源、未入库**（避免画布与仓库两边各改一份，见 `design/README.md` 约定）。
- 逐项结论：

| § 5 项 | 结论 | 证据 |
|---|---|---|
| 1 黑名单零出现 | **字面不过**（见 F1），实质无违规 | `载入投影样例` / `清空会话` / `全部展开` / `投影清单` / `txReplayBtn` / `tx-origin` 全部 0 命中；`投影来源` 31 命中，全部是画板头部注释；变体名在 10–34 各画板只出现 1 次（即该条注释），无块上灰标签 |
| 2 清单完整 | 过 | 40 个文件，编号与文件名与 § 3 完全一致，无多无缺，画板标题中文名逐一对上 |
| 3 覆盖矩阵 | 过 | § 4 的 41 行逐行探针命中（含 `plan_removed`、`requestScope`、`-32000`、`max_turn_requests`、`refusal`、五种内容块、未知变体丢弃） |
| 4 风格硬约束 | 过（两处小瑕，F5 / F6） | 圆角只有 3 / 4 / 6 + 圆形 50%，例外是 F5；字阶只有 11 / 12 / 13 / 15 / 20 + 等宽 12.5，零表外；无渐变 / 模糊 / 文字阴影 / 左侧彩条 / emoji（19、29 的 `✕` 只在注释散文里）；阴影只有 `0 4px 12px rgba(28,28,35,.10)` 一种，且只出现在浮层（18 的 `Go to File` 提示、21 的定位提示、25 的范围下拉、30/40/41/42 的弹层、00 的样本）；**实测色相 4 个**（accent/info 232°、error 10°、warning 46°、success 110°），≤ 5 |
| 5 token 一致性 | 过（一处表外，F3） | 抽 01 / 18 / 25 逐值对照 00-tokens：表外 hex 0 个；扩到全部 40 张，表外值合计 **1 个**（`rgba(255,255,255,.45)`，仅 25） |
| 6 frame 尺寸 | **不过**（见 F2，口径待裁定） | 页面容器本身准确：02/03/50/60/61/70/80 各含 1 个 `height:900px` 容器，01 含 2 个（两状态纵向摆放）；但画板 frame 高普遍超 900（01=1900、60=1260、61=1300、50/70/80=1000、02/03=960），合集高 900–1400 > 800 |
| 7 既定裁定 | 过 | `Keep All` / `Reject All` / `Edits ·` 全 0 命中；21 无接受 / 回退控件，注明只读；定位文案是「在文件面板中定位」（21、32）；03 注释明写「不假设有编辑器」 |
| 8 文案 | 过 | 无 lorem / ipsum / TODO / TBD；原型文案 10 项抽样全部原样保留（`New Claude Agent Thread`、`Error: tool call aborted`、`Awaiting Confirmation`、`Input Requested by dsh-acp-interactive`、`Go to File`、`Subagent Output`、`Only this time`、`Alt-Shift-A`、`Thought for 4 seconds`、`Waiting for input`） |
| 9 深色 | 过 | 00-tokens 含完整 `d.*` 深色中性 10 级 + `d.accent`；页面画板不出深色，与 § 6 疑点一致 |
| 10 导出 | **不过**（见 F7） | 包内 PNG **0 张**；根目录无 `canvas.json` |

- findings（16 条，2 high）。F1–F7 是源码级核对（不渲染）的结果；F8–F16 是 headless Edge 渲染后逐张目视的结果，详见 [`review-01.md`](review-01.md)：

| # | 画板 | 问题 | 建议 | 处理 |
|---|---|---|---|---|
| F1 | 04、10–34、40–42、51、52（31 张） | 画板头部注释用「**投影来源**：…」作前缀，命中本卡验收 #3 的字面 grep，`grep` 会回 31 行而不是 0 行。黑名单的本意是块上的灰色变体标签（`.tx-origin`），注释属设计说明、不是被设计的 UI，实质未违规 | 注释前缀改成「协议来源：」，验收口径不动（改文案，最小改动）。**不自行放宽验收**，按 `rounds/README.md` | 待裁定 |
| F2 | 01、02、03、40、41、50、51、52、60、61、70、80 | frame 高超出 materials § 3 的硬值（整页 1440×900、合集 1200×800）。但页面容器是准确的 1440×900，超出的是画板标题与注释，以及 01 的第二个状态、51 的九个状态纵向摆放 | 二选一：① 把 § 3 与验收 6 的口径改成「页面容器 1440×900 / 合集内容宽 1200，画板 frame 高按状态数与注释顺延」；② 导出 PNG 时裁到页面容器。倾向 ①，因为「多状态并排」是简报 § 5 自己要求的，与固定高度天然冲突 | 待裁定 |
| F3 | 25 | 全套唯一的表外值：Allow 主按钮（强调色填充）里的 kbd 芯片边框用了 `rgba(255,255,255,.45)`。00-tokens 只给了浅色面上的深色叠色，没有「强调色填充面上的发丝边框」 | 00-tokens 补一档 `border.on-accent = rgba(255,255,255,.45)`，否则 `tokens.dart` 会缺这个值、实现时被迫现编 | 待裁定 |
| F4 | 00 | `accent.hover = #4858c9` 是死 token：只在 00 自己出现（其余 39 张 0 次），且与 `accent.text = #4a59c9` 只差 2/255、肉眼无差别；页面画板实际的 hover 用的是 `accent.active = #3d4cb5`（helmet 里 `a:hover`） | 删掉 `accent.hover`，或与 `accent.text` 合并成一个值；否则 `tokens.dart` 多一个无视觉差别又无用处的常量 | 待裁定 |
| F5 | 27、40 | 表外圆角 `8px`，出现在布尔开关的 28×16 轨道（胶囊）。00-tokens 只有 3 / 4 / 6，简报 § 2.3 又写了「不出现胶囊按钮（状态小徽章可以全圆）」——开关轨道两头都不占 | 00-tokens 补一档「pill：仅用于布尔开关轨道与全圆徽章」，或把轨道画成 radius 4 的方轨 | 待裁定 |
| F6 | 00 与多数画板 | 芯片类内边距用了 3 / 5 / 7px（如 kbd 的 `padding:1px 5px`、swatch 的 `margin-top:5px`），不落 4px 网格，且 00-tokens 的间距档只列了 4 / 8 / 12 / 16 / 24，没给这些值命名 | 把「芯片内边距」在 00-tokens 里固化成一个命名值；否则 `tokens.dart` 里会散落 3 / 5 / 7 这些无名数字 | 待裁定 |
| F7 | 全部 | 导出包缺两样入库必需物：**0 张 PNG**（`design/README.md` 与 materials § 0.4 要求每画板一张、按 frame 原尺寸不缩放）；**根目录无 `canvas.json`**（包里只有 `uploads/round-design/input/` 那份输入用的）。另外包内有 `support.js`（Claude Design 运行时，`.dc.html` 靠它渲染）与 `uploads/`（输入包副本） | 补导 40 张 PNG 与画布的 `canvas.json`。入库时：`support.js` 一并进（否则 `.dc.html` 打不开），`uploads/` 不进（`design/round-design/input/` 已在仓库里，会重复） | 待裁定 |
| F8 | 03、50、60、61 | **high**：右栏展开时，— ☐ ✕ 窗口控制按钮出现在中栏顶栏右侧，而不是整个窗口的右上角；原型 `mockplus-expanded-view.png` 固定在窗口右上角 | 固定在右栏标签栏最右侧，中栏顶栏不再出现 | 采纳，revision-01 第 1 条 |
| F9 | 42 | **high**：`@` 与 `/` 菜单以 `bottom:76px` 向上弹出，输入框贴画板顶部，菜单上半截超出 frame 被裁 | 输入框下移，画板高度增到 900，菜单完整可见 | 采纳，revision-01 第 2 条 |
| F10 | 02（规则涉及 01、03） | medium：转录内容限宽 800 居中，输入框铺满整栏；03 列窄时两者又都铺满，无统一规则 | 转录与输入框共用 max-width 800 居中，列宽不足时都铺满 | 采纳，revision-01 第 3 条 |
| F11 | 25 | medium：范围下拉 `bottom:38px` 向上弹出，压住卡头，首行「Only this time」被裁 | 向下展开，四项完整可见 | 采纳，revision-01 第 4 条 |
| F12 | 02 vs 23 / 31 | medium：02 的停止按钮是 error 填充方块，23 / 31 是 ghost 容器 + error 小方块 | 统一为 ghost 容器 + error 小方块 | 采纳，revision-01 第 5 条 |
| F13 | 50 | medium：简报要求的「已登录」徽章缺失（51 有） | 给 Claude Agent 条目补上，样式同 51 | 采纳，revision-01 第 6 条 |
| F14 | 61 | medium：原型终端面板有清屏 / 重置，设计稿只有停止与重启 | cwd 行右侧补 ghost 清屏图标 | 采纳，revision-01 第 7 条 |
| F15 | 01 | low：状态 1 默认态里线程头「新建」图标与底栏「Agents」呈选中容器 | 默认态全 ghost | 采纳，revision-01 第 9 条 |
| F16 | 11 | low：`@` 提及是 accent 等宽文字，简报要求芯片 | 等宽 12.5、accent 文字、accent.soft 底、圆角 3 | 采纳，revision-01 第 10 条 |

- 结论：**未收口**。收口标准是「§ 5 第 1 到 3 全过、第 4 到 10 无 high」；当前第 1 项字面不过（F1）、第 6 项口径待裁定（F2）、第 10 项不过（F7，导出物缺失）；视觉核对另发现 2 个 high（F8、F9，画板内容错位 / 被裁）与 5 个 medium（F10–F14）。设计本身质量达标：40 张齐全、覆盖矩阵全映射、token 一致性 40 张里只有 1 个表外值、既定裁定全部照做、原型文案原样保留。除 F2 外的 15 条已合并进修订提示词 `design/round-design/input/revision-01.md`（F1 取「协议来源：」，F3 取 `border.on-accent`，F5 取 `radius.pill`）；F2 建议取方案 ①，改 `materials.md` § 3 与验收 6 的口径、不改设计，等所有者裁定。所有者贴修订提示词出第 2 版后复审，第 2 轮只核 F1、F7、F8–F14 与 PNG。
- **第 2 轮（2026-09-14，`设计系统文档审核v2.0.zip`）**：详见 [`review-02.md`](review-02.md)。F1、F3、F4、F5、F7–F16 全部确认整改；F6 剩 03 / 31 共 6 处 kbd 内边距，入库时机械改为 `0 4px`；F2 取方案 ①（`$preview` 高按内容校准，`canvas.json` 同步，`materials.md` § 3 口径已改）。全量静态检查无回退：黑名单 0、颜色字面量表外 0、圆角 / 字阶 / 字重全在表内。新发现：画布导出的 PNG 有假换行（01 标题、02 待授权条）与假截断（03 / 50 / 60 / 61 标题），同一 `.dc.html` 用 Chromium 渲染全部单行，判定为导出器字体度量问题；处置是仓库 PNG 基准改由 `scripts/render-design.ps1` 渲染，画布导出件不入库。
- 结论：**第 2 轮 收口**。§ 5 第 1 到 3 全过，第 4 到 10 无 high。已入库，见「本轮实测」。

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-design/BLOCKED.md`，停下呼人。禁止放宽验收标准自我通过。

## 本轮实测

- 画布链接：<待所有者回填>
- 出稿次数：2（首版 + 修订 01；每次导出包一次性给到 40 张，分页情况未知）
- 审核输入：第 1 轮 `设计系统文档审核.zip`（2026-09-14 由所有者提供），内含 40 个 `.dc.html`、`support.js`、`uploads/round-design/`（输入包副本），**无 PNG、无根 `canvas.json`**；第 2 轮 `设计系统文档审核v2.0.zip`（`delivery/`：40 个 `.dc.html`、`support.js`、`canvas.json`、`png/` 40 张、`README.md`）
- 审核方式：解压副本上做源码级核对（CLAUDE.md「不做视觉 review」），机械项用脚本逐值扫全部 40 张 —— 黑名单命中、画板清单与标题、覆盖矩阵 41 行探针、圆角 / 字阶 / 色相 / 阴影 / 禁用手法、全量 token 表外值、frame 与页面容器高度、既定裁定关键词、文案抽样
- 审核方式（视觉）：另做一遍渲染核对，headless Edge 按每张画板的 `$preview` 尺寸渲染 PNG 后逐张目视；设计轮的产物就是视觉，CLAUDE.md「不做视觉 review」只针对实现轮的代码审查。渲染件在会话 scratchpad，不入库
- findings 数：16（2 high F8 / F9；5 medium F10–F14；其余 F1–F7、F15、F16 为 low 或待裁定；阻塞收口的是 F1、F7、F8、F9）
- 整改轮数：1（`input/revision-01.md`，16 条全部整改；F6 的 6 处 kbd 内边距在入库时机械收尾）
- 入库文件清单：`design/round-design/` 下 40 个 `.dc.html`（含入库时的两处仓库侧改动：kbd `padding:0 4px`、`$preview` 高按内容校准 +24 余量）、`support.js`、`canvas.json`（h 与 y 按校准后的高度重排，页与顺序不变）、40 张 PNG（`scripts/render-design.ps1` 渲染，尺寸 = `$preview`，脚本已随本轮入库）；`design/README.md` 索引 40 行，状态 `待实现`，画布 URL 未提供记 `—`；`uploads/` 与画布导出的 PNG 不入库。**全部未提交。**
