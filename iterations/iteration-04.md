# Iteration 04 — BACKLOG P5「内部工程与验收」整档收尾

<!-- 保存为 iterations/iteration-NN.md。一个迭代一个文件、一项一行；流程正本见 iterations/README.md，不在这里复述。 -->

> 状态：进行中　起止：2026-09-23 –　基线：`main` = `2a7c2e9`

所有者 2026-09-23 裁定 P5 整档 16 条按推荐方式关闭：9 条直接按裁定关（不做 / 不修 / 并入 P0），7 条改完代码再关。
全部在 worktree 分支 `claude/close-backlog-p5` 上做（`main` 上同时有别的会话在改）。

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | tidy | 环境缺失的测试一律判红、不再跳过：`rust/fs` 的 git 三处（`git.rs`）+ `watch.rs` 一处（BACKLOG 原文漏记）、`resolve_inside` 的文件符号链接那半边（`lib.rs`）、`rust/pty` 的 `npm.cmd`（原文漏记）、`rust/registry` 的系统 Node（用例改名 `system_node_is_detected`） | BACKLOG P5「测试与代码健康」第 3 条 | `claude/close-backlog-p5` | validate 全绿 | | 待审查 |
| 2 | tidy | `junctions_are_not_followed_out_of_the_workspace` 在 `mklink /J` 失败时判红 | BACKLOG P5「测试与代码健康」第 1 条 | 同上 | validate 全绿 | | 待审查 |
| 3 | tidy | validate 的 `_meta` 契约门按整词 `\b_meta\b` 扫，`symlink_metadata` / `terminal_exit_meta` 这类标识符不再连坐；`rust/fs/src/lib.rs` 当初为绕门拆开的那两行并回一行 | BACKLOG P5「测试与代码健康」第 4 条 | 同上 | validate 全绿 | | 待审查 |
| 4 | tidy | `MotionEnter`：`didUpdateWidget` 比 `duration` / `delay`，同步 `_controller.duration` 与 `_enter.curve`；两者都为零时 Interval 起点取 0（不再 `0 / 0`）；新增 `test/ui/motion_enter_test.dart` 3 条 | BACKLOG P5「测试与代码健康」第 2 条 | 同上 | validate 全绿 | | 待审查 |
| 5 | tidy | `FilesState` / `LocalTerminals` / `AppearanceController` 混入 `GuardedNotifier`，连同核对时发现的第四个 `TranscriptFolds`；mixin 加一个 `logTag`（文件面板 / 本地终端的日志前缀照旧是 `[files]` / `[terminals]`） | BACKLOG P5「R7.5 收尾」第 1 条 | 同上 | validate 全绿 | | 待审查 |
| 6 | tidy | gallery 五个 boards 文件的重复 helper 收拢到 `lib/gallery/boards/board_helpers.dart`（`boardText` / `windowBoard` / `pageBoard` / `fixtureAgentTitle` / `fixtureSessionTitle` / `boardComposerOptions`）；`design/DIVERGENCE.md` 第 11 条里点名的函数名跟着改 | BACKLOG P5「代码质量」第 3 条 | 同上 | validate 全绿 | | 待审查 |
| 7 | tidy | 五处自带 hover 的 widget 并到 `Hoverable`：`AcpButton`（按下态留在按钮里）、`ColumnSplitter`（拖拽态留在把手里）、`_PathChip`、`MentionChip`、`AttachmentChip`；`Hoverable` 加一个可选的 `onHoverChanged`（路径芯片要让卡片放开裁剪、附件芯片要开关预览浮层）。`hoveredInitially` 实际语义就是 `forceHover`（移出时回到它，给 true 就一直悬浮），直接映射过去；新增 `test/ui/hoverable_test.dart` 2 条 | BACKLOG P5「代码质量」第 4 条 | 同上 | validate 全绿 | | 待审查 |
| 8 | tidy | 其余 9 条按所有者裁定关闭、不改代码：行数门维持放宽、按区域订阅不做、权限范围下拉视为已实测、GUI 点击类验收留给手测、几何不变量断言不做、gallery 像素对比不做、桥四层转发不做、`appearance_prefs` 样板不做；「headless 报告的 lastError」并入 P0「失败没有出口」那条 | BACKLOG P5 其余 9 条；所有者裁定 2026-09-23 | 同上 | 只改文档 | 随本迭代一并审 | 待审查 |

## 收口

- 构建 / 手测：
- 发版：—
- 移出项去向：—
- 设计稿补注记：无新增偏离；第 6 项只改了 `design/DIVERGENCE.md` 第 11 条里的函数名。

## 备注

### 验证

- `powershell -File scripts/validate.ps1 -CargoTargetDir D:\cargo-target\AcpAgentClient-close-p5`（改了 `rust/`，按共用 target 串代码那条教训用独立目录）：**VALIDATE OK**。`cargo test` 105 条全过（改成判红的那几条在本机都有 git / Node / 开发者模式，照常绿）；`flutter test` 435 条全过（新增 `motion_enter_test.dart` 3 条、`hoverable_test.dart` 2 条）；`flutter analyze` 的 16 条 info 与基线逐条相同，无新增。
- 第一次全量红了一条：`composer_attachments_test.dart`「× 把那一块去掉」按「芯片里唯一的 `Hoverable`」找 ×，芯片外层也改走 `Hoverable` 之后撞出两个；改成按 × 图标（`AcpIcons.x`）找，行为断言不变。
- 第 3 项：`\b_meta\b` 用六条样本行验过——`json!({"_meta": {"foo": 1}})`、`obj["_meta"]["bar"]`、`x._meta.get("baz")` 照拦；`symlink_metadata(...).expect("...")`、`terminal_exit_meta(...); let s = "x";`、只有 `obj["_meta"]` 没有别的字面量的行不拦。并回一行的 `symlink_metadata` 那行旧门会拦、新门放行，validate 的这一步是 PASS。
- 第 4 项反证：临时换回旧的 `motion.dart`，新用例前两条红（时长 / 延迟变了仍按旧参数播完），换回后绿。零时长那条在旧代码上也绿：值只会是 0 或 1，Interval 的断言碰不到——真正会走到 NaN 的是本项改成「曲线可变」之后「播到一半切成零」这条路，所以守卫是这次改动自己需要的。

### 没改的

- `sidecar/zed-agent-acp/src/translate.rs` 的 `terminal_exit_meta_omits_absent_fields` 里有一段「id 先绑到变量」的绕门写法，第 3 项之后已不需要；sidecar 的问题当前不修（`rounds/BACKLOG-ZED.md`），validate 也不编 sidecar，没动。
