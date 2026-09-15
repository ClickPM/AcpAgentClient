# Round 01 — Rust 核心主线（无 UI）

> 状态：进行中

## 目标

`acp-core` 用官方 rust-sdk v2 以 Client 角色跑通一等 agent 的完整主线（拉起 → initialize → terminal auth → session/new → prompt 含工具 / 权限 / 计划 / 配置 → end_turn 带 usage；cancel、权限与 elicitation 队列、traffic 脱敏、未知变体计数、退出与重连），所有事件与命令经 frb 暴露；用 `acp-smoke` 对 dsh-acp-interactive 真跑验收；Windows 下 `.cmd` 包装的 npx 型 agent 至少完成 initialize。范围 = ROUNDS.md § 3「R1」。

## 前置

- R0 已合并 `main`（ddf22b3）；`scripts/fetch-upstream.ps1 -Check` 全绿。
- 本机：Rust 1.98.1、Flutter 3.47.4、`flutter_rust_bridge_codegen` 2.13.0、Node 24.11.1；`dsh-acp-interactive` 已全局安装（`%APPDATA%\npm\dsh-acp-interactive.cmd`，1.3.0）；`~/.dsh/.credentials.yaml` 已有 DeepSeek 密钥（真跑 prompt 用；本轮不读它的内容）。
- 参照 agent：dsh-acp-interactive（custom 型，settings 手填）；npx 型验 `.cmd` 用 claude-agent-acp 或 pi-acp（只到 initialize）。

## 交付物

| 路径 | 内容 |
|---|---|
| `rust/Cargo.toml` | workspace 依赖加 `futures 0.3`（rust-sdk 公开 API 的底座：`Lines` 传输要实现 `futures::Sink` / `Stream`；已是 rust-sdk 的传递依赖，不引入新的依赖闭包）与 `portable-pty 0.9`（规则 1 清单内） |
| `rust/settings` | `SettingsStore::load / save / get / upsert`：文件不存在 = 空设置；写走「临时文件 + rename」（规则 7）；坏文件报错不覆盖 |
| `rust/pty` | `TerminalManager`：portable-pty 拉起、读线程按块经 `TerminalSink` 回调推字节、写入、等退出（阻塞，异步侧 `spawn_blocking`）、kill / release；子进程退出后关伪终端让 ConPTY 读端 EOF |
| `rust/acp-core/src/agent.rs` | 一条连接：tokio 子进程三路管道；stdin / stdout 行 tap → `acp/traffic`（脱敏）；stderr 单独一路进 traffic + 8 KiB 尾巴；SDK `Client.builder()` 三个 handler（permission / elicitation 入队 + `acp/client_request`；未类型化通知 handler：`session/update` 用 SDK 类型校验后 serde 直出，失败计数 + `update_dropped` 告警，`elicitation/complete` / `$/cancel_request` 以 `requestId: null` 转发）；`initialize` 与进程退出赛跑；`-32000` → `auth_required` 事件 + `AuthRequired` 错误；cancel 后挂起与后到的权限请求自动回 `cancelled`；退出监视 → `exited(code, stderrTail)`；断开 = 关 stdin，3 s 内不退就 `taskkill /T`。头注释标 Zed `agent_servers/src/acp.rs` 来源（规则 5） |
| `rust/acp-core/src/{capabilities,terminal_auth,command,redact}.rs` | § 4 能力声明（Cursor 追加参数化模型选择器键；转写 Zed，标来源）；terminal 型认证 = 同一程序 + 方法 args / env，旧版 `_meta.terminal-auth` 回退（转写 Zed）；裸程序名按 PATH + PATHEXT 解析（Rust std 只找 `.exe`）、`CREATE_NO_WINDOW`、`taskkill /T` 结束进程树；traffic 脱敏（键名子串 authorization / api_key / apikey / token / secret / password，`{name, value}` header 条目，文本行的 `Bearer x` 与 `KEY=value`） |
| `rust/acp-core/src/core.rs` | `Core`：settings、终端表、agent 连接表；§ 3 命令的核心实现；`acp/terminal_output` 的 base64 编码；runtime worker 栈 8 MiB（SDK dispatch 链 debug 构建约 0.5 MiB / 条，Zed 实测） |
| `rust/bridge/src/api.rs` + 生成物 | 新增命令：`agent_connect(agent_id, cwd?)` / `agent_disconnect` / `session_new` / `session_prompt` / `session_cancel` / `session_set_mode` / `session_set_config_option` / `acp_respond` / `authenticate` / `terminal_auth_run` / `terminal_write`（R4 命令提前，认证终端要输入）/ `agent_settings_get` / `agent_settings_set` / `agents_status`（开发期）；每条都是 `runtime().spawn(...)` 再 await，JoinHandle 兜住 panic |
| `rust/tools/acp-smoke` | `run --agent --cwd [--prompt] [--command/--arg/--env] [--config id=value] [--auto-permission ...|none] [--auto-elicitation] [--cancel-after] [--auth-input/--auth-input-delay/--auth-stdin] [--only-initialize]`；事件与结果按 JSON 行打 stdout；自动回应 client_request（`none` = 留在队列，验 cancel 自动回应）；`--auth-input` 看到终端提示含 "key" 后写入，`--auth-input-delay`（默认 5 s）兜底盲写 |
| `rust/acp-core/tests/scripted.rs` | 用 SDK `Channel::duplex()` 接一个脚本化假 agent（Agent 角色）的主线测试：auth_required → 重试 → 一轮含 update / notice 丢弃计数 / permission / form + url elicitation / elicitation/complete / end_turn usage；cancel 自动回 cancelled（挂起的与后到的）；断开 → exited；对端立刻关闭 → initialize 失败 |
| `test/fake-agent/fake-agent.mjs` | 零依赖 Node 假 agent（回放 fixtures 场景、`--setup` 终端认证、`--crash-after` / `--crash-on-prompt` / `--hang-on-prompt`、`--stderr-noise`），给 acp-smoke 离线验收用 |
| `docs/design.md` § 3 | `acp/agent_state` 状态清单与 payload、`acp/client_request` 的 `requestId: null` 通知、`acp/terminal_output` 与 `acp/traffic` payload、`terminal_write` 提前、命令入参以 `api.rs` 注释为准 |

