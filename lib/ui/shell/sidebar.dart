// 画板 01 / 04 · 侧栏：应用标题条、会话搜索、会话项（默认 / 悬浮出重命名与删除 / 选中 / 行内重命名）、
// 空态与无结果态、底部四个导航入口。
// 会话列表以本地索引为准（docs/design.md § 3 末条）：时间戳是客户端本地态，「N 条消息」由投影层分组计数得出（画板 04 注）。
// 删除图标需 `sessionCapabilities.delete`，无能力时不渲染（画板 04 注；确认弹层在画板 41）。

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';
import 'app_logo.dart';
import 'popover_anchor.dart';
import 'shell_common.dart';

/// 侧栏一条会话（本地索引 `sessions.json` 的投影：agentId + sessionId + 标题 + cwd + 时间 + 消息计数）。
class SidebarSession {
  const SidebarSession({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.messageCount,
    this.canDelete = true,
    this.iconSvg,
  });

  final String id;
  final String title;
  final DateTime updatedAt;
  final int messageCount;

  /// `sessionCapabilities.delete`。
  final bool canDelete;

  /// 这条会话所属 agent 的 `icon.svg`（registry 缓存；组合根按 `agentId` 查出来给）。没有时是画板的单色占位。
  final String? iconSvg;
}

class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.sessions,
    required this.now,
    required this.searchController,
    required this.searchFocusNode,
    this.query = '',
    this.selectedId,
    this.renamingId,
    this.renameController,
    this.renameFocusNode,
    this.activeTab,
    this.onSelect,
    this.onStartRename,
    this.onCommitRename,
    this.onCancelRename,
    this.onDelete,
    this.onClearSearch,
    this.onSearchChanged,
    this.onTab,
    this.deleteAnchor,
    this.confirmingDeleteId,
  });

  final List<SidebarSession> sessions;
  final DateTime now;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final String query;
  final String? selectedId;
  final String? renamingId;
  final TextEditingController? renameController;
  final FocusNode? renameFocusNode;
  final ShellTab? activeTab;
  final ValueChanged<String>? onSelect;
  final ValueChanged<String>? onStartRename;
  final ValueChanged<String>? onCommitRename;
  final VoidCallback? onCancelRename;
  final ValueChanged<String>? onDelete;
  final VoidCallback? onClearSearch;
  final ValueChanged<String>? onSearchChanged;
  final ValueChanged<ShellTab>? onTab;

  /// 画板 41 的删除确认弹层锚点：只挂在正在确认的那一行上（内容由组合根给）。
  final PopoverHandle? deleteAnchor;
  final String? confirmingDeleteId;

  @override
  Widget build(BuildContext context) {
    return Container(
      // 独立渲染时的缺省宽；装进 [AppShell] 时由它的紧约束覆盖（分栏把手拖出来的宽度单点在那里）。
      width: t.Geometry.sidebarWidth,
      decoration: const BoxDecoration(
        color: t.Neutral.panel,
        border: Border(right: BorderSide(color: t.Borders.subtle, width: t.Borders.width)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SidebarTitleBar(),
          SidebarSearchField(
            controller: searchController,
            focusNode: searchFocusNode,
            onChanged: onSearchChanged,
            onClear: onClearSearch,
          ),
          Expanded(child: _list()),
          SidebarNav(active: activeTab, onTap: onTab),
        ],
      ),
    );
  }

  Widget _list() {
    if (sessions.isEmpty) return SidebarEmpty(searching: query.isNotEmpty);
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: t.Spacing.s4),
      itemCount: sessions.length,
      itemBuilder: (context, i) {
        final s = sessions[i];
        return SidebarSessionRow(
          s,
          now: now,
          query: query,
          selected: s.id == selectedId,
          renaming: s.id == renamingId,
          renameController: renameController,
          renameFocusNode: renameFocusNode,
          onTap: onSelect == null ? null : () => onSelect!(s.id),
          onRename: onStartRename == null ? null : () => onStartRename!(s.id),
          onDelete: onDelete == null ? null : () => onDelete!(s.id),
          onCommitRename: onCommitRename == null ? null : (text) => onCommitRename!(text),
          onCancelRename: onCancelRename,
          deleteAnchor: s.id == confirmingDeleteId ? deleteAnchor : null,
        );
      },
    );
  }
}

