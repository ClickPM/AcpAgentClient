# Backlog

跨轮次发现的问题与想法都记这里，不当场顺手改；新功能类条目须经所有者裁定才可进轮次。

**本文只留未关闭条目。** 已处理的连同结论原样移到 [`BACKLOG-CLOSED.md`](BACKLOG-CLOSED.md)；
实现与画板不一致的地方（实现先行 / 画板画错 / 实现有意少做）收在 [`design/DIVERGENCE.md`](../design/DIVERGENCE.md)，
按所有者裁定 2026-09-20 **不要求补设计稿**，本文不再重备一份（CLAUDE.md 规则 3）。

## 怎么读这份表

按「谁会撞上、撞上有多疼」分档（所有者 2026-09-20 要的**产品 + 技术双视角**）。每条三行：

- **标题**是一句话说清这是什么问题；
- **产品**是用户会撞上什么、看到什么；
- **技术**是在哪、为什么、最小修法或为什么没修，末尾括号里是发现时的轮次与日期。

| 档 | 条数 | 这档是什么 |
|---|---|---|
| **P0 真缺陷** | 8 | 会丢内容、作用到错对象、吃光资源、静默失败。撞上就是事故，排进最近的轮次。 |
| **P1 看得见的粗糙** | 3 | 用户看得见的不一致、缺等待态、行为不符直觉。能用，膈应；攒批做。 |
| **P2 功能缺口** | 0 | 该有没有的能力。**全部需所有者裁定才能进轮次**，多数还要先改设计稿。 |
| P3 设计稿欠账 | — | **已整体释放**到 `design/DIVERGENCE.md`，见下面的占位小节 |
| P4 平台与分发 | — | **已清空**（2026-09-23）：跨平台暂不做、构建链两条关闭、sidecar 两条移到 `BACKLOG-ZED.md`，见下面的占位小节；以后平台与分发的新问题照常记这一档 |
| P5 内部工程与验收 | — | **已清空**（2026-09-23）：16 条整档收掉（iteration-04），见下面的占位小节；以后测试、行数门、验收自动化这类用户无感的新问题照常记这一档 |
| X 卡在上游 / 协议 | — | **已撤档**：不是本项目的问题不进本表（所有者裁定 2026-09-23），见下面的占位小节 |
| | **11** | |

**新增条目**：挑一档追在该档末尾，照同样的三行格式写。不新开档位；一条只进一档。
**只收本项目自己的问题**：问题出在上游（agent、zed、xterm 等依赖）或协议本身的，不进本表（所有者裁定 2026-09-23，X 档因此撤掉）；其中实现因此与画板对不上的，照规则 3 记 [`design/DIVERGENCE.md`](../design/DIVERGENCE.md)。
**agent 的私有协议扩展目前不接**（所有者裁定 2026-09-23）：某个 agent 自定的 `_meta` 键或私有流程（如 codex-acp 的 `api-key` / `gateway` 认证）不是 ACP 标准，接它就是按 agent 特判（规则 2），这类诉求不进本表。
**内置 Zed agent（sidecar）的问题不进本表**：记 [`BACKLOG-ZED.md`](BACKLOG-ZED.md)（所有者裁定 2026-09-23：原先本表的 4 条连同统筹时新盘点出的 5 条都移到那里，**当前不修**）；背景与上游限制见 [`docs/zed-agent.md`](../docs/zed-agent.md)。
**关闭条目**：把**技术行连同结论压成一行** `- [x]` 剪到 [`BACKLOG-CLOSED.md`](BACKLOG-CLOSED.md) 末尾（那份是平铺存档，不分档），本文删掉这三行。

## P0 · 真缺陷（8）

2026-09-23 全仓只读审查（v1.4.4 之后的 `main`，Rust 核心 / 文件与终端 / Dart 状态层 / 投影与转录四路）登记了其中 7 条，代码路径都逐条核过，均未在 Windows 实机复现；「dsh 的会话存到哪里跟着进程工作目录走」来自所有者同日报障，根因由读代码推出，待实机确认。

### 请求与会话路由（3）

