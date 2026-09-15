# Round 02 — 转录卡片（fixtures 驱动）

<!-- 保存为 rounds/round-02/round-02.md；该轮其他管理产出放同一目录。 -->

> 状态：进行中（开工 2026-09-15，分支 `round-02`，基线 `main` = 981e8f5；画板阶段收口提交见「本轮实测 · 收口」）

## 目标

25 张转录画板（10–34）全部成为可复用 widget，由投影状态层 + fixtures 驱动，每张画板的每个状态都能在 gallery 里静态出现；本轮不接核心、不碰 `rust/`。范围 = ROUNDS.md § 3「R2」。

画板 34（agent 状态与错误）在 ROUNDS.md § 1 / § 3 归 R2（「25 张转录画板（10–34）」），§ 2 表的 widget 文件名是 `lib/ui/shell/agent_state_bar.dart` 且 R3 也列了它：本轮按 § 2 表的路径把它做成画板 widget（数据源是 `lib/projection/agent_state.dart`），R3 只接线不改（接线零 diff 判据是整个 `lib/ui`，两种读法都覆盖）。

## 前置

- R1.5 裁定已落文档（`main` 981e8f5）：CLAUDE.md 规则 1 白名单含 markdown / re_highlight / flutter_math_fork / mermaid_flutter + mermaid_core / audioplayers / diffutil_dart；`validate.ps1` 同步。
- R2 三条裁定门（ROUNDS.md § 3 R2）全部已裁定 2026-09-15：24 子代理卡按 `docs/design.md` § 4 入站 `_meta` 识别键分组；10 / 11 的 Restore / Regenerate 照原型（本地截断 + 同会话重发）；15 / 32 按 R1.5 推荐项、画板不改。
- `scripts/fetch-upstream.ps1 -Check`：2026-09-15 开工时 8 个 OK。
- 本机：Flutter 3.47.4 / Dart 3.13.3；pub 缓存镜像 `pub.flutter-io.cn`（`flutter pub get` 58 个包变化，`objective_c` 9.4.1 override 生效）。
- 无参照 agent（fixtures 驱动）。

## 交付物

