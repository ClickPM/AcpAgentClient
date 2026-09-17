# ACP 可投影内容清单

> R0 前置研究（2026-09-11）。口径 = `pins/upstream.json` 钉的 spec commit `1ce24ea` 与 rust-sdk commit `3a6d0ae`。
> 本文只回答一个问题：**「严格 ACP 投影」到底有多少东西可投、各自靠什么开关打开、哪些协议不给必须客户端自己造。**
> 它是 `docs/design.md` § 3（核心与前端契约）与 § 4（能力声明）的事实底稿，也是 `design/` 画板清单的上限依据。
> 与 design.md 有出入、或需要所有者拍板的，集中在 § 11；本文不擅自改 design.md。

## 0. 一页结论

1. **会话流可投影 15 种 `session/update` 变体**：稳定 v1 有 11 种，rust-sdk 的 `unstable` 再打开 4 种（`plan_update`、`plan_removed`、`compaction_update`、`compaction_summary_chunk`）。还有 1 种 `notice` 存在于协议仓库、但 sdk 的 `unstable` 伞不转发，我们**编译不出来** → 收到会被静默丢弃（§ 8.1）。
2. **会话流之外还有四个投影面**：需要用户参与的 agent → client 请求（permission、elicitation 的 form / url 两种模式）、环境能力回调（fs 两个、terminal 五个）、会话与连接级状态（capabilities / authMethods / modes / configOptions / sessionInfo / stopReason / 错误码）、内容块（5 种，**输出方向没有能力门，客户端必须全部能显示**）。
3. **投影面的开关几乎全在我们手里**：`initialize` 里声明什么能力，agent 才会发什么（§ 6 能力门总表）。不声明 = 收不到，不是 agent 的问题。
4. **协议不提供、必须客户端自造的有 8 项**（§ 7）：工具调用的「已取消」态、消息边界与分组、时间戳、先到的 `tool_call_update`、终端释放后的输出留存、思考块的折叠单元、每轮的边界、用户消息的本地回显。它们决定了前端状态层不是「把 JSON 摊平渲染」，但都是**呈现态**，不构成第二套协议。
5. **五个一等 agent 的实际发射面已实测**（§ 9）。claude-agent-acp 与 codex-acp 另有一整套 JetBrains AIR `_meta` 扩展（subagent 会话、async task、quota、file change report 等，**不在任何 ACP schema 里**），只有客户端在 `_meta.jetbrains.air.capabilities` 里声明才会发；我们按 design.md § 4 不声明，因此收不到，代价见 § 9.3。

## 1. 版本与口径

| 事实 | 值 | 出处 |
|---|---|---|
| 线上协议版本 | v1（`protocolVersion: 1` 协商）；v2 仍是草案，`unstable_protocol_v2` 不开 | `schema/v1/meta.json`、CLAUDE.md 规则 10 |
| JSON Schema 发布版本 | v1 **1.21.0** | `schema/v1/Cargo.toml` |
| Rust 类型 crate | `agent-client-protocol-schema` **1.7.0**（rust-sdk 2.1.0 依赖 `=1.7.0`） | `rust-sdk/Cargo.toml` |
| 两者关系 | 同一 commit 生成，互为同源；`schema.json` 就是 Rust 类型 serde 出来的形状 | vendor 实测 |
| 我们的 feature 集 | `agent-client-protocol` 的 `unstable` = 7 个：`end_turn_token_usage`、`llm_providers`、`mcp_over_acp`、`plan_operations`、`session_compaction`、`session_fork`、`tool_call_name` | `rust-sdk/src/agent-client-protocol/Cargo.toml` |
| Zed 的钉法 | `agent-client-protocol = { version = "=2.0.0", features = ["unstable"] }` | `zed/Cargo.toml:521` |

**一处坑**：schema crate 自己的 `unstable` 伞比 sdk 的**多两个**（`unstable_nes`、`unstable_session_notices`）。sdk 不转发，所以 `SessionUpdate::Notice` 在我们这儿根本不存在。`docs/research.md` § 2 列的 7 个 feature 是对的，但没说清这层差异，§ 11 记为待补。

**两份 schema 文件都不等于我们的编译面**：仓库只提供 `schema.json`（纯稳定，11 个变体）与 `schema.unstable.json`（全部 unstable，16 个变体，含 nes / notices / providers / mcp-over-acp）。我们实际编译出的是 15 个。前端 Dart 类型的生成源因此要选，见 § 11。

