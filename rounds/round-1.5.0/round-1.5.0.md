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
- 发布验证：`scripts/validate.ps1 -CargoTargetDir D:\cargo-target\AcpAgentClient-1.5.0` 全绿（632 Flutter 项、cargo build / test / clippy 与全部静态门）。本次「发布 1.5.0」需要出包，上一轮「合并不跑构建测试」仅适用于当次合并。
- `scripts/build.ps1 -CargoTargetDir D:\cargo-target\AcpAgentClient-1.5.0 -Smoke` 成功；APPDATA 指向终端临时目录，`ok: true`、`coreVersion: 1.5.0`、`droppedEvents: 0`。首次构建因所有者发送缓存范围确认而中断，确认残留编译进程退出后原样重跑，未改代码。
- `scripts/package.ps1 -SkipBuild` 生成 zip / exe，payload 84.1 MiB，含与上一版相同的四份可选字体；`scripts/verify-package.ps1` 的 zip 解压运行、安装器静默装 → 运行 → 卸载全过，VERIFY OK，banner 均为 `AcpAgentClient 1.5.0 (release, windows/x86_64)`。

## 发布与安装

- 构建源码提交 `b078a9d`；此后只更新发布记录 / 清理脚本，不改产品、版本或依赖。
- EXE ProductVersion 为 `1.5.0+1`，`acp_bridge.dll` SHA-256 为 `2fec700aafb894d57f0bdfd2dbd6524980f76aad0abf50ae1872fdec3b898ad8`。
- 待创建附注 tag 和 GitHub release、完成安装镜像。
- 更新目标 `D:\tools\AcpAgentClient`，应用正在运行时不覆盖、不强杀；本轮开始检查运行实例为 0，现有安装为 1.4.9+1。
- 所有 smoke 均隔离 APPDATA，不触碰真实用户数据或会话目录。

## 缓存清理

- 所有者已确认推荐范围：等发布与安装验收成功后，清理本线程旧分支的独立 target，对发布 target 的 debug 剪枝并保留 1.5.0 在用产物；本次 cargokit target 新建，仅当前版本，保留不删指纹。
- 不动其他会话 target、主副本 / release checkout、vendor/upstream、全局 Cargo registry / git 或 Pub Cache；清理前检查编译进程。

| 产物 | 字节 | SHA-256 |
|---|---|---|
| `AcpAgentClient-1.5.0-windows-x64.zip` | 48,405,318 | `46596426c5d47eb72c631cb8ea25a32ca45e84733c36bce8fe491a6c2adf4541` |
| `AcpAgentClient-1.5.0-setup.exe` | 39,903,788 | `5c35514532f5de6c38b380b1b4083371b1bcb4eef77e8ef51a98898243474311` |
