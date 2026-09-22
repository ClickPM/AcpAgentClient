# Iteration 01 — 流程与副产物梳理、文档对齐；BACKLOG 收尾候选圈定

<!-- 一个迭代一个文件、一项一行；流程正本见 iterations/README.md。 -->

> 状态：进行中　起止：2026-09-22 –　基线：`main` = `689fab5`

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | tidy | 建立敏捷迭代流程（`iterations/` 正本 + 模板 + 本文件），与轮次并列；CLAUDE.md「开发模式」改成两条流程的摘要，ROUNDS.md § 7「main 直改」行封存 | 所有者 2026-09-22 | `claude/agile-process-project-cleanup-7d1d7a` → 待合并 | validate -Quick | 待所有者指定 | 待合并 |
| 2 | tidy | 副产物梳理：`scripts/README.md`、`test/README.md` 两份索引；`rounds/README.md` 补与迭代的关系与允许的子目录；`design/README.md` 补画板修订简报（`input/revision-NN.md`）的约定 | 同上 | 同上 | 同上 | 同上 | 待合并 |
| 3 | tidy | 文档与源码对齐（清单见「备注」）：`docs/design.md` § 1 / § 3 / § 9 / § 10、`docs/background.md` 时间线、`docs/review-workflow.md`、README、AGENTS.md 与审查任务书的白名单口径、`test/fixtures/README.md` 的失效路径、五张任务卡的过期状态行、BACKLOG 三条已消解的条目 | 同上 | 同上 | 同上 | 同上 | 待合并 |

## 候选清单（待所有者圈定进本迭代或下一个）

按 `rounds/BACKLOG.md` 2026-09-22 的未关闭条目粗分四档；条目原文与细节仍以 BACKLOG 为准，这里只给「能不能直接开工」的判断。**圈定后把选中的搬进上表**，未选中的留在这里或删掉。

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

**B. 待核对是否已被 2026-09-18 / 09-22 的 main 直改顺手修掉**（核对后关闭，或转 A）

- 载回来的会话在下一轮后丢标题（`SessionIndex.upsert` 应退回索引里已有的标题）——`docs/design.md` § 3 已写「收轮、改名、补标题都沿用索引里已有的值」，看代码是否真落了。
- 收轮那次 `saveIndex()` 写的是当前选中会话而非刚跑完的（`turn._runTurn` → `session.saveIndex()`）。
- `session/list` 校对按 cwd 原串比、侧栏按归一后比（`reconcileSessions` + `normalizeCwd`）。

**C. 需所有者裁定**（机制类修复或产品取舍，按审查边界不能在迭代里顺手做）

- `settings.json` 各段写入没有串行化（board-08 P2；R7.6「并发落盘后发先至」是同一条）——在 `SettingsStore` 上串行化 load + save。
- 剪贴板文件列表没有张数上限——数值是产品取舍。
- `logs/acp-<日期>.log` 按 UTC——引 `chrono` 或自写时区读取。
- `session/load` 重放到一半断了留半份转录——`resetForReplay` 加快照与回滚。
- 两层临时表面一次 Esc 一起关——表面栈。
- agent 换代后内存里其它会话拿的是旧 sessionId——连接代次。
- 认证页成功后自动重试用的是发起时的 cwd——按当前 `workspace.project` 判一次。
- 内置 dsh 条目回落 `npx` 时只认进程 PATH——让内置条目也走 `NodeRuntime`。
- 回合折叠的滚动锚点离开已建窗口那一次不校正——像 `TranscriptJump` 那样一屏一屏找回。
- `fs` 的 symlink TOCTOU 残余——引 `cap-std`（规则 1 之外）或维持现状。
- 桥的四层手写转发塌成一处（quality 第 6 项）；`appearance_prefs` 的 data-class 样板（第 7 项）。
- 依赖环境的测试跳过仍算绿——统一成红或引 ignore 标记。

**D. 需先改设计稿**（BACKLOG「设计稿补注记」与「先改设计稿」的条目，攒成一个设计轮走轮次流程）

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
- `docs/background.md` 时间线：「R8 打包与发布未开始」是 2026-09-17 的措辞，补 2026-09-20（R7.5 / R8 / v1.0.0–v1.4.0）与 2026-09-22（进入迭代阶段）两条。
- `docs/review-workflow.md`：「硬性规则 1–10」→ 1–11；补迭代流程的审查档位。
- `README.md`：文档表补 `iterations/README.md`、`scripts/README.md`、`test/README.md`；审查器型号 4.6 → 4.7；「状态」补 2026-09-22 一行。
- `AGENTS.md` 与 `.claude/cursor-review-prompt.md`：通用库允许清单还是 R1.5 裁定之前的版本（缺 `base64` / `flutter_svg` 与六个渲染库，且仍写着「Markdown 渲染库进清单之前判 P2」）→ 对齐 CLAUDE.md 规则 1 当前文本；AGENTS.md 补迭代范围口径。
- `rounds/README.md` / `rounds/TEMPLATE.md`：审查器型号 4.6 → 4.7。
- `ROUNDS.md`：头注里「R7.5 裁定门待所有者拍板」「缺陷轮拟叫 R7.7」已过期；§ 2 尾段 `clipboard_image.dart` 仍写「借 `powershell.exe` 读」（quality 轮起是 runner 走 Win32），`lib/gallery/`「debug 构建才编入」实为不进产品入口、由 `test/gallery_test.dart` 出图。
- `test/fixtures/README.md`：引用的 `lib/gallery/scenarios.dart` 不存在，画板 34 的 `acp/agent_state` 场景在 `lib/gallery/boards/transcript_boards*.dart`。
- 任务卡状态行：`round-00`「待合并 main」、`round-04`「进行中」、`round-7.5`「等所有者三件事 … 不合并」、`round-7.6`「待推 main」、`round-design`「尚未提交；ROUNDS.md 尚未建立」——全部与 ROUNDS.md § 7 对齐成已合并的口径，保留仍待所有者的手测项。
- `rounds/BACKLOG.md`：关闭三条已消解的——`FilesState.setProject` 的 A→B→A 竞态（2026-09-22 切项目假死那批加了 `_projectEpoch` 守卫，`lib/app/files_state.dart`）、「截图验收 Zed Agent 20 项」（2026-09-14 已做完 22 项，`prototype/README.md`）、`prototype/assets/fixtures.js` 缺 `message`（裁定原型不维护、`test/fixtures/` 已补）。
- **没动的**：`docs/research.md`（研究沉淀，按钉版本口径写，仍成立）、`docs/requirements.md`、`docs/acp-projection.md`（契约底稿，与 `wire.dart` 一致）、`design/round-design/materials.md`（设计轮的历史底稿，「7 项自造态」是当时口径，不回改）、`prototype/`（README 已声明不维护）。
