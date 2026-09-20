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
         ├── dsh-acp-interactive  custom（核心内建条目，§ 6 第 6 条）
         └── zed-agent-acp        sidecar（GPL；headless gpui + Zed NativeAgent；随主程序打包；核心内建条目）
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
| Node 与下载 | Zed `node_runtime`、`http_client/github_download.rs`、`util/archive.rs` | 原定直接 git 依赖（不含 gpui）；R5 实施时改为**参考转写**到 `rust/registry/src/{node,install,archive}.rs`（reqwest + sha2 + 系统 `tar`）：Zed 的 `node_runtime` 把受管 Node 写到它自己的 `paths::data_dir()`、拉进 smol / async-std 第二套运行时与 Zed 整仓 git 依赖，与「数据目录只多 `node/`」和 tokio 单运行时冲突。R5 任务卡「偏离」段记理由，待所有者确认 |
| 连接与认证语义 | Zed `agent_servers/acp.rs` 非测试部分 | 转写：能力声明、AuthRequired 映射、terminal auth、session 控制、config options、elicitation、流量日志 |
| 终端回调语义 | Zed `acp_thread/terminal.rs` | 转写：输出字节上限、wait_for_exit、kill、release |
| 文件面板 | 自研 | `std::fs` + `notify`；不做索引服务 |
| git（分支列表 / 切换 / 新建、文件树状态徽章、Branch Diff 上下文） | 自研 | `git` CLI 子进程薄封装（放 `rust/fs`），不引 git 库；检测不到 git 或目录不是仓库时相关 UI 隐藏（所有者裁定 2026-09-15） |
| Zed 内置 agent | Zed `agent` + `eval_cli` | sidecar，见 § 8 |
| UI | Claude Design 设计稿 | 全部自研；token 提炼到 `lib/theme/tokens.dart`，每个画板一个 widget 文件（同一卡片的状态画板可合一文件，文件头列画板号；画板 → 轮次 → 文件的对应表见 `ROUNDS.md` § 2） |

## 3. 核心与前端的契约（严格 ACP 投影）

> 可投影内容的完整清单（15 个 `session/update` 变体、能力门总表、协议不给必须自造的 8 项、容错与丢失风险）见 [`acp-projection.md`](acp-projection.md)；本节只定契约形状。

**传输形状**：每个事件是一条 frb `StreamSink<String>`，每个命令是一个 frb `async fn(...) -> Result<String>`；`String` 里是下表的 JSON。Dart 侧 `jsonDecode` 后进投影状态层，不在桥层做任何类型镜像。

**事件（核心 → 前端）**

| 事件 | payload |
|---|---|
| `acp/session_update` | `SessionNotification` 的原样 JSON（SDK 类型 serde 直出：`{sessionId, update, _meta?}`）**再加一个 `agentId`**，不另套一层（R3 接线时对齐，核心侧见 `rust/acp-core/src/agent.rs`） |
| `acp/client_request` | `{agentId, requestId, method, params}`；用于需要用户参与的客户端请求：`session/request_permission`、`elicitation/create`；`elicitation/create` 可能是 requestScope（无 `sessionId`，认证阶段），前端队列不能只按会话索引，这类落认证页（画板 52）而不是转录；前端必须以 `acp_respond` 回应。**`requestId` 为 null 的是 agent 发来的通知**，不需回应，只更新队列：`elicitation/complete`（URL elicitation 收尾）与 `$/cancel_request`（agent 撤回了自己的请求，`params.requestId` 已归一化成与队列 `requestId` 同形的字符串——协议原样可能是数字——前端按它把请求从队列移除）（R1） |
| `acp/agent_state` | 连接生命周期 `{agentId, state, droppedUpdates, ...}`：`spawned(pid, program, args, cwd)` / `initialized(initialize)`（InitializeResponse 原样）/ `auth_required(authMethods, message)` / `authenticating(methodId, terminalId, label)`（terminal auth 的 pty 已拉起）/ `update_dropped(method, error)`（一条 `session/update` 反序列化失败，`droppedUpdates` 已 +1，§ 4）/ `exited(code, stderrTail, transportError)`；每条都带 `droppedUpdates` 计数（R1）。核心自身也走这条流：`core_init` 完成时发 `{agentId: null, state: "core_ready", dataDir, coreVersion}`（R0，验证事件通路） |
| `acp/terminal_output` | `{terminalId, source, bytes}`（`bytes` 是 base64 的原始字节）或进程结束时的 `{terminalId, source, exitStatus: {exitCode, signal}}`；`source` ∈ agent（`terminal/*` 回调建的终端）/ auth（terminal auth 的可见终端，R1）/ local（终端面板的本地 shell）；非协议消息，仅用于渲染（R4 补齐 agent / local 两路） |
| `acp/traffic` | `{agentId, direction, line, ts}`：`direction` ∈ in（agent stdout）/ out（agent stdin）/ stderr，`line` 是脱敏后的原始行（`Authorization` / `api_key` / `token` 类键的值打成 `***`，规则 8），`ts` 毫秒时间戳；供调试面板（R1） |
| `registry/progress` | 安装进度 `{agentId, kind, step, done?, total?, detail?, error?}`：`kind` ∈ npx / binary / node；npx 的 `step` 依次是 resolve（`npm install` 到 `agents/<id>/`）/ write_settings / handshake（首次拉起并 `initialize`），binary 是 download（`done` / `total` 字节）/ verify（sha256）/ extract，受管 Node 是 node_download / node_extract（`agentId` 为 null）；收尾一律 done / failed（带 `error`）/ cancelled。前端按 `agentId` 把最近一条落到条目上（画板 51），速率与剩余时间由前端按 `done` 的时间差估算（R5） |

