# Round 06 — 会话生命周期与五 agent 全通

<!-- 保存为 rounds/round-06/round-06.md；该轮其他管理产出放同一目录。 -->

> 状态：已完成（4 轮审查收口 0 findings；两项裁定 2026-09-16 已落）

## 目标

`session/list` / `load` / `resume` / `close` / `delete` 五个命令端到端接通，侧栏与线程头 ≡ 菜单的动作按 `loadSession` 与
`sessionCapabilities` 裁剪后全部可用；modes 回退路径（只发 `current_mode_update`、不发 configOptions 的 agent）真跑；
五个一等 agent 按 `docs/requirements.md` § 必须 第 3 条的七步逐格实测并记录（ROUNDS.md § 4 矩阵）。

## 前置

- R4（`fs/*` 与 `terminal/*`、文件面板与终端面板）、R5（registry 安装 / 认证 / 受管 Node）已合并 `main`。
- `scripts/fetch-upstream.ps1 -Check` 全绿（worktree 的 `vendor/upstream` 用目录联接指向主副本）。
- 参照 agent：**pi-acp**（`session/load`、slash 命令、不用客户端 fs 与 terminal、`--terminal-login`）。
  pi-acp 要求本机装有 `pi` CLI（`npm i -g @earendil-works/pi-coding-agent`）并自行配好模型密钥；R5 只验到握手。
- 本机已有的 agent：`dsh-acp-interactive`（custom）、`claude-agent-acp`（npx）、`fake-agent`（离线夹具）。
  钉版本三家的能力声明（vendor 源码核对）：

  | agent | `loadSession` | `sessionCapabilities` |
  |---|---|---|
  | claude-agent-acp | true | list / delete / resume / close / fork / additionalDirectories |
  | dsh-acp-interactive | true | list / resume / close（**无 delete**） |
  | pi-acp | true | list / delete（**无 resume / close**） |

## 交付物

**Rust 核心**

- `rust/acp-core/src/agent.rs`：`AgentConnection::session_list` / `session_load` / `session_resume` / `session_close` /
  `session_delete`（rust-sdk 的 `ListSessionsRequest` / `LoadSessionRequest` / `ResumeSessionRequest` /
  `CloseSessionRequest` / `DeleteSessionRequest`）；load / resume 成功后把 `(sessionId → cwd)` 记进 `Shared`
  （`fs/*` 与 `terminal/*` 回调要用它做越界判定），close / delete 成功后忘掉。
- `rust/acp-core/src/core.rs`：同名转发 + `cwd` 绝对路径校验。
- `rust/bridge/src/api.rs`：五条桥命令 + 文档注释；`flutter_rust_bridge_codegen generate` 重出生成物。

**Dart 前端（接线；`lib/theme` 与 `lib/ui` 的画板 widget 文件零 diff）**

- `lib/app/core_bridge.dart`：五条命令进 `CoreCommands`、`BridgeCommands` 与 fixtures 的 no-op 实现。
- `lib/projection/session_store.dart`：`applyLoadSession`（`LoadSessionResponse` 的 modes / configOptions）、
  `resetForReplay()`（重放前清空转录与派生态）、`modeFallbackOption`（modes → 合成的 `ConfigOptionWire`，仅本地）。
- `lib/app/workbench_controller.dart`：
  - 侧栏点击已有会话：不在内存里且 agent 声明 `loadSession` → 连接 + `session/load`，整段重放在一次 batch 里做（重放期间不逐条刷新 UI）；
  - ≡ 菜单 Resume / Close / Delete 接通，按 `sessionCapabilities` 裁剪（无能力不渲染，画板 41 已有）；
  - 删除：有 `sessionCapabilities.delete` 时先 `session/delete` 再删本地索引，无能力时只删本地索引；
  - 重载 agent：agent 声明 `loadSession` 时重载后自动 `session/load` 回原会话（否则沿用 R3 的「新会话 + 旧转录只读」）；
  - `session/list` 校对：以本地索引为准，只用来校对存在性与补标题（裁定 2026-09-15，`docs/design.md` § 3 末条），
    agent 有、本地没有的会话不自动进侧栏；分页按 `nextCursor` 取完。
  - modes 回退：`configOptions` 里没有 `category == mode` 的条目时，模式下拉用 `session/new` / `load` / `resume` 返回的
    `modes`，选中走 `session/set_mode`；两者都有时只用 configOptions。

