# AcpAgent Client 设计简报（喂给 Claude Design）

> 用法：所在目录（`design/round-design/input/`）整个交给 Claude Design，本文全文作为首条消息；附件是 `prototype/index.html`、`prototype/mockplus-default-view.png`、`prototype/mockplus-expanded-view.png`、`reference/interactions-22.md`、`reference/acp-projection.md` 与 `canvas.json`，用法见同目录 `README.md`。
> 仓库内部：画板清单与编号以上一层的 `../materials.md` § 3 为准，两处不一致时以 materials.md 为准并回来改本文。
> 可分多次出稿（按下面的画布分页顺序），但画板编号一经使用不得改动。

---

## 1. 这是什么

AcpAgent Client 是一个 Windows 首发的桌面客户端，用 Agent Client Protocol（ACP）接入多个编码 agent（Claude Agent、Codex、Cursor、pi、DeepSeek Harness、Zed 内置 agent）。前端用 Flutter 手写实现，你的设计稿会被逐画板翻成 widget，所以**每个画板对应一个可独立实现的界面单元**，画板里的每个状态都要能静态看见。

界面的信息结构与交互**已经在附件 `index.html` 原型里定死**：三栏布局，左栏会话列表，中栏会话转录加输入框，右栏可折叠的标签面板（文件浏览器 / 终端 / ACP Registry），顶部项目与分支，各种弹层。你的任务是**重做视觉、不改结构**：布局层级、控件有哪些、点了发生什么，一律照原型；配色、字体、间距、圆角、图标、状态样式由你按 § 2 的风格系统重定。

原型里有一批**只属于原型的验收工具**，设计稿里一律不得出现，见 § 4。

## 2. 风格系统（硬约束）

一句话：**Notion 的克制与纸感，Zed 的单一色系与密度，小圆角，无边框按钮。**

### 2.1 颜色：尽量少，同一色系

- **中性色阶只有一条**，从页面底色到正文字色约 10 级，整条色阶带同一个轻微色相偏移（向强调色的色相偏，饱和度极低，白与近黑的饱和度不超过 0.02）。层次全部靠中性色阶的明度差表达，不靠换色相。
- **强调色只有一个**，低饱和的蓝紫，参考 Zed One Light 的 `#5c78e2`。只用于：主按钮填充、焦点环、链接、选中态的文字与图标、进行中的 spinner。不用于大面积底色。
- **语义色四个**：error / warning / success / info，明度与饱和度对齐强调色（参考 Zed One Light：`#d36151` / `#a48819` / `#669f59` / `#5c78e2`），只用于状态图标、状态文字与细的状态条。
- 全套设计里出现的色相**不超过 5 个**（强调 + 4 语义），其余全是中性色阶。
- 参考锚点：Zed One Light 的中性面 `#fafafa` 编辑区、`#ebebec` 面板、`#dcdcdd` 标题栏、`#c9c9ca` 边框、`#242529` 正文、`#58585a` 次要文字、`#7e8086` 占位符。Notion 的底色 `#ffffff`、侧栏 `#f7f6f3`、正文 `#37352f`、hover 叠色 `rgba(55,53,47,0.08)`。取两者的方法，不要照抄任何一家的值。
- **本轮页面画板只出浅色**；`00-tokens` 画板里同时给出深色的中性色阶与强调色，供后续轮使用。

### 2.2 表面与边界

- 三级表面：页面底色、面板（侧栏 / 右栏 / 输入框）、弹层。用明度区分，弹层再加**唯一的一种阴影**（柔和、小偏移）。
- 分隔用 1px 发丝线（中性色阶的浅灰），不用阴影分层。
- 卡片（工具卡、权限卡、计划卡等）：1px 发丝边框，无阴影，无左侧彩色竖条，无渐变。
- **禁止**：渐变背景、玻璃模糊、彩色大色块、噪点纹理、emoji。

### 2.3 圆角：小

- 三档：**3 / 4 / 6**，上限 6。芯片与 kbd 用 3，按钮、输入框、菜单项用 4，卡片与弹层用 6。
- 不出现 8 以上的圆角，不出现胶囊按钮（状态小徽章可以全圆）。

