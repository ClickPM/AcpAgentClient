// 画板 43 · 会话时间线弹层的 widget 单测：行怎么排、封顶滚动、打开落点、键盘与点击、空态。

import 'package:acp_agent_client/projection/timeline.dart';
import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/popovers/session_timeline.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

List<TimelineTurn> sample() => const <TimelineTurn>[
      TimelineTurn(n: 1, entryId: 'u1', query: 'hi', answer: '你好！有什么可以帮你的？', answerEntryId: 'a1'),
      TimelineTurn(n: 2, entryId: 'u2', query: '你是什么模型', answer: '当前会话跑的是 deepseek-v4-flash', answerEntryId: 'a2'),
      // 第 3 轮被打断：只有编号行。
      TimelineTurn(n: 3, entryId: 'u3', query: '你能看到这张图吗'),
      TimelineTurn(n: 4, entryId: 'u4', query: '你能看到这张图吗', answer: '能看到。这是桌面版的截图', answerEntryId: 'a4'),
    ];

List<TimelineTurn> long(int n) => <TimelineTurn>[
      for (var i = 1; i <= n; i++) TimelineTurn(n: i, entryId: 'u$i', query: '第 $i 轮', answer: '答 $i', answerEntryId: 'a$i'),
    ];

/// Popover 自己的 padding 4 与 1px 边框：宽高上限都是**内容**的，这一圈在它之外
/// （与画板 40 / 41 / 42 的封顶同一个口径，见 menu_overflow_test）。
const double _chrome = 2 * t.Spacing.s4 + 2 * t.Borders.width;

