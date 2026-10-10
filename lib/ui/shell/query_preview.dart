// 画板 46 · 侧栏会话行悬停后的首条用户指令卡片。
// 机制与 [AcpTooltip] 同一套（OverlayPortal、按目标矩形现算位置、不吃命中测试），但不是一行短说明：
// 停 [t.QueryPreview.hoverDelay] 后在行的右侧浮出，点下去不挡会话行自己的点击。
// 没有首条指令、或树里没有 Overlay（gallery / 单测直接渲染）时不出卡片。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';
import 'shell_common.dart';

/// 把 [child] 包一层首条指令预览。[prompt] 为空时原样返回 child。
class InitialQueryHover extends StatefulWidget {
  const InitialQueryHover({
    super.key,
    required this.prompt,
    required this.agentName,
    required this.updatedAt,
    required this.now,
    required this.child,
  });

  /// 首条用户指令原文。空串不出卡片。
  final String prompt;

  /// 只展示名字，调用方已经去掉多余标注。
  final String agentName;

  final DateTime updatedAt;
  final DateTime now;
  final Widget child;

  @override
  State<InitialQueryHover> createState() => _InitialQueryHoverState();
}

class _InitialQueryHoverState extends State<InitialQueryHover> {
  final OverlayPortalController _controller = OverlayPortalController();
  Timer? _timer;
  Rect _target = Rect.zero;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _enter() {
    _timer?.cancel();
    _timer = Timer(t.QueryPreview.hoverDelay, _show);
  }

  void _exit() => _cancel();

  void _pointerDown() => _cancel();

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    if (_controller.isShowing) _controller.hide();
  }

  void _show() {
    _timer = null;
    if (!mounted || _controller.isShowing || widget.prompt.isEmpty) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final box = context.findRenderObject();
    final overlayBox = overlay.context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || overlayBox is! RenderBox || !overlayBox.hasSize) return;
    _target = box.localToGlobal(Offset.zero, ancestor: overlayBox) & box.size;
    _controller.show();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.prompt.isEmpty) return widget.child;
    return MouseRegion(
      onEnter: (_) => _enter(),
      onExit: (_) => _exit(),
      child: Listener(
        onPointerDown: (_) => _pointerDown(),
        child: OverlayPortal(controller: _controller, overlayChildBuilder: _overlay, child: widget.child),
      ),
    );
  }

  Widget _overlay(BuildContext context) => Stack(
        children: <Widget>[
          Positioned.fill(
            child: IgnorePointer(
              child: CustomSingleChildLayout(delegate: _QueryPreviewLayout(_target), child: _card()),
            ),
          ),
        ],
      );

  Widget _card() {
    final timeStyle = t.TextStyles.meta.copyWith(fontFeatures: const <FontFeature>[FontFeature.tabularFigures()]);
    return SizedBox(
      width: t.QueryPreview.width,
      child: Popover(
        padding: t.QueryPreview.padding,
        radius: t.Radii.card,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              padding: t.QueryPreview.headerRulePadding,
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width)),
              ),
              child: Row(
                children: <Widget>[
                  AcpIcon(AcpIcons.messageSquare, size: t.IconSizes.toolbar, color: t.Accent.base),
                  const SizedBox(width: t.QueryPreview.titleGap),
                  Text('INITIAL QUERY', style: t.TextStyles.label.copyWith(color: t.Accent.base)),
                  const Spacer(),
                  Text(relativeTime(widget.updatedAt, now: widget.now), style: timeStyle),
                ],
              ),
            ),
            const SizedBox(height: t.QueryPreview.blockGap),
            Text(
              widget.prompt,
              maxLines: t.QueryPreview.maxLines,
              overflow: TextOverflow.ellipsis,
              style: t.TextStyles.secondary.copyWith(color: t.Neutral.text, height: t.LineHeights.body),
            ),
            const SizedBox(height: t.QueryPreview.blockGap),
            Container(
              padding: t.QueryPreview.footerRulePadding,
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width)),
              ),
              child: Text(
                'Agent: ${widget.agentName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.TextStyles.meta,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 卡片贴在目标行的右侧、顶对齐；右侧放不下就翻到左侧，上下贴边就收回来。
class _QueryPreviewLayout extends SingleChildLayoutDelegate {
  const _QueryPreviewLayout(this.target);

  final Rect target;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints(
        maxWidth: math.max(0, constraints.maxWidth - t.QueryPreview.margin * 2),
        maxHeight: constraints.maxHeight,
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final right = target.right + t.QueryPreview.sideGap;
    final left = target.left - t.QueryPreview.sideGap - childSize.width;
    final fitsRight = right + childSize.width <= size.width - t.QueryPreview.margin;
    final preferred = fitsRight ? right : left;
    final maxX = math.max(t.QueryPreview.margin, size.width - childSize.width - t.QueryPreview.margin);
    final x = preferred.clamp(t.QueryPreview.margin, maxX);
    final maxY = math.max(t.QueryPreview.margin, size.height - childSize.height - t.QueryPreview.margin);
    final y = target.top.clamp(t.QueryPreview.margin, maxY);
    return t.QueryPreview.offset(x, y);
  }

  @override
  bool shouldRelayout(_QueryPreviewLayout old) => old.target != target;
}
