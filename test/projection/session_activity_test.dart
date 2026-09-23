// 画板 09 · 等你处理的派生（lib/projection/session_activity.dart）：与「运行中」互斥、最早那一项定种类、
// 按工作区计数（没记 cwd 的只进合计）、requestScope 不算，以及四条了结路径（回应 / agent 撤回 / cancel / agent 退出）。
// 纯 Dart 逻辑，不起 widget。

import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/projection/session_activity.dart';
import 'package:acp_agent_client/projection/session_store.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:flutter_test/flutter_test.dart';

const String _agent = 'agent_a';

/// 测试里工作区键就是 cwd 本身（归一化规则在 `WorkspaceState.normalizeCwd`，由 test/app 那边验）。
SessionActivity _activity(Sessions s) => SessionActivity(s, workspaceKey: (cwd) => cwd);

/// 开一条会话、给 cwd、起一轮（在跑）。
SessionStore _running(Sessions s, String sid, {String? cwd}) {
  final store = s.session(sid, agentId: _agent)..cwd = cwd;
  store.startTurn(<ContentBlockWire>[
    const ContentBlockWire(<String, dynamic>{'type': 'text', 'text': 'go'}),
  ]);
  return store;
}

void _permission(Sessions s, String sid, String requestId) => s.applyClientRequestEnvelope(<String, dynamic>{
      'agentId': _agent,
      'requestId': requestId,
      'method': 'session/request_permission',
      'params': <String, dynamic>{
        'sessionId': sid,
        'toolCall': <String, dynamic>{'toolCallId': 'call_$requestId', 'title': '删文件'},
        'options': <Object?>[
          <String, dynamic>{'optionId': 'ok', 'name': 'Allow', 'kind': 'allow_once'},
        ],
      },
    });

void _elicitation(Sessions s, String? sid, String requestId) => s.applyClientRequestEnvelope(<String, dynamic>{
      'agentId': _agent,
      'requestId': requestId,
      'method': 'elicitation/create',
      'params': <String, dynamic>{
        'mode': 'form',
        'message': '选一个环境',
        'sessionId': ?sid,
        'requestedSchema': <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}},
      },
    });

void main() {
  test('有挂起请求的会话算「等你处理」，不再算在跑；没有的照常在跑', () {
    final s = Sessions();
    _running(s, 's1', cwd: 'A');
    _running(s, 's2', cwd: 'A');
    _permission(s, 's1', 'r1');

    final a = _activity(s);
    expect(a.awaiting.keys, <String>['s1']);
    expect(a.running, <String>{'s2'});
    expect(a.running.intersection(a.awaiting.keys.toSet()), isEmpty, reason: '两者严格互斥');
    expect(a.runningByWorkspace, <String, int>{'A': 1});
    expect(a.awaitingByWorkspace, <String, int>{'A': 1});
    expect(a.workspaceCount, 1);
  });

  test('一条会话同时挂着两种：取最早到的那一项定种类，按会话只数 1', () {
    final s = Sessions();
    _running(s, 's1', cwd: 'A');
    _elicitation(s, 's1', 'e1');
    _permission(s, 's1', 'r1');

    final a = _activity(s);
    expect(a.awaiting['s1'], isA<ElicitationEntry>());
    expect(a.awaitingTotal, 1);
    expect(a.awaitingByWorkspace, <String, int>{'A': 1});

    // 先到的那条了结、后到的还挂着：种类换成后到的那一种。
    s.maybe('s1')!.answerElicitation('e1', 'accept', content: <String, dynamic>{});
    expect(_activity(s).awaiting['s1'], isA<PermissionEntry>());
  });

  test('按工作区计数：没记 cwd 的只进合计；工作区数是在跑与等你两边的并集', () {
    final s = Sessions();
    _running(s, 's1', cwd: 'A');
    _running(s, 's2', cwd: 'B');
    _running(s, 's3');
    _permission(s, 's2', 'r2');
    _permission(s, 's3', 'r3');

    final a = _activity(s);
    expect(a.runningTotal, 1);
    expect(a.awaitingTotal, 2, reason: '没记 cwd 的那条确实在等，合计要算它');
    expect(a.runningByWorkspace, <String, int>{'A': 1});
    expect(a.awaitingByWorkspace, <String, int>{'B': 1});
    expect(a.workspaceCount, 2);
  });

  test('认证阶段不带会话的 elicitation（requestScope，画板 52）不算', () {
    final s = Sessions();
    _running(s, 's1', cwd: 'A');
    _elicitation(s, null, 'rs1');

    final a = _activity(s);
    expect(a.awaiting, isEmpty);
    expect(a.running, <String>{'s1'});
  });

  test('回合没结束时回应了：回到在跑；回合已结束的（不在途）两边都不算', () {
    final s = Sessions();
    final store = _running(s, 's1', cwd: 'A');
    _permission(s, 's1', 'r1');
    store.answerPermission('r1', 'ok');
    expect(_activity(s).running, <String>{'s1'});
    expect(_activity(s).awaiting, isEmpty);

    store.endTurn(stopReason: 'end_turn');
    expect(_activity(s).running, isEmpty);
  });

  test('agent 撤回（\$/cancel_request）、session/cancel、agent 退出都让标记撤掉', () {
    final s = Sessions();
    _running(s, 's1', cwd: 'A');
    final s2 = _running(s, 's2', cwd: 'A');
    _running(s, 's3', cwd: 'A');
    _permission(s, 's1', 'r1');
    _permission(s, 's2', 'r2');
    _elicitation(s, 's3', 'e3');
    expect(_activity(s).awaitingTotal, 3);

    s.applyClientRequestEnvelope(<String, dynamic>{
      'agentId': _agent,
      'requestId': null,
      'method': r'$/cancel_request',
      'params': <String, dynamic>{'requestId': 'r1'},
    });
    expect(_activity(s).awaiting.keys, unorderedEquals(<String>['s2', 's3']));

    s2.cancel();
    expect(_activity(s).awaiting.keys, <String>['s3']);

    s.applyAgentState(<String, dynamic>{'agentId': _agent, 'state': 'exited'});
    expect(_activity(s).awaiting, isEmpty);
  });
}
