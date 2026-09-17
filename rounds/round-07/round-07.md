# Round 07 — zed-agent-acp sidecar

> 状态：已完成（审查 4 轮收口；合并 `main` 待所有者确认）

## 目标

把 Zed 内置 agent（`crates/agent` 的 `NativeAgent`）以**独立进程**的 ACP agent 接进来，主程序侧和其他五个 agent 走完全相同的路；主进程依旧无 gpui（CLAUDE.md 规则 5）。

## 前置

- R1（Rust 核心主线）、R3（工作台与接线）已完成；建议在 R6 之后（本轮即是）。
- `scripts/fetch-upstream.ps1 -Check` 全绿 —— 2026-09-16 实测 8 项全 OK（worktree 的 `vendor/upstream` 用 `mklink /J` 指向主副本）。
- 构建前置：VS 2022 BuildTools（含 CMake，`wasmtime` 的 build.rs 要它）、Rust 1.98.1。

## 交付物

**sidecar（独立 cargo workspace）`sidecar/zed-agent-acp/`**

| 文件 | 说明 |
|---|---|
| `Cargo.toml` | 独立 workspace；path 依赖 `vendor/upstream/zed/crates/*`；`agent-client-protocol` 用 crates.io `=2.0.0`（与 zed 钉版本一致，规则 10）；抄了 zed 根 manifest 的 `[patch.crates-io]` 与 `[profile]` 要点 |
| `Cargo.lock` | 以 `vendor/upstream/zed/Cargo.lock` 为种子（见「本轮实测」第 3 条） |
| `.cargo/config.toml` | Derived from zed `.cargo/config.toml` @ d9e1c02（`windows_slim_errors` + `+crt-static`） |
| `build.rs` | Derived from zed `crates/eval_cli/build.rs` @ d9e1c02（`ZED_PKG_VERSION`） |
| `src/headless.rs` | **复制** from zed `crates/eval_cli/src/headless.rs` @ d9e1c02（四处改动在文件头列明） |
| `src/main.rs` | 入口：`--acp`（默认）/ `--selftest` / `--version` / `--help`；路径开关 `--user-data-dir` / `--zed-settings` |
| `src/meta_keys.rs` | sidecar 侧 `_meta` 键的唯一出处（`validate.ps1` 对它与 `rust/` 那份用同一条规则核对） |
| `src/bridge.rs` | stdio ACP 传输 + 「tokio 世界 ↔ gpui 世界」的两条单向通道 |
| `src/session.rs` | 能力声明、会话表、生命周期五命令、一轮 prompt 的事件流、权限与 elicitation 反向请求、模型 config option |
| `src/translate.rs` | `ThreadEvent` → `session/update`；终端输出经 `_meta.terminal_*` 三键 |

**主程序**

| 文件 | 说明 |
|---|---|
| `rust/acp-core/src/builtin.rs` | 新增：按可执行文件相对路径定位 sidecar，合成一条**不落盘**的 `custom` 型 `agent_servers` 条目；缺失时静默不列出 |
| `rust/acp-core/src/lib.rs` / `core.rs` / `registry_ops.rs` | 把内置条目并进 `agent_settings_get` / `registry_list` / `agent_connect`；`agent_settings_remove` 拒绝删内置条目 |
| `lib/projection/registry.dart` | `RegistryEntryData.builtin` |
| `lib/ui/settings/settings_page.dart`、`lib/ui/registry/registry_entry.dart` | 内置条目的 Remove 按钮置灰（只改判断，不改布局，见「偏离」） |
| `lib/app/workbench_controller.dart` | agent 显示名优先取条目里的 `name`（内置条目显示 "Zed Agent"） |
| `windows/CMakeLists.txt` | install 规则：把 `build/sidecar/zed-agent-acp.exe` 装到应用目录旁（install 时判断存在性，缺了不报错） |
| `scripts/build-sidecar.ps1` | 新增：sidecar 的构建脚本（cmake 路径、独立 target dir、切目录读 `.cargo/config.toml`、产物落 `build/sidecar/`；`-Check` / `-Clippy` / `-Selftest`） |
| `scripts/validate.ps1` | 规则 2 / 6 的两项扫描扩到 `sidecar/`（两份 `meta_keys.rs` 用同一条规则核对） |
| `docs/design.md` § 8 | 按 R7 实测重写：映射细则、终端走 `_meta` 三键、`threads.db` 的「配置共用、数据隔离」裁定 |
| `rounds/BACKLOG.md` | `threads.db` 争用条目关闭；新增 6 条 R7 已知限制 |

