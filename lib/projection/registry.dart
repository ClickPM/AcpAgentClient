// registry 面板的状态层（画板 50 / 51 / 53 / 70 的数据源）：`registry_list` 的结果与 `registry/progress` 事件的投影。
// 安装状态、认证状态都是**本地态**（docs/design.md § 5 / § 6），不是协议内容；展示名 / 版本 / 描述来自 registry.json。
// 下载速率与剩余时间在这里按 `done` 的时间差估算（核心只报字节数，画板 51 的「2.1 MB/s · 约 4s」是前端算的）。纯 Dart。

import 'package:flutter/foundation.dart';

import 'wire.dart';

/// 分发方式（registry.json 的 `distribution` 键，加上 settings 里的 custom 型与「本平台没有可用 target」的 none）。
enum DistributionKind {
  npx('npx'),
  binary('binary'),
  uvx('uvx'),
  custom('custom'),
  none('none');

  const DistributionKind(this.wire);

  final String wire;

  static DistributionKind parse(String? wire) {
    for (final k in values) {
      if (k.wire == wire) return k;
    }
    return DistributionKind.none;
  }
}

/// 认证状态（本地态）：`session/new` 成功 → authenticated；回 `-32000` → needsAuth；没试过 → unknown。
enum AuthStatus {
  unknown('unknown'),
  needsAuth('needs_auth'),
  authenticated('authenticated');

  const AuthStatus(this.wire);

  final String wire;

  static AuthStatus parse(String? wire) {
    for (final s in values) {
      if (s.wire == wire) return s;
    }
    return AuthStatus.unknown;
  }
}

/// custom 型条目的拉起参数（settings.json 的 `command` / `args` / `env`）。
class CustomCommand {
  const CustomCommand({required this.command, this.args = const <String>[], this.env = const <String, String>{}});

  final String command;
  final List<String> args;
  final Map<String, String> env;

  /// 画板 51 / 70 的显示：`args` 空格连接，`env` 是 `K=V` 空格连接。
  String get argsText => args.join(' ');
  String get envText => env.entries.map((e) => '${e.key}=${e.value}').join(' ');
}

/// 一次安装（或受管 Node 下载）的最近进度（`registry/progress` 的一条 + 估算）。
class InstallProgress {
  InstallProgress({
    required this.kind,
    required this.step,
    required this.at,
    this.done,
    this.total,
    this.detail,
    this.error,
    this.bytesPerSecond,
    this.etaSeconds,
    this.upgrade = false,
  });

  /// npx / binary / node。
  final String kind;

  /// `registry_update` 的进度（画板 53）：npx 只有 resolve / handshake 两步；失败 / 取消时旧版本仍在。
  final bool upgrade;

  /// resolve / write_settings / handshake / download / verify / extract / node_download / node_extract / done / failed / cancelled。
  final String step;
  final DateTime at;
  final num? done;
  final num? total;

  /// 该步的补充文字（npx 的包名、binary 的文件名）。
  final String? detail;
  final String? error;
  final double? bytesPerSecond;
  final double? etaSeconds;

  bool get isTerminal => step == 'done' || step == 'failed' || step == 'cancelled';
  bool get isFailed => step == 'failed';
  bool get isRunning => !isTerminal;

  double? get fraction => (done != null && total != null && total! > 0) ? (done! / total!).clamp(0, 1).toDouble() : null;

  /// npx 型的三步（画板 51）。
  static const List<String> npxSteps = <String>['resolve', 'write_settings', 'handshake'];

  /// npx 型升级的两步（画板 53）：settings 条目升级前就在，没有 write_settings。
  static const List<String> npxUpgradeSteps = <String>['resolve', 'handshake'];

  /// binary 型的三步（画板 51；升级同这三步，画板 53 注）。
  static const List<String> binarySteps = <String>['download', 'verify', 'extract'];

  List<String> get steps => switch (kind) {
        'binary' => binarySteps,
        'npx' => upgrade ? npxUpgradeSteps : npxSteps,
        _ => const <String>['node_download', 'node_extract'],
      };

