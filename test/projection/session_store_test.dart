// 投影层单测（R2 验收 1）：docs/acp-projection.md § 7 八项自造态、§ 2.2 合并语义、§ 3.1 cancel 后挂起权限回 cancelled、
// § 8.3 逐项跳过、子代理分组只按 _meta 键（docs/design.md § 4）。纯 Dart 逻辑，不起 widget。

import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/projection/session_store.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固定步进时钟：每次取值 +100ms，测试可断言耗时。
class FakeClock {
  DateTime _t = DateTime.utc(2026, 9, 15, 12);

  DateTime call() {
    _t = _t.add(const Duration(milliseconds: 100));
    return _t;
  }
}

const String sid = 'sess_t';

SessionStore newStore({FakeClock? clock}) => SessionStore(sessionId: sid, clock: (clock ?? FakeClock()).call);

JsonMap chunk(String tag, String text, {String? messageId, JsonMap? meta}) => <String, dynamic>{
      'sessionUpdate': tag,
      'messageId': ?messageId,
      'content': <String, dynamic>{'type': 'text', 'text': text},
      '_meta': ?meta,
    };

JsonMap tool(String id, {String? title, String? kind, String? status, List<JsonMap>? content, List<JsonMap>? locations, JsonMap? meta, bool update = false}) =>
    <String, dynamic>{
      'sessionUpdate': update ? 'tool_call_update' : 'tool_call',
      'toolCallId': id,
      'title': ?title,
      'kind': ?kind,
      'status': ?status,
      'content': ?content,
      'locations': ?locations,
      '_meta': ?meta,
    };

JsonMap permissionEnvelope(String requestId, String toolCallId, {String? sessionId = sid}) => <String, dynamic>{
      'agentId': 'a',
      'requestId': requestId,
      'method': 'session/request_permission',
      'params': <String, dynamic>{
        'sessionId': sessionId,
        'toolCall': <String, dynamic>{'toolCallId': toolCallId},
        'options': <JsonMap>[
          <String, dynamic>{'optionId': 'allow', 'name': '允许', 'kind': 'allow_once'},
          <String, dynamic>{'optionId': 'reject', 'name': '拒绝', 'kind': 'reject_once'},
        ],
      },
    };

