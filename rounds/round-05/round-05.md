# Round 05 — registry、安装、受管 Node、认证页与设置页

<!-- 保存为 rounds/round-05/round-05.md；该轮其他管理产出放同一目录。 -->

> 状态：进行中

## 目标

按画板 50 / 51 / 52 / 70 落地 agent 管理页：registry 面板从拉取到安装到首次握手全通（npx 与 binary 两型、取消、
Remove、受管 Node），认证页覆盖 agent 型、terminal 型与 requestScope 的 URL elicitation（R3 留下的「requestScope 没有落点」
在本轮关闭），设置页四块（agent 配置含 custom 型行内编辑、从 Zed 导入、Node 运行时、数据目录与日志）落地。
参照 agent：codex-acp（npx；ChatGPT 登录走 URL elicitation；`OPENAI_API_KEY` 路径）与 Cursor（binary；terminal auth）。

可证伪：ROUNDS.md § 3 R5 的 7 条验收要点逐条有命令与输出；`git diff <画板阶段收口提交>..HEAD -- lib/theme lib/ui` 为空。

## 前置

- 轮次：R3 已完成（`4b888d7`，整改合并 `d6b6e31`）。R4 与本轮并行开发（另一 worktree，尚无提交），本轮基于 `main`；
  右栏框架用 R3 的 `lib/ui/shell/right_panel.dart`（Agents 标签的正文本轮填）。
- `powershell -File scripts/fetch-upstream.ps1`（本 worktree 首次填充）后 `-Check` 全绿（2026-09-16，8 个钉版本全 OK）。
- 本机版本：Flutter 3.47.4 stable（Dart 3.13.3）、rustc / cargo 1.98.1、Node v24.11.1（系统 Node，≥ 22）、
  `flutter_rust_bridge_codegen` 2.13.0、`C:\Windows\System32\tar.exe`（bsdtar 3.8.8，解 zip / tar.gz 用）。
- 网络：`https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json` 可达（2026-09-16：version 1.0.0，41 个 agent；
  与钉版本 registry 仓库比，cursor 已从 2026.09.02 升到 2026.09.10，列表以线上为准、仓库只作 schema 对照）。
- 参照 agent 凭据：codex-acp 走 ChatGPT 登录（device code，URL elicitation）与 `OPENAI_API_KEY`；Cursor 走 `agent login`。
- 本机 Zed `settings.json`（`%APPDATA%\Zed\settings.json`）里有 `agent_servers` 五条（cursor / codex-acp / pi-acp / claude-acp 四条
  registry 型 + dsh-acp-interactive custom 型，带 `default_config_options`），是验收 4 的输入。

## 交付物

### 画板阶段（只用本地假数据 / fixtures）

- `lib/theme/tokens.dart`：`Geometry` 组新增画板 50 / 51 / 52 / 70 量得的单点尺寸（agent 图标框 28、图标框内菱形 10、
  条目状态卡宽 560、设置页内容宽 860、设置页标签列宽 160、进度条高 3、单选圆 14 / 点 6、认证终端最小高）。
- `lib/ui/registry/registry_panel.dart`（50：标题 + Learn More、搜索、All / Installed / Not Installed 计数、条目列表、
  缺 Node 提示卡）
- `lib/ui/registry/registry_entry.dart`（51：未安装 / 安装中 npx 三步 / 安装中 binary 三步 + 进度条 / 已安装 / 需要认证 /
  安装失败 / uvx 暂不支持 / custom 条目 / 受管 Node 提示卡；条目数据模型 `RegistryEntryData`）
- `lib/ui/registry/auth_page.dart`（52：认证方式选择、terminal auth 可见终端、成功后自动重试、失败态、requestScope 的 URL elicitation）
- `lib/ui/settings/settings_page.dart`（70：agent 配置列表含 custom 型行内编辑 cmd / args / env、从 Zed 导入、Node 运行时、
  数据目录与日志路径的打开 / 复制）
- `lib/ui/transcript/icons.dart`：新增 `download` 一枚（50 / 51 / 70 的 Install / 下载受管 Node）
- `lib/projection/registry.dart`：`registry_list` 与 `registry/progress` 的投影（条目状态机、下载速率与剩余时间估算）
- `lib/gallery/boards/agent_boards.dart`：50 / 51 / 52 / 70 四张 gallery 画板

### 接线阶段（只换数据源；`lib/theme` 与 `lib/ui` 零 diff）

- `rust/registry`：`index.rs`（registry.json 拉取 / 1 小时节流 / 磁盘缓存 / 图标按需拉取 / 按平台过滤 binary target；
  结构体对照官方 `agent.schema.json`；Derived from Zed `agent_registry_store.rs`）、`install.rs`（npx：解析包名与版本 →
  `npm install` 到 `agents/<id>/` → 读 `package.json` 的 `bin`；binary：下载 → sha256 → 解压到 `agents/<id>/<version>/` →
  记 cmd / args / env；取消；Remove 只删 `agents/<id>/`；Derived from Zed `agent_server_store.rs`）、`node.rs`（系统 Node ≥ 22
  检测；受管 Node v24.11.0 下载到 `node/`；参考转写 Zed `node_runtime`，见「偏离」）、`archive.rs`（系统 `tar` 解压，见「偏离」）、
  `manifest.rs`（`agents/<id>/install.json`：安装记录 + 认证状态）。
