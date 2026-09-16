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
import '../theme/tokens.dart' as t;
import '../ui/popovers/inline_menus.dart';
import '../ui/popovers/topbar_popovers.dart';
import '../ui/shell/popover_anchor.dart';
import '../ui/shell/shell_common.dart';
import '../ui/shell/sidebar.dart';
import 'core_bridge.dart';
import 'paths.dart';

enum DataSource {
  bridge,
  fixtures;

  /// `--dart-define=DATA_SOURCE=fixtures`。
  static DataSource fromEnvironment() =>
      const String.fromEnvironment('DATA_SOURCE') == 'fixtures' ? DataSource.fixtures : DataSource.bridge;
}

/// 主区显示什么：会话工作台，或 ACP 流量调试（画板 80，从画板 34 的「打开流量面板」进）。
enum MainPage { workbench, traffic }

/// 项目根下算作「规则文件」的名字（docs/design.md § 9 的 Rules 行，清单在 R3 任务卡定）。
const List<String> ruleFileNames = <String>['AGENTS.md', 'CLAUDE.md', '.rules'];

class WorkbenchController extends ChangeNotifier {
  WorkbenchController({required this.source, this.bridge, FlushScheduler? scheduler})
      : _scheduler = scheduler ?? _scheduleOnFrame;

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
  List<ProjectRef> recentProjects = const <ProjectRef>[];
  List<AgentRef> installedAgents = const <AgentRef>[];
  ProjectRef? project;
  String? branch;
  List<BranchRef> branches = const <BranchRef>[];

  /// 顶栏分支区是否渲染：找得到 git 且当前项目是 git 工作区。
  bool branchAreaVisible = false;
  int rulesCount = 0;

  String? agentId;
  String? sessionId;
  final Map<String, String> _sessionAgent = <String, String>{}; // sessionId → agentId

  // ---- UI 态
  bool sidebarCollapsed = false;

  /// 两栏宽度（画板 04 的分栏把手）：启动时从 `ui-state.json` 读回，没存过就是画板缺省。
  double sidebarWidth = t.Geometry.sidebarWidth;
  double rightPanelWidth = t.Geometry.rightPanelWidth;
  final List<ShellTab> openTabs = <ShellTab>[];
  ShellTab? rightTab;
  MainPage page = MainPage.workbench;
  String search = '';
  String? renamingSessionId;
  String? confirmingDeleteId;
  String? lastError;

  /// 输入框里待随下一条 prompt 发出的附件块（`+` 与 `@` 加进来的）。
  final List<JsonMap> pendingBlocks = <JsonMap>[];

  /// `@` / `/` 内联菜单（画板 42）：null = 不显示。
  Widget? inlineMenu;

  // ---- 输入控件
  final TextEditingController composer = TextEditingController();
  final FocusNode composerFocus = FocusNode();
  final TextEditingController sidebarSearch = TextEditingController();
  final FocusNode sidebarSearchFocus = FocusNode();
  final TextEditingController rename = TextEditingController();
  final FocusNode renameFocus = FocusNode();
  final TextEditingController projectSearch = TextEditingController();
  final FocusNode projectSearchFocus = FocusNode();
  final TextEditingController branchInput = TextEditingController();
  final FocusNode branchFocus = FocusNode();
  final TextEditingController modelSearch = TextEditingController();
  final FocusNode modelSearchFocus = FocusNode();
  final TextEditingController trafficFilter = TextEditingController();
  final FocusNode trafficFilterFocus = FocusNode();

  // ---- 弹层锚点（画板 40 / 41）
  final PopoverHandle projectAnchor = PopoverHandle();
  final PopoverHandle branchAnchor = PopoverHandle();
  final PopoverHandle newSessionAnchor = PopoverHandle();
  final PopoverHandle threadMenuAnchor = PopoverHandle();
  final PopoverHandle deleteAnchor = PopoverHandle();
  final PopoverHandle plusAnchor = PopoverHandle();
  final PopoverHandle followAnchor = PopoverHandle();
  final PopoverHandle usageAnchor = PopoverHandle();
  final PopoverHandle modelAnchor = PopoverHandle();
  final PopoverHandle thoughtAnchor = PopoverHandle();
  final PopoverHandle modeAnchor = PopoverHandle();

