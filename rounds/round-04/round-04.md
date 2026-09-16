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
| claude-agent-acp 0.76.0 | `src/tools.ts`：客户端声明 `_meta.terminal_output: true` 时，Bash 工具卡 `content` 给 `{type: "terminal", terminalId: <toolUseId>}`，输出与退出码经 `tool_call_update._meta.{terminal_info, terminal_output, terminal_exit}` 送来（注释写明「matching codex-acp's _meta protocol」）；`src/acp-agent.ts` 只调 `fs/read_text_file` / `fs/write_text_file` |
| dsh-acp-interactive 1.3.0 | `src/presentation.ts`：同一形状 `_meta.terminal_output {terminal_id, data}` + `terminal_exit {terminal_id, exit_code | signal}` |
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
- `lib/projection/tool_calls.dart` + `session_store.dart`：入站 `_meta.terminal_*` 三键 → 终端缓冲（待确认）；`test/fixtures/26-terminal-meta.jsonl` 新增该场景。
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

<!-- 完成后回填。 -->

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-04/BLOCKED.md`，停下呼人。禁止放宽验收标准自我通过。

## 本轮实测

<!-- 完成后回填 -->