## 验收

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | sidecar 冷编译在本机通过，时长与磁盘占用记任务卡 | `powershell -File scripts\build-sidecar.ps1`；`--selftest` 退出码 0 |
| 2 | 主进程仍无 gpui | `cargo tree -p acp_bridge \| Select-String gpui` 无输出 |
| 3 | `acp-smoke --agent zed` 一轮含工具调用与权限 | 报告 JSON 记路径 |
| 4 | Flutter 里：新会话 → 对话 → 终端卡 → 取消 → 关闭重开后 `session/load` | 无头口子 + 截图 |
| 5 | 与运行中的 Zed 同时开 `threads.db` 的行为（读 / 写 / 锁），据此裁定共用 / 隔离并写回 `docs/design.md` § 8 | 实测记录 |
| 6 | 主程序无 sidecar 时功能不受影响 | 移走 exe → agent 列表里没有 Zed Agent，其余照常 |
| 7 | `scripts/validate.ps1` 全绿 | — |

## 禁止

- 不改前端页面样式（规则 3）；不加设计稿没有的功能（规则 3）；不在 `vendor/upstream/` 里改代码（规则 4）。
- 不把 gpui 带进 `rust/`（规则 5）。
- 不回写用户的 Zed `settings.json` / `threads.db` 之外的任何东西（规则 7）；模型选择只改内存里的线程，不落 Zed 的设置文件。

## 代码审查

- 审查方式：`powershell -File .claude\cursor-review.ps1`（默认档，后台跑）
- 审查器与模型：cursor CLI `cursor-agent` + `cursor-grok-4.6-high`
- 审查范围与基准提交：**第 1 轮**全量 `main...HEAD`（基准 `0a2def9`，被审提交 `d689971` + `74d1e4b`），结果 `.claude/reviews/20260917-111758-review.out.md`

### 第 1 轮 findings：3 条（high 1 / P2 2），**全部采纳整改**

1. **[high] `session/close` / `session/delete` 既不 cancel 也放不掉在途的 prompt** —— 采纳。
   事实核对成立：`pump` 自己按着一条 `Rc<SessionEntry>`，从会话表里 `remove` 之后那一轮照跑（终端还在执行、文件还在改），而随后的 `session/cancel` 已经查不到这条会话、直接返回；客户端按规范只发 `session/close` 不另发 cancel（`workbench_controller.dart` 的 `closeSession` 注释写的就是「`session/close` = 先 cancel 再释放」）。
   整改：新增 `close_session` / `cancel_and_wait`，close 与 delete 都先**等**取消完成再摘会话。
2. **[P2] `UpdateTerminal` 分支不走 `pumped_terminals` 去重** —— 采纳。两条路径都收进新的 `start_terminal_pump`，去重与起泵是同一处判断。
3. **[P2] 内置条目仍可「编辑」并 `agent_settings_set` 落盘** —— 采纳。设置页对 `builtin` 条目把「编辑」与 Remove 一起置灰；核心 `agent_settings_set` 在磁盘上还没有用户同名条目时拒绝写内置 id（用户自己手写过的条目照常可编辑）。补了 Dart 单测。

### 整改带出来的一个回归（自查复跑发现，已修）

