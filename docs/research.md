# 研究概要

> 2026-09-11 三轮可行性分析的沉淀。所有数字来自当日 main 分支源码（commit 见 `pins/upstream.json`）。源码在本仓库 `vendor/upstream/`；分析期的临时克隆在 `D:/variFlight_work/_references/`（含已被排除的 codex、pi-web-0.8.9、acp-components，仅历史参考）。改动钉版本时本文相应段落要重核。

## 1. Zed 的 ACP 相关代码

### 1.1 真实的 crate 布局

Zed 当前 main 里没有 `crates/acp`，也没有 `crates/assistant2`（后者早已改名 `agent`）。与 ACP 相关的是：

| crate / 文件 | 行数 | gpui 引用 | 工作区闭包 | 许可证 | 复用结论 |
|---|---|---|---|---|---|
| `crates/acp_thread` | 15,537 | 430 | 91 / 245 | GPL-3.0 | Zed 自己的会话投影模型；本项目走严格 ACP 投影，不需要它；`terminal.rs` 语义转写 |
| `crates/agent_servers` | 6,135 | 190 | 含在上 | GPL-3.0 | `acp.rs` 非测试部分约 2,300 行，转写：initialize、认证、会话控制 |
| `crates/project/src/agent_registry_store.rs` | 677 | 少 | 79 / 245（因在 project 里） | GPL-3.0 | 复制后去 gpui |
| `crates/project/src/agent_server_store.rs` | 2,340 | 少 | 同上 | GPL-3.0 | 复制后去 gpui，删 remote / collab 路径 |
| `crates/agent`（内置 agent） | 87,483 | 1,975 | 128 / 245 | GPL-3.0 | 只能整体 headless 跑，放 sidecar |
| `crates/agent_ui` | 85,869 | 2,369 | 146 / 245 | GPL-3.0 | 弃 |
| `crates/eval_cli` | 小 | 是 | 151 / 245 | GPL-3.0 | sidecar 的 headless 引导范本 |

不含 gpui、可直接 git 依赖的 Zed crate：`node_runtime`（闭包 9）、`http_client`（1）、`reqwest_client`、`paths`（6）、`util`（5）、`sandbox`（2）。`fs`（26，含 gpui）、`settings`（35，含 gpui）不能直接用。

### 1.2 三个硬事实

- **耦合是结构性的。** 每个状态类型都是 `gpui::Entity`，每个异步都是 `gpui::Task`；`fs/read_text_file` 走 `Project::open_buffer` 以读到编辑器未保存内容。
- **许可证。** gpui、util、collections 是 Apache-2.0，其余上表 crate 都是 GPL-3.0-or-later。本项目开源且接受 GPL，因此可以复制。
- **内置 agent 没有 ACP 服务端。** 全仓库没有 `AgentSideConnection`。`NativeAgentConnection` 只是进程内 `acp_thread::AgentConnection` trait 的实现；它用的类型是 `agent_client_protocol::schema::v1`。

### 1.3 gpui 进不了 Tauri 主进程

macOS 的 headless `run()` 仍然调用 `CFRunLoopRun()` 并把前台任务投到 GCD 主队列；Windows 的 headless `run()` 仍然自己跑 Win32 `GetMessageW` 循环。两者都与 Tauri（tao）的事件循环抢同一个线程。凡是需要 gpui 的东西只能放独立进程。

## 2. 官方 rust-sdk v2

