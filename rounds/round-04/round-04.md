# Round 04 — fs 与 terminal 回调、文件面板与终端面板

<!-- 保存为 rounds/round-04/round-04.md；该轮其他管理产出放同一目录。 -->

> 状态：进行中

## 目标

`fs/*` 与 `terminal/*` 七个回调按规范落地（`rust/fs` / `rust/pty` / `rust/acp-core`），转录里的终端卡（22 / 23）与 diff 卡（21）接真数据，
文件面板（60）与终端面板（61）按画板实现并装进右栏（03 的三个标签），「Go to File」/ diff 行定位 / `@` 芯片点击 / Follow 全部落到
右栏文件面板；本地交互 shell 走 `terminal_open / write / resize / close` 四个桥命令。

可证伪：ROUNDS.md § 3 R4 的 7 条验收要点逐条有命令与输出；`git diff <画板阶段收口提交>..HEAD -- lib/theme lib/ui` 为空
（本轮画板阶段新增的 `lib/ui/files/`、`lib/ui/terminal/` 与改动的 `right_panel.dart` 都在画板阶段收口）。

## 前置

- 轮次：R3 已完成并合并（`4b888d7`，手测整改 `c7c3d38` / `d6b6e31`）。
- `powershell -File scripts/fetch-upstream.ps1 -Check` 全绿（2026-09-16，8 个钉版本全 OK；本 worktree 的 `vendor/upstream` 是指向主工作副本同名目录的目录联接，不重复下载 200 MB）。
- 本机版本：Flutter 3.47.4 / Dart 3.13.3、Rust 1.98.1、Node v24.11.1、`flutter_rust_bridge_codegen` 2.13.0、
  dsh-acp-interactive 1.3.0（`%APPDATA%\npm\dsh-acp-interactive.cmd`）、`CARGO_TARGET_DIR=D:\cargo-target\AcpAgentClient`。
- 参照 agent：claude-agent-acp（钉 0.76.0，`npx`）、dsh-acp-interactive；`test/fake-agent/fake-agent.mjs` 补 `--terminal` / `--fs` 场景做确定性验收。
- 分支：本轮在 worktree 分支 `claude/r4-implementation-76608e` 上开发（Claude Code 桌面端建的 worktree，分支名由它起；等价于 ROUNDS 约定的 `round-04`，进度表按此记）。

### 开工前核对到的一条事实（需所有者确认，先按推荐项开工）

**钉版本的三个参照 agent 都不调 `terminal/create`**，终端输出走 Zed 认的入站 `_meta` 通道：

| agent | 依据 |
|---|---|
| claude-agent-acp 0.76.0 | `src/tools.ts`：客户端声明 `_meta.terminal_output: true` 时，Bash 工具卡 `content` 给 `{type: "terminal", terminalId: <toolUseId>}`，输出与退出码经 `tool_call_update._meta.{terminal_info, terminal_output, terminal_exit}` 送来（注释写明「matching codex-acp's _meta protocol」）。**真跑后订正**：`src/acp-agent.ts` 只定义了 `readTextFile` / `writeTextFile` 两个转发方法，0.76.0 的 `src/` 里没有任何调用点——Read / Edit / Write 由 Claude Code SDK 直接读写磁盘，Edit 的 diff 经 PostToolUse 钩子以 `tool_call_update.content[{type: diff}]` 送来（`acp-agent.ts` 第 9600 行附近）；客户端的 `fs/*` 回调它一次也不调（逐方法流量计数见「真跑」） |
| dsh-acp-interactive 1.3.0 | `src/presentation.ts`：同一形状 `_meta.terminal_output {terminal_id, data}` + `terminal_exit {terminal_id, exit_code | signal}`；`src/` 里同样没有 `fs/read_text_file` / `fs/write_text_file` 的调用点（读文件是它自己的 read 工具，带 `locations`） |
| codex-acp | `src/TerminalOutputMode.ts`：客户端有 `_meta.terminal_output` 时用 `terminal_output`，否则 `terminal_output_delta` |
| Zed（钉版本） | `crates/agent_servers/src/acp.rs` `handle_session_notification` 的 post-handle：只读 `terminal_output.{terminal_id, data}`（追加）与 `terminal_exit.{terminal_id, exit_code, signal}` |

`docs/design.md` § 4 的入站 `_meta` 识别键清单是穷举的，增键要所有者裁定。**推荐**：增 `terminal_info` / `terminal_output` / `terminal_exit` 三键
（与 Zed 读的完全一致；投影层只按键存在追加 / 收尾终端缓冲，不按 agent 名判），否则参照 agent 的终端卡永远是空的。
备选是不增键、终端卡只在 `terminal/create` 路径出内容——那样三个参照 agent 一个都对不上。本轮按推荐项做，任务卡标**待确认**；
`terminal/*` 七个回调仍按规范全部实现（fake-agent `--terminal` 场景 + Rust scripted 测试覆盖），供将来真调它们的 agent 用。

