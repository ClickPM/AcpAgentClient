# 研究概要

> 2026-09-11 三轮可行性分析的沉淀；§ 9 是 2026-09-12 技术栈调整（Tauri → Flutter）的依据，§ 10 是设计交付链路；设计工具 2026-09-12 由 Claude Design 改为 Figma Make，2026-09-14 改回 Claude Design，§ 10 按现状写。所有数字来自当日 main 分支源码（commit 见 `pins/upstream.json`）。源码在本仓库 `vendor/upstream/`；分析期的临时克隆在 `D:/variFlight_work/_references/`（含已被排除的 codex、pi-web-0.8.9、acp-components，仅历史参考）。改动钉版本时本文相应段落要重核。

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

### 1.3 gpui 进不了主进程

macOS 的 headless `run()` 仍然调用 `CFRunLoopRun()` 并把前台任务投到 GCD 主队列；Windows 的 headless `run()` 仍然自己跑 Win32 `GetMessageW` 循环。两者都与宿主 GUI 框架的事件循环抢同一个线程（Tauri 的 tao 如此，Flutter 的 Windows runner / macOS `NSApplication` 同样如此）。凡是需要 gpui 的东西只能放独立进程。2026-09-12 壳从 Tauri 改为 Flutter，这一结论不变。

## 2. 官方 rust-sdk v2

- crates.io `agent-client-protocol` 2.1.0（2026-09-04）。v2 重写为 Send 化的 handler：`Client::builder().on_receive_request(|req, responder, cx| ...)`，`ConnectionContext: Send + Sync`，直接跑在 tokio 多线程 runtime 上。
- `AcpAgentConfig` / `AcpAgent` 是自带的子进程启动器（command / args / env / `spawn_process`），并带 `claude_agent()`、`codex()` 预设。
- 角色：Client、Agent、Proxy、Conductor（`agent-client-protocol-conductor` 可把一串代理串成一个上游端点，本项目暂不需要）。
- feature：`unstable` 打开 `unstable_end_turn_token_usage`、`unstable_llm_providers`、`unstable_mcp_over_acp`、`unstable_plan_operations`、`unstable_session_compaction`、`unstable_session_fork`、`unstable_tool_call_name`；`unstable_protocol_v2` 是协议 v2 草案。
- **两个 `unstable` 伞不是同一个集合**：类型 crate `agent-client-protocol-schema`（sdk 2.1.0 依赖 `=1.7.0`，对应 JSON Schema v1 发布版本 1.21.0）自己的 `unstable` 还含 `unstable_nes` 与 `unstable_session_notices`，sdk 的 `unstable` **不转发**这两个。后果（`SessionUpdate::Notice` 编译不出、收到即静默丢弃）见 [`acp-projection.md`](acp-projection.md) § 1 与 § 8.1。
- Zed 钉 `=2.0.0` + `unstable`，并且自建了一条 foreground dispatch channel 把 Send 回调桥回 gpui 的 !Send 线程。本项目在 tokio 里不需要这层桥。
- **`sidecar/zed-agent-acp/` 用的是 crates.io 的 `=2.0.0` + `unstable`，和 `rust/` 那边（git rev，2.1.0）不是同一份**（R7）：sidecar 里 `acp::` 类型要和 zed crate 的对得上，而 git 源与 crates.io 源即使版本号相同也是两份 crate；zed 又写死 `=2.0.0`，patch 成 2.1.0 也不满足。这不是改钉版本（规则 4 / 10）——**它就是 Zed 钉版本声明的那一个**，两个进程只经 stdio 上的 ACP v1 通信，编译期毫无交集。代价：2.0.0 的 `unstable` 伞里没有 `unstable_plan_operations` / `unstable_session_compaction`（2.1.0 才有），所以 sidecar 发不出 `plan_update` 与 `compaction_update`（上游限制，见 [`zed-agent.md`](zed-agent.md) § 4.1 第 1 条）。
- sidecar 里那层「Send 的 handler ↔ !Send 的 gpui」桥还是要自己搭（和 Zed 一样），见 `sidecar/zed-agent-acp/src/bridge.rs`。
- **版本澄清：** 线上协议是 v1（`protocolVersion` 协商），SDK crate 版本 2.x 与协议版本无关；协议 v2 仍是草案。

## 3. 官方 registry

