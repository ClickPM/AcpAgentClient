# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

> **本文只留五块**：项目定位、仓库结构、开发模式（轮次与迭代）、硬性规则、本地开发。
> 背景 / 诉求 / 研究 / 设计都在 `docs/`，轮次拆解在仓库根 `ROUNDS.md`，敏捷迭代在 `iterations/`，按需读。
> **书写约定：硬性规则编号只增不改、不重排**（代码注释会引用「CLAUDE.md 规则 N」）；删掉的规则留「已废弃」占位。
> `AGENTS.md` 是给**外部审查者**的指针文件（执行器 = cursor CLI），指向本文，无需双份维护。

## 项目定位

**AcpAgent Client**：Flutter 桌面客户端，Rust 核心（进程内 cdylib，经 flutter_rust_bridge v2 桥接）用官方 `agent-client-protocol` rust-sdk v2 以 ACP 接入多个 agent（Claude Agent、Codex、Cursor、pi、DeepSeek Harness，以及以 sidecar 形式接入的 Zed 内置 agent），registry 里的 agent 像 Zed 一样安装即用；前端 Flutter（Dart），完全按 Claude Design 设计稿实现。开源、不商用，许可证拟为 GPL-3.0-or-later（因复用 Zed 源码）。技术栈于 2026-09-12 由 Tauri + React 调整而来，依据见 `docs/research.md` § 9 / § 10。

- **功能范围的唯一边界是设计稿**：[`design/`](design/)（画板索引 `design/README.md` 已建骨架，首轮出稿后填入；每个画板的 `.dc.html` 源与一张 PNG 快照入库，PNG 是验收基准，画板编号只增不改）。设计稿没有的功能一律不做，想到的进 `rounds/BACKLOG.md` 等所有者裁定。
- 诉求与非目标：[`docs/requirements.md`](docs/requirements.md)；架构与既定决策：[`docs/design.md`](docs/design.md)；研究依据：[`docs/research.md`](docs/research.md)；**可投影内容清单**：[`docs/acp-projection.md`](docs/acp-projection.md)；背景：[`docs/background.md`](docs/background.md)。

**用户回复默认中文**；代码、命令、路径、技术术语保持英文。

## 仓库结构