/// 列表空态：无会话（画板 01 状态 2）与搜索无结果（画板 04）。
class SidebarEmpty extends StatelessWidget {
  const SidebarEmpty({super.key, required this.searching});

  final bool searching;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s16, vertical: t.Spacing.s24),
        child: Align(
          alignment: searching ? Alignment.center : Alignment.topCenter,
          child: Text(searching ? '未找到匹配会话' : '还没有会话', style: t.TextStyles.secondary.copyWith(color: t.Neutral.placeholder)),
        ),
      );
}

/// 侧栏顶部的应用标题条。
class SidebarTitleBar extends StatelessWidget {
  const SidebarTitleBar({super.key, this.title = 'Agent ACP Client'});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: t.Geometry.barHeight,
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
      padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12),
      child: Row(
        children: <Widget>[
          const AppLogo(),
          const SizedBox(width: t.Spacing.s8),
          Text(title, style: CardText.strong),
        ],
      ),
    );
  }
}

/// 侧栏搜索框（画板 04 的默认 / 输入中两态）。
class SidebarSearchField extends StatelessWidget {
  const SidebarSearchField({super.key, required this.controller, required this.focusNode, this.onChanged, this.onClear});

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      // 条高而不是 [t.Controls.input]：侧栏搜索行与中栏线程头共用第二条分割线，32 对 36 会错开 4px。
      height: t.Geometry.barHeight,
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
      padding: const EdgeInsets.only(left: t.Spacing.s12, right: t.Spacing.s8),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) => Row(
          children: <Widget>[
            AcpIcon(AcpIcons.search, color: value.text.isEmpty ? t.Neutral.placeholder : t.Neutral.muted, size: t.IconSizes.toolbar),
            const SizedBox(width: t.Spacing.s8),
            Expanded(
              child: AcpTextField(
                controller: controller,
                focusNode: focusNode,
                style: t.TextStyles.secondary.copyWith(color: t.Neutral.text, height: t.LineHeights.control),
                placeholder: '搜索会话',
                placeholderStyle: t.TextStyles.secondary.copyWith(color: t.Neutral.placeholder, height: t.LineHeights.control),
                onChanged: onChanged,
              ),
            ),
            if (value.text.isNotEmpty)
              IconButtonGhost(icon: AcpIcons.x, size: t.Controls.compact, onTap: onClear),
          ],
        ),
      ),
    );
  }
}

/// 会话项：默认 / 悬浮（出重命名与删除）/ 选中 / 行内重命名。高 48（[t.Controls.input] + [t.Spacing.s16]）。
class SidebarSessionRow extends StatelessWidget {
  const SidebarSessionRow(
    this.session, {
    super.key,
    required this.now,
    this.query = '',
    this.selected = false,
    this.forceHover = false,
    this.renaming = false,
    this.renameController,
    this.renameFocusNode,
    this.onTap,
    this.onRename,
    this.onDelete,
    this.onCommitRename,
    this.onCancelRename,
    this.deleteAnchor,
  });

  final SidebarSession session;
  final DateTime now;
  final String query;
  final bool selected;
  final bool forceHover;
  final bool renaming;
  final TextEditingController? renameController;
  final FocusNode? renameFocusNode;
  final VoidCallback? onTap;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;
  final ValueChanged<String>? onCommitRename;
  final VoidCallback? onCancelRename;

  /// 删除确认弹层的锚点（画板 41）。
  final PopoverHandle? deleteAnchor;

  static const double height = t.Controls.input + t.Spacing.s16;

