# Round 1.4.3 — v1.4.2 之后合入 main 的代码改动的复审与整改

<!-- 与 round-1.4.1 同类：发版前的单批次复审轮，登记在 ROUNDS.md § 7 进度表。 -->

> 状态：进行中（2026-09-23：主会话自主审查一遍 → 整改 → cursor 复审）

## 目标

把 `v1.4.2..main`（`901f36d..64a83d1`，38 个提交）里的**代码改动**独立审一遍、发现的缺陷修掉，再交 cursor 复审到 0 条，然后发 v1.4.3。
所有者指示（2026-09-23）：审查由**主会话**做（不委派子代理）；**文档改动不审、不改**（`*.md`、`design/`、`rounds/` 与 `iterations/` 里的登记）。

| 批 | 提交 | 内容 | 此前审查 |
|---|---|---|---|
| A | `5c759e3` | iteration-03 第 1 / 2 项：剪贴板张数门（20 张）、编辑带图消息只改文字的注释 | **未审查**（所有者指定） |
| B | `e3c0e25` | iteration-03 第 3 项：最大化窗口最小化再还原后四边溢出（`acp_window.cpp` 按提议矩形找显示器） | **未审查**（所有者指定） |
| C | `8ef163d`…`72066ac`、`c29ec88` | round-board-53：registry 检查与升级（核心 `registry_update` / 启动清扫 / `reloadPending`，前端四态） | cursor 3 轮，0 条收口 |
| D | `bad6182`、`4b4a3b0` | iteration-03 第 4 / 5 项：`+` → Files & Directories 改走 `@` 菜单；Ctrl+V 粘贴复制的文件与目录按路径引用 | cursor 3 轮 + 合 main 后全量 1 轮，0 条 |
| E | `abcf3d1`、`cd6e36f` | iteration-04：测试环境缺失判红、`_meta` 门整词、`MotionEnter`、`GuardedNotifier` 收编、gallery helper 收拢、`Hoverable` 收编 | cursor 1 轮，1 条（不采纳） |
| F | `98e96a5` | iteration-03 第 6 项：终端 ANSI 白 / 亮白取前景色 | cursor 1 轮，0 条 |

其余提交只动文档（BACKLOG 关闭、回填、DIVERGENCE），不在范围内。

## 验收

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | 主会话审查覆盖全部代码改动 | `git diff v1.4.2..main -- . ':(exclude)*.md' ':(exclude)design/**'`：62 个文件逐个读过（frb 生成物只核对与 `api.rs` 一致） |
| 2 | 每条 finding 有处理结论 | 采纳整改 / 不采纳写明理由，见下表 |
| 3 | 全量校验 | `powershell -File scripts/validate.ps1` 全绿 |
| 4 | cursor 复审归零 | `.claude/cursor-review.ps1`（前两轮 `-Scope since -Base v1.4.2` 全量，第 3 轮起只审整改 diff），直到 `findings: 0` |

## 代码审查

### 第 1 遍：主会话自主审查（2026-09-23）

结论：**没有 high / P2**；4 条 P3，采纳 1 条（最小改动），3 条不整改（理由见表）。

| 批 | 级别 | finding | 处理 |
|---|---|---|---|
| C | P3 | `install_npx` 在目标目录已存在（上一次失败没删干净，里面可能是一整份 `node_modules`）时用同步 `std::fs::remove_dir_all` 清空，跑在 runtime 的工作线程上；与 round-board-53 审查第 2 轮 P3（「删目录放阻塞线程」）同类，那一轮只改了升级失败清理与切换后清扫两处 | **采纳**：改 `tokio::fs::remove_dir_all(...).await`（`rust/registry/src/install.rs`，一行） |
| C | P3 | 启动清扫（`sweep_stale_installs`）逐个 agent 占住安装槽删旧版本目录；这段时间里点 Remove 会等满 `CANCEL_GRACE` 后报「安装还没退出（已发取消）」，点 Install / Update 报「正在安装」，文案对不上 | **不整改**：只在启动后几秒、且确有几百 MB 旧目录时出现，稍后重试即可；要区分「清扫」与「安装」得给安装槽加状态，属机制类改动（审查边界） |
| C | P3 | 应用没有单实例保护：第二个实例启动时的清扫只认安装记录的入口，会删掉第一个实例里「已升级 · 待重载」那条连接正在用的旧版本目录，或第一个实例在途升级的新目录 | **不整改**：整个应用（settings / 会话索引 / 安装槽）都假定单实例，这一条要跨进程锁，属机制类；所有者 2026-09-23 对 P1「进程与资源」的同类极限场景已裁定不修 |
| C | P3 | `refreshRegistry(network: true)` 两次并发（启动那次还在途时打开 Agents 标签）时，先失败的一方把 `fetching` 撤成 false，标题行的「检查中…」提前消失 | **不整改**：纯显示，在途那次回来后 `applyList` 按核心的 `fetching` 重置；核心侧 1 小时节流下几乎碰不到 |