- 仓库结构：根目录 `agent.schema.json`、`registry.schema.json`，每个 agent 一个目录（`agent.json` + `icon.svg`）。CDN `https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json` 是构建产物，结构为 `{version, agents[], extensions[]}`；JetBrains 另有专用索引与 preview 通道。
- 分发类型：`binary`（六个平台 target：darwin/linux/windows × aarch64/x86_64，archive 支持 zip / tar.gz / tgz / tar.bz2 / tbz2 / 裸二进制，可带 sha256）、`npx`（`{package, args, env}`）、`uvx`。
- **收录条件：agent 必须支持 Agent Auth 或 Terminal Auth 之一**，CI 校验 `initialize` 返回的 `authMethods`。
- Zed 的实现：`RegistryAgent` 只有 `Binary` 与 `Npx` 两个变体（不支持 uvx）；registry 拉取 1 小时节流、磁盘缓存、图标另拉；npx 靠 `node_runtime` 下载受管 Node v24.11.0（`MIN_VERSION` 22）；binary 走 `http_client::github_download` 并校验 sha256。设置 schema：`agent_servers: { "<id>": { "type": "registry", env, default_mode, default_config_options, favorite_config_option_values } | { "type": "custom", command: "<程序路径>", args, env, default_mode, ... } }`（`custom` 是扁平的：`command` 是字符串，`args` / `env` 在顶层；`crates/settings_content/src/agent.rs` `CustomAgentServerSettings`，R0 审查纠正）。

## 4. Zed 客户端的能力声明与 agent 特判

`crates/agent_servers/src/acp.rs` 的 `client_capabilities_for_agent`：

- `fs.readTextFile = true`、`fs.writeTextFile = true`、`terminal = true`、`auth.terminal = true`、`session.configOptions.boolean`、`elicitation.form` 与 `elicitation.url`。
- `_meta`：`terminal_output: true`、`terminal-auth: true`；仅对 Cursor 追加 `PARAMETERIZED_MODEL_PICKER_META_KEY: true`（参数化模型选择器）。
- Gemini：在官方 auth methods 发布前，Zed 自行合成一个 terminal auth 方法（`spawn-gemini-cli`，`_meta.terminal-auth` 携带命令）。本项目不把 Gemini 列为一等 agent，可不做。
- 认证：`session/new` 返回 `AuthRequired` 错误码时映射为登录界面；auth method 为 terminal 类型时构造终端任务；兼容旧版 `_meta.terminal-auth`（`label / command / args / env`）；首选一等 terminal auth。
- 其余：`session/list` 带 cursor 分页；elicitation store；ACP 流量调试日志（`acp_tools` 面板消费）。

### 4.1 会话回收：后台自动 `session/close`

> 2026-09-23 按钉版本 `d9e1c02` 核对，是 BACKLOG P1「会话菜单的 Resume / Close 没有入口」（所有者裁定暂不处理）的依据，以后做自动 close 直接从这里开工。行号都是这个 commit 的；换钉版本要重核。

Zed 界面上**没有**手动 Resume / Close。一条会话在 agent 侧占的资源，全靠下面这套自动回收放掉（`session/close` 放掉的是 agent 侧**这一条会话**的资源，agent 进程不退：claude-agent-acp 每条会话挂一个 Claude Code 子进程，`teardownSession` 里 `query.close()` 把它关掉；codex-acp 所有会话共用一个 codex 进程，close 只是 `threadUnsubscribe` 卸掉其中一个 thread）。

- **保活名单**：`crates/agent_ui/src/agent_panel.rs:1169` 的 `retained_threads: HashMap<ThreadId, Entity<ConversationView>>`。正在显示的会话不在名单里，切走的会话进名单，会话在后台照跑。
- **触发时机：只在切走会话时。** `set_base_view`（:4268）先调 `retain_running_thread`（:4202），把旧视图放进名单（没内容的空草稿直接丢），再调 `cleanup_retained_threads`（:4232）。没有定时器：后台会话跑完之后不会马上被回收，要等下一次切换。
- **回收条件**（`cleanup_retained_threads`，:4232 起）：
  - 名单里「`ThreadStatus::Idle`（不在生成；这个枚举只有 `Idle` / `Generating` 两个值）」且「`connection.supports_load_session()`」的会话才算候选。视图还没连上 agent 的也算候选。
  - 候选按 `updated_at` 升序排，只留最近的 `MaxIdleRetainedThreads` 条（:152–161，GPUI global，没设时取默认值 **5**），更旧的从名单里删掉。
  - `updated_at`（`conversation_view.rs:293`）：这条会话的 `AcpThread` 每发一个事件就刷成 `Instant::now()`，也就是「最后一次有动静」的时间。
  - **不回收的两类**：在跑的会话；agent 不支持 `loadSession` 的会话（只支持 resume 的 agent，回收后转录就回不来了）。
