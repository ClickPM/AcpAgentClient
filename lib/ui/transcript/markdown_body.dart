// 助手正文的 Markdown 渲染（R1.5 裁定：package:markdown 只用解析器，渲染层按画板自写）。
// - 每个顶层块带 ValueKey(index)，流式追加时只有尾块的子树变化；
// - 链接的 recognizer 下推到每个叶子 span（RichText 命中测试只看最内层），由 MarkdownBody 的 State 持有：
//   输入变化先 dispose 再重建、widget 卸载时全部释放（审查 P2：流式 chunk 每次 build 新建且从不 dispose 会泄漏）；
// - `$…$` / `$$…$$` 在这里以 InlineSyntax 识别，交给 math_block.dart；
// - 行内 HTML 只认 `<br>`（见 [HtmlLineBreakSyntax]），其余标签仍按 package:markdown 的规矩原样显示；
// - 围栏交给 code_block.dart（语言 mermaid 交给 mermaid_block.dart）、表格交给 gfm_table.dart；
// - 表头行启发式：只有一行 `| a | b |` 还没等到分隔行时先按表头渲染，避免分隔行到达那一帧跳变。
// - 列表项里行内内容与嵌套块（子列表 / 围栏 / 表格）共存时，行内的先并成一段再渲染（见 [MarkdownBlock._mixedChildren]）。
// - 流式追加时只重解析尾部（BACKLOG「流式渲染性能」）：最后一个安全块边界（[markdownSafeBoundary]）之前的块解析一次、
//   widget 实例留着复用，每个 chunk 只重解析、重建边界之后的那几块。

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
class _LatexSyntax extends md.InlineSyntax {
  _LatexSyntax() : super(r'\$\$([\s\S]+?)\$\$|\$([^$\n]+?)\$');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final display = match[1] != null;
    final element = md.Element.text('latex', (match[1] ?? match[2])!);
    element.attributes['display'] = display ? 'true' : 'false';
    parser.addNode(element);
    return true;
  }
}

/// 行内 HTML 的 `<br>`（含 `<br/>` / `<br />`，大小写不敏感）→ 与硬换行同款的 `br` 元素。
/// package:markdown 的 `InlineHtmlSyntax` 只是「原样放行」（substitute 为空 → advanceBy 后 return false，不建节点），
/// 于是 `<br>` 会留在 `md.Text` 的文本里被逐字画出来。GFM 的表格单元格装不下真换行，agent 普遍拿 `<br>` 换行
/// （2026-09-20 实机：pi 的扩展清单表格整列显示成字面 `<br>`），所以这一个标签要认。
/// 必须排在 `InlineHtmlSyntax` 之前：InlineParser 按 syntaxes 顺序取第一个匹配的。
/// 其余行内 HTML（`<sub>` / `<kbd>` / `<span>` 等成对标签）照旧原样显示：实测里只有 `<br>` 常见，其余不做
/// （所有者 2026-09-23 关闭，见 rounds/BACKLOG-CLOSED.md）。
class HtmlLineBreakSyntax extends md.InlineSyntax {
  HtmlLineBreakSyntax() : super(r'<br\s*/?>', caseSensitive: false);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.empty('br'));
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
    <md.InlineSyntax>[_LatexSyntax(), HtmlLineBreakSyntax(), ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes],
  );

  static List<md.Node> parse(String data) => md.Document(extensionSet: _extensions, encodeHtml: false).parse(data);

  @override
  State<MarkdownBody> createState() => _MarkdownBodyState();
}

