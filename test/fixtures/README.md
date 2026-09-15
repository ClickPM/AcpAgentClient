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
| `90-rejected.jsonl` | `notice`（sdk 的 unstable 伞不转发）、假想的未来变体 `artifact_update` —— Rust 侧必须失败 |
