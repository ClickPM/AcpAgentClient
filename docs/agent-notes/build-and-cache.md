# 构建缓存与产物

> 相关：`AGENTS.md` 的「本地开发」段（`CARGO_TARGET_DIR` 的裁定与命令表）、[`release-pipeline.md`](release-pipeline.md)、
> [`git-and-parallel-sessions.md`](git-and-parallel-sessions.md)（并行会话与 worktree 的拆法）。

## 1. 共用 cargo target 会串代码（最容易把人骗过去的那个）

**现象**（2026-09-23 实测，round-board-53）：worktree 里给 `acp-core` 加了方法，`validate.ps1` 的 debug 构建全绿，但
`flutter build windows --release -t lib/main_headless.dart`（cargokit，target 在 `D:\cargo-target\AcpAgentClient\cargokit`）报
`no method named registry_update found for Arc<Core>` —— cargo **没重编 `acp-core`**，拿了别的副本 09:46 编的那份（我的源文件 09:44 最后改过，比它旧）。

**真因**：cargo 给 path 依赖算 `-C metadata` / 指纹时用的是**相对 workspace 根的路径**（`SourceId::stable_hash`），
所以所有副本的 `acp-core`（同版本号、同 profile / target）落在**同一个产物文件名**上；新鲜与否只比「产物 mtime vs 本副本源文件 mtime」。
谁最后编，其余副本就可能用它的代码 —— **方向是双向的**：我在共用目录编完，主副本下次 validate 也会静默用我分支的 `acp-core`。
`git checkout` / `merge` 会刷新被改文件的 mtime，所以按「拉代码 → 编」的节奏多半碰不上，**并行开发时**才出事。

**怎么办**：
- 改了 `rust/` 的分支 / worktree，validate 与构建都带独立目录：
  `validate.ps1 -CargoTargetDir D:\cargo-target\AcpAgentClient-<分支>`；`flutter build` 前设
  `CARGO_TARGET_DIR=D:/cargo-target/AcpAgentClient-<分支>`（cargokit 用 `$CARGO_TARGET_DIR/cargokit`）。代价是一次冷编依赖。
- 已经在共用目录编过了：收尾时
  `CARGO_TARGET_DIR=D:/cargo-target/AcpAgentClient cargo clean -p acp-core -p registry -p acp_bridge -p acp-smoke`
  （用环境变量；`--target-dir` 参数会因缺 `CACHEDIR.TAG` 被拒）。只清 dev profile。清之前先 `Get-Process cargo,rustc` 看有没有别的会话在编。
- **看到「源码里明明有、编译说没有」先怀疑这个**，别去改代码。
- **带独立 target 的 worktree 合并后，那个 target 目录要和工作树一起删** —— 它们不在 `git worktree` 的账上，只能靠人记
  （2026-09-23 是 `du` 盘点 `D:\cargo-target\*` 才发现的，一次找出 4 个、共 78 GB）。

## 2. 缓存在哪、占多少（`（本机）`）

