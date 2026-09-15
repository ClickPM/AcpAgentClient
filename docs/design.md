# 整体设计

> 本文是架构与既定决策。范围以 [`requirements.md`](requirements.md) 为准，依据在 [`research.md`](research.md)。轮次拆解在仓库根 `ROUNDS.md`（首轮拆解时建立），本文 § 11 只是草案。

## 1. 进程模型

```
Flutter 宿主进程（Dart）
├── Flutter 前端（lib/；按 design/ 设计稿实现；只消费 ACP 原样 JSON）
│      │ flutter_rust_bridge v2：命令 = async fn 返回 JSON String；事件 = StreamSink<String>
└── Rust 核心（rust/；cdylib，进程内加载；tokio runtime 由库初始化）
    ├── acp-core    官方 rust-sdk v2 Client 角色；每个 agent 一条 stdio 连接，多会话复用
    ├── registry    registry.json 拉取 / 缓存 / 图标；npx 与 binary 安装；受管 Node
    ├── pty         terminal/* 回调（portable-pty）；terminal auth 用的可见终端
    ├── fs          fs/read_text_file、fs/write_text_file；工作区文件树与搜索
    └── settings    Zed 兼容的 agent_servers JSON；数据目录；从 Zed settings.json 导入
         │ stdio · ACP JSON-RPC（v1）
         ├── claude-agent-acp     npx
         ├── codex-acp            npx
         ├── cursor `agent acp`   binary
         ├── pi-acp               npx
         ├── dsh-acp-interactive  custom
         └── zed-agent-acp        sidecar（GPL；headless gpui + Zed NativeAgent；随主程序打包）
```

规则：主进程（Flutter 宿主及其加载的 Rust cdylib）里没有 gpui；所有 agent，包括 Zed 内置 agent，都是子进程；前端与核心之间只传 ACP 形状的数据。

**为什么是进程内 cdylib 而不是独立 `acp-host.exe`**（所有者裁定 2026-09-12，方案 A）：单进程、打包简单；§ 3 的 payload 本来就是 JSON 字符串，跨 FFI 边界只传 `String`，frb 绑定面极小（十来个命令 + 5 个事件流），不需要为 ACP 类型做 Dart 镜像。将来若要改独立进程，Dart 侧解析层不动，只换传输。

## 2. 分层与来源

| 层 | 来源 | 用法 |
|---|---|---|
| 协议客户端 | rust-sdk v2 | `Client::builder().on_receive_request(...)` 注册回调；`AcpAgentConfig` 拉起子进程；`unstable` 特性集与 Zed 对齐 |
| 前端类型 | 协议仓库 `schema/v1/schema.unstable.json` 按 15 变体白名单裁剪 | 构建期生成 Dart 类型（或手写 15 变体薄封装，R0 定）并入库；运行期零协议依赖 |
| Dart ↔ Rust 桥 | flutter_rust_bridge v2 | Rust 侧 `rust/bridge` crate 暴露 `api.rs`；Dart 侧生成物入库 `lib/bridge/`；payload 一律 JSON `String` |
| registry 与安装 | Zed `agent_registry_store.rs`、`agent_server_store.rs` | 整体复制；删 remote / collab 路径；`Entity` / `Task` 换 tokio；`fs::Fs` 换 `tokio::fs`；结构体对照官方 `agent.schema.json` |
| Node 与下载 | Zed `node_runtime`、`http_client`、`reqwest_client`、`paths`、`util` | 直接 git 依赖（不含 gpui） |
| 连接与认证语义 | Zed `agent_servers/acp.rs` 非测试部分 | 转写：能力声明、AuthRequired 映射、terminal auth、session 控制、config options、elicitation、流量日志 |
| 终端回调语义 | Zed `acp_thread/terminal.rs` | 转写：输出字节上限、wait_for_exit、kill、release |
| 文件面板 | 自研 | `std::fs` + `notify`；不做索引服务 |
| Zed 内置 agent | Zed `agent` + `eval_cli` | sidecar，见 § 8 |
| UI | Claude Design 设计稿 | 全部自研；token 提炼到 `lib/theme/tokens.dart`，每个画板一个 widget 文件 |

## 3. 核心与前端的契约（严格 ACP 投影）

> 可投影内容的完整清单（15 个 `session/update` 变体、能力门总表、协议不给必须自造的 7 项、容错与丢失风险）见 [`acp-projection.md`](acp-projection.md)；本节只定契约形状。