## 验收

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | dsh 全链路：拉起 → initialize → `session/new` 回 `-32000` → terminal auth `--setup` 在 pty 里跑完 → 自动重试 `session/new` 成功 → 一轮 prompt 含 `tool_call` + `request_permission`（allow_once）+ `plan` + `config_option_update` → `end_turn` 带 usage；变体集合与 fixtures 的 dsh 场景同形 | `acp-smoke run --agent dsh-acp-interactive --cwd <dir> --prompt ... --auth-input ...`（DSH_HOME 指临时目录以触发认证） |
| 2 | 同一轮 `--cancel-after`：挂起的权限请求核心自动回 `cancelled`，`stopReason = cancelled`；未完成工具卡由前端本地标（核心不伪造） | `acp-smoke run ... --cancel-after <ms>`；`session_cancel` 结果的 `cancelledRequestIds` 非空或 fake agent 的后到权限请求得到 cancelled |
| 3 | npx 型 agent 在 Windows 用系统 Node 拉起并完成 initialize，工作目录含空格与中文 | `acp-smoke run --agent <id> --command npx --arg -y --arg <pkg> --cwd "D:\测试 目录\..." --only-initialize` |
| 4 | traffic 三类密钥字段为 `***`；注入一条 `notice` → dropped 计数 +1、`update_dropped` 告警、traffic 原文可见；据此复议 BACKLOG 的 `notice` 条目 | fake agent 每轮发一条 `notice`；`cargo test -p acp-core --test scripted`；acp-smoke 输出里 `"line"` 含 `***` |
| 5 | 杀掉 agent 进程 → `exited` 带退出码与 stderr 尾巴；核心不 panic；再次 `agent_connect` 可恢复 | fake agent `--crash-on-prompt`（回合中途 exit 3）与 `--hang-on-prompt` + 外部 `taskkill /F`；随后同一 data-dir 再 `run` 一次成功 |
| 6 | elicitation form 与 url 都能经 `acp/client_request` 到达并由 `acp_respond` 收尾 | dsh 提供 form（实测记录）；url 用 fake agent（`scripted.rs` 与 acp-smoke 两处） |

## 禁止

