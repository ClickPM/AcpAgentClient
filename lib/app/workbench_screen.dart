// 组合根的 widget 装配（R3 接线阶段）：只把 `lib/ui/` 的画板 widget 摆进壳、接上
// [WorkbenchController] 的数据与回调，不改任何布局与 token（CLAUDE.md 规则 3）。
//
// 无边框窗口的拖拽（docs/design.md § 9）：顶栏叠一层在**底下**的 Listener，
// 顶栏里的按钮与芯片在上层先吃掉点击，只有空白处才落到 Listener 上、去调 `startDragging`。

import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../projection/entries.dart';
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
import '../ui/shell/popover_anchor.dart';
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
        main: switch (c.page) {
          MainPage.traffic => _trafficColumn(),
          MainPage.settings => _settingsColumn(),
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
        activeTab: c.activeNavTab,
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
      // 无边框窗口的拖拽区：顶栏空白处按下鼠标就把拖拽交回系统（docs/design.md § 9）。
      // 必须是 opaque（translucent 的 `hitTest` 返回 false，命中链断在这里），且必须交给 TopBar 放进它自己的容器里
      // ——垫在外面会被顶栏的 BoxDecoration 挡掉（审查 finding P2；回归由 test/ui/topbar_drag_test.dart 钉住）。
      dragArea: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => AppWindow.startDragging(),
      ),
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
        topBar: _topBar(windowControls: _windowControlsInTopBar),
        threadHeader: ThreadHeader(
          title: c.threadTitle,
          hasAgent: c.hasAgent,
          running: c.isRunning,
          canRename: c.hasAgent,
          canReload: c.hasAgent,
          menuSelected: c.rightPanelOpen,
          iconSvg: c.agentIconSvg,
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
              // 画板 18 的 Go to File 与 21 的行点击：落右栏文件面板并定位到行。
              onGoToFile: (path, line) => c.goToFile(path, line: line),
              onRestore: (turn) => c.restore(turn),
              onRegenerate: (turn, text) => c.restore(turn, newText: text),
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
      controller: c.composer,
      focusNode: c.composerFocus,
      placeholder: c.composerPlaceholder,
      // 关掉的会话转录只读（画板 41 的 Close；R6 审查 finding P2）。
      enabled: c.hasAgent && !c.sessionClosed,
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
      onFollow: _toggleFollow,
      followOn: c.follow,
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

  // ---------------------------------------------------------------- 设置页（画板 70）

  Widget _settingsColumn() => Container(
        color: t.Surface.canvas,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _topBar(windowControls: _windowControlsInTopBar),
            Expanded(
              child: SettingsPage(
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
              ),
            ),
          ],
        ),
      );

  Widget _rightPanel() {
    final active = c.activePanel!;
    return RightPanel(
      tabs: c.panelTabs,
      active: active,
      onSelect: c.selectPanel,
      onCloseTab: c.closePanel,
      onClose: c.closeRightPanel,
      onMinimize: AppWindow.minimize,
      onMaximize: AppWindow.toggleMaximize,
      onCloseWindow: AppWindow.close,
      body: _panelBody(active),
    );
  }

  /// 右栏正文：Agents 面板 / 认证页（50 / 52）、文件面板（60）、终端面板（61）。
  Widget? _panelBody(PanelTab active) {
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
        onCollapseAll: f.collapseAll,
        onRefresh: f.refresh,
        onFilterChanged: f.onFilterChanged,
        onOpen: f.open,
        onToggleDir: f.toggleDir,
        onViewMode: f.setViewMode,
        onLink: _openLink,
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
