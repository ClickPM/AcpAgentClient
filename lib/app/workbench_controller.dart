// 组合根的状态与动作（R3 接线阶段）：把 `lib/projection/` 的投影层、`lib/app/core_bridge.dart` 的桥命令
// 与 `lib/ui/` 的画板 widget 串起来。widget 只拿数据与回调，不知道桥的存在（CLAUDE.md 规则 3）。
//
// 数据源两种（ROUNDS § 3 R3）：
//   bridge（默认）——真核心；fixtures（`--dart-define=DATA_SOURCE=fixtures`）——回放 `test/fixtures/`，
//   所有会改动 agent 的命令都是 no-op，供 gallery 与不装 agent 时开发。
//
// 不做 agent 特判（规则 2）：agent 名一律来自 settings.json 的键或 `initialize` 的 `agentInfo`；
// 三个下拉按 `config_option_update` 的 `category` 分配，未识别 category 走扁平兜底。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../projection/agent_state.dart';
import '../projection/batcher.dart';
import '../projection/entries.dart';
import '../projection/fixture_line.dart';
import '../projection/fixture_replay.dart';
import '../projection/pending.dart';
import '../projection/session_store.dart';
import '../projection/traffic.dart';
import '../projection/wire.dart';
import '../ui/popovers/topbar_popovers.dart';
import '../ui/shell/popover_anchor.dart';
import '../ui/shell/shell_common.dart';
import '../ui/shell/sidebar.dart';
import 'composer_state.dart';
import 'core_bridge.dart';
import 'files_state.dart';
import 'guarded.dart';
import 'local_terminals.dart';
import 'agents_state.dart';
import 'auth_state.dart';
import 'paths.dart';
import 'session_index.dart';
import 'shell_state.dart';
import 'turn_controller.dart';
import 'workspace_state.dart';

enum DataSource {
  bridge,
  fixtures;

  /// `--dart-define=DATA_SOURCE=fixtures`。
  static DataSource fromEnvironment() =>
      const String.fromEnvironment('DATA_SOURCE') == 'fixtures' ? DataSource.fixtures : DataSource.bridge;
}

class WorkbenchController extends ChangeNotifier with GuardedNotifier implements ThreadPort {
  WorkbenchController({required this.source, this.bridge, FlushScheduler? scheduler})
      : _scheduler = scheduler ?? _scheduleOnFrame {
    shell.addListener(notifyListeners);
    workspace.addListener(notifyListeners);
    agents.addListener(notifyListeners);
    auth.addListener(notifyListeners);
    composer.addListener(notifyListeners);
    turn.addListener(notifyListeners);
  }

  final DataSource source;
  final CoreCommands? bridge;

  /// 批量刷新的调度器。窗口里按帧合并（docs/design.md § 9）；无头实跑（lib/app/headless_run.dart）
  /// 没有 vsync、`scheduleFrameCallback` 永远不回调，那里传微任务调度。
  final FlushScheduler _scheduler;

  // ---- 投影层
  late final Sessions sessions = Sessions();
  late final UpdateBatcher batcher = UpdateBatcher(sessions, scheduler: _scheduler);
  final TrafficStore traffic = TrafficStore();

  // ---- 本地态（协议之外）
  List<SidebarSession> sidebarSessions = const <SidebarSession>[];

  @override
  String? agentId;
  String? sessionId;

  /// 中栏内容整块换过几次（画板 05 A 组的入场触发器）。切会话、新建会话、重载完成各 +1。
  /// 不能只看 `sessionId`：重载 agent 若 `session/load` 回的是同一条，id 没变但内容确实整块换了。
  int sessionEpoch = 0;

  /// 正在等 agent 把会话换过来（画板 05 B 组的等待期）：转录区降到 `opacity.pending` 且不可交互，
  /// 线程头借用 `isRunning` 那只 spinner。两个触发共用同一套 —— 重载 agent（[reloadAgent]：断开 → 重连
  /// → `session/load`）与新建会话（[newSession]：拉进程 → `initialize` → `session/new`，含 `send()`
  /// 现开一条那条路）。画板 05 B 组只画了 reload 图标那个触发，但两者都是「时长不可预知的整块替换」，
  /// 等待期的规格一字不差地套用；新建会话那条是所有者手测报回来的（2026-09-18：选完 agent
  /// 到会话出来这几秒界面一动不动，像卡住了）。
  bool waitingForAgent = false;
  final Map<String, String> _sessionAgent = <String, String>{}; // sessionId → agentId

  // ---- 项目与分支（R7.5 拆出）：当前项目 / 最近项目 / 分支区 / Rules 计数；等待期守卫与换项目的后续动作经回调回到这里。
  late final WorkspaceState workspace = WorkspaceState(
    bridge: bridge,
    files: files,
    busy: () => waitingForAgent,
    onProjectChanged: _enterWorkspace,
  );

  // ---- 本地会话索引 `sessions.json` 的内存镜像（R7.5 拆出）：不是 notifier，条目一变就在这里重投影侧栏。
  late final SessionIndex index = SessionIndex(bridge: bridge, onChanged: _refreshSidebar);

  // ---- 壳的本地 UI 态（R7.5 拆出）：三栏宽度、主区页面、右栏标签条、本地终端标签、Follow、流量过滤框。
  late final ShellState shell = ShellState(
    bridge: bridge,
    files: files,
    terminals: terminals,
    cwd: () => workspace.project?.path,
    onWorkbenchShown: () {
      // 从流量页回到工作台，当前那条会话就又在眼前了：它的绿点一并撤掉（画板 06 的清除条件）。
      final id = sessionId;
      if (id != null) clearUnread(id);
    },
  );

