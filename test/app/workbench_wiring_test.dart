// 组合根接线的单测（R3 验收 10）：Restore / Regenerate 截断时，落在截断范围里、仍挂起的请求
// **必须**逐条 `acp_respond`——permission 回 `{outcome: cancelled}`、elicitation 回 `{action: cancel}`，
// 否则 agent 会一直等着（`RestoreResult` 的两组 id，见 lib/projection/session_store.dart 的注释）。
// 另外核对：`session/cancel` 由核心自动回 cancelled，前端不得再回一遍（api.rs 的契约）。

import 'dart:async';

import 'package:acp_agent_client/app/core_bridge.dart';
import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/ui/shell/shell_common.dart';
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

/// 第一次 `session/prompt` 挂着不返回，直到 [release]；用来复现「回合进行中点 Restore」。
class SlowCore extends FakeCore {
  final List<String> order = <String>[];
  final Completer<void> _gate = Completer<void>();
  bool _first = true;

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<JsonMap> sessionPrompt(String agentId, String sessionId, List<Object?> prompt) async {
    order.add('prompt');
    if (_first) {
      _first = false;
      await _gate.future;
      return <String, dynamic>{'stopReason': 'cancelled'};
    }
    return super.sessionPrompt(agentId, sessionId, prompt);
  }

  @override
  Future<JsonMap> sessionCancel(String agentId, String sessionId) {
    order.add('cancel');
    return super.sessionCancel(agentId, sessionId);
  }
}

/// `session/prompt` 直接抛错（连接断了 / agent 已退出）。
class FailingCore extends FakeCore {
  @override
  Future<JsonMap> sessionPrompt(String agentId, String sessionId, List<Object?> prompt) async {
    throw StateError('not_connected');
  }
}

const String _agent = 'a';
const String _session = 'sess_1';

/// 建一个「一轮里既有挂起的 permission 又有挂起的 elicitation」的控制器。
/// `running: false` = 这一轮已经结束、但两条请求还挂着（Restore 的 `_respondCancelled` 走这条路）。
(WorkbenchController, FakeCore, TurnEntry) _scenario({bool running = true}) {
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
  if (!running) store.endTurn(stopReason: 'end_turn');
  return (c, core, turn);
}

