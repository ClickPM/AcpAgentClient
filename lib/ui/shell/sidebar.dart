// 画板 01 / 04 / 06 · 侧栏：应用标题条、会话搜索、会话项（默认 / 悬浮出重命名与删除 / 选中 / 行内重命名 /
// 运行中的扫掠亮点线 / 完成未读的绿点）、空态与无结果态、底部四个导航入口。
// 会话列表以本地索引为准（docs/design.md § 3 末条）：时间戳是客户端本地态，「N 条消息」由投影层分组计数得出（画板 04 注）。
// 删除图标一律渲染（确认弹层在画板 41）：它删的首先是本地索引这条记录，agent 侧删不删由组合根判——
// 按 `sessionCapabilities.delete` 裁剪过一版，结果是没声明 delete 的 agent 的会话在侧栏里永远清不掉。

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';
import 'app_logo.dart';
import 'popover_anchor.dart';
import 'shell_common.dart';
import 'tooltip.dart';

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

  /// 给不给删除图标（组合根一律给 true；留着这个开关是为了画板对照能演示两种态）。
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
    this.dragArea,
    this.runningIds = const <String>{},
    this.unreadIds = const <String>{},
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

  /// 无边框窗口的拖拽层（docs/design.md § 9），转交给 [SidebarTitleBar]；内容由组合根给。
  final Widget? dragArea;

  /// 画板 06：有在途 prompt 的会话（出扫掠亮点线）与跑完还没被看过的会话（出绿点）。
  /// 这两个是**高频变动**的运行时态，所以不烘进 [SidebarSession]（它只随本地索引重投影）。
  final Set<String> runningIds;
  final Set<String> unreadIds;

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
          SidebarTitleBar(dragArea: dragArea),
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
          // 扫掠的相位与绿点的淡入淡出都是行内状态：列表按 updatedAt 重排时不给 key，
          // 这些状态会留在原来那个位置上、落到别条会话头上。
          key: ValueKey<String>(s.id),
          now: now,
          running: runningIds.contains(s.id),
          unread: unreadIds.contains(s.id),
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
  const SidebarTitleBar({super.key, this.title = 'Agent ACP Client', this.dragArea});

  final String title;

  /// 无边框窗口的拖拽层（docs/design.md § 9）：这条也是顶栏那一行的一段（画板 01–04 左半），
  /// 要能拖窗口、双击最大化。和 `TopBar.dragArea` 同一种装配 —— 铺在容器**里面**、内容行**下面**。
  final Widget? dragArea;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: t.Geometry.barHeight,
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
      child: Stack(
        // `StackFit.expand`：内容行要拿到与原来一样的紧约束（同 [TopBar]）。
        fit: StackFit.expand,
        children: <Widget>[
          if (dragArea != null) Positioned.fill(child: dragArea!),
          // 这条上没有任何可点的东西，[IgnorePointer] 让 logo 与标题文字也把 pointer 漏给下层拖拽层
          // （`RenderParagraph.hitTestSelf` 恒为 true，不挡住就拖不动标题那一段）。
          IgnorePointer(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12),
              child: Row(
                children: <Widget>[
                  const AppLogo(),
                  const SizedBox(width: t.Spacing.s8),
                  Text(title, style: CardText.strong),
                ],
              ),
            ),
          ),
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
    this.running = false,
    this.unread = false,
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

  /// 画板 06 A：这条会话有在途 prompt —— 行高涨到 [t.Geometry.sidebarRowRunning]、底边出扫掠亮点线。
  final bool running;

  /// 画板 06 B：跑完了、还没被看过 —— 条数文字后出绿点。
  final bool unread;

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
        final inset = EdgeInsets.only(left: t.Spacing.s12, right: showActions ? t.Spacing.s8 : t.Spacing.s12);
        return Container(
          height: running ? t.Geometry.sidebarRowRunning : height,
          color: selected ? t.Overlays.selected : (showActions ? t.Overlays.hover : null),
          // 行内缩在 Stack **里面**：亮点线的 12px 内缩不跟着悬浮态的右内缩变（画板 06 A
          //「悬浮态的重命名 / 删除图标压在细线之上；细线不为它让位」）。
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Padding(
                // 运行中行高涨到 58，文字块仍垂直居中于**上方 50px**（余下让给轨道带），
                // 这样 48 ↔ 58 的切换里文字几乎不动，列表在流式期间不抽动。
                // 非运行态沿用 [inset] 本身，不另写 `bottom: 0`（规则 3：widget 文件里不写间距字面量，0 也算）。
                padding: running
                    ? inset.copyWith(bottom: t.Geometry.sidebarRowRunning - t.Geometry.sidebarRowRunningContent)
                    : inset,
                child: Row(
                  children: <Widget>[
                    AgentMark(active: selected, svg: session.iconSvg),
                    const SizedBox(width: t.Spacing.s8),
                    Expanded(child: inlineEdit ? _renameField() : _titleAndMeta(meta)),
                    if (showActions) ...<Widget>[
                      AcpTooltip(
                        message: 'Edit session title',
                        child: IconButtonGhost(icon: AcpIcons.pencil, size: t.Controls.compact, onTap: onRename),
                      ),
                      if (session.canDelete)
                        AcpTooltip(
                          message: 'Delete session',
                          child: PopoverAnchor(
                            handle: deleteAnchor,
                            child: IconButtonGhost(icon: AcpIcons.trash, size: t.Controls.compact, onTap: onDelete),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              if (running)
                const Positioned(
                  left: t.Sweep.inset,
                  right: t.Sweep.inset,
                  bottom: t.Sweep.bottom,
                  height: t.Sweep.band,
                  child: SessionSweepLine(),
                ),
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
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Flexible(
                child: Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.TextStyles.meta.copyWith(fontFeatures: const <FontFeature>[FontFeature.tabularFigures()]),
                ),
              ),
              // 画板 06 D「两者严格互斥：任何一帧都不得同时出现亮点线与绿点」——
              // 运行中即便还挂着未读标记也先撤掉（下一轮结束时再点亮）。
              SessionUnreadDot(visible: unread && !running),
            ],
          ),
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

/// 画板 06 A · 运行中的会话项底边那条扫掠亮点线：一条常亮的 1px 细线上，一段 [t.Sweep.focusWidth] 的
/// accent 亮点自左向右匀速掠过，走完即从左侧重新进入。**亮点位置与进度无关**，单向、不回弹、不反向。
///
/// 由外面的 [Positioned] 给它 [t.Sweep.band] 高的轨道带，线画在带的中线上。
class SessionSweepLine extends StatefulWidget {
  const SessionSweepLine({super.key});

  @override
  State<SessionSweepLine> createState() => _SessionSweepLineState();
}

class _SessionSweepLineState extends State<SessionSweepLine> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: t.Sweep.cycle);

  /// prefers-reduced-motion。关掉动效时**不能只是不画**：`AnimationController` 在这个开关下会把时长当 0，
  /// `repeat()` 就成了每帧空转一个周期。
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (_reduced) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 降级为同位置、同内缩的静态 1px accent 实线（亮点不移动），运行中依然可辨。
    if (_reduced) return const CustomPaint(painter: _SweepPainter(null));
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => CustomPaint(painter: _SweepPainter(_controller.value)),
    );
  }
}