## 2. 投影面 A：会话流 `session/update`

`SessionNotification = { sessionId, update, _meta? }`，`update` 以 `sessionUpdate` 字段做判别式。「门」列 = 收到它的前提，空 = 无条件。

| # | `sessionUpdate` | 载荷 | 门 | 稳定性 |
|---|---|---|---|---|
| 1 | `user_message_chunk` | `content: ContentBlock`、`messageId?` | — | 稳定 |
| 2 | `agent_message_chunk` | 同上 | — | 稳定 |
| 3 | `agent_thought_chunk` | 同上 | — | 稳定 |
| 4 | `tool_call` | 见 § 2.2 | — | 稳定 |
| 5 | `tool_call_update` | 见 § 2.2 | — | 稳定 |
| 6 | `plan` | `entries: PlanEntry[]` | — | 稳定 |
| 7 | `available_commands_update` | `availableCommands: AvailableCommand[]` | — | 稳定 |
| 8 | `current_mode_update` | `currentModeId` | — | 稳定 |
| 9 | `config_option_update` | `configOptions: SessionConfigOption[]`（**全量替换**） | 布尔型选项需客户端声明 `session.configOptions.boolean` | 稳定 |
| 10 | `session_info_update` | `title?`、`updatedAt?`（部分更新，`null` = 清空） | — | 稳定 |
| 11 | `usage_update` | `used`、`size`、`cost?{amount,currency}` | — | 稳定 |
| 12 | `plan_update` | `plan`: `items` / `file` / `markdown`，均带 `planId` | 客户端声明 `plan` 能力 | unstable |
| 13 | `plan_removed` | `planId` | 同上 | unstable |
| 14 | `compaction_update` | `compactionId`、`status`、`summary?`、`error?` | 客户端声明 `session.compaction` | unstable |
| 15 | `compaction_summary_chunk` | `compactionId`、`content: ContentBlock` | 同上 | unstable |
| — | `notice` | `severity`、`title`、`description?` | 无门（agent 可随时发） | **我们编译不出，见 § 8.1** |

### 2.1 内容块 `ContentBlock`（5 种）

`text`、`image`（base64 + mimeType + uri?）、`audio`（base64 + mimeType）、`resource_link`（uri / name / title? / description? / mimeType? / size?）、`resource`（内嵌 `text` 或 `blob` 资源）。全部可带 `annotations`（`audience` / `priority` / `lastModified`）与 `_meta`。

**关键事实：`promptCapabilities` 只约束客户端能往 `session/prompt` 里塞什么，不约束 agent 往回发什么。** 输出方向没有任何能力门，agent 的消息块、思考块、工具卡内容里随时可能出现 image / audio / resource_link / embedded resource，画板必须为这 5 种都有呈现方式（哪怕只是「不可渲染，给个文件卡」）。

### 2.2 工具调用

`ToolCall`：`toolCallId`（必填）、`title`（必填）、`kind`、`status`、`content[]`、`locations[]`、`rawInput`、`rawOutput`、`_meta`；开了 `unstable_tool_call_name` 还有 `name`。

- `kind`：`read` / `edit` / `delete` / `move` / `search` / `execute` / `think` / `fetch` / `switch_mode` / `other`。Rust 侧带 `#[serde(other)]`，未知值安全落到 `other`。
- `status`：`pending` / `in_progress` / `completed` / `failed`。**没有 `cancelled`**，且 Rust 侧**没有** catch-all，未知状态会让整条通知反序列化失败（§ 8.1）。
- `content[]` 三种：`content`（标准内容块）、`diff`（`path` / `oldText?` / `newText`）、`terminal`（`terminalId`，嵌一个活的终端）。
- `locations[]`：`path` + `line?`，用于「跟随 agent」。
- **合并语义（sdk `ToolCall::update` 原文）**：按 `toolCallId` 覆盖；只有给出的字段才更新；**集合字段是替换不是追加**（`content`、`locations` 整体替换）。update 自带的 `_meta` 不并进 tool call。

### 2.3 计划

稳定版 `plan` 是**整份替换**：`entries[] = { content, priority: high|medium|low, status: pending|in_progress|completed }`，没有 id，无法增量更新。
unstable 的 `plan_update` / `plan_removed` 引入 `planId` 与三种载荷（结构化条目 / 文件 URI / markdown），可多份计划共存并单独增删——但要客户端声明 `plan` 能力才会发。codex-acp 已经在发 `plan_update`。

