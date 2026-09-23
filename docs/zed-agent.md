# Zed agent 开发文档

> 内置 Zed agent（`zed-agent-acp` sidecar）的开发入口：版本、sidecar 化方案、与本客户端的集成、已知上游限制、相关待办，集中在这一份。
> 本文是**汇总与导航**，不是新的决策源：架构决策仍以 [`design.md`](design.md) § 8 为准，研究依据在 [`research.md`](research.md) § 1 / § 2 / § 6，
> R7 的实测与审查记录在 [`rounds/round-07/round-07.md`](../rounds/round-07/round-07.md)，待办记在 Zed agent 专属的 [`rounds/BACKLOG-ZED.md`](../rounds/BACKLOG-ZED.md)（所有者裁定 2026-09-23 从 `BACKLOG.md` 移出，当前不修；本文 § 5 只是指针）。
> 几处事实与那几份对不上时，以它们为准，并回头改本文。建立于 2026-09-23。

## 1. 当前使用的 Zed agent 版本

| 项 | 当前值 | 事实来源 |
|---|---|---|
| zed 钉版本 | commit `d9e1c024f393832765a03f4de204d6c8cd9abcb2`，该版本 zed 自称 **`1.21.0`**（2026-09-11 钉） | [`pins/upstream.json`](../pins/upstream.json) zed 条目的 `commit` / `version`；`vendor/upstream/zed/crates/zed/Cargo.toml` |
| 复用的 zed 部分 | `crates/agent`（`NativeAgent` / `Thread` / `ThreadStore`）+ `crates/eval_cli` 的无头引导，依赖清单照 `crates/eval_cli/Cargo.toml` | [`sidecar/zed-agent-acp/Cargo.toml`](../sidecar/zed-agent-acp/Cargo.toml) |
| sidecar 版本 | `1.21.0`，**跟 zed 钉版本走，不跟应用版本走** | `sidecar/zed-agent-acp/Cargo.toml` 的 `version`；CLAUDE.md 规则 11 |
| 自报版本 | `zed-agent-acp --version` → `zed-agent-acp 1.21.0 (zed @ d9e1c02…)`（commit 由 `build.rs` 从 pins 读出）；`initialize` 回的 `agentInfo` 是 `zed-agent-acp` + 同一个版本号 | `src/main.rs`、`build.rs`、`src/session.rs` 的 `initialize_response` |
| ACP crate | crates.io **`agent-client-protocol =2.0.0` + `unstable`**，与 zed 钉版本声明的一致（规则 10）；主进程 `rust/` 用的是 git rev 2.1.0，两边编译期无交集，线上都说 ACP v1 | [`research.md`](research.md) § 2 |
| Rust | 1.98.1（`rust-version = "1.98"`，edition 2024） | `rust-toolchain.toml` |
| 许可证 | GPL-3.0-or-later（复制 / 转写的文件逐个带 `Derived from zed-industries/zed … @ d9e1c02…` 头，`NOTICE` 双向核对） | CLAUDE.md 规则 5；`scripts/validate.ps1` |

**版本门**：`scripts/validate.ps1` 核对 sidecar `version` = pins 里 zed 的 `version` = `vendor/upstream/zed/crates/zed/Cargo.toml` 的 version（外加应用侧 `pubspec.yaml` = `rust/Cargo.toml`）。发应用版本**不动** sidecar：改 sidecar 的 `version` 一行就是 176 MB 二进制全量重链（R8 实测 14 分 16 秒），不改时 cargo 判 fresh（8.2 秒）；改 `Cargo.toml` 里的注释不触发重编（9.5 秒，fingerprint 认的是 manifest 的解析结果）。

### 1.1 换 zed 钉版本的清单

换钉版本 = 改规则 4 的钉版本，整个依赖闭包都要重编，按下面的顺序做，漏一步多半要到冷编译半小时后才报出来：

1. 改 `pins/upstream.json` zed 条目的 `commit` **与** `version`（规则 4、规则 11）；
2. 改 `docs/research.md` 对应段（§ 1 的 crate 表、§ 2 的 acp 版本、§ 6 的接入点与行号）；
3. `scripts/fetch-upstream.ps1`，再 `-Check` 全绿；
4. `sidecar/zed-agent-acp/Cargo.toml`：`version` 改成新 zed 的 version；`agent-client-protocol` 跟新 zed 根 manifest 声明的版本与特性走（规则 10，不开 `unstable_protocol_v2`）；依赖清单对照新 `crates/eval_cli/Cargo.toml`；`[patch.crates-io]` 与 `[profile]` 对照新 zed 根 manifest 重抄（patch 与 profile 不跨 workspace 继承）；
5. `Cargo.lock` 以新 zed 的 `Cargo.lock` 为种子重新生成 —— 让 cargo 自己解会配出编不过的组合（R7 实测坑 3，见 § 2.7）；
6. 复制 / 转写来的文件（`src/headless.rs`、`src/session.rs`、`src/translate.rs`、`build.rs`、`.cargo/config.toml`、`rust/acp-core/assets/zed-icon.svg`）逐个对照上游 diff 更新，并把文件头的 `@ <commit>` 与 `NOTICE` 一起改（规则 5）；
7. 冷编译 → `build-sidecar.ps1 -Clippy` → `-Selftest` → `acp-smoke run --agent zed` 一轮 → 应用内整条生命周期（新会话 / 终端 / 取消 / 关闭重开 `session/load` / 删除），口径同 R7 验收 3、4；
8. `scripts/validate.ps1` 全绿；打包走 `scripts/package.ps1` + `verify-package.ps1`（后者会核 `--version` 里的 zed 版本与 commit）。