**传输形状**：每个事件是一条 frb `StreamSink<String>`，每个命令是一个 frb `async fn(...) -> Result<String>`；`String` 里是下表的 JSON。Dart 侧 `jsonDecode` 后进投影状态层，不在桥层做任何类型镜像。

**事件（核心 → 前端）**

| 事件 | payload |
|---|---|
| `acp/session_update` | `{agentId, sessionId, update}`；`update` 是 `SessionNotification` 的原样 JSON（SDK 类型 serde 直出） |
| `acp/client_request` | `{agentId, requestId, method, params}`；用于需要用户参与的客户端请求：`session/request_permission`、`elicitation/create`；前端必须以 `acp_respond` 回应 |
| `acp/agent_state` | 连接生命周期：spawned / initialized / auth_required(authMethods) / exited(code, stderr tail) |
| `acp/terminal_output` | terminal auth 与内置终端的输出流（非协议消息，仅用于可见终端） |
| `acp/traffic` | 原始 JSON-RPC 行（脱敏后），供调试面板 |

**命令（前端 → 核心）**

- 连接与会话：`agent_connect`、`agent_disconnect`、`session_new`、`session_load`、`session_list`、`session_close`、`session_prompt`、`session_cancel`、`session_set_mode`、`session_set_config_option`、`acp_respond`
- 认证：`authenticate`（agent 类型）、`terminal_auth_run`（terminal 类型；完成后核心自动重试 `session/new`）
- registry 与设置：`registry_refresh`、`registry_list`、`registry_install`、`agent_settings_get/set`、`agent_settings_import_zed`
- 文件面板：`fs_list_dir`、`fs_read`、`fs_watch`、`fs_search`

**前端状态规则**

- 按 `sessionId` 累积 `update`；`tool_call` 与 `tool_call_update` 按协议合并（同 id 覆盖，content 为替换语义）。
- `user_message_chunk` / `agent_message_chunk` / `agent_thought_chunk` 按顺序追加。
- 待处理的 permission 与 elicitation 是队列，回应后出队。
- 不在前端做任何 agent 特判。

## 4. initialize 能力声明

照 Zed 的 `client_capabilities_for_agent`：`fs.readTextFile`、`fs.writeTextFile`、`terminal`、`auth.terminal`、`session.configOptions.boolean`、`elicitation.form`、`elicitation.url`；`_meta` 里 `terminal_output: true`、`terminal-auth: true`。对 Cursor 追加参数化模型选择器键。**这是允许的 `_meta` 键的全部清单**，增加新键要改本节并进所有者裁定。

比 Zed 多声明两个 unstable 客户端能力（所有者裁定 2026-09-11，依据「多数 agent 已支持 plan 与压缩」）：

- `plan: {}` → 打开 `plan_update` / `plan_removed`（多计划、可增量、支持 items / file / markdown 三种载荷；codex-acp 已在发）；稳定的 `plan` 整份替换继续兼容。
- `session.compaction: {}` → 打开 `compaction_update` / `compaction_summary_chunk`（上下文压缩过程与保留摘要可见）。

两者都在 rust-sdk `unstable` 伞内（`unstable_plan_operations`、`unstable_session_compaction`），不改 feature 集，不触发规则 4 / 10。会话流可投影内容的完整清单见 [`acp-projection.md`](acp-projection.md)。

**`notice` 的处置（所有者裁定 2026-09-11）**：sdk 的 `unstable` 不转发 `unstable_session_notices`，`SessionUpdate::Notice` 编译不出来，收到即反序列化失败。不为它改 feature 集；核心侧对反序列化失败的 `session/update` 计数并经 `acp/agent_state` 上抛告警，原文落 `acp/traffic` 供排查。R1 用 dsh 实测一次后复议。

## 5. 认证流程

1. `session/new` 返回 `AuthRequired` → 展示 `initialize` 返回的 `authMethods`。
2. 方法类型为 `agent` → 调 `authenticate`，agent 自己开浏览器；成功后重试 `session/new`。
3. 方法类型为 `terminal` → 在可见终端里跑给定命令；进程退出后重试 `session/new`。兼容旧版 `_meta.terminal-auth`。
4. URL elicitation（codex-acp 登录）走 § 3 的 `acp/client_request`，前端打开系统浏览器并等待 `elicitation/complete`。

## 6. registry 与安装

