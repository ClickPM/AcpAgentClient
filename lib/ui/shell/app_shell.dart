// 画板 01 / 02 / 03 · 三栏壳：侧栏（可折叠）+ 中栏（顶栏 / 线程头 / 转录 / 输入框）+ 右栏（可选）。
// 无边框窗口（docs/design.md § 9）：外框自绘 1px 边框，拖拽与三键走 Windows runner 的平台通道（接线阶段）。
// 两栏宽度可拖（画板 04 的「分栏把手」，所有者裁定 2026-09-16）：宽度单点在这里，夹取与落盘在组合根。

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import 'splitter.dart';

/// 整窗：外框 + 三栏 + 两条分栏把手。
class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    this.sidebar,
    required this.main,
    this.rightPanel,
    this.sidebarWidth = t.Geometry.sidebarWidth,
    this.rightPanelWidth = t.Geometry.rightPanelWidth,
    this.onResizeSidebar,
    this.onResizeRightPanel,
    this.onResizeEnd,
    this.onResetSidebar,
    this.onResetRightPanel,
  });

  /// `null` = 侧栏已折叠（画板 04「侧栏折叠后的顶栏」）。
  final Widget? sidebar;
  final Widget main;

  /// `null` = 右栏未展开（画板 01 / 02）。
  final Widget? rightPanel;

  /// 两栏的当前宽度。这里的紧约束会盖掉 [Sidebar] / [RightPanel] 自带的缺省宽，宽度是单点的。
  final double sidebarWidth;
  final double rightPanelWidth;

  /// 拖拽增量，参数是**该栏宽度**的增量（右栏把手已在这里取过反）。`null` = 不给把手（gallery 画板）。
  final ValueChanged<double>? onResizeSidebar;
  final ValueChanged<double>? onResizeRightPanel;

  /// 松手：落盘时机。
  final VoidCallback? onResizeEnd;

  /// 双击复位。
  final VoidCallback? onResetSidebar;
  final VoidCallback? onResetRightPanel;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: t.Surface.canvas,
        border: Border.all(color: t.Borders.base, width: t.Borders.width),
      ),
      clipBehavior: Clip.hardEdge,
      child: LayoutBuilder(builder: _build),
    );
  }

  Widget _build(BuildContext context, BoxConstraints constraints) {
    final (double side, double right) = _fit(constraints.maxWidth);
    // 把手叠在分栏线上、不占布局：占了布局，分栏线宽度与三栏比例就和画板对不上了。
    const double half = t.Geometry.splitterHit / 2;
    return Stack(
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (sidebar != null) SizedBox(width: side, child: sidebar),
            Expanded(child: main),
            if (rightPanel != null) SizedBox(width: right, child: rightPanel),
          ],
        ),
        if (sidebar != null && onResizeSidebar != null)
          Positioned(
            left: side - half,
            top: 0,
            bottom: 0,
            width: t.Geometry.splitterHit,
            child: ColumnSplitter(onDelta: onResizeSidebar!, onDragEnd: onResizeEnd, onReset: onResetSidebar),
          ),
        if (rightPanel != null && onResizeRightPanel != null)
          Positioned(
            right: right - half,
            top: 0,
            bottom: 0,
            width: t.Geometry.splitterHit,
            // 把手往右拖 = 右栏变窄，所以这里取反再交给组合根。
            child: ColumnSplitter(
              onDelta: (dx) => onResizeRightPanel!(-dx),
              onDragEnd: onResizeEnd,
              onReset: onResetRightPanel,
            ),
          ),
      ],
    );
  }

  /// 窗口装不下两栏加中栏下限时：先压右栏、再压侧栏，各自不低于自己的下限（画板 04 的注）。
  /// 压到下限还不够就随它去——那是窗口本身比三栏的下限还窄，和拖不拖没关系。
  (double, double) _fit(double available) {
    double side = sidebar == null ? 0 : sidebarWidth;
    double right = rightPanel == null ? 0 : rightPanelWidth;
    double over = side + right + t.Geometry.mainMinWidth - available;
    if (over > 0 && right > 0) {
      final double cut = math.min(over, math.max(0, right - t.Geometry.rightPanelMinWidth));
      right -= cut;
      over -= cut;
    }
    if (over > 0 && side > 0) {
      side -= math.min(over, math.max(0, side - t.Geometry.sidebarMinWidth));
    }
    return (side, right);
  }
}

/// 中栏：顶栏 → 线程头 → 转录（可伸缩）→ 输入框。
class WorkbenchColumn extends StatelessWidget {
  const WorkbenchColumn({super.key, required this.topBar, required this.threadHeader, required this.body, required this.composer});

  final Widget topBar;
  final Widget threadHeader;
  final Widget body;
  final Widget composer;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: t.Surface.canvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          topBar,
          threadHeader,
          Expanded(child: body),
          composer,
        ],
      ),
    );
  }
}

/// 转录区：顶部 16 内边距 + 居中的最大宽度列（画板 02 / 03）。
class CenteredContent extends StatelessWidget {
  const CenteredContent({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: t.Spacing.s16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: t.Geometry.contentMaxWidth),
          child: child,
        ),
      ),
    );
  }
}
