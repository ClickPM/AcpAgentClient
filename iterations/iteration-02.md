# Iteration 02 — BACKLOG 收尾：会话索引 / 输入框 / 主题重建三组

<!-- 一个迭代一个文件、一项一行；流程正本见 iterations/README.md。 -->

> 状态：进行中　起止：2026-09-22 –　基线：`main` = `022079b`

三组并行开工（各自 worktree 分支），都从 `iteration-01.md` 的「A. 可直接开工」清单里圈定。

## 工作项

<!-- 类型：fix 缺陷 / ux 交互 / tidy 工程收尾 / board 单画板（设计稿先入库）。
     状态：待开工 / 进行中 / 待审查 / 待合并 / 已合并 / 移出（写去向）。
     验证：validate 全绿 / validate -Quick / 未构建（所有者指定）。
     审查：<轮数> 轮，<条数>（high n / P2 n / P3 n）；或 未审查（所有者指定）。 -->

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | fix | 会话索引（`sessions.json`）写回取错源的三处同根因缺陷：① `SessionIndex.upsert` 的标题退回索引里已有的（含会话头 `sessionTitle` 那一半）；② `saveIndex` 收一个 `SessionStore`，收轮时由 `TurnController._runTurn` 传刚跑完那条；③ `session/list` 校对的 cwd 过滤改走 `WorkspaceState.normalizeCwd` | BACKLOG「会话身份与生命周期」1 条 +「数据一致性」2 条（iteration-01 候选 A 的 13 / 14 / 15） | `claude/session-index-write-bugs-3c53b0` → 待合并 | validate 全绿 | 2 轮，2 条（high 1 / P2 1）→ 0 high | 待合并 |

## 收口

- 构建 / 手测：待填
- 发版：待定
- 移出项去向：—
- 设计稿补注记：第 1 项无（三处都是写回取错源的缺陷，界面按画板本来就该显示真标题与真计数）

## 备注

### 第 1 项 · 三条是同一个根因

三条都是「写回索引时取了错的源」：标题取了会话头的占位串、收轮取了当前选中的 store、校对取了没归一的 cwd 原串。核心侧的 `upsert` 是**整行替换**（`rust/settings/src/index.rs`），所以取错源不是少写一格，而是把索引里对的那格盖掉。

改动只在三个文件：`lib/app/session_index.dart`、`lib/app/session_controller.dart`、`lib/app/turn_controller.dart`。契约零 diff（不加桥命令、不改 `_meta` 键、不动 `docs/design.md` § 3 / § 4），不新增依赖，`lib/theme/tokens.dart` 与画板 widget 零 diff。

**① 标题三级退回 `store → 索引 → 占位串`。** `SessionIndex.upsert` 原来是 `s.title ?? titleFallback`，中间插一层新加的 `SessionIndex.titleOf(sessionId)`（非空才算有）。改名与 agent 的 `session_info_update.title` 都先写进 `store.title`，第一级就命中，所以这层退回不会把用户改过的名字搞反——补了一条用例钉住这点。

**会话头那一半也做了**（BACKLOG 的产品行本来就写着「会话头也一样」）：`SessionController.sessionTitle` 同样退回索引标题。三个分支逐个看过：`!hasAgent` 仍是 `No Agent`；`sessionId == null`（真的新会话、启动后还没开会话）查不到条目，仍是占位串——两条既有用例 `sessionTitle == 'No Agent'` 与 `'New Zed Agent Session'` 原样通过；只有「选中了一条会话、但 store 上没有标题」这一种情况变了，那正是要修的。

**② `saveIndex({SessionStore? target})`。** 缺省仍是 `store`；`_runTurn` 收轮时传它手里的 `s`。另外三个调用点保持「当前会话」语义、未改：`createSession` / `adoptAuthSession`（都紧跟 `_adoptSession`，新会话此刻就是当前会话）、`stampPromptSent`（`send()` 里 `s` 与 `store` 同一个对象）。

顺带把 `titleFallback` 从 `sessionTitle` 改成按**传进来那条会话自己的 agent** 算的占位串（新的 `placeholderTitleOf` / `agentDisplayNameOf`，后者是既有 `agentDisplayName` getter 的参数化版本）：不改的话，给后台那条写索引时会把前台那条的标题写到它头上——这是引入 `target` 参数**带出来的**新缺陷，属于本项该一起了结的，不是顺手改。

