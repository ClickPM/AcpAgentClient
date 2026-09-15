// 画板 17 · 思考折叠块：流式中（spinner + Thinking...）/ 结束折叠（灯泡 + Thought for N seconds）/ 展开（卡片 + 正文）。
// 折叠单元与耗时都是客户端本地态（ThoughtEntry.closed / elapsed）。

import 'package:flutter/widgets.dart';

import '../../projection/entries.dart';
import '../../theme/tokens.dart' as t;
import 'card_chrome.dart';
import 'icons.dart';
import 'markdown_body.dart';

class ThinkingBlock extends StatefulWidget {
  const ThinkingBlock(this.entry, {super.key, this.initiallyExpanded = false, this.streaming});

  final ThoughtEntry entry;
  final bool initiallyExpanded;

  /// 缺省按 entry.closed 判；gallery 可强制。
  final bool? streaming;

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  late bool _expanded = widget.initiallyExpanded;

  static String label(Duration d) {
    final s = d.inMilliseconds / 1000;
    if (s < 1) return 'Thought for less than a second';
    final n = s.round();
    return 'Thought for $n second${n == 1 ? '' : 's'}';
  }

  @override
  Widget build(BuildContext context) {
    final streaming = widget.streaming ?? !widget.entry.closed;
    final title = streaming ? 'Thinking...' : label(widget.entry.elapsed);
    final leading = streaming ? const Spinner(size: t.IconSizes.base) : const AcpIcon(AcpIcons.lightbulb, color: t.Neutral.muted);
    if (!_expanded) {
      return CardHeader(
        leading: leading,
        title: title,
        titleStyle: streaming ? CardText.headerTitle : CardText.headerTitle.copyWith(color: t.Neutral.muted),
        trailing: const <Widget>[Chevron(expanded: false)],
        onTap: () => setState(() => _expanded = true),
        height: t.Controls.standard,
      );
    }
    return TranscriptCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CardHeader(
            leading: leading,
            title: title,
            titleStyle: CardText.headerTitle.copyWith(color: t.Neutral.muted),
            trailing: const <Widget>[Chevron(expanded: true)],
            onTap: () => setState(() => _expanded = false),
          ),
          CardBody(
            padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s16, vertical: t.Spacing.s12),
            children: <Widget>[MarkdownBody(widget.entry.text)],
          ),
        ],
      ),
    );
  }
}