- `rust/settings`：`AgentServer` 两型补 Zed 同 schema 的 `default_mode` / `default_config_options` / `favorite_config_option_values`
  并保留未知字段；`import_zed`（读 `%APPDATA%/Zed/settings.json` 的 `agent_servers`，JSONC 去注释，导入为 custom 型，不覆盖同名）。
- `rust/acp-core`：registry 型的拉起（manifest → `LaunchSpec`，npx 型经系统 / 受管 Node）；`session/new` 成功与 `-32000`
  回写认证状态；`registry/progress` 事件通道；`logs/acp-<日期>.log`（脱敏后的流量行）。
- `rust/bridge/src/api.rs`：`registry_refresh` / `registry_list` / `registry_install` / `registry_cancel_install` /
  `registry_remove` / `node_status` / `node_download` / `agent_settings_import_zed` / `agent_settings_remove` /
  `terminal_close`；`registry_progress_stream` 第六条事件流；`flutter_rust_bridge_codegen generate` 生成物入库。
- `lib/app/`：`core_bridge.dart` 补命令与事件；`workbench_controller.dart` 接 registry / 认证页 / 设置页；
  `workbench_screen.dart` 把右栏 Agents 标签换成 `RegistryPanel` / `AuthPage`、设置作为主区页面；
  `headless_run.dart` 加 `ACP_R5_REPORT` 无头口子（安装 → 认证 → 一轮对话 → Remove）。

## 验收

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | codex-acp 全通 | 干净数据目录：Agents 面板搜索 codex → Install（51 三步可见）→ 新会话 `-32000` → 52 选 ChatGPT device code（URL elicitation，requestScope）→ 自动重试 → 一轮对话；再以 `OPENAI_API_KEY` 环境变量路径过一遍 |
| 2 | Cursor binary | 下载 + sha256 校验 + 解压（51 进度条）→ terminal auth → 一轮对话；人为篡改 sha256 → 安装失败态，可重试、可看日志 |
| 3 | 受管 Node | PATH 里剔除 Node → 51 的受管 Node 提示 → 下载 → npx 型 agent 可用；数据目录只多 `node/` |
| 4 | 从 Zed 导入 | `agent_servers` custom 条目进 70，同名不覆盖，registry 型条目按 id 匹配 |
| 5 | Remove | 条目回未安装、settings 条目消失、`agents/<id>/` 被清理，其他目录不动（规则 7） |
| 6 | registry 缓存 | 断网时列表仍可显示、安装报网络错误而不是崩 |
| 7 | gallery 与门禁 | gallery 50 / 51 / 52 / 70 对照；接线零 diff 判据；`scripts/validate.ps1` 全绿；Windows 实测记录（规则 9：`.cmd`、解压、sha256） |

## 禁止

默认继承三条：不改前端页面样式（CLAUDE.md 规则 3）；不加设计稿没有的功能（规则 3）；不在 `vendor/upstream/` 里改代码（规则 4）。
本轮另外：不做 `uvx`（BACKLOG 既定，只显示「暂不支持」）；不做外观设置（BACKLOG）；不碰 R4 的文件面板 / 终端面板文件
（`lib/ui/files/`、`lib/ui/terminal/`、`rust/fs` 的 watch / read、`rust/pty` 的 Zed 语义转写），只实现契约里本轮要用的
`terminal_close`（认证页的停止方块）。不动 Zed 的 `settings.json`（只读导入）。

## 代码审查

- 审查方式：`powershell -File .claude\cursor-review.ps1 -Note "<要点>"`（默认档，全量分支 diff，后台跑；要点列了安装编排与取消、
  requestScope 路由、settings 写入不覆盖、系统 tar 与 sha256、日志脱敏、规则 3 / 6）
- 审查器与模型：cursor CLI `cursor-grok-4.6-high`（`--mode ask`），没有回落
- 审查范围与基准提交：**第 1 轮** `main...HEAD`（HEAD = `3bacb8c`），产物 `.claude/reviews/20260916-130408-review.out.md`，约 9 分钟

**第 1 轮：3 条（high 1 / P2 2），全部采纳**（整改提交 `d6fdf0a`）