继承 TEMPLATE 三条。本轮额外：不做任何画板 widget（R2 / R3）；不接 `fs/*` 与 `terminal/*` 回调（R4，未处理的请求由 SDK 回 method_not_found）；不做 registry / npx 安装（R5）；不引 Markdown / 高亮 / diff 库（R1.5 裁定前）；不读、不打印 `~/.dsh/.credentials.yaml` 的内容（规则 8）。

## 代码审查

- 审查方式：`cursor-review.ps1`（默认档，`--mode ask`）两次硬失败 → 回落主会话委派的 Claude Code 只读子代理（同一份任务书 `.claude/cursor-review-prompt.md`）。
- cursor 失败原因（`20260915-132034` 与 `20260915-132138`）：两次进程都在启动瞬间退出，`.out.md` 0 字节、`.err.log` 只有一行 `Error: EPERM: operation not permitted, rename 'C:\Users\Click\.cursor\cli-config.json.<pid>.<uuid>.tmp' -> 'C:\Users\Click\.cursor\cli-config.json'`；同一时刻 `cursor-agent status` 正常（已登录），用 `[System.IO.File]::Open(..., 'None')` 探测 `cli-config.json` 报「正由另一进程使用」——CLI 启动要原子重写自己的配置，文件被本机另一个进程（疑似同机另一个 cursor-agent / Cursor IDE 会话）锁住就起不来。属于文档定义的「启动失败」硬失败；本轮与复审都走子代理（同一轮只用一个执行器）。`--mode ask` 的首次实测顺延到 R1.5 / R2。
- 审查器与模型：Claude Code 子代理（general-purpose，**opus**，所有者裁定 2026-09-15），只读；范围 `main...HEAD`（第 1 轮，全量，基准 b3534a6）。
- findings：5（high 2 / P2 0 / P3 3），逐条：
  1. [high] agent 的 stderr 尾巴（`push_stderr`）存的是原始字节，随 `exited.stderrTail` 与 `CoreError::Exited` 文案把明文密钥带到前端与日志，而同一行在 traffic 里已打码（规则 8）→ **采纳**：`stderr_task` 先 `redact_line` 再进尾巴、traffic 共用同一份脱敏结果（`emit_traffic_redacted`）。复验：fake agent `--stderr-noise` + 权限挂起时 `--crash-after 800`，`exited{code: 3, stderrTail: "[fake-agent] turn started; token=*** / fake-agent: simulated crash (exit 3)"}`，`session_prompt failed: ... token=***`，日志与 stderr 里 `FAKE-TOKEN` 0 次。
  2. [high] `cancel_pending` 只在 `session_prompt` 返回时清，cancel 落在回合之外（连点停止、收尾补发）会把**下一回合**的权限请求静默自动 `cancelled`、前端永远看不到权限卡 → **采纳**：`session_prompt` 发请求前先清标志（一行）。`scripted.rs` 的 cancel 用例扩成两回合：回合外补发一次 cancel 后，第二回合的权限请求进队列并被前端回 `selected`，agent 端看到的 outcome 序列是 `cancelled, cancelled, selected, cancelled`。
  3. [P3] `TerminalManager::spawn` 在子进程已拉起、表项已插入之后，读 / 等待线程建不出来就 `?` 返回，子进程与表项成孤儿 → **采纳**：两处失败路径走 `abandon(id, handle)`（撤表项、kill、关伪终端）。
  4. [P3] ConPTY 启动探询 `CSI 6 n` 只在单次 read 的 chunk 内匹配，跨 read 边界就永不应答、终端里的 `--setup` 永久挂 → **采纳**：读线程保留上一块末尾 3 字节拼接后再匹配。
  5. [P3] `$/cancel_request` 转发的 `params.requestId` 是协议原样（数字），与队列键（Display 字符串）不同形，R3 直接比对会匹配不上 → **采纳**：转发前把 `params.requestId` 归一化成与队列键同形的字符串，`docs/design.md` § 3 同步注明。
  未判 finding 的说明（审查者给出）：规则 1 新依赖只有 `futures`（任务卡有理由）与清单内的 `portable-pty`；规则 6 的 `unsafe` 全在 frb 生成物（R0 已裁定）；规则 3 `lib/` 只有生成物变化；规则 7 settings 走 temp + rename；规则 9 四处 Windows 坑都有实测记录；判据 11 能力声明与 § 4 逐条对齐、handler 返回 `Err` 时 SDK 会替我们回错误响应不会让 agent 挂起。