- [ ] **两个 agent 同时在线时，权限卡 / 表单卡会串到另一个 agent 上**
  - **产品**：两个 agent 各有一条会话挂着权限或表单请求时，在一边点「允许」，可能把另一边的卡标成已回应、而真正该收到回应的 agent 一直在等；或者这边的卡成了点了没反应的死按钮。界面上没有任何提示，只有按停止键能解开。
  - **技术**：`requestId` 是每条连接自己的 JSON-RPC id（`rust/acp-core/src/agent.rs` `enqueue` 里的 `responder.id().to_string()`，从小整数起步，fixtures 里就是 9 / 31）。核心侧 `pending` 按连接各一张、`acp_respond(agentId, requestId)` 寻址是对的；但前端 `PendingQueue` 跨 agent 只有一张表（`Sessions.pending`），只按裸 `requestId` 当键（`lib/projection/pending.dart` 的 `_byRequestId`，`_add` 撞号直接覆盖），`answerPermission` / `answerElicitation` / `cancelRequest` / `withdraw` / `byRequestId` 都会命中别的 agent 的条目；`TurnController.answerPermission` 查不到时静默 return（`lib/app/turn_controller.dart`）。两条连接刚连上时 id 都小，撞号机会不低。最小修法：核心 `enqueue` 与 `$/cancel_request` 归一化处把队列键改成 `agentId:requestId`，前端零改动；或前端改 `(agentId, requestId)` 复合键，查不到时落一句 `lastError` 而不是静默。三路审查各自独立报出 (2026-09-23)

- [ ] **会话并跑时，对正在跑的会话点 Restore，停止键会消失、这一轮停不下来**
  - **产品**：A 在跑长任务，切到 B 发一条短的跑完，再回 A 在气泡上点 Restore / Regenerate：会话头 spinner 停了、停止键换回发送键，agent 其实还在输出；这一轮再也取消不了，失败原因也不显示，还能再叠发一条。
  - **技术**：`TurnController._turnInFlight` 是全局单槽（`lib/app/turn_controller.dart` `_runTurn` 里 `_turnInFlight = turn`），谁后发谁占；`restore()` 靠 `await _turnInFlight` 等「当前会话那一轮」收干净，可 2026-09-18 起会话能并跑，这个槽可能是别的会话那一轮（Restore 被别人的长任务挂住），也可能已被清成 null（立即返回，旧的 `session/prompt` 还没回）。旧那轮带 `cancelled` 回来时，`SessionStore.endTurn` 只认 `currentTurn`、不校验是不是自己开的，打在 Restore 新开的轮上并清空 `currentTurn`；新轮真返回时 stopReason / error 都落不下。最小修法：`_turnInFlight` 改成按 sessionId 的 Map，`restore()` 只等本会话那一轮；`endTurn` 带上发起时的那一轮做比对，只收自己开的那一轮 (2026-09-23)

- [ ] **删掉一条正在跑的会话（agent 没声明 delete 时），agent 那边没人收尾**
  - **产品**：用 dsh 这类不支持删除的 agent，会话正在跑或挂着权限卡时在侧栏删掉它：界面上干净了，agent 那一轮却没被取消，继续跑到底（继续改工作区文件、继续耗 token）；挂着的权限 / 表单请求永远没人回，agent 卡在那里。
  - **技术**：`SessionController.deleteSession`（`lib/app/session_controller.dart`）把收尾整段圈在 `if (onAgent)` 里：`deletesOnAgent` 为假（agent 没连，或没声明 `sessionCapabilities.delete`，dsh-acp-interactive 1.3.0 实测就是）时既不 `_releaseSessionRequests`、也不发 `session/cancel`，核心的 `cancel_pending_permissions` 一次都不会跑；随后 `sessions.forget(id)` → `PendingQueue.forgetSession` 把挂起项从本地抹掉、不发任何回应。与 `BACKLOG-CLOSED.md`「删会话时 agent 侧可能留着」不是一回事：那条裁定的是会话记录在 agent 侧残留，这条是在途的那一轮与 client 请求没收尾。最小修法：owner 连着时不论 `onAgent`，先对在跑的会话发 `session/cancel`、再 `_releaseSessionRequests`，与 `closeSession` 同一口径 (2026-09-23)

### 数据一致性（2）

