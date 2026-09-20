# Round 7.5 — 组合根拆分（`lib/app/workbench_controller.dart`）

<!-- 保存为 rounds/round-7.5/round-7.5.md；该轮其他管理产出放同一目录。编号沿用 R1.5 的写法：夹在 R7 与 R8 之间的纯代码结构轮，无画板。 -->

> 状态：**代码与文档完成，等所有者三件事**——验收 8 的 Windows 真跑、验收 9 的手测、合并时机（main 在本轮开工后又进了「Thread → Session 收敛」，见「本轮实测」末段；按所有者 2026-09-20 指示不合并、由所有者定）。裁定门六项按推荐项执行，待确认（2026-09-20 起；裁定门六项全部按推荐项执行：编号 R7.5、组合根 + 8 个对象、直接访问子对象不留转发门面、阶段 A 必做 + 阶段 B 先量后动、不修 BACKLOG 缺陷、validate 加行数门与依赖方向门）。2026-09-18 起草；2026-09-20 按 main 新合并的 16 个提交复核、基线改到 `5a001bf`（实际开工基线 `f62520f` = main = `round-7.5`，只多一个 v1.1.0 版本号提交），见 §「2026-09-20 复核」。本轮在独立 worktree 的分支 `claude/r7-5-composition-root-refactor-7600bf` 上逐步提交（`round-7.5` 在主工作副本已检出、无法在 worktree 再检出），收口时 `round-7.5` 一次 fast-forward 即可。

## 目标

把 `lib/app/workbench_controller.dart`（基线 `5a001bf`：2645 行、1 个 `ChangeNotifier`、103 个公有方法、19 个职责段）拆成
**一个组合根 + 8 个各管一段的对象**，**行为零变化**：`lib/ui` / `lib/theme` / `lib/projection` / `lib/bridge` / `rust` 零 diff，
现有 Dart 单测只改引用路径不改断言与用例数，三份无头实跑报告（`ACP_R3_REPORT` / `ACP_R5_REPORT` / `ACP_R6_REPORT`）
逐步骤等价。拆完后组合根 ≤ 450 行、`lib/app` 下任何文件 ≤ 900 行，子对象之间只允许附录 B 的单向依赖，
没有任何子对象 import 组合根。

本轮**不修** BACKLOG 里的任何缺陷（§「与 BACKLOG 的关系」列了 17 条），缺陷在拆完的结构上另起一轮修：
只有零行为变化的 diff，审查才能验「等价」；把修缺陷混进来，等价性就没法审了。

## 背景（为什么现在拆）

- **增长曲线**：R3 接线 901 行 → R5 1528 → R6 2110 → R7 之后两天的 main 直改 2642（35 个提交 +530 行）。
  R3 任务卡当时的判断「索引、项目、规则计数各十来行，拆成五个文件只会让调用面更碎」在 901 行时成立，之后三轮加 main 直改
  又塞进 1700 行，没有人回头重评。
- **缺陷聚集**：BACKLOG 84 条未关闭项（2026-09-20 重数，起草时 80）里 17 条落在或紧邻这个文件，其中 8 条逻辑缺陷**全部**出在「会话 / 一轮对话 / 索引与项目」
  这约 1050 行共享 `agentId` / `sessionId` / `store` 的段落；`send()` 懒开会话守卫两轮针对性整改都被复审报回，
  所有者已裁定「回退到出厂行为、单独一轮做」。四种状态分不清，根子是状态散在一个类的几十个字段里没有边界。
- **耦合矩阵**（按 19 段统计对 `sessions.` / `store` / `agentId` / `sessionId` 的引用）两极分化：约 1250 行互相咬合
  （会话、索引与项目、一轮对话、会话配置、侧栏活动、派生），约 700 行几乎零引用、只是合租（`@` 与 `/`、`+` 四项、右栏、
  本地终端、设置面板、registry、壳 UI 动作）。后者与 R4 已拆出的 `FilesState` / `LocalTerminals`、R5 的 `RegistryState`
  是同一形态，作者知道怎么拆，只是没有轮次要求拆。
- **通知形态**：`sessions` / `files` / `terminals` 的 listener 全部转发到根的 `notifyListeners`，`workbench_screen.dart`
  用一个 `ListenableBuilder(listenable: c)` 包整个 `AppShell`，任一 `_touch()`（83 处）都重建整个壳；
  `docs/design.md` § 9 写的「widget 用 ListenableBuilder 选择性订阅」只在转录 store 那一层做到了。
- **为什么当初是这样**（有据可查，不是失误）：规则 1 禁状态管理库、只许 `ChangeNotifier`，一个控制器经构造函数传给 screen
  是机制最少的做法；规则 3 要求 widget 不知道桥的存在，天然要有「唯一知道桥的人」；规则 2 把协议状态放进 projection，
  控制器被当成胶水、胶水不被当成需要设计的对象；流程上「非阻断 findings 严禁新增机制类修复」+「跨轮次问题记 BACKLOG 不当场改」
  +「接线轮 tokens / ui 零 diff」把结构性重构锁死在轮次之外。所以这件事只能以一轮的形式做，不能以 findings 整改的形式做。
- 2026-09-18 cursor 的代码质量分析把「前端组合根」判为唯一的「弱」项（「事实上的上帝对象」）。主会话核对后的结论：
  成立一半。它不持有协议 / 领域状态（都在 `lib/projection/`），持有的是本地态 + UI 态 + 对桥的编排；更准确的说法是
  「膨胀的编排层 + 合租的 UI 子状态」。性质是设计债不是缺陷，按 CLAUDE.md「审查边界」走轮次。

## 前置

- R7、画板 43（会话时间线）与 R7.6（字体切换）已合入 main（`5a001bf`，2026-09-20；本地 main 领先 origin 14 个提交、尚未推送）；
  `scripts/validate.ps1` 在 main 上全绿是起点（画板 43 合并时 13 项全绿、`flutter test` 294 项）。R7.6 验收 10（随包字体真机渲染）
  待所有者提供字体文件，与本轮无关。
- 分支 `round-7.5` 已于 2026-09-20 从 `5a001bf` 拉出（主工作副本）；开工前 `scripts/fetch-upstream.ps1 -Check` 全绿。
  届时若主工作副本被别的会话占着（R7.6 就是因此去了独立 worktree `AcpAgentClient-fonts`），把分支挪到独立 worktree 做，
  `vendor/upstream` 用目录联接指向主副本。
- 本机 agent：fake-agent（离线夹具，三份无头报告的等价性比对全靠它）、dsh-acp-interactive 与 claude-agent-acp（收口前各一次 Windows 真跑，规则 9）。
- 与所有者约定：本轮期间 main 上的手测修复**尽量不碰** `workbench_controller.dart`；非碰不可的，本分支先合 main 再继续
  （并行合并的做法见 `rounds/round-04/round-04.md` 的 18 文件冲突记录）。拆分是纯移动，与 main 上的行为修复冲突一次就要手工重放一次，
  所以本轮要短、要一口气做完。

## 现状快照（基线，验收时对照）

| 项 | 数值 |
|---|---|
| 行数 / 类 | 2645 / 1（另一个 `ChunkedUtf8` 是 20 行的解码工具；`58f19f2` 时 2642，画板 43 加了 `timelineAnchor` 3 行） |
| 方法 | 103 公有 / 48 私有 |
| 段（`// ----` 分隔） | 19 |
| 通知出口 | `notifyListeners()` 11 处、`_touch()` 83 处、`_guard()` 36 处，全部落到同一个 notifier |
| 输入控件 / 焦点 / 弹层锚点 | 8 个 `TextEditingController`、9 个 `FocusNode`、9 个 `PopoverHandle`（画板 43 加了 `timelineAnchor`）+ 一个 `_configAnchors` map |
| 引用面（去重成员数） | `workbench_screen.dart` 180、`headless_run.dart` 85、`test/` 105（2026-09-20 重算；起草时 179 / 85 / 97） |
| 驱动它的测试 | `test/` 里 12 个文件 import 它、11 个直接构造（`test/app/` 6 文件含新增的 `timeline_wiring_test`，`test/ui/` 6 文件）；`test/app` + `test/ui` 共 186 例，`flutter test` 全量 294 项；全部经 fake `CoreCommands` 构造 |

19 段的行号、咬合度与去向（咬合度 = 该段对 `sessions.` / `store` / `agentId` / `sessionId` 的引用数之和；行号按 `58f19f2` 记，
`5a001bf` 只在第 229 行附近插了 `timelineAnchor` 的 3 行，「派生」及其后各段整体 +3）：

| 段 | 行 | 行数 | 咬合度 | 去向 |
|---|---|---|---|---|
| 投影 / 本地态 / UI 态字段 | 61–241 | 181 | 5 | 按字段各归其主（附录 A） |
| 派生 getter | 242–287 | 46 | 11 | `session`（`store` / `connection` / `hasSession` / `threadTitle` / `canCompose` …） |
| 画板 06 侧栏活动 | 288–388 | 101 | 9 | `session`（running / unread / `_markDone`）；`composerOptions` / `optionOf` / `optionById` 归 `turn` |
| 生命周期 `start` / `_restoreUiState` | 389–454 | 66 | 6 | 组合根（编排顺序不变）；`_restoreUiState` 归 `shell` |
| 分栏宽度 + fixtures 启动 + 调度 + dispose + `_guard` | 455–636 | 182 | 10 | 宽度归 `shell`；`_startFixtures` / `_enqueue` / dispose 留组合根；`_guard` / `_touch` 抽成 mixin |
| 索引与项目 | 637–942 | 306 | 27 | 项目 / 分支 / 规则归 `workspace`；索引归 `index`；agents 列表归 `agents`；能力 getter 归 `session` |
| 会话 | 943–1501 | 559 | 73 | `session`（整段） |
| 一轮对话 | 1502–1692 | 191 | 20 | `turn`（整段） |
| 会话配置 | 1693–1733 | 41 | 6 | `turn` |
| 输入框的 `@` 与 `/` | 1734–1876 | 143 | 2 | `composer` |
| `+` 的四项 | 1877–1957 | 81 | 1 | `composer`（`transcriptText` 归 `turn`） |
| 壳的 UI 动作 | 1958–1975 | 18 | 0 | `shell`（`toggleSidebar`）；`search` 三件归 `session` |
| 右栏 | 1976–2069 | 94 | 0 | `shell` |
| 本地终端 | 2070–2139 | 70 | 2 | 标签开关归 `shell`；`killTerminal` 归 `turn`；`_onTerminalOutput` 分发留组合根 |
| 定位与 Follow | 2140–2174 | 35 | 1 | `shell` |
| 退出收尾 + 页面切换 + `authenticate` | 2175–2207 | 33 | 2 | `shutdown` 留组合根；`openTraffic` / `openWorkbench` 归 `shell`；`authenticate` 归 `auth` |
| registry 面板 | 2208–2311 | 104 | 4 | `agents` |
| 认证页 | 2312–2517 | 206 | 12 | `auth` |
| 设置面板 | 2518–2622 | 105 | 0 | `agents` |

