# ROUNDS — 轮次总览与 roadmap

> 设计稿已于 2026-09-14 收口（40 张画板；2026-09-17 增画板 05「转场规格」、2026-09-18 增画板 06「侧栏会话活动指示」，现 42 张。清单与计数以 [`design/README.md`](design/README.md) 为准），本文据此把实现拆成 **R0–R8（含 R1.5 spike）**，取代 `docs/design.md` § 11 的草案（2026-09-15）。
> 本文只管三件事：**哪一轮做什么画板与协议面、验收什么、开工前要所有者裁定什么**。流程、审查与硬性规则在 [`CLAUDE.md`](CLAUDE.md)，任务卡模板在 [`rounds/TEMPLATE.md`](rounds/TEMPLATE.md)，每轮开工 `cp rounds/TEMPLATE.md rounds/round-NN/round-NN.md` 后按本文对应节填。
> 轮次编号只增不改；R1.5 沿用 CLAUDE.md 规则 1 的写法（Markdown 库 spike）。R7 = sidecar、R8 = 打包，与 CLAUDE.md 仓库结构里的标注一致。R7.5 = 组合根拆分（纯代码结构轮，无画板；2026-09-18 起草、2026-09-20 按 main 新合并提交复核，裁定门待所有者拍板）、R7.6 = 字体切换（已完成，见 § 7）；拆完后的缺陷轮拟叫 R7.7。

## 0. 拆解原则

1. **画板是功能边界，每张画板归属恰好一轮**（§ 2 的表）。轮次收口时把 `design/README.md` 对应行的状态改成 `已实现（R<N>）`。设计稿没有的功能不做；画板里有、文档里没有的功能（§ 6 列了 9 项）先裁定再做。
2. **先核心后壳。** R1 的 Rust 核心不带 UI，用一个开发用 CLI（`rust/tools/acp-smoke`）对真实 agent 做验收；壳与卡片先用 fixtures 驱动，最后接线。这样 Windows 子进程、`.cmd` 包装、terminal auth 这些最大的不确定性在 R1 就暴露，而不是等到 UI 做完。
3. **fixtures 是契约锚。** `prototype/assets/fixtures.js` 在 R0 移植为 `test/fixtures/`（ACP 线上行，JSON Lines），三处共用：Rust 侧用 rust-sdk 类型逐行反序列化（保证样例合规、且落在我们编译出的 15 变体面内）；Dart 投影层单测；gallery 画板对照。任何轮新增的投影场景都先加 fixtures。
4. **每个有 UI 的轮次分两段提交：画板阶段与接线阶段。** 画板阶段只用 fixtures，收口提交号记进任务卡；接线阶段只换数据源，判据是 `git diff <画板阶段收口提交>..HEAD -- lib/theme lib/ui` 为空（CLAUDE.md 规则 3）。R2 只有画板阶段，它的接线在 R3 完成并按同一判据验。
5. **画板对照走 gallery，不做像素比对。** R0 建 `lib/gallery/`：把每张画板的每个状态以画板 frame 尺寸、fixtures 数据渲染成 `build/gallery/NN-<状态>.png`（gitignored），与 `design/round-design/NN-*.png` 并排看。对照记录进任务卡「本轮实测」：文案、状态、层级、控件不得缺；像素级差异不作 finding。
6. **参照 agent 逐轮递进，五 agent 全通矩阵在 R6 一次收口**（§ 4）。每轮只对参照 agent 做真跑验收，避免每轮都要五套凭据。
7. **裁定门。** 每轮「裁定」段列的事项在开工前要所有者拍板；有推荐项的可按推荐项开工并在任务卡标「待确认」，无推荐项的（涉及范围或白名单）不裁定不开工。裁定结果写回对应文档（`docs/design.md`、CLAUDE.md 规则 1、`rounds/BACKLOG.md`），本文不保存裁定原文。
8. **契约变更走文档。** 画板要求的、`docs/design.md` § 3 没有的桥命令与事件（§ 5 列出），在对应轮次先改 § 3 再实现；`_meta` 键增减一律走 § 4 与所有者裁定（规则 2）。

## 1. 轮次总览

| 轮 | 目标（一句话） | 画板 | 参照 agent | 前置 | 体量 |
|---|---|---|---|---|---|
| R0 | 脚手架：Flutter + Rust cdylib 经 frb 往返、`tokens.dart`、fixtures、gallery、validate / build 脚本、Windows release 构建 | 00 | 无 | fetch-upstream -Check 全绿；Flutter / Rust / VS 2022 前置齐 | M |
| R1 | Rust 核心主线（无 UI）：拉起、initialize、terminal auth、session/new、prompt、权限与 elicitation 队列、cancel、traffic 脱敏、未知变体计数、agent 生命周期 | — | dsh-acp-interactive；另用一个 npx 型验 `.cmd` | R0 | L |
| R1.5 | 富文本渲染 spike：Markdown / 代码高亮 / 数学 / Mermaid / 音频的库选型，所有者裁定后进白名单 | （为 12–16、32、60 选库） | 无 | R0；可与 R1 穿插 | S |
| R2 | 转录卡片：投影状态层 + 25 张转录画板，fixtures 驱动，不接核心 | 10–34 | 无（fixtures） | R1.5 裁定 | XL |
| R3 | 会话工作台壳与接线：三栏壳、输入框与弹层、内联菜单、agent 状态条、流量面板；接 R1 核心，dsh 真跑 | 01–04、40–42、34、80 | dsh-acp-interactive | R1、R2 | L |
| R4 | fs 与 terminal 回调、文件面板与终端面板；终端卡与 diff 卡接真数据；文件定位与 Follow | 60、61（22、23、21、18 接线） | claude-agent-acp + dsh | R3 | L |
| R5 | registry、安装、受管 Node、认证页与设置页 | 50、51、52、70 | codex-acp、Cursor | R3（R4 的右栏框架） | L |
| R6 | 会话生命周期（list / load / resume / close / delete）、modes 回退、五 agent 全通矩阵收口 | 41（会话菜单与删除确认）、04 复核 | pi-acp + 全部五个 | R4、R5 | M |
| R7 | zed-agent-acp sidecar | （无新画板；41 新建会话列表出现 Zed Agent） | Zed 内置 agent | R3；建议在 R6 后 | XL |
| R7.5 | 组合根拆分：`lib/app/workbench_controller.dart`（2645 行单类）拆成组合根 + 8 个对象，行为零变化，`lib/ui` / `lib/theme` / `lib/projection` 零 diff | —（无画板） | fake-agent（无头等价）+ dsh、claude-agent-acp 各一次真跑 | R7、画板 43、R7.6 已合入 main（5a001bf） | L |
| R8 | 打包与发布：sidecar 版本解耦、Windows zip + 安装器、产物自动化验收（macOS 挪到后续一轮） | 01 状态 2（首次启动） | 全部 | R6、R7 | M |

体量只是相对量（S < M < L < XL），不是工时承诺。R7 只依赖 R1 与 R3，若 Zed 构建环境先就绪可提前，但冷编译 30–60 分钟且与主程序无耦合，默认放在 R6 之后。

## 2. 画板 → 轮次 → widget 文件

widget 文件放 `lib/ui/<区域>/`，**默认一画板一文件**；同一卡片的状态画板（18 / 19 / 20、22 / 23）合一文件，文件头注释列出覆盖的画板号。文件名是拟定值，任务卡可改，改了回填本表。

| 画板 | 名称 | 轮 | widget 文件（拟） |
|---|---|---|---|
| 00 | Token 表 | R0 | `lib/theme/tokens.dart`（不是 widget；gallery 里有一张 token 样板页） |
| 01 | 工作台 · 新会话 | R3 | `lib/ui/shell/app_shell.dart` + `sidebar.dart` + `topbar.dart` + `session_header.dart` + `composer.dart` + `transcript_empty.dart`（另有三张以上画板共用的 `shell_common.dart`、`popover_anchor.dart`、`splitter.dart`；2026-09-17 起加 `app_logo.dart`（正式标记），2026-09-18 起加 `composer_attachments.dart`（附件芯片条）与 `tooltip.dart`（悬停提示）——后三者是设计稿之外的增补，见 BACKLOG「设计稿补注记」） |
| 02 | 工作台 · 进行中的一轮 | R3 | 同上（状态由投影层驱动） |
| 03 | 工作台 · 回合结束 + 右栏展开 | R3（右栏内容 R4） | 同上 + `lib/ui/shell/right_panel.dart` |
| 04 | 侧栏与顶栏状态 | R3 | `sidebar.dart`、`topbar.dart`（会话项、搜索、折叠态） |
| 05 | 转场规格 | main 直改（2026-09-17） | `lib/ui/shell/motion.dart`（`MotionEnter`，A / B / C / D 四组共用）+ 接线点 `workbench_screen.dart`、`workbench_controller.dart`、`session_header.dart`、`transcript_empty.dart`、`popover_anchor.dart`；数值在 `tokens.dart` 的 `Motion` / `Opacities` |
| 06 | 侧栏会话活动指示 | main 直改（2026-09-18） | `sidebar.dart`（`SessionSweepLine` / `SessionUnreadDot` + 会话项的 running / unread 两态）+ 接线点 `workbench_controller.dart`（`runningSessionIds` / `unreadSessionIds`）、`workbench_screen.dart`；数值在 `tokens.dart` 的 `Sweep` / `UnreadDot` / `Geometry` |
| 07 | 深色 Token 对位表 | `dark-mode-toggle-implementation` 分支（2026-09-20） | `lib/theme/tokens.dart`（`AppTheme` / `ThemeColors` / `Theming` + 颜色 token 全部改 getter）+ `lib/app/appearance_prefs.dart`（原 `font_prefs.dart`，`AppearanceController` 一并管字体与主题）；切换按钮在 `sidebar.dart` 的 `SidebarTitleBar`，接线点 `workbench_screen.dart` / `app.dart`；落盘在 `rust/settings` 的 `Appearance.theme` |
| 08 | 交互增强（回合折叠 / 跨工作区在跑数） | `claude/new-session-c0ff9d` 分支（2026-09-22） | B：`lib/projection/turn_fold.dart`（分组规则）+ `lib/ui/transcript/turn_fold_row.dart`（摘要行）+ `lib/app/transcript_folds.dart`（全局开关 + 每回合展开态）+ `transcript_list.dart`（行装配与滚动锚点）+ `entries.dart` / `session_store.dart`（`TurnEntry.model` 快照）+ `settings_page.dart`「转录」分组+ `rust/settings` 的 `Transcript` 段与 `transcript_prefs_get/set`；C：`lib/ui/shell/running_badge.dart` + `topbar.dart` + `topbar_popovers.dart` + `session_controller.dart`（`runningByWorkspace` / `runningTotal`）。**A 段（token 速度标签）设计阶段已删除，不实现** |
| 10 | ~~Restore Checkpoint 分隔线~~ 已废弃（2026-09-17） | R2 | 已删除（与画板 11 的 Restore 同一动作） |
| 11 | 用户消息气泡 | R2 | `lib/ui/transcript/user_message.dart` |
| 12 | 助手富文本正文 | R2 | `lib/ui/transcript/assistant_text.dart` |
| 13 | 代码块卡片 | R2 | `lib/ui/transcript/code_block.dart` |
| 14 | GFM 表格 | R2 | `lib/ui/transcript/gfm_table.dart` |
| 15 | Mermaid 图 | R2 | `lib/ui/transcript/mermaid_block.dart` |
| 16 | 数学公式 | R2 | `lib/ui/transcript/math_block.dart` |
| 17 | 思考折叠块 | R2 | `lib/ui/transcript/thinking_block.dart` |
| 18 | 标准工具调用卡 | R2 | `lib/ui/transcript/tool_call_card.dart`（18 / 19 / 20） |
| 19 | 工具调用失败卡 | R2 | 同上 |
| 20 | 工具已取消卡 | R2 | 同上 |
| 21 | 文件差异对比卡 | R2（定位动作 R4） | `lib/ui/transcript/diff_card.dart` |
| 22 | 嵌入式终端控制台卡 | R2（真终端 R4） | `lib/ui/transcript/terminal_card.dart`（22 / 23） |
| 23 | 终端进行中卡 | R2（真终端 R4） | 同上 |
| 24 | 子代理委派卡 | R2 | `lib/ui/transcript/subagent_card.dart` |
| 25 | 权限授权卡 | R2 | `lib/ui/transcript/permission_card.dart` |
| 26 | Awaiting Confirmation | R2 | `lib/ui/transcript/awaiting_bar.dart` |
| 27 | 表单模式交互卡 | R2 | `lib/ui/transcript/elicitation_form_card.dart` |
| 28 | 链接跳转交互卡 | R2 | `lib/ui/transcript/elicitation_url_card.dart` |
| 29 | 计划卡 | R2 | `lib/ui/transcript/plan_card.dart` |
| 30 | 上下文窗口浮窗 | R2 | `lib/ui/transcript/context_window.dart` |
| 31 | 回合态与结束 | R2 | `lib/ui/transcript/turn_state.dart` |
| 32 | 非文本内容块 | R2 | `lib/ui/transcript/content_blocks.dart` |
| 33 | 上下文压缩卡 | R2 | `lib/ui/transcript/compaction_card.dart` |
| 34 | agent 状态与错误 | R3 | `lib/ui/shell/agent_state_bar.dart` |
| 40 | 输入框弹层合集 | R3 | `lib/ui/popovers/composer_popovers.dart`（+ 40 / 41 / 42 共用的 `lib/ui/popovers/menu.dart`） |
| 41 | 顶栏与侧栏弹层合集 | R3（会话菜单动作 R6） | `lib/ui/popovers/topbar_popovers.dart` |
| 42 | 输入框内联菜单 | R3 | `lib/ui/popovers/inline_menus.dart` |
| 43 | 会话时间线弹层 | main 直改（2026-09-20） | `lib/ui/popovers/session_timeline.dart` + 派生层 `lib/projection/timeline.dart`；接线点 `session_header.dart`（history 按钮）、`workbench_screen.dart`（弹层与跳转）、`transcript_list.dart` / `user_message.dart`（行键与落点聚焦态）；数值在 `tokens.dart` 的 `Timeline` |
| 50 | Agents 面板（ACP Registry） | R5 | `lib/ui/registry/registry_panel.dart` |
| 51 | Registry 条目状态 | R5 | `lib/ui/registry/registry_entry.dart` |
| 52 | agent 认证 | R5 | `lib/ui/registry/auth_page.dart` |
| 60 | 文件面板 | R4 | `lib/ui/files/files_panel.dart` + `file_tree.dart`（2026-09-17 起树列可拖、「缩小」改为收起整列） |
| 61 | 终端面板 | R4 | `lib/ui/terminal/terminal_panel.dart` + `local_terminal.dart` + `terminal_ime.dart`（2026-09-17，中文输入法；键盘输入走硬件按键） |
| 70 | 设置 | R5（2026-09-22 加「转录」分组，见画板 08） | `lib/ui/settings/settings_page.dart`（2026-09-17 起是右栏的一个标签，与文件 / Agents 并列，不再占会话区） |
| 80 | ACP 流量调试 | R3 | `lib/ui/traffic/traffic_page.dart`（数据源 `lib/projection/traffic.dart`） |