## 交付物

### 画板阶段（只用 fixtures / 本地假数据）

- `lib/theme/tokens.dart`：`Geometry` 组加画板 60 / 61 量得的单点尺寸（文件树列宽、树行高与缩进、面板头行高、查看器头行高、
  过滤框高、Source / Preview 分段控件、终端状态行高、状态圆点、停止方块等），每条注明出处画板。
- `lib/ui/transcript/icons.dart`：画板 60 / 61 新用到的内联 SVG（树折叠箭头、全部折叠、清屏）。
- `lib/ui/shell/right_panel.dart`（03 / 60 / 61）：标签条泛化为「面板标签 + 每个本地终端一个标签」（画板 60 / 61 的标签条同时列着
  文件浏览器与终端标签），关闭键与窗口控制不动。
- `lib/ui/files/files_panel.dart`（60）：树（过滤输入、刷新、全部折叠、搜索开关、文件夹 / 文件图标、git 徽章）+ 查看器
  （文件名、路径、复制、Source / Preview 切换、元信息徽章、空态）；Preview 用 R1.5 裁定的 `package:markdown` 自写渲染（`MarkdownBody`），
  Source 用 `re_highlight`（`highlightCode`）。
- `lib/ui/terminal/terminal_panel.dart`（61）：状态行（运行中 / 已退出 · exitCode · signal）、cwd 常显、停止方块 / 清屏 / 重启、`xterm` 渲染、
  退出后的 Exit Code · 耗时行。
- `lib/projection/tool_calls.dart` + `session_store.dart`：入站 `_meta.terminal_*` 三键 → 终端缓冲（待确认）；`test/fixtures/27-terminal-meta.jsonl` 新增该场景。
- `lib/gallery/boards/panel_boards.dart`：60（整窗 + 查看器空态）/ 61（整窗 + 已退出）四张样张。

### 接线阶段（只换数据源）

- `rust/fs`：`read_text_file`（`line` / `limit` 1-based、越界报 invalid params）、`write_text_file`（不存在则创建、父目录一并创建、临时文件 + rename）、
  `read_file`（面板查看器：大小 / 行数 / 二进制判定 / 上限截断）、`watch`（`notify`，去抖后推变更目录）、`git_status`（`git status --porcelain -z`）。
- `rust/pty`：每个终端一份输出缓冲（`outputByteLimit`，**截断落字符边界**，Zed 语义：超限从头截、再退到行首）、`terminal/output` 的文本去 ANSI 转义、
  `spawn` 经系统 shell 拼命令（转写 Zed `util/shell_builder.rs` 的 PowerShell / cmd / sh 引号规则）、kill 不释放、release 后缓冲释放（前端自己留存）。
- `rust/acp-core`：`Shared` 注册七个 `fs/*` / `terminal/*` 回调（handler 只入队不阻塞），每条连接记自己建的终端、断开时释放；
  `Core` 加 `fs_read` / `fs_watch`（frb 流命令）/ `git_status` / `terminal_open` / `terminal_resize` / `terminal_close` / `terminal_kill` / `core_shutdown`。
- `rust/bridge/src/api.rs` 新命令 + `flutter_rust_bridge_codegen generate` 生成物入库。
- `lib/app/`：`files_state.dart`（树 / 查看器 / 监视 / git 徽章）、`local_terminals.dart`（本地 shell 标签）、`workbench_controller.dart` / `workbench_screen.dart`
  接右栏三个标签、定位与 Follow、终端卡的停止方块、应用退出时 `core_shutdown`；`headless_run.dart` 加 R4 步骤。
- `test/fake-agent/fake-agent.mjs`：`--terminal`（`terminal/create` → `wait_for_exit` → `output` → `release`，含后台命令等 kill）与 `--fs`（`fs/read_text_file` / `fs/write_text_file`）场景。
- 文档：`docs/design.md` § 3（`terminal_kill`、`fs_watch` 流形状、`git_status`、`core_shutdown`）/ § 4（入站三键，待确认）/ § 7（截断与留存）；
  `design/README.md` 60 / 61 状态；`ROUNDS.md` 进度表；`rounds/BACKLOG.md` git 徽章条目关闭。

