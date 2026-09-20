// 画板 01 / 02 / 03 · 线程头：agent 标记 + 标题（`session_info_update.title`，缺省 `New <agent> Thread`）+ 运行中 spinner，
// 右侧四个动作。画板 01 注：四个动作依能力显示——重命名依赖 `sessionCapabilities`（`canRename`），重载是客户端本地动作
// （断开 + 重拉 + 新会话），无对应能力时该按钮不渲染；≡ 打开右栏（画板 03 是选中态）与画板 41 的会话菜单。
// 画板 43：reload 与 ≡ 之间多一个 history（会话时间线弹层），显示条件与 reload 同规则。

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';
import 'motion.dart';
import 'popover_anchor.dart';
import 'shell_common.dart';
import 'tooltip.dart';

class ThreadHeader extends StatelessWidget {
  const ThreadHeader({
    super.key,
    required this.title,
    this.hasAgent = true,
    this.running = false,
    this.canRename = true,
    this.canReload = true,
    this.canTimeline = true,
    this.timelineSelected = false,
    this.menuSelected = false,
    this.renaming = false,
    this.renameController,
    this.renameFocusNode,
    this.iconSvg,
    this.onRename,
    this.onCommitRename,
    this.onCancelRename,
    this.onNewSession,
    this.onReload,
    this.onTimeline,
    this.onMenu,
    this.newSessionAnchor,
    this.timelineAnchor,
    this.menuAnchor,
    this.transitionEpoch,
  });

  /// 无会话 / 无 agent 时画板给的是 `No Agent`。
  final String title;
  final bool hasAgent;
  final bool running;

  /// 会话内容整块替换时标题与转录区同起同止（画板 05 A 组）；变一次重播一次入场。
  /// null = 不做入场（gallery 里的静态画板对照）。
  final Object? transitionEpoch;

  /// `sessionCapabilities` 支持改标题（画板 01 注）。
  final bool canRename;

  /// 有已连接的 agent 才给「重载 agent」。
  final bool canReload;

  /// 画板 43：有 agent、有会话才给「会话时间线」（与 [canReload] 同规则）。
  final bool canTimeline;

  /// 时间线弹层开着（画板 43 A 组第三态：按下态容器 + accent 图标）。
  final bool timelineSelected;

  /// 右栏已展开（画板 03）。
  final bool menuSelected;

  /// 铅笔按下后就地改标题：标题位换成行内输入框（与侧栏那支笔各改各的，见 [Sidebar]）。
  final bool renaming;
  final TextEditingController? renameController;
  final FocusNode? renameFocusNode;

  /// 当前 agent 的 `icon.svg`（registry 缓存）：agent 标记直接画它，没有时退回单色占位。
  final String? iconSvg;
  final VoidCallback? onRename;
  final ValueChanged<String>? onCommitRename;
  final VoidCallback? onCancelRename;
  final VoidCallback? onNewSession;
  final VoidCallback? onReload;
  final VoidCallback? onTimeline;
  final VoidCallback? onMenu;

  /// 画板 41 的「新建会话 · 选 agent」与 ≡ 菜单、画板 43 时间线的弹层锚点（内容由组合根给；gallery 里为 null）。
  final PopoverHandle? newSessionAnchor;
  final PopoverHandle? timelineAnchor;
  final PopoverHandle? menuAnchor;

  @override
  Widget build(BuildContext context) {
    final inlineEdit = renaming && renameController != null && renameFocusNode != null;
    return Container(
      height: t.Geometry.barHeight,
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
      padding: const EdgeInsets.only(left: t.Spacing.s16, right: t.Spacing.s8),
      child: Row(
        children: <Widget>[
          AgentMark(active: hasAgent, empty: !hasAgent, svg: iconSvg),
          const SizedBox(width: t.Spacing.s8),
          // 标题吃掉余量、动作贴右（画板 01 的 `margin-left:auto`）。这里不能写成 `Flexible` 加 `Spacer`
          // 并列：两者 flex 都是 1，余量被五五分，动作会停在标题与右边缘的中点上（顶栏踩过同一个坑）。
          Expanded(
            child: inlineEdit
                // 改名时标题位整条让给输入框（Enter 保存 · Esc 取消的提示进不去一行高的条，靠输入框自身的焦点环示意）。
                ? InlineRenameField(
                    controller: renameController!,
                    focusNode: renameFocusNode!,
                    onSubmitted: onCommitRename,
                    onCancel: onCancelRename,
                  )
                : Row(
                    children: <Widget>[
                      Flexible(child: _title()),
                      if (running) ...<Widget>[const SizedBox(width: t.Spacing.s8), const Spinner()],
                    ],
                  ),
          ),
          if (hasAgent && canRename && !inlineEdit)
            AcpTooltip(message: 'Edit session title', child: IconButtonGhost(icon: AcpIcons.pencil, onTap: onRename)),
          AcpTooltip(
            message: 'New agent session',
            child: PopoverAnchor(handle: newSessionAnchor, child: IconButtonGhost(icon: AcpIcons.plusSquare, onTap: onNewSession)),
          ),
          if (hasAgent && canReload)
            AcpTooltip(message: 'Reload this session', child: IconButtonGhost(icon: AcpIcons.reload, onTap: onReload)),
          if (hasAgent && canTimeline)
            AcpTooltip(
              message: 'Session timeline',
              child: PopoverAnchor(
                handle: timelineAnchor,
                child: _SelectableIconButton(icon: AcpIcons.history, selected: timelineSelected, onTap: onTimeline),
              ),
            ),
          AcpTooltip(
            message: 'Tools-sidebar',
            child: PopoverAnchor(
              handle: menuAnchor,
              child: _SelectableIconButton(icon: AcpIcons.menuLines, selected: menuSelected, onTap: onMenu),
            ),
          ),
        ],
      ),
    );
  }

  Widget _title() {
    final Widget text = Text(
      title,
      style: hasAgent ? CardText.strong : CardText.strong.copyWith(color: t.Neutral.placeholder),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final epoch = transitionEpoch;
    return epoch == null ? text : MotionEnter(epoch: epoch, child: text);
  }
}

/// 线程头上带「选中态」的图标按钮：≡（右栏开着）与 history（时间线弹层开着）。
/// 选中 = 按下态容器 + accent 图标，与 [IconButtonGhost] 的区别只在这一态。
class _SelectableIconButton extends StatelessWidget {
  const _SelectableIconButton({required this.icon, required this.selected, this.onTap});

  final String icon;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Hoverable(
      onTap: onTap,
      builder: (context, hovered) => Container(
        width: t.Controls.standard,
        height: t.Controls.standard,
        decoration: BoxDecoration(
          color: selected ? t.Overlays.selected : (hovered ? t.Overlays.hover : null),
          borderRadius: t.Radii.control,
        ),
        alignment: Alignment.center,
        child: AcpIcon(icon, color: selected ? t.Accent.text : t.Neutral.muted, size: t.IconSizes.toolbar),
      ),
    );
  }
}
