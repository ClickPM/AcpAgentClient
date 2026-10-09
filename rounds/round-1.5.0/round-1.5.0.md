# round-1.5.0 — 内存路径与 Copy 反馈修复发版

## 授权与基线

- 所有者要求发布 1.5.0、更新本地安装版，成功后清理构建缓存；沿用上一轮「只推 GitHub、不推 origin」。
- 基线 `main = deb0e93`，上一发布 `v1.4.9 = 7fe9bae`。产品改动为 iteration-23 / 24 的四项修复；本轮不新增功能、不改 ACP 契约或依赖版本。
- `pubspec.yaml` / `rust/Cargo.toml` 与 Cargo.lock 七个本地 crate 改为 1.5.0；sidecar 已移除，不随包。
- 在本线程附加的干净 Delta worktree 出包，不写未附加的主副本或 release checkout。独立 target：`D:\cargo-target\AcpAgentClient-1.5.0`。
- 将主副本已有四份可选字体复制到本 worktree 的 gitignored `assets/fonts/optional/`，保持与 1.4.9 相同的随包字体；不提交字体、不单独分发。

## 审查与验证

- 主会话核对 `v1.4.9..deb0e93`：产品代码与已审两轮修复一致，合并仅四份文档冲突，GitHub 原有代码与 v1.4.9 保留。
- 独立缺陷门禁沿用 iteration-23 / 24 的 Delta Reviewer / Grok 4.7 两份有效结论，均 0 条 findings。版本与发布记录不修改产品行为，不为此调用不可用的 Cursor / Codex。
- 发布验证、构建自检、zip / 安装器验收：待执行。本次「发布 1.5.0」需要出包，上一轮「合并不跑构建测试」仅适用于当次合并。

## 发布与安装

- 待构建 zip 与安装器、计算 SHA-256、创建附注 tag 和 GitHub release。
- 更新目标 `D:\tools\AcpAgentClient`，应用正在运行时不覆盖、不强杀；本轮开始检查运行实例为 0，现有安装为 1.4.9+1。
- 所有 smoke 均隔离 APPDATA，不触碰真实用户数据或会话目录。

## 缓存清理

- 等发布与安装验收成功后执行；拟清理本线程旧分支的独立 target，对发布 target 剪枝并保留 1.5.0 在用产物，等待所有者确认范围。
- 不动其他会话 target、主副本 / release checkout、vendor/upstream、全局 Cargo registry / git 或 Pub Cache；清理前检查编译进程。