1. 拉取：`registry.json` 1 小时节流，磁盘缓存，图标按需拉取；结构体对照 `agent.schema.json`。
2. 列表：按当前平台过滤 `binary` 的 target；`uvx` 条目显示但标「暂不支持」。
3. 安装：`npx` 解析包名与版本，写入 settings；`binary` 下载压缩包 → 校验 sha256 → 解压到 `agents/<id>/<version>/` → 记录 `cmd` / `args` / `env`。
4. Node：优先系统 Node ≥ 22；缺失时复用 Zed `node_runtime` 下载受管 Node v24.11.0 到数据目录。
5. 设置：`agent_servers` 与 Zed 同 schema（`type: registry | custom`），提供从 `%APPDATA%/Zed/settings.json` 导入。

## 7. 终端与 fs

- pty：portable-pty；每个终端有输出字节上限；`terminal/wait_for_exit`、`terminal/kill`、`terminal/release` 语义转写自 `acp_thread/terminal.rs`；Windows 下 `.cmd` 包装与引号处理必须实测。
- fs：路径必须是绝对路径且在会话工作目录之内；`line` / `limit` 是 1-based；写文件直接落盘（temp + rename）。

## 8. zed-agent-acp sidecar

- 独立 cargo workspace（`sidecar/zed-agent-acp/`），path 依赖指向 `vendor/upstream/zed/crates/*`；GPL-3.0-or-later。
- 引导：复制 `eval_cli/src/headless.rs`；`session/new` 时 `Project::local` + `create_worktree(cwd)` + `NativeAgent::new`。
- 映射：`initialize` → 固定能力；`session/new` / `session/load` / `session/list` → `NativeAgent::open_thread` 与 `ThreadStore`；`session/prompt` → `Thread::send` 得到 `ThreadEvent` 流；`session/cancel` → `Thread` 取消；`session/set_mode` 与 config options → `model_selector` / 权限预设。
- 事件翻译：`ThreadEvent::{UserMessage, AgentText, AgentThinking, ToolCall, ToolCallUpdate, SubagentSpawned, Retry, ContextCompaction*}` → `session/update`；`ToolCallAuthorization` → `session/request_permission`，结果写回 `response`；`Elicitation` → `elicitation/create`；`Stop` → `PromptResponse`。
- 终端：实现 `ThreadEnvironment::create_terminal`，进程内用 Zed `terminal` crate。
- 数据：默认与本机 Zed 共用 `threads.db` 与 `settings.json`；是否隔离在 R6 裁定。
- 打包：在 `windows/runner/CMakeLists.txt`（macOS / Linux 对应 runner）加 install 规则，把 `zed-agent-acp(.exe)` 放到应用目录旁随主程序分发；核心按可执行文件相对路径定位它。

## 9. 前端

- **Flutter stable（Dart）+ flutter_rust_bridge v2**（所有者裁定 2026-09-12，替代 2026-09-11 裁定的 Tauri + React 19）。改的原因：设计稿只作视觉基准（`.dc.html` 源与 PNG 入库）、不复用其代码，前端框架不再被「设计稿是 HTML」绑定；Flutter 不依赖 WebView2，渲染与列表虚拟化是原生能力；Rust 核心以 cdylib 进程内加载，契约不变。2026-09-14 设计工具由 Figma Make 改回 Claude Design，此裁定不变。代价与风险见 § 12。
- 流式更新的性能靠三件事：投影状态层是纯 Dart 类（不依赖 widget 树），widget 用 `ListenableBuilder` / `StreamBuilder` 选择性订阅；`session/update` 按帧批量合并；转录列表用 `ListView.builder` 惰性构建。
- 通用库允许清单见 CLAUDE.md 规则 1；**不引第三方 UI 组件库与状态管理库**，组件全部从画板手写，状态用 SDK 自带的 `ChangeNotifier` / `Stream`；样式的唯一来源是从画板提炼的 `lib/theme/tokens.dart`（颜色、字号、间距、圆角、动效时长），widget 文件里不出现字面量。
- Markdown 渲染：官方 `flutter_markdown` 已停止维护，社区替代对**流式追加**与代码高亮的支持参差。R1 后做一次专门 spike 比较候选（基于 `package:markdown` 自写渲染、`markdown_widget`、`gpt_markdown` 等），选定后才进规则 1 白名单与 R2；spike 之前不引入任何 Markdown 库。
- 终端渲染用 `xterm`（pub.dev）；PTY 仍在 Rust 侧 portable-pty，`acp/terminal_output` 推字节，Dart 只渲染。文件对话框与打开 URL 用 Flutter 官方 `file_selector` / `url_launcher`，其余系统交互一律走 Rust。
- ACP 投影的状态层自己写，约五百行，是唯一不允许第三方替代的部分；规则来自 `prototype/assets/projection.js`。
- 设计稿存 `design/`：每轮一个子目录，含 `design-prompt.md`（给 Claude Design 的设计简报）、每个画板一个 `.dc.html` 源、`canvas.json` 布局与每个画板一张 PNG 快照；`design/README.md` 是画板索引（编号、名称、`.dc.html`、PNG、画布 URL），画板编号只增不改。`.dc.html` 是设计的唯一事实来源，PNG 是审查与验收的基准，画布上的后续改动不影响已开工轮次；改设计走「先拉回 `.dc.html`、重导 PNG、更新索引，再进轮次」。
- 页面：会话工作台（消息、思考、工具卡、计划、用量、权限与 elicitation）；agent 管理（registry、custom、认证状态）；文件面板；设置；ACP 流量调试。
- 接后端只换数据源，不改样式：接线轮里 `lib/theme/tokens.dart` 与画板 widget 文件应零 diff。

