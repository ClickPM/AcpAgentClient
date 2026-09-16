// 画板 03 · 右栏：标签条（当前标签 + 关闭）、面板关闭按钮、窗口控制（右栏展开时窗口控制在这条上，顶栏那组不渲染）。
// 面板正文本轮是占位：文件面板与终端面板在 R4，Agents 与设置在 R5（ROUNDS § 3 R3「右栏内容 R4」）。

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';
import 'shell_common.dart';
import 'topbar.dart';

class RightPanel extends StatelessWidget {
  const RightPanel({
    super.key,
    required this.tabs,
    required this.active,
    this.onSelect,
    this.onCloseTab,
    this.onClose,
    this.windowControls = true,
    this.onMinimize,
    this.onMaximize,
    this.onCloseWindow,
    this.body,
  });

  /// 已打开的标签（侧栏底部导航点开的那几个）。
  final List<ShellTab> tabs;
  final ShellTab active;
  final ValueChanged<ShellTab>? onSelect;
  final ValueChanged<ShellTab>? onCloseTab;

  /// 整个右栏收起。
  final VoidCallback? onClose;
  final bool windowControls;
  final VoidCallback? onMinimize;
  final VoidCallback? onMaximize;
  final VoidCallback? onCloseWindow;

  /// 面板正文；`null` = 占位（本轮默认）。
  final Widget? body;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: t.Geometry.rightPanelWidth,
      decoration: const BoxDecoration(
        color: t.Neutral.panel,
        border: Border(left: BorderSide(color: t.Borders.subtle, width: t.Borders.width)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _tabBar(),
          Expanded(child: body ?? RightPanelPlaceholder(tab: active)),
        ],
      ),
    );
  }

  Widget _tabBar() => Container(
        height: t.Controls.input,
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
        padding: const EdgeInsets.only(left: t.Spacing.s4, right: t.Spacing.s4),
        child: Row(
          children: <Widget>[
            for (final tab in tabs) _tab(tab),
            const Spacer(),
            // 面板关闭键紧挨窗口控制（画板 03）。两个 `Spacer` 会把余量五五分、把它顶到标签条中间去。
            IconButtonGhost(icon: AcpIcons.x, size: t.Controls.compact, onTap: onClose),
            if (windowControls)
              WindowControls(height: t.Controls.input, onMinimize: onMinimize, onMaximize: onMaximize, onClose: onCloseWindow),
          ],
        ),
      );

  Widget _tab(ShellTab tab) {
    final selected = tab == active;
    return Hoverable(
      onTap: onSelect == null ? null : () => onSelect!(tab),
      builder: (context, hovered) => Container(
        height: t.Controls.compact,
        margin: const EdgeInsets.only(right: t.Spacing.s4),
        padding: t.Controls.padCompact,
        decoration: BoxDecoration(
          color: selected ? t.Overlays.selected : (hovered ? t.Overlays.hover : null),
          borderRadius: t.Radii.control,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AcpIcon(tab.icon, color: selected ? t.Accent.text : t.Neutral.muted, size: t.IconSizes.toolbar),
            const SizedBox(width: t.Spacing.s4),
            Text(tab.panelTitle, style: CardText.secondary.copyWith(color: selected ? t.Accent.text : t.Neutral.muted)),
            const SizedBox(width: t.Spacing.s4),
            GestureDetector(
              onTap: onCloseTab == null ? null : () => onCloseTab!(tab),
              child: AcpIcon(AcpIcons.x, color: selected ? t.Accent.text : t.Neutral.muted, size: t.IconSizes.toolbar),
            ),
          ],
        ),
      ),
    );
  }
}

/// 面板占位（R4 / R5 前）。
class RightPanelPlaceholder extends StatelessWidget {
  const RightPanelPlaceholder({super.key, required this.tab});

  final ShellTab tab;

  @override
  Widget build(BuildContext context) => Center(
        child: Text('${tab.panelTitle}（未实现）', style: t.TextStyles.secondary.copyWith(color: t.Neutral.placeholder)),
      );
}
