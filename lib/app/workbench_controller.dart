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
import '../projection/registry.dart';
import '../projection/session_store.dart';
import '../projection/tool_calls.dart';
import '../projection/traffic.dart';
import '../projection/wire.dart';
import '../theme/tokens.dart' as t;
import '../ui/popovers/inline_menus.dart';
import '../ui/popovers/topbar_popovers.dart';
import '../ui/registry/auth_page.dart';
import '../ui/settings/settings_page.dart';
import '../ui/shell/popover_anchor.dart';
import '../ui/shell/right_panel.dart';
import '../ui/shell/shell_common.dart';
import '../ui/shell/sidebar.dart';
import 'core_bridge.dart';
import 'files_state.dart';
import 'local_terminals.dart';
import 'paths.dart';

enum DataSource {
  bridge,
  fixtures;

  /// `--dart-define=DATA_SOURCE=fixtures`。
  static DataSource fromEnvironment() =>
      const String.fromEnvironment('DATA_SOURCE') == 'fixtures' ? DataSource.fixtures : DataSource.bridge;
}

/// 主区显示什么：会话工作台、ACP 流量调试（画板 80，从画板 34 的「打开流量面板」进）、设置（画板 70，从侧栏底部「设置」进）。
enum MainPage { workbench, traffic, settings }

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

  /// 右栏当前是某个本地终端标签（画板 61）；null = 显示 [rightTab] 那个面板。
  String? activeTerminalId;

  /// Follow（画板 40 的提示；客户端本地开关）：开着时 `locations[]` 到达即在文件面板定位。
  bool follow = false;
  String? _lastFollowed;

  /// 文件面板（画板 60）与终端面板（画板 61）的接线状态（R4）。
  late final FilesState files = FilesState(bridge: bridge);
  late final LocalTerminals terminals = LocalTerminals(bridge: bridge);

  /// agent 终端（`acp/terminal_output` source = agent / auth）的分块 UTF-8 解码：跨块的多字节字符不能逐块 `utf8.decode`。
  final Map<String, ChunkedUtf8> _agentTerminalText = <String, ChunkedUtf8>{};
  MainPage page = MainPage.workbench;
  String search = '';
  String? renamingSessionId;
  String? confirmingDeleteId;
  String? lastError;

  /// 输入框里待随下一条 prompt 发出的附件块（`+` 与 `@` 加进来的）。
  final List<JsonMap> pendingBlocks = <JsonMap>[];

  /// `@` / `/` 内联菜单（画板 42）：null = 不显示。
  Widget? inlineMenu;

  // ---- registry 面板（画板 50 / 51，R5）
  final RegistryState registry = RegistryState();
  final TextEditingController registrySearch = TextEditingController();
  final FocusNode registrySearchFocus = FocusNode();
  String registryQuery = '';
  RegistryFilter registryFilter = RegistryFilter.all;

  /// 失败态展开了日志块的条目（「查看日志」切换）。
  final Set<String> registryShowLog = <String>{};

  /// 核心给的几个路径（画板 70）：`core_init` / `registry_list` 的 `paths`。
  String? dataDir;
  String? logPath;
  String? zedSettingsPath;

  // ---- 认证页（画板 52，R5）：右栏 Agents 标签里、对应 agent 的一页
  String? authAgentId;
  AuthPhase authPhase = AuthPhase.choose;
  String? authMethodId;
  String? authError;
  String? authTerminalLabel;
  String? _authRetryCwd;
  /// 认证页的「代际」：`openAuth` / `closeAuth` 各加一；在途的 `startAuth` 每个 await 之后核对，页已收起或重开就不再改状态
  /// （审查第 2 轮 P2：否则旧的失败会画到新页上、旧的成功会把新页清掉并切走工作台）。
  int _authGeneration = 0;

  /// 无会话阶段的 URL elicitation（挂起 / 已打开 / 已完成都留在页上，直到离开认证页）。
  final List<ElicitationEntry> authElicitations = <ElicitationEntry>[];

  // ---- 设置页（画板 70，R5）
  String? settingsExpandedId;
  String? settingsEditingId;
  String? zedImportResult;
  late final CustomEditFields settingsEdit = CustomEditFields(
    command: TextEditingController(),
    args: TextEditingController(),
    env: TextEditingController(),
    focus: FocusNode(),
  );

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
      b.on(CoreEvent.sessionUpdate).listen((e) => _enqueue(e, (json) {
            sessions.applySessionUpdateEnvelope(json);
            _followLocations(json);
          })),
      b.on(CoreEvent.clientRequest).listen((e) => _enqueue(e, (json) => sessions.applyClientRequestEnvelope(json))),
      b.on(CoreEvent.agentState).listen((e) => _enqueue(e, (json) => sessions.applyAgentState(json))),
      b.on(CoreEvent.terminalOutput).listen((e) => _enqueue(e, _onTerminalOutput)),
      b.on(CoreEvent.traffic).listen((e) {
        final json = e.json;
        if (json != null) traffic.apply(json);
      }),
      b.on(CoreEvent.registryProgress).listen(_onRegistryProgress),
    ]);
    sessions.addListener(notifyListeners);
    sessions.pending.addListener(_onPendingChanged);
    files.addListener(notifyListeners);
    terminals.addListener(notifyListeners);
    await _guard(() async {
      final info = await b.init(defaultDataDir());
      dataDir = info['dataDir'] as String? ?? defaultDataDir();
      logPath = info['logPath'] as String?;
      await refreshRegistry();
      await refreshAgents();
      await refreshSessionIndex();
      await _restoreLastProject();
      await _restoreUiState();
    });
    notifyListeners();
    // registry.json 的联网刷新（1 小时节流）放到后台：断网时 30 秒超时不能挡住启动。
    unawaited(refreshRegistry(network: true));
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


  @override
  void dispose() {
    _disposed = true;
    for (final s in _subs) {
      s.cancel();
    }
    sessions.removeListener(notifyListeners);
    sessions.pending.removeListener(_onPendingChanged);
    files.removeListener(notifyListeners);
    terminals.removeListener(notifyListeners);
    files.dispose();
    terminals.dispose();
    for (final c in <TextEditingController>[
      composer, sidebarSearch, rename, projectSearch, branchInput, modelSearch, trafficFilter, registrySearch,
      settingsEdit.command, settingsEdit.args, settingsEdit.env,
    ]) {
      c.dispose();
    }
    for (final f in <FocusNode>[
      composerFocus, sidebarSearchFocus, renameFocus, projectSearchFocus, branchFocus, modelSearchFocus, trafficFilterFocus,
      registrySearchFocus, settingsEdit.focus,
    ]) {
      f.dispose();
    }
    registry.dispose();
    super.dispose();
  }

  /// 命令统一的错误边界：桥抛出的 `BridgeError` 记到 [lastError]，不让它掀掉整棵树。
  Future<T?> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (e) {
      lastError = describeError(e);
      debugPrint('[workbench] ${describeError(e)}');
      if (!_disposed) notifyListeners();
      return null;
    }
  }

  void _touch() {
    if (!_disposed) notifyListeners();
  }

  /// 关弹层：没在显示的不调 `hide()`——`OverlayPortalController.hide()` 在没挂到 widget 树、也没 show 过时会 assert
  /// （无头实跑与单测里没有 Overlay；产品路径永远有锚点，`isShowing` 在未挂载时不会 assert）。
  static void _hide(PopoverHandle handle) {
    if (handle.isShowing) handle.hide();
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
          // 名字：registry 型用 registry.json 的展示名（R5），custom 型用 settings 里的键；连上之后线程头再从 agentInfo 取（规则 2）。
          AgentRef(id: id, name: registry.byId(id)?.name ?? id),
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
    _hide(projectAnchor);
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
      await files.setProject(project?.path);
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
    _hide(branchAnchor);
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
    _hide(branchAnchor);
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
    _hide(newSessionAnchor);
    final b = bridge;
    final cwd = project?.path;
    if (b == null || cwd == null) {
      lastError = cwd == null ? '先选一个项目目录，新会话的 cwd 从它来' : null;
      _touch();
      return;
    }
    try {
      await b.agentConnect(agent.id, cwd: cwd);
      await _createSession(agent.id, cwd);
    } on CoreCommandError catch (e) {
      lastError = e.message;
      switch (e.code) {
        // `session/new` 回 -32000：认证页（画板 52），成功后自动重试这个 cwd 的新会话（docs/design.md § 5 第 5 条）。
        case 'auth_required':
          await openAuth(agent.id, retryCwd: cwd);
        // npx 型 agent 缺 Node：Agents 面板顶上的受管 Node 提示卡（画板 51）。
        case 'node_missing':
          openTab(ShellTab.agents);
        default:
          break;
      }
    } catch (e) {
      lastError = e.toString();
      debugPrint('[workbench] newSession: $e');
    }
    _touch();
  }

  /// 已连接的 agent 上开一个会话并切过去（`newSession` 的后半段；认证成功后的自动重试也走这里）。
  Future<void> _createSession(String agent, String cwd) async {
    final b = bridge;
    if (b == null) return;
    try {
      _adoptSession(agent, cwd, await b.sessionNew(agent, cwd));
    } finally {
      // 核心按 session/new 的结果回写了认证状态（已登录 / 需要认证），面板上的徽章跟着刷（画板 50 / 51 / 70）。
      unawaited(refreshRegistry());
    }
    await _saveIndex();
  }

  /// `session/new` 的结果落到投影层并切成当前会话。
  void _adoptSession(String agent, String cwd, JsonMap result) {
    final sid = result['sessionId'];
    if (sid is! String) throw StateError('session/new 没有返回 sessionId');
    agentId = agent;
    sessionId = sid;
    _sessionAgent[sid] = agent;
    sessions.session(sid, agentId: agent)
      ..cwd = cwd
      ..applyNewSession(result);
    page = MainPage.workbench;
  }

  /// 重载 agent（画板 01 / 41）：断开 + 重拉 + 新会话；旧会话的转录留在内存里只读（R6 接 `session/load` 后改成自动 load）。
  Future<void> reloadAgent() async {
    _hide(threadMenuAnchor);
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
    page = MainPage.workbench;
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
    _hide(deleteAnchor);
    _touch();
  }

  /// 本轮只从本地索引移除（向 agent 发 `session/delete` 是 R6）。
  Future<void> deleteSession(String id) async {
    confirmingDeleteId = null;
    _hide(deleteAnchor);
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
        lastError = describeError(e);
        debugPrint('[workbench] session/prompt failed: ${describeError(e)}');
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
    _hide(modelAnchor);
    _hide(thoughtAnchor);
    _hide(modeAnchor);
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

  // ---------------------------------------------------------------- 右栏（画板 03 / 50 / 60 / 61）

  /// 标签条：面板标签在前、每个本地终端一个标签在后（画板 60 / 61）。侧栏的「终端」入口不作面板标签，它开的是终端实例。
  List<PanelTab> get panelTabs => <PanelTab>[
        for (final tab in openTabs) PanelTab.shell(tab),
        for (final term in terminals.tabs) PanelTab.terminal(term.id, term.title),
      ];

  PanelTab? get activePanel {
    final tid = activeTerminalId;
    if (tid != null) {
      final term = terminals.byId(tid);
      if (term != null) return PanelTab.terminal(term.id, term.title);
    }
    return rightTab == null ? null : PanelTab.shell(rightTab!);
  }

  bool get rightPanelOpen => activePanel != null;

  /// 侧栏底部导航 / 右栏标签：设置是主区页面（画板 70）；终端开一个本地 shell 标签（已有就切到最近那个，画板 61）；
  /// 文件 / Agents 是右栏标签（画板 03 / 50 / 60）。
  void openTab(ShellTab tab) {
    if (tab == ShellTab.settings) {
      openSettings();
      return;
    }
    if (tab == ShellTab.terminal) {
      openTerminalTab();
      return;
    }
    if (!openTabs.contains(tab)) openTabs.add(tab);
    rightTab = tab;
    activeTerminalId = null;
    _touch();
  }

  /// 侧栏底部导航的选中项：设置页打开时是「设置」；终端标签活着时是「终端」；否则跟右栏当前标签。
  ShellTab? get activeNavTab {
    if (page == MainPage.settings) return ShellTab.settings;
    if (activeTerminalId != null && terminals.byId(activeTerminalId!) != null) return ShellTab.terminal;
    return rightTab;
  }

  void closeTab(ShellTab tab) {
    openTabs.remove(tab);
    if (rightTab == tab) rightTab = openTabs.isEmpty ? null : openTabs.last;
    _touch();
  }

  /// 点标签条上的标签。
  void selectPanel(PanelTab tab) {
    if (tab.isTerminal) {
      activeTerminalId = tab.terminalId;
    } else {
      activeTerminalId = null;
      if (tab.shell != null) openTab(tab.shell!);
    }
    _touch();
  }

  /// 标签条上的关闭键：终端标签 = 关掉那个 shell；面板标签 = 收起该面板。
  Future<void> closePanel(PanelTab tab) async {
    if (tab.isTerminal) {
      await closeTerminalTab(tab.terminalId!);
      return;
    }
    if (tab.shell != null) closeTab(tab.shell!);
  }

  /// 整个右栏收起：面板标签清空、本地 shell 全部关掉。
  Future<void> closeRightPanel() async {
    openTabs.clear();
    rightTab = null;
    activeTerminalId = null;
    final ids = <String>[for (final term in terminals.tabs) term.id];
    for (final id in ids) {
      await terminals.close(id);
    }
    _touch();
  }

  void toggleRightPanel() {
    if (rightPanelOpen) {
      closeRightPanel();
    } else {
      openTab(ShellTab.files);
    }
  }

  // ---------------------------------------------------------------- 本地终端（画板 61）

  /// 开一个本地 shell（cwd = 当前项目）并切到它；已有标签时（侧栏入口）切到最近的那个而不是再开一个。
  Future<void> openTerminalTab({bool forceNew = false}) async {
    if (!forceNew && terminals.tabs.isNotEmpty) {
      activeTerminalId = terminals.tabs.last.id;
      _touch();
      return;
    }
    final cwd = project?.path;
    if (cwd == null) {
      lastError = '先选一个项目目录，终端在它里面打开';
      _touch();
      return;
    }
    final id = await terminals.open(cwd);
    if (id != null) activeTerminalId = id;
    lastError = terminals.lastError ?? lastError;
    _touch();
  }

  Future<void> closeTerminalTab(String id) async {
    final wasActive = activeTerminalId == id;
    await terminals.close(id);
    if (wasActive) activeTerminalId = terminals.tabs.isEmpty ? null : terminals.tabs.last.id;
    _touch();
  }

  Future<void> stopTerminalTab(String id) => terminals.stop(id);

  void clearTerminalTab(String id) => terminals.clear(id);

  Future<void> restartTerminalTab(String id) async {
    final wasActive = activeTerminalId == id;
    final fresh = await terminals.restart(id);
    if (wasActive) activeTerminalId = fresh ?? (terminals.tabs.isEmpty ? null : terminals.tabs.last.id);
    _touch();
  }

  /// 画板 23 的停止方块（agent 建的终端）：`terminal_kill` = `terminal/kill` 语义，退出状态随 `acp/terminal_output` 回来。
  Future<void> killTerminal(String terminalId) async {
    final b = bridge;
    if (b == null) return;
    try {
      await b.terminalKill(terminalId);
    } catch (e) {
      // `_meta` 通道喂出来的终端 id 是 agent 的 toolUseId，核心没有这个 pty：协议里没有能停它的动作，
      // 不算错误、也不标 killed（审查 finding，2026-09-16）。
      final text = describeError(e);
      if (!text.contains('unknown terminal')) {
        lastError = text;
        _touch();
      }
      return;
    }
    store?.markTerminalKilled(terminalId);
  }

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

  // ---------------------------------------------------------------- 定位与 Follow（画板 18 / 21 / 11 / 40）

  /// 「Go to File」/ diff 行 / `@` 芯片：右栏切到文件面板并打开该文件（给了行就切 Source 高亮那一行）。
  Future<void> goToFile(String path, {int? line}) async {
    var p = path;
    if (p.startsWith('file:///')) p = Uri.parse(p).toFilePath(windows: Platform.isWindows);
    openTab(ShellTab.files);
    await files.openPath(p, line: line);
  }

  void toggleFollow() {
    follow = !follow;
    if (!follow) _lastFollowed = null;
    _touch();
  }

  /// Follow 开着时，当前会话的 `tool_call` / `tool_call_update` 带 `locations[]` 就跟到第一条（同一位置不重复跳）。
  void _followLocations(JsonMap envelope) {
    if (!follow || envelope['sessionId'] != sessionId) return;
    final update = envelope['update'];
    if (update is! Map) return;
    final kind = update['sessionUpdate'];
    if (kind != 'tool_call' && kind != 'tool_call_update') return;
    final locations = update['locations'];
    if (locations is! List || locations.isEmpty) return;
    final first = locations.first;
    if (first is! Map || first['path'] is! String) return;
    final path = first['path'] as String;
    final line = first['line'];
    final key = '$path:${line ?? ''}';
    if (key == _lastFollowed) return;
    _lastFollowed = key;
    unawaited(goToFile(path, line: line is num ? line.toInt() : null));
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

  void openTraffic() {
    page = MainPage.traffic;
    _touch();
  }

  void openWorkbench() {
    page = MainPage.workbench;
    _touch();
  }

  /// 画板 34 状态条的登录键：进认证页（画板 52），方法预选。
  Future<void> authenticate(String methodId) async {
    final id = agentId ?? connection?.agentId;
    if (id == null) return;
    await openAuth(id, retryCwd: project?.path, methodId: methodId);
  }

  // ---------------------------------------------------------------- registry 面板（画板 50 / 51，R5）

  /// 过滤 + 搜索之后的条目。
  List<RegistryEntryData> get visibleRegistryEntries => registry.visible(registryFilter, registryQuery);

  /// `registry_list`（`network` = 先联网刷新，1 小时节流，`force` 跳过）。失败不清列表，错误进 `registry.fetchError` 或 [lastError]。
  Future<void> refreshRegistry({bool network = false, bool force = false}) async {
    final b = bridge;
    if (b == null) return;
    await _guard(() async {
      final list = network ? await b.registryRefresh(force: force) : await b.registryList();
      registry.applyList(list);
      final paths = list['paths'];
      if (paths is Map) {
        dataDir = paths['dataDir'] as String? ?? dataDir;
        logPath = paths['logPath'] as String? ?? logPath;
        zedSettingsPath = paths['zedSettingsPath'] as String?;
      }
      // 展示名随 registry 来（画板 41 的新建会话弹层）。
      await refreshAgents();
    });
    _touch();
  }

  void _onRegistryProgress(CoreEventRecord e) {
    final json = e.json;
    if (json == null) return;
    final id = registry.applyProgress(json);
    final step = json['step'];
    if (step == 'done' || step == 'failed' || step == 'cancelled') {
      // 装完 / 失败 / 取消：安装记录与 settings 都变了，重读列表（不联网）。
      unawaited(refreshRegistry());
      if (id != null && step == 'failed') registryShowLog.add(id);
    }
    _touch();
  }

  void setRegistryFilter(RegistryFilter filter) {
    registryFilter = filter;
    _touch();
  }

  void setRegistryQuery(String query) {
    registryQuery = query;
    _touch();
  }

  /// Install / 重试（失败态）。
  Future<void> installAgent(String id) async {
    final b = bridge;
    if (b == null) return;
    registryShowLog.remove(id);
    await _guard(() => b.registryInstall(id));
    _touch();
  }

  Future<void> cancelInstall(String id) async {
    final b = bridge;
    if (b == null) return;
    await _guard(() => b.registryCancelInstall(id));
    _touch();
  }

  void toggleInstallLog(String id) {
    if (!registryShowLog.remove(id)) registryShowLog.add(id);
    _touch();
  }

  /// Remove（画板 50 / 51 / 70）：registry 型走 `registry_remove`（settings 条目 + `agents/<id>/`），custom 型只删 settings 条目。
  Future<void> removeAgent(String id) async {
    final b = bridge;
    if (b == null) return;
    await _guard(() async {
      final entry = registry.byId(id);
      if (entry?.isCustom ?? false) {
        await b.agentSettingsRemove(id);
      } else {
        await b.registryRemove(id);
      }
      if (agentId == id) {
        agentId = null;
        sessionId = null;
      }
      if (authAgentId == id) closeAuth();
      if (settingsEditingId == id || settingsExpandedId == id) collapseSettingsEdit();
      await refreshRegistry();
    });
    _touch();
  }

  /// 受管 Node（画板 51 提示卡 / 画板 70 的 Node 运行时）。进度经 `registry/progress`（`agentId: null`）。
  Future<void> downloadNode() async {
    final b = bridge;
    if (b == null) return;
    await _guard(() async {
      await b.nodeDownload();
      await refreshRegistry();
    });
    _touch();
  }

  // ---------------------------------------------------------------- 认证页（画板 52，R5）

  AgentConnection? get authConnection => authAgentId == null ? null : sessions.agents[authAgentId!];

  List<JsonMap> get authMethods => authConnection?.authMethods ?? const <JsonMap>[];

  String get authAgentName {
    final c = authConnection;
    final id = authAgentId ?? '';
    return c?.agentTitle ?? c?.agentName ?? registry.byId(id)?.name ?? id;
  }

  /// terminal 型认证的可见终端：核心的 `authenticating` 事件带 terminalId。
  String? get authTerminalId => authConnection?.authenticatingTerminalId;

  TerminalBuffer? get authTerminalBuffer {
    final id = authTerminalId;
    return id == null || authTerminalLabel == null ? null : sessions.terminals.ensure(id);
  }

  /// 进认证页：三个入口（`-32000`、画板 51 的登录键、画板 34 的登录键）都到这里。没连上的先 `initialize`（authMethods 从它来）。
  Future<void> openAuth(String agent, {String? retryCwd, String? methodId}) async {
    authAgentId = agent;
    authPhase = AuthPhase.choose;
    authError = null;
    authTerminalLabel = null;
    _authRetryCwd = retryCwd ?? project?.path;
    _authGeneration++;
    _cancelAuthElicitations();
    openTab(ShellTab.agents);
    final b = bridge;
    if (b != null && authMethods.isEmpty) {
      await _guard(() async {
        final result = await b.agentConnect(agent, cwd: _authRetryCwd);
        final init = result['initialize'];
        if (init is Map) sessions.agents.applyInitializeResult(agent, init.cast<String, dynamic>());
      });
    }
    authMethodId = methodId ?? authMethods.firstOrNull?['id'] as String?;
    _touch();
  }

  void selectAuthMethod(String id) {
    authMethodId = id;
    _touch();
  }

  /// 开始认证：agent 型调 `authenticate`（URL elicitation 会经 requestScope 落到本页）；terminal 型在 pty 里重拉同一个 agent，
  /// 核心等它退出后自动重试 `session/new`。成功后回到刚才的新会话，失败留在失败态（可重试、可换方式）。
  Future<void> startAuth() async {
    final b = bridge;
    final agent = authAgentId;
    final methodId = authMethodId ?? authMethods.firstOrNull?['id'] as String?;
    if (b == null || agent == null || methodId == null) return;
    final method = authMethods.where((m) => m['id'] == methodId).firstOrNull ?? const <String, dynamic>{};
    final cwd = _authRetryCwd ?? project?.path;
    final generation = _authGeneration;
    bool stale() => generation != _authGeneration;
    authPhase = AuthPhase.running;
    authError = null;
    _touch();
    try {
      if (AuthPage.methodType(method) == 'terminal') {
        if (cwd == null) throw StateError('先选一个项目目录，terminal auth 在它里面跑');
        authTerminalLabel = method['name'] as String? ?? methodId;
        _touch();
        final result = await b.terminalAuthRun(agent, methodId, cwd);
        if (stale()) return;
        authPhase = AuthPhase.succeeded;
        _touch();
        final session = result['session'];
        if (session is Map) {
          _adoptSession(agent, cwd, session.cast<String, dynamic>());
          await _saveIndex();
        } else {
          await _createSession(agent, cwd);
        }
      } else {
        await b.authenticate(agent, methodId);
        if (stale()) return;
        authPhase = AuthPhase.succeeded;
        _touch();
        if (cwd != null) await _createSession(agent, cwd);
      }
      if (stale()) return;
      closeAuth();
      page = MainPage.workbench;
    } on CoreCommandError catch (e) {
      if (stale()) return;
      authPhase = AuthPhase.failed;
      authError = '${e.message} (${e.code})';
    } catch (e) {
      if (stale()) return;
      authPhase = AuthPhase.failed;
      authError = e.toString();
    }
    _touch();
  }

  /// 失败态的「重试」：同一方法再来一次。
  Future<void> retryAuth() => startAuth();

  /// 失败态的「换一种方式」：回到选方法。
  void changeAuthMethod() {
    authPhase = AuthPhase.choose;
    authError = null;
    authTerminalLabel = null;
    _touch();
  }

  /// 取消：terminal 在跑的先关掉（核心等到退出后照常重试 `session/new`，失败会以 failed 收尾）；回 registry 列表。
  Future<void> cancelAuth() async {
    final b = bridge;
    final terminal = authTerminalId;
    if (b != null && terminal != null && authPhase == AuthPhase.running) {
      await _guard(() => b.terminalClose(terminal));
    }
    closeAuth();
  }

  void closeAuth() {
    _authGeneration++;
    authAgentId = null;
    authPhase = AuthPhase.choose;
    authMethodId = null;
    authError = null;
    authTerminalLabel = null;
    _authRetryCwd = null;
    _cancelAuthElicitations();
    _touch();
  }

  /// 认证页收起 / 重开前：还挂着的 requestScope elicitation 逐条回 `cancel`。不回响应，agent 那边在途的 `authenticate`
  /// 会永远等这条 JSON-RPC 回应（审查 finding high，2026-09-16）；已 accept 的（浏览器已打开）没有第二个响应可发，只从页上拿掉。
  void _cancelAuthElicitations() {
    for (final e in List<ElicitationEntry>.of(authElicitations)) {
      if (e.status == PendingStatus.pending) unawaited(cancelElicitation(e));
    }
    authElicitations.clear();
  }

  Future<void> stopAuthTerminal() async {
    final b = bridge;
    final terminal = authTerminalId;
    if (b == null || terminal == null) return;
    await _guard(() => b.terminalClose(terminal));
  }

  Future<void> authTerminalInput(String data) async {
    final b = bridge;
    final terminal = authTerminalId;
    if (b == null || terminal == null) return;
    await _guard(() => b.terminalWrite(terminal, data));
  }

  /// requestScope 的 elicitation 到达：落认证页（没开的话打开对应 agent 的一页），不落转录（docs/design.md § 5 第 5 条）。
  void _onPendingChanged() {
    final pending = sessions.pending.requestScope;
    if (pending.isEmpty) return;
    var added = false;
    for (final e in pending) {
      if (authElicitations.any((x) => x.requestId == e.requestId)) continue;
      authElicitations.add(e);
      added = true;
    }
    if (!added) return;
    final agent = pending.first.agentId;
    if (authAgentId == null && agent != null) {
      authAgentId = agent;
      authPhase = AuthPhase.running;
      authMethodId ??= authMethods.firstOrNull?['id'] as String?;
      _authRetryCwd ??= project?.path;
    }
    if (rightTab != ShellTab.agents) openTab(ShellTab.agents);
    _touch();
  }

  /// 「Open in browser」：回 `accept`（挂起的）并记已打开；返回要打开的 URL（打开本身由组合根的 `url_launcher` 做）。
  Future<String?> acceptElicitationUrl(ElicitationEntry e) async {
    final b = bridge;
    final agent = e.agentId ?? authAgentId;
    if (e.status == PendingStatus.pending && b != null && agent != null) {
      final payload = sessions.pending.answerElicitation(e.requestId, 'accept', now: sessions.now);
      if (payload != null) await _guard(() => b.acpRespond(agent, e.requestId, payload));
    }
    sessions.pending.markOpened(e.requestId);
    _touch();
    return e.wire.url;
  }

  /// 已打开后的 Cancel：挂起的回 `cancel`；已 accept 的只本地标 cancelled（没有第二个响应可发）。
  Future<void> cancelElicitation(ElicitationEntry e) async {
    final b = bridge;
    final agent = e.agentId ?? authAgentId;
    if (e.status == PendingStatus.pending && b != null && agent != null) {
      final payload = sessions.pending.answerElicitation(e.requestId, 'cancel', now: sessions.now);
      if (payload != null) await _guard(() => b.acpRespond(agent, e.requestId, payload));
    } else {
      sessions.pending.cancelRequest(e.requestId, now: sessions.now);
    }
    _touch();
  }

  // ---------------------------------------------------------------- 设置页（画板 70，R5）

  /// 已安装的条目（registry 型 + custom 型），设置页的 agent 配置列表。
  List<RegistryEntryData> get installedEntries => <RegistryEntryData>[
        for (final e in registry.entries)
          if (e.installed) e,
      ];

  void openSettings() {
    page = MainPage.settings;
    _touch();
  }

  /// 「编辑」：custom 型进行内编辑（cmd / args / env 填进输入框），registry 型只读展开拉起参数。
  void editAgent(String id) {
    final entry = registry.byId(id);
    if (entry != null && entry.isCustom && entry.custom != null) {
      settingsEditingId = id;
      settingsExpandedId = null;
      settingsEdit.command.text = entry.custom!.command;
      settingsEdit.args.text = entry.custom!.argsText;
      settingsEdit.env.text = entry.custom!.envText;
    } else {
      settingsExpandedId = settingsExpandedId == id ? null : id;
      settingsEditingId = null;
    }
    _touch();
  }

  void collapseSettingsEdit() {
    settingsEditingId = null;
    settingsExpandedId = null;
    _touch();
  }

  /// 「保存」：写回 `{type: custom, command, args, env}`（args 按空白分隔、双引号可包空格；env 是 `K=V` 空白分隔）。
  Future<void> saveCustomAgent(String id) async {
    final b = bridge;
    if (b == null) return;
    final command = settingsEdit.command.text.trim();
    if (command.isEmpty) {
      lastError = 'cmd 不能为空';
      _touch();
      return;
    }
    final env = <String, String>{};
    for (final token in splitArgs(settingsEdit.env.text)) {
      final i = token.indexOf('=');
      if (i <= 0) continue;
      env[token.substring(0, i)] = token.substring(i + 1);
    }
    await _guard(() async {
      await b.agentSettingsSet(id, <String, dynamic>{
        'type': 'custom',
        'command': command,
        'args': splitArgs(settingsEdit.args.text),
        'env': env,
      });
      settingsEditingId = null;
      await refreshRegistry();
    });
    _touch();
  }

  /// 按空白切分，双引号里的空格保留（`"C:\a b\x.cmd" --flag`）。
  static List<String> splitArgs(String text) {
    final out = <String>[];
    final buf = StringBuffer();
    var quoted = false;
    var has = false;
    for (final ch in text.runes) {
      final c = String.fromCharCode(ch);
      if (c == '"') {
        quoted = !quoted;
        has = true;
      } else if (!quoted && c.trim().isEmpty) {
        if (has) out.add(buf.toString());
        buf.clear();
        has = false;
      } else {
        buf.write(c);
        has = true;
      }
    }
    if (has) out.add(buf.toString());
    return out;
  }

  /// 「从 Zed 导入」：结果文案留在行下（画板 70 的注释位）。
  Future<void> importZed() async {
    final b = bridge;
    if (b == null) return;
    await _guard(() async {
      final result = await b.agentSettingsImportZed();
      final report = result['report'];
      if (report is Map) {
        List<String> ids(Object? v) => v is List ? v.map((e) => e.toString()).toList() : const <String>[];
        final imported = ids(report['imported']);
        final skipped = ids(report['skipped']);
        final invalid = ids(report['invalid']);
        zedImportResult = '已导入 ${imported.length} 条${imported.isEmpty ? '' : '（${imported.join('、')}）'}，'
            '跳过同名 ${skipped.length} 条${invalid.isEmpty ? '' : '，解不开 ${invalid.length} 条（${invalid.join('、')}）'}。';
      }
      await refreshRegistry();
    });
    _touch();
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