### 2.4 斜杠命令

`available_commands_update` 给的是**全量列表**：`{ name, description, input? }`。`input` 目前只有一种 `unstructured`（`{ hint }`），即「命令名之后的整段文本原样作为参数」。

### 2.5 用量与成本

`usage_update` 是**会话级上下文窗口**，不是每轮增量：`used` / `size` 必填非空，`cost` 可选（`amount` + ISO 4217 `currency`）。
另有一条**回合级**用量：开了 `unstable_end_turn_token_usage` 后 `PromptResponse` 多一个 `usage`（`totalTokens` / `inputTokens` / `outputTokens` / `thoughtTokens?` / `cachedReadTokens?` / `cachedWriteTokens?`）。它不是 `session/update`，是 `session/prompt` 的返回值，投影时属于「回合结束」而不是流。

## 3. 投影面 B：需要用户参与的请求（agent → client）

### 3.1 `session/request_permission`

`{ sessionId, toolCall: ToolCallUpdate, options: PermissionOption[] }`。
`options[] = { optionId, name, kind }`，`kind` 四选一：`allow_once` / `allow_always` / `reject_once` / `reject_always`（仅 UI 提示，记忆语义由 agent 负责）。
回应二选一：`{outcome:"selected", optionId}` 或 `{outcome:"cancelled"}`。
**硬性要求：一旦发出 `session/cancel`，所有挂起的权限请求 MUST 以 `cancelled` 回应。** 注意请求里带的是 `ToolCallUpdate`，可能只有 `toolCallId`，其余字段要从已累积的 tool call 里取。

### 3.2 `elicitation/create` 两种模式

- `mode: "form"`：带 `requestedSchema`（受限 JSON Schema：object + 原始类型属性）。属性类型有 `string`（可带 `minLength` / `maxLength` / `pattern` / `format` ∈ email|uri|date|date-time，或用 `enum` / `oneOf` 做单选）、`number`、`integer`（含 min/max）、`boolean`、`array`（多选，`items` 可以是无标题字符串列表或带标题的选项列表，含 `minItems` / `maxItems`），全都可带 `title` / `description` / `default`。**另有一个 catch-all：未知 `type` 的属性**，客户端应忽略该字段。回应 `{action:"accept", content?}` / `"decline"` / `"cancel"`。
- `mode: "url"`：带 `elicitationId` + `url`，客户端把用户导到该 URL，完成由 agent 发 `elicitation/complete` 通知收尾（codex-acp 的 ChatGPT 登录走这条）。
- 两种模式都有**作用域**二选一：`sessionScope`（`sessionId` + 可选 `toolCallId`）或 `requestScope`（`requestId`，用于还没有会话的认证 / 配置阶段）。**后者意味着 elicitation 可能在任何会话之外到达**，前端队列不能只按 `sessionId` 索引。

## 4. 投影面 C：环境能力回调（agent → client）

| 方法 | 参数 | 投影意义 |
|---|---|---|
| `fs/read_text_file` | `path`（绝对）、`line?`（1-based）、`limit?` | 通常不进转录，但「谁读了什么」可进流量面板 |
| `fs/write_text_file` | `path`、`content`；文件不存在 MUST 创建 | 同上；写盘走临时文件 + rename（CLAUDE.md 规则 7） |
| `terminal/create` | `command`、`args?`、`env?`、`cwd?`、`outputByteLimit?` | 返回 `terminalId`，可被 `tool_call.content` 以 `{type:"terminal"}` 嵌入 |
| `terminal/output` | `terminalId` | 返回 `output`、`truncated`、`exitStatus?` |
| `terminal/wait_for_exit` | `terminalId` | 返回 `exitCode?` / `signal?` |
| `terminal/kill` / `terminal/release` | `terminalId` | kill 不释放；release 释放资源 |

两条规范硬要求：**截断必须落在字符边界上**（不能切出半个 UTF-8）；**终端被嵌进工具卡后，即使 `terminal/release` 了，客户端 SHOULD 继续显示它的输出** —— 输出缓冲的生命周期跟着工具卡走，不跟着终端句柄走。

## 5. 投影面 D：会话与连接级状态

