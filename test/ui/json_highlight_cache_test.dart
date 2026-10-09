import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/projection/traffic.dart';
import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/traffic/traffic_page.dart';
import 'package:acp_agent_client/ui/transcript/card_chrome.dart';
import 'package:acp_agent_client/ui/transcript/tool_call_card.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpCard(WidgetTester tester, ToolCallEntry entry) =>
    tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SingleChildScrollView(
          child: ToolCallCard(entry, initiallyExpanded: true),
        ),
      ),
    );

InlineSpan inputSpan(WidgetTester tester) => tester
    .widget<Text>(
      find
          .descendant(of: find.byType(MonoBlock), matching: find.byType(Text))
          .first,
    )
    .textSpan!;

void main() {
  tearDown(t.Theming.reset);
  tearDown(t.Fonts.reset);

  testWidgets('工具卡重建复用 JSON span，原地更新 entry 字段后失效', (tester) async {
    final entry =
        ToolCallEntry(
            id: 'tool',
            at: DateTime(2026),
            toolCallId: 'tool',
            title: 'read',
          )
          ..status = ToolStatus.completed
          ..rawInput = <String, dynamic>{'path': 'a.txt'}
          ..rawOutput = <String, dynamic>{'result': 'old'};
    await pumpCard(tester, entry);
    final first = inputSpan(tester);
    final output = tester
        .widgetList<MonoBlock>(find.byType(MonoBlock))
        .last
        .text;
    await pumpCard(tester, entry);
    expect(identical(inputSpan(tester), first), isTrue);
    expect(
      identical(
        tester.widgetList<MonoBlock>(find.byType(MonoBlock)).last.text,
        output,
      ),
      isTrue,
    );

    // 投影层复用 ToolCallEntry，但每次 rawInput / rawOutput 都来自新线上 JSON。
    entry.rawInput = <String, dynamic>{'path': 'b.txt'};
    entry.rawOutput = <String, dynamic>{'result': 'new'};
    await pumpCard(tester, entry);
    expect(inputSpan(tester).toPlainText(), contains('b.txt'));
    expect(inputSpan(tester).toPlainText(), isNot(contains('a.txt')));
    expect(
      tester.widgetList<MonoBlock>(find.byType(MonoBlock)).last.text,
      contains('new'),
    );
    final updated = inputSpan(tester);
    entry.cancelledLocally = true;
    await pumpCard(tester, entry);
    expect(identical(inputSpan(tester), updated), isTrue);
    expect(find.text('Error: tool call aborted'), findsOneWidget);
  });

  testWidgets('工具卡换主题和字体后 JSON span 失效', (tester) async {
    final entry = ToolCallEntry(
      id: 'tool',
      at: DateTime(2026),
      toolCallId: 'tool',
      title: 'read',
    )..rawInput = <String, dynamic>{'path': 'a.txt'};
    await pumpCard(tester, entry);
    final light = inputSpan(tester);
    t.Theming.apply(t.AppTheme.dark);
    await pumpCard(tester, entry);
    final dark = inputSpan(tester);
    expect(identical(light, dark), isFalse);
    final colors = <Color?>[];
    dark.visitChildren((span) {
      colors.add(span.style?.color);
      return true;
    });
    expect(colors, contains(t.Accent.text));
    t.Fonts.apply(mono: 'test-mono');
    await pumpCard(tester, entry);
    expect(identical(inputSpan(tester), dark), isFalse);
    expect(inputSpan(tester).style?.fontFamily, 'test-mono');
  });

  for (final dropped in <bool>[false, true]) {
    testWidgets('流量展开行重建复用 span（dropped=$dropped），换行后不显示旧值', (tester) async {
      final store = TrafficStore();
      final filter = TextEditingController();
      final focus = FocusNode();
      addTearDown(store.dispose);
      addTearDown(filter.dispose);
      addTearDown(focus.dispose);
      void append(String text) => store.apply(<String, dynamic>{
        'agentId': 'agent',
        'direction': 'in',
        'ts': 0,
        'line': dropped
            ? '{"method":"session/update","params":{"update":{"sessionUpdate":"unknown","text":"$text"}}}'
            : '{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","text":"$text"}}}',
      });
      append('first');
      Future<void> pump() => tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: TrafficPage(
            store: store,
            filterController: filter,
            filterFocusNode: focus,
            initiallyExpanded: const <int>{1, 2},
          ),
        ),
      );
      InlineSpan span() => tester
          .widgetList<Text>(find.byType(Text))
          .singleWhere(
            (text) => text.textSpan?.toPlainText().contains('"first"') ?? false,
          )
          .textSpan!;
      await pump();
      final first = span();
      await pump();
      expect(identical(span(), first), isTrue);
      t.Theming.apply(t.AppTheme.dark);
      await pump();
      expect(identical(span(), first), isFalse);
      store.lines.clear();
      append('second');
      await pump();
      expect(
        tester
            .widgetList<Text>(find.byType(Text))
            .any(
              (text) =>
                  text.textSpan?.toPlainText().contains('"first"') ?? false,
            ),
        isFalse,
      );
      expect(
        tester
            .widgetList<Text>(find.byType(Text))
            .any(
              (text) =>
                  text.textSpan?.toPlainText().contains('"second"') ?? false,
            ),
        isTrue,
      );
    });
  }
}
