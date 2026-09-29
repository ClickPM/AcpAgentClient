# Iteration 20 — 去 Claude Code 绑定：AGENTS.md 升为正本、审查执行器改「硬失败喊人」、内联上一代的记忆库

> 状态：已收口　起止：2026-09-29 – 2026-09-29　基线：`main` = `1421394`　收口提交：`f752859`

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | tidy | **规范正本从 `CLAUDE.md` 迁到 `AGENTS.md`**（内容整份搬过去，`CLAUDE.md` 退成指针）：本仓库后续开发不绑定某一个 agent，`AGENTS.md` 是 Codex / Cursor / DSH / pi / Zed 原生就读的跨 agent 约定文件 | 所有者 2026-09-29 | 直接 `main` → `f752859` | validate -Quick 全绿 | 未审查（tidy，所有者未指定走审查） | 已合并 |
| 2 | tidy | **审查执行器收窄为「cursor 硬失败就停下喊人」**：不再自动回落子代理；只有所有者点名才换执行器，且必须只读 + 模型独立于主会话。同步改 `AGENTS.md`「开发模式」、`docs/review-workflow.md` § 0/§ 2/§ 3、`rounds/TEMPLATE.md`、`iterations/README.md` | 所有者 2026-09-29 | 同上 | 同上 | 同上 | 已合并 |
| 3 | tidy | **把上一代 agent 的项目私有记忆整批内联入库**（原 `~/.claude/projects/D--variFlight-work-AcpAgentClient/memory/`，34 份 + 索引）→ 新建 `docs/agent-notes/`（README 索引 + 8 份主题册 + 1 份执行器专属坑），从此以仓库里这份为正本 | 所有者 2026-09-29（「对原先 Claude code 针对本项目生成的记忆文件进行挖掘，并以内联式方式引用到本项目中来」） | 同上 | 同上 | 同上 | 已合并 |
| 4 | tidy | 引用改写：`CLAUDE.md` → `AGENTS.md` 的**活引用**（代码注释、脚本、现行文档，53 文件 / 83 处）；历史记录（已收口轮次卡、`BACKLOG-CLOSED`、迭代文件、`ROUNDS.md` § 2–§ 7 拆解与进度表、画板源、fixtures、gallery widget）**原样保留**，在 `AGENTS.md` / `CLAUDE.md` / `ROUNDS.md` 顶部加历史别名映射 | 所有者 2026-09-29 裁定「只改活引用 + 别名映射」 | 同上 | 同上 | 同上 | 已合并 |

## 收口

- 构建 / 手测：本次只动文档与代码注释，未改任何 Rust / Dart 逻辑，按 `iterations/README.md` § 2 第 3 条走 `validate -Quick`（**全绿**），另单跑 `flutter test test/ui/markdown_incremental_test.dart`（**8 项全过**，它改读了 `AGENTS.md`）；不做 release 构建（**未构建**）。
- 发版：不发（不抬版本号）。
- 移出项去向：无。
- 设计稿补注记：无（没有实现先行的功能；`design/` 与 `lib/gallery/` 里的 mock 文案一个字未动，PNG 基准不受影响）。

## 备注

### 三项所有者裁定（2026-09-29，按推荐项）

1. **AGENTS.md 升为正本，CLAUDE.md 退成 3 行指针**（不是删掉 CLAUDE.md）：Claude Code 仍自动读到规范，其他 agent 原生读 `AGENTS.md`；`lib/app/workspace_state.dart` 的 `ruleFileNames` 保持三名，画板 30 / 40 的 Rules 计数（= 2）与产品行为不变 —— 删掉 `CLAUDE.md` 会让计数变成 1，那是画板能看见的行为变化，按规则 3 得先改设计稿重渲 PNG。
2. **记忆内联到 `docs/agent-notes/`**（README 索引 + 按主题成册 + 执行器专属的坑单独一份），不塞进 `AGENTS.md` 正本（会把主线流程淹掉），不合成单一巨文件。
3. **只改「活」引用，历史记录原样保留**，并在 `AGENTS.md` 顶部写明别名：历史记录里的「CLAUDE.md 规则 N」= 本文「规则 N」。
4. 追加裁定（他回答 item 4 时给的）：**cursor 不可用时中断喊人，不随便回落其他子代理** —— 这条改的是 `AGENTS.md` 的「审查执行器」②，把原来的「硬失败 → 自动回落 Claude Code 只读子代理」收窄成「硬失败 → 停下等所有者指示」；审查的**范围口径 / 收口标准 / 审查边界一字未动**（所有者说的「review 流程保持现状」指这三块）。