- 整改提交 2f5c9ef 后：`cargo test -p acp-core -p pty` 全过（scripted 3 含扩展用例）、`cargo clippy --workspace --all-targets -D warnings` 零告警、`validate.ps1 -Quick` 全 PASS。
- 复审：<!-- 第 2 轮回填 -->
- 结论：<!-- 复审后回填 -->

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-01/BLOCKED.md`，停下呼人。禁止放宽验收标准自我通过。

## 本轮实测

全部在本机（Windows 11 26200，`CKROG14AIR`，用户名 `Click`）实测，2026-09-15；日志落 `%TEMP%\claude\...\scratchpad\*.log`（不入库），任务卡只记结论。二进制：`D:\cargo-target\AcpAgentClient\debug\acp-smoke.exe`（`cargo build -p acp-smoke`）。

### 单测与静态门

- `cargo test --workspace`：acp-core 14（redact / command / capabilities / terminal_auth / core）+ fixtures 1 + scripted 3 + pty 3 + settings 3 + fs 1，全过；`cargo clippy --workspace --all-targets -D warnings` 零告警；`validate.ps1 -Quick` 全 PASS（`_meta` 字面量检查拦下过测试代码里的 `v["_meta"]` 与 `with_legacy_meta(json!(...))`，改成常量 / 改名后过）。
- `scripted.rs`（SDK `Channel::duplex()` + Agent 角色假 agent，不拉进程）覆盖：`-32000` → `auth_required` 事件 + `AuthRequired` 错误 → 重试成功；一轮里 `agent_message_chunk` / `tool_call` / `tool_call_update` 直出、`notice` 计数 +1 并发 `update_dropped(error)`、权限请求入队并由 `respond` 收尾（错形状先被拒并留在队列）、form 与 url elicitation、`elicitation/complete` 以 `requestId: null` 转发、`end_turn` 带 usage；cancel 后挂起的与后到的权限请求都自动 `cancelled`、前端只见到一条；断开 → `exited`；对端立即关闭 → initialize 失败不挂。

### 验收 1 · dsh 全链路

（a）**认证段**（`DSH_HOME` 指空目录 `D:/cargo-target/AcpAgentClient/dsh-home-r1`，只有 deepseek 一个 provider 才会触发 dsh 的认证门；不碰 `~/.dsh`）：

```text
acp-smoke run --agent dsh-acp-interactive --command C:/Users/Click/AppData/Roaming/npm/dsh-acp-interactive.cmd
  --env DSH_HOME=D:/cargo-target/AcpAgentClient/dsh-home-r1 --cwd D:/cargo-target/AcpAgentClient/dsh-cwd-a
  --prompt "Reply with exactly the word PONG." --auth-input sk-dummy-key-for-r1-auth-test --auth-input-delay 5000
```

10.8 s：`spawned` → `initialized`（authMethods `deepseek-api-key`，type terminal，args `["--setup"]`）→ `session/new` 回 `-32000` → `acp/agent_state: auth_required{authMethods, message: "DEEPSEEK_API_KEY is not configured..."}` → `terminal_auth_run`：pty 里跑 `dsh-acp-interactive.cmd --setup`（`authenticating{terminalId: term_1, label: "Configure DeepSeek API key"}`）→ 5 s 后盲写 30 字节（提示不可见，见下方「ConPTY 的坑」第 2 条）→ 终端输出 `DeepSeek API key saved in the Harness credential store.` → `exitStatus{exitCode: 0}` → 核心自动重试 `session/new` **成功**（`sessionId cf74b842-…`，modes / configOptions 齐）→ `session/prompt` → DeepSeek 拒绝假密钥：`agent error -32603: Internal error: turn failed: Authentication Fails, Your api key: ****test is invalid`（dsh 自己已打码；整份日志里假密钥 0 次）。临时 home 里多了 `.credentials.yaml` 与 `.anonymous-user-id`，跑完删掉。
断开时 dsh 进程以 `-1073740791`（`0xC0000409`，node fail-fast）退出——是 dsh 在回合失败后 dispose 阶段的行为，B / B' / C 三轮都是 `exited{code: 0}`；`exited` 事件照常带出退出码。

（b）**回合段**（真实 `~/.dsh`，只读它自己的凭据；cwd = `D:\cargo-target\AcpAgentClient\dsh-cwd-b`）：

```text
acp-smoke run --agent dsh-acp-interactive --command C:/Users/Click/AppData/Roaming/npm/dsh-acp-interactive.cmd
  --cwd D:/cargo-target/AcpAgentClient/dsh-cwd-b --config permission=read-only --auto-permission allow_once
  --prompt "First create a todo list with exactly two items using your todo tool (...). Then append the line '...' to README.md using your file edit tool. Then reply DONE."