### 2.4 按钮：无边框，悬浮出深色容器

- 默认态所有按钮**无边框、无填充**，只有图标或文字。
- 悬浮态出现一个**比所在表面更深的中性色容器**（浅色主题下约 6% 的深色叠色），按下再深一档（约 10%）；容器圆角 4，容器比内容四周各多 4 到 6px。
- 选中态（如当前标签、当前会话）用与按下态相同的容器再加强调色文字或图标。
- 唯一例外是**主按钮**（发送、Submit、Install、Allow）：强调色填充、白字，同样圆角 4，高度与普通按钮一致。危险动作（Deny、Remove、删除）用 ghost 样式加 error 色文字，不用红色填充。
- 焦点环：1.5px 强调色描边，偏移 1px，只在键盘焦点时出现。

### 2.5 字体与字阶

- UI 字体 **Geist**（Google Fonts），回退 system-ui；中文回退 Noto Sans SC（设计用）。等宽 **Geist Mono**，回退 ui-monospace。
- 字阶只留五档：11（元信息）/ 12（次要）/ 13（正文与控件，基准）/ 15（标题）/ 20（空态大字）。正文行高 1.5，控件行高 1.35。等宽 12.5。
- 数字（token 数、耗时、费用、行号）开等宽数字（tabular figures）。
- 字重只用 400 与 500，标题 500，不用 600 以上。

### 2.6 间距、控件尺寸、图标、动效

- 4px 网格；常用 4 / 8 / 12 / 16 / 24。
- 控件高度：紧凑 24（芯片、行内按钮）、标准 28（工具栏、输入框内控件）、主输入区 32。
- 图标：单线、1.5px 描边、16px 网格（工具栏可用 14），同一套风格，内联 SVG。agent 图标是各 agent 自己的 logo，设计里用单色占位。
- 动效只记时长：120ms（hover / 颜色）、160ms（展开折叠 / 弹层出现），ease-out，不弹跳。
- kbd 快捷键芯片（Alt-Shift-A 这类）是设计元素：等宽 11、发丝边框、圆角 3。

## 3. 结构与交互来源

- **信息层级与交互照 `index.html`**：栏目、顶栏、线程头、输入框及其左右控件、右栏标签页、每种卡片的折叠 / 展开 / 悬浮动作、弹层内容与分组、快捷键。原型的文案（含中英混排）**原样保留，不翻译、不润色**；示例数据（会话标题、agent 名、文件名、命令输出、计划条目）可直接复用。
- **原型里的两条既定裁定也照做**：不做 Zed 的「Edits 审阅条」（Keep All / Reject All 那一条），diff 卡只读；所有「打开 / 定位文件」动作落到本应用右侧的文件面板，不假设有编辑器。
- 原型是浅色的、样式中性的，**样式不作数**，只取结构。
- 附件 `reference/interactions-22.md` 是转录区 22 种卡片的逐项交互说明与协议来源；`reference/acp-projection.md` 是协议可投影内容的完整清单。画 27 / 29 / 31 / 32 / 34 / 40 / 80 这些画板时，字段名、枚举值、状态名按它取，不自造。
- 转录卡片在实现里是流式出现的，设计里每张卡的每个状态都画成静态。

## 4. 不得出现的内容（原型专用的验收工具）

以下控件与文案只在原型里存在，用于逐项验收，**设计稿的任何画板都不得出现**：

- 转录区顶部整条工具栏：`载入投影样例`、`清空会话`、`全部展开`、`投影来源`、`投影清单 22`（或任何数字）。
- 空态里的提示行「要看 22 项 ACP 投影样式，点上方的『载入投影样例』」。
- 每个块上方的小标签（如 `agent_message_chunk`、`tool_call_update` 这类 ACP 变体名的灰色标签）。
- 任何「载入样例 / 重置 / 回放 / 演示」性质的按钮。

