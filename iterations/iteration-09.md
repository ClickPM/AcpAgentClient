# Iteration 09 — BACKLOG P0「会话身份与生命周期」四条

<!-- 保存为 iterations/iteration-NN.md。一个迭代一个文件、一项一行；流程正本见 iterations/README.md，不在这里复述。 -->

> 状态：已合并（待构建与手测收口）　起止：2026-09-23 –　基线：`main` = `34e66be`

BACKLOG P0「会话身份与生命周期」四条一起做（下文「BACKLOG 第 N 条」按那一小节原来的顺序数）。第 1 / 2 / 4 条同根：前端没有「这条会话挂在哪条 agent 连接上」的状态，
一直拿「内存里有没有转录（`store`）」代替；本迭代补上**挂载代次**（每个 agent 的连接换过几代 + 挂空的会话集合），三条共用。第 3 条独立。
所有者 2026-09-23 按推荐项整批裁定（修法与两处用户可见行为见「备注 · 裁定」），在 worktree 分支里做。
**编号**：开工时 `main` 上最新是 iteration-04，本文起名 05；途中并行会话先后占了 05–08（终端组字、通用 toast、主题跟随系统、画板 09），合 `main` 时定为 **09**（`design/DIVERGENCE.md` 同理避开 `main` 已用的 32 / 33，取 **34**）。

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | fix | 载会话中途失败会留半份转录：失败时整段重放作废（`Sessions.discardUpdates`，在挂起的 batcher 队列里与清空成对排），原先有转录的原样留着；删掉 `_updateArrivals` / `noteUpdateArrival` 那套「重放了几条」的判断 | BACKLOG P0「会话身份与生命周期」第 4 条 | `claude/conversation-identity-lifecycle-p0-dd6bcc`（`9c64804` + 整改 `d9ce250` / `4fe8b13`）→ 合 `main` `556cdba`、整改 `2d8aa30`，`main` 快进 | validate 全绿（合并后 523 项 flutter test）；未构建、未手测 | 分支上 3 轮：3 → 1 → **0**；合并前复审 2 轮：3（high 2 / P2 1）→ **0**；high 6 条、P2 1 条全部采纳 | 已合并 |
| 2 | fix | 发消息可能把选中的会话静默顶掉：`send()` 按四态分流（none / attached / detached / unattachable），detached 先挂回（连上 → load / resume）再发，挂不回不开新会话、这一轮按「发出去失败」收在画板 31 的结束行；unattachable 按 R3 新开一条，输入框占位文案先说明 | BACKLOG P0「会话身份与生命周期」第 1 条 | 同上 | 同上 | 同上 | 已合并 |
| 3 | fix | 重载或崩溃之后，别的会话发不出去：连接每换一次，这个 agent 名下内存里的会话全部标成挂空；切过去（`ensureLoaded`）或发送 / Restore / 下拉之前自动挂回。认证页的 `agent_connect` 改经会话控制器，代次不漏记 | BACKLOG P0「会话身份与生命周期」第 2 条 | 同上 | 同上 | 同上 | 已合并 |
| 4 | fix | 认证完成后建出来的会话挂到旧目录：`_adoptSession` 拆成「登记」与「切成当前会话」，后者只在会话 cwd 属于当前项目时做；索引写回改传 `target` | BACKLOG P0「会话身份与生命周期」第 3 条 | 同上 | 同上 | 同上 | 已合并 |

## 收口

- 构建 / 手测：未构建。所有者手测项（真 agent，Windows）：
  1. **重载后切另一条**：同一个声明了 `loadSession` 的 agent 开两条会话 A、B；在 A 上点会话头「重载 agent」，再点侧栏 B 发一句 → 不撞 `unknown session`，B 先把历史载回来再回复。
  2. **崩溃后接着发**：任务管理器结束 agent 进程（或 fake-agent 带 `--crash-after`），在当前会话直接发一句 → 转录变暗转圈一会儿，随后照常回复。
  3. **载不回不顶掉**：让一条旧会话载不回（agent 侧删掉它的会话记录），点开它发一句 → 不新开会话、侧栏高亮不跳，转录里多一轮带失败原因的结束行，输入框清空。
  4. **挂不回先说明**：既没有 `loadSession` 也没有 `resume` 的 agent，重载后点回旧会话 → 输入框占位是「这条会话在当前连接上无法继续，发送会新开一条」；发送新开一条。
  5. **认证期间换项目**：未登录的 agent 在项目 A 发第一条 → 认证页 → 顶栏换到项目 B → 完成登录 → 界面停在 B（空态），切回 A 侧栏里有这条新会话。
- 发版：不发（所有者定）。
- 移出项去向：—（同一项目里认证期间切了会话仍被顶掉的那一半、`pty` 测试偶发判红，所有者 2026-09-23 裁定都不记 BACKLOG）。
- 设计稿补注记：`design/DIVERGENCE.md` 第 34 条（画板 05 B 组第三个触发、画板 31 失败态的第二个来源、画板 01 / 40 输入框一句占位文案）。

## 备注

### 裁定（所有者 2026-09-23，按推荐项）