```

15.6 s：`session_new` → `session_set_config_option(permission=read-only)` 返回全量 configOptions（model / reasoning_effort / permission 三项）→ 回合 176 条 `session/update`：`config_option_update` 1、`available_commands_update` 1、`tool_call` 6、`tool_call_update` 6、`plan` 3（todo 工具）、`usage_update` 8、`session_info_update` 2、`agent_thought_chunk` 147、`agent_message_chunk` 2；`session/request_permission` 1 条（read-only 下的写升级，`allow-once` / `reject-once` 两项）→ 自动 `allow_once` → `end_turn`；README 多了那一行；`droppedUpdates` 0；`agents_status.pendingRequests` 空。
**与 fixtures 的 dsh 场景比**：变体集合 ⊂ fixtures（fixtures 另有 `current_mode_update`、`plan_update` / `compaction_*` 等；dsh 1.3.0 本轮没发 `current_mode_update`，也**不带 end-turn `usage`**，只发 `usage_update`），无 fixtures 之外的变体，`notice` 没出现（BACKLOG 条目据此复议）。
另一轮（未设 read-only）：7.6 s，`tool_call` 2（read + edit）、无权限请求（默认 preset 为 workspace-write，dsh 不问）。

### 验收 2 · cancel

fake agent（`--auto-permission none` 让权限请求留在队列，`--cancel-after 600`）：`session_cancel` 返回 `{"cancelledRequestIds":["100"]}`，agent 端收到 `cancelled` 后回 `stopReason: cancelled`，`acp/client_request` 只有 1 条，`pendingRequests` 空。scripted 测试另覆盖「cancel 之后才到的权限请求也自动 cancelled、不进前端队列」。未完成工具卡的 cancelled 态是前端本地态（`docs/acp-projection.md` § 11 第 5 条），核心不伪造。

### 验收 3 · npx 型 agent 在 Windows（规则 9）

```text
acp-smoke run --agent claude-agent-acp --command npx --arg -y --arg @agentclientprotocol/claude-agent-acp@0.76.0
  --cwd "D:/测试 目录/acp-smoke-cwd" --only-initialize
