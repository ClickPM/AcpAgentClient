// 组合根的 widget 装配（R3 接线阶段）：只把 `lib/ui/` 的画板 widget 摆进壳、接上
// [WorkbenchController] 的数据与回调，不改任何布局与 token（CLAUDE.md 规则 3）。
//
// 无边框窗口的拖拽（docs/design.md § 9）：顶栏叠一层在**底下**的 Listener，
// 顶栏里的按钮与芯片在上层先吃掉点击，只有空白处才落到 Listener 上、去调 `startDragging`。

import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../projection/entries.dart';
import '../projection/session_store.dart';
import '../theme/tokens.dart' as t;
import '../ui/files/files_panel.dart';
import '../ui/popovers/composer_popovers.dart';
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
import '../ui/shell/thread_header.dart';
import '../ui/shell/topbar.dart';
import '../ui/shell/transcript_empty.dart';
import '../ui/terminal/terminal_panel.dart';
import '../ui/traffic/traffic_page.dart';
import '../ui/transcript/awaiting_bar.dart';
import '../ui/transcript/plan_card.dart';
import '../ui/transcript/transcript_list.dart';
import 'clipboard_image.dart';
import 'window_controls.dart';
import 'workbench_controller.dart';

class WorkbenchScreen extends StatefulWidget {
  const WorkbenchScreen({super.key, required this.controller});

  final WorkbenchController controller;

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
    _transcript.removeListener(_onTranscriptScrolled);
    _transcript.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 转录跟随底部

  void _onControllerChanged() => _observeStore();

  /// 换会话（或第一次拿到 store）：跟随对象换一个，并回到这条会话的最新一条——
  /// 转录换了一份内容，停在上一条会话的偏移没有意义。
  void _observeStore() {
    final store = c.store;
    if (identical(store, _followed)) return;
    _followed?.removeListener(_onTranscriptGrew);
    _followed = store;
    store?.addListener(_onTranscriptGrew);
    _stick = true;
    _scheduleFollow();
  }