- **从名单删掉以后，怎样变成 `session/close`**：
  - 名单删掉 → `ConversationView` 及其中的 `AcpThread` 实体被释放 → `crates/agent_servers/src/acp.rs` 的 `register_session`（:1165）在 :1173 挂的 `observe_release` 回调触发。会话表里登记的仍是这个线程实体、且 agent 声明了 `sessionCapabilities.close`（`agent_supports_session_close`，:1215）时，发一次 `CloseSessionRequest`。
  - 请求是 detach 出去的，结果只 `log_err`：失败了不重试，也不提示用户。
  - 同一个 session 还有别的句柄、或还有 load 在途时不发；最后一个句柄释放时恰好发一次（acp.rs 测试里 :4049 / :4062 / :4200 / :4212 / :4282 / :4314 这几处断言）。
  - **易误读**：`ConversationView::close_all_sessions`（`conversation_view.rs:796`；在 `on_release` :857 与 `set_server_state` :910 两处调用）走的是 `AgentConnection::close_session` trait 方法。外部 ACP agent 的 `AcpConnection` **没有**覆盖 `supports_close_session`（默认 false，`crates/acp_thread/src/connection.rs:125`），全仓库只有测试桩实现了它，所以它对外部 agent 是空操作。真正发请求的只有上面那个释放回调。连接状态被替换（出错重置 / 重连）时，旧状态里的线程也是经释放回调被 close 的。
- **切回被回收的会话**：新建一个 `ConversationView`，`conversation_view.rs:1131` 起，agent 支持 `loadSession` 就走 `session/load` 重放历史；不支持 load、支持 resume 就走 `session/resume`（`resumed_without_history`，转录为空）；两个都不支持则报错。名单里还在的会话切回时直接复用视图（`activate_retained_thread`，agent_panel.rs:3268），不发任何请求。
- **对照我们**（`lib/app/session_controller.dart`）：
  - 切会话（`selectSession`）与换项目（`enterWorkspace`）都不 close，会话在 agent 侧一直占着，直到 agent 断开。
  - 切回已关闭会话的路径（`_ensureLoaded`：load 优先、退回 resume）与 Zed 同序。要照搬，缺的只是「切走时回收」这一步：`selectSession` 里按上面的条件回收，复用 `closeSession` 里现成的「先收干净挂起请求、再 `session/close`」。
  - 还有一个取舍待裁定：我们内存里的转录还在，切回时可以 resume 优先（不重放，快，本地折叠等状态也不丢）；Zed 连视图一起丢了，所以只能 load。

### 4.2 回合进行中的发送队列（Queued Messages）

> 2026-09-24 按钉版本 `d9e1c02` 核对，是 round-send-queue（[`rounds/round-send-queue/round-send-queue.md`](../rounds/round-send-queue/round-send-queue.md)）的依据。行号都是这个 commit 的；换钉版本要重核。

**结论：队列完全在客户端，协议一行没加。** ACP v1 一个会话同一时刻只有一个 `session/prompt`，Zed 在回合进行中把用户输入收进本地队列，回合结束再当普通 `session/prompt` 发；「Send Now」= 先 `session/cancel` 当前回合、等它返回、再发。对任何外部 agent 都成立（所有者的截图是 pi ACP）。

- **状态机**：`crates/agent_ui/src/conversation_view/message_queue.rs`（192 行，纯状态，不碰协议）。
  - 队列项 `QueueEntry { id, content: Vec<acp::ContentBlock>, tracked_buffers, steer, editor }`：`content` 是**入队时就解析好**的 ACP 内容块（含 @ 提及）；每项挂一个只读的小编辑器，就是截图里的一行。
  - `ProcessingState` 三态：**AutoProcess**（回合结束自动弹队首发出）；**Paused**（用户手动点停止时进入，`thread_view.rs:1975` 的 `cancel_generation`，否则一停就立刻发下一条、等于停不下来；用户再发任何消息或再入队一条即恢复 AutoProcess）；**AbsorbingCancel**（Send Now / fast-track 是自己发起的 cancel，那次回合结束事件要吞掉，否则会连带把下一条也发出去）。
  - `on_generation_stopped(is_first_editor_focused)`（:149）：用户正在编辑队首那条时不自动发。
  - `can_fast_track`：入队即置 true，fast-track 一次后置 false。
