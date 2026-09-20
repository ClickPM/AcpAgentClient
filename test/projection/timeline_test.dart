// 画板 43 · 会话时间线的数据派生单测：轮怎么切、A 行取哪一条、首行怎么取。
// 都走真的 `SessionStore`（而不是手搓 entries），这样「session/load 重放回来的历史里没有 TurnEntry」
// 这条最要紧的规则是真被覆盖到的。

import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/projection/session_store.dart';
import 'package:acp_agent_client/projection/timeline.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:flutter_test/flutter_test.dart';

SessionStore newStore() {
  var t = DateTime.utc(2026, 9, 20, 12);
  return SessionStore(
    sessionId: 'sess_timeline',
    clock: () {
      t = t.add(const Duration(milliseconds: 100));
      return t;
    },
  );
}

JsonMap chunk(String tag, String text, {String? messageId, JsonMap? meta}) => <String, dynamic>{
      'sessionUpdate': tag,
      'messageId': ?messageId,
      'content': <String, dynamic>{'type': 'text', 'text': text},
      '_meta': ?meta,
    };

JsonMap blockChunk(String tag, JsonMap content, {JsonMap? meta}) => <String, dynamic>{
      'sessionUpdate': tag,
      'content': content,
      '_meta': ?meta,
    };

void user(SessionStore s, String text) => s.applyUpdateJson(chunk('user_message_chunk', text));

void agent(SessionStore s, String text, {String? messageId}) =>
    s.applyUpdateJson(chunk('agent_message_chunk', text, messageId: messageId));

void toolCall(SessionStore s, String id) => s.applyUpdateJson(<String, dynamic>{
      'sessionUpdate': 'tool_call',
      'toolCallId': id,
      'title': 'Read file',
      'status': 'completed',
    });

