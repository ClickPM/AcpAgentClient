# Round 03 — 会话工作台壳与接线

<!-- 保存为 rounds/round-03/round-03.md；该轮其他管理产出放同一目录。 -->

> 状态：进行中

## 目标

按画板 01–04 / 40 / 41 / 42 / 80 落地完整会话工作台壳（三栏、线程头、输入框与三类弹层、顶栏项目与分支切换、窗口控制、流量面板），
画板阶段收口后把 R1 的 Rust 核心接上：`lib/app/` 组合根默认 bridge 数据源，用 dsh-acp-interactive 在 Windows 真跑一轮完整对话
（权限 / elicitation / 计划 / 回合结束 / 中途停止 / 重载 agent），画板 34 接 `acp/agent_state` 真事件。

可证伪：ROUNDS.md § 3 R3 的 8 条验收要点逐条有命令与输出；`git diff <画板阶段收口提交>..HEAD -- lib/theme lib/ui` 为空。

## 前置

- 轮次：R1（Rust 核心主线）已完成（`5466609`）、R2（转录卡片与投影层）已完成（`050003a`，画板阶段收口 `98e4cea`）。
- `powershell -File scripts/fetch-upstream.ps1 -Check` 全绿（2026-09-15，8 个钉版本全 OK）。
- 本机版本（实测记录）：

  | 组件 | 版本 / 路径 |
  |---|---|
  | Flutter | 3.47.4 stable（framework 9584c6713b，Dart 3.13.3） |
  | Rust | rustc 1.98.1 / cargo 1.98.1（`rust-toolchain.toml` 钉 1.98.1） |
  | Node | v24.11.1 |
  | flutter_rust_bridge_codegen | `C:\Users\Click\.cargo\bin\flutter_rust_bridge_codegen.exe` |
  | dsh-acp-interactive | 1.3.0，`C:\Users\Click\AppData\Roaming\npm\dsh-acp-interactive.cmd` |
  | `CARGO_TARGET_DIR` | `D:\cargo-target\AcpAgentClient` |

- 参照 agent：dsh-acp-interactive（真跑）；`test/fake-agent/fake-agent.mjs`（注入 `notice` 验丢弃告警）。

## 交付物

### 裁定 6 的 token 提交（画板阶段之前，纯 token）

- `lib/theme/tokens.dart` 新增 `Geometry` 一组，收 R2 记 BACKLOG 的 7 个局部几何常量（画板 32 预览高 220、音频进度条高 3、
  画板 25 下拉宽 330、画板 30 弹层宽 266、终端回滚 2000 行、spinner 周期 = `Motion.base × 5`、布尔开关轨道 28 × 16）；
  `lib/ui/transcript/{content_blocks,permission_card,context_window,terminal_card,icons,elicitation_form_card}.dart` 只换引用。

### 画板阶段（只用 fixtures / 本地假数据）

- `lib/ui/shell/app_shell.dart`（01 / 02 / 03 三栏壳与窗口控制条）
- `lib/ui/shell/sidebar.dart`（01 / 04：搜索、会话项四态、行内重命名、底部导航、空态）
- `lib/ui/shell/topbar.dart`（01–04：侧栏开关、项目名、分支名、窗口控制三键）
- `lib/ui/shell/thread_header.dart`（01 / 02 / 03：标题、四个动作按能力裁剪）
- `lib/ui/shell/composer.dart`（01 / 02 / 03：占位文案、`+`、用量圆环、三个下拉、发送 / 停止、Awaiting 停靠条）
- `lib/ui/shell/transcript_empty.dart`（01 两个空态）
- `lib/ui/shell/right_panel.dart`（03 右栏占位；标签条 + 关闭）
- `lib/ui/popovers/composer_popovers.dart`（40：模型选择器 / 思考强度 / 模式 / 布尔开关 / 未知分类兜底 / `+` 弹层 / 用量弹层 / Follow 提示）
- `lib/ui/popovers/topbar_popovers.dart`（41：项目切换 / 分支切换 / 新建会话选 agent / ≡ 菜单 / 重命名 / 删除确认）
- `lib/ui/popovers/inline_menus.dart`（42：`@` 提及菜单 / `/` 命令菜单）
- `lib/ui/traffic/traffic_page.dart`（80：过滤条、告警行、流量行与原文展开、stderr 尾巴区）
- `lib/gallery/boards/shell_boards.dart`：01a / 01b / 02 / 03 / 04 / 40 / 41 / 42 / 80 九张 gallery 画板

### 接线阶段（只换数据源；`lib/theme` 与 `lib/ui` 零 diff）

- `lib/app/app.dart` / `workbench.dart` / `data_source.dart` / `session_index.dart` / `projects.dart` / `rules.dart`：组合根，
  默认 bridge，`--dart-define=DATA_SOURCE=fixtures` 供 gallery 与开发；`SmokeScreen` 换成工作台壳（`scripts/build.ps1 -Smoke` 仍过）。