| # | 级别 | finding | 处理 |
|---|---|---|---|
| 1 | high | 认证页的「取消」/ 收起 / 从另一入口重开都只清空 `authElicitations`，不回应挂起的 requestScope elicitation；agent 在途的 `authenticate` 永远等这条 JSON-RPC 回应 | 采纳。`closeAuth` / `openAuth` 清空前走 `_cancelAuthElicitations`：pending 的逐条经现有 `cancelElicitation` 回 `{action: cancel}`；已 accept 的（浏览器已开）没有第二个响应，只从页上拿掉。新增用例：取消后 `acpRespond` 收到 cancel；accept 一条 + 新挂一条后 `openAuth` 重开，只有挂起那条回 cancel |
| 2 | P2 | npx 安装在 `write_settings` 之后才握手，握手不看 CancelToken：取消把装好的结果报成 cancelled；`registry_remove` 等 5 s 就删目录，晚到的 `manifest.save` 会把 `install.json` 写回；initialize 永不返回时 in-flight 表不摘键 | 采纳。写入 settings 定为提交点：之后不再 `token.check()`；握手用 `tokio::select!` 与 `token.cancelled()` 赛跑——核过 `agent.rs`：connect 的 future 被丢掉时它持有的 kill 通道发送端析构，`exit_watcher` 立刻 `kill_tree`，不是原注释说的「会留孤儿」；握手失败 / 取消回滚成没装过（删 `agents/<id>/`，settings 条目只删本次新建的，原有的带用户 env 不动）；`registry_remove` 宽限期后安装仍在途 → 返回错误「安装还没退出，稍后再试」而不是删目录。`docs/design.md` § 6 第 3 条补了口径 |
| 3 | P2 | 设置页「保存」只回写 `{type, command, args, env}`，`upsert` 整条替换，从 Zed 导入的 `default_config_options` 等 extra 被写空 | 采纳。`agent_settings_set` 收到不带 extra 的 custom 条目时沿用旧条目的 extra（Rust 侧一处判断，前端不用知道这些字段）；加单测：带 `default_config_options` 写入后只改 command，字段仍在 |

整改后 `cargo test -p acp-core`（16 + 4 个用例）、`cargo clippy --workspace -D warnings`、`flutter test test/app/`（17 个用例）全过。

**第 2 轮：2 条（high 0 / P2 2），全部采纳**（范围仍是全量 `main...HEAD`，HEAD = `23e3864`；产物 `.claude/reviews/20260916-132130-review.out.md`，约 11 分钟；
整改提交 `d44d20b`，夹具提交 `05baaa8`）

第 1 轮三条的整改经复核成立（`e.agentId` 在 `closeAuth` 清掉 `authAgentId` 之后仍可用；`settings_created` 只在新建时为 true；
select 丢掉 connect 的 future → `kill_tx` 析构 → `exit_watcher` 走 `kill_tree`，进程侧收尾成立）。新出的两条：

| # | 级别 | finding | 处理 |
|---|---|---|---|
| 1 | P2 | 取消 / 失败后立刻 `rollback_install`，不等另一个 task 里的 `kill_tree` 结束；Windows 上握手子进程还占着 `agents/<id>/node_modules/…`，`remove_dir_all` 失败被 `let _` 吞掉 → settings 已删、`install.json` 还在、列表显示「已安装」而 `agent_connect` 报 `agent_not_configured` | 采纳（按 finding 给的第二种最小修法）。回滚改成先删 `install.json`（`is_intact` 立刻为假，状态先变真）、再删本次新建的 settings 条目、最后 `remove_dir_all` 最多 20 × 250 ms 重试；重试用尽不当成功——剩下的目录由下一次安装覆盖 |
| 2 | P2 | `closeAuth` / `openAuth` 之后在途的 `startAuth` 仍无条件写 `authPhase`，成功路径再 `closeAuth()` + 切工作台：认证中取消再从列表点登录，旧的失败画到新页上、旧的成功把新页清掉 | 采纳。认证页加代际计数（`openAuth` / `closeAuth` 各加一），`startAuth` 每个 await 之后核对，过期就 return；新增用例两条路径（`authenticate` 挂门，页收起再重开后才放行：失败不改 phase / 成功不建会话不切页） |

