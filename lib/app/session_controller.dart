// 当前会话与会话生命周期（R7.5 从 workbench_controller.dart 拆出）：当前 agent / 会话与派生态（画板 01 的两个空态、
// 会话头标题、输入框可用性、画板 34 的状态条）、agent 能力（R6）、侧栏列表与搜索（画板 04）、画板 06 的活动指示、
// 新建 / 重载 / 点选 / `session/load` / resume / close / delete / `session/list` 校对（R6）、改名与删除确认（画板 41）、
// 本地索引的写回。协议状态仍在 `lib/projection/`（规则 2），这里只是「唯一知道桥的人」里管会话的那一段。
// 会话挂在哪条 agent 连接上（四态、挂回、`session/load`、关闭态）在混入的 `session_attach.dart`（iteration-07 拆出）。
//
// 依赖方向（任务卡附录 B）：读本地索引走 [index]、已装 agent 与 registry 走 [agents]、当前项目走 [workspace]；
// 反向的四件事（切回工作台页、判断是否在工作台页、右栏切到 Agents 标签、进认证页）由组合根经回调接线。
//
// 不做 agent 特判（规则 2）：agent 名一律来自 settings.json 的键或 `initialize` 的 `agentInfo`。

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../projection/agent_state.dart';
import '../projection/batcher.dart';
import '../projection/pending.dart';
import '../projection/session_store.dart';
import '../projection/wire.dart';
import '../ui/popovers/topbar_popovers.dart';
import '../ui/shell/popover_anchor.dart';
import '../ui/shell/sidebar.dart';
import 'agents_state.dart';
import 'core_bridge.dart';
import 'guarded.dart';
import 'session_attach.dart';
import 'session_index.dart';
import 'workspace_state.dart';

class SessionController extends ChangeNotifier with GuardedNotifier, SessionAttachment {
  SessionController({
    required this.bridge,
    required this.sessions,
    required this.batcher,
    required this.index,
    required this.agents,
    required this.workspace,
    required this._showWorkbench,
    required this._isWorkbenchPage,
    required this._openAgentsTab,
    required this._openAuth,
  });

  @override
  final CoreCommands? bridge;

  // ---- 投影层（组合根持有）
  @override
  final Sessions sessions;
  @override
  final UpdateBatcher batcher;

  // ---- 同级对象（组合根持有）
  final SessionIndex index;
  final AgentsState agents;
  @override
  final WorkspaceState workspace;

  /// 主区切回工作台页（只换页不通知；本对象随后的 `touch` 会带上）。
  final void Function() _showWorkbench;

  /// 主区现在是不是工作台页（画板 06 的「正在看着」判据）。
  final bool Function() _isWorkbenchPage;

  /// 右栏切到 Agents 标签（npx 型 agent 缺 Node 时的受管 Node 提示卡，画板 51）。
  final void Function() _openAgentsTab;

  /// `session/new` 回 `-32000`：进认证页（画板 52），成功后自动重试这个 cwd 的新会话。
  final Future<void> Function(String agent, String cwd) _openAuth;

  // ---- 本地态（协议之外）
  List<SidebarSession> sidebarSessions = const <SidebarSession>[];
  String? agentId;
  @override
  String? sessionId;

  /// 中栏内容整块换过几次（画板 05 A 组的入场触发器）。切会话、新建会话、重载完成各 +1。
  /// 不能只看 `sessionId`：重载 agent 若 `session/load` 回的是同一条，id 没变但内容确实整块换了。
  @override
  int sessionEpoch = 0;

  /// 正在等 agent 把会话换过来（画板 05 B 组的等待期）：转录区降到 `opacity.pending` 且不可交互，
  /// 会话头借用 `isRunning` 那只 spinner。两个触发共用同一套 —— 重载 agent（[reloadAgent]：断开 → 重连
  /// → `session/load`）与新建会话（[newSession]：拉进程 → `initialize` → `session/new`，含 `send()`
  /// 现开一条那条路）。画板 05 B 组只画了 reload 图标那个触发，但两者都是「时长不可预知的整块替换」，
  /// 等待期的规格一字不差地套用；新建会话那条是所有者手测报回来的（2026-09-18：选完 agent
  /// 到会话出来这几秒界面一动不动，像卡住了）。发送前把会话挂回来（`reattach`，iteration-07）也用这一套。
  @override
  bool waitingForAgent = false;
  final Map<String, String> _sessionAgent = <String, String>{}; // sessionId → agentId

  @override
  String? registeredOwner(String sessionId) => _sessionAgent[sessionId];

  @override
  void registerOwner(String sessionId, String agent) => _sessionAgent[sessionId] = agent;

  // ---- UI 态
  String search = '';
  String? renamingSessionId;

  /// 改名的输入框落在哪一处：会话头的铅笔就在会话头上改（画板 01 的标题位），侧栏那支笔改侧栏那一行。
  /// 两处共用 [rename] / [renameFocus]，靠这个标记分流，同一时刻只可能有一个输入框在树上。
  bool renamingInHeader = false;
  String? confirmingDeleteId;

  // ---- 输入控件
  final TextEditingController sidebarSearch = TextEditingController();
  final FocusNode sidebarSearchFocus = FocusNode();
  final TextEditingController rename = TextEditingController();
  final FocusNode renameFocus = FocusNode();

  // ---- 弹层锚点（画板 41 / 43）
  final PopoverHandle newSessionAnchor = PopoverHandle();
  final PopoverHandle sessionMenuAnchor = PopoverHandle();

  /// 画板 43：会话头 history 的会话时间线弹层。
  final PopoverHandle timelineAnchor = PopoverHandle();
  final PopoverHandle deleteAnchor = PopoverHandle();