- `rust/bridge/src/api.rs` 新命令：`workspace_recent` / `workspace_open`、`git_branches` / `git_switch` / `git_create_branch` / `git_diff`、
  `session_index_list` / `session_index_upsert` / `session_index_remove`、`fs_list_dir` / `fs_search`；`flutter_rust_bridge_codegen generate` 生成物入库。
- `rust/fs/src/lib.rs`：`list_dir` / `search` 最小实现 + `git` CLI 薄封装（`rust/fs/src/git.rs`）。
- `rust/index`（并入 `rust/settings`）：`sessions.json` / `projects.json` 本地索引，临时文件 + rename。
- `rust/acp-core/tests/fixtures.rs` 方法表补 `elicitation/complete` / `$/cancel_request`；`test/fixtures/16-elicitation.jsonl` 收两条通知。
- `windows/runner/`：`WM_NCHITTEST` 拖拽区 + 最小化 / 最大化 / 关闭三个方法的平台通道。

## 验收

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | 画板逐张对照 | `flutter test test/gallery_test.dart` → `build/gallery/{01a,01b,02,03,04,40,41,42,34,80}*.png` 与 `design/round-design/*.png` 文案 / 状态 / 层级 / 控件零缺失，偏离逐条记卡 |
| 2 | 接线不改样式 | `git diff <画板阶段收口提交>..HEAD -- lib/theme lib/ui` 输出为空 |
| 3 | dsh 真跑（规则 9） | 新会话 → 一轮含权限（Alt-Shift-A / Alt-Shift-X / Ctrl-Alt-A）→ elicitation form 提交 → 计划卡折叠 / 展开 → 回合结束行 → 第二轮中途停止（挂起权限回 cancelled）→ 重载 agent；改一个 config option 后弹层与线程头同步刷新 |
| 4 | 流量面板 | 同一轮行数与 `acp-smoke` 一致；`Authorization` / `api_key` / `token` 打码；fake-agent 注入 `notice` 后 34 与 80 的告警同时出现 |
| 5 | 项目与分支 | 切项目后新会话 cwd 正确；分支列表与 `git branch` 一致；新建分支后顶栏立即更新；非 git 目录分支区隐藏 |
| 6 | agent 生命周期 | `taskkill` 杀掉 agent → 34 出 exited 条 + 重启可用；应用不崩 |
| 7 | 空态 | 无已安装 agent 时显示 01 状态 2；「打开 Agents 面板」切到右栏 Agents 标签（R5 前空面板占位） |
| 8 | Windows 实测 | 窗口控制（拖拽 / 三键）、`file_selector` 目录与文件选择、git 子进程（路径带空格与中文） |
| 9 | 门禁 | `powershell -File scripts/validate.ps1` 全绿；投影层已有 80 个测试不回归；`scripts/build.ps1 -Smoke` 通过 |
| 10 | Restore / Regenerate | `RestoreResult` 的 `cancelledRequestIds` / `cancelledElicitationIds` 两组 id 都走 `acp_respond`，有单测或实测记录 |

## 禁止

- 不做 `fs/*` / `terminal/*` 回调与右栏真内容（R4）；不做 registry / 安装 / 认证页 / 设置页（R5）；不做 `session/load` / list / resume / close / delete 的动作（R6）；不做 sidecar（R7）；不做深色主题。
- 不引 `window_manager` / `bitsdojo_window`；不引 `git2` / `gix`（走 `git` CLI 子进程）；pubspec 只新增 `url_launcher`、`file_selector`；`provider` 不得 import。
- 接线阶段不改 `lib/theme` 与 `lib/ui`（规则 3）；缺 token 或缺回调钩子停下问，不偷改。
- 默认继承三条：不改前端页面样式（规则 3）；不加设计稿没有的功能（规则 3）；不在 `vendor/upstream/` 里改代码（规则 4）。
- Rust 禁 `unsafe`（规则 6）；流量面板与本地索引不落密钥，不读不打印 `~/.dsh/.credentials.yaml`（规则 8）。

## 代码审查

<!-- 完成后回填。审查路由见 CLAUDE.md「开发模式」与 docs/review-workflow.md：
     ① cursor CLI + grok 4.6 high → ② 硬失败回落主会话委派的 Claude Code 只读子代理（同一份任务书）。
     范围：前两轮全量（-Scope branch，即 main...HEAD），第 3 轮起只审上一轮整改 diff（-Scope since -Base <上一轮已审提交>）。 -->

- 审查方式：待回填
- 审查器与模型：待回填
- 审查范围与基准提交：待回填
- findings 处理：待回填
- 结论：待回填

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-03/BLOCKED.md`，停下呼人。禁止放宽验收标准自我通过。

## 本轮实测

<!-- 完成后回填：实际数字、踩的坑、与设计 / 计划的偏离及原因；子进程相关改动附 Windows 实测命令与输出（规则 9） -->

待回填。