- **发送入口**：`thread_view.rs:1480` 的 `send()`。输入框有字 + 回合进行中 → `queue_message` 入队、不打断（:1499）；输入框为空 + 按 Enter → `try_fast_track`（:1493），刚入过队就把队首立即发出（截图里「Send Now **Enter**」的来历）；空闲时照常发送。另一个快捷键 `SendImmediately` → `interrupt_and_send`（:1813）：pause 队列 → `thread.cancel()` 并 await → `send_impl`。`/compact 做X` 这类内置命令先发命令、余下的「做X」自动入队（:1559）。
- **出队**：`dispatch_queued_entry`（:2256）是自动出队 / fast-track / Send Now 的唯一出口：先 `thread.cancel()`（空闲时是空操作）并 await，再 `send_content`（即一次普通 `session/prompt`）。回合结束时的自动出队挂在 `conversation_view.rs:1704`（Stopped 事件 → `on_generation_stopped` → `dispatch_queued_entry`）。
- **队列条上的操作**：删除 `remove_from_queue`（:2212）；编辑 `move_queued_message_to_main_editor`（:2307，挪回主输入框，主输入框已有字时以 `\n\n` 拼在后面并校正光标）；在队列行上直接打字 / 粘贴也会把它挪回主输入框并带上这次按键（`InputAttempted`，:2163）；主输入框为空时按 ↑ 把队尾拉回来编辑（:2356）；Clear All（:3682）；标题「N Queued Message(s)」可折叠（:3636）。
- **生命周期**：队列只在内存里，挂在线程视图上，重启即丢，不落盘。

### 4.3 Steer（回合中途插话）：研究记录与裁定

> 2026-09-24 调研。**所有者裁定 2026-09-24：不做 ACP 标准协议之外的事——不接各家 agent 的 steer 私有扩展，也不为内置 Zed agent（sidecar）做 steer 适配**；发送队列只用标准的 `session/prompt` / `session/cancel`（§ 4.2）。本节只作记录，ACP v2 或官方把 steer 收进标准之后再议。

「Steer」= 回合还在跑时把新消息**注入当前回合**，agent 在下一个步骤边界（一批工具结果回来之后、下一次调模型之前）看到它并改道，而不是等回合结束另起一轮。

- **Zed 只对自家 agent 做了**：队列项上有 Steer 开关（默认关，`thread_view.rs:4459` 的 `render_queue_steer_button`）。打开时 `sync_queue_flag_to_native_thread`（:2230）在进程内直接设 native `Thread` 的 `end_turn_at_next_boundary`，`crates/agent/src/thread.rs:3092` 看到它就在工具结果之后收轮，队首随即作为下一轮发出。**这是进程内的布尔标志，线上没有对应的 ACP 消息**；外部 agent 在 Zed 里只能「排队等回合结束」或「cancel 掉再发」。zed main（2026-09-23，`4c902c9`）的 `agent_servers` / `acp_thread` 里仍然没有 `steering` 这个词。
- **外部 agent 的现状**（均按本仓库钉版本的源码）：

  | agent | 支持 | 形态 |
  |---|---|---|
  | claude-agent-acp | 是（至迟 0.64.0 / 2026-07 起，之后几版持续修） | 扩展方法 `_session/steering`（`src/acp-agent.ts:454`，示例 `examples/steering.ts`） |
  | codex-acp | 是 | 同一个 `_session/steering`（`src/AcpExtensions.ts:43`），背后是 Codex app-server 的 turn steer |
  | pi-acp | pi 本身有 steering / follow-up 模式，适配层**没有**做成协议能力 | 只暴露斜杠命令 `/steering`、`/follow-up` 切 pi 的模式；README 写明「Queue is implemented client-side」 |
  | dsh-acp-interactive | 否 | — |

- **claude-agent-acp 与 codex-acp 共用的线上约定**（两边注释都称 agreed ACP steering wire protocol）：① agent 在 `initialize` 响应的顶层 `_meta.steering.supported` 声明；② 回合进行中客户端发 `_session/steering { sessionId, prompt }`，可带 `_meta.steering.idleBehavior: "promptRequired"`；③ agent 回 `outcome`：`injected`（已并入当前回合）/ `startedNewTurn`（回合已结束，agent 按旧兜底自己另起一轮）/ `promptRequired`（回合已结束，且请求要求由客户端负责投递，这条没被消费，要改走普通 `session/prompt`）。方法名以 `_` 开头 = ACP 的自定义扩展方法，**不是标准的一部分**。
- **为什么 Zed（和我们）不接**（Zed 这半是推断，没找到官方说明）：
  1. ACP v1 里 `session/prompt` 的请求到响应就是整个回合，中途插进来的用户消息算哪一轮、转录里落在哪、重放时怎么还原，规范都没定义，扩展方法只能各家自己约定。
  2. 标准解在 ACP v2 草案里：`docs/announcements/acp-v2-draft.mdx` 明说为了 queueing 与 steering，prompt 响应改为「已收到」而非回合结束、agent 在实际插入处重放用户消息、新增 `idle` 状态。本项目按规则 10 不开 `unstable_protocol_v2`，要等 v2 定稿、官方 rust-sdk 跟进。
  3. 对我们还有规则 2（`_meta` 只许 `docs/design.md` § 4 的键）与 `docs/requirements.md` 第 1 条（不给任何 agent 做私有通道）。

