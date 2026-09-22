# Iteration 02 — 回合折叠的两条口径 + BACKLOG 收尾三组

<!-- 保存为 iterations/iteration-NN.md。一个迭代一个文件、一项一行；流程正本见 iterations/README.md，不在这里复述。 -->

> 状态：进行中　起止：2026-09-22 –　基线：`main` = `a7063cf`（第 1 / 2 项开工时）、`022079b`（第 3 项起的三组开工时）

前半是回合折叠的两条口径（第 1 / 2 项，`main` 直改）：失败不再拦住自动折叠、重放回来的历史也能折。
后半是 BACKLOG 收尾三组并行（第 3 项起，各自 worktree 分支，组内的项一起验证、一起审查）：会话索引、输入框、主题重建。

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | board | 含失败工具调用但**正常收轮**的回合改为照常自动折叠（`autoCollapsible` 去掉 `failures == 0`），失败数仍由摘要行的「N 项失败」承担；画板 08 的三处规则文字与画板 70 / 设置页那句说明同步改字，两张 PNG 重出 | 所有者裁定 2026-09-22 | `main` 直改 → `0297393` | validate 全绿（`flutter test` 403 项） | 未审查（所有者指定） | 已合并 |
| 2 | fix | 回合折叠对 `session/load` 重放回来的历史不生效：切轮加一条退路——**没有轮边界时按顶层用户消息切**（`isTurnStart`，与画板 43 时间线、Restore 截断点同口径）。`TurnFold` 随之拆成 `owner`（身份）+ 可空 `turn`（轮边界） | 所有者报障 2026-09-22；BACKLOG P1「壳与交互」（已剪进 BACKLOG-CLOSED.md） | `main` 直改 → 待提交 | validate 全绿（`flutter test` 408 项） | 4 轮 / cursor CLI `grok-4.7-high-fast`：1 → 1 → 1 → **0**（high 0 / P2 3 / P3 0，三条全部采纳整改） | 待提交 |
| 3 | fix | 从文件选择器加图没有大小门：门与 base64 一起收进 `ComposerState.addImageBytes`，**判在编码之前**，超了记 `lastError` 不编码 | BACKLOG P0「附件与剪贴板」第 2 条 | `claude/composer-image-mention-fixes-f2eb2d` → `0778403`（快进） | validate 全绿 | 2 轮（high 0；第 1 轮 P2 1 已采纳整改） | 已合并 |
| 4 | fix | `@` 菜单在用户点走之后自己弹出来：`_updateMentionMenu` 的 await 之后用 `_activeToken(editor.text)` 复核 token，不一致就丢结果。**只关掉「改词 / 清空」那半**，Esc / 点外面那半放回 BACKLOG | BACKLOG P1「壳与交互」第 7 条 | 同上 | 同上 | 同上 | 已合并 |
| 5 | fix | 会话索引（`sessions.json`）写回取错源的三处同根因缺陷：① `SessionIndex.upsert` 的标题退回索引里已有的（含会话头 `sessionTitle` 那一半）；② `saveIndex` 收一个 `SessionStore`，收轮时由 `TurnController._runTurn` 传刚跑完那条；③ `session/list` 校对的 cwd 过滤改走 `WorkspaceState.normalizeCwd` | BACKLOG P0「会话身份与生命周期」1 条 + P1「数据一致性」2 条（iteration-01 候选 A 的 13 / 14 / 15） | `claude/session-index-write-bugs-3c53b0` → `7264fd5`（快进） | validate 全绿 | 2 轮，2 条（high 1 / P2 1）→ 0 high | 已合并 |
| 6 | fix | 换主题 / 换字体之后界面只切一半：`MarkdownBody` 按 `Fonts.generation` 判过期（照抄 `_SourceView`） + 10 个叶子 widget 摘掉 `const` 构造 | BACKLOG P1「主题与渲染」2 条 | `claude/theme-font-partial-rebuild-471573` → `62b6bf8`（快进） | validate 全绿（`flutter test` 408 项，新增 5 项） | 1 轮 / cursor CLI `grok-4.7-high-fast`，**0 条** | 已合并 |
| 7 | fix | 风扇狂转：① 文件树 git 徽章自激空转——`git status` 自己建删 `.git/index.lock`（Windows 还连带一条 `.git` 目录的 Modified），watcher 把它当 `.git` 变化上报，前端据此再跑 `git status`，仓库零改动时每秒起 2–6 个 `git.exe`；② `Spinner` 与侧栏扫掠线两处常驻动画没有 `RepaintBoundary`，会话运行中整窗每帧重栅格（2880×1800 @ 120Hz 核显实测 GPU 44–64%）。修：`rust/fs/src/watch.rs` 的 `classify` 跳过 `.git` 之下目录身上与 `*.lock` 的事件（两条新测试，其一用真 git 带子模块复现）；两处动画包 `RepaintBoundary`。实测见「备注 · 风扇狂转」 | 所有者报障 2026-09-22 | `fix-fs-watch-loop`（worktree `AcpAgentClient-fswatch`）→ 待合并 | validate 全绿（2026-09-22，整改后重跑亦全绿）；未构建 | 2 轮（cursor）：第 1 轮 1（high 1，采纳）、第 2 轮 0 | 待合并 |