```
AcpAgentClient/
├── CLAUDE.md / AGENTS.md / README.md      约定、审查者指针、简介
├── ROUNDS.md                              轮次总览与 roadmap：R0–R8 拆解、画板 → 轮次 → widget 文件、裁定门、进度表
├── docs/                                  background / requirements / research / design / acp-projection / review-workflow
├── design/                                设计稿与简报：design/round-NN/{input/（交给 Claude Design 的简报与附件）, canvas.json, NN-<画板>.dc.html, NN-<画板>.png}
│                                          + design/README.md 画板索引（编号 / 名称 / .dc.html / PNG / 画布 URL）
│                                          + design/DIVERGENCE.md 画板与实现的偏离清单（这几处以实现为准，不要求补稿）
│                                          + design/brand/（应用图标 app-icon.svg 与标记来源；不是画板，见 design/brand/README.md）
├── rounds/                                README（目录约定）/ TEMPLATE（任务卡模板）/ BACKLOG（轮次与迭代共用的唯一入口）
│                                          + rounds/round-NN/{round-NN.md, BLOCKED.md}（轮次级数据与脚本可放子目录）
├── iterations/                            敏捷迭代（2026-09-22 起）：README（流程正本 + 迭代清单）/ TEMPLATE / iteration-NN.md（一迭代一文件、一项一行，不建子目录）
├── .claude/                               cursor-review.ps1（审查启动脚本）+ cursor-review-prompt.md（任务书契约，入库）
│                                          + reviews/（审查产物，gitignored）
├── pins/upstream.json                     上游钉版本清单（提交进仓库；改版本先改这里。zed 那条的 `version` 是 sidecar 版本的事实来源，见规则 11）
├── scripts/                               README（一句话索引）+ fetch-upstream.ps1 / .sh、validate.ps1、build.ps1、build-sidecar.ps1（R7）、package.ps1 + verify-package.ps1（R8 打包与产物验收）、render-design.ps1（画板 → PNG）、render-icon.ps1（app-icon.svg → .ico）
├── packaging/windows/                     Inno Setup 安装器脚本（R8；per-user、不签名，由 scripts/package.ps1 调用）
├── vendor/upstream/<name>/                钉版本源码（gitignored；fetch 脚本按 pins 填充）
├── rust/                                  Rust 核心 workspace：acp-core（含 assets/ 里内置条目的图标）/ registry / pty / fs / settings + bridge（frb cdylib，包名 acp_bridge）+ tools/acp-smoke
├── cargokit/                              frb 模板自带的 cargokit 副本；windows/CMakeLists.txt 直接 apply_cargokit（不走 pub 插件，见 rounds/round-00）
├── assets/fonts/                          Geist / Geist Mono 可变字体 + CJK 回退 Noto Sans SC（Regular 一档）+ 各自的 OFL 许可证
├── lib/                                   Flutter 前端（Dart）：app/（组合根 workbench_controller 只接线与生命周期；R7.5 拆出的 shell_state / workspace_state / session_index / agents_state / auth_state / composer_state 按画板分组管状态，session_controller / turn_controller 驱动协议，guarded 是共用的通知与错误边界；另有 app（根 widget）/ workbench_screen 装配 / core_bridge（桥的 Dart 侧接口与实现，测试用 test/app/fake_core 替换）/ window_controls / clipboard_image / files_state / local_terminals / appearance_prefs / transcript_folds + transcript_fold_anchor + transcript_jump（回合折叠与转录定位的多帧校正）/ paths / smoke（发布包自检）/ headless_run；后者的入口是 lib/main_headless.dart，`flutter build -t`，产品入口 lib/main.dart 不带它）/ bridge/（frb 生成物）/ projection/（ACP 投影状态层）/ theme/tokens.dart / gallery/（画板对照）/ ui/（画板 widget）
├── test/                                  README（布局索引）+ fixtures/（ACP 线上行，JSON Lines，Rust 测试 / Dart 单测 / gallery 三处共用）+ fake-agent/fake-agent.mjs（离线确定性 agent）+ projection/ ui/ app/ 单测
├── prototype/                             早期 HTML 原型：fixtures 与投影规则的来源，不维护、不作功能边界
├── pubspec.yaml / flutter_rust_bridge.yaml Flutter 项目与 frb codegen 配置
├── windows/                               Flutter Windows runner：runner/acp_window.cpp 是无边框窗口的平台通道（拖拽 / 四边四角缩放 / 三键 / 双击）；sidecar 的 CMake install 规则在 windows/CMakeLists.txt；macos/ linux/ 待 R8
└── sidecar/zed-agent-acp/                 （R7）独立 cargo workspace，path 依赖 vendor/upstream/zed；用 scripts/build-sidecar.ps1 构建
```

## 开发模式：轮次与迭代

**两条并列的流程（2026-09-22 起，R0–R8 主体完成后）**：
- **轮次**（`rounds/`，本节下文）留给核心大迭代——改契约（`docs/design.md` § 3 / § 4）、改钉版本或特性集、新页面或一次 ≥ 3 张新画板、结构性重构（R7.5 那种）、新平台、需要开工前裁定门的功能。
- **迭代**（`iterations/`）承接其余日常工作——BACKLOG 收尾、交互优化、缺陷修复、单画板功能（画板 43 / 07 / 08 的做法）。正本在 [`iterations/README.md`](iterations/README.md)：一迭代一文件、一项一行（类型 `fix` / `ux` / `tidy` / `board`）；默认**一轮**审查（`cursor-review.ps1 -Scope since -Base <分支基线>`，小 diff `-Wait`），有采纳整改才复审，0 条 high 才合并；免审只认所有者逐项指定；`board` 类设计稿先入库再开工。
- 判据在 `iterations/README.md` § 0，拿不准按轮次；迭代里撞到轮次判据就停下写 BACKLOG「立项」。硬性规则、审查边界、复审收口标准两边一字不差。