- **`initialize` 返回**：`protocolVersion`、`agentCapabilities`、`authMethods[]`、`agentInfo{name, title?, version}`。可投影的有 agent 名字与版本、支持哪些会话能力（`loadSession`、`sessionCapabilities.{list,delete,resume,close,additionalDirectories}`、`promptCapabilities.{image,audio,embeddedContext}`、`mcpCapabilities.{http,sse}`、`auth.logout`）。**UI 的可用动作应由这些能力驱动**（例如没有 `sessionCapabilities.close` 就不显示关闭）。
- **`authMethods[]`**：两种类型。`agent` 型 = 调 `authenticate`，agent 自己开浏览器；`terminal` 型 = 客户端在可见终端里用附加的 `args` / `env` **重新拉起同一个 agent 程序**（是追加到已配置的调用上，不是另给一条命令）。两者都有 `id` / `name` / `description?`。
- **modes 与 configOptions 的关系（重要）**：规范原文 —— configOptions 是首选，**agent 同时给了 configOptions 和 modes 时客户端 SHOULD 只用 configOptions、忽略 modes，modes 会在未来版本移除**。过渡期 agent 应同时发并保持同步。所以前端以 configOptions 为主投影，modes 只作老 agent 的回退。
- **configOptions 的规则**：`{id, name, description?, category?, type}`，`select` 型带 `currentValue` + `options`（扁平列表或分组），`boolean` 型带 `currentValue`。数组顺序即优先级；`category` ∈ `mode` / `model` / `model_config` / `thought_level` / 未知（**仅 UX，未知必须优雅处理**）；未识别的 `type` 应整条忽略；未声明 boolean 能力时 agent MUST NOT 发 boolean 型。设置走 `session/set_config_option`，返回**全量**列表。
- **会话清单与生命周期**：`session/list`（`cwd?` 过滤 + `cursor` 分页，返回 `SessionInfo{sessionId, cwd, additionalDirectories?, title?, updatedAt?}`）、`session/load`（**MUST 用 `session/update` 把整段历史重放完再返回**）、`session/resume`（**MUST NOT 重放**，只恢复上下文）、`session/close`（等价于先 cancel 再释放）、`session/delete`、`session/fork`（unstable）。
- **回合终止**：`stopReason` ∈ `end_turn` / `max_tokens` / `max_turn_requests` / `refusal` / `cancelled`。五个都该在 UI 上有区分（尤其 `refusal` 与 `max_tokens`，跟「正常结束」不是一回事）。
- **错误码**：`-32700` / `-32600` / `-32601` / `-32602` / `-32603` 标准 JSON-RPC，`-32800` 请求已取消，`-32000` **需要认证**（`session/new` 回这个就是走登录流），`-32002` 资源未找到，其余为自定义整数。

## 6. 能力门总表：我们声明什么 → 能收到什么

design.md § 4 定的声明集（照抄 Zed 的 `client_capabilities_for_agent`）对应的投影面如下。

| 我们声明 | 打开的投影面 | design.md § 4 是否已含 |
|---|---|---|
| `fs.readTextFile` / `fs.writeTextFile` | agent 可读写工作区文件（否则 MUST NOT 调） | 是 |
| `terminal` | 全部 `terminal/*`，以及工具卡里的 `{type:"terminal"}` 内容 | 是 |
| `auth.terminal` | `authMethods` 里的 terminal 型登录 | 是 |
| `session.configOptions.boolean` | `configOptions` 里的布尔开关（否则 agent 只能发 select） | 是 |
| `elicitation.form` | 表单型 elicitation | 是 |
| `elicitation.url` | URL 型 elicitation（codex 登录） | 是 |
| `_meta.terminal_output` / `terminal-auth` | Zed 的两个私约；dsh 读前者决定是否公布终端能力 | 是 |
| `plan`（unstable） | `plan_update` / `plan_removed`（codex 已在发） | 是（所有者裁定 2026-09-11 追加） |
| `session.compaction`（unstable） | `compaction_update` / `compaction_summary_chunk` | 是（所有者裁定 2026-09-11 追加） |
| `_meta.jetbrains.air.capabilities` | subagent / async task / quota 等 AIR 扩展 | 否（明确不做，§ 9.3） |

无需任何声明就会来的：五种内容块、`plan`、`available_commands_update`、`current_mode_update`、`session_info_update`、`usage_update`、`notice`、`session/request_permission`。

## 7. 协议不给、必须客户端自己造的 8 项

这 8 项都是**呈现态**，存在前端 store 里，不进线上协议，也不构成「第二套协议」（CLAUDE.md 规则 2 的边界）。

