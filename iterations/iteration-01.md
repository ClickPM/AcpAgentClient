# Iteration 01 — 流程与副产物梳理、文档对齐；BACKLOG 收尾候选圈定

<!-- 一个迭代一个文件、一项一行；流程正本见 iterations/README.md。 -->

> 状态：进行中　起止：2026-09-22 –　基线：`main` = `689fab5`，2026-09-22 合入 `main@2650a2f`（v1.4.1）

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | tidy | 建立敏捷迭代流程（`iterations/` 正本 + 模板 + 本文件），与轮次并列；CLAUDE.md「开发模式」改成两条流程的摘要，ROUNDS.md § 7「main 直改」行封存 | 所有者 2026-09-22 | `claude/agile-process-project-cleanup-7d1d7a` → 待合并 | validate -Quick | 待所有者指定 | 待合并 |
| 2 | tidy | 副产物梳理：`scripts/README.md`、`test/README.md` 两份索引；`rounds/README.md` 补与迭代的关系与允许的子目录；`design/README.md` 补画板修订简报（`input/revision-NN.md`）的约定 | 同上 | 同上 | 同上 | 同上 | 待合并 |
| 3 | tidy | 文档与源码对齐（清单见「备注」）：`docs/design.md` § 1 / § 3 / § 9 / § 10、`docs/background.md` 时间线、`docs/review-workflow.md`、README、AGENTS.md 与审查任务书的白名单口径、`test/fixtures/README.md` 的失效路径、五张任务卡的过期状态行、BACKLOG 三条已消解的条目 | 同上 | 同上 | 同上 | 同上 | 待合并 |
| 4 | tidy | 合入 `main@2650a2f`（v1.4.1 复审轮），解 README 冲突并按 v1.4.1 的内容更新文档（详见「备注 · 合并 main」） | main 前进 | 同上 | validate -Quick | 同上 | 待合并 |
| 5 | fix | 风扇狂转：① 文件树 git 徽章自激空转——`git status` 自己建删 `.git/index.lock`（Windows 还连带一条 `.git` 目录的 Modified），watcher 把它当 `.git` 变化上报，前端据此再跑 `git status`，仓库零改动时每秒起 2–6 个 `git.exe`；② `Spinner` 与侧栏扫掠线两处常驻动画没有 `RepaintBoundary`，会话运行中整窗每帧重栅格（2880×1800 @ 120Hz 核显实测 GPU 44–64%）。修：`rust/fs/src/watch.rs` 的 `classify` 跳过 `.git` 之下目录身上与 `*.lock` 的事件（两条新测试，其一用真 git 带子模块复现）；两处动画包 `RepaintBoundary`。实测见「备注 · 风扇狂转」 | 所有者报障 2026-09-22 | `fix-fs-watch-loop`（worktree `AcpAgentClient-fswatch`）→ 待合并 | validate 全绿（2026-09-22）；未构建 | 待审查 | 待审查 |

## 候选清单（待所有者圈定进本迭代或下一个）

按 `rounds/BACKLOG.md` 2026-09-22 的未关闭条目粗分三档；条目原文与细节仍以 BACKLOG 为准，这里只给「能不能直接开工」的判断。**圈定后把选中的搬进上表**，未选中的留在这里或删掉。已按合入的 `main@2650a2f`（v1.4.1）复核过一遍：1.4.1 收掉的条目已从本清单移除，它新记的两条已并入。

**A. 可直接开工**（`fix` / `tidy`：最小修复已写在 BACKLOG，不需裁定、不需设计稿）

