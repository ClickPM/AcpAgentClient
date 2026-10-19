# Round 10 — Agents 面板的进程与内存（v1.6.0）

> 从 `rounds/TEMPLATE.md` 复制，依据所有者 2026-10-18 的诉求与裁定填写。硬性规则以 `AGENTS.md` 为准。

> 状态：实现与自动化验证完成，待真实 agent / 性能 / 跨平台及打包验收；2026-10-19 所有者指示开始开发。未提交、未合并、未发布。

- 分支：`round-10`（开工时从 `main` 开出）
- 目标版本：**v1.6.0**（规则 11：`pubspec.yaml` 与 `rust/Cargo.toml` `[workspace.package]` 两处同改，sidecar 不跟）
- 画板：54「Agents 面板 · 进程与内存」（`design/round-design/54-agent-processes.dc.html` / `.png`）；简报 `design/round-design/input/revision-09.md`

## 背景与诉求

所有者 2026-10-18 提出两条：

1. 加一个 dashboard，看本应用（AAC）**及其子进程的总内存消耗**。
2. 支持**按进程关闭活跃的 agent**：pi-acp、agy 等 agent 不声明 `sessionCapabilities.close`，侧栏的「挂起」（`session/close`，iteration-19）对它们不渲染；一旦拉起，除了「重载 agent」（它会重连）或退出应用，界面上没有办法把它停掉。

现状核对（2026-10-18，`main@91cf8bb`）：

- 结束 agent 的能力核心里**已经有**：`Core::agent_disconnect`（`rust/acp-core/src/core.rs:290`）→ `AgentConnection::disconnect`（`rust/acp-core/src/agent.rs:1232`）：关 stdin → 等 `DISCONNECT_GRACE`（3 s）→ `kill_tree`（Windows `taskkill /F /T /PID`，Unix 进程组 `-TERM` / `-KILL`）→ 再等 3 s 仍不退就 `finish(None)` 就地收尾并发 `exited`。桥与 Dart 侧也已有 `agentDisconnect`（`lib/app/core_bridge.dart:61`），但只被「重载 agent」（`lib/app/session_controller.dart:576`）与无头驱动调用，**UI 上没有入口**。
- `exited` 之后的前端收尾**已经有**：清该 agent 的发送队列（`workbench_controller.dart:222`）、挂起的权限 / elicitation 标 `withdrawn`、该连接拥有的终端释放（`Shared::release_owned_terminals`）、会话按 iteration-09 的四态变「挂空」，再次打开时先挂回（`session/load` / `session/resume`）。
- PID：agent 根进程 PID 在 `acp/agent_state: spawned` 里（`agent.rs` `connect`）；终端 PID 在 `pty::TerminalHandle.pid`。
- **内存数据没有**：前端只能拿到宿主进程自身，子进程树与各进程内存要在 Rust 侧枚举。

## 裁定（所有者 2026-10-18）

| # | 问题 | 裁定 |
|---|---|---|
| 1 | 进程枚举与内存读取的实现 | **A：引入 `sysinfo` crate**，进规则 1 的 Rust 通用库白名单（见下「依赖说明」）。不走 PowerShell / `Get-CimInstance` 子进程（每次采样拉一个 powershell 冷启动 0.5–1 s）；不手写 Win32 FFI（规则 6 禁 `unsafe`） |
| 2 | 内存口径 | **专用内存**（Windows：Private Bytes = 任务管理器「详细信息」页的「提交大小」）；合计按子进程求和，数字一律带「约」，口径名写在概览条上、悬停出整句 |
| 3 | 放在哪 | **B：并进 Agents 面板（画板 50）**：标题行下加资源概览条，运行中的条目加运行行 / 进程树 / Stop。不新开右栏标签、不加顶栏徽标 |
| 4 | 终端进程 | **只展示**：终端面板 shell 与 terminal auth 终端归「终端」段，不在这里给停止（停止仍在终端面板）。agent 经 `terminal/create` 开的终端归该 agent，随 Stop 一起结束（它本来就随连接结束而释放） |

开工前另需所有者确认的两点（设计稿已按推荐画）：