1. **工具调用的「已取消」态**。规范要求：客户端发出 `session/cancel` 后 SHOULD 先行把本轮未完成的工具调用标成 cancelled —— 但 `ToolCallStatus` 里**根本没有 cancelled**。只能在客户端侧记一个本地态。
2. **消息边界与分组**。chunk 流里只有可选的 `messageId`（同 id 属同一条消息，id 变了就是新消息）。agent 不发 `messageId` 时（多数情况），把连续 chunk 合成一条气泡的规则由客户端定。
3. **时间戳**。除 `SessionInfo.updatedAt` 外，协议不带任何时间信息。消息时间、工具耗时都得客户端自己打。
4. **先到的 `tool_call_update`**。协议允许 update 先于 `tool_call` 到达（或 `tool_call` 根本没发过，例如权限请求里只带 `toolCallId`）。客户端要能凭一条 update 凭空建卡。
5. **终端释放后的输出留存**。见 § 4。
6. **思考块的折叠单元**。`agent_thought_chunk` 是纯流，没有「一段思考」的边界，折叠 / 展开的分段规则由客户端定。
7. **每轮的边界**。`session/prompt` 的请求与响应之间是一轮，但流里没有「轮开始 / 轮结束」标记；轮的归属靠客户端按请求生命周期自己切。
8. **用户消息的本地回显**。`session/prompt` 的入参里就带着用户发出去的那批内容块，但**没有哪个 agent 在实时一轮里把它回显成 `user_message_chunk`**：钉版本的 claude-agent-acp / codex-acp / pi-acp / dsh-acp-interactive 四家的发射点全在 `session/load` 的历史重放里（§ 9.1 已更正）。客户端必须在发 `session/prompt` 时自己把这批块落成用户气泡，否则转录里只有轮边界、没有用户消息。重放（或将来有 agent 实时回显）时同一批块会再来一遍，按块内容去重、并把协议 `messageId` 认领到本地那条上——照 Zed `acp_thread.rs` 的 `handle_session_update`。去重的查找范围是**本轮**：从尾部回头找到轮边界为止（回显之后可能已经隔着 thought / 工具卡 / agent 消息，只看最后一条会漏；扫过轮边界则会把用户两轮发的同一句话吞掉第二句）。内容对不上、`messageId` 也对不上时（agent 改写过 prompt）**无论带不带 id** 都另起一条，本地回显那条不参与角色连续合并（否则会把改写后的文本写进用户自己发出去的那条）。

## 8. 容错与丢失风险

### 8.1 未知变体会被静默丢弃

- rust-sdk 的 incoming actor 对**通知**的处理是：处理器报错就记日志丢弃，**连接不断、对端无感**（`jsonrpc/incoming_actor.rs`：`Ignoring unhandled notification` / `Ignoring message-processing error because there is no request to answer`）。
- `SessionUpdate` 枚举**没有 catch-all 变体**。因此：agent 发来一个我们没编译的 `sessionUpdate`（今天最现实的就是 `notice`，未来是新变体），整条 `session/update` 反序列化失败 → **用户什么也看不到，也没有报错**。
- 同理，`ToolCallStatus` 没有 catch-all，未来新增状态值会让整条通知消失。`ToolKind` 有 `#[serde(other)]`，安全。
- **对策**：`acp/traffic` 原始行通道不是可选的调试装饰，它是这类丢失的唯一可见性来源；并且建议核心侧对「反序列化失败的 `session/update`」单独计数并上抛一条 `acp/agent_state` 级别的告警。R0 就该把这条接上。

### 8.2 serde 往返对**已知**变体是无损的

- 所有协议类型的 `_meta` 都是 `serde_json::Map<String, Value>` 自由映射，原样进出。
- 规范明令：**实现 MUST NOT 在规范类型的根上加自定义字段**（所有名字为未来版本保留），自定义信息一律进 `_meta`。
- 因此 design.md § 3「`update` 是 SDK 类型 serde 直出」对**合规消息**没有信息损失；风险全部集中在 § 8.1 的「整条丢失」。

### 8.3 schema 自带的软化处理

- 大量可选字段标了 `DefaultOnError`：字段值坏了回落默认，不炸整条。
- 集合字段用 `VecSkipError`：`content[]` / `locations[]` 里**某一项**无法解析就丢那一项，其余保留。所以未来新增的 `ToolCallContent` 类型（例如表格）会**静默少一块内容**，而不是丢整条。

