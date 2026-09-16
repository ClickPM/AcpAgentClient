// Dart 侧的 fixtures 消费者（ROUNDS.md § 0 第 3 条）：薄封装能覆盖全部 15 变体、5 种内容块、3 种工具卡内容与两类请求，
// 未知变体落 unknown 而不是抛异常。

import 'dart:io';

import 'package:acp_agent_client/projection/fixture_line.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:flutter_test/flutter_test.dart';

List<FixtureLine> _loadAll() {
  final dir = Directory('test/fixtures');
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.jsonl')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) throw StateError('no fixtures under ${dir.path}');
  return <FixtureLine>[for (final f in files) ...FixtureLine.parseAll(f.readAsStringSync())];
}

void main() {
  late final List<FixtureLine> lines;
  late final List<FixtureLine> updates;

  setUpAll(() {
    lines = _loadAll();
    updates = lines.where((l) => l.isSessionUpdate).toList();
  });

  test('every fixture line parses and classifies', () {
    expect(lines.length, 219); // R0 61 行 + R2 新增 148 行（10–24）+ R3 新增 5 行（16 补两条通知与被撤回的请求、25 两条 config）+ R5 新增 5 行（26 requestScope 认证）
    expect(lines.where((l) => l.dir == FixtureDir.unknown), isEmpty);
    expect(lines.where((l) => l.dir == FixtureDir.local).map((l) => l.localKind).toSet(), {'terminal_output', 'terminal_exit'});
    expect(lines.where((l) => l.dir == FixtureDir.stderr).single.line, contains('turn finished'));
  });

  test('all 15 session/update variants appear; the two deliberate lines are unknown', () {
    final kinds = <SessionUpdateKind, int>{};
    for (final l in updates) {
      final k = l.sessionNotification!.update.kind;
      kinds[k] = (kinds[k] ?? 0) + 1;
      expect(l.sessionNotification!.sessionId, 'sess_9f3c21a7');
    }
    final unknownLines = updates.where((l) => l.sessionNotification!.update.kind == SessionUpdateKind.unknown).toList();
    expect(unknownLines.map((l) => l.tag), unorderedEquals(<String>['notice', 'artifact_update']));
    expect(unknownLines.every((l) => l.expectReject), isTrue);
    expect(updates.where((l) => l.expectReject).length, 2);
    for (final k in SessionUpdateKind.values) {
      if (k == SessionUpdateKind.unknown) continue;
      expect(kinds[k], isNotNull, reason: 'variant ${k.wire} never appears in fixtures');
    }
  });

  test('variant tags match the wire discriminator', () {
    for (final l in updates.where((l) => !l.expectReject)) {
      expect(l.sessionNotification!.update.kind.wire, l.tag, reason: 'line tagged ${l.tag}');
    }
  });

  test('content chunks expose messageId and five content block types', () {
    final chunks = updates.map((l) => l.sessionNotification!.update).where((u) => u.kind.isContentChunk).toList();
    expect(chunks.map((u) => u.messageId).toSet(), containsAll(<String>['msg_u1', 'th_1', 'msg_a1', 'msg_a2', 'msg_a3']));
    final types = chunks.map((u) => u.content!.type).toSet();
    expect(types, ContentBlockType.values.toSet()..remove(ContentBlockType.unknown));
    final image = chunks.map((u) => u.content!).firstWhere((c) => c.type == ContentBlockType.image);
    expect(image.mimeType, 'image/svg+xml');
    expect(image.data, isNotEmpty);
    final resource = chunks.map((u) => u.content!).firstWhere((c) => c.type == ContentBlockType.resource);
    expect(resource.resource!.isText, isTrue);
    expect(resource.resource!.uri, startsWith('file:///'));
  });

  test('tool calls: three content types, replace semantics fields, unknown kind and unknown content item', () {
    final tools = updates
        .map((l) => l.sessionNotification!.update)
        .where((u) => u.kind == SessionUpdateKind.toolCall || u.kind == SessionUpdateKind.toolCallUpdate)
        .map((u) => u.toolCall)
        .toList();
    final contentTypes = tools.expand((tc) => tc.content).map((c) => c.type).toSet();
    expect(contentTypes, containsAll(<ToolCallContentType>[ToolCallContentType.content, ToolCallContentType.diff, ToolCallContentType.terminal, ToolCallContentType.unknown]));
    final diff = tools.expand((tc) => tc.content).firstWhere((c) => c.type == ToolCallContentType.diff);
    expect(diff.path, endsWith('validate.ps1'));
    expect(diff.oldText, isNotNull);
    expect(diff.newText, isNotNull);
    final ghost = tools.firstWhere((tc) => tc.toolCallId == 'call_ghost_1');
    expect(ToolCallWire.knownKinds.contains(ghost.kind), isFalse);
    expect(ghost.content.where((c) => c.type == ToolCallContentType.unknown).length, 1);
    final readDone = tools.firstWhere((tc) => tc.toolCallId == 'call_read_1' && tc.hasLocations);
    expect(readDone.locations.single.line, 18);
  });

  test('plan, plan_update, plan_removed, commands, modes, config options, usage, compaction', () {
    final byKind = <SessionUpdateKind, List<SessionUpdateWire>>{};
    for (final l in updates) {
      final u = l.sessionNotification!.update;
      byKind.putIfAbsent(u.kind, () => <SessionUpdateWire>[]).add(u);
    }
    expect(byKind[SessionUpdateKind.plan]!.first.planEntries.length, 3);
    final pu = byKind[SessionUpdateKind.planUpdate]!.first.planUpdate!;
    expect(pu.type, 'items');
    expect(pu.planId, 'plan_validate');
    expect(pu.entries.first.status, 'completed');
    expect(byKind[SessionUpdateKind.planRemoved]!.first.planId, 'plan_validate');
    expect(byKind[SessionUpdateKind.availableCommandsUpdate]!.single.availableCommands.map((c) => c.name), ['review', 'compact', 'plan']);
    expect(byKind[SessionUpdateKind.availableCommandsUpdate]!.single.availableCommands.first.inputHint, '可选：范围');
    expect(byKind[SessionUpdateKind.currentModeUpdate]!.single.currentModeId, 'code');
    // 05-elicitation-config 的那条（文件序在 25-config-options 之前）。
    final cfg = byKind[SessionUpdateKind.configOptionUpdate]!.first.configOptions;
    expect(cfg.map((c) => c.category), ['mode', 'model', null, 'thought_level']);
    expect(cfg.firstWhere((c) => c.type == 'boolean').currentValue, true);
    // R3 的 25-config-options：未识别 category 原样透出，未识别 type 由投影层整条忽略（这里只看薄封装）。
    final cfg40 = byKind[SessionUpdateKind.configOptionUpdate]!.last.configOptions;
    expect(cfg40.map((c) => c.category), containsAll(<String>['model', 'thought_level', 'mode', 'sandbox', '_codex_reasoning']));
    expect(cfg40.where((c) => c.type == 'boolean').length, 3);
    expect(cfg40.where((c) => c.type != 'select' && c.type != 'boolean').single.type, 'slider');
    final info = byKind[SessionUpdateKind.sessionInfoUpdate]!.single;
    expect(info.hasTitle && info.hasUpdatedAt, isTrue);
    final usage = byKind[SessionUpdateKind.usageUpdate]!;
    expect(usage.length, greaterThanOrEqualTo(2));
    expect(usage.first.cost!.currency, 'USD');
    final compaction = byKind[SessionUpdateKind.compactionUpdate]!;
    expect(compaction.take(2).map((u) => u.compactionStatus), ['in_progress', 'completed']);
    expect(byKind[SessionUpdateKind.compactionSummaryChunk]!.where((u) => u.compactionId == 'cmp_1').every((u) => u.content!.text!.isNotEmpty), isTrue);
    // R2：plan_update 的 file / markdown 载荷（markdown 正文字段在 schema 里叫 content）
    final byType = <String, PlanUpdateWire>{for (final u in byKind[SessionUpdateKind.planUpdate]!) u.planUpdate!.type!: u.planUpdate!};
    expect(byType['file']!.uri, endsWith('plan.md'));
    expect(byType['markdown']!.markdown, contains('R0 收口顺序'));
  });

  test('permission and elicitation request shapes', () {
    final perm = PermissionRequestWire(lines.firstWhere((l) => l.method == 'session/request_permission').params!);
    expect(perm.sessionId, 'sess_9f3c21a7');
    expect(perm.toolCall.toolCallId, 'call_edit_1');
    expect(perm.toolCall.hasStatus, isFalse);
    expect(perm.options.map((o) => o.kind), ['allow_once', 'allow_always', 'reject_once']);

    final el = ElicitationRequestWire(lines.firstWhere((l) => l.method == 'elicitation/create').params!);
    expect(el.isForm, isTrue);
    expect(el.isRequestScope, isFalse);
    expect(el.toolCallId, 'call_edit_1');
    expect(el.requestedSchema!['required'], ['scope']);

    final urlScoped = const ElicitationRequestWire(<String, dynamic>{'mode': 'url', 'requestId': 'req_1', 'elicitationId': 'e1', 'url': 'https://example.invalid/login'});
    expect(urlScoped.isUrl, isTrue);
    expect(urlScoped.isRequestScope, isTrue);
  });

  test('event envelopes', () {
    // 信封 = SessionNotification 原样 + agentId（核心侧 agent.rs 往 params 里插 agentId，不另套一层）。
    final env = SessionUpdateEnvelope(<String, dynamic>{...updates.first.params!, 'agentId': 'dsh'});
    expect(env.agentId, 'dsh');
    expect(env.sessionId, 'sess_9f3c21a7');
    expect(env.notification.update.kind, SessionUpdateKind.availableCommandsUpdate);
    final req = const ClientRequestEnvelope(<String, dynamic>{'agentId': 'dsh', 'requestId': 6, 'method': 'session/request_permission', 'params': <String, dynamic>{'options': <dynamic>[]}});
    expect(req.isPermission, isTrue);
    expect(req.permission.options, isEmpty);
    final state = const AgentStateWire(<String, dynamic>{'agentId': null, 'state': 'core_ready', 'droppedUpdates': 0});
    expect(state.state, 'core_ready');
    expect(state.agentId, isNull);
  });
}
