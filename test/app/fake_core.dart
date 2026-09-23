// 组合根接线测试共用的假核心（R3 起）：只记调用，不做任何 IO；cdylib 在 flutter_tester 里加载不了，
// `lib/app/` 的接线在这里用它驱动。R5 加 registry / 认证 / 设置命令的记账与可注入的事件流。

import 'dart:async';

import 'package:acp_agent_client/app/core_bridge.dart';
import 'package:acp_agent_client/projection/wire.dart';

/// 记账用的假核心：只记调用，不做任何 IO。
class FakeCore implements CoreCommands {
  final List<(String requestId, JsonMap response)> responded = <(String, JsonMap)>[];
  final List<List<Object?>> prompts = <List<Object?>>[];
  int cancels = 0;

  /// 拖分栏落盘（画板 04）：只记账，不碰文件。
  JsonMap uiState = <String, dynamic>{};

  @override
  Future<JsonMap> uiStateGet() async => uiState;

  @override
  Future<JsonMap> uiStateSet(JsonMap patch) async => uiState = <String, dynamic>{...uiState, ...patch};

  /// 外观（四个字体轴 + 主题）：整段替换，不合并——前端一次给全。
  JsonMap appearance = <String, dynamic>{};

  /// 堵住读外观这一步（不设就立刻返回）：用来复现「读盘还没回来就改设置」那一下。
  Completer<void>? appearanceGetGate;

  /// 让读外观先失败几次（复现「核心还没 core_init 完」）：每失败一次减一，负数表示一直失败。
  int appearanceGetFailures = 0;

  @override
  Future<JsonMap> appearanceGet() async {
    final Completer<void>? gate = appearanceGetGate;
    if (gate != null) await gate.future;
    if (appearanceGetFailures != 0) {
      if (appearanceGetFailures > 0) appearanceGetFailures--;
      throw StateError('not_initialized: call core_init(data_dir) first');
    }
    return appearance;
  }

  @override
  Future<JsonMap> appearanceSet(JsonMap patch) async => appearance = <String, dynamic>{...patch};

  /// 转录偏好（画板 70「转录」小节）：整段替换，与外观同口径。
  JsonMap transcriptPrefs = <String, dynamic>{};

  /// 堵住读转录偏好这一步（不设就立刻返回）：复现「读盘还没回来就改设置」。
  Completer<void>? transcriptPrefsGetGate;

  /// 让读转录偏好先失败几次（复现「核心还没 core_init 完」）：每失败一次减一，负数表示一直失败。
  int transcriptPrefsGetFailures = 0;

  @override
  Future<JsonMap> transcriptPrefsGet() async {
    final Completer<void>? gate = transcriptPrefsGetGate;
    if (gate != null) await gate.future;
    if (transcriptPrefsGetFailures != 0) {
      if (transcriptPrefsGetFailures > 0) transcriptPrefsGetFailures--;
      throw StateError('not_initialized: call core_init(data_dir) first');
    }
    return transcriptPrefs;
  }

  @override
  Future<JsonMap> transcriptPrefsSet(JsonMap patch) async => transcriptPrefs = <String, dynamic>{...patch};

  @override
  Future<JsonMap> acpRespond(String agentId, String requestId, JsonMap response) async {
    responded.add((requestId, response));
    return <String, dynamic>{};
  }

  @override
  Future<JsonMap> sessionPrompt(String agentId, String sessionId, List<Object?> prompt) async {
    prompts.add(prompt);
    return <String, dynamic>{'stopReason': 'end_turn'};
  }

  @override
  Future<JsonMap> sessionCancel(String agentId, String sessionId) async {
    cancels++;
    return <String, dynamic>{'cancelledRequestIds': <String>[]};
  }

  /// 可注入的事件流（R5：`registry/progress` / `acp/client_request` / `acp/agent_state` 的接线测试往这里塞）。
  final StreamController<CoreEventRecord> events = StreamController<CoreEventRecord>.broadcast();

  void emit(CoreEvent channel, JsonMap json) => events.add(CoreEventRecord(channel, '', json));

  @override
  Stream<CoreEventRecord> on(CoreEvent channel) => events.stream.where((e) => e.channel == channel);

  @override
  Future<JsonMap> init(String dataDir) async => <String, dynamic>{};

  @override
  Future<JsonMap> agentConnect(String agentId, {String? cwd}) async => <String, dynamic>{};

  @override
  Future<JsonMap> agentDisconnect(String agentId) async => <String, dynamic>{};

  @override
  Future<JsonMap> sessionNew(String agentId, String cwd) async => <String, dynamic>{'sessionId': 'sess_fake'};