void main() {
  group('轮的切分', () {
    test('按顶层用户消息切轮，编号从 1 起；A 行是该轮最后一条 agent 文本', () {
      final s = newStore();
      user(s, 'hi');
      agent(s, '你好！有什么可以帮你的？');
      user(s, '你是什么模型');
      agent(s, '当前会话跑的是 deepseek-v4-flash');

      final turns = buildTimeline(s.entries);
      expect(turns.map((t) => t.n), <int>[1, 2]);
      expect(turns[0].query, 'hi');
      expect(turns[0].answer, '你好！有什么可以帮你的？');
      expect(turns[1].query, '你是什么模型');
      expect(turns[1].answer, '当前会话跑的是 deepseek-v4-flash');
    });

    test('session/load 重放回来的历史没有 TurnEntry，照样切得出轮', () {
      final s = newStore();
      s.resetForReplay();
      user(s, '第一轮');
      agent(s, '答一');
      user(s, '第二轮');
      agent(s, '答二');

      expect(s.entries.whereType<TurnEntry>(), isEmpty, reason: '重放里本来就没有轮边界');
      expect(buildTimeline(s.entries).map((t) => t.query), <String>['第一轮', '第二轮']);
    });

    test('实时一轮：startTurn 的本地回显就是那一轮的编号行', () {
      final s = newStore();
      s.startTurn(<ContentBlockWire>[ContentBlockWire(<String, dynamic>{'type': 'text', 'text': '本地回显的这句'})]);
      agent(s, '收到');
      s.endTurn(stopReason: 'end_turn');

      final turns = buildTimeline(s.entries);
      expect(turns, hasLength(1));
      expect(turns.single.query, '本地回显的这句');
      expect(turns.single.answer, '收到');
    });

    test('被打断的轮只有编号行，没有 A 行', () {
      final s = newStore();
      user(s, 'hi');
      agent(s, '你好');
      user(s, '你能看到这张图吗');
      s.cancel();

      final turns = buildTimeline(s.entries);
      expect(turns, hasLength(2));
      expect(turns[1].answer, isNull);
      expect(turns[1].answerEntryId, isNull);
    });

    test('工具调用之间的中间文本不作数：A 行取的是最后那条', () {
      final s = newStore();
      user(s, '跑一下校验');
      agent(s, '先读一下文件');
      toolCall(s, 'tc-1');
      agent(s, '读完了，校验可以纯静态做');

      final turns = buildTimeline(s.entries);
      expect(turns.single.answer, '读完了，校验可以纯静态做');
    });

    test('子代理卡里嵌套的消息不入时间线', () {
      final s = newStore();
      user(s, '并行查三处');
      const meta = <String, dynamic>{
        'claudeCode': <String, dynamic>{'subagent': true},
      };
      s.applyUpdateJson(<String, dynamic>{
        'sessionUpdate': 'tool_call',
        'toolCallId': 'sub-1',
        'title': 'Task',
        'status': 'in_progress',
        '_meta': meta,
      });
      s.applyUpdateJson(chunk('agent_message_chunk', '子代理自己说的话', meta: <String, dynamic>{
        'claudeCode': <String, dynamic>{'parentToolUseId': 'sub-1'},
      }));
      agent(s, '三处都查完了');

      final turns = buildTimeline(s.entries);
      expect(turns.single.answer, '三处都查完了');
    });

    test('第一条用户消息之前的 agent 文本不自己开一轮', () {
      final s = newStore();
      agent(s, 'agent 先说了一句');
      expect(buildTimeline(s.entries), isEmpty);
    });
  });

  group('首行怎么取', () {
    test('用户行：提及写成 @name 纯文本', () {
      final s = newStore();
      s.applyUpdateJson(blockChunk('user_message_chunk', <String, dynamic>{'type': 'text', 'text': '看一下 '}));
      s.applyUpdateJson(blockChunk('user_message_chunk', <String, dynamic>{
        'type': 'resource_link',
        'uri': 'file:///d:/proj/lib/main.dart',
        'name': 'main.dart',
      }));
      expect(buildTimeline(s.entries).single.query, '看一下 @main.dart');
    });

    test('用户行：只有图片没有文字时写 image', () {
      final s = newStore();
      s.applyUpdateJson(blockChunk('user_message_chunk', <String, dynamic>{
        'type': 'image',
        'mimeType': 'image/png',
        'data': 'iVBORw0KGgo=',
      }));
      expect(buildTimeline(s.entries).single.query, 'image');
    });

    test('用户行：多行只取第一个非空行', () {
      final s = newStore();
      user(s, '\n\n第一行有内容\n第二行不要');
      expect(buildTimeline(s.entries).single.query, '第一行有内容');
    });

    test('A 行：去掉行首的 Markdown 标记', () {
      for (final (String raw, String want) in <(String, String)>[
        ('## 结论', '结论'),
        ('- 第一条', '第一条'),
        ('1. 第一条', '第一条'),
        ('> 引用的话', '引用的话'),
        ('- [ ] 待办一条', '待办一条'),
        ('> - 引用里套列表', '引用里套列表'),
      ]) {
        final s = newStore();
        user(s, 'q');
        agent(s, raw);
        expect(buildTimeline(s.entries).single.answer, want, reason: raw);
      }
    });

    test('A 行：代码围栏那一行跳过，取下一行', () {
      final s = newStore();
      user(s, 'q');
      agent(s, '```dart\nfinal x = 1;\n```');
      expect(buildTimeline(s.entries).single.answer, 'final x = 1;');
    });

    test('A 行：整条一个字都没有时当这一轮没有回答', () {
      final s = newStore();
      user(s, 'q');
      agent(s, '   \n\n');
      final turns = buildTimeline(s.entries);
      expect(turns.single.answer, isNull);
    });
  });

  test('entryId 指向真实条目：跳转按它定位', () {
    final s = newStore();
    user(s, 'hi');
    agent(s, '你好');

    final turn = buildTimeline(s.entries).single;
    final ids = s.entries.map((e) => e.id).toSet();
    expect(ids, contains(turn.entryId));
    expect(ids, contains(turn.answerEntryId));
  });
}