- [ ] **本地状态文件的读改写没有串行化：会话条目会丢、删掉的会话会复活、刚装好的 agent 配置会被抹掉**
  - **产品**：两条会话前后脚写索引（后台会话收轮 + 前台发消息）时，其中一条可能从侧栏永久消失，重启也回不来；删会话的同时别的会话在写，删掉的那条又冒出来。安装 agent 期间去改字体，装好的 agent 可能显示「已安装」却连不上、也装不了，只能移除重装。
  - **技术**：`rust/settings/src/index.rs` 的 `upsert_session` / `remove_session` / `open_project`、`rust/settings/src/lib.rs` 的 `upsert` / `set_appearance` / `set_transcript` / `remove`、`rust/settings/src/ui_state.rs` 的 `merge` 都是「整份 load → 改一条 → 整份 save」、无锁，而桥的每条命令都在多线程 runtime 上各起一个任务（`rust/bridge/src/api.rs` `on_core`），两笔重叠时后落地的用旧快照整份盖掉先落地的。前端 `SessionIndex` 的 `_inFlight` / `_removing` 只按 (agentId, sessionId) 挡同一条会话，跨会话不挡，而 `stampPromptSent` 是不 await 的。`settings.json` 这一半，`BACKLOG-CLOSED.md`「settings.json 的各段写入没有串行化」已裁定不修，理由是「现有交互做不到同时改外观和拨转录开关」；但写入方还有后台安装 / 升级任务（`rust/acp-core/src/registry_ops.rs` 的 `write_registry_settings`，`run_install` 与 `commit_upgrade` 里调），那条理由覆盖不到，**请所有者按这条新证据复议**。最小修法：照 `rust/registry/src/manifest.rs` 现成的 `static WRITES: Mutex<()>`，给 `IndexStore` / `SettingsStore` / `UiStateStore` 各加一把，load 到 save 整段罩住 (2026-09-23)

- [ ] **dsh 的会话存到哪里跟着进程工作目录走：换过项目后重载，原会话报「不存在」并被新建会话顶掉**
  - **产品**：先在项目 A 用 dsh，再切到项目 B 新建会话聊完，点会话头的「重载」：弹出 `session restore failed: session "…" not found`，随即新开一条空会话，原会话再也载不回来。不止重载：重启应用后先打开哪个项目，决定了哪些旧会话能载回来，表现为时好时坏；每个项目根目录还会多出一个 `.sessions` 文件夹（容易被误提交进 git）。
  - **技术**：dsh 的会话日志落在 `root/<projectKey(会话 cwd)>/<sessionId>/`，`root` 缺省是**相对路径** `./.sessions`（dsh 包 `config/cordis.yml`：`DSH_ACP_SESSIONS_ROOT ?? './.sessions'`），实际位置由 **agent 进程的工作目录**决定。客户端只在第一次连接时拿当时的项目目录当进程 cwd（`rust/acp-core/src/command.rs` `build_command` 的注释「dsh 把会话存在 cwd 下」），之后换项目新建会话，`ensureConnected` 见已连着就复用同一个进程（`lib/app/session_controller.dart`），会话于是存进 A 的 `.sessions`；`reloadAgent` 却用**当前项目** `workspace.project.path` 重拉（`_connectOnce(b, id, cwd)`），新进程去 B 的 `.sessions` 找 → `readSession` 报 not found → 按「载失败就开新会话」的既定回退新开一条。所有者 2026-09-23 报障（media-studio 项目，Gemini 3.8 Flash via CLIProxy）。最小修法：内置 dsh 条目（`rust/acp-core/src/builtin.rs` `dsh_entry`，现在 `env` 为空）固定传 `DSH_ACP_SESSIONS_ROOT = <数据目录>/dsh-sessions` 的绝对路径，与 sidecar 的 `--user-data-dir <数据目录>/zed-agent` 同一做法；已散落在各项目 `.sessions` 里的旧会话要一次性搬过去（或首启时迁移）。待实机确认的前提：出事那次 dsh 进程最早是在别的项目里拉起的，可在那个项目下找 `.sessions\--…media-studio--\<sessionId>` 验证 (2026-09-23)

### 资源与静默失败（3）

