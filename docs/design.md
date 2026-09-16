# 整体设计

> 本文是架构与既定决策。范围以 [`requirements.md`](requirements.md) 为准，依据在 [`research.md`](research.md)。轮次拆解在仓库根 [`ROUNDS.md`](../ROUNDS.md)（2026-09-15 按设计稿建立），本文 § 11 已由它取代。

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
| 前端类型 | 手写薄封装 `lib/projection/wire.dart`（15 变体 + 5 种内容块 + 3 种工具卡内容 + 两类请求；所有者裁定 2026-09-15，不做构建期生成） | 只做字段访问与判别；合规性由 Rust 侧用 rust-sdk 类型反序列化 `test/fixtures/` 的测试兜底；运行期零协议依赖 |
| Dart ↔ Rust 桥 | flutter_rust_bridge v2 | Rust 侧 `rust/bridge` crate 暴露 `api.rs`；Dart 侧生成物入库 `lib/bridge/`；payload 一律 JSON `String` |
| registry 与安装 | Zed `agent_registry_store.rs`、`agent_server_store.rs` | 整体复制；删 remote / collab 路径；`Entity` / `Task` 换 tokio；`fs::Fs` 换 `tokio::fs`；结构体对照官方 `agent.schema.json` |
| Node 与下载 | Zed `node_runtime`、`http_client`、`reqwest_client`、`paths`、`util` | 直接 git 依赖（不含 gpui） |
| 连接与认证语义 | Zed `agent_servers/acp.rs` 非测试部分 | 转写：能力声明、AuthRequired 映射、terminal auth、session 控制、config options、elicitation、流量日志 |
| 终端回调语义 | Zed `acp_thread/terminal.rs` | 转写：输出字节上限、wait_for_exit、kill、release |
| 文件面板 | 自研 | `std::fs` + `notify`；不做索引服务 |
| git（分支列表 / 切换 / 新建、文件树状态徽章、Branch Diff 上下文） | 自研 | `git` CLI 子进程薄封装（放 `rust/fs`），不引 git 库；检测不到 git 或目录不是仓库时相关 UI 隐藏（所有者裁定 2026-09-15） |
| Zed 内置 agent | Zed `agent` + `eval_cli` | sidecar，见 § 8 |
| UI | Claude Design 设计稿 | 全部自研；token 提炼到 `lib/theme/tokens.dart`，每个画板一个 widget 文件（同一卡片的状态画板可合一文件，文件头列画板号；画板 → 轮次 → 文件的对应表见 `ROUNDS.md` § 2） |

## 3. 核心与前端的契约（严格 ACP 投影）

> 可投影内容的完整清单（15 个 `session/update` 变体、能力门总表、协议不给必须自造的 7 项、容错与丢失风险）见 [`acp-projection.md`](acp-projection.md)；本节只定契约形状。

**传输形状**：每个事件是一条 frb `StreamSink<String>`，每个命令是一个 frb `async fn(...) -> Result<String>`；`String` 里是下表的 JSON。Dart 侧 `jsonDecode` 后进投影状态层，不在桥层做任何类型镜像。

**事件（核心 → 前端）**

