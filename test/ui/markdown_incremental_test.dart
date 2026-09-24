// 流式 Markdown 只重解析尾部（BACKLOG「流式渲染性能」）的回归：
// ① 等价性：把真实 agent 消息（fixtures）、仓库里的文档与一批边角样例按随机大小的 chunk 逐段喂给 [MarkdownStream]，
//    每一步「已封口的块 + 尾部的块」渲染成 HTML 都要与整段 [MarkdownBody.parse] 一字不差——切错一处（围栏里、松散列表中间、
//    跨空行的 HTML 块、全文级的链接定义）这里就红；
// ② widget：封口的块实例在后续 chunk 里原样复用（不复用的话每个 chunk 整段重建），封口块里的链接在尾部重建之后仍点得动
//    （尾部那份 recognizer 释放时不能连带释放封口的）。

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:acp_agent_client/ui/transcript/code_block.dart';
import 'package:acp_agent_client/ui/transcript/markdown_body.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;

/// 边角样例：每条都是一种「在这里切开会改变解析结果」的结构。
const List<String> _edgeCases = <String>[
  '- a\n\n- b\n\n- c\n\nParagraph after.\n',
  '1. one\n\n2. two\n\n10. ten\n\nend\n',
  '- item\n\n  ```\n  code\n\n  more\n  ```\n\n- next\n\ntext\n',
  '```dart\nvoid main() {\n\n  print(1);\n\n}\n```\n\nafter\n',
  '~~~~\n```\n\nstill code\n~~~\n\n~~~~~\n\nafter\n',
  'text\n\n```\ncode\n\nmore\n',
  'para\n\n    code1\n\n    code2\n\nnext\n',
  '> a\n\n> b\n\n>c\nlazy\n\nd\n',
  '| a | b |\n|---|---|\n| 1 | 2 |\n\n| c |\n\ntext\n',
  '<div>\nhi\n\n</div>\n\n<!-- comment\n\nstill -->\n\nafter\n\n<pre>\nx\n\ny\n</pre>\n\nz\n',
  'see [foo] and [bar][]\n\nmore\n\n[foo]: http://a\n[bar]: http://b\n\ntail\n',
  'text[^1]\n\nmore\n\n[^1]: note\n\n    continued note\n\nend\n',
  'Title\n=====\n\npara\n---\n\nx\n',
  r'$$' '\na\n' r'$$' '\n\ninline \$x\$ here\n\n' r'$$' '\n\nb\n\n' r'$$' '\n',
  'a\n\n* * *\n\n***\n\n- - -\n\nb\n',
  '# H\npara\n## H2\n\ntext\n',
  '- [ ] a\n- [x] b\n\ndone\n',
  '| k | v |\n|---|---|\n| a | x<br>y |\n\nafter\n',
  '*a\nb*\n\nc\n',
  '> - a\n>\n> - b\n\nc\n',
  '- a\n\nb\n\n- c\n',
  '- a\n\n\tcontinued\n\nx\n',
  '``` a`b\ncode?\n\nx\n',
  '\n\n\nabc\n\n',
  '```mermaid\ngraph TD\n\nA-->B\n```\n\nok\n',
  'para\n```\ncode\n```\nafter\n\nx\n',
  '1) a\n\n2) b\n\n3. c\n\nd\n',
  '+ a\n\n* b\n\n- c\n\nd\n',
  '<script>\nlet a = 1;\n\nlet b = 2;\n</script>\n\nafter\n',
  '<?php\n\necho 1;\n?>\n\nafter\n',
  '<![CDATA[\n\nx\n]]>\n\nafter\n',
  '<!DOCTYPE html>\n\nafter\n',
  '  ```\n  indented fence\n\n  ```\n\nafter\n',
  '````\n```\n\n````\n\nafter\n',
  '```\ncode\n```   \n\nafter\n',
  '```\ncode\n``` x\n\nstill code\n```\n\nafter\n',
];

/// fixtures 里 agent 消息的正文（同一 messageId 的 text chunk 首尾相接）。
List<String> _fixtureMessages() {
  final messages = <String, StringBuffer>{};
  for (final f in Directory('test/fixtures').listSync().whereType<File>().where((f) => f.path.endsWith('.jsonl'))) {
    for (final line in f.readAsLinesSync()) {
      if (!line.contains('agent_message_chunk')) continue;
      final update = ((jsonDecode(line) as Map<String, dynamic>)['msg']?['params']?['update']) as Map<String, dynamic>?;
      final content = update?['content'] as Map<String, dynamic>?;
      if (update == null || content == null || content['type'] != 'text') continue;
      (messages['${f.path}#${update['messageId']}'] ??= StringBuffer()).write(content['text'] as String);
    }
  }
  return <String>[for (final b in messages.values) b.toString()];
}

String _html(Iterable<md.Node> nodes) => md.HtmlRenderer().render(nodes.toList());

/// 按随机 chunk 喂一遍；[every] > 1 时整段解析只在「边界动了」的那几步与每 [every] 步对一次（大文档整段解析贵）。
void _stream(String source, math.Random rng, {int maxChunk = 24, int every = 1}) {
  final stream = MarkdownStream();
  final sealed = <md.Node>[];
  var pos = 0;
  var step = 0;
  while (pos < source.length) {
    pos = math.min(source.length, pos + 1 + rng.nextInt(maxChunk));
    final data = source.substring(0, pos);
    final r = stream.update(data);
    if (r.reset) sealed.clear();
    sealed.addAll(r.sealed);
    step++;
    if (every > 1 && r.sealed.isEmpty && !r.reset && step % every != 0 && pos < source.length) continue;
    final expected = _html(MarkdownBody.parse(data));
    final actual = _html(<md.Node>[...sealed, ...r.tail]);
    if (actual != expected) {
      fail('增量解析与整段解析不一致（前 $pos 个字符）：\n--- 原文 ---\n$data\n--- 整段 ---\n$expected\n--- 增量 ---\n$actual');
    }
  }
}