前端其余目录（R0 定型）：`lib/app/`（组合根：R3 落 `workbench_controller.dart` 状态与动作、`workbench_screen.dart` widget 装配、`window_controls.dart` 平台通道、`headless_run.dart` 无头实跑；R4 加 `files_state.dart` 与 `local_terminals.dart`；2026-09-18 加 `clipboard_image.dart`（剪贴板图片，Windows 借 `powershell.exe` 读）；数据源选择 fixtures / bridge；R7.5（2026-09-20）把 `workbench_controller.dart` 拆成组合根 + 8 个对象：`shell_state` / `workspace_state` / `agents_state` / `auth_state` / `composer_state` 按画板分组管本地态，`session_controller` / `turn_controller` 驱动协议，`session_index` 是本地索引镜像，`guarded` 是共用的通知与错误边界；依赖方向见 `rounds/round-7.5/round-7.5.md` 附录 B）、`lib/bridge/`（frb 生成物，入库）、`lib/projection/`（投影状态层，纯 Dart，无 widget 依赖）、`lib/theme/tokens.dart`、`lib/gallery/`（画板对照，debug 构建才编入）。

## 3. 各轮拆解

每轮五段：目标 / 交付物 / 验收要点 / 裁定（开工前）/ 契约变更。「禁止」段继承 TEMPLATE 的三条默认，本文只写该轮额外的。

### R0 脚手架、token 表与契约检查

**目标**：Flutter Windows 桌面项目与 `rust/` workspace（cdylib）经 frb v2 打通一次命令 + 一条事件流往返，`tokens.dart` 从 `00-tokens` 提炼，fixtures / gallery / validate / build 四套基础设施落地，`flutter build windows --release` 在本机通过。

**交付物**

- `pubspec.yaml`（Flutter stable 钉版本；依赖只有 CLAUDE.md 规则 1 清单内的）、`flutter_rust_bridge.yaml`、`rust-toolchain.toml`、`rust/Cargo.toml` workspace：`bridge`（cdylib；`api.rs` 暴露 `init(data_dir)`、一个 `ping` 命令、五条 `StreamSink<String>` 事件流的注册）、`acp-core` / `registry` / `pty` / `fs` / `settings` 空壳 crate（只定结构与 `Result` 边界）、`rust/tools/acp-smoke`（开发用 CLI 二进制，本轮只打通「连 bridge 之外直接调 acp-core」的骨架，不发布）。
- `lib/bridge/`（frb 生成物入库）、`rust/bridge/src/frb_generated.rs`。
- `lib/theme/tokens.dart`：从 `design/round-design/00-tokens.dc.html` 逐值提炼：浅色中性 10 级、深色中性 10 级 + `d.accent`（只备常量，不接主题切换）、accent 四态、`border.on-accent`、语义色 4 × 2、三级表面、边框两级、`shadow.popover`、字阶五档 + mono 12.5、字重、行高、间距 4 / 8 / 12 / 16 / 24 + `space.chip`、圆角 3 / 4 / 6 + pill、控件高度 24 / 28 / 32、按钮四态叠色 6% / 10%、焦点环 1.5 / +1、图标 16 / 14 + stroke 1.5、`motion.fast` 120ms / `motion.base` 160ms。任务卡附「token 名 → 00 画板位置 → 值」对照表。
- 字体资产：Geist / Geist Mono（OFL，许可证文件一并入库），CJK 回退 Noto Sans SC（Regular 一档随包，OFL，上游 notofonts/noto-cjk 的 `Sans/SubsetOTF/SC`），系统的 Microsoft YaHei UI / PingFang SC 只做兜底；三者的次序由 `tokens.dart` 的字体栈声明。
- `lib/projection/wire.dart`：15 个 `session/update` 变体 + `ContentBlock` 5 种 + `ToolCallContent` 3 种 + permission / elicitation 请求形状的薄封装（只做字段访问与判别，不做校验）。
- `test/fixtures/`：从 `prototype/assets/fixtures.js` 移植的线上行（JSON Lines，按场景分文件），另加一条故意的 `notice` 行与一条未知变体行；`rust/acp-core` 的测试逐行喂 rust-sdk 类型，断言合规行全部成功、两条故意行失败。
- `lib/gallery/` + `test/gallery_test.dart`：以画板 frame 尺寸离屏渲染并写 `build/gallery/`；本轮只有 00 的 token 样板页。
- `scripts/validate.ps1`：`cargo build` / `cargo test` / `cargo clippy -D warnings`、`unsafe` 字面扫描（规则 6）、`cargo tree` 无 gpui（规则 5）、`flutter analyze` / `flutter test`、`pubspec.yaml` 依赖 ⊆ 白名单、`Assert-NoStyleLiteral`（扫 `lib/` 除 `tokens.dart` 与 `bridge/` 外的颜色 / 字号 / 间距 / 圆角字面量）、`rust/` 里 `_meta` 键 ⊆ `docs/design.md` § 4、Zed 派生文件头注释存在、`fetch-upstream.ps1 -Check`。`scripts/build.ps1`：`flutter build windows --release`，`CARGO_TARGET_DIR` 指纯 ASCII 路径。
- `.zed/` 与 `ai-output/` 已 gitignored，不动。

**验收要点**

1. `scripts/build.ps1` 在本机通过；再把仓库复制到一个含中文与空格的目录（例如 `D:\测试 目录\AcpAgentClient`）构建一次，覆盖用户环境（本机用户名已是 ASCII，`docs/design.md` § 12 的用户名风险要靠这一步覆盖）。
2. Dart 调 `ping` 得到返回；核心主动向 `acp/agent_state` 推一条事件，Dart 侧收到。
3. `validate.ps1` 全绿；往任一 widget 里塞一个 `Color(0xFF000000)` 会被 `Assert-NoStyleLiteral` 拦下（记录输出后撤掉）。
4. `tokens.dart` 对照表逐值核对，无表外值、无遗漏；gallery 的 00 样板页与 `00-tokens.png` 并排对照。
5. fixtures 在 Rust 侧的反序列化测试通过（合规行 100%，两条故意行失败并被断言）。
6. 中文 IME 在 Flutter `TextField` 里的组合窗行为实测一次，记录进任务卡（`docs/research.md` § 8 待验证项）。

**裁定（开工前）** —— 已裁定 2026-09-15，三条全部按推荐项，落 `docs/design.md` § 2、CLAUDE.md 规则 1 与「本地开发」：

- 前端 Dart 类型来源（`rounds/BACKLOG.md` 工程项）：**推荐手写薄封装**（`wire.dart`），理由：桥上只传 JSON 字符串，Dart 类型只服务投影层可读性；从 `schema.unstable.json` 生成再裁剪到 15 变体的产物既大又难复现，且需引入生成器工具链。合规性由 Rust 侧的 fixtures 反序列化测试兜底。
- 图标与 SVG：画板图标全是内联单线 SVG，registry 条目图标是 `icon.svg`。**推荐把 `flutter_svg`（Flutter 团队维护）加入规则 1 通用库清单**，理由写任务卡；备选是自写只支持 M / L / C / A / Z 的 path 解析（约 150 行，无新依赖）。
- `CARGO_TARGET_DIR` 的固定位置（建议 `D:\cargo-target\AcpAgentClient`）。

**契约变更**：无。`docs/design.md` § 2 的 Dart 类型来源已于 2026-09-15 按裁定回填。

### R1 Rust 核心主线（无 UI）

**目标**：`acp-core` 用官方 rust-sdk v2 以 Client 角色跑通一等 agent 的完整主线，所有事件与命令经 frb 暴露，用 `acp-smoke` 对 dsh-acp-interactive 做真跑验收；Windows 下 `.cmd` 包装的 npx 型 agent 至少完成 initialize。

**交付物**

- `rust/acp-core`：每个 agent 一条 stdio 连接、多会话复用；`initialize` 能力声明 = `docs/design.md` § 4 全集（含 `plan`、`session.compaction`，`_meta` 只有 `terminal_output` / `terminal-auth`，Cursor 追加参数化模型选择器键）；`session/new` 回 `-32000` → `acp/agent_state: auth_required(authMethods)`；terminal 型认证 = 用 `pty` 以附加 args / env 重拉同一个 agent 程序，进程退出后自动重试 `session/new`（转写 Zed `agent_servers/acp.rs`，头注释标来源）；agent 型认证 = `authenticate`；`session/prompt` / `cancel` / `set_mode` / `set_config_option`；`session/request_permission` 与 `elicitation/create`（form / url；sessionScope / requestScope 都要）转成 `acp/client_request` 并进队列，`acp_respond` 回应；**发出 cancel 后挂起的权限请求自动回 `cancelled`**；`session/update` 原样 JSON 直出 `acp/session_update`；`acp/traffic` 行 tap（转写 Zed `acp.rs:886-910` 的做法，stdin / stdout / stderr 三路）+ 脱敏（`Authorization` / `api_key` / `token` → `***`，规则 8）；反序列化失败的 `session/update` 计数并经 `acp/agent_state` 上抛告警、原文落 traffic；agent 退出 → `exited(code, stderr 尾巴)`；对外 API 统一 `Result`，不让 panic 穿过 FFI。
- `rust/settings` 最小实现：`%APPDATA%/AcpAgentClient/settings.json` 的 `agent_servers`，本轮只支持 `custom` 型（dsh 就是 custom）；写文件走临时文件 + rename（规则 7）；数据目录布局按 `docs/design.md` § 10。
- `rust/pty` 最小实现：只够跑 terminal auth 的可见终端（portable-pty 拉起、输出经 `acp/terminal_output` 推字节、等退出）；`terminal/*` 回调留到 R4。
- `rust/bridge`：§ 3 命令里本轮涉及的全部（`agent_connect` / `agent_disconnect` / `session_new` / `session_prompt` / `session_cancel` / `session_set_mode` / `session_set_config_option` / `acp_respond` / `authenticate` / `terminal_auth_run` / `agent_settings_get` / `agent_settings_set`）与五条事件流。
- `rust/tools/acp-smoke`：`acp-smoke --agent <id> --cwd <dir> --prompt "<text>" [--auto-permission allow_once|reject_once] [--cancel-after <ms>]`，事件按 JSON 行打印到 stdout；后续轮次的 headless 验收都用它。

**验收要点**