| 事件 | payload |
|---|---|
| `acp/session_update` | `SessionNotification` 的原样 JSON（SDK 类型 serde 直出：`{sessionId, update, _meta?}`）**再加一个 `agentId`**，不另套一层（R3 接线时对齐，核心侧见 `rust/acp-core/src/agent.rs`） |
| `acp/client_request` | `{agentId, requestId, method, params}`；用于需要用户参与的客户端请求：`session/request_permission`、`elicitation/create`；`elicitation/create` 可能是 requestScope（无 `sessionId`，认证阶段），前端队列不能只按会话索引，这类落认证页（画板 52）而不是转录；前端必须以 `acp_respond` 回应。**`requestId` 为 null 的是 agent 发来的通知**，不需回应，只更新队列：`elicitation/complete`（URL elicitation 收尾）与 `$/cancel_request`（agent 撤回了自己的请求，`params.requestId` 已归一化成与队列 `requestId` 同形的字符串——协议原样可能是数字——前端按它把请求从队列移除）（R1） |
| `acp/agent_state` | 连接生命周期 `{agentId, state, droppedUpdates, ...}`：`spawned(pid, program, args, cwd)` / `initialized(initialize)`（InitializeResponse 原样）/ `auth_required(authMethods, message)` / `authenticating(methodId, terminalId, label)`（terminal auth 的 pty 已拉起）/ `update_dropped(method, error)`（一条 `session/update` 反序列化失败，`droppedUpdates` 已 +1，§ 4）/ `exited(code, stderrTail, transportError)`；每条都带 `droppedUpdates` 计数（R1）。核心自身也走这条流：`core_init` 完成时发 `{agentId: null, state: "core_ready", dataDir, coreVersion}`（R0，验证事件通路） |
| `acp/terminal_output` | `{terminalId, source, bytes}`（`bytes` 是 base64 的原始字节）或进程结束时的 `{terminalId, source, exitStatus: {exitCode, signal}}`；`source` ∈ agent（`terminal/*` 回调建的终端）/ auth（terminal auth 的可见终端，R1）/ local（终端面板的本地 shell）；非协议消息，仅用于渲染（R4 补齐 agent / local 两路） |
| `acp/traffic` | `{agentId, direction, line, ts}`：`direction` ∈ in（agent stdout）/ out（agent stdin）/ stderr，`line` 是脱敏后的原始行（`Authorization` / `api_key` / `token` 类键的值打成 `***`，规则 8），`ts` 毫秒时间戳；供调试面板（R1） |
| `registry/progress` | 安装进度 `{agentId, step, done?, total?, error?}`：npx 是 resolve / write_settings / handshake，binary 是 download / verify / extract，另有 node_download（R5） |

**命令（前端 → 核心）**

- 连接与会话：`agent_connect`、`agent_disconnect`、`session_new`、`session_load`、`session_list`（cursor 分页）、`session_resume`、`session_close`、`session_delete`、`session_prompt`、`session_cancel`、`session_set_mode`、`session_set_config_option`、`acp_respond`
- 认证：`authenticate`（agent 类型）、`terminal_auth_run`（terminal 类型；完成后核心自动重试 `session/new`）
- registry、Node 与设置：`registry_refresh`、`registry_list`、`registry_install`、`registry_cancel_install`、`registry_remove`、`node_status`、`node_download`、`agent_settings_get/set`、`agent_settings_import_zed`
- 文件面板与 git：`fs_list_dir`、`fs_read`、`fs_watch`、`fs_search`、`git_status`（文件树徽章）、`git_branches`、`git_switch`、`git_create_branch`、`git_diff`（Branch Diff 上下文）
- 本地 shell（终端面板）：`terminal_open`、`terminal_write`、`terminal_resize`、`terminal_close`；输出走 `acp/terminal_output`（`terminal_write` 在 R1 先出：terminal auth 的可见终端要接键盘输入）
- 项目与本地索引：`workspace_recent`、`workspace_open`、`session_index_list/upsert/remove`（会话索引：agentId + sessionId + 标题 + cwd + 时间 + 消息计数）
- 窗口 UI 状态：`ui_state_get`、`ui_state_set`（合并写；载荷 `{sidebarWidth?, rightPanelWidth?}`，缺省与夹取范围都在前端 token，核心不存第二份）

命令名以本节为准，各轮只实现自己那部分（归属见 `ROUNDS.md` § 3 / § 5）；R3–R6 的新增项是 2026-09-15 按画板裁定后一次写入的，不再逐轮改契约。每条命令的入参形状（哪些是 JSON 字符串、哪些是标量）与返回 JSON 以 `rust/bridge/src/api.rs` 的文档注释为准；错误统一是 `BridgeError {code, message}`，`code` 是 `CoreError::code()` 的稳定短码（`auth_required` / `exited` / `not_connected` / `unknown_request` / `acp` 等）。

**前端状态规则**