Future<void> _pump(WidgetTester tester, String source, {LinkCallback? onLink}) async {
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
}

void main() {
  test('边角样例逐字符喂：每一步都与整段解析一致', () {
    for (final s in _edgeCases) {
      _stream(s, math.Random(1), maxChunk: 1);
    }
  });

  test('边角样例随机 chunk 喂（多个种子）', () {
    for (var seed = 0; seed < 20; seed++) {
      final rng = math.Random(seed);
      for (final s in _edgeCases) {
        _stream(s, rng, maxChunk: 8);
      }
      // 拼起来当一条长消息再喂一遍：结构之间的衔接也要对。
      _stream(_edgeCases.join('\n'), rng, maxChunk: 16);
    }
  });

  test('fixtures 里的 agent 消息', () {
    final messages = _fixtureMessages();
    expect(messages, isNotEmpty);
    for (var seed = 0; seed < 5; seed++) {
      final rng = math.Random(seed);
      for (final m in messages) {
        _stream(m, rng, maxChunk: 12);
      }
    }
  });

  test('仓库文档（长文、表格、嵌套列表、围栏）', () {
    for (final path in <String>['README.md', 'docs/background.md', 'docs/requirements.md', 'docs/review-workflow.md', 'CLAUDE.md']) {
      _stream(File(path).readAsStringSync(), math.Random(path.length), maxChunk: 64, every: 16);
    }
  });

  test('边界只往后挪、确实会切（不是永远整段重解析）', () {
    final stream = MarkdownStream();
    const text = '第一段。\n\n第二段。\n\n```\ncode\n\nmore\n```\n\n第三段\n\n第四段';
    var sealedBlocks = 0;
    for (var i = 1; i <= text.length; i++) {
      final r = stream.update(text.substring(0, i));
      expect(r.reset, isFalse);
      sealedBlocks += r.sealed.length;
    }
    // 第一段、第二段、围栏各封口一次（第三段那一行收全之后围栏才封口）；第三段、第四段是尾部（第四段没收全，第三段封不了口）。
    expect(sealedBlocks, 3);
  });

  testWidgets('封口的块实例在后续 chunk 里原样复用', (WidgetTester tester) async {
    const head = '第一段，**加粗**。\n\n第二段。\n\n';
    await _pump(tester, '${head}尾');
    final first = tester.widget<MarkdownBlock>(find.byType(MarkdownBlock).first);
    for (final more in <String>['尾巴长一点', '尾巴长一点\n\n再一段', '尾巴长一点\n\n再一段\n\n又一段']) {
      await _pump(tester, '$head$more');
      expect(identical(tester.widget<MarkdownBlock>(find.byType(MarkdownBlock).first), first), isTrue, reason: '封口块每个 chunk 都换了新实例 = 整段重建');
    }
    expect(find.byType(MarkdownBlock), findsNWidgets(5));
  });

  testWidgets('代码块留在尾部、正文还在往后写时不重新高亮', (WidgetTester tester) async {
    // 围栏已收、下一行还没收全：代码块还在尾部，每个 chunk 都跟着重建，但代码没变，高亮结果原样复用。
    const head = '```dart\nvoid main() {}\n```\n\n';
    TextSpan? codeSpan() => tester.widget<Text>(find.descendant(of: find.byType(CodeBlock), matching: find.byType(Text)).last).textSpan as TextSpan?;
    await _pump(tester, '${head}a');
    final first = codeSpan();
    for (final more in <String>['ab', 'abc', 'abcd']) {
      await _pump(tester, '$head$more');
      expect(identical(codeSpan(), first), isTrue, reason: '代码没变却重新高亮了');
    }
    await _pump(tester, '```dart\nvoid main() { run(); }\n```\n\nabcd');
    expect(identical(codeSpan(), first), isFalse, reason: '代码变了要重新高亮');
  });

  testWidgets('封口块与尾部块里的链接在尾部重建之后都点得动', (WidgetTester tester) async {
    final opened = <String>[];
    // 两段链接都从行首开始：点段落左端就点在链接上（链接文字用 ASCII：测试字体没有中文字形，点中文点不中）。
    // 第一段在第二段收全后封口，第二段一直在尾部。
    const head = '[design](docs/design.md)\n\n[tail](tail.md)\n\n';
    await _pump(tester, '$head再', onLink: opened.add);
    for (final more in <String>['再一', '再一段', '再一段更长']) {
      await _pump(tester, '$head$more', onLink: opened.add);
    }
    final paragraphs = find.byType(Text);
    expect(paragraphs, findsNWidgets(3));
    Offset leftEdge(Finder f) => tester.getTopLeft(f) + Offset(4, tester.getSize(f).height / 2);
    await tester.tapAt(leftEdge(paragraphs.at(0)));
    await tester.tapAt(leftEdge(paragraphs.at(1)));
    expect(opened, <String>['docs/design.md', 'tail.md']);
  });
}