- crates.io `agent-client-protocol` 2.1.0（2026-09-04）。v2 重写为 Send 化的 handler：`Client::builder().on_receive_request(|req, responder, cx| ...)`，`ConnectionContext: Send + Sync`，直接跑在 tokio 多线程 runtime 上。
- `AcpAgentConfig` / `AcpAgent` 是自带的子进程启动器（command / args / env / `spawn_process`），并带 `claude_agent()`、`codex()` 预设。
- 角色：Client、Agent、Proxy、Conductor（`agent-client-protocol-conductor` 可把一串代理串成一个上游端点，本项目暂不需要）。
- feature：`unstable` 打开 `unstable_end_turn_token_usage`、`unstable_llm_providers`、`unstable_mcp_over_acp`、`unstable_plan_operations`、`unstable_session_compaction`、`unstable_session_fork`、`unstable_tool_call_name`；`unstable_protocol_v2` 是协议 v2 草案。
- Zed 钉 `=2.0.0` + `unstable`，并且自建了一条 foreground dispatch channel 把 Send 回调桥回 gpui 的 !Send 线程。本项目在 tokio 里不需要这层桥。
- **版本澄清：** 线上协议是 v1（`protocolVersion` 协商），SDK crate 版本 2.x 与协议版本无关；协议 v2 仍是草案。

## 3. 官方 registry

- 仓库结构：根目录 `agent.schema.json`、`registry.schema.json`，每个 agent 一个目录（`agent.json` + `icon.svg`）。CDN `https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json` 是构建产物，结构为 `{version, agents[], extensions[]}`；JetBrains 另有专用索引与 preview 通道。
- 分发类型：`binary`（六个平台 target：darwin/linux/windows × aarch64/x86_64，archive 支持 zip / tar.gz / tgz / tar.bz2 / tbz2 / 裸二进制，可带 sha256）、`npx`（`{package, args, env}`）、`uvx`。
- **收录条件：agent 必须支持 Agent Auth 或 Terminal Auth 之一**，CI 校验 `initialize` 返回的 `authMethods`。
- Zed 的实现：`RegistryAgent` 只有 `Binary` 与 `Npx` 两个变体（不支持 uvx）；registry 拉取 1 小时节流、磁盘缓存、图标另拉；npx 靠 `node_runtime` 下载受管 Node v24.11.0（`MIN_VERSION` 22）；binary 走 `http_client::github_download` 并校验 sha256。设置 schema：`agent_servers: { "<id>": { "type": "registry", env, default_mode, default_config_options, favorite_config_option_values } | { "type": "custom", command: {path, args, env}, ... } }`。

## 4. Zed 客户端的能力声明与 agent 特判

`crates/agent_servers/src/acp.rs` 的 `client_capabilities_for_agent`：

- `fs.readTextFile = true`、`fs.writeTextFile = true`、`terminal = true`、`auth.terminal = true`、`session.configOptions.boolean`、`elicitation.form` 与 `elicitation.url`。
- `_meta`：`terminal_output: true`、`terminal-auth: true`；仅对 Cursor 追加 `PARAMETERIZED_MODEL_PICKER_META_KEY: true`（参数化模型选择器）。
- Gemini：在官方 auth methods 发布前，Zed 自行合成一个 terminal auth 方法（`spawn-gemini-cli`，`_meta.terminal-auth` 携带命令）。本项目不把 Gemini 列为一等 agent，可不做。
- 认证：`session/new` 返回 `AuthRequired` 错误码时映射为登录界面；auth method 为 terminal 类型时构造终端任务；兼容旧版 `_meta.terminal-auth`（`label / command / args / env`）；首选一等 terminal auth。
- 其余：`session/list` 带 cursor 分页；elicitation store；ACP 流量调试日志（`acp_tools` 面板消费）。

## 5. 五个 agent 对客户端的要求

见 `requirements.md` § 必须 第 3 条的表。补充事实：

- claude-agent-acp：子代理 transcript 只在双向能力协商后暴露（JetBrains 用 `_meta.jetbrains.air.capabilities` 信号）。
- codex-acp：TypeScript 实现，内置 codex 二进制；`NO_BROWSER=1` 隐藏 ChatGPT 登录；`CODEX_CONFIG`（JSON 合并）、`MODEL_PROVIDER`、`INITIAL_AGENT_MODE`（read-only / agent / agent-full-access）可经 env 注入，可指向 OpenAI 兼容网关。
- Cursor：registry 条目 `cursor/agent.json`（版本 2026.09.02），Windows 的 cmd 是 `./dist-package\cursor-agent.cmd`，args `["acp"]`；ACP 里宣告 `cursor_login` 方法，但实际期望 CLI 层预先登录。
- pi-acp：自己拉 `pi --mode rpc`；会话映射存 `~/.pi/pi-acp/session-map.json`；MIT。
- dsh-acp-interactive：初始化时读 `clientCapabilities._meta.terminal_output`、`elicitation.form`、`session.configOptions.boolean` 决定公布哪些能力；子代理身份放 `_meta.dsh_subagent`；以 ACP SDK 1.4.0 的稳定 v1 schema 为基线。

