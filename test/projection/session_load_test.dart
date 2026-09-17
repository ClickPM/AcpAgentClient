// R6 验收 3 / modes 回退 / 重放隔离的投影层单测：
// - `session/load` 的整段重放（260 条更新，15 个变体都有）无论「实时逐条到达」「整段一次 batch」还是
//   「按 batcher 的 hold / release 分批」，投影层结果都一样（R2 的分批 vs 整批等价扩到长历史）；
// - 重放前 `resetForReplay()`：同一份历史连着载两次不叠加，且队列 / 工具表 / 终端缓冲都从头开始；
// - modes 回退：configOptions 里没有 `category == mode` 的条目时用 `modes` 合成一条 select，两者都有时不合成；
// - 28-session-load.jsonl：list 两页 / load 重放 / resume 不重放 / close / delete 的线上形状。

import 'dart:io';

import 'package:acp_agent_client/projection/batcher.dart';
import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/projection/fixture_line.dart';
import 'package:acp_agent_client/projection/fixture_replay.dart';
import 'package:acp_agent_client/projection/session_store.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeClock {
  DateTime _t = DateTime.utc(2026, 9, 16, 9);

  DateTime call() {
    _t = _t.add(const Duration(milliseconds: 100));
    return _t;
  }
}

const String loadedSid = 'sess_loaded_1';

/// 一段确定性的长历史：15 个变体轮着来，工具卡 / 计划 / 压缩各自有 id 可合并，总数 > 200。
List<JsonMap> longHistory({int turns = 26}) {
  final out = <JsonMap>[];
  for (var t = 0; t < turns; t++) {
    out
      ..add(<String, dynamic>{
        'sessionUpdate': 'user_message_chunk',
        'messageId': 'u_$t',
        'content': <String, dynamic>{'type': 'text', 'text': '第 $t 步：继续。'},
      })
      ..add(<String, dynamic>{
        'sessionUpdate': 'agent_thought_chunk',
        'messageId': 'th_$t',
        'content': <String, dynamic>{'type': 'text', 'text': '想一下 $t。'},
      })
      ..add(<String, dynamic>{
        'sessionUpdate': 'agent_message_chunk',
        'messageId': 'a_$t',
        'content': <String, dynamic>{'type': 'text', 'text': '第 $t 步的回答。'},
      })
      ..add(<String, dynamic>{
        'sessionUpdate': 'tool_call',
        'toolCallId': 'call_$t',
        'title': 'Read file docs/$t.md',
        'kind': 'read',
        'status': 'in_progress',
        'locations': <JsonMap>[
          <String, dynamic>{'path': 'D:/repo/docs/$t.md', 'line': t + 1},
        ],
      })
      ..add(<String, dynamic>{
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'call_$t',
        'status': 'completed',
        'content': <JsonMap>[
          <String, dynamic>{
            'type': 'content',
            'content': <String, dynamic>{'type': 'text', 'text': '$t 行'},
          },
        ],
      })
      ..add(<String, dynamic>{
        'sessionUpdate': 'plan',
        'entries': <JsonMap>[
          <String, dynamic>{'content': '步骤 $t', 'priority': 'high', 'status': 'in_progress'},
        ],
      })
      ..add(<String, dynamic>{
        'sessionUpdate': 'plan_update',
        'plan': <String, dynamic>{
          'planId': 'p_$t',
          'type': 'items',
          'entries': <JsonMap>[
            <String, dynamic>{'content': '子步骤 $t', 'priority': 'low', 'status': 'completed'},
          ],
        },
      })
      ..add(<String, dynamic>{'sessionUpdate': 'plan_removed', 'planId': 'p_$t'})
      ..add(<String, dynamic>{
        'sessionUpdate': 'compaction_update',
        'compactionId': 'cmp_$t',
        'status': 'completed',
      })
      ..add(<String, dynamic>{
        'sessionUpdate': 'compaction_summary_chunk',
        'compactionId': 'cmp_$t',
        'content': <String, dynamic>{'type': 'text', 'text': '摘要 $t'},
      })
      ..add(<String, dynamic>{'sessionUpdate': 'usage_update', 'used': 100 * (t + 1), 'size': 128000});
  }
  return out
    ..add(<String, dynamic>{
      'sessionUpdate': 'available_commands_update',
      'availableCommands': <JsonMap>[
        <String, dynamic>{'name': 'review', 'description': '审一遍'},
      ],
    })
    ..add(<String, dynamic>{'sessionUpdate': 'current_mode_update', 'currentModeId': 'code'})
    ..add(<String, dynamic>{
      'sessionUpdate': 'config_option_update',
      'configOptions': <JsonMap>[
        <String, dynamic>{
          'id': 'mode',
          'name': 'Mode',
          'category': 'mode',
          'type': 'select',
          'currentValue': 'code',
          'options': <JsonMap>[
            <String, dynamic>{'value': 'ask', 'name': 'Ask'},
            <String, dynamic>{'value': 'code', 'name': 'Code'},
          ],
        },
      ],
    })
    ..add(<String, dynamic>{
      'sessionUpdate': 'session_info_update',
      'title': '载回来的会话',
      'updatedAt': '2026-09-16T01:02:03.000Z',
    });
}