- 按 `sessionId` 累积 `update`；`tool_call` 与 `tool_call_update` 按协议合并（同 id 覆盖，content 为替换语义）。
- `user_message_chunk` / `agent_message_chunk` / `agent_thought_chunk` 按顺序追加。
- 待处理的 permission 与 elicitation 是队列，回应后出队。
- 不在前端做任何 agent 特判。
- 待处理队列按 `sessionId` 索引，另有一个无会话的 requestScope 队列（认证阶段的 elicitation）。
- 工具调用「已取消」是前端本地态（`ToolCallStatus` 没有 cancelled）：发出 `session/cancel` 后把本轮未完成的工具卡标 cancelled，核心不伪造状态。
- Restore Checkpoint 与用户消息的 Regenerate（画板 10 / 11）= 本地截断其后的投影块并在同一会话重发 prompt；协议没有回滚，agent 侧上下文不回退，这是已知限制（所有者裁定 2026-09-15）。
- `/` 命令菜单单组渲染：`AvailableCommand` 没有分组与来源字段，不按名字猜分组（所有者裁定 2026-09-15）。
- 侧栏会话列表以本地索引为准；`session/list` 只用来校对存在性与补标题，agent 有、本地没有的会话不自动出现（所有者裁定 2026-09-15，R6）。

## 4. initialize 能力声明

照 Zed 的 `client_capabilities_for_agent`：`fs.readTextFile`、`fs.writeTextFile`、`terminal`、`auth.terminal`、`session.configOptions.boolean`、`elicitation.form`、`elicitation.url`；`_meta` 里 `terminal_output: true`、`terminal-auth: true`。对 Cursor 追加参数化模型选择器键 `parameterizedModelPicker: true`（Zed 的 `PARAMETERIZED_MODEL_PICKER_META_KEY`）。**这是允许的 `_meta` 键的全部清单**，增加新键要改本节并进所有者裁定。

比 Zed 多声明两个 unstable 客户端能力（所有者裁定 2026-09-11，依据「多数 agent 已支持 plan 与压缩」）：

- `plan: {}` → 打开 `plan_update` / `plan_removed`（多计划、可增量、支持 items / file / markdown 三种载荷；codex-acp 已在发）；稳定的 `plan` 整份替换继续兼容。
- `session.compaction: {}` → 打开 `compaction_update` / `compaction_summary_chunk`（上下文压缩过程与保留摘要可见）。

两者都在 rust-sdk `unstable` 伞内（`unstable_plan_operations`、`unstable_session_compaction`），不改 feature 集，不触发规则 4 / 10。会话流可投影内容的完整清单见 [`acp-projection.md`](acp-projection.md)。

**`notice` 的处置（所有者裁定 2026-09-11）**：sdk 的 `unstable` 不转发 `unstable_session_notices`，`SessionUpdate::Notice` 编译不出来，收到即反序列化失败。不为它改 feature 集；核心侧对反序列化失败的 `session/update` 计数并经 `acp/agent_state` 上抛告警，原文落 `acp/traffic` 供排查。R1 用 dsh 实测一次后复议。

**入站 `_meta` 识别键（所有者裁定 2026-09-15）**：上面的清单是我们**发出**的 `_meta`。前端**读取**的入站 `_meta` 键也只有这一份清单：`claudeCode.parentToolUseId` / `claudeCode.subagent` / `claudeCode.toolName`（claude-agent-acp 的子代理标记）与 `dsh_subagent`（dsh-acp-interactive）。投影层只按「键是否存在」把工具调用归到子代理卡（画板 24）之下，不按 agent 名判；其余入站 `_meta` 原样保留、不解释。增减键改本段并进所有者裁定。

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
- 数据：默认与本机 Zed 共用 `threads.db` 与 `settings.json`；是否隔离在 R7 实测后裁定。模型密钥沿用 Zed 的 `settings.json` / 环境变量，不做额外配置页（所有者裁定 2026-09-15）。
- 打包：在 `windows/runner/CMakeLists.txt`（macOS / Linux 对应 runner）加 install 规则，把 `zed-agent-acp(.exe)` 放到应用目录旁随主程序分发；核心按可执行文件相对路径定位它。

## 9. 前端

