// gallery 的画板页骨架：复刻设计画板的版式（标题行 + 协议来源说明 / 分节标签 / 底部注释），把画板 widget 摆进去，
// 这样 build/gallery/NN-*.png 与 design/round-design/NN-*.png 能逐段并排看。只在 debug / test 编入。样式只取 tokens。

import 'package:flutter/widgets.dart';

import '../theme/tokens.dart' as t;

/// 画板宽 800（canvas.json），内边距 24，分节间距 16。
class BoardPage extends StatelessWidget {
  const BoardPage({super.key, required this.number, required this.title, required this.source, required this.sections, this.footnote});

  final String number;
  final String title;
  final String source;
  final List<BoardSection> sections;
  final String? footnote;

  static const double width = 800;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      color: t.Surface.canvas,
      padding: const EdgeInsets.all(t.Spacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.only(bottom: t.Spacing.s8),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: <Widget>[
                Text('$number · $title', style: t.TextStyles.title),
                const SizedBox(width: t.Spacing.s12),
                Expanded(child: Text('协议来源：$source', style: t.TextStyles.meta)),
              ],
            ),
          ),
          for (final s in sections) ...<Widget>[
            const SizedBox(height: t.Spacing.s16),
            s,
          ],
          if (footnote != null) ...<Widget>[
            const SizedBox(height: t.Spacing.s16),
            Text(footnote!, style: t.TextStyles.monoMeta),
          ],
        ],
      ),
    );
  }
}

/// 分节：11 / 500 / letter-spacing 的标签 + 内容。
class BoardSection extends StatelessWidget {
  const BoardSection(this.label, {super.key, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label, style: t.TextStyles.label),
        const SizedBox(height: t.Spacing.s8),
        child,
      ],
    );
  }
}

/// 多个卡片竖排，间距 8。
class BoardStack extends StatelessWidget {
  const BoardStack(this.children, {super.key, this.gap = t.Spacing.s8});

  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var i = 0; i < children.length; i++) ...<Widget>[
          if (i > 0) SizedBox(height: gap),
          children[i],
        ],
      ],
    );
  }
}