| 路径 | 内容 |
|---|---|
| `pubspec.yaml` / `pubspec.lock` | 新增 9 个直接依赖（裁定清单内）：markdown 7.3.1、re_highlight 0.0.3、flutter_math_fork 0.7.4、mermaid_flutter 0.3.0、mermaid_core 0.3.0、audioplayers 6.8.1、diffutil_dart 5.0.0、xterm 4.0.0、flutter_svg 2.3.0；`dependency_overrides: objective_c: 9.4.1`（注释写明原因与解除条件）。`windows/flutter/generated_plugin*` 由 `flutter pub get` 重生成（audioplayers_windows 插件注册） |
| `lib/projection/entries.dart` | 转录条目模型：消息 / 思考 / 工具调用（含 children 嵌套）/ 计划 / 压缩 / 权限 / elicitation / 轮边界 / 丢弃记录；§ 7 七项自造态全部落在这里 |
| `lib/projection/session_store.dart` | `SessionStore`（ChangeNotifier）：按 `sessionId` 累积；消息分组（`messageId` 变化另起，无 id 按角色连续合并）；思考折叠单元；轮边界 `startTurn` / `endTurn` / `cancel` / `restoreTo`；注入时钟；未知变体 / 未知 status 丢弃计数；`beginBatch` / `endBatch`；`debugSnapshot()`。`Sessions`：多会话表 + 共享 `PendingQueue` / `TerminalStore` / `AgentStateStore`，拆 `acp/*` 事件信封 |
| `lib/projection/tool_calls.dart` | `ToolCallStore`：同 id 覆盖、`content[]` / `locations[]` 整体替换、先到的 update 凭空建卡、未知 kind 落 other（保留原文）、未知 status 整条丢弃、`content[]` 逐项跳过计数、update 的 `_meta` 不并进卡、本地 cancelled；`InboundMetaKeys`（`claudeCode.parentToolUseId / subagent / toolName`、`dsh_subagent`，前端读取的入站键全部清单）；`TerminalBuffer`（ChangeNotifier，release 后留存，截断落字符边界） |
| `lib/projection/plans.dart` / `compaction.dart` / `usage.dart` / `pending.dart` / `agent_state.dart` | 计划（稳定整份替换 + `plan_update` 三种载荷 + `plan_removed` 打标 + 本地 ✕）；压缩（补丁语义 + chunk 追加）；用量（会话级 + 10k / 1M 缩写）；队列（按会话 + requestScope；cancel 回 cancelled；`$/cancel_request`；`elicitation/complete`；`acp_respond` 载荷）；agent 连接状态（7 种 state + droppedUpdates + stderr） |
| `lib/projection/batcher.dart` | `UpdateBatcher`：按帧合并（调度器注入；缺省微任务） |
| `lib/projection/fixture_replay.dart` | fixtures 回放器：out prompt → 轮开始；in update → 投影；请求入队；out 响应行按 `outcome` / `action` 回应队列；prompt 响应 → 轮结束；`initialize` / `session/new` 结果 → agent 状态 / modes / configOptions / cwd；local 行 → 终端缓冲；stderr → agent；`onDelay` 推进假时钟 |
| `lib/projection/wire.dart` | 修一处：`PlanUpdateWire.markdown` 读 `content`（schema `PlanMarkdown { planId, content }`，R0 写成了 `markdown`） |
| `lib/ui/transcript/`（21 个文件） | 一画板一文件：`checkpoint_divider`(10) `user_message`(11) `assistant_text`(12) `code_block`(13) `gfm_table`(14) `mermaid_block`(15) `math_block`(16) `thinking_block`(17) `tool_call_card`(18/19/20) `diff_card`(21) `terminal_card`(22/23) `subagent_card`(24) `permission_card`(25) `awaiting_bar`(26) `elicitation_form_card`(27) `elicitation_url_card`(28) `plan_card`(29) `context_window`(30) `turn_state`(31) `content_blocks`(32) `compaction_card`(33)；共用件 `icons.dart`（34 个内联 SVG，逐个取自 `.dc.html`，flutter_svg）、`card_chrome.dart`（卡片壳 / 头行 / 收起条 / 等宽块 / JSON 着色 / 徽章 / 按钮 / kbd / 弹层）、`markdown_body.dart`（package:markdown 解析 + 自写渲染）、`transcript_list.dart`（`ListView.builder` + `SelectableRegion` + 分发） |
| `lib/ui/shell/agent_state_bar.dart` | 画板 34（`AgentStateBar` + `DroppedUpdatesBar`） |
| `lib/gallery/` | `board_page.dart`（复刻画板版式）、`fixtures_source.dart`（回放 + 按 delay 推进的假时钟）、`boards/transcript_boards.dart`（10–17）、`boards/transcript_boards_2.dart`（18–34）；`gallery.dart` 加 `fitContent`（宽 800、高随内容） |
| `test/fixtures/10–24-*.jsonl`（15 个文件，148 行） | 新场景（README 有表）：cancel、富文本（12–16）、思考、全部 kind / 四态、子代理两种键、四种权限 kind、form / url elicitation、三种计划载荷、四种 stopReason、用量三档、压缩四态、终端进行中 / kill、五种内容块（真实 PNG）、无 messageId 分组、git log ANSI 终端。全部经 `rust/acp-core/tests/fixtures.rs`（不改）通过：209 行、15 变体、2 条故意拒绝 |
| `test/projection/session_store_test.dart`（20）/ `replay_test.dart`（13）/ `wire_test.dart`（改 3 处适配新行数） | 验收 1 |
| `test/gallery_harness.dart` + `test/gallery_test.dart` | 字体（Geist + msyh + KaTeX 13 家族）、SVG 预热、真实异步等待（图片解码）、内容尺寸截图；25 张画板页 + 00 |
| `test/ui/transcript_scroll_test.dart` / `selection_test.dart` | 验收 4 / 6 |

