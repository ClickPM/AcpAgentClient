// fixtures 回放（R2 验收 1 的后半句）：同一份 fixtures 分批喂与整批喂得到相同状态；15 个变体全部出现；
// 各场景文件回放后的关键状态与文件的意图一致（为 R6 的 session/load 重放打底）。

import 'dart:io';

import 'package:acp_agent_client/projection/batcher.dart';
import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/projection/fixture_line.dart';
import 'package:acp_agent_client/projection/fixture_replay.dart';
import 'package:acp_agent_client/projection/session_store.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeClock {
  DateTime _t = DateTime.utc(2026, 9, 15, 12);

  DateTime call() {
    _t = _t.add(const Duration(milliseconds: 100));
    return _t;
  }
}

const String sid = 'sess_9f3c21a7';

List<FixtureLine> loadFixtures({bool Function(String name)? where}) {
  final files = Directory('test/fixtures').listSync().whereType<File>().where((f) => f.path.endsWith('.jsonl')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final lines = <FixtureLine>[];
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    if (name.startsWith('90-')) continue; // 故意的拒绝行不进回放
    if (where != null && !where(name)) continue;
    lines.addAll(FixtureLine.parseAll(f.readAsStringSync()));
  }
  return lines;
}

Sessions replayWhole(List<FixtureLine> lines) {
  final sessions = Sessions(clock: FakeClock().call);
  FixtureReplayer(sessions).feedAll(lines);
  return sessions;
}

Sessions replayBatched(List<FixtureLine> lines, int batchSize) {
  final sessions = Sessions(clock: FakeClock().call);
  final replayer = FixtureReplayer(sessions);
  final flushes = <void Function()>[];
  final batcher = UpdateBatcher(sessions, scheduler: flushes.add);
  for (var i = 0; i < lines.length; i++) {
    batcher.enqueue(() => replayer.feed(lines[i]));
    if ((i + 1) % batchSize == 0) {
      for (final f in flushes) {
        f();
      }
      flushes.clear();
    }
  }
  for (final f in flushes) {
    f();
  }
  batcher.flush();
  return sessions;
}