**命令（前端 → 核心）**

- 连接与会话：`agent_connect`、`agent_disconnect`、`session_new`、`session_load`、`session_list`（cursor 分页）、`session_resume`、`session_close`、`session_delete`、`session_prompt`、`session_cancel`、`session_set_mode`、`session_set_config_option`、`acp_respond`
- 认证：`authenticate`（agent 类型）、`terminal_auth_run`（terminal 类型；完成后核心自动重试 `session/new`）
- registry、Node 与设置：`registry_refresh`（1 小时节流，`force` 跳过）、`registry_list`（registry 条目 + settings 里的 custom 条目，各带本地安装 / 认证状态）、`registry_install`、`registry_cancel_install`、`registry_remove`（移除 settings 条目并只删自己写的 `agents/<id>/`）、`node_status`、`node_download`、`agent_settings_get/set/remove`、`agent_settings_import_zed`（R5 补 `agent_settings_remove`：custom 条目从设置页删除，与 `registry_remove` 同一条路径但不碰 `agents/`）
- 文件面板与 git：`fs_list_dir`、`fs_read`（查看器：`{path, text, size, lines, binary, truncated}`，超 2 MiB 只给前一段）、`fs_watch` / `fs_unwatch`（R4：`fs_watch` 是**流命令**——frb 的 `StreamSink`，每批去抖后的变化推一条 `{root, dirs: [绝对路径…], git}`，`dirs` 是内容变了的目录、`git` = `.git` 之下有变化；取消流即停，不另开事件通道）、`fs_search`、`git_status`（文件树徽章：`{available, isRepo, root, entries: [{path, badge, code}]}`）、`git_branches`、`git_switch`、`git_create_branch`、`git_diff`（Branch Diff 上下文）
- 本地 shell 与终端控制（终端面板）：`terminal_open`（`{terminalId, cwd, program}`，系统默认 shell）、`terminal_write`、`terminal_resize`、`terminal_close`（kill + 释放）、`terminal_kill`（R4：只结束进程不释放 = `terminal/kill` 语义；画板 23 的停止方块对 agent 建的终端也用它）；输出走 `acp/terminal_output`（`terminal_write` 在 R1 先出：terminal auth 的可见终端要接键盘输入）
- 退出收尾：`core_shutdown`（R4：释放全部终端、断开全部 agent、停掉目录监视；Dart 在 `AppLifecycleListener.onExitRequested` 里等它回来再放行）
- 开发期排查：`agents_status`（每个已连接 agent 的 `droppedUpdates` / 退出状态 / 挂起请求；R1，无头实跑与 `acp-smoke` 用）
- 项目与本地索引：`workspace_recent`、`workspace_open`、`session_index_list/upsert/remove`（会话索引：agentId + sessionId + 标题 + cwd + 时间 + 消息计数）
- 窗口 UI 状态：`ui_state_get`、`ui_state_set`（合并写；载荷 `{sidebarWidth?, rightPanelWidth?, filesTreeWidth?, filesTreeCollapsed?}`，缺省与夹取范围都在前端 token，核心不存第二份）

命令名以本节为准，各轮只实现自己那部分（归属见 `ROUNDS.md` § 3 / § 5）；R3–R6 的新增项是 2026-09-15 按画板裁定后一次写入的，不再逐轮改契约。每条命令的入参形状（哪些是 JSON 字符串、哪些是标量）与返回 JSON 以 `rust/bridge/src/api.rs` 的文档注释为准；错误统一是 `BridgeError {code, message}`，`code` 是 `CoreError::code()` 的稳定短码（`auth_required` / `exited` / `not_connected` / `unknown_request` / `acp` 等）。

**前端状态规则**

