# Iteration 24 — Copy 反馈停留与终端释放测试竞态

> 状态：已合并（本次未重跑构建测试—所有者指定）　基线：`main` = `ce578d7`　分支：`fix/backlog-copy-terminal-test` → `main`（快进 `5436973`）

> 编号冲突处理（所有者明确授权）：本线程原登记为 iteration-22；GitHub `main` 已用 22 登记 Reload Agent 文案，合并时本台账改为 24。历史提交与审查范围不变，不回写历史。

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | fix | Copy 成功反馈停留 1.8 秒，后续复制成功重置计时，卸载时撤计时器 | BACKLOG P1「代码块的 Copy 点完 Copied 一闪就回去」 | `98326fa`（修复）/ `5436973`（改号），快进到 `main` | 此前 Windows validate 全绿（Flutter 632 项）；本次不重跑—所有者指定 | 1 轮：Delta 只读 Reviewer / Grok 4.7（所有者指定），0 条 findings | 已合并 |
| 2 | fix | 断开后的终端释放断言改为有超时的条件等待，不修改生产断开语义 | BACKLOG P5「Rust 集成测试 agent 断开时释放它建的终端在负载下偶发失败」 | 同上 | 同上；此前指定用例连续 20 次通过 | 同上 | 已合并 |

## 收口

- 所有者指定合并 `main`、只推 GitHub，不推 `origin`，不重跑构建测试；两条 BACKLOG 已移入 CLOSED。本次不发版、不改应用版本号。
- 合并顺序：本分支快进到 `main`（`5436973`），再合并 GitHub `main`（`6245c93`），保留远端已有 v1.4.9、Active 行优化、Reload Agent 文案与全部历史。冲突只有四份文档：DIVERGENCE、迭代清单、BACKLOG / CLOSED；保留双方记录并以所有者授权改号 23 / 24 收口，Copy 偏离改 A-39。
- Git 内容核对：远端迭代 21 / 22、sidebar / session_header / sidebar 测试、应用版本与 Cargo.lock 与 GitHub 侧逐字节一致；本线程四份内存实现、Copy 实现、Rust 释放测试及新增回归测试与合并前分支逐字节一致。只更新 token 注释中的迭代编号，不改行为；未运行任何构建测试。
- 构建 / 手测：此前 Windows validate 全绿，未构建本次发布包、未做真窗口手测。
- 设计偏离：画板 13 只画 Copied 状态，未定义停留时长；本次补停留 token，不改布局或其余动效，记 DIVERGENCE。

## 备注

- 上游 `fetch-upstream.ps1 -Check` 八个 pin 全绿。
- Rust 根因已按代码核对：`Shared::finish` 先通知 exit watch，随后 drain owned IDs 并逐个 release；`disconnect` 等 exit watch，不等 release 全部完成。测试必须同时等「owner IDs 为空」与「终端管理器返回 UnknownTerminal」，不能只等其中一个。
- Copy 回归 `flutter test test/ui/code_block_copy_test.dart` 四项：停留 1.8s / 连续在途复制的第二次成功重置计时 / 卸载取消 Timer / 剪贴板晚到不挂 Timer。改前前三项红（120ms 回落和未撤 Timer），改后四项绿。没有引入可再次点击 Copied 的新入口，连续点击指 Clipboard 完成前已有的多笔请求。
- Windows Rust 指定用例：`CARGO_TARGET_DIR=D:/cargo-target/AcpAgentClient-copy-terminal-test cargo test --manifest-path rust/Cargo.toml -p acp-core --test scripted owned_terminals_are_released_when_the_agent_disconnects -- --exact` 连续 **20/20 通过**。这是顺序重复回归，不宣称复现了旧版负载下偶发竞态；仍保留终端与 owner IDs 两条最终断言、10s 超时会失败。
- 全量：`powershell -NoProfile -File scripts/validate.ps1 -CargoTargetDir D:\cargo-target\AcpAgentClient-copy-terminal-test` **VALIDATE OK**；cargo build / test / clippy、flutter analyze / test（632 项）与全部静态门。Rust 测试改动用本分支独立 target，避免共用缓存串代码。
- 审查采用本轮所有者明确指定的 Delta 只读子代理、模型 Grok 4.7；不调用 Cursor / Codex，不改仓库默认执行器。

### 代码审查

- R1：Delta Reviewer / `x_ai-subscribed/grok-4.7`（执行器由所有者指定），范围固定为 `ce578d7..98326fa`，最终 **findings: 0**（high / P2 / P3 全 0），无整改、无需复审。
- 实际审阅范围内七个文件；对照 `Shared::finish`、`release_owned_terminals`、`disconnect` 与 `TerminalManager::release` / `output`。按任务书未重跑测试。
- 审查结果返回后仅回填台账；随后经所有者明确授权合并与处理编号冲突，实现与测试行为不变。