  /// 文件面板（画板 60）与终端面板（画板 61）的接线状态（R4）。
  late final FilesState files = FilesState(bridge: bridge);
  late final LocalTerminals terminals = LocalTerminals(bridge: bridge);

  /// agent 终端（`acp/terminal_output` source = agent / auth）的分块 UTF-8 解码：跨块的多字节字符不能逐块 `utf8.decode`。
  final Map<String, ChunkedUtf8> _agentTerminalText = <String, ChunkedUtf8>{};
  // ---- UI 态
  String search = '';
  String? renamingSessionId;

  /// 改名的输入框落在哪一处：线程头的铅笔就在线程头上改（画板 01 的标题位），侧栏那支笔改侧栏那一行。
  /// 两处共用 [rename] / [renameFocus]，靠这个标记分流，同一时刻只可能有一个输入框在树上。
  bool renamingInHeader = false;
  String? confirmingDeleteId;

  // ---- 输入框（画板 40 / 42）（R7.5 拆出）：正文与附件、`@` `/` 内联菜单、`+` 四项、配置格与三个弹层锚点；
  // 当前 store / 项目目录 / 可用性 / 能否带图经查询回调向这里要。
  late final ComposerState composer = ComposerState(
    bridge: bridge,
    store: () => store,
    cwd: () => workspace.project?.path,
    canCompose: () => canCompose,
    canPromptImage: () => canPromptImage,
  );

  // ---- 一轮对话（R7.5 拆出）：发送 / 取消 / 回应 / Restore、会话配置、停止方块、本地转录文本。
  // 它读当前线程走 ThreadPort（第 7 步由本类实现，第 8 步换成 ThreadController 本体）。
  late final TurnController turn = TurnController(bridge: bridge, thread: this, composer: composer);

  // ---- 已装 agent 列表、registry 面板（画板 50 / 51）与设置面板（画板 70）（R7.5 拆出）
  late final AgentsState agents = AgentsState(
    bridge: bridge,
    onRemoved: (id) {
      if (agentId == id) {
        agentId = null;
        sessionId = null;
      }
      auth.closeIfAgent(id);
    },
    onInstalledChanged: _selectDefaultAgent,
    onRegistryChanged: _refreshSidebar,
    onPaths: _applyPaths,
  );

  /// 核心给的几个路径（画板 70）：`core_init` / `registry_list` 的 `paths`。
  String? dataDir;
  String? logPath;
  String? zedSettingsPath;

  // ---- 认证页（画板 52，R5）的状态机（R7.5 拆出）：右栏标签、当前项目、registry 展示名、当前 agent 经回调向这里要，
  // 认证成功后的自动重试新会话交回会话那一段。
  late final AuthState auth = AuthState(
    bridge: bridge,
    sessions: sessions,
    cwd: () => workspace.project?.path,
    registryName: (id) => agents.registry.byId(id)?.name,
    currentAgentId: () => agentId ?? connection?.agentId,
    openAgentsTab: () => shell.openTab(ShellTab.agents),
    ensureAgentsTab: () {
      if (shell.rightTab != ShellTab.agents) shell.openTab(ShellTab.agents);
    },
    showWorkbench: () => shell.page = MainPage.workbench,
    onAuthenticated: (agent, cwd, session) async {
      if (session == null) {
        await _createSession(agent, cwd);
      } else {
        _adoptSession(agent, cwd, session);
        await saveIndex();
      }
    },
  );

  // ---- 输入控件
  final TextEditingController sidebarSearch = TextEditingController();
  final FocusNode sidebarSearchFocus = FocusNode();
  final TextEditingController rename = TextEditingController();
  final FocusNode renameFocus = FocusNode();

  // ---- 弹层锚点（画板 40 / 41 / 43）
  final PopoverHandle newSessionAnchor = PopoverHandle();
  final PopoverHandle threadMenuAnchor = PopoverHandle();

  /// 画板 43：线程头 history 的会话时间线弹层。
  final PopoverHandle timelineAnchor = PopoverHandle();
  final PopoverHandle deleteAnchor = PopoverHandle();
  final List<StreamSubscription<CoreEventRecord>> _subs = <StreamSubscription<CoreEventRecord>>[];

  // ---------------------------------------------------------------- 派生

  @override
  SessionStore? get store => sessionId == null ? null : sessions.maybe(sessionId!);
  AgentConnection? get connection => agentId == null ? null : sessions.agents[agentId!];

  /// 选中了一个 agent（**不要求**已经开着会话、也不要求进程已拉起）：画板 01 的两个空态按它分流，
  /// 状态 2「还没有已安装的 agent」只在一个都没装时出现。启动时 [_selectDefaultAgent] 会挑一个，
  /// 会话要到第一条消息才现开（[send]），免得每次开应用都去拉一个 agent 进程。
  bool get hasAgent => agentId != null;

  /// 已经有一条会话在手：线程头的重命名 / 重载与 ≡ 菜单的三个动作要它。
  bool get hasSession => agentId != null && sessionId != null;
  bool get isRunning => store?.isRunning ?? false;

