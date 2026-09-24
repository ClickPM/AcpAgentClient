// 画板 13 · 代码块卡片：语言标签 + Copy（点击后 Copied，motion.fast 后回落）+ 高亮（re_highlight，色表按画板 13 注释：
// 关键字 accent、字符串 success、类型 / 数字 warning、注释 placeholder、其余中性色阶）+ 长行横向滚动（不换行）。
// 也被 18 / 19 / 25 的 Raw Input 等宽块以外的 Markdown 围栏复用（markdown_body.dart）。

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';

import '../../theme/tokens.dart' as t;
import 'card_chrome.dart';
import 'icons.dart';

/// 全局只注册一次（197 种语言；注册只存 Mode，编译在首次高亮某语言时发生）。
final Highlight codeHighlighter = Highlight()..registerLanguages(builtinAllLanguages);

/// 围栏标签 → hljs 语言名。
const Map<String, String> _aliases = <String, String>{
  'ps1': 'powershell',
  'pwsh': 'powershell',
  'sh': 'bash',
  'zsh': 'bash',
  'shell': 'shell',
  'js': 'javascript',
  'ts': 'typescript',
  'yml': 'yaml',
  'rs': 'rust',
  'toml': 'ini',
  'jsonc': 'json',
};

/// hljs 11 scope → tokens（画板 13：只用中性色阶 + accent + success + warning + placeholder；
/// 深色按画板 07 § 2.8 换成同名 d. 对位值，映射本身一个都不改）。
///
/// **getter 而不是 `const` / `static final`**：色表把颜色烘进了 [TextStyle]，存成常量就冻在浅色那一套，
/// 换主题后代码块还是浅色字（理由同 `card_chrome.dart` 的 `CardText`）。
Map<String, TextStyle> get codeHighlightTheme => <String, TextStyle>{
  'keyword': TextStyle(color: t.Accent.text),
  'meta-keyword': TextStyle(color: t.Accent.text),
  'literal': TextStyle(color: t.Accent.text),
  'built_in': TextStyle(color: t.Accent.text),
  'variable.language_': TextStyle(color: t.Accent.text),
  'selector-tag': TextStyle(color: t.Accent.text),
  'string': TextStyle(color: t.Semantic.success),
  'meta-string': TextStyle(color: t.Semantic.success),
  'regexp': TextStyle(color: t.Semantic.success),
  'number': TextStyle(color: t.Semantic.warning),
  'type': TextStyle(color: t.Semantic.warning),
  'class': TextStyle(color: t.Semantic.warning),
  'title.class_': TextStyle(color: t.Semantic.warning),
  'symbol': TextStyle(color: t.Semantic.warning),
  'comment': TextStyle(color: t.Neutral.placeholder),
  'doctag': TextStyle(color: t.Neutral.placeholder),
  'quote': TextStyle(color: t.Neutral.placeholder),
  'title': TextStyle(color: t.Neutral.strong),
  'title.function_': TextStyle(color: t.Neutral.strong),
  'function': TextStyle(color: t.Neutral.strong),
  'attr': TextStyle(color: t.Neutral.text),
  'variable': TextStyle(color: t.Neutral.text),
  'params': TextStyle(color: t.Neutral.text),
  'operator': TextStyle(color: t.Neutral.muted),
  'punctuation': TextStyle(color: t.Neutral.muted),
  'meta': TextStyle(color: t.Neutral.muted),
};

TextSpan highlightCode(String code, String? language) {
  final lang = language == null || language.isEmpty ? null : (_aliases[language] ?? language);
  final HighlightResult result = lang != null && codeHighlighter.getLanguage(lang) != null
      ? codeHighlighter.highlight(code: code, language: lang)
      : codeHighlighter.justTextHighlightResult(code);
  final renderer = TextSpanRenderer(CardText.code, codeHighlightTheme);
  result.render(renderer);
  return renderer.span ?? TextSpan(text: code, style: CardText.code);
}

class CodeBlock extends StatefulWidget {
  const CodeBlock({super.key, required this.code, this.language, this.copiedInitially = false});

  final String code;
  final String? language;

  /// gallery 用：直接呈现「Copied」态。
  final bool copiedInitially;

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  late bool _copied = widget.copiedInitially;

  /// 高亮结果按 (code, language, 字体代数) 缓存（BACKLOG「流式渲染性能」）：上百行的代码高亮一次要十几毫秒，
  /// 而转录每个流式 chunk 都会重建这张卡（Markdown 尾部重解析、Copy 态切换）。色表与字阶烘在 span 里，
  /// 换主题 / 字体时 [t.Fonts.generation] 会变，同 `markdown_body.dart` 的块缓存。
  ({String code, String? language, int generation})? _key;
  TextSpan? _span;

  TextSpan _highlighted() {
    final key = (code: widget.code, language: widget.language, generation: t.Fonts.generation);
    final cached = _span;
    if (cached != null && key == _key) return cached;
    _key = key;
    return _span = highlightCode(widget.code.trimRight(), widget.language);
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(t.Motion.fast);
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final span = _highlighted();
    return TranscriptCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            height: t.Controls.standard,
            padding: t.Controls.padStandard,
            decoration: BoxDecoration(
              color: t.Neutral.panel,
              border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width)),
            ),
            child: Row(
              children: <Widget>[
                Text(widget.language ?? 'text', style: t.TextStyles.monoMeta),
                const Spacer(),
                if (_copied)
                  Container(
                    height: t.Controls.compact,
                    padding: t.Controls.padCompact,
                    decoration: BoxDecoration(color: t.Semantic.successSoft, borderRadius: t.Radii.control),
                    child: Row(
                      children: <Widget>[
                        AcpIcon(AcpIcons.check, color: t.Semantic.success, size: t.IconSizes.toolbar),
                        const SizedBox(width: t.Spacing.s4),
                        Text('Copied', style: CardText.secondary.copyWith(color: t.Semantic.success)),
                      ],
                    ),
                  )
                else
                  AcpButton(label: 'Copy', icon: AcpIcons.copy, iconColor: t.Neutral.muted, labelColor: t.Neutral.muted, height: t.Controls.compact, onTap: _copy),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(t.Spacing.s12),
            child: Text.rich(span, softWrap: false),
          ),
        ],
      ),
    );
  }
}
