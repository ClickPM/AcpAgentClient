# Round 1.4.4 — v1.4.3 之后合入 main 的代码改动的复审与整改

<!-- 与 round-1.4.1 / 1.4.3 同类：发版前的单批次复审轮，登记在 ROUNDS.md § 7 进度表。 -->

> 状态：**进行中**（2026-09-23：主会话自主审查一遍（3 条 P3，采纳 1）→ 整改 → 版本号改 1.4.4 → validate → cursor 复审）

## 目标

把 `v1.4.3..main`（`dea12b8..571b828`，35 个提交）里的**代码改动**独立审一遍、发现的缺陷修掉，再交 cursor 复审到 0 条，然后发 v1.4.4。
所有者指示（2026-09-23）：审查由**主会话**做（不委派子代理）；**文档改动不审、不改**（`*.md`、`design/`、`rounds/` 与 `iterations/` 里的登记）。
审查中途所有者报「发现严重 bug、另一会话在查」，审完先不动代码；随后排查结论「不是 bug」，照常继续。

| 批 | 提交 | 内容 | 此前审查 |
|---|---|---|---|
| A | `92edf2b` | iteration-05：终端里看得见正在组的字（xterm 的 `composingText` + layout 阶段保鲜层） | cursor 1 轮，0 条 |
| B | `2cf3fab`、`d18148d` | iteration-06：主题跟随系统（`ThemeChoice` 三档、`didChangePlatformBrightness`、Rust `THEMES` 加 `system`） | cursor 2 轮，0 条 |
| C | `c5c7d8f` | iteration-06：通用 toast（`GuardedNotifier.lastError` → `reportError` → `Toasts`；「会话正在加载中」） | cursor 2 轮，0 条 |
| D | `586fd86` | iteration-07：画板 09「等你处理」（`SessionActivity`、侧栏标记、徽标组） | cursor 3 轮，0 条 |
| E | `9c64804`、`d9ce250`、`4fe8b13`、`2d8aa30` | iteration-09：会话身份与生命周期四条（`session_attach.dart` 四态 / 挂回 / 载入失败整段作废；一轮对话按四态分流） | cursor 3 轮 + 合并前复审 1 轮，0 条 |
| F | `7e63013` | iteration-03 第 7 项：退出时回收 agent 子进程（`core_shutdown` 的 `closing` 令牌 + `connect_gate`、握手中止；关窗二次请求等同一次收尾；无头模式收尾） | cursor 1 轮，0 条 |
| G | `34e66be`、`b0a445f`、`80bef55` | 关闭 BACKLOG 条目时改的注释（`composer_state` / `session_store` / `markdown_body`） | —（只动注释） |
| H | `8e4e1c5`、`cad52e7`、`9768205`、`ca1836b`、`98f2b81`、`c996f66`、`556cdba` | 合入 main 的合并提交（一处代码冲突：`session_controller` 的 `loadingSession` 移进挂载 mixin） | 各迭代合并后 validate |

其余提交只动文档（BACKLOG 关闭、回填、DIVERGENCE），不在范围内。

## 验收

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | 主会话审查覆盖全部代码改动 | `git diff v1.4.3..main -- . ':(exclude)*.md' ':(exclude)design/**'`：45 个文件逐个读过 |
| 2 | 每条 finding 有处理结论 | 采纳整改 / 不采纳写明理由，见下表 |
| 3 | 全量校验 | `powershell -File scripts/validate.ps1` 全绿 |
| 4 | cursor 复审归零 | `.claude/cursor-review.ps1`（前两轮 `-Scope since -Base v1.4.3` 全量，第 3 轮起只审整改 diff），直到 `findings: 0` |

## 代码审查

### 第 1 遍：主会话自主审查（2026-09-23）

结论：**没有 high / P2**；3 条 P3，采纳 1 条（最小改动），2 条不整改（理由见表）。