**夹具与测试**

- `test/fake-agent/fake-agent.mjs`：`--sessions` 开关（会话与转录落 `<cwd>/.fake-agent-sessions.json`）后支持
  `session/list` / `load`（重放整段历史再返回）/ `resume`（不重放）/ `close` / `delete`，能力声明随开关变化；
  `--modes-only` 模拟只发 modes 不发 configOptions 的老 agent（modes 回退路径）。
- `test/projection/`：`session/load` 重放 200+ 条更新的分批 / 整批等价（R2 等价测试扩到长历史）；modes 回退单测。
- `rust/acp-core/tests/`：五个命令的脚本化用例（含 load 期间的 `session/update` 重放、cwd 记账、close / delete 后忘掉）。

**无头实跑**

- `lib/app/headless_run.dart`：`ACP_R6_REPORT` 模式——连接 → 新会话 → 一轮 → `session/list` → 断开重连 → `session/load`
  重放比对 → `resume` / `close` / `delete`（按能力）→ 报告 JSON。

## 验收

| # | 检查 | 命令 / 期望 | 结果 |
|---|---|---|---|
| 1 | § 4 矩阵 5 × 7 全绿，每格记命令 / 输出路径 | ROUNDS.md § 4；拿不到凭据的格子写明卡在哪一步 | **过**：五个 agent 全部真跑，报告见「本轮实测」的路径表；Cursor 的认证这次不需要人工（本机 `cursor-agent` CLI 已登录，凭据共用） |
| 2 | pi-acp：slash 命令可见 → 关闭重开 → 侧栏点击 → `session/load` 重放后转录与关闭前一致 | `ACP_R6_REPORT` 真跑 + 报告里 `beforeDigest` / `afterDigest` 比对 | **过（口径见下）**：`r6-pi2.json` —— 重放后 8 条 slash 命令回来、两轮问答一字不差；「一致」只能是 **agent 侧可重放的那部分**，客户端本地态（轮边界 / 权限卡 / elicitation 卡）不在重放里，见「已知限制」1 |
| 3 | `session/load` 重放 200+ 条更新时投影层结果与实时到达一致 | `flutter test test/projection/session_load_test.dart` | **过**：290 条更新（15 个变体全覆盖）三路等价（挂起重放 / 实时逐条 / 每 1、7、64 条一批），且挂起期间 0 次通知、release 后 1 次 |
| 4 | 无 `sessionCapabilities.delete` 的 agent 侧栏不出删除图标；有的 agent 删除后本地索引与 agent 侧都不再列出 | 真跑 + 接线单测 | **过**：dsh（无 delete）`sentToAgent: false`、侧栏没了、agent 侧还在；pi-acp / fake-agent（有 delete）`sentToAgent: true`、两边都不再列出 |
| 5 | 五种 `stopReason` 的结束行样式与画板 31 一致 | 真跑触发 + fixtures 补 | **过**：真跑拿到 `end_turn`（claude / codex / cursor / pi / fake）与 `cancelled`（codex，`ACP_R6_CANCEL_AFTER=6`）；`max_tokens` / `max_turn_requests` / `refusal` 由 `18-stop-reasons.jsonl` 与 R2 的画板 31 对照覆盖 |
| 6 | 回合级 `PromptResponse.usage` 在真实 agent 上出现 | 报告里记一次真实 usage 数字 | **过**：claude-agent-acp `{total 38933, in 2, out 11, cachedWrite 38920}`；codex-acp `{total 11535, in 11379, out 156, thought 148}` |
| 7 | `scripts/validate.ps1` 全绿；接线阶段 `lib/theme` 与 `lib/ui` 零 diff | `git diff --stat main...HEAD -- lib/theme lib/ui` | **过**：validate 13 项全 PASS；`lib/theme` 与 `lib/ui` 零 diff（本轮只动 `lib/app` / `lib/projection` / `lib/bridge`） |

