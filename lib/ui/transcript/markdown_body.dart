// 助手正文的 Markdown 渲染（R1.5 裁定：package:markdown 只用解析器，渲染层按画板自写）。
// - 每个顶层块带 ValueKey(index)，流式追加时只有尾块的子树变化；
// - 链接的 recognizer 下推到每个叶子 span（RichText 命中测试只看最内层），由 MarkdownBody 的 State 持有：
//   输入变化先 dispose 再重建、widget 卸载时全部释放（审查 P2：流式 chunk 每次 build 新建且从不 dispose 会泄漏）；
// - `$…$` / `$$…$$` 在这里以 InlineSyntax 识别，交给 math_block.dart；
// - 围栏交给 code_block.dart（语言 mermaid 交给 mermaid_block.dart）、表格交给 gfm_table.dart；
// - 表头行启发式：只有一行 `| a | b |` 还没等到分隔行时先按表头渲染，避免分隔行到达那一帧跳变。
// - 列表项里行内内容与嵌套块（子列表 / 围栏 / 表格）共存时，行内的先并成一段再渲染（见 [MarkdownBlock._mixedChildren]）。

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:markdown/markdown.dart' as md;

import '../../theme/tokens.dart' as t;
import 'card_chrome.dart';
import 'code_block.dart';
import 'gfm_table.dart';
import 'icons.dart';
import 'math_block.dart';
import 'mermaid_block.dart';

typedef LinkCallback = void Function(String href);

/// `$$…$$`（块级）与 `$…$`（行内）→ `<latex display="true|false">`。
class LatexSyntax extends md.InlineSyntax {
  LatexSyntax() : super(r'\$\$([\s\S]+?)\$\$|\$([^$\n]+?)\$');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final display = match[1] != null;
    final element = md.Element.text('latex', (match[1] ?? match[2])!);
    element.attributes['display'] = display ? 'true' : 'false';
    parser.addNode(element);
    return true;
  }
}

/// 链接 recognizer 的所有者：`MarkdownBody` 的 State 持有一份，块渲染时经 [create] 登记，State 负责释放。
class LinkRecognizers {
  final List<GestureRecognizer> _owned = <GestureRecognizer>[];

  TapGestureRecognizer create(VoidCallback onTap) {
    final r = TapGestureRecognizer()..onTap = onTap;
    _owned.add(r);
    return r;
  }

  void disposeAll() {
    for (final r in _owned) {
      r.dispose();
    }
    _owned.clear();
  }
}

class MarkdownBody extends StatefulWidget {
  const MarkdownBody(this.data, {super.key, this.onLink, this.mermaidFontFamily, this.baseStyle});

  final String data;
  final LinkCallback? onLink;
  final String? mermaidFontFamily;
  final TextStyle? baseStyle;

  static final md.ExtensionSet _extensions = md.ExtensionSet(
    md.ExtensionSet.gitHubFlavored.blockSyntaxes,
    <md.InlineSyntax>[LatexSyntax(), ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes],
  );

  static List<md.Node> parse(String data) => md.Document(extensionSet: _extensions, encodeHtml: false).parse(data);

  @override
  State<MarkdownBody> createState() => _MarkdownBodyState();
}

class _MarkdownBodyState extends State<MarkdownBody> {
  final LinkRecognizers _links = LinkRecognizers();
  List<Widget> _blocks = const <Widget>[];

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  @override
  void didUpdateWidget(MarkdownBody old) {
    super.didUpdateWidget(old);
    if (old.data != widget.data || old.onLink != widget.onLink || old.mermaidFontFamily != widget.mermaidFontFamily || old.baseStyle != widget.baseStyle) {
      _rebuild();
    }
  }

  @override
  void dispose() {
    _links.disposeAll();
    super.dispose();
  }

  /// 只在输入变化时重新解析；块 widget 实例缓存，父级重建时子树不重建，recognizer 也就不会随父级 build 反复登记。
  void _rebuild() {
    _links.disposeAll();
    final nodes = MarkdownBody.parse(widget.data);
    final base = widget.baseStyle ?? t.TextStyles.body;
    _blocks = <Widget>[
      for (var i = 0; i < nodes.length; i++)
        KeyedSubtree(
          key: ValueKey<int>(i),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: t.Spacing.s4),
            child: MarkdownBlock(node: nodes[i], onLink: widget.onLink, links: _links, mermaidFontFamily: widget.mermaidFontFamily, base: base),
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: _blocks);
  }
}

class MarkdownBlock extends StatelessWidget {
  const MarkdownBlock({super.key, required this.node, this.onLink, this.links, this.mermaidFontFamily, required this.base});

  final md.Node node;
  final LinkCallback? onLink;

  /// 链接 recognizer 的登记处；缺省（不经 MarkdownBody 直接用）时不挂 recognizer。
  final LinkRecognizers? links;
  final String? mermaidFontFamily;
  final TextStyle base;