- **macOS 口径**：`sysinfo` 在 macOS 上 `virtual_memory()` 是 `pti_virtual_size`（虚拟地址空间，GB 级，没有参考意义），只有 `memory()` = 常驻内存（RSS）可用。推荐 macOS 显示**常驻内存合计**、概览条口径名写「常驻内存」；Windows 照裁定 2 用专用内存。
- **Running 过滤**：画板 54 在 All / Installed / Not Installed 之间加了 `Running N`。推荐保留（运行中的 agent 散在长列表里不好找）；不要就从画板删掉再开工。

## 目标

Agents 面板上能看到本应用进程树的专用内存合计与按 agent 的分摊，并能对**任何**已连接的 agent（不论它声明了什么能力）一键结束其整棵进程树；结束后会话转录保留、再打开时照 iteration-09 挂回。可证伪：Windows 上连 pi-acp → 面板出现运行行与内存 → Stop → `tasklist` 里该 PID 及其子孙全部消失、侧栏会话变挂空、再发消息能重连并载回。

## 前置

- `scripts/fetch-upstream.ps1 -Check` 全绿（pins 不改）
- 画板 54 所有者过稿（含上面两点确认）
- 参照 agent：pi-acp（不声明 close，诉求原型）、claude-agent-acp（`.cmd` → node 多级子进程 + `terminal/create`）、dsh（内置条目）；fake-agent 做离线确定性用例

## 依赖说明（规则 1）

- crate：`sysinfo`（钉版本开工时取当时最新的 0.39.x，`rust-version` 1.95 ≤ 本仓 1.98.1）；`default-features = false, features = ["system"]`，不带 disk / network / component / user。
- 理由：跨平台进程表（pid / parent / name / memory / start_time）在 Windows 上走 ToolHelp + `GetProcessMemoryInfo`（`PROCESS_MEMORY_COUNTERS_EX`：`memory()` = `WorkingSetSize`、`virtual_memory()` = `PrivateUsage`，源码 `src/windows/process.rs:324-325` 已核对），macOS 走 `proc_pidinfo`；`unsafe` 全在 crate 内部，我们的代码零 `unsafe`（规则 6 只约束本仓源码，validate 的 `unsafe` 字面扫描不覆盖依赖）。
- 传递依赖：Windows 下 `windows` crate（已在 Cargo.lock 里，版本可能多一份）+ `ntapi`；macOS 下 `objc2-core-foundation` / `objc2-io-kit`；`libc`、`memchr`。均不含 gpui（规则 5 的 `cargo tree` 门照跑）。
- 落点：只进 `rust/acp-core`（新模块），不进 `rust/bridge` 之外的其他 crate。
- 同步：`AGENTS.md` 规则 1、`docs/requirements.md` § 8 的 Rust 允许清单各加一项「`sysinfo`（所有者裁定 2026-10-18：进程树与内存采样，画板 54）」。

## 交付物

### 设计（本轮设计阶段，已完成）
- `design/round-design/54-agent-processes.dc.html` + `54-agent-processes.png`（1200 × 1830，page-4 `x 5360, y 0`）
- `design/round-design/canvas.json` 补画板 54
- `design/round-design/input/revision-09.md`（修订简报）
- `design/README.md` 索引与变更记录

### 契约（`docs/design.md` § 3，开工第一步先改文档）
- 新命令 `process_snapshot` → JSON：
  ```json
  {
    "metric": "private" | "resident",
    "takenAt": 1760000000000,
    "app":   {"pid": 1234, "bytes": 281432064},
    "agents": [{"agentId": "claude-acp", "rootPid": 18324, "bytes": 641728512,
                "startedAt": 1759995680000,
                "processes": [{"pid": 18324, "parentPid": 1234, "name": "cmd.exe", "bytes": 1990656, "depth": 0}, ...],
                "terminals": [{"terminalId": "term_3", "pid": 21004, "bytes": 57042944}]}],
    "terminals": {"count": 2, "bytes": 96048742, "items": [{"terminalId": "...", "source": "local", "pid": 0, "bytes": 0}]},
    "other": {"bytes": 0},
    "total": 1288000000
  }
  ```
  非 ACP 消息、仅用于渲染（与 `acp/terminal_output` 同类）。会话数、是否在跑等**前端已有**的信息不进快照。
