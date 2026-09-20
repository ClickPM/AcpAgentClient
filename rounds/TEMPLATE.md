# Round NN — <标题>

<!-- 保存为 rounds/round-NN/round-NN.md；该轮其他管理产出放同一目录。 -->

> 状态：<未开始 | 进行中 | 已完成 | BLOCKED>

## 目标

一句话，可证伪。范围不得超出 ROUNDS.md 的功能边界（设计稿 + docs 既定约束）。

## 前置

依赖哪些轮次已完成、需要哪些环境 / 凭据 / 参照 agent；`scripts/fetch-upstream.ps1 -Check` 全绿。

## 交付物

文件级清单，写到路径。复用自 Zed 的文件注明来源路径与 commit（CLAUDE.md 规则 5）。

## 验收

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | | |
| 2 | | |

## 禁止

本轮明确不许碰的东西（防范围蔓延）。默认继承三条：不改前端页面样式（CLAUDE.md 规则 3）；不加设计稿没有的功能（规则 3）；不在 `vendor/upstream/` 里改代码（规则 4）。

## 代码审查

<!-- 完成后回填。审查路由见 CLAUDE.md「开发模式」与 docs/review-workflow.md：
     ① cursor CLI + grok 4.6 high fast → ② 硬失败回落主会话委派的 Claude Code 只读子代理（同一份任务书）。
     范围：前两轮全量（-Scope branch，即 main...HEAD），第 3 轮起只审上一轮整改 diff（-Scope since -Base <上一轮已审提交>）。 -->

- 审查方式：<cursor-review.ps1（默认档）| cursor-review.ps1 -Kind adversarial | Claude Code 子代理（写明 cursor 失败原因）>
- 审查器与模型：<cursor CLI cursor-grok-4.6-high-fast | Claude Code 子代理（写明模型）>
- 审查范围与基准提交：<branch main...HEAD | since <sha>..HEAD>
- findings 处理：<逐条：采纳整改 / 不采纳及理由；或链接同目录记录文件>
- 结论：<PASS | 整改后 PASS>

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-NN/BLOCKED.md`，停下呼人。禁止放宽验收标准自我通过。

## 本轮实测

<!-- 完成后回填：实际数字、踩的坑、与设计 / 计划的偏离及原因；子进程相关改动附 Windows 实测命令与输出（规则 9） -->