- 按 `sessionId` 累积 `update`；`tool_call` 与 `tool_call_update` 按协议合并（同 id 覆盖，content 为替换语义）。
- `user_message_chunk` / `agent_message_chunk` / `agent_thought_chunk` 按顺序追加。
- **用户消息由客户端在 `session/prompt` 发出时本地回显**（acp-projection.md § 7 第 8 条）：一等 agent 只在 `session/load` 的重放里发 `user_message_chunk`，不本地回显的话实时一轮里转录只有轮边界、没有用户气泡。重放来的同一批块按块内容去重并认领 `messageId`（照 Zed）。
- 待处理的 permission 与 elicitation 是队列，回应后出队。
- 不在前端做任何 agent 特判。
- 待处理队列按 `sessionId` 索引，另有一个无会话的 requestScope 队列（认证阶段的 elicitation）。
- 工具调用「已取消」是前端本地态（`ToolCallStatus` 没有 cancelled）：发出 `session/cancel` 后把本轮未完成的工具卡标 cancelled，核心不伪造状态。
- 用户消息上的 Restore 与 Regenerate（画板 11）= 本地截断其后的投影块并在同一会话重发 prompt；协议没有回滚，agent 侧上下文不回退，这是已知限制（所有者裁定 2026-09-15）。**画板 10 的 Restore Checkpoint 分隔线已废弃**（所有者裁定 2026-09-17）：我们没有 git checkpoint（Zed 那条线恢复的是项目文件），它点下去与画板 11 的 Restore 完全同一个动作，轮开始因此不再画任何东西。
- `session/load` 的重放只带回 agent 侧的 `session/update`：轮边界（`TurnEntry` / `stopReason` / 回合级 usage）、权限卡与 elicitation 卡是客户端按自己发出的请求造的，**回不来**；也不在本地补一份轮边界——不造协议之外的状态（所有者裁定 2026-09-16，R6）。Restore / Regenerate 因此**不按轮边界定位**：截断点是那条用户气泡自己（气泡前面紧挨着轮边界时一起截掉，重发用轮记下的那批块），载回来的历史照样能重发（所有者报障 2026-09-18：按轮定位时重开应用后每条气泡的 ↺ 与 Regenerate 都是点了毫无反应的死键）。
- `session/close` 之后会话是**只读**的：转录留着，但 prompt / Restore / Regenerate / 三个下拉 / 停止方块都不再发命令，直到 `session/resume` 把它挂回来（R6；`session/resume` 只对没在本连接上活着的会话有效，实测 dsh 1.3.0 对活着的回 `-32602`）。
- `/` 命令菜单单组渲染：`AvailableCommand` 没有分组与来源字段，不按名字猜分组（所有者裁定 2026-09-15）。
- 侧栏会话列表以本地索引为准；`session/list` 只用来校对存在性与补标题，agent 有、本地没有的会话不自动出现（所有者裁定 2026-09-15，R6）。
- 侧栏只列**当前项目目录**下的会话（2026-09-18，所有者报障）：按索引里的 cwd 与当前项目路径归一后比（分隔符 / 尾斜杠 / Windows 大小写），没记 cwd 的老条目各处都列；换项目时正开着的会话若属于别的目录就从线程区放下（不关、不取消，agent 侧照跑），下一条消息在新目录里现开会话；等待期（`session/new` / 重载在途）里不换项目。
- 侧栏按**用户最后一次发消息的时间**倒序（所有者裁定 2026-09-18）：索引 `updatedAt` 的口径就是它，`send()` / Restore 在 `startTurn` 之后、`session/prompt` 之前打一次（不 await，`startTurn` 与 `_runTurn` 之间不能有异步间隙）；收轮、改名、补标题都沿用索引里已有的值，不再把会话顶上去；新会话由核心打创建时间、排最上面。侧栏的「N 分钟前」因此是「上次发消息距今」。此前按「最近收轮 / 最近改名」排，早发出、晚跑完的会话会在收轮时跳到前面。
- 侧栏的删除图标**一律给**（2026-09-18，替代 R6「无 `sessionCapabilities.delete` 不出图标」）：本地索引总能删；agent 已连上且声明了 delete 时顺带发 `session/delete`，agent 侧删不掉（报错或没连）不锁死本地记录。R6 那条裁剪的结果是没声明 delete 的 agent 的会话在侧栏里永远清不掉。
- 新建会话**不重连 agent**（2026-09-18）：线程头 `+` 选 agent 与 `send()` 现开会话都走 `_ensureConnected`（没连才连），不再断开重拉——另一条会话正在跑的那一轮不会被杀；两个触发共用画板 05 B 组的等待期（`waitingForAgent`）。重载 agent（线程头 reload）仍是断开 + 重拉；重载 / 崩溃之后内存里其它会话拿的还是旧进程的 sessionId，记 BACKLOG 等单独一轮。
- 一轮**没走到协议结束值**时的失败原因是本地态（2026-09-18）：`session/prompt` 回 JSON-RPC error（实测 dsh 的 `-32602 model does not declare image input`、`-32603 turn failed …`）时原文落在 `TurnEntry.error`，画板 31 的结束行多一档「失败」徽章显示它，不再只剩一个 `?` 徽章；设计稿待补这一态（BACKLOG）。
- 会话配置（`config_option_update`）按**固定档序平铺**（所有者裁定 2026-09-18，替代 R3「模型 / 思考强度 / 模式三个固定下拉 + 未知分类一个面板」）：`mode → model → model_config → thought_level → 其余`，档内保持数组顺序，一条 configOption 一格，`boolean` 就地开关，未知 `type` 整条忽略。依据是旧渲染下五个 agent 里四个丢格（dsh 的 `permission`、codex 的 `collaboration_mode`、claude 的 `agent` / `fast`、cursor 的 `fast`）。modes 回退（R6）不变：只在没有 `category == mode` 的 configOption、且没有任何 `select` 型 configOption 的可选值集合与 modes 完全相同（超集不算）时，才用 `current_mode_update` 合成一格，排在 mode 档头一格、经 `session/set_mode` 发；判重只看值集合、不看 agent 名（pi 曾因此出两个思考强度下拉，2026-09-17）。

## 4. initialize 能力声明

照 Zed 的 `client_capabilities_for_agent`：`fs.readTextFile`、`fs.writeTextFile`、`terminal`、`auth.terminal`、`session.configOptions.boolean`、`elicitation.form`、`elicitation.url`；`_meta` 里 `terminal_output: true`、`terminal-auth: true`。对 Cursor 追加参数化模型选择器键 `parameterizedModelPicker: true`（Zed 的 `PARAMETERIZED_MODEL_PICKER_META_KEY`）。**这是允许的 `_meta` 键的全部清单**，增加新键要改本节并进所有者裁定。