- **不新增**停止命令：Stop 直接用已有的 `agent_disconnect`。
- `_meta` 零改动（规则 2）。

### Rust
- `rust/Cargo.toml` `[workspace.dependencies]` 加 `sysinfo`；`rust/acp-core/Cargo.toml` 引用
- `rust/acp-core/src/process.rs`（新）：`ProcessSampler`（持一个 `sysinfo::System`，`refresh_processes_specifics(All, true, nothing().with_memory())`，复用实例避免每次全量重建）；从本进程 PID 建子孙树；按「agent 根 PID → 子树」「终端 PID → 子树」归属（规格表 B）；口径选择 `cfg(windows)` → `virtual_memory()`（PrivateUsage）、`cfg(not(windows))` → `memory()`（RSS）
- `rust/acp-core/src/agent.rs`：`Shared` 记根 PID 与启动时间（现在只在 `spawned` 事件里发了一次，不留存）
- `rust/pty/src/lib.rs`：暴露 `ids_with_pid()`（id / source / pid）供归属，不改既有行为
- `rust/acp-core/src/core.rs`：`Core::process_snapshot()`，阻塞部分走 `blocking(...)`
- `rust/bridge/src/api.rs` + `flutter_rust_bridge_codegen generate`（生成物入库）
- 单测：进程树归属的纯函数用例（构造假进程表，不依赖真进程）；一条真进程用例（拉一个 `sh -c 'sleep'` / `cmd /c timeout` 子进程，断言它出现在本进程子树里且 bytes > 0）

### Dart
- `lib/app/core_bridge.dart`：`processSnapshot()`；`test/app/fake_core.dart` 同步
- `lib/projection/process_snapshot.dart`（新，纯 Dart）：快照 → 概览条三段 + 每 agent 运行行数据
- `lib/app/agents_state.dart`：采样定时器（`resource.sampleInterval` 2 s；仅 Agents 标签可见且窗口未最小化时跑，切走即停，失败停表等手动重试）、`stopAgent(id)` → `agentDisconnect`；停止中态。若 `agents_state.dart` 超 900 行门，拆 `lib/app/process_monitor.dart`，并在 `validate.ps1` / `validate.sh` 依赖方向门登记边（`process_monitor.dart → guarded.dart, core_bridge.dart`）
- `lib/ui/registry/resource_bar.dart`（新）：概览条三态（正常 / 无 agent / 采样中 / 失败）
- `lib/ui/registry/registry_entry.dart`：运行中芯片、运行行、进程树展开、Stop 按钮与停止中态；连接中态
- `lib/ui/registry/registry_panel.dart`：概览条插在标题行与搜索行之间；`Running` 过滤
- `lib/ui/registry/stop_agent_confirm.dart`（新）：B1 / B2 两态确认弹层（样式照画板 41 `DeleteSessionConfirm`）；无会话时不弹（B3）
- `lib/app/workbench_screen.dart`：接线（当前 997 行，门 1000——**接线只能放在 `_registryPanel()` 里换参数**，放不下就先把 `_registryPanel()` 挪到 `lib/app/` 下的独立文件，不放宽门）
- `lib/theme/tokens.dart`：新增 `Resource`（barHeight / legendSwatch / sampleInterval）与 `ProcessTree`（rowHeight / indent / pidWidth / bytesWidth）两组；颜色全部引用既有 token
- `lib/gallery/boards/agent_boards.dart`：画板 54 对照（A / B / C 三段）
- 测试：投影层用例（归属、合计、0 段不画、采样不可用降级）；`agents_state` 用例（标签可见才采样、切走停表、失败停表、Stop 调 `agentDisconnect`、停止中态在 `exited` 后撤掉）；确认弹层分流（无会话不弹 / 有会话 B1 / 有回合或等你处理 B2）