  String get agentDisplayName {
    final c = connection;
    // 还没连上时退回已安装列表里的展示名（settings 条目的 `name` 或 registry 的展示名），
    // 不退回 id：启动后的新会话标题写 `New Codex Thread` 而不是 `New codex Thread`。
    return c?.agentTitle ?? c?.agentName ?? agents.installedRef(agentId)?.name ?? agentId ?? 'Agent';
  }

  String get threadTitle {
    if (!hasAgent) return 'No Agent';
    return store?.title ?? 'New $agentDisplayName Thread';
  }

  String get composerPlaceholder {
    if (!hasAgent) return '安装并选择一个 agent 后即可输入';
    // 会话是发第一条消息时才开的，cwd 从当前项目来：没项目就先说清楚，别让发送静默失败。
    if (!hasSession && workspace.project == null) return '先选一个项目目录，新会话的 cwd 从它来';
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

  /// 回合结束时点亮绿点（画板 06 D 表）：`stopReason` 是 cancelled / refusal 的不点，失败收轮（没有 `stopReason`）
  /// 的也不点 —— 取消与出错侧栏一律不表达，错误只在转录区（画板 31 / 34）。
  ///
  /// 「正在看着的那条」不点：它当场就满足画板 06 的清除条件。**偏离**：画板写的是「切入该会话，或它已是当前会话
  /// 且窗口聚焦」，这里没有窗口聚焦这一维（宿主没给这个信号），按「当前会话 + 停在工作台页」判。
  @override
  void markDone(String id, String? stopReason) {
    if (stopReason == null || stopReason == 'cancelled' || stopReason == 'refusal') return;
    if (_isViewing(id)) return;
    _unreadDone.add(id);
  }

  bool _isViewing(String id) => shell.page == MainPage.workbench && sessionId == id;

  /// 该会话被查看 / 被删 / 又开了新一轮：绿点撤掉（运行中与绿点严格互斥）。
  @override
  void clearUnread(String id) => _unreadDone.remove(id);

  /// 画板 34 要显示的连接状态条：initialized 与 none 不出条（那是常态，不是告警）。
  bool get showAgentStateBar {
    final state = connection?.state;
    return state != null && state != AgentLifecycle.none && state != AgentLifecycle.initialized;
  }

  int get droppedUpdates => connection?.droppedUpdates ?? 0;

  // ---------------------------------------------------------------- 生命周期

  Future<void> start() async {
    if (source == DataSource.fixtures) {
      await _startFixtures();
      return;
    }
    final b = bridge;
    if (b == null) return;
    _subs.addAll(<StreamSubscription<CoreEventRecord>>[
      b.on(CoreEvent.sessionUpdate).listen((e) {
        final sid = e.json?['sessionId'];
        if (sid is String) _updateArrivals[sid] = (_updateArrivals[sid] ?? 0) + 1;
        _enqueue(e, (json) {
          sessions.applySessionUpdateEnvelope(json);
          shell.followLocations(json, sessionId: sessionId);
        });
      }),
      b.on(CoreEvent.clientRequest).listen((e) => _enqueue(e, (json) => sessions.applyClientRequestEnvelope(json))),
      b.on(CoreEvent.agentState).listen((e) => _enqueue(e, (json) => sessions.applyAgentState(json))),
      b.on(CoreEvent.terminalOutput).listen((e) => _enqueue(e, _onTerminalOutput)),
      b.on(CoreEvent.traffic).listen((e) {
        final json = e.json;
        if (json != null) traffic.apply(json);
      }),
      b.on(CoreEvent.registryProgress).listen(agents.onRegistryProgress),
    ]);
    sessions.addListener(notifyListeners);
    sessions.pending.addListener(auth.onPendingChanged);
    files.addListener(notifyListeners);
    terminals.addListener(notifyListeners);
    await guard(() async {
      final info = await b.init(defaultDataDir());
      dataDir = info['dataDir'] as String? ?? defaultDataDir();
      logPath = info['logPath'] as String?;
      // 本地索引先读：下面挑「当前 agent」要按索引里最近用过的那条来（`refreshRegistry` 末尾
      // 会用 registry 的图标把侧栏重投影一次，所以先读索引不会让会话项停在占位菱形上）。
      await index.refresh();
      await agents.refreshRegistry();
      await agents.refreshAgents();
      await workspace.restoreLastProject();
      await shell.restoreUiState();
    });
    notifyListeners();
    // registry.json 的联网刷新（1 小时节流）放到后台：断网时 30 秒超时不能挡住启动。
    unawaited(agents.refreshRegistry(network: true));
  }

  /// fixtures 数据源：把线上行喂进同一套投影层与流量面板，本地态给一份可用的假数据。
  Future<void> _startFixtures() async {
    const agent = 'fixture-agent';
    final replayer = FixtureReplayer(sessions, agentId: agent);
    final files = <String>['01-connect', '25-config-options', '02-turn-read', '08-end-turn'];
    var ts = DateTime.now().millisecondsSinceEpoch;
    for (final name in files) {
      final file = File('test/fixtures/$name.jsonl');
      if (!file.existsSync()) continue;
      for (final line in FixtureLine.parseAll(file.readAsStringSync())) {
        replayer.feed(line);
        final msg = line.msg;
        ts += line.delayMs;
        if (msg != null) {
          traffic.apply(<String, dynamic>{
            'agentId': agent,
            'direction': line.dir == FixtureDir.out ? 'out' : 'in',
            'line': jsonEncode(msg),
            'ts': ts,
          });
        } else if (line.dir == FixtureDir.stderr && line.line != null) {
          traffic.apply(<String, dynamic>{'agentId': agent, 'direction': 'stderr', 'line': line.line, 'ts': ts});
        }
      }
    }
    sessions.addListener(notifyListeners);
    agentId = agent;
    sessionId = replayer.lastSessionId;
    final cwd = sessionId == null ? null : sessions.maybe(sessionId!)?.cwd;
    if (cwd != null) workspace.project = ProjectRef(path: cwd, name: cwd.split(RegExp(r'[\\/]')).last);
    sidebarSessions = <SidebarSession>[
      if (sessionId != null)
        SidebarSession(
          id: sessionId!,
          title: sessions.maybe(sessionId!)?.title ?? 'fixtures',
          updatedAt: DateTime.now(),
          messageCount: sessions.maybe(sessionId!)?.entries.whereType<MessageEntry>().length ?? 0,
        ),
    ];
    notifyListeners();
  }

  void _enqueue(CoreEventRecord e, void Function(JsonMap json) apply) {
    final json = e.json;
    if (json == null) return;
    batcher.enqueue(() => apply(json));
  }

  static void _scheduleOnFrame(void Function() flush) {
    SchedulerBinding.instance.scheduleFrameCallback((_) => flush());
    SchedulerBinding.instance.scheduleFrame();
  }

  /// 无头实跑用：微任务里刷，不依赖帧。
  static void scheduleOnMicrotask(void Function() flush) => scheduleMicrotask(flush);


  @override
  void dispose() {
    markDisposed();
    for (final s in _subs) {
      s.cancel();
    }
    sessions.removeListener(notifyListeners);
    sessions.pending.removeListener(auth.onPendingChanged);
    files.removeListener(notifyListeners);
    terminals.removeListener(notifyListeners);
    files.dispose();
    terminals.dispose();
    for (final c in <TextEditingController>[
      sidebarSearch, rename,
    ]) {
      c.dispose();
    }
    for (final f in <FocusNode>[
      sidebarSearchFocus, renameFocus,
    ]) {
      f.dispose();
    }
    for (final h in <PopoverHandle>[
      newSessionAnchor, threadMenuAnchor, timelineAnchor, deleteAnchor,
    ]) {
      h.dispose();
    }
    shell.removeListener(notifyListeners);
    shell.dispose();
    workspace.removeListener(notifyListeners);
    workspace.dispose();
    agents.removeListener(notifyListeners);
    agents.dispose();
    auth.removeListener(notifyListeners);
    auth.dispose();
    composer.removeListener(notifyListeners);
    composer.dispose();
    turn.removeListener(notifyListeners);
    turn.dispose();
    super.dispose();
  }

  /// 组合根里的纯 UI 变化（弹层里的搜索框输入等）需要重建时调它。
  void refresh() => touch();

  // ---------------------------------------------------------------- 已装 agent、侧栏投影与 agent 能力

  /// 当前 agent 还没定（启动、或刚把选中的那个卸掉）时挑一个：本地索引里最近用过、且**还装着**的那个，
  /// 没有就第一个已安装的；一个都没装就留空（画板 01 状态 2）。
  /// 只挑不连——agent 进程等到第一条消息才拉起（[send]），所以开应用不会白拉一个进程、也不会在启动时弹认证。
  /// 已装列表每次刷新完都会调到这里（`AgentsState.onInstalledChanged`）。
  void _selectDefaultAgent() {
    // 会话开着的时候当前 agent 归那条会话，列表刷新一概不许动它：`session/new` 之后那一发
    // `registry_list` / `agent_settings_get` 只要慢一步或回了空，就会把正在用的 agent 抹掉
    // （线程头回到 No Agent、发送打不出去）。卸载走 `removeAgent`，它自己会先清干净再刷。
    if (sessionId != null) return;
    final installed = <String>{for (final a in agents.installed) a.id};
    final current = agentId;
    if (current != null && installed.contains(current)) return; // 已经选好且还装着：不动它
    agentId = index.lastUsedAgentId(installed) ?? (agents.installed.isEmpty ? null : agents.installed.first.id);
  }

  /// 已安装列表里的这一条，不在列表里就按 id 造一条（`send` 现开会话时给 [newSession] 用）。
  @override
  AgentRef agentRefOf(String id) => agents.installedRef(id) ?? AgentRef(id: id, name: id);

  /// 本地索引变了 / registry 变了（图标）：侧栏项重投影一次。不通知，调用方收尾时 `touch`。
  void _refreshSidebar() {
    sidebarSessions = _toSidebar(index.entries);
  }

  /// 把 `sessions.json` 的一条映射成侧栏项，**顺带把 agentId 记进 [_sessionAgent]**：
  /// 重启后点侧栏 / 改名 / 删除都要用 (agentId, sessionId) 这一对键，只靠 `newSession` 时写入
  /// 会让重启后的删除按空 agentId 去匹配、删不掉（审查 finding P2，2026-09-15）。
  /// **只留当前 workspace 的**：cwd 是当前项目目录的才进侧栏，换项目时 [_enterWorkspace] 重投影一次，
  /// 别的目录下的会话就不再露出来（所有者报障 2026-09-18）。agentId 的登记在过滤之前，
  /// 不在侧栏里的会话（比如刚从线程区放下的那条）之后要删 / 要载还得靠它。
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

  /// 线程头的 agent 标记。
  String? get agentIconSvg => agents.iconSvgOf(agentId);

  // ---- agent 能力（R6）：一律读 `agentCapabilities`，不按 agent 名判（规则 2）。
  // 能力是 agent 级的，不是会话级的——侧栏里各条会话可能属于不同 agent，所以按 agentId 查。

  JsonMap? _capsOf(String? agent) => agent == null ? null : sessions.agents[agent]?.agentCapabilities;

  JsonMap _sessionCapsOf(String? agent) {
    final caps = _capsOf(agent)?['sessionCapabilities'];
    return caps is Map ? caps.cast<String, dynamic>() : const <String, dynamic>{};
  }

  JsonMap get _sessionCaps => _sessionCapsOf(agentId);

  /// `agentCapabilities.loadSession`：重开后能不能把历史重放回来。
  bool canLoadSessionOf(String? agent) => _capsOf(agent)?['loadSession'] == true;

  bool get canLoadSession => canLoadSessionOf(agentId);
  bool get canListSessions => _sessionCaps.containsKey('list');

  /// `promptCapabilities.image`：prompt 里能不能带 `image` 块。管住 `+` 的 Image 一项（画板 40）与 Ctrl+V 粘贴。
  /// **能力未知**（这个 agent 本次运行还没连过——选了一条老会话、第一条消息还没发出去就是这个状态）时
  /// 照给，与侧栏删除图标同口径：严判的话那会儿粘贴会静默失灵，而多带一个 `image` 块最坏是被 agent
  /// 拒掉一条 prompt。连上之后按它自己声明的来。
  bool get canPromptImage {
    final caps = _capsOf(agentId);
    if (caps == null) return true;
    final prompt = caps['promptCapabilities'];
    return prompt is Map && prompt['image'] == true;
  }

  /// ≡ 菜单的三个动作（画板 41）：无能力整行不渲染。
  /// Resume 与 Close 还要看会话是不是还「活着」——实测 dsh-acp-interactive 1.3.0 对活着的会话回
  /// `-32602 session is already active in this ACP connection`（2026-09-16）：`session/resume` 是给**没在本连接上活着**的
  /// 会话重新挂上下文用的，所以只在 `session/close` 之后给；反过来 Close 只对还活着的给。
  @override
  bool get sessionClosed => sessionId != null && _closedSessions.contains(sessionId);
  bool get canResumeSession => hasSession && sessionClosed && _sessionCaps.containsKey('resume');
  bool get canCloseSession => hasSession && !sessionClosed && _sessionCaps.containsKey('close');
  bool get canDeleteSession => hasSession && _sessionCaps.containsKey('delete');

  // 侧栏删除图标（画板 04 注）**一律给**：它删的首先是本地索引这条记录，agent 侧删不删由
  // [deletesOnAgent] 单独判。按 `sessionCapabilities.delete` 裁剪过一版，结果是没声明 delete 的 agent
  // （实测 dsh-acp-interactive 1.3.0）的会话在侧栏里永远清不掉——本地记录是我们自己的，不该被 agent
  // 的能力声明锁住（所有者报障 2026-09-18）。见 [_toSidebar] 的 `canDelete: true`。

  /// 换了项目：侧栏只留这个目录下的会话（[_toSidebar] 按 [project] 过滤）；正开着的会话若属于别的目录，
  /// 就从线程区放下（回到画板 01 的空态，下一条消息在新目录里现开会话）——不然顶栏写着新项目、
  /// 消息却发进旧目录的会话，侧栏里还找不到它。放下不等于关掉：它在 agent 侧照跑，切回那个目录再点回来。
  /// 同一个目录换种写法（分隔符 / 尾斜杠）不算换项目，会话不动。
  void _enterWorkspace() {
    _refreshSidebar();
    // 正在改名的那条（侧栏行或线程头）若不属于这个 workspace，它的输入框随行一起没了，`renamingSessionId`
    // 不能悬着：切回来时那行会直接以改名态出现、带着上次没提交的文本（合并复审 2026-09-18）。
    final renaming = renamingSessionId;
    if (renaming != null && !workspace.inCurrentWorkspace(_cwdOf(renaming))) cancelRename();
    final id = sessionId;
    if (id == null || workspace.inCurrentWorkspace(_cwdOf(id))) return;
    sessionId = null;
    sessionEpoch++;
  }

  // ---------------------------------------------------------------- 会话

  @override
  Future<void> newSession(AgentRef agent) async {
    hidePopover(newSessionAnchor);
    // 重入守卫（发布前审查 P2，2026-09-18）：等待期里线程头的 `+` 仍可点（`IgnorePointer` 只包住 `_body()`），
    // 再选一次 agent 会让两条 newSession 交叠：第二条存下的 `wasWaiting` 是 true，它后返回时把等待态永久留在 true
    // （转录区一直变暗不可点、线程头 spinner 不停、[reloadAgent] 永远被挡）；而且两条都走 `_ensureConnected`，
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
      // 进程已经换了一个，旧 sessionId 在新进程里不存在。要换进程走线程头的「重载 agent」。
      await _ensureConnected(b, agent.id, cwd);
      await _createSession(agent.id, cwd);
    } on CoreCommandError catch (e) {
      lastError = e.message;
      switch (e.code) {
        // `session/new` 回 -32000：认证页（画板 52），成功后自动重试这个 cwd 的新会话（docs/design.md § 5 第 5 条）。
        case 'auth_required':
          await auth.open(agent.id, retryCwd: cwd);
        // npx 型 agent 缺 Node：Agents 面板顶上的受管 Node 提示卡（画板 51）。
        case 'node_missing':
          shell.openTab(ShellTab.agents);
        default:
          break;
      }
    } catch (e) {
      lastError = e.toString();
      debugPrint('[workbench] newSession: $e');
    } finally {
      waitingForAgent = wasWaiting;
      touch();
    }
  }