新 zed 若把 `agent-client-protocol` 升到 ≥ 2.1.0，§ 4.1 第 1 条（`plan_update` / `compaction_update` 发不出去）就有机会解掉，届时顺带复议。

## 2. Zed agent 的 sidecar 化方案

### 2.1 为什么只能是独立进程

- **gpui 进不了主进程**（CLAUDE.md 规则 5）：gpui 的无头 `run()` 在 Windows 上仍自己跑 Win32 `GetMessageW` 循环（macOS 上是 `CFRunLoopRun()`），与 Flutter runner 抢同一个线程；而 `crates/agent` 的每个状态都是 `gpui::Entity`、每个异步都是 `gpui::Task`，耦合是结构性的，拆不出无 gpui 的子集（[`research.md`](research.md) § 1.2 / § 1.3）。
- **Zed 内置 agent 没有 ACP 服务端**：全仓库没有 `AgentSideConnection`，`NativeAgentConnection` 只是进程内 `acp_thread::AgentConnection` trait 的实现。所以「agent 那一侧的 ACP」要我们自己写，这就是 sidecar 的主体。
- 结果：主程序把它当成普通的 `custom` 型 agent 经 stdio 拉起，走和其他五个 agent **完全相同**的路；主进程依赖闭包里没有 gpui（`validate.ps1` 用 `cargo tree -p acp_bridge` 守着）。

### 2.2 工程形态

`sidecar/zed-agent-acp/` 是**独立的 cargo workspace**（不在 `rust/` 那个 workspace 里），path 依赖指向 `vendor/upstream/zed/crates/*`。zed 那些 crate 的 `xxx.workspace = true` 仍按它们所在的 zed workspace 解析，所以跨 workspace 的 path 依赖成立；但 `[patch.crates-io]` 与 `[profile]` 不跨 workspace 继承，按 zed 根 manifest 抄了必要的部分（不抄 patch 会拿到 crates.io 的 `tree-sitter-language`，两份实例的 grammar 类型对不上；不抄 profile 约 400 个 crate 会被编两遍）。

| 文件 | 作用 | 来源 |
|---|---|---|
| `Cargo.toml` | 依赖清单（照 eval_cli）、patch、profile；`unsafe_code = "deny"`（规则 6） | 本项目 |
| `Cargo.lock` | 以 `vendor/upstream/zed/Cargo.lock` 为种子 | 见 § 2.7 坑 3 |
| `.cargo/config.toml` | Windows 上只留 `windows_slim_errors` + `+crt-static` 两条 rustflags | Derived from zed `.cargo/config.toml` |
| `build.rs` | 注入 `ZED_PKG_VERSION`（读 vendor 的 zed 版本）与 `ZED_PINNED_COMMIT`（读 pins） | Derived from zed `crates/eval_cli/build.rs` |
| `src/main.rs` | 入口：`--acp`（默认）/ `--selftest` / `--version` / `--help`；路径开关 `--user-data-dir` / `--zed-settings` | 本项目 |
| `src/headless.rs` | 无头引导（SettingsStore、HTTP client、`Client::production`、`LanguageRegistry`、`language_models`、`prompt_store`、`terminal_view`、`agent_ui`…） | **复制** from zed `crates/eval_cli/src/headless.rs`，四处改动列在文件头（其一是去掉 `languages::init`，见 § 4.1） |
| `src/bridge.rs` | stdio 上的 ACP 传输 +「tokio 世界 ↔ gpui 世界」的两条单向通道 | 本项目 |
| `src/session.rs` | 能力声明、会话表、生命周期命令、一轮 prompt 的事件流、权限与 elicitation 反向请求、模型 config option | 参考转写 zed `crates/eval_cli/src/main.rs` 的引导顺序，其余本项目 |
| `src/translate.rs` | `ThreadEvent` → `session/update`；权限选项摊平与去重；终端 `_meta` 三键 | 参考转写 zed `crates/agent/src/agent.rs` 的 `handle_thread_events` |
| `src/meta_keys.rs` | sidecar 侧 `_meta` 键的唯一出处（与 `rust/acp-core/src/meta_keys.rs` 是同一份清单的两个副本，`validate.ps1` 同一条规则核对） | 本项目 |

### 2.3 线程模型（`src/bridge.rs`）

gpui 的 `App` 只活在主线程且不是 `Send`，ACP SDK 的 handler 却必须 `Send`，所以两边各占一条路：

