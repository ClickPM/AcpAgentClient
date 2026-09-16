# test/fixtures — ACP 线上行（契约锚）

从 `prototype/assets/fixtures.js` 移植（R0），JSON Lines，按场景分文件，文件名前缀是回放顺序。三处共用：

- `rust/acp-core/tests/fixtures.rs`：逐行喂 rust-sdk 类型，合规行必须全部成功，标 `expect: reject` 的行必须失败。
- `test/projection/wire_test.dart`：Dart 薄封装 `lib/projection/wire.dart` 的单测。
- `lib/gallery/`：画板对照的数据源（R2 起）。

任何轮新增的投影场景都先加 fixtures（ROUNDS.md § 0 第 3 条）。新增方法要同步扩 `fixtures.rs` 的方法表，否则测试按「未映射方法」失败。

## 行格式

每行一个 JSON 对象：

| 字段 | 说明 |
|---|---|
| `dir` | `out` 客户端 → agent；`in` agent → 客户端；`local` 非协议的本地态（终端输出 / 退出，对应 `acp/terminal_output`）；`stderr` agent 的 stderr 尾巴 |
| `tag` | 方法名或 `sessionUpdate` 变体名（`session/update` 行的 `tag` 必须等于变体名，Rust 测试会核对） |
| `expect` | 只有 `reject`：Rust 侧必须反序列化失败的故意行（`90-rejected.jsonl`） |
| `note` / `awaits` / `turn` / `delay` | 回放提示：说明、停住等用户回应（`permission` / `elicitation`）、轮边界、延时毫秒 |
| `msg` | 协议消息（JSON-RPC 对象，字段照 schema/v1）；`local` / `stderr` 行没有 |
| `kind` / `terminalId` / `chunk` / `exitStatus` | `local` 行：`terminal_output` 的字节或 `terminal_exit` 的退出状态 |
| `line` | `stderr` 行 |

密钥字段只放明显的假值（`FAKE-TOKEN-FOR-REDACTION-TEST`），用于 R1 的脱敏验收（CLAUDE.md 规则 8）。

## 文件