整改后 `cargo test -p acp-core`、`cargo clippy --workspace -D warnings`、`flutter analyze`（与门禁一致的 9 条 info）、`flutter test test/app/`（19 个用例）全过；
Windows 实测见下表「取消与回滚」行（两条整改都靠真跑验证过落点）。

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-05/BLOCKED.md`，停下呼人。禁止放宽验收标准自我通过。

## 本轮实测

### 提交序列

| 阶段 | 提交 | 内容 |
|---|---|---|
| 开工 | `e3014f4` | 任务卡 + `docs/design.md` § 2 / § 3 / § 5 / § 6 / § 10 契约文字 |
| 画板阶段收口 | `5a9c5a6` | 画板 50 / 51 / 52 / 70 的 widget、`lib/projection/registry.dart`、gallery 四张、tokens / icons |
| 接线（Rust） | `fa9dfd2` | `rust/registry` 填实、`rust/settings` 补 Zed 字段 / remove / 从 Zed 导入、acp-core 编排 + 日志、桥十条命令 + 第六条事件流 |
| 接线（Flutter） | `fe3f67b` | 组合根接 registry 面板 / 认证页 / 设置页、`ACP_R5_REPORT` 无头口子、接线单测 |

接线零 diff 判据：`git diff 5a9c5a6..HEAD -- lib/theme lib/ui` 为空（接线阶段全程；见下方「验收 7」）。

### 偏离与理由（按 CLAUDE.md 规则逐条对得上号的地方才写在这里；其余记 BACKLOG）

| # | 项 | 偏离 | 理由 |
|---|---|---|---|
| 1 | Zed `node_runtime` / `http_client` / `util` 的复用方式 | `docs/design.md` § 2 原定「直接 git 依赖」，本轮改成**参考转写**到 `rust/registry/src/{node,download,archive,install}.rs`（每个文件头 `Derived from …`），依赖只加了 reqwest + sha2（都在规则 1 清单内） | ① Zed 的 `ManagedNodeRuntime` 把受管 Node 写到它自己的 `paths::data_dir()`（`%LOCALAPPDATA%\Zed\node`），与「数据目录只多 `node/`」（验收 3）冲突，绕过要调进程全局的 `set_custom_data_dir`；② 它拉进 smol / async-std / async-tar / async-compression 第二套异步栈，和 tokio 单运行时并存；③ git 依赖要把整个 Zed 仓库进 cargo 的 git db，或 path 依赖到 gitignored 的 `vendor/upstream/`。**此项请所有者确认**（`docs/design.md` § 2 已记） |
| 2 | 压缩包解压 | 不引 zip / tar / flate2（规则 1 清单外），用系统 `tar`：Windows 先取 `%SystemRoot%\System32\tar.exe`（bsdtar，zip / tar.gz / tar.bz2 都认），macOS 也是 bsdtar，Linux 的 GNU tar 不认 zip 时回落 `unzip` | 零新依赖；Windows 10 1803 起自带。实测坑：PATH 上排在前面的可能是 Git for Windows 的 GNU tar，它把 `C:\…` 当远程主机（`Cannot connect to C: resolve failed`），所以 Windows 固定取 System32 那份 |
| 3 | 画板 51 npx 第二步文案 | 画板写「写入 agents.json」，实现显示「写入 settings.json」 | 数据目录里没有 `agents.json`（`docs/design.md` § 10），安装写的是 settings.json 的 `{type: "registry"}` 条目 + `agents/<id>/install.json`；已记 BACKLOG 请下个设计轮改字 |
| 4 | 画板 51「需要认证」的描述 | 画板写「需要先完成 ChatGPT 登录」，实现显示「需要先完成认证」 | 规则 2 不按 agent 特判；ChatGPT 是 codex 的方法名，来自 `authMethods`，认证页里会按原名列出 |
| 5 | 画板 50 未安装条目的分发方式芯片 | 画板 50 的未安装行没有 `npx` / `binary` 芯片，画板 51 的未安装卡有；实现统一按 51（未安装 / 安装中 / 失败态显示芯片，已安装不显示） | 同一条目 widget 两处共用；芯片是本地信息（分发方式），有比没有更利于用户判断要不要装受管 Node |
| 6 | 画板 70 registry 型的「编辑」 | 画板头注写「registry 型只读」但每行都有「编辑」键；实现里 registry 型点「编辑」展开一块**只读**的拉起参数（来自 `install.json`），只有收起键 | 既保留画板的控件，又不违背「只读」 |
| 7 | 日志文件名的日期 | `logs/acp-<日期>.log` 的日期按 UTC | 不引 chrono、不做时区换算（规则 1 清单外）；文件名只用来分天，设置页显示的是真实路径 |
| 8 | `terminal_close` 提前到 R5 | 契约把它归 R4 的本地 shell 四命令 | 认证页的停止方块要结束 pty 里的 terminal auth；实现是 `kill` + `release` 两步，R4 的本地 shell 可直接复用 |
| 9 | 画板 52 agent 型认证进行中 | 画板没有「等 agent 完成认证」的状态；实现把选方法卡的底栏换成 spinner + 「等待 <agent> 完成认证…」 | `authenticate` 在途时页面要有反馈；只是状态文案，不是新控件 |
| 10 | 受管 Node 的 npm | 系统 Node 在时用系统 `npm.cmd`；受管 Node 用 `node <受管目录>/node_modules/npm/bin/npm-cli.js` 并带空的 `--userconfig` / `--globalconfig`（照 Zed） | 不碰用户的 `~/.npmrc`（规则 7 的精神） |

### 无头实跑的口子（`ACP_R5_REPORT`）

GUI 点击在本会话里没有自动化通道（R3 任务卡「环境与踩的坑」），沿用 R3 的做法：`lib/app/headless_run.dart` 加 `runR5`，
驱动同一个 `WorkbenchController`（UI 点下去走的就是它）对真实 agent 跑一遍 registry → 受管 Node → 安装 → 新会话 → 认证 →
一轮 → 从 Zed 导入 → Remove，结果写 JSON。启动器 `scratchpad/r5-run.ps1`：每次给一个**干净的数据目录**
（`APPDATA` 指到 `D:\cargo-target\AcpAgentClient\r5-data\<name>`），报告在 `r5-data\<name>-report.json`。

### 验收 1（接线部分）· fake-agent 的两种认证（离线，确定性）

`test/fake-agent/fake-agent.mjs` 本轮加了 agent 型方法 `fake-url`（`authenticate` 在途时发 requestScope 的 URL elicitation，
`requestId` 是 authenticate 的数字 id，照 codex-acp 的 device code 路径），原有 terminal 型 `fake-setup` 不变。

| 跑 | 变量 | 结果 |
|---|---|---|
| `fake-url`（agent 型） | `ACP_R5_AGENT=fake-agent ACP_R5_AUTH_METHOD=fake-url ACP_R5_PROMPT=hi` | `session/new` → `-32000` → `authRequired: true`、右栏切到 Agents 标签（认证页）、`authMethods` 两条（`fake-setup/terminal`、`fake-url/agent`）→ `startAuth` → requestScope 卡出现并 accept（`requestScopeUrls: ["https://example.invalid/fake-login"]`）→ `elicitation/complete` → `authenticate` 返回 → 自动重试 `session/new` 得 `sess_fake_1`、`authPageClosed: true` → 一轮 `end_turn`（权限 / form / url 三条请求都按接线回应）。exit 0，2.3 s |
| `fake-setup`（terminal 型） | `ACP_R5_AUTH_METHOD=fake-setup ACP_R5_AUTH_INPUT=FAKE-KEY-123 ACP_R5_AUTH_INPUT_DELAY=3` | `terminal_auth_run` 在 pty 里以 `--setup` 重拉同一个程序，3 s 后把模拟键盘写进终端，进程退出 0 → 核心自动重试 `session/new` 成功（`sess_fake_1`）→ 一轮 `end_turn`。exit 0，5.2 s |

规则 8 核对（`logs/acp-2026-09-16.log`）：fake-agent 往 stderr 写的 `token=FAKE-TOKEN-…` 在日志里是 `token=***`；敲进终端的假密钥不进日志
（`acp/terminal_output` 不落盘），`grep FAKE-KEY-123` 为 0。

### 验收 1 · codex-acp（真跑，干净数据目录，联网）

`ACP_R5_REFRESH=1 ACP_R5_INSTALL=codex-acp ACP_R5_PROMPT="用一句话回答：1+1 等于几？不要调用工具。" ACP_R5_REMOVE=1`（报告 `r5-data/codex-report.json`）：

| 步骤 | 结果 |
|---|---|
| 刷新 registry | 41 条（线上 registry.json 1.0.0），图标缓存到 `registry-cache/icons/` |
| Install（npx 型） | `resolve`（`npm install @agentclientprotocol/codex-acp@0.0.0 - 1.12.0 --save-exact`，装到 `agents/codex-acp/node_modules/`）→ `write_settings`（`{"type":"registry"}`）→ `handshake`（`node …/codex-acp/dist/index.js` 拉起，`initialize` 成功，agentInfo 记进 `install.json`，随后 disconnect）→ `done`，16.2 s；画板 51 的三步都经 `registry/progress` 到达 |
| `session/new` | 直接成功（`01a0a863-…`）：本机 `~/.codex/config.toml` 走自定义模型网关，codex-acp 不要求登录，所以**没有走到 `-32000`**；`install.json` 的 `authStatus` 记为 `authenticated`（画板 50 / 51 的「已登录」徽章） |
| 一轮 | `end_turn`，4.3 s，usage `totalTokens 10642`（input 10523 / output 119 / thought 111）；`session_info_update` 三次把标题改成提示词；`available_commands_update` 一次 |
| Remove | `agents/codex-acp/` 删除（`dirExistsAfter: false`）、settings 条目消失、条目回未安装；数据目录其余项（`logs/ projects.json registry-cache/ sessions.json settings.json`）不动（规则 7） |

**没跑到的两条**（本机没有对应凭据 / 配置，留给所有者手测）：① ChatGPT device code 登录（`chat-gpt-device-code`，requestScope URL elicitation）——
本机 codex 不要求认证；这条链的客户端侧已用 fake-agent 的 `fake-url` 方法离线跑通（上一段），核心侧的转发 / 回应 / `elicitation/complete` 都是同一套代码；
② `OPENAI_API_KEY` 环境变量路径——本机没有设置该变量（`api-key` 方法由 agent 自己从 env 读，客户端不经手密钥）。

### 验收 2 · Cursor（binary，真跑）

`ACP_R5_REFRESH=1 ACP_R5_INSTALL=cursor ACP_R5_AUTH_TIMEOUT=30`（报告 `r5-data/cursor-report.json`）：

| 步骤 | 结果 |
|---|---|
| Install（binary 型） | `download`（`https://downloads.cursor.com/lab/2026.09.10-…/windows/x64/agent-cli-package.zip`，74,169,932 字节，进度经 `registry/progress` 的 `done` / `total` 推出）→ `verify`（**registry 的 cursor 条目没给 sha256**，跳过并把实际值 `cdf0b9…` 记进 `install.json` 的 `verifyNote`）→ `extract`（系统 tar 解到 `agents/cursor/2026.09.10/`，214 MB）→ `done`，13.9 s |
| 拉起 | `install.json` 记 `command: …\2026.09.10\dist-package\cursor-agent.cmd`、`args: ["acp"]`（`./dist-package\cursor-agent.cmd` 的混合分隔符按段拼成绝对路径）；`.cmd` 经 std 的 `cmd.exe /c` 带引号拉起（路径含 `r5-data` 无空格；含空格与中文的路径见 `rust/registry` 的 tar 测试与 R1 的 `.cmd` 实测），`initialize` 成功 |
| `session/new` | `-32000 Authentication required`，`authMethods = [cursor_login（agent 型）]`——**这个版本的 Cursor 没有 terminal 型方法**（ROUNDS 写的「terminal auth `agent login`」不成立），`install.json` 记 `needs_auth`（画板 51「需要认证」态 + 登录键） |
| 认证 | 认证页选 `cursor_login` → `authenticate` → agent 自己打开系统浏览器等人登录，30 s 后无头脚本超时（`TimeoutException`）；**浏览器里的登录要所有者手测**，随后的「自动重试 session/new → 一轮」与 codex 是同一条接线 |