原型靠这些工具切换出来的每种状态，本简报都已经拆成具体画板（§ 5），你按画板把状态直接画出来即可。

## 5. 画板清单

命名：`NN-<英文短名>.dc.html`，NN 是编号，画板标题用下表「名称」。桌面整页画板 frame **1440×900**；转录卡片画板宽 **800**、高按内容；弹层合集画板 **1200×800**。同一张画板里有多个状态时，横向或纵向并排摆放并用小标题标注状态名。

### 画布分页 P1：token 与壳（先出这一页）

| 编号 | 文件 | 名称 | 内容与状态 |
|---|---|---|---|
| 00 | `00-tokens` | Token 表 | 中性色阶（浅色 + 深色）、强调色及其 hover / active / 淡底四态、四个语义色、三级表面、边框两级、字阶五档、间距、圆角三档、控件高度、图标尺寸、阴影一种、焦点环、动效时长。每个值旁边写名字，这张画板将直接翻成 `tokens.dart`。 |
| 01 | `01-workbench-empty` | 工作台 · 新会话 | 完整壳：侧栏（logo 与应用名、搜索会话、会话列表、底部 设置 / 文件 / Agents / 终端）、顶栏（侧栏开关、项目名、分支、窗口控制）、线程头（agent 图标、`New Claude Agent Thread`、右侧 重命名 / 新建 / 重载 / 菜单 四个图标按钮）、空转录（居中的 agent 图标、标题、一行提示「在下面输入第一条消息开始会话；@ 引用上下文，/ 调命令」）、输入框（占位文案、左下 `+` 与用量圆环、右下 模型 / 思考强度 / 模式 三个下拉与发送按钮）。右栏折叠。两个状态：**有 agent 的新会话**；**首次启动、尚无已安装 agent**（空态改为引导去 Agents 面板安装）。 |
| 02 | `02-workbench-running` | 工作台 · 进行中的一轮 | 同一壳，转录里是一轮进行中：用户消息、思考流式态 `Thinking...`、一张运行中的工具卡（spinner）、输入框上方的悬浮条「Awaiting Permission · … · Scroll」、线程头出 spinner、发送按钮变红色停止方块。右栏折叠。 |
| 03 | `03-workbench-done` | 工作台 · 回合结束 + 右栏展开 | 同一壳，右栏展开为文件浏览器标签页（树 + 查看器），转录里是一轮完整结束：正文、若干折叠工具卡、计划卡折叠成 `Current: … · N left`、回合结束行（`end_turn · 10,240 tokens（in 8,912 / out 1,328）· $0.021 · 4.2s`）。 |
| 04 | `04-sidebar-states` | 侧栏与顶栏状态 | 会话项默认 / 悬浮（出重命名与删除图标）/ 选中；搜索输入中与无结果；侧栏折叠后的顶栏；顶栏项目名与分支的悬浮态。 |

### 画布分页 P2：转录卡片（编号与原型 22 项一致，另加 4 张）

