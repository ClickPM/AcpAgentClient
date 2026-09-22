// 组合根（R3 接线阶段起；R7.5 拆成组合根 + 8 个对象）：把 `lib/projection/` 的投影层、`lib/app/core_bridge.dart` 的桥命令
// 与 `lib/ui/` 的画板 widget 串起来。widget 只拿数据与回调，不知道桥的存在（CLAUDE.md 规则 3）。
//
// 本文件只剩接线与生命周期：投影层三件（sessions / batcher / traffic）、文件与终端面板、八个子对象的构造与回调接线、
// `start()` 的启动顺序、六路核心事件的订阅与分发、批量刷新的调度、dispose / shutdown。状态与动作按画板分组在同目录的
// `*State`（shell / workspace / agents / auth / composer）与协议驱动的两个 `*Controller`（session / turn）里，`SessionIndex`
// 是本地索引的内存镜像；依赖方向见 rounds/round-7.5/round-7.5.md 附录 B——子对象之间只有单向依赖，反向一律走这里接的回调，
// 没有子对象 import 本文件。screen / headless / test 直接访问子对象（`c.session.send()` 这样），这里不留转发门面。
//
// 数据源两种（ROUNDS § 3 R3）：
//   bridge（默认）——真核心；fixtures（`--dart-define=DATA_SOURCE=fixtures`）——回放 `test/fixtures/`，
//   所有会改动 agent 的命令都是 no-op，供 gallery 与不装 agent 时开发。
//
// 通知（R7.5 阶段 A）：八个子对象与 sessions / files / terminals 的通知全部转发到本对象，screen 仍用一个
// ListenableBuilder 包整个壳；按区域订阅是阶段 B 的事，先量后动（任务卡裁定门第 4 项）。
//
// 不做 agent 特判（规则 2）：agent 名一律来自 settings.json 的键或 `initialize` 的 `agentInfo`。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

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
import 'session_index.dart';
import 'shell_state.dart';
import 'session_controller.dart';
import 'transcript_folds.dart';
import 'turn_controller.dart';
import 'workspace_state.dart';

enum DataSource {
  bridge,
  fixtures;

  /// `--dart-define=DATA_SOURCE=fixtures`。
  static DataSource fromEnvironment() =>
      const String.fromEnvironment('DATA_SOURCE') == 'fixtures' ? DataSource.fixtures : DataSource.bridge;
}

class WorkbenchController extends ChangeNotifier with GuardedNotifier {
  WorkbenchController({required this.source, this.bridge, FlushScheduler? scheduler})
      : _scheduler = scheduler ?? _scheduleOnFrame {
    // 阶段 A：子对象的通知全部转发到根。在构造函数里接而不是 start() 里：不 start 也能用（单测这么用）。
    for (final child in <ChangeNotifier>[shell, workspace, agents, auth, composer, turn, session]) {
      child.addListener(notifyListeners);
    }
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

  /// 回合折叠（画板 08 B）：全局开关 + 每个回合的展开态。**不转发到根**——折叠只影响转录列表，
  /// 而 `TranscriptList` 自己听它；转发上来会让点一次摘要行重建整个工作台。
  late final TranscriptFolds folds = TranscriptFolds(bridge: bridge);

  /// 文件面板（画板 60）与终端面板（画板 61）的接线状态（R4）。
  late final FilesState files = FilesState(bridge: bridge);
  late final LocalTerminals terminals = LocalTerminals(bridge: bridge);

  // ---- 八个子对象（R7.5）。构造时把反向依赖接成回调：谁要反向调谁，这里就写一行闭包。

  /// 壳的本地 UI 态：三栏宽度、主区页面、右栏标签条、本地终端标签、Follow、流量过滤框。
  late final ShellState shell = ShellState(
    bridge: bridge,
    files: files,
    terminals: terminals,
    cwd: () => workspace.project?.path,
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

  /// 本地会话索引 `sessions.json` 的内存镜像（不是 notifier）：条目一变，会话控制器重投影侧栏。
  late final SessionIndex index = SessionIndex(bridge: bridge, onChanged: () => session.refreshSidebar());

  /// 已装 agent 列表、registry 面板（画板 50 / 51）与设置面板（画板 70）。
  late final AgentsState agents = AgentsState(
    bridge: bridge,
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
    registryName: (id) => agents.registry.byId(id)?.name,
    currentAgentId: () => session.agentId ?? session.connection?.agentId,
    openAgentsTab: () => shell.openTab(ShellTab.agents),
    ensureAgentsTab: () {
      if (shell.rightTab != ShellTab.agents) shell.openTab(ShellTab.agents);
    },
    showWorkbench: () => shell.page = MainPage.workbench,
    onAuthenticated: (agent, cwd, adopted) =>
        adopted == null ? session.createSession(agent, cwd) : session.adoptAuthSession(agent, cwd, adopted),
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

  /// 一轮对话：发送 / 取消 / 回应 / Restore、会话配置、停止方块、本地转录文本。轮读会话控制器，会话控制器不知道有轮。
  late final TurnController turn = TurnController(bridge: bridge, session: session, composer: composer);

  /// agent 终端（`acp/terminal_output` source = agent / auth）的分块 UTF-8 解码：跨块的多字节字符不能逐块 `utf8.decode`。
  final Map<String, _ChunkedUtf8> _agentTerminalText = <String, _ChunkedUtf8>{};

  /// 核心给的几个路径（画板 70）：`core_init` / `registry_list` 的 `paths`。
  String? dataDir;
  String? logPath;
  String? zedSettingsPath;

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
      b.on(CoreEvent.sessionUpdate).listen((e) {
        final sid = e.json?['sessionId'];
        if (sid is String) session.noteUpdateArrival(sid);
        _enqueue(e, (json) {
          sessions.applySessionUpdateEnvelope(json);
          shell.followLocations(json, sessionId: session.sessionId);
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
    folds.dispose();
    for (final child in <ChangeNotifier>[shell, workspace, agents, auth, composer, turn, session]) {
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
    sessions.applyTerminalOutputEvent(json, decode: (b64) => _agentTerminalText.putIfAbsent(id, _ChunkedUtf8.new).decode(b64));
    if (json['exitStatus'] is Map) _agentTerminalText.remove(id);
  }

  /// `registry_list` 回的 `paths`：`AgentsState.refreshRegistry` 每次刷新都经回调交到这里（画板 70）。
  void _applyPaths(Map<Object?, Object?> paths) {
    dataDir = paths['dataDir'] as String? ?? dataDir;
    logPath = paths['logPath'] as String? ?? logPath;
    zedSettingsPath = paths['zedSettingsPath'] as String?;
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
}

/// 一个终端的 base64 字节流 → 文本：分块 UTF-8 解码，跨块的多字节字符不会被切成 U+FFFD（R3 逐块 `utf8.decode` 的隐患）。
class _ChunkedUtf8 {
  _ChunkedUtf8() {
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