| 文件 | 场景 |
|---|---|
| `01-connect.jsonl` | initialize、session/new、available_commands_update |
| `02-turn-read.jsonl` | prompt、用户 / 思考 / 回答 chunk、稳定 plan、读文件工具卡（fs/read_text_file）、session_info_update、usage_update、plan_update |
| `03-permission-edit.jsonl` | 编辑工具卡、session/request_permission、fs/write_text_file、diff 内容、messageId 变化另起气泡 |
| `04-terminal.jsonl` | 终端工具卡、terminal/create / wait_for_exit / release、本地输出与退出、release 后输出留存 |
| `05-elicitation-config.jsonl` | elicitation/create（form）、config_option_update 全量、current_mode_update |
| `06-compaction.jsonl` | compaction_update / compaction_summary_chunk、usage_update |
| `07-tolerance.jsonl` | 凭空建卡（先到的 tool_call_update）、未知 kind 回落 other、content[] 未知项逐项跳过 |
| `08-end-turn.jsonl` | plan_removed、五种内容块、stderr、回合结束（PromptResponse 带 usage） |
| `10-cancel.jsonl` | （R2）session/cancel：进行中的工具卡本地 cancelled（§ 7 第 1 条）、挂起权限回 cancelled（§ 3.1）、stopReason cancelled；画板 20 |
| `11-rich-text.jsonl` | （R2）画板 12–16 的正文：GFM（标题 / 列表 / 任务清单 / 引用 / 分割线 / 删除线 / 文件链接）、powershell 围栏与长行、GFM 表格、mermaid 围栏、行内与块级公式 |
| `12-thinking.jsonl` | （R2）思考折叠单元（§ 7 第 6 条）：三段 thought chunk 合成一段，agent chunk 到达时关闭；画板 17 |
| `13-tool-kinds.jsonl` | （R2）画板 18 / 19 / 21：pending / in_progress / completed / failed 四态，read / search / execute / fetch / other / edit / delete / move / think / switch_mode 全部 kind，rawInput / rawOutput / locations；末尾一条 edit 带 diff 内容（+4 −1） |
| `14-subagent.jsonl` | （R2）画板 24：`_meta.claudeCode.{subagent, parentToolUseId, toolName}` 嵌套（工具行 + 子代理输出）与 `_meta.dsh_subagent`（转录折进 content[]），只按键存在分组 |
| `15-permission-kinds.jsonl` | （R2）画板 25 / 26：四种 option kind（allow_always ×2 / allow_once / reject_once / reject_always），toolCall 只带 toolCallId + kind + rawInput，用户选 allow_once |
| `16-elicitation.jsonl` | （R2）画板 27 / 28：form（string oneOf / array anyOf / integer / boolean / 未知 type / required）与 url（elicitationId + url，sessionScope）；用户 accept。（R3）补两条不需回应的通知：`elicitation/complete`（URL 收尾）与 `$/cancel_request`（agent 撤回自己发出的 id 31 请求） |
| `17-plan-payloads.jsonl` | （R2）画板 29：稳定 plan（5 条）、plan_update items / file / markdown、plan_removed |
| `18-stop-reasons.jsonl` | （R2）画板 31：max_tokens / max_turn_requests / refusal / cancelled 四轮（end_turn 在 08） |
| `19-usage.jsonl` | （R2）画板 30：1% 无 cost / 带 cost / 78% 高占用 |
| `20-compaction-states.jsonl` | （R2）画板 33：cmp_41 in_progress → 两条 summary chunk → completed（summary 整份替换）；cmp_42 failed + error |
| `21-terminal-running.jsonl` | （R2）画板 23：terminal/create → 三行 ANSI 输出（本地流）→ terminal/kill → 退出信号 → failed |
| `22-content-blocks.jsonl` | （R2）画板 32：真实 base64 PNG 的 image、audio、resource_link（size）、embedded resource text / blob |
| `23-messages-no-id.jsonl` | （R2）§ 7 第 2 条：无 messageId 的 chunk 按角色连续合并，思考插入后另起一条 |
| `25-config-options.jsonl` | （R3）画板 40：`config_option_update` 全量——model 三分组、thought_level 六档、mode 三档、三条 boolean、两条未知 category（`sandbox` / `_codex_reasoning`）、一条未知 type（`slider`，整条忽略）；第二条演示「改一个值也回整份列表」 |
| `24-terminal-git-log.jsonl` | （R2）画板 22：git log 的 ANSI 彩色输出（黄 / 绿 / 青）、wait_for_exit、release 后输出留存 |
| `26-auth-url-elicitation.jsonl` | （R5）画板 52：`authenticate`（agent 型）在途时到达的 **requestScope** URL elicitation（无 sessionId，`requestId` 是 authenticate 的数字 id）→ 用户 accept → `elicitation/complete` → authenticate 返回；方法表补 `authenticate` |
| `27-terminal-meta.jsonl` | （R4）画板 22 / 23 的另一条数据源：`tool_call_update._meta.{terminal_info, terminal_output, terminal_exit}`（Zed 读的终端 provider 通道；钉版本的 claude-agent-acp / dsh / codex-acp 都走它、不调 `terminal/create`）——追加语义、退出码或信号二选一；所有者裁定待确认（`docs/design.md` § 4） |
| `90-rejected.jsonl` | `notice`（sdk 的 unstable 伞不转发）、假想的未来变体 `artifact_update` —— Rust 侧必须失败 |

R2 起的文件由 `scratchpad` 里的生成脚本一次性产出后入库（脚本不入库）；改动直接改 `.jsonl`。

## 不进 fixtures 的两类数据（R2）

- **`acp/agent_state`**（画板 34）是核心自己的事件，不是 ACP 线上行，`fixtures.rs` 不会去解析；gallery 场景在 Dart 侧按 `docs/design.md` § 3 的 payload 形状构造（`lib/gallery/scenarios.dart`）。
- ~~**`elicitation/complete`**~~（R3 已收进 fixtures）：`fixtures.rs` 的方法表已补 `elicitation/complete` → `CompleteElicitationNotification` 与 `$/cancel_request` → `CancelRequestNotification`（BACKLOG 里写的是 `CancelNotification`，那是 `session/cancel` 的类型，实际要的是 `CancelRequestNotification`）；画板 28 的完成态改为回放 `16-elicitation.jsonl` 到 `elicitation/complete` 为止。

## 回放器

`lib/projection/fixture_replay.dart`（Dart 单测与 gallery 共用）按行方向与方法把行喂进 `Sessions`：`out session/prompt` 开一轮、`in session/update` 投影、agent → client 请求入队、`out` 响应行按 `outcome` / `action` 回应队列、`in` 的 prompt 响应结束一轮、`local` 行进终端缓冲、`stderr` 行进 agent 状态。`awaits` 只是回放提示：gallery 想停在「等待中」就把行喂到该行为止。
