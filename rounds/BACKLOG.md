# Backlog

跨轮次发现的问题与想法都记这里，不当场顺手改；新功能类条目须经所有者裁定才可进轮次。
格式：`- [ ] <发现轮次> <一句话> (发现日期)`

## 功能（需所有者裁定后才可进轮次）

- [ ] 立项 registry 的 `uvx` 分发类型：Zed 也未实现，首期不做；要做需引入 `uv` 的检测与下载 (2026-09-11)
- [x] 立项 是否声明 `plan` 与 `session.compaction` 两个 unstable 客户端能力 → 所有者裁定 2026-09-11：**都声明**，已写进 `docs/design.md` § 4 (2026-09-11)
- [ ] 立项 Gemini CLI 作为一等 agent：Zed 目前靠合成 terminal auth 方法过渡，等官方 auth methods 落地再议 (2026-09-11)
- [x] round-design 子代理卡（画板 24）依赖 `_meta.claudeCode.subagent`，与规则 2「无 agent 特判」及 `docs/design.md` § 4 的 `_meta` 键清单有张力 → 所有者裁定 2026-09-15：`docs/design.md` § 4 增「入站 `_meta` 识别键」（`claudeCode.*` 三键 + `dsh_subagent`），投影层按键存在分组、不按 agent 名 (2026-09-14)
- [x] round-design 文件树的 git 状态徽章（原型里的 `M`）不在任何文档里 → 所有者裁定 2026-09-15：保留，`git status --porcelain` 子进程得出，非 git 目录不显示；已写 `docs/design.md` § 9 (2026-09-14)
- [ ] round-design 设置页只按 docs 列四块，无外观设置（主题 / 字号）；要加先改设计稿 (2026-09-14)
- [ ] round-design 深色主题：本轮只在 `00-tokens` 出深色色阶，页面画板不出深色；何时出深色页面待裁定 (2026-09-14)
- [x] 拆解 画板 41 / 04 的项目切换与分支切换 / 新建：文档里没有「项目」与 git 概念 → 所有者裁定 2026-09-15：项目 = 目录 = `session/new` 的 cwd，最近项目存本地 `projects.json`；git 走 CLI 子进程；已写 `docs/design.md` § 2 / § 3 / § 9 / § 10（R3） (2026-09-15)
- [x] 拆解 画板 40 `+` 弹层的 Symbols 与 Selection 需要 LSP 与编辑器选区，与 `docs/requirements.md`「不做」冲突 → 所有者裁定 2026-09-15：从画板 40 删除，PNG 已重渲染 (2026-09-15)
- [x] 拆解 画板 30 / 40 的 `Rules · 1 global rule` 文档没定义语义 → 所有者裁定 2026-09-15：项目根规则文件计数 + 在文件面板打开；已写 `docs/design.md` § 9（R3） (2026-09-15)
- [x] 拆解 画板 42 `/` 菜单的分组在 `AvailableCommand` 里没有字段来源 → 所有者裁定 2026-09-15：单组渲染；画板 42 已去掉分组标题与来源标签，PNG 已重渲染；已写 `docs/design.md` § 3 (2026-09-15)
- [x] 拆解 画板 01–04 / 50 / 60 / 61 的自绘窗口控制意味着无边框窗口 → 所有者裁定 2026-09-15：Windows runner 自写平台通道，不引 `window_manager` 类库；macOS 用原生 traffic lights；已写 `docs/design.md` § 9（R3 / R8） (2026-09-15)
- [x] 拆解 画板 61 的本地交互 shell 不在 `docs/design.md` § 3 → 所有者裁定 2026-09-15：新增 `terminal_open / write / resize / close` 四个桥命令，复用 `rust/pty`；已写 § 3（R4） (2026-09-15)
- [x] 拆解 画板 10 / 11 的 Restore Checkpoint 与 Regenerate：协议没有回滚 → 所有者裁定 2026-09-15：照原型「本地截断 + 同会话重发」，agent 侧上下文不回退作为已知限制，不在 UI 加提示；已写 `docs/design.md` § 3（R2） (2026-09-15)

## 工程