## 交付物

全部在 `lib/app/`，新文件 9 个、改 3 个（`workbench_controller.dart` / `workbench_screen.dart` / `headless_run.dart`）、
`app.dart` 不改。命名沿用现有两种后缀：面板 / 壳类的叫 `*State`（同 `FilesState`），驱动协议的叫 `*Controller`。

| 文件 | 类 | 管什么 | 预估行数 | 依赖（构造时注入） |
|---|---|---|---|---|
| `guarded.dart` | `mixin GuardedNotifier on ChangeNotifier` | `lastError` 字段 + `guard()`（桥命令的统一错误边界）+ `touch()`（dispose 后不通知）+ `disposed` 标记。现在的 `_guard` / `_touch` 原样搬过来，一份代码九个对象共用。`FilesState` / `LocalTerminals` / R7.6 的 `FontPrefsController` 各自还有一份同样的 `_disposed` 挡板与错误边界，本轮不收编（在「禁止」的不动范围里），收口时记 BACKLOG 待下一轮统一 | 40 | — |
| `shell_state.dart` | `ShellState` | 三栏宽度与收起态、`ui-state.json` 读写、`page`（工作台 / 流量）、右栏标签条（`openTabs` / `rightTab` / `panelTabs` / `activePanel` / `rightPanelOpen` / `activeNavTab` 与 open / toggle / close / select）、本地终端标签的开关 / 停止 / 清屏 / 重启、Follow（`follow` / `toggleFollow` / `goToFile` / `followLocations`）、`trafficFilter` 输入控件 | 330 | `bridge`、`files`、`terminals` |
| `workspace_state.dart` | `WorkspaceState` | `project` / `recentProjects` / `branch` / `branches` / `branchAreaVisible` / `rulesCount`、`openProject` / `refreshBranches` / `switchBranch` / `createBranch` / `refreshRules` / `restoreLastProject`、`normalizeCwd` / `inCurrentWorkspace`、`projectSearch` / `branchInput` 两组输入控件与 `projectAnchor` / `branchAnchor` | 250 | `bridge`、`files`；回调 `busy()`（等待期不换项目）、`onProjectChanged()` |
| `session_index.dart` | `SessionIndex` | `sessions.json` 的内存镜像：`refresh` / `upsert(store, …)` / `remove` / `agentOf` / `cwdOf` / `entryOf` / `stampPromptSent` / `lastUsedAgentId(installed)`；不是 notifier，谁写谁负责让侧栏重投影 | 150 | `bridge` |
| `agents_state.dart` | `AgentsState` | 已装 agent 列表（`installed` / `refreshAgents` / `displayName` / `iconSvgOf`）、registry 面板（画板 50 / 51：`registry` / 搜索与过滤 / `refreshRegistry` / `onRegistryProgress` / install / cancel / remove / `downloadNode` / `visibleEntries`）、设置面板（画板 70：`installedEntries` / `editAgent` / `collapseEdit` / `saveCustomAgent` / `splitArgs` / `importZed` / `zedImportResult`） | 450 | `bridge`；回调 `onRemoved(id)`、`onInstalledChanged()` |
| `auth_state.dart` | `AuthState` | 认证页（画板 52）的整个状态机：`agentId` / `phase` / `methodId` / `error` / `terminalLabel` / `elicitations` / `connection` / `methods` / `agentName` / `terminalId` / `terminalBuffer`，`open` / `selectMethod` / `start` / `retry` / `changeMethod` / `cancel` / `close` / `stopTerminal` / `terminalInput` / `authenticate`，requestScope elicitation 的 `onPendingChanged` / `acceptUrl` / `cancelElicitation` | 260 | `bridge`、`sessions`（`agents` 与 `pending`）；回调 `onAuthenticated(agent, cwd)`（自动重试新会话）、`openAgentsTab()`、`cwd()`、`agentName(id)` |
| `composer_state.dart` | `ComposerState` | 输入框：`editor`（原 `composer`）/ `focus`、`pendingBlocks` / `pendingImages`、`onChanged`（原 `onComposerChanged`）、`@` / `/` 内联菜单（`inlineMenu` / `inlineMenuOpen` / close / move / pick / `_updateMentionMenu`）、`+` 四项（`addResourceLink` / `removePendingBlock` / `addImage` / `pasteImageFromClipboard` / `addEmbeddedResource`）、`modelSearch` 输入控件、`configAnchor(id)` / `hideConfigPopovers`、`plusAnchor` / `followAnchor` / `usageAnchor` | 280 | `bridge`（`fs_list_dir` / `fs_search`）；查询 `store()`（slash 命令来源）、`cwd()`、`imageAllowed()` |
| `turn_controller.dart` | `TurnController` | 一轮对话：`send` / `_runTurn` / `_promptBlocks` / `cancel` / `answerPermission` / `answerElicitation` / `restore` / `_respondCancelled` / `_turnInFlight` / `_promptSentAt`；会话配置：`setConfigOption` / `selectConfigValue` / `setMode` / `toggleConfigBoolean` / `composerOptions` / `optionOf` / `optionById`；`firstPending` / `killTerminal` / `transcriptText` | 300 | `bridge`、`session`、`composer`、`index` |
| `session_controller.dart` | `SessionController` | 当前线程与会话生命周期：`agentId` / `sessionId` / `_sessionAgent` / `store` / `connection` / `hasAgent` / `hasSession` / `isRunning` / `agentDisplayName` / `threadTitle` / `agentIconSvg` / `sessionEpoch` / `waitingForAgent` / `composerPlaceholder` / `canCompose` / `showAgentStateBar` / `droppedUpdates`；能力 getter 九个（`canLoadSession` … `deletesOnAgent`）；侧栏列表（`sidebarSessions` / `visibleSessions` / `search` 三件 / `sidebarSearch` / running / unread / `noteUpdateArrival`）；`newSession` / `createSession` / `_ensureConnected` / `_adoptSession` / `reloadAgent` / `selectSession` / `_ensureLoaded` / `loadSession` / `resumeSession` / `closeSession` / `deleteSession` / `reconcileSessions` / `missingOnAgent` / `blockedByClose`；改名（`rename` 输入控件 + `startRename` / `cancelRename` / `commitRename` / `renamingInHeader`）与删除确认（`askDelete` / `cancelDelete` / `confirmingDeleteId`）；`newSessionAnchor` / `threadMenuAnchor` / `timelineAnchor`（画板 43，2026-09-20 新增）/ `deleteAnchor`；`ensureAgentSelected`（原 `_selectDefaultAgent`）、`dropAgent(id)`、`leaveWorkspace()` | 850 | `bridge`、`sessions`、`index`、`agents`、`workspace`；回调 `openWorkbench()` |
| `workbench_controller.dart` | `WorkbenchController`（组合根，仍是 `ChangeNotifier`） | 只剩：`source` / `bridge` / `sessions` / `batcher` / `traffic` / `files` / `terminals` + 九个子对象的构造与回调接线；`start()`（init → 索引 → registry → agents → 项目 → ui-state 的顺序不变）；六路核心事件的订阅与分发（`session_update` → `sessions` + `session.noteUpdateArrival` + `shell.followLocations`；`terminal_output` 按 `source` 分给 `terminals` / `sessions` / `auth`；`registry/progress` → `agents`）；`_enqueue` 与 flush 调度器；`dataDir` / `logPath` / `zedSettingsPath`；`dispose` / `shutdown` / `refresh`；子对象通知的汇总转发（阶段 A） | 400 | — |

`workbench_screen.dart` 与 `headless_run.dart`：只改成员引用路径（附录 A），widget 树与步骤逻辑一行不动。
`test/app/` 与 `test/ui/`：同样只改路径；用例数与断言不变。

**不产出**：新的桥命令、新的 `_meta` 键、新的 pub 依赖、`CoreCommands` 接口改动。

## 附录 A — 引用改名表

screen / headless / test 三处触碰的成员并集，按新家分组。没列出的成员留在组合根、名字不变
（`sessions` / `batcher` / `traffic` / `files` / `terminals` / `bridge` / `source` / `dataDir` / `logPath` / `zedSettingsPath` /
`start` / `shutdown` / `dispose` / `refresh` / `addListener` / `removeListener`）。