void main() {
  final all = loadFixtures();

  test('fixtures 里 15 个 session/update 变体全部出现，且没有变体被丢弃', () {
    final s = replayWhole(all).maybe(sid)!;
    expect(s.seen.keys, unorderedEquals(SessionUpdateKind.values.where((k) => k != SessionUpdateKind.unknown).map((k) => k.wire)));
    expect(s.dropped, isEmpty);
  });

  for (final batchSize in <int>[1, 3, 7, 50]) {
    test('分批（$batchSize 行一批）与整批回放得到相同状态', () {
      final whole = replayWhole(all).debugSnapshot();
      final batched = replayBatched(all, batchSize).debugSnapshot();
      expect(batched, equals(whole));
    });
  }

  test('分批回放时每批只通知一次', () {
    final sessions = Sessions(clock: FakeClock().call);
    final replayer = FixtureReplayer(sessions);
    // 先建会话，再计通知。
    replayer.feedAll(all.take(6));
    var n = 0;
    sessions.maybe(sid)!.addListener(() => n++);
    final rest = all.skip(6).where((l) => l.isSessionUpdate && l.params?['sessionId'] == sid).take(20).toList();
    sessions.batch(() => replayer.feedAll(rest));
    expect(n, 1);
  });

  test('01–08 主线：轮、工具卡、权限、elicitation、终端留存、内容块', () {
    final sessions = replayWhole(loadFixtures(where: (n) => n.compareTo('09') < 0));
    final s = sessions.maybe(sid)!;
    expect(s.turnCount, 1);
    expect(s.isRunning, isFalse);
    final turn = s.entries.whereType<TurnEntry>().single;
    expect(turn.stopReason, 'end_turn');
    expect(turn.usage!.total, 24380);
    expect(s.title, '给 validate.ps1 加 schema 同步校验');
    expect(s.commands.map((c) => c.name), <String>['review', 'compact', 'plan']);
    expect(s.configOptions.map((o) => o.id), <String>['mode', 'model', 'auto_approve_reads', 'thinking']);
    expect(s.currentModeId, 'code');
    expect(s.usage!.used, 6120);

    final read = s.toolCalls['call_read_1']!;
    expect(read.status, ToolStatus.completed);
    expect(read.content.single.content!.text, contains('42 行'));
    expect(read.locations.single.line, 18);

    final edit = s.toolCalls['call_edit_1']!;
    expect(edit.diffs.single.newText, contains('gen-acp-types'));
    final perm = s.pending.byRequestId('fixture-agent', '6')! as PermissionEntry;
    expect(perm.status, PendingStatus.pending, reason: '03 没有记录用户回应，留在队列');

    final exec = s.toolCalls['call_exec_1']!;
    expect(exec.terminalIds, <String>['term_1']);
    final term = sessions.terminals['term_1']!;
    expect(term.released, isTrue);
    expect(term.exitCode, 0);
    expect(term.output, contains('12 passed'));

    final ghost = s.toolCalls['call_ghost_1']!;
    expect(ghost.createdFromUpdate, isTrue);
    expect(ghost.kind, ToolKind.other);
    expect(ghost.rawKind, 'sculpt');
    expect(ghost.skippedContent, 1);
    expect(ghost.content, hasLength(2));

    final plan = s.plans['plan_validate']!;
    expect(plan.removed, isTrue);
    expect(s.compactions['cmp_1']!.status, 'completed');
    expect(s.compactions['cmp_1']!.summaryText, contains('退出码 0'));

    final last = s.entries.whereType<MessageEntry>().last;
    expect(last.blocks.map((b) => b.type), <ContentBlockType>[
      ContentBlockType.text,
      ContentBlockType.image,
      ContentBlockType.resourceLink,
      ContentBlockType.resource,
      ContentBlockType.audio,
    ]);
    expect(sessions.agents['fixture-agent']!.agentName, 'dsh-acp-interactive');
    expect(sessions.agents['fixture-agent']!.stderrLines, <String>['[dsh] turn finished in 6.2s']);
    expect(s.cwd, 'D:/variFlight_work/AcpAgentClient');
  });

  test('10-cancel：cancel 后工具卡本地 cancelled、挂起权限 cancelled、stopReason cancelled', () {
    final s = replayWhole(loadFixtures(where: (n) => n.startsWith('01') || n.startsWith('10'))).maybe(sid)!;
    final turn = s.entries.whereType<TurnEntry>().single;
    expect(turn.stopReason, 'cancelled');
    expect(s.toolCalls['call_exec_c1']!.displayStatus, ToolDisplayStatus.cancelled);
    expect((s.pending.byRequestId('fixture-agent', '21')! as PermissionEntry).status, PendingStatus.cancelled);
  });

  test('14-subagent：只按 _meta 键分组', () {
    final s = replayWhole(loadFixtures(where: (n) => n.startsWith('01') || n.startsWith('14'))).maybe(sid)!;
    final sub2 = s.toolCalls['call_sub_2']!;
    expect(sub2.isSubagent, isTrue);
    expect(sub2.children.map((e) => e.runtimeType.toString()), <String>['ToolCallEntry', 'MessageEntry']);
    expect(s.toolCalls['call_sub_1']!.isSubagent, isTrue);
    expect(s.toolCalls['call_dsh_1']!.isSubagent, isTrue);
    expect(s.toolCalls['call_sub_2_read']!.parentToolCallId, 'call_sub_2');
    // 顶层不含嵌套条目。
    expect(s.entries.whereType<ToolCallEntry>().map((e) => e.toolCallId), <String>['call_sub_1', 'call_sub_2', 'call_dsh_1']);
  });

  test('15 / 16：用户回应记录在队列里', () {
    final s = replayWhole(loadFixtures(where: (n) => n.startsWith('01') || n.startsWith('15') || n.startsWith('16'))).maybe(sid)!;
    final perm = s.pending.byRequestId('fixture-agent', '27')! as PermissionEntry;
    expect(perm.status, PendingStatus.answered);
    expect(perm.chosenOptionId, 'allow-once');
    expect(perm.options.map((o) => o.kind), <String>['allow_always', 'allow_always', 'allow_once', 'reject_once', 'reject_always']);
    final form = s.pending.byRequestId('fixture-agent', '29')! as ElicitationEntry;
    expect(form.isForm, isTrue);
    expect(form.action, 'accept');
    expect(form.values!['concurrency'], 4);
    final url = s.pending.byRequestId('fixture-agent', '30')! as ElicitationEntry;
    expect(url.isUrl, isTrue);
    expect(url.wire.elicitationId, 'elic_login_1');
    expect(s.pending.forSession(sid), isEmpty);
  });

  test('18-stop-reasons：五种 stopReason 各一轮', () {
    final s = replayWhole(loadFixtures(where: (n) => n.startsWith('01') || n.startsWith('08') || n.startsWith('18'))).maybe(sid)!;
    final reasons = s.entries.whereType<TurnEntry>().map((t) => t.stopReason).toList();
    expect(reasons, <String?>['max_tokens', 'max_turn_requests', 'refusal', 'cancelled']);
    expect(s.toolCalls['call_exec_s4']!.displayStatus, ToolDisplayStatus.cancelled);
  });

  test('21-terminal-running：kill 后信号退出、输出留存', () {
    final sessions = replayWhole(loadFixtures(where: (n) => n.startsWith('01') || n.startsWith('21')));
    final term = sessions.terminals['term_run']!;
    expect(term.killed, isTrue);
    expect(term.signal, 'SIGKILL');
    expect(term.output.split('\n').where((l) => l.isNotEmpty), hasLength(3));
    expect(sessions.maybe(sid)!.toolCalls['call_exec_r1']!.status, ToolStatus.failed);
  });

  test('23-messages-no-id：无 messageId 按角色连续合并', () {
    final s = replayWhole(loadFixtures(where: (n) => n.startsWith('01') || n.startsWith('23'))).maybe(sid)!;
    final kinds = s.entries.skip(1).map((e) => switch (e) {
          final MessageEntry m => '${m.role.name}:${m.blocks.length}',
          final ThoughtEntry t => 'thought:${t.blocks.length}',
          _ => e.runtimeType.toString(),
        });
    expect(kinds, <String>['user:1', 'agent:3', 'thought:2', 'agent:1']);
  });
}