1. 对 dsh：拉起 → initialize → `session/new` 回 `-32000` → terminal auth `--setup` 在 pty 里跑完 → 自动重试 `session/new` 成功 → 一轮 prompt 含 `tool_call` + `request_permission`（allow_once）+ `plan` + `config_option_update` → `end_turn` 带 usage；事件序列与 `test/fixtures/` 的 dsh 场景同形（变体集合一致）。
2. 同一轮 `--cancel-after`：未完成的工具卡由前端本地标 cancelled（核心不伪造状态）、挂起的权限请求核心自动回 `cancelled`、`stopReason = cancelled`。
3. npx 型 agent（pi-acp 或 claude-agent-acp）在 Windows 用系统 Node 拉起并完成 initialize，工作目录含空格与中文；命令行与输出入任务卡（规则 9）。
4. traffic 里三类密钥字段为 `***`；人工注入一条 `notice` 行 → dropped 计数 +1、`acp/agent_state` 告警、traffic 原文可见；据此复议 `rounds/BACKLOG.md` 的 `notice` 条目。
5. 杀掉 agent 进程 → `exited` 事件带退出码与 stderr 尾巴；核心不 panic；再次 `agent_connect` 可恢复。
6. elicitation form 与 url 两种模式都能经 `acp/client_request` 到达并由 `acp_respond` 收尾（dsh 提供 form；url 用 fixtures 或 R5 的 codex 补测，任务卡写明哪一种）。

**裁定（开工前）**：无。`notice` 处置按 `docs/design.md` § 4 既定裁定，实测后复议。

**契约变更**：`docs/design.md` § 3 的 `acp/agent_state` payload 补 `droppedUpdates`（计数）与 `stderrTail`；`acp/client_request` 补 requestScope 场景（无 `sessionId`）；工具调用「已取消」是前端本地态（`docs/acp-projection.md` § 11 第 5 条）。

### R1.5 富文本渲染 spike（裁定门）

**目标**：为画板 12–16、32（audio）与 60（Markdown 预览）选库，产出对比记录，所有者裁定后写进 CLAUDE.md 规则 1 与 `docs/requirements.md` § 8 的允许清单。spike 代码只在 worktree，不合并。

**范围与候选**

| 需求 | 画板 | 候选 | 判据 |
|---|---|---|---|
| Markdown（GFM） | 12、13、14、60 | `package:markdown` + 自写渲染、`markdown_widget`、`gpt_markdown` | 流式追加不闪不跳、GFM 表格 / 任务清单 / 引用 / 分割线、行内代码、文件链接可点、CJK 换行、`SelectionArea` 选择复制、维护状态、许可证 |
| 代码高亮 | 13、60 | 随 Markdown 库自带，或 `highlight` / `flutter_highlight` / `re_highlight` | 常见语言覆盖、主题可从 `tokens.dart` 取色、长行横向滚动 |
| 数学公式 | 16 | `flutter_math_fork` 或同类 | 行内 + 块级、失败回落源码 |
| Mermaid | 15 | 无成熟 Dart 渲染器 | 给所有者三选一：(a) 引入 WebView 渲染（与「不依赖 WebView2」的取舍冲突）；(b) 只做源码态 + 复制按钮，画板 15 的图形态改设计稿；(c) 自写子集渲染（不建议） |
| 音频播放 | 32 | `audioplayers` / `just_audio` | 只要求 base64 音频的播放 / 暂停 / 进度条；或先只做「不可渲染兜底卡」（改画板 32） |
| diff 渲染 | 21 | `diff_match_patch` 或同类（规则 1 已允许「一个 diff 库」） | 行级 diff、旧文本可选、大文件性能 |

**交付物**：`rounds/round-1.5/spike.md`（对比矩阵 + 每个候选的截图 + 结论）；所有者裁定记录；CLAUDE.md 规则 1 / `docs/requirements.md` § 8 的清单更新。

**验收要点**：裁定落文档；R2 开工前 `pubspec.yaml` 里只出现裁定过的库。未裁定不开 R2。

**说明**：可在 R0 收口后随时开始、与 R1 穿插，因为产出要等所有者裁定。

### R2 转录卡片（fixtures 驱动）

**目标**：25 张转录画板（10–34）全部成为可复用 widget，由投影状态层 + fixtures 驱动，每张画板的每个状态都能在 gallery 里静态出现；本轮不接核心。

**交付物**

- `lib/projection/`：`session_store.dart`（按 `sessionId` 累积；消息分组：`messageId` 变化另起一条，无 `messageId` 时按角色连续合并；`agent_thought_chunk` 的折叠单元；轮边界与检查点；本地时间戳）、`tool_calls.dart`（同 id 覆盖、`content[]` / `locations[]` 整体替换、先到的 update 凭空建卡、未知 `kind` 落 `other`、`content[]` 逐项跳过、本地 cancelled 态、终端输出留存）、`plans.dart`（稳定 `plan` 整份替换 + `plan_update` 三种载荷按 `planId` 增删）、`compaction.dart`、`usage.dart`、`pending.dart`（permission / elicitation 队列，含 requestScope 的无会话项）、`agent_state.dart`；全部是 `ChangeNotifier` / `Stream`，不依赖 widget。规则来自 `prototype/assets/projection.js`，搬规则不搬代码。
- `lib/ui/transcript/` 按 § 2 的表，一画板一文件；Markdown / 高亮 / 数学 / Mermaid / 音频 / diff 按 R1.5 裁定接入；22 / 23 用 `xterm` 渲染，本轮喂固定字节流。
- fixtures 扩到覆盖 `docs/acp-projection.md` § 2 全部 15 变体、§ 2.1 五种内容块、§ 2.2 合并语义、§ 3 两类请求、§ 7 七项自造态、§ 8.3 逐项跳过；每张画板的每个状态有一个具名场景。
- gallery：25 张画板、全部状态。
- 投影层单测 + `SelectionArea` 跨消息选择实测记录。

**验收要点**

1. 单测覆盖 `docs/acp-projection.md` § 7 七项、§ 2.2 合并语义、§ 3.1「cancel 后挂起权限回 cancelled」、§ 8.3 逐项跳过；同一 fixtures 分批喂与整批喂得到相同状态（为 R6 的 `session/load` 重放打底）。
2. gallery 25 张与 PNG 逐张并排对照，偏差逐条记任务卡；文案、状态、层级、控件零缺失。
3. `validate.ps1` 全绿；`pubspec.yaml` 只含裁定过的库。
4. 1,000 个块的转录滚动流畅（`ListView.builder` + 按帧合并 `session/update`）；粗测即可，数字记任务卡。
5. 24 子代理卡只按裁定的入站 `_meta` 键分组，代码里没有 agent 名。

**裁定（开工前）** —— 前两条已裁定 2026-09-15 按推荐项（落 `docs/design.md` § 3 / § 4）；第三条随 R1.5：

- 24 子代理卡的判据（`rounds/BACKLOG.md` 功能项）：画板依赖 `_meta.claudeCode.{parentToolUseId, subagent, toolName}`，dsh 用 `_meta.dsh_subagent`。**推荐**在 `docs/design.md` § 4 增「入站 `_meta` 识别键」一节，只列这两组键；投影层按「键存在」分组，不按 agent 名判。不裁定则 24 只做「进行中 / 完成」两态、不做嵌套。
- 10 / 11 的 Restore 与 Regenerate 语义：原型定的是「本地截断其后投影块 + 在同一会话重发 prompt」，协议没有回滚，agent 侧上下文不回退。**推荐**照原型做，作为已知限制记 BACKLOG，不在 UI 加提示（设计稿没有）。
- 15 Mermaid、32 audio 的方案随 R1.5 裁定 → 2026-09-15 按推荐项：`mermaid_flutter` + `mermaid_core` 与 `audioplayers`，两张画板都不改。

**契约变更**：无（本轮不碰 `rust/`）。

### R3 会话工作台壳与接线

**目标**：完整壳按画板 01–04 落地，输入框弹层（40）、内联菜单（42）、顶栏与侧栏弹层（41）、agent 状态条（34）、流量面板（80）齐；画板阶段收口后接 R1 核心，用 dsh 真跑一轮完整对话。

**交付物**

- `lib/ui/shell/`、`lib/ui/popovers/`、`lib/ui/traffic/`（§ 2）；`lib/app/` 组合根：数据源默认 bridge，`--dart-define=DATA_SOURCE=fixtures` 供 gallery 与开发。
- 本地会话索引 `%APPDATA%/AcpAgentClient/sessions.json`（agentId + sessionId + 标题 + cwd + 时间 + 消息计数；临时文件 + rename）；侧栏：搜索、会话项默认 / 悬浮（重命名、删除）/ 选中 / 行内重命名、折叠态；「N 条消息」由投影层分组计数得出。
- 会话头：标题（`session_info_update.title`，缺省用 `New <agent> Session`）、重命名（本地索引）、新建（41 选 agent → `session/new`，cwd = 当前项目）、重载 agent（断开 + 重拉 + 新会话，本地转录保留只读；R6 接 `session/load` 后改为重载后自动 load）、≡ 菜单按 `sessionCapabilities` 裁剪（Resume / Close / Delete 无能力不渲染；动作本身 R6 接）。
- 输入框：占位文案、`+` 弹层（Files & Directories → `file_selector` → `resource_link`；Image → `image` 块，受 `promptCapabilities.image` 门；Sessions → 本地转录文本作 embedded resource；Branch Diff → `git diff` 输出作 embedded resource；Symbols / Selection 已按裁定从画板 40 删除）、`@` 提及（42；文件 / 文件夹 / 最近，用 `fs_search` 按名过滤，本轮把 `fs_list_dir` / `fs_search` 的最小实现拉进 `rust/fs`）、`/` 命令（`available_commands_update` 全量列表；`input: unstructured` 时命令名后的整段文本原样作参数）、模型 / 思考强度 / 模式三个下拉与布尔开关行（`config_option_update` 按 `category` 分配，未知 category 扁平兜底，未知 type 整条忽略；同时有 modes 时只用 configOptions）、用量圆环与浮窗（30；`usage_update`）、发送 / 停止（`session/cancel`）、Awaiting 悬浮条（26；Scroll 定位）。
- 顶栏：侧栏开关、项目名与切换弹层（This Window = 已打开的项目、Recent Projects = 本地列表、Open Local Folders = `file_selector` 目录选择）、分支名与切换弹层（`git branch` 列表、搜索、`git switch`、`git switch -c` 新建；非 git 目录整块隐藏）、窗口控制（裁定）。
- 34 agent 状态条（spawned / initialized / auth_required 列认证入口 / exited 带 stderr 尾巴与重启 / 丢弃告警 / `-32000` 错误条）；80 流量面板（方向与方法过滤、变体标签、原文展开、暂停跟随、复制行、丢弃计数告警行、stderr 尾巴区）。
- Windows runner 侧的自绘窗口控制（若裁定为平台通道方案）。

**验收要点**

1. 画板阶段：gallery 01（两状态）/ 02 / 03（右栏用占位）/ 04 / 40 / 41 / 42 / 34 / 80 与 PNG 逐张对照。
2. 接线阶段：`git diff <画板阶段收口提交>..HEAD -- lib/theme lib/ui` 为空（含 R2 的 `lib/ui/transcript/`）。
3. dsh 真跑：新会话 → 一轮含权限（允许 / 拒绝 / 范围下拉；画板 25 上的 Alt-Shift-A / Alt-Shift-X / Ctrl-Alt-A 标签从未接过按键，2026-09-18 已裁定去掉、不做快捷键）→ elicitation form 提交 → 计划卡折叠 / 展开 → 回合结束行 → 第二轮中途停止 → 重载 agent；改一个 config option 后弹层与会话头同步刷新。
4. 流量面板对同一轮的行数与 `acp-smoke` 一致，密钥打码；注入 `notice` 后 34 与 80 的告警同时出现。
5. 项目切换后新会话的 cwd 正确；分支列表与 `git branch` 一致，新建分支后顶栏立即更新；非 git 目录分支区隐藏。
6. 杀掉 agent → 34 的 exited 条 + 重启可用；应用整体不崩。
7. 无已安装 agent 时显示 01 状态 2，`打开 Agents 面板` 切到右栏 Agents 标签（R5 前是空面板占位）。
8. Windows 实测记录（规则 9）：窗口控制、`file_selector`、git 子进程。

**裁定（开工前）** —— 已裁定 2026-09-15，六条全部按推荐项（落 `docs/design.md` § 2 / § 3 / § 9 / § 10；画板 40、42 已改并重渲染 PNG）：

- 窗口控制（— ☐ ✕ 画在应用自己的顶栏里 = 无边框窗口）：**推荐 Windows runner 自写平台通道**（`WM_NCHITTEST` 拖拽区 + 最小化 / 最大化 / 关闭三个方法），不引 `window_manager` / `bitsdojo_window`；macOS 在 R8 用原生 traffic lights。备选是把这两个包写理由进通用库清单。
- `+` 弹层的 Symbols 与 Selection：需要 LSP 与编辑器选区，与 `docs/requirements.md`「不做」直接冲突。**推荐改设计稿删掉这两项**（画板 40 重导 PNG）；裁定前这两项不渲染。
- 30 / 40 的 `Rules · 1 global rule`：文档没定义语义。**推荐**实现为「当前项目根目录下 AGENTS.md / CLAUDE.md / `.rules` 类规则文件的计数，点击在文件面板打开」；或改设计稿删掉。
- 42 `/` 菜单的分组（Commands / Skills / 项目名）：`AvailableCommand` 只有 name / description / input，没有分组字段。**推荐单组渲染**；若要分组只能按名字前缀猜，不建议。
- git 操作方式：**推荐 `git` CLI 子进程**（`rust/fs` 里薄封装，检测不到 git 时分支区隐藏），不引 `git2` / `gix`。
- 41「项目」概念：设计稿要求最近项目列表与本地文件夹打开，文档没有。**推荐**「项目 = 一个本地目录，作为 `session/new` 的 cwd；最近项目列表存本地索引」，不做 Zed 的 worktree 模型。

