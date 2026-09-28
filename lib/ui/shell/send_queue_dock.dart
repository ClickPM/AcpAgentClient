// 画板 44 · Send Queue：回合进行中的本地发送队列停靠条（输入框上方 docks 区）。
// 折叠态：显示「N 条排队消息」与展开/清空；Paused 态提示告警与恢复；AbsorbingCancel 提示打断插队中。
// 展开态：排队消息卡片列表，支持 Send Now 快速插队、挪回输入框编辑与删除。

import 'package:flutter/widgets.dart';

import '../../app/send_queue.dart';
import '../../projection/wire.dart';
import '../../theme/tokens.dart' as t;
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';

/// 输入框上方的发送队列停靠条。
class SendQueueDock extends StatelessWidget {
  const SendQueueDock({
    super.key,
    required this.queue,
    this.onSendNow,
    this.onEdit,
    this.onRemove,
    this.onClearAll,
    this.onResume,
  });

  final SendQueue queue;
  final ValueChanged<int>? onSendNow;
  final ValueChanged<int>? onEdit;
  final ValueChanged<int>? onRemove;
  final VoidCallback? onClearAll;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: queue,
      builder: (context, _) {
        if (queue.isEmpty) return const SizedBox.shrink();
        if (queue.isExpanded) {
          return _buildExpandedCard();
        }
        return _buildCollapsedBar();
      },
    );
  }

  /// 折叠态的停靠条（三种运行状态）。
  Widget _buildCollapsedBar() {
    final isPaused = queue.isPaused;
    final isAbsorbing = queue.isAbsorbingCancel;

    final Color bgColor = isPaused
        ? t.Semantic.warningSoft
        : (isAbsorbing ? t.Accent.soft : t.Neutral.panel);
    final Color borderColor = isPaused
        ? t.Semantic.warning
        : (isAbsorbing ? t.Accent.base : t.Borders.subtle);

    final Widget leadingIcon;
    final Widget titleWidget;

    if (isPaused) {
      leadingIcon = AcpIcon(AcpIcons.alertTriangle, color: t.Semantic.warning);
      titleWidget = Text(
        '队列已暂停 · ${queue.length} 条排队消息',
        style: t.TextStyles.label.copyWith(color: t.Semantic.warning),
      );
    } else if (isAbsorbing) {
      leadingIcon = Spinner(color: t.Accent.base);
      titleWidget = Text(
        '正在打断当前回合并发送...',
        style: t.TextStyles.label.copyWith(color: t.Accent.base),
      );
    } else {
      leadingIcon = AcpIcon(AcpIcons.list, color: t.Accent.base);
      titleWidget = Text(
        '${queue.length} 条排队消息',
        style: t.TextStyles.label.copyWith(color: t.Neutral.text),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        border: Border.all(color: borderColor, width: t.Borders.width),
        borderRadius: t.Radii.card,
      ),
      padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
      child: Row(
        children: <Widget>[
          leadingIcon,
          const SizedBox(width: t.Spacing.s8),
          Expanded(child: titleWidget),
          const SizedBox(width: t.Spacing.s8),
          if (isPaused) ...<Widget>[
            AcpButton(
              label: '恢复出队',
              kind: ButtonKind.primary,
              height: t.Controls.compact,
              onTap: onResume,
            ),
            const SizedBox(width: t.Spacing.s4),
            AcpButton(
              label: '清空',
              kind: ButtonKind.ghost,
              labelColor: t.Semantic.error,
              height: t.Controls.compact,
              onTap: onClearAll,
            ),
          ] else if (!isAbsorbing) ...<Widget>[
            AcpButton(
              label: '展开',
              kind: ButtonKind.ghost,
              trailing: AcpIcon(AcpIcons.chevronDown, color: t.Neutral.muted, size: t.IconSizes.toolbar),
              height: t.Controls.compact,
              onTap: queue.toggleExpanded,
            ),
            const SizedBox(width: t.Spacing.s4),
            AcpButton(
              label: '全部清空',
              kind: ButtonKind.ghost,
              labelColor: t.Semantic.error,
              height: t.Controls.compact,
              onTap: onClearAll,
            ),
          ],
        ],
      ),
    );
  }

  /// 展开态卡片面板。
  Widget _buildExpandedCard() {
    final entries = queue.entries;
    return Container(
      decoration: BoxDecoration(
        color: t.Neutral.panel,
        border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
        borderRadius: t.Radii.card,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s4),
            decoration: BoxDecoration(
              color: t.Neutral.panel,
              border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width)),
            ),
            child: Row(
              children: <Widget>[
                AcpIcon(AcpIcons.list, color: t.Accent.base),
                const SizedBox(width: t.Spacing.s8),
                Text(
                  '${queue.length} 条排队消息',
                  style: t.TextStyles.label.copyWith(color: t.Neutral.strong),
                ),
                const Spacer(),
                AcpButton(
                  label: '全部清空',
                  kind: ButtonKind.ghost,
                  labelColor: t.Semantic.error,
                  height: t.Controls.compact,
                  onTap: onClearAll,
                ),
                const SizedBox(width: t.Spacing.s4),
                AcpButton(
                  label: '收起',
                  kind: ButtonKind.ghost,
                  trailing: AcpIcon(AcpIcons.chevronUp, color: t.Neutral.muted, size: t.IconSizes.toolbar),
                  height: t.Controls.compact,
                  onTap: queue.toggleExpanded,
                ),
              ],
            ),
          ),
          // Entries list
          for (var i = 0; i < entries.length; i++)
            _buildEntryItem(entries[i], i, isLast: i == entries.length - 1),
        ],
      ),
    );
  }

  Widget _buildEntryItem(QueueEntry entry, int index, {required bool isLast}) {
    final attachments = entry.attachmentBlocks;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
      decoration: BoxDecoration(
        color: t.Neutral.canvas,
        border: isLast
            ? null
            : Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: t.Spacing.s4),
            child: SizedBox(
              width: t.Spacing.s24,
              child: Text(
                '#${index + 1}',
                style: t.TextStyles.labelTabular.copyWith(color: t.Neutral.muted),
              ),
            ),
          ),
          const SizedBox(width: t.Spacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (entry.plainText.isNotEmpty)
                  Text(entry.plainText, style: t.TextStyles.body),
                if (attachments.isNotEmpty) ...<Widget>[
                  const SizedBox(height: t.Spacing.s4),
                  Wrap(
                    spacing: t.Spacing.s4,
                    runSpacing: t.Spacing.s4,
                    children: <Widget>[
                      for (final a in attachments) _buildChip(a),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: t.Spacing.s8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AcpButton(
                label: 'Send Now',
                kind: ButtonKind.primary,
                icon: AcpIcons.play,
                kbd: '⏎',
                enabled: !queue.isAbsorbingCancel,
                height: t.Controls.compact,
                onTap: (onSendNow == null || queue.isAbsorbingCancel) ? null : () => onSendNow!(entry.id),
              ),
              const SizedBox(width: t.Spacing.s4),
              IconButtonGhost(
                icon: AcpIcons.pencil,
                size: t.Controls.compact,
                color: t.Neutral.muted,
                onTap: onEdit == null ? null : () => onEdit!(entry.id),
              ),
              const SizedBox(width: t.Spacing.s4),
              IconButtonGhost(
                icon: AcpIcons.trash,
                size: t.Controls.compact,
                color: t.Semantic.error,
                onTap: onRemove == null ? null : () => onRemove!(entry.id),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChip(JsonMap block) {
    final type = block['type'] as String? ?? 'attachment';
    final String label;
    final String icon;
    if (type == 'image') {
      icon = AcpIcons.image;
      final uri = block['uri'] as String?;
      label = uri != null ? _baseName(uri) : 'image';
    } else {
      icon = AcpIcons.file;
      label = block['name'] as String? ?? (block['uri'] != null ? _baseName(block['uri'] as String) : 'file');
    }
    return Container(
      decoration: BoxDecoration(
        color: t.Neutral.panel,
        border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
        borderRadius: t.Radii.chip,
      ),
      padding: t.Spacing.chip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AcpIcon(icon, color: t.Accent.base, size: t.IconSizes.toolbar),
          const SizedBox(width: t.Spacing.s4),
          Text(
            label,
            style: t.TextStyles.label.copyWith(color: t.Accent.text),
          ),
        ],
      ),
    );
  }

  static String _baseName(String uri) {
    final parts = uri.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty);
    return parts.isEmpty ? uri : parts.last;
  }
}