## 验收

| # | 检查 | 命令 / 期望 | 结果 |
|---|---|---|---|
| 1 | 单测覆盖 § 7 七项、§ 2.2 合并语义、§ 3.1 cancel 后挂起权限回 cancelled、§ 8.3 逐项跳过；分批喂与整批喂状态相同 | `flutter test test/projection/` | **过**：41 项全过（`session_store_test` 20 + `replay_test` 13 + `wire_test` 8）；分批 1 / 3 / 7 / 50 行一批的 `debugSnapshot()` 与整批深相等 |
| 2 | gallery 25 张与 PNG 逐张对照，文案 / 状态 / 层级 / 控件零缺失 | `flutter test test/gallery_test.dart` → `build/gallery/` | **过**：26 张（含 00）全部出图，对照表见「本轮实测 · 画板对照」；偏差逐条记录，无缺失 |
| 3 | `validate.ps1` 全绿；pubspec 只含裁定过的库；`tokens.dart` 零 diff | `powershell -File scripts/validate.ps1`；`git diff main -- lib/theme/tokens.dart` | **过**：`VALIDATE OK`（cargo build / test / clippy、gpui、analyze 无问题、flutter test 73 项）；`tokens.dart` diff 0 行 |
| 4 | 1,000 个块的转录滚动流畅（`ListView.builder` + 按帧合并） | `flutter test test/ui/transcript_scroll_test.dart` | **过**：1,001 块；1,000 条 update 一次 flush 只通知 1 次、应用 16 ms；首帧 610 ms；逐屏跳 + 平滑滚 166 帧 p50 30.7 / p95 52.9 / max 90 ms（debug、无 GPU，见「本轮实测」） |
| 5 | 24 子代理卡只按入站 `_meta` 键分组，代码里没有 agent 名 | `grep -rni "claude\|codex\|cursor\|dsh\|pi-acp" lib/projection lib/ui` | **过**：只命中 `InboundMetaKeys.dshSubagent = 'dsh_subagent'`（键名常量）、`claudeCode` 键名、注释里的「dsh 把子代理转录折进父卡」、以及 `cursorColor` / `SystemMouseCursors` 这类无关词 |
| 6 | `SelectableRegion` 跨消息选择实测 | `flutter test test/ui/selection_test.dart` | **过**：从用户气泡拖到工具卡标题，`plainText` 1,664 字符，含用户气泡 / 助手标题 / 代码块 / 工具卡标题四段 |

## 禁止

继承 TEMPLATE 三条。本轮额外：不碰 `rust/`（含 `tests/fixtures.rs` 的方法表）；不接 bridge 数据源（R3）；不做画板 01–04 / 40–42 / 80 的壳与弹层（R3）；不做终端真数据 / 文件定位动作（R4）；不在 `tokens.dart` 加 token（缺 token 记「本轮实测 · 偏离」并在阶段汇报里问所有者）；不 import `provider`（flutter_math_fork 的传递依赖）；不在代码里出现 agent 名（规则 2）。

## 代码审查

<!-- 完成后回填。审查路由见 CLAUDE.md「开发模式」与 docs/review-workflow.md：
     ① cursor CLI + grok 4.6 high → ② 硬失败回落主会话委派的 Claude Code 只读子代理（同一份任务书）。
     范围：前两轮全量（-Scope branch，即 main...HEAD），第 3 轮起只审上一轮整改 diff（-Scope since -Base <上一轮已审提交>）。 -->