1. `ShellState.closeTab` 关掉最后一个面板标签会把整栏收起（R4 第 4 轮 P2）——`openTabs` 空而终端非空时把 `activeTerminalId` 设成最后一个终端。
2. `rust/fs/src/lib.rs` 的 R3 用例 `junctions_are_not_followed_out_of_the_workspace` 建不出链接就 `return`，改成红（R4）。
3. `ComposerState._updateMentionMenu` await 之后无条件写回（P3）——加「光标处的 token 还是原来那个才写回」。
4. `ComposerState.addImage` 没有大小门（P3）——复用 `clipboardImageSizeLimit` 判一次并记 `composer.lastError`。
5. `lib/ui/shell/motion.dart` `didUpdateWidget` 只比 `epoch`（P3）——同步 `duration` / `delay`。
6. `workbench_screen._body()` 两支 widget 类型不同导致首条消息整树重建（P3）——两支都包 `MotionEnter`。
7. `scripts/validate.ps1` 的 `_meta` 门按子串扫、`symlink_metadata` 连坐（2026-09-22）——模式收成 `"_meta"` 或加词边界。
8. R5 npx 安装在提交点之前失败留半个 `agents/<id>/`——收尾里对未提交失败也调 `install::remove`。
9. R7.5 `GuardedNotifier` 未收编 `FilesState` / `LocalTerminals` / `AppearanceController`——统一混入。
10. R0 cargokit 只认 `rustup run stable`、与 `rust-toolchain.toml` 可能漂移——取「接受漂移、validate 里比对两者版本」那一支。
11. R7 sidecar 的 release channel 落成 `dev`——`build.rs` 显式设 channel（只影响 `db/` 目录名）。
12. 认证用的可见终端在认证收尾处没有释放（1.4.1 复审 P3 的另一半；`Sessions.forget` 已收掉本会话名下那几个）——在 `lib/app/auth_state.dart` 的收尾里 `terminals.remove` 掉它。
13. 载回来的会话在下一轮后丢标题。**已按合并后的代码核实仍未修**：`SessionIndex.upsert` 写的是 `s.title ?? titleFallback`，而 `titleFallback` 是会话头的占位串 `New <agent> Session`，载回来的会话 `store.title` 为 null 时就把索引里原来有意义的标题盖掉。最小修复是再退一层到索引里已有的那一行的标题。
14. 收轮那次 `saveIndex()` 写的是**当前选中**会话而非刚跑完那一轮的。**已核实仍未修**：`saveIndex()` 取的是 `store`，`turn_controller` 收轮时无参调用它；后台会话跑完时刷的是前台那条的计数。最小修复是给 `saveIndex` 收一个 `SessionStore` 参数。
15. `session/list` 校对按 cwd **原串**比，侧栏过滤按归一后比。**已核实仍未修**：`reconcileSessions` 里是 `entry['cwd'] != scope` 直接比串，而 `WorkspaceState.normalizeCwd` 已存在并被在跑数分组与 `inScope` 用着。最小修复是这一处也走 `normalizeCwd`。

**B. 需所有者裁定**（机制类修复或产品取舍，按审查边界不能在迭代里顺手做）

- `settings.json` 各段写入没有串行化（board-08 P2；R7.6「并发落盘后发先至」是同一条）——在 `SettingsStore` 上串行化 load + save。
- 剪贴板读取整段跑在**平台线程**上（1.4.1 复审 P3）——8K 整屏位图约一百多毫秒整窗冻结；挪出平台线程属机制类改动。
- 剪贴板文件列表没有张数上限——数值是产品取舍。
- `logs/acp-<日期>.log` 按 UTC——引 `chrono` 或自写时区读取。
- `session/load` 重放到一半断了留半份转录——`resetForReplay` 加快照与回滚。
- 两层临时表面一次 Esc 一起关——表面栈。
- agent 换代后内存里其它会话拿的是旧 sessionId——连接代次。
- 认证页成功后自动重试用的是发起时的 cwd——按当前 `workspace.project` 判一次。
- 内置 dsh 条目回落 `npx` 时只认进程 PATH——让内置条目也走 `NodeRuntime`。
- `fs` 的 symlink TOCTOU 残余——引 `cap-std`（规则 1 之外）或维持现状。
- 桥的四层手写转发塌成一处（quality 第 6 项）；`appearance_prefs` 的 data-class 样板（第 7 项）。
- 依赖环境的测试跳过仍算绿——统一成红或引 ignore 标记。

