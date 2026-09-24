// 画板 08 B · 回合折叠的分组规则单测。走真的 `SessionStore`（不手搓 entries），
// 这样「哪些块进折叠、最后一段连续 agent 文本怎么算、什么时候不自动折叠」是按真实投影验的。

import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/projection/session_store.dart';
import 'package:acp_agent_client/projection/turn_fold.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:flutter_test/flutter_test.dart';

SessionStore newStore() {
  var t = DateTime.utc(2026, 9, 22, 12);
  return SessionStore(
    sessionId: 'sess_fold',
    clock: () {
      t = t.add(const Duration(milliseconds: 100));
      return t;
    },
  );
}

void agent(SessionStore s, String text) => s.applyUpdateJson(<String, dynamic>{
      'sessionUpdate': 'agent_message_chunk',
      'content': <String, dynamic>{'type': 'text', 'text': text},
    });

void thought(SessionStore s, String text) => s.applyUpdateJson(<String, dynamic>{
      'sessionUpdate': 'agent_thought_chunk',
      'content': <String, dynamic>{'type': 'text', 'text': text},
    });

void toolCall(SessionStore s, String id, {String status = 'completed'}) => s.applyUpdateJson(<String, dynamic>{
      'sessionUpdate': 'tool_call',
      'toolCallId': id,
      'title': 'Read file',
      'status': status,
    });

void userMessage(SessionStore s, String text) => s.applyUpdateJson(<String, dynamic>{
      'sessionUpdate': 'user_message_chunk',
      'content': <String, dynamic>{'type': 'text', 'text': text},
    });

TurnEntry startTurn(SessionStore s, String prompt) =>
    s.startTurn(<ContentBlockWire>[ContentBlockWire(<String, dynamic>{'type': 'text', 'text': prompt})]);

TurnFold? foldOf(SessionStore s) => foldsOf(s.entries).values.singleOrNull;