## 收口

- 构建 / 手测：第 1 项已随 release worktree 出包并镜像到 `D:\tools\AcpAgentClient`（2026-09-22 16:48，五处哈希双边一致、安装目录 smoke `ok: true` / `coreVersion 1.4.1`）；**第 2 / 3 / 4 / 5 / 6 项尚未构建**（第 3 / 4 项的手测项：`+` → Image 挑一张 > 20 MB 的图、敲 `@` 后立刻改词；第 5 项：重开应用 → 点一条旧会话 → 聊一句看侧栏标题还在、计数对，另开一条会话后台跑完看侧栏计数当场刷新；第 6 项：浅 → 深 → 浅，看 registry 徽章 / 设置页徽章 / 工具卡 Canceled 徽章 / 各处 chevron / 文件面板空态 / spinner / 整段对话正文（表格、行内代码底色、正文字色）全部跟着变，不用 reload 会话）。
- 发版：不发（版本号仍 1.4.1，不打 tag、不推 GitHub、不发 release）。
- 移出项去向：—
- 设计稿补注记：第 1 项**直接改了画板 08 / 70 的源并重出 PNG**（规则变更写进画板更干净）；第 2 项走 `design/DIVERGENCE.md` A-16（画板没画「重放回来的历史怎么折」，按规则 3 不要求补稿）；第 3 / 4 项都不改画板（大小门的提示文案走既有的 `lastError`，菜单行为回到画板 42 本来画的样子），无偏离可记；第 5 项同样无偏离（三处都是写回取错源的缺陷，界面按画板本来就该显示真标题与真计数）；第 6 项也无偏离——这次是把实现改回画板 07 定义的深色表现，不是偏离，不记 `design/DIVERGENCE.md`。

## 备注

### 第 2 项的四轮审查（范围都是 `-Scope worktree`，因为整批改动直到收口都没提交，没有可当基线的「上一轮已审提交」）

| 轮 | findings | 内容与处理 |
|---|---|---|
| 1 | 1（P2） | **历史轮没有回合页脚兜底时锚点落空**：`_candidates` 的候选是「本轮折叠块之后剩下的条目 + 回合页脚」，历史轮没有页脚；这一轮再收在工具调用 / 思考上（没有最终助手文本）就一条候选都给不出来，`_arm` 落空而 `_collapsed` 已改写，这一下不补校正。**采纳整改**：历史轮跨到下一轮 yield 第一条真实出行的条目当锚 |
| 2 | 1（P2） | **上一轮整改自己引入的回归**：第一圈的跨轮判据写成了 `e is TurnEntry \|\| isTurnStart(e)`，对实时轮也生效；而实时轮按 `TurnEntry` 切轮，agent 发来一条对不上的 `user_message_chunk` 时投影层会在折叠块之后另起一条顶层用户消息，按它停下会把本轮结论整段掐出候选。**采纳整改**：判据与 `foldsOf` 对齐成 `e is TurnEntry \|\| (fold.turn == null && isTurnStart(e))` |
| 3 | 1（P2） | **兜底只给一条**：那一条（下一轮第一行）恰好滚出 `ListView` 缓存、而人正看着它后面那段很长的正文时，候选照样用完。**采纳整改**：不再叠补丁，把两圈**合并成一圈**——遇 `TurnEntry` 时实时轮 `break`（页脚离得更近）、历史轮 `continue`（跳过不出行的轮边界继续往后逐条 yield），其余条目一律 yield。`isTurnStart` 在锚点这边因此完全不再使用 |
| 4 | **0** | 收口。审查器逐项核过：实时轮的候选顺序与整改前一致、`indexOf` 按实例相等不会选到变化点之前的行、`from == 0` 那一支跳过扫描 |

**三条 findings 指的是同一处**（`transcript_fold_anchor._candidates`），根因是一个：**把「哪里切轮」（`foldsOf` 的判据）与「哪一行能当锚」（位移带得住就行）混为一谈**。合并成一圈之后这两件事彻底分开，锚点这边不再引用 `isTurnStart`。

### 回归用例三条都验证过「去掉整改会红」

- 「历史轮收在工具调用上、没有页脚可兜底」→ 关掉整改后气泡被整段推出视口、连 finder 都找不到；
- 「实时轮里折叠块之后多出一条对不上的用户消息」→ 结论 `dy` 从 46 跳到 −261（正好一个折叠块高）；
- 「历史轮的下一轮第一行已滚出缓存」→ 按旧的「跨轮只给一条」行为，正文 `dy` 从 −558 跳到 −834。

**写这类用例踩到的两个坑**（下次照抄）：

