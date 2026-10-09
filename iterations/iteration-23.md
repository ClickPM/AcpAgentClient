# Iteration 23 — JSON 重建缓存与最小化期间消息队列排空

> 状态：已合并（未构建发布包）　基线：`main` = `458cff0`　分支：`fix/backlog-memory` → `main`（快进 `04b7a96`）

> 编号冲突处理（所有者明确授权）：本线程原登记为 iteration-21；GitHub `main` 已用 21 登记 Active 会话行优化，合并时本台账改为 23。历史提交、审查命令及产物里的旧编号保留，不回写历史。

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | fix | 工具卡与流量展开行的 JSON 格式化 / TextSpan 按输入与字体代数缓存；每个 State 只保留当前值 | BACKLOG P0「工具卡与流量面板在 build 里重算缩进 JSON 与语法着色的 TextSpan」 | `fix/backlog-memory` → `main`（快进 `04b7a96`） | validate 全绿（Flutter 628 项） | 1 轮有效审查：Grok 4.7，0 条 findings | 已合并 |
| 2 | fix | 无帧期间用微任务刷新消息，进入 hidden 时迁移已排队的帧回调，恢复后按帧合并 | BACKLOG P0「窗口最小化期间 session/update 在批处理器队列里无上限堆积」 | 同上 | 同上 | 同上 | 已合并 |

## 收口

- 构建 / 手测：validate 全绿；未跑 `scripts/build.ps1`、未构建发布包，Windows 真窗口长任务的内存曲线未测。
- 合并 / 发版：所有者指定合并 `main`；实现与测试提交 `04b7a96`，`git merge --ff-only fix/backlog-memory` 快进，无冲突且合并不改代码；两条 BACKLOG 移入 CLOSED，P0 清空。未 push、不发版。合并前后各一次 `powershell -NoProfile -File scripts/validate.ps1` 全绿（每次 628 Flutter 测试与全部 Rust / 静态门）；合并后只回填本段验证结果，无代码改动。
- 设计稿补注记：无；不改布局、token、协议，不增加会话淘汰机制。

## 备注

- 新 Delta worktree 的上游目录为空，按工程笔记建立 `vendor/upstream` → 主副本同目录的只读联接；`powershell -NoProfile -File scripts/fetch-upstream.ps1 -Check` 八个 pin 全绿。
- 回归测试从真实工具卡 / 流量页检查 span 与格式化串的同一性、字段替换与主题 / 字体失效；生命周期测试只排空微任务、不发帧，守后台刷新、前台按帧、hold/release 与 dispose。
- 红 → 绿：改前工具卡、普通 / dropped 流量行的 span 同一性断言失败；生命周期用例在 hidden 后队列不排空、dispose 后旧帧仍执行两个断言失败。改后六项全部通过。
- Windows 验证：`flutter test test/ui/json_highlight_cache_test.dart test/app/batch_lifecycle_test.dart` 六项绿；`powershell -NoProfile -File scripts/validate.ps1` 全绿（cargo build / test / clippy、flutter analyze / test 628 项与全部静态门）。首轮命令被终端 120 秒上限中止在 analyze；随后取消上限完整重跑通过，未放宽验收。

### 代码审查

- 执行器由所有者指定：本机 Cursor 不可用，改用 Codex CLI `0.154.0`；模型 `gpt-6.1-sol`（本机模型目录确认）/ `medium` / 不开快速。用户明确指定同模型审查，此轮按该指示执行，不改变仓库默认执行器。
- 新脚本 `scripts/codex-review.ps1` 复用 `.claude/cursor-review-prompt.md` 的范围 / 判据 / 禁止 / 输出格式；`codex exec review` 以 read-only + never approval 运行，仅本次忽略用户配置并关闭 fast_mode，不改持久配置、不继承快速 service tier。
- Windows 实际调用：`powershell -NoProfile -File scripts/codex-review.ps1 -Scope worktree -Note 'Review iteration-21 memory fixes and the owner-selected Codex review script. Keep existing layout and ACP semantics; verify JSON cache invalidation and lifecycle scheduling, hold/release, disposal. Validation passed on Windows: 628 Flutter tests.'`。范围 `HEAD`（未提交改动，含未跟踪文件）。
- **硬失败，已停下呼人**：`.claude/reviews/20261009-155625-codex-review.err.log` 的启动头确认 `model: gpt-6.1-sol` / `provider: openai` / `approval: never` / `sandbox: read-only` / `reasoning effort: medium`；随后 HTTP 400：`The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account.`；退出码 **1**，`.out.md` 只有 `Review was interrupted...`，不是有效审查结论。
- Codex 失败时未自行换模型 / provider 或回落子代理，也未修改持久配置；随后所有者明确指定 Delta 只读 Reviewer 子代理、模型 Grok 4.7，按新指示执行。
- **有效审查 R1**：Delta Reviewer（`x_ai-subscribed/grok-4.7`），范围 `HEAD` 的全部未提交改动与未跟踪文件；审查线程 `ksQQ--SwTAYATI-JJvIs6KYlR5LOAAEk5pIBxBBMUQWC3bVISrwKfj3By37j`。最终 **findings: 0**（high / P2 / P3 全 0），无需整改或复审。
- 实际覆盖四个实现文件、两个新增测试、审查脚本及三份登记文档；对照 batcher、tool_calls、wire、traffic、Fonts.generation、hold/release 与 disposed。确认 raw 字段替换（含 null）和字体代数的缓存失效、后台微任务与既有帧回调迁移、恢复按帧、hold/release 和 dispose；未重跑测试。
- 审查过程曾重复推演已排除疑点、扫描 CLI 二进制并运行 `flutter --version`（不符合任务书禁止 `flutter *` 的约束）；所有者指出后，主会话要求停止外围探索和重复重读、按已读证据收口。未见文件修改、构建或测试操作；以上过程限制照实记录，不把零 findings 当成真窗口内存曲线验证。