人为篡改 sha256 → 失败态、可重试、可看日志：在 `rust/registry/src/install.rs` 的 `binary_install_round_trip_and_sha_mismatch`（本地 HTTP 服务 + 真 zip + 系统 tar）
里断言了 `Verify` 错误、staging 清理、上一版本目录不受影响；UI 侧的失败态 / 重试 / 查看日志在断网实跑（验收 6）里走了一遍（`failed` 进度 → 条目失败态 + 日志块自动展开）。

### 验收 4 · 从 Zed 导入

把本机 `%APPDATA%\Zed\settings.json` 复制到实跑数据目录的 `Zed\settings.json`（不动原件，规则 7），`ACP_R5_IMPORT_ZED=1`：
`已导入 5 条（claude-acp、codex-acp、cursor、dsh-acp-interactive、pi-acp），跳过同名 0 条`；`settings.json` 里 registry 型四条保留 `default_config_options`
（Zed 字段经 `extra` 原样带过来），custom 型 dsh 的 `command` / `default_config_options` 原样；面板上 dsh 显示为 custom 条目（已安装），
registry 型四条按 id 对上 registry 条目、因为没有安装记录显示为未安装（Install 会复用已有的 settings 条目）。同名不覆盖在 `zed_import.rs` 的单测里断言
（本地已有 dsh 时导入不改它的 `command`，二次导入 5 条全部跳过且文件不重写）。

