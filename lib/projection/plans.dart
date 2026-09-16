// 计划（docs/acp-projection.md § 2.3）：稳定 `plan` 整份替换、无 id；unstable `plan_update` 三种载荷（items / file / markdown）
// 与 `plan_removed` 按 planId 增删。纯 Dart。

import 'entries.dart';
import 'wire.dart';

class PlanApplyResult {
  const PlanApplyResult({required this.entry, required this.created});

  final PlanCardEntry entry;
  final bool created;
}

class PlanStore {
  final Map<String, PlanCardEntry> _byId = <String, PlanCardEntry>{};

  PlanCardEntry? operator [](String planId) => _byId[planId];
  Iterable<PlanCardEntry> get all => _byId.values;

  /// `session/load` 重放前清空（R6）。
  void clear() => _byId.clear();

  /// 稳定 `plan`：整份替换。
  PlanApplyResult applyStable(List<PlanEntryWire> entries, {required DateTime now, required String Function() newId}) {
    final r = _ensure(PlanCardEntry.stablePlanId, isStable: true, now: now, newId: newId);
    r.entry
      ..type = PlanPayloadType.items
      ..items = _items(entries)
      ..removed = false
      ..updatedAt = now;
    return r;
  }

  /// `plan_update.plan`：items / file / markdown，都带 planId。
  PlanApplyResult? applyUpdate(PlanUpdateWire p, {required DateTime now, required String Function() newId}) {
    final planId = p.planId;
    if (planId == null || planId.isEmpty) return null;
    final r = _ensure(planId, isStable: false, now: now, newId: newId);
    final e = r.entry;
    switch (p.type) {
      case 'file':
        e
          ..type = PlanPayloadType.file
          ..uri = p.uri;
      case 'markdown':
        e
          ..type = PlanPayloadType.markdown
          ..markdown = p.markdown;
      default:
        e
          ..type = PlanPayloadType.items
          ..items = _items(p.entries);
    }
    e
      ..removed = false
      ..updatedAt = now;
    return r;
  }

  /// `plan_removed`：保留条目并打标（画板 29「一份计划被移除」）。没见过的 planId 也建一条打标的卡，让这条更新可见。
  PlanApplyResult? applyRemoved(String? planId, {required DateTime now, required String Function() newId}) {
    if (planId == null || planId.isEmpty) return null;
    final r = _ensure(planId, isStable: false, now: now, newId: newId);
    r.entry
      ..removed = true
      ..updatedAt = now;
    return r;
  }

  /// 本地 ✕：只隐藏本地呈现，不回写 agent。
  bool dismiss(String planId) {
    final e = _byId[planId];
    if (e == null) return false;
    e.dismissed = true;
    return true;
  }

  /// Restore Checkpoint 截断时把条目从表里摘掉（SessionStore._forget）。
  void remove(String planId) => _byId.remove(planId);

  PlanApplyResult _ensure(String planId, {required bool isStable, required DateTime now, required String Function() newId}) {
    final existing = _byId[planId];
    if (existing != null) return PlanApplyResult(entry: existing, created: false);
    final e = PlanCardEntry(id: newId(), at: now, planId: planId, isStable: isStable);
    _byId[planId] = e;
    return PlanApplyResult(entry: e, created: true);
  }

  static List<PlanItem> _items(List<PlanEntryWire> entries) => <PlanItem>[
        for (final w in entries)
          PlanItem(content: w.content ?? '', priority: PlanPriority.parse(w.priority), status: PlanItemStatus.parse(w.status)),
      ];
}
