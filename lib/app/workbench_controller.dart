// dart format off
// 组合根（R3 接线阶段起；R7.5 拆成组合根 + 8 个对象）：把 `lib/projection/` 的投影层、`lib/app/core_bridge.dart` 的桥命令
// 与 `lib/ui/` 的画板 widget 串起来。widget 只拿数据与回调，不知道桥的存在（AGENTS.md 规则 3）。

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
import '../projection/session_store.dart';
import '../projection/traffic.dart';
import '../projection/wire.dart';
import '../ui/popovers/topbar_popovers.dart';
import '../ui/shell/shell_common.dart';
import '../ui/shell/sidebar.dart';
import 'agents_state.dart';
import 'auth_state.dart';
import 'composer_state.dart';
import 'core_bridge.dart';
import 'files_state.dart';
import 'guarded.dart';
import 'local_terminals.dart';
import 'paths.dart';
import 'session_attach.dart';
import 'session_index.dart';
import 'shell_state.dart';
import 'session_controller.dart';
import 'toasts.dart';
import 'transcript_folds.dart';
import 'turn_controller.dart';
import 'workspace_state.dart';

enum DataSource {
  bridge,
  fixtures;

  /// `--dart-define=DATA_SOURCE=fixtures`。
  static DataSource fromEnvironment() =>
      const String.fromEnvironment('DATA_SOURCE') == 'fixtures'
      ? DataSource.fixtures
      : DataSource.bridge;
}

class WorkbenchController extends ChangeNotifier with GuardedNotifier, WidgetsBindingObserver {
  WorkbenchController({required this.source, this.bridge, FlushScheduler? scheduler}) {
    _scheduler = scheduler ?? _scheduleOnFrame;
    _observesLifecycle = scheduler == null;
    if (_observesLifecycle) WidgetsBinding.instance.addObserver(this);
    session.addListener(() => composer.followSession(session.sessionId));
    session.onForgetSession = composer.forgetDraft;
    for (final n in <ChangeNotifier>[shell, auth]) {
      n.addListener(_syncAgentsPanel);
    }
    for (final child in <ChangeNotifier>[shell, workspace, agents, auth, composer, turn, session, toasts]) {
      child.addListener(notifyListeners);
    }
    session.onClearQueue = turn.clearQueue;
    session.onClearAgentQueues = turn.clearQueuesForAgent;
    for (final source in <GuardedNotifier>[this, shell, workspace, agents, auth, composer, turn, session, files, terminals]) {
      source.reportError = toasts.error;
    }
  }

  final DataSource source;
  final CoreCommands? bridge;

  /// 批量刷新的调度器。窗口里按帧合并（docs/design.md § 9）；无头实跑（lib/app/headless_run.dart）
  /// 传微任务调度；默认调度在窗口无帧期间同样走微任务，不攒到还原时。
  late final FlushScheduler _scheduler;
  late final bool _observesLifecycle;
  int? _flushFrameId;
  void Function()? _pendingFrameFlush;

  late final Sessions sessions = Sessions();
  late final UpdateBatcher batcher = UpdateBatcher(sessions, scheduler: _scheduler);
  final TrafficStore traffic = TrafficStore();
  late final TranscriptFolds folds = TranscriptFolds(bridge: bridge);
  final Toasts toasts = Toasts();
  late final FilesState files = FilesState(bridge: bridge);
  late final LocalTerminals terminals = LocalTerminals(bridge: bridge);

  // ---- 八个子对象（R7.5）。构造时把反向依赖接成回调：谁要反向调谁，这里就写一行闭包。