JsonMap envelope(JsonMap update) =>
    <String, dynamic>{'agentId': 'fixture-agent', 'sessionId': loadedSid, 'update': update};

/// 实时到达：每条 update 直接进投影层（不经 batcher）。
Sessions applyLive(List<JsonMap> history) {
  final sessions = Sessions(clock: FakeClock().call);
  sessions.session(loadedSid, agentId: 'fixture-agent').cwd = 'D:/repo';
  for (final u in history) {
    sessions.applySessionUpdateEnvelope(envelope(u));
  }
  return sessions;
}

/// `session/load`：整段重放期间 batcher 挂起（hold），命令返回后一次性 release。
/// [notifications] 收到重放期间的通知次数。
Sessions applyHeldReplay(List<JsonMap> history, {required List<int> notifications, int schedulerTicks = 3}) {
  final sessions = Sessions(clock: FakeClock().call);
  final store = sessions.session(loadedSid, agentId: 'fixture-agent')..cwd = 'D:/repo';
  final flushes = <void Function()>[];
  final batcher = UpdateBatcher(sessions, scheduler: flushes.add);
  var n = 0;
  store.addListener(() => n++);
  batcher.hold();
  batcher.enqueue(store.resetForReplay);
  for (var i = 0; i < history.length; i++) {
    batcher.enqueue(() => sessions.applySessionUpdateEnvelope(envelope(history[i])));
    // 重放期间调度器照常被触发（真窗口里是帧回调）：挂起时一条都不能落到 UI。
    if (i % schedulerTicks == 0) {
      for (final f in flushes) {
        f();
      }
      flushes.clear();
    }
  }
  notifications.add(n);
  batcher.release();
  notifications.add(n);
  return sessions;
}