```

41.6 s（含 npm 首次下载）：`spawned{program:"npx", cwd:"D:/测试 目录/acp-smoke-cwd"}` → `initialized`（agentInfo、`sessionCapabilities` 全套、authMethods `claude-ai-login`（terminal 型）等）→ 断开 `exited{code:0}`。裸 `npx` 由 `command::resolve_program` 按 PATHEXT 解析成 `npx.cmd`，再由 Rust std 经 `cmd.exe /c` 拉起（Rust ≥ 1.77 的 BatBadBut 修复负责引号）；`.cmd` 包装 + 含中文与空格的工作目录都没问题。settings 落盘为 `{"type":"custom","command":"npx","args":["-y","@agentclientprotocol/claude-agent-acp@0.76.0"]}`。

### 验收 4 · traffic 脱敏与未知变体

fake agent `--stderr-noise`（stderr 写 `token=FAKE-TOKEN-FOR-REDACTION-TEST`）+ 每轮一条 `notice`：`acp/traffic` 里 stderr 行是 `[fake-agent] turn started; token=***`，整份日志 `FAKE-TOKEN` 0 次；`initialize` 出站行里 `_meta` 等原样；`notice` → `update_dropped{method, error: "unknown variant `notice`, expected one of ..."}`，`droppedUpdates` 1，之后的 agent_state 事件都带 1，`agents_status` 也是 1；回合照常结束。dsh 真跑三轮 `sk-` 在日志里 0 次（密钥本就不过 ACP）。`redact` 单测另覆盖 header `{name: Authorization, value}`、`env.DEEPSEEK_API_KEY`、`access_token` / `apiKey` / `client_secret` / `password`、文本行 `Bearer x` 与 `KEY=value`。

### 验收 5 · agent 退出与重连

- `--crash-on-prompt`（agent 收到 prompt 就 `exit(3)`）：`exited{code:3, stderrTail:"fake-agent: crash on prompt (exit 3)"}`；`session_prompt` 报 `agent `fake` exited (code Some(3))`（SDK 的「传输已关闭」先到，`race_exit` 等 2 s 内的退出信息再报，前端拿到退出码而不是一句 transport closed）。
- `--stderr-noise` + 权限挂起中 `--crash-after 800`：`exited.stderrTail` 里 stderr 那行是 `token=***`（第 1 轮审查整改后复验，尾巴与 traffic 共用脱敏结果）。
- `--hang-on-prompt` + 外部 `taskkill /PID <pid> /F`：`exited{code:1, stderrTail:"fake-agent: hanging on prompt"}`，`agents_status.exited.code` 1；随后同一 data-dir 再 `run`：`agent_connect` 成功、整轮 `end_turn`。核心全程无 panic。

### 验收 6 · elicitation form / url

- form（dsh 真跑，`ask-user-question` 工具）：`acp/client_request{method: elicitation/create, params.mode: form, requestedSchema.properties.q0.oneOf [Yes, No], q0_custom}` → 自动 `accept{content:{q0:"Yes"}}` → 模型回 `ANSWER=Yes`，8.4 s。
- url（fake agent；codex 真跑留 R5）：`elicitation/create{mode:url, requestId:"req_login_1", url}`（requestScope，params 无 sessionId）→ `accept` → `elicitation/complete` 以 `requestId: null` 转发；scripted 测试同。

### ConPTY 的坑（Windows 实测，规则 9）

1. **conhost 启动探询**：portable-pty 0.9 固定以 `PSEUDOCONSOLE_INHERIT_CURSOR` 建伪终端，本机 conhost 一启动就发 `CSI 6 n` 并**阻塞子进程的控制台 I/O 直到收到光标位置应答**——不答则 `cmd /c echo` 永不退出（pty 单测第一次就挂了 7 分钟），关掉输入管道才被 conhost 以 `STATUS_CONTROL_C_EXIT` 杀掉；portable-pty 自带的 `whoami` 示例在本机也是这么"结束"的。`rust/pty` 的读线程对第一条 `CSI 6 n` 回 `CSI 1;1 R`，之后 `cmd /c echo`、`cmd set /p`、node readline 全部正常（单测 `write_reaches_the_child` 覆盖键盘输入）。记 BACKLOG（R4 与 xterm.dart 的分工）。
2. **dsh `--setup` 在 Windows TTY 上看不见提示**：不是我们的问题——node 在 Windows 上对 TTY 的写是异步的，dsh 在 `question()` 返回后立刻 muted，提示的第二段起全被吞；`TERM=dumb` 或管道 stdin 时正常。pty 里 readline 活着，盲打 + 回车能保存。记 BACKLOG（上游修）。
3. **`.cmd` 在 ConPTY 里**：CreateProcess 对 `.cmd` 隐式走 `cmd.exe`（标题序列 `ESC]0;C:\WINDOWS\system32\cmd.exe`），npm 包装脚本的 `title %COMSPEC%` 也照跑，不需要我们再包一层。

### 偏离与取舍

- `agent_connect(agent_id, cwd?)` 多了可选 `cwd`：dsh 把会话存在进程 cwd 下的 `.sessions`，agent 进程的工作目录不能是随便一个目录；R3 接线时传项目目录。
- `terminal_write` 提前到 R1（§ 3 已注）；`agents_status` 是开发期命令，不在 § 3 清单，前端不用。
- `futures` 进 workspace 依赖（理由见交付物表）；`portable-pty` 在规则 1 清单内。
- `fs/*` 与 `terminal/*` 回调本轮不接，SDK 对未处理请求回 `method_not_found`；dsh 不调客户端 fs / terminal（它自己有工具，终端输出走 `_meta.terminal_output`），claude-agent-acp 只到 initialize，所以本轮没触发。
- Dart 侧只有 frb 生成物变化（`lib/bridge/`），`flutter analyze` 无问题；`CoreBridge` 的新命令封装留给 R3 接线。