void main() {
  group('§ 7.1 工具调用的本地 cancelled 态 + § 3.1 cancel 后挂起权限回 cancelled', () {
    test('cancel 只标未完成的工具卡，已完成的不动；挂起权限回 cancelled', () {
      final s = newStore();
      s.startTurn(const <ContentBlockWire>[]);
      s.applyUpdateJson(tool('t1', title: 'Run', kind: 'execute', status: 'in_progress'));
      s.applyUpdateJson(tool('t2', title: 'Read', kind: 'read', status: 'completed'));
      s.applyUpdateJson(tool('t3', title: 'Search', kind: 'search', status: 'pending'));
      s.applyClientRequest(ClientRequestEnvelope(permissionEnvelope('req1', 't1')));
      expect(s.pending.forSession(sid), hasLength(1));

      final r = s.cancel();
      expect(r.toolCallIds, unorderedEquals(<String>['t1', 't3']));
      expect(r.cancelledRequestIds, <String>['req1']);
      expect(s.toolCalls['t1']!.displayStatus, ToolDisplayStatus.cancelled);
      expect(s.toolCalls['t3']!.displayStatus, ToolDisplayStatus.cancelled);
      expect(s.toolCalls['t2']!.displayStatus, ToolDisplayStatus.completed);
      // 协议状态不被伪造：t1 的 status 仍是 in_progress，cancelled 只是本地态。
      expect(s.toolCalls['t1']!.status, ToolStatus.inProgress);
      final p = s.pending.byRequestId('req1')! as PermissionEntry;
      expect(p.status, PendingStatus.cancelled);
      expect(s.pending.forSession(sid), isEmpty);
      // 已 cancelled 的请求不能再回答。
      expect(s.answerPermission('req1', 'allow'), isNull);
    });

    test('cancel 之后到达的 tool_call_update completed 仍按协议覆盖 status，但本地 cancelled 标记保留', () {
      final s = newStore();
      s.applyUpdateJson(tool('t1', title: 'Run', kind: 'execute', status: 'in_progress'));
      s.cancel();
      s.applyUpdateJson(tool('t1', status: 'completed', update: true));
      expect(s.toolCalls['t1']!.status, ToolStatus.completed);
      expect(s.toolCalls['t1']!.cancelledLocally, isTrue);
    });

    test(r'回应权限得到 acp_respond 载荷；$/cancel_request 撤回；elicitation/complete 收尾', () {
      final s = newStore();
      s.applyClientRequest(ClientRequestEnvelope(permissionEnvelope('req1', 't1')));
      final payload = s.answerPermission('req1', 'allow');
      expect(payload, <String, dynamic>{
        'outcome': <String, dynamic>{'outcome': 'selected', 'optionId': 'allow'},
      });
      s.applyClientRequest(ClientRequestEnvelope(permissionEnvelope('req2', 't2')));
      s.applyClientRequest(const ClientRequestEnvelope(<String, dynamic>{
        'agentId': 'a',
        'requestId': null,
        'method': r'$/cancel_request',
        'params': <String, dynamic>{'requestId': 'req2'},
      }));
      expect((s.pending.byRequestId('req2')! as PermissionEntry).status, PendingStatus.withdrawn);

      s.applyClientRequest(const ClientRequestEnvelope(<String, dynamic>{
        'agentId': 'a',
        'requestId': 'req3',
        'method': 'elicitation/create',
        'params': <String, dynamic>{'mode': 'url', 'message': 'login', 'sessionId': sid, 'elicitationId': 'el1', 'url': 'https://x'},
      }));
      expect(s.answerElicitation('req3', 'accept'), <String, dynamic>{'action': 'accept', 'content': <String, dynamic>{}});
      s.applyClientRequest(const ClientRequestEnvelope(<String, dynamic>{
        'agentId': 'a',
        'requestId': null,
        'method': 'elicitation/complete',
        'params': <String, dynamic>{'elicitationId': 'el1'},
      }));
      expect((s.pending.byRequestId('req3')! as ElicitationEntry).status, PendingStatus.completed);
    });

    test('URL elicitation 已 accept 后 Cancel 只本地标 cancelled，没有第二个响应', () {
      final s = newStore();
      s.applyClientRequest(const ClientRequestEnvelope(<String, dynamic>{
        'agentId': 'a',
        'requestId': 'u2',
        'method': 'elicitation/create',
        'params': <String, dynamic>{'mode': 'url', 'message': 'login', 'sessionId': sid, 'elicitationId': 'el9', 'url': 'https://x'},
      }));
      s.pending.markOpened('u2');
      expect(s.answerElicitation('u2', 'accept'), <String, dynamic>{'action': 'accept', 'content': <String, dynamic>{}});
      expect(s.pending.cancelRequest('u2', now: s.now), isTrue);
      final el = s.pending.byRequestId('u2')! as ElicitationEntry;
      expect(el.status, PendingStatus.cancelled);
      expect(s.answerElicitation('u2', 'cancel'), isNull);
      // 表单模式已回应的不能本地取消。
      s.applyClientRequest(const ClientRequestEnvelope(<String, dynamic>{
        'agentId': 'a',
        'requestId': 'f2',
        'method': 'elicitation/create',
        'params': <String, dynamic>{'mode': 'form', 'message': 'q', 'sessionId': sid, 'requestedSchema': <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}}},
      }));
      s.answerElicitation('f2', 'accept', content: <String, dynamic>{});
      expect(s.pending.cancelRequest('f2', now: s.now), isFalse);
    });

    test(r'Sessions 处理 elicitation/complete 与 $/cancel_request 通知时，所属 SessionStore 也通知', () {
      final sessions = Sessions(clock: FakeClock().call);
      sessions.applyClientRequestEnvelope(<String, dynamic>{
        'agentId': 'a',
        'requestId': 'u1',
        'method': 'elicitation/create',
        'params': <String, dynamic>{'mode': 'url', 'message': 'login', 'sessionId': sid, 'elicitationId': 'e9', 'url': 'https://x'},
      });
      sessions.applyClientRequestEnvelope(permissionEnvelope('p9', 't1'));
      final s = sessions.maybe(sid)!;
      var n = 0;
      s.addListener(() => n++);
      sessions.applyClientRequestEnvelope(<String, dynamic>{
        'agentId': 'a',
        'requestId': null,
        'method': 'elicitation/complete',
        'params': <String, dynamic>{'elicitationId': 'e9'},
      });
      expect(n, 1);
      expect((sessions.pending.byRequestId('u1')! as ElicitationEntry).status, PendingStatus.completed);
      sessions.applyClientRequestEnvelope(<String, dynamic>{
        'agentId': 'a',
        'requestId': null,
        'method': r'$/cancel_request',
        'params': <String, dynamic>{'requestId': 'p9'},
      });
      expect(n, 2);
      expect((sessions.pending.byRequestId('p9')! as PermissionEntry).status, PendingStatus.withdrawn);
    });

    test('requestScope 的 elicitation 只进队列不进转录', () {
      final sessions = Sessions(clock: FakeClock().call);
      sessions.applyClientRequestEnvelope(<String, dynamic>{
        'agentId': 'a',
        'requestId': 'rs1',
        'method': 'elicitation/create',
        'params': <String, dynamic>{'mode': 'url', 'message': 'login', 'requestId': 'auth_1', 'elicitationId': 'el2', 'url': 'https://x'},
      });
      expect(sessions.pending.requestScope, hasLength(1));
      expect(sessions.all, isEmpty);
    });
  });

  group('§ 7.2 消息边界与分组', () {
    test('同 messageId 合并，messageId 变化另起一条', () {
      final s = newStore();
      s.applyUpdateJson(chunk('agent_message_chunk', 'a', messageId: 'm1'));
      s.applyUpdateJson(chunk('agent_message_chunk', 'b', messageId: 'm1'));
      s.applyUpdateJson(chunk('agent_message_chunk', 'c', messageId: 'm2'));
      final msgs = s.entries.whereType<MessageEntry>().toList();
      expect(msgs, hasLength(2));
      expect(msgs[0].text, 'ab');
      expect(msgs[1].text, 'c');
    });

    test('无 messageId 时按角色连续合并；角色变化或别的条目插入后另起', () {
      final s = newStore();
      s.applyUpdateJson(chunk('agent_message_chunk', 'a'));
      s.applyUpdateJson(chunk('agent_message_chunk', 'b'));
      s.applyUpdateJson(chunk('user_message_chunk', 'u'));
      s.applyUpdateJson(chunk('agent_message_chunk', 'c'));
      s.applyUpdateJson(tool('t1', title: 'x', kind: 'read', status: 'completed'));
      s.applyUpdateJson(chunk('agent_message_chunk', 'd'));
      final msgs = s.entries.whereType<MessageEntry>().map((m) => '${m.role.name}:${m.text}').toList();
      expect(msgs, <String>['agent:ab', 'user:u', 'agent:c', 'agent:d']);
    });

    test('有 id 与无 id 不合并', () {
      final s = newStore();
      s.applyUpdateJson(chunk('agent_message_chunk', 'a', messageId: 'm1'));
      s.applyUpdateJson(chunk('agent_message_chunk', 'b'));
      expect(s.entries.whereType<MessageEntry>(), hasLength(2));
    });
  });

  group('§ 7.3 本地时间戳', () {
    test('条目带时钟给的时间；思考块耗时 = 最后一个 chunk 与第一个 chunk 之差', () {
      final clock = FakeClock();
      final s = newStore(clock: clock);
      s.applyUpdateJson(chunk('agent_thought_chunk', 'a'));
      s.applyUpdateJson(chunk('agent_thought_chunk', 'b'));
      s.applyUpdateJson(chunk('agent_thought_chunk', 'c'));
      final th = s.entries.single as ThoughtEntry;
      expect(th.at, DateTime.utc(2026, 9, 15, 12, 0, 0, 100));
      expect(th.elapsed, const Duration(milliseconds: 200));
    });
  });

  group('§ 7.4 先到的 tool_call_update 凭空建卡', () {
    test('update 先到建卡并标记；随后的 tool_call 补全同一张卡而不是新建', () {
      final s = newStore();
      s.applyUpdateJson(tool('t1', status: 'in_progress', update: true));
      expect(s.toolCalls['t1']!.createdFromUpdate, isTrue);
      expect(s.toolCalls['t1']!.title, '(未命名工具调用)');
      s.applyUpdateJson(tool('t1', title: 'Read file', kind: 'read', status: 'completed'));
      expect(s.entries.whereType<ToolCallEntry>(), hasLength(1));
      expect(s.toolCalls['t1']!.title, 'Read file');
      expect(s.toolCalls['t1']!.kind, ToolKind.read);
      expect(s.toolCalls['t1']!.status, ToolStatus.completed);
    });

    test('权限请求只带 toolCallId：标题与 kind 从已累积的 tool call 取', () {
      final s = newStore();
      s.applyUpdateJson(tool('t1', title: 'Delete', kind: 'delete', status: 'pending'));
      final e = s.applyClientRequest(ClientRequestEnvelope(permissionEnvelope('r', 't1')))! as PermissionEntry;
      expect(e.toolCallPatch.title, isNull);
      expect(s.toolCalls[e.toolCallId!]!.title, 'Delete');
    });
  });

  group('§ 7.5 终端释放后的输出留存', () {
    test('release 后输出仍在缓冲里；截断落在字符边界', () {
      final s = newStore();
      s.applyUpdateJson(tool('t1', title: 'Run', kind: 'execute', status: 'in_progress', content: <JsonMap>[
        <String, dynamic>{'type': 'terminal', 'terminalId': 'term_1'},
      ]));
      s.applyTerminalText('term_1', 'hello\n');
      s.applyTerminalExit('term_1', exitCode: 0);
      s.markTerminalReleased('term_1');
      final t = s.terminals['term_1']!;
      expect(t.released, isTrue);
      expect(t.output, 'hello\n');
      expect(t.exitCode, 0);
      expect(s.toolCalls['t1']!.terminalIds, <String>['term_1']);

      final small = s.terminals.ensure('term_2', limit: 6);
      // 4 个 emoji（每个 2 个 code unit），限 6 个 code unit：从字符边界起截，剩下 3 个完整 emoji 而不是半个代理对。
      small.append('😀😀😀😀');
      expect(small.truncated, isTrue);
      expect(small.output, '😀😀😀');
      expect(small.output.codeUnitAt(0), isNot(inInclusiveRange(0xDC00, 0xDFFF)));
    });
  });

  group('§ 7.6 思考块的折叠单元', () {
    test('连续 thought 合成一段；消息到达关闭；再来的 thought 另起一段', () {
      final s = newStore();
      s.applyUpdateJson(chunk('agent_thought_chunk', 'a'));
      s.applyUpdateJson(chunk('agent_thought_chunk', 'b'));
      expect(s.entries.single, isA<ThoughtEntry>());
      expect((s.entries.single as ThoughtEntry).closed, isFalse);
      s.applyUpdateJson(chunk('agent_message_chunk', 'x'));
      expect((s.entries.first as ThoughtEntry).closed, isTrue);
      s.applyUpdateJson(chunk('agent_thought_chunk', 'c'));
      final thoughts = s.entries.whereType<ThoughtEntry>().toList();
      expect(thoughts, hasLength(2));
      expect(thoughts[0].text, 'ab');
      expect(thoughts[1].text, 'c');
      s.endTurn(stopReason: 'end_turn');
      expect(thoughts[1].closed, isTrue);
    });
  });

  group('§ 7.7 每轮的边界', () {
    test('startTurn / endTurn 记 stopReason 与回合级 usage；Restore 截断其后全部投影块', () {
      final s = newStore();
      final t1 = s.startTurn(const <ContentBlockWire>[ContentBlockWire(<String, dynamic>{'type': 'text', 'text': 'hi'})]);
      s.applyUpdateJson(tool('t1', title: 'Read', kind: 'read', status: 'completed'));
      s.endTurn(stopReason: 'end_turn', usage: <String, dynamic>{'totalTokens': 10, 'inputTokens': 8, 'outputTokens': 2});
      expect(t1.stopReason, 'end_turn');
      expect(t1.usage!.total, 10);
      expect(t1.isRunning, isFalse);
      final t2 = s.startTurn(const <ContentBlockWire>[]);
      s.applyUpdateJson(tool('t2', title: 'Read', kind: 'read', status: 'completed'));
      s.applyUpdateJson(<String, dynamic>{'sessionUpdate': 'plan', 'entries': <JsonMap>[]});
      expect(s.turnCount, 2);
      expect(s.isRunning, isTrue);

      final restored = s.restoreTo(t2.id)!;
      expect(restored.turn, same(t2));
      expect(restored.cancelledRequestIds, isEmpty);
      expect(restored.cancelledElicitationIds, isEmpty);
      expect(s.entries.whereType<TurnEntry>(), hasLength(1));
      expect(s.toolCalls.contains('t2'), isFalse);
      expect(s.toolCalls.contains('t1'), isTrue);
      expect(s.plans[PlanCardEntry.stablePlanId], isNull);
      expect(s.turnCount, 1);
      expect(s.isRunning, isFalse);
    });

    test('Restore 截断范围内仍挂起的 permission / elicitation 标 cancelled 并返回 id（截断前的不动）', () {
      final s = newStore();
      s.startTurn(const <ContentBlockWire>[]);
      s.applyClientRequest(ClientRequestEnvelope(permissionEnvelope('keep', 't0')));
      s.endTurn(stopReason: 'end_turn');
      final t2 = s.startTurn(const <ContentBlockWire>[]);
      s.applyUpdateJson(tool('sub', title: 'Task', kind: 'other', status: 'in_progress', meta: <String, dynamic>{'claudeCode': <String, dynamic>{'subagent': true}}));
      // 权限卡本身落顶层（不按 _meta 嵌套），这里只验证它属于被截断的轮；children 的递归收集由消息 / 思考 / 工具的嵌套覆盖。
      s.applyClientRequest(ClientRequestEnvelope(permissionEnvelope('nested', 'sub')));
      s.applyClientRequest(ClientRequestEnvelope(permissionEnvelope('answered', 't1')));
      s.answerPermission('answered', 'allow');
      s.applyClientRequest(const ClientRequestEnvelope(<String, dynamic>{
        'agentId': 'a',
        'requestId': 'el',
        'method': 'elicitation/create',
        'params': <String, dynamic>{'mode': 'url', 'message': 'login', 'sessionId': sid, 'elicitationId': 'e1', 'url': 'https://x'},
      }));

      final r = s.restoreTo(t2.id)!;
      expect(r.cancelledRequestIds, <String>['nested']);
      expect(r.cancelledElicitationIds, <String>['el']);
      expect((s.pending.byRequestId('nested')! as PermissionEntry).status, PendingStatus.cancelled);
      expect((s.pending.byRequestId('answered')! as PermissionEntry).status, PendingStatus.answered);
      final el = s.pending.byRequestId('el')! as ElicitationEntry;
      expect(el.status, PendingStatus.cancelled);
      expect(el.action, 'cancel');
      expect((s.pending.byRequestId('keep')! as PermissionEntry).status, PendingStatus.pending);
      expect(s.pending.pending, hasLength(1));
      expect(s.pending.pending.single, same(s.pending.byRequestId('keep')));
    });
  });

  group('§ 7.8 用户消息的本地回显', () {
    ContentBlockWire text(String t) => ContentBlockWire(<String, dynamic>{'type': 'text', 'text': t});
    const ContentBlockWire link = ContentBlockWire(<String, dynamic>{'type': 'resource_link', 'uri': 'file:///a.dart', 'name': 'a.dart'});

    test('startTurn 把发出去的那批块落成用户气泡（一等 agent 实时一轮里不发 user_message_chunk）', () {
      final s = newStore();
      s.startTurn(<ContentBlockWire>[text('看一眼 '), link]);
      final msg = s.entries.whereType<MessageEntry>().single;
      expect(msg.role, MessageRole.user);
      expect(msg.optimistic, isTrue);
      expect(msg.messageId, isNull);
      expect(msg.blocks, hasLength(2));
      expect(msg.text, '看一眼 ');
      // 气泡在检查点之后：Restore / Regenerate 按它前面那条 TurnEntry 截断。
      expect(s.entries.first, isA<TurnEntry>());
      expect(s.entries[1], same(msg));
    });

    test('空 prompt 不造气泡', () {
      final s = newStore();
      s.startTurn(const <ContentBlockWire>[]);
      expect(s.entries.whereType<MessageEntry>(), isEmpty);
    });

    test('agent 把同一批块回显回来：按块内容去重，并认领协议 messageId', () {
      final s = newStore();
      s.startTurn(<ContentBlockWire>[text('看一眼 '), link]);
      s.applyUpdateJson(chunk('user_message_chunk', '看一眼 ', messageId: 'msg_u1'));
      s.applyUpdateJson(<String, dynamic>{'sessionUpdate': 'user_message_chunk', 'messageId': 'msg_u1', 'content': link.json});
      final msg = s.entries.whereType<MessageEntry>().single;
      expect(msg.messageId, 'msg_u1');
      expect(msg.blocks, hasLength(2));
      // 同一条消息里的新块照常并进来。
      s.applyUpdateJson(chunk('user_message_chunk', ' 再动手。', messageId: 'msg_u1'));
      expect(s.entries.whereType<MessageEntry>().single.blocks, hasLength(3));
      expect(msg.text, '看一眼  再动手。');
    });

    test('回显内容对不上且带了 messageId：另起一条，不并进本地那条', () {
      final s = newStore();
      s.startTurn(<ContentBlockWire>[text('hi')]);
      s.applyUpdateJson(chunk('user_message_chunk', '（agent 改写过的 prompt）', messageId: 'msg_u9'));
      final msgs = s.entries.whereType<MessageEntry>().toList();
      expect(msgs, hasLength(2));
      expect(msgs[0].optimistic, isTrue);
      expect(msgs[0].messageId, isNull);
      expect(msgs[1].optimistic, isFalse);
      expect(msgs[1].messageId, 'msg_u9');
    });

    test('回显内容对不上、又**没带** messageId：照样另起一条，不并进用户那条（审查 P2）', () {
      final s = newStore();
      s.startTurn(<ContentBlockWire>[text('hi')]);
      s.applyUpdateJson(chunk('user_message_chunk', '（agent 改写过的 prompt）'));
      final msgs = s.entries.whereType<MessageEntry>().toList();
      expect(msgs, hasLength(2));
      expect(msgs[0].optimistic, isTrue);
      expect(msgs[0].text, 'hi'); // 修前：两边 messageId 都是 null，改写文本被并进这条成了 'hi（agent 改写过的 prompt）'
      expect(msgs[1].optimistic, isFalse);
      expect(msgs[1].messageId, isNull);
      expect(msgs[1].text, '（agent 改写过的 prompt）');
      // 后续 chunk 跟进新起的那条，不再另开。
      s.applyUpdateJson(chunk('user_message_chunk', ' 补一句'));
      final after = s.entries.whereType<MessageEntry>().toList();
      expect(after, hasLength(2));
      expect(after[1].text, '（agent 改写过的 prompt） 补一句');
    });

    test('回显后先来了 thought / 工具卡，agent 再回显同一批块：照样去重（审查 P2）', () {
      final s = newStore();
      s.startTurn(<ContentBlockWire>[text('看一眼 ')]);
      // 修前：去重只看 `list.last`，这两条一插进来就失效、同一句话出两遍。
      s.applyUpdateJson(chunk('agent_thought_chunk', '想一想'));
      s.applyUpdateJson(tool('t1', title: 'Read', status: 'pending'));
      s.applyUpdateJson(chunk('user_message_chunk', '看一眼 ', messageId: 'msg_u1'));
      final msgs = s.entries.whereType<MessageEntry>().toList();
      expect(msgs, hasLength(1));
      expect(msgs.single.optimistic, isTrue);
      expect(msgs.single.messageId, 'msg_u1'); // 认领回来
    });

    test('上一轮的回显不能拿来给这一轮去重：两轮发同一句话都要在（审查 P2）', () {
      final s = newStore();
      s.startTurn(<ContentBlockWire>[text('再来一遍')]);
      s.endTurn(stopReason: 'end_turn');
      s.startTurn(<ContentBlockWire>[text('再来一遍')]);
      // 本轮的回显与上一轮文字一样；`_openEcho` 扫到轮边界就停，只会命中本轮这条。
      s.applyUpdateJson(chunk('user_message_chunk', '再来一遍', messageId: 'msg_u2'));
      final msgs = s.entries.whereType<MessageEntry>().toList();
      expect(msgs, hasLength(2));
      expect(msgs[0].messageId, isNull); // 上一轮的没被认领
      expect(msgs[1].messageId, 'msg_u2');
      expect(msgs[1].blocks, hasLength(1)); // 没出第二遍
    });

    test('Restore 连本地回显一起截断，重发时再回显一次', () {
      final s = newStore();
      final t1 = s.startTurn(<ContentBlockWire>[text('hi')]);
      s.applyUpdateJson(chunk('agent_message_chunk', 'ok'));
      s.endTurn(stopReason: 'end_turn');
      expect(s.restoreTo(t1.id)!.turn, same(t1));
      expect(s.entries, isEmpty);
      s.startTurn(<ContentBlockWire>[text('hi2')]);
      expect(s.entries.whereType<MessageEntry>().single.text, 'hi2');
    });
  });

  group('§ 2.2 合并语义', () {
    test('content / locations 整体替换；只更新给出的字段；update 的 _meta 不并进卡', () {
      final s = newStore();
      s.applyUpdateJson(tool('t1', title: 'Read', kind: 'read', status: 'pending', meta: <String, dynamic>{'x': 1}, content: <JsonMap>[
        <String, dynamic>{'type': 'content', 'content': <String, dynamic>{'type': 'text', 'text': 'one'}},
      ], locations: <JsonMap>[
        <String, dynamic>{'path': '/a', 'line': 1},
      ]));
      s.applyUpdateJson(tool('t1', status: 'completed', update: true, meta: <String, dynamic>{'y': 2}, content: <JsonMap>[
        <String, dynamic>{'type': 'content', 'content': <String, dynamic>{'type': 'text', 'text': 'two'}},
      ], locations: <JsonMap>[
        <String, dynamic>{'path': '/b', 'line': 2},
      ]));
      final e = s.toolCalls['t1']!;
      expect(e.title, 'Read');
      expect(e.kind, ToolKind.read);
      expect(e.status, ToolStatus.completed);
      expect(e.content, hasLength(1));
      expect(e.content.single.content!.text, 'two');
      expect(e.locations.single.path, '/b');
      expect(e.meta, <String, dynamic>{'x': 1});
    });

    test('未知 kind 落 other 并保留原文；未知 status 整条丢弃且卡不变', () {
      final s = newStore();
      s.applyUpdateJson(tool('t1', title: 'X', kind: 'sculpt', status: 'pending'));
      expect(s.toolCalls['t1']!.kind, ToolKind.other);
      expect(s.toolCalls['t1']!.rawKind, 'sculpt');
      s.applyUpdateJson(tool('t1', title: 'Changed', status: 'exploded', update: true));
      expect(s.toolCalls['t1']!.title, 'X');
      expect(s.dropped, hasLength(1));
      expect(s.dropped.single.reason, contains('unknown ToolCallStatus'));
    });

    test('未知 sessionUpdate 变体整条丢弃并计数；已知变体计入 seen', () {
      final s = newStore();
      s.applyUpdateJson(<String, dynamic>{'sessionUpdate': 'notice', 'severity': 'warning', 'title': 'x'});
      s.applyUpdateJson(chunk('agent_message_chunk', 'a'));
      expect(s.dropped, hasLength(1));
      expect(s.seen, <String, int>{'agent_message_chunk': 1});
    });
  });

  group('§ 8.3 content[] 逐项跳过', () {
    test('未知类型的一项被丢，其余保留，计数 +1', () {
      final s = newStore();
      s.applyUpdateJson(tool('t1', title: 'Sum', status: 'completed', update: true, content: <JsonMap>[
        <String, dynamic>{'type': 'content', 'content': <String, dynamic>{'type': 'text', 'text': '1'}},
        <String, dynamic>{'type': 'table', 'rows': <List<String>>[]},
        <String, dynamic>{'type': 'content', 'content': <String, dynamic>{'type': 'text', 'text': '2'}},
      ]));
      final e = s.toolCalls['t1']!;
      expect(e.content, hasLength(2));
      expect(e.skippedContent, 1);
      expect(e.createdFromUpdate, isTrue);
      // content[] 整份替换时，跳过计数跟着这一份走，不累加。
      s.applyUpdateJson(tool('t1', update: true, content: <JsonMap>[
        <String, dynamic>{'type': 'content', 'content': <String, dynamic>{'type': 'text', 'text': '3'}},
      ]));
      expect(e.content, hasLength(1));
      expect(e.skippedContent, 0);
    });
  });

  group('子代理分组（docs/design.md § 4 入站 _meta 键）', () {
    test('claudeCode.parentToolUseId 嵌套到父卡；subagent 键标记子代理卡；dsh_subagent 同样', () {
      final s = newStore();
      s.applyUpdateJson(tool('task1', title: 'Task', kind: 'other', status: 'in_progress', meta: <String, dynamic>{
        'claudeCode': <String, dynamic>{'subagent': true, 'toolName': 'Task'},
      }));
      s.applyUpdateJson(tool('r1', title: 'Read', kind: 'read', status: 'completed', meta: <String, dynamic>{
        'claudeCode': <String, dynamic>{'parentToolUseId': 'task1', 'toolName': 'Read'},
      }));
      s.applyUpdateJson(chunk('agent_message_chunk', 'child says', meta: <String, dynamic>{
        'claudeCode': <String, dynamic>{'parentToolUseId': 'task1'},
      }));
      s.applyUpdateJson(chunk('agent_message_chunk', 'parent says'));
      s.applyUpdateJson(tool('d1', title: 'Delegate', kind: 'other', status: 'completed', meta: <String, dynamic>{
        'dsh_subagent': <String, dynamic>{'session_id': 'c1'},
      }));
      final top = s.entries;
      expect(top.map((e) => e.runtimeType.toString()), <String>['ToolCallEntry', 'MessageEntry', 'ToolCallEntry']);
      final task = top[0] as ToolCallEntry;
      expect(task.isSubagent, isTrue);
      expect(task.children.map((e) => e.runtimeType.toString()), <String>['ToolCallEntry', 'MessageEntry']);
      expect((task.children[0] as ToolCallEntry).parentToolCallId, 'task1');
      expect((task.children[1] as MessageEntry).text, 'child says');
      expect((top[1] as MessageEntry).text, 'parent says');
      expect((top[2] as ToolCallEntry).isSubagent, isTrue);
    });

    test('先到的 tool_call_update 不带分组键、随后 tool_call 才带：卡从顶层搬进父卡 children', () {
      final s = newStore();
      s.applyUpdateJson(tool('c1', status: 'in_progress', update: true));
      final c1 = s.toolCalls['c1']!;
      expect(s.entries, contains(same(c1)));
      s.applyUpdateJson(tool('c1', title: 'Read', kind: 'read', meta: <String, dynamic>{
        'claudeCode': <String, dynamic>{'parentToolUseId': 'p1'},
      }));
      expect(s.entries, isNot(contains(same(c1))));
      final p1 = s.toolCalls['p1']!;
      expect(p1.isSubagent, isTrue);
      expect(p1.children, <TranscriptEntry>[c1]);
      expect(c1.title, 'Read');
      // 再来的 update 不会再搬（分组键首见即锁定）。
      s.applyUpdateJson(tool('c1', status: 'completed', update: true));
      expect(p1.children, hasLength(1));
    });

    test('父卡未到时先凭空建卡，tool_call 到了补标题', () {
      final s = newStore();
      s.applyUpdateJson(tool('r1', title: 'Read', kind: 'read', status: 'completed', meta: <String, dynamic>{
        'claudeCode': <String, dynamic>{'parentToolUseId': 'task1'},
      }));
      expect(s.entries, hasLength(1));
      final placeholder = s.entries.single as ToolCallEntry;
      expect(placeholder.toolCallId, 'task1');
      expect(placeholder.createdFromUpdate, isTrue);
      expect(placeholder.children, hasLength(1));
      s.applyUpdateJson(tool('task1', title: 'Task', kind: 'other', status: 'completed'));
      expect(s.entries, hasLength(1));
      expect(placeholder.title, 'Task');
    });
  });

  group('其它状态规则', () {
    test('config_option_update 全量替换且忽略未知 type；session_info null 清空；current_mode', () {
      final s = newStore();
      s.applyUpdateJson(<String, dynamic>{
        'sessionUpdate': 'config_option_update',
        'configOptions': <JsonMap>[
          <String, dynamic>{'id': 'mode', 'name': 'm', 'type': 'select', 'currentValue': 'ask', 'options': <JsonMap>[]},
          <String, dynamic>{'id': 'x', 'name': 'x', 'type': 'slider', 'currentValue': 3},
          <String, dynamic>{'id': 'b', 'name': 'b', 'type': 'boolean', 'currentValue': true},
        ],
      });
      expect(s.configOptions.map((o) => o.id), <String>['mode', 'b']);
      s.applyUpdateJson(<String, dynamic>{'sessionUpdate': 'session_info_update', 'title': 'T'});
      expect(s.title, 'T');
      s.applyUpdateJson(<String, dynamic>{'sessionUpdate': 'session_info_update', 'title': null});
      expect(s.title, isNull);
      s.applyUpdateJson(<String, dynamic>{'sessionUpdate': 'current_mode_update', 'currentModeId': 'code'});
      expect(s.currentModeId, 'code');
    });

    test('计划：稳定 plan 整份替换；plan_update 三种载荷按 planId；plan_removed 打标；本地 ✕ 只隐藏', () {
      final s = newStore();
      s.applyUpdateJson(<String, dynamic>{
        'sessionUpdate': 'plan',
        'entries': <JsonMap>[
          <String, dynamic>{'content': 'a', 'priority': 'high', 'status': 'completed'},
          <String, dynamic>{'content': 'b', 'priority': 'low', 'status': 'pending'},
        ],
      });
      s.applyUpdateJson(<String, dynamic>{
        'sessionUpdate': 'plan',
        'entries': <JsonMap>[
          <String, dynamic>{'content': 'c', 'priority': 'medium', 'status': 'in_progress'},
        ],
      });
      final stable = s.plans[PlanCardEntry.stablePlanId]!;
      expect(stable.items.map((i) => i.content), <String>['c']);
      expect(s.entries.whereType<PlanCardEntry>(), hasLength(1));
      s.applyUpdateJson(<String, dynamic>{
        'sessionUpdate': 'plan_update',
        'plan': <String, dynamic>{'type': 'file', 'planId': 'p2', 'uri': 'file:///x.md'},
      });
      s.applyUpdateJson(<String, dynamic>{
        'sessionUpdate': 'plan_update',
        'plan': <String, dynamic>{'type': 'markdown', 'planId': 'p3', 'content': '# md'},
      });
      expect(s.plans['p2']!.type, PlanPayloadType.file);
      expect(s.plans['p2']!.uri, 'file:///x.md');
      expect(s.plans['p3']!.markdown, '# md');
      s.applyUpdateJson(<String, dynamic>{'sessionUpdate': 'plan_removed', 'planId': 'p3'});
      expect(s.plans['p3']!.removed, isTrue);
      s.dismissPlan('p2');
      expect(s.plans['p2']!.dismissed, isTrue);
      expect(s.entries.whereType<PlanCardEntry>(), hasLength(3));
    });

    test('压缩：按 compactionId 就地打补丁，chunk 追加，summary 整份替换', () {
      final s = newStore();
      s.applyUpdateJson(<String, dynamic>{'sessionUpdate': 'compaction_update', 'compactionId': 'c1', 'status': 'in_progress'});
      s.applyUpdateJson(chunk('compaction_summary_chunk', 'part1')..['compactionId'] = 'c1');
      s.applyUpdateJson(chunk('compaction_summary_chunk', 'part2')..['compactionId'] = 'c1');
      final c = s.compactions['c1']!;
      expect(c.summaryText, 'part1part2');
      s.applyUpdateJson(<String, dynamic>{
        'sessionUpdate': 'compaction_update',
        'compactionId': 'c1',
        'status': 'completed',
        'summary': <JsonMap>[
          <String, dynamic>{'type': 'text', 'text': 'final'},
        ],
      });
      expect(c.status, 'completed');
      expect(c.summaryText, 'final');
      expect(s.entries.whereType<CompactionEntry>(), hasLength(1));
      s.applyUpdateJson(<String, dynamic>{'sessionUpdate': 'compaction_update', 'compactionId': 'c2', 'status': 'failed', 'error': 'boom'});
      expect(s.compactions['c2']!.error, 'boom');
    });

    test('批量：一批 update 只通知一次', () {
      final s = newStore();
      var n = 0;
      s.addListener(() => n++);
      s.batch(() {
        for (var i = 0; i < 10; i++) {
          s.applyUpdateJson(chunk('agent_message_chunk', '$i'));
        }
      });
      expect(n, 1);
      s.applyUpdateJson(chunk('agent_message_chunk', 'x'));
      expect(n, 2);
    });
  });
}
