// `acp/traffic` 的投影（docs/design.md § 3）：`{agentId, direction, line, ts}`，`line` 是核心已脱敏的原始行
// （`Authorization` / `api_key` / `token` 类键的值已成 `***`，规则 8；本层不再二次处理，也不落盘）。
// 画板 80 的数据源。纯 Dart，不依赖 widget。
//
// 行标签（画板 80 的变体芯片）按线本身解析：
// - 带 `method` 的是请求 / 通知：`session/update` 取 `params.update.sessionUpdate` 作标签，
//   表外变体标成 `unknown · dropped`（§ 8.1：Rust 侧整条反序列化失败，只有原始行能看到）；
// - 带 `result` / `error` 的是响应：方法名按 `id` 回填自同一条连接上先前的请求，`session/prompt` 的响应带上 stopReason；
// - `stderr` 方向的行不是 JSON，原样收进尾巴区。

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'wire.dart';

enum TrafficDirection {
  /// agent stdout（收）。
  inbound('in'),

  /// agent stdin（发）。
  outbound('out'),
  stderr('stderr');

  const TrafficDirection(this.wire);

  final String wire;

  static TrafficDirection parse(String? wire) {
    for (final d in values) {
      if (d.wire == wire) return d;
    }
    return TrafficDirection.inbound;
  }
}

/// 一条流量行。
class TrafficLine {
  TrafficLine({
    required this.seq,
    required this.agentId,
    required this.direction,
    required this.raw,
    required this.ts,
    required this.method,
    required this.label,
    required this.dropped,
    this.pretty,
  });

  /// 到达序（列表 key 与「复制行」用）。
  final int seq;
  final String? agentId;
  final TrafficDirection direction;

  /// 脱敏后的原始行。
  final String raw;
  final DateTime ts;

  /// 方法名；响应行是按 id 回填的，回填不到时为 null。
  final String? method;

  /// 变体芯片文字（request / response / `<sessionUpdate>` / `unknown · dropped` / `response · stopReason …`）。
  final String label;

  /// 未知 `session/update` 变体：整条通知在核心侧反序列化失败并被丢弃。
  final bool dropped;

  /// 展开时显示的缩进 JSON（不是 JSON 的行为 null，展开直接显示 [raw]）。
  final String? pretty;

  String get displayMethod => method ?? (direction == TrafficDirection.stderr ? 'stderr' : '?');

  /// `14:02:03.560`。
  String get time {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(ts.hour)}:${two(ts.minute)}:${two(ts.second)}.${ts.millisecond.toString().padLeft(3, '0')}';
  }
}

class TrafficStore extends ChangeNotifier {
  /// 环形缓冲上限：调试面板不是日志留存，超出丢最旧的。
  static const int maxLines = 2000;

  /// stderr 尾巴保留行数（与核心 `exited` 的尾巴口径一致）。
  static const int stderrKeep = 5;

  final List<TrafficLine> lines = <TrafficLine>[];

  /// 每个 agent 的 stderr 尾巴。
  final Map<String, List<String>> stderr = <String, List<String>>{};

  /// `id` → 请求方法名，用来给响应行回填方法名；随环形缓冲一起裁剪。
  final Map<String, String> _pendingIds = <String, String>{};

  int _seq = 0;
  int droppedCount = 0;
  DateTime? firstDroppedAt;

  /// `acp/traffic` 的 payload 原样。
  void apply(JsonMap payload) {
    final line = _parse(payload);
    if (line == null) return;
    if (line.direction == TrafficDirection.stderr) {
      final key = line.agentId ?? '';
      final tail = stderr.putIfAbsent(key, () => <String>[]);
      tail.add(line.raw);
      if (tail.length > stderrKeep) tail.removeRange(0, tail.length - stderrKeep);
      notifyListeners();
      return;
    }
    if (line.dropped) {
      droppedCount++;
      firstDroppedAt ??= line.ts;
    }
    lines.add(line);
    if (lines.length > maxLines) lines.removeRange(0, lines.length - maxLines);
    if (_pendingIds.length > maxLines) _pendingIds.clear();
    notifyListeners();
  }

  void clear() {
    lines.clear();
    stderr.clear();
    _pendingIds.clear();
    droppedCount = 0;
    firstDroppedAt = null;
    notifyListeners();
  }

  /// 方向与方法名过滤（画板 80 的「全部 / ← 收 / → 发」与方法名输入框）。
  List<TrafficLine> filtered({TrafficDirection? direction, String query = ''}) {
    final q = query.trim().toLowerCase();
    return <TrafficLine>[
      for (final l in lines)
        if ((direction == null || l.direction == direction) && (q.isEmpty || l.displayMethod.toLowerCase().contains(q))) l,
    ];
  }

  TrafficLine? _parse(JsonMap payload) {
    final raw = payload['line'];
    if (raw is! String) return null;
    final direction = TrafficDirection.parse(payload['direction'] as String?);
    final tsMillis = payload['ts'];
    final ts = tsMillis is num
        ? DateTime.fromMillisecondsSinceEpoch(tsMillis.toInt())
        : DateTime.now();
    final agentId = payload['agentId'] as String?;
    final seq = ++_seq;
    if (direction == TrafficDirection.stderr) {
      return TrafficLine(
        seq: seq, agentId: agentId, direction: direction, raw: raw, ts: ts,
        method: null, label: 'stderr', dropped: false,
      );
    }
    JsonMap? json;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) json = decoded.cast<String, dynamic>();
    } on FormatException {
      json = null;
    }
    if (json == null) {
      return TrafficLine(
        seq: seq, agentId: agentId, direction: direction, raw: raw, ts: ts,
        method: null, label: 'raw', dropped: false,
      );
    }
    final pretty = const JsonEncoder.withIndent('  ').convert(json);
    final id = json['id'];
    final method = json['method'];
    if (method is String) {
      if (id != null) _pendingIds['$id'] = method;
      var label = id == null ? 'notification' : 'request';
      var dropped = false;
      if (method == 'session/update') {
        final update = _mapOf(_mapOf(json['params'])?['update']);
        final variant = update?['sessionUpdate'];
        final kind = SessionUpdateKind.parse(variant is String ? variant : null);
        if (kind == SessionUpdateKind.unknown) {
          label = 'unknown · dropped';
          dropped = true;
        } else {
          label = kind.wire;
        }
      }
      return TrafficLine(
        seq: seq, agentId: agentId, direction: direction, raw: raw, ts: ts,
        method: method, label: label, dropped: dropped, pretty: pretty,
      );
    }
    // 响应：只有 id，方法名回填自先前的请求。
    final resolved = id == null ? null : _pendingIds.remove('$id');
    var label = json.containsKey('error') ? 'error' : 'response';
    final stopReason = _mapOf(json['result'])?['stopReason'];
    if (stopReason is String) label = 'response · stopReason $stopReason';
    return TrafficLine(
      seq: seq, agentId: agentId, direction: direction, raw: raw, ts: ts,
      method: resolved, label: label, dropped: false, pretty: pretty,
    );
  }

  static JsonMap? _mapOf(Object? v) => v is Map ? v.cast<String, dynamic>() : null;
}
