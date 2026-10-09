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
  ///
  /// **按需算 + 记忆化**（iteration-18）：一条线里最大的一份数据就是这个缩进串（带图 prompt 一行 900 KB，
  /// 缩进后 1 MB 出头），而它只有流量面板把这一行展开时才用得到。[TrafficStore] 却保 2000 行，
  /// 收一条算一条＝把整段会话的流量按一倍多的体积常驻在堆里。这里改成第一次访问时算一次、算过记住；
  /// 也不留下解析出来的那个 Map——那同样让 2000 行的解码结果常驻，等于没省。
  ///
  /// 超长行（[TrafficStore.elideThreshold] 以上）缩进的是 [elidedRaw]：长字符串只留开头，见 [elideLongStrings]。
  String? get pretty {
    if (!_prettyResolved) {
      _prettyResolved = true;
      _pretty = _indentJson(_isLong ? elidedRaw : raw);
    }
    return _pretty;
  }

  String? _pretty;
  bool _prettyResolved = false;

  bool get _isLong => raw.length > TrafficStore.elideThreshold;

  /// 展开时显示的原文：短行就是 [raw]；超长行把长字符串截成开头一段，不是 JSON 的超长行直接截断。
  /// 带图 prompt 一行 2 MB 出头（所有者 2026-10-08 实测），整串交给着色器会铺出海量 `TextSpan` 直接撑爆堆。
  /// 同样按需算、不记忆：只有展开那一下用（缩进结果由 [pretty] 记住），常驻的仍只有 [raw]。
  /// 「复制行」照旧复制完整的 [raw]。
  String get elidedRaw {
    if (!_isLong) return raw;
    final body = direction == TrafficDirection.stderr || label == 'raw' ? raw : elideLongStrings(raw);
    // 截完长字符串仍然超门（大量短元素）：展示也要有上界，不能把整行交给出缩进和着色。
    if (body.length <= TrafficStore.elideThreshold) return body;
    return '${body.substring(0, TrafficStore.elideKeep)}…（省略 ${body.length - TrafficStore.elideKeep} 字符）';
  }

  String get displayMethod => method ?? (direction == TrafficDirection.stderr ? 'stderr' : '?');

  /// `14:02:03.560`。
  String get time {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(ts.hour)}:${two(ts.minute)}:${two(ts.second)}.${ts.millisecond.toString().padLeft(3, '0')}';
  }
}

/// 把一条原始行缩进成多行 JSON；不是 JSON（或解析不出）时 null，调用方退回 [TrafficLine.raw]。
/// `_parse` 那一次解析是必须的（要认出 `id` / `method` / 变体），缩进这一步只有展开时才补。
String? _indentJson(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) return const JsonEncoder.withIndent('  ').convert(decoded);
  } on FormatException {
    // 不是 JSON：退回 raw。
  }
  return null;
}

/// 把 JSON 文本里超过 [TrafficStore.elideKeep] 的字符串字面量截成开头一段 + `…（省略 N 字符）`，其余原样。
/// 结构（键、`id`、`method`、`sessionUpdate`）不受影响，所以截完仍是合法 JSON、标签照样认得出。
/// 手写的单趟扫描而不是正则：输入是几 MB 的整行，回溯型正则在这种长度上既慢又有栈风险。
/// 截断点落在转义序列之外（不切断 `\uXXXX` / `\"`），截出来的仍是合法的字符串字面量。
@visibleForTesting
String elideLongStrings(String raw) {
  const keep = TrafficStore.elideKeep;
  final out = StringBuffer();
  var i = 0;
  var copiedUpTo = 0;
  final n = raw.length;
  while (i < n) {
    if (raw.codeUnitAt(i) != 0x22) {
      i++;
      continue;
    }
    // 字符串字面量从 i（开引号）开始：找它的闭引号，顺带记下「保留 keep 个字符」的截断点。
    final start = i + 1;
    var j = start;
    var cut = -1;
    while (j < n) {
      final c = raw.codeUnitAt(j);
      if (c == 0x22) break;
      // 不切在代理对中间：原文里的低位代理，以及 `\uD83D\uDE00` 这种转义形式的一对。
      if (cut < 0 && j - start >= keep && !_inSurrogatePair(raw, j)) cut = j;
      // `\uXXXX` 是 6 个码元，其余转义 2 个：整个跳过，截断点只落在转义之间。
      j += c != 0x5c ? 1 : (j + 1 < n && raw.codeUnitAt(j + 1) == 0x75 ? 6 : 2);
    }
    if (j > n) j = n; // 末尾是一个落单的反斜杠：不是合法 JSON，原样收尾
    if (cut >= 0) {
      out
        ..write(raw.substring(copiedUpTo, cut))
        ..write('…（省略 ${j - cut} 字符）');
      copiedUpTo = j;
    }
    i = j + 1;
  }
  if (copiedUpTo == 0) return raw;
  out.write(raw.substring(copiedUpTo));
  return out.toString();
}

/// `j` 落在一对代理的前半（原文低位代理的前一个码元，或转义形式的高位 `\uD800`–`\uDBFF`）。
bool _inSurrogatePair(String raw, int j) {
  final n = raw.length;
  if (j < 0 || j >= n) return false;
  final c = raw.codeUnitAt(j);
  if (c >= 0xdc00 && c <= 0xdfff) return true;
  // 转义形式的低位代理，且前面紧挨着高位代理：截在这里会留下孤立的 `\uD83D`。
  if (_isSurrogateEscape(raw, j, high: false) && _isSurrogateEscape(raw, j - 6, high: true)) return true;
  if (c < 0xd800 || c > 0xdbff) {
    // 转义的高位代理：`\uD83D` 后面紧跟转义的低位代理才算一对。单独的 `\uD800` 可以截。
    if (!_isSurrogateEscape(raw, j, high: true)) return false;
    return _isSurrogateEscape(raw, j + 6, high: false);
  }
  return j + 1 < n && raw.codeUnitAt(j + 1) >= 0xdc00 && raw.codeUnitAt(j + 1) <= 0xdfff;
}

