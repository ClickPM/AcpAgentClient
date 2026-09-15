// 画板 30 · 上下文窗口浮窗：usage_update（used / size / cost?）。输入框左下的圆环 + 百分比；悬浮弹层 Context（+ Cost）+ Rules
// （Rules = 项目根规则文件计数，R3 从文件系统来，这里只接数字）。usage_update 是会话级上下文窗口，不是每轮增量。

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../projection/usage.dart';
import '../../theme/tokens.dart' as t;
import 'card_chrome.dart';
import 'icons.dart';

/// 16px 圆环：轨道 subtle、进度 accent，从 12 点起顺时针。
class UsageRing extends StatelessWidget {
  const UsageRing({super.key, required this.fraction, this.size = t.IconSizes.base});

  final double fraction;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _RingPainter(fraction));
}

class _RingPainter extends CustomPainter {
  const _RingPainter(this.fraction);

  final double fraction;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = t.IconSizes.stroke;
    final rect = Offset.zero & size;
    final r = rect.deflate(stroke);
    final track = Paint()
      ..color = t.Borders.subtle
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    final fill = Paint()
      ..color = t.Accent.base
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke;
    canvas.drawOval(r, track);
    canvas.drawArc(r, -math.pi / 2, 2 * math.pi * fraction.clamp(0, 1), false, fill);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fraction != fraction;
}

/// 圆环 + 百分比（画板 30 输入框左下）。
class UsageIndicator extends StatelessWidget {
  const UsageIndicator({super.key, required this.usage, this.onTap});

  final UsageState? usage;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final u = usage;
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            UsageRing(fraction: u?.fraction ?? 0),
            const SizedBox(width: t.Spacing.s4),
            Text(u == null ? '—' : '${u.percent}%', style: CardText.secondary),
          ],
        ),
      ),
    );
  }
}

/// 输入框左下那一条（gallery 用：+ · 圆环 · 百分比，panel 底）。
class ComposerUsageStrip extends StatelessWidget {
  const ComposerUsageStrip({super.key, required this.usage});

  final UsageState? usage;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: t.Controls.input + t.Spacing.s16,
      decoration: BoxDecoration(
        color: t.Neutral.panel,
        borderRadius: t.Radii.card,
        border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
      ),
      padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s16),
      child: Row(
        children: <Widget>[
          const AcpIcon(AcpIcons.plus, color: t.Neutral.placeholder),
          const SizedBox(width: t.Spacing.s12),
          UsageIndicator(usage: usage),
        ],
      ),
    );
  }
}

/// 悬浮弹层：Context / Cost（有费用时）/ Rules。
class ContextPopover extends StatelessWidget {
  const ContextPopover({super.key, required this.usage, this.rulesCount = 0, this.onOpenRules});

  final UsageState? usage;
  final int rulesCount;
  final VoidCallback? onOpenRules;

  /// 弹层宽度（几何，不是样式）。
  static const double _width = 266;

  @override
  Widget build(BuildContext context) {
    final u = usage;
    final context_ = u == null ? '—' : '${u.percent}% · ${UsageState.compact(u.used)} / ${UsageState.compact(u.size)}';
    return Popover(
      radius: t.Radii.card,
      padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s16, vertical: t.Spacing.s12),
      child: SizedBox(
        width: _width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text('Context', style: t.TextStyles.secondary),
            Text(context_, style: t.TextStyles.body),
            if (u != null && u.hasCost) ...<Widget>[
              const SizedBox(height: t.Spacing.s8),
              const Text('Cost', style: t.TextStyles.secondary),
              Text('\$${u.costAmount} ${u.costCurrency ?? ''}', style: t.TextStyles.body),
            ],
            const SizedBox(height: t.Spacing.s8),
            const Text('Rules', style: t.TextStyles.secondary),
            GestureDetector(
              onTap: onOpenRules,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text('$rulesCount global rule${rulesCount == 1 ? '' : 's'}', style: CardText.link),
                    const SizedBox(width: t.Spacing.s4),
                    const AcpIcon(AcpIcons.arrowUpRight, color: t.Accent.text, size: t.IconSizes.toolbar),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