**契约变更**：`docs/design.md` § 3 命令补 `workspace_recent` / `workspace_open`、`git_branches` / `git_switch` / `git_create_branch`、`session_index_*`（本地索引读写）、`fs_list_dir` / `fs_search` 提前到本轮；`docs/design.md` § 9 页面清单补「项目与分支切换」；`_meta` 不变。

### R4 fs 与 terminal 回调、文件面板与终端面板

**目标**：`fs/*` 与 `terminal/*` 回调按规范落地，转录里的终端卡（22 / 23）与 diff 卡（21）接真数据，文件面板（60）与终端面板（61）按画板实现，「Go to File」/ diff 行定位 / `@` 芯片点击 / Follow 全部落到右栏文件面板。参照 claude-agent-acp（fs 读写、交互与后台终端）与 dsh（读 `_meta.terminal_output`）。

**交付物**

- `rust/fs`：`fs/read_text_file`（绝对路径且在会话 cwd 内、`line` / `limit` 1-based）、`fs/write_text_file`（不存在则创建；临时文件 + rename）；`fs_list_dir` / `fs_read` / `fs_watch`（`notify`）/ `fs_search`（名字与内容）；git 状态徽章（`git status --porcelain`，裁定）；不做索引服务。
- `rust/pty`：`terminal/create` / `output` / `wait_for_exit` / `kill` / `release` 语义转写 Zed `acp_thread/terminal.rs`（头注释标来源）：输出字节上限、**截断落在字符边界**、kill 不释放、release 后输出仍留在工具卡（缓冲跟卡走）；本地交互 shell（61）：`terminal_open` / `terminal_write` / `terminal_resize` / `terminal_close`，输出经 `acp/terminal_output`（带 `terminalId`）；Windows `.cmd` 包装、引号、含空格与中文的 cwd 实测。
- `lib/ui/files/`：树（过滤输入、刷新、全部折叠、搜索开关、文件夹 / 文件图标、git 徽章）+ 查看器（文件名、路径、复制、Source / Preview 切换、元信息徽章、空态）；Preview 用 R1.5 裁定的 Markdown 库。
- `lib/ui/terminal/`：多标签可关闭、cwd 常显、清屏、停止 / 重启、运行中 / 已退出（退出码 + 耗时）；`xterm` 渲染。
- `lib/ui/shell/right_panel.dart`：文件浏览器 / 终端 / ACP Registry 三个标签（Registry 内容 R5 填）；窗口控制固定在右栏标签栏最右（画板 03 / 50 / 60 / 61）。
- 定位与 Follow：18 的 `Go to File`、21 的「在文件面板中定位」、11 的 `@` 芯片 → 右栏文件面板打开文件并滚到行；Follow 为客户端本地开关（40 的提示），开启时 `locations[]` 到达即跟随。

**验收要点**

1. claude-agent-acp 一轮：读文件（18）→ 编辑（21 diff 只读，行点击定位）→ 前台命令（22，Exit Code，release 后输出仍在）→ 后台命令（23，停止方块 → `terminal/kill`）→ `Go to File` 落右栏。
2. fs 写走临时文件 + rename（测试断言中间文件名与最终 rename）；相对路径、cwd 之外、不存在的父目录按规范处理；`line` / `limit` 1-based 有测试。
3. 终端截断：含中文与 emoji 的输出在字节上限处不切出半个字符（测试）；`truncated` 标志正确。
4. 本地 shell：PowerShell 会话可输入命令、多标签、清屏、关闭；退出后显示退出码；应用退出时子进程全部回收。
5. dsh 因 `_meta.terminal_output: true` 公布终端能力（对照 R1 未声明时的差异）。
6. gallery 60 / 61 对照；接线零 diff 判据（`lib/ui/transcript/terminal_card.dart`、`diff_card.dart` 零 diff）。
7. Windows 实测记录（规则 9）：`.cmd`、引号、含空格与中文的 cwd、`notify` 在 Windows 的事件表现。

**裁定（开工前）** —— 已裁定 2026-09-15，两条按推荐项（落 `docs/design.md` § 3 / § 9）：

- 文件树 git 状态徽章（`rounds/BACKLOG.md` 功能项）：**推荐保留**，`git status --porcelain` 子进程实现，非 git 目录不显示。
- 本地交互 shell 是画板 61 明确要求、`docs/design.md` § 3 没有的能力，需要新增四个桥命令：**推荐同意**，理由是它复用 `rust/pty` 与 `acp/terminal_output`，不引新协议。

**契约变更**：`docs/design.md` § 3 补 `terminal_open` / `terminal_write` / `terminal_resize` / `terminal_close`，`acp/terminal_output` payload 补 `terminalId` 与来源（agent / auth / local）；§ 7 补「截断落字符边界」「release 后输出留存跟卡走」。

### R5 registry、安装、受管 Node、认证页与设置页

**目标**：registry 面板（50 / 51）从拉取到安装到首次握手全通，认证页（52）覆盖 agent 型、terminal 型与 requestScope 的 URL elicitation，设置页（70）四块落地。参照 codex-acp（npx；ChatGPT 登录走 URL elicitation；`OPENAI_API_KEY` 路径）与 Cursor（binary 六平台压缩包；terminal auth `agent login`）。

**交付物**

- `rust/registry`：复制 Zed `crates/project/src/agent_registry_store.rs` 与 `agent_server_store.rs`（头注释标来源 + commit），去 gpui / remote / collab，`Entity` / `Task` 换 tokio，`fs::Fs` 换 `tokio::fs`，结构体对照官方 `agent.schema.json`；`registry.json` 1 小时节流 + 磁盘缓存 + 图标按需；按平台过滤 `binary` target；`npx`：解析包名与版本 → 写 settings → 首次拉起并握手 initialize（51 的三步）；`binary`：下载 → sha256 校验 → 解压到 `agents/<id>/<version>/` → 记 cmd / args / env，进度经 `registry/progress` 事件；取消安装；`uvx` 显示「暂不支持」；Remove：移除 settings 条目并只删自己写的 `agents/<id>/`；受管 Node：直接 git 依赖 Zed `node_runtime`，检测系统 Node ≥ 22，缺失时下载 v24.11.0 到数据目录（51 的提示卡 + 70 的状态行）。
- `rust/settings` 完整：`registry` / `custom` 两型（Zed 同 schema）、`agent_settings_get` / `set`、`agent_settings_import_zed`（读 `%APPDATA%/Zed/settings.json` 的 `agent_servers`，导入为 custom 型，不覆盖同名）。
- 认证：agent 型 → `authenticate`（agent 自己开浏览器）；terminal 型 → R1 的路径在 52 的可见终端呈现；requestScope 的 URL elicitation 落 52 页而不是转录，`url_launcher` 打开并等 `elicitation/complete`；成功后自动重试 `session/new` 并回到原来的新会话；失败态可重试、可换方式。
- `lib/ui/registry/`（50：标题 + Learn More、搜索、All / Installed / Not Installed 计数、条目的图标 / 名称 / 版本 / 已安装 / 已登录 / 描述 / ID / 源码仓库 / Install / Remove；51：全部八种状态；52：认证页）、`lib/ui/settings/`（70：agent 配置列表含 custom 型行内编辑 cmd / args / env、从 Zed 导入、Node 运行时、数据目录与日志路径的打开 / 复制）。

**验收要点**

1. 干净数据目录：Agents 面板搜索 codex → Install（51 三步可见）→ 新会话 `-32000` → 52 选 Sign in with ChatGPT（URL elicitation，requestScope）→ 自动重试 → 一轮对话；再以 `OPENAI_API_KEY` 环境变量路径过一遍。
2. Cursor：binary 下载 + sha256 校验 + 解压（51 进度条）→ terminal auth `agent login` → 一轮对话；人为篡改 sha256 → 安装失败态，可重试、可看日志。
3. PATH 里剔除 Node → 51 的受管 Node 提示 → 下载 → npx 型 agent 可用；数据目录只多 `node/`。
4. 从 Zed 导入：`agent_servers` custom 条目进 70，同名不覆盖，registry 型条目按 id 匹配。
5. Remove 后条目回未安装、settings 条目消失、`agents/<id>/` 被清理，其他目录不动（规则 7）。
6. registry 缓存：断网时列表仍可显示、安装报网络错误而不是崩。
7. gallery 50 / 51 / 52 / 70 对照；接线零 diff 判据；Windows 实测记录（规则 9：`.cmd`、解压、sha256）。

**裁定（开工前）**：无新范围。`uvx` 按 BACKLOG 既定不做。

**契约变更**：`docs/design.md` § 3 补事件 `registry/progress`，命令补 `registry_remove` / `registry_cancel_install` / `node_status` / `node_download`；§ 5 补 requestScope elicitation 的落点（认证页）。

### R6 会话生命周期与五 agent 全通

**目标**：`session/list` / `load` / `resume` / `close` / `delete` 接通，侧栏与会话头菜单的动作全部可用，modes 回退路径真跑；五个一等 agent 按 `docs/requirements.md` § 必须 第 3 条的七步全通，矩阵见 § 4。参照 pi-acp（`session/load`、slash 命令、不用客户端 fs 与 terminal、`--terminal-login`）。

**交付物**

- `session/list`（`cwd` 过滤 + cursor 分页）、`session/load`（整段历史重放进投影层，重放期间不逐条刷新 UI）、`session/resume`（不重放）、`session/close`、`session/delete`（41 的确认弹层）；按 `loadSession` 与 `sessionCapabilities.{list, delete, resume, close}` 裁剪菜单与侧栏动作。
- 本地索引与 `session/list` 的合并（裁定）；重载 agent 后自动 `session/load`（agent 声明 `loadSession` 时）。
- modes 回退：只发 `current_mode_update` 不发 configOptions 的 agent，模式下拉用 modes；两者都有时只用 configOptions。
- 回合级 `PromptResponse.usage` 与五种 `stopReason` 在真实 agent 上各触发一次（31）。
- 五 agent 全通矩阵逐格实测并记录。

**验收要点**

1. § 4 矩阵 5 × 7 全绿，每格记命令 / 截图 / 输出路径。
2. pi-acp：`--terminal-login` → `/` 菜单出现 agent 的 slash 命令并可发 → 关闭应用重开 → 侧栏点击 → `session/load` 重放后转录与关闭前一致。
3. `session/load` 重放 200+ 条更新时投影层结果与实时到达一致（R2 的分批 / 整批测试扩到真实历史）。
4. 无 `sessionCapabilities.delete` 的 agent 侧栏不出删除图标（04 的注释）；有的 agent 删除后本地索引与 agent 侧都不再列出。
5. 五种 `stopReason` 的结束行样式与 31 一致（`refusal` / `max_tokens` 用 fixtures 补触发不到的）。

**裁定（开工前）**：本地索引与 `session/list` 的合并规则 —— 已裁定 2026-09-15 按推荐（落 `docs/design.md` § 3）：侧栏以本地索引为准，`session/list` 只用来校对存在性与补标题；agent 有、本地没有的会话不自动出现在侧栏（避免把 agent 在别处建的会话混进来）。

**契约变更**：`docs/design.md` § 3 命令补 `session_resume` / `session_delete`，`session_list` 补分页参数。

### R7 zed-agent-acp sidecar

**目标**：按 `docs/design.md` § 8 把 Zed 内置 agent 以独立进程接进来，与其他 agent 走完全相同的路（主进程无 gpui，规则 5）。

**交付物**

- `sidecar/zed-agent-acp/`：独立 cargo workspace，path 依赖 `vendor/upstream/zed/crates/*`，GPL-3.0-or-later；复制 `eval_cli/src/headless.rs`（头注释标来源）；rust-sdk Agent 角色实现 `initialize`（固定能力）/ `session/new` / `load` / `list` / `prompt` / `cancel` / `set_mode` / config options（→ `model_selector` 与权限预设）；`ThreadEvent` → `session/update` 翻译；`ToolCallAuthorization` → `session/request_permission` 并写回 `response`；`Elicitation` → `elicitation/create`；`Stop` → `PromptResponse`；`ThreadEnvironment::create_terminal` 用 Zed `terminal` crate 进程内实现。
- 主程序：按可执行文件相对路径定位 sidecar，注册为内置的 custom 型 agent（41 新建会话列表出现 Zed Agent，70 设置里可见、不可删）；sidecar 缺失时静默不列出。
- `windows/runner/CMakeLists.txt` install 规则把 `zed-agent-acp.exe` 放到应用目录旁（macOS / Linux runner 对应）。

**验收要点**