| 新家 | 成员（`旧名 → 新名` 只列改名的，其余同名） |
|---|---|
| `c.shell` | `sidebarCollapsed` `sidebarWidth` `rightPanelWidth` `filesTreeWidth` `filesTreeCollapsed` `resizeSidebar` `resizeRightPanel` `resetSidebarWidth` `resetRightPanelWidth` `resizeFilesTree` `resetFilesTreeWidth` `toggleFilesTree` `saveUiState` `toggleSidebar` `page` `openTraffic` `openWorkbench` `openTabs` `rightTab` `activeTerminalId` `panelTabs` `activePanel` `rightPanelOpen` `activeNavTab` `openTab` `toggleNavTab` `closeTab` `selectPanel` `closePanel` `closeRightPanel` `toggleRightPanel` `openTerminalTab` `closeTerminalTab` `stopTerminalTab` `clearTerminalTab` `restartTerminalTab` `follow` `toggleFollow` `goToFile` `trafficFilter` `trafficFilterFocus` |
| `c.workspace` | `project` `recentProjects` `branch` `branches` `branchAreaVisible` `rulesCount` `openProject` `switchBranch` `createBranch` `projectSearch` `projectSearchFocus` `branchInput` `branchFocus` `projectAnchor` `branchAnchor` |
| `c.index` | `refreshSessionIndex → refresh`（只有 test 直接调） |
| `c.agents` | `installedAgents → installed` `refreshAgents` `agentIconSvgOf → iconSvgOf` `registry` `registrySearch → search` `registrySearchFocus → searchFocus` `registryQuery → query` `registryFilter → filter` `registryShowLog → showLog` `visibleRegistryEntries → visibleEntries` `refreshRegistry` `setRegistryFilter → setFilter` `setRegistryQuery → setQuery` `installAgent → install` `cancelInstall` `toggleInstallLog` `removeAgent → remove` `downloadNode` `installedEntries` `settingsExpandedId → expandedId` `settingsEditingId → editingId` `settingsEdit → edit` `editAgent` `collapseSettingsEdit → collapseEdit` `saveCustomAgent` `importZed` `zedImportResult` |
| `c.auth` | `authAgentId → agentId` `authPhase → phase` `authMethodId → methodId` `authError → error` `authTerminalLabel → terminalLabel` `authElicitations → elicitations` `authConnection → connection` `authMethods → methods` `authAgentName → agentName` `authTerminalId → terminalId` `authTerminalBuffer → terminalBuffer` `openAuth → open` `selectAuthMethod → selectMethod` `startAuth → start` `retryAuth → retry` `changeAuthMethod → changeMethod` `cancelAuth → cancel` `closeAuth → close` `stopAuthTerminal → stopTerminal` `authTerminalInput → terminalInput` `authenticate` `acceptElicitationUrl → acceptUrl` `cancelElicitation` |
| `c.composer` | `composer → editor` `composerFocus → focus` `pendingBlocks` `pendingImages` `onComposerChanged → onChanged` `inlineMenu` `inlineMenuOpen` `closeInlineMenu` `moveInlineMenuSelection` `pickInlineMenuSelection` `addResourceLink` `removePendingBlock` `addImage` `pasteImageFromClipboard` `addEmbeddedResource` `modelSearch` `modelSearchFocus` `configAnchor` `hideConfigPopovers` `plusAnchor` `followAnchor` `usageAnchor` |
| `c.turn` | `send` `cancel` `answerPermission` `answerElicitation` `restore` `setConfigOption` `selectConfigValue` `setMode` `toggleConfigBoolean` `composerOptions` `optionOf` `optionById` `firstPending` `killTerminal` `transcriptText` |
| `c.session` | `agentId` `sessionId` `store` `connection` `hasAgent` `hasSession` `isRunning` `agentDisplayName` `threadTitle` `agentIconSvg` `sessionEpoch` `waitingForAgent` `composerPlaceholder` `canCompose` `canPromptImage` `showAgentStateBar` `droppedUpdates` `canLoadSession` `canLoadSessionOf` `canListSessions` `sessionClosed` `canResumeSession` `canCloseSession` `canDeleteSession` `deletesOnAgent` `missingOnAgent` `sidebarSessions` `visibleSessions` `search` `setSearch` `clearSearch` `sidebarSearch` `sidebarSearchFocus` `runningSessionIds` `unreadSessionIds` `newSession` `reloadAgent` `selectSession` `resumeSession` `closeSession` `deleteSession` `reconcileSessions` `startRename` `cancelRename` `commitRename` `rename` `renameFocus` `renamingSessionId` `renamingInHeader` `askDelete` `cancelDelete` `confirmingDeleteId` `newSessionAnchor` `threadMenuAnchor` `timelineAnchor` `deleteAnchor` |
| 各对象自带 | `lastError`（来自 mixin；headless / test 里读哪个动作的错误就读哪个对象的） |

`waitingForAgent` 留在 `session`（`newSession` / `reloadAgent` 写它），`workspace.openProject` 的等待期守卫经回调 `busy()` 读；
`lastError` 不再有全局一份，谁的命令谁记。BACKLOG「`lastError` 在产品 UI 上没有出口」那条将来做壳级提示位时，
在组合根上聚合九个对象的 `lastError` 即可，本轮不做。

## 附录 B — 依赖方向

只允许下图的箭头（A → B 表示 A 持有 B 或在构造时拿到 B 的引用），反向一律走构造时注入的回调（`void Function()` /
`T Function()`），回调由组合根接线。没有任何子对象 import `workbench_controller.dart`。

```text
                 lib/projection（Sessions / RegistryState / TrafficStore / PendingQueue）
                    ▲            ▲            ▲             ▲
                    │            │            │             │
  shell ──► files, terminals     │            │             │
  workspace ──► files            │            │             │
  index                          │            │             │
  agents ────────────────────────┘            │             │
  auth ───────────────────────────────────────┘             │
  composer ──► (store() / cwd() / imageAllowed() 查询回调)   │
  thread ──► index, agents, workspace ──────────────────────┘
  turn ──► thread, composer, index

  组合根 ──► 以上全部；回调接线：
    workspace.onProjectChanged  → files.setProject + thread.leaveWorkspace + thread.refreshSidebar
    workspace.busy              → thread.waitingForAgent
    agents.onRemoved(id)        → thread.dropAgent(id) + auth.closeIfAgent(id)
    agents.onInstalledChanged   → thread.ensureAgentSelected + thread.refreshSidebar（图标）
    auth.onAuthenticated        → thread.createSession(agent, cwd)
    auth.openAgentsTab / cwd / agentName → shell.openTab / workspace.project / agents.displayName
    composer.store / cwd / imageAllowed → thread.store / workspace.project / thread.canPromptImage
    thread.openWorkbench        → shell.openWorkbench
```

`turn → session` 是唯一保留的「协议对象之间」的依赖，方向固定：一轮对话读当前线程，线程不知道有轮。
BACKLOG 那条 `send()` 懒开会话守卫要分清的四种状态（无 sessionId / 有 store / 已 initialized 且不支持 loadSession /
载回失败或能力未知）正好落在这条边上，下一轮修它时给 `session` 加一个返回四态的查询即可，不必再翻整个类。

## 实施顺序

从边缘往里剥，每一步之后剩下的 `workbench_controller.dart` 都能编译、`validate.ps1` 全绿、fake-agent 的三份无头报告等价；
每步一个提交（提交说明写「R7.5 第 N 步：拆出 X」）。咬合的核心（`session`）最后一步整体搬出，中途不拆散它。

| # | 步骤 | 提交后 `workbench_controller.dart` 约剩 |
|---|---|---|
| 0 | 建分支与任务卡；跑基线：`validate.ps1`、三份无头报告存 `rounds/round-7.5/baseline/`（gitignored 大文件只留 JSON）；分支已于 2026-09-20 拉出 | 2645 |
| 1 | `guarded.dart` mixin；组合根 `with GuardedNotifier`，`_guard` / `_touch` 改调 mixin。纯替换，不搬任何段 | 2620 |
| 2 | `ShellState`：分栏宽度、页面、右栏标签条、本地终端标签、Follow、`trafficFilter`。screen / headless / test 改 `c.shell.*` | 2250 |
| 3 | `WorkspaceState` + `SessionIndex`：项目 / 分支 / 规则、索引镜像。`_saveIndex` 与 `_stampPromptSent` 先以「组合根调 `index.upsert`」形态留在根 | 1850 |
| 4 | `AgentsState`：已装列表、registry 面板、设置面板。`removeAgent` 里碰 `agentId` / `authAgentId` / 设置态的三行改成回调 | 1400 |
| 5 | `AuthState`：认证页整段 + `authenticate` + `_onPendingChanged`。自动重试改走 `onAuthenticated` | 1150 |
| 6 | `ComposerState`：输入框、内联菜单、`+` 四项、配置项弹层锚点 | 900 |
| 7 | `TurnController`：一轮对话 + 会话配置 + `killTerminal` / `transcriptText`。此时它还从组合根读 `agentId` / `sessionId` / `store` | 650 |
| 8 | `SessionController`：会话核心整段搬出，组合根只剩接线；`turn` 的引用改指 `session` | ≤ 400 |
| 9 | 阶段 B（按裁定门第 4 项）：先量后动。在 `debug` 构建里给 `AppShell` 的 build 计数，回放 `test/fixtures/` 的 290 行 `session/load` 重放与一段 fake-agent 流式输出，记「每帧 batch 触发的壳级 build 次数」；超过裁定阈值才把 screen 改成按区域 `Listenable.merge([...])` 订阅并补一条重建计数的 widget 测试，否则数字记任务卡、条目记 BACKLOG | — |

审查节奏：第 2 步与第 8 步之后各发一轮全量审查（`-Scope branch`），中间各步只跑 validate 与无头等价；
第 3 轮起按 CLAUDE.md 只审整改 diff。给审查器的 `-Note` 固定写「纯移动重构，附录 A 是改名表，请核对行为等价与依赖方向，
不要提出设计层面的重排」。