  @override
  Widget build(BuildContext context) {
    final meta = '${relativeTime(session.updatedAt, now: now)} · ${session.messageCount} 条消息';
    return Hoverable(
      onTap: renaming ? null : onTap,
      forceHover: forceHover,
      builder: (context, hovered) {
        final inlineEdit = renaming && renameController != null && renameFocusNode != null;
        // 删除确认弹层开着时行内动作**必须**一直在：弹层的「点外面关闭」蒙层盖住整屏、吃掉命中测试，
        // 这一行的 MouseRegion 随即 onExit，光靠 `hovered` 会把删除图标连同挂在它上面的 `PopoverAnchor`
        // 一起从树上摘掉，弹层刚出现一帧就被销毁（所有者手测 2026-09-17「点了没反应」的成因）。
        // `deleteAnchor` 只在 `confirmingDeleteId` 是这一行时才非空（见 [Sidebar._list]）。
        final showActions = (hovered || deleteAnchor != null) && !inlineEdit;
        return Container(
          height: height,
          color: selected ? t.Overlays.selected : (showActions ? t.Overlays.hover : null),
          padding: EdgeInsets.only(left: t.Spacing.s12, right: showActions ? t.Spacing.s8 : t.Spacing.s12),
          child: Row(
            children: <Widget>[
              AgentMark(active: selected, svg: session.iconSvg),
              const SizedBox(width: t.Spacing.s8),
              Expanded(child: inlineEdit ? _renameField() : _titleAndMeta(meta)),
              if (showActions) ...<Widget>[
                IconButtonGhost(icon: AcpIcons.pencil, size: t.Controls.compact, onTap: onRename),
                if (session.canDelete)
                  PopoverAnchor(
                    handle: deleteAnchor,
                    child: IconButtonGhost(icon: AcpIcons.trash, size: t.Controls.compact, onTap: onDelete),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _titleAndMeta(String meta) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text.rich(
            _highlighted(session.title, query, selected),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(meta, style: t.TextStyles.meta.copyWith(fontFeatures: const <FontFeature>[FontFeature.tabularFigures()])),
        ],
      );

  Widget _renameField() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          InlineRenameField(
            controller: renameController!,
            focusNode: renameFocusNode!,
            onSubmitted: onCommitRename,
            onCancel: onCancelRename,
          ),
          const Text('Enter 保存 · Esc 取消', style: t.TextStyles.meta),
        ],
      );

  /// 搜索命中片段用 accent.soft 底 + accent 文字（画板 04「搜索 · 输入中」）。
  static TextSpan _highlighted(String title, String query, bool selected) {
    final base = selected
        ? t.TextStyles.body.copyWith(
            fontWeight: t.Weights.medium,
            fontVariations: t.Weights.mediumVariation,
            color: t.Accent.text,
            height: t.LineHeights.control,
          )
        : t.TextStyles.body.copyWith(height: t.LineHeights.control);
    if (query.isEmpty) return TextSpan(text: title, style: base);
    final idx = title.toLowerCase().indexOf(query.toLowerCase());
    if (idx < 0) return TextSpan(text: title, style: base);
    return TextSpan(
      style: base,
      children: <InlineSpan>[
        TextSpan(text: title.substring(0, idx)),
        TextSpan(
          text: title.substring(idx, idx + query.length),
          style: base.copyWith(color: t.Accent.text, backgroundColor: t.Accent.soft),
        ),
        TextSpan(text: title.substring(idx + query.length)),
      ],
    );
  }
}

/// 侧栏底部导航（画板 01 / 04）：默认 muted、悬浮 text + hover 底、选中 accent + selected 底。
class SidebarNav extends StatelessWidget {
  const SidebarNav({super.key, this.active, this.onTap, this.hoveredTab});

  final ShellTab? active;
  final ValueChanged<ShellTab>? onTap;

  /// gallery 出悬浮样张用（画板 04）。
  final ShellTab? hoveredTab;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: t.Geometry.barHeight,
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
      padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s8),
      child: Row(
        children: <Widget>[
          for (final tab in ShellTab.values) ...<Widget>[
            Hoverable(
              onTap: onTap == null ? null : () => onTap!(tab),
              forceHover: tab == hoveredTab,
              builder: (context, hovered) {
                final selected = tab == active;
                final color = selected ? t.Accent.text : (hovered ? t.Neutral.text : t.Neutral.muted);
                return Container(
                  height: t.Controls.compact,
                  padding: t.Controls.padCompact,
                  decoration: BoxDecoration(
                    color: selected ? t.Overlays.selected : (hovered ? t.Overlays.hover : null),
                    borderRadius: t.Radii.control,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      AcpIcon(tab.icon, color: color, size: t.IconSizes.toolbar),
                      const SizedBox(width: t.Spacing.s4),
                      Text(tab.label, style: t.TextStyles.meta.copyWith(color: color, height: t.LineHeights.control)),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(width: t.Spacing.s4),
          ],
        ],
      ),
    );
  }
}