- **入站**：传输跑在一条专用 OS 线程上（`futures::executor::block_on`，stdin / stdout 用 `blocking::Unblock` 包，不要 tokio reactor）。handler 只把 `(请求, Responder)` 塞进 mpsc 就返回，绝不在 handler 里 await 业务（会卡住 SDK 的 dispatch 循环）；gpui 前台的 dispatcher 取出来**每条各 spawn 一个前台任务**，所以一次长 `session/prompt` 挡不住随后的 `session/cancel`。
- **出站**：`session/update` 通知、`session/request_permission` / `elicitation/create` 反向请求由 gpui 侧直接持有的 `ConnectionTo<Client>` 发（内部是 mpsc sender，`Send` 且同步）。
- **引导不做惰性**：`warm_up()` 在 dispatcher 收第一条消息**之前**跑一次（读 Zed settings、给所有 provider 跑 `authenticate`、建 `NativeAgent`）。惰性版本里两条并发请求会各建一个 `NativeAgent`、后者覆盖前者（R7 自查抓到）。代价是 `initialize` 往返多一两秒（`--selftest` 实测整个引导 2.1 s）。
- 除 stdout 之外的一切输出走 stderr（`RUST_LOG` 未设时只留 warn 以上）。

### 2.4 协议映射

| ACP | sidecar 里怎么落 |
|---|---|
| `initialize` | 固定能力：`loadSession: true`；`promptCapabilities {image: true, audio: false, embeddedContext: true}`；`sessionCapabilities {list, delete, resume, close}`（不支持 `fork`、`additionalDirectories`）；`authMethods: []`；`mcpCapabilities` 全 false；协议版本取 `min(客户端要的, V1)` |
| `authenticate` | 不做 ACP 层认证：模型密钥沿用 Zed 的 `settings.json` / 环境变量 / 系统凭据（所有者裁定 2026-09-15） |
| `session/new` | `Project::local`（`init_worktree_trust: false`，客户端已替用户选了目录）+ `create_worktree(cwd)` 等扫描完 + `NativeAgentConnection::new_session`；回一个 config option：`select`，id `model`，值是 `provider/model` |
| `session/load` / `session/resume` | 同一条路：`NativeAgentConnection::load_session` 打开 `threads.db` 里的线程；load 再走 `Thread::replay` 重放历史（与实时共用同一套翻译，前端投影不分两条路），resume 不重放 |
| `session/list` | 读 `ThreadStore`，按 cwd 过滤（线程的 folder paths 里含请求的 cwd 就算命中）；每次**强制重扫**，空表再扫一次（上游会吞读错误，见 § 4.2） |
| `session/prompt` | `Thread::send` 得到 `ThreadEvent` 流，自己消费并翻成 `session/update`（见 § 2.5）；`Stop` → `PromptResponse` |
| `session/cancel` | `Thread::cancel` |
| `session/close` | 先 cancel 并**等**取消完成，再在同一次 `cx.update` 里摘表并等 `AcpThread` 真被释放（`release_and_wait`，上限 5 s） |
| `session/delete` | close 的全部 + `delete_thread`，之后每轮「删 → 等 200 ms → 重读 → 核对」，最多 3 次，仍在就如实报错 |
| `session/set_config_option` | 只改这条线程的模型（`thread.set_model`），**不**像 Zed 的模型选择器那样写回 Zed 的 settings.json（规则 7） |
| `session/set_mode` | 不声明 modes，任何 mode id 都报无效 |

### 2.5 一轮 prompt 的事件流

与 Zed 自己的路子有一处**刻意的不同**：Zed 走 `NativeAgentConnection::prompt`，把事件写进进程内的 `AcpThread` 实体供它的 UI 渲染；我们要把同一批事件**发到线上**，而 `handle_thread_events` 是 crate 私有的、一份事件流也喂不了两个消费者，所以直接拿 `Entity<Thread>` 调 `Thread::send` / `Thread::replay` 自己消费。`AcpThread` 仍要持有（终端落点、`session_id`、`available_commands` 事件挂在它上面），但它的转录不再被填充。这条取舍的代价见 § 4.1 第 3 条。

| `ThreadEvent` | 线上 |
|---|---|
| `UserMessage` / `AgentText` / `AgentThinking` | 对应的 `*_chunk` |
| `ToolCall` / `ToolCallUpdate` | `tool_call` / `tool_call_update`；diff 与终端见下 |
| `ToolCallAuthorization` | `session/request_permission`；选项按 allow 在前、deny 在后摊平，**按 `optionId` 去重**；拿不到选择（取消 / 出错 / 选了不存在的 id）时按「拒绝这一次」回，绝不丢 responder |
| `ToolCallAuthorizationResolved` | 不发（线上那张卡由权限请求的响应收尾） |
| `Elicitation` | `elicitation/create`（form 模式） |
| `SubagentSpawned` | 只记日志、不投影（Zed 的子代理是另一条会话；前端子代理卡只认 [`design.md`](design.md) § 4 清单里的键，没有 Zed 的） |
| `Retry` | 只记日志 |
| `ContextCompaction` / `ContextCompactionUpdate` | 不发（§ 4.1 第 1 条） |
| `Stop` | `PromptResponse.stopReason` |

