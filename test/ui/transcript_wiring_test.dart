// R2 审查第 2 轮整改的接线单测：TranscriptList 把 URL elicitation 的 Open / Cancel、用户气泡所属的轮接到回调。
// 不加载字体（只验回调与状态，不出图）；卡里有 Spinner 动画，只 pump 不 pumpAndSettle。

import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/projection/session_store.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/ui/transcript/transcript_list.dart';
import 'package:acp_agent_client/ui/transcript/user_message.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const String sid = 'sess_w';

SessionStore newStore() {
  var t = DateTime.utc(2026, 9, 15, 12);
  return SessionStore(sessionId: sid, clock: () => t = t.add(const Duration(seconds: 1)));
}

JsonMap userChunk(String text) => <String, dynamic>{
      'sessionUpdate': 'user_message_chunk',
      'content': <String, dynamic>{'type': 'text', 'text': text},
    };

const JsonMap urlElicitation = <String, dynamic>{
  'agentId': 'a',
  'requestId': 'u1',
  'method': 'elicitation/create',
  'params': <String, dynamic>{'mode': 'url', 'message': 'login', 'sessionId': sid, 'elicitationId': 'e1', 'url': 'https://x'},
};

Widget host(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(800, 600)),
        child: Overlay(initialEntries: <OverlayEntry>[OverlayEntry(builder: (_) => child)]),
      ),
    );

void main() {
  test('turnOf：用户消息归它前面最近的检查点；嵌套或无轮的条目为 null', () {
    final s = newStore();
    final t1 = s.startTurn(const <ContentBlockWire>[]);
    s.applyUpdateJson(userChunk('a'));
    s.endTurn(stopReason: 'end_turn');
    final t2 = s.startTurn(const <ContentBlockWire>[]);
    s.applyUpdateJson(userChunk('b'));
    final msgs = s.entries.whereType<MessageEntry>().toList();
    expect(turnOf(s.entries, msgs[0]), same(t1));
    expect(turnOf(s.entries, msgs[1]), same(t2));
    final other = newStore();
    other.applyUpdateJson(userChunk('c'));
    expect(turnOf(other.entries, other.entries.single), isNull);
  });

  testWidgets('URL elicitation：Open 打开链接、记已打开并回 accept；Cancel 在已 accept 后只本地标 cancelled', (tester) async {
    final s = newStore();
    s.applyClientRequest(const ClientRequestEnvelope(urlElicitation));
    final answers = <String>[];
    final links = <String>[];
    await tester.pumpWidget(host(TranscriptList(
      s,
      onLink: links.add,
      onAnswerElicitation: (id, action, _) {
        answers.add('$id:$action');
        s.answerElicitation(id, action);
      },
    )));
    await tester.tap(find.text('Open in browser'));
    await tester.pump();
    expect(links, <String>['https://x']);
    expect(answers, <String>['u1:accept']);
    final el = s.pending.byRequestId('u1')! as ElicitationEntry;
    expect(el.opened, isTrue);
    expect(el.status, PendingStatus.answered);
    expect(find.text('Waiting for completion...'), findsOneWidget);

    // 再点 Open 只是再打开，不再回应。
    await tester.tap(find.text('Open in browser'));
    await tester.pump();
    expect(links, hasLength(2));
    expect(answers, hasLength(1));

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(answers, hasLength(1)); // 没有第二个响应
    expect(el.status, PendingStatus.cancelled);
    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('用户气泡的 Restore / Regenerate 带上所属的轮', (tester) async {
    final s = newStore();
    final t1 = s.startTurn(const <ContentBlockWire>[]);
    s.applyUpdateJson(userChunk('hello'));
    TurnEntry? restored;
    (TurnEntry, String)? regenerated;
    await tester.pumpWidget(host(TranscriptList(
      s,
      onRestore: (turn) => restored = turn,
      onRegenerate: (turn, text) => regenerated = (turn, text),
    )));
    // 悬浮条 / 编辑态的控件要鼠标悬停才出现，这里直接取气泡拿到的回调（它们经 turnOf 绑到 t1）。
    final bubble = tester.widget<UserMessage>(find.byType(UserMessage));
    bubble.onRestore!();
    bubble.onRegenerate!('again');
    expect(restored, same(t1));
    expect(regenerated, (t1, 'again'));
  });
}