  // ---- R6：会话生命周期。只记账；`sessionLoad` 可以由用例注入「重放」（往事件流里塞 session/update）。
  final List<(String agentId, String? cwd, String? cursor)> listedSessions = <(String, String?, String?)>[];
  final List<(String agentId, String sessionId, String cwd)> loadedSessions = <(String, String, String)>[];
  final List<(String agentId, String sessionId, String cwd)> resumedSessions = <(String, String, String)>[];
  final List<(String agentId, String sessionId)> closedSessions = <(String, String)>[];
  final List<(String agentId, String sessionId)> deletedSessions = <(String, String)>[];

  /// `session/list` 的返回（用例按需覆盖；默认空）。多页时按 `cursor` 取。
  JsonMap Function(String? cursor) sessionListResult = (_) => <String, dynamic>{'sessions': <Object?>[]};

  /// `session/load` 期间的重放：用例在这里往事件流里塞 `acp/session_update`，返回 LoadSessionResponse。
  Future<JsonMap> Function(String agentId, String sessionId)? onSessionLoad;

  @override
  Future<JsonMap> sessionList(String agentId, {String? cwd, String? cursor}) async {
    listedSessions.add((agentId, cwd, cursor));
    return sessionListResult(cursor);
  }

  @override
  Future<JsonMap> sessionLoad(String agentId, String sessionId, String cwd) async {
    loadedSessions.add((agentId, sessionId, cwd));
    return await onSessionLoad?.call(agentId, sessionId) ?? <String, dynamic>{};
  }

  @override
  Future<JsonMap> sessionResume(String agentId, String sessionId, String cwd) async {
    resumedSessions.add((agentId, sessionId, cwd));
    return <String, dynamic>{};
  }

  @override
  Future<JsonMap> sessionClose(String agentId, String sessionId) async {
    closedSessions.add((agentId, sessionId));
    return <String, dynamic>{};
  }

  @override
  Future<JsonMap> sessionDelete(String agentId, String sessionId) async {
    deletedSessions.add((agentId, sessionId));
    return <String, dynamic>{};
  }

  /// 三个下拉打出去的命令（断言「关掉的会话发不出去」要看这两份，光看 lastError 会假通过）。
  final List<(String configId, JsonMap value)> configOptionCalls = <(String, JsonMap)>[];
  final List<String> modeCalls = <String>[];

  @override
  Future<JsonMap> sessionSetConfigOption(String agentId, String sessionId, String configId, JsonMap value) async {
    configOptionCalls.add((configId, value));
    return <String, dynamic>{'configOptions': <Object?>[]};
  }

  @override
  Future<JsonMap> sessionSetMode(String agentId, String sessionId, String modeId) async {
    modeCalls.add(modeId);
    return <String, dynamic>{};
  }

  @override
  Future<JsonMap> authenticate(String agentId, String methodId) async => <String, dynamic>{};

  @override
  Future<JsonMap> terminalAuthRun(String agentId, String methodId, String cwd) async =>
      <String, dynamic>{'terminalId': 'term_fake', 'exitStatus': <String, dynamic>{'exitCode': 0}, 'session': <String, dynamic>{'sessionId': 'sess_fake'}};

  @override
  Future<JsonMap> agentSettingsGet() async => <String, dynamic>{'agent_servers': <String, dynamic>{}};

  @override
  Future<JsonMap> agentSettingsSet(String agentId, JsonMap server) async => <String, dynamic>{'agent_servers': <String, dynamic>{}};

  @override
  Future<JsonMap> agentSettingsRemove(String agentId) async => <String, dynamic>{'agent_servers': <String, dynamic>{}};

  @override
  Future<JsonMap> agentSettingsImportZed() async => <String, dynamic>{'report': <String, dynamic>{}, 'settings': <String, dynamic>{}};

  /// registry 面板（R5）：默认空列表；用例按需覆盖。
  JsonMap registry = <String, dynamic>{'agents': <Object?>[], 'fetching': false, 'node': <String, dynamic>{}};

  @override
  Future<JsonMap> registryList() async => registry;

  @override
  Future<JsonMap> registryRefresh({bool force = false}) async => registry;

  @override
  Future<JsonMap> registryInstall(String agentId) async => <String, dynamic>{'agentId': agentId, 'started': true};

  @override
  Future<JsonMap> registryUpdate(String agentId) async => <String, dynamic>{'agentId': agentId, 'started': true};

  @override
  Future<JsonMap> registryCancelInstall(String agentId) async => <String, dynamic>{'agentId': agentId, 'cancelled': true};

  @override
  Future<JsonMap> registryRemove(String agentId) async => registry;

  @override
  Future<JsonMap> nodeStatus() async => <String, dynamic>{};

