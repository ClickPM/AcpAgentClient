# AGENTS.md

本仓库的全部开发约定、硬性规则与轮次流程见 **[CLAUDE.md](CLAUDE.md)**，请以其为准（本文件只是指针，避免双份维护）。

**执行器**：独立审查优先走 codex 插件（`/codex:review`、`/codex:adversarial-review`），不可用时降级 Claude Code `/code-review` 并在任务卡写明原因。审查任务书（范围 / 判据 / 严重级 / 输出格式）由每轮任务卡的「代码审查」段给出；本文是**长期口径**，任务卡是**每轮口径**，冲突时以任务卡为准。

审查者速记：

- 功能范围唯一边界 = `design/` 的全部画板（清单与计数以 `design/README.md` 为准）；设计稿没有的功能一律判超范围。
- **审查是缺陷门禁，不负责长出方案**：只判定并报告缺陷与严重级别；finding 若指向设计缺陷，标明「设计层面」即可，由所有者重定方案。
- **非严重阻塞性 finding 不得建议机制类修复**（新队列 / 新协议 / 新抽象 / 新配置 / 新导出面）：只建议最小改动或记 `rounds/BACKLOG.md`。
- 依赖白名单是硬规则（CLAUDE.md 规则 1）：`Cargo.toml` / `package.json` 里出现白名单之外的 ACP 客户端、agent 状态或会话 UI 库，判**阻断级**。
- 严格 ACP 投影是硬规则（规则 2）：前端里出现 agent 特判、核心里出现协议之外的私有消息、`_meta` 出现 `docs/design.md` § 4 之外的键，判阻断级。
- 前端样式零改动（规则 3）：接后端只许换数据源，样式 / 布局 / className / token 的 diff 都应质疑。
- 钉版本（规则 4）：`vendor/upstream/` 内的改动、`pins/upstream.json` 与 `docs/research.md` 不同步，判阻断级。
- gpui 不进主进程（规则 5）：`src-tauri/` 依赖树里出现 gpui，判阻断级；复制自 Zed 的文件缺来源头注释，判一般级。
- `unsafe`（规则 6）、明文密钥入库或入日志（规则 8）、对用户数据目录的破坏性写（规则 7），都是阻断级。
- Windows 首发（规则 9）：子进程拉起相关改动没有 Windows 实测记录，判一般级并要求补测。
