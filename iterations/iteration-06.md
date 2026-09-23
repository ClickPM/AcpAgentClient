# Iteration 06 — 通用 toast：「会话正在加载中」与失败的前台出口

<!-- 保存为 iterations/iteration-NN.md。一个迭代一个文件、一项一行；流程正本见 iterations/README.md，不在这里复述。 -->

> 状态：进行中（2 项已合并，待构建手测收口）　起止：2026-09-23 –　基线：`main` = `34e66be`

所有者 2026-09-23 指图（会话头正下方、正文区顶部居中的一条横框）裁定：BACKLOG 的两条「等待与反馈 / 静默失败」用**一个通用的 toast 交互**收——
① 正在加载的显示「会话正在加载中，请稍后」；② 发生错误的，把后台日志转成错误信息在前台展示。
设计稿没有这一层，按所有者当场裁定实现先行，记 `design/DIVERGENCE.md` 第 33 条（规则 3，不补画板）。

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | ux | 通用 toast（`lib/ui/shell/toast.dart` 画与计时、`lib/app/toasts.dart` 状态）+ 错误出口：`GuardedNotifier.lastError` 改成 setter，写进的每一句经组合根接的 `reportError` 落成一条错误 toast（十个对象一处接线，二十几处 `lastError = …` 不动）；同一句不叠、最多 3 条、6 秒自收、悬停停表、可点 ×；壳上抄终端错误那一行删掉；headless 三处 `report['lastError']` 改读聚合值 `toasts.latest` | BACKLOG P0「失败没有出口，用户看到的是『点了没反应』」（含 2026-09-23 并入的原 P5 headless 条目）；所有者 2026-09-23 | `claude/generic-toast-interaction-e60773` → `ca1836b`（合入 main 后快进） | validate 全绿 | 1 轮（cursor），0 条 | 已合并 |
| 2 | ux | 点开旧会话的「会话正在加载中」：`SessionController._ensureLoaded` 在连 agent + `session/load`（或 `session/resume`）期间记 `_loadingSessions`，`loadingSession` 按当前会话判；同一条在载时再点不再来一遍 | BACKLOG P1「点开旧会话时没有『正在载』」；所有者 2026-09-23 | 同上 | validate 全绿 | 1 轮（cursor），0 条 | 已合并 |

## 收口

- 构建 / 手测：未做。手测项：① 侧栏点一条没载过的会话（最好是要拉进程的 agent），会话头下方出现「会话正在加载中，请稍后」，转录回来后消失；载的过程中点去别的会话提示消失、点回来又出现；② 没选项目时点会话头 `+` 选 agent、删一条 agent 侧已经没有的会话、附件挑一张超 20 MB 的图——各出一条红色提示，6 秒后自己收，鼠标停在上面不收，× 能关；③ 深色主题下同样看一遍。
- 发版：—
- 移出项去向：—
- 设计稿补注记：`design/DIVERGENCE.md` 第 33 条（壳级提示整层是实现先行）。

## 备注

### 实现取舍

- **错误从哪来**：不逐处改二十几个 `lastError = …`，而是把 mixin 里的字段换成 getter / setter，setter 在非 null 时调 `reportError`。组合根构造时给十个对象（自己 + shell / workspace / agents / auth / composer / turn / session + files / terminals）接上 `toasts.error`；单测里单独 new 的对象不接，行为与改前一样（只记不报）。写 null 不报，所以 headless 在步骤之间清 `lastError` 不会冒提示。
- **壳上那一行 `lastError = terminals.lastError ?? lastError` 删掉**：接线之后它会让同一句报两遍，而且 `terminals.lastError` 成功后不清，下次开终端成功也会把上次的错再报一遍（有回归用例）。它原本只是把终端的错抄到壳上，没有别的读者。
- **「正在加载」不存进 `Toasts`**：它是会话控制器的状态，由 `Toasts.visible(loadingSession:)` 现拼，所以切走就消失、切回来还在载就又出现，不需要谁去撤。
- **不套画板 05 B 组的等待期**：所有者这次要的是 toast；底下仍是画板 01 的新会话空态（DIVERGENCE 第 33 条写明）。
- **`_ensureLoaded` 的重入**：原先同一条还在连 agent 时再点一次，会再走一遍 `_ensureConnected`——agent 状态还不是 `initialized`，于是再发一次 `agent_connect`，把正在握手的进程断掉（resume 型的 agent 还会发两次 `session/resume`）。`_loadingSessions.add` 顺带挡掉了这一条。
- **计时放在 widget 里**：`Toasts` 只存列表，`ToastCard` 的 `State` 持有 `Timer` 并在 dispose 时取消；无头实跑与单测没有 widget，也就不会留下挂着的 Timer。
- **提示层不换正文的位置**：`ToastLayer` 无论有没有提示都是同一个 `Stack(fit: expand)`，正文固定在第 0 位，提示出没不会重建转录（滚动位置、卡片展开态不丢；有用例）。
- **行数门**：`session_controller.dart` 改前 897 行、门 900。新增压到 5 行，另把 `_ensureLoaded` 的两行文档并成一行、`visibleSessions` 的集合字面量换成等价的 `where().toList()`，落在 900。

