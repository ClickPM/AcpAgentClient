// 已装 agent 列表、registry 面板（画板 50 / 51，R5；画板 53 的检查与升级）与设置面板（画板 70，R5；右栏标签）（R7.5 从 workbench_controller.dart 拆出）。
// 会话不归它管：卸载正在用的 agent、registry 变化后侧栏 logo 重投影、已装列表变化后挑「当前 agent」都经回调
// 交给会话控制器；核心给的三个路径（画板 70）经 [onPaths] 回到组合根。
//
// 不做 agent 特判（规则 2）：agent 名一律来自 settings.json 的键或 `initialize` 的 `agentInfo`。

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../projection/agent_state.dart';
import '../projection/entries.dart';
import '../projection/process_snapshot.dart';
import '../projection/registry.dart';
import '../projection/session_store.dart';
import '../projection/wire.dart';
import '../theme/tokens.dart' as t;
import '../ui/popovers/topbar_popovers.dart';
import '../ui/registry/registry_entry.dart';
import '../ui/registry/stop_agent_confirm.dart';
import '../ui/settings/settings_page.dart';
import '../ui/shell/popover_anchor.dart';
import 'core_bridge.dart';
import 'guarded.dart';

class AgentsState extends ChangeNotifier with GuardedNotifier {
  AgentsState({
    required this.bridge,
    required this._onRemoved,
    required this._onInstalledChanged,
    required this._onRegistryChanged,
    required this._onPaths,
    this.sessions,
    this.isSessionAttached,
    this.sessionOwner,
    this.onStopped,
  });

  final CoreCommands? bridge;
  final Sessions? sessions;
  final bool Function(String sessionId)? isSessionAttached;
  final String Function(String sessionId)? sessionOwner;
  final void Function(String agentId)? onStopped;

  /// 卸载了一个 agent（settings 条目已删）：会话控制器放下它、认证页若开着它的就收起。
  final void Function(String id) _onRemoved;

  /// 已装列表刷新完：会话控制器按它挑「当前 agent」（原 `_selectDefaultAgent`）。
  final void Function() _onInstalledChanged;

  /// registry 列表刷新完：侧栏的 agent logo 是从 registry 查出来烘进侧栏项的，会话控制器重投影一次。
  final void Function() _onRegistryChanged;

  /// `registry_list` 回的 `paths`（dataDir / logPath，画板 70）：组合根记着。
  final void Function(Map<Object?, Object?> paths) _onPaths;

  List<AgentRef> installed = const <AgentRef>[];

  // ---- registry 面板（画板 50 / 51，R5）
  final RegistryState registry = RegistryState();
  final TextEditingController search = TextEditingController();
  final FocusNode searchFocus = FocusNode();
  String query = '';
  RegistryFilter filter = RegistryFilter.all;

  /// 失败态展开了日志块的条目（「查看日志」切换）。
  final Set<String> showLog = <String>{};

  // ---- 画板 54：进程采样与停止（R10）
  ProcessSnapshot? processSnapshot;
  String? processSampleError;
  bool _sampleInFlight = false;
  Timer? _sampleTimer;
  int _sampleEpoch = 0;
  bool _panelVisible = false;
  bool _windowMinimized = false;

  final Set<String> expandedProcessTrees = <String>{};
  final Set<String> stoppingIds = <String>{};
  final Map<String, int> _stoppingGen = <String, int>{};
  final Map<String, PopoverHandle> _stopAnchors = <String, PopoverHandle>{};
  StopConfirmData? confirmingStop;

  bool get panelVisible => _panelVisible;
  bool get windowMinimized => _windowMinimized;
  bool get processSampling => _sampleInFlight;
  bool get sampleTimerActive => _sampleTimer?.isActive ?? false;
  bool get _shouldSample =>
      _panelVisible && !_windowMinimized && bridge != null;

  // ---- 设置面板（画板 70，R5；右栏标签）
  String? expandedId;
  String? editingId;
  late final CustomEditFields edit = CustomEditFields(
    command: TextEditingController(),
    args: TextEditingController(),
    env: TextEditingController(),
    focus: FocusNode(),
  );

