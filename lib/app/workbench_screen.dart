// 组合根的 widget 装配（R3 接线阶段）：只把 `lib/ui/` 的画板 widget 摆进壳、接上
// [WorkbenchController] 的数据与回调，不改任何布局与 token（CLAUDE.md 规则 3）。
//
// 无边框窗口的拖拽（docs/design.md § 9）：顶栏叠一层在**底下**的 Listener，
// 顶栏里的按钮与芯片在上层先吃掉点击，只有空白处才落到 Listener 上、去调 `startDragging`。

import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../projection/entries.dart';
import '../projection/turn_fold.dart';
import '../projection/session_store.dart';
import '../projection/timeline.dart';
import '../theme/tokens.dart' as t;
import '../ui/files/files_panel.dart';
import '../ui/popovers/composer_popovers.dart';
import '../ui/popovers/session_timeline.dart';
import '../ui/popovers/topbar_popovers.dart';
import '../ui/registry/auth_page.dart';
import '../ui/registry/registry_entry.dart';
import '../ui/registry/registry_panel.dart';
import '../ui/settings/settings_page.dart';
import '../ui/shell/agent_state_bar.dart';
import '../ui/shell/app_shell.dart';
import '../ui/shell/composer.dart';
import '../ui/shell/motion.dart';
import '../ui/shell/right_panel.dart';
import '../ui/shell/shell_common.dart';
import '../ui/shell/sidebar.dart';
import '../ui/shell/session_header.dart';
import '../ui/shell/topbar.dart';
import '../ui/shell/transcript_empty.dart';
import '../ui/terminal/terminal_panel.dart';
import '../ui/traffic/traffic_page.dart';
import '../ui/transcript/awaiting_bar.dart';
import '../ui/transcript/plan_card.dart';
import '../ui/transcript/transcript_list.dart';
import 'clipboard_image.dart';
import 'appearance_prefs.dart';
import 'shell_state.dart';
import 'transcript_fold_anchor.dart';
import 'transcript_jump.dart';
import 'workspace_state.dart';
import 'window_controls.dart';
import 'workbench_controller.dart';

class WorkbenchScreen extends StatefulWidget {
  const WorkbenchScreen({super.key, required this.controller, this.appearance});

  final WorkbenchController controller;

  /// 外观偏好（字体 = 画板 70「外观」，主题 = 画板 07）。gallery 与单测里可以不给：
  /// 设置页的字体小节不出现，侧栏的主题按钮也不出现。
  final AppearanceController? appearance;

  @override
  State<WorkbenchScreen> createState() => _WorkbenchScreenState();
}

class _WorkbenchScreenState extends State<WorkbenchScreen> {
  final ScrollController _transcript = ScrollController();

  /// 转录默认跟随底部：流式回复边来边把视口推到最新一条。用户主动往上翻就停在他翻到的地方，
  /// 直到他自己滚回底部（或发下一条消息）才重新跟随。判据只看「离底部还有多远」——
  /// 我们自己的落点永远是底部，所以跟随不会把自己关掉。
  bool _stick = true;
  bool _followScheduled = false;
  int _corrections = 0;

  /// 正在跟随的那条会话的 store：转录长内容只有它会通知（切会话时换一个）。
  SessionStore? _followed;

  /// 离底部多远还算「在底部」：一格滚轮、一次触控板轻扫都远超这个值，
  /// 而流式增长留下的零头不会被误判成「用户翻上去了」。
  static const double _atBottomSlack = 32;

  /// 画板 43：时间线刚跳到的那条用户气泡（进入画板 11 的点击聚焦态）。转录区里再点一下别处就撤。
  String? _focusedEntryId;

  /// 画板 43 的时间线跳转（惰性列表里的单向步进，见 [TranscriptJump]）。
  late final TranscriptJump _jump = TranscriptJump(controller: _transcript, rows: _rows);

  /// 画板 08 B 的滚动锚点：折 / 展（手动点摘要行，或 stop_reason 到达时自动折叠）前后，
  /// 让这一轮的结论停在原地。见 [TranscriptFoldAnchor]。
  late final TranscriptFoldAnchor _foldAnchor = TranscriptFoldAnchor(
    controller: _transcript,
    entries: () => c.session.store?.entries ?? const <TranscriptEntry>[],
    folds: c.folds,
  );

  /// 转录的行列表。**必须与 `TranscriptList` 算出来的那一份一致**——跳转是按行定位的，
  /// 折叠态（画板 08 B）把折叠块里的条目整批拿掉，两边口径不同就会跳错位。
  List<TranscriptRow> _rows() {
    final List<TranscriptEntry> entries = c.session.store?.entries ?? const <TranscriptEntry>[];
    return buildRows(entries, folds: foldsOf(entries), collapsed: c.folds.isCollapsed);
  }

  WorkbenchController get c => widget.controller;

  /// 输入框连同上方的 `@` / `/` 菜单（画板 42）占的那一块：判断「点在菜单之外」用。
  final GlobalKey _composerArea = GlobalKey();

  @override
  void initState() {
    super.initState();
    c.addListener(_onControllerChanged);
    _transcript.addListener(_onTranscriptScrolled);
    _observeStore();
  }