缓存**不在仓库里**，按 `AGENTS.md` 固定到 `D:\cargo-target\`，几个工作副本（主副本、`AcpAgentClient-release`、各轮 worktree）
**共用同一个 `CARGO_TARGET_DIR`**，所以它只涨不落。

| 路径 | 量级（当时） | 处置 |
|---|---|---|
| `D:\cargo-target\AcpAgentClient\debug` | 常态 10.7–11.8 GB（紧张时 28–74 GB） | 剪枝的主要对象，见下节 |
| `D:\cargo-target\AcpAgentClient\cargokit` | 1.0–1.5 GB | `flutter build` 里 Rust cdylib 的 release target（不在 `debug` 下，**别漏**） |
| `D:\cargo-target\AcpAgentClient-sidecar\release` | 12.4–13.5 GB | **留着**：删了下次 sidecar 冷编约 50 分钟 |
| 各 worktree 的 `build\` + `.dart_tool` | 合计约 2.4 GB | 合并后随 worktree 一起删（单个 Flutter release 产物 0.6–0.78 GB） |
| 主副本 `build\sidecar\zed-agent-acp.exe` | 185 MB | 留着，出包时要用 |
| `dist\` | 每次发版三件产物 | 发完版删上一版的 |
| `flutter_build` 里旧配置目录 | 各约 62 MB | 只留在用的那一版 |
| `vendor\upstream` | 0.26 GB | **不是缓存**（钉版本源码，`fetch-upstream.ps1` 可重建，但删了每个 worktree 都要重填、`-Check` 会红） |

全局的 `.cargo\registry`（约 1.9 GB）/ `.cargo\git`（约 0.7 GB）/ Pub Cache（约 0.6 GB）跨项目共用，**不在这个项目的清理范围里**。

## 3. 怎么剪 `debug`（三版才做对，按最后一版做）

**❌ 别整段删 `debug\deps`**（2026-09-22 实测）：cargo 不会重写「没变的依赖」的 rlib，所以 `deps` 里
**按 mtime 看起来陈旧的恰恰是仍在用的依赖闭包**，按时间戳一刀切等于把依赖全删、下次冷编。

**❌ 「同 crate 变体里留最新那份 ±1 小时」也不安全**（2026-09-23 实测）：同一个 crate 的在用变体可以来自不同时间的构建
（例：`libsyn` 最新一份是别的 worktree 17:59 编的另一特性集，当前 main 在用的是 16:40 那两份），按「组内最新 ±1h」会把在用的删掉、触发重编。

**✅ 改用 cargo 自报的在用清单**（脚本已入库 `rounds/round-1.4.4/prune-cargo-debug.ps1`，`-DryRun` 只报数）：
1. 在每个要保留的工作副本（都在发版提交上）的 `rust\` 下，按 validate 的原样跑三条，都加 `--message-format=json`：
   `cargo build --workspace --locked`、`cargo test --workspace --locked --no-run`、
   `cargo clippy --workspace --all-targets --locked -- -D warnings`。
   fresh 的单元不重编，但 `compiler-artifact` 消息照样列出每个单元的 `filenames`。
   ⚠️ `--message-format=json` 必须放在 clippy 的 `--` **之前**；`build-script-executed` 的 `out_dir` 里的 hash 也要收进集合。
2. 取文件名里 16 位 hex 的并集 = **在用集合**（当时 398–454 个）。
3. `debug\deps` 里 hash 不在集合里的才删；`debug\build` 同理；`debug\incremental` **整段删**。
4. 删完再跑一遍同样三条，要求**全部 fresh、陈旧 0 个**。主副本与 worktree 的 hash 相同，所以只剩一个副本时算一次就够。

实测回收（同一脚本，只换版本号）：2026-09-23 29.44 → **11.76 GB**；2026-09-23 下午 28.66 → **10.76 GB**；
2026-09-24 28.25 → **10.66 GB**；2026-09-24 下午 28.13 → **10.66 GB**。清完 `debug` 仍有约 10.5 GB，那是活着的依赖闭包，下次 validate 不冷编。

**还可以顺手清的一项**（2026-09-24 实测）：`cargokit` 里**本地 crate 的历代变体** ——
`x86_64-pc-windows-msvc\release\deps` 与 `.fingerprint` 里 `acp_core` / `acp_bridge` / `fs` / `pty` / `registry` / `settings`
每个攒了约 10 份（**每次改版本号都换 hash**，外部依赖不换），只留刚出包那次（`acp_bridge.dll` 同一分钟）的 hash、其余删掉，约 0.27 GB；外部依赖不动。

## 4. 怎么删（工具与坑）

- **PowerShell 工具是 pwsh 7**，`[System.IO.Directory]::Delete($p, $true)` / `[System.IO.File]::Delete($f)`
  既不触发命令文本拦截、也没有 MAX_PATH 问题，异常还能直接 catch —— 比 `cmd /c rd /s /q "\\?\<路径>"` 那套清楚（后者退出码不可信，成败看事后 `Test-Path`）。
  两个坑：① 目录被别的进程按着时报 "being used by another process"（残留的 `claude.exe` 会把 worktree 当 cwd）；
  ② 遇到只读文件报 "Access to the path ... is denied" 就整个中断 —— 先
  `Get-ChildItem -Recurse -File -Force | ForEach-Object { $_.IsReadOnly = $false }` 再删。
  cargo target 里的只读文件来自测试夹具建的小 git 仓（`.git/objects/**` 天生只读）。
- 清单写进一个 **ASCII-only 的 `.ps1`** 再 `powershell -File` 跑（纯 ASCII 就不用管 BOM）；
  批量删除类脚本要 `$ErrorActionPreference = "Continue"`，失败项自己收集成 stuck 列表（见 [`harness-pitfalls.md`](harness-pitfalls.md)）。
- **删之前查有没有在编**：`Get-Process cargo,rustc,dart,link,cl,msbuild`。
  别只按进程名判断 app 是否开着 —— `Get-CimInstance Win32_Process` 看 `ExecutablePath`，
  别的会话常从自己的 worktree 跑同名 exe（见 [`release-pipeline.md`](release-pipeline.md)）。
- **`du -sm` 在 Git Bash 下报的是压缩 / 稀疏后的数，比 .NET 量出的 Length 小三成**；要准确数就用 .NET 遍历。

**How to apply:** 再被问「清缓存」就照上表报数、**先问范围再删**；默认建议「`debug` + `cargokit` 剪枝、sidecar 留着」。
清完下次 validate 会冷编一次 debug（含依赖），下次 `build.ps1` 会重编一次 release cdylib。

## 5. 需要「main 的行为基线」二进制时

R7.5 合 main 时要用 main 的 release 构建重出三份 fake-agent 无头基线，临时 worktree 里 `flutter build windows` 失败过一次（原因没查到）。
所有者出发布版时会在 `D:\variFlight_work\AcpAgentClient-release`（分支 `release-build`）上构建，**那份 `build\windows\x64\runner\Release\` 就是 main 的干净构建**。

- **出处可核**：`git -C <release-wt> status --porcelain` 为空、HEAD 与 main 同一提交、`data\app.so` 与 `acp_bridge.dll` 的时间晚于该提交。
- **整个 `Release\` 复制到私有目录再跑**（如 `D:\cargo-target\AcpAgentClient\r75\main-bin`），别直接跑所有者那份 —— 无头脚本会 `taskkill` 同目录下的实例。
- **删掉旁边的 `zed-agent-acp.exe`**：核心（`rust/acp-core/src/builtin.rs`）见到它会多并一条内置 agent 条目，
  `installedAgents` 就和没带 sidecar 的分支构建对不上。`fonts/` 留着无害（无头路径不碰外观）。
- 基线脚本与比对：`rounds/round-7.5/baseline/run-report.ps1 -Exe <私有副本>` + `compare.py`。
- **r3 报告已知的偶发**（都是取样时序，同一二进制重跑就等价 —— **先重跑再怀疑代码**）：
  `branches.error` 撞 git 自己的 `index.lock`；`newSession.commands` 取样早于 `available_commands_update`；
  后台终端 `^C` 回显字节；`files.error` 是 Follow 开着时 `tool_call` 的 `locations` 先于 agent 的 `fs/write_text_file` 到达、
  文件面板先去开还没写出来的文件 —— `FilesState._guard` 记的错不会被之后的成功清掉，竞态哪边赢就报哪个（16 次里 15 次「错误在」）。

## 6. pub 缓存走镜像（`（本机）`）

Flutter pub 缓存目录是 `C:\Users\Click\AppData\Local\Pub\Cache\hosted\pub.flutter-io.cn\`（镜像），**`hosted\pub.dev\` 不存在**；
`PUB_CACHE` 环境变量未设。`flutter pub get` 会提示 "Flutter assets will be downloaded from https://storage.flutter-io.cn"。

要查第三方包（xterm / flutter_svg / mermaid_flutter …）的源码：
`ls "$LOCALAPPDATA/Pub/Cache/hosted/pub.flutter-io.cn/"`（Git Bash 用 `/c/Users/Click/AppData/Local/Pub/Cache/hosted/pub.flutter-io.cn/`），
或读 `.dart_tool/package_config.json` 里的 `rootUri`。**别按 `pub.dev` 路径找，那里是空的。**

## 7. `dart fix --apply` 会动到本来就有的 lint

大批量改动（比如把 `const` 收敛掉）之后想用 `dart fix --apply --code=prefer_const_constructors …` 把还能 `const` 的收回来时，
**它不区分「这一轮弄出来的」和「本来就有的」**：一次跑下来会顺手把 `agent_boards.dart` / `transcript_boards_2.dart` /
`appearance_card.dart` 这些本轮根本没碰的文件里早就存在的 `prefer_const_declarations`、`prefer_const_constructors` 也改掉
（2026-09-20 实测 15 处 / 7 文件，其中 3 个与本轮无关）。

**为什么要在意**：这类无关改动混进 diff，独立审查会花时间问「这几处为什么动」，也让整改 diff 的范围口径
（`AGENTS.md`：第 3 轮起只审 `<上一轮已审提交>..HEAD`）不再干净。

**怎么办**：跑完 `dart fix` 立刻 `git diff` 过一遍，本轮没碰过的文件整份 `git checkout --` 回去，同一文件里无关的那几行手工撤。
判据是「这一行的 lint 是不是我这轮制造的」—— 不是就撤。`flutter analyze --no-fatal-infos` 剩下的 info 里，
`test/` 与未碰文件的那些本来就在，不必清零。