void main() {
  group('折叠范围', () {
    test('思考 / 工具调用进折叠块，用户消息与最后一段 agent 文本不进', () {
      final s = newStore();
      startTurn(s, '开始做第二阶段');
      thought(s, '先复核最新提交');
      toolCall(s, 'tc-1');
      toolCall(s, 'tc-2');
      agent(s, '第二阶段已全部开发完毕。');
      s.endTurn(stopReason: 'end_turn');

      final fold = foldOf(s)!;
      expect(fold.messages, 3, reason: '思考 1 + 工具调用 2');
      expect(fold.toolCalls, 2);
      expect(fold.failures, 0);
      // 用户回显与最终文本都不在折叠块里。
      final folded = fold.folded;
      expect(folded.whereType<MessageEntry>(), isEmpty);
      expect(folded.whereType<ThoughtEntry>(), hasLength(1));
      expect(folded.whereType<ToolCallEntry>(), hasLength(2));
    });

    test('工具调用之间穿插的 agent 文本进折叠块，只有最后一段连续的不进', () {
      final s = newStore();
      startTurn(s, '走两步');
      agent(s, '先看看仓库。'); // 中间段：后面还有工具调用
      toolCall(s, 'tc-1');
      agent(s, '结论一。'); // 最后一段连续 agent 文本的第一句
      agent(s, '结论二。'); // 同一段（连续）
      s.endTurn(stopReason: 'end_turn');

      final fold = foldOf(s)!;
      final foldedText = fold.folded.whereType<MessageEntry>().map((m) => m.text).toList();
      expect(foldedText, <String>['先看看仓库。'], reason: '中间那段进折叠块');
      expect(fold.toolCalls, 1);
      expect(fold.messages, 2, reason: '中间文本 1 + 工具调用 1');
    });

    test('一条都没得折就没有摘要行（只有文本的回合）', () {
      final s = newStore();
      startTurn(s, '你好');
      agent(s, '你好！');
      s.endTurn(stopReason: 'end_turn');
      expect(foldsOf(s.entries), isEmpty);
    });

    test('压缩标记进折叠块（compaction_update 建出的 CompactionEntry，不是工具调用）', () {
      // 复审 P2（2026-09-22）：这条用例原先发的是 tool_call，`e is CompactionEntry` 那条分支从没跑过。
      final s = newStore();
      startTurn(s, '继续');
      s.applyUpdateJson(<String, dynamic>{'sessionUpdate': 'compaction_update', 'compactionId': 'cmp_1', 'status': 'in_progress'});
      s.applyUpdateJson(<String, dynamic>{'sessionUpdate': 'compaction_update', 'compactionId': 'cmp_1', 'status': 'completed'});
      agent(s, '好了。');
      s.endTurn(stopReason: 'end_turn');

      final fold = foldOf(s)!;
      expect(fold.folded.single, isA<CompactionEntry>());
      expect(fold.toolCalls, 0, reason: '压缩标记不是工具调用');
      expect(fold.messages, 1);
      expect(fold.autoCollapsible, isTrue);
    });

    test('Plan 条不进折叠块（画板 29 的常驻元素，不属于某一回合的过程）', () {
      final s = newStore();
      startTurn(s, '做计划');
      s.applyUpdateJson(<String, dynamic>{
        'sessionUpdate': 'plan',
        'entries': <Object?>[
          <String, dynamic>{'content': '第一步', 'priority': 'high', 'status': 'in_progress'},
        ],
      });
      toolCall(s, 'tc-1');
      agent(s, '好了。');
      s.endTurn(stopReason: 'end_turn');

      expect(s.entries.whereType<PlanCardEntry>(), hasLength(1), reason: '用例前提：plan 真的建出了 Plan 条');
      final fold = foldOf(s)!;
      expect(fold.folded.whereType<PlanCardEntry>(), isEmpty);
      expect(fold.messages, 1, reason: '只有那次工具调用进折叠块');
      expect(fold.toolCalls, 1);
    });
  });

  group('自动折叠的判定', () {
    test('stopReason = cancelled -> 不自动折叠', () {
      final s = newStore();
      startTurn(s, '跑一下');
      toolCall(s, 'tc-1');
      s.endTurn(stopReason: 'cancelled');
      expect(foldOf(s)!.autoCollapsible, isFalse);
    });

    test('本地失败（没有 stopReason，只有 error）-> 不自动折叠', () {
      final s = newStore();
      startTurn(s, '跑一下');
      toolCall(s, 'tc-1');
      s.endTurn(error: '连接断了');
      expect(foldOf(s)!.autoCollapsible, isFalse);
    });

    test('有失败的工具调用但正常收轮 -> 照常自动折叠，失败数留在摘要行上（所有者裁定 2026-09-22）', () {
      final s = newStore();
      startTurn(s, '跑一下');
      toolCall(s, 'tc-1');
      toolCall(s, 'tc-2', status: 'failed');
      agent(s, '出错了。');
      s.endTurn(stopReason: 'end_turn');

      final fold = foldOf(s)!;
      expect(fold.failures, 1);
      expect(fold.toolCalls, 2, reason: '失败的也计进「次工具调用」');
      expect(fold.autoCollapsible, isTrue, reason: '跑到了结论就收起来；失败只体现在摘要行的「N 项失败」上');
    });

    test('失败 + 取消同时在 -> 仍不自动折叠（取消那一条独立拦住）', () {
      final s = newStore();
      startTurn(s, '跑一下');
      toolCall(s, 'tc-1', status: 'failed');
      toolCall(s, 'tc-2', status: 'in_progress');
      s.cancel();
      s.endTurn(stopReason: 'end_turn');

      final fold = foldOf(s)!;
      expect(fold.failures, 1);
      expect(fold.cancelled, 1);
      expect(fold.autoCollapsible, isFalse);
    });

    test('max_tokens / refusal 照常自动折叠（坏消息在回合页脚，页脚不参与折叠）', () {
      for (final reason in <String>['max_tokens', 'refusal']) {
        final s = newStore();
        startTurn(s, '跑一下');
        toolCall(s, 'tc-1');
        s.endTurn(stopReason: reason);
        expect(foldOf(s)!.autoCollapsible, isTrue, reason: reason);
      }
    });

    test('运行中的回合不可自动折叠（流式期间过程必须可见）', () {
      final s = newStore();
      startTurn(s, '跑一下');
      toolCall(s, 'tc-1');
      expect(foldOf(s)!.autoCollapsible, isFalse);
    });
  });

  group('收轮之后才到的条目（iteration-15，所有者报障 2026-09-24）', () {
    // agent 在 `session/prompt` 回了 stopReason 之后接着推 update（Claude Code 的后台命令跑完把它唤醒）。
    // 改前：末尾换成新来的工具调用，原结论被当成过程折进去，新来的也全在已经收起的折叠块里。
    test('收轮后来的工具调用与文本都不进折叠块，原结论也不被折进去', () {
      final s = newStore();
      startTurn(s, '那条报价没有命中政策让利吗');
      toolCall(s, 'tc-1');
      agent(s, '目前查到的情况：结果回来后给你结论。');
      s.endTurn(stopReason: 'end_turn');
      toolCall(s, 'tc-late-1');
      agent(s, 'codescope 没返回内容，拆成两个小问题重问。');
      toolCall(s, 'tc-late-2', status: 'failed');
      thought(s, '回到数据层面');

      final fold = foldOf(s)!;
      expect(fold.folded.map((e) => e is ToolCallEntry ? e.toolCallId : e.runtimeType.toString()), <String>['tc-1']);
      expect(fold.messages, 1);
      expect(fold.toolCalls, 1, reason: '摘要行的计数只算收轮那一刻的过程');
      expect(fold.failures, 0, reason: '收轮后才失败的那一条不进摘要行');
      expect(fold.autoCollapsible, isTrue, reason: '收轮前那段照常自动折叠');
      final conclusion = s.entries.whereType<MessageEntry>().firstWhere((m) => m.text.startsWith('目前查到的情况'));
      expect(fold.contains(conclusion), isFalse);
    });

    test('收轮后先来的是思考块：原结论照样不折，思考块也不进折叠块', () {
      // 2026-09-24 实测的形状：唤醒之后先思考、再调工具。
      final s = newStore();
      startTurn(s, '跑一下');
      toolCall(s, 'tc-1');
      agent(s, '跑完了。');
      s.endTurn(stopReason: 'end_turn');
      thought(s, '回到数据层面');

      final fold = foldOf(s)!;
      expect(fold.folded.whereType<MessageEntry>(), isEmpty, reason: '原结论不被折进去');
      expect(fold.folded.whereType<ThoughtEntry>(), isEmpty, reason: '收轮后的思考块不进折叠块');
      expect(fold.messages, 1);
    });

    test('收轮那一刻还没开出来的结论（最后几个 chunk 晚一帧才落地）：前面的过程照常折，结论不折', () {
      // `session/prompt` 的返回是当场收轮，`session/update` 要等下一帧批量应用，所以结论那条可能收轮之后才建出来。
      final s = newStore();
      startTurn(s, '走两步');
      agent(s, '先看看仓库。');
      toolCall(s, 'tc-1');
      s.endTurn(stopReason: 'end_turn');
      agent(s, '这就是结论。');

      final fold = foldOf(s)!;
      expect(fold.folded.whereType<MessageEntry>().map((m) => m.text), <String>['先看看仓库。']);
      expect(fold.folded.whereType<ToolCallEntry>(), hasLength(1));
      final conclusion = s.entries.whereType<MessageEntry>().firstWhere((m) => m.text == '这就是结论。');
      expect(fold.contains(conclusion), isFalse);
    });

    test('还在跑的轮不按时间切：流式期间一切照旧', () {
      final s = newStore();
      startTurn(s, '跑一下');
      agent(s, '先看看。');
      toolCall(s, 'tc-1');
      final fold = foldOf(s)!;
      expect(fold.folded, hasLength(2), reason: '没有 endedAt，整段都算（运行中本来也不折）');
    });
  });

  group('多轮与 session/load', () {
    test('每轮各自一份，按 TurnEntry.id 索引', () {
      final s = newStore();
      startTurn(s, '第一轮');
      toolCall(s, 'a');
      agent(s, '答一');
      s.endTurn(stopReason: 'end_turn');
      startTurn(s, '第二轮');
      toolCall(s, 'b');
      toolCall(s, 'c');
      agent(s, '答二');
      s.endTurn(stopReason: 'end_turn');

      final folds = foldsOf(s.entries);
      expect(folds, hasLength(2));
      final counts = folds.values.map((f) => f.toolCalls).toList();
      expect(counts, <int>[1, 2]);
    });

    test('重放回来的历史没有轮边界，按顶层用户消息切轮，照样折（所有者裁定 2026-09-22）', () {
      final s = newStore();
      s.resetForReplay();
      userMessage(s, '历史一问');
      thought(s, '历史里的思考');
      toolCall(s, 'tc-old');
      agent(s, '历史一答');
      userMessage(s, '历史二问');
      toolCall(s, 'tc-old-2');
      toolCall(s, 'tc-old-3');
      agent(s, '历史二答');

      expect(s.entries.whereType<TurnEntry>(), isEmpty, reason: '用例前提：重放确实不带轮边界');
      final folds = foldsOf(s.entries);
      expect(folds, hasLength(2));
      expect(folds.values.map((f) => f.toolCalls), <int>[1, 2]);
      expect(folds.values.first.messages, 2, reason: '思考 1 + 工具调用 1；最后一段 agent 文本不进');
      for (final f in folds.values) {
        expect(f.turn, isNull, reason: '历史轮没有轮边界');
        expect(f.model, isNull, reason: '模型名取不到，摘要行退化成单行');
        expect(f.isRunning, isFalse);
        expect(f.autoCollapsible, isTrue);
        expect(f.id, startsWith('msg'), reason: '身份是那条用户消息');
      }
    });

    test('历史之后接着实时发一轮：历史按用户消息切，实时那轮按轮边界切', () {
      final s = newStore();
      s.resetForReplay();
      userMessage(s, '历史一问');
      toolCall(s, 'tc-old');
      agent(s, '历史一答');

      startTurn(s, '新一轮');
      toolCall(s, 'tc-new');
      agent(s, '新一答');
      s.endTurn(stopReason: 'end_turn');

      final folds = foldsOf(s.entries).values.toList();
      expect(folds, hasLength(2));
      expect(folds.first.turn, isNull, reason: '历史轮');
      expect(folds.last.turn, isNotNull, reason: '实时轮拿得到轮边界');
      expect(folds.last.owner, isA<TurnEntry>());
      expect(folds.last.toolCalls, 1, reason: '本地回显的用户气泡不会把这一轮再切一次');
    });
  });

  group('模型名快照', () {
    test('回合开始时取 category == model 的当前选项显示名；中途换模型不改', () {
      final s = newStore();
      s.applyUpdateJson(<String, dynamic>{
        'sessionUpdate': 'config_option_update',
        'configOptions': <Object>[
          <String, dynamic>{
            'id': 'model',
            'name': 'Model',
            'category': 'model',
            'type': 'select',
            'currentValue': 'gemini-3.8-flash-high',
            'options': <Object>[
              <String, dynamic>{'value': 'gemini-3.8-flash-high', 'name': 'Gemini 3.8 Flash High (CLIProxy)'},
              <String, dynamic>{'value': 'other', 'name': 'Other Model'},
            ],
          },
        ],
      });
      final turn = startTurn(s, '跑一下');
      expect(turn.model, 'Gemini 3.8 Flash High (CLIProxy)');

      // 回合中途换模型：这一行不跟着改（所有者裁定 2026-09-22）。
      s.applyUpdateJson(<String, dynamic>{
        'sessionUpdate': 'config_option_update',
        'configOptions': <Object>[
          <String, dynamic>{
            'id': 'model',
            'name': 'Model',
            'category': 'model',
            'type': 'select',
            'currentValue': 'other',
            'options': <Object>[
              <String, dynamic>{'value': 'gemini-3.8-flash-high', 'name': 'Gemini 3.8 Flash High (CLIProxy)'},
              <String, dynamic>{'value': 'other', 'name': 'Other Model'},
            ],
          },
        ],
      });
      expect(turn.model, 'Gemini 3.8 Flash High (CLIProxy)');
      expect(startTurn(s, '再跑一下').model, 'Other Model', reason: '下一轮才用新模型');
    });

    test('分组形状的 options 也认', () {
      final s = newStore();
      s.applyUpdateJson(<String, dynamic>{
        'sessionUpdate': 'config_option_update',
        'configOptions': <Object>[
          <String, dynamic>{
            'id': 'model',
            'category': 'model',
            'type': 'select',
            'currentValue': 'sonnet',
            'options': <Object>[
              <String, dynamic>{
                'group': 'anthropic',
                'name': 'Anthropic',
                'options': <Object>[
                  <String, dynamic>{'value': 'sonnet', 'name': 'Claude Sonnet 5'},
                ],
              },
            ],
          },
        ],
      });
      expect(startTurn(s, 'x').model, 'Claude Sonnet 5');
    });

    test('没有 model 那一档配置时是 null（摘要行退化成单行）', () {
      final s = newStore();
      expect(startTurn(s, 'x').model, isNull);
    });
  });
}