- **终端**：Zed 的终端在 agent 进程内跑（`NativeThreadEnvironment` 用 `terminal` crate），客户端没有句柄，不能走 `terminal/*`。按 `design.md` § 4 的「终端 provider 通道」发 `_meta.terminal_info {terminal_id, cwd}` / `terminal_output {terminal_id, data}` / `terminal_exit {terminal_id, exit_code}` 三键 —— 正是 Zed 作为客户端时读的三键，前端按键存在处理、不按 agent 名判。输出是流式增量（差分前先 `trim_end()` 去掉 PTY 网格的尾部空行），按 `terminal_id` 去重，一个终端只起一个泵。
- **diff**：等工具调用 `status` 变成 `completed` / `failed` 时再读一次 diff 发终稿，路径拼成绝对路径（客户端按绝对路径在文件面板里定位）。
- **命令菜单**：`AcpThread` 的 `AvailableCommandsUpdated` 照常转成 `available_commands_update`（R7 实测是 `[compact]`）。

### 2.6 数据：配置共用、数据隔离

sidecar 的两个路径开关（都必须在任何人读 `paths::*` 之前处理，`set_custom_data_dir` 之后再调会 panic）：

- `--zed-settings <file>`：**只读**沿用本机 Zed 的 `settings.json`（模型、密钥、MCP server、`tool_permissions` 等），读不到按默认值继续；
- `--user-data-dir <dir>`：把 `threads.db` / `db/` / `prompts/` / logs 整体挪走。

主程序默认两个都传（§ 3.2），于是 sidecar 的会话库在 `%APPDATA%\AcpAgentClient\zed-agent\`，与本机 Zed 隔开。依据是 R7 实测：与**运行中的** Zed 共用 `threads.db` 时，Zed 那边保存线程会报 `Sqlite call failed with code 5 … database is locked`，代价落在用户的编辑器上（规则 7）。隔离的代价：两边会话列表不互通。要改回「全共用」只需在 `rust/acp-core/src/builtin.rs` 里去掉 `--user-data-dir`。这条裁定仍标着「待所有者确认」（[`BACKLOG-ZED.md`](../rounds/BACKLOG-ZED.md)「待所有者确认的裁定」）。

### 2.7 构建（`scripts/build-sidecar.ps1`）

```
powershell -File scripts/build-sidecar.ps1              # release，产物复制到 build/sidecar/zed-agent-acp.exe
powershell -File scripts/build-sidecar.ps1 -Debug       # debug
powershell -File scripts/build-sidecar.ps1 -Check       # 只 cargo check（改代码后最快的回路）
powershell -File scripts/build-sidecar.ps1 -Clippy      # clippy -D warnings（validate.ps1 不跑 sidecar，太慢）
powershell -File scripts/build-sidecar.ps1 -Selftest    # 构建后跑一次 --selftest（数据目录落 build/sidecar/selftest-data）
```

- 不能从仓库根 `cargo build --manifest-path …`：`.cargo/config.toml` 只在工作目录位于 sidecar 之内时被读到，脚本先切目录；`wasmtime` 的 build.rs 要 `cmake`，脚本在 VS 2022 BuildTools 里找；`CARGO_TARGET_DIR` 与主程序分开（`D:\cargo-target\AcpAgentClient-sidecar`），两边 rustflags 与 profile 不同，共用会互相冲掉缓存。
- **R7 实测数字**：依赖闭包 debug 约 730 / release 约 910 个 crate；冷编译 debug / release 各约 50 分钟（release 依赖 ~35 min + 本 crate 连链接 16.5 min，`lto = "thin"` + `codegen-units = 1`）；依赖齐了之后改自己代码 40 s（debug）；target 目录约 56 GB；产物 debug 276 MB / **release 176.7 MB**。
- **冷编译踩过的四个坑**（都已固化在脚本或 manifest 里）：
  1. `wasmtime` 的 build.rs 找不到 `cmake` → 脚本按已知位置找；
  2. `languages` crate 唯一地依赖 `pet`，`pet` 打开 `msvc_spectre_libs` 的 `error` 特性，本机 VS 没装「Spectre 缓解库」组件 → build.rs panic → **去掉了 `languages` 依赖**（§ 4.1 第 2 条，[`BACKLOG-ZED.md`](../rounds/BACKLOG-ZED.md)「构建与打包」）；
  3. cargo 新解析出来的锁把 `merman` 0.8.0-alpha.5 与 `merman-render` 0.8.0-alpha.6 配在一起、编不过 → 以 zed 的 `Cargo.lock` 为种子；
  4. debug 构建下 `util::fs_embed!` 不内嵌资源、运行时从「可执行文件向上第一个带 `.git` 的祖先」读 `assets/`，而产物在仓库之外 → `settings/default.json` panic → `util` 打开 `debug-embed`。
- `scripts/validate.ps1` **不**编译也不测试 sidecar，只对 `sidecar/` 扫 `unsafe`、`_meta` 键、派生文件头，并跑版本门（§ 1）。sidecar 自己的单测（`translate` 的终端增量差分、权限选项摊平与去重、`_meta` 形状）`build-sidecar.ps1` 没有开关，要在 `sidecar/zed-agent-acp/` 里带同一个 `CARGO_TARGET_DIR` 手动 `cargo test`。

### 2.8 进程生命周期

sidecar 由主程序按 stdio 拉起。stdin 关闭（主程序退出或 `agent_disconnect`）→ `connect_with` 的 `main_fn` 等到 `incoming_closed()` 返回 → 传输结束 → handler 连同 mpsc sender 被丢弃 → dispatcher 循环退出 → `cx.quit()`。那一等不能省：传输关闭不会自动取消 `main_fn`，只等 shutdown 信号会成环、sidecar 成孤儿进程（2026-09-17 修过一次）。主程序那侧与其他 agent 一样：关 stdin、等 3 s、再杀进程树。

## 3. 本客户端（AAC）与 Zed agent 的集成方案

一句话：**核心在内存里合成一条内置的 `custom` 型 agent 条目，前端没有任何 Zed 特判**，只读通用的 `builtin` / `name` / `iconSvg` 字段。

### 3.1 内置条目（`rust/acp-core/src/builtin.rs`）

- 定义全在 Rust 代码里，没有 JSON 或 registry 文件：id `zed`、显示名 `Zed Agent`、可执行文件 `zed-agent-acp(.exe)`、图标 `include_str!("../assets/zed-icon.svg")`（来自 zed `assets/icons/ai_zed.svg @ d9e1c02`，只把填充色改成 `currentColor`）。同一个文件里另有一条内置条目 `dsh-acp-interactive`。
- 形状：`AgentServer::Custom { path: <sidecar 绝对路径>, args, env: {}, extra: { builtin: true, name: "Zed Agent", iconSvg } }`；`extra` 是 `#[serde(flatten)]`，这三个键与 `type` / `command` 平级。它们是**设置条目的字段，不是 ACP `_meta`**，不会发给任何 agent。
- **不落盘**，每次读时并进来：`agent_settings_get`、`registry_list`、`agent_connect`（`settings.json` 里没有这个 id 时回落到内置条目）。合并只补缺：用户在 `settings.json` 里自己写了 `zed` 条目时以用户的为准。
- 与 registry 安装的 agent 的区别：没有安装步骤、没有 `agents/<id>/install.json`、不需要 Node；`registry_list` 里是 `distribution: "custom"`、`installed: null`、`builtin: true`；**不可删**（`agent_settings_remove` 拒绝）、**不可编辑**（`agent_settings_set` 经 `builtin::rejects_settings_write` 拒绝，用户自己手写过同名条目时照常可编辑）。设置页（画板 70）与 registry 条目（画板 51）的 Remove / 编辑按钮对内置条目置灰。设置页的 custom 行按 id 显示，所以那里写的是 `zed` 而不是 `Zed Agent`（`test/ui/settings_builtin_test.dart` 断言了这一点）；新建会话弹层、侧栏等处取 `name`。