### 8.4 原始行是可以拿到的

Zed 的做法可直接转写：把子进程 stdout 的行流与 stdin 的行 sink 各包一层 tap（`futures::io::BufReader::lines().inspect(...)` + `futures::sink::unfold(...)`），再交给 sdk 的 `Lines` transport（`zed/crates/agent_servers/src/acp.rs:886-910`）。stderr 单独一路。这一层同时满足：`acp/traffic` 面板、§ 8.1 的丢失可见性、崩溃时的 stderr 尾巴。

## 9. 五个一等 agent 的实际发射面

### 9.1 实测表

源码静态扫描（排除测试文件，含条件表达式的发射点已人工核对）。Cursor 无源码，按其文档与 registry 条目标注。

| 变体 | claude-agent-acp | codex-acp | pi-acp | dsh-acp-interactive | Cursor |
|---|---|---|---|---|---|
| `user_message_chunk` | 是（重放） | 是（重放） | 是（重放） | 是（重放） | 未知 |
| `agent_message_chunk` | 是 | 是 | 是 | 是 | 是 |
| `agent_thought_chunk` | 是 | 是 | 是 | 是 | 未知 |
| `tool_call` / `tool_call_update` | 是 | 是 | 是 | 是 | 是 |
| `plan` | 是 | 是 | 否 | 是 | 未知 |
| `plan_update`（unstable） | 否 | **是** | 否 | 否 | 未知 |
| `available_commands_update` | 是 | 是 | 是 | 是 | 未知 |
| `current_mode_update` | 是 | 否（只用 configOptions） | 是 | 是 | 未知 |
| `config_option_update` | 是 | 是 | 是 | 是 | 是（参数化模型选择器） |
| `session_info_update` | 是 | 是 | 是 | 是 | 未知 |
| `usage_update` | 是 | 是 | 否 | 是 | 未知 |
| `compaction_*`（unstable） | 否（走 AIR `_meta`） | 否（走 AIR `_meta`） | 否 | 否 | 否 |

更正（2026-09-17，实测）：`user_message_chunk` 四家**都只在 `session/load` 的历史重放里发**——codex-acp 的发射点在 `createHistoryUpdates`、pi-acp 在 `getMessages()` 重放、dsh 在 `replayMessageContent`。实时一轮里用户消息只能由客户端自己回显（§ 7 第 8 条）。

结论：**11 个稳定变体在一等 agent 里全部有真实发射源**，没有哪个是纸面功能；只有 `plan_update` 需要额外声明 `plan` 能力才能从 codex 收到（不声明时 codex 仍发稳定的 `plan`）。

### 9.2 各 agent 对客户端的额外期待

- **dsh-acp-interactive**：读 `clientCapabilities._meta.terminal_output`、`elicitation.form`、`session.configOptions.boolean` 决定公布哪些能力；权限预设做成 config option。
- **pi-acp**：不用客户端 fs 与 terminal，依赖 `session/load` 与斜杠命令。
- **Cursor**：fs 与 terminal 可声明为 false；靠参数化模型选择器 `_meta` 键。
- **codex-acp**：URL elicitation 登录；三种 mode 与 config options。
- **claude-agent-acp**：fs 读写、交互与后台终端、elicitation、权限，面最全。

### 9.3 JetBrains AIR 扩展：我们不接的那一块

claude-agent-acp 与 codex-acp 都带一层 `_meta.jetbrains.air` 扩展（两边实现一致，版本号 1），能力在 `clientCapabilities._meta.jetbrains.air.capabilities` 数组里声明，**客户端不声明就完全不会发**：

| AIR 能力 | 打开后多出来的东西 |
|---|---|
| `nativeSubagentSessions` | `subagent_spawned` / `subagent_state_update` 两个**非 ACP** 会话更新，子代理有独立 sessionId 与独立转录 |
| `asyncTasks` | `async_task_spawned` / `async_task_progress` / `async_task_state_update` 三个非 ACP 更新，后台任务卡与停止按钮 |
| `sessionFailure` | 结构化的会话失败信息 |
| `agentFileChangeReport` | agent 侧汇总的文件改动报告 |
| `recommendedValue` | config option 的推荐值标注 |
| 另有 codex 侧的 quota / rateLimits / goal / auth status 等 `_meta` 与 `_` 前缀扩展方法 |

