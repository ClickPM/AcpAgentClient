// 画板 54 · Agents 面板的进程与内存投影（R10）：把核心 `process_snapshot` 返回的 JSON
// 解析为资源概览条的三段数据（本应用 / Agents / 终端）与每个 agent 的运行行、进程树行。纯 Dart。

import 'wire.dart';

/// 内存口径：Windows 为专用内存（`private`），macOS 为常驻内存（`resident`）。
enum MemoryMetric {
  private('private'),
  resident('resident');

  const MemoryMetric(this.wire);

  final String wire;

  static MemoryMetric parse(String? wire) =>
      wire == 'resident' ? MemoryMetric.resident : MemoryMetric.private;

  /// 口径名（概览条右上角与进程树表头右列）。
  String get label => switch (this) {
    MemoryMetric.resident => '常驻内存',
    MemoryMetric.private => '专用内存',
  };

  /// 概览条右上角：`专用内存 · 每 2 秒采样` / `常驻内存 · 每 2 秒采样`。
  String get summary => '$label · 每 2 秒采样';

  /// 概览条 `info` 图标的悬停说明。
  String get tooltip => switch (this) {
    MemoryMetric.resident =>
      '口径：进程的常驻内存（macOS：Resident Memory，即活动监视器的内存占用）。合计 = 本应用进程及其全部子进程。',
    MemoryMetric.private => '口径：进程的专用内存（Windows：Private Bytes，即任务管理器「详细信息」页的「提交大小」）。合计 = 本应用进程及其全部子进程。',
  };
}

/// 概览条分段条的三段。
enum ResourceSegmentKind { app, agents, terminals }

class ResourceBarSegment {
  const ResourceBarSegment({required this.kind, required this.bytes});

  final ResourceSegmentKind kind;
  final int bytes;
}

/// agent 子树里的一个进程节点。
class ProcessNode {
  const ProcessNode({
    required this.pid,
    required this.parentPid,
    required this.name,
    required this.bytes,
    required this.depth,
  });

  final int pid;
  final int parentPid;
  final String name;
  final int bytes;
  final int depth;

  factory ProcessNode.fromJson(JsonMap json) => ProcessNode(
    pid: (json['pid'] as num?)?.toInt() ?? 0,
    parentPid: (json['parentPid'] as num?)?.toInt() ?? 0,
    name: json['name'] as String? ?? '',
    bytes: (json['bytes'] as num?)?.toInt() ?? 0,
    depth: (json['depth'] as num?)?.toInt() ?? 0,
  );
}

/// agent 经 `terminal/create` 打开的终端进程（顶层显示，标 `agent 终端 <terminalId>`）。
class AgentTerminalProcess {
  const AgentTerminalProcess({
    required this.terminalId,
    required this.pid,
    required this.bytes,
    this.name = '',
  });

  final String terminalId;
  final int pid;
  final int bytes;
  final String name;

  factory AgentTerminalProcess.fromJson(JsonMap json) => AgentTerminalProcess(
    terminalId: json['terminalId'] as String? ?? '',
    pid: (json['pid'] as num?)?.toInt() ?? 0,
    bytes: (json['bytes'] as num?)?.toInt() ?? 0,
    name: (json['name'] as String?) ?? (json['program'] as String?) ?? '',
  );
}

/// 展开进程树里的一行（普通子进程或 agent 终端）。
class ProcessTreeRow {
  const ProcessTreeRow({
    required this.pid,
    required this.name,
    required this.bytes,
    this.depth = 0,
    this.terminalId,
  });

  final int pid;
  final String name;
  final int bytes;
  final int depth;

  /// 非空表示这是 agent 经 `terminal/create` 开的终端（顶层显示，名称后带 ` · agent 终端 <terminalId>`）。
  final String? terminalId;

  bool get isIndented => depth > 0;
  bool get isAgentTerminal => terminalId != null && terminalId!.isNotEmpty;

  String get prefix => isIndented ? '└ ' : '';
  String? get terminalSuffix {
    if (!isAgentTerminal) return null;
    return name.isEmpty ? 'agent 终端 $terminalId' : ' · agent 终端 $terminalId';
  }
}

/// 单个已连接 agent 的进程与内存快照。
class AgentProcessSnapshot {
  const AgentProcessSnapshot({
    required this.agentId,
    required this.rootPid,
    required this.bytes,
    this.startedAt,
    this.takenAt,
    this.processes = const <ProcessNode>[],
    this.terminals = const <AgentTerminalProcess>[],
  });

  final String agentId;
  final int rootPid;
  final int bytes;
  final DateTime? startedAt;
  final DateTime? takenAt;
  final List<ProcessNode> processes;
  final List<AgentTerminalProcess> terminals;

  /// 进程总数 = agent 子树进程数 + 该 agent 打开的终端进程数。
  int get processCount => processes.length + terminals.length;