bool _isSurrogateEscape(String raw, int j, {required bool high}) {
  if (j < 0 || j + 6 > raw.length) return false;
  if (raw.codeUnitAt(j) != 0x5c || raw.codeUnitAt(j + 1) != 0x75) return false;
  final v = int.tryParse(raw.substring(j + 2, j + 6), radix: 16);
  if (v == null) return false;
  return high ? v >= 0xd800 && v <= 0xdbff : v >= 0xdc00 && v <= 0xdfff;
}

/// 超长、截完字符串仍然超门的行：只从文本里取 `method` / `id` / `sessionUpdate` / `stopReason`，不 `jsonDecode`。
/// 这些键通常在行首；取到的是第一个同名键，够给流量行做标签。取不到就当普通 JSON 对象，标签退回 request / response。
JsonMap _headerOnly(String raw) {
  final method = _jsonStringField(raw, 'method');
  final id = _jsonIdToken(raw);
  final variant = _jsonStringField(raw, 'sessionUpdate');
  final stop = _jsonStringField(raw, 'stopReason');
  return <String, dynamic>{
    if (method != null) 'method': method,
    if (id != null) 'id': id,
    if (method == 'session/update')
      'params': <String, dynamic>{
        'update': <String, dynamic>{'sessionUpdate': variant},
      },
    if (stop != null) 'result': <String, dynamic>{'stopReason': stop},
    if (raw.contains('"error"')) 'error': <String, dynamic>{},
  };
}

String? _jsonStringField(String raw, String key) {
  final value = _jsonValueAt(raw, key);
  if (value == null || value.isEmpty || value.codeUnitAt(0) != 0x22) return null;
  final end = value.indexOf('"', 1);
  if (end < 0) return null;
  return value.substring(1, end > 80 ? 80 : end);
}

/// `id` 可能是字符串或数字，回填表用它的文本形式。
String? _jsonIdToken(String raw) {
  final value = _jsonValueAt(raw, 'id');
  if (value == null || value.isEmpty) return null;
  if (value.codeUnitAt(0) == 0x22) {
    final end = value.indexOf('"', 1);
    return end < 0 ? null : value.substring(1, end);
  }
  final m = RegExp(r'^-?[0-9]+').matchAsPrefix(value);
  return m?.group(0);
}

/// 键后面的值从哪开始，最多看 200 个码元（方法名 / id / 变体都远小于此）。找不到返回 null。
String? _jsonValueAt(String raw, String key) {
  final needle = '"$key"';
  var from = 0;
  while (from < raw.length) {
    final at = raw.indexOf(needle, from);
    if (at < 0) return null;
    var j = at + needle.length;
    while (j < raw.length && _isJsonWs(raw.codeUnitAt(j))) {
      j++;
    }
    if (j >= raw.length || raw.codeUnitAt(j) != 0x3a) {
      from = at + needle.length;
      continue;
    }
    j++;
    while (j < raw.length && _isJsonWs(raw.codeUnitAt(j))) {
      j++;
    }
    if (j >= raw.length) return null;
    final end = j + 200 < raw.length ? j + 200 : raw.length;
    return raw.substring(j, end);
  }
  return null;
}

bool _isJsonWs(int c) => c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d;

class TrafficStore extends ChangeNotifier {
  /// 环形缓冲上限：调试面板不是日志留存，超出丢最旧的。
  static const int maxLines = 2000;

  /// 超过这么长（UTF-16 码元）的行先截掉长字符串再解析与展示（BACKLOG P0「超大 payload 进入 TrafficStore」）。
  /// 正常的 JSON-RPC 行远小于它；越过它的几乎都是 base64 图或整份文件的正文。
  static const int elideThreshold = 64 * 1024;

  /// 超长行里每个字符串字面量保留的开头长度。
  static const int elideKeep = 256;

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
    final source = raw.length > elideThreshold ? elideLongStrings(raw) : raw;
    if (raw.length > elideThreshold && source.length > elideThreshold) {
      // 截完长字符串还是超门（大量短元素拼成的数 MB）：不再 jsonDecode，避免整棵对象树。
      // 不是 JSON 对象的超长行保持「raw」。
      json = raw.trimLeft().startsWith('{') ? _headerOnly(raw) : null;
    } else {
      try {
        // 超长但能截短的行只解析截过的那一份：要的只是 `id` / `method` / 变体。
        final decoded = jsonDecode(source);
        if (decoded is Map) json = decoded.cast<String, dynamic>();
      } on FormatException {
        json = null;
      }
    }
    if (json == null) {
      return TrafficLine(
        seq: seq, agentId: agentId, direction: direction, raw: raw, ts: ts,
        method: null, label: 'raw', dropped: false,
      );
    }
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
        method: method, label: label, dropped: dropped,
      );
    }
    // 响应：只有 id，方法名回填自先前的请求。
    final resolved = id == null ? null : _pendingIds.remove('$id');
    var label = json.containsKey('error') ? 'error' : 'response';
    final stopReason = _mapOf(json['result'])?['stopReason'];
    if (stopReason is String) label = 'response · stopReason $stopReason';
    return TrafficLine(
      seq: seq, agentId: agentId, direction: direction, raw: raw, ts: ts,
      method: resolved, label: label, dropped: false,
    );
  }

  static JsonMap? _mapOf(Object? v) => v is Map ? v.cast<String, dynamic>() : null;
}
