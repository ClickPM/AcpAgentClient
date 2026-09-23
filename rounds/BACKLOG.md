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
| **P0 真缺陷** | 5 | 会丢内容、作用到错对象、吃光资源、静默失败。撞上就是事故，排进最近的轮次。 |
| **P1 看得见的粗糙** | 1 | 用户看得见的不一致、缺等待态、行为不符直觉。能用，膈应；攒批做。 |
| **P2 功能缺口** | 0 | 该有没有的能力。**全部需所有者裁定才能进轮次**，多数还要先改设计稿。 |
| P3 设计稿欠账 | — | **已整体释放**到 `design/DIVERGENCE.md`，见下面的占位小节 |
| P4 平台与分发 | — | **已清空**（2026-09-23）：跨平台暂不做、构建链两条关闭、sidecar 两条移到 `BACKLOG-ZED.md`，见下面的占位小节；以后平台与分发的新问题照常记这一档 |
| P5 内部工程与验收 | — | **已清空**（2026-09-23）：16 条整档收掉（iteration-04），见下面的占位小节；以后测试、行数门、验收自动化这类用户无感的新问题照常记这一档 |
| X 卡在上游 / 协议 | — | **已撤档**：不是本项目的问题不进本表（所有者裁定 2026-09-23），见下面的占位小节 |
| | **6** | |

**新增条目**：挑一档追在该档末尾，照同样的三行格式写。不新开档位；一条只进一档。
**只收本项目自己的问题**：问题出在上游（agent、zed、xterm 等依赖）或协议本身的，不进本表（所有者裁定 2026-09-23，X 档因此撤掉）；其中实现因此与画板对不上的，照规则 3 记 [`design/DIVERGENCE.md`](../design/DIVERGENCE.md)。
**agent 的私有协议扩展目前不接**（所有者裁定 2026-09-23）：某个 agent 自定的 `_meta` 键或私有流程（如 codex-acp 的 `api-key` / `gateway` 认证）不是 ACP 标准，接它就是按 agent 特判（规则 2），这类诉求不进本表。
**内置 Zed agent（sidecar）的问题不进本表**：记 [`BACKLOG-ZED.md`](BACKLOG-ZED.md)（所有者裁定 2026-09-23：原先本表的 4 条连同统筹时新盘点出的 5 条都移到那里，**当前不修**）；背景与上游限制见 [`docs/zed-agent.md`](../docs/zed-agent.md)。
**关闭条目**：把**技术行连同结论压成一行** `- [x]` 剪到 [`BACKLOG-CLOSED.md`](BACKLOG-CLOSED.md) 末尾（那份是平铺存档，不分档），本文删掉这三行。

## P0 · 真缺陷（5）

### 会话身份与生命周期（4）

- [ ] **发消息可能把选中的会话静默顶掉**
  - **产品**：点开一条旧会话直接发消息，有时会新开一条把它顶掉，侧栏高亮跟着跳走，用户不知道发生了什么。
  - **技术**：`lib/app/workbench_controller.dart` `send()` 的懒开会话守卫：`store` 是 `sessionId == null ? null : sessions.maybe(sessionId!)`，所以选中的会话只是**载不回**转录（agent 不支持 `loadSession` / `_ensureConnected` 抛错被 `_guard` 吞掉 / 拿不到 cwd）时 `store` 也是 null，发送会开一条新会话把选中的那条静默顶掉、侧栏高亮跟着跳走。发布前审查 P2。**两轮针对性整改都被复审报回**：改判 `sessionId == null` 让「agent 不支持 loadSession」那类旧会话按发送零响应（那恰是 R3 既定语义要开新会话）；补成 `store == null && (sessionId == null || !canLoadSessionOf(id))` 又把 `newSession` 已写好的认证 / 缺 Node / 没选目录报错覆盖成一句不相干的话，且「本次还没连上、能力未知」时仍会顶掉。所有者裁定 2026-09-18 回退到出厂行为、单独一轮做。做的时候要一次把四种状态分清：无 sessionId / 有 store / 已 initialized 且不支持 loadSession / 载回失败或能力未知，且别覆盖 `newSession` 的 `lastError` (2026-09-18) → **R7.5 拆分后的新家**：`turn.send` ↔ `session` 的边（给 `session` 加四态查询） (2026-09-20)