  /// 展开进程树的所有行：先排 agent 子树进程（按 `depth` 缩进），再排顶层 `agent 终端 <terminalId>`。
  List<ProcessTreeRow> get rows => <ProcessTreeRow>[
    for (final p in processes)
      ProcessTreeRow(pid: p.pid, name: p.name, bytes: p.bytes, depth: p.depth),
    for (final t in terminals)
      ProcessTreeRow(
        pid: t.pid,
        name: t.name,
        bytes: t.bytes,
        depth: 0,
        terminalId: t.terminalId,
      ),
  ];

  /// 已运行时长（缺省以快照采样时刻 [takenAt] 或当前时间为准）。
  Duration? uptime({DateTime? now}) {
    final start = startedAt;
    if (start == null) return null;
    final ref = now ?? takenAt ?? DateTime.now();
    final diff = ref.difference(start);
    return diff.isNegative ? Duration.zero : diff;
  }

  /// `已运行 1 小时 12 分` / `已运行 26 分` / `已运行 < 1 分`。
  String? uptimeText({DateTime? now}) {
    final d = uptime(now: now);
    return d == null ? null : formatProcessUptime(d);
  }

  factory AgentProcessSnapshot.fromJson(JsonMap json, {DateTime? takenAt}) {
    final rawProcesses = json['processes'];
    final rawTerminals = json['terminals'];
    final startMs = json['startedAt'];
    return AgentProcessSnapshot(
      agentId: json['agentId'] as String? ?? '',
      rootPid: (json['rootPid'] as num?)?.toInt() ?? 0,
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      startedAt: startMs is num && startMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(startMs.toInt())
          : null,
      takenAt: takenAt,
      processes: <ProcessNode>[
        if (rawProcesses is List)
          for (final p in rawProcesses)
            if (p is Map) ProcessNode.fromJson(p.cast<String, dynamic>()),
      ],
      terminals: <AgentTerminalProcess>[
        if (rawTerminals is List)
          for (final t in rawTerminals)
            if (t is Map)
              AgentTerminalProcess.fromJson(t.cast<String, dynamic>()),
      ],
    );
  }
}

/// 终端段（本地 shell 与 terminal auth 终端）的单项。
class TerminalProcessItem {
  const TerminalProcessItem({
    required this.terminalId,
    required this.source,
    required this.pid,
    required this.bytes,
  });

  final String terminalId;
  final String source;
  final int pid;
  final int bytes;

  factory TerminalProcessItem.fromJson(JsonMap json) => TerminalProcessItem(
    terminalId: json['terminalId'] as String? ?? '',
    source: json['source'] as String? ?? 'local',
    pid: (json['pid'] as num?)?.toInt() ?? 0,
    bytes: (json['bytes'] as num?)?.toInt() ?? 0,
  );
}

/// `process_snapshot` 命令的完整快照。
class ProcessSnapshot {
  const ProcessSnapshot({
    this.metric = MemoryMetric.private,
    this.takenAt,
    this.appPid = 0,
    this.hostBytes = 0,
    this.otherBytes = 0,
    this.agents = const <AgentProcessSnapshot>[],
    this.terminalCount = 0,
    this.terminalsBytes = 0,
    this.terminalItems = const <TerminalProcessItem>[],
    int? totalBytes,
  }) : _explicitTotal = totalBytes;

  final MemoryMetric metric;
  final DateTime? takenAt;
  final int appPid;

  /// 宿主进程自身字节数（`app.bytes`）。
  final int hostBytes;

  /// 其余短命子孙字节数（`other.bytes`）。
  final int otherBytes;
  final List<AgentProcessSnapshot> agents;
  final int terminalCount;
  final int terminalsBytes;
  final List<TerminalProcessItem> terminalItems;
  final int? _explicitTotal;

  /// 规格表 B：其余子孙（git 等短命进程）+ 宿主进程本身归「本应用」段。
  int get appBytes => hostBytes + otherBytes;

  /// Agents 段字节 = 各运行中 agent 的 `bytes` 之和。
  int get agentsBytes => agents.fold<int>(0, (sum, a) => sum + a.bytes);

  /// 运行中的 agent 数。
  int get runningAgentCount => agents.length;

  /// 合计字节 = 本应用 + Agents + 终端（若 JSON 显式给了正的 `total` 则取之）。
  int get totalBytes {
    final t = _explicitTotal;
    if (t != null && t > 0) return t;
    return appBytes + agentsBytes + terminalsBytes;
  }

  String get metricLabel => metric.label;
  String get metricSummary => metric.summary;
  String get metricTooltip => metric.tooltip;

  /// 终端数为 0 时整段图例省略（画板 54 C1 注）。
  bool get showTerminalsLegend => terminalCount > 0;

  /// 分段条只画 > 0 字节的段（规格表 A：按字节比例分，0 的段不画）。
  List<ResourceBarSegment> get barSegments => <ResourceBarSegment>[
    if (appBytes > 0)
      ResourceBarSegment(kind: ResourceSegmentKind.app, bytes: appBytes),
    if (agentsBytes > 0)
      ResourceBarSegment(kind: ResourceSegmentKind.agents, bytes: agentsBytes),
    if (terminalsBytes > 0)
      ResourceBarSegment(
        kind: ResourceSegmentKind.terminals,
        bytes: terminalsBytes,
      ),
  ];