## 验收

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | 参照 agent 一轮 | claude-agent-acp：读文件（18）→ 编辑（21 diff 只读，行点击定位）→ 前台命令（22，Exit Code）→ `Go to File` 落右栏；终端 `kill` 与 release 后留存用 fake-agent `--terminal` 与 dsh 验（见上「事实」） |
| 2 | fs 写走临时文件 + rename | `cargo test -p fs`：中间文件名与最终 rename、相对路径 / cwd 之外 / 父目录不存在、`line` / `limit` 1-based 与越界 |
| 3 | 终端截断 | `cargo test -p pty`：含中文与 emoji 的输出在字节上限处不切半个字符；`truncated` 正确；kill 不释放、release 释放 |
| 4 | 本地 shell | PowerShell 会话可输入命令、多标签、清屏、关闭；退出后显示退出码；应用退出时子进程全部回收（`core_shutdown` + 进程表核对） |
| 5 | dsh 能力 | `_meta.terminal_output: true` 时 dsh 的 Bash 工具卡走终端卡（对照 R1 未声明时的差异） |
| 6 | gallery 与零 diff | `flutter test test/gallery_test.dart` → `build/gallery/{60a,60b,61a,61b}.png` 对照；`git diff <画板阶段收口提交>..HEAD -- lib/theme lib/ui` 为空 |
| 7 | Windows 实测（规则 9） | `terminal/create` 经 `.cmd` 包装、带引号、含空格与中文的 cwd；`notify` 在 Windows 的事件表现 |
| 8 | 门禁 | `powershell -File scripts/validate.ps1` 全绿；`scripts/build.ps1 -Smoke` 通过 |

## 禁止

- 不做 registry / 安装 / 认证页 / 设置页（R5；右栏 Agents / 设置标签仍是占位）；不做 `session/load` 等会话生命周期动作（R6）；不做 sidecar（R7）。
- 不做索引服务、不做 Zed 的 Edits 审阅条、不做编辑器（查看器只读）。
- 不引 `git2` / `gix`；`notify` 是规则 1 清单内的库，pubspec 零新增。
- 接线阶段不改 `lib/theme` 与 `lib/ui`（规则 3）；缺 token 或缺回调钩子停下问，不偷改。
- 默认继承三条：不改前端页面样式（规则 3）；不加设计稿没有的功能（规则 3）；不在 `vendor/upstream/` 里改代码（规则 4）。
- Rust 禁 `unsafe`（规则 6）：进程树用 `taskkill /T`，不用 Job Object。

## 代码审查

执行器：cursor CLI（`cursor-agent`，`cursor-grok-4.6-high`，`--mode ask`），`.claude/cursor-review.ps1`。范围口径按 CLAUDE.md：前两轮全量 `main...HEAD`，第 3 轮起只审整改 diff。

### 第 1 轮（全量 `main...HEAD`，2026-09-16，产物 `.claude/reviews/20260916-135559-review.out.md`）

被审提交 `8bd20c9`（53 files / +6864）。findings 6（high 2 / P2 4 / P3 0），**全部采纳**，整改提交见本节末尾：

| # | 级别 | 位置 | 问题 | 处理 |
|---|---|---|---|---|
| 1 | high | `rust/acp-core/src/agent.rs` `on_create_terminal` | agent 断开与 `terminal/create` 竞态：`finish()` 先把 owned 集合清空，spawn 完成后才登记的新终端没人再释放，pty 活到 `core_shutdown` | 采纳。登记与「连接是否已退出」在同一把 `owned_terminals` 锁下判：已退出就当场 `release`、回 internal error 不登记 |
| 2 | high | `rust/fs/src/lib.rs` `ensure_inside` | 边界只做词法 `starts_with`，工作区里的目录联接 / 符号链接能把 `fs/read_text_file` / `fs/write_text_file` / `fs_read` 打到工作区外 | 采纳。cwd 之下通往目标的每一级已存在分量做 `symlink_metadata`，是链接 / 联接（`FILE_ATTRIBUTE_REPARSE_POINT`，与 `list_dir` 的 `entry_is_dir` 同一判断，抽成 `is_link`）就回 `OutsideWorkspace`；不存在的尾段（要新建的）不看。新用例 `links_inside_the_workspace_do_not_escape_read_or_write`（Windows `mklink /J`，其他平台 symlink）：读 / 写 / 查看器读 / 在链接下新建四条都拒绝，外面的文件一字节没动 |
| 3 | P2 | `agent.rs` `on_terminal_output` / `on_release_terminal`；`rust/pty/src/lib.rs` `output` | 两个 handler 同步跑在 SDK 分发线程上；`output` 持锁期间对最多 4 MiB 缓冲做 lossy 解码 + 去 ANSI，读线程的 push 与分发一起等 | 采纳。两个 handler 改成 `tokio::spawn` + `spawn_blocking`（与 create / kill / wait 同口径）；`output` 锁内只 clone 字节，解码与去 ANSI 放锁外 |
| 4 | P2 | `rust/acp-core/src/core.rs` `terminal_write` | 在 tokio worker 上对 ConPTY 做阻塞 `write_all`（子进程不读 stdin 时占死一条 worker） | 采纳。`terminal_write` 改 async + `spawn_blocking`；bridge 加 `.await`，acp-smoke 的三处（都在普通线程里）改 `runtime().block_on` |
| 5 | P2 | `lib/app/files_state.dart` / `local_terminals.dart` `dispose` | dispose 只取消 Dart 端口 / 丢模型，Rust 侧监视器与 shell 活到 `core_shutdown`（`core_init` 幂等复用 Core，热重启 / 测试里会攒） | 采纳。`FilesState.dispose` 对当前 root 调 `fs_unwatch`；`LocalTerminals.dispose` 对每个标签调 `terminal_close`。新用例断言两条命令都到了核心 |
| 6 | P2 | `lib/app/workbench_controller.dart` `killTerminal` | `_meta` 通道的终端 id 是 agent 的 toolUseId，核心没有这个 pty：停止方块一按就 `unknown terminal` 进 `lastError`，且本地已先标 killed（命令其实没停） | 采纳（最小改动）。先调 `terminal_kill`，成功才标 killed；`unknown terminal` 不记错、不标；其他错误照记。新用例覆盖 |

