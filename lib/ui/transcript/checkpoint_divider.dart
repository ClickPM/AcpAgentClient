// 画板 10 · Restore Checkpoint 分隔线：轮边界处的一条线 + 居中按钮（默认 muted 文字；悬浮加 6% 叠色、文字转深）。
// 点一下丢弃其后全部投影块（SessionStore.restoreTo）并在同一会话重发该轮 prompt（R3 接线）。

import 'package:flutter/widgets.dart';

import '../../projection/entries.dart';
import '../../theme/tokens.dart' as t;
import 'card_chrome.dart';
import 'icons.dart';

class CheckpointDivider extends StatefulWidget {
  const CheckpointDivider({super.key, this.turn, this.onRestore, this.hoveredInitially = false});

  final TurnEntry? turn;
  final VoidCallback? onRestore;
  final bool hoveredInitially;

  @override
  State<CheckpointDivider> createState() => _CheckpointDividerState();
}

class _CheckpointDividerState extends State<CheckpointDivider> {
  late bool _hover = widget.hoveredInitially;

  @override
  Widget build(BuildContext context) {
    final fg = _hover ? t.Neutral.text : t.Neutral.muted;
    return SizedBox(
      height: t.Controls.standard,
      child: Row(
        children: <Widget>[
          const Expanded(child: SizedBox(height: t.Borders.width, child: ColoredBox(color: t.Borders.subtle))),
          const SizedBox(width: t.Spacing.s8),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = widget.hoveredInitially),
            child: GestureDetector(
              onTap: widget.onRestore,
              child: Container(
                height: t.Controls.compact,
                padding: t.Controls.padCompact,
                decoration: BoxDecoration(color: _hover ? t.Overlays.hover : null, borderRadius: t.Radii.control),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    AcpIcon(AcpIcons.rotateCcw, color: fg, size: t.IconSizes.toolbar),
                    const SizedBox(width: t.Spacing.s4),
                    Text('Restore Checkpoint', style: CardText.secondary.copyWith(color: fg)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: t.Spacing.s8),
          const Expanded(child: SizedBox(height: t.Borders.width, child: ColoredBox(color: t.Borders.subtle))),
        ],
      ),
    );
  }
}