### 验收 5 · Remove

见验收 1 的 Remove 行；`registry_remove` 顺序是：取消在途安装 → 断开连接 → 删 settings 条目 → 只删 `agents/<id>/`（`install.rs::remove` 先核父目录是 `agents/`）。
单测 `remove_only_touches_own_agent_dir` 断言别的 agent 目录与 `node/` 不动。

### 验收 3 · 受管 Node（PATH 里剔除 Node）

`-PathOverride` 把 `nodejs` / `npm` 目录从 PATH 里去掉后跑 `ACP_R5_NODE_DOWNLOAD=1 ACP_R5_INSTALL=pi-acp`：

| 步骤 | 结果 |
|---|---|
| 启动时 Node 状态 | `system: null, managed: null`（面板顶上就是画板 51 的受管 Node 提示卡） |
| 下载受管 Node | `https://nodejs.org/dist/v24.11.0/node-v24.11.0-win-x64.zip` → 系统 tar 解到 `node/node-v24.11.0-win-x64/` → `node --version` 自检 = `v24.11.0` |
| 安装 pi-acp（npx 型） | 用受管目录里的 `npm-cli.js`（空 npmrc、私有 cache）`npm install pi-acp@0.0.0 - 0.0.33`：`resolve` → `write_settings` → `handshake` → `done`，20.4 s；`install.json` 记 `command: node`、`args: [agents/pi-acp/node_modules/pi-acp/dist/index.js]`、`agentInfo: {name: pi-acp, title: pi ACP adapter, version: 0.0.33}` |
| 数据目录 | `agents/ logs/ node/ projects.json registry-cache/ settings.json` —— 只多 `node/`（与 `agents/`，那是安装本身） |
| `session/new` | pi-acp 回 `-32603 Internal error: Cannot call write after a stream was destroyed`：pi-acp 要本机装有 `pi` CLI（它拉 `pi --mode rpc`），本机没有；这是 R6 的参照 agent，本轮只验到握手 |

### 验收 6 · 断网

