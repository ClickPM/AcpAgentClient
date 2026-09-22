// 画板 28 · URL 型 elicitation 卡的收尾态：agent 撤回 / 进程退出（withdrawn）与本地 cancelled 同一收尾——
// 「Open in browser」不再可点、Cancel 不出、状态行写明。审查 P2（2026-09-22）：此前这张卡只认 completed / cancelled，
// agent 退出把它标成 withdrawn 之后按钮仍可点，点下去还会真开一个浏览器，而回应早就发不出去了。

import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/projection/session_store.dart';
import 'package:acp_agent_client/ui/transcript/card_chrome.dart';
import 'package:acp_agent_client/ui/transcript/elicitation_url_card.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../gallery_harness.dart';

void main() {
  ElicitationEntry urlRequest(Sessions sessions, {required String requestId}) {
    sessions.applyClientRequestEnvelope(<String, dynamic>{
      'agentId': 'a',
      'requestId': requestId,
      'method': 'elicitation/create',
      'params': <String, dynamic>{'sessionId': 'sess_1', 'mode': 'url', 'elicitationId': 'el_1', 'url': 'https://example.invalid'},
    });
    return sessions.pending.byRequestId(requestId)! as ElicitationEntry;
  }

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.runAsync(() async {
      await loadGalleryFonts();
      await precacheIcons();
    });
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(800, 600)),
          // 每次 pump 换一个 key：`initialEntries` 只在 Overlay 首次建树时生效，不换 key 第二次 pump 不会重建卡片。
          child: Overlay(
            key: UniqueKey(),
            initialEntries: <OverlayEntry>[
              OverlayEntry(builder: (_) => Center(child: SizedBox(width: 600, child: child))),
            ],
          ),
        ),
      ),
    );
  }

  AcpButton openButton(WidgetTester tester) =>
      tester.widget<AcpButton>(find.byWidgetPredicate((w) => w is AcpButton && w.label == 'Open in browser'));

  testWidgets('agent 退出（withdrawn）：Open 不可点、不出 Cancel、状态行写明 agent 已不再等待', (tester) async {
    final sessions = Sessions(clock: () => DateTime.utc(2026, 9, 22));
    sessions.session('sess_1', agentId: 'a');
    final ElicitationEntry e = urlRequest(sessions, requestId: 'r1');
    await pump(tester, ElicitationUrlCard(e, agentName: 'agent'));
    expect(openButton(tester).enabled, isTrue, reason: '挂起时照常可点');
    expect(find.text('Waiting for input'), findsOneWidget);

    sessions.applyAgentState(<String, dynamic>{'agentId': 'a', 'state': 'exited', 'code': 1});
    expect(e.status, PendingStatus.withdrawn);
    await pump(tester, ElicitationUrlCard(e, agentName: 'agent'));
    expect(openButton(tester).enabled, isFalse, reason: '进程没了，点下去只会白开一个浏览器，回应发不出去');
    expect(find.text('agent 已不再等待'), findsOneWidget);
    expect(find.widgetWithText(AcpButton, 'Cancel'), findsNothing);
    expect(find.text('Waiting for input'), findsNothing);
  });

  testWidgets('已打开浏览器后 agent 才退出：spinner 收掉，Cancel 也不再给', (tester) async {
    final sessions = Sessions(clock: () => DateTime.utc(2026, 9, 22));
    sessions.session('sess_1', agentId: 'a');
    final ElicitationEntry e = urlRequest(sessions, requestId: 'r1');
    sessions.pending.markOpened('r1');
    await pump(tester, ElicitationUrlCard(e, agentName: 'agent'));
    expect(find.text('Waiting for completion...'), findsOneWidget);
    expect(find.widgetWithText(AcpButton, 'Cancel'), findsOneWidget);

    sessions.applyAgentState(<String, dynamic>{'agentId': 'a', 'state': 'exited', 'code': 1});
    await pump(tester, ElicitationUrlCard(e, agentName: 'agent'));
    expect(find.text('Waiting for completion...'), findsNothing, reason: '不会再有 elicitation/complete 了');
    expect(find.text('agent 已不再等待'), findsOneWidget);
    expect(find.widgetWithText(AcpButton, 'Cancel'), findsNothing, reason: 'cancelRequest 对 withdrawn 是空操作，按钮留着只会点不动');
    expect(openButton(tester).enabled, isFalse);
  });
}