  /// 已连接的 agent 上开一个会话并切过去（`newSession` 的后半段；认证成功后的自动重试也走这里）。
  Future<void> _createSession(String agent, String cwd) async {
    final b = bridge;
    if (b == null) return;
    try {
      _adoptSession(agent, cwd, await b.sessionNew(agent, cwd));
    } finally {
      // 核心按 session/new 的结果回写了认证状态（已登录 / 需要认证），面板上的徽章跟着刷（画板 50 / 51 / 70）。
      unawaited(agents.refreshRegistry());
    }
    await saveIndex();
  }

  /// `agent_connect` + 把返回的 `initialize` 立刻落进 agent 状态表。
  /// 为什么不等 `acp/agent_state: initialized` 事件：事件要过一轮 batcher 才到，而紧接着的
  /// `session/new` / `session/load` 就要读 `agentCapabilities` 裁剪动作，等不起（R6）。落两次是幂等的。
  Future<JsonMap> _connect(CoreCommands b, String agent, String cwd) async {
    final result = await b.agentConnect(agent, cwd: cwd);
    final init = result['initialize'];
    if (init is Map) sessions.agents.applyInitializeResult(agent, init.cast<String, dynamic>());
    return result;
  }

  /// 已经连着就不动它（`agent_connect` 会先断开旧连接，重连会把正在跑的会话一起杀掉）。
  Future<void> _ensureConnected(CoreCommands b, String agent, String cwd) async {
    if (sessions.agents[agent]?.state == AgentLifecycle.initialized) return;
    await _connect(b, agent, cwd);
  }