比 Zed 多声明两个 unstable 客户端能力（所有者裁定 2026-09-11，依据「多数 agent 已支持 plan 与压缩」）：

- `plan: {}` → 打开 `plan_update` / `plan_removed`（多计划、可增量、支持 items / file / markdown 三种载荷；codex-acp 已在发）；稳定的 `plan` 整份替换继续兼容。
- `session.compaction: {}` → 打开 `compaction_update` / `compaction_summary_chunk`（上下文压缩过程与保留摘要可见）。

两者都在 rust-sdk `unstable` 伞内（`unstable_plan_operations`、`unstable_session_compaction`），不改 feature 集，不触发规则 4 / 10。会话流可投影内容的完整清单见 [`acp-projection.md`](acp-projection.md)。

**`notice` 的处置（所有者裁定 2026-09-11）**：sdk 的 `unstable` 不转发 `unstable_session_notices`，`SessionUpdate::Notice` 编译不出来，收到即反序列化失败。不为它改 feature 集；核心侧对反序列化失败的 `session/update` 计数并经 `acp/agent_state` 上抛告警，原文落 `acp/traffic` 供排查。R1 用 dsh 实测一次后复议。

**入站 `_meta` 识别键（所有者裁定 2026-09-15）**：上面的清单是我们**发出**的 `_meta`。前端**读取**的入站 `_meta` 键也只有这一份清单：`claudeCode.parentToolUseId` / `claudeCode.subagent` / `claudeCode.toolName`（claude-agent-acp 的子代理标记）与 `dsh_subagent`（dsh-acp-interactive）。投影层只按「键是否存在」把工具调用归到子代理卡（画板 24）之下，不按 agent 名判；其余入站 `_meta` 原样保留、不解释。增减键改本段并进所有者裁定。

**终端 provider 通道（R4 按推荐项开工，所有者裁定待确认）**：`tool_call` / `tool_call_update` 的 `_meta.terminal_info {terminal_id, cwd?}` / `terminal_output {terminal_id, data}` / `terminal_exit {terminal_id, exit_code? | signal?}`。这是 Zed `agent_servers/acp.rs` `handle_session_notification` 的 post-handle 读的三键；钉版本的 claude-agent-acp、dsh-acp-interactive、codex-acp 都**不调 `terminal/create`**，而是在自己进程里跑命令、经这三键把输出送来（客户端声明 `_meta.terminal_output: true` 时）。投影层只按键存在处理：`terminal_output.data` 追加进该 `terminal_id` 的终端缓冲（与 `terminal/create` 路径同一份 `TerminalBuffer`，画板 22 / 23 不分数据源）、`terminal_exit` 收尾、`terminal_info.cwd` 作卡片副标题；不按 agent 名判。

## 5. 认证流程

1. `session/new` 返回 `AuthRequired` → 展示 `initialize` 返回的 `authMethods`。
2. 方法类型为 `agent` → 调 `authenticate`，agent 自己开浏览器；成功后重试 `session/new`。
3. 方法类型为 `terminal` → 在可见终端里跑给定命令；进程退出后重试 `session/new`。兼容旧版 `_meta.terminal-auth`。
4. URL elicitation（codex-acp 登录）走 § 3 的 `acp/client_request`，前端打开系统浏览器并等待 `elicitation/complete`。
5. **落点与收尾（R5，画板 52）**：以上全部落在认证页（右栏 Agents 标签内、对应 agent 的一页），不落转录。入口有三：`session/new` 回 `-32000`（自动切到认证页并记下要重试的 cwd）、画板 51「需要认证」条目的登录键、画板 34 状态条的登录键。requestScope 的 `elicitation/create`（无 `sessionId`，`requestId` 是在途 `authenticate` 的请求 id）到达即在认证页出卡片；用户点开浏览器 = 回 `accept` 并 `url_launcher` 打开，`elicitation/complete` 到达把卡片标完成。`authenticate` / terminal auth 成功后核心（terminal 型）或前端（agent 型）自动重试原来的 `session/new` 并回到工作台；失败态可重试、可换方式；取消回到 registry 列表。认证状态是本地态：`session/new` 成功记「已登录」、`-32000` 记「需要认证」，只对 registry 型条目记（`agents/<id>/install.json`），不做任何 agent 特判。

## 6. registry 与安装

