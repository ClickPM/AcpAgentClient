# Iteration 22 — Copy 反馈停留与终端释放测试竞态

> 状态：待审查　基线：`main` = `ce578d7`　分支：`fix/backlog-copy-terminal-test`

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | fix | Copy 成功反馈停留 1.8 秒，后续复制成功重置计时，卸载时撤计时器 | BACKLOG P1「代码块的 Copy 点完 Copied 一闪就回去」 | `fix/backlog-copy-terminal-test` → 待所有者指定合并 | Windows validate 全绿（Flutter 632 项） | Delta 只读 Reviewer / Grok 4.7（所有者指定），待执行 | 待审查 |
| 2 | fix | 断开后的终端释放断言改为有超时的条件等待，不修改生产断开语义 | BACKLOG P5「Rust 集成测试 agent 断开时释放它建的终端在负载下偶发失败」 | 同上 | 同上；指定用例连续 20 次通过 | 同上 | 待审查 |

## 收口

- 未合并、未发版；BACKLOG 合并后再移入 CLOSED。
- 构建 / 手测：Windows validate 全绿，未构建发布包、未做真窗口手测。
- 设计偏离：画板 13 只画 Copied 状态，未定义停留时长；本次补停留 token，不改布局或其余动效，记 DIVERGENCE。

## 备注

- 上游 `fetch-upstream.ps1 -Check` 八个 pin 全绿。
- Rust 根因已按代码核对：`Shared::finish` 先通知 exit watch，随后 drain owned IDs 并逐个 release；`disconnect` 等 exit watch，不等 release 全部完成。测试必须同时等「owner IDs 为空」与「终端管理器返回 UnknownTerminal」，不能只等其中一个。
- Copy 回归 `flutter test test/ui/code_block_copy_test.dart` 四项：停留 1.8s / 连续在途复制的第二次成功重置计时 / 卸载取消 Timer / 剪贴板晚到不挂 Timer。改前前三项红（120ms 回落和未撤 Timer），改后四项绿。没有引入可再次点击 Copied 的新入口，连续点击指 Clipboard 完成前已有的多笔请求。
- Windows Rust 指定用例：`CARGO_TARGET_DIR=D:/cargo-target/AcpAgentClient-copy-terminal-test cargo test --manifest-path rust/Cargo.toml -p acp-core --test scripted owned_terminals_are_released_when_the_agent_disconnects -- --exact` 连续 **20/20 通过**。这是顺序重复回归，不宣称复现了旧版负载下偶发竞态；仍保留终端与 owner IDs 两条最终断言、10s 超时会失败。
- 全量：`powershell -NoProfile -File scripts/validate.ps1 -CargoTargetDir D:\cargo-target\AcpAgentClient-copy-terminal-test` **VALIDATE OK**；cargo build / test / clippy、flutter analyze / test（632 项）与全部静态门。Rust 测试改动用本分支独立 target，避免共用缓存串代码。
- 审查采用本轮所有者明确指定的 Delta 只读子代理、模型 Grok 4.7；不调用 Cursor / Codex，不改仓库默认执行器。
