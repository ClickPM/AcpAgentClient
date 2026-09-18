// 画板 40 / 41 / 42 共用的弹层骨架（ROUNDS § 2 的文件表之外新增，任务卡已记）：容器、分组标题、菜单行、
// 分隔线、搜索输入、注释行。弹层是唯一带阴影的表面；当前项用「按下态容器 + accent 文字 + 对勾」表示（画板 40 注）。

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import '../shell/shell_common.dart';
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';

/// 弹层容器：popover 底 + subtle 边框 + radius 6 + shadow.popover，内边距 4。
///
/// 内容高过 [maxHeight] 时在弹层内部滚动：条目数没有上限（`/` 菜单是 `available_commands_update`
/// 的全量列表，装了几十个 skill 就是几十行），不封顶的话弹层会顶出窗口，下面的条目既看不见也选不中
/// （所有者手测 2026-09-18）。内容不足这个高度时弹层仍按内容收窄，画板上那些三五行的菜单外观不变。
class MenuPopover extends StatelessWidget {
  const MenuPopover({
    super.key,
    required this.children,
    this.width = t.Geometry.menuWidth,
    this.maxHeight = t.Geometry.menuMaxHeight,
  });

  final List<Widget> children;
  final double width;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    return Popover(
      radius: t.Radii.card,
      padding: const EdgeInsets.all(t.Spacing.s4),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SizedBox(
          width: width,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      ),
    );
  }
}

/// 分组标题（`SessionConfigSelectGroup.name` / `Files` / `Commands` / `This Window`…）。
class MenuGroupLabel extends StatelessWidget {
  const MenuGroupLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        height: t.Geometry.menuGroupLabelHeight,
        padding: t.Controls.padCompact,
        alignment: Alignment.centerLeft,
        child: Text(text, style: t.TextStyles.label.copyWith(color: t.Neutral.placeholder), maxLines: 1, overflow: TextOverflow.ellipsis),
      );
}

/// 菜单行：`[图标] 标题 [副标题] … [尾部]`，选中时叠按下态并在尾部出对勾。
class MenuRow extends StatelessWidget {
  const MenuRow({
    super.key,
    this.icon,
    this.leading,
    required this.label,
    this.labelStyle,
    this.secondary,
    this.secondaryStyle,
    this.trailing,
    this.selected = false,
    this.danger = false,
    this.forceHover = false,
    this.onTap,
  });

  final String? icon;

  /// 图标位放自定义内容（例如 agent 标记方块）。
  final Widget? leading;
  final String label;
  final TextStyle? labelStyle;

  /// 标题右侧的次要文字（`scripts/` 路径、命令描述）。
  final String? secondary;
  final TextStyle? secondaryStyle;

  /// 尾部（参数提示、当前值、布尔开关）。选中时若未给尾部则渲染对勾。
  final Widget? trailing;
  final bool selected;

