# agent-notes — 工程实践与踩坑索引

> **这不是规范正本。** 开发约定与硬性规则在 [`AGENTS.md`](../../AGENTS.md)，冲突时**以 `AGENTS.md` 为准**；
> 这里放的是「怎么在这个仓库里把活干对」的实践、命令、实测数字与坑。
> **动手前先扫一眼下面那张表** —— 这些坑每一条都是「命令看着成功、结果是错的」，第二次遇到很难再定位。

## 这份目录是怎么来的

2026-09-29 从上一代开发 agent（Claude Code）的**项目私有记忆库**整批内联入库
（原位置 `~/.claude/projects/D--variFlight-work-AcpAgentClient/memory/`，34 份 + 一份 `MEMORY.md` 索引）。
原因是项目不再绑定某一个 agent：私有记忆只有那一个 agent 读得到，换执行器就等于把两年来攒的实测结论丢掉。

**从今以后这里是正本**：新踩的坑写进本目录（按主题加到对应那份，或开新的一份并在下表登记），
别再只写进某个 agent 自己的记忆目录 —— 个人 agent 的私有记忆里若与本文不一致，**以本文为准**。

## 索引

| 文件 | 一句话 |
|---|---|
| [`build-and-cache.md`](build-and-cache.md) | 构建缓存都在 `D:\cargo-target`（几个副本共用，会涨到 70 GB+）怎么盘、怎么剪；**共用 target 会串代码**，改 `rust/` 的分支要用自己的目录；pub 缓存走 flutter-io.cn 镜像 |
| [`flutter-and-windows.md`](flutter-and-windows.md) | Flutter Windows 的构建 / 测试 / 无边框窗口坑：开发者模式、非 ASCII 路径、测试 zone 是 FakeAsync、GUI 进程 stdout、FLUTTERVIEW 吃掉边框命中测试、`flutter test` 并发与字体、真窗口里测 GPU/CPU |
| [`git-and-parallel-sessions.md`](git-and-parallel-sessions.md) | 同一个工作副本会被多个会话同时改：提交前重查 status、只 add 自己的路径、commit 后核对文件数；worktree 的 `vendor/upstream` 用目录联接、拆之前先拆联接；并行轮次的合并与编号抢号 |
| [`review-runbook.md`](review-runbook.md) | 审查者速记（长期口径）+ 发起 / 取回 / 判死活；`-Wait` 产物是 UTF-16；掉线先同执行器重试；**硬失败就停下喊人，不自动回落** |
| [`release-pipeline.md`](release-pipeline.md) | 所有者「review 完就发版」的整条流水线：验证 → 出包 → 验收 → 推两远端 → 发 release → 更新本地安装版 → 清缓存；日常那份 release 装在 `D:\tools\AcpAgentClient` |
| [`runtime-and-debugging.md`](runtime-and-debugging.md) | 拿真实 ACP 日志回放排障（日志按 UTC 分天）；重载后气泡里的 `[Context]` / `[resource_link]` 原文是上游重放格式、不是渲染 bug；claude-agent-acp 的 OAuth 过期锁 |
| [`upstream-and-design.md`](upstream-and-design.md) | 怎么把设计画板从画布拉回仓库（画布未必比本地新）；改 dsh 上游并发 npm 的路子与四个环境坑；本机生图网关 |
| [`owner-rulings.md`](owner-rulings.md) | 所有者怎么处理裁定门（给一个推荐项 + 备选，他整批按推荐批）；**所有方向的合并时机都归他** |
| [`harness-pitfalls.md`](harness-pitfalls.md) | **执行器专属**（不是项目规则）：上一代是 Claude Code 的工具栈（Bash 工具 heredoc、PowerShell 工具沙箱、worktree 隔离、工具对用户目录的虚拟化视图、`python3` 占位程序）。换 agent 后按自己的工具重写这一份 |

## 读法约定

- **`（本机）`** 标记 = 只在这台机器 / 这个用户下成立（路径、镜像、环境变量、已装的全局工具）。换机器时按下面的清单重核。
- **`（当时）`** 标记 = 实测数字，会随版本变，但量级与判据仍然可用。
- 命令一律写 PowerShell（`pwsh`）或 Git Bash 两种环境里**实测过**的那一种；含中文的 `.ps1` 必须 UTF-8 with BOM。
- 涉及 `%APPDATA%` / `%LOCALAPPDATA%` 用户目录的结论要标明是不是在真实文件系统上确认过的，见 [`harness-pitfalls.md`](harness-pitfalls.md)。

## 换机器要重核（`（本机）` 条目的汇总）

| 项 | 本机现状 | 判据 / 怎么重核 |
|---|---|---|
| 用户名 / 工作副本路径 | 用户名已是纯 ASCII（`Click`），仓库在 `D:\variFlight_work\AcpAgentClient`（`（本机）`） | 路径含中文或空格时只能走 `scripts/build.ps1`，见 [`flutter-and-windows.md`](flutter-and-windows.md) |
| 构建缓存根 | `CARGO_TARGET_DIR=D:\cargo-target\AcpAgentClient`（`（本机）`，所有者裁定 2026-09-15） | 纯 ASCII、与仓库不同盘；见 [`build-and-cache.md`](build-and-cache.md) |
| 日常使用的安装版 | `D:\tools\AcpAgentClient`（`（本机）`），桌面快捷方式「AcpAgent Client.lnk」指它 | 见 [`release-pipeline.md`](release-pipeline.md) |
| pub 缓存 | 走 `pub.flutter-io.cn` 镜像，包源码在 `%LOCALAPPDATA%\Pub\Cache\hosted\pub.flutter-io.cn\`（`（本机）`） | 查 `.dart_tool/package_config.json` 的 `rootUri` |
| Python | Bash 工具里只能写 `python`（`python3` 是 Store 占位程序）（`（本机）`） | `python -V`；见 [`harness-pitfalls.md`](harness-pitfalls.md) |
| 全局安装的 dsh | `%APPDATA%\npm` 里有一份，会盖住客户端内置条目钉的 npx 版本（`（本机）`） | 要测 npx 那条路，先从 PATH 摘掉 `%APPDATA%\npm` |
| 审查器 | `cursor-agent` 在 `%LOCALAPPDATA%\cursor-agent\cursor-agent.cmd`，不在 PATH，须先 `cursor-agent login`（`（本机）`） | 见 [`review-runbook.md`](review-runbook.md) |
| Windows 开发者模式 | 2026-09-15 起已开启 | 注册表 `AppModelUnlock\AllowDevelopmentWithoutDevLicense` |
| 全局记忆里还有一份 | 跨项目通用的 Windows 坑在用户级 `~/.claude/CLAUDE.md`（BOM / `%TEMP%` 8.3 短名 / `\\` 塌陷 / docker 在 WSL） | 与本项目相关的那几条已折进 [`harness-pitfalls.md`](harness-pitfalls.md) 与 `AGENTS.md`「本地开发」 |

## 往这里加东西时

1. 按主题加到现有的那一份；主题不合再开新的一份并**登记到上表**。
2. 每条写清「现象 → 真因 → 判据 → 怎么办」；只写结论不写现象，下次就认不出来。
3. 带实测时点与数字（`（2026-09-23 实测）`），并区分「一直成立」与「当前版本才成立」。
4. 属于**项目规范**的（依赖白名单、设计稿边界、钉版本流程……）不进这里，改 `AGENTS.md` 的对应规则。
5. 属于**上游 / 协议本身**的问题不进这里，也不进 `rounds/BACKLOG.md`（所有者裁定 2026-09-23）。