## 5. 五个 agent 对客户端的要求

见 `requirements.md` § 必须 第 3 条的表。补充事实：

- claude-agent-acp：子代理 transcript 只在双向能力协商后暴露（JetBrains 用 `_meta.jetbrains.air.capabilities` 信号）。
- codex-acp：TypeScript 实现，内置 codex 二进制；`NO_BROWSER=1` 隐藏 ChatGPT 登录；`CODEX_CONFIG`（JSON 合并）、`MODEL_PROVIDER`、`INITIAL_AGENT_MODE`（read-only / agent / agent-full-access）可经 env 注入，可指向 OpenAI 兼容网关。
- Cursor：registry 条目 `cursor/agent.json`（版本 2026.09.02），Windows 的 cmd 是 `./dist-package\cursor-agent.cmd`，args `["acp"]`；ACP 里宣告 `cursor_login` 方法，但实际期望 CLI 层预先登录。
- pi-acp：自己拉 `pi --mode rpc`；会话映射存 `~/.pi/pi-acp/session-map.json`；MIT。
- dsh-acp-interactive：初始化时读 `clientCapabilities._meta.terminal_output`、`elicitation.form`、`session.configOptions.boolean` 决定公布哪些能力；子代理身份放 `_meta.dsh_subagent`；以 ACP SDK 1.4.0 的稳定 v1 schema 为基线。会话日志存 `$DSH_HOME/acp-sessions`（缺省 `~/.dsh/acp-sessions`，其下按会话 cwd 分目录；`DSH_ACP_SESSIONS_ROOT` 可覆盖）；1.3.2 之前缺省是相对 agent 进程工作目录的 `./.sessions`，换项目重连后就找不到前一个进程写下的会话（本项目报障后在上游修掉，钉版本 1.3.2 起生效；旧 `.sessions` 里的会话不搬，规则 7）。它是独立的社区项目，composes 上游 `deepseek-ai/deepseek-harness` 发布的 `@deepseek-ai/dsh-*` 包，**不隶属于也未获 DeepSeek 背书**（上游 README 自述）。
  - deepseek-harness（**不是第六个 agent**，本节标题仍指上面五个）：`dsh-acp-interactive` 所 composes 的上游，**只作资产来源钉版本，没有代码依赖**——`apps/web/public/favicon.svg` 复制成 `rust/acp-core/assets/dsh-icon.svg`（内置条目的 `iconSvg`，官方 registry 里没有这个 agent 所以图标随包带）。复制时两处改动：去掉靠 `prefers-color-scheme` 切黑白的 `<style>`、固定填充色换 `currentColor`；画布改 16 见方、`viewBox` 不动。用 DeepSeek 企业标志作这条 agent 的标记是所有者裁定（2026-09-18，知情于上一条的「未获背书」与「MIT 是版权许可、通常不含商标授权」）。

## 6. Zed 内置 agent 的接入点（sidecar 依据）