  @override
  void dispose() {
    _stopSampleTimer();
    for (final c in <TextEditingController>[
      search,
      edit.command,
      edit.args,
      edit.env,
    ]) {
      c.dispose();
    }
    for (final f in <FocusNode>[searchFocus, edit.focus]) {
      f.dispose();
    }
    for (final h in _stopAnchors.values) {
      h.dispose();
    }
    _stopAnchors.clear();
    registry.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 已装列表

  Future<void> refreshAgents() async {
    final b = bridge;
    if (b == null) return;
    final settings = await b.agentSettingsGet();
    final servers = settings['agent_servers'];
    installed = <AgentRef>[
      if (servers is Map)
        for (final entry in servers.entries)
          // 名字：条目自带的 `name` 优先（内置条目用它显示名称），其次 registry.json 的
          // 展示名（R5），最后退回 settings 里的键；连上之后会话头再从 agentInfo 取（规则 2）。
          AgentRef(
            id: entry.key as String,
            name: _displayName(entry.key as String, entry.value),
            // logo 与侧栏 / 会话头同一条路：registry 缓存的 `icon.svg`（内置 sidecar 是随包带的那份）。
            iconSvg: iconSvgOf(entry.key as String),
          ),
    ];
    _onInstalledChanged();
  }

  /// 已安装列表里的这一条（展示名与图标从它来）。
  AgentRef? installedRef(String? id) {
    if (id == null) return null;
    for (final a in installed) {
      if (a.id == id) return a;
    }
    return null;
  }

  String _displayName(String id, Object? server) {
    if (server is Map) {
      final name = server['name'];
      if (name is String && name.isNotEmpty) return name;
    }
    return registry.byId(id)?.name ?? id;
  }

  /// agent 自己的 logo：registry 缓存的 `icon.svg` 原样内容，侧栏会话项与会话头的 agent 标记直接画它
  /// （画板 50 / 51 / 70 的图标框用的是同一份）。registry 里没有这条 / 没缓存到图标时为 null，退回画板的单色占位。
  /// 不按 agent 名判（规则 2）：id 查不到就是没有。
  String? iconSvgOf(String? agent) =>
      agent == null || agent.isEmpty ? null : registry.byId(agent)?.iconSvg;

  // ---------------------------------------------------------------- registry 面板（画板 50 / 51 / 54，R5 / R10）

  /// 过滤 + 搜索之后的条目。
  List<RegistryEntryData> get visibleEntries =>
      registry.visible(filter, query, runningIds: runningIds);

  static bool _isConnected(AgentLifecycle? state) =>
      state == AgentLifecycle.initialized ||
      state == AgentLifecycle.authRequired ||
      state == AgentLifecycle.authenticating;

  /// 已连接的 agent id 集合（含正在停止的条目，直至进程退出）。
  Set<String> get runningIds {
    final ids = <String>{...stoppingIds};
    for (final e in registry.entries) {
      if (isAgentRunning(e.id)) ids.add(e.id);
    }
    final s = sessions;
    if (s != null) {
      for (final c in s.agents.all) {
        if (c.agentId.isNotEmpty && _isConnected(c.state)) {
          ids.add(c.agentId);
        }
      }
    }
    final snap = processSnapshot;
    if (snap != null) {
      for (final a in snap.agents) {
        if (a.agentId.isNotEmpty && isAgentRunning(a.agentId)) {
          ids.add(a.agentId);
        }
      }
    }
    return ids;
  }

  int get runningCount => registry.entries.isEmpty
      ? runningIds.length
      : registry.entries.where((e) => runningIds.contains(e.id)).length;

  bool isAgentRunning(String id) {
    if (stoppingIds.contains(id)) return false;
    final state = sessions?.agents[id]?.state;
    if (_isConnected(state)) return true;
    if (state == AgentLifecycle.exited || state == AgentLifecycle.spawned) {
      return false;
    }
    return processSnapshot?.agent(id) != null;
  }

  bool isAgentConnecting(String id) {
    if (stoppingIds.contains(id)) return false;
    return sessions?.agents[id]?.state == AgentLifecycle.spawned;
  }

  AgentEntryRuntime? runtimeOf(RegistryEntryData entry) {
    final id = entry.id;
    final snap = processSnapshot?.agent(id);
    final pid = snap?.rootPid ?? sessions?.agents[id]?.pid?.toInt();
    final metric = processSnapshot?.metric ?? MemoryMetric.private;
    if (stoppingIds.contains(id)) {
      return AgentEntryRuntime(
        phase: AgentRunPhase.stopping,
        pid: pid,
        snapshot: snap,
        metric: metric,
      );
    }
    if (isAgentConnecting(id)) {
      return AgentEntryRuntime(
        phase: AgentRunPhase.connecting,
        pid: pid,
        metric: metric,
      );
    }
    if (isAgentRunning(id)) {
      return AgentEntryRuntime(
        phase: AgentRunPhase.running,
        pid: pid,
        snapshot: snap,
        metric: metric,
        sessionCount: attachedSessionCount(id),
        expanded: expandedProcessTrees.contains(id),
        stopHovered: confirmingStop?.agentId == id,
      );
    }
    return null;
  }

  RegistryEntryActions actionsFor(
    RegistryEntryData entry, {
    required VoidCallback onLogin,
    required ValueChanged<String> onOpenUrl,
  }) => RegistryEntryActions(
    onInstall: () => install(entry.id),
    onUpdate: () => upgrade(entry.id),
    onRetry: () => retry(entry.id),
    onCancel: () => cancelInstall(entry.id),
    onRemove: () => remove(entry.id),
    onLogin: onLogin,
    onViewLog: () => toggleInstallLog(entry.id),
    onOpenRepository: () {
      final url = entry.repository ?? entry.website;
      if (url != null) onOpenUrl(url);
    },
    onStop: () => requestStop(entry.id),
    onToggleProcesses: () => toggleProcessTree(entry.id),
    stopAnchor: stopAnchorFor(entry.id),
  );

  // ---------------------------------------------------------------- 进程采样（画板 54）

  void setPanelVisible(bool visible) {
    if (_panelVisible == visible) return;
    _panelVisible = visible;
    _syncSampleTimer();
  }

  void setWindowMinimized(bool minimized) {
    if (_windowMinimized == minimized) return;
    _windowMinimized = minimized;
    _syncSampleTimer();
  }

  void _syncSampleTimer() {
    if (!_shouldSample) {
      _stopSampleTimer();
      return;
    }
    if (_sampleTimer != null) return;
    processSampleError = null;
    _startSampleTimer();
    unawaited(sampleProcesses());
  }

  void _startSampleTimer() {
    _sampleTimer?.cancel();
    _sampleTimer = Timer.periodic(t.Resource.sampleInterval, (_) {
      unawaited(sampleProcesses());
    });
  }

  void _stopSampleTimer() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _sampleEpoch++;
  }