**③ 校对的 cwd 比法。** `reconcileSessions` 里 `entry['cwd'] != scope` 换成两边都过 `WorkspaceState.normalizeCwd` 再比。**过滤本身留着**（那句注释记的是 2026-09-16 dsh 实测「21 条全被误标」的教训），`entry['cwd']` 不是 String（没记 cwd 的老条目）时**照旧跳过**——这一条只换比法，不放宽过滤。

### 第 1 项 · 验证

- `flutter test test/app/session_order_test.dart test/app/session_lifecycle_wiring_test.dart`：35 项全绿。
- **三条各补一条可证伪的回归用例**，并逐一验证过「把 `lib/app/` 那三个文件还原成 `main` 的版本后这三条必红」：
  - `test/app/session_lifecycle_wiring_test.dart`「载回来的会话再聊一句…」——索引里已有 `My Session`、`session/load` 不重放 `session_info`，聊一句之后索引仍是 `My Session`（还原后实得 `New a Session`），会话头同样；
  - `test/app/session_order_test.dart`「后台跑完那一轮刷的是它自己那条…」——A 选中、B 后台收轮，之后 B 的 `messageCount` 是 1、A 的仍是 3（还原后 A 被刷成 0）；
  - `test/app/session_lifecycle_wiring_test.dart`「cwd 只差写法的条目照常参与校对」——索引条目 cwd 写成 `D:\repo\`、当前项目是 `D:/repo`，校对照常补标题（还原后实得没补），agent 侧真没有了时也照常进 `missingOnAgent`。
  - 另加一条护栏用例「agent 补的标题照常盖过索引」（store 上有标题时不退回索引），它在改动前后都绿，防的是以后把三级退回的顺序改反。
- 这台机器上 `scripts/validate.ps1` 的结果见下面的「Windows 实测」段。

### 第 1 项 · 代码审查

**第 1 轮**（`cursor-review.ps1 -Scope branch -Wait`，`main...HEAD`，产物 `.claude/reviews/20260922-181509-review.out.md`）：2 条（high 1 / P2 1）。

- **[high] 删掉仍在跑的会话后，收轮仍会把这条写回索引** — **采纳整改**。验真属实，而且是本次改动**引入**的：`deleteSession` 不发 `session/cancel`，在途那一轮照样会收，而收轮那次 `saveIndex` 手里握着的是开轮时那个 `SessionStore`；改之前它读 `store`（`sessionId` 已被 `deleteSession` 置空、`sessions.forget` 也已经把它拿掉），自己就挡住了。整改是 `saveIndex` 加一句判断：会话表里那个 id 底下不是同一个 store 就不写（`!identical(sessions.maybe(s.sessionId), s)`）——顺带覆盖「删掉再新建同 id 会话」被迟到的写盖成旧值那一档。补了回归用例「删掉正在跑的会话：那一轮收轮时不把它写回索引」，同样验证过去掉这句判断后必红。
- **[P2] agent 把标题清成 null 之后，下一笔写回会从索引把旧标题填回去** — **不采纳**，已记 `rounds/BACKLOG.md`「数据一致性」。理由：`store.title == null` 的两种含义（载回来还不知道 / agent 显式清空）要分清，得在 `SessionStore` 上记一个「`hasTitle` 曾经为真」的新状态，属投影层的新机制，按审查边界非严重 finding 不许；复审给的最小修复「清空时把 `store.title` 写成空串」违反规则 2（协议给的是 null，不自造值），改用 `seen['session_info_update']` 当判据也不成立——只带 `updatedAt` 不带 `title` 的更新也会计数，会把本轮修掉的那个缺陷放回来。本项目接的五个 agent 没有一个会清空标题。

**第 2 轮**（`-Scope since -Base <第 1 轮已审提交>`）：见下方回填。

### 第 1 项 · Windows 实测（规则 9）

本轮不涉及子进程拉起。worktree 第一步的 `scripts/fetch-upstream.ps1 -Check` 九条全绿（`vendor/upstream` 按惯例用目录联接指向主副本）。