  /// 某一步的状态：done / active / pending（done 态按步序推断：当前步之前的都算完成）。
  StepState stateOf(String name) {
    final list = steps;
    final current = step == 'done' ? list.length : list.indexOf(step);
    final i = list.indexOf(name);
    if (i < 0) return StepState.pending;
    if (i < current) return StepState.done;
    if (i == current && isRunning) return StepState.active;
    if (i == current && step == 'failed') return StepState.failed;
    return StepState.pending;
  }
}

enum StepState { pending, active, done, failed }

/// registry 面板的一条（registry.json 条目 + 本地安装 / 认证状态，或 settings 里的 custom 条目）。
class RegistryEntryData {
  const RegistryEntryData({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    this.repository,
    this.website,
    this.iconSvg,
    this.kind = DistributionKind.npx,
    this.supported = true,
    this.packageSpec,
    this.installed = false,
    this.builtin = false,
    this.installedVersion,
    this.authStatus = AuthStatus.unknown,
    this.custom,
    this.launch,
    this.progress,
    this.failure,
    this.updateAvailable,
    this.reloadPending,
  });

  final String id;
  final String name;
  final String version;
  final String description;
  final String? repository;
  final String? website;

  /// 缓存的 `icon.svg` 内容；没有时画板上的单色占位。
  final String? iconSvg;
  final DistributionKind kind;

  /// binary 型：本平台有可用 target。
  final bool supported;
  final String? packageSpec;
  final bool installed;

  /// 随包分发的内置 agent（R7 的 zed-agent-acp sidecar）：画板 70 里可见、不可删。
  final bool builtin;
  final String? installedVersion;
  final AuthStatus authStatus;
  final CustomCommand? custom;

  /// registry 型装好后的拉起参数（`install.json` 里的 command / args / env；画板 70「编辑」展开时只读显示）。
  final CustomCommand? launch;

  /// 安装中 / 刚失败的最近进度（终态 done 的不留）。
  final InstallProgress? progress;

  /// 最近一次安装失败的日志（画板 51 的失败态）。
  final String? failure;

  /// registry 当前版本，与安装记录里的版本不等时才有（画板 53「有新版本」；核心判定，只判不等）。
  final String? updateAvailable;

  /// 升级之后该 agent 仍连着旧版本时，运行中那条的版本号（画板 53「已升级 · 待重载」；认不出时为空串）。
  final String? reloadPending;

  bool get isCustom => kind == DistributionKind.custom;
  bool get isInstalling => progress != null && progress!.isRunning;
  bool get isFailed => failure != null || (progress?.isFailed ?? false);

  /// 升级中（画板 53）：进度带 `upgrade`。
  bool get isUpgrading => isInstalling && progress!.upgrade;

  /// 升级失败（画板 53）：失败了但还是已安装——首装失败会回滚成未安装，所以已安装 + 失败只可能是升级那条。
  bool get isUpgradeFailed => installed && !isCustom && isFailed;

  /// 有新版本（画板 50 / 53）。
  bool get hasUpdate => installed && !isCustom && (updateAvailable ?? '').isNotEmpty;

  /// 名字旁的版本号：已安装的是本机装着的版本（安装记录的 registry 版本），没装的是 registry 当前版本（画板 50 注）。
  String get displayVersion => installed && (installedVersion ?? '').isNotEmpty ? installedVersion! : version;

  /// 升级的目标版本（「旧 → 新」的新）：registry 当前版本。
  String get upgradeTarget => (updateAvailable ?? '').isNotEmpty ? updateAvailable! : version;
  bool get isUnsupported => kind == DistributionKind.uvx || kind == DistributionKind.none || !supported;
  bool get needsAuth => installed && authStatus == AuthStatus.needsAuth;
  bool get loggedIn => installed && authStatus == AuthStatus.authenticated;

  RegistryEntryData copyWith({InstallProgress? progress, bool clearProgress = false, String? failure, bool clearFailure = false}) =>
      RegistryEntryData(
        id: id,
        name: name,
        version: version,
        description: description,
        repository: repository,
        website: website,
        iconSvg: iconSvg,
        kind: kind,
        supported: supported,
        packageSpec: packageSpec,
        installed: installed,
        builtin: builtin,
        installedVersion: installedVersion,
        authStatus: authStatus,
        custom: custom,
        launch: launch,
        progress: clearProgress ? null : (progress ?? this.progress),
        failure: clearFailure ? null : (failure ?? this.failure),
        updateAvailable: updateAvailable,
        reloadPending: reloadPending,
      );

