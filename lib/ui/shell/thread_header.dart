// 画板 01 / 02 / 03 · 线程头：agent 标记 + 标题（`session_info_update.title`，缺省 `New <agent> Thread`）+ 运行中 spinner，
// 右侧四个动作。画板 01 注：四个动作依能力显示——重命名依赖 `sessionCapabilities`（`canRename`），重载是客户端本地动作
// （断开 + 重拉 + 新会话），无对应能力时该按钮不渲染；≡ 打开右栏（画板 03 是选中态）与画板 41 的会话菜单。

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';
import 'popover_anchor.dart';
import 'shell_common.dart';

class ThreadHeader extends StatelessWidget {
  const ThreadHeader({
    super.key,
    required this.title,
    this.hasAgent = true,
    this.running = false,
    this.canRename = true,
    this.canReload = true,
    this.menuSelected = false,
    this.iconSvg,
    this.onRename,
    this.onNewSession,
    this.onReload,
    this.onMenu,
    this.newSessionAnchor,
    this.menuAnchor,
  });

  /// 无会话 / 无 agent 时画板给的是 `No Agent`。
  final String title;
  final bool hasAgent;
  final bool running;

  /// `sessionCapabilities` 支持改标题（画板 01 注）。
  final bool canRename;

  /// 有已连接的 agent 才给「重载 agent」。
  final bool canReload;

  /// 右栏已展开（画板 03）。
  final bool menuSelected;

  /// 当前 agent 的 `icon.svg`（registry 缓存）：agent 标记直接画它，没有时退回单色占位。
  final String? iconSvg;
  final VoidCallback? onRename;
  final VoidCallback? onNewSession;
  final VoidCallback? onReload;
  final VoidCallback? onMenu;

  /// 画板 41 的「新建会话 · 选 agent」与 ≡ 菜单的弹层锚点（内容由组合根给；gallery 里为 null）。
  final PopoverHandle? newSessionAnchor;
  final PopoverHandle? menuAnchor;

  @override
  Widget build(BuildContext context) {
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
            child: Row(
              children: <Widget>[
                Flexible(
                  child: Text(
                    title,
                    style: hasAgent ? CardText.strong : CardText.strong.copyWith(color: t.Neutral.placeholder),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (running) ...<Widget>[const SizedBox(width: t.Spacing.s8), const Spinner()],
              ],
            ),
          ),
          if (hasAgent && canRename) IconButtonGhost(icon: AcpIcons.pencil, onTap: onRename),
          PopoverAnchor(handle: newSessionAnchor, child: IconButtonGhost(icon: AcpIcons.plusSquare, onTap: onNewSession)),
          if (hasAgent && canReload) IconButtonGhost(icon: AcpIcons.reload, onTap: onReload),
          PopoverAnchor(handle: menuAnchor, child: _MenuButton(selected: menuSelected, onTap: onMenu)),
        ],
      ),
    );
  }
}

class _MenuButton extends StatelessWidget {
  const _MenuButton({required this.selected, this.onTap});

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
        child: AcpIcon(AcpIcons.menuLines, color: selected ? t.Accent.text : t.Neutral.muted, size: t.IconSizes.toolbar),
      ),
    );
  }
}
