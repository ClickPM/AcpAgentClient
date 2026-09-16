// 画板 03 / 60 / 61 · 右栏：标签条（面板标签 + 每个本地终端一个标签，当前项选中态 + 各自的关闭键）、面板关闭按钮、
// 窗口控制（右栏展开时窗口控制在这条上，顶栏那组不渲染）。
// 面板正文由调用方给（`body`）：文件面板（60）与终端面板（61）在 R4，Agents 与设置在 R5。

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';
import 'shell_common.dart';
import 'topbar.dart';

/// 标签条上的一个标签：侧栏底部导航打开的面板（[ShellTab]），或一个本地终端（画板 60 / 61 的标签条把两种并排列着）。
class PanelTab {
  const PanelTab.shell(ShellTab tab)
      : shell = tab,
        terminalId = null,
        _title = null;

  const PanelTab.terminal(String id, String title)
      : shell = null,
        terminalId = id,
        _title = title;

  final ShellTab? shell;
  final String? terminalId;
  final String? _title;

  /// 标签条上的文案：面板名（画板 03）或终端的标题（画板 61 用 cwd 末段）。
  String get title => shell?.panelTitle ?? _title ?? '';
  String get icon => shell?.icon ?? AcpIcons.terminal;

  bool get isTerminal => terminalId != null;

  @override
  bool operator ==(Object other) => other is PanelTab && other.shell == shell && other.terminalId == terminalId;

  @override
  int get hashCode => Object.hash(shell, terminalId);

  @override
  String toString() => isTerminal ? 'PanelTab.terminal($terminalId)' : 'PanelTab.shell($shell)';
}

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

  /// 已打开的标签（侧栏底部导航点开的面板 + 本地终端）。
  final List<PanelTab> tabs;
  final PanelTab active;
  final ValueChanged<PanelTab>? onSelect;
  final ValueChanged<PanelTab>? onCloseTab;

  /// 整个右栏收起。
  final VoidCallback? onClose;
  final bool windowControls;
  final VoidCallback? onMinimize;
  final VoidCallback? onMaximize;
  final VoidCallback? onCloseWindow;

  /// 面板正文；`null` = 占位。
  final Widget? body;

  @override
  Widget build(BuildContext context) {
    return Container(
      // 独立渲染时的缺省宽；装进 [AppShell] 时由它的紧约束覆盖。
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
        // 条高而不是 [t.Controls.input]：标签条与顶栏共用第一条分割线，32 对 36 会错开 4px。
        height: t.Geometry.barHeight,
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
        padding: const EdgeInsets.only(left: t.Spacing.s4, right: t.Spacing.s4),
        child: Row(
          children: <Widget>[
            for (final tab in tabs) _tab(tab),
            const Spacer(),
            // 面板关闭键紧挨窗口控制（画板 03）。两个 `Spacer` 会把余量五五分、把它顶到标签条中间去。
            IconButtonGhost(icon: AcpIcons.x, size: t.Controls.compact, onTap: onClose),
            if (windowControls)
              WindowControls(height: t.Geometry.barHeight, onMinimize: onMinimize, onMaximize: onMaximize, onClose: onCloseWindow),
          ],
        ),
      );

  Widget _tab(PanelTab tab) {
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
            Text(tab.title, style: CardText.secondary.copyWith(color: selected ? t.Accent.text : t.Neutral.muted)),
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

/// 面板占位（R5 前的 Agents / 设置）。
class RightPanelPlaceholder extends StatelessWidget {
  const RightPanelPlaceholder({super.key, required this.tab});

  final PanelTab tab;

  @override
  Widget build(BuildContext context) => Center(
        child: Text('${tab.title}（未实现）', style: t.TextStyles.secondary.copyWith(color: t.Neutral.placeholder)),
      );
}
