# Round 08 — 打包与发布（Windows 端）

> 状态：进行中

## 目标

Windows 免安装 zip 与 per-user 安装器随包 sidecar 一起交付，并且**把 sidecar 的版本号从应用版本上解开**——发一次应用版本不再白烧一刻钟的重链。

范围按所有者 2026-09-20 的指示裁到 **Windows 端**：macOS 构建、原生 traffic lights 与 Linux 留给后续（ROUNDS.md § 3 的 R8 交付物里那两条不在本轮）。

## 前置

- R7 已完成（sidecar 随包的 CMake install 规则在 `windows/CMakeLists.txt`）；R7.5 已合入 `main`。
- `scripts/fetch-upstream.ps1 -Check` 全绿（2026-09-20 实测，9 条 OK）。
- 本机 Inno Setup 6（`C:\Program Files (x86)\Inno Setup 6\ISCC.exe`，已在 PATH）。
- `build/sidecar/zed-agent-acp.exe` 存在（`scripts/build-sidecar.ps1` 产出）。

## 裁定（开工前，所有者 2026-09-20）

| # | 项 | 裁定 |
|---|---|---|
| 1 | sidecar 版本解耦后取什么值 | **跟 zed 钉版本走**（`pins/upstream.json` 的 `zed.version` = `1.21.0`），不跟应用版本走；备选「独立起 1.0.0」「冻结 1.3.0」未采纳 |
| 2 | 干净机验收（ROUNDS R8 验收 1） | **只做自动化**，不记「待所有者在 VM 上跑」的待办 |
| 3 | 安装器形态 | **Inno Setup · per-user**（装进 `%LOCALAPPDATA%\Programs`，免 UAC、不签名）；同时出含 / 不含 sidecar 两个免安装 zip |
| 4 | 本轮范围 | 只做 Windows 端（用户原话「完成 R8 Windows 端」） |

## 交付物

- `sidecar/zed-agent-acp/Cargo.toml`：`version` 由 `1.3.0`（跟着应用抬）改为 `1.21.0`（= zed 钉版本），连同解耦理由的注释。
- `pins/upstream.json`：zed 条目加 `version` 字段（上游 crate 版本，`vendor/upstream/zed/crates/zed/Cargo.toml`），`notes` 写明它是 sidecar 版本的事实来源。
- `sidecar/zed-agent-acp/build.rs`：加 `ZED_PINNED_COMMIT`（从 pins 手工扫，不引 serde）；`src/main.rs` 的 `--version` 改为 `zed-agent-acp 1.21.0 (zed @ <commit>)`。
- `scripts/validate.ps1`：新增「版本门」（应用两处一致；sidecar == pins zed version == vendor zed manifest；sidecar ≠ 应用版本），并把原「Zed 派生文件头注释」一步扩成与 `NOTICE` 双向核对（ROUNDS R8 验收 4）。
- `scripts/package.ps1`（新）：zip（含 / 不含 sidecar）+ Inno Setup 安装器，产物落 `dist/`（已加 `.gitignore`）。
- `packaging/windows/acp-agent-client.iss`（新）：per-user 安装器脚本，`LICENSE` 进向导，卸载不动 `%APPDATA%\AcpAgentClient`。
- `scripts/verify-package.ps1`（新）：打包产物的自动化验收（空 `%APPDATA%` 上跑无头自检、随包 sidecar 自检、安装器静默装 / 跑 / 卸）。
- `rust/acp-core/src/{log.rs,core.rs}`：起核心时往 `logs/acp-<日期>.log` 写一行版本与构建信息（画板 70 没有版本位，按规则 3 只进日志）。
- 文档：`README.md`（构建与运行 + 状态）、`CLAUDE.md`（仓库结构、本地开发的命令表）、`ROUNDS.md`（R8 段与进度表）、`docs/design.md` § 10（日志首行）。

## 验收

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | 版本解耦成立 | 抬应用版本（`pubspec.yaml` + `rust/Cargo.toml`）后跑 `scripts/build-sidecar.ps1`：cargo 判 fresh，秒级结束、不重链 |
| 2 | 解耦前的代价有数 | 改 sidecar `version` 那一次的重链耗时实测记本卡（对照：不改时 8.2 s） |
| 3 | 版本门拦得住 | `scripts/validate.ps1` 新增 Step PASS；手工把 sidecar 版本改成应用版本时该 Step FAIL |
| 4 | 三件产物 | `scripts/package.ps1` 产出 zip（含 / 不含 sidecar）与 `AcpAgentClient-<版本>-setup.exe`，三个体积数字记本卡 |
| 5 | 解压即用 / 装得上卸得掉 | `scripts/verify-package.ps1` 全绿（空 `%APPDATA%` 无头往返、随包 sidecar `--version` / `--selftest`、静默装 → 跑 → 静默卸） |
| 6 | 日志版本行 | 空数据目录首启后 `logs/acp-<日期>.log` 里有 `core AcpAgentClient <版本> (release, windows/x86_64) data=… sidecar=…` |
| 7 | NOTICE 与头注释一致 | validate 的同名 Step PASS（双向：扫到的派生文件都在 NOTICE；NOTICE 列的都在盘上且带头注释） |
| 8 | validate 全绿 | `scripts/validate.ps1` 16 项全 PASS（15 项 + 新增的版本门；NOTICE 核对并进既有的派生文件那一步） |
| 9 | 文档同步 | README / CLAUDE.md / ROUNDS.md / docs/design.md 改动随本轮提交 |