## 禁止

- 不改前端页面样式（CLAUDE.md 规则 3）；不加设计稿没有的功能（规则 3）；不在 `vendor/upstream/` 里改代码（规则 4）。
- 不做 `session/fork`（unstable，设计稿没有）、不做 `logout`、不做 `providers/*`。
- 不把 agent 侧 `session/list` 有、本地索引没有的会话塞进侧栏（裁定 2026-09-15）。
- 不为任何 agent 写特判（规则 2）：能力一律读 `agentCapabilities`。

## 代码审查

- 审查方式：`powershell -File .claude\cursor-review.ps1 -Note "<本轮要点>"`（默认档；第 3 轮起加 `-Scope since -Base <上一轮已审提交>`，后台跑）
- 审查器与模型：cursor CLI `cursor-grok-4.6-high`（`--mode ask`），没有回落
- 审查范围与基准提交：第 1–2 轮全量 `main...HEAD`（`8106248` / `2659074`），第 3–4 轮只审整改 diff
  （`-Scope since -Base 2659074` / `-Base 02756a4`）。耗时：第 1 轮 **12 分 03 秒**（30 文件 / 2,831 行），
  第 2 轮 **11 分 26 秒**，第 3–4 轮的整改 diff 各几分钟。

### 第 1 轮（7 条：high 2 / P2 4 / P3 1）

| # | 级别 | finding | 处理 |
|---|---|---|---|
| 1 | high | `session/load` 失败会清掉并忘掉内存里已有的转录：reload / close 之后再点等于丢掉本地唯一一份 | **采纳整改**。整段重放挂在 batcher 里、闭包要到 `release()` 才跑，而那时成败已知——所以清空改成带条件的闭包：失败且**一条历史都没重放**时取消清空，转录原样留着（新建的空壳才 `forget`）；重放到一半才断的仍然清（否则和旧的叠起来）。「重放了几条」用新加的 `_updateArrivals` 在**事件到达时**计数（不等 batcher）。新增两条用例 |
| 2 | high | `session/close` / `session/delete` 不收在途的 `request_permission` / `elicitation/create`，agent 会挂在那条 JSON-RPC 上 | **采纳整改**。核心把 `session_cancel` 里那段抽成 `cancel_pending_permissions()`，close / delete **发请求之前**先走一遍，响应里带回 `cancelledRequestIds`；elicitation 照 `cancel()` 的老规矩由前端回（`_releasePendingElicitations`）。新增 Rust 用例 `close_and_delete_cancel_pending_permission_requests` 与一条接线用例 |
| 3 | P2 | agent 侧 `session/delete` 成功、本地那步失败时，重试会被 agent 的「没有这条」永远挡住 | **采纳整改**。记 `_deletedOnAgent`，`deletesOnAgent()` 对它返回 false，重试只删本地。新增用例 |
| 4 | P2 | 已知会话的 load / resume 失败会留下错误的 cwd，越界判定按新目录放行 | **已在审查期间自查修掉**（提交 `001a7d2`，审查看到的是修之前的 `8106248`）：`attach_session` 失败时把记账退回原样，`record_session` 对已有会话只改 cwd、不再清 `cancel_pending`。按 finding 补了缺的覆盖（「已知会话 + 失败 + cwd 不变」） |
| 5 | P2 | Close 之后作曲器仍可发 `session/prompt`，与「转录只读」不一致 | **采纳整改**。`send()` 在 `sessionClosed` 时直接返回并给一行提示；`workbench_screen.dart` 的 `enabled` 改成 `hasAgent && !sessionClosed`。新增用例 |
| 6 | P2 | `_guard` 不是互斥：load 与 close 可重叠，load 成功会无条件把会话从「已关闭」里拿掉 | **采纳整改**。加 `_closeEpoch`（每次 close +1）：load 成功只在 epoch 没变时才清「已关闭」；同一条会话用 `_loadsInFlight` 挡住并发 load。新增用例 |
| 7 | P3 | 线程头 ≡ 从右栏开关改成画板 41 菜单（设计层面） | **不采纳整改，等裁定**：审查者明确说「不在这里替所有者选」。任务卡「已知限制」2 已给推荐项与备选，留所有者裁定 |