- 类型：`crates/agent/src/{agent.rs, thread.rs}` 都 `use agent_client_protocol::schema::v1 as acp`。
- 事件：`pub enum ThreadEvent { UserMessage, AgentText, AgentThinking, ToolCall(acp::ToolCall), ToolCallUpdate, ToolCallAuthorization, ToolCallAuthorizationResolved, Elicitation, SubagentSpawned, Retry, ContextCompaction, ContextCompactionUpdate, Stop(acp::StopReason) }`（`thread.rs:890`）。`NativeAgentConnection::handle_thread_events`（`agent.rs:2276`）把它们翻成对 `AcpThread` 的方法调用，sidecar 镜像这段翻成线上 `session/update`。
- 公开钩子：`Thread::send` 返回 `mpsc::UnboundedReceiver<Result<ThreadEvent>>`；`NativeAgent::open_thread` 公开；`ToolCallAuthorization` 字段公开（含 `response: oneshot::Sender`）；终端经 `pub trait ThreadEnvironment { fn create_terminal(...) }`。不需要 fork Zed。
- 引导：`crates/eval_cli/src/headless.rs`（140 行）初始化 SettingsStore、theme base、`Client::production`、languages、extension、`language_model(s)`、`prompt_store`、`terminal_view`、`agent_ui`；`main.rs` 746–812 行构建 `Project::local` + `create_worktree` + `NativeAgent::new(ThreadStore, Templates, fs)`。
- 数据：线程库在 `paths::data_dir()/threads/threads.db`，设置读 Zed 自己的 `settings.json`，即与本机 Zed 共用；未发现现成的目录覆盖变量。模型密钥走环境变量（如 `ANTHROPIC_API_KEY`）、系统凭据库或 `openai_compatible` / `anthropic_compatible` 配置。**R7 实测（2026-09-17）**：覆盖变量确实没有，但 `paths::set_custom_data_dir` 是公开 API，sidecar 以 `--user-data-dir` 把 `threads.db` / `db/` / `prompts/` 隔到本应用数据目录、`--zed-settings` 只读沿用配置；与运行中的 Zed 共用 `threads.db` 会让 **Zed 那边**报 `database is locked`（`docs/design.md` § 8）。
- 构建：闭包约 150 个 crate；Windows 需 VS C++ 生成工具（含 Spectre 库）、Windows SDK ≥ 10.0.20348、CMake（wasmtime 依赖）；冷编译 30 到 60 分钟。**R7 实测**：依赖闭包 debug 约 730 / release 约 910 个 crate，冷编译各约 50 分钟，`CARGO_TARGET_DIR` 占 56 GB，release 产物 176.7 MB；`languages` crate 因本机 VS 缺「Spectre 缓解库」未带（`rounds/BACKLOG-ZED.md`）；`Cargo.lock` 要以 zed 自己的为种子才解得出可编译的版本组合（`rounds/round-07/round-07.md`）。
- **版本号（R8，2026-09-20）**：钉的这一版 zed 自称 `1.21.0`（`vendor/upstream/zed/crates/zed/Cargo.toml`），已记进 `pins/upstream.json` 的 zed 条目 `version` 字段——**sidecar 的版本就取这个数**，与应用版本无关（CLAUDE.md 规则 11）。起因是实测：`sidecar/zed-agent-acp/Cargo.toml` 的 `version` 一改就是 crate 重编 + 176 MB 二进制全量重链 **14 分 16 秒**，不改则 cargo 判 fresh（8.2 秒），而发一次应用版本根本不动 sidecar 的源码。改注释不触发（9.5 秒，fingerprint 认的是 manifest 的解析结果）。换 zed 钉版本时 `pins` 的 `commit` 与 `version` 一起改，那一次的重编本来就免不了。

## 7. 被排除的路线

| 路线 | 排除原因 |
|---|---|
| 把 Zed 的 acp_thread / agent_servers / agent 链接进主进程 | § 1.3 的事件循环冲突；acp_thread 是 Zed 的投影不是线上协议，违反严格 ACP 投影 |
| 参考 Codex 桌面端前端 | 闭源，2026-07 并入 ChatGPT 桌面端；`openai/codex` 只有 CLI / TUI / app-server |
| 复用 pi-web 的文件管理与会话组件 | MIT 但传输层是 pi 私有 RPC；所有者裁定前端全部自研 |
| acp-components / acp-ui / Jockey 等第三方 ACP 客户端与组件库 | 所有者裁定白名单之外一律不引入 |
| 前端跑官方 TypeScript SDK | `typescript-sdk` 不在白名单；协议层落 Rust 核心 |
| Tauri 2 + WebView2 + React 19（2026-09-11 原方案） | 2026-09-12 所有者改为 Flutter：设计稿只作视觉基准、不复用代码，「设计稿是 HTML」的绑定消失；见 § 9 |
| Rust 核心作为独立进程 `acp-host.exe` 经 stdio 与 Flutter 通信（方案 B） | 所有者裁定 2026-09-12 取进程内 cdylib（方案 A）；契约是 JSON 字符串，日后要改传输层 Dart 侧不动 |
| Rinf（Rust 持有状态、消息传递） | 不支持带返回值的调用，`session_new` 这类请求 / 响应要自己配对；frb v2 更直接 |
| Dart 侧 PTY（`kyroon_pty` / `flutter_pty` / `pty2`） | PTY 语义要转写 Zed `acp_thread/terminal.rs` 且是 `terminal/*` 回调的实现方，必须留在 Rust；Dart 只渲染 |