在上一条的数据目录（已有 41 条缓存）上把 `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` 指到 `http://127.0.0.1:9`：
列表仍是 41 条（`fetchedAt` 是缓存时间）；强制刷新后 `fetchError = 网络错误：拉取 registry.json：error sending request …`；
`Install amp-acp`（binary）→ 条目进失败态，`failure = 网络错误：https://github.com/…/amp-acp-windows-x86_64.zip：error sending request …`，
进程照常退出 0、报告完整。

### 验收 7 · 画板逐张对照与门禁

`flutter test test/gallery_test.dart` 出 50 / 51 / 52 / 70 四张到 `build/gallery/`，与 `design/round-design/*.png` 并排看，文案 / 状态 / 层级 / 控件齐。偏离见上表 3 / 4 / 5 / 6。
另：50 的中栏样例取 fixtures（`New DeepSeek Harness Thread`），画板上是 `New Claude Agent Thread`（数据驱动，ROUNDS § 0 第 5 条）；
52 多出一张「已打开浏览器，等 elicitation/complete」样张（画板 28 的第二态在 requestScope 卡上的样子），数据来自 `26-auth-url-elicitation.jsonl`。

    powershell -File scripts/validate.ps1      # 13 项全 PASS，VALIDATE OK（接线（Flutter）提交 fe3f67b 上跑的；日志 scratchpad/validate-1.log）
    flutter test                               # 119 passed（R3 的 103 + gallery 4 张 + 接线 5 + 对齐测试改字体 + …）
    cargo test --workspace                     # 全绿（registry 16 / settings +2 / acp-core log 2 / fixtures +1 文件）
    git diff 5a9c5a6..HEAD -- lib/theme lib/ui # 空

第二次全量 `validate.ps1`（含 fixtures 26、fake-agent、竞态与日志两处修正之后）见 `scratchpad/validate-2.log`，结论回填在下方「门禁复核」。

### Windows 实测记录（规则 9）

| 项 | 命令 / 现象 |
|---|---|
| `.cmd` 包装拉起 | Cursor 的 `…\2026.09.10\dist-package\cursor-agent.cmd acp`：std 经 `cmd.exe /c` 带引号拉起，`initialize` 成功（验收 2）；npx 型不经 `.cmd`，直接 `node <bin.js>`（照 Zed，避开 `npx.cmd` 的临时缓存与引号问题） |
| npm | 系统 `npm.cmd`（PATHEXT 解析，`C:\Program Files\nodejs\npm.cmd`）与受管 `node npm-cli.js --cache … --userconfig <空> --globalconfig <空>` 两条路都装成功；包规格 `pkg@0.0.0 - 1.12.0` 含空格，作为单个 argv 经 `cmd.exe` 传给 npm 没被拆开 |
| 解压 | `C:\Windows\System32\tar.exe`（bsdtar 3.8.8）解 zip（Cursor 74 MB、Node 30 MB）；单测 `system_tar_extracts_a_zip_into_a_non_ascii_dir` 在路径含空格与中文（`acp-registry-tar 测试-<pid>\包 archive.zip` → `目标 dir`）下过。坑：PATH 上排在前面的 Git for Windows GNU tar 把 `C:\…` 当远程主机，所以 Windows 固定取 System32 那份 |
| sha256 | `binary_install_round_trip_and_sha_mismatch`：本地 HTTP 服务 + 真 zip，大小写不敏感比较通过；篡改后 `Verify { expected, actual }`，staging 目录清掉、上一版本目录不动。Cursor 条目没给 sha256：跳过并把实际值记进 `install.json`（画板 51 的「sha256 校验」步在这种条目上显示「registry 条目没给 sha256，跳过校验」） |
| 受管 Node | `node-v24.11.0-win-x64.zip` → `node\node-v24.11.0-win-x64\node.exe --version` = `v24.11.0`；不改 PATH，只在拉起 npx 型 agent 时把该目录插到子进程的 PATH 前面 |
| 子进程无控制台 | registry crate 的 npm / node / tar / taskkill 都带 `CREATE_NO_WINDOW`（与 acp-core 同一口径） |
| 数据目录路径 | 实跑数据目录在 `D:\cargo-target\AcpAgentClient\r5-data\<name>\AcpAgentClient`（ASCII）；含中文的路径只在 tar 单测里盖到，agent 安装到含中文数据目录下的整链没有真跑（本机 `%APPDATA%` 是 ASCII） |
| 取消与回滚（审查整改后，提交 `d44d20b` + `05baaa8` 的构建） | `ACP_R5_CANCEL_AT=handshake`（codex-acp，`run-cancel-at-hs.log`）：`handshake` 事件到即取消，子进程 `spawned` 后 274 ms 收到 `cancelled`，`agents/` 空、`settings.json` 为 `{"agent_servers": {}}`、`installed: false`，事后没有新起的 node / codex 进程；核心日志里子进程因回滚删文件先报 `MODULE_NOT_FOUND` 退出（回滚与 `kill_tree` 并发，这次是删目录赢了，重试循环没用上）。`ACP_R5_CANCEL_AT=resolve`（`run-cancel-at-resolve.log`）：npm 在 574 ms 内被结束，没有 settings 条目，`agents/codex-acp/` 留着半个 npm 目录（提交点之前，记 BACKLOG）。定时取消（`ACP_R5_CANCEL_AFTER=7` / `13`，`run-cancel-hs3.log` / `run-cancel-hs7.log`）两次都落在 `initialized` 之后：按设计不再取消，`done` + 已安装 + `session/new` 成功——握手可取消的窗口只有 spawn → initialize 的 1.6 s，所以夹具加了按步骤取消。整改前的构建（`run-cancel-hs2.log`，取消落在 spawn 后 0.5 s）同样回滚干净，子进程 0.74 s 后 `exited code=1` |