**Claude Code solo 开发，独立审查做缺陷门禁**；不做视觉 review（规则 3 管住样式即可），有 UI 的轮次按设计稿逐画板对照。
**审查执行器两级**（所有者裁定 2026-09-11，与 agent-xray 一致）：
① **cursor CLI（`cursor-agent`）+ 模型 `grok-4.7-high-fast`**，首选；
② cursor 硬失败 → **主会话委派 Claude Code 子代理**做只读审查，读同一份任务书 `.claude/cursor-review-prompt.md`。
回落原因写进任务卡；同一轮审查只用一个执行器，不混两份 findings。发起命令、结果取回与坑清单在 [`docs/review-workflow.md`](docs/review-workflow.md)。

```
设计轮（有 UI 变动时先做）：design/round-NN/design-prompt.md → Claude Design 出稿 → .dc.html + canvas.json 入库、每画板导出 PNG 入库 → 更新 design/README.md（编号 / 名称 / .dc.html / PNG / 画布 URL）
                                                                              ↓
开工：cp rounds/TEMPLATE.md rounds/round-NN/round-NN.md，按 ROUNDS.md 该轮拆解填任务卡
  → 每个 worktree 第一步：scripts/fetch-upstream.ps1 且 -Check 全绿（规则 4）
  → 实现（遵守规则 1 / 2 / 3 / 5）
  → 验证：scripts/validate.ps1 + 任务卡验收项全过（R0 落地 validate）
  → 独立审查：powershell -File .claude\cursor-review.ps1（默认全量分支 diff、后台跑）；
     质疑设计取舍加 -Kind adversarial；小 diff 想直接看结果加 -Wait；结果落 .claude/reviews/<时间戳>-<kind>.out.md
  → findings 逐条处理（采纳整改 / 不采纳写明理由），回填任务卡「代码审查」段
  → 只要有采纳整改的 findings → 再发一轮复审（缺陷门禁，非设计评审），范围按下方「审查范围」
  → commit + 更新 ROUNDS.md 进度表
```

- **审查范围**：**只有前两轮**用固定的全量范围（`branch diff against main`）；**第 3 轮起只审「上一轮 findings 整改后的 diff」**，即只审 `<上一轮已审提交>..HEAD`。
  - 命令：`powershell -File .claude\cursor-review.ps1 -Scope since -Base <上一轮已审提交>`（默认 `-Scope branch` = `main...HEAD` 全量；`since` = `<Base>..HEAD` 整改 diff；`-Note` 传本轮要点）。
  - 为什么：全量重扫一条长分支单轮要十几分钟，而第 3 轮起的复审职责只是「确认整改本身没引入新缺陷」。
  - 代价要认：整改 diff 之外的问题这几轮不会再被扫到。所以**前两轮必须是全量**，那是覆盖面的来源；第 3 轮起是门禁，不是覆盖。
