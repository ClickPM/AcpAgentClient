// 工具调用的合并规则（docs/acp-projection.md § 2.2）与终端输出留存（§ 4 / § 7 第 5 条）。纯 Dart。
// - 同 toolCallId 覆盖；只有给出的字段才更新；content[] / locations[] 整体替换不是追加。
// - 先到的 tool_call_update 凭空建卡（§ 7 第 4 条）。
// - 未知 kind 落 other（Rust `#[serde(other)]`）；未知 status 整条丢弃（Rust 无 catch-all，§ 8.1）。
// - content[] 里未知类型逐项跳过并计数（§ 8.3 VecSkipError）。
// - 子代理分组只看 docs/design.md § 4 的入站 _meta 键是否存在，不按 agent 名判（规则 2）。

import 'package:flutter/foundation.dart';

import 'entries.dart';
import 'wire.dart';

/// 入站 `_meta` 识别键（docs/design.md § 4，所有者裁定 2026-09-15）。这是前端读取的入站键的全部清单。
abstract final class InboundMetaKeys {
  static const String claudeCode = 'claudeCode';
  static const String parentToolUseId = 'parentToolUseId';
  static const String subagent = 'subagent';
  static const String toolName = 'toolName';
  static const String dshSubagent = 'dsh_subagent';

  /// `_meta.claudeCode.parentToolUseId`：本条目归属的父工具调用。
  static String? parentToolCallIdOf(JsonMap? meta) {
    final cc = meta?[claudeCode];
    if (cc is! Map) return null;
    final v = cc[parentToolUseId];
    return v is String && v.isNotEmpty ? v : null;
  }

  /// `_meta.claudeCode.subagent` 或 `_meta.dsh_subagent` 存在 → 这条工具调用是子代理卡。
  static bool isSubagent(JsonMap? meta) {
    if (meta == null) return false;
    if (meta.containsKey(dshSubagent)) return true;
    final cc = meta[claudeCode];
    return cc is Map && cc.containsKey(subagent);
  }

  // ---- 终端 provider 通道（R4，所有者裁定待确认，见 rounds/round-04 任务卡）：Zed `agent_servers/acp.rs`
  //      `handle_session_notification` 的 post-handle 只读这三键；钉版本的 claude-agent-acp / dsh-acp-interactive / codex-acp
  //      都不调 terminal/create，而是把命令输出经 `tool_call_update._meta` 送来。只按键存在，不按 agent 名判（规则 2）。
  static const String terminalInfo = 'terminal_info';
  static const String terminalOutput = 'terminal_output';
  static const String terminalExit = 'terminal_exit';
  static const String terminalIdField = 'terminal_id';
}

enum TerminalMetaKind { info, output, exit }

/// `_meta.terminal_*` 解出来的一条终端事件。
class TerminalMetaEvent {
  const TerminalMetaEvent(this.kind, this.terminalId, {this.data, this.exitCode, this.signal, this.cwd});

  final TerminalMetaKind kind;
  final String terminalId;

  /// `terminal_output.data`：追加语义（Zed `TerminalProviderEvent::Output`）。
  final String? data;

  /// `terminal_exit.exit_code` / `.signal`：任一缺省都合法（dsh 只给其中一个）。
  final int? exitCode;
  final String? signal;

  /// `terminal_info.cwd`（dsh 会带；Zed 不读，这里只带出来给卡片副标题用）。
  final String? cwd;

  /// 固定顺序 info → output → exit，与 Zed 的处理顺序一致；键存在但形状不对（没有 `terminal_id`）的整项跳过。
  static List<TerminalMetaEvent> parse(JsonMap? meta) {
    if (meta == null) return const <TerminalMetaEvent>[];
    final out = <TerminalMetaEvent>[];
    final info = meta[InboundMetaKeys.terminalInfo];
    if (info is Map) {
      final id = info[InboundMetaKeys.terminalIdField];
      if (id is String && id.isNotEmpty) {
        out.add(TerminalMetaEvent(TerminalMetaKind.info, id, cwd: info['cwd'] is String ? info['cwd'] as String : null));
      }
    }
    final output = meta[InboundMetaKeys.terminalOutput];
    if (output is Map) {
      final id = output[InboundMetaKeys.terminalIdField];
      final data = output['data'];
      if (id is String && id.isNotEmpty && data is String) out.add(TerminalMetaEvent(TerminalMetaKind.output, id, data: data));
    }
    final exit = meta[InboundMetaKeys.terminalExit];
    if (exit is Map) {
      final id = exit[InboundMetaKeys.terminalIdField];
      if (id is String && id.isNotEmpty) {
        final code = exit['exit_code'];
        final signal = exit['signal'];
        out.add(TerminalMetaEvent(
          TerminalMetaKind.exit,
          id,
          exitCode: code is num ? code.toInt() : null,
          signal: signal is String ? signal : null,
        ));
      }
    }
    return out;
  }
}

class ToolCallApplyResult {
  const ToolCallApplyResult({required this.entry, required this.created, required this.dropped});

  final ToolCallEntry? entry;
  final bool created;

  /// 未知 ToolCallStatus：整条丢弃（entry 为 null）。
  final String? dropped;
}

/// 按 toolCallId 索引的工具调用表。条目本身也进转录列表（顶层或父卡的 children），由 SessionStore 负责摆放。
class ToolCallStore {
  final Map<String, ToolCallEntry> _byId = <String, ToolCallEntry>{};

  ToolCallEntry? operator [](String id) => _byId[id];
  Iterable<ToolCallEntry> get all => _byId.values;
  bool contains(String id) => _byId.containsKey(id);

  /// `session/load` 重放前清空（R6）。
  void clear() => _byId.clear();

