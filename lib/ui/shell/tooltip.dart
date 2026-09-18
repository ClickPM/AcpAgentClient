// 悬停提示（设计稿之外的增补，所有者 2026-09-18 直接要求）：壳上那些只有图标、或只有两个字标签的入口，
// 鼠标停住 [t.Motion.tooltipDelay] 之后在旁边出一行英文说明。样式只取 tokens（CLAUDE.md 规则 3）。
//
// 自写而不用 Material 的 `Tooltip`：壳里一个 Material widget 都不用（见 lib/app/app.dart 的注释），
// 它那套底色与字样也不在 tokens 里。浮层机制和 [PopoverAnchor] 一样是 `OverlayPortal`，但位置是按目标控件
// 的全局矩形现算的——下方放不下就翻到上方、左右贴边就收回来——所以不复用那套 `CompositedTransformFollower`
// （底部导航与输入框那几个按钮贴着窗口下沿，跟随式锚点会把提示条顶到屏幕外）。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;

/// 把 [child] 包一层悬停提示。[message] 为空时原样返回 child。
class AcpTooltip extends StatefulWidget {
  const AcpTooltip({super.key, required this.message, required this.child});

  final String message;
  final Widget child;

  @override
  State<AcpTooltip> createState() => _AcpTooltipState();
}

class _AcpTooltipState extends State<AcpTooltip> {
  final OverlayPortalController _controller = OverlayPortalController();
  Timer? _timer;

  /// 目标控件在 Overlay 坐标系里的矩形，显示的那一刻量一次。
  Rect _target = Rect.zero;

  /// 这一次悬停里已经点过了：按钮点下去多半是开面板 / 开弹层，提示条不该还挂在那儿挡着。
  /// 指针离开再进来才重新计时。
  bool _suppressed = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _enter() {
    if (_suppressed) return;
    _timer?.cancel();
    _timer = Timer(t.Motion.tooltipDelay, _show);
  }

  void _exit() {
    _suppressed = false;
    _cancel();
  }

  void _pointerDown() {
    _suppressed = true;
    _cancel();
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    if (_controller.isShowing) _controller.hide();
  }

  void _show() {
    _timer = null;
    if (!mounted || _controller.isShowing) return;
    // gallery 的画板对照页与单测直接渲染 widget，树里没有 Overlay：没有就干脆不出提示
    // （`OverlayPortal` 一显示就去找 Overlay，找不到直接抛）。隐藏着的 `OverlayPortal` 不查 Overlay，
    // 所以这些场景下整棵树照常。
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
    if (widget.message.isEmpty) return widget.child;
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
            // 提示条一律不吃命中测试：它就浮在按钮边上，挡住指针的话按钮自己的 hover 当场就断了。
            child: IgnorePointer(
              child: CustomSingleChildLayout(delegate: _TooltipLayout(_target), child: _bubble()),
            ),
          ),
        ],
      );

  Widget _bubble() => Container(
        padding: t.Geometry.tooltipPadding,
        decoration: BoxDecoration(
          color: t.Surface.popover,
          border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
          borderRadius: t.Radii.control,
          boxShadow: const <BoxShadow>[t.Shadows.popover],
        ),
        child: Text(
          widget.message,
          style: t.TextStyles.secondary.copyWith(color: t.Neutral.text, height: t.LineHeights.control),
        ),
      );
}

/// 提示条的位置：默认贴在目标下方、横向与目标中心对齐；下方放不下就翻到上方，左右贴到窗口边上就收回来。
class _TooltipLayout extends SingleChildLayoutDelegate {
  const _TooltipLayout(this.target);

  /// 目标控件在 Overlay 坐标系里的矩形。
  final Rect target;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints(
        maxWidth: math.max(
          0,
          math.min(t.Geometry.tooltipMaxWidth, constraints.maxWidth - t.Geometry.tooltipMargin * 2),
        ),
        maxHeight: constraints.maxHeight,
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final below = target.bottom + t.Geometry.tooltipGap;
    final above = target.top - t.Geometry.tooltipGap - childSize.height;
    // 下方装得下就走下方；装不下才翻上方，上方也装不下（窗口比提示条还矮）就仍按下方来。
    final fitsBelow = below + childSize.height <= size.height - t.Geometry.tooltipMargin;
    final y = fitsBelow || above < t.Geometry.tooltipMargin ? below : above;
    final maxX = math.max(t.Geometry.tooltipMargin, size.width - childSize.width - t.Geometry.tooltipMargin);
    final x = (target.center.dx - childSize.width / 2).clamp(t.Geometry.tooltipMargin, maxX);
    return t.Geometry.tooltipOffset(x, y);
  }

  @override
  bool shouldRelayout(_TooltipLayout old) => old.target != target;
}