- [ ] **终端输出超过 64 K 字符后，终端卡的画面就冻住了**
  - **产品**：`cargo build`、`npm install`、跑测试这类输出多的命令，终端卡停在写满 64 K 那一刻，之后的输出全都不显示——编译报错、测试失败这些最要紧的尾巴恰好看不到。只有卡片被重建（比如滚出列表缓存再滚回来）才会刷新。
  - **技术**：`TerminalBuffer`（`lib/projection/tool_calls.dart`，`defaultLimit = 65536`，`ensure` 从不传别的上限）写满后只留最后 64 K，长度恒定在 65536；`TerminalCard._sync`（`lib/ui/transcript/terminal_card.dart`）只按「长度变长就写增量、变短就整体重写」判断，长度不变两支都不进，xterm 视图从此不再更新（偶发的 65535 → 65536 那一帧还只写进 1 个字符，画面与真实输出对不上）。现有用例只在缓冲层验了 `truncated`，没覆盖卡片。最小修法：`TerminalBuffer` 加一个只增不减的累计写入量（或 revision），`_sync` 按它算增量、按「这次丢掉了多少前缀」决定整体重写 (2026-09-23)

- [ ] **agent 读大文件时整份读进内存**
  - **产品**：工作区里有很大的文件（几个 GB 的日志 / 数据导出），agent 去读它时应用内存暴涨，极端时整个应用直接闪退、没有任何提示。
  - **技术**：`rust/fs/src/lib.rs` 的 `read_text_file`（agent 的 `fs/read_text_file`）先 `std::fs::read` 整份读入、再 `from_utf8_lossy`、再按 `line` / `limit` 切行，`line` / `limit` 压不住峰值；查看器那条路径有 `READ_FILE_LIMIT = 2 MiB` 的 `take` 上限，这条没有。分配失败时 Rust 直接 abort，Flutter 宿主进程一起没。最小修法：给这条路径加同量级的上限（超限回 invalid params），或按 `line` / `limit` 流式读 (2026-09-23)

- [ ] **agent 开终端不释放时，最终会把整个客户端拖死**
  - **产品**：某个 agent 反复开跑不完的终端（`npm run dev`、`ping -t`）又不释放、还对每个都等退出，次数多了以后文件树、git 徽章、所有 agent 的读写文件回调、连「杀终端」本身都会排队不动，只能重启应用。正常 agent 撞不上，写得糙的 agent 能撞上。
  - **技术**：`terminal/create` 没有数量上限（`rust/acp-core/src/agent.rs` `on_create_terminal`）；`terminal/wait_for_exit` 走 `spawn_blocking` + `ExitCell::wait` 条件变量死等、无超时（`agent.rs` `on_wait_for_terminal_exit`、`rust/pty/src/lib.rs`），每个都钉住一条阻塞池线程。这个池子（tokio 默认 512，`core.rs` 未设 `max_blocking_threads`）与文件面板、git、agent 的 fs 回调、`terminal/kill` 共用；终端只在 agent release 或连接结束时回收。最小修法：每条连接的 `owned_terminals` 设上限、超限回错；等退出改成带超时的等待或在连接关闭时唤醒，不长期占阻塞池线程 (2026-09-23)

## P1 · 看得见的粗糙（3）

### 壳与交互（1）

- [ ] **会话菜单的 Resume / Close 没有入口**（暂不处理）
  - **产品**：两个动作已经接通也有单测，但产品界面上点不到（Delete 有入口）。实际缺的只有 Close：侧栏点开一条会话时已经自动 load（agent 不支持 load 时退回 resume），Resume 的用途被覆盖了；Close 是让 agent 放掉这条会话占的资源而不删它，现在打开过的会话在 agent 侧一直占着，直到 agent 断开。
  - **技术**：R6 会话头 ≡ 的语义在画板 03（右栏展开的选中态）与画板 41（会话菜单）之间冲突。所有者裁定 2026-09-16：**≡ 保持右栏开关，会话菜单要入口先改设计稿**。R6 已把菜单的动作接通并做了单测（`resumeSession` / `closeSession` / `deleteSession` + 能力裁剪），产品 UI 里 **Delete 有入口（侧栏删除图标，画板 04）、Resume / Close 没有**。下个设计轮给会话菜单定一个入口（改画板 41 / 03），再接上 `SessionMenuPopover` (2026-09-16) → **所有者裁定 2026-09-23：暂不处理**。当天查过 Zed 的做法：它也**没有**手动 Resume / Close 入口，而是在切走会话时后台自动 close，只保活最近 5 条空闲且 agent 支持 `loadSession` 的会话，切回被回收的会话走 `session/load`。机制全文、源码行号和与我们的对照记在 [`docs/research.md`](../docs/research.md) § 4.1，以后做自动 close 从那里开工。当时评估的方案是 `selectSession` 切走时回收、保活上限 5，还差一个裁定点：切回时 resume 优先（内存里的转录还在、不重放），还是照 Zed 一律 load。本次不做 (2026-09-23)