### 文档
- `docs/design.md` § 3（`process_snapshot`）、§ 1 进程模型旁注一句「Agents 面板可停止任一 agent 的进程树」
- `AGENTS.md` 规则 1、`docs/requirements.md` § 8（`sysinfo`）
- `ROUNDS.md` § 2 画板 54 行、§ 7 进度表 R10 行
- `design/README.md` 画板 54 状态改「已实现（R10）」
- 发版：`pubspec.yaml` / `rust/Cargo.toml` → 1.6.0；README「状态」加一行

## 验收

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | 钉版本 | `powershell -File scripts/fetch-upstream.ps1 -Check` 全绿 |
| 2 | 全量门 | `powershell -File scripts/validate.ps1 -CargoTargetDir D:\cargo-target\AcpAgentClient-round-10` 全绿（含 `unsafe` 扫描、`cargo tree` 无 gpui、版本门 1.6.0、lib/app 行数门与依赖方向门、pubspec 白名单）；macOS 上 `scripts/validate.sh` 同样全绿 |
| 3 | 依赖白名单落文档 | `AGENTS.md` 规则 1 与 `docs/requirements.md` § 8 都出现 `sysinfo`；`rust/acp-core/Cargo.toml` 里 `default-features = false` |
| 4 | 口径正确（Windows，规则 9） | 连上 claude-agent-acp，`process_snapshot` 里该 agent 各进程 `bytes` 与 `Get-Process -Id <pid> \| Select PrivateMemorySize64` 逐个对比，偏差 ≤ 5%（采样时刻不同）；命令与输出记「本轮实测」 |
| 5 | 归属正确 | 同一快照：`.cmd` 包装下 `cmd.exe → node.exe → …` 全部归该 agent；agent 经 `terminal/create` 开的终端归该 agent 的 `terminals`；终端面板 shell 归 `terminals`；`total` = 各段之和 |
| 6 | Stop 结束整棵树（Windows，规则 9） | pi-acp 与 claude-agent-acp 各一次：Stop 前 `Get-CimInstance Win32_Process` 记下子树 PID 列表，Stop 后 10 s 内全部不存在；面板条目回到「已安装」、运行行撤掉；路径含中文与空格的工作区下同样通过 |
| 7 | 会话收尾 | Stop 一个有会话、有排队消息、挂着权限请求的 agent：队列清空、权限卡标 withdrawn、侧栏会话变挂空且转录保留；再发消息 → 重连并 `session/load` 载回（pi-acp） |
| 8 | 确认分流 | 单测覆盖：无会话直接停止（B3）、有会话弹 B1、有回合在跑或等你处理弹 B2；取消不发命令 |
| 9 | 采样开销 | 面板打开 60 s，`acp_agent_client.exe` CPU 平均 < 1%（`Get-Counter '\Process(acp_agent_client)\% Processor Time'` 采 30 次取均值）；切到别的标签后 `process_snapshot` 不再被调用（流量 / 日志或单测断言） |
| 10 | 画板对照 | gallery 渲出画板 54 的 A / B / C 三段，与 PNG 逐段对照；偏离记 `design/DIVERGENCE.md` |
| 11 | 发布包 | `scripts/build.ps1 -Smoke` 通过；`scripts/package.ps1` + `scripts/verify-package.ps1` 四条 PASS |

## 禁止

- 默认三条：不改与本轮无关的页面样式（规则 3）；不加设计稿没有的功能（规则 3）；不在 `vendor/upstream/` 里改代码（规则 4）。
- 不做「全部停止」、不做空闲自动停止、不做内存阈值告警、不做历史曲线（都不在画板 54 上；想要先进 BACKLOG 等裁定）。
- 不在侧栏 / 顶栏 / 会话头加任何内存或停止入口（裁定 3）。
- 终端只展示，不给停止（裁定 4）。
- 不按 agent 名字或能力特判 Stop 的可用性（规则 2）：已连接即给。
- 不新增停止命令、不改 `agent_disconnect` 的语义与宽限期；不引入 Windows Job Object（要的话另行裁定，见风险）。
- 不手写 Win32 / libc FFI、不写 `unsafe`（规则 6）。
- Stop 不改 settings、不动安装记录、不动 agent 自己的会话目录（规则 7）。

## 风险与已知限制