  static const Set<String> _blockTags = <String>{'p', 'ul', 'ol', 'pre', 'blockquote', 'table', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'hr'};
  static final RegExp _tableHeadLine = RegExp(r'^\|.*\|\s*$');

  @override
  Widget build(BuildContext context) {
    final n = node;
    if (n is md.Text) return Text(n.text, style: base);
    if (n is! md.Element) return const SizedBox.shrink();
    switch (n.tag) {
      case 'p':
        return _paragraph(n);
      case 'h1':
      case 'h2':
        return Padding(
          padding: const EdgeInsets.only(top: t.Spacing.s8),
          child: Text.rich(inlines(n.children, t.TextStyles.title), style: t.TextStyles.title),
        );
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        return Padding(
          padding: const EdgeInsets.only(top: t.Spacing.s4),
          child: Text.rich(inlines(n.children, CardText.strong), style: CardText.strong),
        );
      case 'ul':
      case 'ol':
        return _list(n);
      case 'blockquote':
        return Container(
          padding: const EdgeInsets.only(left: t.Spacing.s12),
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: t.Borders.base, width: t.Borders.width * 2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final c in n.children ?? const <md.Node>[])
                MarkdownBlock(node: c, onLink: onLink, links: links, mermaidFontFamily: mermaidFontFamily, base: base.copyWith(color: t.Neutral.muted)),
            ],
          ),
        );
      case 'hr':
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: t.Spacing.s8),
          child: SizedBox(height: t.Borders.width, child: ColoredBox(color: t.Borders.subtle)),
        );
      case 'pre':
        final code = n.children?.whereType<md.Element>().where((e) => e.tag == 'code').firstOrNull;
        final cls = code?.attributes['class'] ?? '';
        final lang = cls.startsWith('language-') ? cls.substring('language-'.length) : null;
        final text = code?.textContent ?? n.textContent;
        if (lang == 'mermaid') return MermaidBlock(source: text.trimRight(), fontFamily: mermaidFontFamily);
        return CodeBlock(code: text, language: lang);
      case 'table':
        return GfmTable(element: n, inline: inlines);
      case 'latex':
        return MathBlock(n.textContent);
      default:
        return Text(n.textContent, style: base);
    }
  }

  Widget _paragraph(md.Element p) {
    final kids = p.children ?? const <md.Node>[];
    if (kids.length == 1 && kids.first is md.Element) {
      final only = kids.first as md.Element;
      if (only.tag == 'latex' && only.attributes['display'] == 'true') return MathBlock(only.textContent);
    }
    // 表头行启发式：整段只有一行 `| … |`（分隔行还没到），先按只有表头的表渲染。
    if (kids.length == 1 && kids.first is md.Text) {
      final text = (kids.first as md.Text).text;
      if (!text.contains('\n') && _tableHeadLine.hasMatch(text)) {
        final cells = text.trim().substring(1, text.trim().length - 1).split('|').map((c) => c.trim()).toList();
        if (cells.length >= 2) {
          final tr = md.Element('tr', <md.Node>[for (final c in cells) md.Element('th', <md.Node>[md.Text(c)])]);
          final table = md.Element('table', <md.Node>[
            md.Element('thead', <md.Node>[tr]),
          ]);
          return GfmTable(element: table, inline: inlines);
        }
      }
    }
    return Text.rich(inlines(kids, base), style: base);
  }

  Widget _list(md.Element list) {
    final ordered = list.tag == 'ol';
    final start = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    final items = list.children?.whereType<md.Element>().where((e) => e.tag == 'li').toList() ?? const <md.Element>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var i = 0; i < items.length; i++) _listItem(items[i], ordered ? '${start + i}.' : '•'),
      ],
    );
  }

  Widget _listItem(md.Element li, String marker) {
    final kids = List<md.Node>.of(li.children ?? const <md.Node>[]);
    Widget? checkbox;
    if (kids.isNotEmpty && kids.first is md.Element && (kids.first as md.Element).tag == 'input') {
      final checked = (kids.removeAt(0) as md.Element).attributes['checked'] == 'true';
      checkbox = TaskCheckbox(checked: checked);
    }
    final hasBlocks = kids.any((k) => k is md.Element && _blockTags.contains(k.tag));
    final body = hasBlocks
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: _mixedChildren(kids),
          )
        : Text.rich(inlines(kids, base), style: base);
    return Padding(
      padding: const EdgeInsets.only(bottom: t.Spacing.s4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (checkbox != null)
            Padding(padding: const EdgeInsets.only(right: t.Spacing.s8, top: t.Spacing.s4), child: checkbox)
          else
            SizedBox(width: t.Spacing.s24, child: Text(marker, style: base.copyWith(color: t.Neutral.muted))),
          Expanded(child: body),
        ],
      ),
    );
  }

  /// 紧凑列表（项之间没有空行）的 `li` 不会给行内内容包 `<p>`：`**标题**：` + 子列表解析成
  /// `[<strong>, Text(：), <ul>]`。把它们逐个当块渲染的话，每个行内节点都会独占一行（冒号单独一行），
  /// 行内元素还会掉进 [build] 的 `default` 分支丢掉粗体 / 行内代码 / 链接 recognizer，
  /// 所以这里先把连续的行内兄弟并回一段，再让真正的块级子节点各自成块。
  List<Widget> _mixedChildren(List<md.Node> kids) {
    final out = <Widget>[];
    final run = <md.Node>[];
    void flush() {
      if (run.isEmpty) return;
      out.add(Text.rich(inlines(run, base), style: base));
      run.clear();
    }

    for (final k in kids) {
      if (k is md.Element && _blockTags.contains(k.tag)) {
        flush();
        out.add(MarkdownBlock(node: k, onLink: onLink, links: links, mermaidFontFamily: mermaidFontFamily, base: base));
      } else {
        run.add(k);
      }
    }
    flush();
    return out;
  }

  InlineSpan _withRecognizer(InlineSpan span, GestureRecognizer recognizer) {
    if (span is! TextSpan) return span;
    return TextSpan(
      text: span.text,
      style: span.style,
      recognizer: recognizer,
      children: span.children?.map((c) => _withRecognizer(c, recognizer)).toList(),
    );
  }

  TextSpan inlines(List<md.Node>? nodes, TextStyle base) {
    return TextSpan(children: <InlineSpan>[for (final n in nodes ?? const <md.Node>[]) _inline(n, base)]);
  }

  InlineSpan _inline(md.Node node, TextStyle base) {
    if (node is md.Text) return TextSpan(text: node.text);
    if (node is! md.Element) return const TextSpan();
    switch (node.tag) {
      case 'em':
        return TextSpan(style: const TextStyle(fontStyle: FontStyle.italic), children: <InlineSpan>[inlines(node.children, base)]);
      case 'strong':
        return TextSpan(
          style: const TextStyle(fontWeight: t.Weights.medium, fontVariations: t.Weights.mediumVariation),
          children: <InlineSpan>[inlines(node.children, base)],
        );
      case 'del':
        return TextSpan(style: const TextStyle(decoration: TextDecoration.lineThrough), children: <InlineSpan>[inlines(node.children, base)]);
      case 'code':
        return TextSpan(text: node.textContent, style: CardText.inlineCode);
      case 'a':
        final href = node.attributes['href'] ?? '';
        final cb = onLink;
        final owner = links;
        final span = TextSpan(style: const TextStyle(color: t.Accent.text), children: <InlineSpan>[inlines(node.children, base)]);
        if (cb == null || owner == null) return span;
        // RichText 命中测试只看最内层 TextSpan 的 recognizer，所以要下推到每个叶子；recognizer 由 MarkdownBody 的 State 释放。
        return _withRecognizer(span, owner.create(() => cb(href)));
      case 'br':
        return const TextSpan(text: '\n');
      case 'latex':
        return WidgetSpan(alignment: PlaceholderAlignment.middle, child: MathInline(node.textContent, base: base));
      case 'input':
        return WidgetSpan(alignment: PlaceholderAlignment.middle, child: TaskCheckbox(checked: node.attributes['checked'] == 'true'));
      case 'img':
        return TextSpan(text: '[image: ${node.attributes['alt'] ?? node.attributes['src'] ?? ''}]', style: const TextStyle(color: t.Neutral.muted));
      default:
        return inlines(node.children, base);
    }
  }
}

/// 画板 12 的任务清单复选框：画布绘制（不依赖 Material 图标字体）；只改本地呈现态，不回写 agent。
class TaskCheckbox extends StatefulWidget {
  const TaskCheckbox({super.key, required this.checked});

  final bool checked;

  @override
  State<TaskCheckbox> createState() => _TaskCheckboxState();
}

class _TaskCheckboxState extends State<TaskCheckbox> {
  late bool _checked = widget.checked;

  @override
  void didUpdateWidget(TaskCheckbox old) {
    super.didUpdateWidget(old);
    if (old.checked != widget.checked) _checked = widget.checked;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _checked = !_checked),
      child: Container(
        width: t.IconSizes.toolbar,
        height: t.IconSizes.toolbar,
        decoration: BoxDecoration(
          color: _checked ? t.Accent.base : null,
          border: _checked ? null : Border.all(color: t.Borders.base, width: t.Borders.width),
          borderRadius: t.Radii.chip,
        ),
        alignment: Alignment.center,
        child: _checked ? const AcpIcon(AcpIcons.check, color: t.Accent.onAccent, size: t.IconSizes.toolbar, strokeWidth: t.IconSizes.stroke * 2) : null,
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