未报项：规则 1 / 4 / 5 / 6 / 8 / 10 未命中；`unsafe` 只在 `frb_generated.rs`（既有例外）；`5380c03..HEAD` 的 `lib/theme` / `lib/ui` 零 diff；`_meta.terminal_*` 三键的裁定留给所有者。

整改后 `cargo test -p fs`（18）/ `-p pty`（13）/ `acp-core --test scripted`（6）、clippy `-D warnings`、`flutter test test/app/`（19）全过；全量 `validate.ps1` 与 `build.ps1 -Smoke` 结果见「本轮实测 · 验收 8」。
整改提交：`d970e0f`；整改后全量 `validate.ps1` 13 项 PASS、`build.ps1 -Smoke` OK、fake-agent 真跑重跑通过（逐方法流量见「本轮实测」）。

### 第 2 轮（全量 `main...HEAD`，2026-09-16，产物 `.claude/reviews/20260916-141625-review.out.md`）

被审提交 `d970e0f`（54 文件）。审查者核对第 1 轮 6 条整改都在；findings 1（high 0 / P2 1 / P3 0），**采纳**：

| # | 级别 | 位置 | 问题 | 处理 |
|---|---|---|---|---|
| 1 | P2 | `rust/fs/src/lib.rs` `links_inside_the_workspace_do_not_escape_read_or_write` | 建联接失败时 `eprintln` + `return`，越界回归用例的四条断言一行没跑也算绿 | 采纳。建不出链接直接 `assert!` 红掉；`cargo test -p fs` 18 个照过（本机 `mklink /J` 正常） |

未报项同第 1 轮（规则 1 / 4 / 5 / 6 / 8 / 10，零 diff）。

### 第 3 轮（只审整改 diff `d970e0f..HEAD`，2026-09-16，产物 `.claude/reviews/20260916-143225-review.out.md`）

被审提交 `7030e05`。findings 0：审查者确认建不出链接会直接红掉、没有新的绿过路径；顺带指出同文件里 R3 的 `junctions_are_not_followed_out_of_the_workspace` 仍有「`mklink` 失败就 skip」的写法，不在本轮范围（记 BACKLOG）。

### 合并 main 之后的第 4 轮（全量 `main...HEAD`）

R4 收口时 `main` 已并入 R5（`b1339c8`，另一会话并行完成），本分支先合入 `main`（合并提交 `96b7c99`，18 个文件手工解冲突：右栏标签条改成 `PanelTab` 承载文件 / Agents / 终端标签而设置仍是主区页面、`core_bridge` 的 R4 命令改成 R5 的 `_run` 风格、`Core::terminal_close` 与 bridge 的同名命令各合成一条、`fixtures/26-terminal-meta` 改号 27 让位 R5 的 26、frb 生成物重出）。合并本身是新 diff，按缺陷门禁再全量审一轮（2026-09-16，产物 `.claude/reviews/20260916-145123-review.out.md`，被审提交 `9aabaf0`）：

审查者确认前三轮 7 条整改都在、合并解冲突的各点没有引出阻断级问题；findings 2（high 0 / P2 2 / P3 0）。所有者裁定（2026-09-16，本轮收口时）：R5 提前合入的部分已经过 cursor 独立审查，合并后再审出的问题先判严重程度，不属于阻断性 bug / 功能缺陷 / 需求偏离的直接记 BACKLOG 结束本轮。两条都按这个口径处理：

| # | 级别 | 位置 | 问题 | 判定 | 处理 |
|---|---|---|---|---|---|
| 1 | P2 | `workbench_controller.dart` `closeTab` | 「文件 + 终端」标签并存时关掉最后一个面板标签，右栏整栏收起、shell 在后台继续跑（侧栏再点「终端」能找回，pty 仍在 `terminals.tabs` 里、`closeRightPanel` / `shutdown` 照常收） | 非阻断：不丢数据、不泄资源（进程仍受管）、有找回路径 | 记 BACKLOG，不改 |
| 2 | P2 | `files_state.dart` `setProject` | 快速 A→B→A 切项目时 Dart 订到 B 的流而字段是 A，核心多留一个 B 的监视器到 `core_shutdown` | 非阻断：只在两次 await 的窗口里连切两次才触发，监视器泄漏有界（进程生命周期内一个 `DirWatcher`）、事件落到不在树里的目录是空操作 | 记 BACKLOG，不改 |