  double get appFraction => totalBytes > 0 ? appBytes / totalBytes : 0;
  double get agentsFraction => totalBytes > 0 ? agentsBytes / totalBytes : 0;
  double get terminalsFraction =>
      totalBytes > 0 ? terminalsBytes / totalBytes : 0;

  AgentProcessSnapshot? agent(String agentId) {
    for (final a in agents) {
      if (a.agentId == agentId) return a;
    }
    return null;
  }

  factory ProcessSnapshot.fromJson(JsonMap json) {
    final takenMs = json['takenAt'];
    final takenAt = takenMs is num && takenMs > 0
        ? DateTime.fromMillisecondsSinceEpoch(takenMs.toInt())
        : null;
    final app = json['app'];
    final appMap = app is Map
        ? app.cast<String, dynamic>()
        : const <String, dynamic>{};
    final other = json['other'];
    final otherMap = other is Map
        ? other.cast<String, dynamic>()
        : const <String, dynamic>{};
    final terms = json['terminals'];
    final termsMap = terms is Map
        ? terms.cast<String, dynamic>()
        : const <String, dynamic>{};
    final rawAgents = json['agents'];
    final rawTermItems = termsMap['items'];
    final termItems = <TerminalProcessItem>[
      if (rawTermItems is List)
        for (final item in rawTermItems)
          if (item is Map)
            TerminalProcessItem.fromJson(item.cast<String, dynamic>()),
    ];
    final termCount = (termsMap['count'] as num?)?.toInt() ?? termItems.length;
    return ProcessSnapshot(
      metric: MemoryMetric.parse(json['metric'] as String?),
      takenAt: takenAt,
      appPid: (appMap['pid'] as num?)?.toInt() ?? 0,
      hostBytes: (appMap['bytes'] as num?)?.toInt() ?? 0,
      otherBytes: (otherMap['bytes'] as num?)?.toInt() ?? 0,
      agents: <AgentProcessSnapshot>[
        if (rawAgents is List)
          for (final a in rawAgents)
            if (a is Map)
              AgentProcessSnapshot.fromJson(
                a.cast<String, dynamic>(),
                takenAt: takenAt,
              ),
      ],
      terminalCount: termCount,
      terminalsBytes: (termsMap['bytes'] as num?)?.toInt() ?? 0,
      terminalItems: termItems,
      totalBytes: (json['total'] as num?)?.toInt(),
    );
  }
}

/// 运行时长文案（画板 54 A 段：`已运行 1 小时 12 分`、`已运行 26 分`、不足 1 分钟写 `已运行 < 1 分`）。
String formatProcessUptime(Duration duration) {
  if (duration.isNegative || duration.inMinutes < 1) return '已运行 < 1 分';
  final hours = duration.inHours;
  final minutes = duration.inMinutes % 60;
  if (hours == 0) return '已运行 $minutes 分';
  if (minutes == 0) return '已运行 $hours 小时';
  return '已运行 $hours 小时 $minutes 分';
}

/// 条目上的运行态阶段（画板 54 规格表 C & B3）。
enum AgentRunPhase { none, connecting, running, stopping }

/// 叠加在 [RegistryEntryData] 上的运行态视图数据。
class AgentEntryRuntime {
  const AgentEntryRuntime({
    this.phase = AgentRunPhase.none,
    this.pid,
    this.snapshot,
    this.metric = MemoryMetric.private,
    this.sessionCount = 0,
    this.expanded = false,
    this.stopHovered = false,
    this.now,
  });

  final AgentRunPhase phase;

  /// 根进程 PID（优先取 [snapshot] 的 `rootPid`，采样不可用时回退到 `acp/agent_state: spawned` 的 `pid`）。
  final int? pid;

  /// 该 agent 的内存与进程树采样（采样不可用时为 null，运行行只显示 `PID <pid>` 且不可展开）。
  final AgentProcessSnapshot? snapshot;
  final MemoryMetric metric;

  /// 挂在该 agent 上的活跃会话数（0 显示 `无会话`，> 0 显示 `N 个会话`）。
  final int sessionCount;

  /// 是否展开进程树（只在本次运行内记住）。
  final bool expanded;

  /// Stop 按钮是否固定出 hover 态（确认弹层打开时或画板 54 A 段第一行样张）。
  final bool stopHovered;
  final DateTime? now;

  bool get isRunning => phase == AgentRunPhase.running;
  bool get isConnecting => phase == AgentRunPhase.connecting;
  bool get isStopping => phase == AgentRunPhase.stopping;

  int? get effectivePid => snapshot?.rootPid ?? pid;
  bool get hasSample => snapshot != null && snapshot!.processCount > 0;
  bool get canExpand => isRunning && hasSample;

  int? get processCount => snapshot?.processCount;
  int? get bytes => snapshot?.bytes;
  String? get uptimeText => snapshot?.uptimeText(now: now);
  String get sessionLabel => sessionCount > 0 ? '$sessionCount 个会话' : '无会话';
  List<ProcessTreeRow> get rows => snapshot?.rows ?? const <ProcessTreeRow>[];
}
