# Round 1.4.1 — v1.4.0 之后合入 main 的六批改动的复审与整改

<!-- 与 quality / 画板 08 同类：R8 之后的单批次轮，登记在 ROUNDS.md § 7 进度表。 -->

> 状态：**已完成**（2026-09-22：Claude 自主审查一遍 → 逐条整改 → cursor 复审两轮、第 2 轮 0 条收口；版本号已改 1.4.1，待所有者快进 `main` 并发布）

## 目标

把 `v1.4.0..main`（`25a7074..689fab5`）这段里合进 main 的六批改动逐批**独立审一遍**、发现的缺陷逐条修掉，再交 cursor 复审到 0 条。其中三批此前从未经过独立审查（提交说明写明「未审查（所有者指定）」），两批走过 cursor 门禁，一批只是审查模型换代：

| 批 | 范围 | 内容 | 此前审查 |
|---|---|---|---|
| A | `v1.4.0..8aa609f` | quality 代码质量清理轮（死代码 / `formatBytes` 与 `write_atomic` 合一 / 私有化 / 无头入口分离 / 剪贴板走 runner 原生通道 / `base64` 直接依赖） | cursor 3 轮，0 条收口 |
| B0 | `8aa609f..1111faa` | 独立审查默认模型换代 `grok-4.7-high-fast`（脚本 + 文档） | — |
| B1 | `1111faa..64f90ba` | 画板 43 时间线跳转白屏闪烁（`transcript_jump.dart`） | **未审查** |
| B2 | `64f90ba..f2192db` | 添加工作目录 / 切项目假死（`workspace_state` 并发补齐、`files_state` 防重入 + epoch、`node.rs` 缓存） | **未审查** |
| C | `f2192db..29d1810` | cursor 九条 findings 的验真与修复（终端表按会话删 / elicitation cancel 守卫 / exited 标 withdrawn / sidecar 自检隔离 / `resolve_inside` / 索引墓碑） | **未审查** |
| D | `29d1810..689fab5` | 画板 08 回合折叠 + 跨工作区在跑数 + 画板 70「转录」开关 | cursor 4 轮，0 条收口 |

所有者指示：审查期间不跑构建；整改完再找 cursor（grok）复审第二遍，直至 findings 归零。

## 前置

- 工作树停在 `main@689fab5`，`vendor/upstream` 是指向主副本的目录联接（fetch-upstream -Check 由 validate 跑）。
- 审查执行器（第 1 遍）：主会话委派 **4 个 Claude Code 只读子代理（opus，并行，一批一个）** 读同一份任务书 `.claude/cursor-review-prompt.md`，范围分别是上表 A / B1+B2 / C / D，判定一律以 HEAD 工作树为准；主会话对每条 finding 逐条核对代码事实后再定处理。这不是回落（cursor 没有硬失败），是所有者指定的「Claude 自主 review」第一遍；第二遍才是 cursor。

## 交付物

整改落在各批原文件上（清单见「代码审查」表的「处理」列），另：

- `rounds/round-1.4.1/round-1.4.1.md`（本卡）
- `rounds/BACKLOG.md`：新增 2 条（剪贴板读取跑在平台线程；没归属的终端缓冲），关闭 1 条（回合折叠锚点量不到时不校正）
- 新用例：`test/ui/elicitation_url_card_test.dart`（2 条）；`test/app/session_order_test.dart`（+1，改 1）；`test/app/workbench_wiring_test.dart`（+2）；`test/ui/turn_fold_test.dart`（+1）；`test/projection/turn_fold_test.dart`（改 1、+1）；`rust/registry/src/node.rs`（+1）

## 验收

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | 第 1 遍审查覆盖六批全部代码改动 | 四个子代理各自列出实际看过的文件；主会话另读全部六批 diff |
| 2 | 每条 finding 有处理结论 | 采纳整改 / 不采纳写明理由 / 记 BACKLOG，见下表 |
| 3 | 整改各带回归用例 | high 与 P2 级整改逐条有用例，且「去掉整改会红」 |
| 4 | 全量校验 | `powershell -File scripts/validate.ps1` 全绿 |
| 5 | cursor 复审归零 | `.claude/cursor-review.ps1`（前两轮全量 `main...HEAD`，第 3 轮起 `since`），直到 `findings: 0` |

## 禁止