整改 1 加的 `cancel` 会触发 Zed 的 `cx.notify()` → `save_thread`，而 `release_session` 在放掉会话时本来就**必定再存一次**。两次异步保存赶在 `delete_thread` 之后落盘，就把刚删掉的线程原样写回 `threads.db` —— 复跑实测 `delete` 的 `inAgentList` 从 `false` 变成了 `true`（会话又冒出来了）。
整改：`delete_session` 改成「删 → 核对 → 必要时重删」（上限 3 次、间隔 200 ms，以 `ThreadStore` 自己的 reload 作屏障），三次之后仍在就**如实报错**而不是假装删成功。复跑 `inAgentList: false`。

### 第 2 轮（仍为全量 `main...HEAD`，被审提交 `925282e`）findings：2 条（high 1 / P2 1），**全部采纳整改**

结果 `.claude/reviews/20260917-114859-review.out.md`。审查者确认第 1 轮的四处整改都成立，另抓出两条：

1. **[high] `session/delete` 在 `still_there == false` 时立刻回成功，释放后那次异步保存仍能把线程写回 `threads.db`** —— 采纳，指得准。
   我第 1 轮的重删循环只在「保存比删除**快**」时才起作用；保存**慢**的那条路上，attempt 0 立刻核对只看到「已经没了」的假象，直接回成功，几十到几百毫秒后它又出现在 `session/list` 里 —— 任务卡里紧接着查 `inAgentList: false` 也照样看不出来（我上一轮正是这么「验证」的）。
   整改两处：① 新增 `release_and_wait`：摘表**之前**先挂 `observe_release`，摘完等这条会话的 `AcpThread` 真被释放（`prompt` 的事件泵也按着一份 `Rc`，摘表 ≠ 释放），上限 5 s；② 删除循环改成每轮「删 → 等 200 ms → 重读 → 核对」，**不再有立刻返回的成功路径**。
2. **[P2] 内置条目「编辑置灰」的单测是恒真的** —— 采纳，说得对：`_settingsRowEnabled(e) => !e.builtin` 等于什么都没测，把 widget 里的判断改回去照样绿。
   整改：删掉那个 helper；新增 `test/ui/settings_builtin_test.dart`（建**真的 `SettingsPage`**、点真的按钮，断言内置行两个按钮都没有回调），核心那道拒写抽成纯函数 `builtin::rejects_settings_write` 并补真值表单测。
   **反向验证**：把 `settings_page.dart` 里的 `|| a.builtin` 去掉，新用例立刻变红（退出码 1）；改回来再变绿 —— 这条门是真的。

**delete 的最终验证**（不再只看删完那一刻）：整改后复跑整条生命周期 `ok: true`、`delete.inAgentList: false`；随后**另起一个进程**、只做 `session/list`，确认被删的 `c461932a-…` 不在列表里（列表里只剩两条更早的测试会话）。

### 第 3 轮（只审整改 diff，`-Scope since -Base 925282e`）findings：1 条（high 1），**采纳整改**

第一次发起时 cursor 掉线卡死（`.err.log`：`Connection lost, reconnecting to …cursor.sh (attempt 1)` / `Retry attempt 1...`），工作进程没了而 `.out` 空了 58 分钟。按 `docs/review-workflow.md` 这算硬失败，但**没有回落子代理** —— 掉线是瞬时故障，重发同一轮 cursor 即可；重发（`20260917-130621`）10 分钟内正常出结果。结果 `.claude/reviews/20260917-130621-review.out.md`。

1. **[high] `release_and_wait` 根本没等到释放** —— 采纳，审查者对着 gpui 源码查实的，指得比我自己准。
   `observe_release` 只在 `App::flush_effects` → `release_dropped_entities` 里跑，`Entity` 的 drop 本身只是把 id 推进待释放队列；而 flush 发生在一次 `App::update` 结束时。我把 `drop(entry)` / `sessions.remove` 写在 `cx.update` **之外**，于是那次 drop 什么也没触发：空闲会话一路空等到 5 s 超时，随后 `delete_thread` 自己那次 update 才第一次 flush —— 「释放时的保存」又和删除挤进同一轮 effect，退回第 2 轮那条 high 的慢保存路径。
   整改：把挂订阅、`drop(entry)`、摘表全放进**同一个** `cx.update`（闭包返回订阅句柄），让这次 update 收尾的 flush 直接跑完 `release_session`；`prompt` 的事件泵还按着 `Rc` 的情况，等待期间每 50 ms 空跑一次 `cx.update` 把 effect 冲一遍，而不是只挂 background timer。