### 验证

- `powershell -File scripts/validate.ps1`：cargo build / test / clippy / tree、`flutter analyze`（16 条 info，与基线相同，无新增）、`flutter test` 478 条全过（`toast_screen_test.dart` 的 2 条是之后补的，单独跑过全绿）；第一次跑只红在 `fetch-upstream -Check`——新 worktree 的 `vendor/upstream` 是空目录，按老办法换成指向主副本的目录联接后 `-Quick` 全绿（**VALIDATE OK**）。
- 新增用例 18 条：`test/app/toast_wiring_test.dart` 10 条（Toasts 本身 3、`lastError` → toast 5、正在加载 2）、`test/ui/toast_test.dart` 6 条（到时自收 / 悬停停表 / × / 正在载不计时 / 不重建正文 / 空白处点击落到正文）、`test/ui/toast_screen_test.dart` 2 条（真工作台里点侧栏：落点在会话头下方 12px、水平居中，载完撤掉；新建会话失败的那一句 6 秒后自收）。
- 目视：临时用例把真工作台渲成 PNG（浅色「正在加载」、浅色 / 深色「正在加载 + 三条错误」含一条折到 4 行的长错误），看过后删掉，不入库。

### 审查（1 轮，cursor CLI + `grok-4.7-high-fast`）

- 范围 `-Scope worktree`（未提交改动对 `HEAD`，新文件先 `git add -N` 让 `git diff HEAD` 看得到），17 个文件；产物 `.claude/reviews/20260923-135340-review.out.md`。结论 **0 条**。
- 任务书点名的五处审查者逐条核过、都不成立：build 期间不会 notify（赋值都在回调或 `await` 之后，build 里只读 `visible` / `loadingSession`）；dispose 之后 `Toasts` 先看 `_disposed`，`files` / `terminals` dispose 里的 `unawaited(guard(...))` 要让出一轮才回调；终端错误不再重报、`loadSession` 自己接住错误不经外层 `guard` 再报；`Stack(fit: expand)` 把 `Expanded` 的紧约束原样给第 0 位的正文；`_loadingSessions` 重入直接 return、`guard` 不外抛所以 `remove` 总会执行。
- 没有采纳整改，按流程不复审。

### 合并 main（2026-09-23，`main` = `8241316`）

- 所有者 2026-09-23 指定：两处「同时报两遍」（一轮发失败时 toast + 画板 31 结束行；需要认证 / 缺 Node 时 toast + 认证页或 Agents 标签）保持现状、不改；先把 `main` 合进本分支解冲突，再快进 `main`。
- **编号撞车**：开工时 `main` 还没有 iteration-05，合并前发现另一个会话已用掉 iteration-05（终端组字）与 DIVERGENCE 第 32 条，本迭代改为 **06**、偏离条目改为 **第 33 条**（提交前改好，免得 add/add 冲突）。
- 冲突 3 处，全是文档：`iterations/README.md` 迭代清单两行都留；`rounds/BACKLOG.md` 两边的删除都保留，「等待与反馈」小节清空整节删掉，按真实条数重算为 P0 5 / P1 3 / P2 1、合计 **9**（逐小节核对标题计数与实际条数一致）；`rounds/BACKLOG-CLOSED.md` 末尾两边都留（main 四条在前）。另外 `design/DIVERGENCE.md` 自动合并把第 33 条排到了第 32 条前面，调回顺序。
- 代码自动合并（`lib/app/headless_run.dart` 两边改的是不同段）；`main` 新进的代码里没有「把别的对象的 `lastError` 抄过来」的写法，也没碰 `lastError`。按「合 main 后没代码冲突就不复审」，validate 全绿即合入。
- 合并后全量 `validate.ps1 -CargoTargetDir D:\cargo-target\AcpAgentClient-toast`（`main` 这批带了 `rust/acp-core` 的改动，按共用 target 会串代码那条教训用独立目录）：**VALIDATE OK**，`flutter analyze` 16 条 info 与基线相同，`flutter test` 482 条全过。