1. **往回翻的量必须大于折叠块自身的高度**。否则折叠后 `pixels` 被 `maxScrollExtent` 夹到底，视口跟着内容一起缩，位移正好抵消，`before == after` 恒成立——第一条用例因此假绿过一轮（翻 200 < 折叠块 307，改成 350 才真红）。
2. **往回翻得越多离上面的条目越近**（视口上移）。要让某一行落在 `ListView` 缓存（默认约 250px）之外，得靠**加长它后面的正文**，不是靠多翻——第三条用例的正文因此从 200 段加到 400 段。

### 环境

- `validate.ps1` 有一次报 `VALIDATE FAILED: cargo test --workspace`，单独重跑 `cargo test --workspace` 全绿（acp-core 25 / scripted 10 / fs 19 / pty 13 / registry 18 / settings 17 + doc-tests，0 failed），再跑整份 validate 也全绿。本轮一行 Rust 都没改，判定为 validate 内部 cargo 与 flutter 并行时的 flaky，不追。


**编号**：合入 `main` 后已定下——第 1 / 2 项是 `main` 直改的两条回合折叠口径，输入框那组占 3 / 4，会话索引那组占 5；主题重建那组合入时往后排。

**第 3 / 4 项（输入框，2026-09-22）**

- 改动面：`lib/app/composer_state.dart`（两处）、`lib/app/workbench_screen.dart`（`_addImage()` 一行 + 删掉因此空掉的 `dart:convert` import）、`test/app/workbench_wiring_test.dart`（四桩新用例 + 一个假核心）、`test/ui/menu_overflow_test.dart`（两处 `onChanged` 之前补 `editor.text`，见下）。契约零 diff，`lib/theme/tokens.dart` 与画板 widget 零 diff。
- **大小门为什么落在 `ComposerState`**：`workbench_screen` 一处都不写 `lastError`，门做在那边就是新的分层（BACKLOG 2026-09-20 已定这个落点）。新入口 `addImageBytes(bytes, mimeType, {path})` 收原始字节，超 `clipboardImageSizeLimit` 就置 `lastError` + `touch()` 返回、**不编码**——判在 `addImage` 里已经晚了，界面卡住的正是那个约 80 MB 的 base64 字符串。文案沿用剪贴板那条路的「图片太大，没有加进输入框」，不写死 MB 数（两条路的门不是同一个数）。`pasteImageFromClipboard` 的 `skippedTooLarge` 一行未动。
- **`@` 菜单的过期判据**：`_updateMentionMenu` 改收整个 `@…` token（原来只收查询词），await 之后 `if (_activeToken(editor.text) != token) return false;`，靠 `guard` 的返回值把「过期」与「桥抛错」分开——过期不写回也不 `touch`，抛错由 `guard` 自己通知过。没有新增请求序号或取消队列（审查边界）。
- **只关掉了一半，另一半放回 BACKLOG**：用户按 Esc / 点走**但一个字都没改**时 token 仍然相等，结果照样写回；菜单已经开着时同理（`@` 的结果显示后改成 `@x`，Esc 先把菜单清掉，`@x` 回来又写回去）。要覆盖得给「已被用户撤掉」立一个态，属机制类改动。第 1 轮审查把「代码注释与 BACKLOG 关闭行都按整条症状写」判为 P2，已采纳：注释改成只描述「正文里的 token 变了才丢」，`BACKLOG-CLOSED.md` 那一行写明只关掉哪半，残余作为一条窄条目回到 `BACKLOG.md` 壳与交互（合入 `main` 后按真实条数重算：P0 11 / P1 25 / 壳与交互 7 / 总计 79）。
- **测试里必须先写 `editor.text` 再调 `onChanged`**：产品里 `onChanged` 是 `EditableText` 把新值写进 controller **之后**才回调的，两者永远一致；过期判据就是拿回调时的 token 和事后的 `editor.text` 比。原先 `test/ui/menu_overflow_test.dart` 直接调 `c.composer.onChanged('@')` 而不碰 `editor.text`，加上判据后结果会被判成过期丢掉（菜单不出来），所以那两处补上赋值——这是测试替身不够真，不是产品行为变了。
- **未构建**：本组只跑 `scripts/validate.ps1`（全量，含 `flutter test`）。`+` → Image 挑大图、敲 `@` 后立刻改词这两项手测留到迭代收口时的 `build.ps1` 一起做。

**代码审查（第 3 / 4 项）**

- 执行器 cursor CLI（`grok-4.7-high-fast`），无回落。
- 第 1 轮 `-Scope branch`（`main...HEAD`，提交 `dc2c588`）：**high 0 / P2 1 / P3 0**，产物 `.claude/reviews/20260922-181159-review.out.md`。
  - P2「正文没改时 Esc / 点外部之后 `@` 菜单仍会自己打开」——**采纳**。它指的不是判据本身错，而是代码注释与 BACKLOG 关闭行按整条症状写、名实不符，且用例没锁住那条路径。按它给的最小修复办：不加「已撤掉」状态，只改注释与登记口径，残余条目回 `BACKLOG.md`（见上一段）。