- **复审收口标准**：审查 / 复审循环不得带**阻塞性问题或明显 bug / 漏洞类 findings**（high 级，或任何会丢数据、漏凭据、泄资源、逻辑错误、让 agent 挂起的问题）收口，继续「整改 → 复审」直到此类 findings 清零才允许合并 `main`；低危改进项可写明理由记 `rounds/BACKLOG.md` 后放行。禁止以「spike 会被替换」「概率低」为由跳过整改。
- **审查边界**：**严禁以审查代替设计**，审查是缺陷门禁，不负责长出方案；findings 若指向设计缺陷，停下回任务卡 / 所有者层面重定方案。**非严重阻塞性 findings 严禁新增机制类修复**（新队列 / 新协议 / 新抽象 / 新配置 / 新导出面）：只允许最小改动（改判断、改文案、删代码）或写明理由记 BACKLOG；机制类修复仅限严重阻塞性 bug / 漏洞。
- **回落只认硬失败**（`cursor-agent` 未安装 / 未登录 / 启动失败 / 限流 / 后台进程已死而 `.out` 仍空），「等得久」「改动小」不是理由；回落原因写进任务卡。回落 = 主会话用 Agent 工具委派一个只读子代理，提示词是「读 `.claude/cursor-review-prompt.md`，把 `{{RANGE}}` 当作 `<范围>`、`{{NOTE}}` 当作 `<要点>` 执行，只输出结论不改文件」；范围口径不变（前两轮 `main...HEAD`，第 3 轮起 `<上一轮已审提交>..HEAD`）。
- 同一验收项针对性整改后连续 2 次仍不过 → 写 `rounds/round-NN/BLOCKED.md` 停下呼人，禁止放宽验收（rounds/README.md）。
- 分支：每轮在 `round-NN` 分支开发，审查通过后合并 `main`；纯文档与微修可直接 `main`。R7 合并后（2026-09-17 起）所有者手测报障的修复也直接在 `main` 上做：每批是否构建、是否走独立审查由所有者逐批指示，不走的在提交说明里写明「未构建 / 未审查（所有者指定）」；走审查的按同一套缺陷门禁（发布前审查 → 整改 → 复审）。这一段的汇总在 `ROUNDS.md` § 7「main 直改」行；设计稿因此滞后的项记 [`design/DIVERGENCE.md`](design/DIVERGENCE.md)（规则 3，**不要求补稿**），不再进 `rounds/BACKLOG.md`。**2026-09-22 起这类工作按迭代流程登记在 `iterations/`**（ROUNDS.md § 7「main 直改」行封存，不再追加）。
- 跨轮次发现的问题写 `rounds/BACKLOG.md`，不当场顺手改。

## 硬性规则

