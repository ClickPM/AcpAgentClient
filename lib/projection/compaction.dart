// 上下文压缩（unstable）：`compaction_update` 按 compactionId 就地打补丁（summary / error 有补丁语义：缺省不动、null 清空、
// 给值替换），`compaction_summary_chunk` 追加流式摘要。纯 Dart。

import 'entries.dart';
import 'wire.dart';

class CompactionApplyResult {
  const CompactionApplyResult({required this.entry, required this.created});

  final CompactionEntry entry;
  final bool created;
}

class CompactionStore {
  final Map<String, CompactionEntry> _byId = <String, CompactionEntry>{};

  CompactionEntry? operator [](String id) => _byId[id];
  Iterable<CompactionEntry> get all => _byId.values;

  /// `session/load` 重放前清空（R6）。
  void clear() => _byId.clear();

  CompactionApplyResult? applyUpdate(SessionUpdateWire u, {required DateTime now, required String Function() newId}) {
    final id = u.compactionId;
    if (id == null || id.isEmpty) return null;
    final r = _ensure(id, now: now, newId: newId);
    final e = r.entry;
    final status = u.compactionStatus;
    if (status != null) e.status = status;
    if (u.json.containsKey('summary')) {
      final s = u.json['summary'];
      e.summary = s is List
          ? <ContentBlockWire>[
              for (final item in s)
                if (item is Map) ContentBlockWire(item.cast<String, dynamic>()),
            ]
          : null;
    }
    if (u.json.containsKey('error')) e.error = u.compactionError;
    e.updatedAt = now;
    return r;
  }

  CompactionApplyResult? applyChunk(SessionUpdateWire u, {required DateTime now, required String Function() newId}) {
    final id = u.compactionId;
    if (id == null || id.isEmpty) return null;
    final r = _ensure(id, now: now, newId: newId);
    final c = u.content;
    if (c != null) r.entry.chunks.add(c);
    r.entry.updatedAt = now;
    return r;
  }

  /// Restore Checkpoint 截断时把条目从表里摘掉（SessionStore._forget）。
  void remove(String id) => _byId.remove(id);

  CompactionApplyResult _ensure(String id, {required DateTime now, required String Function() newId}) {
    final existing = _byId[id];
    if (existing != null) return CompactionApplyResult(entry: existing, created: false);
    final e = CompactionEntry(id: newId(), at: now, compactionId: id);
    _byId[id] = e;
    return CompactionApplyResult(entry: e, created: true);
  }
}