| 批 | 级别 | finding | 处理 |
|---|---|---|---|
| C | P3 | `AppearanceController` 挂在 `AcpApp` 上、不在组合根那份 `reportError` 接线里，而且它落盘失败（`appearanceSet` 抛错、或一直读不到设置而不落盘）只 `debugPrint`、从没写过 `lastError`：界面已经变了、下次启动却回到旧值，用户不知道——正是 toast 要补的「失败没有出口」那一类 | **采纳**：两条「没存下来」的路写 `lastError`（`lib/app/appearance_prefs.dart`），`AcpApp.initState` 把 `_appearance.reportError` 接到 `_controller.toasts.error`（`lib/app/app.dart`）；`FakeCore` 加 `appearanceSetError` 钩子，`appearance_prefs_test` 补 1 条 + 扩 1 条断言，`workbench_wiring_test` 补 1 条（真 `AcpApp` 点主题按钮，toast 出现、界面照常变深色） |
| E | P3 | `Sessions.forget()` 不清 `_discarding`：载入失败时的「开始丢弃」与「停止丢弃」成对排在同一条 batcher 队列里、必然一起跑完，只在「删会话恰好插在两者之间」时才多丢几条 | **不整改**：窗口只存在于同一次 flush 之内，删会话本身也会把这条从表里拿掉 |
| F | P3 | `core_shutdown` 开始时若某条 `agent_connect` 正卡在 `previous.disconnect()` 的 3 秒宽限里，它随后仍会拉起新进程、握手时才被 `closing` 中止再杀掉；Dart 侧收尾等 8 秒 | **不整改**：进程树照样被收（`disconnect` 等到退出才返回），只是白拉一次；要提前拦截得把令牌检查塞进 `AgentConnection::connect` 的 spawn 之前，属机制类改动 |

其余核对过、判定无缺陷的要点（留作复审参考）：
- `CancelToken::cancelled` 先建 `Notified` 再看标志：与 tokio 文档一致（`Notified` 建出来就能收到 `notify_waiters`，不必先 poll）；`connect_gate` 读锁只在 `agent_connect` 里持有、写锁只在 `core_shutdown` 里取，没有递归取锁的路径；`closing.check()` 在拿到读锁之后，顺序正确。
- `_load` 的清空 / 重放 / 收尾三段严格排在同一条 batcher 队列里，`failed` 在 `finally { release() }` 之前置位，闭包跑到时成败已知；`settled` 只在收尾闭包真跑完才完成，`reloadAgent` / `reattach` 拿到的都是「转录真的换过来」之后的结果。
- `_connectOnce` / `_loadsInFlight` / `_attaching` 三处在途合并：Future 的错误都有 `await` 的一方接（`whenComplete` 链不吞错），不会出现 unhandled error。
- `TurnController.send()` 四态分流：`unattachable` + `session/new` 失败时按「挂没挂上」判、不发给旧 sessionId；`reattach` 期间切走会话时消息不改投；`_failDetached` 只在 detached 时把这一轮收进转录。
- xterm 4.0.0 的 `RenderTerminal.composingText` setter 只 `markNeedsPaint`，在 `_RenderComposingKeeper.performLayout` 里写它安全；`markNeedsLayout` 每次重建只让代理盒重跑一次空 layout（子树约束没变不重排）。
- 无头模式 `_shutdown()`：`runR3` 正常路径只调 `shutdown()` 不 `dispose()`，事后那一下不会二次 dispose；`AcpApp` 的 `_shutdown ??=` 让两次关窗请求等同一个 Future。
- `WorkbenchController` 构造里给十个对象接 `reportError`；`TranscriptFolds` / `SessionIndex` 从不写 `lastError`，不接无妨；`Toasts.dispose` 之后 `error()` 直接返回，测试锁住。

## 版本号

发 v1.4.4（所有者 2026-09-23）：`pubspec.yaml` `1.4.4+1`、`rust/Cargo.toml` `[workspace.package]` `1.4.4`、`rust/Cargo.lock` 七个本地 crate；sidecar 不跟（规则 11，仍是 zed 钉版本 1.21.0）。