  @override
  void didUpdateWidget(WorkbenchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != c) {
      oldWidget.controller.removeListener(_onControllerChanged);
      c.addListener(_onControllerChanged);
      _observeStore();
    }
  }

  @override
  void dispose() {
    c.removeListener(_onControllerChanged);
    _followed?.removeListener(_onTranscriptGrew);
    _jump.cancel();
    _foldAnchor.dispose();
    _transcript.removeListener(_onTranscriptScrolled);
    _transcript.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 转录跟随底部

  void _onControllerChanged() => _observeStore();

  /// 换会话（或第一次拿到 store）：跟随对象换一个，并回到这条会话的最新一条——
  /// 转录换了一份内容，停在上一条会话的偏移没有意义。
  void _observeStore() {
    final store = c.session.store;
    if (identical(store, _followed)) return;
    _followed?.removeListener(_onTranscriptGrew);
    _followed = store;
    store?.addListener(_onTranscriptGrew);
    // 转录换了一份内容，上一条会话没跳完的那次跳转、没做完的折叠校正都不再算数。
    _jump.cancel();
    _foldAnchor.cancel();
    _stick = true;
    _scheduleFollow();
  }

  /// 转录长出新内容：流式分块、工具卡、终端输出都会通知这个 store。
  /// **这一刻屏幕上还是旧布局**（重建在本帧稍后），所以 `stop_reason` 那一下的自动折叠要在这里
  /// 先把锚点量下来（复审 high，2026-09-22：自动折叠不经过任何点击回调，第 1 轮实现整条没校正）。
  void _onTranscriptGrew() {
    _foldAnchor.beforeRebuild();
    if (_stick) _scheduleFollow();
  }

  /// 用户（或任何人）把转录滚到了别处：只要落点离底部够远就停掉跟随，滚回底部即自动接上。
  void _onTranscriptScrolled() {
    if (!_transcript.hasClients) return;
    final p = _transcript.position;
    _stick = p.maxScrollExtent - p.pixels <= _atBottomSlack;
  }

  /// 下一帧（新内容已经布完局）把转录推到底。ListView 惰性构建，没建到的那截 maxScrollExtent
  /// 是估出来的：推完可能又长出一段（估少了），也可能反过来落到底部之外（估多了，不纠正的话
  /// 会看见一次回弹）。所以允许连着纠正几帧，两个方向都纠；还够不着就等下一次内容更新。
  void _scheduleFollow({bool correction = false}) {
    if (!correction) _corrections = 0;
    if (_followScheduled) return;
    _followScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followScheduled = false;
      if (!_followToBottom()) return;
      if (++_corrections < 4) _scheduleFollow(correction: true);
    });
  }

  /// 返回值：这一帧是否真推了一下（推了就可能还差一截，值得下一帧再看一眼）。
  bool _followToBottom() {
    if (!mounted || !_stick || !_transcript.hasClients) return false;
    final p = _transcript.position;
    // 用户正在拖 / 触控板正在滑：jumpTo 会 goIdle 把这次拖拽掐断，让他先滑完。
    if (p.userScrollDirection != ScrollDirection.idle) return false;
    if ((p.maxScrollExtent - p.pixels).abs() <= 0.5) return false;
    _transcript.jumpTo(p.maxScrollExtent);
    return true;
  }

  /// 发送时无条件回到底部：刚发出去的这条就在最底下，翻上去看过旧内容之后更要看见它。
  Future<void> _send() {
    _stick = true;
    _scheduleFollow();
    return c.turn.send();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Listener(
        onPointerDown: _closeInlineMenuOnOutsideTap,
        child: AppShell(
          sidebar: c.shell.sidebarCollapsed ? null : _sidebar(),
          main: switch (c.shell.page) {
            MainPage.traffic => _trafficColumn(),
            MainPage.workbench => _workbenchColumn(),
          },
          rightPanel: c.shell.rightPanelOpen ? _rightPanel() : null,
          sidebarWidth: c.shell.sidebarWidth,
          rightPanelWidth: c.shell.rightPanelWidth,
          onResizeSidebar: c.shell.resizeSidebar,
          onResizeRightPanel: c.shell.resizeRightPanel,
          onResizeEnd: c.shell.saveUiState,
          onResetSidebar: c.shell.resetSidebarWidth,
          onResetRightPanel: c.shell.resetRightPanelWidth,
        ),
      ),
    );
  }

  /// 点输入框以外的地方就关掉 `@` / `/` 菜单。它内联在输入框上方（不是 Overlay 里的弹层），
  /// 没有画板 40 / 41 那层「点外即关」的透明遮罩，在这里补上（所有者手测 2026-09-18）。
  /// 画板 40 / 41 的弹层开着时点击先落到它们自己的遮罩上、根本到不了这里，两者不会互相打架。
  void _closeInlineMenuOnOutsideTap(PointerDownEvent event) {
    // 画板 43：转录区里（或壳上任何地方）再点一下就撤掉时间线跳过来的那个聚焦态。
    // 点在气泡自己身上时它自己的本地聚焦接手，看上去焦点环没动过。
    if (_focusedEntryId != null) setState(() => _focusedEntryId = null);
    if (!c.composer.inlineMenuOpen) return;
    final box = _composerArea.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize && box.paintBounds.contains(box.globalToLocal(event.position))) return;
    c.composer.closeInlineMenu();
  }

  // ---------------------------------------------------------------- 侧栏（画板 01 / 04）

  Widget _sidebar() => Sidebar(
        sessions: c.session.visibleSessions,
        now: DateTime.now(),
        query: c.session.search,
        selectedId: c.session.sessionId,
        // 会话头那支笔就地改（下面的 [SessionHeader]），别同时把侧栏这一行也切成输入框。
        renamingId: c.session.renamingInHeader ? null : c.session.renamingSessionId,
        renameController: c.session.rename,
        renameFocusNode: c.session.renameFocus,
        searchController: c.session.sidebarSearch,
        searchFocusNode: c.session.sidebarSearchFocus,
        activeTab: c.shell.activeNavTab,
        onSelect: c.session.selectSession,
        onSearchChanged: c.session.setSearch,
        onClearSearch: c.session.clearSearch,
        onStartRename: c.session.startRename,
        onCommitRename: c.session.commitRename,
        onCancelRename: c.session.cancelRename,
        onDelete: _askDelete,
        onTab: c.shell.toggleNavTab,
        deleteAnchor: c.session.deleteAnchor,
        confirmingDeleteId: c.session.confirmingDeleteId,
        // 画板 06：在跑的出扫掠亮点线，跑完没看的出绿点。
        runningIds: c.session.runningSessionIds,
        unreadIds: c.session.unreadSessionIds,
        // 侧栏标题条与顶栏是同一行：那一段也要能拖窗口、双击最大化。
        dragArea: _dragArea(),
        // 画板 07：标题条右端的浅色 / 深色切换。没有外观控制器（gallery / 单测）就不画这个按钮。
        dark: widget.appearance?.theme == t.AppTheme.dark,
        onToggleTheme: widget.appearance?.toggleTheme,
      );

  void _askDelete(String id) {
    c.session.askDelete(id);
    final title = c.session.sidebarSessions.where((s) => s.id == id).map((s) => s.title).firstOrNull ?? '';
    c.session.deleteAnchor.show(
      (_) => DeleteSessionConfirm(title: title, onCancel: c.session.cancelDelete, onDelete: () => c.session.deleteSession(id)),
      // 点弹层之外关掉也要清「正在确认」，否则那一行的行内动作（锚点所在）会一直挂着（画板 04 的悬浮态）。
      onDismiss: c.session.cancelDelete,
    );
  }

  // ---------------------------------------------------------------- 顶栏（画板 01–04）

  bool get _windowControlsInTopBar => !c.shell.rightPanelOpen;

  Widget _topBar({bool windowControls = true}) {
    return TopBar(
      projectName: c.workspace.project?.name ?? '—',
      branch: c.workspace.branchAreaVisible ? c.workspace.branch : null,
      sidebarCollapsed: c.shell.sidebarCollapsed,
      windowControls: windowControls,
      onToggleSidebar: c.shell.toggleSidebar,
      onProject: _openProjectPopover,
      onBranch: _openBranchPopover,
      onMinimize: AppWindow.minimize,
      onMaximize: AppWindow.toggleMaximize,
      onClose: AppWindow.close,
      projectAnchor: c.workspace.projectAnchor,
      branchAnchor: c.workspace.branchAnchor,
      dragArea: _dragArea(),
      // 画板 08 C：全部工作区在跑会话合计。
      runningTotal: c.session.runningTotal,
      runningWorkspaces: c.session.runningWorkspaceCount,
    );
  }

  /// 无边框窗口的拖拽区（docs/design.md § 9）：空白处按下左键就把拖拽交回系统，
  /// runner 侧连着两次还会判成双击 → 最大化 / 还原。顶栏那一行的三段（侧栏标题条、顶栏、右栏标签条）共用一份装配。
  ///
  /// 必须是 opaque（translucent 的 `hitTest` 返回 false，命中链断在这里），且必须交给各自的条放进它们自己的容器里
  /// ——垫在外面会被那层 BoxDecoration 挡掉（审查 finding P2；回归由 test/ui/topbar_drag_test.dart 钉住）。
  Widget _dragArea() => Listener(
        behavior: HitTestBehavior.opaque,
        // 只认左键：右键 / 中键按下也会走 onPointerDown，转成 `WM_NCLBUTTONDOWN` 会莫名其妙开始拖窗口，
        // 还会被 runner 侧的双击判定算成一次点击。
        onPointerDown: (event) {
          if (event.buttons != kPrimaryButton) return;
          unawaited(AppWindow.startDragging());
        },
      );

  void _openProjectPopover() {
    c.workspace.projectAnchor.toggle((_) => ListenableBuilder(
          listenable: c,
          builder: (context, _) => ProjectSwitcherPopover(
            openProjects: <ProjectRef>[if (c.workspace.project != null) c.workspace.project!],
            recentProjects: <ProjectRef>[
              for (final p in c.workspace.recentProjects)
                if (p.path != c.workspace.project?.path) p,
            ],
            currentPath: c.workspace.project?.path,
            searchController: c.workspace.projectSearch,
            searchFocusNode: c.workspace.projectSearchFocus,
            query: c.workspace.projectSearch.text,
            // 画板 08 C：每一行的在跑会话数。归一化那条规则只有 `WorkspaceState.normalizeCwd` 一份。
            runningOf: (p) => c.session.runningByWorkspace[WorkspaceState.normalizeCwd(p.path)] ?? 0,
            onQueryChanged: (_) => c.refresh(),
            onSelect: c.workspace.openProject,
            onOpenLocalFolders: _pickProjectDirectory,
          ),
        ));
  }

  Future<void> _pickProjectDirectory() async {
    c.workspace.projectAnchor.hide();
    final path = await getDirectoryPath();
    if (path == null) return;
    await c.workspace.openProject(ProjectRef(path: path, name: path.split(RegExp(r'[\\/]')).last));
  }

  void _openBranchPopover() {
    c.workspace.branchAnchor.toggle((_) => ListenableBuilder(
          listenable: c,
          builder: (context, _) => BranchSwitcherPopover(
            branches: c.workspace.branches,
            current: c.workspace.branch ?? '',
            controller: c.workspace.branchInput,
            focusNode: c.workspace.branchFocus,
            query: c.workspace.branchInput.text,
            onQueryChanged: (_) => c.refresh(),
            onSwitch: c.workspace.switchBranch,
            onCreate: c.workspace.createBranch,
          ),
        ));
  }

  // ---------------------------------------------------------------- 中栏（画板 01 / 02 / 03）

  Widget _workbenchColumn() => WorkbenchColumn(
        topBar: _topBar(windowControls: _windowControlsInTopBar),
        sessionHeader: SessionHeader(
          title: c.session.sessionTitle,
          hasAgent: c.session.hasAgent,
          // 等待期（重载 agent / 新建会话）借用同一只 spinner（画板 05 B 组阶段 ①：不新增元素）。
          running: c.session.isRunning || c.session.waitingForAgent,
          // 标题与转录区同起同止（画板 05 A 组）。
          transitionEpoch: c.session.sessionEpoch,
          canRename: c.session.hasSession,
          canReload: c.session.hasSession,
          menuSelected: c.shell.rightPanelOpen,
          iconSvg: c.session.agentIconSvg,
          renaming: c.session.renamingInHeader && c.session.renamingSessionId == c.session.sessionId,
          renameController: c.session.rename,
          renameFocusNode: c.session.renameFocus,
          onRename: c.session.sessionId == null ? null : () => c.session.startRename(c.session.sessionId!, inHeader: true),
          onCommitRename: c.session.commitRename,
          onCancelRename: c.session.cancelRename,
          onNewSession: _openNewSessionPopover,
          onReload: c.session.reloadAgent,
          canTimeline: c.session.hasSession,
          timelineSelected: c.session.timelineAnchor.isShowing,
          onTimeline: _openTimelinePopover,
          onMenu: _openSessionMenu,
          newSessionAnchor: c.session.newSessionAnchor,
          timelineAnchor: c.session.timelineAnchor,
          menuAnchor: c.session.sessionMenuAnchor,
        ),
        body: _body(),
        composer: _composer(),
      );

  /// 画板 05 的 A 组（会话内容整块替换的入场）与 B 组（等待期：重载 agent、新建会话）都落在中栏这一块。
  ///
  /// 两层透明度会相乘：等待期结束那一下 `AnimatedOpacity` 从 `opacity.pending` 回 1，
  /// 同时入场从 0 起，中段比规格的单条曲线低 0.1 上下 —— 200ms 内看不出。
  /// 不给 `AnimatedOpacity` 挂 epoch key 去换严格一致：那会整棵重建转录子树，
  /// 把卡片的展开态与滚动位置一起丢掉，代价远大于收益。
  Widget _body() {
    // 新会话空态自己按 motion.stagger 错开三层（画板 05 A 组的错开规则），那一下**代替**整体入场。
    final staggered = c.session.hasAgent && (c.session.store?.entries.isEmpty ?? true);
    final Widget content = IgnorePointer(
      ignoring: c.session.waitingForAgent,
      child: AnimatedOpacity(
        opacity: c.session.waitingForAgent ? t.Opacities.pending : 1,
        duration: t.Motion.fast,
        curve: t.Motion.curve,
        child: _bodyContent(),
      ),
    );
    return staggered ? content : MotionEnter(epoch: c.session.sessionEpoch, child: content);
  }

  Widget _bodyContent() {
    final store = c.session.store;
    if (store == null || store.entries.isEmpty) {
      return CenteredContent(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ..._stateBars(),
            Expanded(
              child: c.session.hasAgent
                  ? NewSessionEmpty(title: c.session.sessionTitle, transitionEpoch: c.session.sessionEpoch, svg: c.session.agentIconSvg)
                  : NoAgentEmpty(onOpenAgents: () => c.shell.openTab(ShellTab.agents)),
            ),
          ],
        ),
      );
    }
    // 状态条照旧夹到内容列宽，转录区自己铺满整块面板：滚动命中区要含左右留白，
    // 不然鼠标在两侧滚滚轮滚不动（内容仍由 TranscriptList 居中到同一列宽）。
    return Padding(
      padding: const EdgeInsets.only(top: t.Spacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ..._stateBars().map((Widget bar) => ContentWidth(child: bar)),
          Expanded(
            child: TranscriptList(
              store,
              controller: _transcript,
              // 画板 43 的跳转落点：只有这一份转录需要行键（gallery / 单测里不开，见 TranscriptList.trackRows）。
              trackRows: true,
              focusedEntryId: _focusedEntryId,
              agentName: c.session.agentDisplayName,
              onLink: _openLink,
              // 画板 18 的 Go to File 与 21 的行点击：落右栏文件面板并定位到行。
              onGoToFile: (path, line) => c.shell.goToFile(path, line: line),
              onRestore: (message) => c.turn.restore(message),
              onRegenerate: (message, text) => c.turn.restore(message, newText: text),
              onAnswerPermission: c.turn.answerPermission,
              onAnswerElicitation: c.turn.answerElicitation,
              // 画板 23 的停止方块：terminal_kill。
              onKillTerminal: c.turn.killTerminal,
              // 画板 08 B：回合结束后过程折叠为一行摘要；折 / 展经锚点走，结论停在原地。
              folds: c.folds,
              onToggleFold: _foldAnchor.toggle,
            ),
          ),
        ],
      ),
    );
  }

  /// 画板 34：连接状态条与丢弃告警（会话头下）。
  List<Widget> _stateBars() {
    final connection = c.session.connection;
    return <Widget>[
      if (connection != null && c.session.showAgentStateBar) ...<Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s24, vertical: t.Spacing.s4),
          child: AgentStateBar(
            connection,
            onAuthenticate: c.auth.authenticate,
            onRestart: c.session.reloadAgent,
            onOpenTraffic: c.shell.openTraffic,
          ),
        ),
      ],
      if (c.session.droppedUpdates > 0)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s24, vertical: t.Spacing.s4),
          child: DroppedUpdatesBar(count: c.session.droppedUpdates, onOpenTraffic: c.shell.openTraffic),
        ),
    ];
  }

  Future<void> _openLink(String href) async {
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      await launchUrl(uri);
      return;
    }
    // 文件链接与 `@` 芯片（file:// 或裸路径）：右栏文件面板定位。
    await c.shell.goToFile(href);
  }

  // ---------------------------------------------------------------- 输入框（画板 01–03 / 40 / 42）

  Widget _composer() {
    final store = c.session.store;
    final pending = c.turn.firstPending;
    final plan = _activePlan();
    return Composer(
      key: _composerArea,
      controller: c.composer.editor,
      focusNode: c.composer.focus,
      placeholder: c.session.composerPlaceholder,
      // 关掉的会话转录只读（画板 41 的 Close；R6 审查 finding P2）。
      enabled: c.session.canCompose,
      running: c.session.isRunning,
      usage: store?.usage,
      // 会话配置格（画板 40）：一条 configOption 一格，顺序 = 控制器的固定档序；boolean 就地开关。
      options: <ComposerOption>[
        for (final o in c.turn.composerOptions)
          if (o.type == 'boolean')
            ComposerOption(
              label: o.name ?? o.id ?? '',
              on: o.currentValue == true,
              onToggle: () => c.turn.toggleConfigBoolean(o.id ?? '', o.currentValue != true),
            )
          else
            ComposerOption(
              label: configCurrentName(o),
              anchor: c.composer.configAnchor(o.id ?? ''),
              onTap: () => _openSelectPopover(o.id ?? ''),
              maxWidth: o.category == 'model' ? t.Geometry.composerModelMaxWidth : null,
            ),
      ],
      attachments: c.composer.pendingImages,
      onRemoveAttachment: c.composer.removePendingBlock,
      onPaste: c.composer.pasteImageFromClipboard,
      inlineMenu: c.composer.inlineMenu,
      onInlineMenuMove: c.composer.moveInlineMenuSelection,
      onInlineMenuPick: c.composer.pickInlineMenuSelection,
      onInlineMenuDismiss: c.composer.closeInlineMenu,
      docks: <Widget>[
        if (plan != null) PlanCard(plan, initiallyCollapsed: true, cwd: store?.cwd, onDismiss: () => store?.dismissPlan(plan.planId)),
        ?AwaitingDock.forPending(
          pending,
          toolCall: pending is PermissionEntry && pending.toolCallId != null ? store?.toolCalls[pending.toolCallId!] : null,
          cwd: store?.cwd,
          agentName: c.session.agentDisplayName,
          onScroll: _scrollToBottom,
        ),
      ],
      onChanged: c.composer.onChanged,
      onSend: _send,
      onStop: c.turn.cancel,
      onPlus: _openPlusPopover,
      onFollow: _toggleFollow,
      followOn: c.shell.follow,
      onUsage: _openUsagePopover,
      plusAnchor: c.composer.plusAnchor,
      followAnchor: c.composer.followAnchor,
      usageAnchor: c.composer.usageAnchor,
    );
  }

  /// 输入框上方的折叠计划条（画板 29 / 03）：取最近一份未被移除也未被关掉的计划。
  PlanCardEntry? _activePlan() {
    final store = c.session.store;
    if (store == null) return null;
    PlanCardEntry? latest;
    for (final e in store.entries) {
      if (e is PlanCardEntry && !e.removed && !e.dismissed) latest = e;
    }
    return latest;
  }

  void _scrollToBottom() {
    if (!_transcript.hasClients) return;
    _transcript.animateTo(_transcript.position.maxScrollExtent, duration: t.Motion.base, curve: t.Motion.curve);
  }

  /// 按 configOption 的 id 开那一格的 select 弹层（画板 40）：模型那格带搜索框与行首图标占位，其余都是窄弹层。
  void _openSelectPopover(String id) {
    final option = c.turn.optionById(id);
    if (option == null) return;
    final searchable = option.category == 'model';
    c.composer.hideConfigPopovers();
    c.composer.configAnchor(id).showAbove((_) => ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            // `set_config_option` 的响应是全量替换，所以每次 rebuild 都按 id 重新取当前那一份。
            final current = c.turn.optionById(id);
            if (current == null) return const SizedBox.shrink();
            return ConfigSelectPopover(
              option: current,
              title: searchable ? null : current.name,
              searchController: searchable ? c.composer.modelSearch : null,
              searchFocusNode: searchable ? c.composer.modelSearchFocus : null,
              query: searchable ? c.composer.modelSearch.text : '',
              showLeadingMark: searchable,
              width: searchable ? t.Geometry.menuWidthWide : t.Geometry.menuWidthNarrow,
              onQueryChanged: (_) => c.refresh(),
              onSelect: (value) => c.turn.selectConfigValue(current.id ?? '', value),
            );
          },
        ));
  }

  void _openUsagePopover() {
    c.composer.usageAnchor.showAbove((_) => ListenableBuilder(
          listenable: c,
          builder: (context, _) => UsagePopover(
            usage: c.session.store?.usage,
            rulesCount: c.workspace.rulesCount,
            onOpenRules: () {
              c.composer.usageAnchor.hide();
              c.shell.openTab(ShellTab.files);
            },
          ),
        ));
  }

  /// Follow 是客户端本地开关（画板 40 的提示）：点一下切换，开的那一下顺带把提示浮出来。
  void _toggleFollow() {
    c.shell.toggleFollow();
    if (c.shell.follow) {
      c.composer.followAnchor.showAbove((_) => FollowTip(agentName: c.session.agentDisplayName));
    } else {
      c.composer.followAnchor.hide();
    }
  }

  void _openPlusPopover() {
    c.composer.plusAnchor.showAbove((_) => PlusPopover(
          imageEnabled: c.session.canPromptImage,
          onFiles: _addFiles,
          onSessions: _addSession,
          onImage: _addImage,
          onBranchDiff: _addBranchDiff,
        ));
  }

  Future<void> _addFiles() async {
    c.composer.plusAnchor.hide();
    final files = await openFiles();
    for (final f in files) {
      c.composer.addResourceLink(f.path, f.name);
    }
  }

  Future<void> _addImage() async {
    c.composer.plusAnchor.hide();
    const group = XTypeGroup(label: 'images', extensions: <String>['png', 'jpg', 'jpeg', 'gif', 'webp']);
    final file = await openFile(acceptedTypeGroups: <XTypeGroup>[group]);
    if (file == null) return;
    // 大小门与 base64 编码都在 ComposerState 里（超了不编码、记 composer.lastError）：这里一处都不写
    // lastError，门做在这边就是新的分层（BACKLOG 定的落点）。
    c.composer.addImageBytes(await file.readAsBytes(), file.mimeType ?? imageMimeOf(file.path), path: file.path);
  }

  void _addSession() {
    c.composer.plusAnchor.hide();
    final text = c.turn.transcriptText();
    if (text.isEmpty) return;
    c.composer.addEmbeddedResource('acp-session:${c.session.sessionId}', text, mimeType: 'text/plain');
  }

  Future<void> _addBranchDiff() async {
    c.composer.plusAnchor.hide();
    final cwd = c.workspace.project?.path;
    final bridge = c.bridge;
    if (cwd == null || bridge == null) return;
    final result = await bridge.gitDiff(cwd);
    final text = result['text'] as String? ?? '';
    if (text.isEmpty) return;
    c.composer.addEmbeddedResource('acp-branch-diff:${result['command'] ?? 'git diff'}', text, mimeType: 'text/x-diff');
  }

  // ---------------------------------------------------------------- 会话头的两个弹层（画板 41）

  void _openNewSessionPopover() {
    c.session.newSessionAnchor.toggle(
      (_) => ListenableBuilder(
        listenable: c,
        builder: (context, _) => NewSessionAgentPopover(agents: c.agents.installed, onSelect: c.session.newSession),
      ),
      // 右对齐：+ 就贴在窗口右边缘上（会话头右侧 padding 只有 8），左对齐的话 240 宽的弹层整块甩出屏外，
      // 只剩最左边一条（所有者手测 2026-09-17「选择框被截断」）。
      targetAnchor: Alignment.bottomRight,
      followerAnchor: Alignment.topRight,
    );
  }

  /// 会话头 ≡：右栏开关（画板 03 是右栏展开的选中态）。
  /// 画板 41 里同一个 ≡ 又是会话菜单，两张画板对它的语义冲突；**所有者裁定 2026-09-16：≡ 保持右栏开关，
  /// 会话菜单要另开入口得先改设计稿**。所以 R6 只接通菜单的动作（`resumeSession` / `closeSession` /
  /// `deleteSession` 与能力裁剪都在组合根里、有单测覆盖），产品里的入口留到改完画板的那一轮。
  /// 现有入口：删除走侧栏的删除图标（画板 04）；Resume / Close 本轮在产品 UI 上没有入口（见任务卡「已知限制」）。
  void _openSessionMenu() {
    c.shell.toggleRightPanel();
  }

  // ---------------------------------------------------------------- 会话时间线（画板 43）

  /// 会话头 history：开 / 关时间线弹层。右边缘对齐按钮右边缘（按钮贴着中栏右侧，向左展开才落得进窗口）。
  /// 开着的时候再点这个按钮其实到不了这里：弹层那层透明遮罩先吃掉点击并关掉它（与画板 41 的 ≡ / `+` 一样），
  /// 「再点一次关」是这么实现的。这里的 [PopoverHandle.isShowing] 分支只是兜底。
  void _openTimelinePopover() {
    final store = c.session.store;
    if (store == null) return;
    if (c.session.timelineAnchor.isShowing) {
      c.session.timelineAnchor.hide();
      setState(() {});
      return;
    }
    c.session.timelineAnchor.show(
      (_) => ListenableBuilder(
        // 弹层开着时这一轮还在跑：轮列表跟着转录长。
        listenable: store,
        builder: (context, _) => SessionTimelinePopover(
          turns: buildTimeline(store.entries),
          onJump: (row) {
            c.session.timelineAnchor.hide();
            _jumpToEntry(row.entryId, focus: row.isUser);
          },
        ),
      ),
      targetAnchor: Alignment.bottomRight,
      followerAnchor: Alignment.topRight,
      // 点外面 / Esc 关掉时按钮的选中容器要跟着撤（句柄自己不通知组合根）。
      onDismiss: () {
        if (mounted) setState(() {});
      },
    );
    // 按钮的选中容器要当帧出现（画板 05 D 组：0ms，不等弹层）。
    setState(() {});
  }

  /// 画板 43：跳到某个转录条目，落点是「目标块顶边对齐转录区顶部内边距」，不做滚动动画。
  /// 惰性列表里目标行多半还没建出来，怎么一步步挪过去见 [TranscriptJump]。
  void _jumpToEntry(String entryId, {required bool focus}) {
    final store = c.session.store;
    if (store == null) return;
    TranscriptEntry? target;
    for (final e in store.entries) {
      if (e is! TurnEntry && e.id == entryId) target = e;
    }
    if (target == null) return;
    // 画板 08 B：目标落在折叠块里就先展开那一轮——折着的时候它根本没有行，跳过去没有落点。
    // 展开按「展开态记忆」照常记住。
    final TurnFold? fold = foldContaining(foldsOf(store.entries).values, target);
    final bool expanded = fold != null && c.folds.expand(fold);
    // 时间线跳转自己定落点：折叠锚点一律让路——它订阅着 `folds`，刚才那下 `expand` 的通知会把它武装一次
    // （帧后把结论拽回原地、跳转再把目标拉回来，两个 jumpTo 打架）；上一次折 / 展量不到锚点时它起的找回
    // 跳转也可能还在逐帧 jumpTo，不管这次有没有翻面都得停掉（cursor 复审 P3，2026-09-22）。
    _foldAnchor.cancel();
    // 跳到旧内容 = 用户自己翻上去，跟随底部要停掉，否则下一条流式块又把视口拽回最底下。
    _stick = false;
    setState(() => _focusedEntryId = focus ? entryId : null);
    if (!expanded) {
      _jump.start(entryId);
      return;
    }
    // **刚展开的这一帧不能就地开跳**（发布前审查 high，2026-09-22）：`expand` 只是 notifyListeners，
    // 列表要下一帧才按展开后的行重建，而 `TranscriptJump.start` 是当帧同步走一次 `_step` 的。
    // 那一下 `rows()` 已经是展开后的行号，sliver 的 firstChild / lastChild 却还是折叠前的布局；
    // 新行号一旦落进这段过期区间，`_step` 就去问目标行的 RenderObject —— 它这一帧还没建出来，
    // 于是 `cancel()`，`_schedule` 又因为 `_target == null` 不再登记下一帧：回合展开了，滚动却原地不动。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _jump.start(entryId);
    });
  }

  // ---------------------------------------------------------------- 右栏与流量面板（画板 03 / 80）

  // ---------------------------------------------------------------- Agents 面板与认证页（画板 50 / 51 / 52）

  Widget _registryPanel() => RegistryPanel(
        entries: c.agents.visibleEntries,
        searchController: c.agents.search,
        searchFocusNode: c.agents.searchFocus,
        query: c.agents.query,
        filter: c.agents.filter,
        installedCount: c.agents.registry.installedCount,
        notInstalledCount: c.agents.registry.notInstalledCount,
        node: c.agents.registry.node,
        nodeProgress: c.agents.registry.nodeProgress,
        fetchError: c.agents.registry.fetchError,
        fetching: c.agents.registry.fetching,
        fetchedAt: c.agents.registry.fetchedAt,
        showLogFor: c.agents.showLog,
        onSearchChanged: c.agents.setQuery,
        onFilter: c.agents.setFilter,
        onLearnMore: () => _openExternal(registryLearnMoreUrl),
        onRefresh: c.agents.checkForUpdates,
        onDownloadNode: c.agents.downloadNode,
        actionsFor: (entry) => RegistryEntryActions(
          onInstall: () => c.agents.install(entry.id),
          onUpdate: () => c.agents.upgrade(entry.id),
          onRetry: () => c.agents.retry(entry.id),
          onCancel: () => c.agents.cancelInstall(entry.id),
          onRemove: () => c.agents.remove(entry.id),
          onLogin: () => c.auth.open(entry.id),
          onViewLog: () => c.agents.toggleInstallLog(entry.id),
          onOpenRepository: () {
            final url = entry.repository ?? entry.website;
            if (url != null) _openExternal(url);
          },
        ),
      );

  Widget _authPage() => AuthPage(
        agentName: c.auth.agentName,
        authMethods: c.auth.methods,
        message: c.auth.connection?.authMessage,
        selectedMethodId: c.auth.methodId,
        phase: c.auth.phase,
        terminalLabel: c.auth.terminalLabel,
        terminalBuffer: c.auth.terminalBuffer,
        error: c.auth.error,
        requestScope: c.auth.elicitations,
        onSelectMethod: c.auth.selectMethod,
        onStart: c.auth.start,
        onCancel: c.auth.cancel,
        onRetry: c.auth.retry,
        onChangeMethod: c.auth.changeMethod,
        onStopTerminal: c.auth.stopTerminal,
        onTerminalInput: c.auth.terminalInput,
        onOpenUrl: (e) async {
          final url = await c.auth.acceptUrl(e);
          if (url != null) await _openExternal(url);
        },
        onCancelElicitation: c.auth.cancelElicitation,
      );

  Future<void> _openExternal(String href) async {
    final uri = Uri.tryParse(href);
    if (uri != null) await launchUrl(uri);
  }

  // ---------------------------------------------------------------- 设置（画板 70）：右栏的一个标签，不占主区

  /// 右栏能拖到 360，比设置行排得下的最窄宽度还窄（实测 360 时数据目录那行溢出 24–37px）。
  /// 窄于 [t.Geometry.settingsMinWidth] 就整块横向滚，不改画板 70 的行布局（规则 3）。
  Widget _settingsPanel() => LayoutBuilder(
        builder: (context, box) {
          final page = _settingsBody();
          if (box.maxWidth >= t.Geometry.settingsMinWidth) return page;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: t.Geometry.settingsMinWidth, height: box.maxHeight, child: page),
          );
        },
      );

  Widget _settingsBody() => SettingsPage(
        agents: c.agents.installedEntries,
        dataDir: c.dataDir ?? '',
        logPath: c.logPath,
        zedSettingsPath: c.zedSettingsPath,
        zedImportResult: c.agents.zedImportResult,
        node: c.agents.registry.node,
        nodeProgress: c.agents.registry.nodeProgress,
        expandedId: c.agents.expandedId,
        editingId: c.agents.editingId,
        editFields: c.agents.edit,
        onEdit: c.agents.editAgent,
        onCollapse: c.agents.collapseEdit,
        onSave: c.agents.saveCustomAgent,
        onRemove: c.agents.remove,
        onImportZed: c.agents.importZed,
        onDownloadNode: c.agents.downloadNode,
        // 「打开」：目录在资源管理器里开，日志文件用系统默认程序开（都经 url_launcher 的 file: URI）。
        onOpenPath: (path) => launchUrl(Uri.file(path, windows: true)),
        onCopyPath: (path) => Clipboard.setData(ClipboardData(text: path)),
        appearance: widget.appearance,
        onOpenUrl: (url) => launchUrl(Uri.parse(url)),
        folds: c.folds,
      );

  Widget _rightPanel() {
    final active = c.shell.activePanel!;
    // 画板 05 C 组：标签互切时内容区复用 A 组的入场；标签条本身、分隔线、栏宽都不动。
    // `PanelTab` 自带 == / hashCode，直接当触发器。
    final body = _panelBody(active);
    return RightPanel(
      tabs: c.shell.panelTabs,
      active: active,
      onSelect: c.shell.selectPanel,
      onCloseTab: c.shell.closePanel,
      onMinimize: AppWindow.minimize,
      onMaximize: AppWindow.toggleMaximize,
      onCloseWindow: AppWindow.close,
      body: body == null ? null : MotionEnter(epoch: active, child: body),
      // 右栏展开时窗口控制在标签条上：那一段同样是顶栏那一行。
      dragArea: _dragArea(),
    );
  }

  /// 右栏正文：设置（70）、Agents 面板 / 认证页（50 / 52）、文件面板（60）、终端面板（61）。
  Widget? _panelBody(PanelTab active) {
    if (active.shell == ShellTab.settings) return _settingsPanel();
    if (active.shell == ShellTab.agents) return c.auth.agentId == null ? _registryPanel() : _authPage();
    if (active.isTerminal) {
      final term = c.terminals.byId(active.terminalId!);
      if (term == null) return null;
      return TerminalPanel(
        key: ValueKey<String>('terminal-${term.id}'),
        terminal: term,
        autofocus: true,
        onStop: () => c.shell.stopTerminalTab(term.id),
        onClear: () => c.shell.clearTerminalTab(term.id),
        onRestart: () => c.shell.restartTerminalTab(term.id),
      );
    }
    if (active.shell == ShellTab.files) {
      final f = c.files;
      final tree = f.tree;
      if (tree == null) return FileViewerEmpty();
      return FilesPanel(
        tree: tree,
        filterController: f.filter,
        filterFocusNode: f.filterFocus,
        searchMode: f.searchMode,
        searchResults: f.searchResults,
        selectedPath: f.selectedPath,
        viewer: f.viewer,
        viewMode: f.viewMode,
        highlightLine: f.highlightLine,
        onToggleSearch: f.toggleSearch,
        onRefresh: f.refresh,
        onFilterChanged: f.onFilterChanged,
        onOpen: f.open,
        onToggleDir: f.toggleDir,
        onViewMode: f.setViewMode,
        onLink: _openLink,
        treeWidth: c.shell.filesTreeWidth,
        treeCollapsed: c.shell.filesTreeCollapsed,
        onToggleTree: c.shell.toggleFilesTree,
        onResizeTree: c.shell.resizeFilesTree,
        onResizeTreeEnd: c.shell.saveUiState,
        onResetTreeWidth: c.shell.resetFilesTreeWidth,
      );
    }
    return null;
  }

  Widget _trafficColumn() => Container(
        color: t.Surface.canvas,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _topBar(windowControls: _windowControlsInTopBar),
            Expanded(
              child: TrafficPage(
                store: c.traffic,
                filterController: c.shell.trafficFilter,
                filterFocusNode: c.shell.trafficFilterFocus,
                stderrAgentId: c.session.agentId,
              ),
            ),
          ],
        ),
      );
}