## 验收

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | 契约与画板零 diff | `git diff main...HEAD --stat -- lib/ui lib/theme lib/projection lib/bridge rust test/fixtures pubspec.yaml` 为空 |
| 2 | validate 全绿 | `powershell -File scripts/validate.ps1`：13 项 PASS（含白名单、样式字面量扫描、`flutter analyze`、`flutter test`） |
| 3 | 测试只改路径 | `test/` 的 diff 里没有删改 `expect(` 行，`test(` / `testWidgets(` 计数与基线相同（基线 2026-09-20：`test/app` + `test/ui` 186 例，`flutter test` 全量 294 项） |
| 4 | 无头实跑等价 | fake-agent 跑 `ACP_R3_REPORT` / `ACP_R5_REPORT` / `ACP_R6_REPORT`，与第 0 步的基线 JSON 逐步骤比对（忽略耗时字段），三份全等 |
| 5 | 行数门 | `workbench_controller.dart` ≤ 450 行；`lib/app/*.dart` 无一超过 900 行；用 `wc -l` 记进任务卡 |
| 6 | 依赖方向门 | `grep -l "workbench_controller.dart" lib/app/*.dart` 只剩 `app.dart` / `workbench_screen.dart` / `headless_run.dart`；子对象之间的 import 只出现附录 B 允许的边（人工核一遍 import 列表，记任务卡） |
| 7 | 通知等价（阶段 A） | 组合根仍把九个子对象的通知汇总转发；`test/ui/` 现有 widget 测试全过即视为通过 |
| 8 | Windows 真跑（规则 9） | `scripts/build.ps1 -Smoke` 过；dsh 与 claude-agent-acp 各一轮：新建 → 发消息 → 权限 → 停止 → 改名 → 删除 → 换项目 → 认证页开合 → registry 面板 → 设置面板 → 本地终端 → 文件面板 Follow；命令与结果记任务卡 |
| 9 | 所有者手测 | 弹层锚点搬了家（9 个 `PopoverHandle` 分到 thread / workspace / composer），画板 40 / 41 / 42 / 43 / 25 的弹层位置、Esc、点外面关、`@` `/` 键盘导航、画板 05 转场、画板 06 活动指示逐项看一遍 |
| 10 | 阶段 B（若做） | 重建计数的 widget 测试：一次 `session/update` batch 只重建转录区与侧栏活动指示，不重建右栏与顶栏 |

## 禁止

- 默认三条：不改前端页面样式（规则 3）；不加设计稿没有的功能（规则 3）；不在 `vendor/upstream/` 里改代码（规则 4）。
- **不改任何行为**：包括错误文案、通知时机、`start()` 的调用顺序、`_guard` 吞错的范围。看到想修的记 BACKLOG，哪怕只是一行。
- **不修 BACKLOG 条目**，包括 § 「与 BACKLOG 的关系」里那 8 条「拆完就能修」的；它们归下一轮。
- 不动 `lib/projection/`（`Sessions` / `SessionStore` / `RegistryState` 的接口一个不加）；不动 `FilesState` / `LocalTerminals` 内部（只换它们的持有者）；不改 `CoreCommands`。
- 不引任何 pub 依赖；不用 `provider` 之类的传递依赖（规则 1）。
- 不保留转发门面（裁定门第 3 项按推荐项时）：组合根上不写「`Future<void> send() => turn.send()`」这类一行转发，让上帝接口真的消失。
- 不给子对象持有组合根的引用；反向调用一律回调注入（附录 B）。

## 裁定门（开工前）

按所有者习惯每项一个推荐 + 备选；有推荐项的可按推荐项开工并标「待确认」。

| # | 事项 | 推荐 | 备选 |
|---|---|---|---|
| 1 | 轮次编号 | **R7.5**：纯代码结构、无画板，夹在 R7 与 R8 之间做，先于打包发布；沿用 R1.5 的编号写法 | R9，排在 R8 之后（代价：R8 干净机验收之后再动组合根，发布后的回归风险更高） |
| 2 | 拆分粒度 | **组合根 + 8 个对象**（交付物表）。粒度取自耦合矩阵：咬合的两段各成一个 Controller，零咬合的按画板归组成 State | 保守版「组合根 + 3 个」：`SessionController`（会话 + 一轮 + 索引）、`PanelsState`（registry + 认证 + 设置）、`ShellState`（其余）。改名面小一半，但 thread 仍 1300 行、下一轮修缺陷时还得再拆 |
| 3 | 引用方式 | **直接访问子对象**（`c.session.send()`），screen / headless / test 按附录 A 改名，编译器兜底漏改 | 组合根保留转发门面、零改名。代价：150 行一行转发，103 个公有方法的上帝接口原样留着，只是身体变薄 |
| 4 | 通知策略 | **阶段 A 必做 + 阶段 B 先量后动**：阶段 A 组合根继续汇总转发（行为零变化）；阶段 B 按实施顺序第 9 步量壳级 build 次数，超过阈值才改区域订阅。阈值建议：一次 `session/update` batch 触发的壳级 build > 1 次且 290 行重放的总 build 耗时 > 一帧（16 ms） | 阶段 B 本轮必做（代价：screen 的订阅关系是新的行为面，「漏订阅 → 界面不刷新」这类缺陷要靠手测兜） |
| 5 | 是否顺手修缺陷 | **不修**，本轮零行为变化；紧接着开 R7.7 在新结构上修 § 「与 BACKLOG 的关系」的 8 条（起草时叫 R7.6，该编号 2026-09-20 已被字体切换轮占用） | 本轮末尾（第 8 步审查收口后）追加修 4 条「最小修复」项（`closeTab` / `_updateMentionMenu` / `_saveIndex` 两条），单独提交、单独审查 |
| 6 | validate 加门 | **加两个 Step**：「lib/app 行数门（规则 3 补充）」与「lib/app 依赖方向门」，各十来行 PowerShell，防止再长回去 | 只在任务卡记数字，不进 validate |

## 与 BACKLOG 的关系

BACKLOG 84 条未关闭项（2026-09-20 重数，含本轮自己的立项条目；起草时 80）里 17 条与这个文件有关，本轮**一条都不修**，但每条都要在拆完后有明确的新家；下一轮（建议 R7.7）按这张表做。2026-09-20 复核：这 17 条一条未关、一条未改；上游新关的 1 条（会话大纲 → 画板 43）与新增的 5 条（R7.6 字体后续）都不碰组合根。
条目按 BACKLOG 里的用语引用。

**拆完立即可修（8 条，逻辑缺陷，归 R7.7）**

| BACKLOG 条目 | 新家 | 备注 |
|---|---|---|
| `send()` 的懒开会话守卫（两轮整改被报回，所有者裁定单独一轮） | `turn` ↔ `session` 的边 | 给 `session` 加四态查询，`turn.send` 按四态分流；别覆盖 `newSession` 的 `lastError` |
| `_runTurn` 收轮 `_saveIndex()` 写的是当前选中而不是刚跑完的会话 | `turn` → `index.upsert(s)` | 拆分时 `_saveIndex` 已改成收 `SessionStore` 参数（只是形参，行为不变），修的时候只改一个实参 |
| 载回来的会话在下一轮对话后丢标题（`_saveIndex` 写占位串） | `index.upsert` | 退回索引里已有的标题 |
| `_updateMentionMenu` 在 await 之后无条件写回 | `composer` | await 之后加一句 token 仍是原来那个才写回 |
| `closeTab`：文件 + 终端并存时关掉最后一个面板标签把整栏收起 | `shell` | `openTabs` 空而 `terminals.tabs` 非空时 `activeTerminalId` 设成最后一个 |
| `session/list` 校对 `_reconcile` 按 cwd 原串比、侧栏按归一后比 | `session.reconcileSessions` + `workspace.normalizeCwd` | 两处统一走 `workspace.normalizeCwd` |
| agent 进程换过一轮之后其它会话拿的还是旧 sessionId（要连接代次） | `session` | 机制类，代次记在 `session._sessionAgent` 旁；拆完后改动面只在一个文件 |
| 认证页成功后的自动重试 `_createSession(agent, retryCwd)` 用的是旧 cwd | `auth.onAuthenticated` → `session.createSession` | 在 `session.createSession` 里按当前 `workspace.project` 判一次 |

**要先改设计稿的（3 条，扩边界，等设计轮）**

| BACKLOG 条目 | 新家 |
|---|---|
| `lastError` 在产品 UI 上没有出口 | 组合根聚合九个 `lastError` + 壳级提示位（画板要先画） |
| 第三条「等 agent」的路径没有等待态（`selectSession → _ensureLoaded`） | `session`（`waitingForAgent` 套在 `_ensureLoaded` 上；画板 05 A 组要先补等待期） |
| 换项目放下的会话若正挂着权限 / elicitation 请求，界面无痕迹 | `session.leaveWorkspace` + 项目切换器徽章（画板 41 要先画） |

**设计稿补注记（2 条，实现已在控制器里，只等重出 PNG）**

| BACKLOG 条目 | 新家 |
|---|---|
| 画板 05 B 组 `waitingForAgent` 两个触发共用 | `session.waitingForAgent` |
| 画板 40 会话配置固定档序平铺（`composerOptions`；gallery 之后改回走控制器的档序） | `turn.composerOptions` |

**相邻（4 条，主体在别处，改动会碰到这些新家）**

| BACKLOG 条目 | 会碰到 |
|---|---|
| 用户消息的编辑重发只带回文本（`onRegenerate` 只传 `String`） | `turn.restore` |
| `workbench_screen.dart` `_addImage()` 没有大小门、screen 一处都不写 `lastError` | `composer.addImage` 做门、记 `composer.lastError`，分层就顺了 |
| R5 无头实跑以 `exit()` 结束不走 `agent_disconnect` | 组合根 `shutdown` |
| R6 `session/delete` 只在「已连上且声明 delete」时发 | `session.deleteSession`（产品取舍，等裁定） |

另有 3 条与 `lib/app/` 其它文件有关但不碰组合根，本轮不动：`files_state.dart` `setProject` 的 A→B→A 竞态、
`clipboard_image.dart` 的三条（超时不杀进程 / 张数门 / 截断 PNG）。

## 2026-09-20 复核：main 新合并提交对本计划的影响

起草（2026-09-18，基线 `58f19f2`）之后 main 进了 16 个提交（`521c405..5a001bf`，78 个文件 +4360 / −324），三件事：
画板 43 会话时间线（`session-timeline` 分支，合并 `867251b`）、R7.6 字体切换四轴（`font-switching` 分支，合并 `1bf7eb8` / `5a001bf`）、
v1.0.0 许可证与版本号（`9771d19` / `8eacfe7`）。逐项核对后计划的骨架不变，改的是编号、数字与几处说明：

