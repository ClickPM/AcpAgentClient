# Iteration 07 — BACKLOG P0「会话身份与生命周期」四条

<!-- 保存为 iterations/iteration-NN.md。一个迭代一个文件、一项一行；流程正本见 iterations/README.md，不在这里复述。 -->

> 状态：进行中　起止：2026-09-23 –　基线：`main` = `34e66be`

BACKLOG P0「会话身份与生命周期」四条一起做（下文「BACKLOG 第 N 条」按那一小节原来的顺序数）。第 1 / 2 / 4 条同根：前端没有「这条会话挂在哪条 agent 连接上」的状态，
一直拿「内存里有没有转录（`store`）」代替；本迭代补上**挂载代次**（每个 agent 的连接换过几代 + 挂空的会话集合），三条共用。第 3 条独立。
所有者 2026-09-23 按推荐项整批裁定（修法与两处用户可见行为见「备注 · 裁定」），在 worktree 分支里做。
**编号**：开工时 `main` 上最新是 iteration-04，本文起名 05；途中 `main` 合进了另一条 iteration-05（终端组字），`claude/system-theme-toggle-icon-fd8551` 占了 06，故改为 07（`design/DIVERGENCE.md` 同理避开 `main` 已用的第 32 条，取 33）。

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | fix | 载会话中途失败会留半份转录：失败时整段重放作废（`Sessions.discardUpdates`，在挂起的 batcher 队列里与清空成对排），原先有转录的原样留着；删掉 `_updateArrivals` / `noteUpdateArrival` 那套「重放了几条」的判断 | BACKLOG P0「会话身份与生命周期」第 4 条 | `claude/conversation-identity-lifecycle-p0-dd6bcc` | | | 进行中 |
| 2 | fix | 发消息可能把选中的会话静默顶掉：`send()` 按四态分流（none / attached / detached / unattachable），detached 先挂回（连上 → load / resume）再发，挂不回不开新会话、这一轮按「发出去失败」收在画板 31 的结束行；unattachable 按 R3 新开一条，输入框占位文案先说明 | BACKLOG P0「会话身份与生命周期」第 1 条 | 同上 | | | 进行中 |
| 3 | fix | 重载或崩溃之后，别的会话发不出去：连接每换一次，这个 agent 名下内存里的会话全部标成挂空；切过去（`ensureLoaded`）或发送 / Restore / 下拉之前自动挂回。认证页的 `agent_connect` 改经会话控制器，代次不漏记 | BACKLOG P0「会话身份与生命周期」第 2 条 | 同上 | | | 进行中 |
| 4 | fix | 认证完成后建出来的会话挂到旧目录：`_adoptSession` 拆成「登记」与「切成当前会话」，后者只在会话 cwd 属于当前项目时做；索引写回改传 `target` | BACKLOG P0「会话身份与生命周期」第 3 条 | 同上 | | | 进行中 |

## 收口

- 构建 / 手测：
- 发版：
- 移出项去向：
- 设计稿补注记：

## 备注

### 裁定（所有者 2026-09-23，按推荐项）

- 修法：挂载代次（BACKLOG 第 1 / 2 / 4 条共用）；第 4 条用「失败时丢弃重放」而不是快照回滚；第 3 条用「按会话自己的 cwd 登记、只有属于当前项目才切成当前会话」，不在认证期间锁住换项目。
- `session_controller.dart` 超行数门（900）时先拆出去：挂载那一段放新文件 `lib/app/session_attach.dart`。
- 挂不回（unattachable：能力已知且既没有 `loadSession` 也没有 `resume`，或 `session/list` 校对出 agent 侧已经没有）：发送照 R3 新开一条，输入框占位文案先写明。
- 挂回失败：复用画板 31 的失败轮结束行（与 2026-09-18「这一轮发出去失败」同一个出口），这条消息留在本地转录里；Regenerate 同样过这道门。

### 实现要点