1. 拉取：`registry.json` 1 小时节流，磁盘缓存，图标按需拉取；结构体对照 `agent.schema.json`。
2. 列表：按当前平台过滤 `binary` 的 target；`uvx` 条目显示但标「暂不支持」。
3. 安装：`npx` 解析包名与版本，`npm install` 到 `agents/<id>/`（照 Zed：装成本地 `node_modules` 再以 `node <bin>` 拉起，不走 `npx` 的临时缓存），写入 settings（`{type: "registry"}`），首次拉起并 `initialize`；`binary` 下载压缩包 → 校验 sha256（条目没给 sha256 时跳过并记明）→ 解压到 `agents/<id>/<version>/` → 记录 `cmd` / `args` / `env`。两型都把安装记录写在 `agents/<id>/install.json`（拉起参数 + 认证状态），settings 里只有 Zed 同形的 registry 条目；Remove 删 settings 条目与 `agents/<id>/`。写入 settings 是提交点：之后的取消不再把装好的结果报成 cancelled；首次握手失败或被取消则回滚成没装过（删 `agents/<id>/`，settings 条目只删本次新建的），Remove 在安装任务还没退出时拒绝而不是抢着删目录（R5 审查）。
4. Node：优先系统 Node ≥ 22；缺失时下载受管 Node v24.11.0 到数据目录 `node/`（语义照 Zed `node_runtime`：nodejs.org 官方压缩包、按平台取 zip / tar.gz、装好后以 `node --version` 自检；R5 按参考转写落在 `rust/registry/src/node.rs`，理由见任务卡「偏离」）。解压统一走系统 `tar`（Windows 10 1803+ 自带 bsdtar，zip 与 tar.gz 都认）。
5. 设置：`agent_servers` 与 Zed 同 schema（`type: registry | custom`），提供从 `%APPDATA%/Zed/settings.json` 导入。
6. **内置条目（`rust/acp-core/src/builtin.rs`）**：官方 registry 里没有、但本项目一等的两个 agent，由核心合成成 `type: custom` 条目并入列表，**不落 `settings.json`**。① `zed`（§ 8 的 sidecar，随包分发；可执行文件不在就整条不出现）；② `dsh-acp-interactive`（所有者裁定 2026-09-17：registry 里没有它，不内建就只能让用户手改 `settings.json`）——拉起三选一：`ACP_DSH_PATH` 指到的文件 → PATH 上全局安装的 `dsh-acp-interactive` → `npx -y deepseekharness-acp-interactive@<pins 里的版本>`，所以**本机没装也一直在列**（缺 Node 时拉起失败，由画板 50 的受管 Node 卡兜）。两条都带 `_meta` 同形的 `builtin: true` / `name` / `iconSvg`（图标随包带，`rust/acp-core/assets/`）；前端据 `builtin` **不画**「编辑」与 Remove（画板 50 / 70），核心侧 `agent_settings_set` / `agent_settings_remove` 再挡一道。用户自己在 `settings.json` 里写过同名条目时**他那条优先**，且照常可编辑可删 —— 删完剩下的就是内置条目。

## 7. 终端与 fs

- pty：portable-pty；每个终端有输出字节上限（`terminal/create.outputByteLimit`，缺省只受 4 MiB 的绝对上限约束）；**截断从头截、落在 UTF-8 字符边界**（规范原文；Zed 的 `truncated_output` 是从尾截，本项目按规范）；`terminal/output` 返回的文本去掉 ANSI 转义、`\r\n` 归一成 `\n`；`terminal/kill` 结束进程但句柄与输出留存，`terminal/release` 才释放（还在跑的先 kill）；kill 的成败以进程真的退出为准（portable-pty 0.9.0 的 Windows `kill` 把 TerminateProcess 的成败判反了，成功时带回陈旧的 GetLastError，R4 实测见过 os error 0 / 6），最多等 5 s；**终端嵌进工具卡后即使 release 也继续显示输出**——前端的 `TerminalBuffer` 跟工具卡走、自己留存一份，核心侧 release 后不再持有。agent 只许碰自己建的终端；agent 断开 / 退出时它建的终端一并释放。命令经系统默认 shell 拼装（`rust/pty/src/shell.rs`，转写 Zed `ShellBuilder`：Windows 首选 PowerShell `-C "$null | & {<command> <args>}"`，退到 `cmd /S /C`；其他平台 `sh -c "exec </dev/null\n…"`），`.cmd` 包装与引号处理在 Windows 实测（R4 任务卡）。
- fs：路径必须是绝对路径且在会话工作目录之内（越界 `-32602`）；`line` / `limit` 是 1-based（行的口径照 Zed：末尾换行之后算一个空行，起点落在最后一行之后 `-32602`）；文件不存在 `-32002`；写文件不存在则创建、父目录一并创建，直接落盘（temp + rename）。

## 8. zed-agent-acp sidecar

- 独立 cargo workspace（`sidecar/zed-agent-acp/`），path 依赖指向 `vendor/upstream/zed/crates/*`；GPL-3.0-or-later。
- 引导：复制 `eval_cli/src/headless.rs`；`session/new` 时 `Project::local` + `create_worktree(cwd)` + `NativeAgent::new`。
- 映射：`initialize` → 固定能力（`loadSession` + `sessionCapabilities.{list, delete, resume, close}`，`authMethods` 空）；`session/new` / `session/load` / `session/list` / `session/delete` → `NativeAgentConnection` 与 `ThreadStore`；`session/resume` = load 的不重放版；`session/close` = 放掉 `AcpThread` 引用；`session/prompt` → `Thread::send` 得到 `ThreadEvent` 流；`session/cancel` → `Thread::cancel`；模型选择走 **config options**（一个 `select`，id `model`），**不**声明 `modes`。
- 事件翻译：`ThreadEvent::{UserMessage, AgentText, AgentThinking, ToolCall, ToolCallUpdate, SubagentSpawned, Retry, ContextCompaction*}` → `session/update`；`ToolCallAuthorization` → `session/request_permission`，结果写回 `response`；`Elicitation` → `elicitation/create`；`Stop` → `PromptResponse`。
- 终端：沿用 Zed 的 `NativeThreadEnvironment::create_terminal`（进程内 `terminal` crate），输出经 § 4 的 `_meta.terminal_info / terminal_output / terminal_exit` 三键推给客户端 —— 终端是 agent 进程内的，客户端没有它的句柄，不能走 `terminal/*`。
- **数据（R7 实测后按推荐项落地 2026-09-17，待所有者确认）：配置共用、数据隔离。** sidecar 以
  `--zed-settings <%APPDATA%/Zed/settings.json>` **只读**沿用 Zed 的模型与密钥配置（所有者裁定 2026-09-15），
  但以 `--user-data-dir <本应用数据目录>/zed-agent` 把 `threads.db` / `db/` / `prompts/` 与本机 Zed 隔开。
  依据：与运行中的 Zed 共用 `threads.db` 时，两边同时写会让 **Zed 那边**保存线程失败 —— Zed 日志里出现
  `Sqlite call failed with code 5 … database is locked`（`crates/agent/src/agent.rs` 的保存路径），
  本 sidecar 侧没报错，即代价由用户的编辑器承担（CLAUDE.md 规则 7：不拿用户数据冒险）。
  代价要认：**两边的会话列表不互通**（Zed 里建的线程在本客户端看不到，反之亦然）。要共用的话把
  `--user-data-dir` 参数去掉即可（`rust/acp-core/src/builtin.rs`），行为回到「全共用」。
