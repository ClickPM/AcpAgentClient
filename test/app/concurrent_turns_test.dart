// 会话并跑时的 Restore / Regenerate（iteration-12，BACKLOG P0「请求与会话路由」第 2 条）。
// 旧实现的在途轮是全局单槽、谁后发谁占：Restore 可能等到别的会话那一轮（被它的长任务挂住），
// 也可能槽已被清空（立即截断重发，旧的 `session/prompt` 晚回来把新开的轮收掉，停止键消失、新轮的结束值落不下）。

import 'dart:async';

import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/projection/session_store.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/ui/popovers/topbar_popovers.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_core.dart';

/// 每次 `session/prompt` 都挂住，由用例按会话逐个放行；每条 `session/new` 发一个不同的 id
/// （`FakeCore` 默认回固定的 `sess_fake`，那样两条会话其实是同一条）。
/// `agent_connect` 回一份 initialize：连上之后 agent 是 initialized 态，第二条新建会话复用同一条连接
/// （`FakeCore` 默认回空对象，每次新建都当成没连上去重连，前一条会话就被标成挂空了）。
class _TurnCore extends FakeCore {
  final Map<String, List<Completer<JsonMap>>> turns = <String, List<Completer<JsonMap>>>{};
  int _seq = 0;

  @override
  Future<JsonMap> agentConnect(String agentId, {String? cwd}) async => <String, dynamic>{
        'agentId': agentId,
        'initialize': <String, dynamic>{
          'protocolVersion': 1,
          'agentInfo': <String, dynamic>{'name': agentId},
          'agentCapabilities': <String, dynamic>{'loadSession': true},
        },
      };

  @override
  Future<JsonMap> sessionNew(String agentId, String cwd) async => <String, dynamic>{'sessionId': 'sess_${++_seq}'};

  @override
  Future<JsonMap> sessionPrompt(String agentId, String sessionId, List<Object?> prompt) {
    prompts.add(prompt);
    final turn = Completer<JsonMap>();
    (turns[sessionId] ??= <Completer<JsonMap>>[]).add(turn);
    return turn.future;
  }

  /// 放行这条会话最早还没回的那次 `session/prompt`。
  void finish(String sessionId, String stopReason) =>
      turns[sessionId]!.firstWhere((t) => !t.isCompleted).complete(<String, dynamic>{'stopReason': stopReason});
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

WorkbenchController _controller(_TurnCore core) =>
    WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask)
      ..workspace.project = const ProjectRef(path: r'D:\repo', name: 'repo');

/// 开一条会话并发一条消息（不回，于是一直在跑）；返回它的 sessionId，它成为当前会话。
Future<String> _startRunning(WorkbenchController c, String text) async {
  await c.session.newSession(const AgentRef(id: 'a', name: 'a'));
  final sid = c.session.sessionId!;
  c.composer.editor.text = text;
  unawaited(c.turn.send());
  await _settle();
  return sid;
}

MessageEntry _firstUserBubble(SessionStore s) => s.entries.whereType<MessageEntry>().firstWhere((m) => m.role == MessageRole.user);

void main() {
  test('别的会话那一轮已经跑完：Restore 仍等本会话旧的那一轮真正返回，旧那轮的 cancelled 不收新开的轮', () async {
    final core = _TurnCore();
    final c = _controller(core);
    final sidA = await _startRunning(c, 'A 的长任务');
    final sidB = await _startRunning(c, 'B 的短任务');
    core.finish(sidB, 'end_turn');
    await _settle();

    await c.session.selectSession(sidA);
    final a = c.sessions.maybe(sidA)!;
    final restoring = c.turn.restore(_firstUserBubble(a), newText: 'A 换个说法');
    await _settle();
    expect(core.cancelledSessions, <(String, String)>[('a', sidA)]);
    expect(core.prompts, hasLength(2), reason: '旧的 session/prompt 还没回，不能先截断重发');

    core.finish(sidA, 'cancelled'); // agent 收到 cancel，旧那一轮回来
    await _settle();
    expect(core.prompts, hasLength(3));
    expect(a.isRunning, isTrue, reason: '新开的轮在跑，停止键要在');
    final fresh = a.currentTurn!;

    core.finish(sidA, 'end_turn');
    await restoring;
    expect(fresh.stopReason, 'end_turn', reason: '新轮的结束值要落得下');
    expect(a.isRunning, isFalse);
    c.dispose();
  });

  test('别的会话的长任务还在跑：Restore 只等本会话那一轮，不被它挂住', () async {
    final core = _TurnCore();
    final c = _controller(core);
    final sidA = await _startRunning(c, 'A');
    final sidB = await _startRunning(c, 'B 的长任务'); // 一直不回

    await c.session.selectSession(sidA);
    final a = c.sessions.maybe(sidA)!;
    final restoring = c.turn.restore(_firstUserBubble(a));
    await _settle();
    core.finish(sidA, 'cancelled');
    await _settle();
    expect(core.prompts, hasLength(3), reason: 'B 还没回也要重发');
    expect(a.isRunning, isTrue);
    expect(c.sessions.maybe(sidB)!.isRunning, isTrue, reason: 'B 那一轮不受影响');

    core.finish(sidA, 'end_turn');
    await restoring;
    expect(a.isRunning, isFalse);
    c.dispose();
  });
}