| 新合并的内容 | 对组合根的实际改动 | 对本计划的影响 |
|---|---|---|
| 画板 43 会话时间线（`42ad9fc` / `e44620d` / `c1227fd` / `867251b`） | `workbench_controller.dart` +3 行：`timelineAnchor`（第 9 个 `PopoverHandle`）。弹层开关、跳转估位与聚焦态全在 `workbench_screen.dart`（+106 行：`_openTimelinePopover` / `_jumpToEntry` / `_scheduleJump` / `_revealRow` / `_focusedEntryId`），另有新的 `lib/projection/timeline.dart` 与 `lib/ui/popovers/session_timeline.dart`；`test/app/timeline_wiring_test.dart` 经 `c.timelineAnchor` / `c.sessionId` / `c.sessions` / `c.composer` 驱动 | `timelineAnchor` 归 `session`（与 `threadMenuAnchor` 同属线程头）；附录 A、交付物表、验收 9 已加。screen 侧的跳转逻辑不在本轮范围（screen 只改引用路径），但 screen 已从 835 行长到 945 行、开始攒滚动 / 跟随 / 跳转三套多帧纠正逻辑，记「观察」不记 BACKLOG，等它出第一个缺陷再议 |
| R7.6 字体切换（`0238842` / `7117f68` / `bab8bf5` / `1bf7eb8` / `93c4204` / `6d7f301` / `5a001bf`） | 组合根零改动。新增 `lib/app/font_prefs.dart`（479 行，`FontPrefsController extends ChangeNotifier`，自带 `bridge` 与 `_disposed` 挡板），在 `app.dart` 里与 `WorkbenchController` 并列构造、作为第二个构造参数传给 `WorkbenchScreen`，整棵 `MaterialApp` 包在 `ListenableBuilder(listenable: _fonts)` 下；`CoreCommands` 加 `appearanceGet` / `appearanceSet`（`test/app/fake_core.dart` 已同步）；`tokens.dart` 的 `Fonts` 从编译期常量改为运行时四轴、9 个字阶改 getter | ① 它是「独立 `ChangeNotifier` + 注入 `bridge` + 在组合根旁接线」这一形态的第四个先例（前三个是 `FilesState` / `LocalTerminals` / `RegistryState`），本计划的 8 个对象与它同形，裁定门第 2 项的推荐项因此更稳；② 它又复制了一份 `_disposed` / 错误边界的样板，是 `GuardedNotifier` mixin 的又一个收编对象，但本轮不碰它（交付物表 `guarded.dart` 行已注）；③ 「`app.dart` 不改」仍成立，`FontPrefsController` 留在 `app.dart`、不进组合根；④ 验收 1 零 diff 清单里的 `lib/theme` 与 `lib/bridge` 都被上游改过，但本轮不碰它们，判据不变；⑤ 「不改 `CoreCommands`」仍成立 |
| R7.6 这个编号 | — | 起草时把「拆完后修 8 条缺陷」那一轮叫 R7.6，现已被字体切换占用；**后续缺陷轮改叫 R7.7**（裁定门第 5 项、§ 与 BACKLOG 的关系、ROUNDS.md 已同步改） |
| v1.0.0 许可证与版本号 | 无 | 无；R8 的 LICENSE / NOTICE 交付物已提前落地，与本轮无关 |
| 审查默认模型切到 `cursor-grok-4.6-high-fast`（`bab8bf5`） | 无 | 「代码审查」段的模型名已随之更新 |
| BACKLOG | 上游关闭 1 条（会话大纲 → 画板 43）、新增 5 条（R7.6 的字体后续），均不碰组合根 | 17 条相关条目一条未动、一条未关；分母从 80 变为 84（含本轮自己的立项条目） |

复核后的引用面：screen 180、headless 85、test 105 个不同成员，改名总量约 370 处，仍由编译器兜底。
main 直改期间控制器只被碰了 3 行，说明「前置」里那条「尽量不碰 `workbench_controller.dart`」的约定在这两天里自然成立；
但这更像是这两轮恰好不在会话路径上，不是常态，开工后仍要盯着 main。

## 契约与文档同步（收口时）

- `CLAUDE.md` 仓库结构里 `lib/app/` 那一行：列出九个文件的分工。
- `ROUNDS.md` § 2 第 84 行「前端其余目录」的 `lib/app/` 描述；§ 7 进度表本轮一行。
- `docs/design.md` § 9「前端」加一条「组合根分层」：组合根只接线，状态按画板分组成 `*State`，协议驱动的两个 `*Controller`，依赖方向附录 B。
- `rounds/BACKLOG.md`：本轮的立项条目关闭；17 条相关条目各补一句「新家」。
- 若裁定门第 6 项按推荐：`scripts/validate.ps1` 两个新 Step 与 CLAUDE.md「命令」段的一句说明。

## 代码审查

<!-- 完成后回填。审查路由见 CLAUDE.md「开发模式」与 docs/review-workflow.md：
     ① cursor CLI + grok 4.6 high fast → ② 硬失败回落主会话委派的 Claude Code 只读子代理（同一份任务书）。
     范围：前两轮全量（-Scope branch，即 main...HEAD），第 3 轮起只审上一轮整改 diff（-Scope since -Base <上一轮已审提交>）。
     本轮特殊：diff 以「移动」为主，给审查器的 -Note 固定写「纯移动重构，附录 A 是改名表，请核对行为等价与依赖方向」；
     人看 diff 用 git diff --color-moved=dimmed-zebra。 -->

