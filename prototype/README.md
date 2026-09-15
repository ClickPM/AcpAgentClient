# prototype

**这里的东西不是设计稿，也不是产品代码。** 它是开工前用来验证「严格 ACP 投影」能不能成立的一次性原型：把 ACP 线上消息喂进一个投影状态机，看转录里长出什么。

- **样式不作数。** 功能边界与视觉一律以 `design/` 的画板为准（CLAUDE.md 规则 3）。原型用的是中性的开发者工具样式，只为看清结构，不要拿它当 UI 参照。
- **不进构建。** 纯 HTML + CSS + JS，无框架、无依赖、无构建步骤，双击 `session-projection.html` 即可跑。
- **可以丢。** R2 会话工作台按画板实现之后，这里的价值就只剩「状态机的参考实现」。

## index.html — 界面骨架原型（含会话区交互）

回答的问题：**投影出来的东西摆在真实界面里怎么用**。左侧会话列表 / 顶栏 / 右侧面板是壳，重点是中间**会话区（转录流 + 输入框上方的停靠条 + 回合态）**。

**会话区的交互严格照 Zed Agent 实测截图实现**（2026-09-14 逐项截图，见 `rounds/BACKLOG.md` 的截图验收条目），不是照着这份 html 原有的交互约定编的。共 22 项，编号与截图里「总纲一 / 二 / 三」一致：

| # | 样式 | 可点的交互 | 投影来源 |
|---|---|---|---|
| 1 | Restore Checkpoint 分隔线 | 点一下丢弃其后全部投影块 | 客户端本地态 |
| 2 | 用户消息气泡 | 点击聚焦（蓝边）；悬浮出 Edit / Copy / Restore；Edit → 改文本 → Regenerate 截断后续并重起一轮 | `user_message_chunk` |
| 3 | 助手富文本正文 | 任务清单复选框可勾；文件链接可点 | `agent_message_chunk · text` |
| 4 | 代码块卡片 | 语言标签 + Copy（变 Copied） | 同上 |
| 5 | GFM 表格 | 列对齐 / 斑马纹 / 横向滚动 | 同上 |
| 6 | Mermaid 图 | 图形 ↔ 源码切换 | 同上（客户端渲染） |
| 7 | 数学公式 | 行内 + 块级 | 同上 |
| 8 | 思考折叠块 | 折叠 ↔ 展开；流式时是 `Thinking...`，结束是 `Thought for X seconds` | `agent_thought_chunk` |
| 9 | 标准工具调用卡 | 整行点开 → `Raw Input:` / `Output:` / 底部收起条；路径悬浮出 `Go to File` | `tool_call` + `tool_call_update` |
| 10 | 工具调用失败卡 | 右侧红 ✕ 常驻，展开看错误 | `status: failed` |
| 11 | 工具已取消卡 | 输出位置是 `Error: tool call aborted` | **客户端本地态**（`ToolCallStatus` 没有 cancelled） |
| 12 | 文件差异对比卡 | 头部折叠；点任一行「在编辑器中定位」 | `tool_call.content[] · diff` |
| 13 | 嵌入式终端控制台卡 | ANSI 彩色输出 + Exit Code + 折叠 | `tool_call.content[] · terminal` |
| 14 | 终端进行中卡 | spinner + 红色停止方块 → `terminal/kill` | `terminal/*`（本地流） |
| 15 | 子代理委派卡 | 进行中可停；完成后展开 → 嵌套工具行 + `↳ Subagent Output` + 反馈图标 | `tool_call · _meta.claudeCode.subagent` |
| 16 | 权限授权卡 | `View Raw Input` 展开；Allow / Deny（Alt-Shift-A / Alt-Shift-X）；右侧范围下拉三选一（Ctrl-Alt-A） | `session/request_permission` |
| 17 | Awaiting Confirmation | 卡下的动画行 + 输入框上方悬浮条（带 Scroll 定位） | 客户端本地态 |
| 18 | 表单模式交互卡 | 单选 / 多选 / 两个 Other 文本框；Submit 校验必填后回 `{action:"accept",content}`；Decline / Cancel | `elicitation/create · form` |
| 19 | 链接跳转交互卡 | Open in browser → `Waiting for completion...` → 收到 `elicitation/complete` 变 Completed | `elicitation/create · url` |
| 20 | 计划卡 | 展开是 `Plan` + `5 Tasks` / `1/5`；折叠成 `Current: …` + `N left`；✕ 隐藏 | `plan` / `plan_update` |
| 21 | 上下文窗口浮窗 | 输入框左下的圆环 `1%` → `Context 1% · 10k / 1M` + `Rules` | `usage_update` |
| 22 | 回合态与结束 | 运行中工具栏出 spinner、发送箭头变红色停止方块；点它发 `session/cancel`，未完成的工具卡转本地 cancelled、挂起的权限请求回 `cancelled`、`stopReason` 变 `cancelled` | `stopReason` + end-turn `usage` |