## 8. 待验证的假设（进首轮任务卡）

- ~~rust-sdk v2 的 `AcpAgent` 在 Windows 上拉起 `.cmd` 包装的 npx agent 时引号与路径处理是否正确（dsh 在 Zed 里踩过）~~ → R1 已验证（2026-09-15）：npx 型 `.cmd` 在含中文与空格的工作目录下完成 initialize；结束进程树用 `taskkill /F /T`（`rounds/round-01/round-01.md`）。
- ~~无系统 Node 时复用 Zed `node_runtime` 下载受管 Node 的路径在中文用户名下是否可用~~ → R5：改为参考转写到 `rust/registry/src/node.rs`（理由见 `docs/design.md` § 2），受管 Node 下载与 npx 型拉起已实测（`rounds/round-05/round-05.md`）；内置 dsh 条目的 `npx` 回退还没走受管 Node（BACKLOG）。
- ~~sidecar 与运行中的 Zed 同时打开 `threads.db` 的行为~~ → R7 已验证：共用会锁住 Zed，已按「配置共用、数据隔离」落地（§ 6）。
- ~~`unstable` 特性集与五个 agent 的对齐（usage、compaction、session fork）~~ → R6 五 agent 全通矩阵已收口（`ROUNDS.md` § 4）；sidecar 用的 2.0.0 缺 `plan_operations` / `session_compaction`（§ 2）。
- ~~Flutter 构建链（CMake → cargokit → cargo）在含中文与全角括号的用户名路径下能否完成 Windows release 构建（§ 9.3）~~ → R0 已验证：本机用户名已是 ASCII；含中文与空格的项目路径经 `build.ps1` 的目录联接可过，裸 `flutter build` 不行（§ 9.3）。
- Flutter Windows 桌面的中文 IME 组合窗行为；`SelectionArea` 包住惰性列表后跨消息选择的表现。→ 跨消息选择 R2 已实测记录；终端面板的中文输入法 2026-09-17 由自建的 `TerminalIme` 接通（组字串暂不画在光标处，BACKLOG）；输入框的组合窗行为留给所有者手测（`rounds/round-00/round-00.md` 验收 6）。

## 9. Flutter + Rust 桥接（2026-09-12 技术栈调整依据）

### 9.1 为什么改

2026-09-11 选 Tauri + React 的核心依据是「Claude Design 出的是纯 HTML + 内联样式，Web 栈与它距离最近」。2026-09-12 起本项目只拿设计稿当**视觉基准**（`.dc.html` 源与 PNG 快照入库），不复用其代码；前端框架因此不再被设计工具绑定，2026-09-14 设计工具改回 Claude Design 也不影响这条。Flutter 的收益：不依赖 WebView2；列表惰性构建、动效、字体渲染是原生能力；单一 Dart 工具链。代价见 § 9.4。

### 9.2 frb v2 与 Rinf

| | flutter_rust_bridge v2 | Rinf |
|---|---|---|
| 调用模型 | Dart 直接调 Rust `async fn`，有返回值；Rust → Dart 用 `StreamSink<T>` | 纯消息传递（signals），无返回值 |
| 类型 | 自动镜像 Rust 类型，也可 opaque | serde 结构体双端生成 |
| 构建 | cargokit 挂进 Flutter 各平台的 CMake / Xcode | 同样挂 CMake，不改敏感构建文件 |
| 与本项目契约的匹配 | § 3 的命令是请求 / 响应，事件是流，一一对应 | 请求 / 响应要自己配 id |

裁定 frb v2（所有者 2026-09-12）。本项目**只跨边界传 `String`（JSON）**，frb 的类型镜像能力基本不用，绑定面是：十来个 `async fn(...) -> Result<String>` 命令 + 5 个 `StreamSink<String>` 事件流 + 一个 `init(data_dir)`。这样 Rust 侧的 ACP 类型不需要 Dart 镜像，schema → Dart 生成物只服务 Dart 投影层的可读性，与桥无关。

### 9.3 Windows 构建链的已知坑