### 流式渲染性能（2）

- [ ] **转录里有大 diff 时，流式输出越来越卡**
  - **产品**：agent 改了一个大文件（上千行的 diff），这张 diff 卡在视口里时，agent 后面每吐一段字界面都会顿一下，严重时看起来像卡死；展开 diff 那一下也很慢。
  - **技术**：`DiffCard.build`（`lib/ui/transcript/diff_card.dart`）每次都现算 `lineDiff`、不缓存，折叠态也要算 +N / −N；转录列表监听 store，每帧重建时视口内的 diff 卡整份重算。`lineDiff` 里的 `indexOfLive` 每条更新都整表线性扫一遍、再 `List.insert`，大 diff 下是平方级；展开体是非惰性 `Column`。最小修法：diff 结果连同 +N / −N 缓存进 State，只在 `oldText` / `newText` 变了才重算；`indexOfLive` 换成随遍历维护的游标；展开体改惰性列表。全仓审查 (2026-09-23)

- [ ] **长回答 / 大代码块流式输出时，每帧整段重新解析和高亮**
  - **产品**：agent 输出很长的回答，或回答里有几百行的代码块时，越往后越掉帧。
  - **技术**：`AssistantText`（`lib/ui/transcript/assistant_text.dart`）把整条消息的 text 块拼成一段交给 `MarkdownBody`，`data` 一变 `_rebuild()` 就整段 `MarkdownBody.parse`、重建全部块 widget 实例（`lib/ui/transcript/markdown_body.dart`）；`CodeBlock.build` 又把整段代码 `highlightCode` 一遍、不缓存（`lib/ui/transcript/code_block.dart`）。批处理器把通知压到一帧一次，所以单帧代价随消息长度线性增长。最小修法：只重新解析最后一个块边界之后的尾部、已完成的块 widget 复用；`CodeBlock` 按 code / language / 字体代数缓存高亮结果。全仓审查 (2026-09-23)

## P2 · 功能缺口（0）

眼下没有未关闭条目：「主题没有跟随系统」iteration-07 做掉（结论见 [`BACKLOG-CLOSED.md`](BACKLOG-CLOSED.md) 末尾）。以后该有没有的能力照常追在这里。

## P3 · 设计稿欠账 —— 已整体释放

所有者裁定 2026-09-20：**不要求补设计稿**。原先这一档的 23 条连同结论搬到
[`design/DIVERGENCE.md`](../design/DIVERGENCE.md)，按「实现已超越画板 / 画板画错 / 实现有意少做」
分三节记着，那几处以实现为准、PNG 不再是它们的验收基准。档位留空占位，不重排编号。

## P4 · 平台与分发 —— 已清空

所有者裁定 2026-09-23，这一档的 7 条都已移出，档位留空占位，不重排编号：「跨平台」2 条关闭（目前没有 mac 设备，
macOS / Linux 暂不做）；「构建链」里中文路径兜底与 Rust 版本漂移 2 条关闭；sidecar 体积 1 条关闭（R8 已给出两个数字）；
sidecar 的另 2 条（languages crate、`0-dev` 目录名）移到 [`BACKLOG-ZED.md`](BACKLOG-ZED.md)。以后平台与分发的新问题照常追在这里。

## P5 · 内部工程与验收 —— 已清空

所有者裁定 2026-09-23，这一档的 16 条整档收掉，档位留空占位，不重排编号：7 条在 iteration-04 改完代码关闭，8 条按裁定不做 / 不修 / 视为已覆盖，「headless 报告的 lastError」并入 P0「失败没有出口」那条；各条结论见 [`BACKLOG-CLOSED.md`](BACKLOG-CLOSED.md) 末尾。以后内部工程与验收的新问题照常追在这里。

## X · 卡在上游 / 协议 —— 已撤档

所有者裁定 2026-09-23：**不是本项目的问题不进 BACKLOG**。原先这一档的 6 条连同结论压成一行剪到
[`BACKLOG-CLOSED.md`](BACKLOG-CLOSED.md) 末尾；其中「终端当前搜索命中」同时是画板 07 § 2.9 的偏离，
另记 [`design/DIVERGENCE.md`](../design/DIVERGENCE.md) C-28。档位留空占位，不重排编号。