默认三条：不改前端页面样式（规则 3）；不加设计稿没有的功能（规则 3）；不在 `vendor/upstream/` 里改代码（规则 4）。本轮另加：审查期间不跑构建（所有者指示）；非严重 finding 不新增机制（CLAUDE.md 审查边界）。

## 代码审查

### 第 1 遍：Claude 自主审查（2026-09-22）

- 审查方式：主会话委派 4 个只读子代理（`general-purpose`，model `opus`）并行，每个读 `.claude/cursor-review-prompt.md` 按第 1–6 节执行；主会话逐条核对代码事实后定处理。
- 范围与结果：A `v1.4.0..8aa609f` 4 条（P3 4）；B1+B2 `1111faa..f2192db` 3 条（P2 1 / P3 2）；C `f2192db..29d1810` 7 条（high 1 / P2 2 / P3 4）；D `29d1810..689fab5` 6 条（high 1 / P2 2 / P3 3）。B0 无代码。**合计 20 条（high 2 / P2 5 / P3 13）**。
- findings 处理：

| 批 | 级别 | finding | 核对 | 处理 |
|---|---|---|---|---|
| A | P3 | `ReadFileList` 只要 `CF_HDROP` 非空就返回 true，一个路径都取不出来时位图分支被跳过（旧 PowerShell 版是 `if ($files.Count -gt 0)`） | 属实 | **采纳**：`windows/runner/acp_clipboard.cpp` 改 `return !out.empty();`（一行；runner 的 C++ 本轮未构建，见「本轮实测」） |
| A | P3 | 剪贴板读取整段跑在平台线程上，8K 位图约百余毫秒整窗冻结；旧实现是异步子进程 | 属实 | **记 BACKLOG**：挪出平台线程属机制类改动 |
| A | P3 | `rounds/round-quality/build-and-test.ps1` 调的是 `D:\cargo-target\...\quality\clip-test.ps1`，按任务卡记的命令跑不通 | 属实 | **采纳**：改成 `$PSScriptRoot` 下那份 |
| A | P3 | `_PermissionScopeMenu` 的注释还写着「公开只为画板对照页」 | 属实 | **采纳**：删掉半句 |
| B2 | P2 | 换项目「先通知后补齐」的窗口里分支切换器仍列着旧项目的分支，点一行会对**新项目**跑 `git switch`（同名分支 main / master 几乎必撞） | 属实：`branch` / `branches` / `branchAreaVisible` / `rulesCount` 要等 `_hydrate` 回来才改，而 `project` 与 `touch()` 已先到 | **采纳**：`workspace_state.openProject` 写完 `project` 后、`touch()` 之前清掉四个字段。回归用例 `workbench_wiring_test`「换项目的补齐窗口里不留旧项目的分支表」（第二次换项目卡住补齐，断言分支表为空），**已验证去掉整改会红** |
| B1 | P3 | `TranscriptJump` 的 `userScrollDirection` 守卫两头都不兑现：滚轮当帧就回 idle 拦不住；真在拖 / 惯性时 `start()` 同步那一下就 `cancel()`，整次点击丢掉不重试 | 属实（SDK `pointerScroll` → `goBallistic(0)` → idle） | **不改行为，改注释**：拖动 / 惯性中点时间线只发生在触屏 + 弹层同时操作（Windows 触控板走 pointer signal），概率极低；反过来改成「等滑完再跳」会在惯性中途把人拽走，两害取轻保留 cancel。注释写明「拦不住滚轮」这一事实 |
| B2 | P3 | 系统 Node 的进程级缓存没有失效条件：`locate` 命中缓存后直接拿路径拉子进程，卸载 / nvm 切走后拿的是过期路径 | 属实 | **采纳**：命中缓存时复核 `is_file()`，不在就重探并回填；`node.rs` 加用例 `locate_reprobes_when_cached_system_node_is_gone` |
| C | **high** | 会话索引的墓碑永不过期：sessionId 被复用时（fake-agent 不带 `--sessions` 恒回 `sess_fake_1`）新会话的索引行被 `_undoIfRemoved` 静默删掉，侧栏根本不出现 | 属实（`_removed` 只加不减） | **采纳，换掉墓碑**：`SessionIndex.remove` 改为**只等这一条会话在途的 upsert 落地**（按 `(agentId, sessionId)` 登记在途 Future）再发删除——删除总排在它们之后到核心，被删的行不会被写回；之后再来的 upsert（删掉再新建的同 id 会话）照常写入。不排队所有写命令（那是原作者验证过会让收轮 `saveIndex` 超时的方向）。用例：原「删掉的会话不会被在途的 upsert 写回来」改成不 await remove（它现在会等），新增「删掉再新建同 id 的会话：新的那条照常写进索引」，**已验证去掉整改会红** |
| C | P2 | agent 退出把 URL 型 elicitation 标成 withdrawn，但画板 28 的 URL 卡只认 completed / cancelled：Open 仍可点且真开浏览器，已点过 Open 的永远转圈、Cancel 点不动 | 属实 | **采纳**：`elicitation_url_card.dart` 把 withdrawn 并进 cancelled 的收尾（按钮不可点、不出 Cancel），状态行写「agent 已不再等待」。新用例文件 `test/ui/elicitation_url_card_test.dart` 2 条 |
| C | P2 | `resolve_inside` 用例注释声称 ② 覆盖了「走完之后才建链接」那个窗口，实际链接在调用前就建好、被 `ensure_inside` 的逐级 `symlink_metadata` 拦下（末段也在循环里），canonicalize 那条越界分支零覆盖 | 属实 | **采纳（改注释）**：写明 ② 由 `ensure_inside` 拦下，canonicalize 分支只在竞态窗口里走得到、用例造不出那个窗口。不新增机制（造竞态要 hook 文件系统） |
| C | P3 | tar 回归用例钉的是 bsdtar 语义，GNU tar 是剥掉 `../` 后照常解出、退出码 0，用例会红 | **不成立**：GNU tar 自 1.29（2016，CVE-2016-6321）起同样跳过含 `..` 的成员并以 2 退出（`Member name contains '..'`），剥前缀的是打包（`-c`）那一侧；现行 Linux 发行版都 ≥ 1.29 | **不采纳**；注释补一句 GNU tar 的版本口径 |
| C | P3 | 删掉 `TerminalStore.clear()` 之后没有归属的终端缓冲永不回收（认证终端、只用 `terminal/output` 轮询没嵌进卡的终端） | 属实（有界：单条 64 KB，条数随终端数长） | **采纳一半 + 记 BACKLOG**：`Sessions.forget` 顺手 `terminals.removeAll(s.ownedTerminalIds)`（删会话 / 收回空壳后本会话名下的缓冲跟着走）；认证终端要在认证收尾处释放，记 BACKLOG |
| C | P3 | 重连窗口里迟到的 `exited` 会把新连接的挂起项误标 withdrawn：`disconnect` 两次 3 s 宽限超时后直接返回，旧连接的 `finish()` 还没跑（典型是 `.cmd` 包装的孙进程攥着 stdout），`exited` 在新连接跑起来之后才发，前端按 agentId 认领 → 新 agent 的请求全 withdrawn、agent 干等 | 属实；后果是 agent 挂起 | **采纳**：`rust/acp-core/src/agent.rs` 的 `disconnect` 在第二次宽限也超时后就地 `shared.finish(None)`——清挂起表、放终端、发 `exited`，一定发生在新连接建立之前；`finish` 只生效一次，进程真退出时那一下空转。无法在 scripted 里造「kill 不死」的进程，靠代码阅读与既有 disconnect 用例（`cargo test` 全过） |
| C | P3 | `withdrawn` 复用了「agent 已撤回」的文案，进程退出不是撤回 | 属实（设计稿里没有这句，是实现自定的） | **采纳**：permission 卡 / 表单卡 / URL 卡统一改成「agent 已不再等待」，对 `$/cancel_request` 与进程退出都成立 |
| D | **high** | 转录偏好的读盘 `folds.start()` 排在 `core_init` 之前且没有补读：核心回 `not_initialized`，`_readSettingsOk` 停在 false，画板 70 的开关既读不回（每次启动恒为默认开）也存不下（`setAutoCollapse` 永不落盘） | 属实（`workbench_controller.dart:189` vs `:213`；`AppearanceController` 对同一场景有补读，这一份没抄） | **采纳**：`unawaited(folds.start())` 挪到 `await b.init(...)` 之后。回归用例 `workbench_wiring_test`「转录偏好在 core_init 之后才读」（FakeCore 在 `init` 之前对 `transcriptPrefsGet` 抛 not_initialized），**已验证去掉整改会红** |
| D | P2 | 画板 70 的全局开关翻面这条路完全没有滚动锚点校正（设置页与转录同屏，开关既不走点击回调也不通知 store），人正读着长转录时拨一下，视口跳走所有折叠块高度之和 | 属实 | **采纳（两半）**：① `TranscriptFoldAnchor` 自己订阅 `TranscriptFolds`（通知到达时 `isCollapsed` 已翻面、屏幕还是旧布局，与 store 通知同一时机），快照在构造 / 换会话时按当前状态打底，多轮同时变时从后往前取第一个量得到的轮；② 锚点行在重建后被推出已建窗口、量不到时，不再放弃，交给画板 43 的 `TranscriptJump` 分帧找回来（`start` 加 `topInset`，落点是那一行原来在视口里的 y；目标改按行 id `transcriptRowId`，页脚也能当目标）——这同时收掉了 BACKLOG 里「锚点量不到时不校正」那条残余。用例 `turn_fold_test`「全局开关翻面：长转录里…」（五轮几十行同时折 / 展，结论位置 ±0.5），**已验证去掉整改会红**（第一版只订阅不找回时该用例在展开一侧就红）。中途试过的「列表按键复用（`findChildIndexCallback`）」已撤回：Flutter 的 SliverList 对被移动的子节点会清空 `layoutOffset` 并从头重排，不保位置，只多一次全量布局 |
| D | P2 | 「压缩标记进折叠块」用例建的其实是 tool_call，`e is CompactionEntry` 分支从没跑过；Plan 条不折叠也无用例 | 属实 | **采纳**：改成发真的 `compaction_update`（断言 `folded.single is CompactionEntry`），另加「Plan 条不进折叠块」用例 |
| D | P3 | 时间线跳转里的 `c.folds.expand(...)` 绕过锚点，`_collapsed` 快照过期，下一条 store 通知白 `_arm` 一次、消耗 `_maxSettles` | 属实 | **采纳**：锚点订阅 `folds` 之后快照自然同步；跳转侧在 `expand` 之后调 `_foldAnchor.cancel()` 让路（否则帧后校正把结论拽回原地、跳转再拉回来，两个 jumpTo 打架） |
| D | P3 | `Fold.itemGap` 是死 token（画板的 token 表里也没有这一项） | 属实 | **采纳**：删掉 |
| D | P3 | `ProjectSwitcherPopover._row` 顶上两段「一行工作区。」互相矛盾，第一段是上一版残留 | 属实 | **采纳**：删掉第一段 |