/// 分批到达（每 [batchSize] 条刷一次），模拟不挂起时的按帧合并。
Sessions applyBatched(List<JsonMap> history, int batchSize) {
  final sessions = Sessions(clock: FakeClock().call);
  sessions.session(loadedSid, agentId: 'fixture-agent').cwd = 'D:/repo';
  final flushes = <void Function()>[];
  final batcher = UpdateBatcher(sessions, scheduler: flushes.add);
  for (var i = 0; i < history.length; i++) {
    batcher.enqueue(() => sessions.applySessionUpdateEnvelope(envelope(history[i])));
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

/// 本地时间戳每次回放都往前走（注入的假时钟是单调的），比对两次回放要把它们摘掉
/// （`updatedAt` 在条目里是本地的、在会话顶层是协议给的，后者单独断言）。
const Set<String> _localTimeKeys = <String>{'at', 'endedAt', 'updatedAt', 'startedAt', 'finishedAt', 'answeredAt'};

Object? _stripTimes(Object? v) => switch (v) {
      final Map<String, dynamic> m => <String, dynamic>{
          for (final e in m.entries)
            if (!_localTimeKeys.contains(e.key)) e.key: _stripTimes(e.value),
        },
      final List<Object?> l => <Object?>[for (final e in l) _stripTimes(e)],
      _ => v,
    };

void main() {
  final history = longHistory();

  test('长历史确实超过 200 条更新，且 15 个变体全部覆盖', () {
    expect(history.length, greaterThan(200));
    final variants = history.map((u) => u['sessionUpdate']).toSet();
    expect(variants, hasLength(15));
  });

  test('session/load 的整段重放：挂起重放、实时到达、分批到达三者结果一致（验收 3）', () {
    final live = applyLive(history).debugSnapshot();
    final counts = <int>[];
    final held = applyHeldReplay(history, notifications: counts).debugSnapshot();
    expect(held, equals(live));
    for (final batchSize in <int>[1, 7, 64]) {
      expect(applyBatched(history, batchSize).debugSnapshot(), equals(live), reason: '每 $batchSize 条一批');
    }
  });

  test('重放期间一次都不刷新 UI，release 之后刷一次（ROUNDS § 3 R6 交付物）', () {
    final counts = <int>[];
    applyHeldReplay(history, notifications: counts);
    expect(counts.first, 0, reason: 'hold 期间不得有任何通知，${history.length} 条更新也一样');
    expect(counts.last, 1, reason: 'release 之后整段只刷一次');
  });

  test('resetForReplay：同一份历史载两次不叠加', () {
    final sessions = Sessions(clock: FakeClock().call);
    final store = sessions.session(loadedSid, agentId: 'fixture-agent')..cwd = 'D:/repo';
    for (final u in history) {
      sessions.applySessionUpdateEnvelope(envelope(u));
    }
    final once = _stripTimes(store.debugSnapshot());
    store.resetForReplay();
    expect(store.entries, isEmpty);
    expect(store.toolCalls.all, isEmpty);
    expect(store.usage, isNull);
    expect(store.turnCount, 0);
    for (final u in history) {
      sessions.applySessionUpdateEnvelope(envelope(u));
    }
    expect(_stripTimes(store.debugSnapshot()), equals(once));
    expect(store.updatedAt, '2026-09-16T01:02:03.000Z', reason: '会话顶层的 updatedAt 是协议给的，重放后要一致');
  });

  test('resetForReplay 把这个会话的挂起队列清掉，别的会话不动', () {
    final sessions = Sessions(clock: FakeClock().call);
    final mine = sessions.session(loadedSid, agentId: 'a');
    sessions.session('sess_other', agentId: 'a');
    for (final (sid, requestId) in <(String, String)>[(loadedSid, 'r1'), ('sess_other', 'r2')]) {
      sessions.applyClientRequestEnvelope(<String, dynamic>{
        'agentId': 'a',
        'requestId': requestId,
        'method': 'session/request_permission',
        'params': <String, dynamic>{
          'sessionId': sid,
          'toolCall': <String, dynamic>{'toolCallId': 'c_$requestId'},
          'options': <JsonMap>[
            <String, dynamic>{'optionId': 'allow-once', 'name': 'Allow once', 'kind': 'allow_once'},
          ],
        },
      });
    }
    expect(sessions.pending.pending, hasLength(2));
    mine.resetForReplay();
    expect(sessions.pending.byRequestId('r1'), isNull);
    expect(sessions.pending.byRequestId('r2'), isNotNull);
    expect(sessions.pending.forSession('sess_other'), hasLength(1));
  });

  test('Sessions.forget：删掉的会话连同它的队列项一起没有', () {
    final sessions = Sessions(clock: FakeClock().call);
    sessions.session(loadedSid, agentId: 'a');
    sessions.applyClientRequestEnvelope(<String, dynamic>{
      'agentId': 'a',
      'requestId': 'r1',
      'method': 'session/request_permission',
      'params': <String, dynamic>{
        'sessionId': loadedSid,
        'toolCall': <String, dynamic>{'toolCallId': 'c1'},
        'options': <JsonMap>[
          <String, dynamic>{'optionId': 'allow-once', 'name': 'Allow once', 'kind': 'allow_once'},
        ],
      },
    });
    sessions.forget(loadedSid);
    expect(sessions.maybe(loadedSid), isNull);
    expect(sessions.pending.byRequestId('r1'), isNull);
    sessions.forget(loadedSid); // 幂等
  });

  group('modes 回退（R6）', () {
    SessionStore storeWith({JsonMap? modes, List<JsonMap>? configOptions}) {
      final s = SessionStore(sessionId: loadedSid, clock: FakeClock().call);
      s.applyNewSession(<String, dynamic>{
        'sessionId': loadedSid,
        if (modes != null) 'modes': modes,
        if (configOptions != null) 'configOptions': configOptions,
      });
      return s;
    }

    final modes = <String, dynamic>{
      'currentModeId': 'ask',
      'availableModes': <JsonMap>[
        <String, dynamic>{'id': 'ask', 'name': 'Ask', 'description': '只读'},
        <String, dynamic>{'id': 'code', 'name': 'Code'},
      ],
    };
    final modeConfig = <JsonMap>[
      <String, dynamic>{
        'id': 'mode',
        'name': 'Mode',
        'category': 'mode',
        'type': 'select',
        'currentValue': 'code',
        'options': <JsonMap>[
          <String, dynamic>{'value': 'code', 'name': 'Code'},
        ],
      },
    ];

    test('只有 modes：合成一条 select，值跟着 current_mode_update 走', () {
      final s = storeWith(modes: modes);
      final option = s.modeFallbackOption!;
      expect(option.id, SessionStore.modeFallbackId);
      expect(option.category, 'mode');
      expect(option.type, 'select');
      expect(option.currentValue, 'ask');
      expect(option.options.map((o) => o['value']), <String>['ask', 'code']);
      expect(option.options.first['description'], '只读');
      s.applyUpdateJson(<String, dynamic>{'sessionUpdate': 'current_mode_update', 'currentModeId': 'code'});
      expect(s.modeFallbackOption!.currentValue, 'code');
    });

    test('两者都有：只用 configOptions，不合成', () {
      expect(storeWith(modes: modes, configOptions: modeConfig).modeFallbackOption, isNull);
    });

    // pi-acp：同一批思考强度既在 modes 里、又在 category thought_level 的 configOption 里。
    // 再合成一条模式下拉，输入框右下就是两个一模一样的「Thinking: high」（所有者手测 2026-09-17）。
    final thinkingModes = <String, dynamic>{
      'currentModeId': 'high',
      'availableModes': <JsonMap>[
        <String, dynamic>{'id': 'low', 'name': 'Thinking: low'},
        <String, dynamic>{'id': 'high', 'name': 'Thinking: high'},
      ],
    };
    final thoughtConfig = <JsonMap>[
      <String, dynamic>{
        'id': 'thought_level',
        'name': 'Thinking',
        'category': 'thought_level',
        'type': 'select',
        'currentValue': 'high',
        'options': <JsonMap>[
          <String, dynamic>{'value': 'low', 'name': 'Thinking: low'},
          <String, dynamic>{'value': 'high', 'name': 'Thinking: high'},
        ],
      },
    ];

    test('同一批值换个 category 又发了一遍（pi-acp 的思考强度）：不合成', () {
      expect(storeWith(modes: thinkingModes, configOptions: thoughtConfig).modeFallbackOption, isNull);
    });

    test('值不一样（另有 thought_level，但 modes 是 Plan 模式）：照常合成', () {
      final s = storeWith(modes: modes, configOptions: thoughtConfig);
      expect(s.modeFallbackOption!.options.map((o) => o['value']), <String>['ask', 'code']);
    });

    test('都没有 / modes 为空：不合成', () {
      expect(storeWith().modeFallbackOption, isNull);
      expect(storeWith(modes: <String, dynamic>{'availableModes': <JsonMap>[]}).modeFallbackOption, isNull);
    });

    test('applyModeSelected：set_mode 成功后本地同步（响应是空的）', () {
      final s = storeWith(modes: modes);
      s.applyModeSelected('code');
      expect(s.currentModeId, 'code');
      expect(s.modeFallbackOption!.currentValue, 'code');
    });
  });

  test('28-session-load.jsonl：load 重放后转录与 modes 就位，delete 之后会话不在表里', () {
    final lines = FixtureLine.parseAll(File('test/fixtures/28-session-load.jsonl').readAsStringSync());
    final sessions = Sessions(clock: FakeClock().call);
    FixtureReplayer(sessions).feedAll(lines);
    final s = sessions.maybe(loadedSid)!;
    expect(s.title, '给 validate.ps1 加 schema 同步校验');
    expect(s.entries.whereType<MessageEntry>().map((e) => e.role), <MessageRole>[MessageRole.user, MessageRole.agent]);
    expect(s.toolCalls['call_load_read']!.status, ToolStatus.completed);
    expect(s.usage!.used, 2048);
    expect(s.currentModeId, 'code');
    // 这个 agent 只给 modes、不给 configOptions：模式下拉走回退。
    expect(s.configOptions, isEmpty);
    expect(s.modeFallbackOption!.options.map((o) => o['value']), <String>['ask', 'code']);
    // close 的那条还在（只是 agent 侧释放了），delete 的那条没了。
    expect(sessions.maybe('sess_loaded_2'), isNull);
  });
}