## 10. 数据目录

Windows：`%APPDATA%/AcpAgentClient/{settings.json, registry-cache/, agents/, node/, logs/}`。会话数据归各 agent 自己（claude、codex、pi、dsh 各有自己的存储）；本客户端只存会话索引（agentId + sessionId + 标题 + cwd + 时间）。日志脱敏：`Authorization`、`api_key`、`token` 字段一律打码。

## 11. 阶段草案

| 轮 | 目标 | 参照 agent |
|---|---|---|
| R0 | 脚手架：Flutter 桌面项目 + `rust/` workspace（cdylib）+ frb v2 接通（一个命令 + 一条事件流往返）+ schema→Dart 生成 + Rust 核心独立 CLI smoke + validate 脚本；**在含中文与全角括号的用户名路径下完成 Windows 构建** | 无 |
| R1 | 主线：拉起、initialize、terminal auth、prompt、权限、取消 | dsh-acp-interactive |
| R1.5 | spike：Markdown 渲染选型（流式追加、代码高亮、CJK、选择复制），产出对比记录与所有者裁定，进白名单 | 无 |
| R2 | 会话工作台按设计稿实现 | dsh-acp-interactive |
| R3 | fs 与 terminal 回调 | claude-agent-acp |
| R4 | registry：拉取、npx / binary 安装、受管 Node；URL elicitation 登录 | codex-acp、Cursor |
| R5 | session/list、session/load、modes、config options、Zed 设置导入 | pi-acp、全部 |
| R6 | zed-agent-acp sidecar | Zed 内置 agent |
| R7 | 打包：Windows 免安装 zip 与安装器；macOS | 全部 |

设计轮插在实现轮之前：R2 之前先出会话工作台设计稿，R4 之前先出 agent 管理设计稿。

## 12. 风险与对策

| 风险 | 对策 |
|---|---|
| Windows 上 npx 类 agent 的 `.cmd` 包装与引号 | R1 第一项验收就是用 dsh 在 Windows 实测；转写 Zed `ShellBuilder` 的处理 |
| Flutter 构建链（CMake → cargokit → cargo）在含中文与全角括号的用户名路径下失败 | R0 第一项验收；失败则在 `flutter_rust_bridge.yaml` / CMake 里把 `CARGO_TARGET_DIR` 指到纯 ASCII 路径 |
| Flutter 侧 Markdown 渲染不如 Web 成熟（流式、高亮、选择复制） | R1.5 专门 spike，选定前不进 R2 |
| Rust panic 会带倒整个 Flutter 进程 | 核心对外 API 边界统一 `catch_unwind` 转 `Result`；agent 子进程崩溃只上报 `acp/agent_state` |
| Windows 中文 IME 组合窗与转录跨消息文本选择 | R0 / R2 各实测一次记录；设计稿有「复制整段」按钮可绕过大部分选择需求 |
| `unstable` 特性集漂移 | 钉 rust-sdk commit；改钉先改 `pins/upstream.json` 与 `research.md` |
| sidecar 与运行中的 Zed 争用 `threads.db` | R6 裁定：只读共用 / 隔离目录二选一 |
| Zed 构建环境重 | sidecar 独立 workspace，主程序不依赖它也能跑；CI 分开 |
| 设计稿范围蔓延 | 画板编号只增不改；设计稿没有的功能进 BACKLOG |