| 编号 | 文件 | 名称 | 内容与状态 |
|---|---|---|---|
| 10 | `10-checkpoint` | Restore Checkpoint 分隔线 | 默认 / 悬浮。 |
| 11 | `11-user-message` | 用户消息气泡 | 默认（含 `@文件` 提及芯片）/ 点击聚焦 / 悬浮出 Edit · Copy · Restore / 编辑中（文本可改，Regenerate 与取消）。 |
| 12 | `12-assistant-text` | 助手富文本正文 | 标题、段落、有序无序列表、可勾选的任务清单、行内代码、引用、可点的文件链接、分割线。 |
| 13 | `13-code-block` | 代码块卡片 | 语言标签 + Copy；Copy 变 Copied；长行横向滚动。 |
| 14 | `14-gfm-table` | GFM 表格 | 列对齐、斑马纹、横向滚动。 |
| 15 | `15-mermaid` | Mermaid 图 | 图形态 / 源码态切换。 |
| 16 | `16-math` | 数学公式 | 行内 + 块级。 |
| 17 | `17-thinking` | 思考折叠块 | 流式 `Thinking...` / 结束折叠 `Thought for 4 seconds` / 展开。 |
| 18 | `18-tool-call` | 标准工具调用卡 | 折叠行（kind 图标 + 标题 + 路径或命令 + 状态）；展开（`Raw Input:` / `Output:` / 底部收起条）；路径悬浮出 `Go to File`；状态 pending / in_progress / completed；kind 至少画 read / search / execute / fetch / other 五种图标。 |
| 19 | `19-tool-failed` | 工具调用失败卡 | 右侧红 ✕ 常驻的折叠行 / 展开看错误。 |
| 20 | `20-tool-cancelled` | 工具已取消卡 | 输出位置是 `Error: tool call aborted`。 |
| 21 | `21-diff-card` | 文件差异对比卡 | 头部（路径 + `+4 −1`）折叠 / 展开（行号、增删行着色）；行悬浮「在文件面板中定位」。**只读，无 Keep / Reject。** |
| 22 | `22-terminal-card` | 嵌入式终端控制台卡 | ANSI 彩色输出 + `Exit Code 0` + 折叠；终端已 release 但输出仍留存的标注。 |
| 23 | `23-terminal-running` | 终端进行中卡 | spinner + 红色停止方块。 |
| 24 | `24-subagent` | 子代理委派卡 | 进行中（可停）/ 完成后展开：嵌套工具行、`↳ Subagent Output`、反馈图标。 |
| 25 | `25-permission` | 权限授权卡 | 标题（工具动作）+ `View Raw Input` 折叠 / 展开；Allow（Alt-Shift-A）/ Deny（Alt-Shift-X）；右侧范围下拉（Ctrl-Alt-A）展开态列出 allow once / allow always / reject once / reject always 的文案。 |
| 26 | `26-awaiting` | Awaiting Confirmation | 卡片下方的动画行；输入框上方的悬浮条（带 `Scroll` 定位）。 |
| 27 | `27-elicitation-form` | 表单模式交互卡 | 标题「Input Requested by dsh-acp-interactive · Waiting for input」；单选（含 Recommended 标记）、多选、两个 Other 文本框、数字与布尔字段各一；Submit / Decline / Cancel；必填未填的校验态。 |
| 28 | `28-elicitation-url` | 链接跳转交互卡 | 「Sign in requested by codex-acp」、URL 展示、`Open in browser` → `Waiting for completion...` → Completed 三态。 |
| 29 | `29-plan` | 计划卡 | 展开（`Plan` · `5 Tasks` · `1/5`，条目带 status 与 priority）/ 折叠（`Current: … · N left`）/ ✕ 隐藏；另画 `plan_update` 的三种载荷：结构化条目、文件链接、markdown；两份计划并存；一份计划被移除。 |
| 30 | `30-context-window` | 上下文窗口浮窗 | 输入框左下的圆环 `1%` / 悬浮弹层 `Context 1% · 10k / 1M` + `Rules`；带费用时多一行 cost。 |
| 31 | `31-turn-state` | 回合态与结束 | 运行中：线程头 spinner、发送按钮变红色停止方块；结束行五种 stopReason 各一：`end_turn`（带 tokens in / out、cost、耗时）、`max_tokens`、`max_turn_requests`、`refusal`、`cancelled`，后四种要一眼区分于正常结束。 |
| 32 | `32-content-blocks` | 非文本内容块 | image（内嵌预览）、audio（播放条）、resource_link（文件卡：名、mime、大小、打开）、embedded resource（文本内嵌 / 二进制给文件卡）；「不可渲染」的兜底文件卡。 |
| 33 | `33-compaction` | 上下文压缩卡 | in_progress → 摘要流式追加 → completed；error 态。 |
| 34 | `34-agent-state` | agent 状态与错误 | 转录内或线程头下的状态条：spawned / initialized / auth_required（列出认证方式入口）/ exited（退出码 + stderr 尾巴可展开）；「N 条未知会话更新已丢弃」告警；`需要认证（-32000）` 等错误条。 |

### 画布分页 P3：弹层与菜单