### 没有做的（item 4 的其余候选，所有者未选）

- 没在 `AGENTS.md` 顶部加「新 agent 30 秒上手」入口段（裁定 B）—— 别名映射那一条按裁定 3 已加。
- 没给 `validate.ps1` 加「单份正本门」（裁定 C，防 `CLAUDE.md` 又被写胖）。
- 没加 `GEMINI.md` / `.cursor/rules` / `.github/copilot-instructions.md` 这类 1 行指针（裁定 D）。
- 没在 `scripts/` 加 agent 中立的 review 转调入口（裁定 E）：`.claude/cursor-review.ps1` 路径不动，改在 `AGENTS.md` 仓库结构里注明「目录名是历史遗留，审查流程本身是 agent 中立的」。

以上四项如需要，随时可以补做。

### 编号

开工前按 `iterations/README.md` § 1 扫了三处：`main` 上到 iteration-18、分支 `claude/iter-19-session-suspend` 占了 19、其余 worktree 无未提交的 `iterations/iteration-*.md` → 取 **iteration-20**。`design/DIVERGENCE.md` 最大号为 37，本次不新增偏离条目。

### 改写的范围（可核）

- **正本**：`AGENTS.md`（新，全文 111 行 → 规范正本 + 别名 + agent-notes 指引 + 审查执行器新口径）；`CLAUDE.md`（111 行 → 15 行指针）。
- **新增**：`docs/agent-notes/` 共 10 个文件（README + `build-and-cache` / `flutter-and-windows` / `git-and-parallel-sessions` / `review-runbook` / `release-pipeline` / `runtime-and-debugging` / `upstream-and-design` / `owner-rulings` / `harness-pitfalls`）。
- **机械改名**（`CLAUDE.md` → `AGENTS.md`，48 文件）：`analysis_options.yaml`、`cargokit/cmake/cargokit.cmake`、`docs/{acp-projection,background,design,research,zed-agent}.md`、`lib/app/{clipboard_image,files_state,local_terminals,workbench_controller,workbench_screen}.dart`、`lib/theme/tokens.dart`、`lib/ui/{files,shell}/*.dart`、`packaging/windows/acp-agent-client.iss`、`prototype/README.md`、`pubspec.yaml`、`rounds/{BACKLOG,README}.md`、`rust-toolchain.toml`、`rust/**`、`scripts/validate.ps1`、`test/**`。BOM 逐个保留（`validate.ps1` 改后仍是 `ef bb bf`）。
- **整句改写**（不只是改名）：`README.md` / `README.en.md` 的文档表与「本地开发」指引、`docs/review-workflow.md`（标题 / § 0 执行器表 / § 2 / § 3 / 坑清单第 6–8 条）、`.claude/cursor-review-prompt.md` 开头、`rounds/TEMPLATE.md`「代码审查」段、`iterations/README.md`（§ 2 分支与审查两处）、`ROUNDS.md` 头部、`design/README.md`、`design/DIVERGENCE.md`、`lib/app/workspace_state.dart` 的注释。
- **一个字未动**（有意）：`design/round-design/**`（画板源与设计输入，改了要重渲 PNG）、`lib/gallery/boards/**`（画板 widget，规则 3）、`test/fixtures/**`（三处共用的线上行夹具）、`test/app/workbench_wiring_test.dart`（mock 目录清单）、`prototype/index.html`（不维护的原型）、已收口的 `rounds/round-*/**` 与 `rounds/BACKLOG-CLOSED.md`、`iterations/iteration-0*.md`、`ROUNDS.md` § 2–§ 7 的拆解与进度表。
