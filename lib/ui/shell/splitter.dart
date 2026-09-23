// 画板 04 · 分栏把手：叠在两条分栏线上的拖拽区（所有者裁定 2026-09-16）。
// 分栏线本身仍是侧栏 / 右栏容器自己的 1px 边框，把手只是盖在上面的命中区，**不占布局**——
// 占布局就得让两栏各让出几像素，画板上的分栏线宽度与三栏比例都会跟着变。
// 夹取范围与复位默认值是组合根的事（这里只报位移），见 lib/app/workbench_controller.dart。

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import 'shell_common.dart';

class ColumnSplitter extends StatefulWidget {
  const ColumnSplitter({super.key, required this.onDelta, this.onDragEnd, this.onReset});

  /// 一次拖拽的增量（逻辑像素，向右为正）。
  final ValueChanged<double> onDelta;

  /// 松手：落盘时机，拖拽途中不落盘。
  final VoidCallback? onDragEnd;

  /// 双击复位到画板默认宽度。
  final VoidCallback? onReset;

  @override
  State<ColumnSplitter> createState() => _ColumnSplitterState();
}

class _ColumnSplitterState extends State<ColumnSplitter> {
  /// 拖拽态是把手自己的；悬浮态走 [Hoverable]。
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    return Hoverable(
      cursor: SystemMouseCursors.resizeLeftRight,
      builder: (context, hovered) => _handle(hovered || _dragging),
    );
  }

  Widget _handle(bool active) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 只认鼠标与触控笔：触屏上横扫整窗不该变成拖分栏。
      supportedDevices: const <PointerDeviceKind>{PointerDeviceKind.mouse, PointerDeviceKind.stylus},
      onDoubleTap: widget.onReset,
      onHorizontalDragStart: (_) => setState(() => _dragging = true),
      onHorizontalDragUpdate: (d) => widget.onDelta(d.delta.dx),
      onHorizontalDragEnd: (_) {
        setState(() => _dragging = false);
        widget.onDragEnd?.call();
      },
      onHorizontalDragCancel: () => setState(() => _dragging = false),
      child: SizedBox(
        width: t.Geometry.splitterHit,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          // stretch：压上去的那条线要和分栏线一样通到底。
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // 静息时不画（分栏线是两栏容器自己的边框），悬停 / 拖拽时压一条 accent 上去。
            Container(width: t.Borders.width, color: active ? t.Accent.base : null),
          ],
        ),
      ),
    );
  }
}
