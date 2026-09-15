# 原型 index.html 的 22 项会话区交互（节选）

> 节选自仓库 `prototype/README.md`，2026-09-14 快照。表里的编号对应简报画板 10 到 31（画板号 = 10 + 表中序号 - 1）。
> 「投影来源」列是每张卡在 ACP 协议里的数据来源，画卡片时按它决定要显示哪些字段。

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