  @override
  void dispose() {
    for (final c in <TextEditingController>[sidebarSearch, rename]) {
      c.dispose();
    }
    for (final f in <FocusNode>[sidebarSearchFocus, renameFocus]) {
      f.dispose();
    }
    for (final h in <PopoverHandle>[newSessionAnchor, sessionMenuAnchor, timelineAnchor, deleteAnchor]) {
      h.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------- 派生

  SessionStore? get store => sessionId == null ? null : sessions.maybe(sessionId!);
  AgentConnection? get connection => agentId == null ? null : sessions.agents[agentId!];

  /// 选中了一个 agent（**不要求**已经开着会话、也不要求进程已拉起）：画板 01 的两个空态按它分流，
  /// 状态 2「还没有已安装的 agent」只在一个都没装时出现。启动时 [ensureAgentSelected] 会挑一个，
  /// 会话要到第一条消息才现开（一轮对话控制器的 `send`），免得每次开应用都去拉一个 agent 进程。
  bool get hasAgent => agentId != null;

  /// 已经有一条会话在手：会话头的重命名 / 重载与 ≡ 菜单的三个动作要它。
  bool get hasSession => agentId != null && sessionId != null;
  bool get isRunning => store?.isRunning ?? false;

  String get agentDisplayName => agentDisplayNameOf(agentId);

  /// 某个 agent 的展示名。当前 agent 之外也要取：写索引时占位标题按**那条会话自己的** agent 算（见 [saveIndex]）。
  /// 还没连上时退回已安装列表里的展示名（settings 条目的 `name` 或 registry 的展示名），
  /// 不退回 id：启动后的新会话标题写 `New Codex Session` 而不是 `New codex Session`。
  String agentDisplayNameOf(String? id) {
    final c = id == null ? null : sessions.agents[id];
    return c?.agentTitle ?? c?.agentName ?? agents.installedRef(id)?.name ?? id ?? 'Agent';
  }

  /// 这条会话还没有标题时的占位串。
  String placeholderTitleOf(String? agent) => 'New ${agentDisplayNameOf(agent)} Session';

  /// 与 [SessionIndex.upsert] 同一条三级退回 `store → 索引 → 占位串`：`session/load` 不重放 `session_info`，
  /// 载回来的会话 `store.title` 是 null、标题只在本地索引里还留着，不退回它的话会话头也只显示占位串
  /// （BACKLOG「载回来的会话下一轮之后丢标题」的另一半）。没有 sessionId 的「真的新会话」查不到条目，照旧是占位串。
  String get sessionTitle {
    if (!hasAgent) return 'No Agent';
    final id = sessionId;
    return store?.title ?? (id == null ? null : index.titleOf(id)) ?? placeholderTitleOf(agentId);
  }

  String get composerPlaceholder {
    if (!hasAgent) return '安装并选择一个 agent 后即可输入';
    // 挂不回的会话（iteration-07）：发送只能照 R3 新开一条，先说清楚，别让它静默顶掉选中的这条。
    final unattachable = hasSession && !sessionClosed && attachOf(sessionId) == SessionAttach.unattachable;
    // 会话是发第一条消息时才开的，cwd 从当前项目来：没项目就先说清楚，别让发送静默失败。
    if ((!hasSession || unattachable) && workspace.project == null) return '先选一个项目目录，新会话的 cwd 从它来';
    if (unattachable) return '这条会话在当前连接上无法继续，发送会新开一条';
    return 'Message to $agentDisplayName , @ to include context , / for commands';
  }

  /// 输入框可用：选了 agent、没项目也没会话时不可用（发不出去），已关掉的会话只读。
  bool get canCompose => hasAgent && !sessionClosed && (hasSession || workspace.project != null);

  /// 侧栏按搜索过滤后的会话（标题子串，大小写不敏感）。
  List<SidebarSession> get visibleSessions {
    if (search.isEmpty) return sidebarSessions;
    final q = search.toLowerCase();
    return <SidebarSession>[
      for (final s in sidebarSessions)
        if (s.title.toLowerCase().contains(q)) s,
    ];
  }

  /// 会话头的 agent 标记。
  String? get agentIconSvg => agents.iconSvgOf(agentId);

  /// 画板 34 要显示的连接状态条：initialized 与 none 不出条（那是常态，不是告警）。
  bool get showAgentStateBar {
    final state = connection?.state;
    return state != null && state != AgentLifecycle.none && state != AgentLifecycle.initialized;
  }

  int get droppedUpdates => connection?.droppedUpdates ?? 0;

  // ---------------------------------------------------------------- 画板 06：侧栏会话活动指示

  /// 跑完了、还没被看过的会话（画板 06 B 的绿点）。纯客户端本地态，不落盘、不进协议。
  final Set<String> _unreadDone = <String>{};

  /// 画板 06 A：有在途 prompt 的会话（出扫掠亮点线）。只有内存里有投影的会话才可能在跑，
  /// 所以直接从会话表算，不另记一份（少一处要对齐的状态）。
  Set<String> get runningSessionIds => <String>{
        for (final s in sessions.all)
          if (s.isRunning) s.sessionId,
      };

  /// 画板 06 B：完成未读的会话。
  Set<String> get unreadSessionIds => _unreadDone;

  // ---------------------------------------------------------------- 画板 08 C：跨工作区在跑数

  /// 按工作区分组的在跑会话数。键是归一化后的 cwd（同 [WorkspaceState.normalizeCwd]，
  /// 同一目录的两种写法不能被判成两个工作区）。
  ///
  /// 数据源与画板 06 的扫掠线是同一个：内存里的会话表。**换项目不关会话**（见 [enterWorkspace]
  /// 的注释：放下不等于关掉），所以之前打开过的工作区里还在跑的会话仍然在这张表里，
  /// 不必去后台探活。本次运行从没打开过的工作区自然一条都没有。
  Map<String, int> get runningByWorkspace {
    final out = <String, int>{};
    for (final s in sessions.all) {
      final String? cwd = s.cwd;
      if (!s.isRunning || cwd == null || cwd.isEmpty) continue;
      final key = WorkspaceState.normalizeCwd(cwd);
      out[key] = (out[key] ?? 0) + 1;
    }
    return out;
  }

  /// 触发钮上的合计：所有工作区（含当前）。**没记 cwd 的在跑会话也算进来**——它确实在跑，
  /// 只是归不到某一行上，漏掉它就不再是「别处还有多少在跑」的真数。
  int get runningTotal => runningSessionIds.length;

  /// 有在跑会话的工作区个数（触发钮 tooltip 的第二个数）。
  int get runningWorkspaceCount => runningByWorkspace.length;

  /// 回合结束时点亮绿点（画板 06 D 表）：`stopReason` 是 cancelled / refusal 的不点，失败收轮（没有 `stopReason`）
  /// 的也不点 —— 取消与出错侧栏一律不表达，错误只在转录区（画板 31 / 34）。
  ///
  /// 「正在看着的那条」不点：它当场就满足画板 06 的清除条件。**偏离**：画板写的是「切入该会话，或它已是当前会话
  /// 且窗口聚焦」，这里没有窗口聚焦这一维（宿主没给这个信号），按「当前会话 + 停在工作台页」判。
  void markDone(String id, String? stopReason) {
    if (stopReason == null || stopReason == 'cancelled' || stopReason == 'refusal') return;
    if (_isViewing(id)) return;
    _unreadDone.add(id);
  }

  bool _isViewing(String id) => _isWorkbenchPage() && sessionId == id;

  /// 该会话被查看 / 被删 / 又开了新一轮：绿点撤掉（运行中与绿点严格互斥）。
  void clearUnread(String id) => _unreadDone.remove(id);

  // ---------------------------------------------------------------- 当前 agent 与侧栏投影

  /// 当前 agent 还没定（启动、或刚把选中的那个卸掉）时挑一个：本地索引里最近用过、且**还装着**的那个，
  /// 没有就第一个已安装的；一个都没装就留空（画板 01 状态 2）。
  /// 只挑不连——agent 进程等到第一条消息才拉起（一轮对话控制器的 `send`），所以开应用不会白拉一个进程、也不会在启动时弹认证。
  /// 已装列表每次刷新完都会调到这里（组合根接的 `AgentsState.onInstalledChanged`）。
  void ensureAgentSelected() {
    // 会话开着的时候当前 agent 归那条会话，列表刷新一概不许动它：`session/new` 之后那一发
    // `registry_list` / `agent_settings_get` 只要慢一步或回了空，就会把正在用的 agent 抹掉
    // （会话头回到 No Agent、发送打不出去）。卸载走 `AgentsState.remove`，它自己会先清干净再刷。
    if (sessionId != null) return;
    final installed = <String>{for (final a in agents.installed) a.id};
    final current = agentId;
    if (current != null && installed.contains(current)) return; // 已经选好且还装着：不动它
    agentId = index.lastUsedAgentId(installed) ?? (agents.installed.isEmpty ? null : agents.installed.first.id);
  }

  /// 已安装列表里的这一条，不在列表里就按 id 造一条（`send` 现开会话时给 [newSession] 用）。
  AgentRef agentRefOf(String id) => agents.installedRef(id) ?? AgentRef(id: id, name: id);

  /// 卸载了这个 agent：正在用它就放下（`AgentsState.remove` 里那一步）。
  void dropAgent(String id) {
    if (agentId == id) {
      agentId = null;
      sessionId = null;
    }
  }

  /// 本地索引变了 / registry 变了（图标）：侧栏项重投影一次。不通知，调用方收尾时 `touch`。
  void refreshSidebar() {
    sidebarSessions = _toSidebar(index.entries);
  }

  /// 把 `sessions.json` 的一条映射成侧栏项，**顺带把 agentId 记进 [_sessionAgent]**：
  /// 重启后点侧栏 / 改名 / 删除都要用 (agentId, sessionId) 这一对键，只靠 `newSession` 时写入
  /// 会让重启后的删除按空 agentId 去匹配、删不掉（审查 finding P2，2026-09-15）。
  /// **只留当前 workspace 的**：cwd 是当前项目目录的才进侧栏，换项目时 [enterWorkspace] 重投影一次，
  /// 别的目录下的会话就不再露出来（所有者报障 2026-09-18）。agentId 的登记在过滤之前，
  /// 不在侧栏里的会话（比如刚从会话区放下的那条）之后要删 / 要载还得靠它。
  List<SidebarSession> _toSidebar(Object? raw) {
    final out = <SidebarSession>[];
    if (raw is! List) return out;
    for (final item in raw) {
      if (item is! Map) continue;
      final sessionId = item['sessionId'] as String? ?? '';
      if (sessionId.isEmpty) continue;
      final owner = item['agentId'] as String?;
      if (owner != null && owner.isNotEmpty) _sessionAgent[sessionId] = owner;
      final cwd = item['cwd'];
      if (!workspace.inCurrentWorkspace(cwd is String ? cwd : null)) continue;
      out.add(SidebarSession(
        id: sessionId,
        title: item['title'] as String? ?? sessionId,
        updatedAt: DateTime.fromMillisecondsSinceEpoch((item['updatedAt'] as num?)?.toInt() ?? 0),
        messageCount: (item['messageCount'] as num?)?.toInt() ?? 0,
        canDelete: true,
        iconSvg: agents.iconSvgOf(owner ?? agentId),
      ));
    }
    return out;
  }

  /// 换了项目：侧栏只留这个目录下的会话（[_toSidebar] 按当前项目过滤）；正开着的会话若属于别的目录，
  /// 就从会话区放下（回到画板 01 的空态，下一条消息在新目录里现开会话）——不然顶栏写着新项目、
  /// 消息却发进旧目录的会话，侧栏里还找不到它。放下不等于关掉：它在 agent 侧照跑，切回那个目录再点回来。
  /// 同一个目录换种写法（分隔符 / 尾斜杠）不算换项目，会话不动。组合根接的 `WorkspaceState.onProjectChanged`。
  void enterWorkspace() {
    refreshSidebar();
    // 正在改名的那条（侧栏行或会话头）若不属于这个 workspace，它的输入框随行一起没了，`renamingSessionId`
    // 不能悬着：切回来时那行会直接以改名态出现、带着上次没提交的文本（合并复审 2026-09-18）。
    final renaming = renamingSessionId;
    if (renaming != null && !workspace.inCurrentWorkspace(cwdOf(renaming))) cancelRename();
    final id = sessionId;
    if (id == null || workspace.inCurrentWorkspace(cwdOf(id))) return;
    sessionId = null;
    sessionEpoch++;
  }

  void setSearch(String value) {
    search = value;
    touch();
  }

  void clearSearch() {
    sidebarSearch.clear();
    search = '';
    touch();
  }

  // ---- agent 能力（R6）：一律读 `agentCapabilities`，不按 agent 名判（规则 2）。
  // 能力是 agent 级的，不是会话级的——侧栏里各条会话可能属于不同 agent，所以按 agentId 查。

  @override
  JsonMap? capsOf(String? agent) => agent == null ? null : sessions.agents[agent]?.agentCapabilities;

  @override
  JsonMap sessionCapsOf(String? agent) {
    final caps = capsOf(agent)?['sessionCapabilities'];
    return caps is Map ? caps.cast<String, dynamic>() : const <String, dynamic>{};
  }

  JsonMap get _sessionCaps => sessionCapsOf(agentId);

  /// `agentCapabilities.loadSession`：重开后能不能把历史重放回来。
  @override
  bool canLoadSessionOf(String? agent) => capsOf(agent)?['loadSession'] == true;

  bool get canLoadSession => canLoadSessionOf(agentId);
  bool get canListSessions => _sessionCaps.containsKey('list');

  /// `promptCapabilities.image`：prompt 里能不能带 `image` 块。管住 `+` 的 Image 一项（画板 40）与 Ctrl+V 粘贴。
  /// **能力未知**（这个 agent 本次运行还没连过——选了一条老会话、第一条消息还没发出去就是这个状态）时
  /// 照给，与侧栏删除图标同口径：严判的话那会儿粘贴会静默失灵，而多带一个 `image` 块最坏是被 agent
  /// 拒掉一条 prompt。连上之后按它自己声明的来。
  bool get canPromptImage {
    final caps = capsOf(agentId);
    if (caps == null) return true;
    final prompt = caps['promptCapabilities'];
    return prompt is Map && prompt['image'] == true;
  }

  /// ≡ 菜单的三个动作（画板 41）：无能力整行不渲染。
  /// Resume 与 Close 还要看会话是不是还「活着」——实测 dsh-acp-interactive 1.3.0 对活着的会话回
  /// `-32602 session is already active in this ACP connection`（2026-09-16）：`session/resume` 是给**没在本连接上活着**的
  /// 会话重新挂上下文用的，所以只在 `session/close` 之后给；反过来 Close 只对还活着的给（`sessionClosed` 在 `session_attach.dart`）。
  bool get canResumeSession => hasSession && sessionClosed && _sessionCaps.containsKey('resume');
  bool get canCloseSession => hasSession && !sessionClosed && _sessionCaps.containsKey('close');
  bool get canDeleteSession => hasSession && _sessionCaps.containsKey('delete');

  // 侧栏删除图标（画板 04 注）**一律给**：它删的首先是本地索引这条记录，agent 侧删不删由
  // [deletesOnAgent] 单独判。按 `sessionCapabilities.delete` 裁剪过一版，结果是没声明 delete 的 agent
  // （实测 dsh-acp-interactive 1.3.0）的会话在侧栏里永远清不掉——本地记录是我们自己的，不该被 agent
  // 的能力声明锁住（所有者报障 2026-09-18）。见 [_toSidebar] 的 `canDelete: true`。

  // ---------------------------------------------------------------- 会话

  Future<void> newSession(AgentRef agent) async {
    hidePopover(newSessionAnchor);
    // 重入守卫（发布前审查 P2，2026-09-18）：等待期里会话头的 `+` 仍可点（`IgnorePointer` 只包住 `_body()`），
    // 再选一次 agent 会让两条 newSession 交叠：第二条存下的 `wasWaiting` 是 true，它后返回时把等待态永久留在 true
    // （转录区一直变暗不可点、会话头 spinner 不停、[reloadAgent] 永远被挡）；而且两条都走 [ensureConnected]，
    // 第二条的 `agent_connect` 会把第一条刚拉起的进程断掉——正是本轮要避免的那种误杀。`send()` 现开一条
    // 与 `+` 交错是同一回事。[reloadAgent] 的「没有旧会话」分支自己已经在等待期里，走不带守卫的 [_newSession]。
    if (waitingForAgent) return;
    await _newSession(agent);
  }

  Future<void> _newSession(AgentRef agent) async {
    final b = bridge;
    final cwd = workspace.project?.path;
    if (b == null || cwd == null) {
      lastError = cwd == null ? '先选一个项目目录，新会话的 cwd 从它来' : null;
      touch();
      return;
    }
    // 画板 05 B 组阶段 ①：先把等待态摆出来再发命令。拉起进程 + `initialize` + `session/new`
    // 要几百毫秒到数秒，这期间界面一动不动会被当成卡死（所有者手测 2026-09-18，与重载 agent 同一回事）。
    // 先存旧值再恢复：[reloadAgent] 的「没有旧会话」分支会调到这里，直接写 false 会把它的等待态提前收掉。
    final wasWaiting = waitingForAgent;
    waitingForAgent = true;
    touch();
    try {
      // 已经连着就别重连：`agent_connect` 会先断开旧连接，把这个 agent 上**所有**会话连着正在跑的那一轮
      // 一起杀掉。所有者报障 2026-09-18（dsh-acp-interactive）：一条会话跑着任务时新建另一条，
      // 跑着的那条当场中断，回头再给它发消息就撞 agent 的 `-32602 unknown session`——
      // 进程已经换了一个，旧 sessionId 在新进程里不存在。要换进程走会话头的「重载 agent」。
      await ensureConnected(agent.id, cwd);
      await createSession(agent.id, cwd);
    } on CoreCommandError catch (e) {
      await onConnectError(e, agent.id, cwd);
    } catch (e) {
      lastError = e.toString();
      debugPrint('[workbench] newSession: $e');
    } finally {
      waitingForAgent = wasWaiting;
      touch();
    }
  }

  /// 连 agent / 开会话失败的共用出口（新建会话与挂回 [reattach] 两条路同一口径）：原因写进 [lastError]，
  /// 认证与缺 Node 各自把去处安排好。挂回失败时一轮对话直接用这里写好的原因，不另写一句盖掉它。
  @override
  Future<void> onConnectError(CoreCommandError e, String agent, String cwd) async {
    lastError = e.message;
    switch (e.code) {
      // `session/new` 回 -32000：认证页（画板 52），成功后自动重试这个 cwd 的新会话（docs/design.md § 5 第 5 条）。
      case 'auth_required':
        await _openAuth(agent, cwd);
      // npx 型 agent 缺 Node：Agents 面板顶上的受管 Node 提示卡（画板 51）。
      case 'node_missing':
        _openAgentsTab();
      default:
        break;
    }
  }

  /// 已连接的 agent 上开一个会话（`newSession` 的后半段；认证成功后的自动重试也走这里）。
  /// 索引按**这条**会话写（`target`）：它不一定成了当前会话（见 [_adoptSession]）。
  Future<void> createSession(String agent, String cwd) async {
    final b = bridge;
    if (b == null) return;
    final SessionStore s;
    try {
      s = _adoptSession(agent, cwd, await b.sessionNew(agent, cwd));
    } finally {
      // 核心按 session/new 的结果回写了认证状态（已登录 / 需要认证），面板上的徽章跟着刷（画板 50 / 51 / 70）。
      unawaited(agents.refreshRegistry());
    }
    await saveIndex(target: s);
  }

  /// terminal 型认证由核心顺手开好的会话（`terminal_auth_run` 回的 `session`）：直接采用并写索引。
  Future<void> adoptAuthSession(String agent, String cwd, JsonMap session) async {
    await saveIndex(target: _adoptSession(agent, cwd, session));
  }

  /// 认证页（没连上的 agent 先 `initialize`）也经这里连：连接换了一代要记账（iteration-07），
  /// 不然这个 agent 名下内存里的会话还当自己挂着，发出去撞 `-32602 unknown session`。
  Future<void> connectAgent(String agent, String? cwd) async {
    final b = bridge;
    if (b != null) await _connect(b, agent, cwd);
  }

  /// `agent_connect` + 把返回的 `initialize` 立刻落进 agent 状态表。
  /// 为什么不等 `acp/agent_state: initialized` 事件：事件要过一轮 batcher 才到，而紧接着的
  /// `session/new` / `session/load` 就要读 `agentCapabilities` 裁剪动作，等不起（R6）。落两次是幂等的。
  /// 换上的是一条新连接：这个 agent 名下内存里的会话全部挂空（iteration-07），切过去或再发时自动挂回。
  Future<JsonMap> _connect(CoreCommands b, String agent, String? cwd) async {
    final result = await b.agentConnect(agent, cwd: cwd);
    final init = result['initialize'];
    if (init is Map) sessions.agents.applyInitializeResult(agent, init.cast<String, dynamic>());
    connectionReplaced(agent);
    return result;
  }

  /// 已经连着就不动它（`agent_connect` 会先断开旧连接，重连会把正在跑的会话一起杀掉）。
  @override
  Future<void> ensureConnected(String agent, String cwd) async {
    final b = bridge;
    if (b == null || sessions.agents[agent]?.state == AgentLifecycle.initialized) return;
    await _connect(b, agent, cwd);
  }

  /// `session/new` 的结果落到投影层；会话的 cwd 属于当前项目时才切成当前会话。
  /// 认证期间换了项目（BACKLOG P0「认证完成后建出来的会话挂到旧目录」，iteration-07）：认证页成功后的自动重试
  /// 用的是发起时的 cwd，会话照常登记在它自己的目录下（切回那个项目就在侧栏里），但不顶掉当前项目里正看着的。
  /// 平常的新建会话在等待期里换不了项目（`WorkspaceState` 的等待期守卫），这道判断对它恒真。
  SessionStore _adoptSession(String agent, String cwd, JsonMap result) {
    final sid = result['sessionId'];
    if (sid is! String) throw StateError('session/new 没有返回 sessionId');
    _sessionAgent[sid] = agent;
    attachedNew(sid);
    final s = sessions.session(sid, agentId: agent)
      ..cwd = cwd
      ..applyNewSession(result);
    if (workspace.inCurrentWorkspace(cwd)) {
      agentId = agent;
      sessionId = sid;
      sessionEpoch++;
      _showWorkbench();
    }
    return s;
  }

  /// 重载 agent（画板 01 / 41）：断开 + 重拉。agent 声明 `loadSession` 时重连后自动 `session/load` 回原来那个会话
  /// （R6 交付物）；没声明的沿用 R3 的做法——开一个新会话，旧转录留在内存里只读。
  Future<void> reloadAgent() async {
    hidePopover(sessionMenuAnchor);
    final id = agentId;
    final b = bridge;
    final cwd = workspace.project?.path;
    if (id == null || b == null || cwd == null) return;
    // 重入守卫：等待期里会话头的重载按钮仍可点（`canReload` 全程为真，`IgnorePointer` 只包住 `_body()`），
    // 连点两下会让两条 disconnect → reconnect → load 序列交叠，且先返回的那条提前把等待态收掉
    // （审查 finding P2，2026-09-18）。判据换成 [waitingForAgent] 之后，「新会话正在开」时点重载
    // 也一并挡住 —— 那同样是 disconnect 撞 `session/new` 的交叠。
    if (waitingForAgent) return;
    final previous = sessionId;
    // 画板 05 B 组阶段 ①：先把等待态摆出来再发命令。断开 → 重连 → load 要几百毫秒到数秒，
    // 这期间界面一动不动会被当成卡死（所有者反馈 2026-09-17）。
    waitingForAgent = true;
    touch();
    // `session/load` 回的是同一条会话时 `sessionId` 不变、`_adoptSession` 也不走，
    // 但转录确实整块换过，得单独补一次入场触发（画板 05 阶段 ③）。
    var loaded = false;
    try {
      await guard(() async {
        await b.agentDisconnect(id);
        if (previous == null) {
          // 走不带重入守卫的那条：这里的等待态是本方法刚摆出来的，守卫会把它当成「另一条在途」。
          await _newSession(AgentRef(id: id, name: id));
          return;
        }
        await _connect(b, id, cwd);
        if (!canLoadSessionOf(id) || !await loadSession(id, previous, sessions.maybe(previous)?.cwd ?? cwd)) {
          // 不支持 loadSession：开新会话，旧转录留在内存里只读（R3 的做法）。
          // 支持但载失败：这次重放整段作废、原来那份转录原样留着（仍标挂空，点回去会再载），这里同样开新会话。
          await createSession(id, cwd);
        } else {
          loaded = true;
        }
      });
    } finally {
      // 阶段 ③：载回原会话才补触发；开了新会话的路径 `_adoptSession` 已经 +1 过，
      // 全都失败的路径不补 —— 画板 05 阶段 ③' 只把亮度恢复，不播入场。
      if (loaded) sessionEpoch++;
      waitingForAgent = false;
      touch();
    }
  }

  /// 侧栏点选一条会话（画板 04）。它没挂在连接上时（内存里没有转录、关过、连接换过一代）顺带挂回来（[ensureLoaded]）。
  Future<void> selectSession(String id) async {
    _showWorkbench();
    // 会话头正在改名时切走：那个输入框改的是原来那条会话，跟着切过去会把名字落到别人头上。
    if (renamingInHeader && renamingSessionId != id) cancelRename();
    if (sessionId != id) sessionEpoch++;
    sessionId = id;
    agentId = _sessionAgent[id] ?? agentId;
    // 切进来就算「被查看」：绿点淡出（画板 06 B ④）。
    clearUnread(id);
    touch();
    await ensureLoaded(id);
  }

  /// `session/list` 校对出来的「agent 侧已经没有了」的会话（裁定 2026-09-15：只校对，不自动删、不自动加）。
  @override
  final Set<String> missingOnAgent = <String>{};

  /// ≡ 菜单 Resume（画板 41）：`session/resume` 只恢复 agent 侧上下文，**不重放**——转录用内存里已有的那份。
  Future<void> resumeSession() async {
    hidePopover(sessionMenuAnchor);
    final b = bridge;
    final id = sessionId;
    final agent = agentId;
    if (b == null || id == null || agent == null) return;
    final cwd = sessions.maybe(id)?.cwd ?? cwdOf(id) ?? workspace.project?.path;
    if (cwd == null) return;
    final generation = generationOf(agent);
    await guard(() async {
      final result = await b.sessionResume(agent, id, cwd);
      sessions.session(id, agentId: agent)
        ..cwd = cwd
        ..applyLoadSession(result);
      markResumed(id, agent, generation);
    });
    touch();
  }

  /// ≡ 菜单 Close（画板 41）：`session/close` = 先 cancel 再释放。本地转录留着**只读**，会话仍是当前会话——
  /// 这样 ≡ 菜单里紧接着就能 Resume（`session/resume` 只对没在本连接上活着的会话有效），
  /// 从侧栏再点开它则走 `session/load` 重放。
  Future<void> closeSession() async {
    hidePopover(sessionMenuAnchor);
    final b = bridge;
    final id = sessionId;
    final agent = agentId;
    if (b == null || id == null || agent == null) return;
    await guard(() async {
      await _releaseSessionRequests(b, agent, id);
      await b.sessionClose(agent, id);
      markClosed(id);
    });
    touch();
  }

  /// close / delete 之前把这个会话挂起的 client 请求收干净——与一轮对话控制器的 `cancel` **同一条规矩**
  /// （`session/close` 按规范就等价于「先 cancel 再释放」）：
  /// - 权限请求：核心那边已经自动回 `cancelled` 了，这里把转录上的卡也标成 cancelled，
  ///   否则卡还停在 pending、用户点 Allow 会撞 `unknown_request`（审查第 2 轮 P2）；
  /// - elicitation：**核心不代答**，必须逐条回，不回 agent 会一直等，连后面的 `session/close` 都不处理
  ///   （审查第 1 轮 finding high）；
  /// - 未完成的工具卡一并本地标 cancelled（`SessionStore.cancel()` 的既有语义）。
  Future<void> _releaseSessionRequests(CoreCommands b, String agent, String id) async {
    final s = sessions.maybe(id);
    if (s == null) return;
    final result = s.cancel();
    for (final requestId in result.cancelledElicitationIds) {
      await guard(() => b.acpRespond(agent, requestId, PendingQueue.cancelledAction));
    }
  }

  /// `session/list` 校对（R6，裁定 2026-09-15 落 docs/design.md § 3 末条）：侧栏以本地索引为准，
  /// 这里只做两件事——① agent 侧还在的会话，缺标题就用 agent 给的补上；② agent 侧没有的记进 [missingOnAgent]
  /// （不自动删本地记录，也不把 agent 有、本地没有的塞进侧栏）。分页按 `nextCursor` 取完。
  Future<void> reconcileSessions({int maxPages = 20}) async {
    final b = bridge;
    final agent = agentId;
    if (b == null || agent == null || !canListSessions) return;
    await guard(() async {
      final remote = <String, JsonMap>{};
      String? cursor;
      for (var page = 0; page < maxPages; page++) {
        final result = await b.sessionList(agent, cwd: workspace.project?.path, cursor: cursor);
        final list = result['sessions'];
        if (list is List) {
          for (final item in list) {
            if (item is! Map) continue;
            final sid = item['sessionId'];
            if (sid is String && sid.isNotEmpty) remote[sid] = item.cast<String, dynamic>();
          }
        }
        final next = result['nextCursor'];
        if (next is! String || next.isEmpty) break;
        cursor = next;
      }
      var changed = false;
      final scope = workspace.project?.path;
      final scopeKey = scope == null ? null : WorkspaceState.normalizeCwd(scope);
      for (final entry in <JsonMap>[...index.entries]) {
        if (entry['agentId'] != agent) continue;
        // `session/list` 按 cwd 过滤了，本地也只能拿同一个 cwd 的条目去对——否则别的项目下的会话
        // 会被整批判成「agent 侧没有了」（2026-09-16 dsh 实测踩到：21 条全被误标）。比法与侧栏过滤
        // （[WorkspaceState.inCurrentWorkspace]）统一成归一后比：按原串比的话，只差分隔符 / 尾斜杠 /
        // Windows 大小写写法的条目侧栏列着、这里却跳过，既不补标题也不参与 missingOnAgent 判定
        // （BACKLOG「cwd 写法不同的会话，校对会跳过」）。没记 cwd 的老条目照旧跳过：只换比法，不放宽过滤。
        final cwd = entry['cwd'];
        if (scopeKey != null && (cwd is! String || WorkspaceState.normalizeCwd(cwd) != scopeKey)) continue;
        final sid = entry['sessionId'];
        if (sid is! String) continue;
        final info = remote[sid];
        if (info == null) {
          missingOnAgent.add(sid);
          continue;
        }
        missingOnAgent.remove(sid);
        final title = info['title'];
        final local = entry['title'];
        // 只补、不覆盖：本地改过的名字是用户的，agent 的标题不能盖回去。
        final needsTitle = local is! String || local.isEmpty || local == sid;
        if (needsTitle && title is String && title.isNotEmpty) {
          await index.upsertEntry(<String, dynamic>{...entry, 'title': title});
          changed = true;
        }
      }
      if (changed) touch();
    });
  }

  /// 删除 / 改名 / 挂载用的 agentId：优先本地索引里记的那个，退到当前连接。
  @override
  String ownerOf(String sessionId) => _sessionAgent[sessionId] ?? agentId ?? '';

  /// 这条会话的 cwd：本地索引里登记的，没有就退到内存里那份转录的。
  @override
  String? cwdOf(String sessionId) => index.cwdOf(sessionId) ?? sessions.maybe(sessionId)?.cwd;

  /// 一条会话写进本地索引（`sessions.json`）：收轮刷消息计数、新会话登记、发消息时打 `updatedAt`（口径见 [SessionIndex.upsert]）。
  /// [target] 缺省是**当前**会话；收轮那次由 `TurnController._runTurn` 把刚跑完的那条传进来——2026-09-18 起
  /// 新建会话不再重连、可以并跑，后台那条跑完时当前选中的往往是另一条，写成 [store] 就成了刷前台那条的计数、
  /// 后台那条要等它自己下一轮（BACKLOG「后台跑完的那轮，侧栏消息数不刷新」）。占位标题同理按**这条会话自己的**
  /// agent 算，不然是把前台那条的标题写到它头上；索引里已有标题时 [SessionIndex.upsert] 先退回那一级。
  Future<void> saveIndex({SessionStore? target, bool promptSent = false}) async {
    final s = target ?? store;
    // 会话表里已经没有这条（[deleteSession] 的 `sessions.forget`），或那个 id 底下换了一个 store（删掉再新建
    // 的同 id 会话，fake-agent 不带 `--sessions` 时每次都回 `sess_fake_1`）：这笔写不发。跑着的会话被删掉时
    // 这一轮照样会收，写了就是把删掉的行写回 `sessions.json`（侧栏幽灵条目）或把新会话那行盖成旧转录的值。
    // 缺省那条路天然成立（[store] 就是从会话表取的），这道门只管传了 [target] 的收轮那次（复审 high，2026-09-22）。
    if (s == null || !identical(sessions.maybe(s.sessionId), s)) return;
    await index.upsert(s,
        agentFallback: agentId ?? '', titleFallback: placeholderTitleOf(s.agentId ?? agentId), promptSent: promptSent);
  }

  /// 用户发出一条消息（发送 / Restore / Regenerate）：把索引的 `updatedAt` 打成现在，侧栏这条立刻升到最上面。
  /// **不 await**：`startTurn` 与 `_runTurn` 之间不能有异步间隙，否则这段里 `isRunning` 已是 true 而
  /// `_turnInFlight` 还是 null，Restore / cancel 等不到在途那一轮就会重叠两个 `session/prompt`
  /// （审查 finding high，2026-09-15）。先后由 [SessionIndex] 本地记的发消息时间兜住：收轮那次 [saveIndex]
  /// 不靠这条命令回没回来，本地记的那份时间总在。写不动只记日志不挡发送——索引是可再生缓存
  /// （`rust/settings/src/index.rs`），发送才是正事。
  Future<void> stampPromptSent() async {
    try {
      await saveIndex(promptSent: true);
    } catch (e) {
      debugPrint('[workbench] session index: ${describeError(e)}');
    }
  }

  void startRename(String id, {bool inHeader = false}) {
    renamingSessionId = id;
    renamingInHeader = inHeader;
    final current = sidebarSessions.where((s) => s.id == id).map((s) => s.title).firstOrNull ??
        (inHeader ? sessionTitle : '');
    rename.text = current;
    touch();
  }

  void cancelRename() {
    renamingSessionId = null;
    renamingInHeader = false;
    touch();
  }

  Future<void> commitRename(String title) async {
    final id = renamingSessionId;
    renamingSessionId = null;
    renamingInHeader = false;
    final b = bridge;
    if (id == null || b == null || title.trim().isEmpty) {
      touch();
      return;
    }
    // 会话头显示的是 store 的标题，改完要跟着变；不写回去的话 [saveIndex] 收轮时还会拿旧标题把索引盖回去。
    // agent 之后再发 `session_info_update.title` 仍然照单全收（规则 2），改名只管到那时候。
    sessions.maybe(id)?.title = title.trim();
    await guard(() async {
      final owner = ownerOf(id);
      // 计数与 cwd 都从索引本身取，不从侧栏：侧栏只投影当前 workspace 的条目（[_toSidebar]），
      // 核心的 upsert 是整行替换，这里少给一个字段就是把它抹成默认值。
      await index.upsertEntry(<String, dynamic>{
        'agentId': owner,
        'sessionId': id,
        'title': title.trim(),
        'cwd': cwdOf(id) ?? workspace.project?.path,
        'messageCount': (index.entryOf(id)?['messageCount'] as num?)?.toInt() ?? 0,
        // 改名不是发消息：沿用原时间，侧栏不因此重排（见 [SessionIndex.upsert]）。
        'updatedAt': ?index.updatedAtOf(id),
      });
    });
    touch();
  }

  void askDelete(String id) {
    confirmingDeleteId = id;
    touch();
  }

  void cancelDelete() {
    confirmingDeleteId = null;
    hidePopover(deleteAnchor);
    touch();
  }

  /// 删除这条会话时会不会连 agent 侧一起删：它的 agent 连着（能力已知）且声明了 `sessionCapabilities.delete`。
  /// 与侧栏的删除图标（一律给）不同——能力未知时图标照给，但不会发 `session/delete`。
  bool deletesOnAgent(String sessionId) {
    if (_deletedOnAgent.contains(sessionId)) return false;
    final owner = ownerOf(sessionId);
    return owner.isNotEmpty && sessionCapsOf(owner).containsKey('delete');
  }

  /// agent 侧那一步已经走过的会话（删成功，或删失败已经放行）：本地索引那步失败后重试时不再发第二次
  /// `session/delete`。
  final Set<String> _deletedOnAgent = <String>{};

  /// 删除会话（画板 41 的确认弹层）：agent 连着且声明了 `sessionCapabilities.delete` 就先删 agent 侧，
  /// 然后删本地索引；agent 没连或没声明就只删本地索引。
  /// 没连的 agent 不为了删一条记录去拉进程（已知限制，记 rounds/round-06 任务卡）。
  Future<void> deleteSession(String id) async {
    confirmingDeleteId = null;
    hidePopover(deleteAnchor);
    final b = bridge;
    if (b == null) return;
    final owner = ownerOf(id);
    final onAgent = deletesOnAgent(id);
    await guard(() async {
      if (onAgent) {
        await _releaseSessionRequests(b, owner, id);
        try {
          await b.sessionDelete(owner, id);
        } catch (e) {
          // **agent 侧删不掉也要放行本地这条**：agent 根本没有这条会话时（0 条消息的会话多半没落盘，
          // 重启换了进程后 `session/delete` 一直回「没有这条」）原先停在这儿，于是这条本地记录再也删不掉
          // （所有者报障 2026-09-18）。报一句，继续删本地索引——侧栏以本地索引为准，留着它用户没有别的办法清。
          lastError = 'agent 侧删除失败（${describeError(e)}），本地这条记录已经移除';
        }
        // agent 侧那一步走过了：本地那步万一失败，重试不能再往 agent 发一次（成功的那条它会以「没有这条」
        // 拒绝，于是本地索引永远删不掉、两边永远岔开，审查 finding P2）。
        _deletedOnAgent.add(id);
      }
      // 索引这条记录按 (agentId, sessionId) 精确匹配删除，agentId 要用**索引里登记的那个**：
      // 拿当前连接的 agentId 去删会一条都对不上，核心照样返回成功，于是那一行纹丝不动、也没有任何提示。
      await index.remove(index.agentOf(id) ?? owner, id);
      // 查索引本身而不是侧栏：侧栏只投影当前 workspace 的条目（[_toSidebar]），不在侧栏 ≠ 已删掉。
      if (index.entries.any((e) => e['sessionId'] == id)) {
        lastError = '这条会话的本地记录没能删掉（索引里找不到匹配的记录）';
      }
      missingOnAgent.remove(id);
      forgetAttachment(id);
      _deletedOnAgent.remove(id);
      _sessionAgent.remove(id);
      index.forgetPromptSent(id);
      clearUnread(id);
      sessions.forget(id);
      if (sessionId == id) sessionId = null;
    });
    touch();
  }
}
