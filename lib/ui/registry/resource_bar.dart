// 画板 54 A / C · Agents 面板顶部的资源概览条（R10）：
// 展示本应用及其全部子进程的内存合计、口径名与悬停说明、三段比例条（本应用 / Agents / 终端）与图例；
// 另有 C1（没有 agent 在运行）、C2（首次采样中）、C3（采样失败，停表等手动重试）三态。样式只取 tokens（规则 3）。

import 'package:flutter/widgets.dart';

import '../../projection/process_snapshot.dart';
import '../../theme/tokens.dart' as t;
import '../format.dart';
import '../shell/shell_common.dart';
import '../shell/tooltip.dart';
import '../transcript/icons.dart';

class ResourceBar extends StatelessWidget {
  // ignore: prefer_const_constructors_in_immutables
  ResourceBar({super.key, this.snapshot, this.error, this.onRetry});

  /// 最新一次采样快照；为 null 且 [error] 为 null 时显示 C2「首次采样中」。
  final ProcessSnapshot? snapshot;

  /// 采样失败信息；非空时显示 C3「无法读取进程信息」并停表等待手动点刷新重试。
  final String? error;

  /// C3 采样失败时点刷新图标重试。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final snap = snapshot;
    final failed = error != null;
    return Container(
      padding: t.Resource.padding,
      decoration: BoxDecoration(
        color: t.Neutral.panel,
        border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
        borderRadius: t.Radii.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _topRow(snap, failed: failed),
          const SizedBox(height: t.Spacing.s8),
          _bar(snap, failed: failed),
          const SizedBox(height: t.Spacing.s8),
          _legendRow(snap, failed: failed),
        ],
      ),
    );
  }

  Widget _topRow(ProcessSnapshot? snap, {required bool failed}) {
    final hasData = !failed && snap != null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Text('本机内存', style: t.TextStyles.secondary),
        const SizedBox(width: t.Spacing.s8),
        Text(
          hasData ? '约 ${formatBytes(snap.totalBytes)}' : '—',
          style: hasData
              ? t.TextStyles.title
              : t.TextStyles.title.copyWith(color: t.Neutral.placeholder),
        ),
        const Spacer(),
        if (failed)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '无法读取进程信息',
                style: t.TextStyles.meta.copyWith(color: t.Neutral.muted),
              ),
              const SizedBox(width: t.Resource.gap),
              Hoverable(
                onTap: onRetry,
                builder: (context, hovered) => AcpIcon(
                  AcpIcons.rotateCw,
                  size: t.Resource.iconSize,
                  color: hovered ? t.Neutral.text : t.Neutral.muted,
                ),
              ),
            ],
          )
        else if (snap == null)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Spinner(size: t.Resource.iconSize),
              const SizedBox(width: t.Spacing.s4),
              Text('采样中…', style: t.TextStyles.meta),
            ],
          )
        else
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(snap.metricSummary, style: t.TextStyles.meta),
              const SizedBox(width: t.Spacing.s4),
              AcpTooltip(
                message: snap.metricTooltip,
                child: AcpIcon(
                  AcpIcons.info,
                  size: t.Resource.iconSize,
                  color: t.Neutral.placeholder,
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _bar(ProcessSnapshot? snap, {required bool failed}) {
    final segments = !failed && snap != null
        ? snap.barSegments
        : const <ResourceBarSegment>[];
    if (segments.isEmpty) {
      return Container(
        height: t.Resource.barHeight,
        decoration: BoxDecoration(
          color: t.Borders.subtle,
          borderRadius: t.Resource.barRadius,
        ),
      );
    }
    final total = snap!.totalBytes;
    return ClipRRect(
      borderRadius: t.Resource.barRadius,
      child: Container(
        height: t.Resource.barHeight,
        color: t.Borders.subtle,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final seg in segments)
              Expanded(
                flex: _flexOf(seg.bytes, total),
                child: ColoredBox(color: _segmentColor(seg.kind)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _legendRow(ProcessSnapshot? snap, {required bool failed}) {
    if (failed) {
      return Text('原因写进日志；Stop 不受影响', style: t.TextStyles.meta);
    }
    if (snap == null) {
      // C2：图例行留高不留字，采到后不跳布局。
      return Text('', style: t.TextStyles.meta);
    }
    final running = snap.runningAgentCount;
    return Wrap(
      spacing: t.Spacing.s16,
      runSpacing: t.Spacing.s4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        _legendItem(
          color: t.Neutral.placeholder,
          label: '本应用 ${formatBytes(snap.appBytes)}',
          textColor: t.Neutral.muted,
        ),
        _legendItem(
          color: t.Accent.base,
          label: running > 0
              ? 'Agents · $running 个运行中 · ${formatBytes(snap.agentsBytes)}'
              : 'Agents · 无运行',
          textColor: running > 0 ? t.Neutral.muted : t.Neutral.placeholder,
        ),
        if (snap.showTerminalsLegend)
          _legendItem(
            color: t.Neutral.border,
            label:
                '终端 · ${snap.terminalCount} 个 · ${formatBytes(snap.terminalsBytes)}',
            textColor: t.Neutral.muted,
          ),
      ],
    );
  }

  Widget _legendItem({
    required Color color,
    required String label,
    required Color textColor,
  }) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Container(
        width: t.Resource.legendSwatch,
        height: t.Resource.legendSwatch,
        decoration: BoxDecoration(
          color: color,
          borderRadius: t.Resource.barRadius,
        ),
      ),
      const SizedBox(width: t.Resource.gap),
      Text(label, style: t.TextStyles.meta.copyWith(color: textColor)),
    ],
  );

  static Color _segmentColor(ResourceSegmentKind kind) => switch (kind) {
    ResourceSegmentKind.app => t.Neutral.placeholder,
    ResourceSegmentKind.agents => t.Accent.base,
    ResourceSegmentKind.terminals => t.Neutral.border,
  };

  static int _flexOf(int bytes, int total) {
    if (total <= 0 || bytes <= 0) return 1;
    return (bytes * 10000 ~/ total).clamp(1, 10000);
  }
}