其余核对过、判定无缺陷的要点（留作复审参考）：
- 升级的目录避让（`version_dir` 避开安装记录与运行中连接的入口）、切换时认证状态与 `session/new` 回写串行（`switch_to`）、失败只删本次新目录、切换后当前入口一律留到下次启动清——与 round-board-53 三轮审查的结论一致。
- `sweep_stale` 不跟符号链接 / 目录联接（`file_type().is_dir()` 对联接为假），入口不在 `agents/<id>/` 下时整个不扫。
- `Hoverable` 收编后 `AcpButton` / `ColumnSplitter` 的按下 / 拖拽态仍在各自 state 里，`GestureDetector` 在 builder 里重建时同类型同位置、识别器不丢；`MouseRegion.onExit` 在卸载时不触发，`onHoverChanged` 不会打到已 dispose 的对象。
- `GuardedNotifier` 收编：`FilesState` / `LocalTerminals` 的 `dispose` 先 `markDisposed()`；`AppearanceController` / `TranscriptFolds` 走 mixin 自带的 `dispose`。
- `acp_window.cpp`：`rect` 就是 `WM_NCCALCSIZE` 的 `rgrc[0]`（提议的新窗口矩形），`MONITOR_DEFAULTTONEAREST` 不会回 NULL。
- 剪贴板：张数门判在读字节之前、`continue` 不丢后面的路径；`{"bitmap": false}` 时 runner 不取位图。

## 版本号

发 v1.4.3（所有者 2026-09-23）：`pubspec.yaml` `1.4.3+1`、`rust/Cargo.toml` `[workspace.package]` `1.4.3`、`rust/Cargo.lock` 七个本地 crate；sidecar 不跟（规则 11，仍是 zed 钉版本 1.21.0）。

## 验证

- 工作树：`D:\variFlight_work\AcpAgentClient-release`，分支 `claude/review-1.4.3`（从 `main@64a83d1` 开出）；`vendor/upstream` 是指向主副本的目录联接。
- `powershell -File scripts/validate.ps1`（整改 + 版本号之后）：**VALIDATE OK**，16 道门全过；`cargo build / test / clippy -D warnings` 全绿，`flutter test` 461 项全过，`flutter analyze` 16 条 info 与基线同数。

## cursor 复审

执行器：cursor CLI `grok-4.7-high-fast`（未回落）。

### 第 1 轮（`-Scope since -Base v1.4.2`，全量，基于 `f427d66`）

`.claude/reviews/20260923-121508-review.out.md`：**1 条（high 0 / P2 1 / P3 0）**；任务卡里已定不整改的三条 P3 未再报。

| 级别 | finding | 核对 | 处理 |
|---|---|---|---|
| P2 | `composer_state.dart:291`：正文以裸 `@` 加换行结尾（`@\n`，Shift+Enter 之后）时，审查认为 `_activeToken` 的 `$` 会落在末尾换行之前、仍回 `@`，`addResourceLink` 删掉的是换行而不是 `@` | **前提不成立**：Dart 的 `RegExp` 按 ECMAScript，非 multiLine 的 `$` 只认输入末尾（那是 PCRE / Python 的语义）。同一个函数实测：`'@' → @`、`'@\n' → null`、`'看看 @\n' → null`、`'@\r\n' → null`、`'@ab\n' → null`、`'x\n@' → @`——以换行结尾时吃掉 `@` 那一步根本不触发，正文照旧 `@\n @名字 `。与 iteration-03 第 4 / 5 项审查第 3 轮那条不采纳的 finding 同一个说法 | **不采纳**；为免再被误报，在 `test/app/workbench_wiring_test.dart` 补一条用例锁住这个行为（`'@\n'` 粘贴后是 `'@\n @outside dir @shot.png '`），整个文件 34 项全过 |

无采纳整改；按所有者「findings 为 0 才收」的要求，带上核对结论再发第 2 轮全量。