- 审查方式：`cursor-review.ps1`（默认档，两轮全量；`-Note`「纯移动重构，附录 A 是改名表，请核对行为等价与依赖方向，不要提出设计层面的重排」）
- 审查器与模型：cursor CLI `cursor-grok-4.6-high-fast`（两轮都是；未回落）
- 审查范围与基准提交：第 1 轮 `main...HEAD`（HEAD = `2c25099`，第 0–6 步，30 文件 +3796 / −1859）；第 2 轮 `main...HEAD`（HEAD = `fd5b7a9`，第 0–9 步 + 文档同步，35 files changed, 5419 insertions(+), 3309 deletions(-)）
- 第 1 轮（2026-09-20 13:29，7 分钟，产物 `.claude/reviews/20260920-132929-review.out.md`）：**0 findings**。审查器逐段与 main 对照了 `start` / `openProject` / `_enterWorkspace` / `_saveIndex` / `_createSession` / `_adoptSession` / `send` / `_runTurn` / `refreshRegistry` / `removeAgent` / `startAuth` / `_onPendingChanged` / Follow / 右栏，确认契约面零 diff、测试只改接收者路径、`start()` 顺序与阶段 A 通知不变、子对象只走附录 B 的边。
- 第 2 轮（2026-09-20 13:53，5 分钟，产物 `.claude/reviews/20260920-135353-review.out.md`）：**0 findings**。审查器对着基线 `f62520f` 核了组合根接线（`start()` 顺序、六路事件分发、`terminal_output` 分流、子对象 listener 汇总、dispose）、九个新文件、screen / headless / 12 个测试文件的改名、依赖方向（与附录 B 和 validate 门一致）、以及会话 / 认证 / 一轮对话几条关键路径（`openProject` / `_enterWorkspace`、`refreshRegistry` / `_selectDefaultAgent`、`startAuth` 的 `_adoptSession` + `_saveIndex` vs `adoptAuthSession`、`_createSession`、`_onTerminalOutput`、`_guard` / `_touch`、permission / elicitation 必回、`session/cancel` 后 elicitation 代答）；任务卡写明不修的 BACKLOG 项未报。审查器顺带指出 main 在本轮开工后又进了「Thread → Session 收敛」（不在范围内），见下方「main 的后续提交」。
- findings 处理：两轮共 0 条，无整改。
- 结论：PASS（两轮全量审查 0 findings）。第 9 步之后只动了两处非代码的东西（validate 行数门改按原始行计 + screen 放宽、BACKLOG 一条措辞），没有再发一轮（没有采纳整改的 findings）。
- 与计划的偏离：第 2 步之后那一轮审查漏发（本会话的疏忽），改在第 6 步提交后发第 1 轮全量——范围仍是 `main...HEAD`，覆盖第 0–6 步；第 2 轮按计划在第 8 步之后发（含第 9 步与文档同步）。

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-7.5/BLOCKED.md`，停下呼人。禁止放宽验收标准自我通过。
本轮最可能的 BLOCKED 点是验收 4（无头等价）：某一步搬完后报告不等价，说明搬动改了通知时机或 `_guard` 范围；
回退那一步，把差异原因记任务卡，不要「顺手修成对的」。

## 本轮实测

<!-- 完成后回填：基线数字（行数 / 用例数 / 三份报告）、每步的 wc -l、import 列表核对、阶段 B 的 build 计数、
     Windows 真跑命令与输出（规则 9）、与计划的偏离及原因 -->

### 第 0 步：基线（2026-09-20，提交 `f62520f`）

| 项 | 数值 |
|---|---|
| `wc -l lib/app/workbench_controller.dart` | 2645 |
| `scripts/validate.ps1` | 13 项 PASS（`flutter test` 全量 **319** 项通过；任务卡起草时记的 294 是旧数字，以这次实测为准） |
| `test/app` + `test/ui` 用例数 / `expect(` 行数 | 186 / 798（`grep -cE '^\s*(test|testWidgets)\('` 与 `grep -c 'expect('`） |
| 三份无头报告 | `rounds/round-7.5/baseline/{r3,r5,r6}.json`（fake-agent，`ok: true`；r3 70 s、r5 2 s、r6 6 s） |

无头报告的跑法（脚本随基线入库：`rounds/round-7.5/baseline/run-report.ps1`，工作目录 `D:\cargo-target\AcpAgentClient\r75`）：
每次跑都从模板复制一份**隔离的** `APPDATA`（只有 `settings.json` 的三条 fake 条目 + 一份 `registry-cache` 副本，不碰所有者的真实数据目录，规则 7）
与一份 git 化的项目目录，所以三份报告逐次可比。参数：r3 = `fake-r3`（`--fs --terminal --terminal-bg --stderr-noise`）+ `ACP_R3_CONFIG=mode=code` +
两轮（第二轮 2 s 后 cancel）+ 新建分支 + `ACP_R3_KILL=1` + R4 的四项（后台终端 2 s 后停止、本地 shell、文件面板、Follow）；
r5 = `fake-r5`（无 `FAKE_AGENT_AUTHED`，走 `-32000` → 认证页 → `fake-url` → requestScope 卡 → 自动重试）+ 一轮 + `ACP_R5_IMPORT_ZED=1`（隔离目录里没有 Zed，走错误文案那条路）；
r6 = `fake-r6`（`--sessions`）+ 三轮（第三轮 2 s 后 cancel）+ `ACP_R6_MODE=ask` + reload + close + resume + delete。
基线连跑两遍做噪声校准：原始 diff 只有 `elapsedMs`、`taskkill` 块（pid 与文案）与 r6 随机的 `sess_<uuid>`，r5 零差异；
比对脚本 `compare.py` 只忽略这三样（uuid 按首次出现顺序规范化），其余字段（含 `traffic.byMethod` 的逐方法计数、`seen` 的逐类 update 计数、
每步的 `error` 文案）全部逐字比。

### 第 1–8 步：逐步拆出（每步一个提交；每步 validate 13 项 PASS、`flutter test` 319、三份无头报告与基线等价）

| 步 | 提交 | 拆出 | `workbench_controller.dart` 行数 | 新文件行数 | 引用改动数（screen / headless / test） |
|---|---|---|---|---|---|
| 1 | `a794323` | `guarded.dart`（`GuardedNotifier` mixin + `hidePopover`） | 2645 → 2622 | 50 | —（纯替换：`guard` 36 / `touch` 82 / `hidePopover` 10 处） |
| 2 | `60c439b` | `shell_state.dart` | 2345 | 348 | 41 / 15 / 57 |
| 3 | `c02d89d` | `workspace_state.dart` + `session_index.dart` | 2131 | 196 + 144 | 27 / 25 / 21 |
| 4 | `1a3efc6` | `agents_state.dart` | 1883 | 317 | 34 / 31 / 29 |
| 5 | `d8e5096` | `auth_state.dart` | 1681 | 288 | 21 / 13 / 40 |
| 6 | `2c25099` | `composer_state.dart` | 1430 | 327 | 34 / 6 / 29 |
| 7 | `67082bc` | `turn_controller.dart`（临时 `ThreadPort` 接口由根实现，第 8 步删） | 1134 | 358 | 14 / 19 / 32 |
| 8 | `60235d4` | `session_controller.dart`；根整体改写成组合根；`turn` 改指 `SessionController` | **356** | thread 848 / turn 345 | 85 / 104 / 160（另 13 处级联赋值 `..agentId = ` 等，与 session_lifecycle 里 `full` / `pi` / `none` / `plain` 四个变量名上的 19 处） |

验收 5 的行数门：`wc -l`：`workbench_controller.dart` **356**（≤ 450）；新文件 `session_controller.dart` 848、`shell_state.dart` 348、`turn_controller.dart` 345、`composer_state.dart` 327、`agents_state.dart` 317、`auth_state.dart` 288、`workspace_state.dart` 196、`session_index.dart` 144、`guarded.dart` 50，都 ≤ 900；本轮只改引用路径的两个既有文件超过 900——`headless_run.dart` 1186（无头驱动，基线就是这个数）与 `workbench_screen.dart` 946（画板 43 之后就是这个数）——在门里显式放宽到 1300 / 1000 并写明理由，记 BACKLOG 等裁定。门一开始用 `Measure-Object -Line` 数非空行（screen 870 / headless 1112）与本表的 `wc -l` 口径不一致，第 2 轮审查后改成按原始行计（与 `wc -l` 同口径）

验收 6 的依赖方向（`lib/app/*.dart` 同目录 import，2026-09-20 核对）：`guarded` → core_bridge；`shell_state` → core_bridge / files_state / guarded / local_terminals；`workspace_state` → core_bridge / files_state / guarded；`session_index` → core_bridge；`agents_state` → core_bridge / guarded；`auth_state` → core_bridge / guarded；`composer_state` → clipboard_image / core_bridge / guarded；`turn_controller` → composer_state / core_bridge / guarded / session_controller；`session_controller` → agents_state / core_bridge / guarded / session_index / workspace_state；组合根 → 以上全部 + files_state / local_terminals / paths。全部是附录 B 的边（`turn → session`、`session → index / agents / workspace`、`shell / workspace → files`），没有反向边
`grep -l "workbench_controller.dart" lib/app/*.dart` = `app.dart` / `workbench_screen.dart` / `headless_run.dart` 三个。两道门已进 `scripts/validate.ps1`（提交 `fd5b7a9`），validate 从 13 项变 15 项。

验收 3：`test/` 只改引用路径——`test/app` + `test/ui` 仍是 186 例 / `expect(` 798 行（`git diff main...HEAD -- test | grep -c '^[-+].*expect('` = `-` 191 行 / `+` 191 行，一一对应，全部是接收者路径改动，见 `git diff --color-moved=dimmed-zebra`）；`flutter test` 全量 319。

验收 1：`git diff main...HEAD --stat -- lib/ui lib/theme lib/projection lib/bridge rust test/fixtures pubspec.yaml` 为空（`--stat` 输出 0 行，`pins/upstream.json` 一并核过）。

验收 4：每步 `rounds/round-7.5/baseline/compare.py` 三份全部 `EQUIVALENT`。两次偶发（都是同一二进制重跑后等价，不是行为差异）：
第 5 步 r3 的 `branches.afterSwitchBack` / `branches.error` 撞上 git 自己的 `index.lock`（分支切回 main 时文件面板的 `git status` 正在刷新索引）；
第 7 步 r3 的 `newSession.commands` 取样早于 `available_commands_update` 到达（r6 基线里同一字段本就是空的，这是取样时序）。
另一次不是偶发而是**比对抓到了报告读错对象**：第 4 步 r5 的 `importZed.error` 读的还是根上更早的认证错误——拆分后 `lastError`
按对象分开了，headless 里各步的 `error` 改读对应对象（agents / workspace / turn / thread）之后等价；这也是附录 A「谁的命令谁记」在无头脚本上的落实。

### 与计划的偏离（原因都在括号里，不改任务卡正文）

1. 分支：本会话跑在独立 worktree，提交落在 `claude/r7-5-composition-root-refactor-7600bf`（`round-7.5` 在主工作副本已检出、worktree 里再检出会让主副本 HEAD 跟着走）；收口后 `git -C D:\variFlight_work\AcpAgentClient merge --ff-only claude/r7-5-composition-root-refactor-7600bf` 即可把 `round-7.5` 推到同一个提交。
2. 回调比附录 B 多几条，都是原码里确实存在、附录 B 没画出来的反向读写：`shell.cwd`（开本地终端要项目目录）、`shell.onWorkbenchShown`（回工作台撤绿点）、`agents.onRegistryChanged`（与 `onInstalledChanged` 分开——原码里侧栏重投影在 `refreshAgents` **之前**，合成一条会改顺序）、`agents.onPaths`（`dataDir` / `logPath` / `zedSettingsPath` 留在根）、`auth.ensureAgentsTab`（`onPendingChanged` 那条「右栏不是 Agents 标签才切」的判断）、`auth.currentAgentId` / `auth.registryName` / `auth.showWorkbench`、`session.showWorkbench` / `isWorkbenchPage` / `openAgentsTab` / `openAuth`、`composer.canCompose`。
3. `_promptSentAt` 放在 `SessionIndex`（不是任务卡写的 `turn`）：`commitRename` 与 `saveIndex` 都要读它；`saveIndex` / `stampPromptSent` 留在 `session`（`turn` 调它们），`SessionIndex.upsert` 收显式的 agent / 标题兜底参数。
4. `session.leaveWorkspace` 沿用原名 `enterWorkspace`；`_selectDefaultAgent` → `ensureAgentSelected`（任务卡的名字）。
5. `hidePopover` 顶层函数放在 `guarded.dart`（三个对象共用，原 `static _hide`）。
6. 第 7 步用临时接口 `ThreadPort`（九个成员）让 `turn` 先接根、第 8 步换本体后删掉，代替任务卡写的「先读组合根」；根上五个私有方法（`_clearUnread` / `_markDone` / `_saveIndex` / `_stampPromptSent` / `agentRefOf`）因此提前转公有。
7. headless 的 `report['lastError']`（异常收尾时那一份）改读 `session.lastError`，记 BACKLOG（做壳级聚合时一并改）。
8. 行数门对 `headless_run.dart`（1186 行，本轮只改引用路径）单独放宽到 1300，记 BACKLOG。
9. `flutter test` 全量是 319 不是任务卡写的 294（起草时的旧数字）。
10. 私有具名初始化形参（`required this._cwd`，Dart 3.10+）：analyzer 对 `: _x = x` 的写法报 `prefer_initializing_formals`，为了不给基线的 14 条 info 添新条目改用了这种写法，仓库里首次出现。

### 第 9 步：阶段 B 先量后动（探针 `debugOnRebuildDirtyWidget` 数 `AppShell` 的 build，临时测试不入库）

探针（临时的 `test/app/phase_b_probe_test.dart`，用框架的 `debugOnRebuildDirtyWidget` 钩子数 `AppShell` 元素的 rebuild，不改 `lib/ui`；`flutter test` = flutter_tester **debug** 口径，绝对时间只能看量级）：

| 场景 | 根通知次数 | 壳级 build 次数 | 耗时 |
|---|---|---|---|
| A：290 条 `agent_message_chunk` 挂在 batcher 里一次放行（`session/load` 重放的形状） | 1 | **1**（首帧 1，之后 5 帧 0） | 首帧 229 ms（含 290 条转录的首次构建），6 帧共 1137 ms |
| B：40 条分块逐帧到达（fake-agent 流式输出的形状） | 40 | **40**（每帧 1） | 1491 ms，约 37 ms / 帧 |

裁定门第 4 项的阈值：「一次 `session/update` batch 触发的壳级 build > 1 次且 290 行重放的总 build 耗时 > 一帧（16 ms）」。次数正好是 1（一帧一次，batcher 已经把 batch 内的通知合并成一次），第一个条件不成立，**不动区域订阅**；数字与建议记 `rounds/BACKLOG.md`（流式输出时每帧一次整壳重建的 37 ms 是 debug 测试机口径，release 真机要另量）。验收 10 不适用。

### 验收 8：Windows 真跑（规则 9）——待所有者点跑

`scripts/build.ps1 -Smoke`：过（第 8 步的 release 构建，`ACP_SMOKE_REPORT` + 隔离的 `APPDATA`，exit 0：init / ping / core_ready 三步 ok，coreVersion 1.1.0，droppedEvents 0）；合并 main@7c9c592 后的构建（`4e17300`）再跑一次：过（`ok: true`，exit 0，coreVersion 1.2.0，droppedEvents 0）

dsh-acp-interactive 与 claude-agent-acp 各一轮的命令（用真实数据目录、真实 agent；在 worktree 根跑，先 `scripts/build.ps1`）：

```powershell
# dsh：新建 → 发消息（带权限）→ 第二轮 2 s 后停止 → 新建分支再切回 → 杀进程后重载 → 文件面板 Follow → 本地终端
$env:ACP_R3_REPORT="build\r75-dsh.json"; $env:ACP_R3_AGENT="dsh-acp-interactive"; $env:ACP_R3_CWD="<一个 git 项目目录>"
$env:ACP_R3_PROMPT="读一下 README.md 的第一行，然后把它复述给我"; $env:ACP_R3_PROMPT2="把 README.md 每一行都解释一遍"
$env:ACP_R3_CANCEL_AFTER="4"; $env:ACP_R3_NEW_BRANCH="r75-dsh"; $env:ACP_R3_KILL="1"; $env:ACP_R4_FILES="1"; $env:ACP_R4_FOLLOW="1"; $env:ACP_R4_LOCAL_SHELL="1"
$p = Start-Process build\windows\x64\runner\Release\acp_agent_client.exe -PassThru -WindowStyle Hidden; $p.WaitForExit(); $p.ExitCode
# claude-agent-acp：R6 的会话生命周期（新建 → 一轮 → list 校对 → 重载 → 重连 + load 重放 → 第二轮 → close → resume → delete）
$env:ACP_R6_REPORT="build\r75-claude.json"; $env:ACP_R6_AGENT="claude-agent-acp"; $env:ACP_R6_CWD="<同一个目录>"
$env:ACP_R6_PROMPT="用 Read 工具读 README.md 的第一行"; $env:ACP_R6_PROMPT2="2+2 等于几"; $env:ACP_R6_RELOAD="1"; $env:ACP_R6_CLOSE="1"; $env:ACP_R6_RESUME="1"; $env:ACP_R6_DELETE="1"
$p = Start-Process build\windows\x64\runner\Release\acp_agent_client.exe -PassThru -WindowStyle Hidden; $p.WaitForExit(); $p.ExitCode
```

跑之前按记忆里的两条：`ls ~/.claude | grep oauth` 有过期锁先挪开；每次跑前后 `Get-Process acp_agent_client` 看有没有残留实例。
认证页开合、registry 面板、设置面板三项无头口子覆盖不到（R5 的 `ACP_R5_REPORT` 只对 fake-agent 跑过），归验收 9 手测。

### 验收 9：所有者手测清单（弹层锚点搬家后的画板 40 / 41 / 42 / 43 / 25 / 05 / 06）

用 `D:\tools\AcpAgentClient` 那份 release 替换前先在 worktree 里 `scripts/build.ps1` 构建；逐项看：
1. 画板 41：线程头 `+` 的「新建会话 · 选 agent」弹层位置（右对齐）、Esc / 点外面关；项目切换器（顶栏项目名）与分支切换器的位置、搜索框可输入、选中后关。
2. 画板 41 / 04：侧栏删除图标 → 确认弹层位置；取消 / 点外面 / 删除三条路；线程头铅笔与侧栏那支笔的改名输入框各自出现、Esc 撤销、Enter 提交。
3. 画板 40：输入框右下配置格的弹层（模型那格带搜索）、`+` 的四项、Follow 提示、用量弹层；每个弹层的 Esc、点外面关、封顶滚动。
4. 画板 42：`@` 菜单（裸 `@` 列根目录、有词搜索）与 `/` 菜单：上下键、Enter 填入、Esc 关、点输入框外关。
5. 画板 43：线程头 history 的时间线弹层开合、跳转到某条用户气泡的聚焦态、再点别处撤。
6. 画板 25：权限卡的范围下拉（Overlay）与 Allow / Reject。
7. 画板 05：重载 agent 与新建会话的等待期（转录区变暗不可点、线程头 spinner），完成后入场；切会话的入场。
8. 画板 06：一条会话跑着时切到另一条，侧栏原来那条出扫掠亮点线；跑完出绿点；切回去绿点撤；从流量页回工作台绿点撤。
9. 画板 52 / 50 / 70 / 60 / 61：认证页从三个入口进入与取消；registry 面板搜索 / 过滤 / 安装 / 卸载；设置面板编辑 custom 条目并保存、从 Zed 导入；文件面板 Go to File；本地终端开 / 停 / 重启 / 关。
10. 关窗：agent 进程与本地 shell 全部回收（任务管理器里没有残留的 node / pwsh）。

### 验收对照

| # | 检查 | 结果 |
|---|---|---|
| 1 | 契约与画板零 diff | 过（`--stat` 输出 0 行，`pins/upstream.json` 一并核过；合并 main@7c9c592 后对 main 重核仍为空） |
| 2 | validate 全绿 | 过（每步 13 项；第 9 步起 15 项；合并 main 后 15 项 PASS，`flutter test` 334） |
| 3 | 测试只改路径 | 过（186 例 / 798 处 `expect(` 不变；合并 main 后 201 / 886，与 main 相同） |
| 4 | 无头实跑等价 | 过（每步三份 EQUIVALENT；两次偶发重跑等价；合并 main 后对 main@7c9c592 的构建三份 EQUIVALENT） |
| 5 | 行数门 | 过（组合根 356 ≤ 450；`headless_run.dart` 单独放宽，见偏离 8） |
| 6 | 依赖方向门 | 过（见上表；validate 门守着） |
| 7 | 通知等价（阶段 A） | 过（`test/ui` 全过；构造时转发七个 notifier，`sessions` / `files` / `terminals` 仍在 `start()` 里挂） |
| 8 | Windows 真跑 | **待所有者点跑**（命令见上；smoke：过（第 8 步的 release 构建，`ACP_SMOKE_REPORT` + 隔离的 `APPDATA`，exit 0：init / ping / core_ready 三步 ok，coreVersion 1.1.0，droppedEvents 0）；合并 main@7c9c592 后的构建再跑一次：过，coreVersion 1.2.0，droppedEvents 0） |
| 9 | 所有者手测 | **待所有者**（清单见上） |
| 10 | 阶段 B | 不触发（一次 batch 的壳级 build = 1，未超过阈值）；数字记 BACKLOG，验收 10 不适用 |

### main 的后续提交与合并（2026-09-20，所有者指示「在本分支把 main 合进来解冲突」）

本轮开工基线 `f62520f` 之后 main 进了 11 个提交，三件事：`44d256d`「UI 与前端代码语义统一：Thread 收敛为 Session」（碰组合根 62 行、screen 32 行、headless 6 行与 12 个测试文件，全是改名与文案；提交说明标「未构建 / 未审查（所有者指定）」）、画板 07 深色模式那一轮（`1420556` 合入 main，4 轮 cursor 审查收口；`lib/app/font_prefs.dart` → `appearance_prefs.dart`、`FontPrefsController` → `AppearanceController`，screen 的构造参数 `fonts` → `appearance`、侧栏多了 `dark` / `onToggleTheme` 两个参数）、`7c9c592` v1.2.0 版本号。先前那份只对 `44d256d` 备用的解冲突脚本已删，换成实际用的这份。

合法（脚本 `rounds/round-7.5/merge-main-7c9c592.py`，随本轮入库）：`git merge --no-ff --no-commit main` 出 6 个文件的冲突——组合根 5 块（main 改了注释 / 名字的那几段本分支已经搬走，本分支侧全是空或一行）、screen 7 块、headless 2 块、`workbench_wiring_test` 3 块、ROUNDS.md 1 块、BACKLOG.md 1 块。每个冲突块取本分支这一侧再重放 main 的改名（`threadTitle → sessionTitle`、`threadMenuAnchor → sessionMenuAnchor`、`ThreadHeader → SessionHeader`、`NewThreadEmpty → NewSessionEmpty`、`_openThreadMenu → _openSessionMenu`、`_addThread → _addSession`、`acp-thread: → acp-session:`、默认标题 `New <agent> Thread → Session`、`+` 的 `Threads → Sessions`、注释「线程头 / 线程区 / 线程标题」→「会话头 / 会话区 / 会话标题」、`font_prefs → appearance_prefs`），改名同时施加到本轮拆出的九个文件与本轮改过的测试——搬走的代码在 main 那边改了名，git 合不到新文件上（七个文件有改动：`session_controller` 的 `sessionTitle` / `sessionMenuAnchor` 与注释，`turn_controller` / `agents_state` / `auth_state` / `workspace_state` / `session_index` / `guarded` 只有注释）。深色模式对 screen 的四处改动不在冲突块里，git 自动合上（核对过 `import 'appearance_prefs.dart'`、`AppearanceController? appearance`、`onToggleTheme`、`appearance: widget.appearance` 四处都在）。ROUNDS.md 两行都留（main 的「Thread → Session 收敛」行在前）；BACKLOG 以本分支的 17 行为准换成 main 的措辞（它们的「新家」后缀保留），再补 main 新增的「设计稿补注记（Thread → Session 收敛）」一条。`CLAUDE.md` 仓库结构那一行的 `font_prefs` 改 `appearance_prefs`。

核对（都对 main@7c9c592）：
- 解完之后 `lib/app` + `test` 里不再有 `ThreadHeader` / `threadTitle` / `threadMenuAnchor` / `NewThreadEmpty` / `thread_header` / `acp-thread:` / 「线程头 / 线程区 / 线程标题」/ `font_prefs` / `FontPrefsController`；只剩本轮自己的 `SessionController` / `session_controller.dart` / 注释里的「会话控制器」（见下）。
- 逐词比对 screen / headless / wiring 测试与 main 的差异（difflib 按行配对再按 token 配对）：256 / 219 / 89 处替换全部是接收者路径（`c.` → `c.session.` 等）与附录 A 的改名（`installAgent → agents.install`、`authPhase → auth.phase` 等），0 行只删、1 行只增（screen 多一个 `import 'shell_state.dart';`）——main 的每一处改动都在。
- 验收 1：`git diff main -- lib/ui lib/theme lib/projection lib/bridge rust test/fixtures pubspec.yaml pins` 为空。
- 验收 3：`test/app` + `test/ui` 用例 201 / `expect(` 886，与 main 相同（main 那几轮加了主题切换与外观的用例，所以比开工时的 186 / 798 多）；`git diff main -- test` 的 `expect(` 行 `-` 191 / `+` 191。
- `flutter analyze`：0 error / 0 warning / 14 info（与基线同一批）。
- validate：15 项 PASS（`flutter test` 334，与 main 相同；cargo test 全过、clippy 干净；两道门 PASS）
- 验收 4（无头等价）：基线换成 main@7c9c592——拿所有者 15:08 在 `AcpAgentClient-release` worktree（工作树干净、HEAD 就是 `7c9c592`、`app.so` / `acp_bridge.dll` 都晚于该提交）出的 release 构建，整个 `Release/` 复制到 `D:\cargo-target\AcpAgentClient\r75\main-bin` 跑，只删掉旁边的 `zed-agent-acp.exe`（核心见到它会多并一条内置 agent 条目，本分支的构建目录里没有它）。新基线与旧基线 `f62520f` 的差异只有 `threadTitle → sessionTitle` 这个键与 `New Fake Agent Thread → Session` 这个标题（r3 2 处、r6 3 处、r5 零差异），说明 main 这 11 个提交在这三条路径上除改名外行为没变。合并后的构建（`scripts/build.ps1`）对新基线：r5 / r6 **EQUIVALENT**；r3 第一次只在 `steps.files.error` 差一处（main 与之前 15 次跑都是 `fs: not found …fake-agent.txt`，这次是 null）——这是 Follow 开着时 `tool_call` 的 `locations` 先于 agent 的 `fs/write_text_file` 到达、文件面板先去开一个还没写出来的文件的竞态，`FilesState._guard` 记下的错误不会被之后的成功清掉，所以竞态哪边赢就报哪个；同一二进制重跑 r3 **EQUIVALENT**，与前两次偶发同类（取样时序，不是行为差异）。新基线三份存在 `rounds/round-7.5/baseline/main-7c9c592/`（合并后那三份与重跑的一份在 `D:\cargo-target\AcpAgentClient\r75\reports\merged{,-b}\`，不入库）
- 第 3 轮审查（`fd5b7a9..HEAD`，含 main 带进来的改动与本次解冲突）：2026-09-20 15:23 → 15:28（5 分钟），产物 `.claude/reviews/20260920-152350-review.out.md`：**0 findings**。审查器核了：① `44d256d` 的符号表在 `lib/app` 与 `test/` 里旧名全部不存在，并逐个列了落地处（`session_controller` 的 `sessionTitle` / `sessionMenuAnchor` / 默认标题、`turn_controller` 的 Sessions 与 `saveIndex`、screen 的 `SessionHeader` / `NewSessionEmpty` / `_openSessionMenu` / `_addSession` / `acp-session:`、headless 的 JSON 键、wiring 测试的断言、五个文件的注释）；② `lib/ui` / `lib/theme` / `appearance_prefs.dart` / `app.dart` / `rust/settings` / 两个外观测试相对 `7c9c592` 零 diff，screen 相对 main 只有成员路径前缀、画板 07 的三处接线都在；③ 行数门（组合根 356、thread 848、screen 950、headless 1186）与依赖方向门仍成立、没有子对象 import 组合根；另核了版本号、无新依赖、pins 未动、`unsafe_code = deny`、`set_appearance` 仍整段替换、无冲突标记残留。`ThreadController` 按任务书保留、未替所有者决定（随后所有者裁定改名 `SessionController`，见下「命名收敛」）。未跟踪的基线目录 `rounds/round-7.5/baseline/main-7c9c592/` 不在 git 范围内（随本次回填入库）。无整改。

合并提交 4e17300。**已裁定（2026-09-20）**：原 `ThreadController` / `c.thread` / `thread_controller.dart` 改成 `SessionController` / `c.session` / `session_controller.dart`，单独一个提交，见下「命名收敛」段。

### 第二次合并 main（2026-09-20，所有者：「main 上现在又有两个提交，请在分支上合并进你来，并由你自己 review 一下」）

main@32d372f 相对 `7c9c592` 多 3 个提交：`0fd4fcb` markdown 渲染器认行内 HTML 的 `<br>`（`HtmlLineBreakSyntax`，4 条测试）、`0c95a84` 深色下 agent 图标与应用标记看不见（`SvgTint.mark` 给外来 SVG 的 `currentColor` 一个随主题走的取值；`AppLogo` 去 const）、`32d372f` 合并提交；两个提交都标「未构建 / 未审查（所有者指定）」。碰的文件全在 `lib/theme` / `lib/ui` / `test/ui` 与两份文档，与本轮的 `lib/app` 零重叠；`git merge --no-ff --no-commit main` 自动合上（ROUNDS.md / BACKLOG.md / `agent_logo_test.dart` 三个两边都改过的文件是 git 自己合的，核过两边条目都在），无手工改动。合并提交 `97ebfe8`。

核对（都对 main@32d372f）：`flutter analyze` 0 error / 0 warning / 14 info（同一批）；验收 1 零 diff 仍为空；验收 3 用例 207 / `expect(` 901 与 main 相同，`git diff main -- test` 的 `expect(` 行仍是 `-` 191 / `+` 191；validate 15 项 PASS（`flutter test` 340）；无头等价：这三个提交不碰 `lib/app` / `rust` / `lib/projection`，main@7c9c592 的基线仍是对的对照，合并后的构建（`scripts/build.ps1`）三份一次即 **EQUIVALENT**。

自审（第 4 轮；按所有者指示由本会话自己审、不走 cursor，范围 = main 这两个提交 + 合并本身）：
- 合并本身：无冲突、无手工改动，三个两边都改的文件核过。**0 条**。
- `0fd4fcb`（`<br>`）：`HtmlLineBreakSyntax` 排在 GFM 的 `InlineHtmlSyntax` 之前（InlineParser 取第一个匹配的），产出 `md.Element.empty('br')` 走渲染器原有的 `case 'br'`（`TextSpan('\n')`），表格单元格与段落两条路都有测试；行内代码里的 `<br>` 由 `CodeSyntax` 整段吃掉、不经过它（测试第 4 条守着）；`<br>` 落在单元格末尾会多一个空行，属边角、不算问题。**0 条**。
- `0c95a84`（深色 SVG 取色）：`SvgTheme(currentColor: Neutral.strong)` 按 build 现算，`SvgStringLoader` 的相等性含 theme、换主题后缓存不会串；`AppLogo` 去 const 的理由成立（`Element.updateChild` 见 `identical(old, new)` 直接复用旧 element、不 build）。**1 条 P3，机制不止 `AppLogo` 一处**：主题切换只靠 `app.dart` 的 `ListenableBuilder` 整树重建，`t.Theming.apply` 只换颜色表、不给树换 key，于是凡是 **`const` 构造**又在 build 里读颜色 token 的自写 widget，实例相同就被跳过、颜色冻在切换前那一套，直到那个 element 被重建。本会话用临时探针证实（`const ToneChip('x', tone: success)` 与非 const 的孪生放在同一个 `ListenableBuilder` 下，`Theming.apply(dark)` 后重建父级：非 const 那只变成 `d.successSoft`，const 那只仍是浅色值；探针跑完即删、不入库）。元素常驻的调用点：`registry_entry.dart` 7 处 `ToneChip` + 2 处 `_Diamond`、`settings_page.dart` 2 处 `ToneChip`、`tool_call_card.dart` 的 `ToneChip('Canceled')`、`elicitation_form_card.dart` 的 `ToneChip('Recommended')`、`card_chrome.dart` / `plan_card.dart` / `composer.dart` / `turn_state.dart` 的 `Chevron`、`files_panel.dart` 的 `FileViewerEmpty`；弹层里的 `MenuDivider` / `MenuGroupLabel` / `_TimelineEmpty` 每次打开都新建 element，实际看不出来。**不在本轮修**：`lib/ui` 是本轮零 diff 区（验收 1），且这是画板 07 那轮的遗留、不是这次合并引入的；记 `rounds/BACKLOG.md`，修法由所有者定（逐处去 const，与 `AppLogo` 同一做法；或换主题时给 `home` 换 `ValueKey(theme)` 整树重建，代价是滚动位置 / 焦点等瞬时态全丢）。

### 命名收敛：`SessionController`（2026-09-20，所有者裁定「跟 main 一样改成 Session」）

`ThreadController` → `SessionController`、`lib/app/thread_controller.dart` → `session_controller.dart`、组合根与 `TurnController` 上的字段 `thread` → `session`（screen / headless / 测试的接收者 `c.thread.` → `c.session.`），注释里的「线程控制器」→「会话控制器」；组合根 `onAuthenticated` 回调的参数 `session` 改名 `adopted`，免得遮住新字段。validate 的依赖方向门表跟着改键名。本文上面各处（步骤表、附录 A / B、偏离、审查段）的 `ThreadController` / `c.thread` 已一并改成新名，历史提交说明里仍是旧名。纯机械替换，行为零变化（validate 15 项全绿、`flutter test` 340、三份无头报告与 main@7c9c592 基线等价）；提交 `2404956`。所有者指示「只是改方法名的代码不要审核」，这一个提交不发审查，合入 main 前的最后一轮审查仍是第 4 轮。

### 合入 main（2026-09-20）

所有者指示「连同 R7.5 一并合并到 main 上，然后发布 1.3.0」：分支 `claude/r7-5-composition-root-refactor-7600bf`（末提交 `05eed96`）以 `--no-ff` 合入 main，合并提交 `05a2e4a`，无冲突；随后 `6b016bb` 抬三处版本号到 1.3.0 并记 README 发布行。发布与本地安装版的更新记录见任务卡末尾与记忆 `daily-release-install`。