- 第 2 轮 `-Scope since -Base dc2c588`（只审整改 diff，提交 `843c0d2`）：**findings 0**，产物 `.claude/reviews/20260922-182152-review.out.md`。核到「过期判据仍只比较正文 token，没有加『已撤掉』状态，BACKLOG 的三个计数与条目数一致」。
- 收口：**0 条 high**，符合合并标准。

**合入 `main`（第 3 / 4 项，2026-09-22，所有者指示）**

- 范围：`main` 从 `022079b` 前进到 `d4c33a1`（一个提交，即第 2 项「重放历史也能折」）。**代码零重叠**——那边动的是 `lib/projection/turn_fold.dart` 与转录折叠一线，本组动的是 `lib/app/composer_state.dart` / `workbench_screen.dart`，四处冲突全在登记文件上，按「两边都留」解：
  - `iterations/iteration-02.md`：两份任务卡合成一份——标题与基线行各收一半（第 1 / 2 项基线 `a7063cf`，第 3 项起 `022079b`），表行按 1 / 2（`main` 直改）+ 3 / 4（本组）排，「收口」两套条目并成一套，「备注」两段并列。第 2 项那行的「待提交」保持原样，不代另一组回填。
  - `iterations/README.md`：§ 5 的 02 行两边主题并成一句。
  - `rounds/BACKLOG-CLOSED.md`：两边各自追加的条目都留，`main` 那条在前（`d4c33a1` 先落）。
  - `rounds/BACKLOG.md`：**计数必须按合并后的真实条数重算，不能取任一边**。基线 81：`main` 关掉 1 条（P1 壳与交互），本组关掉 2 条（P0 1 + P1 1）并新开 1 条（P1 壳与交互的残余）→ P0 11、P1 25、壳与交互 7、总计 79。git 自动合并把总计留成了 80（两边各自算的巧合值），已改。改完用脚本逐档数过一遍 `- [ ]`，六个档位声明数与实际条数全部相符。
- 顺手发现、**没动**：`### 代码质量（quality 批）（4）` 这个小节的声明数与其下条目数对不上，在 `main` 上就已如此，与本次合并无关，留给下一次动 BACKLOG 的人核。
- **合并方向反过来那一下（所有者指示 2026-09-22）**：分支已含 `main`，所以是**快进**——`main` 由 `d4c33a1` 直接前进到 `0778403`，没有新的合并提交。合并前 `main` 工作副本干净（只有一个未跟踪的 `design/round-design/input/revision-04.md`，快进不碰它）。合并前的全量 validate 已绿（16 步全 PASS，`flutter test` 412 项），未在 `main` 上重跑——快进不改任何内容，树与刚验过的那份逐字节相同。
- **另两组尚未合入**（`claude/session-index-write-bugs-3c53b0`、`claude/theme-font-partial-rebuild-471573` 合并时本文件与 `rounds/BACKLOG.md` 还会再冲突一次，计数照样要按真实条数重算，别取任一边）。

### 第 5 项（会话索引，2026-09-22）· 三条是同一个根因

三条都是「写回索引时取了错的源」：标题取了会话头的占位串、收轮取了当前选中的 store、校对取了没归一的 cwd 原串。核心侧的 `upsert` 是**整行替换**（`rust/settings/src/index.rs`），所以取错源不是少写一格，而是把索引里对的那格盖掉。

改动只在三个文件：`lib/app/session_index.dart`、`lib/app/session_controller.dart`、`lib/app/turn_controller.dart`。契约零 diff（不加桥命令、不改 `_meta` 键、不动 `docs/design.md` § 3 / § 4），不新增依赖，`lib/theme/tokens.dart` 与画板 widget 零 diff。

**① 标题三级退回 `store → 索引 → 占位串`。** `SessionIndex.upsert` 原来是 `s.title ?? titleFallback`，中间插一层新加的 `SessionIndex.titleOf(sessionId)`（非空才算有）。改名与 agent 的 `session_info_update.title` 都先写进 `store.title`，第一级就命中，所以这层退回不会把用户改过的名字搞反——补了一条用例钉住这点。

**会话头那一半也做了**（BACKLOG 的产品行本来就写着「会话头也一样」）：`SessionController.sessionTitle` 同样退回索引标题。三个分支逐个看过：`!hasAgent` 仍是 `No Agent`；`sessionId == null`（真的新会话、启动后还没开会话）查不到条目，仍是占位串——两条既有用例 `sessionTitle == 'No Agent'` 与 `'New Zed Agent Session'` 原样通过；只有「选中了一条会话、但 store 上没有标题」这一种情况变了，那正是要修的。

**② `saveIndex({SessionStore? target})`。** 缺省仍是 `store`；`_runTurn` 收轮时传它手里的 `s`。另外三个调用点保持「当前会话」语义、未改：`createSession` / `adoptAuthSession`（都紧跟 `_adoptSession`，新会话此刻就是当前会话）、`stampPromptSent`（`send()` 里 `s` 与 `store` 同一个对象）。