1. **依赖白名单。** 实现层只允许来自：官方协议仓库（规范 + `schema/v1`）、官方 `rust-sdk`、官方 `registry`、`zed-industries/zed`、五个 agent（claude-agent-acp、codex-acp、Cursor CLI ACP 文档、pi-acp、dsh-acp-interactive）。**任何实现了 ACP 客户端、agent 会话状态或会话 UI 的第三方库一律不引入**（acp-components、acp-ui、pi-web 等已被裁定排除）。通用库允许清单：Rust 侧 tokio、serde、serde_json、reqwest、sha2、portable-pty、notify、flutter_rust_bridge、base64（所有者裁定 2026-09-20：`acp/terminal_output` 的编码，0.22 本就是 reqwest 那条线的传递依赖）；Dart 侧 Flutter SDK 自带的 Material / Cupertino、flutter_rust_bridge、xterm、url_launcher、file_selector、flutter_svg（内联图标与 registry `icon.svg`，所有者裁定 2026-09-15）、以及 R1.5 spike 裁定的六项（所有者裁定 2026-09-15 按推荐项，依据 `rounds/round-1.5/spike.md`）：`markdown`（只用解析器，渲染层按画板自写）、`re_highlight`（代码高亮）、`flutter_math_fork`（数学公式）、`mermaid_flutter` + `mermaid_core`（Mermaid）、`audioplayers`（音频块）、`diffutil_dart`（即「一个 diff 库」）。传递依赖不算引入（`flutter_math_fork` 带来的 `provider` 不得在我们的代码里 import），`scripts/validate.ps1` 只核对 `pubspec.yaml` 的直接依赖；为工具链兼容而加的 `dependency_overrides` 要在 pubspec 注释里写明原因与解除条件（首例 `objective_c` 9.4.1，见「本地开发」）。清单之外新增通用库要在任务卡写明理由；**不引第三方 UI 组件库与状态管理库**（shadcn_ui / GetWidget / fluent_ui、riverpod / bloc / getx 及同类），组件全部从画板手写，状态用 SDK 自带的 `ChangeNotifier` / `Stream`。界定有疑问时按 `docs/requirements.md` 第 8 条，仍有疑问问所有者。
2. **严格 ACP 投影。** 前端只消费 ACP 线上消息的原样 JSON（契约见 `docs/design.md` § 3）；不自造第二套协议；前端不做任何 agent 特判；`_meta` 只允许 `docs/design.md` § 4 列出的键，增键先改文档再进所有者裁定。
3. **设计稿是功能边界。** 设计稿（`design/` 里入库的 PNG 与索引）没有的功能不做；样式唯一来源是 `lib/theme/tokens.dart`，widget 文件里不写样式字面量；接后端只换数据源，不改布局、widget 树结构与 token，接线轮里 `tokens.dart` 与画板 widget 文件应零 diff。扩边界的唯一正确顺序是「先改设计稿（更新 PNG 与索引）、再进轮次」。**实现与画板不一致时记 [`design/DIVERGENCE.md`](design/DIVERGENCE.md)**（所有者裁定 2026-09-20）：功能超越设计稿（画板没画、实现先做了）、画板画错或自相矛盾、实现有意少做或做不到，都在那份清单里追加一行「画板画的是什么 → 实现是什么（为什么）·（轮次, 日期）」，**不要求回补设计稿**；列进去的那几处以实现为准、PNG 不再是它们的验收基准，看画板之前先看这份清单。这一条不放开扩边界：新长出设计稿上没有的功能仍要先裁定再进轮次，DIVERGENCE 只收已经发生的既成事实。
4. **钉版本。** `pins/upstream.json` 是上游唯一事实来源，`vendor/upstream/` 永不入库；改版本先改 pins，再改 `docs/research.md` 对应段，再 fetch。禁止在 `vendor/upstream/` 里改代码：要改就复制出来（规则 5）。
5. **gpui 不进主进程；复用要标来源。** 主进程（Flutter 宿主进程及其加载的 `rust/` cdylib）不得依赖任何含 gpui 的 crate；需要 gpui 的东西只能放 `sidecar/`。复用 Zed 代码的三种方式（直接链接 crate / 复制后改写 / 参考转写）都要在文件头标注 `// Derived from zed-industries/zed <path> @ <commit> (GPL-3.0-or-later)`。
6. **Rust 禁 `unsafe`。** 需要时问所有者，不自行放行。
7. **不动用户数据。** Zed 的 `threads.db` 与 `settings.json`、`~/.pi`、各 agent 自己的会话目录：能只读就只读，必须写走「临时文件 + rename」；sidecar 同样适用。禁止任何破坏性操作。
8. **密钥不入库、不入日志。** ACP 流量日志与调试面板对 `Authorization`、`api_key`、`token` 类字段打码；`.env*` 与 `*.pem` 已在 `.gitignore`。
9. **Windows 首发。** 涉及子进程拉起（`.cmd` 包装、引号、路径含中文与空格）的改动必须在 Windows 实测并在任务卡记录命令与输出；不得只在 macOS / Linux 验证。
10. **协议对齐。** rust-sdk 的 `unstable` 特性集与 Zed 钉版本对齐（见 `docs/research.md` § 2），不开 `unstable_protocol_v2`；改特性集视为改钉版本，走规则 4。
11. **版本号两处，sidecar 不跟。**（R8，所有者裁定 2026-09-20）发应用版本只改 `pubspec.yaml` 与 `rust/Cargo.toml` 的 `[workspace.package]`，两处必须一致。`sidecar/zed-agent-acp/Cargo.toml` 的 `version` **跟 zed 钉版本走**（= `pins/upstream.json` 里 zed 那条的 `version`，= `vendor/upstream/zed/crates/zed/Cargo.toml` 的 version），只在换 zed 钉版本时一起改：改这一行 = 那个 crate 重编 + 176 MB 二进制全量重链（2026-09-20 实测 14 分 16 秒；不改时 cargo 判 fresh，8.2 秒），而发应用版本根本不动 sidecar 的源码。`scripts/validate.ps1` 的「版本门」核对这四个数。

## 本地开发

