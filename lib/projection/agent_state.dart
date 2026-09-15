// `acp/agent_state` 的连接级状态（docs/design.md § 3）：spawned / initialized / auth_required / authenticating /
// update_dropped / exited / core_ready；每条都带 droppedUpdates 计数。画板 34 的数据源。纯 Dart。

import 'package:flutter/foundation.dart';

import 'wire.dart';

enum AgentLifecycle {
  none(''),
  spawned('spawned'),
  initialized('initialized'),
  authRequired('auth_required'),
  authenticating('authenticating'),
  exited('exited'),
  coreReady('core_ready'),
  unknown('?');

  const AgentLifecycle(this.wire);

  final String wire;

  static AgentLifecycle parse(String? wire) {
    for (final s in values) {
      if (s != none && s != unknown && s.wire == wire) return s;
    }
    return unknown;
  }
}

/// 一个 agent 的连接状态。`update_dropped` 不改生命周期，只加计数与最近一次错误。
class AgentConnection {
  AgentConnection(this.agentId);

  final String agentId;
  AgentLifecycle state = AgentLifecycle.none;
  String? rawState;
  num? pid;
  String? program;
  List<String> args = const <String>[];
  String? cwd;

  /// InitializeResponse 原样。
  JsonMap? initialize;
  List<JsonMap> authMethods = const <JsonMap>[];
  String? authMessage;
  String? authenticatingMethodId;
  String? authenticatingTerminalId;
  String? authenticatingLabel;
  num? exitCode;
  String? signal;
  String? stderrTail;
  String? transportError;
  int droppedUpdates = 0;
  String? lastDropMethod;
  String? lastDropError;

  /// stderr 行流（fixtures 的 `stderr` 行 / `acp/traffic` 的 stderr 方向）最后 N 行，与 exited 的尾巴分开记。
  final List<String> stderrLines = <String>[];

  String? get agentName => _asMap(initialize?['agentInfo'])?['name'] as String?;
  String? get agentTitle => _asMap(initialize?['agentInfo'])?['title'] as String?;
  String? get agentVersion => _asMap(initialize?['agentInfo'])?['version'] as String?;
  num? get protocolVersion => initialize?['protocolVersion'] is num ? initialize!['protocolVersion'] as num : null;
  JsonMap? get agentCapabilities => _asMap(initialize?['agentCapabilities']);

  /// 画板 34「fs / terminal / elicitation / plan / compaction」：把 agentCapabilities 的顶层键名列出来。
  List<String> get capabilityNames => agentCapabilities?.keys.toList(growable: false) ?? const <String>[];

  static JsonMap? _asMap(Object? v) => v is Map ? v.cast<String, dynamic>() : null;
}

class AgentStateStore extends ChangeNotifier {
  static const int stderrKeep = 5;

  final Map<String, AgentConnection> _byAgent = <String, AgentConnection>{};

  /// 核心自身（`agentId: null` 的 core_ready）。
  AgentConnection? core;

  AgentConnection? operator [](String agentId) => _byAgent[agentId];
  Iterable<AgentConnection> get all => _byAgent.values;

  AgentConnection ensure(String agentId) => _byAgent.putIfAbsent(agentId, () => AgentConnection(agentId));

  /// `acp/agent_state` 事件 payload 原样。
  void apply(JsonMap payload) {
    final w = AgentStateWire(payload);
    final state = AgentLifecycle.parse(w.state);
    final agentId = w.agentId;
    final c = agentId == null ? (core ??= AgentConnection('')) : ensure(agentId);
    c.rawState = w.state;
    if (w.droppedUpdates != null) c.droppedUpdates = w.droppedUpdates!.toInt();
    switch (w.state) {
      case 'update_dropped':
        c.lastDropMethod = payload['method'] as String?;
        c.lastDropError = payload['error'] as String?;
      case 'spawned':
        c
          ..state = state
          ..pid = payload['pid'] is num ? payload['pid'] as num : null
          ..program = payload['program'] as String?
          ..args = payload['args'] is List ? (payload['args'] as List).map((e) => e.toString()).toList() : const <String>[]
          ..cwd = payload['cwd'] as String?;
      case 'initialized':
        c
          ..state = state
          ..initialize = payload['initialize'] is Map ? (payload['initialize'] as Map).cast<String, dynamic>() : null;
        final methods = c.initialize?['authMethods'];
        if (methods is List) {
          c.authMethods = <JsonMap>[
            for (final m in methods)
              if (m is Map) m.cast<String, dynamic>(),
          ];
        }
      case 'auth_required':
        c
          ..state = state
          ..authMessage = payload['message'] as String?;
        final methods = payload['authMethods'];
        if (methods is List) {
          c.authMethods = <JsonMap>[
            for (final m in methods)
              if (m is Map) m.cast<String, dynamic>(),
          ];
        }
      case 'authenticating':
        c
          ..state = state
          ..authenticatingMethodId = payload['methodId'] as String?
          ..authenticatingTerminalId = payload['terminalId'] as String?
          ..authenticatingLabel = payload['label'] as String?;
      case 'exited':
        c
          ..state = state
          ..exitCode = payload['code'] is num ? payload['code'] as num : null
          ..signal = payload['signal'] as String?
          ..stderrTail = w.stderrTail
          ..transportError = payload['transportError'] as String?;
      default:
        c.state = state;
    }
    notifyListeners();
  }

  /// `initialize` 的响应（fixtures 回放 / R3 接线时从 agent_connect 结果补），等价于 `initialized` 事件。
  void applyInitializeResult(String agentId, JsonMap result) {
    apply(<String, dynamic>{'agentId': agentId, 'state': 'initialized', 'initialize': result});
  }

  void appendStderr(String agentId, String line) {
    final c = ensure(agentId);
    c.stderrLines.add(line);
    while (c.stderrLines.length > stderrKeep) {
      c.stderrLines.removeAt(0);
    }
    notifyListeners();
  }

  JsonMap debugSnapshot() => <String, dynamic>{
        for (final c in _byAgent.values)
          c.agentId: <String, dynamic>{
            'state': c.state.name,
            'pid': c.pid,
            'agentName': c.agentName,
            'authMethods': c.authMethods.length,
            'exitCode': c.exitCode,
            'droppedUpdates': c.droppedUpdates,
            'stderrLines': List<String>.of(c.stderrLines),
          },
      };
}
