# 运行时排障

> 相关：[`harness-pitfalls.md`](harness-pitfalls.md)（读 `%APPDATA%` 里应用写的文件要用哪个工具）、
> `docs/design.md` § 3 / § 4（契约）、`AGENTS.md` 规则 2（前端不做 agent 特判）。

## 1. 拿真实 ACP 日志回放对账（所有者报「界面上没显示 / 丢了」时的第一招）

**日志位置**：`%APPDATA%\AcpAgentClient\logs\acp-<日期>.log`。
**日期按 UTC 分文件**（北京时间 08:00 换文件，「昨晚」在前一天那份里）。

**行格式**：`<毫秒时间戳> <in|out|state|stderr|install|core> <agentId> <原样 JSON>`。
`session/update` / 请求 / 响应都在；`usage` 里的 token 数被脱敏成 `***`（规则 8）。
启动横幅 `core   AcpAgentClient <版本>` 标出当时跑的是哪一版。

**排障做法**（2026-09-24「收轮后结论没显示」一案，有效）：

1. 用 python 把某轮 `session/prompt` → 响应之间、以及响应之后同一 `sessionId` 的 update 压成摘要，
   **先看数据有没有到**（到没到客户端 vs 到了但没画出来，是两类完全不同的 bug）。
2. 在 `test/` 下放临时 `_scratch_*_test.dart`，把日志行原样喂
   `Sessions.applySessionUpdateEnvelope` / `startTurn` / `endTurn`，跑真实的 `foldsOf` + `buildRows` 逐轮判
   「最后一段 agent 文本有没有行」；要看画面就挂 `WorkbenchScreen`（批处理用按帧调度）按时间戳推帧、
   `RenderRepaintBoundary.toImage` 截图。**跑完删掉，不入库。**

## 2. 已知的上游行为：收轮之后还在推 update

**claude-agent-acp 的已知行为**：Claude Code 的后台命令 / 后台子代理跑完会把 agent 唤醒，
**在 `session/prompt` 已经回了 `end_turn` 之后**继续推 `tool_call` / `agent_message_chunk`
（2026-09-24 实测：早上 11:56 收轮后又推了 10 分钟、111 条）。
`session/load` 重放里还会冒出 `<task-notification>` 形式的 `user_message_chunk`。

我们的回合折叠会把这些收进已结束那一轮、连带把原结论折掉，界面也不显示运行中。
**处置**（iteration-15，2026-09-24）：折叠块与「最后一段」只按**收轮那一刻已有的条目**算
（`at` 不晚于 `TurnEntry.endedAt`），收轮后到的条目不进折叠块、按到达顺序排在结论后面照常显示；
回合页脚仍在整轮最后；收轮之后的活动**不标运行中**（协议没有信号说它什么时候结束）。
背景与实际做法记在 `design/DIVERGENCE.md` 第 36 条。

## 3. 重载后气泡里的 `[Context]` / `[resource_link …]` 是上游重放格式，不是渲染 bug

用户气泡在**重开会话 / 重载后**显示 `[Context] file:///…`（pi-acp）或
`[resource_link name="…" uri="…"]`（dsh-acp-interactive）原文 —— **不是客户端渲染回归**。

发送时客户端的本地回显按块渲染（@ 芯片），但两个 agent 存的是自己喂给模型的**摊平文本**
（pi：`src/acp/translate/prompt.ts`；dsh：`src/content.ts` 的 `resourceLinkText`），
`session/load` 重放时把这段文本当成一个 `user_message_chunk` 的 text 块发回来。
embedded resource（Sessions 引用、diff）在 pi 那边会摊成 `[Embedded Context] uri (mime)` 再跟上全文。

所有者 2026-09-23 报过一次，以为是当天才有的 bug（其实是当天开始大量用 @ / 粘贴路径 / 引用会话 / 引用 diff）。

- **规则 2 禁止前端对 agent 做特判**，所以客户端**不能**反解析这些文本；按 `AGENTS.md` 这属于上游问题，**不进 BACKLOG**。
- Zed 客户端对此同样原样显示（文本块直接进只读 MessageEditor，不反解析）；
  只有 Zed 自带 agent 因为存的是结构化 Mention、重放发 `resource` 块才显示芯片。
- 所有者 2026-09-23 看完对照后裁定**不修、维持现状**（dsh 改存原始块、给 pi-acp 提 issue 都不做）—— **别再主动提**。

## 4. claude-agent-acp 的 OAuth 刷新锁

（2026-09-16 实测）用 npx `@agentclientprotocol/claude-agent-acp@0.76.0` 真跑时，agent 的第一轮直接回文本
`Failed to refresh OAuth token: another Claude Code process is refreshing it or exited mid-refresh`，没有任何工具调用；重载会话同样失败。

**真因**：它和主会话共用 `~/.claude/.credentials.json`，刷新令牌时建了 `~/.claude/.oauth_refresh.lock`（一个**空目录**）
后半途退出，锁留在那里，之后每次跑都被挡。**报错文案指向「别的进程」，实际是它自己留下的过期锁。**

**怎么办**：真跑前 `ls ~/.claude | grep oauth`，有过期锁先**挪开**（`mv` 成 `.oauth_refresh.lock.stale-<时间>`，凭据文件不动；
`rmdir` 会被 auto 模式拦），再重跑就通。

**另一个现象**：它继承本机 Claude Code 的 auto 模式（`bashFirst`），读文件、改文件都走 bash 的 `cat` / `sed`，
**不发** `fs/read_text_file` / `fs/write_text_file`；要验 fs 回调与 diff 卡，提示词里要点名「用 Read / Edit 工具，不要用 bash」。
（R4 实测时第一次提示词没点名，6 张卡全是 terminal 卡，没有 diff 卡 —— 也说明终端卡 / 退出码 / 失败态在真 agent 上都对得上。）