/// 流式 Markdown 的「安全块边界」：[data] 里 [from] 之后最后一个可以切开分段解析的位置，没有就是 [from]。
/// [from] 本身必须是安全边界（或 0）。
///
/// 安全 = 在这里切开、两段各自 [MarkdownBody.parse] 再首尾相接，与整段解析出的顶层块一致（`test/ui/markdown_incremental_test.dart`
/// 按字符逐段喂真实 fixtures 与边角样例对照）。判据宁可少切：
/// 1. 位置在一行或几行空行之后、下一块首行的行首，且那一行已经收全（后面有换行）；
/// 2. 不在围栏代码块里。围栏行与 package:markdown 7.3.1 的 `codeFencePattern` **整行**同一条判（反引号围栏的信息串里不能再有反引号），
///    收栏要同一字符、不短于开栏、信息串 `trim()` 后为空——与它逐条一致，才不会出现「这边收了、它还开着」的失步
///    （审查 high：`` ``` a`b `` 不是开栏，当成开栏的话下一行 `` ``` `` 被当收栏，真围栏中间就切了一刀）。
///    只跟踪顶格的围栏：顶格的围栏行一定在顶层（它会打断列表、引用、段落、表格）；缩进 1–3 格的可能在列表项里，
///    项结束时围栏被隐式收掉，这边跟不上，所以碰到就不再往后切；
/// 3. 下一块首行顶格、不是列表标记：空行后跟这样一行，前面的列表、引用、缩进代码块、表格、段落一定已经结束；
///    也不以 `<` 开头——package:markdown 给「不是全文第一块」的 HTML 块前面补一个换行，切开后它成了第一块就少了这个换行；
/// 4. 出现 `<` 开头的行（HTML 块）之后不再切：第 1–5 类能跨空行，第 6 / 7 类到空行为止、但块里的 `` ``` `` 是原文不是开栏，
///    两种这边都不去模拟。
/// 链接引用定义与脚注定义是全文级的（后文的定义改前文的渲染），`\r` 换行另有切法——这两种由调用方整段解析，不走这里。
int markdownSafeBoundary(String data, int from) {
  var best = from;
  String? fence;
  var afterBlank = false;
  var pos = from;
  while (true) {
    final nl = data.indexOf('\n', pos);
    if (nl < 0) break;
    final line = data.substring(pos, nl);
    if (fence != null) {
      if (_closesFence(line, fence)) fence = null;
    } else if (_blankLine.hasMatch(line)) {
      afterBlank = true;
    } else {
      if (afterBlank && pos > from && !_notABlockStart.hasMatch(line)) best = pos;
      afterBlank = false;
      final f = _fenceLine.firstMatch(line);
      if (_htmlLine.hasMatch(line) || (f != null && f[1]!.isNotEmpty)) break;
      fence = f == null ? null : f[2] ?? f[4];
    }
    pos = nl + 1;
  }
  return best;
}

final RegExp _blankLine = RegExp(r'^[ \t]*$');

/// 空行之后不能当新块起点的行：缩进、`<`、列表标记（判据 3）。
final RegExp _notABlockStart = RegExp(r'^(?:[ \t<]|(?:\d{1,9}[.)]|[*+-])(?:[ \t]|$))');

/// 围栏行（判据 2）：package:markdown 7.3.1 `codeFencePattern` 的原样。组 1 缩进，组 2 / 3 反引号标记与信息串，组 4 / 5 波浪号。
final RegExp _fenceLine = RegExp(r'^( {0,3})(?:(`{3,})([^`]*)|(~{3,})(.*))$');

bool _closesFence(String line, String fence) {
  final m = _fenceLine.firstMatch(line);
  if (m == null) return false;
  final marker = m[2] ?? m[4]!;
  return marker[0] == fence[0] && marker.length >= fence.length && (m[3] ?? m[5]!).trim().isEmpty;
}

/// HTML 块起点（判据 4）：缩进 ≤ 3 的 `<`。
final RegExp _htmlLine = RegExp(r'^ {0,3}<');

/// 行首（缩进 ≤ 3）的 `[…]:`：链接引用定义或脚注定义。
final RegExp _definitionLine = RegExp(r'^ {0,3}\[.*\]:', multiLine: true);

/// 流式 Markdown 的块级增量解析：[markdownSafeBoundary] 之前的部分「封口」，只解析一次；每次 [update] 只重解析边界之后的尾部。
/// 新全文以已封口的原文开头（流式追加）时沿用；否则（改写、有全文级定义、`\r` 换行）作废重来，整段当尾部解析。
class MarkdownStream {
  String _sealed = '';

  /// 喂入最新全文。`reset` = 之前封口的块作废；`sealed` = 这次新封口、接在已封口之后的块；`tail` = 边界之后的块。
  ({bool reset, List<md.Node> sealed, List<md.Node> tail}) update(String data) {
    final incremental = !data.contains('\r') && !(data.contains(']:') && _definitionLine.hasMatch(data));
    final reset = _sealed.isNotEmpty && (!incremental || !data.startsWith(_sealed));
    if (reset) _sealed = '';
    var sealed = const <md.Node>[];
    if (incremental) {
      final from = _sealed.length;
      final to = markdownSafeBoundary(data, from);
      if (to > from) {
        sealed = MarkdownBody.parse(data.substring(from, to));
        _sealed = data.substring(0, to);
      }
    }
    return (reset: reset, sealed: sealed, tail: MarkdownBody.parse(_sealed.isEmpty ? data : data.substring(_sealed.length)));
  }

  /// 忘掉已封口的部分，下次 [update] 从头解析。
  void clear() => _sealed = '';
}