### 复跑时自己抓到的一个缺陷（`session/list` 会把「读失败」报成「一条都没有」）

整改后复跑，`session/delete` 不再有 5 s 空等（应用日志里 `was not released` / `came back after delete` 都是 0 条），被删的会话另起进程查 3/3 都不在了。但**另一次** `session/list` 返回了空表，而库里那两条老会话还在 —— 连查 5 次只中了 1 次。

查到根因在上游：`ThreadStore::spawn_reload` 连库或读表失败时是**静默 return**（`let Ok(..) else { return }`），任务照常完成、`threads` 保持原样，对刚建好的 store 就是空的。于是「读失败」和「真的没有会话」在外面长得一模一样，而客户端拿 `session/list` 校对存在性（R6）。

整改（在我们这侧，不动 `vendor/`）：`list_sessions` 每次**强制重扫**再读（原来 await 的是可能早就跑完的 `reload_task`，读的是缓存），空表时再重扫一次把偶发读失败滤掉。复跑连查 5 次，5/5 都是 2 条。上游吞错误这件事记 BACKLOG。

### 第 4 轮（只审整改 diff，`-Scope since -Base be03008`）findings：**0 条**

结果 `.claude/reviews/20260917-133121-review.out.md`。审查者对着 gpui 的 `flush_effects` / `observe_release` / `Entity` drop 只入队、以及上游 `ThreadStore::spawn_reload` 的静默失败逐条核对了两处整改，确认：

- `release_and_wait`：三件事收在同一次 `cx.update` 里，`let _subscription` 保住了订阅（不是 `let _ =`，不会立刻退订）；`NativeAgent` 先登记的 listener 先 `enqueue_save`、我们的 oneshot 后发，空闲会话不再空等 5 s；泵还持有 `Rc` 时只有空跑 `cx.update` 才冲得掉，光挂 background timer 确实等不到；`try_recv` 的 `Err(Canceled)` 只在 sender 已丢且没送到时出现。
- `list_sessions` / `reload_threads`：不再 await 可能早已完成的那份 Shared 任务；「空表再扫一次」与上游静默失败的形状匹配，真空表只多一次读，**已有缓存时的失败不会被误判成空表**（失败路径不清表），也没有把「读失败」装成新的成功路径。

规则 1–10、ACP 协议面、`unsafe`、密钥、用户数据破坏性写：本 diff 未触及。

- 结论：**整改后 PASS**（4 轮 / cursor CLI；6 条 findings —— high 3 / P2 3 —— 全部采纳整改，第 4 轮 0 条收口，缺陷门禁关闭）


## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-07/BLOCKED.md`，停下呼人。

## 偏离

1. **`languages` crate 没进 sidecar 的依赖**（eval_cli 有）。原因是构建环境：它唯一地依赖 `pet`，`pet` 打开 `msvc_spectre_libs` 的 `error` 特性，本机 VS 2022 BuildTools 没装「Spectre 缓解库」组件，build.rs 直接 panic。代价：`LanguageRegistry` 为空，靠语法树的工具（`read_file` 的 outline 模式、跳转类工具）退化成纯文本；编辑、终端、grep、权限不受影响。装上那个 VS 组件后取消 `Cargo.toml` 里那一行的注释即可恢复。记 BACKLOG。
2. **不走 `NativeAgentConnection::prompt`，直接消费 `Thread::send` 的 `ThreadEvent` 流**。理由与两个已知取舍见 `src/session.rs` 文件头。
3. **两个 widget 文件各改了一行判断**（Remove 按钮在内置条目上置灰）。规则 3 的零 diff 口径是针对「接线轮」的；本轮画板 70 / 51 的「可见、不可删」没有别的落点，改动限于 `onTap` 的判断，不涉布局 / widget 树 / token。
4. **`ACP_ZED_SIDECAR` 环境变量**（`rust/acp-core/src/builtin.rs`）是开发用的路径覆盖：开发时 sidecar 在 `CARGO_TARGET_DIR` 里、不在应用目录旁，`acp-smoke` 与无头实跑都靠它。它只换「拉起哪个可执行文件」，能设这个变量的人本来就能改 `settings.json` 里的 `agent_servers`，不额外开面；发行版里不设它，走「应用可执行文件旁边」那条。