### 3.2 拉起方式

| 项 | 值 |
|---|---|
| 可执行文件定位（`builtin::sidecar_path()`，每次调用现查、不缓存） | ① 环境变量 `ACP_ZED_SIDECAR`（开发用覆盖；设了就必须指向存在的文件，否则视为没有，**不再**回落到 ②）；② 应用可执行文件同目录下的 `zed-agent-acp.exe`。没有别的回落（不查 PATH、不查开发目录） |
| 参数 | 总是 `--user-data-dir <本应用数据目录>/zed-agent`；Zed 的 `settings.json` 存在时再加 `--zed-settings <它的路径>`（Windows `%APPDATA%\Zed\settings.json`，其他平台 `$XDG_CONFIG_HOME/zed/settings.json` 或 `~/.config/zed/settings.json`，见 `rust/settings/src/zed_import.rs`） |
| 环境变量 | 不额外设任何变量（没有 `ZED_*`、没有 release channel），子进程继承主程序环境；sidecar 里的 `ZED_PKG_VERSION` / `ZED_PINNED_COMMIT` 是**编译期**值 |
| 工作目录 | 与其他 agent 一样，取首个会话的项目目录 |
| 退出 | 与其他 agent 一样：关 stdin → 等 3 s → 杀进程树 |

**sidecar 不在时**：条目根本不进列表（`agents_at(None, …)` 什么都不插；单测 `missing_sidecar_is_not_listed`），前端自然看不到 Zed Agent，其余 agent 照常；`agent_connect("zed")` 报 `agent \`zed\` is not in settings.json agent_servers`；`is_builtin` 与拒写都失效，用户手写的 `zed` 条目回到普通可编辑 / 可删的条目。核心启动时写进日志的第一行会带 `sidecar=<路径|none>`，装机报障先看这一处。

### 3.3 用户数据（规则 7）