class _MarkdownBodyState extends State<MarkdownBody> {
  /// 封口的块（解析一次、实例留着）与尾部的块（每次输入变都重建）各用一份 recognizer 登记处，
  /// 尾部重建时只释放尾部那一份。
  final LinkRecognizers _stableLinks = LinkRecognizers();
  final LinkRecognizers _tailLinks = LinkRecognizers();

  final MarkdownStream _stream = MarkdownStream();

  /// 封口的块 widget（按顺序，下标即 key）与当前整列。
  final List<Widget> _stableBlocks = <Widget>[];
  List<Widget> _blocks = const <Widget>[];

  /// 算 [_blocks] 时的字体代数。块实例是缓存的（见 [_update]），而每块都把当时的字阶连同颜色
  /// 一起烘了进去（`base` 与各处 `CardText` / 颜色 token），换字体或换主题后必须重解析一次；
  /// [t.Fonts.generation] 两件事都会 +1（tokens.dart 的注释写明了），一个代数覆盖两件事。
  /// 同 `lib/ui/files/files_panel.dart` 的 `_SourceView`。
  int _fontGeneration = t.Fonts.generation;

  @override
  void initState() {
    super.initState();
    _update();
  }

  @override
  void didUpdateWidget(MarkdownBody old) {
    super.didUpdateWidget(old);
    if (old.onLink != widget.onLink || old.mermaidFontFamily != widget.mermaidFontFamily || old.baseStyle != widget.baseStyle) {
      _reset();
      _update();
    } else if (old.data != widget.data) {
      _update();
    }
  }

  @override
  void dispose() {
    _stableLinks.disposeAll();
    _tailLinks.disposeAll();
    super.dispose();
  }

  /// 丢掉封口的缓存（输入以外的参数、字体或主题变了），下次 [_update] 从头解析。
  void _reset() {
    _stream.clear();
    _stableLinks.disposeAll();
    _stableBlocks.clear();
  }

  /// 只在输入变化（或字体 / 主题换了）时重新解析；块 widget 实例缓存，父级重建时子树不重建，
  /// recognizer 也就不会随父级 build 反复登记。流式追加时封口的块原样复用（[MarkdownStream]），只重建尾部。
  void _update() {
    _fontGeneration = t.Fonts.generation;
    final r = _stream.update(widget.data);
    if (r.reset) {
      _stableLinks.disposeAll();
      _stableBlocks.clear();
    }
    _stableBlocks.addAll(_widgets(r.sealed, _stableBlocks.length, _stableLinks));
    _tailLinks.disposeAll();
    _blocks = <Widget>[..._stableBlocks, ..._widgets(r.tail, _stableBlocks.length, _tailLinks)];
  }

  List<Widget> _widgets(List<md.Node> nodes, int start, LinkRecognizers links) {
    final base = widget.baseStyle ?? t.TextStyles.body;
    return <Widget>[
      for (var i = 0; i < nodes.length; i++)
        KeyedSubtree(
          key: ValueKey<int>(start + i),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: t.Spacing.s4),
            child: MarkdownBlock(node: nodes[i], onLink: widget.onLink, links: links, mermaidFontFamily: widget.mermaidFontFamily, base: base),
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // 换过字体或主题就重解析一次（[didUpdateWidget] 只比得出输入变化，这两件事输入一个都没变）。
    // 放在 build 而不是监听器里：MarkdownBody 拿不到 AppearanceController，而组合根换主题时本来
    // 就会重建整棵树，这里只是顺带对一次代数——同 `_SourceView`。
    //
    // 整段重来会 `disposeAll()` 掉旧的 link recognizer，这一条与 [didUpdateWidget] 那条路径
    // （流式 chunk 每到一段就对尾部这么做一次）是同一个操作，不是新增的风险面：代数只由 `Fonts.apply` /
    // `Theming.apply` 推进，那一下用户的指针在外观开关上、不在转录的链接上；真撞上了也只是那次点击
    // 被取消（`OneSequenceGestureRecognizer.dispose` 先 `resolve(rejected)` 再摘路由），不会挂。
    if (_fontGeneration != t.Fonts.generation) {
      _reset();
      _update();
    }
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
          decoration: BoxDecoration(
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
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: t.Spacing.s8),
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
        final span = TextSpan(style: TextStyle(color: t.Accent.text), children: <InlineSpan>[inlines(node.children, base)]);
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
        return TextSpan(text: '[image: ${node.attributes['alt'] ?? node.attributes['src'] ?? ''}]', style: TextStyle(color: t.Neutral.muted));
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
        child: _checked ? AcpIcon(AcpIcons.check, color: t.Accent.onAccent, size: t.IconSizes.toolbar, strokeWidth: t.IconSizes.stroke * 2) : null,
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