顺带把 `titleFallback` 从 `sessionTitle` 改成按**传进来那条会话自己的 agent** 算的占位串（新的 `placeholderTitleOf` / `agentDisplayNameOf`，后者是既有 `agentDisplayName` getter 的参数化版本）：不改的话，给后台那条写索引时会把前台那条的标题写到它头上——这是引入 `target` 参数**带出来的**新缺陷，属于本项该一起了结的，不是顺手改。

**③ 校对的 cwd 比法。** `reconcileSessions` 里 `entry['cwd'] != scope` 换成两边都过 `WorkspaceState.normalizeCwd` 再比。**过滤本身留着**（那句注释记的是 2026-09-16 dsh 实测「21 条全被误标」的教训），`entry['cwd']` 不是 String（没记 cwd 的老条目）时**照旧跳过**——这一条只换比法，不放宽过滤。

**行数门只剩 3 行余量**：`lib/app/session_controller.dart` 改完 897 行，门是 900（`validate.ps1` 的「lib/app 行数门」）。为此压过一轮注释，下一个动这个文件的人要先腾地方。

### 第 5 项 · 验证

- **三条各补一条可证伪的回归用例**，并逐一验证过「把 `lib/app/` 那三个文件还原成 `main` 的版本后这三条必红」：
  - `test/app/session_lifecycle_wiring_test.dart`「载回来的会话再聊一句…」——索引里已有 `My Session`、`session/load` 不重放 `session_info`，聊一句之后索引仍是 `My Session`（还原后实得 `New a Session`），会话头同样；
  - `test/app/session_order_test.dart`「后台跑完那一轮刷的是它自己那条…」——A 选中、B 后台收轮，之后 B 的 `messageCount` 是 1、A 的仍是 3（还原后 A 被刷成 0）；
  - `test/app/session_lifecycle_wiring_test.dart`「cwd 只差写法的条目照常参与校对」——索引条目 cwd 写成 `D:\repo\`、当前项目是 `D:/repo`，校对照常补标题（还原后实得没补），agent 侧真没有了时也照常进 `missingOnAgent`。
  - 另加一条护栏用例「agent 补的标题照常盖过索引」（store 上有标题时不退回索引），它在改动前后都绿，防的是以后把三级退回的顺序改反。
- `powershell -File scripts/validate.ps1` 全量三次全绿（整改前 407 项、整改后 408 项、合入 `main` 后 417 项）。
- **未构建、未手测**，手测项见上面的「收口」段。
- Windows 实测（规则 9）：本项不涉及子进程拉起。worktree 第一步的 `scripts/fetch-upstream.ps1 -Check` 九条全绿（`vendor/upstream` 按惯例用目录联接指向主副本）。

### 第 5 项 · 代码审查

执行器 cursor CLI（`grok-4.7-high-fast`），无回落。

**第 1 轮**（`-Scope branch`，`main...HEAD`，提交 `dcc87ed`，产物 `.claude/reviews/20260922-181509-review.out.md`）：2 条（high 1 / P2 1）。

- **[high] 删掉仍在跑的会话后，收轮仍会把这条写回索引** — **采纳整改**。验真属实，而且是本项改动**引入**的：`deleteSession` 不发 `session/cancel`，在途那一轮照样会收，而收轮那次 `saveIndex` 手里握着的是开轮时那个 `SessionStore`；改之前它读 `store`（`sessionId` 已被 `deleteSession` 置空、`sessions.forget` 也已经把它拿掉），自己就挡住了。整改是 `saveIndex` 加一句判断：会话表里那个 id 底下不是同一个 store 就不写（`!identical(sessions.maybe(s.sessionId), s)`）——顺带覆盖「删掉再新建同 id 会话」被迟到的写盖成旧值那一档。补了回归用例「删掉正在跑的会话：那一轮收轮时不把它写回索引」，同样验证过去掉这句判断后必红。
- **[P2] agent 把标题清成 null 之后，下一笔写回会从索引把旧标题填回去** — **不采纳**，已记 `rounds/BACKLOG.md`「数据一致性」。理由：`store.title == null` 的两种含义（载回来还不知道 / agent 显式清空）要分清，得在 `SessionStore` 上记一个「`hasTitle` 曾经为真」的新状态，属投影层的新机制，按审查边界非严重 finding 不许；复审给的最小修复「清空时把 `store.title` 写成空串」违反规则 2（协议给的是 null，不自造值），改用 `seen['session_info_update']` 当判据也不成立——只带 `updatedAt` 不带 `title` 的更新也会计数，会把本项修掉的那个缺陷放回来。本项目接的五个 agent 没有一个会清空标题。

**第 2 轮**（`-Scope since -Base dcc87ed`，只审整改 diff，产物 `.claude/reviews/20260922-182840-review.out.md`）：**0 条**。复审逐条核对了那道门的两档（表里没有这个 store / 同 id 换了 store）、缺省路径不受影响、以及「删除进行中但 `forget` 还没发生」那段窗口仍由 `SessionIndex._removing` 挡着（中间没有 await，收轮插不进来）。**0 high，可合并。**

### 第 5 项 · 合入 `main`（2026-09-22，所有者指示）

- `main` 从 `022079b` 前进到 `eac3a91`（回合折叠两条口径 + 输入框那组）。**代码零重叠**：那边动的是 `lib/projection/turn_fold.dart` / `transcript_fold_anchor.dart` / `composer_state.dart` 一线，本项动的是 `session_index.dart` / `session_controller.dart` / `turn_controller.dart`，三处冲突全在登记文件上：
  - `iterations/iteration-02.md`（add/add）：以 `main` 那份为底，本项按上面的「编号」约定占第 5 行，「收口」与「备注」各并进去；
  - `iterations/README.md`：§ 5 的 02 行取 `main` 那句（它已经把三组写进主题里），不留两行；
  - `rounds/BACKLOG-CLOSED.md`：两边追加的各三行都留，`main` 那三行在前。
- **`rounds/BACKLOG.md` 的计数 git 自动合并给错了**，与上一组遇到的是同一个坑：两边各自从 81 减，git 只留一边的数字。按合并后的真实条数重算——`main` 已到 P0 11 / P1 25 / 总计 79，本项再关 2 条（P0 1 + P1 1）、新开 1 条（P1 数据一致性的不采纳项）→ **P0 10、P1 24、会话身份与生命周期 4、数据一致性 6、总计 77**。改完用脚本逐档数过一遍 `- [ ]`，六个档位声明数与实际条数全部相符（上一组留的「代码质量（quality 批）」那条存疑也复核了，现在是 4 = 4）。
- 合并后在分支上重跑全量 `validate.ps1`：全绿（`flutter test` 417 项）。
- **反过来那一下**：分支已含 `main`，所以是**快进**——`main` 由 `eac3a91` 直接前进到 `7264fd5`，没有新的合并提交。合并前 `main` 工作副本干净（只有那个未跟踪的 `design/round-design/input/revision-04.md`，快进不碰它）；快进不改内容，树与刚验过的那份逐字节相同，未在 `main` 上重跑 validate。
- **主题重建那组还没合**（`claude/theme-font-partial-rebuild-471573`）：本文件与 `rounds/BACKLOG.md` 还会再冲突一次，计数照样要按真实条数重算，别取任一边。

### 第 6 项（主题重建，2026-09-22）


**根因一条**：同一个 widget 实例 → `Element.updateChild` 见 `child.widget == newWidget` 直接复用旧 element、不再 build，于是 build 里现取颜色 token 的代码根本没被重新执行。颜色 token 都是 getter、能每帧现取，出问题的只是「element 压根没重建」的地方。

**① 转录正文**（`lib/ui/transcript/markdown_body.dart`）：`_MarkdownBodyState` 把块 widget 实例缓存在 `_blocks`（有意为之：父级重建时子树不重建，recognizer 才不会随 build 反复登记），`didUpdateWidget` 只比 data / onLink / mermaidFontFamily / baseStyle，换主题这四个都没变。照 `files_panel.dart` 的 `_SourceView` 抄同一句：State 里记下算 `_blocks` 时的 `t.Fonts.generation`，`build()` 开头对不上就 `_rebuild()`。换字体与换主题都会推进这个代数（`tokens.dart` 的 `rebuildStyles()`），一个代数覆盖两件事。7 个调用点（assistant_text / content_blocks / plan_card / subagent_card / thinking_block / 文件面板 md 预览）一次都覆盖到，没一个传 `baseStyle`，所以 `didUpdateWidget` 那条路从来不会替它们重建。

**在 build 里调 `_links.disposeAll()` 安全吗——结论：安全，按原方案在 build 里重建，没有改成「标脏 + 下一帧」。** 三条依据：(a) 这不是新增的风险面——`didUpdateWidget` 那条路径每到一段流式 chunk 就 `disposeAll()` 一次，早就在跑；(b) 触发条件收得很紧：代数只由 `Fonts.apply` / `Theming.apply` 推进，而这两处的入口是侧栏标题条的主题开关与设置页的外观卡，那一下用户的指针在开关上、不在转录的链接上（启动时读盘落定那一次也走这条，但那是头几帧）；(c) 真撞上了也只是那一次点击被取消、不会挂：`OneSequenceGestureRecognizer.dispose()` 先 `resolve(GestureDisposition.rejected)`、再把 `_trackedPointers` 的路由摘掉，之后才 `assert(_entries.isEmpty)`。另外 `_rebuild()` 同帧就把新块返回给 `build()`，旧 recognizer 不会在渲染树里多活一帧。

**② `const` 叶子 widget**：按所有者裁定摘**构造函数声明**上的 `const`（不是逐处加 `// ignore: prefer_const_constructors`）——构造函数不再是 const，`dart fix` 与 lint 就回改不了调用点。代价是声明那一行要带 `// ignore: prefer_const_constructors_in_immutables`：这条 lint 会让 `dart fix` 把 `const` 加回构造函数、等于把修复整个撤销，所以这 10 个 ignore 是必须的，不是可省的装饰。备选「换主题时给 `home` 换 `ValueKey(theme)` 整树重建」按裁定不采用（丢滚动位置与焦点等瞬时态）。