**C. 需先改设计稿**（BACKLOG「设计稿补注记」与「先改设计稿」的条目，攒成一个设计轮走轮次流程）

- 补注记（实现先行）：画板 00 tooltip 一组 token；01 空态画各 agent logo；01–03 / 40 附件芯片条与预览；05 B 组触发补新建会话；25 去快捷键标签 + 范围下拉浮层；31「一轮没走到结束值」失败态；40 会话配置固定档序平铺；40 / 41 / 42 弹层封顶滚动；70「外观」小节（字体四轴 + 主题行）；07 的 `SvgTint.mark` 与切换按钮；08 的 `$preview` 收紧；`Thread → Session` 文案（00 / 01 / 02 / 03 / 06 / 31 / 40 / 50 / 60 / 61）；01–04 / 40 悬停提示样张；04 删除图标一律显示。
- 扩边界（要新画）：深色页面画板 90 / 91 / 92；壳级错误提示位（`lastError` 出口）；侧栏后台会话挂起请求的徽章 / 停靠条跨会话；项目切换器上「被放下的会话正挂着请求」的徽章；registry 无 sha256 时 `verify_note` 的出口；画板 80 的返回入口；会话菜单（Resume / Close）的入口（41 / 03）；窗口最小尺寸或窄窗折叠；弹层「上方放不下翻到下方」；终端组字串浮层；第三条「等 agent」路径（侧栏点未载入会话）的等待态；「关于 / 致谢」界面；主题「跟随系统」档；设置页字号；registry 型 agent 的升级态；输入框内的 `@` / `/` 芯片。
- 改字：画板 27 占位文案；33 `status: error` → `failed`；34 initialized 行；51 「写入 agents.json」→ `settings.json`；51 / 52 codex 专属样例改通用；50 / 51 未安装行对齐；70 registry 行的「编辑」→「查看」；31 `max_turn_requests` 的「18 次请求」；40 模型行的 provider 图标与 `Latest` 徽章；41 分支弹层的搜索语义；15 Mermaid 布局。

## 收口

- 构建 / 手测：纯文档与流程改动，未构建（本迭代第 1–3 项）；候选项圈定后按各项验证。
- 发版：不发。
- 移出项去向：—
- 设计稿补注记：本迭代无实现先行项。

## 备注

**第 3 项「文档与源码对齐」的逐条清单**（2026-09-22，全部按源码现状核对后改的）：