class _SweepPainter extends CustomPainter {
  const _SweepPainter(this.progress);

  /// 一个周期内的进度 0 → 1（linear）。null = reduced-motion 的静态替代线。
  final double? progress;

  @override
  void paint(Canvas canvas, Size size) {
    final top = (size.height - t.Sweep.trackWidth) / 2;
    final track = Rect.fromLTWH(0, top, size.width, t.Sweep.trackWidth);
    final at = progress;
    if (at == null) {
      canvas.drawRect(track, Paint()..color = t.Sweep.focus);
      return;
    }
    canvas.drawRect(track, Paint()..color = t.Sweep.track);
    // 亮点左端从线左端外（-96）走到线右端外（整条线的宽度），全程匀速；越界的部分裁掉。
    final left = -t.Sweep.focusWidth + (size.width + t.Sweep.focusWidth) * at;
    final focus = Rect.fromLTWH(left, top, t.Sweep.focusWidth, t.Sweep.trackWidth);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(
      focus,
      Paint()
        ..shader = const LinearGradient(colors: t.Sweep.focusGradient, stops: t.Sweep.focusStops).createShader(focus),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SweepPainter old) => old.progress != progress;
}

/// 画板 06 B ·「N 条消息」后的完成未读绿点：出现与清除都**只做 opacity**（[t.Motion.fast] · [t.Motion.curve]），
/// 不缩放、不弹跳、不呼吸、不闪烁；淡出走完就从布局里移除，不留 [t.UnreadDot.gap] 的占位。
class SessionUnreadDot extends StatefulWidget {
  const SessionUnreadDot({super.key, required this.visible});

  final bool visible;

  @override
  State<SessionUnreadDot> createState() => _SessionUnreadDotState();
}

class _SessionUnreadDotState extends State<SessionUnreadDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: t.Motion.fast,
    value: widget.visible ? 1 : 0,
  );
  late final Animation<double> _opacity = _controller.drive(CurveTween(curve: t.Motion.curve));

  @override
  void didUpdateWidget(SessionUnreadDot old) {
    super.didUpdateWidget(old);
    if (widget.visible == old.visible) return;
    if (widget.visible) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _opacity,
        builder: (context, _) {
          if (_opacity.value == 0) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(left: t.UnreadDot.gap),
            child: Opacity(
              opacity: _opacity.value,
              child: Container(
                width: t.UnreadDot.size,
                height: t.UnreadDot.size,
                decoration: const BoxDecoration(color: t.UnreadDot.color, shape: BoxShape.circle),
              ),
            ),
          );
        },
      );
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
            AcpTooltip(
              message: tab.tooltip,
              child: Hoverable(
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
            ),
            const SizedBox(width: t.Spacing.s4),
          ],
        ],
      ),
    );
  }
}