  /// 壳的本地 UI 态：三栏宽度、主区页面、右栏标签条、本地终端标签、Follow、流量过滤框。
  late final ShellState shell = ShellState(
    bridge: bridge,
    files: files,
    terminals: terminals,
    cwd: () => workspace.project?.path,
    // 打开 Agents 标签时检查一次 registry 有没有新版本（画板 53；核心侧 1 小时节流，不 force）。
    onTabShown: (tab) {
      if (tab == ShellTab.agents)
        unawaited(agents.refreshRegistry(network: true));
    },
    onWorkbenchShown: () {
      // 从流量页回到工作台，当前那条会话就又在眼前了：它的绿点一并撤掉（画板 06 的清除条件）。
      final id = session.sessionId;
      if (id != null) session.clearUnread(id);
    },
  );

  /// 项目与分支：当前项目 / 最近项目 / 分支区 / Rules 计数。等待期里不换项目；换了项目由会话控制器放下别的目录的会话。
  late final WorkspaceState workspace = WorkspaceState(
    bridge: bridge,
    files: files,
    busy: () => session.waitingForAgent,
    onProjectChanged: () => session.enterWorkspace(),
  );

  late final SessionIndex index = SessionIndex(bridge: bridge, onChanged: () => session.refreshSidebar());

  /// 已装 agent 列表、registry 面板（画板 50 / 51 / 54）与设置面板（画板 70）。
  late final AgentsState agents = AgentsState(
    bridge: bridge,
    sessions: sessions,
    isSessionAttached: (id) => session.attachOf(id) == SessionAttach.attached,
    sessionOwner: (id) => session.ownerOf(id),
    onStopped: (id) {
      if (sessions.agents[id]?.state != AgentLifecycle.exited) {
        sessions.applyAgentState(<String, dynamic>{'agentId': id, 'state': 'exited'});
      }
      turn.clearQueuesForAgent(id);
    },
    onRemoved: (id) {
      session.dropAgent(id);
      auth.closeIfAgent(id);
    },
    onInstalledChanged: () => session.ensureAgentSelected(),
    onRegistryChanged: () => session.refreshSidebar(),
    onPaths: _applyPaths,
  );

  /// 认证页（画板 52）的状态机。认证成功后的自动重试新会话交回会话控制器。
  late final AuthState auth = AuthState(
    bridge: bridge,
    sessions: sessions,
    cwd: () => workspace.project?.path,
    connect: (agent, cwd) => session.connectAgent(agent, cwd),
    registryName: (id) => agents.registry.byId(id)?.name,
    currentAgentId: () => session.agentId ?? session.connection?.agentId,
    openAgentsTab: () => shell.openTab(ShellTab.agents),
    ensureAgentsTab: () {
      if (shell.rightTab != ShellTab.agents) shell.openTab(ShellTab.agents);
    },
    showWorkbench: () => shell.page = MainPage.workbench,
    onAuthenticated: (agent, cwd, adopted) async {
      if (adopted == null)
        await session.createSession(agent, cwd);
      else
        await session.adoptAuthSession(agent, cwd, adopted);
    },
  );

  /// 输入框（画板 40 / 42）：正文与附件、`@` `/` 内联菜单、`+` 四项、配置格与三个弹层锚点。
  late final ComposerState composer = ComposerState(
    bridge: bridge,
    store: () => session.store,
    cwd: () => workspace.project?.path,
    canCompose: () => session.canCompose,
    canPromptImage: () => session.canPromptImage,
  );

  /// 当前会话与会话生命周期（画板 01 / 04 / 06 / 41 / 43 与 R6 的整套会话动作）。
  late final SessionController session = SessionController(
    bridge: bridge,
    sessions: sessions,
    batcher: batcher,
    index: index,
    agents: agents,
    workspace: workspace,
    showWorkbench: () => shell.page = MainPage.workbench,
    isWorkbenchPage: () => shell.page == MainPage.workbench,
    openAgentsTab: () => shell.openTab(ShellTab.agents),
    openAuth: (agent, cwd) => auth.open(agent, retryCwd: cwd),
  );