## 6. Zed 内置 agent 的接入点（sidecar 依据）

- 类型：`crates/agent/src/{agent.rs, thread.rs}` 都 `use agent_client_protocol::schema::v1 as acp`。
- 事件：`pub enum ThreadEvent { UserMessage, AgentText, AgentThinking, ToolCall(acp::ToolCall), ToolCallUpdate, ToolCallAuthorization, ToolCallAuthorizationResolved, Elicitation, SubagentSpawned, Retry, ContextCompaction, ContextCompactionUpdate, Stop(acp::StopReason) }`（`thread.rs:890`）。`NativeAgentConnection::handle_thread_events`（`agent.rs:2276`）把它们翻成对 `AcpThread` 的方法调用，sidecar 镜像这段翻成线上 `session/update`。
- 公开钩子：`Thread::send` 返回 `mpsc::UnboundedReceiver<Result<ThreadEvent>>`；`NativeAgent::open_thread` 公开；`ToolCallAuthorization` 字段公开（含 `response: oneshot::Sender`）；终端经 `pub trait ThreadEnvironment { fn create_terminal(...) }`。不需要 fork Zed。
- 引导：`crates/eval_cli/src/headless.rs`（140 行）初始化 SettingsStore、theme base、`Client::production`、languages、extension、`language_model(s)`、`prompt_store`、`terminal_view`、`agent_ui`；`main.rs` 746–812 行构建 `Project::local` + `create_worktree` + `NativeAgent::new(ThreadStore, Templates, fs)`。
- 数据：线程库在 `paths::data_dir()/threads/threads.db`，设置读 Zed 自己的 `settings.json`，即与本机 Zed 共用；未发现现成的目录覆盖变量。模型密钥走环境变量（如 `ANTHROPIC_API_KEY`）、系统凭据库或 `openai_compatible` / `anthropic_compatible` 配置。
- 构建：闭包约 150 个 crate；Windows 需 VS C++ 生成工具（含 Spectre 库）、Windows SDK ≥ 10.0.20348、CMake（wasmtime 依赖）；冷编译 30 到 60 分钟。

## 7. 被排除的路线

| 路线 | 排除原因 |
|---|---|
| 把 Zed 的 acp_thread / agent_servers / agent 链接进 Tauri 主进程 | § 1.3 的事件循环冲突；acp_thread 是 Zed 的投影不是线上协议，违反严格 ACP 投影 |
| 参考 Codex 桌面端前端 | 闭源，2026-07 并入 ChatGPT 桌面端；`openai/codex` 只有 CLI / TUI / app-server |
| 复用 pi-web 的文件管理与会话组件 | MIT 但传输层是 pi 私有 RPC；所有者裁定前端全部自研 |
| acp-components / acp-ui / Jockey 等第三方 ACP 客户端与组件库 | 所有者裁定白名单之外一律不引入 |
| 前端跑官方 TypeScript SDK | `typescript-sdk` 不在白名单；协议层落 Rust 核心 |

## 8. 待验证的假设（进首轮任务卡）

- rust-sdk v2 的 `AcpAgent` 在 Windows 上拉起 `.cmd` 包装的 npx agent 时引号与路径处理是否正确（dsh 在 Zed 里踩过）。
- 无系统 Node 时复用 Zed `node_runtime` 下载受管 Node 的路径在中文用户名下是否可用。
- sidecar 与运行中的 Zed 同时打开 `threads.db` 的行为。
- `unstable` 特性集与五个 agent 的对齐（usage、compaction、session fork）。
