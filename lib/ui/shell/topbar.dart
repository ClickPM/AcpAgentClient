// 画板 01 / 02 / 03 / 04 · 顶栏：侧栏折叠开关、项目名（点开画板 41 的项目切换弹层）、分支名（点开分支切换弹层）、
// 窗口控制三键。窗口是无边框的（docs/design.md § 9 裁定）：拖拽区与三个动作走 Windows runner 的平台通道，
// 这里只出按钮与回调；非 git 目录（`branch == null`）时整块分支区不渲染。

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';
import 'popover_anchor.dart';
import 'shell_common.dart';
import 'tooltip.dart';

/// 顶栏一条（高 [t.Geometry.barHeight]，下边框 subtle）。
class TopBar extends StatelessWidget {
  const TopBar({
    super.key,
    required this.projectName,
    this.branch,
    this.sidebarCollapsed = false,
    this.onToggleSidebar,
    this.onProject,
    this.onBranch,
    this.windowControls = true,
    this.onMinimize,
    this.onMaximize,
    this.onClose,
    this.hoverProject = false,
    this.hoverBranch = false,
    this.projectAnchor,
    this.branchAnchor,
    this.dragArea,
  });

  final String projectName;

  /// 当前分支；`null` = 不是 git 仓库或找不到 git，整块隐藏（docs/design.md § 9）。
  final String? branch;
  final bool sidebarCollapsed;
  final VoidCallback? onToggleSidebar;
  final VoidCallback? onProject;
  final VoidCallback? onBranch;

  /// 右栏展开时窗口控制移到右栏的标签条上（画板 03），这里就不渲染。
  final bool windowControls;
  final VoidCallback? onMinimize;
  final VoidCallback? onMaximize;
  final VoidCallback? onClose;

  /// gallery 出悬浮样张用（画板 04）。
  final bool hoverProject;
  final bool hoverBranch;

  /// 画板 41 的项目切换 / 分支切换弹层锚点（内容由组合根给；gallery 里为 null）。
  final PopoverHandle? projectAnchor;
  final PopoverHandle? branchAnchor;

  /// 无边框窗口的拖拽层（docs/design.md § 9）：铺在顶栏**里面**、控件行**下面**。
  /// 必须在容器内部：`BoxDecoration.hitTest` 对矩形一律返回 true，顶栏那层 `Container` 会把 pointer 全吃掉，
  /// 垫在外面（兄弟 `Stack`）的 Listener 根本收不到（审查 finding P2，2026-09-15）。
  /// 子节点先于 `hitTestSelf` 参与命中，所以放进来就能拿到空白处的事件；控件在更上层，照常先吃掉自己的。
  final Widget? dragArea;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: t.Geometry.barHeight,
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
      // `StackFit.expand`：控件行要拿到与原来一样的紧约束（否则没有窗口控制的那几张画板里，
      // 行高塌成 24 再顶部对齐，纵向居中就变了）。
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (dragArea != null) Positioned.fill(child: dragArea!),
          _bar(),
        ],
      ),
    );
  }

  Widget _bar() {
    return Padding(
      padding: const EdgeInsets.only(left: t.Spacing.s8),
      child: Row(
        children: <Widget>[
          AcpTooltip(message: 'Session-sidebar', child: _ToggleButton(collapsed: sidebarCollapsed, onTap: onToggleSidebar)),
          const SizedBox(width: t.Spacing.s4),
          // 项目名与分支挤在左侧、剩余空白留给窗口控制：内层 Row 的 Flexible 只按内容取宽（loose），
          // 多出来的空间留在 Expanded 的右侧。不能用 Flexible + Spacer——那会把空白对半分掉。
          Expanded(
            child: Row(
              children: <Widget>[
                Flexible(
                  child: AcpTooltip(
                    message: 'Recent workspace',
                    child: PopoverAnchor(
                      handle: projectAnchor,
                      child: Hoverable(
                        onTap: onProject,
                        forceHover: hoverProject,
                        builder: (context, hovered) => _chip(
                          hovered: hovered,
                          child: Text(projectName, style: CardText.headerTitle.copyWith(color: t.Neutral.strong), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    ),
                  ),
                ),
                if (branch != null) ...<Widget>[
                  const SizedBox(width: t.Spacing.s4),
                  AcpTooltip(
                    message: 'Branch',
                    child: PopoverAnchor(
                      handle: branchAnchor,
                      child: Hoverable(
                        onTap: onBranch,
                        forceHover: hoverBranch,
                        builder: (context, hovered) => _chip(
                          hovered: hovered,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              AcpIcon(AcpIcons.gitBranch, color: hovered ? t.Neutral.text : t.Neutral.muted, size: t.IconSizes.toolbar),
                              const SizedBox(width: t.Spacing.s4),
                              Text(branch!, style: CardText.secondary.copyWith(color: hovered ? t.Neutral.text : t.Neutral.muted)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (windowControls) WindowControls(onMinimize: onMinimize, onMaximize: onMaximize, onClose: onClose),
        ],
      ),
    );
  }

  static Widget _chip({required bool hovered, required Widget child}) => Container(
        height: t.Controls.compact,
        padding: t.Controls.padCompact,
        decoration: BoxDecoration(color: hovered ? t.Overlays.hover : null, borderRadius: t.Radii.control),
        // Row 而不是 alignment：Container 一旦给了 alignment 就会撑满 Flexible 给的最大宽度。
        child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[Flexible(child: child)]),
      );
}

class _ToggleButton extends StatelessWidget {
  const _ToggleButton({required this.collapsed, this.onTap});

  final bool collapsed;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Hoverable(
      onTap: onTap,
      builder: (context, hovered) => Container(
        width: t.Controls.compact,
        height: t.Controls.compact,
        decoration: BoxDecoration(
          color: collapsed ? t.Overlays.selected : (hovered ? t.Overlays.hover : null),
          borderRadius: t.Radii.control,
        ),
        alignment: Alignment.center,
        child: AcpIcon(AcpIcons.panelLeft, color: collapsed ? t.Accent.text : t.Neutral.muted),
      ),
    );
  }
}

/// — ☐ ✕ 三键：每格 [t.Geometry.windowButtonWidth] 宽、条高满格；关闭键 hover 走 error 底（Windows 习惯）。
class WindowControls extends StatelessWidget {
  const WindowControls({super.key, this.onMinimize, this.onMaximize, this.onClose, this.height = t.Geometry.barHeight});

  final VoidCallback? onMinimize;
  final VoidCallback? onMaximize;
  final VoidCallback? onClose;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _cell(AcpIcons.windowMinimize, onMinimize),
        _cell(AcpIcons.windowMaximize, onMaximize),
        _cell(AcpIcons.x, onClose, danger: true),
      ],
    );
  }

  Widget _cell(String icon, VoidCallback? onTap, {bool danger = false}) => Hoverable(
        onTap: onTap,
        builder: (context, hovered) => Container(
          width: t.Geometry.windowButtonWidth,
          height: height,
          color: hovered ? (danger ? t.Semantic.errorSoft : t.Overlays.hover) : null,
          alignment: Alignment.center,
          child: AcpIcon(icon, color: hovered && danger ? t.Semantic.error : t.Neutral.muted, size: t.IconSizes.toolbar),
        ),
      );
}