- frb 用 cargokit 在 Flutter 的 CMake 里调 `cargo build`，中间目录经过 `%LOCALAPPDATA%` 或项目路径；本机用户名含中文与全角括号，8.3 短名与 UTF-8 路径在 CMake ↔ cargo 间传递可能出错。对策：`CARGO_TARGET_DIR` 指到纯 ASCII 路径，R0 第一项验收就是在本机跑通 `flutter build windows --release`。
  **R0 实测（2026-09-15）**：cargokit ↔ cargo 这段在含中文与空格的项目路径下没问题（`CARGO_TARGET_DIR` 补丁生效）；出问题的是 Flutter 自己的 `flutter_assemble` MSBuild 自定义生成规则，项目路径按系统代码页转码后读不到 `app.dill`。`scripts/build.ps1` 用 ASCII 目录联接（`mklink /J`）绕过，见 `rounds/round-00/round-00.md`。
- Flutter Windows 前置：VS 2022「使用 C++ 的桌面开发」工作负载 + CMake（随 VS 装）+ Windows 10 SDK；与 Zed sidecar 的前置重叠，不额外增加机器要求。
- frb codegen 需要 `cargo expand`（依赖 nightly rustfmt 或 `cargo-expand` 二进制），要写进本地开发前置。
- Rust panic 跨 FFI 边界是 UB 级问题；frb 默认在边界 `catch_unwind` 转 Dart 异常，核心 API 层仍应统一返回 `Result`，不依赖这层兜底。

### 9.4 Flutter 侧能力对照与缺口

| 需求 | Web 栈原方案 | Flutter 方案 | 结论 |
|---|---|---|---|
| 终端渲染 | `@xterm/xterm` | `xterm`（pub.dev，TerminalStudio 维护） | 成熟；PTY 留在 Rust |
| Markdown（流式、GFM、代码高亮） | `react-markdown` + `remark-gfm` | 官方 `flutter_markdown` 已停维（2025）；R1.5 spike 五候选对比后裁定 `package:markdown` 解析 + 自写渲染，高亮 `re_highlight`，公式 `flutter_math_fork`，Mermaid `mermaid_flutter` + `mermaid_core`，音频 `audioplayers`（`rounds/round-1.5/spike.md`） | 已裁定 2026-09-15 |
| 长列表 | `@tanstack/react-virtual` | `ListView.builder` | 原生更好 |
| diff 渲染 | 一个 diff 库 | Dart `diffutil_dart`（R1.5 spike 对比 `diff_match_patch` 后裁定 2026-09-15） | 等价 |
| 文件对话框 / 打开 URL | Tauri 插件 | `file_selector` / `url_launcher`（Flutter 官方） | 等价 |
| 跨消息文本选择 | 浏览器免费 | `SelectionArea`，与惰性列表配合有边界情况 | 弱于 Web，实测记录 |
| 打包 | Tauri bundler + `externalBin` | Flutter Windows CMake install + Inno Setup / MSIX；sidecar 用 CMake install 规则 | 等价，多写几行 CMake |

## 10. Claude Design 交付链路

- **产物形态**：Claude Design 的设计稿是「一画板一个 `.dc.html`」加一份 `canvas.json` 布局清单；`.dc.html` 是自包含的 HTML 加内联样式，可以直接入库、diff、回溯。这是它与 Figma Make 的主要差异：Make 的产物只在 Figma 云端，仓库里只能放 PNG。本项目把设计稿当视觉基准而不是代码来源：`.dc.html`、`canvas.json` 与每画板一张 PNG 入库，`design/README.md` 记编号、名称、`.dc.html`、PNG、画布 URL；画板编号只增不改。PNG 是审查与验收的锚，画布上的后续改动不影响已开工轮次。
- **两个入口**：claude.ai/design 的完整产品，或 Claude Code 内的 `/design`（把 `.dc.html` 画板发布成一个可编辑的画布 Artifact；早期预览，不与网页版对齐）。两者产物相同。画布上 Save 过的改动要先读回仓库覆盖源文件，再重导 PNG，不在两边各改一份。
- **Figma MCP 与 Code Connect 随 Make 一起退出**：`get_screenshot` / `get_design_context` / `get_variable_defs` 不再用于对照与提炼，直接读 `.dc.html`。
- **token 提炼**：首个设计轮先出 `00-tokens` 画板，页面画板从它取值；从它的 `<helmet><style>` 与内联样式提炼颜色、字号、间距、圆角、动效时长到 `lib/theme/tokens.dart`，作为样式唯一来源，不从页面画板反推。规则 3 的「样式零改动」在 Flutter 下的判据就是接线轮里 `tokens.dart` 与画板 widget 文件零 diff。
- **组件仍全部从画板手写**：`.dc.html` 里的 HTML 与 CSS 不翻译成 Dart，只作结构与数值参照（CLAUDE.md 规则 1 / 3）。