1. sidecar 冷编译在本机通过，时长与磁盘占用记任务卡；`cargo tree -p bridge` 仍无 gpui。
2. `acp-smoke --agent zed` 一轮含工具调用与权限；在 Flutter 里：新会话 → 对话 → 终端卡 → 取消 → 关闭重开后 `session/load`。
3. 与运行中的 Zed 同时打开 `threads.db` 的行为实测（读、写、锁），据此裁定共用 / 隔离并写回 `docs/design.md` § 8。
4. 主程序无 sidecar 时功能不受影响。

**裁定（开工前）**：`threads.db` 与 `settings.json` 共用还是隔离 —— R7 实测 2026-09-17 共用会让运行中的 Zed 报 `database is locked`，按推荐项落地「配置共用、数据隔离」（`--zed-settings` 只读沿用 + `--user-data-dir <数据目录>/zed-agent`），已写 `docs/design.md` § 8，**待所有者确认**；模型密钥来源沿用 Zed 的 `settings.json` / 环境变量，不做额外配置页（70 没有）—— 已裁定 2026-09-15，落 `docs/design.md` § 8。

**契约变更**：无（sidecar 走标准 ACP）。

### R7.5 组合根拆分（纯代码结构轮）

**目标**：`lib/app/workbench_controller.dart`（基线 `5a001bf`：2645 行、1 个 `ChangeNotifier`、103 个公有方法、19 段）拆成组合根 + 8 个各管一段的对象（`shell` / `workspace` / `index` / `agents` / `auth` / `composer` / `turn` / `session` + 共用的 `GuardedNotifier` mixin），**行为零变化**；拆完组合根 ≤ 450 行、`lib/app` 无文件超 900 行、子对象只允许单向依赖、没有子对象 import 组合根。依据：R3 起的增长曲线（901 → 2642）、19 段耦合矩阵两极分化（约 1250 行咬合 / 约 700 行合租）、BACKLOG 17 条相关项里 8 条逻辑缺陷全出在共享 `agentId` / `sessionId` / `store` 的段落。

**交付物**：`lib/app/` 新增 `guarded.dart` / `shell_state.dart` / `workspace_state.dart` / `session_index.dart` / `agents_state.dart` / `auth_state.dart` / `composer_state.dart` / `turn_controller.dart` / `session_controller.dart`；`workbench_controller.dart` 只剩接线与生命周期；`workbench_screen.dart` / `headless_run.dart` / `test/` 只改成员引用路径（改名表在任务卡附录 A）。不产出新桥命令、新 `_meta` 键、新依赖。

**验收要点**：① `git diff main...HEAD -- lib/ui lib/theme lib/projection lib/bridge rust test/fixtures pubspec.yaml` 为空；② validate 全绿；③ 测试只改路径、用例数与 `expect(` 不变；④ fake-agent 的 `ACP_R3/R5/R6_REPORT` 与基线逐步骤等价；⑤ 行数门与依赖方向门；⑥ Windows 真跑 + 所有者手测弹层锚点搬家后的画板 40 / 41 / 42 / 25 / 05 / 06。

**裁定（开工前，任务卡「裁定门」六项，各有推荐 + 备选）**：编号 R7.5 还是 R9；粒度 8 对象还是保守 3 对象；直接访问子对象还是保留转发门面；通知策略阶段 B 先量后动还是必做；本轮是否顺手修缺陷（推荐不修，紧接 R7.7 修 8 条；R7.6 已被字体切换占用）；validate 是否加行数门与依赖方向门。

**契约变更**：无。文档同步：CLAUDE.md 仓库结构 `lib/app/` 行、本文 § 2 的 `lib/app/` 描述、`docs/design.md` § 9 加「组合根分层」一条。

### R8 打包与发布

**目标**：Windows 免安装 zip 与安装器，sidecar 随包；macOS 构建；LICENSE 与派生文件清单；在只有系统 Node 的干净 Windows 上，从 registry 安装到发出第一条 prompt 不看文档（`docs/requirements.md` 验收视角）。

**2026-09-20 起按所有者指示拆两步做**：**R8 Windows 端**（本轮，任务卡 `rounds/round-08/round-08.md`）＝ 版本解耦 + Windows 打包与产物验收；**macOS / Linux 留给后续一轮**（`flutter build macos`、原生 traffic lights、sidecar install 规则）。

**交付物（Windows 端）**

- **sidecar 版本与应用解耦**（本轮新增，起因是发一次应用版本要白等一刻钟的重链）：`sidecar/zed-agent-acp/Cargo.toml` 的 `version` 改为跟 **zed 钉版本**走（`pins/upstream.json` 的 zed 条目新增 `version` 字段），`scripts/validate.ps1` 加「版本门」核对四个数，落 CLAUDE.md **规则 11**；`--version` 输出带钉的 zed commit（`build.rs` 注入 `ZED_PINNED_COMMIT`）。
- `scripts/package.ps1`（**没有**扩进 `build.ps1`，见任务卡「偏离」）：zip（含 / 不含 sidecar）+ Inno Setup 安装器 → `dist/`；`packaging/windows/acp-agent-client.iss` 是 per-user、不签名的安装器脚本。
- `scripts/verify-package.ps1`：打包产物的自动化验收（空 `%APPDATA%` 上无头往返、随包 sidecar `--version` / `--selftest`、安装器静默装 → 跑 → 静默卸）。
- 版本号与构建信息：画板 70 没有版本位，按规则 3 **只进日志** —— 起核心时写一行 `core  AcpAgentClient <版本> (release, windows/x86_64) data=… sidecar=…`（`rust/acp-core/src/{log.rs,core.rs}`，落 `docs/design.md` § 10）。
- `LICENSE`（GPL-3.0-or-later）+ `NOTICE`（Zed 派生文件清单）已随 v1.0.0 落地；本轮把 `NOTICE` 与头注释扫描的**双向**一致核对加进 validate，并让两份文件随包分发。
- README 的「状态」与「构建与运行」更新（加打包段与版本号两处的说明）。

**验收要点**

1. ~~干净 Windows VM~~ → 所有者裁定 2026-09-20「只做自动化」：`verify-package.ps1` 在**全新空数据目录**上跑通 zip 与安装器两条路（真·干净 VM 不列为待办）。
2. zip 与安装器体积、含 sidecar 与不含 sidecar 两个数字。
3. ~~macOS~~ → 挪到后续一轮。
4. `validate.ps1` 全绿；`NOTICE` 与头注释扫描一致（本轮起由 validate 双向核对）。
5. 版本解耦成立：抬应用版本后 `build-sidecar.ps1` 判 fresh、不重链（数字记任务卡）。

**裁定（2026-09-20，所有者）**：sidecar 版本**跟 zed 钉版本走**；干净机验收**只做自动化**；安装器 **Inno Setup · per-user**（免 UAC、不签名）；本轮只做 Windows 端。

**契约变更**：无（CLAUDE.md 加规则 11 是开发约定，不是线上契约）。


## 4. 五 agent 全通矩阵（R6 收口）

七步来自 `docs/requirements.md` § 必须 第 3 条。格子里写「首次打通的轮次」，R6 全部重跑一遍；R7 加 Zed 行（逐格证据在 `rounds/round-07/round-07.md`「本轮实测」）。

| agent | 安装 | 认证 | 新会话 | 一轮含工具与权限 | 终端 | 取消 | 重开并加载历史 |
|---|---|---|---|---|---|---|---|
| claude-agent-acp（npx） | R5 | R5（agent / terminal 型；env 也认） | R4 | R4 | R4（交互 + 后台） | R4 | **R6 ✅** |
| codex-acp（npx） | R5 / **R6 重跑 11.4 s** | R5（本机网关，不要求登录） | R5 / **R6** | R5 | R5 | R5 / **R6（`cancelled`）** | **R6 ✅**（25 条 slash 命令随 load 回来） |
| Cursor（binary） | R5 / **R6 重跑 159 s / 74 MB** | **R6：本机 `cursor-agent` CLI 已登录，凭据共用，`session/new` 直接成功**（R5 的浏览器登录不再阻塞） | R5 / **R6** | R5 | R5（fs / terminal 可为 false） | R5 | **R6 ✅**（只声明 `list`，≡ 菜单三行都不渲染） |
| pi-acp（npx） | R5 / **R6 重跑 5.8 s** | **R6：本机 `pi` CLI 已配好，`--terminal-login` 没走到**（R5 卡在没装 pi，已不成立） | **R6 ✅** | **R6 ✅** | 不适用（不用客户端终端） | R5 | **R6 ✅**（`session/load` + 8 条 slash 命令） |
| dsh-acp-interactive（custom；2026-09-17 起核心内建条目） | R3（settings 手填）/ R5（70 编辑）/ **2026-09-17 内建免配置**（`ACP_DSH_PATH` → PATH 上的全局安装 → `npx` 三路回退；只有受管 Node 的机器拉不起，记 BACKLOG） | R1（terminal auth `--setup`） | R1 / **R6** | R1 / R3 | R4 | R1 / R3 | **R6 ✅**（`session/load` + 5 条 slash 命令）。**本机模型网关 404，R6 拿不到它的 `stopReason` / usage** |
| zed-agent-acp（sidecar） | **R7 ✅**（随包：CMake install 到应用目录旁，核心按相对路径定位） | **R7 ✅**（无 `authMethods`；模型与密钥经 `--zed-settings` 只读沿用 Zed 的 settings.json，14 个模型可用） | **R7 ✅** | **R7 ✅**（terminal 工具 + `session/request_permission`，选项按 optionId 去重） | **R7 ✅**（进程内 Zed terminal，输出走 `_meta.terminal_*` 三键） | **R7 ✅**（`cancelled`） | **R7 ✅**（`session/load` 重放，11/12 行与实时一致，差的一行是 R6 已裁定的轮边界限制） |

R6 的逐格证据（报告 JSON 路径、能力声明、重放 digest 比对、踩到的坑）在 `rounds/round-06/round-06.md`「本轮实测」。

## 5. 契约与文档同步清单

2026-09-15 所有者按推荐项批了 § 6 的 9 项与 R0 的 3 项之后，下表中 R0 / R2 / R3 / R4 / R6 的 `docs/design.md` 改动（§ 2 / § 3 / § 4 / § 9 / § 10）与 CLAUDE.md 规则 1 的 `flutter_svg` 已一次写入，各轮只需实现；仍列出以便核对。R1 的 payload 补充也已并入 § 3。

| 轮 | `docs/design.md` | 其他 |
|---|---|---|
| R0 | § 2 Dart 类型来源（已回填 2026-09-15） | CLAUDE.md 规则 1 已加 `flutter_svg`、「本地开发」已定 `CARGO_TARGET_DIR`；`rounds/BACKLOG.md` 三条已关闭 |
| R1 | § 3 `acp/agent_state` payload、requestScope、本地 cancelled 态（`acp-projection.md` § 11 第 5 条） | `rounds/BACKLOG.md` `notice` 条目复议 |
| R1.5 | — | CLAUDE.md 规则 1、`docs/requirements.md` § 8 允许清单 |
| R2 | § 4 入站 `_meta` 识别键（若裁定） | `rounds/BACKLOG.md` 子代理条目关闭；画板 15 / 32 若改设计稿则更新 `design/README.md` |
| R3 | § 3 workspace / git / session_index / fs_list_dir / fs_search；§ 9 页面清单补项目与分支切换 | 画板 40 若删 Symbols / Selection 则重导 PNG |
| R4 | § 3 本地 shell 四命令与 `acp/terminal_output` payload；§ 7 截断与留存 | `rounds/BACKLOG.md` git 徽章条目关闭 |
| R5 | § 3 `registry/progress` 与四命令；§ 5 requestScope 落点 | — |
| R6 | § 3 `session_resume` / `session_delete` / 分页 | — |
| R7 | § 8 `threads.db` 裁定结果（已落 2026-09-17：配置共用、数据隔离，待所有者确认） | `rounds/BACKLOG.md` 争用条目已关闭；新增 6 条 R7 已知限制 |
| R7.5 | § 9 加「组合根分层」一条（收口时） | CLAUDE.md 仓库结构 `lib/app/` 行；本文 § 2 `lib/app/` 描述；`rounds/BACKLOG.md` 立项条目关闭、17 条相关条目各补「新家」；若裁定加门则 `scripts/validate.ps1` 两个 Step |
| R8 | — | README、LICENSE、NOTICE |

## 6. 设计稿之外与待裁定汇总

画板里有、文档里没有或与文档冲突的 9 项，全部已记 `rounds/BACKLOG.md`，这里只给归属轮与推荐：

