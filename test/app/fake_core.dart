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

  @override
  Future<JsonMap> sessionSetConfigOption(String agentId, String sessionId, String configId, JsonMap value) async =>
      <String, dynamic>{'configOptions': <Object?>[]};

  @override
  Future<JsonMap> sessionSetMode(String agentId, String sessionId, String modeId) async => <String, dynamic>{};

  @override
  Future<JsonMap> authenticate(String agentId, String methodId) async => <String, dynamic>{};

  @override
  Future<JsonMap> terminalAuthRun(String agentId, String methodId, String cwd) async =>
      <String, dynamic>{'terminalId': 'term_fake', 'exitStatus': <String, dynamic>{'exitCode': 0}, 'session': <String, dynamic>{'sessionId': 'sess_fake'}};

  @override
  Future<JsonMap> terminalWrite(String terminalId, String data) async => <String, dynamic>{};

  @override
  Future<JsonMap> terminalClose(String terminalId) async => <String, dynamic>{};

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

  @override
  Future<JsonMap> sessionIndexList() async => <String, dynamic>{'sessions': <Object?>[]};

  @override
  Future<JsonMap> sessionIndexUpsert(JsonMap entry) async => <String, dynamic>{'sessions': <Object?>[]};

  @override
  Future<JsonMap> sessionIndexRemove(String agentId, String sessionId) async => <String, dynamic>{'sessions': <Object?>[]};
}