- `docs/design.md` § 1：`rust/settings` 一行补 `appearance` / `transcript` 段与索引文件；「十来个命令 + 5 个事件流」补成实际的 57 个命令 + 6 条事件流（`rust/bridge/src/api.rs`）。§ 3：命令清单补 `appearance_get/set`、`transcript_prefs_get/set`（画板 07 / 08 加的两对偏好命令）与开发期的 `ping` / `dropped_event_count`。§ 9：「投影层约五百行」补实际约 4,100 行。§ 10：数据目录补 `fonts/`；`appearance` 段补 `theme`；新增 `transcript` 段一段。
- `docs/background.md` 时间线：「R8 打包与发布未开始」是 2026-09-17 的措辞，补 2026-09-20（R7.5 / R8 / v1.0.0–v1.4.0）与 2026-09-22（1.4.1 复审轮与 v1.4.1、进入迭代阶段）两条。
- `docs/review-workflow.md`：「硬性规则 1–10」→ 1–11；补迭代流程的审查档位。
- `README.md`：文档表补 `iterations/README.md`、`scripts/README.md`、`test/README.md`；审查器型号 4.6 → 4.7；「状态」补 2026-09-22 一行。
- `AGENTS.md` 与 `.claude/cursor-review-prompt.md`：通用库允许清单还是 R1.5 裁定之前的版本（缺 `base64` / `flutter_svg` 与六个渲染库，且仍写着「Markdown 渲染库进清单之前判 P2」）→ 对齐 CLAUDE.md 规则 1 当前文本；AGENTS.md 补迭代范围口径。
- `rounds/README.md` / `rounds/TEMPLATE.md`：审查器型号 4.6 → 4.7。
- `ROUNDS.md`：头注里「R7.5 裁定门待所有者拍板」「缺陷轮拟叫 R7.7」已过期；§ 2 尾段 `clipboard_image.dart` 仍写「借 `powershell.exe` 读」（quality 轮起是 runner 走 Win32），`lib/gallery/`「debug 构建才编入」实为不进产品入口、由 `test/gallery_test.dart` 出图。
- `test/fixtures/README.md`：引用的 `lib/gallery/scenarios.dart` 不存在，画板 34 的 `acp/agent_state` 场景在 `lib/gallery/boards/transcript_boards*.dart`。
- 任务卡状态行：`round-00`「待合并 main」、`round-04`「进行中」、`round-7.5`「等所有者三件事 … 不合并」、`round-7.6`「待推 main」、`round-design`「尚未提交；ROUNDS.md 尚未建立」——全部与 ROUNDS.md § 7 对齐成已合并的口径，保留仍待所有者的手测项。
- `rounds/BACKLOG.md`：关闭三条已消解的——`FilesState.setProject` 的 A→B→A 竞态（2026-09-22 切项目假死那批加了 `_projectEpoch` 守卫，`lib/app/files_state.dart`）、「截图验收 Zed Agent 20 项」（2026-09-14 已做完 22 项，`prototype/README.md`）、`prototype/assets/fixtures.js` 缺 `message`（裁定原型不维护、`test/fixtures/` 已补）。
- **没动的**：`docs/research.md`（研究沉淀，按钉版本口径写，仍成立）、`docs/requirements.md`、`docs/acp-projection.md`（契约底稿，与 `wire.dart` 一致）、`design/round-design/materials.md`（设计轮的历史底稿，「7 项自造态」是当时口径，不回改）、`prototype/`（README 已声明不维护）。

**合并 main（第 4 项，2026-09-22）**

- 范围：`main` 从 `689fab5` 前进到 `2650a2f`，五个提交，即 1.4.1 复审轮与 v1.4.1 的版本号。合并方式是把 `main` 合进本分支（所有者指示），非快进。
- 重叠三个文件，两个自动合并干净：`ROUNDS.md`（他们在 § 7 末尾加 1.4.1 复审行，我们改的是头注与「main 直改」行的封存句，不同区段）、`rounds/BACKLOG.md`（他们关闭「回合折叠滚动锚点」并新增两条，我们加表头两行并关闭三条，不同区段）。合并后逐项核过两边的意图都在。
- **`README.md` 冲突**，原因是结构性的：`main` 把 v1.4.1 的发布行追加进旧 README 的「状态」清单，而本分支的重写版把那份逐版本清单整段换成了指向 GitHub Releases 的紧凑段。按新结构解——版本号抬到 v1.4.1，v1.4.1 的实质压成一段（六批复审、两条 high、cursor 两轮归零、指向任务卡），逐版本历史仍由 Releases 承担，不把那份清单搬回来。
- 按 v1.4.1 的内容更新的文档：`docs/background.md` 时间线的 2026-09-22 一条补上复审轮与 v1.4.1；`iterations/README.md` 开头的「v1.4.0 发布之后」改成 v1.4.1，§ 5 补一段说明 `round-1.4.1` 为何仍按轮次走完（本流程建立之前已立项，不回改编号；封存的是 § 7「main 直改」行，轮次自己的行照旧）。
- 候选清单按 1.4.1 复核：移除已被它收掉的「回合折叠的滚动锚点离开已建窗口不校正」；并入它新记的两条（认证终端释放 → A 档，剪贴板读取在平台线程 → 需裁定档）；原「待核对是否已被 main 直改修掉」那一档的三项**逐项查过合并后的代码，确认全部仍未修**，各自最小修复已写明并升进 A 档，该档撤掉。
- 核过但未受影响：`docs/` 里没有出现 `withdrawn` / 墓碑 / 索引删除顺序这类被 1.4.1 改动的实现细节，所以第 3 项对齐过的文档陈述无一条被推翻；`docs/design.md` § 10 关于 `transcript` 段默认值的写法与 1.4.1 修掉的「读盘排在 `core_init` 之前」是两回事（那是接线缺陷，不是契约），保持原样。

