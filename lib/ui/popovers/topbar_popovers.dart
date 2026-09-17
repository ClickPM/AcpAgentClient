// 画板 41 · 顶栏与侧栏弹层合集：项目切换（This Window / Recent Projects / Open Local Folders）、
// 分支切换（搜索即创建）、新建会话选 agent、线程头 ≡ 菜单（动作由 sessionCapabilities 驱动）、会话删除确认。
// 「项目 = 一个本地目录，作为 session/new 的 cwd」（docs/design.md § 9 裁定）；分支走 git CLI 子进程，
// 非 git 目录时顶栏整块分支区隐藏，本弹层也不会被打开。
// ≡ 菜单里 Resume / Close / Delete 依 `sessionCapabilities` 显示（画板 41 注，acp-projection.md § 5）；动作本身在 R6 接。

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import '../shell/shell_common.dart';
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';
import 'menu.dart';

/// 一个项目 = 一个本地目录。
class ProjectRef {
  const ProjectRef({required this.path, required this.name});

  final String path;
  final String name;
}

/// 一条本地分支（`git for-each-ref` 得出）。
class BranchRef {
  const BranchRef({required this.name, this.author, this.when, this.subject});

  final String name;
  final String? author;
  final String? when;
  final String? subject;

  String get meta => <String>[?author, ?when, ?subject].join(' · ');
}

/// 一个可新建会话的 agent（settings.json 的 `agent_servers`；名字来自设置或 `initialize` 的 agentInfo，代码里没有 agent 名）。
class AgentRef {
  const AgentRef({required this.id, required this.name, this.bundled = false, this.iconSvg});

  final String id;
  final String name;

  /// 随主程序分发的 sidecar（R7）：排在列表最前并与其余用分隔线隔开（画板 41）。
  final bool bundled;

  /// 这个 agent 自己的 `icon.svg`（registry 缓存的那一份，内置 sidecar 是随包带的）：
  /// 「新建会话 · 选 agent」列表里画它，没有时退回画板的单色占位菱形。组合根按 id 查出来给。
  final String? iconSvg;
}

/// 项目切换弹层。
class ProjectSwitcherPopover extends StatelessWidget {
  const ProjectSwitcherPopover({
    super.key,
    required this.openProjects,
    required this.recentProjects,
    required this.searchController,
    required this.searchFocusNode,
    this.currentPath,
    this.query = '',
    this.width = t.Geometry.menuWidth,
    this.onSelect,
    this.onQueryChanged,
    this.onOpenLocalFolders,
  });

  /// 本窗口已打开的项目。
  final List<ProjectRef> openProjects;

  /// 本地最近项目列表（`projects.json`）。
  final List<ProjectRef> recentProjects;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final String? currentPath;
  final String query;
  final double width;
  final ValueChanged<ProjectRef>? onSelect;
  final ValueChanged<String>? onQueryChanged;
  final VoidCallback? onOpenLocalFolders;

  @override
  Widget build(BuildContext context) {
    bool match(ProjectRef p) => query.isEmpty || p.name.toLowerCase().contains(query.toLowerCase());
    final open = openProjects.where(match).toList(growable: false);
    final recent = recentProjects.where(match).toList(growable: false);
    return MenuPopover(
      width: width,
      children: <Widget>[
        MenuSearchField(
          controller: searchController,
          focusNode: searchFocusNode,
          placeholder: 'Search projects...',
          onChanged: onQueryChanged,
        ),
        if (open.isNotEmpty) const MenuGroupLabel('This Window'),
        for (final p in open)
          MenuRow(label: p.name, selected: p.path == currentPath, onTap: onSelect == null ? null : () => onSelect!(p)),
        if (recent.isNotEmpty) const MenuGroupLabel('Recent Projects'),
        for (final p in recent)
          MenuRow(label: p.name, selected: p.path == currentPath, onTap: onSelect == null ? null : () => onSelect!(p)),
        const MenuDivider(),
        MenuRow(icon: AcpIcons.folder, label: 'Open Local Folders', onTap: onOpenLocalFolders),
      ],
    );
  }
}

/// 分支切换弹层：列本地分支、可搜索、可切换（`git switch`）与新建（`git switch -c`）。
class BranchSwitcherPopover extends StatelessWidget {
  const BranchSwitcherPopover({
    super.key,
    required this.branches,
    required this.current,
    required this.controller,
    required this.focusNode,
    this.query = '',
    this.width = t.Geometry.menuWidthWide,
    this.onSwitch,
    this.onCreate,
    this.onQueryChanged,
  });

  final List<BranchRef> branches;
  final String current;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String query;
  final double width;
  final ValueChanged<String>? onSwitch;

  /// `git switch -c <name>`（从当前分支拉）。
  final ValueChanged<String>? onCreate;
  final ValueChanged<String>? onQueryChanged;

  @override
  Widget build(BuildContext context) {
    final visible = <BranchRef>[
      for (final b in branches)
        if (query.isEmpty || b.name.toLowerCase().contains(query.toLowerCase())) b,
    ];
    final exact = branches.any((b) => b.name == query);
    return MenuPopover(
      width: width,
      children: <Widget>[
        MenuSearchField(
          controller: controller,
          focusNode: focusNode,
          placeholder: '搜索或新建分支',
          onChanged: onQueryChanged,
          onSubmitted: (text) {
            if (text.isEmpty) return;
            if (branches.any((b) => b.name == text)) {
              onSwitch?.call(text);
            } else {
              onCreate?.call(text);
            }
          },
        ),
        const MenuGroupLabel('Local Branches'),
        for (final b in visible)
          MenuTwoLineRow(
            title: b.name,
            meta: b.meta,
            selected: b.name == current,
            showCheck: b.name == current,
            onTap: onSwitch == null ? null : () => onSwitch!(b.name),
          ),
        if (query.isNotEmpty && !exact) ...<Widget>[
          const MenuDivider(),
          _CreateBranchRow(name: query, from: current, onTap: onCreate == null ? null : () => onCreate!(query)),
        ],
      ],
    );
  }
}

