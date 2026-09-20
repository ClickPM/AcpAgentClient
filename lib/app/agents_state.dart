// 已装 agent 列表、registry 面板（画板 50 / 51，R5）与设置面板（画板 70，R5；右栏标签）（R7.5 从 workbench_controller.dart 拆出）。
// 会话不归它管：卸载正在用的 agent、registry 变化后侧栏 logo 重投影、已装列表变化后挑「当前 agent」都经回调
// 交给会话控制器；核心给的三个路径（画板 70）经 [onPaths] 回到组合根。
//
// 不做 agent 特判（规则 2）：agent 名一律来自 settings.json 的键或 `initialize` 的 `agentInfo`。

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../projection/registry.dart';
import '../ui/popovers/topbar_popovers.dart';
import '../ui/settings/settings_page.dart';
import 'core_bridge.dart';
import 'guarded.dart';

class AgentsState extends ChangeNotifier with GuardedNotifier {
  AgentsState({
    required this.bridge,
    required this._onRemoved,
    required this._onInstalledChanged,
    required this._onRegistryChanged,
    required this._onPaths,
  });

  final CoreCommands? bridge;

  /// 卸载了一个 agent（settings 条目已删）：会话控制器放下它、认证页若开着它的就收起。
  final void Function(String id) _onRemoved;

  /// 已装列表刷新完：会话控制器按它挑「当前 agent」（原 `_selectDefaultAgent`）。
  final void Function() _onInstalledChanged;

  /// registry 列表刷新完：侧栏的 agent logo 是从 registry 查出来烘进侧栏项的，会话控制器重投影一次。
  final void Function() _onRegistryChanged;

  /// `registry_list` 回的 `paths`（dataDir / logPath / zedSettingsPath，画板 70）：组合根记着。
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

  // ---- 设置面板（画板 70，R5；右栏标签）
  String? expandedId;
  String? editingId;
  String? zedImportResult;
  late final CustomEditFields edit = CustomEditFields(
    command: TextEditingController(),
    args: TextEditingController(),
    env: TextEditingController(),
    focus: FocusNode(),
  );

  @override
  void dispose() {
    for (final c in <TextEditingController>[search, edit.command, edit.args, edit.env]) {
      c.dispose();
    }
    for (final f in <FocusNode>[searchFocus, edit.focus]) {
      f.dispose();
    }
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
          // 名字：条目自带的 `name` 优先（R7 的内置 sidecar 用它显示 "Zed Agent"），其次 registry.json 的
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
  String? iconSvgOf(String? agent) => agent == null || agent.isEmpty ? null : registry.byId(agent)?.iconSvg;

  // ---------------------------------------------------------------- registry 面板（画板 50 / 51，R5）

  /// 过滤 + 搜索之后的条目。
  List<RegistryEntryData> get visibleEntries => registry.visible(filter, query);

  /// `registry_list`（`network` = 先联网刷新，1 小时节流，`force` 跳过）。失败不清列表，错误进 `registry.fetchError` 或 [lastError]。
  Future<void> refreshRegistry({bool network = false, bool force = false}) async {
    final b = bridge;
    if (b == null) return;
    await guard(() async {
      final list = network ? await b.registryRefresh(force: force) : await b.registryList();
      registry.applyList(list);
      // 侧栏的 agent logo 是从 registry 查出来**烘进**侧栏项的，所以 registry 一变就要重投影一次：
      // 首次启动时图标是这轮联网刷新才落盘的，不重投影侧栏会一直停在占位菱形上，直到下次刷新本地索引。
      _onRegistryChanged();
      final paths = list['paths'];
      if (paths is Map) _onPaths(paths);
      // 展示名随 registry 来（画板 41 的新建会话弹层）。
      await refreshAgents();
    });
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

  /// Install / 重试（失败态）。
  Future<void> install(String id) async {
    final b = bridge;
    if (b == null) return;
    showLog.remove(id);
    await guard(() => b.registryInstall(id));
    touch();
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

  /// 「从 Zed 导入」：结果文案留在行下（画板 70 的注释位）。
  Future<void> importZed() async {
    final b = bridge;
    if (b == null) return;
    await guard(() async {
      final result = await b.agentSettingsImportZed();
      final report = result['report'];
      if (report is Map) {
        List<String> ids(Object? v) => v is List ? v.map((e) => e.toString()).toList() : const <String>[];
        final imported = ids(report['imported']);
        final skipped = ids(report['skipped']);
        final invalid = ids(report['invalid']);
        zedImportResult = '已导入 ${imported.length} 条${imported.isEmpty ? '' : '（${imported.join('、')}）'}，'
            '跳过同名 ${skipped.length} 条${invalid.isEmpty ? '' : '，解不开 ${invalid.length} 条（${invalid.join('、')}）'}。';
      }
      await refreshRegistry();
    });
    touch();
  }
}