## 本轮实测

> 报告与日志都在会话 scratchpad（不入库）：`smoke-*.jsonl`（acp-smoke 的事件行）、`r7-zed-report*.json`（`ACP_R6_REPORT` 无头实跑）、`build*.log` / `validate2.log`。

### 构建（验收 1 / 2）

| 项 | 数字 |
|---|---|
| 依赖闭包 | debug 约 730 个 crate、release 约 910 个（`cargo build` 的 `Compiling` 行计数） |
| 冷编译（debug，含依赖） | 首次 ~50 min（含三次失败重来，见下）；依赖齐了之后改自己代码 40 s |
| 冷编译（release，含依赖） | 依赖 ~35 min + 自己这一个 crate 连链接 16.5 min（`lto = "thin"` + `codegen-units = 1`） |
| 产物 | debug 276 MB / **release 176.6 MB**（随包分发的是 release） |
| `CARGO_TARGET_DIR` 占用 | 55.9 GB（debug 47.5 + release 8.4）—— 与主程序的 target 目录分开（`D:\cargo-target\AcpAgentClient-sidecar`） |
| `cargo tree 无 gpui (规则 5)` | `validate.ps1` PASS —— 主进程 `acp_bridge` 的依赖闭包里没有 gpui |
| `--selftest` | 退出码 0：`settings: C:\Users\Click\AppData\Roaming\Zed\settings.json` / `models: 14` |
| `validate.ps1` | 13 项全 PASS（`VALIDATE OK`） |
| sidecar clippy | `scripts/build-sidecar.ps1 -Clippy` 绿（修了 `large_enum_variant` 与两处 `cloned_ref_to_slice_refs`） |
| sidecar 单测 | 6 passed（`translate` 的增量差分 4 条 + 权限选项去重 + `_meta` 形状） |
| release 产物复跑 | 随包分发的那个（release）也跑了一轮：`stopReason end_turn`，终端一条干净的增量 `\nrelease-build-ok` + `exit_code 0` |

**冷编译路上踩的四个坑**（都在脚本或 manifest 里固化了）：

1. `wasmtime` 的 build.rs 要 `cmake`，本机 cmake 只在 VS 2022 BuildTools 里、不在 PATH → `failed to spawn cmake: program not found`。`build-sidecar.ps1` 按几个已知位置找。
2. `languages` crate 唯一地依赖 `pet`，`pet` 打开 `msvc_spectre_libs` 的 `error` 特性；本机 VS 没装「Spectre 缓解库」组件 → build.rs 直接 panic。**去掉了 `languages` 依赖**（偏离 1）。
3. 新解析出来的锁把 `merman` 0.8.0-alpha.5 与 `merman-render` 0.8.0-alpha.6 配在一起，编不过（`VendoredFontMetricsTextMeasurer` 不存在）。**以 `vendor/upstream/zed/Cargo.lock` 为种子**生成 sidecar 的 `Cargo.lock`，版本就与 zed 本体一致了。
4. debug 构建下 zed 的 `util::fs_embed!` 不内嵌资源，改为运行时从「可执行文件向上第一个带 `.git` 的祖先」读 `assets/`；sidecar 的产物在 `CARGO_TARGET_DIR`（仓库之外）→ `settings/default.json` panic。对策：`util` 打开 `debug-embed` 特性。

### 一轮含工具调用与权限（验收 3）

`acp-smoke run --agent zed`（`ACP_ZED_SIDECAR` 指向 debug 产物）：