| 编号 | 文件 | 名称 | 内容与状态 |
|---|---|---|---|
| 40 | `40-composer-popovers` | 输入框弹层合集 | 模型选择器（搜索、分组 Recommended / Zed / cliproxy、Latest 徽章、当前项对勾）；思考强度；模式（Write / Ask 等，当前项）；布尔型会话选项的开关行；未知分类选项的兜底渲染；`+` 的上下文加入弹层；用量弹层；`Follow` 提示。 |
| 41 | `41-topbar-popovers` | 顶栏与侧栏弹层合集 | 项目切换（搜索、This Window、Recent Projects、Open Local Folders）；分支（搜索、本地分支、新建分支输入）；新建会话（选 agent）；线程头 ≡ 菜单；会话项的重命名 / 删除确认。 |
| 42 | `42-inline-menus` | 输入框内联菜单 | `@` 提及菜单（文件 / 文件夹 / 最近，带路径与图标）；`/` 命令菜单（命令名 + 描述 + 参数提示，来自 agent 的 available commands）。 |

### 画布分页 P4：其余页面

| 编号 | 文件 | 名称 | 内容与状态 |
|---|---|---|---|
| 50 | `50-registry` | Agents 面板（ACP Registry） | 右栏标签页：标题「ACP Registry · Agent Client Protocol 插件市场」+ Learn More；搜索；筛选 All / Installed / Not Installed 带计数；条目：图标、名称、版本、已登录徽章、描述、ID、源码仓库、Install / Remove。 |
| 51 | `51-registry-states` | Registry 条目状态 | 未安装 / 安装中（npx 解析；binary 下载 → sha256 校验 → 解压 的进度）/ 已安装 / 需要认证 / 安装失败（可重试、看日志）/ `uvx` 暂不支持 / 自定义命令的 agent 条目 / 缺 Node 时下载受管 Node 的提示。 |
| 52 | `52-auth` | agent 认证 | 认证方式选择（agent 型：agent 自己开浏览器；terminal 型：在内置终端运行给定命令）；terminal auth 运行中的可见终端；成功后自动重试新会话的提示；失败态。 |
| 60 | `60-files-panel` | 文件面板 | 右栏标签页：文件树（过滤输入、刷新、全部折叠、搜索开关；文件夹与文件图标）+ 查看器（文件名、路径提示、复制、源码 / Markdown 预览切换、元信息徽章）；查看器空态「没有打开的文件」。 |
| 61 | `61-terminal-panel` | 终端面板 | 右栏标签页：多标签（可关闭）、cwd、输出区、清屏；运行中 / 已退出。 |
| 70 | `70-settings` | 设置 | agent 配置列表（registry 型与 custom 型，custom 可编辑 cmd / args / env）；「从 Zed 导入」；Node 运行时状态（系统 Node ≥ 22 或受管 Node）；数据目录与日志路径。**只做这四块。** |
| 80 | `80-traffic` | ACP 流量调试 | 原始 JSON-RPC 行列表：方向（← →）、方法名、变体标签、时间、可展开的原文；`Authorization` / `api_key` / `token` 打码成 `***`；按方向与方法过滤；「未知会话更新已丢弃」计数与告警行；stderr 尾巴区；暂停跟随 / 复制行。 |

## 6. 产出要求

- 一画板一个 `.dc.html`，文件名照 § 5；布局照附件 `canvas.json`（已按编号、四个分页与 frame 尺寸摆好），需要时只改坐标与高度，不改文件名与分页。
- 每个画板设计完成后导出一张 PNG，按 frame 原尺寸，不缩放。
- 文案用真实内容（原型里的示例可直接用），不用 lorem ipsum，不编造价格与日期之外的硬数据。
- 图标全部内联 SVG 单线风格；不用 emoji；不用图片素材。
- 画板内的所有颜色、字号、间距、圆角必须能在 `00-tokens` 里找到对应值，不出现 token 之外的数值。
- 不加任何 § 5 未列的页面、面板或功能；觉得缺的，写成画布上的便签注释交回，不直接画。