- 客户端**只读** Zed 的 `settings.json`，三处：建条目时判存在、`registry_list.paths.zedSettingsPath` 展示路径、「从 Zed 导入」动作（只读 `agent_servers` 段，只写本客户端自己的 `settings.json`，临时文件 + rename）。
- 客户端**从不打开** `threads.db`；它归 sidecar，且已隔离到 `%APPDATA%\AcpAgentClient\zed-agent\`（§ 2.6）。卸载器不动 `%APPDATA%`，这个目录卸载后保留。
- 所有自检路径（`build-sidecar.ps1 -Selftest`、`verify-package.ps1` 的 `--selftest`）都显式传 `--user-data-dir`，不会碰到本机 Zed 的数据目录。

### 3.4 前端与 `_meta`

- `lib/` 里没有任何按 `'zed'` 判断的代码（规则 2）。前端用到的只有：`builtin`（`lib/projection/registry.dart`、`registry_entry.dart`、`settings_page.dart`）、`name`（`lib/app/agents_state.dart` 取显示名）、`iconSvg`（同文件）。
- 核心里 Zed 专属的代码只有 `builtin.rs`；另一处 agent 专属是 Cursor 的 `parameterizedModelPicker`，与 Zed 无关。
- sidecar 发出的 `_meta` 只有终端三键 `terminal_info` / `terminal_output` / `terminal_exit`（字段 `terminal_id`），都在 [`design.md`](design.md) § 4 清单里；前端按键存在处理。客户端发给 sidecar 的 `_meta` 与发给其他 agent 的完全相同。

### 3.5 构建与打包

| 环节 | 与 sidecar 的关系 |
|---|---|
| `scripts/build-sidecar.ps1` | 构建 sidecar，产物复制到 `build/sidecar/zed-agent-acp.exe`（`build/` 不入库） |
| `windows/CMakeLists.txt` | install 规则把 `build/sidecar/zed-agent-acp.exe` 放到 runner 旁；**install 时**才判存在，缺了只打一行状态、不报错；CMake 从不构建 sidecar |
| `scripts/build.ps1` | 不管 sidecar，`flutter build windows` 时 CMake 规则顺带捡起 `build/sidecar/` 里现成的那份 |
| `scripts/package.ps1` | 不构建 sidecar；总是出一个 `-nosidecar.zip`（打包时把 exe 暂时挪开），payload 里有 sidecar 时才出完整 zip；安装器（Inno Setup）打整个 payload，有 sidecar 就带上；缺 sidecar 打一行 NOTE |
| `scripts/verify-package.ps1` | 实际上**要求**有 sidecar：完整 zip 里要有 `zed-agent-acp.exe` / `LICENSE` / `NOTICE`；日志行的 `sidecar=` 要指向随包那份；slim zip 里不能有；`--version` 要含钉的 zed 版本与 commit；跑一次 `--selftest` |
| `NOTICE` | Zed 的 GPL 段列出 sidecar 的派生文件与二进制的许可说明；`validate.ps1` 双向核对「带 Derived from 头的文件 ⇔ NOTICE 所列」并核对钉的 commit |

所以：**先** `build-sidecar.ps1`，**再** `build.ps1` / `package.ps1`；顺序反了产物里就没有 Zed Agent，而且不会报错（`verify-package.ps1` 会拦下）。

### 3.6 测试与实跑

- Rust 单测：`builtin.rs`（sidecar 缺失不列出、条目形状含隔离数据目录、`--zed-settings` 只在文件存在时传、用户条目优先、拒写真值表）；`zed_import.rs`（JSONC 与不覆盖导入）。`rust/acp-core/tests/` 里没有拉起 sidecar 的用例。
- Dart 单测全用假 core，不拉 sidecar：`test/app/registry_wiring_test.dart`（显示名、`builtin` 透传）、`test/ui/settings_builtin_test.dart`（内置行没有编辑 / Remove 回调，R7 审查后改成建真的 `SettingsPage` 点真按钮）、`test/ui/agent_logo_test.dart`（内置图标到达新会话选择器、`zed-icon.svg` 可解析且带来源标注）。
- 实跑：`acp-smoke run --agent zed` 不带 `--command` 时回落内置条目（开发期配 `ACP_ZED_SIDECAR` 指向 target 目录里的产物）；Flutter 无头口子 `ACP_R6_AGENT=zed` 跑整条生命周期（R7 验收 4）；`lib/app/smoke.dart`（`build.ps1 -Smoke`）只做 ping，不拉 agent。

## 4. 已知上游限制

按所有者裁定 2026-09-23，**出在上游或协议本身的问题不进 BACKLOG**，本节就是它们的去处。分三类：4.1 是用户看得见的功能缺口；4.2 是已在 sidecar 里绕过去的上游行为（改 sidecar 或换钉版本时要逐条复核，别把绕法改掉）；4.3 不是上游问题，是 sidecar 自己的取舍，列在这里是为了和前两类分清。

### 4.1 仍在影响功能的

| # | 限制 | 用户看到的 | 根因（上游） | 出路 |
|---|---|---|---|---|
| 1 | **上下文压缩投影不出去** | Zed agent 压缩上下文时界面上没有压缩卡（画板 33） | zed 钉版本写死 `agent-client-protocol =2.0.0`，它的 `unstable` 伞里没有 `unstable_session_compaction`（2.1.0 才有），编不出 `compaction_update`；单独改特性集撞规则 10。同理也没有 `unstable_plan_operations`，但 `ThreadEvent` 本来就没有计划类事件，实际缺的只是压缩 | 等 zed 升 acp ≥ 2.1.0 后随换钉版本复议（§ 1.1）。原 BACKLOG X 档，2026-09-23 关闭 |
| 2 | **`languages` crate 带不进来** | 读超过 16 KB 的文件又没给行号时，`read_file` 只回**前 1 KB 原文**，而不是带行号的文件大纲（`vendor/upstream/zed/crates/agent/src/outline.rs`，`AUTO_OUTLINE_SIZE = 16384`）；跳转类工具退化成纯文本。编辑、终端、grep、权限不受影响 | `languages` 唯一地依赖 `pet`，`pet` 打开 `msvc_spectre_libs` 的 `error` 特性，构建机没装 VS「Spectre 缓解库」组件时 build.rs 直接 panic | 构建环境问题，可在我们这侧解，修法见 [`BACKLOG-ZED.md`](../rounds/BACKLOG-ZED.md)「构建与打包」第 1 条（当前不修） |
| 3 | **斜杠命令不分流** | `/` 菜单里看得到 `compact`，点了只是发一条普通消息；MCP prompt 与 skill 同理 | Zed 的斜杠命令分流在 `NativeAgentConnection::prompt` 里，而把事件翻给 Zed UI 的 `handle_thread_events` 是 crate 私有的，sidecar 只能绕开 `prompt` 直接消费 `Thread::send`（§ 2.5） | 复制 `agent.rs` 的 `Command::parse` 那一段，或等上游公开 `handle_thread_events`。记在 [`BACKLOG-ZED.md`](../rounds/BACKLOG-ZED.md)「功能缺口」（当前不修） |
| 4 | **子代理看不见** | Zed agent 开的子代理在界面上完全没有，只进日志 | Zed 的子代理是**另一条会话**，事件不经过本轮的流；画板 24 的子代理卡只认 `design.md` § 4 清单里的 `_meta` 键，清单里没有 Zed 的 | 给 § 4 加键并进所有者裁定。记在 [`BACKLOG-ZED.md`](../rounds/BACKLOG-ZED.md)「功能缺口」（当前不修） |
| 5 | **权限没有「只对这条命令永久允许」** | 权限卡上只出现较宽的那一档「永久允许」 | Zed 的 pattern 型下拉让多个 choice 共用一个 `optionId`、靠 Zed UI 的勾选框区分范围；ACP v1 的 `session/request_permission` 只有一维选项表，线上只有 `optionId` 能回指 | sidecar 按 `optionId` 去重、只留第一次出现的那个 —— 否则用户点窄范围、实际生效的是宽范围。要完整投影得协议支持带范围的选项 |
| 6 | **不能发音频** | 给 Zed agent 的消息里不会带音频块 | Zed 把音频内容块降级成 `[audio]` 占位文本 | `initialize` 不声明 `audio`，免得前端以为能发 |
| 7 | **与本机 Zed 的会话列表不互通** | Zed 里建的线程在本客户端看不到，反之亦然 | 两个进程同时写同一个 `threads.db` 会让**运行中的 Zed** 保存线程失败（`database is locked`），上游没有跨进程共享的机制 | 已按「配置共用、数据隔离」落地（§ 2.6），裁定待所有者确认（[`BACKLOG-ZED.md`](../rounds/BACKLOG-ZED.md)） |
| 8 | **读会话库失败时报不出真错误** | 偶发时会话列表会短暂像是空的（R7 实测 6 次里见过 1 次） | `ThreadStore::spawn_reload` 连库或读表失败时静默 `return`（`let Ok(..) else { return }`），「读失败」和「真没有会话」外面长得一样 | sidecar 每次强制重扫、空表再扫一次，已滤掉偶发失败；真错误仍拿不到，要等上游把错误露出来。原 BACKLOG X 档，2026-09-23 关闭 |
| 9 | **终端输出偶尔重复一段** | 交互式程序用 `\r` 回改同一行或清屏时，终端卡里可能重复出现一段输出 | `acp_thread::Terminal` 只给**全量快照**、没有增量事件；超过 `output_byte_limit` 时 Zed 从**尾部**截断、保留开头（与核心按规范截头的做法相反） | sidecar 每 100 ms 取一次快照差成增量；前缀不成立时找最长重叠，完全对不上就整份补发（前端缓冲是纯追加的，宁可重复不能丢） |

### 4.2 已在 sidecar 里适配的上游行为

改 sidecar 或换 zed 钉版本时逐条复核；每条都是实跑或审查抓出来过的：

1. **终端内容挂在 `UpdateFields` 里**：Zed 的 terminal 工具把 `ToolCallContent::Terminal` 放进 `ToolCallUpdate::UpdateFields`，不走 `UpdateTerminal`。只处理后者，前端会拿到一张没有数据源的空终端卡 → 两条路径都找 `Terminal` 内容块，按 `terminal_id` 去重后起泵。
2. **`UpdateDiff` 在编辑开始时就到**，那时 buffer 还空，`oldText` / `newText` 都是空串 → 记下 diff 实体，等工具调用完成或失败时再读一次发终稿；worktree 相对路径拼成绝对路径。
3. **`get_content()` 带着 PTY 网格末尾的空行** → 差分前先 `trim_end()`，否则第一帧是一串空行、之后每帧整份重发。
4. **取消与释放都会触发一次异步保存**，能把刚删掉的线程写回 `threads.db`（删完又冒出来）→ `session/delete` 改成「删 → 等 200 ms → 重读 → 核对」最多 3 次，没有立刻返回成功的路径。
5. **gpui 的 `observe_release` 只在 `App::update` 结束时的 `flush_effects` 里跑**，`Entity` 的 drop 只是入队 → 挂订阅、`drop(entry)`、摘表必须放进**同一次** `cx.update`；事件泵还持有 `Rc` 时每 50 ms 空跑一次 `cx.update` 把 effect 冲掉（光挂 background timer 等不到）。
6. **`NativeAgent` 惰性初始化有并发窗口** → `warm_up()` 在 dispatcher 收第一条消息之前跑完。
7. **provider 的 `authenticate` 要和读 settings 分成两次 `cx.update`**，中间让 gpui 冲掉 `SettingsStore` 的全局观察者，否则 provider 注册不全、`available_models` 为空（照 eval CLI）。
8. **数据目录没有覆盖用的环境变量**，只有公开 API `paths::set_custom_data_dir`，而且必须在任何人读 `paths::*` 之前调，之后再调会 panic → `main.rs` 最先处理 `--user-data-dir`。
9. **release channel 缺省是 `dev`**（`ZED_RELEASE_CHANNEL` 没设时的编译期缺省），sidecar 的 `db/` 因此落在 `0-dev` 下 → 只影响目录名，记在 [`BACKLOG-ZED.md`](../rounds/BACKLOG-ZED.md)「构建与打包」（当前不修）。
10. **zed 写死 `agent-client-protocol =2.0.0`** → sidecar 用 crates.io 的 2.0.0，不能与 `rust/` 的 git rev 2.1.0 共用一份 crate（git 源与 crates.io 源同版本也是两份，`acp::` 类型对不上）。
11. **构建侧的四个坑**（§ 2.7）：`wasmtime` 要 cmake；`.cargo/config.toml` 的 `windows_slim_errors` 只在工作目录位于 sidecar 内时生效；cargo 自己解出的锁编不过（以 zed 的 `Cargo.lock` 为种子）；debug 构建的 `fs_embed!` 不内嵌资源（开 `debug-embed`）。
12. **Zed 会对新目录要一次信任确认** → `Project::local` 传 `init_worktree_trust: false`，目录已由客户端替用户选定（画板 41 的项目切换）。

### 4.3 sidecar 自己的取舍（不是上游问题）

- 不声明 `modes`（`session/set_mode` 一律报无效）；模型选择走 config option `model`，改模型只改这一条线程、不写回 Zed 的 settings.json。
- 不支持 `session/fork` 与 `additionalDirectories`（一个会话一个 cwd）；`session/list` 不分页（`nextCursor` 恒为空）。
- `authMethods` 为空，密钥全走 Zed 的配置（所有者裁定 2026-09-15）。
- 客户端发来的 `mcpServers` 不接（`initialize` 里 `mcpCapabilities` 全 false）；Zed 自己 settings.json 里配的 MCP server 照常生效。
- `Retry`（模型调用重试）只记日志、不投影；`ToolCallAuthorizationResolved` 不发（线上那张卡由权限响应收尾）。
- `AcpThread` 实体仍持有、但它的转录不再被填充（§ 2.5）；内存里没有第二份转录，前端是唯一的投影方。

## 5. 与 Zed agent 相关的 backlog

**所有者裁定 2026-09-23：Zed agent 的问题从 `rounds/BACKLOG.md` 整体移到专属台账 [`rounds/BACKLOG-ZED.md`](../rounds/BACKLOG-ZED.md)，当前不修**（不排轮次、不进迭代候选，重启时由所有者从那里点名）。那份现有 9 条：

- **功能缺口 2 条**：斜杠命令发出去只是普通消息（§ 4.1 第 3 条）、子代理不投影（§ 4.1 第 4 条）；
- **构建与打包 2 条**：缺 `languages` crate（§ 4.1 第 2 条，附修法与代价）、数据目录落在 `0-dev` 下（§ 4.2 第 9 条）；
- **工程与文档 4 条**：统筹时新盘点出来的（自检路径上的两条 ERROR、sidecar 单测没有脚本会跑、源码里两处过时注释、`acp-projection.md` § 9.1 缺 Zed 列）；
- **待所有者确认 1 条**：「配置共用、数据隔离」（§ 2.6）。

上游问题照旧不进台账，留在本文 § 4。相关的已关闭条目（`threads.db` 争用、agent 名与图标、压缩投影、`threads.db` 读失败、macOS cargokit、sidecar 体积）在那份末尾有索引，存档本身在 `rounds/BACKLOG-CLOSED.md`。
