// 画板 16 · 数学公式：行内（与正文基线对齐）与块级（居中、上下各留 12、发丝线与正文分隔）；flutter_math_fork，
// 错误公式经 onErrorFallback 回落源码态（error 色）。`$…$` / `$$…$$` 的识别在 markdown_body.dart 的 InlineSyntax。

import 'package:flutter/widgets.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../../theme/tokens.dart' as t;
import 'card_chrome.dart';

class MathBlock extends StatelessWidget {
  const MathBlock(this.tex, {super.key});

  final String tex;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: t.Borders.subtle, width: t.Borders.width),
          bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: t.Spacing.s12),
      alignment: Alignment.center,
      child: Math.tex(
        tex,
        mathStyle: MathStyle.display,
        textStyle: t.TextStyles.body.copyWith(fontFeatures: const <FontFeature>[FontFeature.tabularFigures()]),
        onErrorFallback: (err) => Text(tex, style: CardText.codeError),
      ),
    );
  }
}

/// 行内公式（WidgetSpan 里用）。
class MathInline extends StatelessWidget {
  const MathInline(this.tex, {super.key, required this.base});

  final String tex;
  final TextStyle base;

  @override
  Widget build(BuildContext context) {
    return Math.tex(
      tex,
      mathStyle: MathStyle.text,
      textStyle: base,
      onErrorFallback: (err) => Text(tex, style: CardText.codeError),
    );
  }
}
