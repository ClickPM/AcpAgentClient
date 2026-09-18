// 紧凑列表项里「行内内容 + 嵌套块」共存的回归：package:markdown 对紧凑 li 不包 <p>，
// 行内兄弟必须并成一段再渲染，否则 `**标题**：` 的冒号单独成行、粗体 / 行内代码 / 链接全掉进
// MarkdownBlock 的 default 分支（2026-09-18 实机截图里 4 个列表项都中招）。

import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/transcript/markdown_body.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpMarkdown(WidgetTester tester, String source, {LinkCallback? onLink}) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(800, 600)),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 600, child: MarkdownBody(source, onLink: onLink)),
        ),
      ),
    ),
  );
  await tester.pump();
  expect(tester.takeException(), isNull);
}

List<TextSpan> spansOf(WidgetTester tester, Finder finder) {
  final out = <TextSpan>[];
  void walk(InlineSpan span) {
    if (span is! TextSpan) return;
    out.add(span);
    for (final c in span.children ?? const <InlineSpan>[]) {
      walk(c);
    }
  }

  walk(tester.widget<Text>(finder).textSpan!);
  return out;
}

void main() {
  testWidgets('紧凑列表项：粗体标题与其后的冒号同行，粗体不丢', (tester) async {
    await pumpMarkdown(tester, '''
1. **AAC 客户端自身占用了 ~620MB，偏大的原因**：
   - 图形/UI 与多会话缓存：维护了 6 个会话的消息历史。
   - 大图传输引起的内存驻留：本会话发送了大截图。
2. **Sidecar 进程的并发表现**：
   - Rust 系 Sidecar 多会话共享单实例。
''');

    // 修复前：strong 与 Text(：) 各自成块 → 冒号单独一行。
    expect(find.text('：'), findsNothing);
    expect(find.text('AAC 客户端自身占用了 ~620MB，偏大的原因：'), findsOneWidget);
    expect(find.text('Sidecar 进程的并发表现：'), findsOneWidget);

    // 修复前：strong 落进 build 的 default 分支 → 粗体丢失。
    final spans = spansOf(tester, find.text('Sidecar 进程的并发表现：'));
    expect(spans.any((s) => s.toPlainText() == 'Sidecar 进程的并发表现' && s.style?.fontWeight == t.Weights.medium), isTrue);

    // 嵌套列表照旧成块。
    expect(find.text('大图传输引起的内存驻留：本会话发送了大截图。'), findsOneWidget);
    expect(find.text('•'), findsNWidgets(3));
  });

  testWidgets('紧凑列表项：行内代码与链接不被拆行，链接仍可点', (tester) async {
    var tapped = '';
    await pumpMarkdown(tester, '''
- 见 [文档](https://example.com/a) 里的 `pi-acp` 说明：
  - 子项 A
''', onLink: (href) => tapped = href);

    final line = find.text('见 文档 里的 pi-acp 说明：');
    expect(line, findsOneWidget);

    final spans = spansOf(tester, line);
    final link = spans.firstWhere((s) => s.text == '文档');
    expect(link.recognizer, isNotNull, reason: '链接 recognizer 不能在混排里丢掉');
    expect(spans.any((s) => s.toPlainText() == '文档' && s.style?.color == t.Accent.text), isTrue);
    expect(spans.any((s) => s.text == 'pi-acp' && s.style?.fontFamily == t.Fonts.mono), isTrue);

    // 直接触发叶子 span 的 recognizer：混排行里链接的命中点不在整行中心。
    (link.recognizer! as TapGestureRecognizer).onTap!();
    expect(tapped, 'https://example.com/a');
  });

  testWidgets('松散列表（项间空行）仍照旧：li 里是 <p> + <ul>', (tester) async {
    await pumpMarkdown(tester, '''
1. **标题一**：

   - 子项 A

2. **标题二**：

   - 子项 B
''');

    expect(find.text('：'), findsNothing);
    expect(find.text('标题一：'), findsOneWidget);
    expect(find.text('子项 B'), findsOneWidget);
  });

  testWidgets('任务清单 + 嵌套列表：复选框还在，其余合成一行', (tester) async {
    await pumpMarkdown(tester, '''
- [x] 已完成 **要点**：
  - 子项 A
''');

    expect(find.byType(TaskCheckbox), findsOneWidget);
    expect(find.text('已完成 要点：'), findsOneWidget);
  });
}
