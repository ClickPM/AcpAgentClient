// 画板 01 / 02 / 03 · 三栏壳：侧栏（可折叠）+ 中栏（顶栏 / 线程头 / 转录 / 输入框）+ 右栏（可选，展开时中栏与右栏各 580）。
// 无边框窗口（docs/design.md § 9）：外框自绘 1px 边框，拖拽与三键走 Windows runner 的平台通道（接线阶段）。

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;

/// 整窗：外框 + 三栏。
class AppShell extends StatelessWidget {
  const AppShell({super.key, this.sidebar, required this.main, this.rightPanel});

  /// `null` = 侧栏已折叠（画板 04「侧栏折叠后的顶栏」）。
  final Widget? sidebar;
  final Widget main;

  /// `null` = 右栏未展开（画板 01 / 02）。
  final Widget? rightPanel;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: t.Surface.canvas,
        border: Border.all(color: t.Borders.base, width: t.Borders.width),
      ),
      clipBehavior: Clip.hardEdge,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ?sidebar,
          Expanded(child: main),
          ?rightPanel,
        ],
      ),
    );
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