- 主会话另读全部六批 diff 的补充结论：B0（模型换代）无代码；`transcript_jump` 的步进单调性 / 终止性、`_hydrate` 的 epoch 覆盖面、`resolve_inside` 在 Windows 上 `\\?\` 前缀两边同源、`Transcript` 段的 serde 形状、C++ 剪贴板通道的资源配对与整数溢出边界逐项核过，未另发现缺陷。
- 结论（第 1 遍）：20 条里 16 条采纳整改（含 2 条 high 与 5 条 P2 全部）、1 条不采纳（tar / GNU 语义，写明理由）、1 条只改注释（滚轮守卫）、2 条记 BACKLOG（含 1 条采纳一半）。

### 第 2 遍起：cursor CLI 复审

- 审查方式：`powershell -File .claude\cursor-review.ps1`（默认档，后台）
- 审查器与模型：cursor CLI + `grok-4.7-high-fast`
- 审查范围与基准提交：
  - 第 1 轮 全量 `v1.4.0..HEAD`（HEAD = `c29fd8a`，即六批合并 + 第 1 遍整改 = v1.4.1 的全部内容），产物 `.claude/reviews/20260922-143942-review.out.md`（18 分钟）
- findings 处理：

| 轮 | 级别 | finding | 处理 |
|---|---|---|---|
| 1 | P2 | `SessionIndex.remove` 的等待只覆盖发删除之前就在途的 upsert；删除命令发出去之后、落地之前，收轮的 `saveIndex` 再写这条会话（当前会话的 `sessionId` 要等 `remove` 返回才清空，`store` 仍非空），与删除在核心里并行，删除先落、它后落就把刚删的行写回来 | **采纳整改**：加 `_removing`——删除从发出到 `apply` 落地之间，同一条会话新来的 upsert 不发（`_upsertTracked` 回 null，调用方直接返回）；删除返回之后的写照常。循环退出到登记 `_removing` 之间没有 await，起不了新写。回归用例 `session_order_test`「删除命令在途时这条会话再来的写不发」（`_SlowRemoveCore` 按住 remove，断言 upsert 计数不增），**已验证去掉整改会红** |
| 1 | P3 | `_jumpToEntry` 只在 `expand` 真翻面时才 `_foldAnchor.cancel()`；目标本就不在折叠块里、或那一轮已经展开时，上一次折 / 展量不到锚点起的找回跳转（最多 300 帧）不会停，与时间线跳转每帧各 jumpTo 一次、点击落点被盖掉 | **采纳整改**：`cancel()` 改为无条件调用（它同时停掉锚点的 `TranscriptJump`）。没有单独用例：要同时造出「上一次找回还在跑」与「时间线点击」两个多帧过程，现有跳转与锚点用例已各自覆盖两条路 |

- 第 2 轮 全量 `v1.4.0..HEAD`（HEAD = `c7932ad`，第 1 轮整改之后），产物 `.claude/reviews/20260922-150739-review.out.md`：**`findings: 0`**。审查器逐项核了第 1 轮两处整改「关严了」（`_removing` 的登记与等待循环之间没有 await；`_jumpToEntry` 无条件 `cancel`），并说明已记 BACKLOG 的四项没有升到 high、不重复报。
- 结论：**整改后 PASS**。cursor 两轮累计 2 条（P2 1 / P3 1）全部采纳整改；第 2 轮 0 条收口，无 high 级或阻塞性 findings 遗留。连同第 1 遍的 20 条，本轮合计 22 条 findings：18 条采纳整改、1 条不采纳（写明理由）、1 条只改注释、2 条记 BACKLOG。

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-1.4.1/BLOCKED.md`，停下呼人。禁止放宽验收标准自我通过。