**风扇狂转（第 5 项）的实测（2026-09-22，Windows 11，规则 9）**

- 现象：安装版 `D:\tools\AcpAgentClient\acp_agent_client.exe`（PID 37236，打开的项目 `D:\variFlight_work\VariFlightWork`，61001 个文件）GPU 3D 引擎 44–64%（另一会话先测到 64%；本会话 `Get-Counter '\GPU Engine(*)\Utilization Percentage'` 抓到一次 44%，其余采样 1.2–1.8%），CPU 不高。不是 WebView（这个应用没有 WebView）。
- 闭环证据：① `Get-CimInstance Win32_Process -Filter "ParentProcessId=37236 AND Name='git.exe'"` 轮询：12 秒 24 个、20 秒 54 个、15 秒 96 个 `git.exe`，命令构成 `rev-parse --is-inside-work-tree` / `rev-parse --show-toplevel` / `status --porcelain` 三者数量相当（= `git_status` 的三个子进程，`refreshBadges` 在空转，不是 `git_branches`）；② 同期仓库工作区**零文件改动**（`Get-ChildItem -Recurse` 前后快照，8 秒与 10 分钟两档均为 0）；③ `System.IO.FileSystemWatcher` 挂在 `.git` 上 8 秒抓 46 条事件，**全部**是 `index.lock` 的 Created / Deleted；④ 25ms 高频探测 400 次采样有 5 次抓到 `index.lock` 存在、`.git/index` 的 mtime 0 次变化（前后快照法查不出锁文件，所以最初漏判）；`core.fsmonitor` / `core.untrackedCache` 均未设（`.git/fsmonitor--daemon` 目录是残留）。
- 单测揭示的第二条路径：合成建删 `index.lock` 的测试在只滤 `*.lock` 时仍 `git: true`——Windows 的 ReadDirectoryChangesW 在目录里建删文件时会给 **`.git` 目录本身**报一条 Modified（③ 挂在 `.git` 上看不到它自己的事件，所以没抓到）；生产环境同样如此，光滤锁文件循环照样闭合。`classify` 两条都跳过；`.git/HEAD` 写入与 `index.lock → index` 的改名仍打标志（测试断言）。
- 审查第 1 轮（cursor `grok-4.7-high-fast`，`022079b..d3774c6`）1 条 high，采纳：有子模块时 `git status` 递归进子仓库、在 `.git/modules/<name>/` 建删锁，Windows 给**那个目录**报的 Modified 最后一段是子模块名不是 `.git`，「只认目录自身等于 `.git`」盖不住，循环重新闭合。整改按它给的最小修复：`.git` 之下凡是**目录**身上的事件都跳过——`fold` 现查 `path.is_dir()` 传给 `classify`（纯函数仍可拿假路径单测；已删掉的目录查不到会当文件打一次标志，多刷一回徽章无妨）。合成测试加 `.git/modules/sub/` 的锁；真 git 测试真的加一个本地子模块（`-c protocol.file.allow=always submodule add`），racy 等待挪到子模块检出之后。
- 真 git 测试的 racy 坑：刚写的文件与索引落在同一秒时 git 每次 `status` 都补写索引（真变化，照常打标志）直到时钟跨秒，测试三跑两挂；让文件比索引老 1.1 秒后连跑五轮稳定。
- GPU 一侧：`lib/` 里 `RepaintBoundary` 出现 0 次（全仓 6 处都在 `test/`）；显示器 2880×1800 @ 120Hz、Radeon 780M 核显。机制成立，但爆发当下没抓到对应的 UI 状态，效果要构建后手测（会话运行中看 GPU 引擎占用）。
- 立刻止血的办法：把项目从那个 6 万文件的仓库切走或关掉应用；git 风暴与会话是否在跑无关。