- [ ] **重载或崩溃之后，别的会话发不出去**
  - **产品**：重载过 agent 再切到另一条会话发消息，撞 unknown session，只能重开应用。
  - **技术**：agent 进程换过一轮之后（崩溃、或会话头的「重载 agent」），**内存里其它会话**拿的还是旧进程的 sessionId：`_ensureLoaded` 只在「内存里没有转录」时才 `session/load`，切过去直接发消息会撞 agent 的 `-32602 unknown session`。2026-09-18 所有者报障（dsh-acp-interactive）的那条路径里，「新建会话顺手重连」这一半已经修掉（`newSession` 改走 `_ensureConnected`），重载 / 崩溃这一半还在——只是现在要用户主动重载或进程真的死掉才会撞上。要修得给每条连接记一个代次，把代次之前载进来的会话标成待重载（`selectSession` 时自动 `session/load` 回来），属机制类改动，等单独一轮 (2026-09-18) → **R7.5 拆分后的新家**：`SessionController`（代次记在 `_sessionAgent` 旁） (2026-09-20)

- [ ] **认证完成后建出来的会话挂到旧目录**
  - **产品**：认证期间换了项目，认证成功后建出来的会话在当前项目的侧栏里找不到。
  - **技术**：认证页成功后的自动重试 `_createSession(agent, retryCwd)` 用的是发起时的 cwd：认证期间换了项目，回来的会话挂在旧目录、侧栏（当前 workspace）里找不到。`openProject` 的等待期守卫（合并复审 2026-09-18）管不到认证页这条路（认证期间 `waitingForAgent` 不为真）。要修得让 `_createSession` 按当前 `project` 判一次「还该不该挂成当前会话」，属机制类，等单独一轮 (2026-09-18) → **R7.5 拆分后的新家**：`AuthState.onAuthenticated` → `SessionController.createSession`（按当前 `workspace.project` 判一次） (2026-09-20)

- [ ] **载会话中途失败会留半份转录**
  - **产品**：载到一半断了，屏幕上留着残缺的历史，看起来像对话本身就长这样。
  - **技术**：R6 `session/load` 在「原先内存里就有转录 + 重放到一半断了」时会留下半份转录（清空已经生效、重放没跑完）。一条都没重放的失败已经不清空了；这一半的情况要完全无损得给 `resetForReplay` 加快照与回滚，本轮按最小改动没做 (2026-09-16)

### 资源与静默失败（1）

- [ ] **安装或升级进行中关掉应用，npm 与握手用的 agent 进程没人收**
  - **产品**：Agents 面板里正在装 / 升级一个 agent 时关掉应用，`npm install` 在后台自己跑完才退；恰好卡在最后「握手」那几秒的话，拉起来验版本的那个 agent 进程可能留下来。
  - **技术**：`core_shutdown` 管的是连接表与在途的 `agent_connect`（iteration-03 第 7 项），`registry_install` / `registry_update` 的后台任务（`installs` 表里的 `CancelToken`）与 `node_download` 不在它的收尾范围：npm 子进程随应用退出没人杀（有界，装完自己退），握手那条临时连接靠 `registry_ops.rs` 的 `tokio::select!` 丢 future → `exit_watcher` 异步 `kill_tree`，收尾时令牌没人取消、也没人等。要修得在收尾时取消这些令牌，并等安装任务从 `installs` 表里摘掉（中途含回滚删目录，那步最多 5 s），和 Dart 侧 `shutdown()` 的 8 s 总等待一起算 (2026-09-23)

## P1 · 看得见的粗糙（1）

### 壳与交互（1）

- [ ] **会话菜单的 Resume / Close 没有入口**（暂不处理）
  - **产品**：两个动作已经接通也有单测，但产品界面上点不到（Delete 有入口）。实际缺的只有 Close：侧栏点开一条会话时已经自动 load（agent 不支持 load 时退回 resume），Resume 的用途被覆盖了；Close 是让 agent 放掉这条会话占的资源而不删它，现在打开过的会话在 agent 侧一直占着，直到 agent 断开。
  - **技术**：R6 会话头 ≡ 的语义在画板 03（右栏展开的选中态）与画板 41（会话菜单）之间冲突。所有者裁定 2026-09-16：**≡ 保持右栏开关，会话菜单要入口先改设计稿**。R6 已把菜单的动作接通并做了单测（`resumeSession` / `closeSession` / `deleteSession` + 能力裁剪），产品 UI 里 **Delete 有入口（侧栏删除图标，画板 04）、Resume / Close 没有**。下个设计轮给会话菜单定一个入口（改画板 41 / 03），再接上 `SessionMenuPopover` (2026-09-16) → **所有者裁定 2026-09-23：暂不处理**。当天查过 Zed 的做法：它也**没有**手动 Resume / Close 入口，而是在切走会话时后台自动 close，只保活最近 5 条空闲且 agent 支持 `loadSession` 的会话，切回被回收的会话走 `session/load`。机制全文、源码行号和与我们的对照记在 [`docs/research.md`](../docs/research.md) § 4.1，以后做自动 close 从那里开工。当时评估的方案是 `selectSession` 切走时回收、保活上限 5，还差一个裁定点：切回时 resume 优先（内存里的转录还在、不重放），还是照 Zed 一律 load。本次不做 (2026-09-23)

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