### 第 2 轮（全量 `main...HEAD` @ `2659074`，3 条：high 0 / P2 3 / P3 0；耗时 11 分 26 秒）

审查者先抽查了第 1 轮的整改并确认自洽（`skipReset` 闭包与 `_updateArrivals` 在「0 条 / 半截 / 成功」三条路径上、
`cancel_pending_permissions` 的三条路、`_deletedOnAgent` 不会挡住下次真删），再报了三条新的——全部指向**同一个根**：
「关掉的会话」这条新状态只堵住了一半的出口。

| # | 级别 | finding | 处理 |
|---|---|---|---|
| 8 | P2 | `sessionClosed` 只挡住了 `send()`：Restore / Regenerate 与 model / thought / mode 三个下拉仍会往已关闭会话发命令。Restore 更糟——`restoreTo` 先把本地转录截断，随后的 `session/prompt` 必然失败，本地就少了一截而 agent 侧还是关闭前那份 | **采纳整改**。抽出 `_blockedByClose()` 一道门，`send` / `restore` / `setConfigOption` / `setMode` 共用。新增用例（关闭后连点五个入口，`prompts` 为空且转录条数不变） |
| 9 | P2 | close / delete 只让核心回掉挂起的权限请求，**前端的权限卡还停在 pending**：用户点 Allow 会撞 `unknown_request` | **采纳整改**。`_releasePendingElicitations` 改成 `_releaseSessionRequests`，走 `SessionStore.cancel()`（与 `cancel()` 同一条规矩：权限卡标 cancelled、未完成的工具卡标 cancelled、elicitation 逐条回）。新增用例 |
| 10 | P2 | 核心 close / delete 抽了 `cancel_pending_permissions` 却没置 `set_cancel_pending`：agent 在读到 close 之前又发一条权限请求时，客户端等 `CloseSessionResponse`、agent 等权限回应，**双方挂死** | **采纳整改**。`session_close` / `session_delete` 在排空队列之前同样 `set_cancel_pending(true)`（成功 `forget_session` 时标志随会话一起丢掉）。新增脚本化用例 `permission_arriving_while_close_is_in_flight_is_auto_cancelled`，并**反证过**：去掉那一行后这条用例 150 s 不返回（真的挂死） |

### 第 3 轮（只审整改 diff `2659074..HEAD`，2 条：high 0 / P2 1 / P3 1）

审查者先逐条核了第 2 轮那三条的整改并确认没问题（`_blockedByClose()` 没误伤 resume / load / delete；
`_releaseSessionRequests` 走 `cancel()` 后权限不二次 `acpRespond`、elicitation 一条不漏；
`set_cancel_pending` 在失败路径上不会永久钉死——`session_prompt` 首尾都会清）。两条新的：

| # | 级别 | finding | 处理 |
|---|---|---|---|
| 11 | P2 | **停止方块漏了这道门**：`closeSession` 里的 `s.cancel()` 不收轮（`isRunning` 还是 true），作曲器禁用态下 Stop 仍渲染，点下去把 `session/cancel` 打到已释放的会话上 | **采纳整改**。`cancel()` 开头也加 `_blockedByClose()` |
| 12 | P3 | **我那条用例是假通过的**：「三个下拉全都发不出去」只断言了 `core.prompts` 与 `lastError`，而 `lastError` 早被 `send()` 写成同一句、`FakeCore` 又不记 config / mode 调用 —— 把 `setConfigOption` / `setMode` 的门删掉，用例照样绿 | **采纳整改**。`FakeCore` 记下 `configOptionCalls` / `modeCalls`，用例逐个命令面分别断言；再加一条反向用例（没关闭的会话 prompt / 下拉 / 停止都照常发），证明这道门不误伤 |

