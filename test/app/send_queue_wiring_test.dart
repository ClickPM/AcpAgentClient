// Round send-queue — 接线单测（fake core，验收 2 / 3）。

import 'dart:async';

import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/ui/popovers/topbar_popovers.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_core.dart';

class _QueueTurnCore extends FakeCore {
  final Map<String, List<Completer<JsonMap>>> turns = <String, List<Completer<JsonMap>>>{};
  final List<String> callLog = <String>[];
  int _seq = 0;

  @override
  Future<JsonMap> agentConnect(String agentId, {String? cwd}) async => <String, dynamic>{
        'agentId': agentId,
        'initialize': <String, dynamic>{
          'protocolVersion': 1,
          'agentInfo': <String, dynamic>{'name': agentId},
          'agentCapabilities': <String, dynamic>{
            'loadSession': true,
            'sessionCapabilities': <String, dynamic>{'close': <String, dynamic>{}},
          },
        },
      };

  @override
  Future<JsonMap> sessionNew(String agentId, String cwd) async => <String, dynamic>{'sessionId': 'sess_${++_seq}'};

  @override
  Future<JsonMap> sessionPrompt(String agentId, String sessionId, List<Object?> prompt) {
    prompts.add(prompt);
    final text = prompt
        .whereType<Map<String, dynamic>>()
        .where((b) => b['type'] == 'text')
        .map((b) => b['text'])
        .join(' ');
    callLog.add('prompt:$sessionId:$text');
    final turn = Completer<JsonMap>();
    (turns[sessionId] ??= <Completer<JsonMap>>[]).add(turn);
    return turn.future;
  }

  @override
  Future<JsonMap> sessionCancel(String agentId, String sessionId) async {
    final result = await super.sessionCancel(agentId, sessionId);
    callLog.add('cancel:$sessionId');
    return result;
  }

  Completer<void>? indexSaveGate;

  @override
  Future<JsonMap> sessionIndexUpsert(JsonMap entry) async {
    final gate = indexSaveGate;
    if (gate != null) await gate.future;
    return super.sessionIndexUpsert(entry);
  }

  void finish(String sessionId, [String stopReason = 'end_turn']) {
    turns[sessionId]!.firstWhere((t) => !t.isCompleted).complete(<String, dynamic>{'stopReason': stopReason});
  }

