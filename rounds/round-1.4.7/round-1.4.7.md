# round-1.4.7 — v1.4.6 之后的三项内容发版（2026-09-29）

发版轮（不走轮次流程，无审查轮）：把 v1.4.6 之后合入 `main` 的 iteration-16、17、18 出包、镜像到日用安装目录、推 github 与 origin 并建 GitHub release。三项合并前各自经 cursor（`grok-4.7-high-fast`）审到 0 条收口，本轮不再开审查。

## 内容

| 项 | 要点 | 基线 |
|---|---|---|
| iteration-16 | 从产品、功能与构建体系彻底移除 Zed：`zed-agent-acp` 内置条目与 sidecar 探测、设置页「从 Zed 导入」（`zed_import.rs` / `agent_settings_import_zed`）、`sidecar/zed-agent-acp/` 独立 workspace 与 `scripts/build-sidecar.ps1`、`windows/CMakeLists.txt` 的安装规则、`assets/zed-icon.svg`；打包从双包收敛成单包 | `2d67f24` |
| iteration-17 | 侧栏会话区分 Active（有存活连接、绿标）与 History 两组，History 可折叠；搜索保持分组，点 History 会话升格到 Active、断开或关闭后沉降回去（画板 45） | `9c73c50` |
| iteration-18 | 工具卡图片不再按帧重解 base64（`content_blocks.dart` 的 `_ImageBlock` 改 `StatefulWidget`，只在 `data` 变化时解）、流量面板缩进 JSON 改按需计算并记忆化（`traffic.dart`）；会话转录 LRU 淘汰经所有者当场裁定暂不做 | `9c73c50` |

## 版本号与提交

- `473cd09`「版本号 1.4.7：pubspec.yaml 与 rust/Cargo.toml 两处 + Cargo.lock 里 7 个本地 crate」：`pubspec.yaml` `1.4.7+1`、`rust/Cargo.toml` `[workspace.package] version = "1.4.7"`、`rust/Cargo.lock` 里 7 个本地 crate（`cargo metadata --offline` 重写）。
- 同一提交里 README.md / README.en.md 去掉 iteration-16 已删除的 Zed 描述：支持列表里的 Zed Agent 条目、安装产物表里已不存在的 `-nosidecar.zip`、构建命令里的 `build-sidecar.ps1`、sidecar 相关的架构与许可证段（复用文件数 15 → 10、来源目录 `rust/` 与 `lib/app/`），并登记 v1.4.7。
- `release-build` 提交 → `main` 快进到 `473cd09` → 附注 tag `v1.4.7`（`9ebae2b`）→ 推 github 与 origin 两远端（`main` 与 tag 都已核对远端口径）。

## 出包与验收（release worktree `D:\variFlight_work\AcpAgentClient-release`）

- `scripts\validate.ps1` 全量：**17 道门全绿**，`flutter test` **614 项**通过（`app 1.4.7`）。
- `scripts\package.ps1`：`acp_agent_client.exe` 123,392 B / `acp_bridge.dll` 13,007,872 B，Inno Setup 出安装器。
- `scripts\verify-package.ps1`：**VERIFY OK** —— zip 解压即用（空数据目录 + 无头往返）与安装器静默装 → 跑通 → 静默卸载两段都过，banner 都是 `AcpAgentClient 1.4.7`。

| 产物 | 体积 | SHA-256 |
|---|---|---|
| `AcpAgentClient-1.4.7-windows-x64.zip` | 48,399,179 B（46.2 MiB） | `67ddc9424aae91d3657d01e9aa72c56f05fd49e20fe3dba4f95f98e550d67d5a` |
| `AcpAgentClient-1.4.7-setup.exe` | 39,901,782 B（38.1 MiB） | `e8d0dd8178e3add05ad563ade82a76b26bdc2ae284e989de387bfbb71b597254` |

一件 zip 的原因是 sidecar 已从产品移除；免安装 zip 从 v1.4.6 的 107.3 MB 降到 46.2 MB。GitHub release <https://github.com/ClickPM/AcpAgentClient/releases/tag/v1.4.7> 带这两件产物（`gh release view` 里两件 `state=uploaded`）。

## 镜像到日用安装目录

`rounds\round-1.4.7\release-mirror.ps1`（`robocopy /MIR`，先查应用未在跑）：

- 42 = 42 个文件，`acp_agent_client.exe` / `acp_bridge.dll` / `data\app.so` / `data\flutter_assets\FontManifest.json` 四处哈希与 dist 一致（`robocopy exit 0`）。
- 临时 `APPDATA` 下 smoke：`coreVersion 1.4.7`、`droppedEvents 0`；banner `AcpAgentClient 1.4.7 (release, windows/x86_64)`；exe 的 `FileVersion` / `ProductVersion` 都是 `1.4.7+1`；安装目录里没有 `zed-agent-acp.exe`。
- 脚本第一版把 `coreVersion` 当成顶层字段读，实际在 `init` / `ping` / `coreReady` 里，已改正并重跑一遍（第二遍 `robocopy exit 0` 直接对上）。

## 打扫（本次构建之前的缓存、分支与 worktree）

- `rounds\round-1.4.7\cleanup-build-outputs.ps1`：`dist\stage` 84.1 MB、主 worktree 的 `build\sidecar`（内有一个 176.9 MB 的旧 `zed-agent-acp.exe`，产品已不再构建也不再认它，全树最后一个）、主 worktree 的 `build\test_cache` 70.9 MB、1.4.6 的两件产物 84.2 MB，合计 **0.41 GB**。
- `rounds\round-1.4.7\prune-cargo-debug.ps1`：共用 target `D:\cargo-target\AcpAgentClient` 按 cargo 自报的在用 hash 集合剪枝（build 266 / test 273 / clippy 281 units，454 个 hash）：`deps` 删 74 个 2.51 GB、`build` 无可删、`incremental` 整删 9.83 GB，合计 **12.34 GB**；重跑三条 cargo **0 重编**，`du` 口径 20 GB → 7.5 GB。
- `rounds\round-1.4.7\cleanup-worktrees.ps1`（守卫文件从 `vendor\upstream\zed\Cargo.toml` 改成 `vendor\upstream\agent-client-protocol\Cargo.toml`，zed 已不在 vendor 里）：注销 iter18 worktree（先拆 5 个 `ephemeral\.plugin_symlinks` 联接，**0.30 GB**）、删掉已合入的 `claude/iter-17-active-history-sessions` 与 `claude/iter-18-transcript-memory`；`vendor\upstream` 前后都是 8 项。
- 结果：D: 可用 290.6 GB → 303.6 GB（**+13.0 GB**）；worktree 只剩 `AcpAgentClient`（`main`）与 `AcpAgentClient-release`（`release-build`），分支只剩 `main` / `release-build` / `pr-1`。

## 留给下一轮 / 所有者

- **旧文档里的 Zed 残留**（本轮未动，属另一件事）：`CLAUDE.md` 规则 5 / 11 与多处结构说明、`ROUNDS.md`、`docs/zed-agent.md`（第 182 行仍写「总是出一个 `-nosidecar.zip`」）、`scripts/README.md`、`docs/design.md`。
- 旧版用户升级后安装目录里会留一个约 176 MB 的 `zed-agent-acp.exe` 孤儿文件（Inno 不删未知文件），应用不会再列出它，已写进 release 正文提示手动删。
