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
import 'package:flutter/services.dart';
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
import 'clipboard_image.dart';
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

/// 主区显示什么：会话工作台、ACP 流量调试（画板 80，从画板 34 的「打开流量面板」进）。
/// 设置（画板 70）不在这里——它是右栏的一个标签（画板 03 的标签条），跟文件 / Agents 一样不占主区。
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

  // ---- UI 态
  bool sidebarCollapsed = false;

  /// 两栏宽度（画板 04 的分栏把手）：启动时从 `ui-state.json` 读回，没存过就是画板缺省。
  double sidebarWidth = t.Geometry.sidebarWidth;
  double rightPanelWidth = t.Geometry.rightPanelWidth;

  /// 文件面板（画板 60）里树列的宽度与收起态：同样记在 `ui-state.json`（所有者裁定 2026-09-17）。
  double filesTreeWidth = t.Geometry.filesTreeWidth;
  bool filesTreeCollapsed = false;
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

  /// 改名的输入框落在哪一处：线程头的铅笔就在线程头上改（画板 01 的标题位），侧栏那支笔改侧栏那一行。
  /// 两处共用 [rename] / [renameFocus]，靠这个标记分流，同一时刻只可能有一个输入框在树上。
  bool renamingInHeader = false;
  String? confirmingDeleteId;
  String? lastError;

  /// 输入框里待随下一条 prompt 发出的附件块（`+` 与 `@` 加进来的）。
  final List<JsonMap> pendingBlocks = <JsonMap>[];

  /// `@` / `/` 内联菜单（画板 42）的数据：两个来源同一时刻只可能有一个非空，都空 = 不显示。
  /// 存数据而不是存 widget，是因为键盘上下键要按它算高亮、Enter 要按它取项。
  List<MentionItem> _mentionFiles = const <MentionItem>[];
  List<MentionItem> _mentionDirs = const <MentionItem>[];
  List<AvailableCommandWire> _slashCommands = const <AvailableCommandWire>[];

  /// 键盘高亮下标（`@` 菜单里跨分组是全局的，与 [MentionMenu.items] 的拼接顺序一致）。
  int _inlineSelected = 0;

  /// 内联菜单 widget：null = 不显示。
  Widget? get inlineMenu {
    if (_slashCommands.isNotEmpty) {
      return SlashCommandMenu(commands: _slashCommands, selectedIndex: _inlineSelected, onPick: _pickCommand);
    }
    if (_mentionFiles.isNotEmpty || _mentionDirs.isNotEmpty) {
      return MentionMenu(
        files: _mentionFiles,
        directories: _mentionDirs,
        selectedIndex: _inlineSelected,
        onPick: _pickMention,
      );
    }
    return null;
  }

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

  // ---- 设置面板（画板 70，R5；右栏标签）
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

  /// 输入框右下每一格配置的弹层锚点：按 configOption 的 id 取（modes 回退那条用它的哨兵 id）。
  /// 惰性建、按 id 复用；换 agent 后旧 id 的锚点留着不回收（一个 agent 的条目是个位数），统一在 [dispose] 里收。
  final Map<String, PopoverHandle> _configAnchors = <String, PopoverHandle>{};

  final List<StreamSubscription<CoreEventRecord>> _subs = <StreamSubscription<CoreEventRecord>>[];
  bool _disposed = false;

  // ---------------------------------------------------------------- 派生

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
    return c?.agentTitle ?? c?.agentName ?? _installedRef(agentId)?.name ?? agentId ?? 'Agent';
  }

  String get threadTitle {
    if (!hasAgent) return 'No Agent';
    return store?.title ?? 'New $agentDisplayName Thread';
  }

  String get composerPlaceholder {
    if (!hasAgent) return '安装并选择一个 agent 后即可输入';
    // 会话是发第一条消息时才开的，cwd 从当前项目来：没项目就先说清楚，别让发送静默失败。
    if (!hasSession && project == null) return '先选一个项目目录，新会话的 cwd 从它来';
    return 'Message to $agentDisplayName , @ to include context , / for commands';
  }

  /// 输入框可用：选了 agent、没项目也没会话时不可用（发不出去），已关掉的会话只读。
  bool get canCompose => hasAgent && !sessionClosed && (hasSession || project != null);

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
    // modes 回退（R6）：只发 modes / `current_mode_update`、不发 configOptions 的 agent，
    // 模式下拉用 `SessionStore.modeFallbackOption` 合成的那条；两者都有时上面的循环已经命中，走不到这里。
    if (category == 'mode') return store?.modeFallbackOption;
    return null;
  }

  /// 输入框右下的固定档序（所有者裁定 2026-09-18）：`mode → model → model_config → thought_level → 其余`，
  /// 档内保持 agent 给的数组顺序、同一档可以有多条。ACP 的 category 是开放集合（schema：
  /// `Mode | Model | ModelConfig | ThoughtLevel | Other(String)`，字段本身还可缺省，`_` 开头的是 agent 自定义），
  /// 所以匹配不上的一律排进最后一档、一条一格，不丢条目（spec v1 session-config-options：
  /// 「Clients MUST handle missing or unknown categories gracefully」）。boolean 型也在这条列表里，就地渲染成开关。
  /// 与 Zed 的差别只在顺序：Zed 照 agent 给的数组顺序排，我们按档序排（换 agent 时输入框的位置稳定）。
  static const List<String> _categoryOrder = <String>['mode', 'model', 'model_config', 'thought_level'];

  List<ConfigOptionWire> get composerOptions {
    final all = store?.configOptions ?? const <ConfigOptionWire>[];
    final ordered = <ConfigOptionWire>[];
    for (final category in _categoryOrder) {
      // modes 回退（R6）：没有 `category == 'mode'` 的 configOption 时才合成，排在 mode 档的头一格。
      if (category == 'mode') {
        final fallback = store?.modeFallbackOption;
        if (fallback != null) ordered.add(fallback);
      }
      for (final o in all) {
        if (o.category == category) ordered.add(o);
      }
    }
    for (final o in all) {
      if (!_categoryOrder.contains(o.category)) ordered.add(o);
    }
    return ordered;
  }

  /// 按 id 取当前那一份（弹层要在每次 rebuild 时重新读，`set_config_option` 的响应是全量替换）。
  ConfigOptionWire? optionById(String id) {
    for (final o in composerOptions) {
      if (o.id == id) return o;
    }
    return null;
  }

  /// 配置格的弹层锚点：id 一个，见 [_configAnchors]。
  PopoverHandle configAnchor(String id) => _configAnchors.putIfAbsent(id, PopoverHandle.new);

  void hideConfigPopovers() {
    for (final h in _configAnchors.values) {
      _hide(h);
    }
  }

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
      b.on(CoreEvent.sessionUpdate).listen((e) {
        final sid = e.json?['sessionId'];
        if (sid is String) _updateArrivals[sid] = (_updateArrivals[sid] ?? 0) + 1;
        _enqueue(e, (json) {
          sessions.applySessionUpdateEnvelope(json);
          _followLocations(json);
        });
      }),
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
      // 本地索引先读：下面挑「当前 agent」要按索引里最近用过的那条来（`refreshRegistry` 末尾
      // 会用 registry 的图标把侧栏重投影一次，所以先读索引不会让会话项停在占位菱形上）。
      await refreshSessionIndex();
      await refreshRegistry();
      await refreshAgents();
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
    final tree = state['filesTreeWidth'];
    final treeCollapsed = state['filesTreeCollapsed'];
    if (side is num) sidebarWidth = _clampSidebar(side.toDouble());
    if (right is num) rightPanelWidth = _clampRightPanel(right.toDouble());
    if (tree is num) filesTreeWidth = _clampFilesTree(tree.toDouble());
    if (treeCollapsed is bool) filesTreeCollapsed = treeCollapsed;
  }

  static double _clampSidebar(double w) => w.clamp(t.Geometry.sidebarMinWidth, t.Geometry.sidebarMaxWidth);
  static double _clampRightPanel(double w) => w.clamp(t.Geometry.rightPanelMinWidth, t.Geometry.rightPanelMaxWidth);
  static double _clampFilesTree(double w) => w.clamp(t.Geometry.filesTreeMinWidth, t.Geometry.filesTreeMaxWidth);

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

  void resizeFilesTree(double delta) {
    final next = _clampFilesTree(filesTreeWidth + delta);
    if (next == filesTreeWidth) return;
    filesTreeWidth = next;
    notifyListeners();
  }

  void resetFilesTreeWidth() {
    if (filesTreeWidth == t.Geometry.filesTreeWidth) return;
    filesTreeWidth = t.Geometry.filesTreeWidth;
    notifyListeners();
    saveUiState();
  }

  /// 文件面板头行的「缩小」 / 查看器头行的「放回来」：同一个开关。
  void toggleFilesTree() {
    filesTreeCollapsed = !filesTreeCollapsed;
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
          'filesTreeWidth': filesTreeWidth,
          'filesTreeCollapsed': filesTreeCollapsed,
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
    for (final h in <PopoverHandle>[
      projectAnchor, branchAnchor, newSessionAnchor, threadMenuAnchor, deleteAnchor, plusAnchor,
      followAnchor, usageAnchor, ..._configAnchors.values,
    ]) {
      h.dispose();
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
        for (final entry in servers.entries)
          // 名字：条目自带的 `name` 优先（R7 的内置 sidecar 用它显示 "Zed Agent"），其次 registry.json 的
          // 展示名（R5），最后退回 settings 里的键；连上之后线程头再从 agentInfo 取（规则 2）。
          AgentRef(
            id: entry.key as String,
            name: _agentDisplayName(entry.key as String, entry.value),
            // logo 与侧栏 / 线程头同一条路：registry 缓存的 `icon.svg`（内置 sidecar 是随包带的那份）。
            iconSvg: agentIconSvgOf(entry.key as String),
          ),
    ];
    _selectDefaultAgent();
  }

  /// 当前 agent 还没定（启动、或刚把选中的那个卸掉）时挑一个：本地索引里最近用过、且**还装着**的那个，
  /// 没有就第一个已安装的；一个都没装就留空（画板 01 状态 2）。
  /// 只挑不连——agent 进程等到第一条消息才拉起（[send]），所以开应用不会白拉一个进程、也不会在启动时弹认证。
  void _selectDefaultAgent() {
    // 会话开着的时候当前 agent 归那条会话，列表刷新一概不许动它：`session/new` 之后那一发
    // `registry_list` / `agent_settings_get` 只要慢一步或回了空，就会把正在用的 agent 抹掉
    // （线程头回到 No Agent、发送打不出去）。卸载走 `removeAgent`，它自己会先清干净再刷。
    if (sessionId != null) return;
    final installed = <String>{for (final a in installedAgents) a.id};
    final current = agentId;
    if (current != null && installed.contains(current)) return; // 已经选好且还装着：不动它
    agentId = _lastUsedAgentId(installed) ?? (installedAgents.isEmpty ? null : installedAgents.first.id);
  }

  /// 本地索引（`sessions.json`）里 `updatedAt` 最大的那条会话的 agent，限于还装着的。
  String? _lastUsedAgentId(Set<String> installed) {
    String? best;
    var bestAt = -1;
    for (final e in _indexEntries) {
      final id = e['agentId'];
      if (id is! String || !installed.contains(id)) continue;
      final at = (e['updatedAt'] as num?)?.toInt() ?? 0;
      if (at > bestAt) {
        bestAt = at;
        best = id;
      }
    }
    return best;
  }

  /// 已安装列表里的这一条（展示名与图标从它来）。
  AgentRef? _installedRef(String? id) {
    if (id == null) return null;
    for (final a in installedAgents) {
      if (a.id == id) return a;
    }
    return null;
  }

  String _agentDisplayName(String id, Object? server) {
    if (server is Map) {
      final name = server['name'];
      if (name is String && name.isNotEmpty) return name;
    }
    return registry.byId(id)?.name ?? id;
  }

  Future<void> refreshSessionIndex() async {
    final b = bridge;
    if (b == null) return;
    final result = await b.sessionIndexList();
    _applyIndex(result['sessions']);
  }

  /// 本地索引落地：原始条目（cwd 等字段接线要用）与侧栏投影一起更新。
  void _applyIndex(Object? raw) {
    _indexEntries = <JsonMap>[
      if (raw is List)
        for (final item in raw)
          if (item is Map) item.cast<String, dynamic>(),
    ];
    sidebarSessions = _toSidebar(raw);
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
        canDelete: true,
        iconSvg: agentIconSvgOf(owner ?? agentId),
      ));
    }
    return out;
  }

  /// agent 自己的 logo：registry 缓存的 `icon.svg` 原样内容，侧栏会话项与线程头的 agent 标记直接画它
  /// （画板 50 / 51 / 70 的图标框用的是同一份）。registry 里没有这条 / 没缓存到图标时为 null，退回画板的单色占位。
  /// 不按 agent 名判（规则 2）：id 查不到就是没有。
  String? agentIconSvgOf(String? agent) =>
      agent == null || agent.isEmpty ? null : registry.byId(agent)?.iconSvg;

  /// 线程头的 agent 标记。
  String? get agentIconSvg => agentIconSvgOf(agentId);

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
  bool get sessionClosed => sessionId != null && _closedSessions.contains(sessionId);
  bool get canResumeSession => hasSession && sessionClosed && _sessionCaps.containsKey('resume');
  bool get canCloseSession => hasSession && !sessionClosed && _sessionCaps.containsKey('close');
  bool get canDeleteSession => hasSession && _sessionCaps.containsKey('delete');

  // 侧栏删除图标（画板 04 注）**一律给**：它删的首先是本地索引这条记录，agent 侧删不删由
  // [deletesOnAgent] 单独判。按 `sessionCapabilities.delete` 裁剪过一版，结果是没声明 delete 的 agent
  // （实测 dsh-acp-interactive 1.3.0）的会话在侧栏里永远清不掉——本地记录是我们自己的，不该被 agent
  // 的能力声明锁住（所有者报障 2026-09-18）。见 [_toSidebar] 的 `canDelete: true`。

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
    // 画板 05 B 组阶段 ①：先把等待态摆出来再发命令。拉起进程 + `initialize` + `session/new`
    // 要几百毫秒到数秒，这期间界面一动不动会被当成卡死（所有者手测 2026-09-18，与重载 agent 同一回事）。
    // 先存旧值再恢复：[reloadAgent] 的「没有旧会话」分支会调到这里，直接写 false 会把它的等待态提前收掉。
    final wasWaiting = waitingForAgent;
    waitingForAgent = true;
    _touch();
    try {
      await _connect(b, agent.id, cwd);
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
    } finally {
      waitingForAgent = wasWaiting;
      _touch();
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
      unawaited(refreshRegistry());
    }
    await _saveIndex();
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
    page = MainPage.workbench;
  }

  /// 重载 agent（画板 01 / 41）：断开 + 重拉。agent 声明 `loadSession` 时重连后自动 `session/load` 回原来那个会话
  /// （R6 交付物）；没声明的沿用 R3 的做法——开一个新会话，旧转录留在内存里只读。
  Future<void> reloadAgent() async {
    _hide(threadMenuAnchor);
    final id = agentId;
    final b = bridge;
    final cwd = project?.path;
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
    _touch();
    // `session/load` 回的是同一条会话时 `sessionId` 不变、`_adoptSession` 也不走，
    // 但转录确实整块换过，得单独补一次入场触发（画板 05 阶段 ③）。
    var loaded = false;
    try {
      await _guard(() async {
        await b.agentDisconnect(id);
        if (previous == null) {
          await newSession(AgentRef(id: id, name: id));
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
      _touch();
    }
  }

  /// 侧栏点选一条会话（画板 04）。内存里没有转录且 agent 声明 `loadSession` 时顺带 `session/load` 把历史重放回来。
  Future<void> selectSession(String id) async {
    page = MainPage.workbench;
    // 线程头正在改名时切走：那个输入框改的是原来那条会话，跟着切过去会把名字落到别人头上。
    if (renamingInHeader && renamingSessionId != id) cancelRename();
    if (sessionId != id) sessionEpoch++;
    sessionId = id;
    agentId = _sessionAgent[id] ?? agentId;
    _touch();
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
    final cwd = _indexCwdOf(id) ?? project?.path;
    if (cwd == null) return;
    if (missingOnAgent.contains(id)) {
      lastError = '$id 在 agent 侧已经不存在了，载不回历史';
      _touch();
      return;
    }
    await _guard(() async {
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
    _touch();
  }

  /// 本地索引里这条记录登记的 agentId（删 / 改索引都按 (agentId, sessionId) 匹配，见 [deleteSession]）。
  String? _indexAgentOf(String sessionId) {
    for (final s in _indexEntries) {
      if (s['sessionId'] == sessionId) {
        final agent = s['agentId'];
        if (agent is String) return agent;
      }
    }
    return null;
  }

  String? _indexCwdOf(String sessionId) {
    for (final s in _indexEntries) {
      if (s['sessionId'] == sessionId) {
        final cwd = s['cwd'];
        if (cwd is String && cwd.isNotEmpty) return cwd;
      }
    }
    return sessions.maybe(sessionId)?.cwd;
  }

  /// 本地索引原始条目（`sessions.json` 的投影；侧栏项只留了展示要用的字段，cwd 在这里）。
  List<JsonMap> _indexEntries = const <JsonMap>[];

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
    _hide(threadMenuAnchor);
    final b = bridge;
    final id = sessionId;
    final agent = agentId;
    if (b == null || id == null || agent == null) return;
    final cwd = sessions.maybe(id)?.cwd ?? _indexCwdOf(id) ?? project?.path;
    if (cwd == null) return;
    await _guard(() async {
      final result = await b.sessionResume(agent, id, cwd);
      sessions.session(id, agentId: agent)
        ..cwd = cwd
        ..applyLoadSession(result);
      _closedSessions.remove(id);
    });
    _touch();
  }

  /// ≡ 菜单 Close（画板 41）：`session/close` = 先 cancel 再释放。本地转录留着**只读**，会话仍是当前会话——
  /// 这样 ≡ 菜单里紧接着就能 Resume（`session/resume` 只对没在本连接上活着的会话有效），
  /// 从侧栏再点开它则走 `session/load` 重放。
  Future<void> closeSession() async {
    _hide(threadMenuAnchor);
    final b = bridge;
    final id = sessionId;
    final agent = agentId;
    if (b == null || id == null || agent == null) return;
    await _guard(() async {
      await _releaseSessionRequests(b, agent, id);
      await b.sessionClose(agent, id);
      _closeEpoch[id] = (_closeEpoch[id] ?? 0) + 1;
      _closedSessions.add(id);
    });
    _touch();
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
      await _guard(() => b.acpRespond(agent, requestId, PendingQueue.cancelledAction));
    }
  }

  /// `session/list` 校对（R6，裁定 2026-09-15 落 docs/design.md § 3 末条）：侧栏以本地索引为准，
  /// 这里只做两件事——① agent 侧还在的会话，缺标题就用 agent 给的补上；② agent 侧没有的记进 [missingOnAgent]
  /// （不自动删本地记录，也不把 agent 有、本地没有的塞进侧栏）。分页按 `nextCursor` 取完。
  Future<void> reconcileSessions({int maxPages = 20}) async {
    final b = bridge;
    final agent = agentId;
    if (b == null || agent == null || !canListSessions) return;
    await _guard(() async {
      final remote = <String, JsonMap>{};
      String? cursor;
      for (var page = 0; page < maxPages; page++) {
        final result = await b.sessionList(agent, cwd: project?.path, cursor: cursor);
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
      final scope = project?.path;
      for (final entry in <JsonMap>[..._indexEntries]) {
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
          final result = await b.sessionIndexUpsert(<String, dynamic>{...entry, 'title': title});
          _applyIndex(result['sessions']);
          changed = true;
        }
      }
      if (changed) _touch();
    });
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
    _applyIndex(result['sessions']);
  }

  void startRename(String id, {bool inHeader = false}) {
    renamingSessionId = id;
    renamingInHeader = inHeader;
    final current = sidebarSessions.where((s) => s.id == id).map((s) => s.title).firstOrNull ??
        (inHeader ? threadTitle : '');
    rename.text = current;
    _touch();
  }

  void cancelRename() {
    renamingSessionId = null;
    renamingInHeader = false;
    _touch();
  }

  Future<void> commitRename(String title) async {
    final id = renamingSessionId;
    renamingSessionId = null;
    renamingInHeader = false;
    final b = bridge;
    if (id == null || b == null || title.trim().isEmpty) {
      _touch();
      return;
    }
    // 线程头显示的是 store 的标题，改完要跟着变；不写回去的话 [_saveIndex] 收轮时还会拿旧标题把索引盖回去。
    // agent 之后再发 `session_info_update.title` 仍然照单全收（规则 2），改名只管到那时候。
    sessions.maybe(id)?.title = title.trim();
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
      _applyIndex(result['sessions']);
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
    _hide(deleteAnchor);
    final b = bridge;
    if (b == null) return;
    final owner = _ownerOf(id);
    final onAgent = deletesOnAgent(id);
    await _guard(() async {
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
      final result = await b.sessionIndexRemove(_indexAgentOf(id) ?? owner, id);
      _applyIndex(result['sessions']);
      if (sidebarSessions.any((s) => s.id == id)) {
        lastError = '这条会话的本地记录没能删掉（索引里找不到匹配的记录）';
      }
      missingOnAgent.remove(id);
      _closedSessions.remove(id);
      _closeEpoch.remove(id);
      _updateArrivals.remove(id);
      _deletedOnAgent.remove(id);
      _sessionAgent.remove(id);
      sessions.forget(id);
      if (sessionId == id) sessionId = null;
    });
    _touch();
  }

  // ---------------------------------------------------------------- 一轮对话

  /// `session/close` 之后这条会话是**只读**的：所有会往它发命令的入口共用这一道门
  /// （prompt / Restore / Regenerate / 三个下拉；审查第 2 轮 P2：第 1 轮只挡住了 `send()`）。
  bool _blockedByClose() {
    if (!sessionClosed) return false;
    lastError = '这个会话已经关闭；用 ≡ 菜单的 Resume 挂回来，或新建一个会话';
    _touch();
    return true;
  }

  /// 「选了 agent 但还没有会话」时，第一条消息现开一条：在途期间挡住重复点发送。
  bool _startingSession = false;

  Future<void> send() async {
    final b = bridge;
    final id = agentId;
    if (b == null || id == null) return;
    if (composer.text.trim().isEmpty && pendingBlocks.isEmpty) return; // 空输入不开会话
    // 启动后的画板 01 状态 1：agent 已选、会话还没开（进程也没拉）。第一条消息把它开出来，
    // 失败（认证 / 缺 Node）时 `newSession` 已经把错误与认证页安排好，输入框里的文本原样留着。
    // 守卫看 `store`（= 没有可用转录）。已知问题：选中的会话只是**载不回**转录时 `store` 也是 null，
    // 于是这里会开一条新会话把选中的那条静默顶掉（审查 finding P2）。两轮针对性整改都在别处引入了
    // 新缺陷（改 `sessionId` 判据 → 不支持 loadSession 的 agent 按发送零响应；加能力判据 →
    // 覆盖掉 `newSession` 安排好的认证 / 缺 Node 报错，且能力未知时仍会顶掉），
    // 所有者裁定 2026-09-18：回退到出厂行为，记 `rounds/BACKLOG.md` 等单独一轮做。
    if (store == null) {
      if (_startingSession) return;
      _startingSession = true;
      try {
        await newSession(_installedRef(id) ?? AgentRef(id: id, name: id));
      } finally {
        _startingSession = false;
      }
    }
    // 静默 return 是有意的：走到这里说明 `newSession` 失败了，而它的每条失败路径都已经把
    // 真实原因写进 `lastError`（认证 / 缺 Node / 没选项目目录）并安排好认证页，这里再写一句会盖掉它。
    final s = store;
    if (s == null) return;
    if (_blockedByClose()) return;
    // 快照要取在开会话之后：拉起进程 + `initialize` + `session/new` 要几百毫秒到数秒，
    // 这期间新打的字与新加的附件也得发出去，否则下面的 clear 会把它们静默抹掉（审查 finding P2，2026-09-18）。
    final blocks = _promptBlocks(composer.text);
    if (blocks.isEmpty) return;
    composer.clear();
    pendingBlocks.clear();
    _clearInlineMenu();
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
        // `stopReason` 留空：连接断了本来就没有协议给的结束值，不编一个（规则 2）；原因走 `TurnEntry.error`，
        // 由画板 31 的结束行显示——只记 `lastError` 的话整条错误在界面上无处可见，用户只看到一个 `?` 徽章
        // （2026-09-18 实测：dsh 回 `-32602 model does not declare image input` 与 `-32603 turn failed`，界面全无提示）。
        final message = describeError(e);
        s.endTurn(error: message);
        lastError = message;
        debugPrint('[workbench] session/prompt failed: $message');
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
    // 停止方块也是往会话发命令的入口：`closeSession` 里的 `s.cancel()` 不收轮（`isRunning` 还是 true），
    // 作曲器禁用态下 Stop 仍会渲染，点下去就把 `session/cancel` 打到已经释放掉的会话上（审查第 3 轮 P2）。
    if (_blockedByClose()) return;
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

  /// 用户气泡上的 Restore 与 Regenerate（画板 11）：本地截断 + 同会话重发。
  /// （画板 10 的 Restore Checkpoint 分隔线已废弃，所有者裁定 2026-09-17：与这里是同一个动作。）
  /// **截断范围内仍挂起的请求必须回应**，否则 agent 一直等着：permission 回 cancelled outcome、
  /// elicitation 回 cancelled action（`RestoreResult` 的两组 id）。
  Future<void> restore(TurnEntry turn, {String? newText}) async {
    final s = store;
    if (s == null) return;
    // 关掉的会话不能 Restore / Regenerate：`restoreTo` 会先把本地转录截断，随后的 `session/prompt`
    // 必然失败，本地就少了一截而 agent 侧还是关闭前那份（审查第 2 轮 P2）。
    if (_blockedByClose()) return;
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
    hideConfigPopovers();
    final s = store;
    final b = bridge;
    final id = agentId;
    if (s == null || b == null || id == null) return;
    if (_blockedByClose()) return;
    await _guard(() async {
      final result = await b.sessionSetConfigOption(id, s.sessionId, configId, value);
      s.applyConfigOptionsResponse(result);
    });
    _touch();
  }

  Future<void> selectConfigValue(String configId, String value) {
    // modes 回退（R6）：合成条目的 id 是本地哨兵，不能当 configId 发出去——它走 `session/set_mode`。
    if (configId == SessionStore.modeFallbackId) return setMode(value);
    return setConfigOption(configId, <String, dynamic>{'type': 'select', 'value': value});
  }

  /// `session/set_mode`（modes 回退路径）。响应是空的；按规范客户端发起的切换成功即生效，
  /// 所以本地同步 `currentModeId`（agent 自己改模式时会另发 `current_mode_update`）。
  Future<void> setMode(String modeId) async {
    hideConfigPopovers();
    final s = store;
    final b = bridge;
    final id = agentId;
    if (s == null || b == null || id == null) return;
    if (_blockedByClose()) return;
    await _guard(() async {
      await b.sessionSetMode(id, s.sessionId, modeId);
      s.applyModeSelected(modeId);
    });
    _touch();
  }

  Future<void> toggleConfigBoolean(String configId, bool value) =>
      setConfigOption(configId, <String, dynamic>{'type': 'boolean', 'value': value});

  // ---------------------------------------------------------------- 输入框的 @ 与 /

  /// 输入框正文变化：按最后一个 token 决定要不要出内联菜单（画板 42）。
  Future<void> onComposerChanged(String text) async {
    final token = _activeToken(text);
    if (token == null) {
      closeInlineMenu();
      return;
    }
    if (token.startsWith('/')) {
      final q = token.substring(1).toLowerCase();
      final commands = <AvailableCommandWire>[
        for (final c in store?.commands ?? const <AvailableCommandWire>[])
          if (q.isEmpty || (c.name ?? '').toLowerCase().startsWith(q)) c,
      ];
      _clearInlineMenu();
      _slashCommands = commands;
      _touch();
      return;
    }
    await _updateMentionMenu(token.substring(1));
  }

  /// 菜单开着（有东西可选）。
  bool get inlineMenuOpen => _inlineMenuCount > 0;

  int get _inlineMenuCount =>
      _slashCommands.isNotEmpty ? _slashCommands.length : _mentionFiles.length + _mentionDirs.length;

  void _clearInlineMenu() {
    _mentionFiles = const <MentionItem>[];
    _mentionDirs = const <MentionItem>[];
    _slashCommands = const <AvailableCommandWire>[];
    // 列表一换高亮就回第一条：每次改词后最匹配的那条在最上面。
    _inlineSelected = 0;
  }

  /// Esc：关掉菜单，输入框里的文本原样留着。
  void closeInlineMenu() {
    if (!inlineMenuOpen) return;
    _clearInlineMenu();
    _touch();
  }

  /// 上下键移动高亮（`-1` / `+1`，首尾环绕）。
  void moveInlineMenuSelection(int delta) {
    final n = _inlineMenuCount;
    if (n == 0) return;
    _inlineSelected = (_inlineSelected + delta) % n;
    if (_inlineSelected < 0) _inlineSelected += n;
    _touch();
  }

  /// Enter：把高亮项填进输入框（与鼠标点那一行同一条路，不发送）。
  void pickInlineMenuSelection() {
    if (!inlineMenuOpen) return;
    if (_slashCommands.isNotEmpty) {
      _pickCommand(_slashCommands[_inlineSelected]);
      return;
    }
    _pickMention(<MentionItem>[..._mentionFiles, ..._mentionDirs][_inlineSelected]);
  }

  /// 光标处的 `@` / `/` token：只在正文开头的 `/` 或空白后的 `@` 上触发。
  String? _activeToken(String text) {
    if (text.isEmpty) return null;
    if (text.startsWith('/') && !text.contains(RegExp(r'\s'))) return text;
    final m = RegExp(r'(?:^|\s)(@[^\s]*)$').firstMatch(text);
    return m?.group(1);
  }

  /// `@` 菜单一组最多几条（裸 `@` 列根目录、有词时是 `fs_search` 的 limit）。
  static const int _mentionLimit = 10;

  Future<void> _updateMentionMenu(String query) async {
    final b = bridge;
    // 提及的根用当前会话的 cwd（agent 按它解析路径），没有才回落到当前项目。
    final cwd = store?.cwd ?? project?.path;
    if (b == null || cwd == null) {
      _clearInlineMenu();
      _touch();
      return;
    }
    await _guard(() async {
      final List<MentionItem> files;
      final List<MentionItem> dirs;
      if (query.isEmpty) {
        // 裸 `@`：还没有可搜的词，`fs_search` 对空词按约定返回空结果（不做全量遍历），
        // 所以这一步改列项目根目录的一层——菜单一出来就有东西可选。
        final listing = await b.fsListDir(cwd, cwd);
        final entries = _toMentions(listing['entries']);
        files = <MentionItem>[for (final e in entries) if (!e.isDirectory) e].take(_mentionLimit).toList();
        dirs = <MentionItem>[for (final e in entries) if (e.isDirectory) e].take(_mentionLimit).toList();
      } else {
        final result = await b.fsSearch(cwd, query, limit: _mentionLimit);
        files = _toMentions(result['files']);
        dirs = _toMentions(result['directories']);
      }
      _clearInlineMenu();
      _mentionFiles = files;
      _mentionDirs = dirs;
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
    _clearInlineMenu();
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
    _clearInlineMenu();
    composerFocus.requestFocus();
    _touch();
  }

  static String _fileUri(String path) => Uri.file(path, windows: Platform.isWindows).toString();

  // ---------------------------------------------------------------- `+` 的四项（画板 40）

  void addResourceLink(String path, String name) {
    pendingBlocks.add(<String, dynamic>{'type': 'resource_link', 'uri': _fileUri(path), 'name': name});
    _appendToComposer('@$name');
  }

  /// 输入框顶部芯片条的数据：待发的 `image` 块本身（规则 2，不另存一份视图状态）。
  List<ContentBlockWire> get pendingImages => <ContentBlockWire>[
        for (final b in pendingBlocks)
          if (b['type'] == 'image') ContentBlockWire(b),
      ];

  /// 芯片上的 ×。按**同一个 map 对象**删，不按内容比——两张一模一样的图也要能分别删掉。
  void removePendingBlock(ContentBlockWire block) {
    pendingBlocks.removeWhere((b) => identical(b, block.json));
    _touch();
  }

  /// 图片不再往输入框塞 `[image]` 占位文本：它以芯片的形式显示在输入框顶部（[pendingImages]）。
  /// `path` 只在图来自磁盘上的文件时有，转成 `image` 块的可选 `uri`，芯片按它显示文件名。
  void addImage(String base64Data, String mimeType, {String? path}) {
    pendingBlocks.add(<String, dynamic>{
      'type': 'image',
      'data': base64Data,
      'mimeType': mimeType,
      if (path != null) 'uri': _fileUri(path),
    });
    _touch();
  }

  /// Ctrl/Cmd+V（输入框的按键回调只管调这里，判断全在这）：剪贴板里是文本就什么都不做——
  /// 那一下已经由 `EditableText` 自己贴进去了；是截图 / 图片文件才加成 `image` 块。
  Future<void> pasteImageFromClipboard() async {
    if (!canCompose) return;
    // 按键回调是 fire-and-forget（`onPaste?.call()` 没人 await），所以这里自己兜住：
    // `Clipboard.getData` 在剪贴板被别的进程占着时会抛 `PlatformException`，不兜就成了未捕获的异步错误。
    await _guard(() async {
      final text = await Clipboard.getData(Clipboard.kTextPlain);
      if ((text?.text ?? '').isNotEmpty) return;
      if (!canPromptImage) return; // 不支持图片的 agent：连剪贴板都不用读
      final result = await readClipboardImages();
      if (result.skippedTooLarge) {
        lastError = '图片超过 ${clipboardImageSizeLimit ~/ (1024 * 1024)} MB，没有加进输入框';
        _touch();
      }
      if (result.images.isEmpty) return;
      for (final image in result.images) {
        addImage(base64Encode(image.bytes), image.mimeType, path: image.path);
      }
      composerFocus.requestFocus();
    });
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

  /// 侧栏底部导航 / 右栏标签：终端开一个本地 shell 标签（已有就切到最近那个，画板 61）；
  /// 设置 / 文件 / Agents 是右栏标签（画板 03 / 50 / 60 / 70）。
  void openTab(ShellTab tab) {
    if (tab == ShellTab.terminal) {
      openTerminalTab();
      return;
    }
    if (!openTabs.contains(tab)) openTabs.add(tab);
    rightTab = tab;
    activeTerminalId = null;
    _touch();
  }

  /// 侧栏底部导航点一下：没开这个面板就开；当前就是它，再点一下把右栏整个收起
  /// （画板 03 的面板关闭键已废弃，右栏的「关」挪到这里，见 `lib/ui/shell/right_panel.dart` 文件头）。
  void toggleNavTab(ShellTab tab) {
    if (rightPanelOpen && activeNavTab == tab) {
      closeRightPanel();
      return;
    }
    openTab(tab);
  }

  /// 侧栏底部导航的选中项：终端标签活着时是「终端」；否则跟右栏当前标签（设置也在右栏标签里）。
  ShellTab? get activeNavTab {
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
      // 侧栏的 agent logo 是从 registry 查出来**烘进** [SidebarSession] 的，所以 registry 一变就要重投影一次：
      // 首次启动时图标是这轮联网刷新才落盘的，不重投影侧栏会一直停在占位菱形上，直到下次刷新本地索引。
      sidebarSessions = _toSidebar(_indexEntries);
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

  // ---------------------------------------------------------------- 设置面板（画板 70，R5；右栏标签）

  /// 已安装的条目（registry 型 + custom 型），设置页的 agent 配置列表。
  List<RegistryEntryData> get installedEntries => <RegistryEntryData>[
        for (final e in registry.entries)
          if (e.installed) e,
      ];

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