- **Flutter stable（Dart）+ flutter_rust_bridge v2**（所有者裁定 2026-09-12，替代 2026-09-11 裁定的 Tauri + React 19）。改的原因：设计稿只作视觉基准（`.dc.html` 源与 PNG 入库）、不复用其代码，前端框架不再被「设计稿是 HTML」绑定；Flutter 不依赖 WebView2，渲染与列表虚拟化是原生能力；Rust 核心以 cdylib 进程内加载，契约不变。2026-09-14 设计工具由 Figma Make 改回 Claude Design，此裁定不变。代价与风险见 § 12。
- 流式更新的性能靠三件事：投影状态层是纯 Dart 类（不依赖 widget 树），widget 用 `ListenableBuilder` / `StreamBuilder` 选择性订阅；`session/update` 按帧批量合并；转录列表用 `ListView.builder` 惰性构建。
- 通用库允许清单见 CLAUDE.md 规则 1；**不引第三方 UI 组件库与状态管理库**，组件全部从画板手写，状态用 SDK 自带的 `ChangeNotifier` / `Stream`；样式的唯一来源是从画板提炼的 `lib/theme/tokens.dart`（颜色、字号、间距、圆角、动效时长），widget 文件里不出现字面量。
- Markdown 渲染：官方 `flutter_markdown` 已停止维护，社区替代对**流式追加**与代码高亮的支持参差。R1.5 spike（`rounds/round-1.5/spike.md`）比较了 `package:markdown` 自写渲染、`markdown_widget`、`gpt_markdown`、`flutter_markdown_plus`、`streamdown` 五个候选，所有者裁定 2026-09-15：**`package:markdown` 只用解析器，渲染层按画板自写**（每个顶层块带 key，样式全从 `tokens.dart` 来）；代码高亮 `re_highlight`，公式 `flutter_math_fork`（`$…$` / `$$…$$` 的识别在 Markdown 层做），Mermaid `mermaid_flutter` + `mermaid_core`（解析失败经 `errorBuilder` 回落源码态），音频块 `audioplayers`（内存 `BytesSource`），diff `diffutil_dart`；画板 15 / 32 不改。
- 终端渲染用 `xterm`（pub.dev）；PTY 仍在 Rust 侧 portable-pty，`acp/terminal_output` 推字节，Dart 只渲染。文件对话框与打开 URL 用 Flutter 官方 `file_selector` / `url_launcher`，其余系统交互一律走 Rust。
- ACP 投影的状态层自己写，约五百行，是唯一不允许第三方替代的部分；规则来自 `prototype/assets/projection.js`。
- 设计稿存 `design/`：每轮一个子目录，含 `design-prompt.md`（给 Claude Design 的设计简报）、每个画板一个 `.dc.html` 源、`canvas.json` 布局与每个画板一张 PNG 快照；`design/README.md` 是画板索引（编号、名称、`.dc.html`、PNG、画布 URL），画板编号只增不改。`.dc.html` 是设计的唯一事实来源，PNG 是审查与验收的基准，画布上的后续改动不影响已开工轮次；改设计走「先拉回 `.dc.html`、重导 PNG、更新索引，再进轮次」。
- 页面：会话工作台（消息、思考、工具卡、计划、用量、权限与 elicitation；顶栏的项目与分支切换）；agent 管理（registry、custom、认证状态）；文件面板（含终端面板）；设置；ACP 流量调试。
- 画板要求、文档原本没有的几项，所有者 2026-09-15 按 `ROUNDS.md` § 6 的推荐一并裁定：
  - **项目** = 一个本地目录，作为 `session/new` 的 cwd；顶栏可在已打开项目、最近项目（本地列表）与 `file_selector` 选目录之间切换；不做 Zed 的 worktree 模型。
  - **分支**：顶栏显示当前分支，弹层列本地分支、可搜索、可切换与新建（`git switch` / `git switch -c`）；非 git 目录整块隐藏。
  - **窗口控制**（— ☐ ✕ 画在应用顶栏，即无边框窗口）：Windows runner 自写平台通道（`WM_NCHITTEST` 拖拽区 + 最小化 / 最大化 / 关闭三个方法），不引 `window_manager` 类库；macOS 用原生 traffic lights。
  - **`Rules` 行**（画板 30 / 40 的用量弹层）：当前项目根目录下规则文件的计数（AGENTS.md、CLAUDE.md、`.rules`；清单在 R3 任务卡定），点击在文件面板打开。
  - **文件树 git 状态徽章**（画板 60）：保留，由 `git status --porcelain` 得出。
  - **`+` 弹层**只有 Files & Directories / Threads / Image / Branch Diff 四项；原稿的 Symbols 与 Selection 需要 LSP 与编辑器选区，与 `requirements.md`「不做」冲突，已从画板 40 删除。
  - **终端面板**（画板 61）含本地交互 shell、多标签；复用 `rust/pty` 与 `acp/terminal_output`，命令见 § 3。
  - **分栏宽度**（画板 01–03 的两条分栏线，所有者裁定 2026-09-16）：拖拽命中区 4px 叠在 1px 分栏线上、**不占布局**；侧栏 220–480、右栏 360–900、中栏至少留 360（窗口变窄时先压右栏、再压侧栏）；双击复位到 280 / 580；宽度记在 `ui-state.json`。把手的默认与悬停态见画板 04。