| # | 项 | 画板 | 阻塞轮 | 推荐 | 裁定 |
|---|---|---|---|---|---|
| 1 | 项目切换与分支切换 / 新建（git） | 41、04 | R3 | 做；git CLI 子进程；项目 = 目录 | 2026-09-15 按推荐，落 design.md § 2 / § 3 / § 9 / § 10 |
| 2 | `+` 弹层的 Symbols / Selection | 40 | R3 | 改设计稿删除（与「不做 LSP / 编辑器」冲突） | 2026-09-15 按推荐，画板 40 已删并重渲染 |
| 3 | `Rules · 1 global rule` | 30、40 | R3 | 规则文件计数 + 打开 | 2026-09-15 按推荐，落 design.md § 9 |
| 4 | `/` 菜单分组 | 42 | R3 | 单组 | 2026-09-15 按推荐，画板 42 已改并重渲染，落 design.md § 3 |
| 5 | 自绘窗口控制（无边框窗口） | 01–04、50、60、61 | R3 | runner 平台通道自写 | 2026-09-15 按推荐，落 design.md § 9 |
| 6 | 本地交互 shell 与四个桥命令 | 61 | R4 | 做 | 2026-09-15 按推荐，落 design.md § 3 |
| 7 | 文件树 git 徽章 | 60、03 | R4 | 保留 | 2026-09-15 按推荐，落 design.md § 9 |
| 8 | 子代理卡的入站 `_meta` 键 | 24 | R2 | § 4 增识别键节 | 2026-09-15 按推荐，落 design.md § 4 |
| 9 | Restore / Regenerate 的协议语义 | 10、11 | R2 | 照原型（本地截断），记已知限制 | 2026-09-15 按推荐，落 design.md § 3 |

库选型 5 项（Markdown、高亮、数学、Mermaid、音频）与 diff 库已随 R1.5 spike 于 2026-09-15 按推荐项裁定进规则 1 清单（`rounds/round-1.5/spike.md` § 0）；`flutter_svg` 同日进清单。

**不在本计划内**（要做先改设计稿或所有者裁定）：深色主题页面（`00-tokens` 只备色阶；**外观设置里的字体切换已于 2026-09-20 由所有者裁定移出本行，见 R7.6**）；`uvx` 分发；Gemini CLI；JetBrains AIR `_meta` 扩展（子代理独立会话、async task、quota）；Zed 的 Edits 审阅条；Web / 移动版。

## 7. 进度表

每轮收口时更新：状态、分支、画板阶段收口提交、合并提交、审查轮数与执行器。