- [ ] 立项 sidecar 与运行中的 Zed 争用 `threads.db`：R7 实测后裁定「只读共用 / 隔离目录」，未发现 Zed 现成的数据目录覆盖变量 (2026-09-11)
- [x] 立项 前端 Dart 类型来源二选一 → 所有者裁定 2026-09-15：手写薄封装 `lib/projection/wire.dart`，不做构建期生成；合规性由 Rust 侧 fixtures 反序列化测试兜底；已写 `docs/design.md` § 2 与 `docs/acp-projection.md` § 11 (2026-09-11)
- [x] 立项 Markdown 渲染库选型：官方 `flutter_markdown` 已停维；R1.5 spike 比较 `package:markdown` 自写渲染 / `markdown_widget` / `gpt_markdown`（流式追加、GFM、代码高亮、CJK、选择复制），所有者裁定后进规则 1 白名单；spike 前不得引入 (2026-09-12) → spike 完成 2026-09-15（`rounds/round-1.5/spike.md` § 0，2 轮审查收口）：推荐 `package:markdown` 7.3.1 解析 + 自写渲染，备选 `flutter_markdown_plus`；代码高亮推荐 `re_highlight` 0.0.3；所有者裁定 2026-09-15 按推荐项，已写进 CLAUDE.md 规则 1 / `docs/requirements.md` § 8 / `docs/design.md` § 9 / `validate.ps1` 白名单
- [x] 拆解 R1.5 spike 范围扩到画板 15 Mermaid（Dart 无成熟渲染器：WebView / 只做源码态并改画板 / 自写子集三选一）、16 数学公式、32 audio 播放、13 / 60 代码高亮与 21 的 diff 库，一并裁定进白名单 (2026-09-15) → spike 完成 2026-09-15（同上）：Mermaid 推荐第四条路 `mermaid_flutter` + `mermaid_core` 0.3.0（纯 Dart，画板 15 不用改），公式 `flutter_math_fork` 0.7.4（附带裁定 `provider` 传递依赖），音频 `audioplayers` 6.8.1（附带 `objective_c` 9.4.1 override），diff `diffutil_dart` 5.0.0；所有者裁定 2026-09-15 按推荐项，已写进 CLAUDE.md 规则 1 / `docs/requirements.md` § 8 / `docs/design.md` § 9 / `validate.ps1` 白名单
- [x] 拆解 图标与 registry `icon.svg` 的渲染 → 所有者裁定 2026-09-15：`flutter_svg` 进规则 1 通用库清单（CLAUDE.md 与 `docs/requirements.md` § 8 已加） (2026-09-15)
- [x] 拆解 `CARGO_TARGET_DIR` 位置 → 所有者裁定 2026-09-15：`D:\cargo-target\AcpAgentClient`，已写 CLAUDE.md「本地开发」 (2026-09-15)
- [ ] 立项 若 R0 在中文用户名路径下 `flutter build windows` 因 cargokit 路径失败，`CARGO_TARGET_DIR` 指 ASCII 路径仍不够时评估形态 B（独立 `acp-host.exe`），见 `docs/research.md` § 9.3 (2026-09-12)
- [x] R1 `notice` 会话更新我们编译不出、收到即静默丢弃 → 所有者裁定 2026-09-11 取「不改 feature 集，计数 + 告警 + 落 `acp/traffic`」→ R1 复议 2026-09-15：dsh 1.3.0 真跑三轮（编辑 / 计划 / 表单）没有发过 `notice`，用 `test/fake-agent/fake-agent.mjs` 注入一条：核心 `droppedUpdates` +1、`acp/agent_state: update_dropped` 带 serde 错误文本、原文在 `acp/traffic`，进程与回合都不受影响；**裁定维持**，不改 feature 集；见 `docs/acp-projection.md` § 8.1 与 `rounds/round-01/round-01.md` (2026-09-15)
- [ ] 截图验收：逐一验证并截图 Zed Agent 的 20 项 ACP 投影交互卡片样式 (2026-09-14)
- [ ] R0 cargokit 只认 `rustup run stable`（它的 `toolchain` 选项只有 stable / beta / nightly），`rust-toolchain.toml` 钉的 1.98.1 只约束 `validate.ps1` 里的 cargo；本机 stable 升级后 Flutter 构建会用新版。要么给 cargokit 打补丁读 rust-toolchain.toml，要么接受漂移并在 validate 里比对两者版本 (2026-09-15)
- [x] R0 Windows 开发者模式未开启：Flutter 给 pub 插件建符号链接需要它。R0 的 Rust 核心改走 runner CMake 直接 apply_cargokit 绕过 → 所有者 2026-09-15 当天已开启并验证（`flutter pub get` 对插件工程通过），R3 无障碍 (2026-09-15)
- [ ] R0 macOS 构建（R8）要把 cargokit 挂进 Xcode（runner 级脚本阶段或 podspec），与 Windows 的 runner CMake 方式对应；frb 模板的 rust_builder 插件路径已不用 (2026-09-15)
- [x] R0 gallery 里画板的内联单线图标目前用 CustomPainter 手描路径（`Radius.elliptical` / `Offset` 几何字面量），`Assert-NoStyleLiteral` 因此没扫这两种写法；R2 起画板图标改用 `flutter_svg` 内联设计稿的 SVG 字符串后，把 `Radius.elliptical(` / `Offset(` 纳入扫描（审查 P3，2026-09-15）→ R2 完成 2026-09-15：画板 10–34 的 34 个图标全部是 `lib/ui/transcript/icons.dart` 的内联 SVG（flutter_svg），00 样板页的三个图标改用同一套，`validate.ps1` 已把 `Radius.elliptical(` / `Offset(` 纳入扫描
- [ ] R1 dsh-acp-interactive 1.3.0 的 `--setup` 在 Windows TTY 上**看不见提示**：`secretQuestion` 在 `readline.question()` 返回后立刻 `muted = true`，而 Node 在 Windows 上对 TTY 的写是异步的（`process.stderr` 文档：TTY 在 Windows 异步），readline terminal 模式的提示由多次 `write` 组成，第一段之后的都在 muted 之后才被处理而被吞掉；`TERM=dumb`（非 terminal 模式，单次写）或管道 stdin 都正常。本项目实测（`rounds/round-01/round-01.md` 验收 1）：pty 里 readline 活着、盲打密钥 + 回车能保存并自动重试 `session/new` 成功，只是用户看不到 "Enter DeepSeek API key:"。是上游（所有者自己的项目）的缺陷，客户端不做 agent 特判（规则 2）；R3 认证页出来前请上游修（把提示写完再 muted，或非 terminal 模式）(2026-09-15)
- [x] R1 portable-pty 0.9 固定以 `PSEUDOCONSOLE_INHERIT_CURSOR` 建 ConPTY，Windows 11 26200 的 conhost 会先发 `CSI 6 n` 并阻塞子进程直到收到光标位置应答；`rust/pty` 只答启动那一次，之后的 DSR 留给渲染器。R4 接 xterm.dart 时确认它不会重复应答第一次（重复的 `CSI 1;1 R` 会当键盘输入进子进程），或统一由 pty 层应答 (2026-09-15) → R4 处理 2026-09-16：实测**会重复应答且有害**——本地 PowerShell 会话里 xterm.dart 对那条探询再答一次，PSReadLine 解析应答时把相邻的按键一起吞掉（敲 `echo` 丢了 `e`）。改成 pty 层答完就把启动探询从输出流里抠掉（`rust/pty` 读线程先攒最多 256 字节），渲染器看不到就不会再答；之后的 DSR 仍留给渲染器。agent 终端卡是只读视图本来不接 `onOutput`
- [ ] R1 Windows 上结束 agent 进程树用 `taskkill /F /T`（Job Object 需要 unsafe，规则 6）；`.cmd` 包装（npx / npm 全局 bin）被 `taskkill /T` 一并杀掉 node 子进程已实测，但 `agent_disconnect` 的正常路径只关 stdin、等 3 s 再杀，agent 不响应 stdin EOF 时会多等 3 s；R5 做 registry 安装时复核 (2026-09-15)
- [ ] R0 `prototype/assets/fixtures.js` 的 `elicitation/create` 缺必填字段 `message`，被 Rust 侧 fixtures 测试抓出；`test/fixtures/` 已补，原型不改（原型不维护） (2026-09-15)
- [x] R2 `rust/acp-core/tests/fixtures.rs` 的方法表没有 `elicitation/complete` 与 `$/cancel_request`，这两条 ACP 通知因此进不了 `test/fixtures/`（画板 28 完成态在 gallery 里用 Dart 侧 `PendingQueue.completeElicitation` 构造）；R3 接线时补方法表（`CompleteElicitationNotification` / `CancelNotification`），再把两条收进 fixtures (2026-09-15) → R3 完成 2026-09-15：`$/cancel_request` 的类型是 `CancelRequestNotification`（`CancelNotification` 是 `session/cancel` 的），两条通知与一条被撤回的请求已进 `16-elicitation.jsonl`，画板 28 完成态改为 fixtures 驱动
- [ ] R2 画板 27 的 Other 文本框占位文案「留空表示用上面的选项」不在 elicitation 的 `requestedSchema` 里（规则 2 不自造文案，widget 里没有）；要么改设计稿删掉占位，要么裁定「string 字段无 default 时的通用占位」进 `docs/design.md` (2026-09-15)
- [ ] R2 画板 33 第四态写作 `status: error`，协议 `CompactionStatus` 的值是 `failed`（widget 显示协议原值）；画板 34 initialized 行列的是客户端能力（fs / terminal / elicitation / plan / compaction），widget 列 `agentCapabilities` 顶层键；两处建议下个设计轮改字 (2026-09-15)
- [ ] R2 画板 15 的图形态是纯竖链，`mermaid_flutter` 的 elk 布局把带回边的图排成两列（spike § 5 已记）；若所有者要求与画板一致，只能换布局引擎或改画板 (2026-09-15)
- [ ] R2 画板 31 `max_turn_requests` 结束行的「18 次请求」协议里没有来源（`PromptResponse` 只有 usage）；widget 省略该段，要保留得改设计稿 (2026-09-15)
- [x] R2 widget 里的 7 个局部几何常量（画板 32 预览高 220、音频进度条 3、画板 25 下拉宽 330、画板 30 弹层宽 266、终端回滚 2000 行、spinner 周期 motion.base×5、开关轨道 28×16）不是 token 也不是样式字面量扫描项，任务卡「偏离」段逐个记了；是否进 `tokens.dart` 由所有者定 (2026-09-15) → 所有者裁定 2026-09-15：进 `tokens.dart` 的 `Geometry` 组；R3 已落（提交 37ecfd5），widget 只换引用
- [ ] R3 画板 40 模型行的 provider 图标与 `Latest` 徽章在协议里没有来源（`SessionConfigSelectOption` 只有 value / name / description）；本轮图标位用中性占位、徽章省略。与画板 31「18 次请求」同类，归下个设计轮改稿或裁定一个来源 (2026-09-15)
- [ ] R3 画板 41 分支弹层：画板上输入 `feat/tokens` 时两条本地分支仍列着，但 ROUNDS § 3 R3 要求「搜索」。本轮取搜索语义（命中为空时只剩 Create 行），gallery 出了两张样张；要按画板就得改设计稿说明搜索只作用于新建 (2026-09-15)
- [ ] R3 输入框正文是纯文本（`EditableText`），`@mention` / `/command` 不做行内彩色芯片；芯片只在已发送的用户气泡里（画板 11）。要在输入框里出芯片需要富文本输入控件，先记着 (2026-09-15)
- [ ] R3 requestScope 的 `elicitation/create`（无 `sessionId`）在本轮没有 UI 落点：`docs/design.md` § 3 说它落认证页（画板 52），画板 52 归 R5。现在它只进 `PendingQueue.requestScope`，用户看不到也回不了，agent 会一直等。R5 接画板 52 时一并解决 (2026-09-15)
- [ ] R3 画板 80 上没有「返回工作台」的控件：本轮从画板 34 的「打开流量面板」进、点侧栏任一会话返回。下个设计轮补一个返回入口，或裁定现状 (2026-09-15)
- [ ] R3 新建会话弹层里的 agent 名用的是 `settings.json` 的键（`dsh-acp-interactive`）：协议里没有「展示名」，连上之后线程头才从 `initialize.agentInfo` 取。R5 的 registry 会带来展示名与 logo，届时回填 (2026-09-15)
- [ ] R3 `Ctrl-Alt-A` 的权限「范围下拉」没实测到：dsh 只给 `allow_once` / `reject_once`，下拉里没有第二个同向选项。R6 五 agent 全通时用给 `allow_always` 的 agent 补 (2026-09-15)
- [ ] R3 `computer-use` 的 `request_access` 只认 Start 菜单里的应用，认不出自己构建的 `acp_agent_client.exe`，GUI 点击类验收（窗口拖拽、`file_selector` 对话框）没有自动化通道。要么做 `integration_test` + `flutter drive`，要么每轮留给所有者手测 (2026-09-15)
- [ ] R3 画板逐张对照拦不住「位移类」偏差：右侧那组按钮没贴右这件事在 `build/gallery/01a` 与 `18` 里都画出来了，偏移量却随窗口宽度与文本长度变，肉眼比对时看不出「它本该更靠右」。本轮给三处补了数值断言（`test/ui/shell_alignment_test.dart`），但这是逐点补；是否给画板对照加一层几何不变量（贴左 / 贴右 / 等距）的通用断言，待裁定 (2026-09-16)
- [ ] R3 设计源里两个连续的 `margin-left:auto` 会把余量均分（画板 03 标签条的关闭键因此停在半路，2026-09-16 已改源并重渲 PNG）。其余画板没逐个扫过是否有同样写法；下个设计轮顺带核一遍 (2026-09-16)
- [x] R3 左右侧栏不能自定义宽度（所有者手测 2026-09-16）→ 所有者裁定 2026-09-16 按「我改设计源、和分割线一起做」：画板 04 加分栏把手样张、01–03 加注脚，`docs/design.md` § 9 / § 10 写明范围与落盘；R3 整改分支已落（`ui-state.json` + `ui_state_get/set`） (2026-09-16)
- [x] R3 画板 03 右栏的面板内头行（R4 的文件面板标题行）本轮随分割线一起抬到 36：R4 实现文件面板时按新 PNG 来，别再取 `Controls.input` (2026-09-16) → R4 已按 03 的新源：查看器头行 `Geometry.barHeight`（36），树列头行仍是画板给的 28（`Geometry.panelHeaderHeight`）
- [ ] R3 窗口没有最小尺寸：三栏都顶到下限要 220 + 360 + 360 = 940，窗口比这窄时 `AppShell._fit` 压不动了只能裁切。要么在 Windows runner 上设 `WM_GETMINMAXINFO`，要么窄窗时自动折叠侧栏；两条都得先改设计稿 (2026-09-16)
- [ ] R5 画板 51 npx 安装第二步写的是「写入 agents.json」，数据目录里没有这个文件（`docs/design.md` § 10）：实际写的是 settings.json 的 registry 条目 + `agents/<id>/install.json`，实现显示「写入 settings.json」；下个设计轮改字 (2026-09-16)
- [ ] R5 画板 51「需要认证」条目的描述写死了「ChatGPT 登录」，规则 2 不按 agent 特判，实现显示「需要先完成认证」；画板 52 的方法名（Sign in with ChatGPT / Codex CLI）也是 codex 专属样例，实现按 `authMethods` 原名列出；下个设计轮把样例换成通用措辞或注明是样例 (2026-09-16)
- [ ] R5 画板 50 的未安装行没有分发方式芯片、画板 51 的未安装卡有；实现统一按 51。两张画板下个设计轮对齐一下 (2026-09-16)
- [ ] R5 画板 70 头注写「registry 型只读」但每行都有「编辑」键；实现里 registry 型点「编辑」只读展开拉起参数。设计稿要么去掉 registry 行的「编辑」、要么改成「查看」 (2026-09-16)
- [ ] R5 `logs/acp-<日期>.log` 的日期按 UTC（不引 chrono）；跨日的两小时里文件名与本地日期对不上。要本地日期得裁定引 chrono 或自写时区读取 (2026-09-16)
- [ ] R5 registry 型 agent 的更新：registry.json 里版本升了，已安装的条目仍是旧版本（`install.json` 记的），面板上只显示 registry 的最新版本、没有「有新版本」提示与升级动作（Zed 有 `new_version_available`）。要做先改设计稿加一个升级态 (2026-09-16)
- [ ] R5 codex-acp 的 `api-key` 方法带 `_meta["api-key"]`（客户端可在 `authenticate` 的 `_meta` 里直接递密钥）与 `gateway` 方法（需客户端声明 `auth._meta.gateway`）：两者都要新增 `_meta` 键（规则 2 / `docs/design.md` § 4），本轮只走环境变量 `OPENAI_API_KEY` / `CODEX_API_KEY`（agent 自己从 env 读）；要做先裁定 (2026-09-16)
- [ ] R5 `docs/design.md` § 2 的「Node 与下载」行原定直接 git 依赖 Zed `node_runtime` 等 crate，R5 改为参考转写（理由见 `rounds/round-05/round-05.md` 偏离 1），待所有者确认后把 § 2 那一行改成定稿措辞 (2026-09-16)
- [ ] R5 npx 安装在提交点之前取消 / 失败（`npm install` 阶段）时 `agents/<id>/` 留着半个 npm 目录：没有 `install.json` 所以列表是「未安装」、下一次安装会覆盖，只是占磁盘；binary 型的 staging 目录已会清掉。要一致的话在 `registry_install` 的收尾里对未提交的失败也调 `install::remove` (2026-09-16)
- [ ] R5 无头实跑以 `exit()` 结束进程时不走 `agent_disconnect`，Cursor 的 `cursor-agent.cmd`（cmd.exe 包装）随进程一起没了、它拉的 `dist-package
ode.exe` 却留成孤儿（实测 PID 42768，手动 `taskkill /T`）。R4 验收 4「应用退出时子进程全部回收」要把桌面应用的关闭路径（`AcpApp.dispose` / Windows runner 的 `WM_CLOSE`）与无头口子都接到 `agent_disconnect`（`taskkill /F /T`） (2026-09-16)
- [ ] R4 `rust/fs/src/lib.rs` 的 R3 用例 `junctions_are_not_followed_out_of_the_workspace` 在 `mklink /J` 失败时 `eprintln` + `return`，断言一行不跑也算绿（R4 第 3 轮审查顺带指出，同文件新用例已改成 `assert!`）：下次碰这个文件时同样改成建不出链接就红 (2026-09-16)