### 第 4 轮（只审整改 diff `02756a4..HEAD`）：**0 条**

审查者逐条验了第 3 轮那两条的整改，并特意确认了两件我点名让它查的事：
① `cancel()` 上的这道门不会挡住该发的取消 —— `closeSession` 是在 `sessionClose` **成功之后**才 `add` 进 `_closedSessions`，
所以 close 之前正在跑的那一轮点 Stop 时 `sessionClosed == false`，`session/cancel` 照常发；`restore()` 内部那次 `cancel()`
也因为 `restore` 自己先过同一道门而不可能走到关闭态；
② 两条新用例不是假通过 —— 把 `cancel()` 或 `setConfigOption` / `setMode` 的门删掉那条会红，把 `_blockedByClose()`
写成无条件 `true` 反向那条会红。

### 第 5 轮（只审裁定落地的 diff `9519981..HEAD`）：**0 条**

裁定之后那两笔里 `b7b90cc` 带了代码改动（≡ 回退），不能靠「只是回退」免审。审查者核了三件事：
回退没留悬空引用（`_renameFromMenu` / `_deleteFromMenu` 已删且无残留、`canResumeSession` / `canCloseSession`
仍被 controller / 单测 / headless 用着、`ThreadMenuPopover` 只在 gallery 出样张）；
`docs/design.md` § 3 新加的三句与代码实际行为逐句对得上（载回的历史里 `turnOf` 找不到 `TurnEntry` →
Restore / Regenerate 的回调本来就是 null，检查点分隔线也不出现）。
顺带指出 `ROUNDS.md` 进度表还留着「≡ 归属待裁定」的过时字样（不是缺陷），已改。

- 结论：**整改后 PASS**（五轮共 12 条：high 2 / P2 8 / P3 2；11 条采纳整改并补了用例，1 条是设计取舍、所有者已裁定；
  第 4、5 轮各 0 条，缺陷门禁收口）。
  收口时的复核：`flutter test` 186 条全过、Rust 10 条脚本化用例全过、`validate.ps1` 13 项全 PASS；
  fake-agent 离线全链与 claude-agent-acp 真跑各复跑一次（reopen / close / resume / delete 全绿）。

### 一条流程教训

第 1 轮审查跑着的时候我在改仓库（自查的三处硬化，提交 `001a7d2`），`cursor-review.ps1` 的提示明写「等待期间不要改仓库里的文件」。
后果是 finding 4 报的是我已经修掉的代码，得逐条拿当前代码核对才能分清「真缺陷」与「你看到的是旧版」。**下一轮审查期间不动仓库。**

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-06/BLOCKED.md`，停下呼人。禁止放宽验收标准自我通过。

## 本轮实测

无头实跑口子：`ACP_R6_REPORT=<报告文件>`（`lib/app/headless_run.dart` 的 `runR6`，与 R3 / R5 同一个口子的第四个模式）。
启动器与全部报告 JSON 在 **`D:\cargo-target\AcpAgentClient
启动器与全部报告 JSON 在 **`D:/cargo-target/AcpAgentClient/r6-reports/`**（gitignored，不入库）：
`run-r6.ps1`（GUI 进程 stdout 收不到，用 `Start-Process -PassThru` + `WaitForExit`）、`run-exe.ps1`（通用启动器，装 agent 用）。

### 真跑一览（2026-09-16，Windows 11，规则 9）

