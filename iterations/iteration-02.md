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

## 收口

- 构建 / 手测：第 1 项已随 release worktree 出包并镜像到 `D:\tools\AcpAgentClient`（2026-09-22 16:48，五处哈希双边一致、安装目录 smoke `ok: true` / `coreVersion 1.4.1`）；**第 2 / 3 / 4 项尚未构建**（第 3 / 4 项的手测项：`+` → Image 挑一张 > 20 MB 的图、敲 `@` 后立刻改词）。
- 发版：不发（版本号仍 1.4.1，不打 tag、不推 GitHub、不发 release）。
- 移出项去向：—
- 设计稿补注记：第 1 项**直接改了画板 08 / 70 的源并重出 PNG**（规则变更写进画板更干净）；第 2 项走 `design/DIVERGENCE.md` A-16（画板没画「重放回来的历史怎么折」，按规则 3 不要求补稿）；第 3 / 4 项都不改画板（大小门的提示文案走既有的 `lastError`，菜单行为回到画板 42 本来画的样子），无偏离可记。

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


**编号**：合入 `main` 后已定下——第 1 / 2 项是 `main` 直改的两条回合折叠口径，本组（输入框）占 3 / 4；另两组合入时往后排。

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
