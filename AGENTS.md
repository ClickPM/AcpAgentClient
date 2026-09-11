# AGENTS.md

本仓库的全部开发约定、硬性规则与轮次流程见 **[CLAUDE.md](CLAUDE.md)**，请以其为准（本文件只是指针，避免双份维护）。

**执行器**（所有者裁定 2026-09-11，与 agent-xray 一致）：独立审查首选 **cursor CLI（`cursor-agent`）+ `cursor-grok-4.6-high`**；
cursor 硬失败时回落**主会话委派的 Claude Code 只读子代理**，读同一份任务书。
每次审查的任务书（范围 / 判据 / 严重级 / 输出格式）由 `.claude/cursor-review.ps1` 从 `.claude/cursor-review-prompt.md`
实例化后给到审查者；两级的发起、取回与回落条件见 [`docs/review-workflow.md`](docs/review-workflow.md)。本文是**长期口径**，任务书是**每轮口径**，冲突时以任务书为准。

审查者速记：

- 功能范围唯一边界 = `design/` 的全部画板（清单与计数以 `design/README.md` 为准）；设计稿没有的功能一律判超范围。
- **审查是缺陷门禁，不负责长出方案**：只判定并报告缺陷与严重级别；finding 若指向设计缺陷，标明「设计层面」即可，由所有者重定方案。
- **非严重阻塞性 finding 不得建议机制类修复**（新队列 / 新协议 / 新抽象 / 新配置 / 新导出面）：只建议最小改动或记 `rounds/BACKLOG.md`。
- 依赖白名单是硬规则（CLAUDE.md 规则 1）：出现白名单之外的 ACP 客户端、agent 状态或会话 UI 库，或引入 UI 组件库，判**阻断级**；通用库允许清单之外的新增没写理由判一般级。
- 严格 ACP 投影是硬规则（规则 2）：前端里出现 agent 特判、核心里出现协议之外的私有消息、`_meta` 出现 `docs/design.md` § 4 之外的键，判阻断级。
- 前端样式零改动（规则 3）：接后端只许换数据源，样式 / 布局 / className / token 的 diff 都应质疑。
- 钉版本（规则 4）：`vendor/upstream/` 内的改动、`pins/upstream.json` 与 `docs/research.md` 不同步，判阻断级；`vendor/upstream/` 本身不在审查范围。
- gpui 不进主进程（规则 5）：`src-tauri/` 依赖树里出现 gpui，判阻断级；复制自 Zed 的文件缺来源头注释，判一般级。
- `unsafe`（规则 6）、明文密钥入库或入日志（规则 8）、对用户数据目录的破坏性写（规则 7）、未走钉版本流程改动协议特性集（规则 10），都是阻断级。
- Windows 首发（规则 9）：子进程拉起相关改动没有 Windows 实测记录，判一般级并要求补测。
- 审查范围口径：前两轮全量分支 diff，第 3 轮起只审上一轮整改 diff；范围之外的既有问题不报，记 BACKLOG。