  final List<StreamSubscription<CoreEventRecord>> _subs = <StreamSubscription<CoreEventRecord>>[];
  bool _disposed = false;

  // ---------------------------------------------------------------- 派生

  SessionStore? get store => sessionId == null ? null : sessions.maybe(sessionId!);
  AgentConnection? get connection => agentId == null ? null : sessions.agents[agentId!];
  bool get hasAgent => agentId != null && sessionId != null;
  bool get isRunning => store?.isRunning ?? false;

  String get agentDisplayName {
    final c = connection;
    return c?.agentTitle ?? c?.agentName ?? agentId ?? 'Agent';
  }

  String get threadTitle {
    if (!hasAgent) return 'No Agent';
    return store?.title ?? 'New $agentDisplayName Thread';
  }

  String get composerPlaceholder =>
      hasAgent ? 'Message to $agentDisplayName , @ to include context , / for commands' : '安装并选择一个 agent 后即可输入';

  /// 侧栏按搜索过滤后的会话（标题子串，大小写不敏感）。
  List<SidebarSession> get visibleSessions {
    if (search.isEmpty) return sidebarSessions;
    final q = search.toLowerCase();
    return <SidebarSession>[
      for (final s in sidebarSessions)
        if (s.title.toLowerCase().contains(q)) s,
    ];
  }

  ConfigOptionWire? optionOf(String category) {
    for (final o in store?.configOptions ?? const <ConfigOptionWire>[]) {
      if (o.category == category) return o;
    }
    return null;
  }

  List<ConfigOptionWire> get booleanOptions => <ConfigOptionWire>[
        for (final o in store?.configOptions ?? const <ConfigOptionWire>[])
          if (o.type == 'boolean') o,
      ];

  /// 未识别 category（不在 mode / model / model_config / thought_level）的 select 条目：扁平兜底（画板 40）。
  List<ConfigOptionWire> get unknownCategoryOptions => <ConfigOptionWire>[
        for (final o in store?.configOptions ?? const <ConfigOptionWire>[])
          if (o.type == 'select' && !_knownCategories.contains(o.category)) o,
      ];

  static const Set<String?> _knownCategories = <String?>{'mode', 'model', 'model_config', 'thought_level'};