  /// `tool_call` / `tool_call_update` 的总入口。`newId` 由调用方分配本地序号。
  ToolCallApplyResult apply(
    ToolCallWire w, {
    required bool isUpdate,
    required DateTime now,
    required String Function() newId,
    JsonMap? updateMeta,
  }) {
    final id = w.toolCallId;
    if (id == null || id.isEmpty) {
      return const ToolCallApplyResult(entry: null, created: false, dropped: 'tool call without toolCallId');
    }
    ToolStatus? status;
    if (w.hasStatus) {
      status = ToolStatus.tryParse(w.status);
      if (status == null) {
        return ToolCallApplyResult(entry: null, created: false, dropped: 'unknown ToolCallStatus: ${w.status}');
      }
    }
    final meta = w.meta ?? updateMeta;
    var created = false;
    var entry = _byId[id];
    if (entry == null) {
      created = true;
      entry = ToolCallEntry(
        id: newId(),
        at: now,
        toolCallId: id,
        title: w.title ?? '(未命名工具调用)',
        createdFromUpdate: isUpdate,
        parentToolCallId: InboundMetaKeys.parentToolCallIdOf(meta),
        isSubagent: InboundMetaKeys.isSubagent(meta),
      );
      if (!isUpdate) entry.meta = w.meta;
      _byId[id] = entry;
    } else {
      // 分组键首见即锁定；update 上的 _meta 只用来补分组，不并进 entry.meta。
      entry.parentToolCallId ??= InboundMetaKeys.parentToolCallIdOf(meta);
      if (!entry.isSubagent && InboundMetaKeys.isSubagent(meta)) entry.isSubagent = true;
      if (!isUpdate && entry.meta == null) entry.meta = w.meta;
    }
    if (w.title != null) entry.title = w.title!;
    if (w.name != null) entry.name = w.name;
    if (w.hasKind) {
      final k = ToolKind.tryParse(w.kind);
      if (k == null) {
        entry.kind = ToolKind.other;
        entry.rawKind = w.kind;
      } else {
        entry.kind = k;
        entry.rawKind = null;
      }
    }
    if (status != null) {
      entry.status = status;
      if (status == ToolStatus.completed || status == ToolStatus.failed) entry.finishedAt = now;
    }
    if (w.hasContent) {
      final kept = <ToolCallContentWire>[];
      var skipped = 0;
      for (final c in w.content) {
        if (c.type == ToolCallContentType.unknown) {
          skipped++;
        } else {
          kept.add(c);
        }
      }
      entry.content = kept; // 替换，不是追加
      entry.skippedContent = skipped; // 计数跟着这一份 content 走，不累加（审查 P3）
    }
    if (w.hasLocations) entry.locations = w.locations; // 同上
    if (w.json.containsKey('rawInput')) entry.rawInput = w.rawInput;
    if (w.json.containsKey('rawOutput')) entry.rawOutput = w.rawOutput;
    entry.updatedAt = now;
    return ToolCallApplyResult(entry: entry, created: created, dropped: null);
  }

  /// § 7 第 1 条：发出 session/cancel 后，未完成的工具调用本地标 cancelled；返回被标记的 id。
  List<String> cancelUnfinished(DateTime now) {
    final touched = <String>[];
    for (final e in _byId.values) {
      if (!e.cancelledLocally && (e.status == ToolStatus.pending || e.status == ToolStatus.inProgress)) {
        e.cancelledLocally = true;
        e.finishedAt = now;
        e.updatedAt = now;
        touched.add(e.toolCallId);
      }
    }
    return touched;
  }

  void remove(String id) => _byId.remove(id);
}

/// 嵌入工具卡的终端输出缓冲（§ 4：release 后输出仍留在卡上；截断落在字符边界）。
class TerminalBuffer extends ChangeNotifier {
  TerminalBuffer(this.terminalId, {this.limit = defaultLimit});

  static const int defaultLimit = 65536;

  final String terminalId;
  final int limit;
  final StringBuffer _out = StringBuffer();
  String _cached = '';
  bool truncated = false;
  int? exitCode;
  String? signal;
  bool released = false;
  bool killed = false;

  /// `_meta.terminal_info.cwd`（有的 agent 会带；没有就用会话 cwd）。
  String? cwd;

  String get output => _cached;
  bool get exited => exitCode != null || signal != null;

  void append(String chunk) {
    _out.write(chunk);
    var s = _out.toString();
    if (s.length > limit) {
      var start = s.length - limit;
      // 不切出半个代理对（字符边界）。
      if (start > 0 && start < s.length) {
        final cu = s.codeUnitAt(start);
        if (cu >= 0xDC00 && cu <= 0xDFFF) start++;
      }
      s = s.substring(start);
      truncated = true;
      _out
        ..clear()
        ..write(s);
    }
    _cached = s;
    notifyListeners();
  }

  void exit({int? code, String? sig}) {
    exitCode = code;
    signal = sig;
    notifyListeners();
  }

  void markReleased() {
    released = true;
    notifyListeners();
  }

  void markKilled() {
    killed = true;
    notifyListeners();
  }
}

class TerminalStore {
  final Map<String, TerminalBuffer> _byId = <String, TerminalBuffer>{};

  TerminalBuffer ensure(String terminalId, {int? limit}) =>
      _byId.putIfAbsent(terminalId, () => TerminalBuffer(terminalId, limit: limit ?? TerminalBuffer.defaultLimit));

  TerminalBuffer? operator [](String id) => _byId[id];
  Iterable<TerminalBuffer> get all => _byId.values;

  /// `session/load` 重放前清空（R6）：终端缓冲跟着工具卡走，卡没了缓冲也不该留。
  void clear() => _byId.clear();
}