  /// 转录长出新内容：流式分块、工具卡、终端输出都会通知这个 store。
  void _onTranscriptGrew() {
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
    return c.send();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Listener(
        onPointerDown: _closeInlineMenuOnOutsideTap,
        child: AppShell(
          sidebar: c.sidebarCollapsed ? null : _sidebar(),
          main: switch (c.page) {
            MainPage.traffic => _trafficColumn(),
            MainPage.workbench => _workbenchColumn(),
          },
          rightPanel: c.rightPanelOpen ? _rightPanel() : null,
          sidebarWidth: c.sidebarWidth,
          rightPanelWidth: c.rightPanelWidth,
          onResizeSidebar: c.resizeSidebar,
          onResizeRightPanel: c.resizeRightPanel,
          onResizeEnd: c.saveUiState,
          onResetSidebar: c.resetSidebarWidth,
          onResetRightPanel: c.resetRightPanelWidth,
        ),
      ),
    );
  }

  /// 点输入框以外的地方就关掉 `@` / `/` 菜单。它内联在输入框上方（不是 Overlay 里的弹层），
  /// 没有画板 40 / 41 那层「点外即关」的透明遮罩，在这里补上（所有者手测 2026-09-18）。
  /// 画板 40 / 41 的弹层开着时点击先落到它们自己的遮罩上、根本到不了这里，两者不会互相打架。
  void _closeInlineMenuOnOutsideTap(PointerDownEvent event) {
    if (!c.inlineMenuOpen) return;
    final box = _composerArea.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize && box.paintBounds.contains(box.globalToLocal(event.position))) return;
    c.closeInlineMenu();
  }

  // ---------------------------------------------------------------- 侧栏（画板 01 / 04）

  Widget _sidebar() => Sidebar(
        sessions: c.visibleSessions,
        now: DateTime.now(),
        query: c.search,
        selectedId: c.sessionId,
        // 线程头那支笔就地改（下面的 [ThreadHeader]），别同时把侧栏这一行也切成输入框。
        renamingId: c.renamingInHeader ? null : c.renamingSessionId,
        renameController: c.rename,
        renameFocusNode: c.renameFocus,
        searchController: c.sidebarSearch,
        searchFocusNode: c.sidebarSearchFocus,
        activeTab: c.activeNavTab,
        onSelect: c.selectSession,
        onSearchChanged: c.setSearch,
        onClearSearch: c.clearSearch,
        onStartRename: c.startRename,
        onCommitRename: c.commitRename,
        onCancelRename: c.cancelRename,
        onDelete: _askDelete,
        onTab: c.toggleNavTab,
        deleteAnchor: c.deleteAnchor,
        confirmingDeleteId: c.confirmingDeleteId,
        // 画板 06：在跑的出扫掠亮点线，跑完没看的出绿点。
        runningIds: c.runningSessionIds,
        unreadIds: c.unreadSessionIds,
        // 侧栏标题条与顶栏是同一行：那一段也要能拖窗口、双击最大化。
        dragArea: _dragArea(),
      );

  void _askDelete(String id) {
    c.askDelete(id);
    final title = c.sidebarSessions.where((s) => s.id == id).map((s) => s.title).firstOrNull ?? '';
    c.deleteAnchor.show(
      (_) => DeleteSessionConfirm(title: title, onCancel: c.cancelDelete, onDelete: () => c.deleteSession(id)),
      // 点弹层之外关掉也要清「正在确认」，否则那一行的行内动作（锚点所在）会一直挂着（画板 04 的悬浮态）。
      onDismiss: c.cancelDelete,
    );
  }

  // ---------------------------------------------------------------- 顶栏（画板 01–04）

  bool get _windowControlsInTopBar => !c.rightPanelOpen;

  Widget _topBar({bool windowControls = true}) {
    return TopBar(
      projectName: c.project?.name ?? '—',
      branch: c.branchAreaVisible ? c.branch : null,
      sidebarCollapsed: c.sidebarCollapsed,
      windowControls: windowControls,
      onToggleSidebar: c.toggleSidebar,
      onProject: _openProjectPopover,
      onBranch: _openBranchPopover,
      onMinimize: AppWindow.minimize,
      onMaximize: AppWindow.toggleMaximize,
      onClose: AppWindow.close,
      projectAnchor: c.projectAnchor,
      branchAnchor: c.branchAnchor,
      dragArea: _dragArea(),
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
    c.projectAnchor.toggle((_) => ListenableBuilder(
          listenable: c,
          builder: (context, _) => ProjectSwitcherPopover(
            openProjects: <ProjectRef>[if (c.project != null) c.project!],
            recentProjects: <ProjectRef>[
              for (final p in c.recentProjects)
                if (p.path != c.project?.path) p,
            ],
            currentPath: c.project?.path,
            searchController: c.projectSearch,
            searchFocusNode: c.projectSearchFocus,
            query: c.projectSearch.text,
            onQueryChanged: (_) => c.refresh(),
            onSelect: c.openProject,
            onOpenLocalFolders: _pickProjectDirectory,
          ),
        ));
  }

  Future<void> _pickProjectDirectory() async {
    c.projectAnchor.hide();
    final path = await getDirectoryPath();
    if (path == null) return;
    await c.openProject(ProjectRef(path: path, name: path.split(RegExp(r'[\\/]')).last));
  }

  void _openBranchPopover() {
    c.branchAnchor.toggle((_) => ListenableBuilder(
          listenable: c,
          builder: (context, _) => BranchSwitcherPopover(
            branches: c.branches,
            current: c.branch ?? '',
            controller: c.branchInput,
            focusNode: c.branchFocus,
            query: c.branchInput.text,
            onQueryChanged: (_) => c.refresh(),
            onSwitch: c.switchBranch,
            onCreate: c.createBranch,
          ),
        ));
  }

  // ---------------------------------------------------------------- 中栏（画板 01 / 02 / 03）

  Widget _workbenchColumn() => WorkbenchColumn(
        topBar: _topBar(windowControls: _windowControlsInTopBar),
        threadHeader: ThreadHeader(
          title: c.threadTitle,
          hasAgent: c.hasAgent,
          // 等待期（重载 agent / 新建会话）借用同一只 spinner（画板 05 B 组阶段 ①：不新增元素）。
          running: c.isRunning || c.waitingForAgent,
          // 标题与转录区同起同止（画板 05 A 组）。
          transitionEpoch: c.sessionEpoch,
          canRename: c.hasSession,
          canReload: c.hasSession,
          menuSelected: c.rightPanelOpen,
          iconSvg: c.agentIconSvg,
          renaming: c.renamingInHeader && c.renamingSessionId == c.sessionId,
          renameController: c.rename,
          renameFocusNode: c.renameFocus,
          onRename: c.sessionId == null ? null : () => c.startRename(c.sessionId!, inHeader: true),
          onCommitRename: c.commitRename,
          onCancelRename: c.cancelRename,
          onNewSession: _openNewSessionPopover,
          onReload: c.reloadAgent,
          onMenu: _openThreadMenu,
          newSessionAnchor: c.newSessionAnchor,
          menuAnchor: c.threadMenuAnchor,
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
    final staggered = c.hasAgent && (c.store?.entries.isEmpty ?? true);
    final Widget content = IgnorePointer(
      ignoring: c.waitingForAgent,
      child: AnimatedOpacity(
        opacity: c.waitingForAgent ? t.Opacities.pending : 1,
        duration: t.Motion.fast,
        curve: t.Motion.curve,
        child: _bodyContent(),
      ),
    );
    return staggered ? content : MotionEnter(epoch: c.sessionEpoch, child: content);
  }

  Widget _bodyContent() {
    final store = c.store;
    if (store == null || store.entries.isEmpty) {
      return CenteredContent(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ..._stateBars(),
            Expanded(
              child: c.hasAgent
                  ? NewThreadEmpty(title: c.threadTitle, transitionEpoch: c.sessionEpoch, svg: c.agentIconSvg)
                  : NoAgentEmpty(onOpenAgents: () => c.openTab(ShellTab.agents)),
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
              agentName: c.agentDisplayName,
              onLink: _openLink,
              // 画板 18 的 Go to File 与 21 的行点击：落右栏文件面板并定位到行。
              onGoToFile: (path, line) => c.goToFile(path, line: line),
              onRestore: (message) => c.restore(message),
              onRegenerate: (message, text) => c.restore(message, newText: text),
              onAnswerPermission: c.answerPermission,
              onAnswerElicitation: c.answerElicitation,
              // 画板 23 的停止方块：terminal_kill。
              onKillTerminal: c.killTerminal,
            ),
          ),
        ],
      ),
    );
  }

  /// 画板 34：连接状态条与丢弃告警（线程头下）。
  List<Widget> _stateBars() {
    final connection = c.connection;
    return <Widget>[
      if (connection != null && c.showAgentStateBar) ...<Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s24, vertical: t.Spacing.s4),
          child: AgentStateBar(
            connection,
            onAuthenticate: c.authenticate,
            onRestart: c.reloadAgent,
            onOpenTraffic: c.openTraffic,
          ),
        ),
      ],
      if (c.droppedUpdates > 0)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s24, vertical: t.Spacing.s4),
          child: DroppedUpdatesBar(count: c.droppedUpdates, onOpenTraffic: c.openTraffic),
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
    await c.goToFile(href);
  }

  // ---------------------------------------------------------------- 输入框（画板 01–03 / 40 / 42）

  Widget _composer() {
    final store = c.store;
    final pending = c.firstPending;
    final plan = _activePlan();
    return Composer(
      key: _composerArea,
      controller: c.composer,
      focusNode: c.composerFocus,
      placeholder: c.composerPlaceholder,
      // 关掉的会话转录只读（画板 41 的 Close；R6 审查 finding P2）。
      enabled: c.canCompose,
      running: c.isRunning,
      usage: store?.usage,
      // 会话配置格（画板 40）：一条 configOption 一格，顺序 = 控制器的固定档序；boolean 就地开关。
      options: <ComposerOption>[
        for (final o in c.composerOptions)
          if (o.type == 'boolean')
            ComposerOption(
              label: o.name ?? o.id ?? '',
              on: o.currentValue == true,
              onToggle: () => c.toggleConfigBoolean(o.id ?? '', o.currentValue != true),
            )
          else
            ComposerOption(
              label: configCurrentName(o),
              anchor: c.configAnchor(o.id ?? ''),
              onTap: () => _openSelectPopover(o.id ?? ''),
              maxWidth: o.category == 'model' ? t.Geometry.composerModelMaxWidth : null,
            ),
      ],
      attachments: c.pendingImages,
      onRemoveAttachment: c.removePendingBlock,
      onPaste: c.pasteImageFromClipboard,
      inlineMenu: c.inlineMenu,
      onInlineMenuMove: c.moveInlineMenuSelection,
      onInlineMenuPick: c.pickInlineMenuSelection,
      onInlineMenuDismiss: c.closeInlineMenu,
      docks: <Widget>[
        if (plan != null) PlanCard(plan, initiallyCollapsed: true, cwd: store?.cwd, onDismiss: () => store?.dismissPlan(plan.planId)),
        ?AwaitingDock.forPending(
          pending,
          toolCall: pending is PermissionEntry && pending.toolCallId != null ? store?.toolCalls[pending.toolCallId!] : null,
          cwd: store?.cwd,
          agentName: c.agentDisplayName,
          onScroll: _scrollToBottom,
        ),
      ],
      onChanged: c.onComposerChanged,
      onSend: _send,
      onStop: c.cancel,
      onPlus: _openPlusPopover,
      onFollow: _toggleFollow,
      followOn: c.follow,
      onUsage: _openUsagePopover,
      plusAnchor: c.plusAnchor,
      followAnchor: c.followAnchor,
      usageAnchor: c.usageAnchor,
    );
  }

  /// 输入框上方的折叠计划条（画板 29 / 03）：取最近一份未被移除也未被关掉的计划。
  PlanCardEntry? _activePlan() {
    final store = c.store;
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
    final option = c.optionById(id);
    if (option == null) return;
    final searchable = option.category == 'model';
    c.hideConfigPopovers();
    c.configAnchor(id).showAbove((_) => ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            // `set_config_option` 的响应是全量替换，所以每次 rebuild 都按 id 重新取当前那一份。
            final current = c.optionById(id);
            if (current == null) return const SizedBox.shrink();
            return ConfigSelectPopover(
              option: current,
              title: searchable ? null : current.name,
              searchController: searchable ? c.modelSearch : null,
              searchFocusNode: searchable ? c.modelSearchFocus : null,
              query: searchable ? c.modelSearch.text : '',
              showLeadingMark: searchable,
              width: searchable ? t.Geometry.menuWidthWide : t.Geometry.menuWidthNarrow,
              onQueryChanged: (_) => c.refresh(),
              onSelect: (value) => c.selectConfigValue(current.id ?? '', value),
            );
          },
        ));
  }

  void _openUsagePopover() {
    c.usageAnchor.showAbove((_) => ListenableBuilder(
          listenable: c,
          builder: (context, _) => UsagePopover(
            usage: c.store?.usage,
            rulesCount: c.rulesCount,
            onOpenRules: () {
              c.usageAnchor.hide();
              c.openTab(ShellTab.files);
            },
          ),
        ));
  }

  /// Follow 是客户端本地开关（画板 40 的提示）：点一下切换，开的那一下顺带把提示浮出来。
  void _toggleFollow() {
    c.toggleFollow();
    if (c.follow) {
      c.followAnchor.showAbove((_) => FollowTip(agentName: c.agentDisplayName));
    } else {
      c.followAnchor.hide();
    }
  }

  void _openPlusPopover() {
    c.plusAnchor.showAbove((_) => PlusPopover(
          imageEnabled: c.canPromptImage,
          onFiles: _addFiles,
          onThreads: _addThread,
          onImage: _addImage,
          onBranchDiff: _addBranchDiff,
        ));
  }

  Future<void> _addFiles() async {
    c.plusAnchor.hide();
    final files = await openFiles();
    for (final f in files) {
      c.addResourceLink(f.path, f.name);
    }
  }

  Future<void> _addImage() async {
    c.plusAnchor.hide();
    const group = XTypeGroup(label: 'images', extensions: <String>['png', 'jpg', 'jpeg', 'gif', 'webp']);
    final file = await openFile(acceptedTypeGroups: <XTypeGroup>[group]);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    c.addImage(base64Encode(bytes), file.mimeType ?? imageMimeOf(file.path), path: file.path);
  }

  void _addThread() {
    c.plusAnchor.hide();
    final text = c.transcriptText();
    if (text.isEmpty) return;
    c.addEmbeddedResource('acp-thread:${c.sessionId}', text, mimeType: 'text/plain');
  }

  Future<void> _addBranchDiff() async {
    c.plusAnchor.hide();
    final cwd = c.project?.path;
    final bridge = c.bridge;
    if (cwd == null || bridge == null) return;
    final result = await bridge.gitDiff(cwd);
    final text = result['text'] as String? ?? '';
    if (text.isEmpty) return;
    c.addEmbeddedResource('acp-branch-diff:${result['command'] ?? 'git diff'}', text, mimeType: 'text/x-diff');
  }

  // ---------------------------------------------------------------- 线程头的两个弹层（画板 41）

  void _openNewSessionPopover() {
    c.newSessionAnchor.toggle(
      (_) => ListenableBuilder(
        listenable: c,
        builder: (context, _) => NewSessionAgentPopover(agents: c.installedAgents, onSelect: c.newSession),
      ),
      // 右对齐：+ 就贴在窗口右边缘上（线程头右侧 padding 只有 8），左对齐的话 240 宽的弹层整块甩出屏外，
      // 只剩最左边一条（所有者手测 2026-09-17「选择框被截断」）。
      targetAnchor: Alignment.bottomRight,
      followerAnchor: Alignment.topRight,
    );
  }

  /// 线程头 ≡：右栏开关（画板 03 是右栏展开的选中态）。
  /// 画板 41 里同一个 ≡ 又是会话菜单，两张画板对它的语义冲突；**所有者裁定 2026-09-16：≡ 保持右栏开关，
  /// 会话菜单要另开入口得先改设计稿**。所以 R6 只接通菜单的动作（`resumeSession` / `closeSession` /
  /// `deleteSession` 与能力裁剪都在组合根里、有单测覆盖），产品里的入口留到改完画板的那一轮。
  /// 现有入口：删除走侧栏的删除图标（画板 04）；Resume / Close 本轮在产品 UI 上没有入口（见任务卡「已知限制」）。
  void _openThreadMenu() {
    c.toggleRightPanel();
  }

  // ---------------------------------------------------------------- 右栏与流量面板（画板 03 / 80）

  // ---------------------------------------------------------------- Agents 面板与认证页（画板 50 / 51 / 52）

  Widget _registryPanel() => RegistryPanel(
        entries: c.visibleRegistryEntries,
        searchController: c.registrySearch,
        searchFocusNode: c.registrySearchFocus,
        query: c.registryQuery,
        filter: c.registryFilter,
        installedCount: c.registry.installedCount,
        notInstalledCount: c.registry.notInstalledCount,
        node: c.registry.node,
        nodeProgress: c.registry.nodeProgress,
        fetchError: c.registry.fetchError,
        fetching: c.registry.fetching,
        showLogFor: c.registryShowLog,
        onSearchChanged: c.setRegistryQuery,
        onFilter: c.setRegistryFilter,
        onLearnMore: () => _openExternal(registryLearnMoreUrl),
        onDownloadNode: c.downloadNode,
        actionsFor: (entry) => RegistryEntryActions(
          onInstall: () => c.installAgent(entry.id),
          onRetry: () => c.installAgent(entry.id),
          onCancel: () => c.cancelInstall(entry.id),
          onRemove: () => c.removeAgent(entry.id),
          onLogin: () => c.openAuth(entry.id),
          onViewLog: () => c.toggleInstallLog(entry.id),
          onOpenRepository: () {
            final url = entry.repository ?? entry.website;
            if (url != null) _openExternal(url);
          },
        ),
      );

  Widget _authPage() => AuthPage(
        agentName: c.authAgentName,
        authMethods: c.authMethods,
        message: c.authConnection?.authMessage,
        selectedMethodId: c.authMethodId,
        phase: c.authPhase,
        terminalLabel: c.authTerminalLabel,
        terminalBuffer: c.authTerminalBuffer,
        error: c.authError,
        requestScope: c.authElicitations,
        onSelectMethod: c.selectAuthMethod,
        onStart: c.startAuth,
        onCancel: c.cancelAuth,
        onRetry: c.retryAuth,
        onChangeMethod: c.changeAuthMethod,
        onStopTerminal: c.stopAuthTerminal,
        onTerminalInput: c.authTerminalInput,
        onOpenUrl: (e) async {
          final url = await c.acceptElicitationUrl(e);
          if (url != null) await _openExternal(url);
        },
        onCancelElicitation: c.cancelElicitation,
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
        agents: c.installedEntries,
        dataDir: c.dataDir ?? '',
        logPath: c.logPath,
        zedSettingsPath: c.zedSettingsPath,
        zedImportResult: c.zedImportResult,
        node: c.registry.node,
        nodeProgress: c.registry.nodeProgress,
        expandedId: c.settingsExpandedId,
        editingId: c.settingsEditingId,
        editFields: c.settingsEdit,
        onEdit: c.editAgent,
        onCollapse: c.collapseSettingsEdit,
        onSave: c.saveCustomAgent,
        onRemove: c.removeAgent,
        onImportZed: c.importZed,
        onDownloadNode: c.downloadNode,
        // 「打开」：目录在资源管理器里开，日志文件用系统默认程序开（都经 url_launcher 的 file: URI）。
        onOpenPath: (path) => launchUrl(Uri.file(path, windows: true)),
        onCopyPath: (path) => Clipboard.setData(ClipboardData(text: path)),
      );

  Widget _rightPanel() {
    final active = c.activePanel!;
    // 画板 05 C 组：标签互切时内容区复用 A 组的入场；标签条本身、分隔线、栏宽都不动。
    // `PanelTab` 自带 == / hashCode，直接当触发器。
    final body = _panelBody(active);
    return RightPanel(
      tabs: c.panelTabs,
      active: active,
      onSelect: c.selectPanel,
      onCloseTab: c.closePanel,
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
    if (active.shell == ShellTab.agents) return c.authAgentId == null ? _registryPanel() : _authPage();
    if (active.isTerminal) {
      final term = c.terminals.byId(active.terminalId!);
      if (term == null) return null;
      return TerminalPanel(
        key: ValueKey<String>('terminal-${term.id}'),
        terminal: term,
        autofocus: true,
        onStop: () => c.stopTerminalTab(term.id),
        onClear: () => c.clearTerminalTab(term.id),
        onRestart: () => c.restartTerminalTab(term.id),
      );
    }
    if (active.shell == ShellTab.files) {
      final f = c.files;
      final tree = f.tree;
      if (tree == null) return const FileViewerEmpty();
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
        treeWidth: c.filesTreeWidth,
        treeCollapsed: c.filesTreeCollapsed,
        onToggleTree: c.toggleFilesTree,
        onResizeTree: c.resizeFilesTree,
        onResizeTreeEnd: c.saveUiState,
        onResetTreeWidth: c.resetFilesTreeWidth,
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
                filterController: c.trafficFilter,
                filterFocusNode: c.trafficFilterFocus,
                stderrAgentId: c.agentId,
              ),
            ),
          ],
        ),
      );
}