  late final TurnController turn = TurnController(bridge: bridge, session: session, composer: composer);
  final Map<String, _ChunkedUtf8> _agentTerminalText = <String, _ChunkedUtf8>{};
  String? dataDir;
  String? logPath;
  final List<StreamSubscription<CoreEventRecord>> _subs = <StreamSubscription<CoreEventRecord>>[];

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
            shell.followLocations(json, sessionId: session.sessionId);
          })),
      b.on(CoreEvent.clientRequest).listen((e) => _enqueue(e, (json) => sessions.applyClientRequestEnvelope(json))),
      b.on(CoreEvent.agentState).listen((e) => _enqueue(e, (json) {
            sessions.applyAgentState(json);
            if (json['state'] == 'exited') {
              final aid = json['agentId'] as String?;
              if (aid != null) turn.clearQueuesForAgent(aid);
            }
            agents.onAgentState(json);
          })),
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
      // 转录偏好（画板 70「转录」）在 `core_init` **之后**读：排在它前面那一下核心回 not_initialized，
      // `TranscriptFolds._readSettingsOk` 就停在 false，开关既读不回也存不下（发布前审查 high，2026-09-22）。
      // 不 await：读不回来也只是回到「默认开」，不该拖慢启动。
      unawaited(folds.start());
      // 本地索引先读：下面挑「当前 agent」要按索引里最近用过的那条来（`refreshRegistry` 末尾
      // 会用 registry 的图标把侧栏重投影一次，所以先读索引不会让会话项停在占位菱形上）。
      await index.refresh();
      await agents.refreshRegistry();
      await agents.refreshAgents();
      // 三栏宽度在前：只读一条本地 UI 状态，而恢复项目要跑 6 个 git 子进程 + 两次目录列举，
      // 排在它后面会让冷启动的第一屏先用缺省宽度撑着、跑完才跳一次。
      await shell.restoreUiState();
      await workspace.restoreLastProject();
    });
    notifyListeners();
    // registry.json 的联网刷新（1 小时节流）放到后台：断网时 30 秒超时不能挡住启动。
    unawaited(agents.refreshRegistry(network: true));
  }

  void _syncAgentsPanel() {
    agents.setPanelVisible(shell.rightPanelOpen && shell.activePanel?.shell == ShellTab.agents && auth.agentId == null);
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
    session.agentId = agent;
    session.sessionId = replayer.lastSessionId;
    final sessionId = session.sessionId;
    final cwd = sessionId == null ? null : sessions.maybe(sessionId)?.cwd;
    if (cwd != null) workspace.project = ProjectRef(path: cwd, name: cwd.split(RegExp(r'[\\/]')).last);
    session.sidebarSessions = <SidebarSession>[
      if (sessionId != null)
        SidebarSession(
          id: sessionId,
          title: sessions.maybe(sessionId)?.title ?? 'fixtures',
          updatedAt: DateTime.now(),
          messageCount: sessions.maybe(sessionId)?.entries.whereType<MessageEntry>().length ?? 0,
        ),
    ];
    notifyListeners();
  }

  void _enqueue(CoreEventRecord e, void Function(JsonMap json) apply) {
    final json = e.json;
    if (json == null) return;
    batcher.enqueue(() => apply(json));
  }

  void _scheduleOnFrame(void Function() flush) {
    if (disposed) return;
    // 手动 flush / release 后可能仍留着上一轮帧回调；新刷新只能保留一个。
    _cancelFrameFlush();
    final binding = SchedulerBinding.instance;
    if (!binding.framesEnabled) {
      _scheduleFlushMicrotask(flush);
      return;
    }
    _pendingFrameFlush = flush;
    _flushFrameId = binding.scheduleFrameCallback((_) {
      _flushFrameId = null;
      _pendingFrameFlush = null;
      if (!disposed) flush();
    });
  }

  void _scheduleFlushMicrotask(void Function() flush) {
    scheduleMicrotask(() {
      if (!disposed) flush();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final minimized =
        state != AppLifecycleState.resumed &&
        state != AppLifecycleState.inactive;
    agents.setWindowMinimized(minimized);
    // 已排上帧再最小化时，batcher 的 _scheduled 仍为 true，把那一次刷新迁走（并撤销帧回调）。
    if (!minimized) return;
    final flush = _pendingFrameFlush;
    _cancelFrameFlush();
    if (flush != null) _scheduleFlushMicrotask(flush);
  }

  void _cancelFrameFlush() {
    final id = _flushFrameId;
    if (id != null) SchedulerBinding.instance.cancelFrameCallbackWithId(id);
    _flushFrameId = null;
    _pendingFrameFlush = null;
  }

  /// 无头实跑用：微任务里刷，不依赖帧。
  static void scheduleOnMicrotask(void Function() flush) =>
      scheduleMicrotask(flush);

  @override
  void dispose() {
    markDisposed();
    if (_observesLifecycle) WidgetsBinding.instance.removeObserver(this);
    _cancelFrameFlush();
    for (final s in _subs) {
      s.cancel();
    }
    sessions.removeListener(notifyListeners);
    sessions.pending.removeListener(auth.onPendingChanged);
    files.removeListener(notifyListeners);
    terminals.removeListener(notifyListeners);
    files.dispose();
    terminals.dispose();
    folds.dispose();
    for (final child in <ChangeNotifier>[shell, workspace, agents, auth, composer, turn, session, toasts]) {
      child.removeListener(notifyListeners);
      child.dispose();
    }
    super.dispose();
  }

  /// 组合根里的纯 UI 变化（弹层里的搜索框输入等）需要重建时调它。
  void refresh() => touch();

  // ---------------------------------------------------------------- 事件分发

  /// `acp/terminal_output`：source = local 的进终端面板，其余（agent / auth）进转录里的终端卡。
  void _onTerminalOutput(JsonMap json) {
    if (json['source'] == 'local') {
      terminals.applyOutput(json);
      return;
    }
    final id = json['terminalId'];
    if (id is! String) return;
    sessions.applyTerminalOutputEvent(
      json,
      decode: (b64) =>
          _agentTerminalText.putIfAbsent(id, _ChunkedUtf8.new).decode(b64),
    );
    if (json['exitStatus'] is Map) _agentTerminalText.remove(id);
  }

  /// `registry_list` 回的 `paths`：`AgentsState.refreshRegistry` 每次刷新都经回调交到这里（画板 70）。
  void _applyPaths(Map<Object?, Object?> paths) {
    dataDir = paths['dataDir'] as String? ?? dataDir;
    logPath = paths['logPath'] as String? ?? logPath;
  }

  // ---------------------------------------------------------------- 退出收尾

  /// 应用退出前：释放全部终端、断开全部 agent（核心侧 `core_shutdown`）。超时也放行，别把窗口卡住。
  ///
  /// 超时要盖住核心收尾的最坏一段（cursor 审查 high，1.4.4）：关窗那一刻若某条 `agent_connect` 正卡在旧连接的
  /// 断开里（`DISCONNECT_GRACE` 3 秒 + kill 后再等 3 秒），它随后拉起的握手被 `closing` 中止又是同样的两段——合计
  /// 12 秒，`core_shutdown` 要等这整段才返回。宿主进程若先退出，还在 taskkill 的收尾被一起杀掉，进程树收不完。
  static const Duration shutdownTimeout = Duration(seconds: 15);

  Future<void> shutdown() async {
    final b = bridge;
    if (b == null) return;
    try {
      await b.coreShutdown().timeout(shutdownTimeout);
    } catch (e) {
      debugPrint('[workbench] shutdown: $e');
    }
  }
}

/// 一个终端的 base64 字节流 → 文本：分块 UTF-8 解码，跨块的多字节字符不会被切成 U+FFFD（R3 逐块 `utf8.decode` 的隐患）。
class _ChunkedUtf8 {
  _ChunkedUtf8() {
    _sink = const Utf8Decoder(allowMalformed: true)
        .startChunkedConversion(StringConversionSink.fromStringSink(_out));
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