- `initialize` 回的能力：`loadSession: true`、`promptCapabilities {image: true, audio: false, embeddedContext: true}`、`sessionCapabilities {list, delete, resume, close}`、`authMethods: []`、`agentInfo {zed-agent-acp 0.0.1}`。
- `session/new` 回 `configOptions`：一个 `select`（id `model`，14 个模型，当前 `cliproxy/gemini-3.8-flash-high`）。
- 一轮 `Use the terminal tool to run: echo hello-from-r7` → `tool_call`（kind `execute`）+ 4 条 `tool_call_update` + `agent_message_chunk`，`stopReason: end_turn`，`usage {total 49108, in 49102, out 6}`。
- 终端：`_meta.terminal_info {terminal_id, cwd}` 一条、`_meta.terminal_output {data}` 增量、`_meta.terminal_exit {exit_code: 0}` 一条。慢命令（两段 `Start-Sleep`）实测分两帧推出来，证明是**流式**而不是收尾一次性给。
- 编辑：`Create a file named r7-note.txt …` → 文件真的建出来了，`ToolCallContent::Diff` 的 `path` 是绝对路径、`newText` 是终稿（见下「五个真缺陷」）。
- 权限：把 Zed settings 复制一份到隔离目录、`tool_permissions.default` 改 `confirm`，跑 `--user-data-dir <隔离目录>` → `session/request_permission` 到达客户端、客户端回 `allow`、回合以 `end_turn` 收尾。

### Flutter 里的完整生命周期（验收 4）

`ACP_R6_REPORT` 无头口子（R6 建的那个，本轮直接复用）+ 随包分发的 sidecar（`build/windows/x64/runner/Debug/zed-agent-acp.exe`，CMake install 规则放的），`ACP_R6_AGENT=zed`：

| 步骤 | 结果 |
|---|---|
| 新会话 | `agentName: zed-agent-acp`，标题 `New zed-agent-acp Thread`，`commands: [compact]`，无 modes 下拉（我们不声明 modes） |
| 第一轮（终端） | `stopReason end_turn`，`usage {total 49327, out 17}`，条目 `TurnEntry 1 / ThoughtEntry 1 / ToolCallEntry 1 / MessageEntry 1` |
| `session/list` 校对 | `containsCurrent: true` |
| 断开重连 → `session/load` | `beforeEntries 4 → afterEntries 4`；digest 12 行里 **11 行一致**，差的一行是首行：实时是 `turn:1:end_turn`、重放是 `user:…`。这正是 R6 已裁定的「重放不带回轮边界」已知限制，不是本轮缺陷 |
| load 之后再一轮 | `LOADED`，`stopReason end_turn` |
| 取消 | 第三轮 4 s 后发 `session/cancel` → `stopReason: cancelled` |
| `session/close` → `session/resume` | `closed: true`；resume 后 `noReplay: true`、条目数不变 |
| `session/delete` | 成功（`error: null`） |

### `threads.db` 与运行中的 Zed（验收 5 → 裁定）

- 本机装了 Zed 且**跑着两个 Zed 进程**（PID 3176 / 28612）。sidecar 的线程库默认落在 `%LOCALAPPDATA%\Zed\threads\threads.db` —— 与 Zed 是同一份文件（实测：跑完之后该文件的修改时间正是本轮实跑的时刻）。
- **读**：没问题，`session/list` 能按 cwd 过滤出我们建的 6 条。
- **写**：**Zed 那边出事了**。Zed 日志 `%LOCALAPPDATA%\Zed\logs\Zed.log` 出现两条
  `ERROR [crates/agent/src/agent.rs:1861] Sqlite call failed with code 5 and message: Some("database is locked")`，
  时间戳 10:02:24 / 10:02:25 正是本轮实跑的窗口；sidecar 侧没有任何 sqlite 报错。即：代价由用户的编辑器承担（它存不下线程）。
