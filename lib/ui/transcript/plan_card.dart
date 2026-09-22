// 画板 29 · 计划卡：稳定 plan（整份替换、无 id）与 unstable plan_update（items / file / markdown，带 planId）、plan_removed。
// 展开 = Plan · N Tasks · done/N，条目带 status 图标与 priority 徽章；折叠 = Current: … · N left（停靠在输入框上方）；
// file 载荷 = 文件链接（在右栏文件面板打开，R4）；markdown 载荷 = 正文；removed = 「该计划已被 agent 移除」；✕ 只隐藏本地呈现。

import 'package:flutter/widgets.dart';

import '../../projection/entries.dart';
import '../../theme/tokens.dart' as t;
import 'card_chrome.dart';
import 'icons.dart';
import 'markdown_body.dart';
import 'tool_call_card.dart';

class PlanCard extends StatefulWidget {
  const PlanCard(this.entry, {super.key, this.initiallyCollapsed = false, this.cwd, this.onDismiss, this.onOpenFile});

  final PlanCardEntry entry;
  final bool initiallyCollapsed;
  final String? cwd;
  final VoidCallback? onDismiss;
  final void Function(String uri)? onOpenFile;

  @override
  State<PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<PlanCard> {
  late bool _collapsed = widget.initiallyCollapsed;

  @override
  Widget build(BuildContext context) {
    final p = widget.entry;
    if (p.removed) return _removed(p);
    return switch (p.type) {
      PlanPayloadType.items => _collapsed ? _collapsedBar(p) : _items(p),
      PlanPayloadType.file => _file(p),
      PlanPayloadType.markdown => _markdown(p),
    };
  }

  Widget _title(PlanCardEntry p) => Text('Plan', style: CardText.cardTitle);

  Widget _planId(PlanCardEntry p, {String? suffix}) =>
      Text(p.isStable ? '' : (suffix == null ? p.planId : 'planId ${p.planId} · $suffix'), style: t.TextStyles.monoMeta);

  Widget _items(PlanCardEntry p) {
    return TranscriptCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CardHeader(
            leading: Chevron(expanded: true),
            title: 'Plan',
            titleStyle: CardText.cardTitle,
            subtitleWidget: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (!p.isStable) ...<Widget>[Text(p.planId, style: t.TextStyles.monoMeta), const SizedBox(width: t.Spacing.s8)],
                Text('${p.items.length} Tasks', style: CardText.secondary),
                const SizedBox(width: t.Spacing.s8),
                Text('${p.completedCount}/${p.items.length}', style: t.TextStyles.monoMeta),
              ],
            ),
            trailing: <Widget>[IconButtonGhost(icon: AcpIcons.x, size: t.Controls.compact, onTap: widget.onDismiss)],
            onTap: () => setState(() => _collapsed = true),
          ),
          Container(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
            padding: const EdgeInsets.symmetric(vertical: t.Spacing.s4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[for (final i in p.items) _itemRow(i)],
            ),
          ),
        ],
      ),
    );
  }

  Widget _itemRow(PlanItem i) {
    final done = i.status == PlanItemStatus.completed;
    final icon = switch (i.status) {
      PlanItemStatus.completed => AcpIcon(AcpIcons.checkCircle, color: t.Semantic.success, size: t.IconSizes.toolbar),
      PlanItemStatus.inProgress => Spinner(),
      _ => AcpIcon(AcpIcons.dashedCircle, color: t.Neutral.placeholder, size: t.IconSizes.toolbar),
    };
    final tone = switch (i.priority) {
      PlanPriority.high => ChipTone.warning,
      _ => ChipTone.neutral,
    };
    return SizedBox(
      height: t.Controls.standard,
      child: Padding(
        padding: t.Controls.padInput,
        child: Row(
          children: <Widget>[
            icon,
            const SizedBox(width: t.Spacing.s8),
            Expanded(
              child: Text(
                i.content,
                style: done ? CardText.headerTitle.copyWith(color: t.Neutral.muted, decoration: TextDecoration.lineThrough) : CardText.headerTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (i.priority != PlanPriority.unknown) ToneChip(i.priority.wire, tone: tone),
          ],
        ),
      ),
    );
  }

  Widget _collapsedBar(PlanCardEntry p) {
    final current = p.current;
    return Container(
      height: t.Controls.input,
      decoration: BoxDecoration(color: t.Neutral.panel, borderRadius: t.Radii.card),
      padding: t.Controls.padInput,
      child: Row(
        children: <Widget>[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _collapsed = false),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Chevron(expanded: false),
                const SizedBox(width: t.Spacing.s8),
                _title(p),
                if (!p.isStable) ...<Widget>[const SizedBox(width: t.Spacing.s8), Text(p.planId, style: t.TextStyles.monoMeta)],
              ],
            ),
          ),
          const SizedBox(width: t.Spacing.s8),
          Expanded(
            child: Text(current == null ? '全部完成' : 'Current: ${current.content}', style: CardText.headerTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: t.Spacing.s8),
          Text('${p.leftCount} left', style: CardText.secondary),
          const SizedBox(width: t.Spacing.s4),
          IconButtonGhost(icon: AcpIcons.x, size: t.Controls.compact, onTap: widget.onDismiss),
        ],
      ),
    );
  }

  Widget _file(PlanCardEntry p) {
    final uri = p.uri ?? '';
    final path = displayPath(uri, cwd: widget.cwd);
    return TranscriptCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CardHeader(title: 'Plan', titleStyle: CardText.cardTitle, subtitleWidget: _planId(p, suffix: 'file')),
          Container(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
            height: t.Controls.input,
            padding: t.Controls.padInput,
            child: Row(
              children: <Widget>[
                AcpIcon(AcpIcons.file, color: t.Neutral.muted),
                const SizedBox(width: t.Spacing.s8),
                GestureDetector(
                  onTap: uri.isEmpty ? null : () => widget.onOpenFile?.call(uri),
                  child: MouseRegion(cursor: SystemMouseCursors.click, child: Text(path, style: CardText.link)),
                ),
                const SizedBox(width: t.Spacing.s8),
                Text('在右栏文件面板打开', style: CardText.secondary),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _markdown(PlanCardEntry p) {
    return TranscriptCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CardHeader(title: 'Plan', titleStyle: CardText.cardTitle, subtitleWidget: _planId(p, suffix: 'markdown')),
          CardBody(
            padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
            children: <Widget>[MarkdownBody(p.markdown ?? '')],
          ),
        ],
      ),
    );
  }

  Widget _removed(PlanCardEntry p) {
    return Container(
      height: t.Controls.input,
      decoration: BoxDecoration(color: t.Neutral.panel, borderRadius: t.Radii.card),
      padding: t.Controls.padInput,
      child: Row(
        children: <Widget>[
          Text('plan_removed · planId ${p.planId}', style: t.TextStyles.monoMeta),
          const SizedBox(width: t.Spacing.s12),
          Text('该计划已被 agent 移除', style: CardText.secondary),
        ],
      ),
    );
  }
}