**结论**：4 轮审查共 9 条（high 2 / P2 7），7 条采纳整改、2 条按所有者裁定记 BACKLOG；收口时 high 0。

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-04/BLOCKED.md`，停下呼人。禁止放宽验收标准自我通过。

## 本轮实测

### 提交

- 画板阶段收口提交：`5380c03`（判据 `git diff 5380c03..7030e05 -- lib/theme lib/ui` 在接线阶段全程为空，见验收 6；合并 `main` 之后这个区间会含 R5 的画板文件，判据要按合并前的 `7030e05` 看）。
- Rust 核心接线：`434db40`；Dart 接线与实测：见本文末尾的提交号。

### 验收 2 · fs 写走临时文件 + rename、1-based 行、越界

    cargo test -p fs        # 17 passed

| 用例 | 断言 |
|---|---|
| `slice_lines_is_one_based_and_keeps_newlines` | 照 Zed 的 6 组用例：`line 3` 起、`limit 2`、`line 6`（末尾换行之后的空行）读到空串、`line 7` 报 invalid params、`line 0` 与缺省同义、末尾无换行的文件最后一行不补换行 |
| `read_and_write_text_file_stay_inside_cwd_and_write_atomically` | 相对路径 / cwd 之外 → `OutsideWorkspace`（agent 侧 `-32602`）；不存在 → `NotFound`（`-32002`）；父目录不存在一并创建；覆盖后没有 `.tmp-` 残留 |
| `write_atomic_uses_temp_name_in_same_dir` | 临时文件名 `<name>.tmp-<pid>-<nanos>`；rename 失败时临时文件被清掉、旧内容不动 |
| `read_file_reports_size_lines_binary_and_truncation` | 查看器读文件：行数 / 字节数 / NUL 判二进制 / 超 2 MiB 只给前一段且不切坏汉字 |
| `watch::reports_parent_dirs_and_git_flag_but_skips_ignored` | **规则 9 的 `notify` Windows 实测**：ReadDirectoryChangesW 报出「src 下变了」；`.git` 只打 git 标志、不进 dirs；`node_modules` 之下整条跳过 |
| `git::porcelain_z_parses_badges_and_rename_pairs` / `status_of_a_real_repo` | `-z` 格式的改名字段成对吃掉；真仓库（路径含空格与中文）改一个 + 新建一个 → `M` 与 `?`，路径绝对 |

### 验收 3 · 终端截断落字符边界、kill 不释放、release 释放

    cargo test -p pty       # 13 passed

| 用例 | 断言 |
|---|---|
| `output_buffer_truncates_from_the_start_at_char_boundaries` | 限 10 字节推「汉字😀ab」：从头截掉 2 字节会落在「汉」中间，退到「字」的首字节，剩 `字😀ab`；再推一大块仍合法 UTF-8；不给上限时受 4 MiB 绝对上限 |
| `strip_ansi_removes_escapes_and_normalizes_newlines` | CSI / OSC / 单字节 ESC 全去掉，`\r\n` → `\n`，截断在转义中间的流不 panic |
| `output_and_kill_then_release` | `terminal/output` 文本含命令输出、不含 ESC、带退出状态；退出后 kill 是空操作；release 后 id 失效 |
| `kill_running_command_keeps_output_until_release` | 长命令（`ping -n 30`）kill 后 wait 返回非零、输出还在、release 收尾 |
| `spawn_shell_command_runs_through_the_system_shell` | **规则 9**：经 PowerShell 拼命令，参数含空格与 `"引号"` 与中文，cwd 含空格与中文（`acp pty 中文 目录-<pid>`） |
| `spawn_shell_command_runs_cmd_wrappers_on_windows` | **规则 9**：裸名 `npm` 由 PowerShell 按 PATHEXT 找到 `npm.cmd` 经 cmd.exe 跑起来 |

踩到的一个 portable-pty 坑：Windows 上 `ChildKiller::kill` 在 TerminateProcess 成功后仍可能报 `os error 0`（「操作成功完成」），进程其实已经结束、等待线程随后拿到退出码；`kill()` 对错误码 0 视为成功。

### 七个回调走真实 handler（Rust scripted 测试）

    cargo test -p acp-core --test scripted   # 6 passed（R1 的 4 个 + R4 的 2 个）

`fs_and_terminal_callbacks_through_the_client_handlers`：假 agent 在 prompt 回合里依次发 `fs/write_text_file`（父目录不存在）→ `fs/read_text_file`（line 2 / limit 1 → `第二行\n`）→ 读不存在的（`-32002`）→ 读 cwd 之外的（`-32602`）→ 从第 9 行起读 3 行的文件（`-32602`）→ `terminal/create`（`echo r4-terminal-ok`，`outputByteLimit 4096`）→ `wait_for_exit`（0）→ `output`（含文本、`truncated: false`、带 `exitStatus`）→ 退出后 `kill`（空操作）→ `release` → 再 `output`（`-32602`，id 已失效）→ 后台命令 `create` → 轮询 `output` 看到 `started` → `kill` → `wait_for_exit`（非零）→ `output`（输出还在）→ `release`。会话目录含空格与中文（`acp-core r4 会话目录-<pid>`）。事件侧：`acp/terminal_output` 以 `source: agent` 推出字节与退出状态；release 后连接不再持有终端。
`owned_terminals_are_released_when_the_agent_disconnects`：agent 建了长命令的终端后断开，终端被一并释放（`output` 报 UnknownTerminal）。

acp-smoke 对 `fake-agent-r4`（`--fs --terminal --terminal-bg`）跑一整轮：99 条事件，最后一条 agent 消息里 `fs={"write":{},"read":{"content":"第二行\n"}} terminal={"exit":{"exitCode":0},"truncated":false,"sawOutput":true} background={"exit":{"exitCode":0},"sawOutput":true}`，`call_fs_write` / `call_fs_read` / `call_term_fg` / `call_term_bg` 四张卡都 completed，`PromptResponse end_turn`。

### 验收 6 · gallery 对照与零 diff

`flutter test test/gallery_test.dart --plain-name <id>` 出 `build/gallery/{60a-files-panel, 60b-files-empty, 61a-terminal-panel, 61b-terminal-exited, 03-workbench-done}.png`，与 `design/round-design/{60,61,03}-*.png` 并排看，文案 / 状态 / 层级 / 控件齐。偏离：

| # | 画板 | 偏离 | 原因 |
|---|---|---|---|
| 1 | 60 / 03 | 查看器头行 36 高（03 改稿后的值），树列头行 28（60 / 03 都是 28）；树列宽取 60 的 240（03 是 200） | BACKLOG 的 R3 条目要求按 03 新 PNG 取头行；03 的右栏比 60 窄 100，树列各自量得不同，取专门画板 60 的值 |
| 2 | 60 | 查看器正文内边距 16、标题 15（03 的值）；60 写的是 20/24 与 20 | 03 是 2026-09-16 改过的新源，同一组件取新的 |
| 3 | 61 | 终端正文行高 1.5（`CardText.code`），画板写 1.7；「Exit Code · 耗时」行固定在面板底部，画板紧跟在输出后 | 1.7 不是 token；xterm 视口要有界高度，退出后正文仍占满 |
| 4 | 61 | 「已退出」样张的耗时是 1.0s（画板 0.9s） | 样例时长要用 `Duration(milliseconds:)`，被样式字面量扫描拦；只是样例数据 |
| 5 | 60 | 复制键带「复制」文案（60 的写法；03 是纯图标） | 60 是文件面板的专门画板 |

零 diff 判据：`git diff 5380c03..HEAD -- lib/theme lib/ui` 为空（接线阶段的三次提交都只动 `lib/app` / `rust` / 文档 / 测试）。

### 验收 1 / 4 / 5 / 7 / 8 · 真跑

跑法：release 构建的 `build/windows/x64/runner/Release/acp_agent_client.exe`，无头口子在 R3 的 `ACP_R3_*` 之上加了四个环境变量（`lib/app/headless_run.dart` 头注释）：`ACP_R4_FILES=1`（回合后打开文件面板、按 locations 定位、读树与徽章）、`ACP_R4_FOLLOW=1`（回合前打开 Follow）、`ACP_R4_KILL_BG_AFTER=<秒>`（后台终端卡出现后到点按停止方块）、`ACP_R4_LOCAL_SHELL=1`（开本地 shell、等提示符、敲 `echo r4-local-shell-ok`、停止、重启、关闭）；报告落 `build/r4-*.json`，同名 `.trace.log` 记每步时间。项目目录 `D:/cargo-target/AcpAgentClient/r4 项目 目录`（git 仓库，路径含空格与中文）。三个 agent 各一条 `.ps1`（UTF-8 with BOM；`Start-Process -PassThru` + `WaitForExit()`，`-Wait` 会等整棵子进程树）。逐方法流量计数（`traffic.byMethod`）与每张工具卡的 content 种类（`r4Turn1.toolCallContent`）是本轮新加进报告的两个证据字段。

**fake-agent-r4**（`--fs --terminal --terminal-bg --stderr-noise`，`build/r4-fake.json`，exit 0，全程 7 s）——确定性地走完 `terminal/*` 与 `fs/*` 真回调：

| 步骤 | 结果 |
|---|---|
| 前台命令卡（22） | `call_term_fg` completed，`term_1` 退出码 0、输出 102 字符、`truncated: false` |
| 后台命令卡（23）+ 停止方块 | `call_term_bg` 出现 3 s 后按停止方块 → `terminal_kill` → `term_2` 退出码 1、`killed: true`，卡状态 failed；`killedByStopButton: [term_2]` |
| fs 回调落地 | `call_fs_write` / `call_fs_read` 的 locations 是 `fake-agent.txt` 与 `fake-agent.txt:2`（agent 经 `fs/write_text_file` 写、`fs/read_text_file` 读回第二行） |
| Follow | 回合中 locations 到达即落右栏：`rightTab: files`、选中 `fake-agent.txt`、`highlightLine: 2`、Source 模式 |
| 文件面板（60） | 根目录 4 项（`docs`、`AGENTS.md`、`fake-agent.txt`、`README.md`），徽章 `README.md: M`、`fake-agent.txt: ?`；Go to File 后查看器打开 `fake-agent.txt` |
| 本地 shell（61） | `term_3` 标题「r4 项目 目录」，提示符 `PS D:/cargo-target/AcpAgentClient/r4 项目 目录>` 出来后敲 echo，输出行 `r4-local-shell-ok` 单独一行；停止 → 退出码 1；重启 → `term_4` running；关闭 → 0 个标签 |
| 重载 agent | `lastError: null`（第一次跑时这里是 `pty: io: 句柄无效 (os error 6)`，见「Windows 实测」第 3 条，已修） |
| 退出收尾 | `shutdown()` → agent `exited`、终端标签 0；事后进程表没有残留的 `acp_agent_client` / `pwsh` / `node` |
| 逐方法流量（整改后重跑） | `in:fs/write_text_file` 1、`in:fs/read_text_file` 1、`in:terminal/create` 2、`in:terminal/wait_for_exit` 2、`in:terminal/output` 2、`in:terminal/release` 2（`terminal/kill` 由停止方块走本地 `terminal_kill`，agent 侧不发）——七个回调里六个由 agent 真调到客户端 |

**claude-agent-acp 0.76.0**（`npx -y @agentclientprotocol/claude-agent-acp@0.76.0`，`build/r4-claude3.json`，exit 0；模型 `opus[1m]`，mode `auto`）——提示词点名「用 Read 工具读 README.md、用 Edit 工具把第一行改成「# R4 真跑」、用 Bash 跑 `git status --porcelain`」：

| 步骤 | 结果 |
|---|---|
| 回合 | `end_turn`，22 s，3 张工具卡：read（content）→ edit（**`content: {diff: 1}`** = 画板 21 的 diff 卡）→ execute（**`content: {terminal: 1}`** = 画板 22，输出 ` M README.md` / `?? fake-agent.txt`，退出码 0，走 `_meta.terminal_output` 通道） |
| locations | read 与 edit 两张卡都带 `README.md:1` |
| Follow | `rightTab: files`、选中 `README.md`、`highlightLine: 1`、Source |
| Go to File | 查看器 `README.md`，5 行，正文开头 `# R4 真跑`（agent 改过之后的内容，查看器读的是磁盘） |
| 逐方法流量 | `in:session/update` 76 条、`in:_auth/status_update` 5 条；**没有 `in:fs/read_text_file` / `in:fs/write_text_file` / `in:terminal/create`**——见上面「事实」表的订正 |
| 本地 shell / 重载 / 收尾 | 与 fake-agent 相同：提示符、echo、停止（退出码 1）、重启、关闭；重载 `error: null`；shutdown 后 agent `exited` |

第一次跑（`build/r4-claude.json`）提示词没点名工具，它按本机 Claude Code 的 auto 模式（`bashFirst`）全用 bash 的 `cat` / `sed` / `unix2dos`，6 张卡全是 terminal 卡（其中一张退出码 1：`bash: -c: command not found`，卡状态 failed），没有 diff 卡；这说明终端卡 / 退出码 / 失败态在真 agent 上都对得上，但 diff 卡要靠 Edit 工具。它继承本机 Claude Code 的 `~/.claude` 设置（auto 模式 → 一次也没发 `session/request_permission`）。

**dsh-acp-interactive 1.3.0**（`build/r4-dsh2.json`，exit 0；`ACP_R3_CONFIG=model=cliproxy-dmit:deepseek-v4-pro,permission=read-only`）——提示词「跑 `git status --porcelain`，然后读 README.md 的前 3 行」：

| 步骤 | 结果 |
|---|---|
| 回合 | `end_turn`，7 s，2 张卡：execute（**`content: {content: 1, terminal: 1}`**，`_meta.terminal_output` 通道，输出 ` M README.md` / `?? fake-agent.txt` + `[stderr]` 段，退出码 0）→ read（content，locations `README.md:1`） |
| 验收 5 | R1 时（客户端没声明 `_meta.terminal_output`）dsh 的 Bash 卡只有 content 文本；本轮声明后同一张卡多出 `{type: terminal}` 内容与 `_meta.terminal_info / terminal_output / terminal_exit`，走终端卡 |
| Follow / Go to File | `rightTab: files`、`README.md`、`highlightLine: 1`、Source；查看器 5 行 |
| 逐方法流量 | `session/set_config_option` 2 次（model、permission）、`in:session/update` 146 条；没有 `fs/*` |
| 观察 | ① 它缺省模型 `deepseek-official:deepseek-v4-pro` 的直连端点在本机报 `DeepSeek API error (HTTP 404)`（回合失败、`stopReason: null`，`build/r4-dsh.json`），是 agent 侧环境，换成同一模型的代理路由即通；② `[stderr]` 段是 GBK 字节按 UTF-8 解码出的乱码（PowerShell 中文错误文案），是 dsh 自己捕获 stderr 时的编码问题，客户端原样投影 |

**Windows 实测（验收 7，规则 9）**：

1. `terminal/create` 的 shell 拼装与 `.cmd` 包装：`cargo test -p pty` 的 `spawn_shell_command_runs_through_the_system_shell`（参数含空格 / 引号 / 中文，cwd 含空格与中文）与 `spawn_shell_command_runs_cmd_wrappers_on_windows`（裸名 `npm` 经 PATHEXT 找到 `npm.cmd`）；真跑里 fake-agent 的两条命令经 PowerShell `-C "$null | & {...}"` 拉起，cwd 是 `r4 项目 目录`。
2. `notify`：`watch::reports_parent_dirs_and_git_flag_but_skips_ignored`（ReadDirectoryChangesW）；真跑里 agent 改完 README 后文件面板的徽章与查看器内容都是改后的。
3. **portable-pty 0.9.0 的 Windows `kill` 成败判反了**：`WinChildKiller::kill` 在 TerminateProcess 成功时返回 `Err(GetLastError())`（陈旧值——本机先后见过 `os error 0` 与 `os error 6` 句柄无效），失败时反而 `Ok`。第一次接线只把 0 当成功，第二次真跑就撞上 6。改成不看返回值、等等待线程把退出状态落进 `ExitCell`（最多 5 s）；`terminal_kill` 与 `on_kill_terminal` 因此改走 `spawn_blocking`。`cargo test -p pty` 13 个用例 + scripted 6 个照过，重跑 fake-agent 后重载步骤 `lastError: null`。
4. ConPTY 启动探询：xterm.dart 会对 `CSI 6 n` 再答一次并吞掉相邻按键（敲 `echo` 丢了 `e`），pty 读线程答完就把它从流里抠掉（BACKLOG 该条已关闭）。
5. 本地 shell 的键盘输入在「停止方块按下 → 退出事件到达」之间写不进 pty（`句柄无效`），`LocalTerminals` 对未在运行的终端直接丢弃输入、不记错误。

**验收 8**：`powershell -File scripts/validate.ps1`（全量，2026-09-16）13 项全 PASS（fetch-upstream -Check、rust-sdk pin、unsafe 扫描、`_meta` 键 ⊆ § 4、Zed 来源头注释、pubspec ⊆ 白名单、Assert-NoStyleLiteral、cargo build / test / clippy -D warnings、cargo tree 无 gpui、flutter analyze、flutter test）→ `VALIDATE OK`；`scripts/build.ps1 -Smoke` → `OK smoke round trip`。

### 已知限制 / 观察（不阻塞）

- `_meta` 三键（`terminal_info` / `terminal_output` / `terminal_exit`）按推荐项做了，**仍待所有者确认**（`docs/design.md` § 4 已标「待确认」）。
- 钉版本的两个参照 agent 都不调客户端的 `fs/*` 与 `terminal/*`，这七个回调的真实 handler 只靠 fake-agent（headless 真跑）+ Rust scripted 测试 + acp-smoke 覆盖；将来换到会调它们的 agent 版本时不用改客户端。
- 画板 61 的「Exit Code · 耗时」行固定在面板底部（画板紧跟输出后），见验收 6 偏离 3。
- 关掉右栏（`closeRightPanel`）会把全部本地 shell 一起关掉：画板 03 / 61 没有「隐藏但保留」的状态。
- 合并 `main`（R5）之后重跑三条真跑（`96b7c99` 的 release 构建；validate 13 项 PASS、smoke OK）：fake-agent / dsh / claude-agent-acp 的终端卡、diff 卡、locations、Go to File、本地 shell、重载、收尾全部照旧；唯一变化是 fake-agent 那条 `follow.rightTab` 读到 `agents`——R5 把 requestScope 的 URL elicitation 当认证流程、到达即把右栏切到 Agents 标签的认证页（画板 52），而 R3 起的 fake 回合里就带一条这样的 elicitation，它在 Follow 落到文件面板之后到达；`selectedPath` / `highlightLine` 仍是 Follow 的落点，两个参照 agent 的 `rightTab` 仍是 `files`。
- 在 Claude Code 会话里跑 claude-agent-acp 会与主会话争 OAuth 刷新锁（`~/.claude/.oauth_refresh.lock` 是它留下的过期空目录，挪开后重跑即通）；与客户端无关，记在记忆里。