## 验证

- 工作树：`D:\variFlight_work\AcpAgentClient-release`，分支 `claude/review-1.4.4`（从 `main@571b828` 开出）；`vendor/upstream` 是指向主副本的目录联接。
- `powershell -File scripts/validate.ps1`（整改 + 版本号之后）：待跑。

## cursor 复审

执行器：cursor CLI `grok-4.7-high-fast`（未回落）。

### 第 1 轮（`-Scope since -Base v1.4.3`，全量，基于 `6366d9e`）

`.claude/reviews/20260923-160252-review.out.md`：**2 条（high 2 / P2 0 / P3 0）**；任务卡里已定不整改的两条 P3，第 1 条未再报，第 2 条给出了反例（见下表第 2 行）。

| 级别 | finding | 核对 | 处理 |
|---|---|---|---|
| high | `session/new` 回了内存里已有的 sessionId 时（fake-agent 不带 `--sessions`；关掉后再新建也是这条路），`_adoptSession` 只 `applyNewSession` + 摘挂空 / 关闭标记，旧转录留在这条「新会话」上；随后 `send` 判 attached，把新 prompt 接在一段 agent 侧没有的历史后面 | 属实：`sessions.session(sid)` 对已有 id 是取回同一个 store，没有清空 | **采纳**：`_adoptSession` 里 id 已有 store 就先 `resetForReplay()` 再 `applyNewSession`（`lib/app/session_controller.dart`）；`session_attach_test` 两条「同一个 id」用例各补一句转录断言 |
| high | 关窗 8 秒超时盖不住收尾的最坏一段：`agent_connect` 卡在 `previous.disconnect()` 的双宽限（3 s + 3 s）里，随后新拉起的握手被 `closing` 中止又走一遍 `disconnect` 的双宽限，合计 12 秒；Dart 侧 `coreShutdown().timeout(8 s)` 到点放行退出，还在 taskkill 的收尾被一起杀掉，进程树收不完——这是主会话那条「不整改」P3 的反例 | 属实：`disconnect()` 是「等 3 秒 → kill → 再等 3 秒」，握手中止那条路 kill 已先发但仍要走完 `disconnect()` | **采纳**：超时改 15 秒并收成 `WorkbenchController.shutdownTimeout`（`lib/app/workbench_controller.dart`）；`workbench_wiring_test` 补一条「12 秒内不放行、超时之后放行」并断言常量 ≥ 12 秒 |

两条都采纳整改 → 按流程再发第 2 轮全量。

### 第 2 轮（`-Scope since -Base v1.4.3`，全量，基于 `625013b`）

`.claude/reviews/20260923-162620-review.out.md`：**1 条（high 1 / P2 0 / P3 0）**；第 1 轮两条未再报。

| 级别 | finding | 核对 | 处理 |
|---|---|---|---|
| high | 重载断开途中（`agent_disconnect` 等旧连接的宽限）再点当前会话：agent 已 `exited`、会话判挂空，点击走 `ensureLoaded` 先发起 `agent_connect`，重载随后合并进这一次；连接回来时点击那条先恢复、先把 `session/load` 记进 `_loadsInFlight`，重载的 `loadSession` 看到「已在载」立刻回 `false`，被当成载入失败去 `createSession`——用户被切到新会话，同 id 时还会被在途的重放把旧转录铺回去 | 属实：用例复现（不修时 `calls` 多出 `new`）。`_connectOnce` 的发起方等的是 `whenComplete` 派生的 Future、合并方等的是原始 Future，监听按注册顺序回调，发起方（点击）先恢复 | **采纳**：`loadSession` 已在载时返回 `_loadsInFlight` 里那一个 Future 而不是 `false`（`lib/app/session_attach.dart`）；`_AttachCore` 加 `disconnectGate`，`session_attach_test` 补一条「重载断开途中再点当前会话」 |

采纳整改 → 第 3 轮起只审整改 diff（`625013b..HEAD`）。
