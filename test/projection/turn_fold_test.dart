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

    test('压缩标记进折叠块', () {
      final s = newStore();
      startTurn(s, '继续');
      s.applyUpdateJson(<String, dynamic>{
        'sessionUpdate': 'tool_call',
        'toolCallId': 'tc-compact',
        'title': 'Compacting',
        'status': 'completed',
        '_meta': <String, dynamic>{'claudeCode': <String, dynamic>{'toolName': 'x'}},
      });
      agent(s, '好了。');
      s.endTurn(stopReason: 'end_turn');
      expect(foldOf(s)!.toolCalls, 1);
    });
  });

  group('不自动折叠的回合', () {
    test('有失败的工具调用 -> autoCollapsible 为假，且摘要行给出失败数', () {
      final s = newStore();
      startTurn(s, '跑一下');
      toolCall(s, 'tc-1');
      toolCall(s, 'tc-2', status: 'failed');
      agent(s, '出错了。');
      s.endTurn(stopReason: 'end_turn');

      final fold = foldOf(s)!;
      expect(fold.failures, 1);
      expect(fold.toolCalls, 2, reason: '失败的也计进「次工具调用」');
      expect(fold.autoCollapsible, isFalse);
    });

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

    test('重放回来的历史没有轮边界，也就没有折叠块（已知限制）', () {
      final s = newStore();
      s.resetForReplay();
      s.applyUpdateJson(<String, dynamic>{
        'sessionUpdate': 'user_message_chunk',
        'content': <String, dynamic>{'type': 'text', 'text': '历史一问'},
      });
      thought(s, '历史里的思考');
      toolCall(s, 'tc-old');
      agent(s, '历史一答');
      expect(s.entries.whereType<TurnEntry>(), isEmpty);
      expect(foldsOf(s.entries), isEmpty);
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