**范围是重新扫出来的，比 BACKLOG 那份清单多六个。** 判据两条：在 `lib/ui` / `lib/app`（不含 `lib/gallery`）有 `const` 调用点，且 build 里读随主题走的 token（`Neutral` / `Accent` / `Semantic` / `Surface` / `Borders` / `Shadows` / `TextStyles` / `CardText` / `Overlays` / `FocusRing` / `SvgTint` / `Kbd` / `Spinner` / `Sweep` / `UnreadDot` / `Timeline` / `Fold` / `Badge`）。结果 10 个 widget、62 处调用点：

| widget | 声明 | 调用点 | 为什么算 |
|---|---|---|---|
| `ToneChip` | `card_chrome.dart` | 11 | `Semantic.*Soft` / `Neutral.surface` / `Accent.soft` |
| `Chevron` | `card_chrome.dart` | 9 | `Neutral.placeholder` |
| `SectionLabel` | `card_chrome.dart` | 4 | `TextStyles.label`（颜色烘在字阶里） |
| `MonoBlock` | `card_chrome.dart` | 1 | `Neutral.panel` + `CardText.code` |
| `Spinner` | `icons.dart` | 20 | `Spinner.color` = `Accent.base`，浅 `#5566D8` ↔ 深 `#8B96EC` |
| `AwaitingRow` | `awaiting_bar.dart` | 1 | `CardText.headerTitle`，里面还套着 `Spinner` |
| `FileViewerEmpty` | `files_panel.dart` | 3 | `Surface.canvas` / `Borders.base` / `TextStyles.*` |
| `_TreeNote` | `files_panel.dart` | 1 | `TextStyles.*` |
| `_Diamond` | `registry_entry.dart` | 2 | `Neutral.placeholder` |
| `AuthSucceededCard` | `auth_page.dart` | 2 | `Semantic.success` / `TextStyles.*` |