## 禁止

默认三条（不改前端页面样式、不加设计稿没有的功能、不在 `vendor/upstream/` 改代码）之外，本轮另加：

- **不往 UI 里加版本号**：画板 70 没有版本位，规则 3 下它只能进日志；要显示得先改设计稿。
- **不动 macOS / Linux 的构建链**（本轮范围只到 Windows）。
- **不为了缩体积裁 sidecar 的依赖**（`languages` crate 的事是 BACKLOG 里的构建环境问题，不在打包轮里动）。
- **不签名、不上应用商店**：per-user 免签是本轮的裁定结果。

## 代码审查

- 审查方式：`powershell -File .claude/cursor-review.ps1`（默认档，后台）
- 审查器与模型：cursor CLI `cursor-grok-4.6-high-fast`
- 审查范围与基准提交：第 1 轮全量 `main...HEAD`（本轮提交 `c1c3fbf`，22 文件 +659 / -33）；产物 `.claude/reviews/20260920-170310-review.out.md`
- findings 处理：**3 条（high 0 / P2 2 / P3 1），全部采纳整改**

  | # | 级别 | finding | 整改 |
  |---|---|---|---|
  | 1 | P2 | 安装器验收与正式安装共用固定 `AppId`：跑一遍会把本机已有安装的卸载注册顶掉；装上之后中途失败则连这次安装都卸不掉；脚本声称验「卸载不动用户数据」但那是假绿的（卸载时 `%APPDATA%` 已恢复成真路径，Inno 的 `{userappdata}` 也不读进程环境变量） | `verify-package.ps1`：AppId 改为从 iss 里读（不在两处各写一份 GUID）；HKCU 已有同 AppId 的卸载键时**跳过**这条并在末尾报 `SKIPPED`；装上之后用 `try/finally` 保证一定跑卸载，卸完再断言 exe 与卸载注册都没了；「不动用户数据」改成**静态**核对 iss 里没有 `[UninstallDelete]` / `[InstallDelete]` 段，脚本头注释同步写明这条是静态的 |
  | 2 | P2 | `build.rs` 的 `pinned_commit` 只往后找第一个 `"commit"`：pins 里字段一旦重排成 `branch` / `commit` / `name`，拿到的会是**下一条上游**的 commit（`claude-agent-acp`），而且不会退回 `unknown`；版本门只比版本号，拦不住 | 搜索范围先收到**同一个 `{ … }` 对象**（name 前最近的 `{` 到 name 后最近的 `}`）再找 commit，找不到返回 `None`；`verify-package.ps1` 的 `--version` 断言从「commit 前 12 位」改成**完整 commit** |
  | 3 | P3 | `Invoke-Smoke` 先建沙箱目录、成功返回后才登记到清理列表，自检失败时那个 `%TEMP%` 目录留着没人删 | 建完目录立刻 `$sandboxes.Add($sandbox)`，两处调用点去掉重复登记 |

  审查同时逐条核过规则 1–11 与 NOTICE 双向门，未报其余问题。第 2 条的整改要动 `build.rs` → sidecar 全量重链一次（14 分钟），产物与 `verify-package.ps1` 因此重跑了一遍。

  第 2 条的复核（把 `pinned_commit` 整改前后的算法各跑一遍，`build.rs` 是 build script、`cargo test` 碰不到它，所以拿同一套逻辑离线比对）：

  | 输入 | 整改前拿到 | 整改后拿到 |
  |---|---|---|
  | `pins/upstream.json` 现状（`name` → `url` → `branch` → `commit`） | `d9e1c024…`（对） | `d9e1c024…`（对） |
  | 字段重排成 `branch` → `commit` → `name` | `6b7473b1…`（**下一条 claude-agent-acp 的 commit**，正是 finding 说的） | `d9e1c024…`（对） |

### 第 2 轮（全量复审）