- 打包：在 `windows/CMakeLists.txt`（macOS / Linux 对应 runner）加 install 规则，把 `build/sidecar/zed-agent-acp(.exe)` 放到应用目录旁随主程序分发（缺了不报错）；核心按可执行文件相对路径定位它，开发期可用 `ACP_ZED_SIDECAR` 环境变量覆盖路径（`rounds/round-07/round-07.md` 偏离 4）。构建用 `scripts/build-sidecar.ps1`。
- 进程生命周期：sidecar 由主程序按 stdio 拉起；stdin EOF（主程序退出或 `agent_disconnect`）时 `connect_with` 的 `main_fn` 跟着返回、进程退出，不留孤儿（2026-09-17 修：此前主程序关掉后 `zed-agent-acp.exe` 还活着）。

## 9. 前端

- **Flutter stable（Dart）+ flutter_rust_bridge v2**（所有者裁定 2026-09-12，替代 2026-09-11 裁定的 Tauri + React 19）。改的原因：设计稿只作视觉基准（`.dc.html` 源与 PNG 入库）、不复用其代码，前端框架不再被「设计稿是 HTML」绑定；Flutter 不依赖 WebView2，渲染与列表虚拟化是原生能力；Rust 核心以 cdylib 进程内加载，契约不变。2026-09-14 设计工具由 Figma Make 改回 Claude Design，此裁定不变。代价与风险见 § 12。
- 流式更新的性能靠三件事：投影状态层是纯 Dart 类（不依赖 widget 树），widget 用 `ListenableBuilder` / `StreamBuilder` 选择性订阅；`session/update` 按帧批量合并；转录列表用 `ListView.builder` 惰性构建。
- 通用库允许清单见 CLAUDE.md 规则 1；**不引第三方 UI 组件库与状态管理库**，组件全部从画板手写，状态用 SDK 自带的 `ChangeNotifier` / `Stream`；样式的唯一来源是从画板提炼的 `lib/theme/tokens.dart`（颜色、字号、间距、圆角、动效时长），widget 文件里不出现字面量。
- Markdown 渲染：官方 `flutter_markdown` 已停止维护，社区替代对**流式追加**与代码高亮的支持参差。R1.5 spike（`rounds/round-1.5/spike.md`）比较了 `package:markdown` 自写渲染、`markdown_widget`、`gpt_markdown`、`flutter_markdown_plus`、`streamdown` 五个候选，所有者裁定 2026-09-15：**`package:markdown` 只用解析器，渲染层按画板自写**（每个顶层块带 key，样式全从 `tokens.dart` 来）；代码高亮 `re_highlight`，公式 `flutter_math_fork`（`$…$` / `$$…$$` 的识别在 Markdown 层做），Mermaid `mermaid_flutter` + `mermaid_core`（解析失败经 `errorBuilder` 回落源码态），音频块 `audioplayers`（内存 `BytesSource`），diff `diffutil_dart`；画板 15 / 32 不改。
- 终端渲染用 `xterm`（pub.dev）；PTY 仍在 Rust 侧 portable-pty，`acp/terminal_output` 推字节，Dart 只渲染。文件对话框与打开 URL 用 Flutter 官方 `file_selector` / `url_launcher`，其余系统交互一律走 Rust。
- ACP 投影的状态层自己写，约五百行，是唯一不允许第三方替代的部分；规则来自 `prototype/assets/projection.js`。
- 设计稿存 `design/`：每轮一个子目录，含 `design-prompt.md`（给 Claude Design 的设计简报）、每个画板一个 `.dc.html` 源、`canvas.json` 布局与每个画板一张 PNG 快照；`design/README.md` 是画板索引（编号、名称、`.dc.html`、PNG、画布 URL），画板编号只增不改。`.dc.html` 是设计的唯一事实来源，PNG 是审查与验收的基准，画布上的后续改动不影响已开工轮次；改设计走「先拉回 `.dc.html`、重导 PNG、更新索引，再进轮次」。
- 页面：会话工作台（消息、思考、工具卡、计划、用量、权限与 elicitation；顶栏的项目与分支切换；线程头 history 开画板 43 的会话时间线弹层）；右栏三个标签——文件面板（含终端面板）、agent 管理（registry、custom、认证状态）、设置（2026-09-17 起也是右栏标签）；ACP 流量调试（占会话区，从画板 34 的入口进、点侧栏会话返回）。
- 画板要求、文档原本没有的几项，所有者 2026-09-15 按 `ROUNDS.md` § 6 的推荐一并裁定：
  - **项目** = 一个本地目录，作为 `session/new` 的 cwd；顶栏可在已打开项目、最近项目（本地列表）与 `file_selector` 选目录之间切换；不做 Zed 的 worktree 模型。侧栏只列当前项目目录下的会话，换项目时别的目录的会话不露出、正开着的那条放下回空态（2026-09-18，规则在 § 3）。
  - **分支**：顶栏显示当前分支，弹层列本地分支、可搜索、可切换与新建（`git switch` / `git switch -c`）；非 git 目录整块隐藏。
  - **窗口控制**（— ☐ ✕ 画在应用顶栏，即无边框窗口）：Windows runner 自写平台通道（`WM_NCHITTEST` 拖拽区 + 最小化 / 最大化 / 关闭三个方法），不引 `window_manager` 类库；macOS 用原生 traffic lights。2026-09-17 / 18 补齐：缩放热区按 DPI 换算、四边四角都可拉（给 FLUTTERVIEW 子类化，缩放带上回 `HTTRANSPARENT`）、双击顶栏最大化 / 还原（`windows/runner/acp_window.cpp`）。
  - **`Rules` 行**（画板 30 / 40 的用量弹层）：当前项目根目录下规则文件的计数（AGENTS.md、CLAUDE.md、`.rules`；清单在 R3 任务卡定），点击在文件面板打开。
  - **文件树 git 状态徽章**（画板 60）：保留，由 `git status --porcelain` 得出。
  - **`+` 弹层**只有 Files & Directories / Threads / Image / Branch Diff 四项；原稿的 Symbols 与 Selection 需要 LSP 与编辑器选区，与 `requirements.md`「不做」冲突，已从画板 40 删除。
  - **图片粘贴与附件芯片条**（所有者 2026-09-18 直接要求，对齐 Zed）：输入框里 Ctrl/Cmd+V，剪贴板里是截图或图片文件就加成 ACP `image` 块（同样受 `promptCapabilities.image` 门，与 `+` 的 Image 一项共用），待发的 `image` 块以芯片显示在输入行之上、悬浮浮出原图预览、芯片上的 × 去掉它。Flutter 的 `Clipboard` 只给 text/plain，位图与文件列表读不到，第三方剪贴板包又在规则 1 的清单之外，所以 Windows（规则 9 首发）借 `powershell.exe` 读一次 `System.Windows.Forms.Clipboard`（位图存临时 PNG 再读回字节）；其他平台暂时读不到图，Ctrl+V 照旧只贴文本。**设计稿还没有这一条**，补稿记在 `rounds/BACKLOG.md`。
  - **终端面板**（画板 61）含本地交互 shell、多标签；复用 `rust/pty` 与 `acp/terminal_output`，命令见 § 3。
  - **分栏宽度**（画板 01–03 的两条分栏线，所有者裁定 2026-09-16）：拖拽命中区 4px 叠在 1px 分栏线上、**不占布局**；侧栏 220–480、右栏 360–900、中栏至少留 360（窗口变窄时先压右栏、再压侧栏）；双击复位到 280 / 580；宽度记在 `ui-state.json`。把手的默认与悬停态见画板 04。文件面板（画板 60）里树列与查看器之间用同一个把手：树列 160–480、查看器至少留 240，双击复位到 240；树列头行那个「缩小」按钮把整列收起（收起后由查看器头行左侧的按钮放回来），宽度与收起态同样记在 `ui-state.json`（所有者裁定 2026-09-17）。
  - **R7 合并后按所有者手测直接定下的交互**（2026-09-17 / 18；设计稿未改的都记在 `rounds/BACKLOG.md`「设计稿补注记」里）：输入框 Enter 发送、Shift+Enter 换行；转录默认跟着底部走、用户翻上去就停，转录区左右留白也在滚动区内；线程头的铅笔就在线程头上改标题；设置是右栏的一个标签（与文件 / Agents 并列），右栏没有关闭键，开合都交给侧栏底部导航；文件面板树列可拖、「缩小」是收起整列；agent 的标记（侧栏会话项、新建会话选 agent 弹层、画板 01 空态的大图标位）都画各 agent 自己的 logo（registry 缓存的 `icon.svg`，内置条目随包带）；侧栏顶部是正式标记（`design/brand/`）；终端面板的键盘输入走硬件按键（Windows 引擎拒了 xterm 的文本输入通道），中文输入法由自建的 `TerminalIme` 接（组字串暂不画在光标处）；终端卡跑完自动收起；弹层内容区封顶 `Geometry.menuMaxHeight` 并内部滚动、搜索框钉在滚动区外，Esc 与点外面都能关，`@` / `/` 菜单支持上下键与 Enter，裸 `@` 列会话 cwd 的一层；壳上 14 个入口有悬停提示（`lib/ui/shell/tooltip.dart`）；权限卡（画板 25）的范围下拉走 `PopoverAnchor` 浮在 Overlay 上（原来画在卡片自己的 Stack 里会被下一张卡压住），三个按钮上的 Alt-Shift-A / Alt-Shift-X / Ctrl-Alt-A 标签已去掉——它们从未接过按键，不做快捷键（所有者裁定 2026-09-18）；画板 05 的转场（新建 / 切换会话、重载 agent、右栏切标签、弹层）与画板 06 的侧栏活动指示（运行中扫掠线、完成未读绿点）已接线，新建会话与重载共用 B 组等待期（转录降到 `opacity.pending`、线程头 spinner）。
  - **字体**：Geist / Geist Mono 随包；CJK 回退随包的 Noto Sans SC（Regular 一档，OFL），不再让中文落到系统的 Microsoft YaHei UI（2026-09-18；原因与「别换成可变字体」的坑见 `pubspec.yaml` 注释）。
  - **会话时间线**（画板 43，2026-09-20）：线程头 reload 与 ≡ 之间一个 history 按钮，弹层按轮列「用户 query 首行 + 该轮最终回答首行（A）」，点一行转录区跳到那一条。轮的切分按**顶层用户消息**而不是 `TurnEntry`——轮边界只有客户端自己 `session/prompt` 时才放，`session/load` 重放回来的历史一条都没有（Restore 截断点踩过同一个坑）。整份是 `SessionStore.entries` 的纯派生，不新增 `docs/acp-projection.md` § 7 的自造态、不碰协议。