两种**隐式 const** 也一并摘（原清单没列，靠编译器暴露）：`thinking_block.dart` 的 `trailing: const <Widget>[Chevron(…)]` 两处、`files_panel.dart` 与 `gallery/boards/panel_boards.dart` 的 `const Expanded(child: FileViewerEmpty())`。

**没动的两类**，各有理由：
- 弹层里的 `MenuDivider` / `MenuGroupLabel` / `_TimelineEmpty`：所有者已裁定不在范围内（每次打开都新建 element）。
- 只在 `lib/gallery` 里写 `const` 的 14 个（`TopBar` / `SessionHeader` / `MentionMenu` / `NoAgentEmpty` / `AuthFailedCard` / `AuthMethodPicker` / `ManagedNodePrompt` / `SessionTimelinePopover` / `RunningBadge` / `BoardSection` / `ComposerRunning` / `TokensBoard` / `_ButtonSample` / `_Kbd`）：gallery 全程不调 `Theming.apply`（`loadGalleryFonts` 只往引擎里注册 family，不碰 `Fonts.apply`），一张画板只渲染一次，撞不上这个 bug；摘了反而白丢 const 的好处。

**回归用例**：`test/ui/theme_rebuild_test.dart`，5 条，**全部先验证过「退回修复即红」**（修复前 5 红、修复后 5 绿）。关键是一律从**真实调用点**渲染——在测试里自己 `ToneChip(...)` 新造一个实例测不出来，新实例本来就会重建、退回修复也不会红。覆盖：`MarkdownBody`（正文字色 + 行内代码底色）、`RegistryEntryRow` → `ToneChip` + `_Diamond`、`CollapseBar` → `Chevron`、`AwaitingRow` → `Spinner`、`FilesPanel` → `FileViewerEmpty`。

**验证**
- `powershell -File scripts/validate.ps1` 全绿（16 道门；`flutter test` 408 项，新增 5 项）。首跑只挂在 `fetch-upstream -Check`，是 worktree 的 `vendor/upstream` 是空目录——按惯例换成指向主副本的目录联接（`mklink /J`）后全绿，与本次改动无关。
- `flutter analyze`：16 条 info 全是既有的（4 条在 `lib/gallery`、12 条在 `test/`），本次改动一条不增；0 error / 0 warning。
- **画板对照**：在 `022079b` 上开一个临时 worktree 渲染同一批画板，与本分支的 `build/gallery/` **45 张 PNG 逐字节一致**（`md5sum` 全等）。摘 `const` 不改变任何单次渲染的输出，`Fonts.generation` 那一句在 gallery 里是恒假分支。
- 手测：**未构建**（本组只动 `lib/ui` 与测试，随迭代收口时统一构建手测；手测项＝浅→深→浅看 registry 徽章 / 设置页徽章 / 工具卡 Canceled 徽章 / 各处 chevron / 文件面板空态 / spinner / 整段对话正文，全部不 reload 会话就跟着变）。