- 范围：`main...HEAD`（`c1c3fbf` + 整改提交 `38b8578`，22 文件）；产物 `.claude/reviews/20260920-173603-review.out.md`
- findings：**1 条（high 0 / P2 0 / P3 1）**，采纳整改。三条整改本身逐条复核通过（`try/finally` 与 `$uninstaller` 的作用域、跳过分支的退出码语义、对象边界收口、`$sandboxes` 的引用可变）。

  | # | 级别 | finding | 整改 |
  |---|---|---|---|
  | 4 | P3 | 版本门把「sidecar 版本 == 应用版本」当成解耦被改回去：应用哪天正好升到 `1.21.0`（= zed 钉版本）时，第一道「sidecar == pins.zed.version」通过、第二道却报错，而 sidecar 又不能改成别的数 —— 两道门互相死锁（`validate.ps1` 与 `verify-package.ps1` 各一处） | 删掉这两处判定，只留「应用两处一致」与「sidecar == pins.zed.version」：后者成立时 sidecar 本来就不可能是跟着应用抬上来的，那一判是冗余的。`validate.ps1` 补注释写明为什么不再判 |

  改动只在两个开发脚本里（不进产物），所以按所有者 2026-09-20 的指示**没有重出安装包**；改完跑了 PowerShell 解析检查与 `validate.ps1 -Quick`（全绿）。

### 第 3 轮（只审整改 diff）

- 范围：`38b8578..HEAD`
- findings：<回填>

- 结论：<回填>

## 偏离