- 审查方式：`powershell -File .claude\cursor-review.ps1`（默认档 `review`，后台跑，`--mode ask --force --trust --output-format text`）。
- 审查器与模型：① cursor CLI（`cursor-agent`）+ `cursor-grok-4.6-high`，全程没有硬失败，没有回落。
- 审查范围与基准提交：
  - 第 1 轮：`-Scope branch`（`main...HEAD`，全量），HEAD = f3a3f87，74 files / +9595；产物 `.claude/reviews/20260915-172733-review.out.md`（17:27:33 发起，17:37:52 落地）。
  - 第 2 轮：`-Scope branch`（前两轮必须全量），HEAD = 整改提交（见下）；产物待回填。
- findings 处理（第 1 轮 6 条：high 1 / P2 4 / P3 1，全部采纳，均为最小改动，没有新增机制）：
  1. [high] `restoreTo` 截断转录后挂起的 permission / elicitation 仍 pending，agent 会挂起 → **采纳**：`restoreTo` 改返回 `RestoreResult{turn, cancelledRequestIds, cancelledElicitationIds}`，截断范围内（含子代理卡 children 递归）仍 pending 的 permission 标 cancelled（回 `PendingQueue.cancelledOutcome`）、elicitation 标 cancelled + `action: cancel`（回新增常量 `PendingQueue.cancelledAction`）；接线侧（R3）必须拿这些 id 去 `acp_respond`。`PendingQueue` 加 `cancelRequest(requestId)`（复用 `cancelSession` 的标记逻辑，不是新队列）。单测 § 7.7 加一例：截断前的请求不动、已回应的不动、范围内的两类都回 cancelled 且 id 原样返回。
  2. [P2] Markdown 链接的 `TapGestureRecognizer` 每次 build 新建且从不 dispose → **采纳**：`MarkdownBody` 改 `StatefulWidget`，State 持有 `LinkRecognizers`（登记 + 统一释放）；只在 data / onLink / baseStyle / mermaidFontFamily 变化时重新解析并「先 dispose 再重建」，`dispose()` 全部释放；块 widget 实例缓存，父级重建不重建子树。`MarkdownBlock` 新增可选 `links` 参数，缺省不挂 recognizer。
  3. [P2] `session/new` 的 configOptions 未忽略未知 type → **采纳**：`applyNewSession` 与 `config_option_update` 同一判断，只收 `select` / `boolean`。
  4. [P2] elicitation schema 的 `type` 用 `as String?`，非字符串（`["string","null"]`）整卡 build 失败 → **采纳**：`type` / `title` / `description` 都 `is String` 才用，否则 type 当未知跳过字段、标题回落属性名。
  5. [P2] 子代理卡不渲染 children 里的 `ThoughtEntry` → **采纳**：children 按到达顺序渲染（工具行 → `ToolCallCard`、思考 → `ThinkingBlock`、消息 → `AssistantText`，首条消息前给「↳ Subagent Output」标签），`hasBody` 改为 children 非空或 content 文本非空。画板 24 重渲染无视觉变化（fixtures 里子代理没有思考块）。
  6. [P3] `content[]` 整份替换但 `skippedContent += skipped` 累加 → **采纳**：改赋值；§ 8.3 单测加一例「第二次 update 全合法 → 计数归 0」。
  - 整改后：`flutter analyze` 0 issue；`flutter test test/projection` 45 通过；`selection_test` + `gallery_test`（27 张）通过；`validate.ps1 -Quick` 全 PASS。
