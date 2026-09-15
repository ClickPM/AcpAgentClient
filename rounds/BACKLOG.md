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
- [ ] R0 gallery 里画板的内联单线图标目前用 CustomPainter 手描路径（`Radius.elliptical` / `Offset` 几何字面量），`Assert-NoStyleLiteral` 因此没扫这两种写法；R2 起画板图标改用 `flutter_svg` 内联设计稿的 SVG 字符串后，把 `Radius.elliptical(` / `Offset(` 纳入扫描（审查 P3，2026-09-15）
- [ ] R1 dsh-acp-interactive 1.3.0 的 `--setup` 在 Windows TTY 上**看不见提示**：`secretQuestion` 在 `readline.question()` 返回后立刻 `muted = true`，而 Node 在 Windows 上对 TTY 的写是异步的（`process.stderr` 文档：TTY 在 Windows 异步），readline terminal 模式的提示由多次 `write` 组成，第一段之后的都在 muted 之后才被处理而被吞掉；`TERM=dumb`（非 terminal 模式，单次写）或管道 stdin 都正常。本项目实测（`rounds/round-01/round-01.md` 验收 1）：pty 里 readline 活着、盲打密钥 + 回车能保存并自动重试 `session/new` 成功，只是用户看不到 "Enter DeepSeek API key:"。是上游（所有者自己的项目）的缺陷，客户端不做 agent 特判（规则 2）；R3 认证页出来前请上游修（把提示写完再 muted，或非 terminal 模式）(2026-09-15)
- [ ] R1 portable-pty 0.9 固定以 `PSEUDOCONSOLE_INHERIT_CURSOR` 建 ConPTY，Windows 11 26200 的 conhost 会先发 `CSI 6 n` 并阻塞子进程直到收到光标位置应答；`rust/pty` 只答启动那一次，之后的 DSR 留给渲染器。R4 接 xterm.dart 时确认它不会重复应答第一次（重复的 `CSI 1;1 R` 会当键盘输入进子进程），或统一由 pty 层应答 (2026-09-15)
- [ ] R1 Windows 上结束 agent 进程树用 `taskkill /F /T`（Job Object 需要 unsafe，规则 6）；`.cmd` 包装（npx / npm 全局 bin）被 `taskkill /T` 一并杀掉 node 子进程已实测，但 `agent_disconnect` 的正常路径只关 stdin、等 3 s 再杀，agent 不响应 stdin EOF 时会多等 3 s；R5 做 registry 安装时复核 (2026-09-15)
- [ ] R0 `prototype/assets/fixtures.js` 的 `elicitation/create` 缺必填字段 `message`，被 Rust 侧 fixtures 测试抓出；`test/fixtures/` 已补，原型不改（原型不维护） (2026-09-15)