- **孤儿进程看不到也杀不掉**：根进程先退出时，孙进程的 parent 指向已不存在的 PID（Windows 不重挂父），从本进程往下建树挂不上，`taskkill /T` 也够不到。本轮不处理：概览条规格写明「不计入」。后续可选：`spawned` 时记录子孙 PID 集合做兜底，或用 Job Object（需裁定，且 `tokio::process` 没有现成接口）→ 收口时记 `rounds/BACKLOG.md`。
- **PID 复用**：两次采样之间 PID 被系统复用会短暂归错；用 `start_time` 与 agent 启动时间比对，早于 agent 启动的进程不归给它。
- **采样耗时**：`sysinfo` 在 Windows 上刷新全部进程约数十毫秒（进程数相关），放阻塞线程池；2 s 周期、只在面板可见时跑。验收 9 兜底。
- **macOS 口径不一致**：常驻内存与专用内存不是同一个量，跨平台数字不可比；概览条上的口径名随平台变。
- **`workbench_screen.dart` 余量只剩 3 行**：接线若放不下，按交付物里写的挪文件，不放宽门。

## 代码审查

<!-- 完成后回填。审查路由见 AGENTS.md「开发模式」与 docs/review-workflow.md：
     ① cursor CLI + grok-4.7-high-fast 是唯一默认执行器 → ② 硬失败就**停下喊人**（不自动回落子代理）。
     范围：前两轮全量（-Scope branch，即 main...HEAD），第 3 轮起只审上一轮整改 diff。 -->

- 审查方式：所有者指定只读子代理（替代默认执行器）。
- 审查器与模型：ChatGPT 订阅 `openai-subscribed/gpt-6.1-sol`；所有者要求 medium，工具无独立 reasoning 参数，未能强制核验。session `d5180e13-11e3-461d-abbb-a710b0d408eb`。
- 审查范围与基准提交：前两轮均为 `db815ecd977ad6bf6f1f094cc168acf51e68744c` 后全部未提交改动及新增文件。
- findings 处理：首轮 high 1 / P2 3，全部整改并补回归：旧 Stop 完成误伤重连、切标签积压采样、升级态遗漏 Stop、认证态采样失败遗漏 Stop。
- 结论：第二轮全量复审 0 findings；不代表尚未执行的实测验收通过。

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-10/BLOCKED.md`，停下呼人。禁止放宽验收标准自我通过。

## 本轮实测

### 2026-10-19 主会话验证

- Dart worker：`cliproxy/gemini-4-argon-high`（非 AI Studio）。Rust worker：Sonnet 5.5 反复断连后按所有者指示切至 `cliproxy/claude-opus-5-5-high`。构建测试均由主会话运行。
- `flutter_rust_bridge_codegen generate` 成功，生成物已更新。
- `powershell -File scripts/validate.ps1 -CargoTargetDir "D:/cargo-target/AcpAgentClient-round-10"`：`VALIDATE OK`，Flutter 683 项通过；Rust workspace build / test / clippy、无 gpui 与静态门全部通过。日志 `build/r10-validate.log`（本地产物）。
- `powershell -File scripts/build.ps1 -Smoke -CargoTargetDir "D:/cargo-target/AcpAgentClient-round-10"`：exit 0，`OK smoke round trip`，`coreVersion: 1.6.0`、`droppedEvents: 0`。日志 `build/r10-build.log`；Windows release 产物在 `build/windows/x64/runner/Release/`。
- Rust 10 条进程采样用例含 Windows 真实子进程；新增 Dart 回归覆盖采样可见性、停止分流、重连代际及升级/认证态 Stop。
- Gallery 54 已渲染到 `build/gallery/54-agent-processes.png`；它是 A/B/C 组件样张，未包含设计稿规格表，不能视为整张 PNG 像素一致。
- `analysis_options.yaml` 排除本地 `ai-output/**`，避免历史临时 Dart 文件阻塞全库 analyze。
- 待完成：验收 4–7 的真实 pi/Claude 内存对照、整树 Stop、中文空格目录及重连；验收 9 的 60 秒 CPU 数字；macOS validate；验收 11 的 package / verify-package。这些项目未宣称通过。