  /// `registry_list` 的一条。
  factory RegistryEntryData.fromJson(JsonMap json) {
    final installed = json['installed'];
    final installedMap = installed is Map ? installed.cast<String, dynamic>() : null;
    final custom = json['custom'];
    final customMap = custom is Map ? custom.cast<String, dynamic>() : null;
    return RegistryEntryData(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? json['id'] as String? ?? '',
      version: json['version'] as String? ?? '',
      description: json['description'] as String? ?? '',
      repository: json['repository'] as String?,
      website: json['website'] as String?,
      iconSvg: json['iconSvg'] as String?,
      kind: DistributionKind.parse(json['distribution'] as String?),
      supported: json['supported'] != false,
      packageSpec: json['package'] as String?,
      installed: installedMap != null || customMap != null,
      builtin: json['builtin'] == true,
      installedVersion: installedMap?['version'] as String?,
      authStatus: AuthStatus.parse(installedMap?['authStatus'] as String?),
      custom: customMap == null
          ? null
          : CustomCommand(
              command: customMap['command'] as String? ?? '',
              args: customMap['args'] is List ? (customMap['args'] as List).map((e) => e.toString()).toList() : const <String>[],
              env: customMap['env'] is Map
                  ? (customMap['env'] as Map).map((k, v) => MapEntry(k.toString(), v.toString()))
                  : const <String, String>{},
            ),
      launch: installedMap == null || installedMap['command'] is! String
          ? null
          : CustomCommand(
              command: installedMap['command'] as String,
              args: installedMap['args'] is List ? (installedMap['args'] as List).map((e) => e.toString()).toList() : const <String>[],
              env: installedMap['env'] is Map
                  ? (installedMap['env'] as Map).map((k, v) => MapEntry(k.toString(), v.toString()))
                  : const <String, String>{},
            ),
      failure: installedMap?['lastError'] as String? ?? json['lastError'] as String?,
      updateAvailable: json['updateAvailable'] as String?,
      reloadPending: json['reloadPending'] as String?,
    );
  }
}

/// 系统 / 受管 Node 的状态（`node_status`）。
class NodeInfo {
  const NodeInfo({required this.version, required this.path});

  final String version;
  final String path;
}

class NodeStatus {
  const NodeStatus({this.system, this.managed, this.minVersion = '22.0.0', this.systemError});

  final NodeInfo? system;
  final NodeInfo? managed;
  final String minVersion;

  /// 系统 Node 在但版本不够 / 跑不起来时的说明。
  final String? systemError;

  /// npx 型 agent 能不能跑：系统 Node ≥ 22 或受管 Node 在。
  bool get usable => system != null || managed != null;

  factory NodeStatus.fromJson(JsonMap json) {
    NodeInfo? info(Object? v) => v is Map && v['version'] is String && v['path'] is String
        ? NodeInfo(version: v['version'] as String, path: v['path'] as String)
        : null;
    return NodeStatus(
      system: info(json['system']),
      managed: info(json['managed']),
      minVersion: json['minVersion'] as String? ?? '22.0.0',
      systemError: json['systemError'] as String?,
    );
  }
}

/// 面板过滤（画板 50 的 All / Installed / Not Installed）。
enum RegistryFilter { all, installed, notInstalled }

class RegistryState extends ChangeNotifier {
  List<RegistryEntryData> entries = const <RegistryEntryData>[];
  NodeStatus node = const NodeStatus();
  bool fetching = false;
  String? fetchError;
  DateTime? fetchedAt;

  /// 受管 Node 下载的进度（`agentId` 为 null 的 `registry/progress`）。
  InstallProgress? nodeProgress;

  final Map<String, InstallProgress> _progress = <String, InstallProgress>{};

  int get installedCount => entries.where((e) => e.installed).length;
  int get notInstalledCount => entries.length - installedCount;

  /// 按过滤与搜索（名字 / id / 描述子串，大小写不敏感）。
  List<RegistryEntryData> visible(RegistryFilter filter, String query) {
    final q = query.trim().toLowerCase();
    return <RegistryEntryData>[
      for (final e in entries)
        if ((filter == RegistryFilter.all || (filter == RegistryFilter.installed) == e.installed) &&
            (q.isEmpty || e.name.toLowerCase().contains(q) || e.id.toLowerCase().contains(q) || e.description.toLowerCase().contains(q)))
          e,
    ];
  }