void main() {
  test('轮已结束但请求还挂着时 Restore：两组 id 都要 acp_respond（permission cancelled / elicitation cancel）', () async {
    final (c, core, turn) = _scenario(running: false);
    final store = c.sessions.session(_session);
    expect(store.pending.forSession(_session).length, 2, reason: '两条都还挂着');

    await c.restore(turn);

    final byId = <String, JsonMap>{for (final r in core.responded) r.$1: r.$2};
    expect(byId.keys.toSet(), <String>{'req_perm', 'req_elic'}, reason: '一条都不能漏，否则 agent 挂起');
    expect(byId['req_perm'], <String, dynamic>{'outcome': <String, dynamic>{'outcome': 'cancelled'}});
    expect(byId['req_elic']!['action'], 'cancel');
    expect(store.pending.forSession(_session), isEmpty);
    expect(core.cancels, 0, reason: '轮已经结束，不该再发 session/cancel');
    // 截断后用原 prompt 同会话重发。
    expect(core.prompts.single.length, 1);
    expect((core.prompts.single.single as JsonMap)['text'], '原始提示');
    c.dispose();
  });

  test('Regenerate 用新文本重发，同样先回应被截断的挂起请求', () async {
    final (c, core, turn) = _scenario(running: false);
    await c.restore(turn, newText: '改过的提示');

    expect(core.responded.length, 2);
    expect(core.prompts.single.length, 1);
    expect((core.prompts.single.single as JsonMap)['text'], '改过的提示');
    c.dispose();
  });

  test('轮还在进行时 Restore：权限交给核心的 cancel、elicitation 前端回 cancel，队列清空', () async {
    final (c, core, turn) = _scenario();
    final store = c.sessions.session(_session);
    expect(store.isRunning, isTrue);

    await c.restore(turn);

    final byId = <String, JsonMap>{for (final r in core.responded) r.$1: r.$2};
    expect(core.cancels, 1, reason: '先把在途那一轮收掉');
    expect(byId.keys.toSet(), <String>{'req_elic'}, reason: 'req_perm 由核心 session_cancel 自动回，前端再回会撞 unknown_request');
    expect(byId['req_elic'], <String, dynamic>{'action': 'cancel'});
    expect(store.pending.forSession(_session), isEmpty);
    c.dispose();
  });

  test('session/cancel：权限交给核心，elicitation 前端必须自己回 cancel（审查 finding high）', () async {
    final (c, core, _) = _scenario();
    await c.cancel();

    expect(core.cancels, 1);
    // 权限请求由核心 session_cancel 自动回 cancelled，前端再回一遍会撞 unknown_request。
    expect(core.responded.map((r) => r.$1), isNot(contains('req_perm')));
    // elicitation 核心不管：不回 agent 会一直等着。
    final byId = <String, JsonMap>{for (final r in core.responded) r.$1: r.$2};
    expect(byId.keys.toSet(), <String>{'req_elic'});
    expect(byId['req_elic'], <String, dynamic>{'action': 'cancel'});
    c.dispose();
  });

  test('回合进行中点 Restore：先 cancel 并等在途的 session/prompt 结束，再截断重发（审查 finding high）', () async {
    final core = SlowCore();
    final c = WorkbenchController(source: DataSource.bridge, bridge: core)
      ..agentId = _agent
      ..sessionId = _session;
    final store = c.sessions.session(_session, agentId: _agent);
    c.composer.text = '第一轮';
    final sending = c.send();
    expect(store.isRunning, isTrue);
    final turn = store.entries.whereType<TurnEntry>().first;

    // 第一轮还没返回就点 Restore。
    final restoring = c.restore(turn, newText: '改过的提示');
    core.release();
    await Future.wait(<Future<void>>[sending, restoring]);

    expect(core.cancels, 1, reason: '截断之前要把在途那一轮收掉');
    expect(core.order, <String>['prompt', 'cancel', 'prompt'], reason: '两次 prompt 不能重叠');
    final turns = store.entries.whereType<TurnEntry>().toList();
    expect(turns.length, 1, reason: '旧轮被截断，只剩重发的那一轮');
    expect(turns.single.stopReason, 'end_turn',
        reason: '剩下的是重发那一轮、带它自己的结束值；先返回的那次（cancelled）没有打到它头上');
    c.dispose();
  });

  test('session/prompt 失败也要收轮，否则线程头一直转 spinner（审查第 2 轮 finding P2）', () async {
    final core = FailingCore();
    final c = WorkbenchController(source: DataSource.bridge, bridge: core)
      ..agentId = _agent
      ..sessionId = _session;
    final store = c.sessions.session(_session, agentId: _agent);
    c.composer.text = '会失败的一轮';

    await c.send();

    expect(store.isRunning, isFalse, reason: 'currentTurn 不收，停止键与 spinner 就永远去不掉');
    final turn = store.entries.whereType<TurnEntry>().single;
    expect(turn.endedAt, isNotNull);
    expect(turn.stopReason, isNull, reason: '连接断了没有协议给的结束值，不编一个');
    expect(c.lastError, contains('not_connected'));
    c.dispose();
  });

  test('无已安装 agent：空态 + 「打开 Agents 面板」切右栏 Agents 标签（验收 7）', () async {
    final core = FakeCore(); // agentSettingsGet 回空 agent_servers
    final c = WorkbenchController(source: DataSource.bridge, bridge: core);
    await c.start();

    expect(c.installedAgents, isEmpty);
    expect(c.hasAgent, isFalse, reason: '画板 01 状态 2：线程头 No Agent、输入框禁用');
    expect(c.threadTitle, 'No Agent');
    expect(c.composerPlaceholder, '安装并选择一个 agent 后即可输入');
    expect(c.rightTab, isNull);

    c.openTab(ShellTab.agents);
    expect(c.rightTab, ShellTab.agents);
    expect(c.openTabs, <ShellTab>[ShellTab.agents]);
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
