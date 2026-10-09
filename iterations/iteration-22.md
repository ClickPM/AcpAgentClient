# Iteration 22 — Reload Agent 文案与研究收口

> 状态：已完成（main 直改；未构建 / 未审查）　起止：2026-09-30 – 2026-09-30　基线：`main` = `291cd6d`

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | ux | 会话头 tooltip 由 `Reload this session` 改为 `Reload Agent`，保持当前行为，不增加中断提示；记录 ACP、各 agent 与 Zed 源码研究，关闭对应 backlog | 所有者 2026-09-30 裁定 | `main` 直改 | `git diff --check` 与改动范围核对；未构建、未运行测试或客户端手测（所有者指定，仅本次有效） | 未审查（所有者指定，仅本次有效） | 已完成 |

## 收口

- 代码只改 `lib/ui/shell/session_header.dart` 一处字符串；`reloadAgent()`、Rust 核心、bridge、tokens 均无改动。
- 研究正本：`docs/research.md` § 4.4。Zed UI 叫 Reload Agent，替换缓存连接并在新连接 load/resume 当前根会话；旧连接用 Rc 管理，其他会话仍持有时未必立即退出。AAC 显式断开旧连接，生命周期不完全相同，不冒称隔离行为一致。
- 本次只纠正文案；不实现 session 级重建、不加提示或确认框。闭项见 `rounds/BACKLOG-CLOSED.md`，设计偏离见 `design/DIVERGENCE.md` 第 38 条。
- 所有者授权：commit main 后只推 `github` 的 main；不推 `origin`，不构建、不 review（仅针对本次）。版本号不变。
- 工作区原有「切换 session 草稿串入另一会话」登记与研究子代理的 `ai-output/` 临时产物不属于本次提交，保留未提交。
