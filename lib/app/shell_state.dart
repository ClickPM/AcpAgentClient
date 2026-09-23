// 壳的本地 UI 态（R7.5 从 workbench_controller.dart 拆出）：三栏宽度与收起态（画板 04）、`ui-state.json` 读写、
// 主区页面（工作台 / 流量）、右栏标签条（画板 03 / 50 / 60 / 61）、本地终端标签的开关、Follow（画板 40）、
// 流量面板的过滤输入框。不知道会话与 agent：要用的两样（当前项目目录、当前会话 id）由组合根经回调 / 参数给。

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../projection/wire.dart';
import '../theme/tokens.dart' as t;
import '../ui/shell/right_panel.dart';
import '../ui/shell/shell_common.dart';
import 'core_bridge.dart';
import 'files_state.dart';
import 'guarded.dart';
import 'local_terminals.dart';

/// 主区显示什么：会话工作台、ACP 流量调试（画板 80，从画板 34 的「打开流量面板」进）。
/// 设置（画板 70）不在这里——它是右栏的一个标签（画板 03 的标签条），跟文件 / Agents 一样不占主区。
enum MainPage { workbench, traffic }

class ShellState extends ChangeNotifier with GuardedNotifier {
  ShellState({
    required this.bridge,
    required this.files,
    required this.terminals,
    required this._cwd,
    required this._onWorkbenchShown,
    required this._onTabShown,
  });

  final CoreCommands? bridge;

  /// 文件面板（画板 60）与终端面板（画板 61）的接线状态（R4）：持有者是组合根，这里只用。
  final FilesState files;
  final LocalTerminals terminals;

  /// 当前项目目录（本地终端在它里面打开）。
  final String? Function() _cwd;

  /// 从流量页回到工作台：当前会话又在眼前了，组合根借这个回调撤它的绿点（画板 06 的清除条件）。
  final void Function() _onWorkbenchShown;

  /// 右栏换到了某个面板标签（原来不是它）：打开 Agents 标签时组合根借这个检查一次 registry 更新（画板 53，1 小时节流）。
  final void Function(ShellTab tab) _onTabShown;

  bool sidebarCollapsed = false;

  /// 两栏宽度（画板 04 的分栏把手）：启动时从 `ui-state.json` 读回，没存过就是画板缺省。
  double sidebarWidth = t.Geometry.sidebarWidth;
  double rightPanelWidth = t.Geometry.rightPanelWidth;

  /// 文件面板（画板 60）里树列的宽度与收起态：同样记在 `ui-state.json`（所有者裁定 2026-09-17）。
  double filesTreeWidth = t.Geometry.filesTreeWidth;
  bool filesTreeCollapsed = false;
  final List<ShellTab> openTabs = <ShellTab>[];
  ShellTab? rightTab;

  /// 右栏当前是某个本地终端标签（画板 61）；null = 显示 [rightTab] 那个面板。
  String? activeTerminalId;

  /// Follow（画板 40 的提示；客户端本地开关）：开着时 `locations[]` 到达即在文件面板定位。
  bool follow = false;
  String? _lastFollowed;

  MainPage page = MainPage.workbench;

  final TextEditingController trafficFilter = TextEditingController();
  final FocusNode trafficFilterFocus = FocusNode();