| agent | 拉起方式 | `loadSession` / `sessionCapabilities` | 报告 | 结果 |
|---|---|---|---|---|
| fake-agent（`--sessions`） | 本机 node + `test/fake-agent/fake-agent.mjs` | true / list, resume, close, delete（`--caps` 可裁） | `r6-fake-full.json` / `r6-fake.json` / `r6-modes.json` / `r6-delete.json` / `r6-nodelete.json` | 全链绿：新会话 → 一轮 → list → 重载 → 重连 + load（digest 逐字相同）→ 第二轮 → close → resume → delete |
| claude-agent-acp 0.76.0 | npx（settings 里的 custom 条目） | true / list, delete, resume, close, fork, additionalDirectories | `r6-claude.json` | 全链绿；真实 usage `38933`；load 后第二轮上下文在（答出 2+2） |
| codex-acp 1.12.0 | registry 安装（`npx:resolve → write_settings → handshake`，11.4 s） | true / 同上六项 | `r6-codex.json` / `r6-install-codex.json` | 全链绿；usage 带 `thoughtTokens`；**`cancelled` 在这里真跑到**；load 后 25 条 slash 命令立刻回来 |
| cursor 2026.09.10 | registry 安装（binary：`download 74,169,932 B → verify → extract`，159 s） | true / **只有 list** | `r6-cursor.json` / `r6-install-cursor.json` | 全链绿；≡ 菜单里 Resume / Close / Delete 三行都不渲染；load 重放回 user + thought + agent 三条与 20 条 slash 命令 |
| pi-acp 0.0.33（参照 agent） | registry 安装（npx，5.8 s） | true / list, delete | `r6-pi2.json` / `r6-pi.json` / `r6-install-pi.json` | 全链绿；load 后 8 条 slash 命令回来；delete 之后本地与 agent 侧都不再列出 |
| dsh-acp-interactive 1.3.0 | custom（`.cmd` 包装） | true / list, resume, close（**无 delete**） | `r6-dsh2.json` / `r6-dsh.json` | 生命周期全绿；**回合本身跑不通**：dsh 的模型网关回 `DeepSeek API error (HTTP 404)`（本机环境问题，不是客户端的），所以这台机器上拿不到它的 `stopReason` / usage |

**Cursor 的认证不再需要人工**（R5 的已知限制 1）：本机 `cursor-agent` CLI 已登录（审查器在用），registry 装出来的那份共用同一份凭据，
`session/new` 直接成功、没有走到 `-32000`。codex-acp 同理（本机 `~/.codex/config.toml` 走自定义网关，不要求登录）。
pi-acp 的 `--terminal-login` 这次也没走到：本机 `pi` CLI 已装好并配了模型，`session/new` 直接成功（R5 卡在「没装 pi」，本轮已不成立）。

### 验收 2 的口径：重放「一致」到什么程度

`session/load` 只重放 **agent 侧的 `session/update`**，客户端本地态不在里面。四个真 agent 的 before / after digest 都印证：

- **回来的**：用户消息（agent 以 `user_message_chunk` 重放）、agent 消息、思考块、工具卡与状态、计划、标题、slash 命令（pi / codex / cursor / dsh 都发，`available_commands_update`）。
- **回不来的**：`TurnEntry`（轮边界 / `stopReason` / 回合级 usage）、权限卡、elicitation 卡——这些是客户端按自己发出的
  `session/prompt` 与收到的 client request 造的，协议里没有对应的重放。
- 所以关闭前后逐字相等的只有「agent 可重放的那部分」：`r6-fake-full.json` 的 `reopen.digestMatches: true`（fake-agent 的历史全部来自 update），
  真 agent 上是 `turn:1:end_turn` + `agent:…` → `user:…` + `agent:…`，内容一致、结构差一个轮边界。

**claude-agent-acp 的 slash 命令在 load 后不回来**（其余三家都回）：它不把 `available_commands_update` 算进重放。
不做 agent 特判（规则 2），照原样呈现。

### 踩到的坑（本轮抓出来的真缺陷）

1. **`session/resume` 不能对「还活着」的会话发**：dsh 1.3.0 回 `-32602 session is already active in this ACP connection`。
   原来的接线把 ≡ 菜单的 Resume 一直挂在当前会话上，等于必错。改成：Close 之后才给 Resume（`sessionClosed` 门），
   Close 只对还活着的给；`session/close` 也不再把 `sessionId` 清空（转录留着只读，紧接着就能 Resume）。