| 轮 | 状态 | 分支 | 画板阶段收口提交 | 合并 `main` 提交 | 审查（轮数 / 执行器） | 备注 |
|---|---|---|---|---|---|---|
| round-design | 已完成 | main | — | 72e2be1 | 设计稿审核 2 轮（主会话） | 40 张画板入库 |
| R0 | 已完成 | `round-00` | —（R0 无画板阶段） | ddf22b3 | 5 轮 / cursor 两次空输出（`--plan` 误判，旁路会话已修为 `--mode ask`）→ Claude Code 子代理（第 1 轮 Fable 5.1，第 2–5 轮 opus）；18 条全部关闭 | 任务卡 `rounds/round-00/round-00.md`；Rust 核心不走 pub 插件（runner CMake 直接 apply_cargokit，见任务卡「偏离」）；IME 实测待所有者手测 |
| R1 | 已完成 | `round-01` | —（R1 无画板阶段） | 5466609 | 3 轮 / 第 1 轮 Claude Code 子代理（opus；cursor 因 Zed 占 `cli-config.json` 启动 EPERM）→ 第 2–3 轮 cursor CLI（`--mode ask`）；6 条（high 3 / P3 3）全部关闭 | 任务卡 `rounds/round-01/round-01.md`；6 项验收全过（dsh 真跑 4 轮 + fake agent 离线链 + npx `.cmd` 中文路径）；ConPTY 启动探询、dsh `--setup` 提示不可见、taskkill 收尾三条记 BACKLOG |
| R1.5 | 已完成（裁定 2026-09-15 按推荐项） | `round-01.5`（worktree，不合并；spike 收口提交 32f122f） | —（无画板阶段） | —（不合并；`rounds/round-1.5/` 以纯文档进 `main`） | 2 轮 / cursor CLI `--mode ask`（第 1 轮 adversarial：4 条 P2 3 / P3 1 + 4 条取舍质疑；第 2 轮：1 条 P3；全部采纳） | 任务卡 `rounds/round-1.5/round-1.5.md`；`spike.md` § 0 六项各一个推荐 + 备选（Markdown：`package:markdown` + 自写渲染；高亮 `re_highlight`；公式 `flutter_math_fork`；Mermaid `mermaid_flutter` + `mermaid_core`；音频 `audioplayers`；diff `diffutil_dart`），截图 19 张、测量 7 份 JSON；裁定后落 CLAUDE.md 规则 1 / `docs/requirements.md` § 8 / BACKLOG |
| R2 | 已完成 | `round-02` | 98e4cea | 050003a | 3 轮 / cursor CLI `--mode ask`（第 1–2 轮全量 `main...HEAD`：6 条 high 1 / P2 4 / P3 1，5 条 high 1 / P2 4；第 3 轮只审整改 diff：0 条；11 条全部采纳） | 任务卡 `rounds/round-02/round-02.md`；6 项验收全过（投影单测 § 7 七项 / § 2.2 / § 3.1 / § 8.3 + 分批与整份回放等价；25 张画板 gallery 逐张对照、偏离逐板记卡；validate 全绿、pubspec 只有裁定的 9 库 + `objective_c` override；1,000 块滚动数字见卡；子代理只按 `docs/design.md` § 4 入站 `_meta` 键分组；跨消息选择实测）；fixtures 新增 15 文件 148 行；跨轮问题 6 条记 BACKLOG（fixtures.rs 方法表缺两条通知、画板 27 占位文案、画板 33 / 34 措辞、画板 15 elk 布局、画板 31 请求次数、7 个局部几何常量） |
| R3 | 已完成 | `round-03` | dc4de5e | 4b888d7 | 3 轮 / cursor CLI `--mode ask`（第 1–2 轮全量 `main...HEAD`：7 条 high 2 / P2 5，2 条 P2；第 3 轮只审整改 diff：0 条；9 条全部采纳） | 任务卡 `rounds/round-03/round-03.md`；10 项验收里 8 项自动化通过（dsh 真跑 + fake-agent 离线链 + Win32 API 核对无边框窗口），窗口拖拽 / 三键与 `file_selector` 三个对话框待所有者手测（本机 computer-use 认不出自建 exe，没有 GUI 自动化通道）；接线阶段抓出并修掉 4 个缺陷（`acp/session_update` 信封形状核心与 Dart 差一层嵌套是 R2 遗留真 bug）；新增无头实跑口子 `ACP_R3_REPORT`；跨轮问题 8 条记 BACKLOG |
| R4 | 已完成 | `claude/r4-implementation-76608e`（Claude Code 桌面端 worktree 分支，≙ `round-04`） | 5380c03 | 8cef00f | 4 轮 / cursor CLI `--mode ask`（第 1–2 轮全量 `main...HEAD`：6 条 high 2 / P2 4，1 条 P2；第 3 轮只审整改 diff：0 条；第 4 轮合并 main 之后再全量：2 条 P2，所有者裁定非阻断记 BACKLOG；7 条全部采纳） | 任务卡 `rounds/round-04/round-04.md`；8 项验收全过（fake-agent 走完 `fs/*` 与 `terminal/*` 六个真回调 + 停止方块 + Follow + 本地 shell + 收尾；claude-agent-acp 0.76.0 的 diff 卡 + `_meta` 终端卡；dsh 1.3.0 的 `_meta` 终端卡 + read 定位；gallery 60a / 60b / 61a / 61b / 03 对照、接线阶段 `lib/theme` / `lib/ui` 零 diff；validate 13 项 PASS + smoke）；订正事实：钉版本的两个参照 agent 都不调客户端 `fs/*`，走 `_meta.terminal_*` 三键（待所有者确认）；Windows 实测抓出 portable-pty 0.9.0 的 kill 成败判反、xterm.dart 重复应答 ConPTY 探询两个坑；R5 并行合入 main 后本分支手工解 18 个文件冲突再全量复审；跨轮问题 1 条记 BACKLOG |
| R5 | 已完成 | `round-05` | 5a9c5a6 | b1339c8 | 3 轮 / cursor CLI `--mode ask`（第 1–2 轮全量 `main...HEAD`：3 条 high 1 / P2 2，2 条 P2；第 3 轮只审整改 diff：0 条；5 条全部采纳） | 任务卡 `rounds/round-05/round-05.md`；7 项验收全有证据：fake-agent 两种认证离线确定性 + codex-acp / Cursor / pi-acp 真跑（安装、`-32000` → 认证页、Zed 导入 5 条、Remove、受管 Node、断网），其中 Cursor / codex 的浏览器登录与 `OPENAI_API_KEY` 路径待所有者手测；新增无头口子 `ACP_R5_REPORT`（含按步骤取消）；Zed `node_runtime` 等改为参考转写待所有者确认（`docs/design.md` § 2）；跨轮问题 10 条记 BACKLOG；与 R4 并行开发（基于 `main`，右栏文件 / 终端标签归 R4） |
| R6 | 已完成 | `claude/r6-development-e3bd8c`（Claude Code 桌面端 worktree 分支，≙ `round-06`） | —（R6 无画板阶段） | 681a7e2 | 5 轮 / cursor CLI `--mode ask`（第 1–2 轮全量 `main...HEAD`：7 条 high 2 / P2 4 / P3 1，3 条 P2；第 3–5 轮只审整改 diff：2 条 P2 1 / P3 1，**0 条**，**0 条**；12 条里 11 条采纳整改、1 条设计取舍所有者已裁定） | 任务卡 `rounds/round-06/round-06.md`；7 项验收全过（会话生命周期五命令 + 侧栏 / ≡ 菜单按能力裁剪 + modes 回退 + `session/list` 校对 + 290 条重放等价 + 五 agent 真跑矩阵）；真跑抓出 5 个真缺陷（resume 不能对活着的会话发、list 校对的 cwd 口径、重连后 requestId 复用、resume 空响应抹掉 modes、重放前清空会闪 UI）；两项裁定 2026-09-16：① ≡ 保持右栏开关、会话菜单要入口先改设计稿（本轮把菜单动作接通并做了单测，产品 UI 里只有 Delete 有入口，Resume / Close 等改完画板那一轮）；② `session/load` 重放不带回轮边界，记已知限制不在本地补（落 `docs/design.md` § 3） |
| R7 | 已完成 | `claude/r7-implementation-f52398`（Claude Code 桌面端 worktree 分支，≙ `round-07`） | —（R7 无画板阶段） | 44cd33a | 4 轮 / cursor CLI `--mode ask`（第 1–2 轮全量 `main...HEAD`：3 条 high 1 / P2 2，2 条 high 1 / P2 1；第 3–4 轮只审整改 diff：1 条 high，**0 条**；6 条全部采纳整改） | 任务卡 `rounds/round-07/round-07.md`；sidecar 是独立 cargo workspace（`sidecar/zed-agent-acp/`，`agent-client-protocol` 用 crates.io `=2.0.0` 与 zed 钉版本对齐，规则 10）；7 项验收全有证据；`threads.db` 实测后按推荐项改成「配置共用、数据隔离」（落 `docs/design.md` § 8，**待所有者确认**）；未带 `languages` crate（VS Spectre 组件缺失，记 BACKLOG）；实跑 + 自查 + 审查共修掉 10 个缺陷（终端卡与 diff 卡拿不到数据源、权限选项 id 重复会放大授权、close/delete 停不掉在途回合、delete 被释放时的保存写回、`release_and_wait` 没真的等到释放、`session/list` 把读失败报成空表等）；第 3 轮首发时 cursor 掉线卡死，重发即恢复（未回落子代理） |
| main 直改（R7 后） | 进行中（2026-09-17 起） | `main` | —（画板 05 / 06 随修复一起入库） | 直接提交 `main`（`44cd33a..HEAD`） | 2026-09-17 两轮 / cursor CLI `--mode ask`（全量 `44cd33a..HEAD`：2 条 P2 1 / P3 1，复审 0 条；产物在 `.claude/reviews/20260917-15*`）。之后各批由所有者逐批指示是否构建、是否走审查：走了的按「发布前审查 → 整改 → 复审」记在提交说明（执行器未逐批记，`.claude/reviews/` 里没有再落产物），未走的在提交说明写明「未构建 / 未审查（所有者指定）」 | 所有者手测报障的修复（按提交顺序）：侧栏删除确认弹层、弹层位置与锚点、用户消息本地回显（`acp-projection.md` § 7 第 8 条）、转录跟随、终端面板硬件按键 + `TerminalIme`、Enter 发送、agent 自己的 logo（侧栏 / 新建弹层 / 空态）、正式 logo 与 `.ico`、右栏去关闭键 / 设置改右栏标签 / 树列可拖、无边框窗口缩放与双击、`@` `/` 键盘导航与裸 `@`、画板 10 废弃、内建 dsh 条目与 DeepSeek 图标（pins 加 `deepseek-harness`）、画板 05 转场 + 新建会话等待期、画板 06 活动指示、Noto Sans SC、图片粘贴与芯片条、一轮失败原因落结束行、弹层封顶滚动 / Esc / 点外面关、终端卡自动收起、14 个 tooltip、会话配置固定档序平铺、新建会话不重连、sidecar 孤儿进程；2026-09-18 五个并行会话的改动合并（16af3d1 侧栏按用户最后发消息时间倒序 + 权限卡范围下拉浮到 Overlay（e6b074f 是空提交，内容随 16af3d1 落地）、354d71d Restore / Regenerate 改按用户气泡定位、0945c42 侧栏只留当前 workspace 的会话 + 换项目时放下别的目录的会话、aa98275 文档同步）：所有者指定由主会话自审（cursor 未用），4 条采纳整改随一个提交落地（收轮写索引不再盖掉发消息时打的时间、换项目撤掉离开侧栏那条的改名态、等待期里不换项目、改名从索引取计数与 cwd），3 条记 BACKLOG；validate 全绿后构建并替换 `D:\tools\AcpAgentClient`。设计稿待补的注记记 BACKLOG（清单见 `design/README.md` 变更记录）；2026-09-20 深色下 agent 图标与应用标记看不见（所有者手测报障，未构建 / 未审查（所有者指定））：registry 缓存的 `icon.svg` 与内置那两张全是单色 `fill="currentColor"`，不给 `SvgTheme` 时 flutter_svg 按纯黑画 → `tokens.dart` 加 `SvgTint.mark`（随主题取 `Neutral.strong`），`AgentMark` / `NewSessionEmpty` / `AgentIconBox` 三处传上；应用标记另有一条：调用点写的是 `const AppLogo()`，换主题时父级重建被 `identical` 跳过、颜色冻在浅色那一套上 → 构造函数去 `const`；2026-09-22 画板 43 时间线点非首屏的行会白屏闪烁并停在错位置（所有者手测报障，未构建 / 未审查（所有者指定））：`workbench_screen.dart` 原来按 `maxScrollExtent * index / count` 估位、多帧纠正，而惰性列表的 `maxScrollExtent` 对没建出来的那截是按已建行的平均外推的（`SliverMultiBoxAdaptorElement._extrapolateMaxScrollOffset`），已建窗口只剩一行巨高行时会暴涨（复现实测 27292 → 230347），落点被抛到真实内容末端之外、sliver 的 `paintExtent` 归零 = 整片白屏，下一帧夹回来又跳出去，8 帧耗尽后停在越界位置 → 新建 `lib/app/transcript_jump.dart`（`TranscriptJump`：锚在 `RenderSliverMultiBoxAdaptor` 的 `firstChild` / `lastChild` 这两行当帧真正布好局的行上，按它们量到的真实几何一屏一屏单向步进，落点永不超过锚行底边所以不白屏、方向定死且每帧必有推进所以不发散），`workbench_screen.dart` 只留接线（950 → 919 行，仍在 R7.5 行数门的 1000 之内）；`test/app/timeline_wiring_test.dart` 补 3 个长会话用例（从底部跳中间轮用户消息 / 跳中间轮 A 行 / 从顶部往下跳），逐帧断言 `paintExtent > 0` 与落点 = `Spacing.s16` ±0.5，已验证修前代码在第 2 帧 `paintExtent == 0` 失败；2026-09-22 添加工作目录 / 切项目时界面假死数百毫秒到数秒（所有者报障，未构建 / 未审查（所有者指定））：`WorkspaceState.openProject` 把 `workspace_open` + `refreshBranches` + `refreshRules` + `files.setProject` 串在一个 `await guard` 里，`touch()` 只在最后一次，而 `_onProjectChanged()` → `SessionController.enterWorkspace()` 本身不通知 —— 于是从点下目录到顶栏项目名 / 输入框 `canCompose` 有反应，要等完 6 个 git 子进程（分支 3 个、`git_status` 3 个）+ 2 次目录列举 + 起 `fs_watch`（`vendor/upstream/zed` 那种大检出实测中位 531 ms，冷启动按单条命令量约 2.5 s）。改成 `workspace_open` 一回来就 `touch()`（那一步只是往 `projects.json` 写一条），其余三件 `Future.wait` 并发、各自完成各通知一次，配 `_openEpoch` 序号 + `refreshBranches` / `refreshRules` 回来核对 `project?.path` 防连点竞态。**并发本身不省总时长**：release 无头二进制交替 A/B 各 12 轮（项目自己的 R3 驱动，数据目录隔离），中位 531 → 514 ms、尾部更抖，这些 git 命令瓶颈在进程拉起与磁盘，并发只是抢同一个瓶颈；收益全在「等多久才有反应」，留并发是为了分步显示（分支切换器不必等文件树的 `git_status`）。同批另三处：`FilesState.refreshBadges` 加防重入 + 尾随补跑（`fs_watch` 在 Rust 侧已有 250 ms 合批，但一批没刷完下一批就到的仓库上仍会叠起几路 `git.exe`）；`FilesState.setProject` 加 epoch 守卫，修掉并发换项目时旧一轮把新的 `_watch` 订阅挤掉（被挤掉那条既不 cancel、Rust 侧也收不到 `fs_unwatch`）；`WorkbenchController.start()` 把 `shell.restoreUiState()` 提到 `restoreLastProject()` 之前，冷启动第一屏的三栏宽度不再跳一次；`rust/registry/src/node.rs` 给系统 Node 探测加缓存（std `Mutex`，无新依赖），`locate`（每条 `agent_connect` 都走）不再每次拉 `node --version`（本机实测 28.8 ms/次），`status`（画板 51 的 Node 状态与刷新）仍每次实探并回填，`locate` 也改成只在系统 Node 用不上时才探受管 Node。`validate.ps1 -Quick` 全绿、`cargo test --workspace` 与 `cargo clippy --all-targets -- -D warnings` 全过、`flutter test` 348 项通过（新增 2 条回归：换项目那条断言 `workspace_open` 回来时通知数 > 0，已验证改前是 0 会红；徽章那条断言并发刷新只发一个 `git_status`）；2026-09-22 cursor 九条 findings 的验真与修复（分支 `claude/cursor-issues-verification-1d6a1e`，**已构建（validate 全绿）/ 未审查（所有者指定）**）：逐条核对后 6 条属实已修、2 条半属实（另一半不成立）、1 条低危记账。① `session/load` 抹掉别的会话的终端画面（cursor 判高）—— `Sessions.terminals` 是跨会话共享的一张表（`acp/terminal_output` 事件不带 sessionId，只能按 terminalId 索引），而 `SessionStore.resetForReplay()` 调的是全局 `clear()`，并跑时对 A 做 `session/load` 会把 B 正在跑的工具终端缓冲一起抹掉（旁边的 `pending.forgetSession(sessionId)` 本来就是按会话的，对比之下是漏网）；改成按 `ownedTerminalIds`（本会话登记过的 ∪ 本会话工具卡 `terminalIds` 上挂着的）只删自己那几个，`TerminalStore.clear()` 整个删掉让「不能全清」由编译器守着，`debugSnapshot` 的 terminals 一并收敛到本会话。② 核心 `on_elicitation` 缺 cancel 期守卫 —— `on_permission` 有 `is_cancel_pending` 就地回 cancelled，elicitation 没有，于是发出 cancel / close **之后**才到的那条谁都不认领：前端三条路（`turn.cancel` / `closeSession` / `deleteSession`）是按当时的队列快照逐条回的，看不见这条，agent 一直等、连后面的 `session/close` 都不返回（R6 修掉的双边挂死只剩 elicitation 那半边）；补上同一条守卫，`rust/acp-core/tests/scripted.rs` 的 cancel 场景加一条「cancel 后才发的 elicitation」（没守卫这条测试直接挂死）。③ agent 进程退出后权限卡仍可点 —— `Shared::finish` 清了核心的挂起表只发 `exited`，前端队列项还是 pending，点下去撞 `unknown_request`；收到 `acp/agent_state: exited` 时把该 agent 的挂起项标 `withdrawn`（UI 已有这一态，不新增设计），不发 `acp_respond`。④ `build-sidecar.ps1 -Selftest` 不传 `--user-data-dir`，自检写进本机 Zed 的数据目录（违反规则 7，还会和正在跑的 Zed 抢 `threads.db`）；补上并一起补 `--zed-settings`（只给前者会让自检从空目录读配置、报 `models: 0`，那行就白报了），实跑确认 7 个文件落隔离目录、`models: 14`。⑤ `fs` 的 symlink TOCTOU —— 新增 `resolve_inside`，边界判定用 canonicalize 过的真实路径、读写按那一份开；**只收窄未堵死**，canonicalize 与 open 之间换掉某一级目录仍逃得出去，要堵死得句柄级逐段打开（std 没有这套 API、手写要 `unsafe`，规则 6），残余与威胁模型（agent 是本机子进程、同权限，绕开回调直接读写本就没人拦）写在注释与 BACKLOG。⑥ `stampPromptSent` 与 `deleteSession` 竞态（幽灵侧栏条目）—— 墓碑法：`remove` 先立 `(agentId, sessionId)`，upsert 落地后发现被删就把那行再删一次，两种到达顺序都收敛；先试的「三条写命令排队」作废，它会让收轮那次 await 的 `saveIndex` 挡在发消息那次不 await 的写后面，现成的 `_LaggyIndexCore` 用例当场 30 秒超时。**不成立的两条**：tar 成员路径逃逸——系统 tar 拒绝含 `..` 的成员、剥掉开头的 `/`，实测手写的恶意包一个字节都没落到目标目录外，补了回归用例把这个隐式依赖钉住（换解压器或加 `-P` 都会红）；无头应答只看当前会话——验收脚本本来就只跑一条会话。**记 BACKLOG 6 条**：后台会话挂起项在界面上无痕迹（要先改设计稿）、registry 无 sha256 时的 `verify_note` 没有出口、TOCTOU 残余、环境依赖测试跳过仍绿、gallery 只断言 PNG 非零、`validate.ps1` 的 `_meta` 门按子串扫会误报 `symlink_metadata`。合并 main（画板 43 + 切项目假死）后重跑 validate 全绿（`flutter test` 355 项，新增用例 6 条），那两个直改提交也是第一次被编译与跑测试 |
| 画板 43（会话时间线） | 已完成 | `session-timeline` | `42ad9fc`（画板 43 拉回 + 01 / 02 / 03 补 history 按钮） | `867251b` | 3 轮 / cursor CLI `--mode ask`（第 1–2 轮全量 `main...HEAD`：各 1 条 P2；第 3 轮只审整改 diff `e44620d..HEAD`：0 条；2 条全部采纳整改） | 简报 `design/round-design/input/revision-03.md`；两条 P2 是同一条路径的两半 —— 弹层原用 `HardwareKeyboard` 全局处理器接键，而全局处理器**挡不住焦点链**（`KeyEventManager` 跑完它还会无条件再发给焦点链），Enter 因此落到输入框被当成「发送」把草稿发出去；改成弹层自己拿焦点后，Tab / 左右键又经默认 Shortcuts 把焦点交回输入框，最终改为除 Esc 外一律 `handled`。`autofocus` 在这里不兑现的真因是域里已有 `focusedChild`（复审订正）。validate 13 项全绿、`flutter test` 294 项通过（新增 37 项）；**未构建、未手测** |
| 画板 07（深色模式） | 已完成 | `claude/dark-mode-toggle-implementation-e028d0`（Claude Code 桌面端 worktree 分支） | `0977cde`（画板 07 拉回 + 实现） | `1420556`（合 main 前先 `46d3952` 把 main 的 Thread → Session 收敛合进分支，唯一冲突是 `design/README.md` 变更记录顶部） | 4 轮 / cursor CLI `cursor-grok-4.6-high-fast`（第 1–2 轮全量 `main...HEAD`：2 条 high 1 / P3 1，1 条 high；第 3 轮起只审整改 diff：1 条 high，第 4 轮 0 条收口；4 条全部采纳整改） | 三条 high 是同一处的三层：`AppearanceController` 在读盘未落定 / 读盘失败 / 补读之后拿错基线时，都会把 `appearance` 段整段覆盖成缺省，抹掉盘上已存的字体轴或主题（`appearance` 段在 Rust 侧是整段替换的）。各带一条回归用例，去掉整改都会红（逐条实测过）。P3 是两处文档还指着改名前的 `font_prefs.dart`。`validate.ps1` 全绿（flutter test 334 项）。并发落盘后发先至（R7.6 就有）与终端当前搜索命中的前景色记 `rounds/BACKLOG.md` |
| R7.6 | 已完成 | `font-switching`（worktree `AcpAgentClient-fonts`） | —（设计稿待补，见下） | — | 3 轮 / cursor CLI `cursor-grok-4.6-high`（第 1 轮全量 `main...HEAD`：3 条 high 1 / P2 2，全部采纳整改；第 2 轮全量复审：**0 条**；第 3 轮合并 `main`（画板 43）之后再全量：**0 条**） | 字体切换四轴（界面西文 / 界面中文 / 代码等宽西文 / 代码等宽中文），所有者裁定 2026-09-20「字体属聚合物 + 随包直选 + 两组互不重叠的下拉」；任务卡 `rounds/round-7.6/round-7.6.md`；validate 全绿（281 测试）；第 1 轮审查抓到 high 1 条：`CardText` 等 14 个 `static final` 样式缓存会把 family 冻在首次访问那一刻，导致「全局生效」原本是假的（自测只断言 `TextStyles.*` 故假通过），已改 getter 并加扫源码的回归测试；**画板 70 的「外观」小节属实现先行、设计稿待补**；随包字体文件需所有者本人下载后放 `assets/fonts/optional/`（协议的点击同意不可由工具绕过），在此之前验收 9 待完成 |
| Thread → Session 收敛 | 已完成 | `claude/thread-to-session-unify-fb9f63` | —（设计稿待补，见 BACKLOG） | — | —（所有者指定直接合并，未走独立审查） | UI 文案与前端 Dart 符号从 `Thread` 统一收敛为 `Session`（中文「会话」）：默认会话标题 `New <agent> Thread` → `New <agent> Session`、`+` 弹层 `Threads` → `Sessions`；`ThreadHeader` / `NewThreadEmpty` / `ThreadMenuPopover` / `ThreadHeaderRunning` → `SessionHeader` / `NewSessionEmpty` / `SessionMenuPopover` / `SessionHeaderRunning`（`lib/ui/shell/thread_header.dart` → `session_header.dart`）、`threadTitle` → `sessionTitle`、`threadMenuAnchor` → `sessionMenuAnchor`、`WorkbenchColumn.threadHeader` → `sessionHeader`、`+` 加入的转录 URI `acp-thread:` → `acp-session:`；注释与文档里的「线程头 / 线程区」改「会话头 / 会话区」。起因是协议层与状态层本就是 `session/*`、中文文案本就是「会话」，只有临摹 Zed 原型留下的几处英文还写着 `Thread`。零布局 / 零 token 值改动（`tokens.dart` 只动一行注释），31 文件 +166 -165；validate 13 项全绿、`flutter test` 319 项通过、`flutter analyze` 0 error 0 warning。Zed 上游的 `ThreadEvent` / `ThreadStore` / `threads.db` / `acp_thread.rs` 不在收敛范围。**画板 00 / 01 / 02 / 03 / 06 / 31 / 40 / 50 / 60 / 61 仍是旧文案，属实现先行**，注记记 BACKLOG「设计稿补注记（Thread → Session 收敛）」；**未构建 / 未审查（所有者指定）** |
| R7.5 | 已完成，2026-09-20 合入 main（`05a2e4a`，随 v1.3.0 发布）；验收 8 真跑与验收 9 手测待所有者 | `claude/r7-5-composition-root-refactor-7600bf`（独立 worktree，基线 `f62520f`；`round-7.5` 收口时 fast-forward 到它） | —（无画板阶段） | — | 3 轮 / cursor CLI `cursor-grok-4.6-high-fast`（第 1 轮全量 `main...HEAD` 到第 6 步：**0 条**；第 2 轮全量到第 9 步：**0 条**；第 3 轮 `fd5b7a9..HEAD` 合并 main 之后：**0 条**；第 4 轮合 main@32d372f 后按所有者指示本会话自审：合并本身 0 条，main 那两个直改提交 1 条 P3 记 BACKLOG） | 任务卡 `rounds/round-7.5/round-7.5.md`；9 步各一个提交，每步 validate 全绿 + 三份 fake-agent 无头报告与基线逐步骤等价（比对脚本随基线入库）；拆完组合根 356 行、`lib/app` 九个新文件（thread 848 / shell 348 / turn 345 / composer 327 / agents 317 / auth 288 / workspace 196 / index 144 / guarded 50）；validate 加行数门与依赖方向门（13 → 15 项）；阶段 B 只量不动（一次 batch 壳级 build = 1，不触发，数字记 BACKLOG）；不修 BACKLOG 缺陷，17 条相关条目已各补新家，缺陷轮开 R7.7。main 的后续 11 个提交（Thread → Session 收敛 `44d256d`、画板 07 深色模式 `1420556`、v1.2.0 `7c9c592`）已于 2026-09-20 按所有者指示合进本分支（合并提交 `4e17300`，解冲突脚本 `rounds/round-7.5/merge-main-7c9c592.py`；validate 15 项全绿、三份无头报告与 main@7c9c592 的构建等价、第 3 轮审查 **0 条**；同日再合 main@32d372f 的两个 main 直改提交，无冲突，合并提交 `97ebfe8`，自审 1 条 P3 记 BACKLOG）；`ThreadController` 已按裁定改名 `SessionController`（2026-09-20） |
| R8（Windows 端） | 已完成，2026-09-20 合入 `main` 并发布 v1.4.0 | `round-08` | —（无画板阶段） | `453965e`（fast-forward，无 merge commit；随后 `25a7074` 是 README 的发布行） | 3 轮 / cursor CLI `cursor-grok-4.6-high-fast`（第 1–2 轮全量 `main...HEAD`：3 条 P2 2 / P3 1，1 条 P3；第 3 轮只审整改 diff `38b8578..HEAD`：**0 条**；4 条全部采纳整改，无一条记 BACKLOG 放行） | 任务卡 `rounds/round-08/round-08.md`；9 项验收全有证据：sidecar 版本解耦（改 version 重链 14 m 16 s → 抬应用版本 1.51 s fresh）、版本门（含负面测试）、三件产物（zip 110.3 / 46.7 MB、安装器 79.0 MB）、`verify-package.ps1` 四条全 PASS、日志 banner、NOTICE 双向核对、validate 16 项全绿；偏离：打包是独立的 `package.ps1` 而非扩 `build.ps1`（理由记任务卡）；macOS / Linux 挪到后续一轮 |
| quality（代码质量清理） | 已完成，2026-09-20 合入 `main` | `quality-cleanup`（独立 worktree `AcpAgentClient-quality`，基线 `4ddaf2e`） | —（无画板阶段） | `8aa609f` | 3 轮 / cursor CLI `cursor-grok-4.6-high-fast`（第 1–2 轮全量 `main...HEAD`：3 条 high 0 / P2 3，2 条 P2 1 / P3 1；第 3 轮只审整改 diff `a61981f..HEAD`：**0 条**；累计 5 条全部采纳整改，0 条 high） | 任务卡 `rounds/round-quality/round-quality.md`。起因是所有者 2026-09-20 让我按七条原则（真的需要吗 / 库里已有吗 / 标准库能否 / 平台原生能否 / 已装依赖能否 / 能否一行 / 最小代码）评估代码质量，本轮落地其中第 1–5 项：① 死代码（`smoke_screen.dart` 自 R3 起无引用却还在被改、3 个无人调用的 `pub fn`、`TextAction`）；② 复用（`formatBytes` 三份合一并补上 GB 档 —— 此前文件面板封顶 MB，1 GB 的文件显示成「1024.0 MB」；`write_atomic` 两份合一只留 `rust/fs`；`IconButtonGhost` 改走 `Hoverable` 并吸收 `PanelIconButton`；38 个只在自己文件里用的类改 `_` 前缀，私有化后 analyzer 立刻报出 30 个从没人传过的可选参数，一并删掉）；③ R3 / R5 / R6 的无头验收驱动挪出产品入口到 `lib/main_headless.dart`（`flutter build -t`）—— 此前它们随发布包一起编进去、任何人设个环境变量就能把桌面应用切成无头模式；④ 剪贴板图片改由 runner 走 Win32（`windows/runner/acp_clipboard.cpp`，挂在既有的 `acp/window` 通道上），不再每次 Ctrl+V 拉一个 `powershell.exe` 经临时 PNG 中转，BACKLOG 上两条（孤儿 powershell + 临时目录、截断 PNG）随之消除；⑤ `base64` 改用 Cargo.lock 里本就有的 crate，删两份手写编解码。44 个代码文件 +637 / −593。验收 8 项全过，含规则 9 的 Windows 剪贴板实测（位图 / 含中文名的文件列表 / 纯文本三种，探针脚本随卡入库）。审查抓到的 5 条里有 1 条是第 1 轮整改自己引入的（两道大小门共用一个旗标、提示文案写死 20 MB 会谎报）。第 6 / 7 项（桥的四层手写转发、`appearance_prefs` 的 data-class 样板）与 gallery helper 重复、其余自带 hover 的 widget 只记 `rounds/BACKLOG.md`，本轮不动 |
| 画板 08（回合折叠 / 在跑数） | 已完成，待所有者裁定四处偏离与手测 | `claude/new-session-c0ff9d`（Claude Code 桌面端 worktree） | `68ae329`（画板 08 首次入库 + 画板 70 补「转录」分组） | `67d6148`（2026-09-22 快进合并，无 merge commit） | 4 轮 / cursor CLI `grok-4.7-high-fast`（第 1–2 轮全量 `main...HEAD`：3 条 high 1 / P2 2，1 条 high；第 3 轮起只审整改 diff：3 条 high 1 / P2 2，第 4 轮 **0 条**收口；累计 7 条里 6 条采纳整改、1 条按审查器自己的建议记 BACKLOG） | 任务卡 `rounds/round-board-08/round-board-08.md`；简报 `design/round-design/input/revision-05.md`。**A 段（回复中的 token 速度标签）在设计阶段整段删除**：流式期间协议给不出输出 token（`usage_update.used` 是会话级上下文占用，四家 agent 口径还各不相同；`session/update` 里也没有时间戳），回合级真值只有 `PromptResponse.usage`、回合结束才到 —— 那是画板 31 页脚已经在做的事，所以画板 31 零改动。落地的是 B（回合折叠）与 C（跨工作区在跑数徽标）加画板 70 的「转录」开关。验收 1–9 全过（`validate.ps1` 16 项全绿、`flutter test` 393 项、gallery 两张对照图），验收 10 只做了一半：Windows release 构建 + smoke 往返实测通过（194.0s、`acp_bridge.dll` 12.9 MB、`ok: true`、0 丢事件），UI 级行为本机没有 GUI 自动化通道，留所有者手测。**滚动锚点这一块三版才对**：第 1 版漏了自动折叠整条路径（`isCollapsed` 翻面后由重建自然发生，不经过任何点击回调），第 2 版搬进 `transcript_fold_anchor.dart` 时把位移符号写反、又加了个自己没测到的「按 `maxScrollExtent` 差值粗调」兜底，第 3 轮审查指出那个兜底是错的（Flutter 同帧已经夹过一次 `pixels`，且外推的 extent 可能不降反升）后整段删掉，现在是「量得到就精确校正，量不到就不动」。四处偏离（权限卡 / elicitation 卡不折叠、触发钮 tooltip 整句替换、切换器对勾沿用画板 41 的右侧位置、徽标图标复用 `AcpIcons.rotateCw`）与两条残余记 `rounds/BACKLOG.md` |
| 1.4.1 复审（v1.4.0 之后六批合并的复审与整改） | 已完成，2026-09-22；待所有者快进 `main` 并发布 v1.4.1 | `claude/review-1.4.1`（从 `main@689fab5` 开出） | —（无画板阶段） | —（待快进） | 第 1 遍 **Claude 自主审查**（所有者指定；4 个 opus 只读子代理并行 + 主会话通读六批 diff 逐条验真）：20 条 high 2 / P2 5 / P3 13，16 条采纳整改（含 2 条 high 与 5 条 P2 全部）、1 条不采纳（tar 的 GNU 语义，写明理由）、1 条只改注释、2 条记 BACKLOG；第 2 遍 cursor CLI `grok-4.7-high-fast` 全量 `v1.4.0..HEAD` 两轮：第 1 轮 2 条（P2 1 / P3 1，都指向整改本身）采纳整改，第 2 轮 **0 条**收口 | 任务卡 `rounds/round-1.4.1/round-1.4.1.md`。所有者指示审查期间不跑构建。范围是 `v1.4.0..689fab5` 的六批：quality（cursor 3 轮过）、审查模型换代、画板 43 跳转白屏（**未审查**）、切项目假死（**未审查**）、cursor 九条修复（**未审查**）、画板 08（cursor 4 轮过）。high ①（cursor 九条修复那批）会话索引的墓碑永不过期，删掉再新建同 id 的会话（fake-agent 不带 `--sessions` 恒回 `sess_fake_1`）被静默删掉、侧栏不出现 → 删除改为只等该会话在途的 upsert 落地、删除在途期间不发同会话的写；high ②（画板 08 那批）转录偏好的读盘排在 `core_init` 之前且无补读，画板 70 的开关既读不回也存不下 → 挪到 init 之后。P2：换项目补齐窗口里旧项目的分支表仍可点、会对新项目跑 `git switch`；URL 型 elicitation 卡不认 withdrawn；`resolve_inside` 用例注释声称覆盖了走不到的分支；画板 70 全局开关翻面没有滚动锚点（锚点订阅 `TranscriptFolds` + 量不到时交 `TranscriptJump` 分帧找回，顺带收掉 BACKLOG 的「锚点量不到不校正」残余）；压缩标记用例建的其实是 tool_call。validate 全绿（`flutter test` 401 项，新增 8 条用例，high / P2 的整改逐条验证过去掉整改会红）；runner 的一行 C++（`return !out.empty()`）未编译，随 v1.4.1 的 release 构建一起编。版本号 1.4.0 → 1.4.1 随收口一起改（sidecar 不跟，规则 11） |