- 修法：挂载代次（BACKLOG 第 1 / 2 / 4 条共用）；第 4 条用「失败时丢弃重放」而不是快照回滚；第 3 条用「按会话自己的 cwd 登记、只有属于当前项目才切成当前会话」，不在认证期间锁住换项目。
- `session_controller.dart` 超行数门（900）时先拆出去：挂载那一段放新文件 `lib/app/session_attach.dart`。
- 挂不回（unattachable：能力已知且既没有 `loadSession` 也没有 `resume`，或 `session/list` 校对出 agent 侧已经没有）：发送照 R3 新开一条，输入框占位文案先写明。
- 挂回失败：复用画板 31 的失败轮结束行（与 2026-09-18「这一轮发出去失败」同一个出口），这条消息留在本地转录里；Regenerate 同样过这道门。

### 实现要点

- **挂载那一段是个 mixin**（`SessionAttachment`，`lib/app/session_attach.dart`）：账本（每个 agent 的连接代次、挂空集合）、关闭态（`_closedSessions` / `_closeEpoch` 从会话控制器搬过来——关掉也是「不挂在连接上」的一种）、四态查询 `attachOf`、挂回 `ensureLoaded` / `reattach`、`loadSession`。会话控制器混入它，公开 API（`c.session.attachOf` / `loadSession` / `sessionClosed` …）不变；它要的会话控制器状态与动作列成抽象成员（`ownerOf` / `cwdOf` / `capsOf` / `ensureConnected` / `onConnectError` 等，原先的私有方法改成 `@protected` 覆写）。`session_controller.dart` 1006 → 850 行（整改后 864）。`scripts/validate.ps1` 依赖方向门给它登记了三条边（会话控制器自己那几条的子集），一轮对话多一条 → `session_attach.dart`（只用四态枚举）。
- **缺省是挂着的**：只有 `agent_connect`（`_connect`，含认证页那条——原先认证页直接调桥，改成经会话控制器的 `connectAgent`）、载入 / 恢复开始、挂回失败留下的转录会把会话标成挂空；`session/new` 与载入 / 恢复成功摘掉标记，且只认发起时那一代。测试与 fixtures 直接建的 store、`session/update` 顺带建的 store 都按挂着算，既有 277 项接线 / 投影测试的断言一条没改。进程已 `exited` 还没重连的也不算挂着。
- **发送**：`TurnController.send` 先查四态。挂空时 `reattach`（等待期同新建会话，画板 05 B 组），期间用户在侧栏点走了就不发、输入框原样留着（等待期里侧栏仍可点，不守这一下消息会改投别的会话）；挂回失败走 `_failDetached`，用户消息 + 原因落进转录的失败轮（`detachedStore` 在内存里没有转录时建一份、仍标挂空，下次载入成功被整段重放换掉）。Restore / Regenerate / 两个下拉走 `_ensureAttached`：挂不回什么都不动；挂回时整段重放过的，点的那条气泡已经不在转录里，Restore 就此作罢（气泡的本地 id 重放后会被重新编号，不能拿旧 id 去截断）。
- **载入**：同一条正在载入时，切过去 / 发送都等那一次（`_loadsInFlight` 从集合改成「id → 那一次的 Future」），不另发、也不会让发送先落进转录再被随后的重放清掉。失败时第一个闭包从「清空」换成 `Sessions.discardUpdates`，队尾补 `acceptUpdates`（原先没有转录的顺带 `forget`）。
- **认证期间换项目**：`_adoptSession` 返回 store、`createSession` / `adoptAuthSession` 都按 `target` 写索引；只在 `workspace.inCurrentWorkspace(cwd)` 时改 `agentId` / `sessionId` / `sessionEpoch` 并切回工作台。同一项目里认证期间点开了另一条会话、认证成功后被新会话顶掉的那一半没做（要在三个认证入口都带上发起时的选中态记号，属机制类）；所有者 2026-09-23 裁定不记 BACKLOG。

### 测试

- 新增 `test/app/session_attach_test.dart` 23 项（第 1 / 2 轮审查整改补 3 + 1 项、合并前复审补 3 项，见下）：载入中途失败两项（有 / 没有原转录）、发送分流十一项（载不回、能力未知、挂不回、连上才知道挂不回、缺 Node、载入在途时发送、挂回期间点走；整改补的：连接拉起中就发送、另一条还在载时这条不提前报成功、挂不回且新开失败、挂不回且新开回了同一个 id）、重载 / 崩溃五项（重载后切另一条、崩溃后当前会话、只有 resume 的 agent、认证页连接也记一代、Regenerate 与下拉先挂回）、认证期间换项目两项（agent 型 / terminal 型）。
- **反向核对**：逐一把修法退回去（重放失败照样清空、挂空当成「没会话」、连接不记代次、认证后一律切成当前会话、认证页直连桥、Restore / 下拉不过门、发送不守「挂回期间点走」），每一处都至少让一项变红（脚本在会话的 scratchpad，不入库）。

### 代码审查