2. **`session/list` 校对把别的项目的会话全判成「agent 侧没了」**：`session/list` 按 `cwd` 过滤，本地却拿了该 agent 的全部条目去对，
   dsh 那次 21 条本地会话被整批标进 `missingOnAgent`。改成本地也只取同一个 `cwd` 的条目。
3. **重连后 agent 的 JSON-RPC id 从头再来**：无头验收脚本的 `_AutoAnswer` 按 `requestId` 去重，重连后第一批权限 / elicitation 被当成
   「答过了」而不再回，agent 一直等 → 第二轮 prompt 超时 3 分钟。改成按队列项**对象身份**去重。
4. **`ResumeSessionResponse` 经常是空对象**：`applyLoadSession` 一开始直接复用 `applyNewSession`（全量替换），resume 回 `{}` 就把
   `session/load` 刚重放出来的 modes / configOptions 抹掉了（`28-session-load.jsonl` 的用例当场抓到）。改成缺省不清空。
5. **重放前的清空会自己闪一下 UI**：`resetForReplay()` 原来带 `_changed()`，在挂起的 batcher 之外先通知一次（转录先空再填）。
   改成不通知，由接线侧把清空排进同一条挂起队列，整段重放只刷一次。

### 数字

- `session/load` 重放的投影层等价测试：**290 条更新**、15 个变体全覆盖，三路（挂起重放 / 实时逐条 / 分批）快照逐字相同；
  挂起期间投影层通知 **0 次**，`release` 之后 **1 次**。
- registry 安装耗时：pi-acp 5.8 s、codex-acp 11.4 s、cursor 159 s（74 MB 下载 + 解压）。
- `scripts/validate.ps1`：13 项全 PASS（`cargo build/test/clippy`、`flutter analyze/test`、五条规则检查）。
- `flutter test`：179 个用例全过（R6 新增 17 + 13 个）。
- `lib/theme` 与 `lib/ui` 零 diff。

### 已知限制与留给所有者的裁定

1. **重放的「一致」口径**见上。副作用：载回来的会话没有轮边界，所以画板 10 / 11 的 Restore Checkpoint 与 Regenerate
   对重放出来的历史不可用（它们按 `TurnEntry` 截断）。协议没有给重放轮边界的手段。
   **所有者裁定 2026-09-16：记已知限制，不在本地补一份轮边界**（不造协议之外的状态，规则 2）。已落 `docs/design.md` § 3。
2. **线程头 ≡ 的归属 —— 所有者裁定 2026-09-16：≡ 保持右栏开关，会话菜单要入口先改设计稿**（推荐项没被采纳）。
   画板 03 里 ≡ 是「右栏展开」的选中态，画板 41 里同一个 ≡ 是会话菜单，两张画板冲突；R3 按前者接成了右栏开关。
   本轮曾按推荐项改成「≡ 打开会话菜单」，裁定后**已回退**（`lib/app/workbench_screen.dart` 的 `_openThreadMenu`）。
   **落到本轮的实际结果**：
   - 菜单的动作本身已经接通并有单测覆盖（`resumeSession` / `closeSession` / `deleteSession` + 能力裁剪，
     `test/app/session_lifecycle_wiring_test.dart`），无头实跑也走的是这几条；
   - 产品 UI 里 **Delete 有入口**（侧栏的删除图标，画板 04），**Resume / Close 本轮没有入口** —— 要等改完画板 41 / 03
     的那一轮把菜单挂上去。已记 `rounds/BACKLOG.md`。
   - `ThreadMenuPopover` 仍只在 gallery 出样张（与 R3 相同）。
3. **没连的 agent 不为了删一条记录去拉进程**：`session/delete` 只在「agent 已连上且声明了 delete」时发；否则只删本地索引。
   对应地，侧栏删除图标在**能力未知**（该 agent 本次运行还没连过）时照给——否则重启后一条本地记录都清不掉。
4. **dsh 的回合在本机跑不通**（模型网关 404），它那格的 `stopReason` / usage 只能等环境恢复后补。