- **前置**：Rust stable（`rust-toolchain.toml` 在 R0 钉）、Flutter stable（版本在 `pubspec.yaml` `environment` 钉，R0 定）、`flutter_rust_bridge_codegen`（与 Rust 侧 crate 同版本，另需 `cargo-expand`）、Node ≥ 22（跑 npx 类 agent 用）、Flutter Windows 前置（VS 2022「使用 C++ 的桌面开发」工作负载、CMake、Windows 10 SDK）；sidecar 另需 Zed 的构建前置（Windows SDK ≥ 10.0.20348，见 `vendor/upstream/zed/docs/src/development/windows.md`；cmake 在 VS 2022 BuildTools 里即可，`build-sidecar.ps1` 自己找；本机没装 VS「Spectre 缓解库」组件，所以 R7 把 `languages` crate 从 sidecar 依赖里去掉了，装上后取消 `sidecar/zed-agent-acp/Cargo.toml` 那一行注释即可恢复，见 BACKLOG）。R0 起 `CARGO_TARGET_DIR` 固定为纯 ASCII 路径 `D:\cargo-target\AcpAgentClient`（所有者裁定 2026-09-15；本机用户名已是 ASCII，此项为含中文 / 空格的工作副本兜底，见 `docs/research.md` § 9.3）。
- **上游源码**：`powershell -File scripts/fetch-upstream.ps1`（首次填充）、`-Check`（验证钉版本）；Git Bash 用 `scripts/fetch-upstream.sh [--check]`。
- **审查器**：`cursor-agent` 装在 `%LOCALAPPDATA%\cursor-agent\cursor-agent.cmd`（不在 PATH），须先 `cursor-agent login`；脚本按绝对路径找。
- **本机坑**（沿用全局记忆）：本机用户名已是纯 ASCII（`Click`），含中文 / 空格的路径风险只剩工作副本本身（用 `build.ps1` 兜，见下条）；含中文的 `.ps1` 必须 UTF-8 with BOM（`cursor-review.ps1` / `build-sidecar.ps1` / `render-icon.ps1` 已带）；Bash 工具里 `\\` 会塌成 `\`；`%TEMP%` 是 8.3 短名，路径比较要双边规范化。
- **命令**：`scripts/validate.ps1`（编译 + 测试 + 契约检查 + R7.5 起的 lib/app 行数门与依赖方向门；`-Quick` 只跑静态检查；不含 sidecar）与 `scripts/build.ps1`（`flutter build windows --release`；`-Smoke` 跑一次无头往返自检）。sidecar：`scripts/build-sidecar.ps1`（R7；`-Debug` / `-Check` / `-Clippy` / `-Selftest`；target 目录独立为 `D:\cargo-target\AcpAgentClient-sidecar`，产物落 `build/sidecar/` 再由 runner 的 install 规则随包；冷编译 debug / release 各约 50 分钟，target 目录约 56 GB，release 产物 176.7 MB）。设计与品牌：`scripts/render-design.ps1`（`.dc.html` → PNG，改画板源后必跑）、`scripts/render-icon.ps1`（`design/brand/app-icon.svg` → `windows/runner/resources/app_icon.ico`）。frb 生成：`flutter_rust_bridge_codegen generate`（改 `rust/bridge/src/api.rs` 后必跑，生成物入库）。
- **项目路径含中文 / 空格时只用 `scripts/build.ps1`**：Flutter 自己的 Windows 构建链会把非 ASCII 项目路径转码坏（R0 实测），`build.ps1` 检测到后经 `CARGO_TARGET_DIR\ascii-root` 目录联接构建；裸 `flutter build windows` 会失败。
- **`objective_c` override**（R1.5 实测 2026-09-15）：`audioplayers` → `path_provider` → `path_provider_foundation` 2.6.0 → `objective_c ^9.2.1` 解析到 9.6.1，其构建钩子在 Dart 3.13.3 上编不过（`Architecture.arm64e` 不存在），`flutter test` / `flutter build` 在「Building native assets」阶段整体失败。引入 audioplayers 的轮次要在 `pubspec.yaml` 带 `dependency_overrides: objective_c: 9.4.1` 并注明解除条件（升 Flutter 走规则 4）；任何拉进 path_provider 的包都会复发。
- **Windows 开发者模式**：Flutter 为 pub 插件建符号链接需要它；R0 的 Rust 核心不走插件所以不依赖，本机已于 2026-09-15 开启（设置 → 系统 → 开发者选项），换机器先看注册表 `AppModelUnlock\AllowDevelopmentWithoutDevLicense`。