- 结论：待第 2 轮复审回填（high 级清零才合并 `main`）。

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-02/BLOCKED.md`，停下呼人。禁止放宽验收标准自我通过。

## 本轮实测

全部在本机（Windows 11 26200，`CKROG14AIR`，用户名 `Click`）实测，2026-09-15。gallery 产物 `build/gallery/NN-*.png`（gitignored），与 `design/round-design/NN-*.png` 逐张并排看。

### 收口

- 画板阶段收口提交：待回填（R3 接线以 `git diff <该提交>..HEAD -- lib/theme lib/ui` 为空作判据）。
- 依赖解析：`flutter pub get` 58 个包变化；直接依赖只有裁定清单内的 9 个 + flutter_rust_bridge；`validate.ps1` 白名单 PASS。`provider`（flutter_math_fork 传递依赖）没有被我们的代码 import（`grep -rn "package:provider" lib test` 为空）。

### 画板对照（验收 2）

每张画板一页（`lib/gallery/board_page.dart` 复刻画板的标题行 / 分节标签 / 底部注释），所有状态与画板同序排列；像素级差异不作 finding。「偏差」列是文案 / 状态 / 层级 / 控件之外、需要说明的取舍。

| 画板 | 状态（全部出现） | 偏差 / 说明 |
|---|---|---|
| 10 | 默认 / 悬浮 | 无 |
| 11 | 默认 / 聚焦 / 悬浮工具条 / 编辑中 / 芯片默认与悬浮 | 编辑框用 `EditableText`（无 Material），`@` 提及在编辑框里写成纯文本 `@name`（R3 重发时还原成 resource_link）；悬浮工具条上移 16 |
| 12 | 全部块类型 | h1 / h2 取 `TextStyles.title`，h3+ 取 13 / 500；引用左线 2px = `Borders.width × 2` |
| 13 | 默认 / Copied / 长行 | 代码行高 1.5（token 只有 1.5，画板 1.6）；Copied 在 `Motion.fast`（120 ms）后回落 |
| 14 | 对齐 / 斑马纹 / 横滚 / 数字列 tabular | 行间加 subtle 分隔线；数字列判定 = 整列都像数字 |
| 15 | 图形 / 源码 | mermaid_flutter 的 elk 布局把 `Proj` 排到右列（画板是纯竖链，spike § 5 已记）；gallery 的 Mermaid 字体用微软雅黑（flutter_tester 不做平台回退，真机用 `Fonts.sans`） |
| 16 | 行内 / 块级 | 无（KaTeX 字体在测试里手动装） |
| 17 | 流式中 / 结束折叠 / 展开 | 「Thought for 4 seconds」由 fixtures 的 delay 推进假时钟得出（1.3 + 2.4 s → 4 秒） |
| 18 | 折叠 / 展开 / 路径悬浮 / 三态 / kind 图标 | 副标题 `(lines 1-85)` 由 rawInput 的 `offset` / `limit` 推导；路径相对 cwd 并按平台用反斜杠；收起条高 24（画板 20，无 20 的 token）；move 用 ↳ 图标、switch_mode 用 ↺（画板没画这两个） |
| 19 | 折叠 / 展开 | 无 |
| 20 | 已取消 | 「Error: tool call aborted」是本地固定文案（画板如此） |
| 21 | 折叠 / 展开 + 行悬浮 | 行号从 1 起（diff 内容不带起始行偏移；画板从 24 起）；悬浮提示落在「## 文档」行 |
| 22 | 展开 / 折叠 | 折叠态副标题 = 命令、展开态 = cwd（画板两态各自如此）；xterm 只读并隐藏光标；输出区高度按行数（最多 12 行）算 |
| 23 | 进行中 | 无 |
| 24 | 进行中 / 完成展开 | **多一节**：同一张卡吃 `_meta.dsh_subagent`（覆盖第二个入站键；画板没有这节，只是同一 widget 换数据） |
| 25 | 默认 / Raw Input 展开 / 范围下拉 | Raw Input 显示请求里 `toolCall`（ToolCallUpdate）原样 JSON（画板扁平写了三个键）；下拉展开时卡片不裁剪 |
| 26 | 等待行 / 待授权停靠条 / 待输入停靠条 | 「Awaiting Input · dsh-acp-interactive 请求表单填写」的 agent 名来自 initialize 的 agentInfo |
| 27 | 默认 / 校验态 | Other 文本框没有占位文案（画板的「留空表示用上面的选项」不在 schema 里，规则 2 不自造，记 BACKLOG）；「Recommended」只标 `default`；未知 type 的 `legacy` 字段被忽略（fixtures 里故意放了一个）；数值框类型元信息「1–16」来自 minimum / maximum |
| 28 | 默认 / 已打开 / 完成 | 标题「Sign in requested by <agentInfo.name>」（fixtures 是 dsh，画板写 codex）；完成态在 Dart 侧调 `completeElicitation`（`elicitation/complete` 不进 fixtures，见 README） |
| 29 | 展开 / 折叠 / file / markdown / 两份并存 / 被移除 | 「N left」= pending 条目数（5 条、1 完成、1 进行中 → 3）；file 载荷路径相对 cwd |
| 30 | 默认 / 弹层 / 带费用 / 78% | 弹层与输入条竖排（画板重叠）；圆环 stroke 用 `IconSizes.stroke`（画板 2.5） |
| 31 | 运行中 / 五种结束行 | 线程头标题 = `New <agentInfo.title> Thread`（数据驱动）；`max_turn_requests` 行没有「18 次请求」（协议没有请求计数）；cost 取会话级 `usage_update`；耗时是本地时钟 |
| 32 | image / audio / resource_link / text / blob | 尺寸按真实数据算（10.7 KB / 44 B / 128 B，画板是示意值）；图像预览高 220 是局部几何；音频进度是静态预览（播放器只在点击时创建，测试环境没有平台通道） |
| 33 | in_progress / 流式 / completed / failed | 状态值显示协议原值 `failed`（画板写 `error`，同一态；记 BACKLOG 给设计稿改字） |
| 34 | spawned / initialized / auth_required / exited / 丢弃告警 | initialized 行列 `agentCapabilities` 顶层键（画板列的是客户端能力 fs / terminal / …，记 BACKLOG）；认证按钮文案「用 <name> 登录」（agent 型）/「在内置终端认证」（terminal 型）；agent 名 / 版本来自数据 |

### 偏离与取舍

- **非 4px 网格的画板尺寸就近取 token**（R0 起的既定做法）：内边距 10px → `s8` / `s12` 或 `Controls.padInput`；收起条 20px → `Controls.compact`；代码行高 1.6 → `LineHeights.body`；圆环 stroke 2.5 → `IconSizes.stroke`。没有加 token，`tokens.dart` 零 diff。
- **文件局部几何常量（不是样式 token，validate 不扫、逐个记录）**：`ImageBlock._previewHeight = 220`（画板 32 示意框）、`AudioBlock._barHeight = 3`、`_ScopeMenu._width = 330`（画板 25 下拉宽）、`ContextPopover._width = 266`（画板 30 弹层宽）、`TerminalCard._maxLines = 2000`（回滚行数）、`Spinner` 周期 = `Motion.base × 5`、开关轨道 28 × 16 = `Controls.standard × Kbd.lineHeightPx`。若所有者要求这些也进 token，下一轮加。
- **`acp/agent_state` 与 `elicitation/complete` 不进 fixtures**：前者是核心事件不是 ACP 线上行；后者 `fixtures.rs` 方法表没有、R2 不碰 `rust/`。gallery 在 Dart 侧构造（`transcript_boards_2.dart` 34 / 28）。记 BACKLOG 让 R3 补方法表。
- **fixtures 生成器不入库**：15 个新文件由 scratchpad 里的 python 脚本一次性产出后入库（README 注明），后续改动直接改 `.jsonl`。
- **`wire.dart` 修一处 R0 的字段名**：`PlanUpdateWire.markdown` 原读 `json['markdown']`，schema 里 `PlanMarkdown` 的正文字段叫 `content`；`wire_test` 加了 file / markdown 载荷断言。
- **画板 34 的文件位置**：按 ROUNDS § 2 表放 `lib/ui/shell/agent_state_bar.dart`（不在 `lib/ui/transcript/`），理由见「目标」。

### 投影层与 fixtures（验收 1）

- `flutter test test/projection/`：41 项全过。覆盖：§ 7.1 cancel 只标未完成的卡 + 挂起权限回 cancelled（协议 status 不被伪造）；cancel 后到达的 completed 仍覆盖 status 但本地标记保留；§ 7.2 三种分组；§ 7.3 假时钟耗时；§ 7.4 update 先到建卡、tool_call 后到补全同一张卡、权限请求只带 toolCallId；§ 7.5 release 后留存 + 代理对边界截断；§ 7.6 折叠单元开 / 关；§ 7.7 轮边界 + Restore 截断并从表里摘掉工具卡 / 计划；§ 2.2 集合替换 / 部分更新 / update `_meta` 不并入 / 未知 kind / 未知 status 丢弃；§ 8.3 逐项跳过计数；子代理按键分组 + 父卡未到先建卡；config 未知 type 忽略、session_info null 清空；计划 / 压缩规则；批量一次通知；`$/cancel_request` / `elicitation/complete` / requestScope 只进队列 / `acp_respond` 载荷形状。
- `replay_test`：209 行 fixtures 整批与 1 / 3 / 7 / 50 行一批回放的 `debugSnapshot()` 深相等；15 变体全部出现且无丢弃；01–08 主线 + 10 / 14 / 15 / 16 / 18 / 21 / 23 各文件的关键状态断言。
- Rust 侧 `cargo test -p acp-core --test fixtures`：209 行通过（新增行没有碰 `fixtures.rs`：只用它方法表里的方法、id 全局唯一、不新增拒绝行）。fixtures 里故意放了一个未知 `type: color` 的 elicitation 字段验证 UI 忽略。

### 滚动粗测（验收 4）

`flutter test test/ui/transcript_scroll_test.dart`（单独跑；debug、无 GPU，数字只作相对参考）：1,001 块（用户 / 思考 / Markdown 含代码块 / 读文件卡 / diff 卡 / 执行卡 / 计划卡 轮换）；`UpdateBatcher` 排队 1,000 条后一次 flush → `notifyListeners` 1 次、应用 16.1 ms；首帧 610 ms（含 1,001 块的 `buildRows` 与首屏 widget 构建，视口 800 × 900）；逐屏 `jumpTo` 到底（106 帧）+ 每帧 40px 平滑滚 60 帧：p50 30.7 ms / p95 52.9 ms / max 90.0 ms（`build/scroll-report.json`）。`ListView.builder` 只构建视口内的卡，1,001 块的 `maxScrollExtent` 95,061 px。

### 跨消息选择（验收 6）

`flutter test test/ui/selection_test.dart`：`SelectableRegion(selectionControls: emptyTextSelectionControls)` 包住 `ListView.builder`，鼠标从用户气泡左上拖到工具卡标题右下，`SelectedContent.plainText` 1,664 字符，含「加一项校验」（用户气泡）、「样式字面量校验」（助手正文标题）、「Assert-NoStyleLiteral」（代码块）、「Read file」（工具卡标题）。Markdown 链接的 recognizer 已下推到叶子 span（spike 的坑）。

### 测试环境的坑（沿 R0 / R1.5）

- flutter_svg 的 `SvgPicture.string` 在 isolate 里解码，FakeAsync 等不到 → `test/gallery_harness.dart` 先在 `runAsync` 里把 34 个图标 × 3 种 stroke 解码进 `svg.cache`（命中后是 `SynchronousFuture`，同帧出图）；`Image.memory` 同理，pump 前先 `runAsync` 让出 250 ms 真实时间。
- Mermaid 主题只能给一个家族名、flutter_tester 不做平台回退 → gallery 传微软雅黑；真机用 Geist + 平台回退（R3 真机验一次）。
- xterm 的 `TerminalView` 在无 Material 的 `Directionality + MediaQuery` 下可渲染；只读展示写 `ESC[?25l` 隐藏光标。
- Bash 工具里的 `\\` 塌成 `\`：生成 fixtures 的 python 脚本里带转义的字符串被吞过一次（diff 文本、ANSI 序列），改用 `chr(10)` / `chr(27)` 与 Write 工具重写。