class _CreateBranchRow extends StatelessWidget {
  const _CreateBranchRow({required this.name, required this.from, this.onTap});

  final String name;
  final String from;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Hoverable(
      onTap: onTap,
      builder: (context, hovered) => Container(
        padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s8, vertical: t.Spacing.s4),
        decoration: BoxDecoration(color: hovered ? t.Overlays.active : t.Overlays.hover, borderRadius: t.Radii.control),
        child: Row(
          children: <Widget>[
            const AcpIcon(AcpIcons.plus, color: t.Neutral.muted, size: t.IconSizes.toolbar),
            const SizedBox(width: t.Spacing.s4),
            Flexible(
              child: Text.rich(
                TextSpan(
                  style: CardText.secondary.copyWith(color: t.Neutral.text),
                  children: <InlineSpan>[
                    const TextSpan(text: 'Create branch '),
                    TextSpan(
                      text: name,
                      style: CardText.secondary.copyWith(
                        color: t.Neutral.text,
                        fontWeight: t.Weights.medium,
                        fontVariations: t.Weights.mediumVariation,
                      ),
                    ),
                    TextSpan(text: " from '$from'"),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 新建会话 · 选 agent：选中后 `session/new`，cwd = 当前项目。
class NewSessionAgentPopover extends StatelessWidget {
  const NewSessionAgentPopover({super.key, required this.agents, this.width = t.Geometry.menuWidthNarrow, this.onSelect});

  final List<AgentRef> agents;
  final double width;
  final ValueChanged<AgentRef>? onSelect;

  @override
  Widget build(BuildContext context) {
    final bundled = <AgentRef>[for (final a in agents) if (a.bundled) a];
    final rest = <AgentRef>[for (final a in agents) if (!a.bundled) a];
    return MenuPopover(
      width: width,
      children: <Widget>[
        for (final a in bundled) _row(a),
        if (bundled.isNotEmpty && rest.isNotEmpty) const MenuDivider(),
        for (final a in rest) _row(a),
      ],
    );
  }

  Widget _row(AgentRef a) => MenuRow(
        leading: AgentMark(svg: a.iconSvg),
        label: a.name,
        onTap: onSelect == null ? null : () => onSelect!(a),
      );
}

/// 线程头 ≡ 菜单。Rename 依 `sessionCapabilities`（改标题），Reload 是客户端本地动作，
/// Resume / Close / Delete 无能力时整行不渲染（画板 41 注）；动作本身在 R6 接。
class ThreadMenuPopover extends StatelessWidget {
  const ThreadMenuPopover({
    super.key,
    this.canRename = true,
    this.canResume = false,
    this.canClose = false,
    this.canDelete = false,
    this.width = t.Geometry.menuWidth,
    this.note = 'Resume / Close / Delete 依 sessionCapabilities 显示',
    this.onRename,
    this.onReload,
    this.onResume,
    this.onCloseSession,
    this.onDelete,
  });

  final bool canRename;
  final bool canResume;
  final bool canClose;
  final bool canDelete;
  final double width;
  final String note;
  final VoidCallback? onRename;
  final VoidCallback? onReload;
  final VoidCallback? onResume;
  final VoidCallback? onCloseSession;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return MenuPopover(
      width: width,
      children: <Widget>[
        if (canRename) MenuRow(icon: AcpIcons.pencil, label: 'Rename Session', onTap: onRename),
        MenuRow(icon: AcpIcons.rotateCw, label: 'Reload Agent', onTap: onReload),
        if (canResume) MenuRow(icon: AcpIcons.play, label: 'Resume Session', onTap: onResume),
        if (canClose) MenuRow(icon: AcpIcons.x, label: 'Close Session', onTap: onCloseSession),
        if (canDelete) ...<Widget>[
          const MenuDivider(),
          MenuRow(icon: AcpIcons.trash, label: 'Delete Session', danger: true, onTap: onDelete),
        ],
        MenuNote(note),
      ],
    );
  }
}

/// 会话删除确认（画板 41）。
class DeleteSessionConfirm extends StatelessWidget {
  const DeleteSessionConfirm({super.key, required this.title, this.width = t.Geometry.menuWidth, this.onCancel, this.onDelete});

  final String title;
  final double width;
  final VoidCallback? onCancel;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return MenuPopover(
      width: width,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(t.Spacing.s8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('删除会话「$title」？', style: CardText.strong),
              const SizedBox(height: t.Spacing.s8),
              Text('会话与其转录会从本地数据目录移除，且会向 agent 发 session/delete。此操作不可撤销。',
                  style: t.TextStyles.secondary.copyWith(height: t.LineHeights.body)),
              const SizedBox(height: t.Spacing.s8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  AcpButton(label: '取消', onTap: onCancel),
                  const SizedBox(width: t.Spacing.s4),
                  AcpButton(label: '删除', labelColor: t.Semantic.error, onTap: onDelete),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