- 接后端只换数据源，不改样式：接线轮里 `lib/theme/tokens.dart` 与画板 widget 文件应零 diff。

## 10. 数据目录

Windows：`%APPDATA%/AcpAgentClient/{settings.json, sessions.json, projects.json, ui-state.json, registry-cache/, agents/, node/, logs/}`。会话数据归各 agent 自己（claude、codex、pi、dsh 各有自己的存储）；本客户端只存会话索引 `sessions.json`（agentId + sessionId + 标题 + cwd + 时间 + 消息计数）与最近项目列表 `projects.json`，两者都走临时文件 + rename。日志脱敏：`Authorization`、`api_key`、`token` 字段一律打码。

`ui-state.json` 是窗口的机器态（目前只有两栏宽度），同样走临时文件 + rename。它与 `settings.json` 分开：后者是用户手写的配置（`agent_servers` 与 Zed 同形），不该被拖窗口改写。字段一律可缺省，缺省宽度与夹取范围只在前端 token 里（`lib/theme/tokens.dart`），核心不复制一份；读不动或不是合法 JSON 时按缺省重建，不挡启动。

## 11. 阶段草案（已取代）

本节的草案已于 2026-09-15 由仓库根 [`ROUNDS.md`](../ROUNDS.md) 取代：设计稿（40 张画板）收口后，实现拆成 R0–R8（含 R1.5 spike），每张画板归属恰好一轮，各轮的验收、裁定门与契约变更都在那里。本节不再维护，编号沿革只记一句：原草案的 R6（sidecar）与 R7（打包）在 `ROUNDS.md` 里是 R7 与 R8，其余编号含义不变。

## 12. 风险与对策

| 风险 | 对策 |
|---|---|
| Windows 上 npx 类 agent 的 `.cmd` 包装与引号 | R1 第一项验收就是用 dsh 在 Windows 实测；转写 Zed `ShellBuilder` 的处理 |
| Flutter 构建链（CMake → cargokit → cargo）在含中文与全角括号的用户名路径下失败 | R0 第一项验收；失败则在 `flutter_rust_bridge.yaml` / CMake 里把 `CARGO_TARGET_DIR` 指到纯 ASCII 路径 |
| Flutter 侧 Markdown 渲染不如 Web 成熟（流式、高亮、选择复制） | R1.5 spike 已做并裁定（2026-09-15，见 § 9）；R2 的自写渲染层按 spike 的判据（流式不闪、SelectionArea、链接、CJK）逐项验收 |
| Rust panic 会带倒整个 Flutter 进程 | 核心对外 API 边界统一 `catch_unwind` 转 `Result`；agent 子进程崩溃只上报 `acp/agent_state` |
| Windows 中文 IME 组合窗与转录跨消息文本选择 | R0 / R2 各实测一次记录；设计稿有「复制整段」按钮可绕过大部分选择需求 |
| `unstable` 特性集漂移 | 钉 rust-sdk commit；改钉先改 `pins/upstream.json` 与 `research.md` |
| sidecar 与运行中的 Zed 争用 `threads.db` | R7 实测后裁定：只读共用 / 隔离目录二选一 |
| Zed 构建环境重 | sidecar 独立 workspace，主程序不依赖它也能跑；CI 分开 |
| 设计稿范围蔓延 | 画板编号只增不改；设计稿没有的功能进 BACKLOG |