  /// `session/new` 的结果落到投影层并切成当前会话。
  void _adoptSession(String agent, String cwd, JsonMap result) {
    final sid = result['sessionId'];
    if (sid is! String) throw StateError('session/new 没有返回 sessionId');
    agentId = agent;
    sessionId = sid;
    sessionEpoch++;
    _sessionAgent[sid] = agent;
    sessions.session(sid, agentId: agent)
      ..cwd = cwd
      ..applyNewSession(result);
    shell.page = MainPage.workbench;
  }

  /// 重载 agent（画板 01 / 41）：断开 + 重拉。agent 声明 `loadSession` 时重连后自动 `session/load` 回原来那个会话
  /// （R6 交付物）；没声明的沿用 R3 的做法——开一个新会话，旧转录留在内存里只读。
  Future<void> reloadAgent() async {
    hidePopover(threadMenuAnchor);
    final id = agentId;
    final b = bridge;
    final cwd = workspace.project?.path;
    if (id == null || b == null || cwd == null) return;
    // 重入守卫：等待期里线程头的重载按钮仍可点（`canReload` 全程为真，`IgnorePointer` 只包住 `_body()`），
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
          // 支持但载失败：`loadSession` 已经把那条从内存里拿掉了（转录已清，留空壳会挡住下次重试），这里同样开新会话。
          await _createSession(id, cwd);
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

  /// 侧栏点选一条会话（画板 04）。内存里没有转录且 agent 声明 `loadSession` 时顺带 `session/load` 把历史重放回来。
  Future<void> selectSession(String id) async {
    shell.page = MainPage.workbench;
    // 线程头正在改名时切走：那个输入框改的是原来那条会话，跟着切过去会把名字落到别人头上。
    if (renamingInHeader && renamingSessionId != id) cancelRename();
    if (sessionId != id) sessionEpoch++;
    sessionId = id;
    agentId = _sessionAgent[id] ?? agentId;
    // 切进来就算「被查看」：绿点淡出（画板 06 B ④）。
    clearUnread(id);
    touch();
    await _ensureLoaded(id);
  }

  /// 关过的会话（`session/close`）：再点开要重新 `session/load`，不能拿内存里那份当还活着。
  final Set<String> _closedSessions = <String>{};

  /// 每条会话被 `session/close` 的次数：`session/load` 用它判断「我在途时有没有人把它关了」。
  final Map<String, int> _closeEpoch = <String, int>{};

  /// 正在 `session/load` 的会话（同一条不并发）。
  final Set<String> _loadsInFlight = <String>{};

  /// 每条会话到达过多少条 `session/update`（在事件到达时计数，不等 batcher）：
  /// `session/load` 失败时用它区分「一条都没重放」与「重放到一半断了」。
  final Map<String, int> _updateArrivals = <String, int>{};

  /// `session/list` 校对出来的「agent 侧已经没有了」的会话（裁定 2026-09-15：只校对，不自动删、不自动加）。
  final Set<String> missingOnAgent = <String>{};

  /// 侧栏点到一条内存里没有转录的会话：连上它的 agent 再 `session/load`。
  /// agent 没声明 `loadSession` 就什么都不做（转录空着，画板 01 的空态）。
  Future<void> _ensureLoaded(String id) async {
    final b = bridge;
    final owner = _sessionAgent[id];
    if (b == null || owner == null || owner.isEmpty) return;
    final reopening = _closedSessions.contains(id);
    if (sessions.maybe(id) != null && !reopening) return;
    final cwd = _cwdOf(id) ?? workspace.project?.path;
    if (cwd == null) return;
    if (missingOnAgent.contains(id)) {
      lastError = '$id 在 agent 侧已经不存在了，载不回历史';
      touch();
      return;
    }
    await guard(() async {
      await _ensureConnected(b, owner, cwd);
      if (canLoadSessionOf(owner)) {
        await loadSession(owner, id, cwd);
        return;
      }
      // 没有 loadSession 但有 resume：agent 侧把上下文挂回来，转录只有内存里这份（不重放，规范如此）。
      if (_sessionCapsOf(owner).containsKey('resume')) {
        await b.sessionResume(owner, id, cwd);
        sessions.session(id, agentId: owner).cwd = cwd;
        _closedSessions.remove(id);
      }
    });
    touch();
  }

  /// 这条会话的 cwd：本地索引里登记的，没有就退到内存里那份转录的。
  String? _cwdOf(String sessionId) => index.cwdOf(sessionId) ?? sessions.maybe(sessionId)?.cwd;

  /// `session/load`（R6）：整段历史由 agent 用 `session/update` 重放，**重放期间不逐条刷新 UI**——
  /// 事件照常入队，但 batcher 挂起到命令返回后一次性刷完。成功返回 true。
  Future<bool> loadSession(String agent, String id, String cwd) async {
    final b = bridge;
    if (b == null) return false;
    // 同一条会话不并发 load：连点两下（或重载 agent 撞上侧栏点击）会重放两遍。
    if (!_loadsInFlight.add(id)) return false;
    final fresh = sessions.maybe(id) == null;
    final s = sessions.session(id, agentId: agent)..cwd = cwd;
    _sessionAgent[id] = agent;
    final arrivalsBefore = _updateArrivals[id] ?? 0;
    final closeEpoch = _closeEpoch[id] ?? 0;
    // 失败且一条都没重放时把清空取消掉：整段重放挂在 batcher 里，这些闭包要到 release 才跑，
    // 而那时候成败已经知道了（审查 finding high：reload / close 之后 load 失败会丢掉本地唯一一份转录）。
    var skipReset = false;
    // hold 与 release 必须严格配对：中间任何一步抛出都得 release，否则 UI 从此不再刷新。
    batcher.hold();
    try {
      // 清空排进同一条挂起队列：清空与重放在 UI 上是一步，中间不会闪一下空转录。
      batcher.enqueue(() {
        if (!skipReset) s.resetForReplay();
      });
      final result = await b.sessionLoad(agent, id, cwd);
      batcher.enqueue(() => s.applyLoadSession(result));
      // 这中间要是有人把它 close 了，别把「已关闭」标记抹掉（审查 finding P2：load 与 close 并发）。
      if ((_closeEpoch[id] ?? 0) == closeEpoch) _closedSessions.remove(id);
      return true;
    } catch (e) {
      lastError = describeError(e);
      debugPrint('[workbench] session/load $id: ${describeError(e)}');
      final replayed = (_updateArrivals[id] ?? 0) - arrivalsBefore;
      if (replayed == 0) {
        // 一条历史都没到：内存里原来那份转录原样留着（reload / close 之后重点开的唯一一份就在这儿）。
        skipReset = true;
        if (fresh) batcher.enqueue(() => sessions.forget(id));
      } else if (fresh) {
        // 重放到一半断了：清空必须生效（否则和旧的叠起来）。刚建的空壳收回，下次点击能重试。
        batcher.enqueue(() => sessions.forget(id));
      }
      // 原先就在内存里 + 重放到一半断了：留下这半份（叠起来更糟），用户可以再点一次重载。
      return false;
    } finally {
      _loadsInFlight.remove(id);
      batcher.release();
    }
  }

  /// ≡ 菜单 Resume（画板 41）：`session/resume` 只恢复 agent 侧上下文，**不重放**——转录用内存里已有的那份。
  Future<void> resumeSession() async {
    hidePopover(threadMenuAnchor);
    final b = bridge;
    final id = sessionId;
    final agent = agentId;
    if (b == null || id == null || agent == null) return;
    final cwd = sessions.maybe(id)?.cwd ?? _cwdOf(id) ?? workspace.project?.path;
    if (cwd == null) return;
    await guard(() async {
      final result = await b.sessionResume(agent, id, cwd);
      sessions.session(id, agentId: agent)
        ..cwd = cwd
        ..applyLoadSession(result);
      _closedSessions.remove(id);
    });
    touch();
  }

  /// ≡ 菜单 Close（画板 41）：`session/close` = 先 cancel 再释放。本地转录留着**只读**，会话仍是当前会话——
  /// 这样 ≡ 菜单里紧接着就能 Resume（`session/resume` 只对没在本连接上活着的会话有效），
  /// 从侧栏再点开它则走 `session/load` 重放。
  Future<void> closeSession() async {
    hidePopover(threadMenuAnchor);
    final b = bridge;
    final id = sessionId;
    final agent = agentId;
    if (b == null || id == null || agent == null) return;
    await guard(() async {
      await _releaseSessionRequests(b, agent, id);
      await b.sessionClose(agent, id);
      _closeEpoch[id] = (_closeEpoch[id] ?? 0) + 1;
      _closedSessions.add(id);
    });
    touch();
  }

  /// close / delete 之前把这个会话挂起的 client 请求收干净——与 [cancel] **同一条规矩**
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
      for (final entry in <JsonMap>[...index.entries]) {
        if (entry['agentId'] != agent) continue;
        // `session/list` 按 cwd 过滤了，本地也只能拿同一个 cwd 的条目去对——否则别的项目下的会话
        // 会被整批判成「agent 侧没有了」（2026-09-16 dsh 实测踩到：21 条全被误标）。
        if (scope != null && entry['cwd'] != scope) continue;
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

  /// 删除 / 改名用的 agentId：优先本地索引里记的那个，退到当前连接。
  String _ownerOf(String sessionId) => _sessionAgent[sessionId] ?? agentId ?? '';

  /// 当前会话写进本地索引（`sessions.json`）：收轮刷消息计数、新会话登记、发消息时打 `updatedAt`
  /// （口径见 [SessionIndex.upsert]）。没有当前会话就什么都不做。
  @override
  Future<void> saveIndex({bool promptSent = false}) async {
    final s = store;
    if (s == null) return;
    await index.upsert(s, agentFallback: agentId ?? '', titleFallback: threadTitle, promptSent: promptSent);
  }

  /// 用户发出一条消息（发送 / Restore / Regenerate）：把索引的 `updatedAt` 打成现在，侧栏这条立刻升到最上面。
  /// **不 await**：`startTurn` 与 `_runTurn` 之间不能有异步间隙，否则这段里 `isRunning` 已是 true 而
  /// `_turnInFlight` 还是 null，Restore / cancel 等不到在途那一轮就会重叠两个 `session/prompt`
  /// （审查 finding high，2026-09-15）。先后由 [SessionIndex] 本地记的发消息时间兜住：收轮那次 [saveIndex] 不靠这条命令回没回来，
  /// 本地记的那份时间总在。写不动只记日志不挡发送——索引是可再生缓存（`rust/settings/src/index.rs`），发送才是正事。
  @override
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
        (inHeader ? threadTitle : '');
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
    // 线程头显示的是 store 的标题，改完要跟着变；不写回去的话 [saveIndex] 收轮时还会拿旧标题把索引盖回去。
    // agent 之后再发 `session_info_update.title` 仍然照单全收（规则 2），改名只管到那时候。
    sessions.maybe(id)?.title = title.trim();
    await guard(() async {
      final owner = _ownerOf(id);
      // 计数与 cwd 都从索引本身取，不从侧栏：侧栏只投影当前 workspace 的条目（[_toSidebar]），
      // 核心的 upsert 是整行替换，这里少给一个字段就是把它抹成默认值。
      await index.upsertEntry(<String, dynamic>{
        'agentId': owner,
        'sessionId': id,
        'title': title.trim(),
        'cwd': _cwdOf(id) ?? workspace.project?.path,
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
    final owner = _ownerOf(sessionId);
    return owner.isNotEmpty && _sessionCapsOf(owner).containsKey('delete');
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
    final owner = _ownerOf(id);
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
      _closedSessions.remove(id);
      _closeEpoch.remove(id);
      _updateArrivals.remove(id);
      _deletedOnAgent.remove(id);
      _sessionAgent.remove(id);
      index.forgetPromptSent(id);
      clearUnread(id);
      sessions.forget(id);
      if (sessionId == id) sessionId = null;
    });
    touch();
  }

  // ---------------------------------------------------------------- 侧栏搜索

  void setSearch(String value) {
    search = value;
    touch();
  }

  void clearSearch() {
    sidebarSearch.clear();
    search = '';
    touch();
  }

  // ---------------------------------------------------------------- agent 终端（画板 23）

  /// `acp/terminal_output`：source = local 的进终端面板，其余（agent / auth）进转录里的终端卡。
  void _onTerminalOutput(JsonMap json) {
    if (json['source'] == 'local') {
      terminals.applyOutput(json);
      return;
    }
    final id = json['terminalId'];
    if (id is! String) return;
    sessions.applyTerminalOutputEvent(json, decode: (b64) => _agentTerminalText.putIfAbsent(id, ChunkedUtf8.new).decode(b64));
    if (json['exitStatus'] is Map) _agentTerminalText.remove(id);
  }

  // ---------------------------------------------------------------- 退出收尾

  /// 应用退出前：释放全部终端、断开全部 agent（核心侧 `core_shutdown`）。超时也放行，别把窗口卡住。
  Future<void> shutdown() async {
    final b = bridge;
    if (b == null) return;
    try {
      await b.coreShutdown().timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('[workbench] shutdown: $e');
    }
  }

  // ---------------------------------------------------------------- 核心给的路径（画板 70）

  /// `registry_list` 回的 `paths`：`AgentsState.refreshRegistry` 每次刷新都经回调交到这里。
  void _applyPaths(Map<Object?, Object?> paths) {
    dataDir = paths['dataDir'] as String? ?? dataDir;
    logPath = paths['logPath'] as String? ?? logPath;
    zedSettingsPath = paths['zedSettingsPath'] as String?;
  }
}

/// 一个终端的 base64 字节流 → 文本：分块 UTF-8 解码，跨块的多字节字符不会被切成 U+FFFD（R3 逐块 `utf8.decode` 的隐患）。
class ChunkedUtf8 {
  ChunkedUtf8() {
    _sink = const Utf8Decoder(allowMalformed: true).startChunkedConversion(StringConversionSink.fromStringSink(_out));
  }

  final StringBuffer _out = StringBuffer();
  late final ByteConversionSink _sink;

  /// 解一块，返回这一块新解出来的文本（可能为空：字符还没凑齐）。
  String decode(String base64) {
    try {
      _sink.add(base64Decode(base64));
    } on FormatException {
      return '';
    }
    final text = _out.toString();
    _out.clear();
    return text;
  }
}