void main() {
  Future<void> pumpTimeline(
    WidgetTester tester, {
    required List<TimelineTurn> turns,
    ValueChanged<TimelineRow>? onJump,
    double? maxHeight,
    bool scrollToBottomOnOpen = true,
  }) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(1440, 900)),
          child: Align(
            alignment: Alignment.topLeft,
            child: SessionTimelinePopover(
              turns: turns,
              onJump: onJump,
              maxHeight: maxHeight,
              scrollToBottomOnOpen: scrollToBottomOnOpen,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  ScrollableState scrollerOf(WidgetTester tester) => tester.state<ScrollableState>(
        find.descendant(of: find.byType(SingleChildScrollView), matching: find.byType(Scrollable)),
      );

  testWidgets('每轮一条编号行；有回答才跟一条 A 行，被打断的轮没有', (tester) async {
    await pumpTimeline(tester, turns: sample());

    expect(find.text('01'), findsOneWidget);
    expect(find.text('02'), findsOneWidget);
    expect(find.text('03'), findsOneWidget);
    expect(find.text('04'), findsOneWidget);
    expect(find.text('A'), findsNWidgets(3), reason: '4 轮里第 3 轮被打断，只有 3 条 A 行');
    expect(find.text('你好！有什么可以帮你的？'), findsOneWidget);
  });

  testWidgets('标题行带轮数，且钉在滚动区之外', (tester) async {
    await pumpTimeline(tester, turns: sample());

    expect(find.text('Session timeline · 4 turns'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(SingleChildScrollView), matching: find.text('Session timeline · 4 turns')),
      findsNothing,
      reason: '标题行滚起来要一直在',
    );
  });

  testWidgets('弹层宽 420（与画板 42 的 @ / 命令菜单同一档）', (tester) async {
    await pumpTimeline(tester, turns: sample());
    // 420 是内容宽；Popover 自己的 padding 4 与 1px 边框在它之外（同 MenuPopover 的封顶口径）。
    expect(tester.getSize(find.byType(SessionTimelinePopover)).width, t.Timeline.width + _chrome);
  });

  testWidgets('轮多到装不下时按窗口高的 75% 封顶，并在内部滚动', (tester) async {
    await pumpTimeline(tester, turns: long(30));

    const double cap = 900 * t.Timeline.maxHeightFactor;
    expect(tester.getSize(find.byType(SessionTimelinePopover)).height, lessThanOrEqualTo(cap + _chrome));
    expect(scrollerOf(tester).position.maxScrollExtent, greaterThan(0));
  });

  testWidgets('装得下时按内容收窄，不留空白', (tester) async {
    await pumpTimeline(tester, turns: sample());

    const double cap = 900 * t.Timeline.maxHeightFactor;
    expect(tester.getSize(find.byType(SessionTimelinePopover)).height, lessThan(cap));
    expect(scrollerOf(tester).position.maxScrollExtent, 0);
  });

  testWidgets('打开时滚到底部，最新一轮在视口内', (tester) async {
    await pumpTimeline(tester, turns: long(30));

    final scroller = scrollerOf(tester);
    expect(scroller.position.pixels, scroller.position.maxScrollExtent);
    expect(find.text('30'), findsOneWidget);
  });

  testWidgets('空态：只剩标题行与一行占位文案，没有导轨', (tester) async {
    await pumpTimeline(tester, turns: const <TimelineTurn>[]);

    expect(find.text('Session timeline · 0 turns'), findsOneWidget);
    expect(find.text('No messages in this session yet'), findsOneWidget);
    expect(find.byType(Stack), findsNothing, reason: '空态不画导轨那一层');
  });

  testWidgets('点一行回调该行的条目 id；A 行回调的是回答那一条', (tester) async {
    final jumped = <TimelineRow>[];
    await pumpTimeline(tester, turns: sample(), onJump: jumped.add);

    await tester.tap(find.text('你是什么模型'));
    await tester.pump();
    expect(jumped.single.entryId, 'u2');
    expect(jumped.single.isUser, isTrue);

    jumped.clear();
    await tester.tap(find.text('能看到。这是桌面版的截图'));
    await tester.pump();
    expect(jumped.single.entryId, 'a4');
    expect(jumped.single.isUser, isFalse);
  });

  testWidgets('上下键移动高亮、Enter 命中；打开那一下没有高亮', (tester) async {
    final jumped = <TimelineRow>[];
    await pumpTimeline(tester, turns: sample(), onJump: jumped.add);

    // 打开那一下没有高亮：直接 Enter 不命中任何行。
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(jumped, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // 第 1 行
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // 第 2 行（01 的 A 行）
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(jumped.single.entryId, 'a1');
  });

  testWidgets('高亮夹在两端，不回绕', (tester) async {
    final jumped = <TimelineRow>[];
    await pumpTimeline(tester, turns: sample(), onJump: jumped.add);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    }
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(jumped.single.entryId, 'u1', reason: '在第一行再按上键还是第一行');
  });

  testWidgets('键盘高亮移出视口时自动露出', (tester) async {
    await pumpTimeline(tester, turns: long(30), scrollToBottomOnOpen: false);
    final scroller = scrollerOf(tester);
    expect(scroller.position.pixels, 0);

    for (var i = 0; i < 25; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    }
    await tester.pumpAndSettle();

    expect(scroller.position.pixels, greaterThan(0));
  });

  testWidgets('导轨两端不出头：线顶在第一个节点中心、底在最后一个节点中心', (tester) async {
    await pumpTimeline(tester, turns: sample(), scrollToBottomOnOpen: false);

    final rail = tester.getRect(find.byType(ColoredBox));
    final firstRow = tester.getRect(find.text('01'));
    final lastRow = tester.getRect(find.text('能看到。这是桌面版的截图'));
    expect(rail.top, moreOrLessEquals(firstRow.center.dy, epsilon: 1));
    expect(rail.bottom, moreOrLessEquals(lastRow.center.dy, epsilon: 1));
  });

  testWidgets('弹层卸载后不再吃方向键（焦点节点随它一起没了）', (tester) async {
    final jumped = <TimelineRow>[];
    await pumpTimeline(tester, turns: sample(), onJump: jumped.add);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    // 没崩、也没有回调：拿着键的那个 Focus 已经随弹层一起卸载了。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(jumped, isEmpty);
  });
}