- 接后端只换数据源，不改样式：接线轮里 `lib/theme/tokens.dart` 与画板 widget 文件应零 diff。

## 10. 数据目录

Windows：`%APPDATA%/AcpAgentClient/{settings.json, sessions.json, projects.json, ui-state.json, registry-cache/, agents/, node/, logs/, zed-agent/}`。`registry-cache/` 放 `registry.json` 与 `icons/<id>.svg`；`zed-agent/` 是 sidecar 的隔离数据目录（`threads.db` / `db/` / `prompts/`，R7，§ 8）；`agents/<id>/` 放该 agent 的安装（npx 型的 `node_modules/`、binary 型的 `<version>/`）与 `install.json`；`node/` 放受管 Node；`logs/acp-<日期>.log` 是脱敏后的 ACP 流量行（与 `acp/traffic` 同源，规则 8），设置页（画板 70）给打开 / 复制路径（R5）。会话数据归各 agent 自己（claude、codex、pi、dsh 各有自己的存储）；本客户端只存会话索引 `sessions.json`（agentId + sessionId + 标题 + cwd + 时间 + 消息计数；「时间」= 用户最后一次发消息的时间，也是侧栏的排序键与 workspace 过滤的依据，§ 3）与最近项目列表 `projects.json`，两者都走临时文件 + rename。日志脱敏：`Authorization`、`api_key`、`token` 字段一律打码。