  Future<void> sampleProcesses() async {
    final b = bridge;
    if (b == null || _sampleInFlight || processSampleError != null) return;
    final epoch = ++_sampleEpoch;
    _sampleInFlight = true;
    if (processSnapshot == null) touch();
    try {
      final json = await b.processSnapshot();
      if (disposed || epoch != _sampleEpoch) return;
      processSnapshot = ProcessSnapshot.fromJson(json);
      processSampleError = null;
    } catch (e) {
      if (disposed || epoch != _sampleEpoch) return;
      debugPrint('[process_snapshot] ${describeError(e)}');
      processSampleError = describeError(e);
      processSnapshot = null;
      _sampleTimer?.cancel();
      _sampleTimer = null;
    } finally {
      _sampleInFlight = false;
      if (!disposed) {
        if (_shouldSample &&
            processSampleError == null &&
            epoch != _sampleEpoch) {
          unawaited(sampleProcesses());
        }
        touch();
      }
    }
  }

  Future<void> retryProcessSample() async {
    processSampleError = null;
    if (_shouldSample) _startSampleTimer();
    await sampleProcesses();
  }

  void toggleProcessTree(String id) {
    if (!expandedProcessTrees.remove(id)) expandedProcessTrees.add(id);
    touch();
  }

  // ---------------------------------------------------------------- Stop 与确认弹层（画板 54 B1 / B2 / B3）