**审查**：1 轮，cursor CLI（`grok-4.7-high-fast`，未回落），范围 `main...HEAD` = `022079b..a4ba7e7`，**0 条 findings**，无整改故不复审（`iterations/README.md` § 2 第 4 条）。产物 `.claude/reviews/20260922-182343-review.out.md`。审查器另行确认了两点我没写进注释的：`Theming.apply` / `Fonts.apply` 推进代数发生在根 `ListenableBuilder` 重建**之前**；`didUpdateWidget` 已因输入变化 `_rebuild()` 过时代数已是当前值，同一帧不会再拆一次链接。

**与设计稿的关系**：这次是把实现改回画板 07 定义的深色表现，不是偏离，**不记** `design/DIVERGENCE.md`。

**风扇狂转（第 7 项）的实测（2026-09-22，Windows 11，规则 9）**

- 现象：安装版 `D:\tools\AcpAgentClient\acp_agent_client.exe`（PID 37236，打开的项目 `D:\variFlight_work\VariFlightWork`，61001 个文件）GPU 3D 引擎 44–64%（另一会话先测到 64%；本会话 `Get-Counter '\GPU Engine(*)\Utilization Percentage'` 抓到一次 44%，其余采样 1.2–1.8%），CPU 不高。不是 WebView（这个应用没有 WebView）。
- 闭环证据：① `Get-CimInstance Win32_Process -Filter "ParentProcessId=37236 AND Name='git.exe'"` 轮询：12 秒 24 个、20 秒 54 个、15 秒 96 个 `git.exe`，命令构成 `rev-parse --is-inside-work-tree` / `rev-parse --show-toplevel` / `status --porcelain` 三者数量相当（= `git_status` 的三个子进程，`refreshBadges` 在空转，不是 `git_branches`）；② 同期仓库工作区**零文件改动**（`Get-ChildItem -Recurse` 前后快照，8 秒与 10 分钟两档均为 0）；③ `System.IO.FileSystemWatcher` 挂在 `.git` 上 8 秒抓 46 条事件，**全部**是 `index.lock` 的 Created / Deleted；④ 25ms 高频探测 400 次采样有 5 次抓到 `index.lock` 存在、`.git/index` 的 mtime 0 次变化（前后快照法查不出锁文件，所以最初漏判）；`core.fsmonitor` / `core.untrackedCache` 均未设（`.git/fsmonitor--daemon` 目录是残留）。
- 单测揭示的第二条路径：合成建删 `index.lock` 的测试在只滤 `*.lock` 时仍 `git: true`——Windows 的 ReadDirectoryChangesW 在目录里建删文件时会给 **`.git` 目录本身**报一条 Modified（③ 挂在 `.git` 上看不到它自己的事件，所以没抓到）；生产环境同样如此，光滤锁文件循环照样闭合。`classify` 两条都跳过；`.git/HEAD` 写入与 `index.lock → index` 的改名仍打标志（测试断言）。
- 审查第 1 轮（cursor `grok-4.7-high-fast`，`022079b..d3774c6`）1 条 high，采纳：有子模块时 `git status` 递归进子仓库、在 `.git/modules/<name>/` 建删锁，Windows 给**那个目录**报的 Modified 最后一段是子模块名不是 `.git`，「只认目录自身等于 `.git`」盖不住，循环重新闭合。整改按它给的最小修复：`.git` 之下凡是**目录**身上的事件都跳过——`fold` 现查 `path.is_dir()` 传给 `classify`（纯函数仍可拿假路径单测；已删掉的目录查不到会当文件打一次标志，多刷一回徽章无妨）。合成测试加 `.git/modules/sub/` 的锁；真 git 测试真的加一个本地子模块（`-c protocol.file.allow=always submodule add`），racy 等待挪到子模块检出之后。
- 审查第 2 轮（cursor，`d3774c6..50ad95d`）0 条：确认目录事件与锁都进 `Ignored`、文件路径（含 `.git/modules/<name>/HEAD`）仍打标志，删目录时当文件多刷一回可接受，真 git 测试的隔离够用。第一次发起时 cursor 与服务端连接中断两次后 `Agent turn stopped`、`.out.md` 未写出（硬失败），同执行器重试一次成功，未回落。整改后完整 validate 重跑全绿。
- 真 git 测试的 racy 坑：刚写的文件与索引落在同一秒时 git 每次 `status` 都补写索引（真变化，照常打标志）直到时钟跨秒，测试三跑两挂；让文件比索引老 1.1 秒后连跑五轮稳定。
- GPU 一侧：`lib/` 里 `RepaintBoundary` 出现 0 次（全仓 6 处都在 `test/`）；显示器 2880×1800 @ 120Hz、Radeon 780M 核显。机制成立，但爆发当下没抓到对应的 UI 状态，效果要构建后手测（会话运行中看 GPU 引擎占用）。
- 立刻止血的办法：把项目从那个 6 万文件的仓库切走或关掉应用；git 风暴与会话是否在跑无关。