  RegistryEntryData? byId(String id) {
    for (final e in entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// `registry_list` 的结果：`{agents: [...], fetching, fetchError, fetchedAt, node}`。
  void applyList(JsonMap json) {
    final raw = json['agents'];
    entries = <RegistryEntryData>[
      if (raw is List)
        for (final a in raw)
          if (a is Map) _withProgress(RegistryEntryData.fromJson(a.cast<String, dynamic>())),
    ];
    fetching = json['fetching'] == true;
    fetchError = json['fetchError'] as String?;
    final at = json['fetchedAt'];
    fetchedAt = at is num ? DateTime.fromMillisecondsSinceEpoch(at.toInt()) : null;
    final node = json['node'];
    if (node is Map) this.node = NodeStatus.fromJson(node.cast<String, dynamic>());
    notifyListeners();
  }

  void applyNodeStatus(JsonMap json) {
    node = NodeStatus.fromJson(json);
    notifyListeners();
  }

  RegistryEntryData _withProgress(RegistryEntryData e) {
    final p = _progress[e.id];
    if (p == null) return e;
    return e.copyWith(progress: p.isTerminal && !p.isFailed ? null : p, failure: p.isFailed ? p.error : null);
  }

  /// `registry/progress`：`{agentId, kind, step, done?, total?, detail?, error?}`。返回落到的条目 id（受管 Node 为 null）。
  String? applyProgress(JsonMap json, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final agentId = json['agentId'] as String?;
    final previous = agentId == null ? nodeProgress : _progress[agentId];
    final done = json['done'] is num ? json['done'] as num : null;
    final total = json['total'] is num ? json['total'] as num : null;
    double? rate;
    double? eta;
    if (previous != null && previous.step == json['step'] && previous.done != null && done != null) {
      final dt = at.difference(previous.at).inMilliseconds / 1000.0;
      if (dt > 0 && done > previous.done!) {
        rate = (done - previous.done!) / dt;
        // 按最近两次采样的速率算，再和上一次的估计做一次平滑（画板 51 的数字不该每帧乱跳）。
        if (previous.bytesPerSecond != null) rate = (rate + previous.bytesPerSecond!) / 2;
        if (total != null && rate > 0) eta = (total - done) / rate;
      } else if (previous.bytesPerSecond != null) {
        rate = previous.bytesPerSecond;
        eta = previous.etaSeconds;
      }
    }
    final progress = InstallProgress(
      kind: json['kind'] as String? ?? (agentId == null ? 'node' : 'npx'),
      step: json['step'] as String? ?? '',
      at: at,
      done: done,
      total: total,
      detail: json['detail'] as String?,
      error: json['error'] as String?,
      bytesPerSecond: rate,
      etaSeconds: eta,
      upgrade: json['upgrade'] == true,
    );
    if (agentId == null) {
      nodeProgress = progress.isTerminal && !progress.isFailed ? null : progress;
    } else {
      if (progress.step == 'done' || progress.step == 'cancelled') {
        _progress.remove(agentId);
      } else {
        _progress[agentId] = progress;
      }
      entries = <RegistryEntryData>[
        for (final e in entries)
          if (e.id == agentId)
            (progress.step == 'done' || progress.step == 'cancelled')
                ? e.copyWith(clearProgress: true, clearFailure: true)
                : e.copyWith(progress: progress, failure: progress.isFailed ? progress.error : null, clearFailure: !progress.isFailed)
          else
            e,
      ];
    }
    notifyListeners();
    return agentId;
  }

  JsonMap debugSnapshot() => <String, dynamic>{
        'entries': <String, dynamic>{
          for (final e in entries)
            e.id: <String, dynamic>{
              'installed': e.installed,
              'kind': e.kind.wire,
              'auth': e.authStatus.wire,
              'progress': e.progress?.step,
              'failure': e.failure,
              'updateAvailable': e.updateAvailable,
              'reloadPending': e.reloadPending,
            },
        },
        'node': <String, dynamic>{'system': node.system?.version, 'managed': node.managed?.version},
        'fetchError': fetchError,
      };
}