  PopoverHandle stopAnchorFor(String id) =>
      _stopAnchors.putIfAbsent(id, PopoverHandle.new);

  List<SessionStore> attachedSessionsOf(String agentId) {
    final s = sessions;
    if (s == null || s.agents[agentId]?.state == AgentLifecycle.exited) {
      return const <SessionStore>[];
    }
    final out = <SessionStore>[];
    for (final store in s.all) {
      final owner = store.agentId ?? sessionOwner?.call(store.sessionId) ?? '';
      if (owner != agentId) continue;
      final attached = isSessionAttached?.call(store.sessionId) ?? true;
      if (attached) out.add(store);
    }
    return out;
  }

  int attachedSessionCount(String agentId) =>
      attachedSessionsOf(agentId).length;

  StopConfirmData? stopConfirmDataFor(String id) {
    final attached = attachedSessionsOf(id);
    if (attached.isEmpty) return null;
    final awaiting =
        sessions?.pending.firstBySession() ?? const <String, TranscriptEntry>{};
    var runningCount = 0;
    var awaitingCount = 0;
    var hasPermission = false;
    var hasElicitation = false;
    for (final store in attached) {
      final entry = awaiting[store.sessionId];
      if (entry != null) {
        awaitingCount++;
        if (entry is PermissionEntry) hasPermission = true;
        if (entry is ElicitationEntry) hasElicitation = true;
      } else if (store.isRunning) {
        runningCount++;
      }
    }
    final verb = hasPermission || !hasElicitation ? '授权' : '处理';
    final snap = processSnapshot?.agent(id);
    final name = registry.byId(id)?.name ?? installedRef(id)?.name ?? id;
    return StopConfirmData(
      agentId: id,
      agentName: name,
      sessionCount: attached.length,
      runningSessions: runningCount,
      awaitingSessions: awaitingCount,
      awaitingVerb: verb,
      processCount: snap?.processCount,
      bytes: snap?.bytes,
    );
  }

  Future<void> requestStop(String id) async {
    if (stoppingIds.contains(id)) return;
    final data = stopConfirmDataFor(id);
    if (data == null) {
      await stopAgent(id);
      return;
    }
    if (confirmingStop != null && confirmingStop!.agentId != id) {
      hidePopover(stopAnchorFor(confirmingStop!.agentId));
    }
    confirmingStop = data;
    stopAnchorFor(id).show(
      (_) => StopAgentConfirm.fromData(
        data,
        onCancel: cancelStop,
        onConfirm: () => unawaited(confirmStop()),
      ),
      targetAnchor: Alignment.bottomRight,
      followerAnchor: Alignment.topRight,
      onDismiss: cancelStop,
    );
    touch();
  }

  Future<void> confirmStop() async {
    final data = confirmingStop;
    if (data == null) return;
    hidePopover(stopAnchorFor(data.agentId));
    confirmingStop = null;
    await stopAgent(data.agentId);
  }

  void cancelStop() {
    final data = confirmingStop;
    if (data != null) hidePopover(stopAnchorFor(data.agentId));
    confirmingStop = null;
    touch();
  }

  Future<void> stopAgent(String id) async {
    final b = bridge;
    if (b == null || stoppingIds.contains(id)) return;
    if (confirmingStop?.agentId == id) {
      hidePopover(stopAnchorFor(id));
      confirmingStop = null;
    }
    final gen = sessions?.agents[id]?.generation ?? 0;
    _stoppingGen[id] = gen;
    stoppingIds.add(id);
    touch();
    var ok = false;
    try {
      await guard(() async {
        await b.agentDisconnect(id);
        ok = true;
      });
    } finally {
      final unchanged = (sessions?.agents[id]?.generation ?? 0) == gen;
      if (_stoppingGen[id] == gen) {
        _stoppingGen.remove(id);
        stoppingIds.remove(id);
      }
      if (unchanged && ok) {
        onStopped?.call(id);
        _removeAgentFromSnapshot(id);
        if (_shouldSample && processSampleError == null) {
          unawaited(sampleProcesses());
        }
      }
      if (!disposed) touch();
    }
  }