- **打包没有扩进 `scripts/build.ps1`，而是独立的 `scripts/package.ps1`**（ROUNDS.md R8 原文写的是「`scripts/build.ps1` 扩到打包」）。理由：`build.ps1` 现在 70 行、职责单一（一条 `flutter build` 加中文路径的 junction 兜底），打包要多出版本解析、staging、两次压缩、ISCC 调用与体积汇总，塞进去会让「构建」和「发包」两件事互相牵制；而且 `-SkipBuild` 是常用档（改了 iss 想重出安装器时不该重新 `flutter build`）。`package.ps1` 默认会先调 `build.ps1`，命令行入口仍是一条。
- **产物验收单独一个 `scripts/verify-package.ps1`**，不并进 `validate.ps1`：validate 是「改完代码跑一遍」的门（分钟级），而产物验收要先有 `dist/` 里的包，跑一次要解压 226 MB、静默装卸，档期不同。

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-08/BLOCKED.md`，停下呼人。禁止放宽验收标准自我通过。

## 本轮实测

### 1. 版本解耦：四次计时（2026-09-20，本机 `D:\cargo-target\AcpAgentClient-sidecar`，release）

| # | 改了什么 | `scripts/build-sidecar.ps1` 耗时 | 结论 |
|---|---|---|---|
| A | 什么都没改（基线） | **8.23 s**（cargo 判 fresh） | 重链不是每次都发生 |
| B | `Cargo.toml` 的 `version` 1.3.0 → 1.21.0，外加 `build.rs` / `main.rs` 各一处 | **14 m 16 s** | 这就是「发一次应用版本白烧一刻钟」的那一刻钟 |
| C | 只改 `Cargo.toml` 里的注释（内容变、解析结果不变） | **9.53 s**（fresh） | cargo 的 fingerprint 认 manifest 的解析结果，不认注释 —— 所以规则 11 拦的是 `version` 那一行，不是整个文件 |
| D | 抬应用版本 1.3.0 → 1.4.0（`pubspec.yaml` + `rust/Cargo.toml` + `rust/Cargo.lock` 七个条目） | **1.51 s**（fresh） | **解耦成立**：验收 1 的证据 |

B 与 D 的差就是本轮省下的：以后每发一个应用版本省约 14 分钟，代价是换 zed 钉版本时照样要这 14 分钟（那次本来就要重编整个依赖闭包，不额外多花）。

`--version` 的新输出（B 之后实测）：

```
zed-agent-acp 1.21.0 (zed @ d9e1c024f393832765a03f4de204d6c8cd9abcb2)
```

版本号 `1.21.0` 是 zed 钉版本（`vendor/upstream/zed/crates/zed/Cargo.toml`），commit 由 `build.rs` 从 `pins/upstream.json` 注入（`ZED_PINNED_COMMIT`）。

### 2. 打包产物（`scripts/package.ps1`，版本 1.4.0）

`flutter build windows --release` 115.2 s；payload（应用目录 + LICENSE + NOTICE + sidecar）260.6 MB。

| 产物 | 体积 | 说明 |
|---|---|---|
| `AcpAgentClient-1.4.0-windows-x64.zip` | **110.3 MB** | 免安装，含 sidecar |
| `AcpAgentClient-1.4.0-windows-x64-nosidecar.zip` | **46.7 MB** | 免安装，不含 sidecar（差值 63.6 MB 就是 176.6 MB 的 sidecar 压缩后的大小） |
| `AcpAgentClient-1.4.0-setup.exe` | **79.0 MB** | Inno Setup、per-user、未签名、`lzma2/max`（比 zip 的 deflate 小 31 MB） |

安装器界面语言只有英文：Inno Setup 6 自带的 `Languages\` 里没有简体中文（`ChineseSimplified.isl` 要另外下载，入库它等于再分发第三方文件）。应用自己的界面不受影响。

### 3. 产物验收（`scripts/verify-package.ps1`，2026-09-20，四条全 PASS）

每条都把 `%APPDATA%` 指到一个新建的空目录再起进程 —— 本机能做到的「干净机首启」等价物（所有者裁定「只做自动化」，真·干净 VM 不列待办）。

| 检查 | 结果 |
|---|---|
| zip 解压即用 | PASS。解压出的 exe 在空 `%APPDATA%` 上跑完无头往返（`ACP_SMOKE_REPORT`），数据目录与 `logs/acp-<日期>.log` 都是新建出来的；banner：`core   AcpAgentClient 1.4.0 (release, windows/x86_64) data=…\AcpAgentClient sidecar=…\zip\AcpAgentClient-1.4.0-windows-x64\zed-agent-acp.exe` —— **sidecar 是按「应用可执行文件旁边」找到的那份**（验收 6 的证据一并在这里） |
| 精简 zip | PASS（有主程序、没有 `zed-agent-acp.exe`） |
| 随包 sidecar 自己能跑 | PASS。`--version` → `zed-agent-acp 1.21.0 (zed @ d9e1c024f393832765a03f4de204d6c8cd9abcb2)`；`--selftest` → `selftest ok`。脚本给 selftest 传了 `--user-data-dir <临时目录>`（不给就会落到**本机 Zed 自己的**数据目录，规则 7），所以这一跑 `settings: (none) / models: 0` 是预期的 —— 它验的是「起得来」，不是「有模型」 |
| 安装器静默装 → 跑 → 静默卸 | PASS。`/VERYSILENT /NOICONS /DIR=<临时目录>` 装上、同样跑通无头往返（banner 里的 sidecar 指向安装目录那份）、`unins000.exe /VERYSILENT` 卸完目录清空；`%APPDATA%` 里的用户数据不在卸载范围内 |

第一次跑挂在两条断言上，都是脚本自己的问题、不是产物的问题：① 断言写了 `data/flutter_assets/AssetManifest.json`，而 Flutter 这个版本产出的是 `AssetManifest.bin`；② 第一条失败后 `$script:zipAppDir` 为空，第三条的 `Join-Path` 报「参数为 null」而不是说清原因。两处都已改（断言改成 `data/icudtl.dat` + `data/app.so` + `AssetManifest.bin`，第三条先判空再说话）。

**审查整改后重跑一遍（三件产物按新 sidecar 重出，体积不变）**：四条仍全 PASS，`--version` 与 banner 都与上面一致。这一跑把 sidecar 的 stderr 也打出来了，两条 ERROR 是 selftest 路径上的既有噪音、不影响退出码，**属于 R7 遗留、记 BACKLOG 不在本轮改**：

- `prompt_store … environment already open in this program`（同一进程里 lmdb 环境被开了两次）；
- `settings_store  Failed to write settings to file …\zed-agent-data\config\settings.json: 系统找不到指定的路径`（自带的 config 目录没建就写；模型与密钥本来就走 `--zed-settings` 只读那份，所以写不进去不影响功能）。

### 4. 跨轮次 / 环境

- **可选字体随包**：payload 里有 `fonts/`（R7.6 的 install 规则，本机 `assets/fonts/optional/` 里有文件），所以三件产物都带着它们。MiSans / HarmonyOS Sans 一类的协议是「可以嵌在应用里分发、不可以单独分发字体文件」，随包成立；`package.ps1` 末尾加了一行 NOTE 提醒发包的人别把 `fonts/` 单独发出去。
- **`scripts/build-sidecar.ps1 -Selftest` 不传 `--user-data-dir`**（R7 留下的）：那一档会写到**本机 Zed 自己的**数据目录，踩规则 7。本轮新脚本已经避开，但那一行没顺手改（CLAUDE.md：跨轮次问题记 BACKLOG，不当场顺手改）—— 收口时记进 `rounds/BACKLOG.md`。
- **同一工作副本上有并行会话**：本轮开工时建的 `round-08` 分支，16:42 被另一个会话（在整理 `rounds/BACKLOG.md`）切回了 `main`。为不互相踩，本轮的提交用 `GIT_INDEX_FILE` 临时索引做，只 `git add` 本轮自己的路径，不动共享的 HEAD 与索引。
