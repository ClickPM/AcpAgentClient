// 侧栏顺序的口径（所有者裁定 2026-09-18）：按**用户最后一次发消息的时间**倒序。
// 核心按索引的 `updatedAt` 排（rust/settings/src/index.rs 的 `IndexStore::sessions`），所以这里验的是
// 控制器往索引里写的 `updatedAt`：
// - 发消息时打成现在，且在 `session/prompt` 发出之前就写好；
// - 收轮只刷消息计数，不动时间（早发出去、晚跑完的会话不会在收轮时插队）；
// - 改名不动时间；
// - 再发一条才再打。

import 'dart:async';

import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/ui/popovers/topbar_popovers.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_core.dart';

/// `session/prompt` 可以挂住不回：验「发出去之前就打好时间、收轮不再改」要把发与收拆开。
class _GatedCore extends FakeCore {
  Completer<JsonMap>? gate;

  @override
  Future<JsonMap> sessionPrompt(String agentId, String sessionId, List<Object?> prompt) async {
    prompts.add(prompt);
    final g = gate;
    if (g != null) return g.future;
    return <String, dynamic>{'stopReason': 'end_turn'};
  }
}

int _updatedAtOf(FakeCore core, String sessionId) {
  final entry = core.sessionIndex.singleWhere((e) => e['sessionId'] == sessionId);
  return (entry['updatedAt'] as num).toInt();
}

Future<void> _untilPromptSent(FakeCore core) async {
  for (var i = 0; i < 100 && core.prompts.isEmpty; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(core.prompts, isNotEmpty, reason: 'session/prompt 没有发出去');
}

void main() {
  test('索引的 updatedAt 只在用户发消息时打：收轮、改名都不动它', () async {
    final core = _GatedCore();
    final c = WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask)
      ..project = const ProjectRef(path: 'D:/repo', name: 'repo');
    await c.newSession(const AgentRef(id: 'a', name: 'a'));
    final sid = c.sessionId!;
    expect(_updatedAtOf(core, sid), 0, reason: '刚建的会话控制器不传 updatedAt（核心打创建时间；假核心记 0）');

    // 发第一条：session/prompt 挂着不回，索引里已经打上发消息的时间。
    core.gate = Completer<JsonMap>();
    final before = DateTime.now().millisecondsSinceEpoch;
    c.composer.text = '第一条';
    final sending = c.send();
    await _untilPromptSent(core);
    final t1 = _updatedAtOf(core, sid);
    expect(t1, greaterThanOrEqualTo(before), reason: '发出去之前就该打好时间');

    // 隔一会儿再收轮：时间不该被刷成收轮时间。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    core.gate!.complete(<String, dynamic>{'stopReason': 'end_turn'});
    await sending;
    expect(_updatedAtOf(core, sid), t1, reason: '收轮只刷消息计数，不刷时间');
    expect(core.sessionIndex.single['messageCount'], 1);

    // 改名不动时间。
    c.startRename(sid);
    await c.commitRename('改了名');
    expect(core.sessionIndex.single['title'], '改了名');
    expect(_updatedAtOf(core, sid), t1, reason: '改名不是发消息');

    // 再发一条才再打。
    core.gate = null;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    c.composer.text = '第二条';
    await c.send();
    expect(_updatedAtOf(core, sid), greaterThan(t1));
    expect(core.sessionIndex.single['messageCount'], 2);
    c.dispose();
  });
}
