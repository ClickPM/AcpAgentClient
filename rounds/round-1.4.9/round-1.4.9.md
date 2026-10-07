# round-1.4.9 — Active 行精简与 Reload Agent 文案发版

## 授权与基线

- 所有者要求：基于最新 main 发布 1.4.9，更新本地安装版；成功之后清历史 Rust 构建缓存，只留最新版在用产物。
- 所有者明确授权直接操作现有 `D:\variFlight_work\AcpAgentClient-release`，不必附加到 Delta。
- 基线：`main = a784f42`；上一发布 `v1.4.8 = f4e5e57`。产品改动仅 iteration-21 的 Active 行精简、iteration-22 的 Reload Agent tooltip。
- 版本号：`pubspec.yaml` / `rust/Cargo.toml` 与 Cargo.lock 七个本地 crate 改为 1.4.9；不改依赖版本。
- 本轮不修 BACKLOG 中 Send Now / Close 竞态，不把问题登记写成修复。

## 主会话 review

已逐处核对 `v1.4.8..a784f42` 非文档 / 非设计稿 diff：产品仅两处 UI 文案与相应侧栏测试，未改生命周期、协议与重载逻辑。历史发版脚本未改产品，清理前单独核对范围与守卫。未发现需整改问题。

## 验证与代码审查

release 工作区 `4ae8d58` 上完整 `scripts/validate.ps1` 通过（VALIDATE OK），上游八项钉版本、Rust build / test / clippy、静态门、Flutter analyze 全过；Flutter 测试 622 项全过。

首次 validate 的 Rust build / test / clippy 全过，但 Flutter 启动挂住。进一步定位为本机全局 Git `safe.directory` 列表中的不可达 UNC 路径：Git 校验另一个所有者安装的 Flutter / vendor 仓库时扫描该列表，卡在网络路径解析。用 `GIT_CONFIG_COUNT` 重置不能阻止先扫描旧项。最终将全局配置复制到终端临时目录，移除该副本的安全目录条目，仅加入 Flutter 与上游目录，再通过子进程 `GIT_CONFIG_GLOBAL` 使用这份临时配置，保留原凭据配置且不修改用户全局配置；完整验证通过。试验性的 fetch 脚本调整已撤回，脚本净 diff 为零。

### 审查硬失败（停下等所有者）

- 命令：`powershell -NoProfile -File .claude/cursor-review.ps1 -Scope since -Base v1.4.8 -Wait -Note <发布范围：非文档 diff，UI 两项与版本号>`。
- 执行器：Cursor CLI / `grok-4.7-high-fast`。
- 产物：release 工作区 `.claude/reviews/20261007-144847-review.prompt.md` 与 `.out.md`。
- `.out.md` 输出：`ActionRequiredError: Named models unavailable Free plans can only use Auto. Switch to Auto or upgrade plans to continue.`
- 包装脚本退出码为 0，但输出是套餐拒绝指定模型，不是 findings，也不是审查通过。`-Wait` 分支不生成 `.err.log`。
- 按 AGENTS.md 硬失败规则停下，不换 Auto、不回落子代理。等待所有者恢复指定模型权限或明确点名只读独立审查执行器。

### 所有者裁定：发版不追加审查

所有者指出本次只发布 main 的既有改动，不是新开发，明确要求继续发布、无需 Cursor。本轮未追加独立审查（所有者指定），不换审查执行器，不修改产品代码。完整 validate 结果沿用，不重复执行。

## 发布、安装与清理

- 发布构建源码：`fdb6b8a`；此后仅补发布记录与产物哈希，不改产品、版本或依赖。
- `scripts/build.ps1 -Smoke` 成功；APPDATA 指向临时目录，不接触真实用户数据。`ok: true`、`coreVersion: 1.4.9`、`droppedEvents: 0`。
- `scripts/package.ps1 -SkipBuild` 成功，payload 84.1 MiB；包内四个可选字体仅随应用分发。
- `scripts/verify-package.ps1`：zip 解压运行与安装器静默装 → 运行 → 卸载均通过，VERIFY OK；两处 banner 均为 `AcpAgentClient 1.4.9 (release, windows/x86_64)`。

| 产物 | 字节 | SHA-256 |
|---|---|---|
| `AcpAgentClient-1.4.9-windows-x64.zip` | 48,400,570 | `e812b693ad44e70be1638cf696d0a0b9f98514b9e1685a153344c4e87399b4b9` |
| `AcpAgentClient-1.4.9-setup.exe` | 39,903,213 | `54a2d9659667d425da1d35124addeb696c66d0e67224e2fb5dc91bd39671fae4` |

## 发布结果（2026-10-07）

- 附注 tag `v1.4.9` 指向 `7fe9bae`（相比构建源码只增加发布记录）。GitHub main 与 tag 已推送。
- GitHub release：<https://github.com/ClickPM/AcpAgentClient/releases/tag/v1.4.9>，非 draft、latest 为 v1.4.9；两个 assets 均 uploaded，远端 digest 与上述 SHA-256 一致。
- Cursor origin 推送失败：HTTP 403，`Origin requires a paid plan; user is on 'free'`。不是 GitHub 发布失败，未强推或改认证配置；origin 镜像保持旧状态。
- 本地日用目录 `D:\tools\AcpAgentClient` 已更新。`release-mirror.ps1` 从验收过的包镜像，连同 LICENSE / NOTICE 共 44 个文件清单及逐文件 SHA-256 全一致；robocopy exit 1（成功复制）。
- 安装目录隔离 APPDATA smoke：`ok: true`、`coreVersion: 1.4.9`、`droppedEvents: 0`；banner 为 release / windows x86_64，exe FileVersion / ProductVersion 均 1.4.9+1。未触碰真实 APPDATA 或会话数据。

## 成功之后的缓存清理

- 先确认没有 cargo / rustc / dart / link / cl / msbuild 在编译，再清理；未删除 vendor、全局 Cargo registry / git、Pub Cache 或其它项目目录。
- debug：沿用 `rounds/round-1.4.8/prune-cargo-debug.ps1`，Cargo build / test --no-run / clippy 自报在用 hash 并集 454 个；删除 74 个旧 deps 文件（2.51 GiB）、incremental（4.92 GiB）。剪枝后三条均 0 重编，debug 保留 11.00 GiB 的当前版依赖闭包。
- cargokit release：临时脚本收集当前 acp_bridge 的 compiler-artifact / build-script 输出与 fingerprint trace，在 host / Windows target 两个 release profile 剪枝；删除 45 个文件与 133 个目录，199,277,842 字节（0.19 GiB）。fingerprint 采集不足导致剪枝后检查重编 148 个单元；已完成当前 1.4.9 缓存重建，未再次删除。随后独立检查 243 个 compiler-artifact **全部 fresh、0 重编**。这不是「剪枝后一直零重编」，不要照抄临时 fingerprint 删除方法。
- release 缓存重建不会重新发布或覆盖安装文件：安装目录与已打包 Release 的 acp_bridge.dll SHA-256 仍一致（`0065007376bbed79fcd551c8ffe3de0291761e54f6b95b0e79f02e41c159e386`）；最终 cargokit 目录保留 0.92 GiB。
- 删除 release 工作区的 v1.4.8 两个旧包与已用完的 dist/stage，共 176,449,069 字节；dist 只剩 v1.4.9 zip 与 exe，保留最新 Release 构建输出。
- 发布后补记与安装脚本仅追加到 main，不移动已发布 tag，不改发布产物。