  /// 破坏性动作（Delete Session）走 error 色。
  final bool danger;
  final bool forceHover;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fg = danger ? t.Semantic.error : (selected ? t.Accent.text : t.Neutral.text);
    return _RevealWhenSelected(
      selected: selected,
      child: Hoverable(
        onTap: onTap,
        forceHover: forceHover,
        builder: (context, hovered) => Container(
          height: t.Controls.standard,
          padding: t.Controls.padCompact,
          decoration: BoxDecoration(
            color: selected ? t.Overlays.selected : (hovered ? t.Overlays.hover : null),
            borderRadius: t.Radii.control,
          ),
          child: Row(
            children: <Widget>[
              if (leading != null) ...<Widget>[leading!, const SizedBox(width: t.Spacing.s8)]
              else if (icon != null) ...<Widget>[
                AcpIcon(icon!, color: danger ? t.Semantic.error : t.Neutral.muted, size: t.IconSizes.toolbar),
                const SizedBox(width: t.Spacing.s8),
              ],
              Expanded(
                child: Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(label, style: (labelStyle ?? CardText.secondary).copyWith(color: fg), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    if (secondary != null) ...<Widget>[
                      const SizedBox(width: t.Spacing.s8),
                      Flexible(
                        child: Text(secondary!, style: secondaryStyle ?? CardText.secondary, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...<Widget>[const SizedBox(width: t.Spacing.s8), trailing!]
              else if (selected) ...<Widget>[
                const SizedBox(width: t.Spacing.s8),
                const AcpIcon(AcpIcons.check, color: t.Accent.text, size: t.IconSizes.toolbar),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 两行的菜单行（画板 41 的分支：分支名 + 「作者 · 时间 · 主题」）。
class MenuTwoLineRow extends StatelessWidget {
  const MenuTwoLineRow({
    super.key,
    required this.title,
    required this.meta,
    this.selected = false,
    this.showCheck = false,
    this.forceHover = false,
    this.onTap,
  });

  final String title;
  final String meta;
  final bool selected;

  /// 当前分支在行首出对勾（画板 41）。
  final bool showCheck;
  final bool forceHover;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return _RevealWhenSelected(
      selected: selected,
      child: Hoverable(
        onTap: onTap,
        forceHover: forceHover,
        builder: (context, hovered) => Container(
          padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s8, vertical: t.Spacing.s4),
          decoration: BoxDecoration(
            color: selected ? t.Overlays.selected : (hovered ? t.Overlays.hover : null),
            borderRadius: t.Radii.control,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: t.IconSizes.toolbar,
                child: showCheck ? const AcpIcon(AcpIcons.check, color: t.Accent.text, size: t.IconSizes.toolbar) : null,
              ),
              const SizedBox(width: t.Spacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(title, style: CardText.secondary.copyWith(color: selected ? t.Accent.text : t.Neutral.text)),
                    Text(meta, style: t.TextStyles.monoMeta),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 选中行自动露出：`/` 菜单几十条时键盘上下键必然把高亮移出滚动区。没有滚动祖先（画板对照页里的
/// 静态样张）就什么都不做。
///
/// **只在高亮移动时露出，打开那一下不露**：搜索框是 [MenuPopover] 的第一个 child、和条目在同一个
/// 滚动区里，开局就把靠后的当前值滚到正中会顺带把搜索框推出视口，而它正是长列表弹层的主交互
///（发布前审查 P2，2026-09-18）。代价是打开时当前值可能在视口外，翻一下或敲字过滤即可。
class _RevealWhenSelected extends StatefulWidget {
  const _RevealWhenSelected({required this.selected, required this.child});

  final bool selected;
  final Widget child;

  @override
  State<_RevealWhenSelected> createState() => _RevealWhenSelectedState();
}

class _RevealWhenSelectedState extends State<_RevealWhenSelected> {
  @override
  void didUpdateWidget(_RevealWhenSelected oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected && !oldWidget.selected) _reveal();
  }

  /// 改高亮的这一帧还没布局（新位置要等这帧的 layout 才算得出来），推到帧末再滚。
  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.selected) return;
      if (Scrollable.maybeOf(context) == null) return;
      Scrollable.ensureVisible(context, alignment: 0.5);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 分组之间的分隔线。
class MenuDivider extends StatelessWidget {
  const MenuDivider({super.key});

  @override
  Widget build(BuildContext context) => Container(
        height: t.Borders.width,
        margin: const EdgeInsets.symmetric(vertical: t.Spacing.s4),
        color: t.Borders.subtle,
      );
}

/// 弹层顶部的搜索 / 输入框（模型选择器、项目切换、分支切换）。
class MenuSearchField extends StatelessWidget {
  const MenuSearchField({super.key, required this.controller, required this.focusNode, required this.placeholder, this.onChanged, this.onSubmitted});

  final TextEditingController controller;
  final FocusNode focusNode;
  final String placeholder;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: t.Spacing.s4),
      child: Container(
        height: t.Controls.standard,
        decoration: BoxDecoration(
          color: t.Neutral.panel,
          border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
          borderRadius: t.Radii.control,
        ),
        padding: t.Controls.padCompact,
        alignment: Alignment.centerLeft,
        child: AcpTextField(
          controller: controller,
          focusNode: focusNode,
          style: CardText.secondary.copyWith(color: t.Neutral.text),
          placeholder: placeholder,
          placeholderStyle: CardText.secondary.copyWith(color: t.Neutral.placeholder),
          onChanged: onChanged,
          onSubmitted: onSubmitted,
        ),
      ),
    );
  }
}

/// 弹层底部的注释行（mono 11 placeholder）。
class MenuNote extends StatelessWidget {
  const MenuNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(t.Spacing.s8, t.Spacing.s4, t.Spacing.s8, t.Spacing.s8),
        child: Text(text, style: t.TextStyles.monoMeta),
      );
}

/// 布尔开关（画板 40 的 `session.configOptions.boolean`；与画板 27 表单里的同形）。
class MenuToggle extends StatelessWidget {
  const MenuToggle({super.key, required this.on, this.onTap});

  final bool on;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          width: t.Geometry.toggleTrackWidth,
          height: t.Geometry.toggleTrackHeight,
          padding: const EdgeInsets.all(t.Geometry.toggleKnobInset),
          decoration: BoxDecoration(
            color: on ? t.Accent.base : t.Neutral.border,
            borderRadius: t.Radii.pill(t.Geometry.toggleTrackHeight),
          ),
          alignment: on ? Alignment.centerRight : Alignment.centerLeft,
          child: const AspectRatio(
            aspectRatio: 1,
            child: DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: t.Accent.onAccent)),
          ),
        ),
      ),
    );
  }
}
