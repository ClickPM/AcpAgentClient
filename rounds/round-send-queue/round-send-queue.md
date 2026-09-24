# Round send-queue — 回合进行中的发送队列（照 Zed 的 Queued Messages 状态机）

<!-- 与画板 08 / 43 / 53 同类：R8 之后的单功能轮，登记在 ROUNDS.md § 7 进度表。走轮次而非迭代：所有者 2026-09-24 指定按轮次做（涉及新画板 + 回合驱动的发送路径）。
     目录名不带画板号：画板编号到设计阶段才定（起名前按 design/README.md 与各分支查重，编号会被并行会话抢）。 -->

> 状态：未开始（2026-09-24 立项，文档先行；设计阶段与实现都还没开工）

## 目标

回合进行中也能继续输入：按 Enter 把消息收进**本会话的本地队列**（不打断 agent），回合结束后自动按先进先出发出；队列条上可删除、挪回输入框编辑、Send Now（打断当前回合立即发这条）、清空。只用 ACP 标准的 `session/prompt` 与 `session/cancel`，对所有 agent 行为一致。
可证伪：fake-agent 挂住一轮 → 连发两条 → 队列条显示 2 条、线上没有第二个 `session/prompt` → 放行这一轮 → 两条依次各发一次 `session/prompt`、不重不漏；手动停止后队列不自动发；Send Now 线上顺序是 `session/cancel` → 那一轮的 `session/prompt` 返回 `cancelled` → 新的 `session/prompt`，且只发这一条。

## 依据

- Zed 的实现与行号：[`docs/research.md`](../../docs/research.md) § 4.2（钉版本 `d9e1c02`，`crates/agent_ui/src/conversation_view/message_queue.rs` + `thread_view.rs`）。
- Steer 的调研与裁定：`docs/research.md` § 4.3。

## 裁定（所有者 2026-09-24，已定）

1. **只做发送队列，不做 steer。** 不接 claude-agent-acp / codex-acp 的 `_session/steering` 扩展（不是 ACP 标准，撞规则 2 与 `docs/requirements.md` 第 1 条）；**不为内置 Zed agent（sidecar）做 steer 适配**（Zed 那个进程内标志 `end_turn_at_next_boundary` 不接）。队列对 sidecar 自然生效，sidecar 零改动。
2. 队列状态机**照 Zed 同步**：三态（AutoProcess / Paused / AbsorbingCancel）与 fast-track 的语义逐条对齐 § 4.2，不另发明。

## 裁定（开工前，待所有者；按推荐项开工的标「待确认」）

| # | 事项 | 推荐 | 备选 |
|---|---|---|---|
| a | 队列归属 | **每个会话一条**，切走会话时队列留在那条会话上，切回还在；后台会话回合结束照样自动出队 | 只给当前显示的会话排队，切走即清空 |
| b | 持久化 | **只在内存**，重启 / agent 断开即丢（与 Zed 同） | 落盘到会话索引，重启后恢复 |
| c | agent 断开 / 会话关闭 / 删除时 | **清空该会话的队列，不自动重发** | 保留，重连后等用户手动发 |
| d | 回合以错误结束（`session/prompt` 回错误）时 | **按 Paused 处理**：不自动发，等用户再次操作（错误后自动连发容易放大失败） | 照常自动出队 |
| e | 队列条的位置与形态 | **输入框上方的一格 dock**（与计划卡、等待条同一排 `docks`），标题「N 条排队消息」可折叠 + 「全部清空」；每行：删除 / 编辑 / Send Now | 做进转录末尾 |
| f | 编辑的交互 | **挪回主输入框**（主输入框已有字时以空行拼在后面），不做行内编辑 | 行内编辑 |
| g | 键位 | 回合进行中 Enter = 入队；主输入框为空时 Enter = fast-track 队首（Zed 的「Send Now Enter」）；主输入框为空时 ↑ = 把队尾挪回输入框 | 只做按钮不做键位 |
| h | 入队时的附件与 @ 提及 | **入队时就把内容块定下来**（与 Zed 一样存 `ContentBlock` 列表），附件芯片随之清空 | 出队时才读输入框 |

## 前置

- `scripts/fetch-upstream.ps1 -Check` 全绿（规则 4）。
- **设计阶段先行（规则 3）**：简报 `design/round-design/input/revision-08.md`（编号起名前查重）→ Claude Design 出新画板（编号在设计阶段按 `design/README.md` 查重后定，拟放 40 段「输入框」一组的下一个空号）+ 需要改动的既有画板（至少 02「进行中的一轮」要出现队列条）→ `.dc.html` 与 PNG 入库、`design/README.md` 更新 → 再开工实现。
- 上表 a–h 裁定完成（或按推荐项开工并标「待确认」）。