**代价（明确记录）**：不声明时，claude-agent-acp 的子代理输出仍会进主转录，只是带 `_meta.claudeCode.{parentToolUseId, subagent, toolName}` 标记而没有独立会话；后台任务只表现为普通工具调用。也就是说**信息不丢，层级丢了**。这与 design.md § 4「`_meta` 只允许列出的键」一致，是有意取舍，不是缺陷。

## 10. 与 design.md § 3 的对照

| design.md § 3 的说法 | 本文核对结果 |
|---|---|
| `acp/session_update` 传 `SessionNotification` 原样 JSON | 成立；对合规消息无损（§ 8.2）。需补「未知变体会整条丢失」的处理（§ 8.1） |
| `acp/client_request` 覆盖 `session/request_permission` 与 `elicitation/create` | 覆盖面正确。需补：elicitation 可能是 **requestScope**（无 sessionId），前端队列不能只按会话索引（§ 3.2） |
| 「`tool_call` 与 `tool_call_update` 按协议合并（同 id 覆盖，content 为替换语义）」 | 与 sdk 实现完全一致（§ 2.2） |
| 「待处理的 permission 与 elicitation 是队列」 | 成立；补一条硬要求：发出 cancel 后挂起的权限请求 MUST 回 `cancelled`（§ 3.1） |
| 「不在前端做任何 agent 特判」 | 与实测相容：11 个稳定变体各 agent 都发，差异靠能力位而非 agent 名区分 |

## 11. 待所有者裁定 / 待补文档

1. ~~是否声明 `plan` 与 `session.compaction`~~ → **已裁定 2026-09-11：两个都声明**（依据「多数 agent 已支持 plan 与压缩」）。两者都在 sdk `unstable` 伞内，不改 feature 集。design.md § 4 已补；`plan_update` / `plan_removed` / `compaction_update` / `compaction_summary_chunk` 四个变体由此成为**必投影面**，设计稿要为多计划（items / file / markdown 三种载荷）与压缩卡片留画板。
2. ~~`notice` 怎么办~~ → **已裁定 2026-09-11：取方案 (a)**，不为它改 feature 集；核心侧对反序列化失败的 `session/update` 计数并经 `acp/agent_state` 上抛告警，原文落 `acp/traffic`。R1 用 dsh 实测后复议。
3. ~~前端 Dart 类型的生成源~~ → **已裁定 2026-09-15：不生成，手写薄封装** `lib/projection/wire.dart`（15 变体 + 5 种内容块 + 3 种工具卡内容 + 两类请求）；合规性由 Rust 侧用 rust-sdk 类型反序列化 `test/fixtures/` 的测试兜底，「我们支持的 15 个」就是这份 fixtures 与薄封装的显式清单。原问题：`schema.json`（11 变体）少了我们编译出的 4 个；`schema.unstable.json`（16 变体）多了 nes / notices / providers / mcp-over-acp，两份都不能直接生成。
4. **`docs/research.md` § 2 补一句**：schema crate 的 `unstable` 伞与 sdk 的 `unstable` 伞不是同一个集合（多 `unstable_nes`、`unstable_session_notices`），并记 schema crate 版本 `=1.7.0`、JSON Schema 版本 1.21.0。
5. ~~`docs/design.md` § 3 建议补三条~~ → 已补（2026-09-15）：未知 `session/update` 的丢弃计数进 `acp/agent_state`；elicitation 的 requestScope 队列与落点；工具调用「已取消」是客户端本地态。

---

**出处索引**（全部为 `vendor/upstream/` 下钉版本源码）：
`agent-client-protocol/schema/v1/{meta,schema,schema.unstable}.json`、
`agent-client-protocol/agent-client-protocol-schema/src/v1/{client,agent,tool_call,content,plan,elicitation}.rs`、
`agent-client-protocol/docs/protocol/v1/{prompt-turn,tool-calls,content,terminals,file-system,session-config-options,session-setup,elicitation,extensibility,cancellation}.mdx`、
`rust-sdk/src/agent-client-protocol/{Cargo.toml,src/jsonrpc/incoming_actor.rs}`、
`zed/crates/{agent_servers/src/acp.rs,acp_tools/src/acp_tools.rs,acp_thread/src/*.rs}`、
`claude-agent-acp/src/{acp-subagents,air-extension,acp-agent}.ts`、`codex-acp/src/{AirExtension,AcpExtensions,CodexEventHandler}.ts`、
`pi-acp/src/`、`dsh-acp-interactive/src/`。