- **裁定（按推荐项落地，待所有者确认）**：**配置共用、数据隔离**。sidecar 新增两个开关，主程序默认两个都传：
  `--user-data-dir %APPDATA%\AcpAgentClient\zed-agent`（`threads.db` / `db/` / `prompts/` 全挪过来）
  + `--zed-settings %APPDATA%\Zed\settings.json`（模型与密钥照旧只读沿用）。
- 隔离后复跑同一套生命周期：`ok: true`，Zed 的 `database is locked` 计数**停在 2 不再增加**，隔离目录里如期长出
  `zed-agent\threads\threads.db`（12 KB）与 `zed-agent\db\0-dev\`。
- 代价（已写 `docs/design.md` § 8 与 BACKLOG）：两边会话列表不互通；切换隔离之后，之前共用期建的会话在 `session/list` 里成了 `missingOnAgent`。

### 没有 sidecar 时（验收 6）

`ACP_ZED_SIDECAR` 指向一个不存在的文件：`agent_connect` 干净地报 `agent \`zed\` is not in settings.json agent_servers`（退出码 1），同一个 core 随后 `ping` 照常 `pong`。单测 `builtin::tests::missing_sidecar_is_not_listed` 覆盖「条目表为空 / 合并进设置后仍为空」。

### 五个真缺陷（实跑抓出来的四个 + 提交前自查一个，都已修 + 补了单测或复跑）

1. **终端卡是空的**：Zed 的 terminal 工具把 `ToolCallContent::Terminal` 放进 `ToolCallUpdate::UpdateFields`（`tools/terminal_tool.rs`），**不**走 `acp_thread::ToolCallUpdate::UpdateTerminal`。只处理后者的话 `_meta.terminal_info` 永远不会发，前端拿到一个没有数据源的终端卡。改成在 `UpdateFields` / `ToolCall` 的 `content` 里找 `Terminal` 内容块，按 `terminal_id` 去重后起输出泵。
2. **diff 卡是空的**：`UpdateDiff` 事件在编辑**开始**时就到了，那时 buffer 还没内容 → 线上的 `oldText` / `newText` 都是空串。改成记下 diff 实体，等这条工具调用 `status` 变成 `completed` / `failed` 时再读一次发终稿；顺带把 worktree 相对路径拼成绝对路径（客户端的「在文件面板里定位」按绝对路径开文件）。

另外两处是实跑看出来的**语义**问题，也修了（编号接上）：

3. **权限选项 id 重复**：Zed 的 pattern 型下拉让多个 choice 共用同一个 `optionId`（`always_allow:terminal` 同时叫「Always for terminal」和「Always for \`echo …\` commands」），靠 UI 勾选框区分范围。线上只有 id 能回指，重复会让「只对这条命令永久允许」被当成「对整个工具永久允许」—— **授权范围比用户点的更大**。改成按 `optionId` 去重（保留第一个），实跑后是 4 个互不相同的选项；补了单测。
4. **终端第一帧是一串空行**：`get_content()` 返回整个 PTY 网格含末尾空行，下一帧的真实输出接在前面、前缀不成立，于是整份重发。改成差分前先 `trim_end()`。
5. **惰性初始化会被并发请求撞出两个 `NativeAgent`**（提交前自查发现）：每条请求是一个独立的前台任务，`native()` 里有 `.await`，两条并发请求（`session/new` 与 `session/list`）会各自越过「还没建」的判断、各建一个，后一个覆盖前一个 —— 先建的那条会话在后来的 `connection.thread(&id)` 里查不到。改成 dispatcher 收第一条消息**之前**跑一次 `warm_up()`，去掉并发窗口；代价是 `initialize` 的往返里多了引导的一两秒。

### 与计划的偏离

见上面「偏离」段的三条。此外：`docs/design.md` § 8 原文说「实现 `ThreadEnvironment::create_terminal`」，实际**不需要自己实现** —— Zed 的 `NativeThreadEnvironment` 已经用 `terminal` crate 在进程内实现了，sidecar 只需把输出转成 `_meta` 三键；§ 8 已按实际改写。