  /// 挂起队列的首项（画板 26 的停靠条）。
  TranscriptEntry? get firstPending {
    final s = store;
    if (s == null) return null;
    final list = s.pending.forSession(s.sessionId);
    return list.isEmpty ? null : list.first;
  }

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
      b.on(CoreEvent.sessionUpdate).listen((e) => _enqueue(e, (json) => sessions.applySessionUpdateEnvelope(json))),
      b.on(CoreEvent.clientRequest).listen((e) => _enqueue(e, (json) => sessions.applyClientRequestEnvelope(json))),
      b.on(CoreEvent.agentState).listen((e) => _enqueue(e, (json) => sessions.applyAgentState(json))),
      b.on(CoreEvent.terminalOutput)
          .listen((e) => _enqueue(e, (json) => sessions.applyTerminalOutputEvent(json, decode: _decodeBase64))),
      b.on(CoreEvent.traffic).listen((e) {
        final json = e.json;
        if (json != null) traffic.apply(json);
      }),
    ]);
    sessions.addListener(notifyListeners);
    await _guard(() async {
      await b.init(defaultDataDir());
      await refreshAgents();
      await refreshSessionIndex();
      await _restoreLastProject();
      await _restoreUiState();
    });
    notifyListeners();
  }

  // ---------------------------------------------------------------- 分栏宽度（画板 04）

  /// 读回上次拖出来的宽度。没存过 / 存的是垃圾 → 保持画板缺省；夹取一遍再用，
  /// 免得改过 token 之后旧文件里的值落在范围外。
  Future<void> _restoreUiState() async {
    final b = bridge;
    if (b == null) return;
    final state = await b.uiStateGet();
    final side = state['sidebarWidth'];
    final right = state['rightPanelWidth'];
    if (side is num) sidebarWidth = _clampSidebar(side.toDouble());
    if (right is num) rightPanelWidth = _clampRightPanel(right.toDouble());
  }

  static double _clampSidebar(double w) => w.clamp(t.Geometry.sidebarMinWidth, t.Geometry.sidebarMaxWidth);
  static double _clampRightPanel(double w) => w.clamp(t.Geometry.rightPanelMinWidth, t.Geometry.rightPanelMaxWidth);

  /// 拖拽增量（正 = 变宽）。夹取在这里做，widget 只报位移。
  void resizeSidebar(double delta) {
    final next = _clampSidebar(sidebarWidth + delta);
    if (next == sidebarWidth) return;
    sidebarWidth = next;
    notifyListeners();
  }

  void resizeRightPanel(double delta) {
    final next = _clampRightPanel(rightPanelWidth + delta);
    if (next == rightPanelWidth) return;
    rightPanelWidth = next;
    notifyListeners();
  }

  void resetSidebarWidth() {
    if (sidebarWidth == t.Geometry.sidebarWidth) return;
    sidebarWidth = t.Geometry.sidebarWidth;
    notifyListeners();
    saveUiState();
  }

  void resetRightPanelWidth() {
    if (rightPanelWidth == t.Geometry.rightPanelWidth) return;
    rightPanelWidth = t.Geometry.rightPanelWidth;
    notifyListeners();
    saveUiState();
  }

  /// 松手才落盘：拖拽途中每帧写文件没有意义。
  Future<void> saveUiState() async {
    final b = bridge;
    if (b == null) return;
    await _guard(() => b.uiStateSet(<String, dynamic>{
          'sidebarWidth': sidebarWidth,
          'rightPanelWidth': rightPanelWidth,
        }));
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
    if (cwd != null) project = ProjectRef(path: cwd, name: cwd.split(RegExp(r'[\\/]')).last);
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

  static String _decodeBase64(String b64) {
    try {
      return utf8.decode(base64Decode(b64), allowMalformed: true);
    } on FormatException {
      return '';
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subs) {
      s.cancel();
    }
    sessions.removeListener(notifyListeners);
    for (final c in <TextEditingController>[composer, sidebarSearch, rename, projectSearch, branchInput, modelSearch, trafficFilter]) {
      c.dispose();
    }
    for (final f in <FocusNode>[composerFocus, sidebarSearchFocus, renameFocus, projectSearchFocus, branchFocus, modelSearchFocus, trafficFilterFocus]) {
      f.dispose();
    }
    super.dispose();
  }

  /// 命令统一的错误边界：桥抛出的 `BridgeError` 记到 [lastError]，不让它掀掉整棵树。
  Future<T?> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (e) {
      lastError = e.toString();
      debugPrint('[workbench] $e');
      if (!_disposed) notifyListeners();
      return null;
    }
  }

  void _touch() {
    if (!_disposed) notifyListeners();
  }

  /// 组合根里的纯 UI 变化（弹层里的搜索框输入等）需要重建时调它。
  void refresh() => _touch();

  // ---------------------------------------------------------------- 本地索引与项目

  Future<void> refreshAgents() async {
    final b = bridge;
    if (b == null) return;
    final settings = await b.agentSettingsGet();
    final servers = settings['agent_servers'];
    installedAgents = <AgentRef>[
      if (servers is Map)
        for (final id in servers.keys.cast<String>())
          // 名字用 settings 里的键：协议里没有「展示名」，连上之后线程头才从 agentInfo 取（规则 2）。
          AgentRef(id: id, name: id),
    ];
  }

  Future<void> refreshSessionIndex() async {
    final b = bridge;
    if (b == null) return;
    final result = await b.sessionIndexList();
    sidebarSessions = _toSidebar(result['sessions']);
  }

  /// 把 `sessions.json` 的一条映射成侧栏项，**顺带把 agentId 记进 [_sessionAgent]**：
  /// 重启后点侧栏 / 改名 / 删除都要用 (agentId, sessionId) 这一对键，只靠 `newSession` 时写入
  /// 会让重启后的删除按空 agentId 去匹配、删不掉（审查 finding P2，2026-09-15）。
  List<SidebarSession> _toSidebar(Object? raw) {
    final out = <SidebarSession>[];
    if (raw is! List) return out;
    for (final item in raw) {
      if (item is! Map) continue;
      final sessionId = item['sessionId'] as String? ?? '';
      if (sessionId.isEmpty) continue;
      final owner = item['agentId'] as String?;
      if (owner != null && owner.isNotEmpty) _sessionAgent[sessionId] = owner;
      out.add(SidebarSession(
        id: sessionId,
        title: item['title'] as String? ?? sessionId,
        updatedAt: DateTime.fromMillisecondsSinceEpoch((item['updatedAt'] as num?)?.toInt() ?? 0),
        messageCount: (item['messageCount'] as num?)?.toInt() ?? 0,
        canDelete: _sessionCaps.containsKey('delete'),
      ));
    }
    return out;
  }

  JsonMap get _sessionCaps {
    final caps = connection?.agentCapabilities?['sessionCapabilities'];
    return caps is Map ? caps.cast<String, dynamic>() : const <String, dynamic>{};
  }

  /// 启动时恢复最近一次打开的项目（没有就留空，顶栏显示 `—`，新建会话前要先选项目）。
  Future<void> _restoreLastProject() async {
    final b = bridge;
    if (b == null) return;
    final result = await b.workspaceRecent();
    recentProjects = _toProjects(result['projects']);
    if (recentProjects.isNotEmpty) await openProject(recentProjects.first);
  }

  List<ProjectRef> _toProjects(Object? raw) => <ProjectRef>[
        if (raw is List)
          for (final p in raw)
            if (p is Map) ProjectRef(path: p['path'] as String? ?? '', name: p['name'] as String? ?? ''),
      ];

  Future<void> openProject(ProjectRef ref) async {
    projectAnchor.hide();
    final b = bridge;
    if (b == null) {
      project = ref;
      _touch();
      return;
    }
    await _guard(() async {
      final result = await b.workspaceOpen(ref.path);
      final p = result['project'];
      project = p is Map ? ProjectRef(path: p['path'] as String? ?? ref.path, name: p['name'] as String? ?? ref.name) : ref;
      recentProjects = _toProjects(result['projects']);
      await refreshBranches();
      await refreshRules();
    });
    _touch();
  }

  Future<void> refreshBranches() async {
    final b = bridge;
    final cwd = project?.path;
    if (b == null || cwd == null) return;
    final result = await b.gitBranches(cwd);
    final available = result['available'] == true;
    final isRepo = result['isRepo'] == true;
    branchAreaVisible = available && isRepo;
    branch = branchAreaVisible ? result['current'] as String? : null;
    final raw = result['branches'];
    branches = <BranchRef>[
      if (raw is List)
        for (final x in raw)
          if (x is Map)
            BranchRef(
              name: x['name'] as String? ?? '',
              author: x['author'] as String?,
              when: x['when'] as String?,
              subject: x['subject'] as String?,
            ),
    ];
  }

  /// Rules 行（画板 30 / 40）：项目根下规则文件的计数。
  Future<void> refreshRules() async {
    final b = bridge;
    final cwd = project?.path;
    if (b == null || cwd == null) return;
    final listing = await b.fsListDir(cwd, cwd);
    final entries = listing['entries'];
    var count = 0;
    if (entries is List) {
      for (final e in entries) {
        if (e is Map && e['isDir'] != true && ruleFileNames.contains(e['name'])) count++;
      }
    }
    rulesCount = count;
  }

  Future<void> switchBranch(String name) async {
    branchAnchor.hide();
    branchInput.clear();
    final b = bridge;
    final cwd = project?.path;
    if (b == null || cwd == null) return;
    await _guard(() async {
      await b.gitSwitch(cwd, name);
      await refreshBranches();
    });
    _touch();
  }

  Future<void> createBranch(String name) async {
    branchAnchor.hide();
    branchInput.clear();
    final b = bridge;
    final cwd = project?.path;
    if (b == null || cwd == null) return;
    await _guard(() async {
      await b.gitCreateBranch(cwd, name);
      await refreshBranches();
    });
    _touch();
  }

  // ---------------------------------------------------------------- 会话

  Future<void> newSession(AgentRef agent) async {
    newSessionAnchor.hide();
    final b = bridge;
    final cwd = project?.path;
    if (b == null || cwd == null) {
      lastError = cwd == null ? '先选一个项目目录，新会话的 cwd 从它来' : null;
      _touch();
      return;
    }
    await _guard(() async {
      await b.agentConnect(agent.id, cwd: cwd);
      final result = await b.sessionNew(agent.id, cwd);
      final sid = result['sessionId'];
      if (sid is! String) throw StateError('session/new 没有返回 sessionId');
      agentId = agent.id;
      sessionId = sid;
      _sessionAgent[sid] = agent.id;
      sessions.session(sid, agentId: agent.id)
        ..cwd = cwd
        ..applyNewSession(result);
      page = MainPage.workbench;
      await _saveIndex();
    });
    _touch();
  }

  /// 重载 agent（画板 01 / 41）：断开 + 重拉 + 新会话；旧会话的转录留在内存里只读（R6 接 `session/load` 后改成自动 load）。
  Future<void> reloadAgent() async {
    threadMenuAnchor.hide();
    final id = agentId;
    final b = bridge;
    final cwd = project?.path;
    if (id == null || b == null || cwd == null) return;
    await _guard(() async {
      await b.agentDisconnect(id);
      await newSession(AgentRef(id: id, name: id));
    });
  }

  void selectSession(String id) {
    if (page == MainPage.traffic) page = MainPage.workbench;
    sessionId = id;
    agentId = _sessionAgent[id] ?? agentId;
    _touch();
  }

  /// 删除 / 改名用的 agentId：优先本地索引里记的那个，退到当前连接。
  String _ownerOf(String sessionId) => _sessionAgent[sessionId] ?? agentId ?? '';

  Future<void> _saveIndex() async {
    final b = bridge;
    final s = store;
    if (b == null || s == null) return;
    final result = await b.sessionIndexUpsert(<String, dynamic>{
      'agentId': s.agentId ?? agentId ?? '',
      'sessionId': s.sessionId,
      'title': s.title ?? threadTitle,
      'cwd': s.cwd,
      'messageCount': s.entries.whereType<MessageEntry>().length,
    });
    sidebarSessions = _toSidebar(result['sessions']);
  }

  void startRename(String id) {
    renamingSessionId = id;
    final current = sidebarSessions.where((s) => s.id == id).map((s) => s.title).firstOrNull ?? '';
    rename.text = current;
    _touch();
  }

  void cancelRename() {
    renamingSessionId = null;
    _touch();
  }

  Future<void> commitRename(String title) async {
    final id = renamingSessionId;
    renamingSessionId = null;
    final b = bridge;
    if (id == null || b == null || title.trim().isEmpty) {
      _touch();
      return;
    }
    await _guard(() async {
      final owner = _ownerOf(id);
      final existing = sidebarSessions.where((s) => s.id == id).firstOrNull;
      final result = await b.sessionIndexUpsert(<String, dynamic>{
        'agentId': owner,
        'sessionId': id,
        'title': title.trim(),
        'cwd': sessions.maybe(id)?.cwd ?? project?.path,
        'messageCount': existing?.messageCount ?? 0,
      });
      sidebarSessions = _toSidebar(result['sessions']);
    });
    _touch();
  }

  void askDelete(String id) {
    confirmingDeleteId = id;
    _touch();
  }

  void cancelDelete() {
    confirmingDeleteId = null;
    deleteAnchor.hide();
    _touch();
  }

  /// 本轮只从本地索引移除（向 agent 发 `session/delete` 是 R6）。
  Future<void> deleteSession(String id) async {
    confirmingDeleteId = null;
    deleteAnchor.hide();
    final b = bridge;
    if (b == null) return;
    await _guard(() async {
      final result = await b.sessionIndexRemove(_ownerOf(id), id);
      sidebarSessions = _toSidebar(result['sessions']);
      if (sessionId == id) sessionId = null;
    });
    _touch();
  }

  // ---------------------------------------------------------------- 一轮对话

  Future<void> send() async {
    final s = store;
    final b = bridge;
    final id = agentId;
    if (s == null || b == null || id == null) return;
    final text = composer.text;
    final blocks = _promptBlocks(text);
    if (blocks.isEmpty) return;
    composer.clear();
    pendingBlocks.clear();
    inlineMenu = null;
    s.startTurn(<ContentBlockWire>[for (final b in blocks) ContentBlockWire(b)]);
    await _runTurn(b, id, s, blocks);
  }

  /// 在途的那一轮（`session/prompt` 还没返回）。Restore / Regenerate 要先等它结束，
  /// 否则同一个 session 上会重叠两个 `session/prompt`，先返回的那次会把 `endTurn` 打到新开的轮上
  /// （审查 finding high，2026-09-15）。
  Future<void>? _turnInFlight;

  Future<void> _runTurn(CoreCommands b, String id, SessionStore s, List<JsonMap> blocks) async {
    final turn = () async {
      try {
        final result = await b.sessionPrompt(id, s.sessionId, blocks);
        s.endTurn(
          stopReason: result['stopReason'] as String?,
          usage: result['usage'] is Map ? (result['usage'] as Map).cast<String, dynamic>() : null,
        );
        await _saveIndex();
      } catch (e) {
        // 失败也必须收轮：不收的话 `currentTurn` 一直挂着，线程头永远转 spinner、发送位永远是停止键，
        // 之后的 Restore 还会拿新连接去操作一个 agent 侧已不存在的 sessionId（审查第 2 轮 finding P2，2026-09-15）。
        // `stopReason` 留空：连接断了本来就没有协议给的结束值，不编一个（规则 2）。
        s.endTurn();
        lastError = e.toString();
        debugPrint('[workbench] session/prompt failed: $e');
      }
    }();
    _turnInFlight = turn;
    try {
      await turn;
    } finally {
      if (identical(_turnInFlight, turn)) _turnInFlight = null;
    }
    _touch();
  }

  /// 输入框正文 + 附件块。`/` 命令按 unstructured 口径原样作为一条 text 块发出（docs/design.md § 3）。
  List<JsonMap> _promptBlocks(String text) {
    final trimmed = text.trim();
    return <JsonMap>[
      if (trimmed.isNotEmpty) <String, dynamic>{'type': 'text', 'text': text},
      ...pendingBlocks,
    ];
  }

  Future<void> cancel() async {
    final s = store;
    final b = bridge;
    final id = agentId;
    if (s == null || b == null || id == null) return;
    await _guard(() async {
      // 权限请求由核心自动回 cancelled（api.rs 的契约），前端再回会撞 unknown_request；
      // **elicitation 核心不管**，不回 agent 会一直等（审查 finding high，2026-09-15）。
      await b.sessionCancel(id, s.sessionId);
      final result = s.cancel();
      for (final requestId in result.cancelledElicitationIds) {
        await _guard(() => b.acpRespond(id, requestId, PendingQueue.cancelledAction));
      }
    });
    _touch();
  }

  Future<void> answerPermission(String requestId, String optionId) async {
    final s = store;
    final b = bridge;
    final id = agentId;
    if (s == null) return;
    final payload = s.answerPermission(requestId, optionId);
    if (payload == null || b == null || id == null) return;
    await _guard(() => b.acpRespond(id, requestId, payload));
  }

  Future<void> answerElicitation(String requestId, String action, JsonMap? content) async {
    final s = store;
    final b = bridge;
    final id = agentId;
    if (s == null) return;
    final payload = s.answerElicitation(requestId, action, content: content);
    if (payload == null || b == null || id == null) return;
    await _guard(() => b.acpRespond(id, requestId, payload));
  }

  /// Restore Checkpoint（画板 10）与用户气泡的 Regenerate（画板 11）：本地截断 + 同会话重发。
  /// **截断范围内仍挂起的请求必须回应**，否则 agent 一直等着：permission 回 cancelled outcome、
  /// elicitation 回 cancelled action（`RestoreResult` 的两组 id）。
  Future<void> restore(TurnEntry turn, {String? newText}) async {
    final s = store;
    if (s == null) return;
    // 先把在途的那一轮收干净（发 cancel 并等 session/prompt 真正返回），再截断重发。
    if (s.isRunning) {
      await cancel();
      await _turnInFlight;
    }
    final result = s.restoreTo(turn.id);
    if (result == null) return;
    await _respondCancelled(result);
    final blocks = <JsonMap>[
      if (newText != null && newText.trim().isNotEmpty)
        <String, dynamic>{'type': 'text', 'text': newText}
      else
        for (final b in result.turn.prompt) b.json,
    ];
    if (blocks.isEmpty) return;
    final b = bridge;
    final id = agentId;
    if (b == null || id == null) {
      _touch();
      return;
    }
    s.startTurn(<ContentBlockWire>[for (final x in blocks) ContentBlockWire(x)]);
    await _runTurn(b, id, s, blocks);
  }

  /// 把被截断的挂起请求逐条回应（顺序无所谓，但一条都不能漏）。
  Future<void> _respondCancelled(RestoreResult result) async {
    final b = bridge;
    final id = agentId;
    if (b == null || id == null) return;
    for (final requestId in result.cancelledRequestIds) {
      await _guard(() => b.acpRespond(id, requestId, PendingQueue.cancelledOutcome));
    }
    for (final requestId in result.cancelledElicitationIds) {
      await _guard(() => b.acpRespond(id, requestId, PendingQueue.cancelledAction));
    }
  }

  // ---------------------------------------------------------------- 会话配置

  Future<void> setConfigOption(String configId, JsonMap value) async {
    modelAnchor.hide();
    thoughtAnchor.hide();
    modeAnchor.hide();
    final s = store;
    final b = bridge;
    final id = agentId;
    if (s == null || b == null || id == null) return;
    await _guard(() async {
      final result = await b.sessionSetConfigOption(id, s.sessionId, configId, value);
      s.applyConfigOptionsResponse(result);
    });
    _touch();
  }

  Future<void> selectConfigValue(String configId, String value) =>
      setConfigOption(configId, <String, dynamic>{'type': 'select', 'value': value});

  Future<void> toggleConfigBoolean(String configId, bool value) =>
      setConfigOption(configId, <String, dynamic>{'type': 'boolean', 'value': value});

  // ---------------------------------------------------------------- 输入框的 @ 与 /

  /// 输入框正文变化：按最后一个 token 决定要不要出内联菜单（画板 42）。
  Future<void> onComposerChanged(String text) async {
    final token = _activeToken(text);
    if (token == null) {
      if (inlineMenu != null) {
        inlineMenu = null;
        _touch();
      }
      return;
    }
    if (token.startsWith('/')) {
      final q = token.substring(1).toLowerCase();
      final commands = <AvailableCommandWire>[
        for (final c in store?.commands ?? const <AvailableCommandWire>[])
          if (q.isEmpty || (c.name ?? '').toLowerCase().startsWith(q)) c,
      ];
      inlineMenu = commands.isEmpty ? null : SlashCommandMenu(commands: commands, onPick: _pickCommand);
      _touch();
      return;
    }
    await _updateMentionMenu(token.substring(1));
  }

  /// 光标处的 `@` / `/` token：只在正文开头的 `/` 或空白后的 `@` 上触发。
  String? _activeToken(String text) {
    if (text.isEmpty) return null;
    if (text.startsWith('/') && !text.contains(RegExp(r'\s'))) return text;
    final m = RegExp(r'(?:^|\s)(@[^\s]*)$').firstMatch(text);
    return m?.group(1);
  }

  Future<void> _updateMentionMenu(String query) async {
    final b = bridge;
    final cwd = project?.path;
    if (b == null || cwd == null || query.isEmpty) {
      inlineMenu = null;
      _touch();
      return;
    }
    await _guard(() async {
      final result = await b.fsSearch(cwd, query);
      final files = _toMentions(result['files']);
      final dirs = _toMentions(result['directories']);
      inlineMenu = files.isEmpty && dirs.isEmpty
          ? null
          : MentionMenu(files: files, directories: dirs, onPick: _pickMention);
    });
    _touch();
  }

  List<MentionItem> _toMentions(Object? raw) => <MentionItem>[
        if (raw is List)
          for (final e in raw)
            if (e is Map)
              MentionItem(
                path: e['path'] as String? ?? '',
                name: e['name'] as String? ?? '',
                parent: e['parent'] as String? ?? '',
                isDirectory: e['isDir'] == true,
              ),
      ];

  void _pickCommand(AvailableCommandWire command) {
    composer.text = '/${command.name ?? ''} ';
    composer.selection = TextSelection.collapsed(offset: composer.text.length);
    inlineMenu = null;
    composerFocus.requestFocus();
    _touch();
  }

  void _pickMention(MentionItem item) {
    final text = composer.text;
    final m = RegExp(r'(?:^|\s)(@[^\s]*)$').firstMatch(text);
    final replaced = m == null ? '$text@${item.name} ' : '${text.substring(0, m.start + (m.group(0)!.length - m.group(1)!.length))}@${item.name} ';
    composer.text = replaced;
    composer.selection = TextSelection.collapsed(offset: replaced.length);
    pendingBlocks.add(<String, dynamic>{
      'type': 'resource_link',
      'uri': _fileUri(item.path),
      'name': item.name,
    });
    inlineMenu = null;
    composerFocus.requestFocus();
    _touch();
  }

  static String _fileUri(String path) => Uri.file(path, windows: Platform.isWindows).toString();

  // ---------------------------------------------------------------- `+` 的四项（画板 40）

  void addResourceLink(String path, String name) {
    pendingBlocks.add(<String, dynamic>{'type': 'resource_link', 'uri': _fileUri(path), 'name': name});
    _appendToComposer('@$name');
  }

  void addImage(String base64Data, String mimeType) {
    pendingBlocks.add(<String, dynamic>{'type': 'image', 'data': base64Data, 'mimeType': mimeType});
    _appendToComposer('[image]');
  }

  void addEmbeddedResource(String uri, String text, {String mimeType = 'text/plain'}) {
    pendingBlocks.add(<String, dynamic>{
      'type': 'resource',
      'resource': <String, dynamic>{'uri': uri, 'mimeType': mimeType, 'text': text},
    });
    _appendToComposer('[${Uri.parse(uri).pathSegments.isEmpty ? uri : Uri.parse(uri).pathSegments.last}]');
  }

  void _appendToComposer(String label) {
    final sep = composer.text.isEmpty || composer.text.endsWith(' ') ? '' : ' ';
    composer.text = '${composer.text}$sep$label ';
    composer.selection = TextSelection.collapsed(offset: composer.text.length);
    _touch();
  }

  /// 本地转录文本（`+` 的 Threads）：把当前会话的消息拼成一份 embedded resource。
  String transcriptText() {
    final s = store;
    if (s == null) return '';
    final buffer = StringBuffer();
    for (final e in s.entries) {
      if (e is! MessageEntry) continue;
      buffer.writeln('[${e.role.name}] ${e.blocks.map((b) => b.text ?? '').where((t) => t.isNotEmpty).join('')}');
    }
    return buffer.toString();
  }

  // ---------------------------------------------------------------- 壳的 UI 动作

  void toggleSidebar() {
    sidebarCollapsed = !sidebarCollapsed;
    _touch();
  }

  void setSearch(String value) {
    search = value;
    _touch();
  }

  void clearSearch() {
    sidebarSearch.clear();
    search = '';
    _touch();
  }

  void openTab(ShellTab tab) {
    if (!openTabs.contains(tab)) openTabs.add(tab);
    rightTab = tab;
    _touch();
  }

  void closeTab(ShellTab tab) {
    openTabs.remove(tab);
    if (rightTab == tab) rightTab = openTabs.isEmpty ? null : openTabs.last;
    _touch();
  }

  void closeRightPanel() {
    openTabs.clear();
    rightTab = null;
    _touch();
  }

  void toggleRightPanel() {
    if (rightTab != null) {
      closeRightPanel();
    } else {
      openTab(ShellTab.files);
    }
  }

  void openTraffic() {
    page = MainPage.traffic;
    _touch();
  }

  void openWorkbench() {
    page = MainPage.workbench;
    _touch();
  }

  Future<void> authenticate(String methodId) async {
    final b = bridge;
    final id = agentId ?? connection?.agentId;
    if (b == null || id == null) return;
    await _guard(() => b.authenticate(id, methodId));
    _touch();
  }
}