`ui-state.json` 是窗口的机器态（两栏宽度、文件面板树列的宽度与收起态），同样走临时文件 + rename。它与 `settings.json` 分开：后者是用户手写的配置（`agent_servers` 与 Zed 同形），不该被拖窗口改写。字段一律可缺省，缺省宽度与夹取范围只在前端 token 里（`lib/theme/tokens.dart`），核心不复制一份；读不动或不是合法 JSON 时按缺省重建，不挡启动。

## 11. 阶段草案（已取代）

本节的草案已于 2026-09-15 由仓库根 [`ROUNDS.md`](../ROUNDS.md) 取代：设计稿（40 张画板）收口后，实现拆成 R0–R8（含 R1.5 spike），每张画板归属恰好一轮，各轮的验收、裁定门与契约变更都在那里。本节不再维护，编号沿革只记一句：原草案的 R6（sidecar）与 R7（打包）在 `ROUNDS.md` 里是 R7 与 R8，其余编号含义不变。

## 12. 风险与对策

| 风险 | 对策 |
|---|---|
| Windows 上 npx 类 agent 的 `.cmd` 包装与引号 | R1 第一项验收就是用 dsh 在 Windows 实测；转写 Zed `ShellBuilder` 的处理 |
| Flutter 构建链（CMake → cargokit → cargo）在含中文与全角括号的用户名路径下失败 | R0 已验证：cargokit 段没问题，出问题的是 Flutter 自己的 MSBuild 规则；`scripts/build.ps1` 用 ASCII 目录联接绕过（`research.md` § 9.3）；本机用户名已是 ASCII |
| Flutter 侧 Markdown 渲染不如 Web 成熟（流式、高亮、选择复制） | R1.5 spike 已做并裁定（2026-09-15，见 § 9）；R2 的自写渲染层按 spike 的判据（流式不闪、SelectionArea、链接、CJK）逐项验收 |
| Rust panic 会带倒整个 Flutter 进程 | 核心对外 API 边界统一 `catch_unwind` 转 `Result`；agent 子进程崩溃只上报 `acp/agent_state` |
| Windows 中文 IME 组合窗与转录跨消息文本选择 | R2 跨消息选择已实测记录；终端面板的中文输入法 2026-09-17 由自建 `TerminalIme` 接通（组字串不画在光标处，BACKLOG）；输入框的组合窗行为留给所有者手测（R0 验收 6）；设计稿有「复制整段」按钮可绕过大部分选择需求 |
| `unstable` 特性集漂移 | 钉 rust-sdk commit；改钉先改 `pins/upstream.json` 与 `research.md` |
| sidecar 与运行中的 Zed 争用 `threads.db` | R7 实测 2026-09-17：共用会让 Zed 报 `database is locked`，已按「配置共用、数据隔离」落地（§ 8，待所有者确认） |
| Zed 构建环境重 | sidecar 独立 workspace，主程序不依赖它也能跑；CI 分开 |
| 设计稿范围蔓延 | 画板编号只增不改；设计稿没有的功能进 BACKLOG |