  void onAgentState(JsonMap json) {
    final state = json['state'];
    final id = json['agentId'];
    if (id is String) {
      if ((state == 'initialized' || state == 'exited') &&
          registry.byId(id)?.reloadPending != null) {
        unawaited(refreshRegistry());
      }
      if (state == 'exited') {
        if (confirmingStop?.agentId == id) cancelStop();
        _stoppingGen.remove(id);
        stoppingIds.remove(id);
        _removeAgentFromSnapshot(id);
        if (_shouldSample && processSampleError == null) {
          unawaited(sampleProcesses());
        }
        touch();
      } else if (state == 'initialized' || state == 'spawned') {
        _stoppingGen.remove(id);
        stoppingIds.remove(id);
        if (_shouldSample && processSampleError == null) {
          unawaited(sampleProcesses());
        }
        touch();
      }
    }
  }

  void _removeAgentFromSnapshot(String id) {
    final snap = processSnapshot;
    if (snap == null || snap.agent(id) == null) return;
    final remaining = <AgentProcessSnapshot>[
      for (final a in snap.agents)
        if (a.agentId != id) a,
    ];
    processSnapshot = ProcessSnapshot(
      metric: snap.metric,
      takenAt: snap.takenAt,
      appPid: snap.appPid,
      hostBytes: snap.hostBytes,
      otherBytes: snap.otherBytes,
      agents: remaining,
      terminalCount: snap.terminalCount,
      terminalsBytes: snap.terminalsBytes,
      terminalItems: snap.terminalItems,
    );
  }

  /// `registry_list`（`network` = 先联网刷新，1 小时节流，`force` 跳过）。失败不清列表，错误进 `registry.fetchError` 或 [lastError]。
  Future<void> refreshRegistry({
    bool network = false,
    bool force = false,
  }) async {
    final b = bridge;
    if (b == null) return;
    // 联网这一次的在途态由这里先置上（画板 53 标题行「检查中…」）：核心的 `fetching` 要等列表回来才看得到，那时已经拉完了。
    if (network) {
      registry.fetching = true;
      touch();
    }
    var listed = false;
    await guard(() async {
      final list = network
          ? await b.registryRefresh(force: force)
          : await b.registryList();
      registry.applyList(list);
      listed = true;
      // 侧栏的 agent logo 是从 registry 查出来**烘进**侧栏项的，所以 registry 一变就要重投影一次：
      // 首次启动时图标是这轮联网刷新才落盘的，不重投影侧栏会一直停在占位菱形上，直到下次刷新本地索引。
      _onRegistryChanged();
      final paths = list['paths'];
      if (paths is Map) _onPaths(paths);
      // 展示名随 registry 来（画板 41 的新建会话弹层）。
      await refreshAgents();
    });
    // 失败时列表没回来（guard 吞了异常），在途态要自己撤。
    if (network && !listed) registry.fetching = false;
    touch();
  }

  void onRegistryProgress(CoreEventRecord e) {
    final json = e.json;
    if (json == null) return;
    final id = registry.applyProgress(json);
    final step = json['step'];
    if (step == 'done' || step == 'failed' || step == 'cancelled') {
      // 装完 / 失败 / 取消：安装记录与 settings 都变了，重读列表（不联网）。
      unawaited(refreshRegistry());
      if (id != null && step == 'failed') showLog.add(id);
    }
    touch();
  }

  void setFilter(RegistryFilter value) {
    filter = value;
    touch();
  }

  void setQuery(String value) {
    query = value;
    touch();
  }

  /// Install（首装）。
  Future<void> install(String id) async {
    final b = bridge;
    if (b == null) return;
    showLog.remove(id);
    await guard(() => b.registryInstall(id));
    touch();
  }

  /// Update（画板 53）：升到 registry 当前版本，进度同安装（`upgrade: true`）。
  Future<void> upgrade(String id) async {
    final b = bridge;
    if (b == null) return;
    showLog.remove(id);
    await guard(() => b.registryUpdate(id));
    touch();
  }

