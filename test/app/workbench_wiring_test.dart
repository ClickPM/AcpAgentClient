// 组合根接线的单测（R3 验收 10）：Restore / Regenerate 截断时，落在截断范围里、仍挂起的请求
// **必须**逐条 `acp_respond`——permission 回 `{outcome: cancelled}`、elicitation 回 `{action: cancel}`，
// 否则 agent 会一直等着（`RestoreResult` 的两组 id，见 lib/projection/session_store.dart 的注释）。
// 另外核对：`session/cancel` 由核心自动回 cancelled，前端不得再回一遍（api.rs 的契约）。

import 'dart:async';

import 'package:acp_agent_client/app/core_bridge.dart';
import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记账用的假核心：只记调用，不做任何 IO。
class FakeCore implements CoreCommands {
  final List<(String requestId, JsonMap response)> responded = <(String, JsonMap)>[];
  final List<List<Object?>> prompts = <List<Object?>>[];
  int cancels = 0;

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

  @override
  Stream<CoreEventRecord> on(CoreEvent channel) => const Stream<CoreEventRecord>.empty();

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
  Future<JsonMap> agentSettingsGet() async => <String, dynamic>{'agent_servers': <String, dynamic>{}};

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

const String _agent = 'a';
const String _session = 'sess_1';

/// 建一个「一轮里既有挂起的 permission 又有挂起的 elicitation」的控制器。
(WorkbenchController, FakeCore, TurnEntry) _scenario() {
  final core = FakeCore();
  final c = WorkbenchController(source: DataSource.bridge, bridge: core)
    ..agentId = _agent
    ..sessionId = _session;
  final store = c.sessions.session(_session, agentId: _agent);
  final turn = store.startTurn(<ContentBlockWire>[
    const ContentBlockWire(<String, dynamic>{'type': 'text', 'text': '原始提示'}),
  ]);
  c.sessions.applyClientRequestEnvelope(<String, dynamic>{
    'agentId': _agent,
    'requestId': 'req_perm',
    'method': 'session/request_permission',
    'params': <String, dynamic>{
      'sessionId': _session,
      'toolCall': <String, dynamic>{'toolCallId': 'call_1', 'title': '删文件'},
      'options': <Object?>[
        <String, dynamic>{'optionId': 'ok', 'name': 'Allow', 'kind': 'allow_once'},
      ],
    },
  });
  c.sessions.applyClientRequestEnvelope(<String, dynamic>{
    'agentId': _agent,
    'requestId': 'req_elic',
    'method': 'elicitation/create',
    'params': <String, dynamic>{
      'mode': 'form',
      'message': '选一个环境',
      'sessionId': _session,
      'requestedSchema': <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}},
    },
  });
  return (c, core, turn);
}

void main() {
  test('Restore 截断时两组挂起请求都要 acp_respond（permission cancelled / elicitation cancel）', () async {
    final (c, core, turn) = _scenario();
    final store = c.sessions.session(_session);
    expect(store.pending.forSession(_session).length, 2, reason: '两条都还挂着');

    await c.restore(turn);

    final byId = <String, JsonMap>{for (final r in core.responded) r.$1: r.$2};
    expect(byId.keys.toSet(), <String>{'req_perm', 'req_elic'}, reason: '一条都不能漏，否则 agent 挂起');
    expect(byId['req_perm'], <String, dynamic>{'outcome': <String, dynamic>{'outcome': 'cancelled'}});
    expect(byId['req_elic']!['action'], 'cancel');
    expect(store.pending.forSession(_session), isEmpty);
    // 截断后用原 prompt 同会话重发。
    expect(core.prompts.single.length, 1);
    expect((core.prompts.single.single as JsonMap)['text'], '原始提示');
    c.dispose();
  });

  test('Regenerate 用新文本重发，同样先回应被截断的挂起请求', () async {
    final (c, core, turn) = _scenario();
    await c.restore(turn, newText: '改过的提示');

    expect(core.responded.length, 2);
    expect(core.prompts.single.length, 1);
    expect((core.prompts.single.single as JsonMap)['text'], '改过的提示');
    c.dispose();
  });

  test('session/cancel 只发命令、不重复回应（挂起的权限由核心自动回 cancelled）', () async {
    final (c, core, _) = _scenario();
    await c.cancel();

    expect(core.cancels, 1);
    expect(core.responded, isEmpty, reason: 'acp_respond 由核心侧做，前端再回一遍会撞 unknown_request');
    c.dispose();
  });

  test('权限与 elicitation 的回应载荷原样来自投影层', () async {
    final (c, core, _) = _scenario();
    await c.answerPermission('req_perm', 'ok');
    await c.answerElicitation('req_elic', 'accept', <String, dynamic>{'env': 'dev'});

    final byId = <String, JsonMap>{for (final r in core.responded) r.$1: r.$2};
    expect(byId['req_perm'], <String, dynamic>{
      'outcome': <String, dynamic>{'outcome': 'selected', 'optionId': 'ok'},
    });
    expect(byId['req_elic'], <String, dynamic>{
      'action': 'accept',
      'content': <String, dynamic>{'env': 'dev'},
    });
    c.dispose();
  });
}