## 交付物（拟，设计阶段后细化）

**设计**
- `design/round-design/input/revision-08.md`（简报）、新画板 `.dc.html` + PNG、改动画板的 `.dc.html` + PNG、`canvas.json`、`design/README.md`。

**前端（Dart）**——核心（Rust）与桥**零改动**：队列只用现成的 `session_prompt` / `session_cancel`。
- `lib/app/send_queue.dart`（新）：纯状态机，逐条对齐 Zed `message_queue.rs`（入队 / 删除 / 清空 / `tryFastTrack` / `onTurnStopped` / `sendNow` / `pause` / `resume`），不依赖 widget，单测直接打。头部标注 `// Derived from zed-industries/zed crates/agent_ui/src/conversation_view/message_queue.rs @ d9e1c024f393832765a03f4de204d6c8cd9abcb2 (GPL-3.0-or-later)`（规则 5，参考转写），NOTICE 同步（validate 的双向核对会查）。
- `lib/app/turn_controller.dart`：`send()` 在本会话回合进行中改为入队；`_runTurn` 收轮处接 `onTurnStopped` 自动出队；Send Now 复用 Restore / Regenerate 现成的「`cancel()` → 等 `_turnsInFlight[sid]` → 再发」；手动停止走 `pause`。
- `lib/app/composer_state.dart`：入队时取走输入框内容块并清空；「编辑」挪回输入框。
- `lib/ui/shell/composer.dart`：回合进行中 Enter 不再被吞（现在 `:172` 的 `enabled && !running`）；停止按钮保留。
- 队列条 widget（文件名随画板定，拟 `lib/ui/shell/send_queue_dock.dart`）+ `workbench_screen.dart` 接到 `docks`。
- `lib/theme/tokens.dart`：只加画板给出的 token（如有）。
- `lib/gallery/`：新画板页。
- 文档：`docs/acp-projection.md` 补一段「队列是客户端本地态，不进投影、不改线上形状」；`design/README.md` 状态改「已实现」。

## 验收

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | 状态机单测 | 三态迁移全覆盖：回合结束自动出队（FIFO）；编辑队首时不自动发；手动停止 → Paused 不发、再入队 / 再发送恢复；Send Now 与 fast-track 在回合进行中 → AbsorbingCancel，吞掉那次结束、不双发；空闲时 fast-track 不进 AbsorbingCancel |
| 2 | 接线单测（fake core） | 回合进行中 Enter 只入队、线上无第二个 `session_prompt`；回合结束依次发出、每条恰好一次；Send Now 的调用顺序是 `session_cancel` → 等在途那一轮返回 → `session_prompt`；删除 / 清空 / 编辑后不再发出；裁定 a / c / d 的行为各一条 |
| 3 | 多会话 | A 会话排队时切到 B 发消息，A 的队列不串到 B；A 在后台收轮后按裁定 a 出队 |
| 4 | widget 测试 | 队列条：计数标题、折叠、全部清空、每行三个动作、Send Now 键位提示 |
| 5 | gallery | 新画板与改动画板出图，与 PNG 逐段对照 |
| 6 | `scripts/validate.ps1` | 全绿（含 NOTICE / 派生文件头双向核对） |
| 7 | Windows 真跑（规则 9） | 无头：fake-agent 挂住回合 → 入队两条 → 放行 → 流量日志里两次 `session/prompt` 顺序正确；另对 dsh 或 claude-agent-acp 真跑一轮「回合中入队 → 自动发出」与一次 Send Now，流量里是标准 `session/cancel` + `session/prompt`，没有任何 `_session/*` 扩展方法 |

## 禁止

- **不接任何 agent 的 steer 私有扩展**（`_session/steering`、`_meta.steering` 等）；不在 `docs/design.md` § 4 加键；不为 sidecar 做 steer（裁定 1）。
- 不改 `rust/`、`sidecar/`、桥（`rust/bridge/src/api.rs` 与 frb 生成物零 diff）。
- 不改协议形状：队列不进投影层（`lib/projection/` 不感知队列），不改 `docs/design.md` § 3。
- 默认三条：不加设计稿没有的功能、样式只来自 `tokens.dart`（规则 3）；不改 `vendor/upstream/`（规则 4）。

## 代码审查

<!-- 完成后回填。 -->

- 审查方式：
- 审查器与模型：
- 审查范围与基准提交：
- findings 处理：
- 结论：

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-send-queue/BLOCKED.md`，停下呼人。禁止放宽验收标准自我通过。

## 本轮实测

<!-- 完成后回填 -->