  void fail(String sessionId, Object error) {
    turns[sessionId]!.firstWhere((t) => !t.isCompleted).completeError(error);
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

WorkbenchController _controller(_QueueTurnCore core) =>
    WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask)
      ..workspace.project = const ProjectRef(path: r'D:\repo', name: 'repo');

Future<String> _startRunning(WorkbenchController c, String text) async {
  await c.session.newSession(const AgentRef(id: 'a', name: 'a'));
  final sid = c.session.sessionId!;
  c.composer.editor.text = text;
  unawaited(c.turn.send());
  await _settle();
  return sid;
}

void main() {
  test('回合进行中连发两条：只入队不发第二个 prompt；放行后依次自动发出且每条恰好一次', () async {
    final core = _QueueTurnCore();
    final c = _controller(core);
    final sid = await _startRunning(c, 'turn-1');

    expect(core.prompts.length, 1);
    expect(c.turn.currentQueue?.length, 0);

    // 在途连发两条
    c.composer.editor.text = 'queued-1';
    await c.turn.send();
    c.composer.editor.text = 'queued-2';
    await c.turn.send();

    // 线上没有第二个 session/prompt，队列里有 2 条
    expect(core.prompts.length, 1);
    expect(c.turn.currentQueue?.length, 2);
    expect(c.composer.editor.text, isEmpty);

    // 放行第 1 轮 → 自动发出 queued-1
    core.finish(sid);
    await _settle();
    expect(core.prompts.length, 2);
    expect(core.callLog.last, 'prompt:$sid:queued-1');
    expect(c.turn.currentQueue?.length, 1);

    // 放行第 2 轮 → 自动发出 queued-2
    core.finish(sid);
    await _settle();
    expect(core.prompts.length, 3);
    expect(core.callLog.last, 'prompt:$sid:queued-2');
    expect(c.turn.currentQueue?.length, 0);

    // 放行第 3 轮 → 队列已空，不再发
    core.finish(sid);
    await _settle();
    expect(core.prompts.length, 3);
  });

  test('Send Now：线上顺序是 session_cancel → 等在途返回 → session_prompt，且只发这一条', () async {
    final core = _QueueTurnCore();
    final c = _controller(core);
    final sid = await _startRunning(c, 'turn-1');

    c.composer.editor.text = 'q-1';
    await c.turn.send();
    c.composer.editor.text = 'q-2';
    await c.turn.send();

    final q2Id = c.turn.currentQueue!.entries[1].id;
    // 对 q-2 点 Send Now
    final sendNowFuture = c.turn.sendNow(sid, q2Id);
    await _settle();

    // 已发出 cancel，但在途 turn-1 还没返回，所以 q-2 还没发出
    expect(core.callLog, <String>['prompt:$sid:turn-1', 'cancel:$sid']);
    expect(c.turn.currentQueue!.isAbsorbingCancel, isTrue);

    // 放行被 cancel 的 turn-1
    core.finish(sid, 'cancelled');
    await _settle();
    unawaited(sendNowFuture);

    // 立即只发出了 q-2，q-1 仍在队列中未双发
    expect(core.callLog, <String>[
      'prompt:$sid:turn-1',
      'cancel:$sid',
      'prompt:$sid:q-2',
    ]);
    expect(c.turn.currentQueue!.length, 1);
    expect(c.turn.currentQueue!.first!.plainText, 'q-1');
  });

  test('手动停止后队列转入 Paused 不自动发；删除 / 编辑 / 清空后不再发出', () async {
    final core = _QueueTurnCore();
    final c = _controller(core);
    final sid = await _startRunning(c, 'turn-1');

    c.composer.editor.text = 'q-1';
    await c.turn.send();
    c.composer.editor.text = 'q-2';
    await c.turn.send();

    // 手动停止
    await c.turn.cancel();
    core.finish(sid, 'cancelled');
    await _settle();

    expect(c.turn.currentQueue!.isPaused, isTrue);
    expect(core.prompts.length, 1); // 没有自动发出 q-1

    // 编辑 q-1 挪回输入框（主输入框已有字时以空行拼在后面）
    c.composer.editor.text = 'prefix';
    final q1Id = c.turn.currentQueue!.first!.id;
    c.turn.editQueued(sid, q1Id);
    expect(c.composer.editor.text, 'prefix\n\nq-1');
    expect(c.turn.currentQueue!.length, 1);

    // 清空剩余
    c.turn.clearQueue(sid);
    expect(c.turn.currentQueue!.isEmpty, isTrue);
  });

  test('裁定 d：回合以错误结束时队列自动转入 Paused，不自动连发；点 resumeQueue 恢复出队', () async {
    final core = _QueueTurnCore();
    final c = _controller(core);
    final sid = await _startRunning(c, 'turn-1');

    c.composer.editor.text = 'q-after-error';
    await c.turn.send();

    core.fail(sid, StateError('turn failed'));
    await _settle();

    expect(c.turn.currentQueue!.isPaused, isTrue);
    expect(core.prompts.length, 1); // 未自动发出

    // 点恢复出队：当前已空闲，立即发出 q-after-error
    c.turn.resumeQueue(sid);
    await _settle();
    expect(core.prompts.length, 2);
    expect(core.callLog.last, 'prompt:$sid:q-after-error');
  });

  test('前台会话关闭不误清后台会话队列；后台收轮后正常自动出队', () async {
    final core = _QueueTurnCore();
    final c = _controller(core);
    final sidA = await _startRunning(c, 'A-1');

    c.composer.editor.text = 'A-queued';
    await c.turn.send();

    // 切到会话 B 并关闭会话 B
    final sidB = await _startRunning(c, 'B-1');
    core.finish(sidB);
    await _settle();
    await c.session.closeSession();
    expect(c.session.sessionClosed, isTrue);

    // 此时前台是已关闭的 B，后台 A 正常收轮：A 的队列不被误清，且自动发出 A-queued
    core.finish(sidA);
    await _settle();
    expect(core.callLog.last, 'prompt:$sidA:A-queued');
  });

  test('closeSession 与 deleteSession 清除会话队列', () async {
    final core = _QueueTurnCore();
    final c = _controller(core);
    final sid = await _startRunning(c, 'm-1');

    c.composer.editor.text = 'm-queued';
    await c.turn.send();
    expect(c.turn.queueFor(sid).length, 1);

    await c.session.closeSession();
    expect(c.turn.queueFor(sid).isEmpty, isTrue);
  });

  test('Paused 后空闲时再发新消息，会恢复队列自动出队', () async {
    final core = _QueueTurnCore();
    final c = _controller(core);
    final sid = await _startRunning(c, 'turn-1');

    c.composer.editor.text = 'queued-1';
    await c.turn.send();

    // 手动停止
    await c.turn.cancel();
    core.finish(sid, 'cancelled');
    await _settle();
    expect(c.turn.queueFor(sid).isPaused, isTrue);

    // 空闲时主动再发一条新消息
    c.composer.editor.text = 'new-active-msg';
    unawaited(c.turn.send());
    await _settle();
    expect(core.prompts.length, 2);

    // 新回合结束收轮：已恢复 autoProcess，自动弹出 queued-1 并发出
    core.finish(sid);
    await _settle();
    expect(core.prompts.length, 3);
    expect(core.callLog.last, 'prompt:$sid:queued-1');

    core.finish(sid);
    await _settle();
  });

  test('Finding 1 验证：endTurn 到 _onTurnStopped 空隙中按 Enter 仍作为入队处理，不双发 prompt', () async {
    final core = _QueueTurnCore();
    final c = _controller(core);
    final sid = await _startRunning(c, 'turn-1');

    // 挂住 sessionIndexUpsert
    core.indexSaveGate = Completer<void>();

    // 让 prompt 返回（触发 s.endTurn，此时 isRunning == false，但仍处于 _turnsInFlight）
    core.finish(sid);
    await _settle();
    expect(c.session.isRunning, isFalse);

    // 在此空隙中输入并发送：应作为入队处理，不能 startTurn 双发
    c.composer.editor.text = 'gap-msg';
    await c.turn.send();
    expect(c.turn.queueFor(sid).length, 1);
    expect(core.prompts.length, 1);

    // 放行 indexSave，_onTurnStopped 在 finally 自动出队发送 gap-msg
    core.indexSaveGate!.complete();
    await _settle();

    expect(core.prompts.length, 2);
    expect(core.callLog.last, 'prompt:$sid:gap-msg');
  });
}