## 本轮实测

- **审查期间没跑任何构建**（所有者指示）：第 1 遍全靠读 diff 与工作树。整改之后才跑门禁。
- `scripts/validate.ps1` 全绿：17 项门禁 + `cargo test --workspace`（acp-core 25 + fixtures 1 + scripted 10、fs 19、pty 13、registry 18、settings 17）+ `cargo clippy --all-targets -- -D warnings` + `flutter analyze`（0 error 0 warning，16 条 info 与 main 基线同）+ `flutter test` **400 项**（main 是 393；新增 7 条、改 2 条）。
- 逐条验证过「去掉整改会红」的用例：索引删除（`session_order_test` 两条）、分支表窗口、转录偏好读盘顺序、全局开关锚点（第一版只订阅不找回时在展开一侧就红）、URL 卡 withdrawn（第一版用例自己写错——`Overlay.initialEntries` 只在首次建树生效，第二次 pump 没重建卡片，改成每次换 key）。
- cursor 两轮耗时：第 1 轮全量 `v1.4.0..HEAD`（约 140 文件 / +5,400 行）**22 分 22 秒**（14:39:42 → 15:02:04），第 2 轮同范围 **13 分 05 秒**（15:07:39 → 15:20:44）。发起脚本的 PowerShell 包装会一直等到审查进程结束才返回（不是脚本的 bug，只是别把它当「起好了」的信号）。
- **runner 的 C++（`acp_clipboard.cpp` 一行 `return !out.empty();`）本轮未编译**：`validate.ps1` 不含 `flutter build windows`，按所有者指示也没单独跑构建；语法是一行布尔表达式，随 v1.4.1 的 release 构建一起编。
- 踩到的坑：① 一度把 `TranscriptList` 改成按键复用行（`findChildIndexCallback`）以为能保住视口位置——Flutter 的 `SliverMultiBoxAdaptorElement.performRebuild` 对**被移动**的子节点会把 `layoutOffset` 置 null，`RenderSliverList.performLayout` 随后把这些子节点全部回收、从 index 0 重排，位置不保还多一次全量布局，已撤回；② 折叠锚点的快照 `_collapsed` 原来只在「变化时」同步，构造时是空集，于是全局开关第一次翻面（从默认全折到全展）被判成「没变」——构造与换会话时按当前状态打底才对；③ `sed -i` 在 Git Bash 里会把 `.ps1` 的 CRLF 写成 LF，改完用 python 按字节转回。
