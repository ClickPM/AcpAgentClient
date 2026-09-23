// 画板 08 C / 09 B · 工作区切换器上的两枚计数徽标：
// - 在跑数（08 C）：11px 循环箭头 + 数字，accent 文字配 `badge.accent.bg` 底；
// - 等你处理数（09 B）：11px 三角警示 + 数字，warning 文字配 warningSoft 底（按会话数，不分 permission / elicitation）。
// 出现在项目切换钮（全部工作区合计）与切换器每一行（该工作区各自的数）上；两枚并排时等你在左、在跑在右（[ActivityBadges]）。
//
// 图标**静态不旋转**（linear 动效在本系统只留给画板 06 的扫掠），数字直切不做过渡，
// 为 0 一律不渲染（调用方用 `maybe`，不留占位）。

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import '../transcript/icons.dart';
import 'tooltip.dart';

class RunningBadge extends StatelessWidget {
  const RunningBadge(this.count, {super.key});

  final int count;

  /// 为 0 就不渲染（画板：无徽标、无灰底 0、不留占位）。
  static Widget? maybe(int count) => count <= 0 ? null : RunningBadge(count);

  /// 两位数照排、宽度自增；> 99 显示 `99+`。
  static String label(int count) => count > t.Badge.overflowAt ? '${t.Badge.overflowAt}+' : '$count';

  @override
  Widget build(BuildContext context) =>
      _CountBadge(count: count, icon: AcpIcons.rotateCw, color: t.Accent.text, background: t.Badge.accentBg);
}

/// 画板 09 B：等你处理的会话数。
class AwaitingBadge extends StatelessWidget {
  const AwaitingBadge(this.count, {super.key});

  final int count;

  static Widget? maybe(int count) => count <= 0 ? null : AwaitingBadge(count);

  @override
  Widget build(BuildContext context) =>
      _CountBadge(count: count, icon: AcpIcons.alertTriangle, color: t.Badge.warningFg, background: t.Badge.warningBg);
}

/// 画板 09 B 的并排：等你在左、在跑在右，间距 [t.Badge.pairGap]；为 0 的那枚不渲染、不占位。
/// 给了 tooltip 文案就各自挂一条（切换器的行内；触发钮那边整句挂在钮上，这里不给）。
class ActivityBadges extends StatelessWidget {
  const ActivityBadges({super.key, required this.awaiting, required this.running, this.awaitingTooltip, this.runningTooltip});

  final int awaiting;
  final int running;
  final String? awaitingTooltip;
  final String? runningTooltip;

  /// 两枚都为 0 时整组不渲染。
  static Widget? maybe({required int awaiting, required int running, String? awaitingTooltip, String? runningTooltip}) =>
      awaiting <= 0 && running <= 0
          ? null
          : ActivityBadges(awaiting: awaiting, running: running, awaitingTooltip: awaitingTooltip, runningTooltip: runningTooltip);

  @override
  Widget build(BuildContext context) {
    Widget tip(Widget badge, String? message) => message == null ? badge : AcpTooltip(message: message, child: badge);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (awaiting > 0) tip(AwaitingBadge(awaiting), awaitingTooltip),
        if (awaiting > 0 && running > 0) const SizedBox(width: t.Badge.pairGap),
        if (running > 0) tip(RunningBadge(running), runningTooltip),
      ],
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count, required this.icon, required this.color, required this.background});

  final int count;
  final String icon;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) => Container(
        height: t.Badge.height,
        padding: t.Badge.padding,
        decoration: BoxDecoration(color: background, borderRadius: t.Badge.radius),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AcpIcon(icon, color: color, size: t.Badge.iconSize, strokeWidth: t.Badge.iconStroke),
            const SizedBox(width: t.Badge.gap),
            Text(
              RunningBadge.label(count),
              style: t.TextStyles.monoMeta.copyWith(
                color: color,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      );
}
