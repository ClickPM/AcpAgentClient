# round-1.5.1 — 会话草稿隔离与超大流量行发版

## 授权与基线

- 所有者要求构建并更新本地安装版、把最新 main 同步到 GitHub、以 v1.5.1 发 release，然后清理本次构建之前的构建缓存、分支和 worktree。沿用 v1.5.0：只推 GitHub，不推 origin。
- 基线 `main = 9afdd53`，上一发布 `v1.5.0`。产品改动是 iteration-25 的两条 P0。
- `pubspec.yaml` / `rust/Cargo.toml` 与 Cargo.lock 七个本地 crate 改为 1.5.1。sidecar 不随包。
- 在本线程的 Delta worktree 出包。独立 target：`D:\cargo-target\AcpAgentClient-1.5.1`。四份可选字体从主副本 `assets/fonts/optional/` 复制进本 worktree（gitignored，不提交）。

## 审查与验证

- 审查：所有者指定的 Delta Reviewer / GPT-6.1-Sol，中等思考。R1 为 3 条 high、2 条 P2；high 与转义代理对已整改。R2 findings 0。完整流量原文仍留在环形缓冲里，不另设累计上界。
- `scripts/validate.ps1 -CargoTargetDir D:\cargo-target\AcpAgentClient-1.5.1` 全绿（Flutter 644 项）。
- `scripts/build.ps1 -Smoke` 用同一 target。脚本自带的 smoke 用了真实 APPDATA（`build.ps1` 没有改 `%APPDATA%`）；安装目录验收改用临时 APPDATA，`ok: true`、`coreVersion: 1.5.1`、`droppedEvents: 0`。
- `scripts/package.ps1 -SkipBuild` 与 `scripts/verify-package.ps1`：VERIFY OK。zip 与安装器的 banner 都是 `AcpAgentClient 1.5.1 (release, windows/x86_64)`。

## 发布与安装

- 构建源码提交 `916184e`（`release: 1.5.1`）。tag `v1.5.1` 指向这一提交。
- EXE FileVersion / ProductVersion 均为 `1.5.1+1`。
- 安装目录 `D:\tools\AcpAgentClient` 当时没有从该路径启动的进程，已用 stage 目录镜像覆盖。与 stage 的 `acp_agent_client.exe`、`acp_bridge.dll`、`data\app.so`、`FontManifest.json` 哈希一致。安装目录 smoke 使用临时 APPDATA。

| 产物 | 字节 | SHA-256 |
|---|---|---|
| `AcpAgentClient-1.5.1-windows-x64.zip` | 48,407,438 | `3ada8d0af6a3115f25429b4a7b773f08dcda9a1fca648647423669b6963d3971` |
| `AcpAgentClient-1.5.1-setup.exe` | 39,907,177 | `a6abffee4a36486fd24a98db4b49327d2c7305b88958e8235391dfdb7de5ca84` |
