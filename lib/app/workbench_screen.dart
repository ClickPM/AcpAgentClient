// 组合根的 widget 装配（R3 接线阶段）：只把 `lib/ui/` 的画板 widget 摆进壳、接上
// [WorkbenchController] 的数据与回调，不改任何布局与 token（CLAUDE.md 规则 3）。
//
// 无边框窗口的拖拽（docs/design.md § 9）：顶栏叠一层在**底下**的 Listener，
// 顶栏里的按钮与芯片在上层先吃掉点击，只有空白处才落到 Listener 上、去调 `startDragging`。

import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../projection/entries.dart';
import '../theme/tokens.dart' as t;
import '../ui/popovers/composer_popovers.dart';
import '../ui/popovers/topbar_popovers.dart';
import '../ui/shell/agent_state_bar.dart';
import '../ui/shell/app_shell.dart';
import '../ui/shell/composer.dart';
import '../ui/shell/popover_anchor.dart';
import '../ui/shell/right_panel.dart';
import '../ui/shell/shell_common.dart';
import '../ui/shell/sidebar.dart';
import '../ui/shell/thread_header.dart';
import '../ui/shell/topbar.dart';
import '../ui/shell/transcript_empty.dart';
import '../ui/traffic/traffic_page.dart';
import '../ui/transcript/awaiting_bar.dart';
import '../ui/transcript/plan_card.dart';
import '../ui/transcript/transcript_list.dart';
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

  WorkbenchController get c => widget.controller;

  @override
  void dispose() {
    _transcript.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => AppShell(
        sidebar: c.sidebarCollapsed ? null : _sidebar(),
        main: c.page == MainPage.traffic ? _trafficColumn() : _workbenchColumn(),
        rightPanel: c.rightTab == null ? null : _rightPanel(),
      ),
    );
  }

  // ---------------------------------------------------------------- 侧栏（画板 01 / 04）

  Widget _sidebar() => Sidebar(
        sessions: c.visibleSessions,
        now: DateTime.now(),
        query: c.search,
        selectedId: c.sessionId,
        renamingId: c.renamingSessionId,
        renameController: c.rename,
        renameFocusNode: c.renameFocus,
        searchController: c.sidebarSearch,
        searchFocusNode: c.sidebarSearchFocus,
        activeTab: c.rightTab,
        onSelect: c.selectSession,
        onSearchChanged: c.setSearch,
        onClearSearch: c.clearSearch,
        onStartRename: c.startRename,
        onCommitRename: c.commitRename,
        onCancelRename: c.cancelRename,
        onDelete: _askDelete,
        onTab: c.openTab,
        deleteAnchor: c.deleteAnchor,
        confirmingDeleteId: c.confirmingDeleteId,
      );

  void _askDelete(String id) {
    c.askDelete(id);
    final title = c.sidebarSessions.where((s) => s.id == id).map((s) => s.title).firstOrNull ?? '';
    c.deleteAnchor.show(
      (_) => DeleteSessionConfirm(title: title, onCancel: c.cancelDelete, onDelete: () => c.deleteSession(id)),
    );
  }

  // ---------------------------------------------------------------- 顶栏（画板 01–04）

  Widget _topBar({bool windowControls = true}) {
    final bar = TopBar(
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
    );
    // 拖拽区：Listener 在底下，顶栏的可点控件在上面先吃掉事件（无边框窗口，docs/design.md § 9）。
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => AppWindow.startDragging(),
          ),
        ),
        bar,
      ],
    );
  }

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
        topBar: _topBar(windowControls: c.rightTab == null),
        threadHeader: ThreadHeader(
          title: c.threadTitle,
          hasAgent: c.hasAgent,
          running: c.isRunning,
          canRename: c.hasAgent,
          canReload: c.hasAgent,
          menuSelected: c.rightTab != null,
          onRename: c.sessionId == null ? null : () => c.startRename(c.sessionId!),
          onNewSession: _openNewSessionPopover,
          onReload: c.reloadAgent,
          onMenu: _openThreadMenu,
          newSessionAnchor: c.newSessionAnchor,
          menuAnchor: c.threadMenuAnchor,
        ),
        body: _body(),
        composer: _composer(),
      );

  Widget _body() {
    final store = c.store;
    if (store == null || store.entries.isEmpty) {
      return CenteredContent(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ..._stateBars(),
            Expanded(
              child: c.hasAgent
                  ? NewThreadEmpty(title: c.threadTitle)
                  : NoAgentEmpty(onOpenAgents: () => c.openTab(ShellTab.agents)),
            ),
          ],
        ),
      );
    }
    return CenteredContent(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ..._stateBars(),
          Expanded(
            child: TranscriptList(
              store,
              controller: _transcript,
              agentName: c.agentDisplayName,
              onLink: _openLink,
              onGoToFile: (path, line) => c.openTab(ShellTab.files),
              onRestore: (turn) => c.restore(turn),
              onRegenerate: (turn, text) => c.restore(turn, newText: text),
              onAnswerPermission: c.answerPermission,
              onAnswerElicitation: c.answerElicitation,
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
    // 文件链接：R4 接右栏文件面板，本轮先把面板打开。
    c.openTab(ShellTab.files);
  }

  // ---------------------------------------------------------------- 输入框（画板 01–03 / 40 / 42）

  Widget _composer() {
    final store = c.store;
    final pending = c.firstPending;
    final plan = _activePlan();
    return Composer(
      controller: c.composer,
      focusNode: c.composerFocus,
      placeholder: c.composerPlaceholder,
      enabled: c.hasAgent,
      running: c.isRunning,
      usage: store?.usage,
      model: _currentName('model'),
      thoughtLevel: _currentName('thought_level'),
      mode: _currentName('mode'),
      inlineMenu: c.inlineMenu,
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
      onSend: c.send,
      onStop: c.cancel,
      onPlus: _openPlusPopover,
      onFollow: _openFollowTip,
      onUsage: _openUsagePopover,
      onModel: () => _openSelectPopover('model', c.modelAnchor, searchable: true),
      onThoughtLevel: () => _openSelectPopover('thought_level', c.thoughtAnchor),
      onMode: () => _openSelectPopover('mode', c.modeAnchor),
      plusAnchor: c.plusAnchor,
      followAnchor: c.followAnchor,
      usageAnchor: c.usageAnchor,
      modelAnchor: c.modelAnchor,
      thoughtAnchor: c.thoughtAnchor,
      modeAnchor: c.modeAnchor,
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

  String? _currentName(String category) {
    final option = c.optionOf(category);
    return option == null ? null : configCurrentName(option);
  }

  void _scrollToBottom() {
    if (!_transcript.hasClients) return;
    _transcript.animateTo(_transcript.position.maxScrollExtent, duration: t.Motion.base, curve: t.Motion.curve);
  }

  void _openSelectPopover(String category, PopoverHandle anchor, {bool searchable = false}) {
    final option = c.optionOf(category);
    if (option == null) return;
    c.modelAnchor.hide();
    c.thoughtAnchor.hide();
    c.modeAnchor.hide();
    anchor.showAbove((_) => ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            final current = c.optionOf(category);
            if (current == null) return const SizedBox.shrink();
            return ConfigSelectPopover(
              option: current,
              title: searchable ? null : current.name,
              searchController: searchable ? c.modelSearch : null,
              searchFocusNode: searchable ? c.modelSearchFocus : null,
              query: searchable ? c.modelSearch.text : '',
              showLeadingMark: category == 'model',
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

  void _openFollowTip() {
    c.followAnchor.showAbove((_) => FollowTip(agentName: c.agentDisplayName));
  }

  void _openPlusPopover() {
    final image = c.connection?.agentCapabilities?['promptCapabilities'];
    final imageEnabled = image is Map ? image['image'] == true : false;
    c.plusAnchor.showAbove((_) => PlusPopover(
          imageEnabled: imageEnabled,
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
    c.addImage(base64Encode(bytes), file.mimeType ?? 'image/png');
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
    c.newSessionAnchor.toggle((_) => ListenableBuilder(
          listenable: c,
          builder: (context, _) => NewSessionAgentPopover(agents: c.installedAgents, onSelect: c.newSession),
        ));
  }

  void _openThreadMenu() {
    // ≡ 同时是右栏开关（画板 03 是选中态）：先开右栏，菜单从会话项的 ≡ 走。
    c.toggleRightPanel();
  }

  // ---------------------------------------------------------------- 右栏与流量面板（画板 03 / 80）

  Widget _rightPanel() => RightPanel(
        tabs: c.openTabs,
        active: c.rightTab!,
        onSelect: c.openTab,
        onCloseTab: c.closeTab,
        onClose: c.closeRightPanel,
        onMinimize: AppWindow.minimize,
        onMaximize: AppWindow.toggleMaximize,
        onCloseWindow: AppWindow.close,
      );

  Widget _trafficColumn() => Container(
        color: t.Surface.canvas,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _topBar(windowControls: c.rightTab == null),
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