  @override
  void dispose() {
    trafficFilter.dispose();
    trafficFilterFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 分栏宽度（画板 04）

  /// 读回上次拖出来的宽度。没存过 / 存的是垃圾 → 保持画板缺省；夹取一遍再用，
  /// 免得改过 token 之后旧文件里的值落在范围外。
  Future<void> restoreUiState() async {
    final b = bridge;
    if (b == null) return;
    final state = await b.uiStateGet();
    final side = state['sidebarWidth'];
    final right = state['rightPanelWidth'];
    final tree = state['filesTreeWidth'];
    final treeCollapsed = state['filesTreeCollapsed'];
    if (side is num) sidebarWidth = _clampSidebar(side.toDouble());
    if (right is num) rightPanelWidth = _clampRightPanel(right.toDouble());
    if (tree is num) filesTreeWidth = _clampFilesTree(tree.toDouble());
    if (treeCollapsed is bool) filesTreeCollapsed = treeCollapsed;
  }

  static double _clampSidebar(double w) => w.clamp(t.Geometry.sidebarMinWidth, t.Geometry.sidebarMaxWidth);
  static double _clampRightPanel(double w) => w.clamp(t.Geometry.rightPanelMinWidth, t.Geometry.rightPanelMaxWidth);
  static double _clampFilesTree(double w) => w.clamp(t.Geometry.filesTreeMinWidth, t.Geometry.filesTreeMaxWidth);

  /// 拖拽增量（正 = 变宽）。夹取在这里做，widget 只报位移。
  void resizeSidebar(double delta) {
    final next = _clampSidebar(sidebarWidth + delta);
    if (next == sidebarWidth) return;
    sidebarWidth = next;
    notifyListeners();
  }

  void resizeRightPanel(double delta) {
    final next = _clampRightPanel(rightPanelWidth + delta);
    if (next == rightPanelWidth) return;
    rightPanelWidth = next;
    notifyListeners();
  }

  void resetSidebarWidth() {
    if (sidebarWidth == t.Geometry.sidebarWidth) return;
    sidebarWidth = t.Geometry.sidebarWidth;
    notifyListeners();
    saveUiState();
  }

  void resetRightPanelWidth() {
    if (rightPanelWidth == t.Geometry.rightPanelWidth) return;
    rightPanelWidth = t.Geometry.rightPanelWidth;
    notifyListeners();
    saveUiState();
  }

  void resizeFilesTree(double delta) {
    final next = _clampFilesTree(filesTreeWidth + delta);
    if (next == filesTreeWidth) return;
    filesTreeWidth = next;
    notifyListeners();
  }

  void resetFilesTreeWidth() {
    if (filesTreeWidth == t.Geometry.filesTreeWidth) return;
    filesTreeWidth = t.Geometry.filesTreeWidth;
    notifyListeners();
    saveUiState();
  }

  /// 文件面板头行的「缩小」 / 查看器头行的「放回来」：同一个开关。
  void toggleFilesTree() {
    filesTreeCollapsed = !filesTreeCollapsed;
    notifyListeners();
    saveUiState();
  }

  /// 松手才落盘：拖拽途中每帧写文件没有意义。
  Future<void> saveUiState() async {
    final b = bridge;
    if (b == null) return;
    await guard(() => b.uiStateSet(<String, dynamic>{
          'sidebarWidth': sidebarWidth,
          'rightPanelWidth': rightPanelWidth,
          'filesTreeWidth': filesTreeWidth,
          'filesTreeCollapsed': filesTreeCollapsed,
        }));
  }

  // ---------------------------------------------------------------- 壳的 UI 动作

  void toggleSidebar() {
    sidebarCollapsed = !sidebarCollapsed;
    touch();
  }

  // ---------------------------------------------------------------- 右栏（画板 03 / 50 / 60 / 61）

  /// 标签条：面板标签在前、每个本地终端一个标签在后（画板 60 / 61）。侧栏的「终端」入口不作面板标签，它开的是终端实例。
  List<PanelTab> get panelTabs => <PanelTab>[
        for (final tab in openTabs) PanelTab.shell(tab),
        for (final term in terminals.tabs) PanelTab.terminal(term.id, term.title),
      ];

  PanelTab? get activePanel {
    final tid = activeTerminalId;
    if (tid != null) {
      final term = terminals.byId(tid);
      if (term != null) return PanelTab.terminal(term.id, term.title);
    }
    return rightTab == null ? null : PanelTab.shell(rightTab!);
  }

  bool get rightPanelOpen => activePanel != null;

  /// 侧栏底部导航 / 右栏标签：终端开一个本地 shell 标签（已有就切到最近那个，画板 61）；
  /// 设置 / 文件 / Agents 是右栏标签（画板 03 / 50 / 60 / 70）。
  void openTab(ShellTab tab) {
    if (tab == ShellTab.terminal) {
      openTerminalTab();
      return;
    }
    if (!openTabs.contains(tab)) openTabs.add(tab);
    final shown = rightTab != tab || activeTerminalId != null;
    rightTab = tab;
    activeTerminalId = null;
    touch();
    if (shown) _onTabShown(tab);
  }

  /// 侧栏底部导航点一下：没开这个面板就开；当前就是它，再点一下把右栏整个收起
  /// （画板 03 的面板关闭键已废弃，右栏的「关」挪到这里，见 `lib/ui/shell/right_panel.dart` 文件头）。
  void toggleNavTab(ShellTab tab) {
    if (rightPanelOpen && activeNavTab == tab) {
      closeRightPanel();
      return;
    }
    openTab(tab);
  }

  /// 侧栏底部导航的选中项：终端标签活着时是「终端」；否则跟右栏当前标签（设置也在右栏标签里）。
  ShellTab? get activeNavTab {
    if (activeTerminalId != null && terminals.byId(activeTerminalId!) != null) return ShellTab.terminal;
    return rightTab;
  }

  void closeTab(ShellTab tab) {
    openTabs.remove(tab);
    if (rightTab == tab) rightTab = openTabs.isEmpty ? null : openTabs.last;
    touch();
  }

  /// 点标签条上的标签。
  void selectPanel(PanelTab tab) {
    if (tab.isTerminal) {
      activeTerminalId = tab.terminalId;
    } else {
      activeTerminalId = null;
      if (tab.shell != null) openTab(tab.shell!);
    }
    touch();
  }

  /// 标签条上的关闭键：终端标签 = 关掉那个 shell；面板标签 = 收起该面板。
  Future<void> closePanel(PanelTab tab) async {
    if (tab.isTerminal) {
      await closeTerminalTab(tab.terminalId!);
      return;
    }
    if (tab.shell != null) closeTab(tab.shell!);
  }

  /// 整个右栏收起：面板标签清空、本地 shell 全部关掉。
  Future<void> closeRightPanel() async {
    openTabs.clear();
    rightTab = null;
    activeTerminalId = null;
    final ids = <String>[for (final term in terminals.tabs) term.id];
    for (final id in ids) {
      await terminals.close(id);
    }
    touch();
  }

  void toggleRightPanel() {
    if (rightPanelOpen) {
      closeRightPanel();
    } else {
      openTab(ShellTab.files);
    }
  }

  // ---------------------------------------------------------------- 本地终端（画板 61）

  /// 开一个本地 shell（cwd = 当前项目）并切到它；已有标签时（侧栏入口）切到最近的那个而不是再开一个。
  Future<void> openTerminalTab({bool forceNew = false}) async {
    if (!forceNew && terminals.tabs.isNotEmpty) {
      activeTerminalId = terminals.tabs.last.id;
      touch();
      return;
    }
    final cwd = _cwd();
    if (cwd == null) {
      lastError = '先选一个项目目录，终端在它里面打开';
      touch();
      return;
    }
    final id = await terminals.open(cwd);
    if (id != null) activeTerminalId = id;
    lastError = terminals.lastError ?? lastError;
    touch();
  }

  Future<void> closeTerminalTab(String id) async {
    final wasActive = activeTerminalId == id;
    await terminals.close(id);
    if (wasActive) activeTerminalId = terminals.tabs.isEmpty ? null : terminals.tabs.last.id;
    touch();
  }

  Future<void> stopTerminalTab(String id) => terminals.stop(id);

  void clearTerminalTab(String id) => terminals.clear(id);

  Future<void> restartTerminalTab(String id) async {
    final wasActive = activeTerminalId == id;
    final fresh = await terminals.restart(id);
    if (wasActive) activeTerminalId = fresh ?? (terminals.tabs.isEmpty ? null : terminals.tabs.last.id);
    touch();
  }

  // ---------------------------------------------------------------- 定位与 Follow（画板 18 / 21 / 11 / 40）

  /// 「Go to File」/ diff 行 / `@` 芯片：右栏切到文件面板并打开该文件（给了行就切 Source 高亮那一行）。
  Future<void> goToFile(String path, {int? line}) async {
    var p = path;
    if (p.startsWith('file:///')) p = Uri.parse(p).toFilePath(windows: Platform.isWindows);
    openTab(ShellTab.files);
    await files.openPath(p, line: line);
  }

  void toggleFollow() {
    follow = !follow;
    if (!follow) _lastFollowed = null;
    touch();
  }

  /// Follow 开着时，当前会话的 `tool_call` / `tool_call_update` 带 `locations[]` 就跟到第一条（同一位置不重复跳）。
  /// [sessionId] 是当前会话（组合根在分发 `session_update` 时传进来）。
  void followLocations(JsonMap envelope, {required String? sessionId}) {
    if (!follow || envelope['sessionId'] != sessionId) return;
    final update = envelope['update'];
    if (update is! Map) return;
    final kind = update['sessionUpdate'];
    if (kind != 'tool_call' && kind != 'tool_call_update') return;
    final locations = update['locations'];
    if (locations is! List || locations.isEmpty) return;
    final first = locations.first;
    if (first is! Map || first['path'] is! String) return;
    final path = first['path'] as String;
    final line = first['line'];
    final key = '$path:${line ?? ''}';
    if (key == _lastFollowed) return;
    _lastFollowed = key;
    unawaited(goToFile(path, line: line is num ? line.toInt() : null));
  }

  // ---------------------------------------------------------------- 页面切换

  void openTraffic() {
    page = MainPage.traffic;
    touch();
  }

  void openWorkbench() {
    page = MainPage.workbench;
    // 从流量页回到工作台，当前那条会话就又在眼前了：它的绿点一并撤掉（画板 06 的清除条件）。
    _onWorkbenchShown();
    touch();
  }
}
