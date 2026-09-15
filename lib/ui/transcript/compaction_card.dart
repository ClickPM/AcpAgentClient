// 画板 33 · 上下文压缩卡：compaction_update（status / summary? / error?）· compaction_summary_chunk。
// in_progress（尚无摘要）→ 摘要流式追加 → completed → failed（error.soft 等宽块）。协议状态值是 failed（画板写的 error 是同一态）。
// unstable 变体，需客户端声明 session.compaction（已裁定声明）；摘要按 chunk 追加，卡片高度随之增长。

import 'package:flutter/widgets.dart';

import '../../projection/entries.dart';
import '../../theme/tokens.dart' as t;
import 'card_chrome.dart';
import 'icons.dart';

class CompactionCard extends StatefulWidget {
  const CompactionCard(this.entry, {super.key, this.initiallyExpanded});

  final CompactionEntry entry;

  /// 缺省：有摘要 / 错误时展开，否则折叠。
  final bool? initiallyExpanded;

  @override
  State<CompactionCard> createState() => _CompactionCardState();
}

class _CompactionCardState extends State<CompactionCard> {
  late bool _expanded = widget.initiallyExpanded ?? (widget.entry.summaryText.isNotEmpty || widget.entry.error != null);

  @override
  Widget build(BuildContext context) {
    final c = widget.entry;
    final inProgress = c.status == 'in_progress';
    final failed = c.status == 'failed';
    final Widget icon = inProgress
        ? const Spinner()
        : failed
            ? const AcpIcon(AcpIcons.x, color: t.Semantic.error, size: t.IconSizes.toolbar)
            : c.status == 'completed'
                ? const AcpIcon(AcpIcons.checkCircle, color: t.Semantic.success, size: t.IconSizes.toolbar)
                : const AcpIcon(AcpIcons.dashedCircle, color: t.Neutral.placeholder, size: t.IconSizes.toolbar);
    final summary = c.summaryText;
    final hasBody = summary.isNotEmpty || c.error != null;
    return TranscriptCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CardHeader(
            leading: icon,
            title: '上下文压缩',
            subtitleWidget: Text('compactionId ${c.compactionId} · status: ${c.status}', style: t.TextStyles.monoMeta, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: <Widget>[Chevron(expanded: _expanded)],
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded && hasBody)
            CardBody(
              padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
              children: <Widget>[
                if (c.error != null)
                  MonoBlock(text: c.error, background: t.Semantic.errorSoft, style: CardText.codeError)
                else
                  Text.rich(
                    TextSpan(children: <InlineSpan>[
                      TextSpan(text: summary),
                      // 流式中的插入符：accent 竖线。
                      if (inProgress) const TextSpan(text: '|', style: TextStyle(color: t.Accent.base)),
                    ]),
                    style: t.TextStyles.body,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