### 已知限制与需所有者手测

1. **浏览器里的登录**：Cursor 的 `cursor_login`（agent 型）与 codex 的 `chat-gpt` / `chat-gpt-device-code` 都要人在浏览器完成，本会话没有通道；
   客户端侧（认证页 → `authenticate` → requestScope 卡 → accept → `elicitation/complete` → 自动重试）用 fake-agent 跑通，核心侧是同一套代码。
   跑法：`build\windows\x64\runner\Release\acp_agent_client.exe`，Agents 面板装 cursor → 新会话 → 认证页选 `cursor_login` → 浏览器登录。
2. **`OPENAI_API_KEY` 路径**：本机没设；设了之后 codex-acp 的 `api-key` 方法由 agent 自己读 env（`authenticate` 不带 `_meta`，见 BACKLOG）。
3. **Cursor 没有 terminal 型方法**：ROUNDS § 3 / § 4 写的「terminal auth `agent login`」按 2026.09.10 版的 `authMethods` 不成立，只有 `cursor_login`（agent 型）；
   terminal 型的路径用 fake-agent 的 `fake-setup` 验（dsh 的 `--setup` 是 R1 验过的同一条）。
4. **含中文数据目录下的安装整链**没有真跑（见上表末行）。
5. **pi-acp 的 `session/new`** 在本机回 `-32603`（要装 `pi` CLI），本轮只验到握手；pi-acp 是 R6 的参照 agent。
6. 无头实跑退出不走 `agent_disconnect`，Cursor 拉的 `node.exe` 留成孤儿（记 BACKLOG，归 R4 的「应用退出回收子进程」）。

### 环境与踩的坑（本机）

- **`OverlayPortalController.hide()` 未挂载时 assert**：R3 的控制器在 `newSession` / `openProject` 开头无条件 `hide()`，Release 里 assert 被剥掉所以无头实跑没事，
  debug 单测一进 `newSession` 就炸。改成只在 `isShowing` 时 hide（`isShowing` 未挂载时不 assert）。
- **`refresh(force)` 与启动时的后台刷新竞态**：`registry_refresh` 遇到在途拉取原来立刻回 false，无头脚本「刷新 → 立刻安装」撞上「registry 里没有这个 id」；
  改成等在途那次结束。
- **日志刷屏**：下载进度每块一条 `registry/progress`，`LoggingSink` 原样落盘写了两千多行；改成按 `(agentId, step)` 去重。
- **flutter_tester 的占位字体**：`ACP Registry` 标签比真实字体宽一倍，把右栏标签条撑溢出，`shell_alignment_test` 那组改成加载真实字体再量。
- **Bash 工具里 python 补丁的反斜杠 / 引号**：含 `\S`、`\t` 的 Rust 文本经 heredoc 进 python 会被解释，两次补丁静默失配；改用 Edit 工具。
- **Git for Windows 的 GNU tar**（见上表）。
- **requestScope 的 `requestId` 是数字**：R3 的 `ElicitationRequestWire.requestId` 只认字符串，codex-acp（`authenticate` 的 JSON-RPC id）会被判成「不是 requestScope」，
  认证阶段的 elicitation 就没有落点；本轮改成按字符串形状给出，并进 fixtures 26。

### 门禁复核

第二次全量 `powershell -File scripts/validate.ps1`（树 = 4f514c9 + 本任务卡 / BACKLOG / ROUNDS 的文档改动，2026-09-16 13:01 跑完，日志 `scratchpad/validate-2.log`）：
13 项全 PASS，`VALIDATE OK`——fetch-upstream -Check、rust-sdk pin、unsafe 扫描、`_meta` 键、Zed 派生头、pubspec 白名单、`Assert-NoStyleLiteral`、
`cargo build / test / clippy -D warnings`、`cargo tree` 无 gpui、`flutter analyze`、`flutter test`（119 个用例，gallery 输出 50 / 51 / 52 / 70 四张 PNG）。
与第一次（fe3f67b）相比只多了 fixtures 26、fake-agent 的 agent 型认证、`registry_refresh` 竞态修正与日志去重，结论不变。
