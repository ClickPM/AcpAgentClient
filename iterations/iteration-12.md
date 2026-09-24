# Iteration 12 — BACKLOG P0「请求与会话路由」三条

<!-- 保存为 iterations/iteration-NN.md。一个迭代一个文件、一项一行；流程正本见 iterations/README.md，不在这里复述。 -->

> 状态：已合并（待构建与手测收口）　起止：2026-09-24 –　基线：`main` = `7dcdfbe`

BACKLOG P0「请求与会话路由」三条一起做（下文「第 N 条」按那一小节原来的顺序数），所有者 2026-09-24 按推荐方案开工。
三条都只改前端（Dart），核心与 `docs/design.md` § 3 的事件 / 命令语义零 diff（§ 0 判据：走迭代）。
**编号**：开工时 `main` 上最新是 iteration-09；途中 `main` 前进到 iteration-10（`d626643`，「数据一致性」写锁），
`claude/optimize-three-p0-issues-6b5905` 分支已占 11，本文取 **12**。

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | fix | 两个 agent 同时在线时权限卡 / 表单卡串到另一个 agent 上：`PendingQueue` 的键从裸 `requestId` 改成 `(agentId, requestId)`，`byRequestId` / `answer*` / `markOpened` / `cancelRequest` / `withdraw` / `completeElicitation` 都带上 agentId；`forgetSession` 只删仍指向被删条目的键（同一个 agent 重连后同号的新卡不被摘掉）；同一个键又来一条时旧的挂起项标 withdrawn；`TurnController` 的回应发给发请求的那个 agent | BACKLOG P0「请求与会话路由」第 1 条 | `claude/p0-session-routing-optimization-89bc64`（`7aca3bb`）→ 合 `main`（`296f249`）后 `main` 快进 | validate 全绿（分支上 540 项、合并后再跑一遍）；未构建、未手测 | cursor 1 轮（`7dcdfbe..7aca3bb`）：**0 条**；合并只解文档冲突，不复审 | 已合并 |
| 2 | fix | 会话并跑时对正在跑的会话点 Restore，停止键消失、这一轮停不下来：`TurnController` 的在途轮从全局单槽改成按 sessionId 的 Map，Restore / Regenerate 只等本会话那一轮；`SessionStore.endTurn` 带上发起时 `startTurn` 开出的那一轮，已不是当前轮就不动（返回 false，调用方不点绿点） | BACKLOG P0「请求与会话路由」第 2 条 | 同上 | 同上 | 同上 | 已合并 |
| 3 | fix | 删掉一条正在跑的会话（agent 没声明 delete 时）agent 那边没人收尾：`deleteSession` 把收尾从「删 agent 侧」里拆出来——会话还挂在活着的连接上时，在跑或挂着请求就先 `session/cancel`（失败不挡删除），再 `_releaseSessionRequests` 回掉 elicitation；没挂在连接上的不往连接发 | BACKLOG P0「请求与会话路由」第 3 条 | 同上 | 同上 | 同上 | 已合并 |

## 收口

- 构建 / 手测：
- 发版：
- 移出项去向：
- 设计稿补注记：无（不动 UI）

## 备注

- **第 1 条为什么不在核心给 requestId 加 agent 前缀**（BACKLOG 给的另一种修法）：① 改的是 `acp/client_request` 的形状（`docs/design.md` § 3 第 57 行「与队列 `requestId` 同形的字符串」），按 § 0 是轮次的事；② 流量面板里的 id 与线上 JSON-RPC id 对不上，fixtures 与 gallery 跟着改；③ 修不掉**同一个 agent 重连后撞号**——新进程的 id 又从小整数数起，前缀还是同一个。前端复合键三条都没有，另把 ③ 在 `forgetSession` 里按条目身份删键补上（审计时新发现：旧实现删旧会话会把新会话同号的卡从表里摘掉，成了死按钮）。
- **`SessionStore.answerPermission` / `answerElicitation` 按会话找条目**（`pendingRequest`），再用条目上记的 agentId 拼键，不拿会话自己的 `agentId`：单测与 fixture 回放里会话可以没登记 agent，而条目上的 agentId 总是信封给的那个。
- **`completeElicitation` 顺带按 agent 过滤、从最新的往前找**：elicitationId 是 agent 自己起的，与 requestId 同一类撞号；不在 BACKLOG 原文的清单里，同一个根因，一并改。
- **先红后绿**：在基线 `7dcdfbe` 的临时 worktree 里放进新用例（去掉新签名多出的 agentId 实参；`endTurn(turn:)` 那条因签名不存在剔除），10 条判红——第 1 条 6 条（投影层 5、接线 1）、第 2 条 2 条（`test/app/concurrent_turns_test.dart`）、第 3 条 2 条（声明 / 没声明 delete 各一）；另两条防回归用例（agent 已退出不发 cancel、不在跑不发 cancel）在基线上本来就过。本分支上全绿。
- **测试核心的一个坑**：`FakeCore.agentConnect` 回空对象，agent 不进 initialized 态，每次 `newSession` 都会重连、把前一条会话标成挂空——并跑用例（`test/app/concurrent_turns_test.dart`）的假核心因此回一份 initialize。`FakeCore` 另加两份记账：`respondedTo`（回应发给了哪个 agent）、`cancelledSessions`（cancel 打到了哪条会话）。
- **validate 撞上一次 Rust 用例偶发**：第一遍 `cargo test` 里 `owned_terminals_are_released_when_the_agent_disconnects` 失败（本分支 `rust/` 零 diff）；同一个测试二进制随后单跑 3 次、`scripted` 整组 10 项连跑 2 次都过，第二遍 validate 全绿。是用例自己的时序竞态（`disconnect()` 返回即断言终端已释放，释放在连接收尾里做），记 `rounds/BACKLOG.md` P5，不在本迭代改。
- **合并**（所有者 2026-09-24 指示合并）：`main` 此时已前进到 `296f249`（iteration-10 写锁、iteration-11 资源三条、round dsh-1.3.2）。`git merge-tree` 先探：冲突只在三份登记文档——`iterations/README.md` 清单两边都留（10 / 11 在前、12 在后）、`rounds/BACKLOG-CLOSED.md` 末尾两边都留（`main` 五条在前、本迭代三条在后）、`rounds/BACKLOG.md` 两边关掉的条目都删；P0 两边合计关掉 8 条、归零，档位与总计按 `- [ ] ` 真实条数重算（P0 0 / P1 3 / P5 1，合计 4），P0 节首段改写成「7 条已全部关闭」。代码两边无重叠文件、全部自动合并，按「解冲突没改代码就不复审」不发复审；`pins/upstream.json` 随 `main` 变了（dsh 1.3.2），`fetch-upstream -Check` 全绿。P5 那条偶发用例在 `main` 上未改（只挪了行号），条目里的行号改成引那句断言。
