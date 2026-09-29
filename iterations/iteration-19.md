# Iteration 19 — 侧栏 Active 行的「挂起」：把会话交还 agent（`session/close`）后从 History 点回来

<!-- 保存为 iterations/iteration-NN.md。一个迭代一个文件、一项一行；流程正本见 iterations/README.md，不在这里复述。 -->

> 状态：进行中　起止：2026-09-29 –　基线：`main` = `1421394`

所有者指示（2026-09-29）：「增加一个挂起按钮，点击后支持将 active 的会话关闭，之后可以从 history 区通过点击重新启动。做完这个可以关闭 backlog 里那个 session close 和 resume 的记录了。走正常迭代需要经过 cursor review」。

解决的核心问题：`session/close`（让 agent 放掉这条会话占的资源、**不删**它）在 R6 就接通了协议与单测，但产品界面里一直没有入口——打开过的会话在 agent 侧一直占着，直到 agent 断开（BACKLOG P1「会话菜单的 Resume / Close 没有入口」，所有者 2026-09-23 曾裁定暂不处理）。本迭代按所有者当场指示把这一半补上：入口做成画板 45 Active 行的行内动作「挂起」，挂起即 `session/close`，会话从 Active 沉到 History，再点 History 里那一行由既有的 `selectSession` → `ensureLoaded` 挂回来。Resume 仍不做单独入口（侧栏点开一条会话本来就是 load / resume 自动选一条，用途被覆盖，见 BACKLOG 结论）。

## 工作项

<!-- 类型：fix 缺陷 / ux 交互 / tidy 工程收尾 / board 单画板（设计稿先入库）。
     状态：待开工 / 进行中 / 待审查 / 待合并 / 已合并 / 移出（写去向）。
     验证：validate 全绿 / validate -Quick / 未构建（所有者指定）。
     审查：<轮数> 轮，<条数>（high n / P2 n / P3 n）；或 未审查（所有者指定）。 -->

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | ux | 侧栏 Active 行加「挂起」行内动作：新图标 `AcpIcons.pause`、`SidebarSessionRow.onSuspend`（只在 Active 且**这条会话自己的** agent 声明了 `sessionCapabilities.close` 时出，`SessionController.canSuspendSession` / `suspendableSessionIds`）；`closeSession` 泛化到指定会话（`closeSession({String? id})`，目标 agent 按 `ownerOf` 取，≡ 菜单那条缺省路径不变）；挂起后这条会话沉到 History，点它那一行走既有的 `ensureLoaded` 挂回来；关闭态提示文案改成指侧栏 History | BACKLOG P1「会话菜单的 Resume / Close 没有入口」（所有者 2026-09-29 指示） | `claude/iter-19-session-suspend` → `<sha>` | validate 全绿 | 待审查 | 待审查 |
| 2 | tidy | 补测试 `test/ui/sidebar_suspend_test.dart`（5 条：渲染与点击、能力门、只给 Active 行、挂起 → History → 点击挂回完整往返、没声明 close 时入口不存在）；`test/app/session_lifecycle_wiring_test.dart` 的关闭态提示断言跟着文案改 | 同上 | 同上 | validate 全绿（`flutter test` 619 项） | 待审查 | 待审查 |
| 3 | tidy | BACKLOG 收尾：P1「会话菜单的 Resume / Close 没有入口」剪到 `BACKLOG-CLOSED.md`（`→ iteration-19`）、P1 计数 3 → 2、总计数 8 → 7；实现先行的偏离记 `design/DIVERGENCE.md` A-37 | 同上 | 同上 | 纯文档，随同一分支 validate | 待审查 | 待审查 |

## 收口

- 构建 / 手测：待所有者定时机。手测三项：① 对一条 Active（已连接）的会话悬浮点「挂起」，它立刻落到 HISTORY 区、转录仍在（只读），agent 侧这条会话已释放；② 在 HISTORY 里点它那一行，回到 ACTIVE 区、能继续发消息（声明 `loadSession` 的 agent 会重放历史）；③ 对没声明 `sessionCapabilities.close` 的 agent（如 pi-acp），Active 行只有改名 / 删除两个图标。
- 发版：不发（所有者定）。
- 移出项去向：—（BACKLOG 那一条在本迭代关闭；Zed 的「切走自动 close、保活 5 条」是另一件事，仍留在 `docs/research.md` § 4.1，本迭代不动）
- 设计稿补注记：挂起是画板 45 / 04 / 41 都没有的行内动作，按所有者当场指示实现先行，记 `design/DIVERGENCE.md` A-37，不补画板。

## 备注

### 为什么是「挂起」而不是把 Close 摆进会话菜单

- 画板 03（右栏展开的选中态）与画板 41（会话菜单）对会话头 ≡ 的语义冲突，所有者 2026-09-16 裁定「≡ 保持右栏开关，会话菜单要入口先改设计稿」；本迭代不再去动 ≡ 与 `SessionMenuPopover`（它至今只在 gallery 与单测里出图）。
- `session/close` 的语义正好是「先 cancel 再释放、不删记录」：本地转录留着只读、索引不动、agent 侧放掉资源。挂起之后 `attachOf(id)` 不再是 `attached`，画板 45 的分组判定（`attachedSessionIds`）当场就把它分到 History —— 前端不需要另记一个「挂起中」的状态，一个协议动作同时完成了 UI 分组的搬家。
- 挂回走的是已有的一条路：`selectSession` → `ensureLoaded` → `_attach`（声明 `loadSession` 就重放、否则 `session/resume`），iteration-17 的 History 点击升格已经把它测过；本迭代只补「挂起之后这条路仍然通」的往返用例。

### 能力门与目标 agent

- 判据是**这条会话自己的** agent（`ownerOf(id)`，索引里登记的，退当前连接），不是当前选中的会话，所以后台的 Active 会话也能挂起，规则 2 的「不按 agent 名判」照旧。
- 只给 `attachOf(id) == attached` 的行：挂起过的会话不再是 Active，图标自然消失；History 行仍旧只有改名 / 删除。
- 没声明 `sessionCapabilities.close` 的 agent（实测 pi-acp）不出这个按钮 —— 与 `canCloseSession`（≡ 菜单那条）同一口径；也不为它在客户端侧造一个「本地挂起」的假动作（那要断整条连接，会连坐这个 agent 上别的会话）。

### 实测（本机，Windows）

- `flutter test test/ui/sidebar_suspend_test.dart`：5 条全过（渲染 3 条 + 往返 2 条）。
- 未跑真实 agent 的实机手测：按钮点下去到 `session/close` 这一步在 `FakeCore` 上验（`closedSessions` 记到 `(agent, session)`），真机手测留给收口那一轮。
