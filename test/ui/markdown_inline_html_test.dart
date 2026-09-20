// 行内 HTML `<br>` 的回归：GFM 的表格单元格装不下真换行，agent 普遍拿 `<br>` 换行
// （2026-09-20 实机：pi 的扩展清单表格，「名称<br>id」整列显示成字面 `<br>`）。
// package:markdown 的 InlineHtmlSyntax 只是「原样放行」，不建节点，所以要自己认这一个标签
// （[HtmlLineBreakSyntax]）；markdown_body.dart 里原有的 `case 'br'` 只接硬换行（行尾两空格 / 反斜杠），
// 表格单元格是单行，永远走不到那里。

import 'package:acp_agent_client/ui/transcript/markdown_body.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpMarkdown(WidgetTester tester, String source) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(800, 600)),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 600, child: MarkdownBody(source)),
        ),
      ),
    ),
  );
  await tester.pump();
  expect(tester.takeException(), isNull);
}

/// 画面上所有 Text 的纯文本（Text.rich 走 textSpan）。
List<String> plainTexts(WidgetTester tester) =>
    tester.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? w.textSpan?.toPlainText() ?? '').toList();

void main() {
  testWidgets('表格单元格里的 <br> 变成换行，画面上不再出现字面标签', (tester) async {
    await pumpMarkdown(tester, '''
| 序号 | 扩展名称 (id) |
| --- | --- |
| 1 | 通用 Agent 人设<br>`general-agent-prompt` |
| 2 | 中文语言守卫<br>`language-guard` |
''');

    expect(find.text('通用 Agent 人设\ngeneral-agent-prompt'), findsOneWidget);
    expect(find.text('中文语言守卫\nlanguage-guard'), findsOneWidget);
    expect(plainTexts(tester).any((s) => s.contains('<br')), isFalse, reason: '修复前这里是字面 <br>');
  });

  testWidgets('段落里的 <br> / <br/> / <BR /> 都认，大小写与自闭合斜杠不挑', (tester) async {
    await pumpMarkdown(tester, '一行<br>两行<br/>三行<BR />四行');

    expect(find.text('一行\n两行\n三行\n四行'), findsOneWidget);
  });

  testWidgets('硬换行（行尾两个空格）照旧', (tester) async {
    await pumpMarkdown(tester, '上一行  \n下一行');

    expect(find.text('上一行\n下一行'), findsOneWidget);
  });

  testWidgets('只认 <br>：其余行内 HTML 与行内代码里的 <br> 都不动', (tester) async {
    // 现状记录，不是期望值：成对标签（<kbd> / <sub> / <span> …）仍原样显示，见 rounds/BACKLOG.md。
    await pumpMarkdown(tester, '按 <kbd>Ctrl</kbd> 键；行内代码 `<br>` 不动');

    expect(find.text('按 <kbd>Ctrl</kbd> 键；行内代码 <br> 不动'), findsOneWidget);
  });
}