  /// 失败态的「重试」：已安装的条目失败的只能是升级（首装失败会回滚成未安装），重试升级；否则重试首装。
  Future<void> retry(String id) =>
      (registry.byId(id)?.isUpgradeFailed ?? false) ? upgrade(id) : install(id);

  /// 标题行的「检查更新」（画板 50）：强制联网拉一次；已在检查就不再发。
  Future<void> checkForUpdates() async {
    if (registry.fetching) return;
    await refreshRegistry(network: true, force: true);
  }

  Future<void> cancelInstall(String id) async {
    final b = bridge;
    if (b == null) return;
    await guard(() => b.registryCancelInstall(id));
    touch();
  }

  void toggleInstallLog(String id) {
    if (!showLog.remove(id)) showLog.add(id);
    touch();
  }

  /// Remove（画板 50 / 51 / 70）：registry 型走 `registry_remove`（settings 条目 + `agents/<id>/`），custom 型只删 settings 条目。
  Future<void> remove(String id) async {
    final b = bridge;
    if (b == null) return;
    await guard(() async {
      final entry = registry.byId(id);
      if (entry?.isCustom ?? false) {
        await b.agentSettingsRemove(id);
      } else {
        await b.registryRemove(id);
      }
      _onRemoved(id);
      if (editingId == id || expandedId == id) collapseEdit();
      await refreshRegistry();
    });
    touch();
  }

  /// 受管 Node（画板 51 提示卡 / 画板 70 的 Node 运行时）。进度经 `registry/progress`（`agentId: null`）。
  Future<void> downloadNode() async {
    final b = bridge;
    if (b == null) return;
    await guard(() async {
      await b.nodeDownload();
      await refreshRegistry();
    });
    touch();
  }

  // ---------------------------------------------------------------- 设置面板（画板 70，R5；右栏标签）

  /// 已安装的条目（registry 型 + custom 型），设置页的 agent 配置列表。
  List<RegistryEntryData> get installedEntries => <RegistryEntryData>[
    for (final e in registry.entries)
      if (e.installed) e,
  ];

  /// 「编辑」：custom 型进行内编辑（cmd / args / env 填进输入框），registry 型只读展开拉起参数。
  void editAgent(String id) {
    final entry = registry.byId(id);
    if (entry != null && entry.isCustom && entry.custom != null) {
      editingId = id;
      expandedId = null;
      edit.command.text = entry.custom!.command;
      edit.args.text = entry.custom!.argsText;
      edit.env.text = entry.custom!.envText;
    } else {
      expandedId = expandedId == id ? null : id;
      editingId = null;
    }
    touch();
  }

  void collapseEdit() {
    editingId = null;
    expandedId = null;
    touch();
  }

  /// 「保存」：写回 `{type: custom, command, args, env}`（args 按空白分隔、双引号可包空格；env 是 `K=V` 空白分隔）。
  Future<void> saveCustomAgent(String id) async {
    final b = bridge;
    if (b == null) return;
    final command = edit.command.text.trim();
    if (command.isEmpty) {
      lastError = 'cmd 不能为空';
      touch();
      return;
    }
    final env = <String, String>{};
    for (final token in splitArgs(edit.env.text)) {
      final i = token.indexOf('=');
      if (i <= 0) continue;
      env[token.substring(0, i)] = token.substring(i + 1);
    }
    await guard(() async {
      await b.agentSettingsSet(id, <String, dynamic>{
        'type': 'custom',
        'command': command,
        'args': splitArgs(edit.args.text),
        'env': env,
      });
      editingId = null;
      await refreshRegistry();
    });
    touch();
  }

  /// 按空白切分，双引号里的空格保留（`"C:\a b\x.cmd" --flag`）。
  static List<String> splitArgs(String text) {
    final out = <String>[];
    final buf = StringBuffer();
    var quoted = false;
    var has = false;
    for (final ch in text.runes) {
      final c = String.fromCharCode(ch);
      if (c == '"') {
        quoted = !quoted;
        has = true;
      } else if (!quoted && c.trim().isEmpty) {
        if (has) out.add(buf.toString());
        buf.clear();
        has = false;
      } else {
        buf.write(c);
        has = true;
      }
    }
    if (has) out.add(buf.toString());
    return out;
  }
}