- **第 1 轮**（cursor CLI `grok-4.7-high-fast`，`-Scope since -Base 34e66be`，审 `9c64804`，约 10 分钟）：3 条，**high 3**，全部采纳整改：
  1. 同一次挂回在 `ensureConnected` 的等待窗口里会连打两次 `agent_connect`（点开没连上的旧会话、紧接着发送；核心的 `agent_connect` 先断开已有连接，后到的发送把消息写成失败轮、随后被先开始的那次载入清掉）→ 会话控制器按 agent 合并在途的连接（`_connectOnce`，认证页的 `connectAgent` 同走它）；`ensureLoaded` 连上之后再查一次在途载入，等那一次。
  2. `session/load` 在 batcher 还被另一次载入挂着时就报成功（`_attached` 在队列之外、`finally` 才 release）→ 摘挂空标记与转录换过来放进同一个排队闭包，`loadSession` 的 Future 等排队的清空 / 重放 / 收尾真的跑完才完成（`Completer`）；失败路径的 `forget` 同样在完成之前生效。
  3. 挂不回、内存里有转录、`newSession` 又失败时仍会往旧 sessionId 发 `session/prompt` 并盖掉原因 → `send` 在 `newSession` 之后 `sessionId` 还是原来那条就返回。
  - 三项各补一条用例，逐一把整改退回去时各自变红。
  - 残留（不采纳，记在这里）：`loadSession` 的 Future 靠排队闭包完成，排在它前面的闭包要是抛错，`UpdateBatcher.flush` 按既有语义丢掉队列里余下的闭包，等它的调用方会一直等下去。闭包都是投影层的应用函数（未知变体只丢不抛），与改前「抛错后 UI 不再刷新这一批」是同一类既有风险，不为它改 batcher 的错误语义。
- **第 2 轮**（同一执行器，`-Scope since -Base 9c64804`，审 `d9ce250`，约 10 分钟）：1 条，**high 1**，采纳：第 1 轮第 3 条的整改把「`sessionId` 还是原来那条」当成「新会话没开出来」，而 `session/new` 可以回同一个 id（fake-agent 不带 `--sessions` 时总是这样），那时会话其实已经挂上、发送却被丢掉 → 改成 id 没变**且**这条仍没挂上才返回（只改判断）。补一条用例，退回旧判断时变红。审查者另外核对了 `_connectOnce` 与 `Completer` 两处整改，没有新缺陷；残留那条未再计。
- validate：整改后第一次全量跑在 `cargo test` 的 `pty::spawn_streams_output_and_reports_exit` 红了一次（本分支没有 Rust 改动；`wait` 返回时退出回调还没记上），第 2 轮整改后又红一次——全量 validate 6 次里 2 次，单跑、`--test-threads=1`、`--no-fail-fast` 全 workspace 都过，只在同 crate 并行且机器负载高（当时好几个副本在编）时出现。所有者 2026-09-23 裁定不记 BACKLOG；每次重跑 validate 全绿（最后一次 482 项 flutter test）。

- **第 3 轮**（同一执行器，`-Scope since -Base d9ce250`，审 `4fe8b13`）：**0 条**。审查者对照 `attachOf` / `attachedNew` 与 `_newSession` / `createSession` / `_adoptSession` 核过两条路径（同 id 成功照发、失败仍返回），也确认退回旧判断时新用例会红。**0 high 收口。**

- **合并前复审**（所有者 2026-09-23 指示合入 `main`；先把 `main` `c907a13` 合进分支 `556cdba`，合并时手改了代码——把 iteration-06 的「会话正在加载中」移进挂载 mixin、`_ensureAttached` 不再重复报错——所以按 `-Scope since -Base main` 审将要落进 `main` 的全部改动）：3 条，**high 2 / P2 1**，全部采纳，都只改判断：
  1. high：会话还在加载时点「重载 agent」会再打一次 `agent_connect`（断掉正在握手的那条），又把「已在载」的立即 `false` 当成载入失败而新开一条 → 有会话在挂回 / 载入（`attachInFlight`）或正在连 agent（`_connecting`）时重载不动手；重载自己的连接也改走 `_connectOnce`。
  2. high：关掉当前会话后新建、`session/new` 回同一个 id 时关闭标记还在，新会话一开出来就是只读 → `attachedNew` 连关闭标记一起清。
  3. P2：`reattach` 一开头清空 `lastError`，等侧栏那次挂回时会把它写好的原因（认证页正在打开）换成笼统的一句 → 只在自己发起挂回时清空。
  - 三项各补一条用例，逐一退回整改时各自变红。
- **合并前复审第 2 轮**（`-Scope since -Base 556cdba`，审 `2d8aa30`）：**0 条**，三处整改都落在原问题上。所有者指示合入，`main` 从 `c907a13` 快进到 `2d8aa30`（其间 `main` 没有新提交）。

### 合并注意

- 开工基线是 `34e66be`；`main` 其间已前进到 `5fdcc2c`（另一条 iteration-05、BACKLOG 关了 P0「没有归属的终端缓冲」与 P1「行内 HTML」、DIVERGENCE 加了第 32 条）。合 `main` 时 `rounds/BACKLOG.md` 的档位计数与 `iterations/README.md` 的清单会冲突，按真实条数重算（`- [ ]` 逐档数）；合并时机由所有者定。