  @override
  Future<JsonMap> nodeDownload() async => <String, dynamic>{};

  @override
  Future<JsonMap> fsListDir(String root, String path) async => <String, dynamic>{'entries': <Object?>[]};

  @override
  Future<JsonMap> fsSearch(String root, String query, {int limit = 10}) async =>
      <String, dynamic>{'files': <Object?>[], 'directories': <Object?>[]};

  @override
  Future<JsonMap> gitBranches(String cwd) async => <String, dynamic>{'available': false, 'isRepo': false};

  @override
  Future<JsonMap> gitSwitch(String cwd, String branch) async => <String, dynamic>{};

  @override
  Future<JsonMap> gitCreateBranch(String cwd, String branch) async => <String, dynamic>{};

  @override
  Future<JsonMap> gitDiff(String cwd, {String? base}) async => <String, dynamic>{'text': ''};

  @override
  Future<JsonMap> workspaceRecent() async => <String, dynamic>{'projects': <Object?>[]};

  @override
  Future<JsonMap> workspaceOpen(String path) async => <String, dynamic>{'projects': <Object?>[]};

  /// 本地会话索引（`sessions.json` 的替身）：upsert / remove 真的改它，接线测试才能验「删完不再列出」。
  final List<JsonMap> sessionIndex = <JsonMap>[];

  JsonMap get _indexResult => <String, dynamic>{'sessions': <Object?>[...sessionIndex]};

  @override
  Future<JsonMap> sessionIndexList() async => _indexResult;

  @override
  Future<JsonMap> sessionIndexUpsert(JsonMap entry) async {
    final i = sessionIndex.indexWhere((e) => e['agentId'] == entry['agentId'] && e['sessionId'] == entry['sessionId']);
    final merged = <String, dynamic>{'updatedAt': 0, 'createdAt': 0, ...entry};
    if (i < 0) {
      sessionIndex.add(merged);
    } else {
      sessionIndex[i] = <String, dynamic>{...sessionIndex[i], ...merged};
    }
    return _indexResult;
  }

  /// 让下一次 `session_index_remove` 抛一次错（验「agent 侧删成功、本地那步失败」的重试路径）。
  bool indexRemoveFailsOnce = false;

  @override
  Future<JsonMap> sessionIndexRemove(String agentId, String sessionId) async {
    if (indexRemoveFailsOnce) {
      indexRemoveFailsOnce = false;
      throw const CoreCommandError('settings', 'sessions.json is locked');
    }
    sessionIndex.removeWhere((e) => e['agentId'] == agentId && e['sessionId'] == sessionId);
    return _indexResult;
  }

  // ---- R4：文件面板 / 终端 / 退出收尾，测试里只记账。
  final List<String> killedTerminals = <String>[];
  final List<String> closedTerminals = <String>[];
  final List<(String, String)> writtenToTerminal = <(String, String)>[];
  int shutdowns = 0;
  int openedTerminals = 0;

  @override
  Future<JsonMap> fsRead(String root, String path) async =>
      <String, dynamic>{'path': path, 'text': '', 'size': 0, 'lines': 0, 'binary': false, 'truncated': false};

  @override
  Stream<JsonMap> fsWatch(String root) => const Stream<JsonMap>.empty();

  @override
  Future<JsonMap> fsUnwatch(String root) async => <String, dynamic>{'root': root, 'removed': false};

  @override
  Future<JsonMap> gitStatus(String cwd) async => <String, dynamic>{'available': false, 'isRepo': false, 'entries': <Object?>[]};

  @override
  Future<JsonMap> terminalOpen(String cwd, {required int cols, required int rows}) async {
    openedTerminals++;
    return <String, dynamic>{'terminalId': 'term_fake_$openedTerminals', 'cwd': cwd, 'program': 'fake-shell'};
  }

  @override
  Future<JsonMap> terminalWrite(String terminalId, String data) async {
    writtenToTerminal.add((terminalId, data));
    return <String, dynamic>{'terminalId': terminalId, 'written': data.length};
  }

  @override
  Future<JsonMap> terminalResize(String terminalId, {required int cols, required int rows}) async =>
      <String, dynamic>{'terminalId': terminalId, 'cols': cols, 'rows': rows};

  @override
  Future<JsonMap> terminalKill(String terminalId) async {
    killedTerminals.add(terminalId);
    return <String, dynamic>{'terminalId': terminalId};
  }

  @override
  Future<JsonMap> terminalClose(String terminalId) async {
    closedTerminals.add(terminalId);
    return <String, dynamic>{'terminalId': terminalId};
  }

  @override
  Future<JsonMap> coreShutdown() async {
    shutdowns++;
    return <String, dynamic>{'terminals': 0, 'agents': 0};
  }
}