**初始态是「新建会话」**：转录为空，只有输入框；在输入框发第一条消息就会长出一轮（思考流式态 → 运行中工具卡 → 正文 → 回合结束）。22 项投影样式放在页面里的两个 `<template>` 里，不占初始态。

会话区顶部是**只属于原型的**验收工具条：`载入投影样例`（注入 22 项样式，含截图里的瞬时态——1 个待授权、1 个待输入、2 个运行中）、`清空会话`（回到初始态）、`全部展开`、`投影来源`（给每个块打上它对应的 ACP 变体标签）、`投影清单 22`（逐项跳转并高亮，供逐一截图验收）。

**照了截图但没做的（所有者裁定 2026-09-14）**：Zed 的 **Edits 审阅条**（`Edits · N files · +X −Y` 加 `Keep All` / `Reject All` / 逐文件 Keep、Reject）不做 —— 本客户端不是 IDE，不具备接受 / 回退文件改动的能力，超出范围。工具卡里的 `diff` 内容（第 12 项）照旧投影，但只是**只读展示**：点行只在右侧文件面板定位，不提供接受 / 回退。同理，涉及「打开 / 定位文件」的动作一律落到本应用自己的右侧文件面板，不假设有编辑器。

**注意**：这里的样式同样不作数（规则 3），Zed 是深色、这份原型是浅色；照搬的是**交互与信息层级**，不是配色与间距。

## session-projection.html — ACP 会话投影原型

回答的问题：[`docs/acp-projection.md`](../docs/acp-projection.md) 列的 15 个 `session/update` 变体 + 权限 + elicitation + 终端 + 5 种内容块，**投影到界面上到底是什么样，够不够，哪里不够**。

打开后按「播放」，它会回放一段合成的 ACP 会话（客户端拉起 dsh-acp-interactive，让它给 `scripts/validate.ps1` 加一项校验）。左栏是会话级状态，中栏是转录，右栏是线上流量。

### 这段回放专门覆盖了这些点

| 点 | 在原型里怎么看 |
|---|---|
| 15 个变体全覆盖 | 右栏流量按变体打标；左栏「已投影变体」逐个点亮 |
| 新声明的 `plan` 能力 | 稳定 `plan` 之外，还有 `plan_update`（items 载荷）与 `plan_removed` |
| 新声明的 `session.compaction` | 压缩卡片：in_progress → 两段 `compaction_summary_chunk` → completed |
| `notice` 被丢弃（裁定的兜底方案） | 流量里标红「丢弃」，左栏丢弃计数 +1，转录里**什么都不出现** |
| 未知的未来变体 | 同上，用一个假想的 `artifact_update` 演示 |
| 工具调用合并语义 | `content` / `locations` 是**替换**不是追加，看 read 那张卡的三次更新 |
| 集合项跳过（`VecSkipError`） | 有一次 update 的 `content[]` 里混了未知类型，只丢那一项，卡上标「跳过 1 项」 |
| 未知 `kind` 回落 | 一次 `kind: "sculpt"` 落到 `other` |
| 凭空建卡 | 一条 `tool_call_update` 的 id 此前没出现过，直接建卡 |
| 客户端本地的「已取消」 | 流播放中点「取消本轮」：未完成的工具卡变 cancelled（协议里**没有**这个状态） |
| 权限请求 | 流会停下等你选；不选就不往下走 |
| elicitation（form 模式） | 同上，渲染受限 JSON Schema 的表单 |
| 终端 | 输出是**本地流**不是协议消息（流量里标 local）；`terminal/release` 之后输出仍然留在卡上 |
| 5 种内容块 | 最后一条消息里 text / image / audio / resource_link / embedded resource 各一 |
| 消息分组 | `messageId` 变了就另起一条气泡；没有 `messageId` 时按角色连续合并 |
| 轮边界 | 客户端自己切的，不是协议给的 |
| 密钥打码 | `session/new` 的 MCP 头与终端 env 里的 token 在流量面板里是 `***` |

### 目录

```text
prototype/
├── README.md
├── index.html              界面骨架 + 会话区交互（单文件，无依赖）
├── session-projection.html
└── assets/
    ├── projection.css      样式（不作数）
    ├── fixtures.js         合成的 ACP 线上流（wire script）
    ├── projection.js       投影状态机 —— 这一份是有参考价值的部分
    └── app.js              播放器与渲染
```

`projection.js` 刻意不碰 DOM：它只吃线上 JSON、吐状态。R0/R1 往 Rust + Dart（`lib/projection/`）搬的时候，搬的是它的规则，不是它的代码。