- **挂载那一段是个 mixin**（`SessionAttachment`，`lib/app/session_attach.dart`）：账本（每个 agent 的连接代次、挂空集合）、关闭态（`_closedSessions` / `_closeEpoch` 从会话控制器搬过来——关掉也是「不挂在连接上」的一种）、四态查询 `attachOf`、挂回 `ensureLoaded` / `reattach`、`loadSession`。会话控制器混入它，公开 API（`c.session.attachOf` / `loadSession` / `sessionClosed` …）不变；它要的会话控制器状态与动作列成抽象成员（`ownerOf` / `cwdOf` / `capsOf` / `ensureConnected` / `onConnectError` 等，原先的私有方法改成 `@protected` 覆写）。`session_controller.dart` 1006 → 850 行。`scripts/validate.ps1` 依赖方向门给它登记了三条边（会话控制器自己那几条的子集），一轮对话多一条 → `session_attach.dart`（只用四态枚举）。
- **缺省是挂着的**：只有 `agent_connect`（`_connect`，含认证页那条——原先认证页直接调桥，改成经会话控制器的 `connectAgent`）、载入 / 恢复开始、挂回失败留下的转录会把会话标成挂空；`session/new` 与载入 / 恢复成功摘掉标记，且只认发起时那一代。测试与 fixtures 直接建的 store、`session/update` 顺带建的 store 都按挂着算，既有 277 项接线测试一条没改。进程已 `exited` 还没重连的也不算挂着。
- **发送**：`TurnController.send` 先查四态。挂空时 `reattach`（等待期同新建会话，画板 05 B 组），期间用户在侧栏点走了就不发、输入框原样留着（等待期里侧栏仍可点，不守这一下消息会改投别的会话）；挂回失败走 `_failDetached`，用户消息 + 原因落进转录的失败轮（`detachedStore` 在内存里没有转录时建一份、仍标挂空，下次载入成功被整段重放换掉）。Restore / Regenerate / 两个下拉走 `_ensureAttached`：挂不回什么都不动；挂回时整段重放过的，点的那条气泡已经不在转录里，Restore 就此作罢（气泡的本地 id 重放后会被重新编号，不能拿旧 id 去截断）。
- **载入**：同一条正在载入时，切过去 / 发送都等那一次（`_loadsInFlight` 从集合改成「id → 那一次的 Future」），不另发、也不会让发送先落进转录再被随后的重放清掉。失败时第一个闭包从「清空」换成 `Sessions.discardUpdates`，队尾补 `acceptUpdates`（原先没有转录的顺带 `forget`）。
- **认证期间换项目**：`_adoptSession` 返回 store、`createSession` / `adoptAuthSession` 都按 `target` 写索引；只在 `workspace.inCurrentWorkspace(cwd)` 时改 `agentId` / `sessionId` / `sessionEpoch` 并切回工作台。同一项目里认证期间点开了另一条会话、认证成功后被新会话顶掉的那一半没做（要在三个认证入口都带上发起时的选中态记号，属机制类），记 BACKLOG P1「壳与交互」。

### 测试

- 新增 `test/app/session_attach_test.dart` 16 项：载入中途失败两项（有 / 没有原转录）、发送分流七项（载不回、能力未知、挂不回、连上才知道挂不回、缺 Node、载入在途时发送、挂回期间点走）、重载 / 崩溃五项（重载后切另一条、崩溃后当前会话、只有 resume 的 agent、认证页连接也记一代、Regenerate 与下拉先挂回）、认证期间换项目两项（agent 型 / terminal 型）。
- **反向核对**：逐一把修法退回去（重放失败照样清空、挂空当成「没会话」、连接不记代次、认证后一律切成当前会话、认证页直连桥、Restore / 下拉不过门、发送不守「挂回期间点走」），每一处都至少让一项变红（脚本在会话的 scratchpad，不入库）。

### 合并注意

- 开工基线是 `34e66be`；`main` 其间已前进到 `5fdcc2c`（另一条 iteration-05、BACKLOG 关了 P0「没有归属的终端缓冲」与 P1「行内 HTML」、DIVERGENCE 加了第 32 条）。合 `main` 时 `rounds/BACKLOG.md` 的档位计数与 `iterations/README.md` 的清单会冲突，按真实条数重算（`- [ ]` 逐档数）；合并时机由所有者定。
