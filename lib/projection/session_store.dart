// 投影状态层的组合根（docs/design.md § 3「前端状态规则」+ docs/acp-projection.md § 7）。纯 Dart，ChangeNotifier；
// 规则来自 prototype/assets/projection.js，只搬规则不搬代码。
// - 按 sessionId 累积 update；消息分组：messageId 变化另起一条，无 messageId 按角色连续合并；
// - 思考折叠单元：连续 agent_thought_chunk 合成一段，其它条目到达或轮结束时关闭；
// - 轮边界与检查点：session/prompt 请求到响应之间是一轮（TurnEntry），Restore = 本地截断其后全部投影块；
// - 本地时间戳：注入时钟（测试用固定时钟，分批 / 整批回放可比对）；
// - 未知 sessionUpdate / 未知 ToolCallStatus 整条丢弃并计数（与 Rust 侧 § 8.1 同口径）。

import 'package:flutter/foundation.dart';

import 'agent_state.dart';
import 'compaction.dart';
import 'entries.dart';
import 'pending.dart';
import 'plans.dart';
import 'tool_calls.dart';
import 'usage.dart';
import 'wire.dart';

typedef Clock = DateTime Function();

class RestoreResult {
  const RestoreResult({required this.turn, required this.cancelledRequestIds, required this.cancelledElicitationIds});

  /// 被截断的轮（其 prompt 用于同会话重发）。
  final TurnEntry turn;

  /// 要以 `PendingQueue.cancelledOutcome` 回应的权限请求。
  final List<String> cancelledRequestIds;

  /// 要以 `PendingQueue.cancelledAction` 回应的 elicitation。
  final List<String> cancelledElicitationIds;
}

class CancelResult {
  const CancelResult({
    required this.toolCallIds,
    required this.cancelledRequestIds,
    required this.cancelledElicitationIds,
  });

  /// 本地标成 cancelled 的工具调用。
  final List<String> toolCallIds;

  /// 要以 `{outcome: {outcome: cancelled}}` 回应的权限请求（核心在 R1 也会自动回，前端只是同步本地队列）。
  final List<String> cancelledRequestIds;

  /// 挂起的 elicitation：**接线侧必须**逐条 `acp_respond(PendingQueue.cancelledAction)`——
  /// 核心的 `session/cancel` 只自动回权限请求，elicitation 不回 agent 会一直等（审查 finding high）。
  final List<String> cancelledElicitationIds;
}

class SessionStore extends ChangeNotifier {
  SessionStore({
    required this.sessionId,
    this.agentId,
    PendingQueue? pending,
    TerminalStore? terminals,
    Clock? clock,
  })  : pending = pending ?? PendingQueue(),
        terminals = terminals ?? TerminalStore(),
        _clock = clock ?? DateTime.now;

  final String sessionId;
  String? agentId;

  /// `session/new` 的 cwd（路径显示时相对化用；R3 从项目目录来）。
  String? cwd;
  final PendingQueue pending;
  final TerminalStore terminals;
  final Clock _clock;

  /// 顶层转录块（子代理卡里的嵌套条目在 ToolCallEntry.children）。
  final List<TranscriptEntry> entries = <TranscriptEntry>[];
  final ToolCallStore toolCalls = ToolCallStore();
  final PlanStore plans = PlanStore();
  final CompactionStore compactions = CompactionStore();

  UsageState? usage;
  List<AvailableCommandWire> commands = const <AvailableCommandWire>[];
  List<ConfigOptionWire> configOptions = const <ConfigOptionWire>[];

  /// `session/new` 返回的 modes（老 agent 的回退；同时有 configOptions 时只用 configOptions）。
  JsonMap? modes;
  String? currentModeId;
  String? title;
  String? updatedAt;

  int turnCount = 0;
  TurnEntry? currentTurn;
  final List<DroppedUpdate> dropped = <DroppedUpdate>[];

  /// 每个变体见过的次数（流量面板 / 测试）。
  final Map<String, int> seen = <String, int>{};

  int _seq = 0;
  int _batchDepth = 0;
  bool _dirty = false;

  DateTime get now => _clock();
  bool get isRunning => currentTurn != null;

  String _newId(String prefix) => '${prefix}_${++_seq}';

  // ---------------------------------------------------------------- 批量（按帧合并）

  void beginBatch() => _batchDepth++;

  void endBatch() {
    _batchDepth--;
    if (_batchDepth <= 0) {
      _batchDepth = 0;
      if (_dirty) {
        _dirty = false;
        notifyListeners();
      }
    }
  }

  void batch(void Function() body) {
    beginBatch();
    try {
      body();
    } finally {
      endBatch();
    }
  }

  void _changed() {
    if (_batchDepth > 0) {
      _dirty = true;
    } else {
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- session/update

  void applyNotification(SessionNotificationWire n) => applyUpdate(n.update, notificationMeta: n.meta);

  void applyUpdateJson(JsonMap update) => applyUpdate(SessionUpdateWire(update));

  void applyUpdate(SessionUpdateWire u, {JsonMap? notificationMeta}) {
    final now = this.now;
    final kind = u.kind;
    if (kind == SessionUpdateKind.unknown) {
      _drop('unknown sessionUpdate: ${u.rawKind} — 我们编译不出这个变体，整条通知被丢弃', u.json, now);
      return;
    }
    final meta = u.meta ?? notificationMeta;
    switch (kind) {
      case SessionUpdateKind.userMessageChunk:
        _appendMessage(MessageRole.user, u, meta, now);
      case SessionUpdateKind.agentMessageChunk:
        _appendMessage(MessageRole.agent, u, meta, now);
      case SessionUpdateKind.agentThoughtChunk:
        _appendThought(u, meta, now);
      case SessionUpdateKind.toolCall:
      case SessionUpdateKind.toolCallUpdate:
        final tcId = u.toolCall.toolCallId;
        final prevParent = tcId == null ? null : toolCalls[tcId]?.parentToolCallId;
        final r = toolCalls.apply(
          u.toolCall,
          isUpdate: kind == SessionUpdateKind.toolCallUpdate,
          now: now,
          newId: () => _newId('tool'),
          updateMeta: meta,
        );
        if (r.dropped != null) {
          _drop(r.dropped!, u.json, now);
          return;
        }
        final entry = r.entry!;
        if (r.created) {
          _ensureParent(entry.parentToolCallId, now);
          _place(entry, now);
        } else if (prevParent == null && entry.parentToolCallId != null) {
          // § 7.4 先凭空建在顶层的卡，分组键随后才到：搬进父卡 children（审查 P2）。
          entries.remove(entry);
          _ensureParent(entry.parentToolCallId, now);
          _place(entry, now);
        }
        // 终端 provider 通道（待确认）：update 自带的 `_meta.terminal_*` 直接进终端缓冲，与 Zed 的 post-handle 同序。
        _applyTerminalMeta(u.meta);
      case SessionUpdateKind.plan:
        final r = plans.applyStable(u.planEntries, now: now, newId: () => _newId('plan'));
        if (r.created) _place(r.entry, now);
      case SessionUpdateKind.planUpdate:
        final p = u.planUpdate;
        if (p == null) {
          _drop('plan_update without plan', u.json, now);
          return;
        }
        final r = plans.applyUpdate(p, now: now, newId: () => _newId('plan'));
        if (r == null) {
          _drop('plan_update without planId', u.json, now);
          return;
        }
        if (r.created) _place(r.entry, now);
      case SessionUpdateKind.planRemoved:
        final r = plans.applyRemoved(u.planId, now: now, newId: () => _newId('plan'));
        if (r == null) {
          _drop('plan_removed without planId', u.json, now);
          return;
        }
        if (r.created) _place(r.entry, now);
      case SessionUpdateKind.compactionUpdate:
        final r = compactions.applyUpdate(u, now: now, newId: () => _newId('compaction'));
        if (r == null) {
          _drop('compaction_update without compactionId', u.json, now);
          return;
        }
        if (r.created) _place(r.entry, now);
      case SessionUpdateKind.compactionSummaryChunk:
        final r = compactions.applyChunk(u, now: now, newId: () => _newId('compaction'));
        if (r == null) {
          _drop('compaction_summary_chunk without compactionId', u.json, now);
          return;
        }
        if (r.created) _place(r.entry, now);
      case SessionUpdateKind.availableCommandsUpdate:
        commands = u.availableCommands; // 全量替换
      case SessionUpdateKind.currentModeUpdate:
        currentModeId = u.currentModeId;
      case SessionUpdateKind.configOptionUpdate:
        // 全量替换；未识别的 type 整条忽略（规范）。未知 category 保留，由 UI 扁平兜底。
        configOptions = <ConfigOptionWire>[
          for (final o in u.configOptions)
            if (o.type == 'select' || o.type == 'boolean') o,
        ];
      case SessionUpdateKind.sessionInfoUpdate:
        if (u.hasTitle) title = u.title; // null = 清空
        if (u.hasUpdatedAt) updatedAt = u.updatedAt;
      case SessionUpdateKind.usageUpdate:
        usage = UsageState.fromUpdate(u);
      case SessionUpdateKind.unknown:
        return;
    }
    seen[kind.wire] = (seen[kind.wire] ?? 0) + 1;
    _changed();
  }

  void _drop(String reason, JsonMap raw, DateTime now) {
    dropped.add(DroppedUpdate(reason: reason, raw: raw, at: now));
    _changed();
  }

  /// 条目要摆进哪个列表：顶层，或父工具调用的 children。
  List<TranscriptEntry> _containerFor(String? parentToolCallId) {
    if (parentToolCallId == null) return entries;
    return toolCalls[parentToolCallId]?.children ?? entries;
  }

  /// 嵌套条目的父卡还没到：凭空建一张（§ 7 第 4 条的同一口径），等 tool_call 到了补标题。
  void _ensureParent(String? parentToolCallId, DateTime now) {
    if (parentToolCallId == null || toolCalls.contains(parentToolCallId)) return;
    final r = toolCalls.apply(
      ToolCallWire(<String, dynamic>{'toolCallId': parentToolCallId}),
      isUpdate: true,
      now: now,
      newId: () => _newId('tool'),
    );
    final parent = r.entry;
    if (parent != null) {
      parent.isSubagent = true;
      _place(parent, now);
    }
  }

  void _place(TranscriptEntry e, DateTime now) {
    final list = _containerFor(e.parentToolCallId);
    _closeOpenThought(list);
    list.add(e);
  }

  void _closeOpenThought(List<TranscriptEntry> list) {
    if (list.isEmpty) return;
    final last = list.last;
    if (last is ThoughtEntry && !last.closed) last.closed = true;
  }

  static bool _sameMessage(String? a, String? b) {
    if (a == null && b == null) return true; // 都没有 messageId：按角色连续合并
    return a != null && b != null && a == b; // 有 id：id 相同才是同一条
  }

  void _appendMessage(MessageRole role, SessionUpdateWire u, JsonMap? meta, DateTime now) {
    final content = u.content;
    if (content == null) return;
    final parent = InboundMetaKeys.parentToolCallIdOf(meta);
    _ensureParent(parent, now);
    final list = _containerFor(parent);
    final last = list.isEmpty ? null : list.last;
    if (last is MessageEntry && last.role == role && _sameMessage(last.messageId, u.messageId)) {
      last.blocks.add(content);
      last.updatedAt = now;
      return;
    }
    final entry = MessageEntry(id: _newId('msg'), at: now, role: role, messageId: u.messageId, parentToolCallId: parent);
    entry.blocks.add(content);
    _place(entry, now);
  }

  void _appendThought(SessionUpdateWire u, JsonMap? meta, DateTime now) {
    final content = u.content;
    if (content == null) return;
    final parent = InboundMetaKeys.parentToolCallIdOf(meta);
    _ensureParent(parent, now);
    final list = _containerFor(parent);
    final last = list.isEmpty ? null : list.last;
    if (last is ThoughtEntry && !last.closed) {
      last.blocks.add(content);
      last.updatedAt = now;
      return;
    }
    final entry = ThoughtEntry(id: _newId('thought'), at: now, parentToolCallId: parent);
    entry.blocks.add(content);
    list.add(entry);
  }

  // ---------------------------------------------------------------- 轮边界（§ 7 第 7 条）

  /// `session/prompt` 发出：开一轮（也是画板 10 的检查点）。
  TurnEntry startTurn(List<ContentBlockWire> prompt) {
    final now = this.now;
    _closeOpenThought(entries);
    turnCount++;
    final t = TurnEntry(id: _newId('turn'), at: now, n: turnCount, prompt: List<ContentBlockWire>.unmodifiable(prompt));
    currentTurn = t;
    entries.add(t);
    _changed();
    return t;
  }

  /// `session/prompt` 返回：`stopReason` 五种之一，`usage` 是回合级用量（可空）。
  void endTurn({String? stopReason, JsonMap? usage}) {
    final now = this.now;
    _closeOpenThought(entries);
    for (final e in entries) {
      if (e is ToolCallEntry) _closeOpenThought(e.children);
    }
    final t = currentTurn;
    if (t != null) {
      t
        ..stopReason = stopReason
        ..usage = usage == null ? null : TurnUsage.fromJson(usage)
        ..endedAt = now;
    }
    currentTurn = null;
    _changed();
  }

  /// 发出 `session/cancel` 后的本地处理（§ 7 第 1 条 + § 3.1）。
  CancelResult cancel() {
    final now = this.now;
    final tools = toolCalls.cancelUnfinished(now);
    final requests = pending.cancelSession(sessionId, now: now);
    final elicitations = pending.cancelSessionElicitations(sessionId, now: now);
    _changed();
    return CancelResult(toolCallIds: tools, cancelledRequestIds: requests, cancelledElicitationIds: elicitations);
  }

  /// Restore Checkpoint（画板 10）：本地截断该轮及其后全部投影块，返回被截断的轮（其 prompt 用于同会话重发）与
  /// 截断范围内仍挂起的请求：permission 标 cancelled（回 `PendingQueue.cancelledOutcome`）、elicitation 标 cancelled
  /// （回 `PendingQueue.cancelledAction`）——接线侧必须拿这些 id 去 `acp_respond`，否则 agent 挂起（审查 high）。
  /// 协议没有回滚，agent 侧上下文不回退（所有者裁定 2026-09-15，已知限制）。
  RestoreResult? restoreTo(String turnEntryId) {
    final idx = entries.indexWhere((e) => e.id == turnEntryId && e is TurnEntry);
    if (idx < 0) return null;
    final now = this.now;
    final turn = entries[idx] as TurnEntry;
    final removed = entries.sublist(idx);
    entries.removeRange(idx, entries.length);
    final permissions = <String>[];
    final elicitations = <String>[];
    for (final e in removed) {
      _forget(e);
      _collectPending(e, permissions, elicitations);
    }
    for (final id in <String>[...permissions, ...elicitations]) {
      pending.cancelRequest(id, now: now);
    }
    turnCount = turn.n - 1;
    currentTurn = null;
    _changed();
    return RestoreResult(turn: turn, cancelledRequestIds: permissions, cancelledElicitationIds: elicitations);
  }

  void _collectPending(TranscriptEntry e, List<String> permissions, List<String> elicitations) {
    switch (e) {
      case final PermissionEntry p when p.status == PendingStatus.pending:
        permissions.add(p.requestId);
      case final ElicitationEntry el when el.status == PendingStatus.pending:
        elicitations.add(el.requestId);
      case final ToolCallEntry tc:
        for (final c in tc.children) {
          _collectPending(c, permissions, elicitations);
        }
      default:
        break;
    }
  }

  void _forget(TranscriptEntry e) {
    switch (e) {
      case final ToolCallEntry tc:
        for (final c in tc.children) {
          _forget(c);
        }
        toolCalls.remove(tc.toolCallId);
      case final PlanCardEntry p:
        plans.remove(p.planId);
      case final CompactionEntry c:
        compactions.remove(c.compactionId);
      default:
        break;
    }
  }

  // ---------------------------------------------------------------- agent → client 请求

  /// `acp/client_request`（requestId 非 null）：permission / elicitation 入队；sessionScope 的也进转录。
  TranscriptEntry? applyClientRequest(ClientRequestEnvelope env) {
    final now = this.now;
    if (env.requestId == null) {
      applyClientNotification(env);
      return null;
    }
    if (env.isPermission) {
      final e = pending.addPermission(env, now: now, newId: () => _newId('permission'));
      _place(e, now);
      _changed();
      return e;
    }
    if (env.isElicitation) {
      final e = pending.addElicitation(env, now: now, newId: () => _newId('elicitation'));
      if (!e.isRequestScope) _place(e, now); // requestScope 落认证页（画板 52），不进转录
      _changed();
      return e;
    }
    return null;
  }

  /// `acp/client_request` 里 requestId 为 null 的通知：`elicitation/complete` 与 `$/cancel_request`。
  void applyClientNotification(ClientRequestEnvelope env) {
    final now = this.now;
    switch (env.method) {
      case 'elicitation/complete':
        final id = env.params['elicitationId'];
        if (id is String) pending.completeElicitation(id, now: now);
      case r'$/cancel_request':
        final id = env.params['requestId'];
        if (id != null) pending.withdraw(id.toString(), now: now);
      default:
        return;
    }
    _changed();
  }

  JsonMap? answerPermission(String requestId, String optionId) {
    final r = pending.answerPermission(requestId, optionId, now: now);
    if (r != null) _changed();
    return r;
  }

  JsonMap? answerElicitation(String requestId, String action, {JsonMap? content}) {
    final r = pending.answerElicitation(requestId, action, content: content, now: now);
    if (r != null) _changed();
    return r;
  }

  /// `session/new` 的返回：modes 与初始 configOptions。
  void applyNewSession(JsonMap result) {
    modes = result['modes'] is Map ? (result['modes'] as Map).cast<String, dynamic>() : null;
    currentModeId = modes?['currentModeId'] as String?;
    _setConfigOptions(result['configOptions']);
    _changed();
  }

  /// `session/load` / `session/resume` 的返回（R6）：形状是 `{modes?, configOptions?}`，与 `session/new` 少一个 sessionId。
  /// 与 `session/new` 的差别是**缺省不清空**：`ResumeSessionResponse` 经常是空对象（两个字段都可选），
  /// 那时候不能把 `session/load` 刚重放出来的 modes / configOptions 抹掉。
  void applyLoadSession(JsonMap result) {
    if (result['modes'] is Map) {
      modes = (result['modes'] as Map).cast<String, dynamic>();
      currentModeId = modes?['currentModeId'] as String?;
    }
    _setConfigOptions(result['configOptions']);
    _changed();
  }

  /// `session/load` 的重放之前把转录与派生态清空（R6）：agent 会把整段历史重新发一遍，
  /// 不清就会和内存里已有的那份叠起来。会话身份（sessionId / agentId / cwd）与本地索引里的标题不动。
  /// **不发通知**：清空与随后的重放要在 UI 上是一步（接线侧把它排在挂起的 batcher 队列里，一起刷）。
  void resetForReplay() {
    entries.clear();
    toolCalls.clear();
    plans.clear();
    compactions.clear();
    pending.forgetSession(sessionId);
    terminals.clear();
    dropped.clear();
    seen.clear();
    usage = null;
    currentTurn = null;
    turnCount = 0;
    _seq = 0;
  }

  /// `session/set_mode` 成功后的本地同步（R6 modes 回退路径）：SetSessionModeResponse 是空的，
  /// 规范里客户端发起的切换成功即生效（agent 自己改模式才发 `current_mode_update`）。
  void applyModeSelected(String modeId) {
    currentModeId = modeId;
    _changed();
  }

  /// `session/set_config_option` 的响应（`{configOptions}`，全量替换）。与 `config_option_update` 同一口径。
  void applyConfigOptionsResponse(JsonMap result) {
    _setConfigOptions(result['configOptions']);
    _changed();
  }

  /// modes 回退（R6，ROUNDS § 3）：只发 `current_mode_update` / 只在 `session/new` 里给 `modes`、不发 configOptions 的 agent，
  /// 模式下拉用这里合成的一条 select；`configOptions` 里已经在管这批值时返回 null（ROUNDS § 3「两者都有只用 configOptions」）：
  /// 既包括有 `category == mode` 的条目，也包括**同一批值换个 category 发一遍**的 ——
  /// pi-acp 把思考强度同时发在 `modes` 与 `category == thought_level` 的 configOption 里，
  /// 再合成一条就是两个一模一样的「Thinking: high」下拉（所有者手测 2026-09-17）。
  /// 判据不看 agent 也不看 category（规则 2 不做 agent 特判）：可选值集合一样就是同一个选择。
  /// `id` 是本地哨兵，**不会发给 agent**——选中走 `session/set_mode`（见 lib/app/workbench_controller.dart）。
  static const String modeFallbackId = 'acp.modes';

  ConfigOptionWire? get modeFallbackOption {
    if (configOptions.any((o) => o.category == 'mode')) return null;
    final available = modes?['availableModes'];
    if (available is! List || available.isEmpty) return null;
    final modeIds = <String>{
      for (final m in available)
        if (m is Map && m['id'] is String) m['id'] as String,
    };
    // 严格按「值集合完全相同」判，超集不算：那可能真是另一个更大的选择。
    if (modeIds.isNotEmpty &&
        configOptions.any((o) {
          if (o.type != 'select') return false;
          final values = _selectValues(o);
          return values.length == modeIds.length && values.containsAll(modeIds);
        })) {
      return null;
    }
    return ConfigOptionWire(<String, dynamic>{
      'id': modeFallbackId,
      'name': 'Mode',
      'category': 'mode',
      'type': 'select',
      'currentValue': currentModeId,
      'options': <JsonMap>[
        for (final m in available)
          if (m is Map)
            <String, dynamic>{
              'value': m['id'],
              'name': m['name'] ?? m['id'],
              if (m['description'] != null) 'description': m['description'],
            },
      ],
    });
  }

  /// 一条 select 的可选值集合（扁平或 `{group, name, options}` 两种形状都收），给上面的去重判据用。
  static Set<String> _selectValues(ConfigOptionWire option) {
    final values = <String>{};
    void collect(List<Object?> raw) {
      for (final o in raw) {
        if (o is! Map) continue;
        if (o['value'] is String) values.add(o['value'] as String);
        final nested = o['options'];
        if (nested is List) collect(nested);
      }
    }

    collect(option.options);
    return values;
  }

  void _setConfigOptions(Object? opts) {
    if (opts is! List) return;
    // 与 config_option_update 同一口径：未识别的 type 整条忽略（审查 P2）。
    configOptions = <ConfigOptionWire>[
      for (final o in opts)
        if (o is Map && (o['type'] == 'select' || o['type'] == 'boolean')) ConfigOptionWire(o.cast<String, dynamic>()),
    ];
  }

  void dismissPlan(String planId) {
    if (plans.dismiss(planId)) _changed();
  }

  // ---------------------------------------------------------------- 终端输出（§ 4 / § 7 第 5 条）

  /// `tool_call` / `tool_call_update` 的 `_meta.terminal_info / terminal_output / terminal_exit`（docs/design.md § 4 入站识别键，R4）。
  void _applyTerminalMeta(JsonMap? meta) {
    for (final ev in TerminalMetaEvent.parse(meta)) {
      final buffer = terminals.ensure(ev.terminalId);
      switch (ev.kind) {
        case TerminalMetaKind.info:
          if (ev.cwd != null) buffer.cwd = ev.cwd;
        case TerminalMetaKind.output:
          buffer.append(ev.data ?? '');
        case TerminalMetaKind.exit:
          buffer.exit(code: ev.exitCode, sig: ev.signal);
      }
    }
  }

  void applyTerminalText(String terminalId, String text) {
    terminals.ensure(terminalId).append(text);
    _changed();
  }

  void applyTerminalExit(String terminalId, {int? exitCode, String? signal}) {
    terminals.ensure(terminalId).exit(code: exitCode, sig: signal);
    _changed();
  }

  void markTerminalReleased(String terminalId) {
    terminals.ensure(terminalId).markReleased();
    _changed();
  }

  void markTerminalKilled(String terminalId) {
    terminals.ensure(terminalId).markKilled();
    _changed();
  }

  // ---------------------------------------------------------------- 快照（测试：分批 vs 整批）

  JsonMap debugSnapshot() => <String, dynamic>{
        'sessionId': sessionId,
        'title': title,
        'updatedAt': updatedAt,
        'turnCount': turnCount,
        'running': isRunning,
        'currentModeId': currentModeId,
        'commands': <String?>[for (final c in commands) c.name],
        'configOptions': <JsonMap>[for (final o in configOptions) o.json],
        'usage': usage?.toJson(),
        'seen': Map<String, int>.of(seen),
        'dropped': <String>[for (final d in dropped) d.reason],
        'entries': <JsonMap>[for (final e in entries) _entryJson(e)],
        'pending': pending.debugSnapshot(),
        'terminals': <String, dynamic>{
          for (final t in terminals.all)
            t.terminalId: <String, dynamic>{
              'output': t.output,
              'truncated': t.truncated,
              'exitCode': t.exitCode,
              'released': t.released,
            },
        },
      };

  static String _iso(DateTime? d) => d?.toIso8601String() ?? '';

  JsonMap _entryJson(TranscriptEntry e) => switch (e) {
        final MessageEntry m => <String, dynamic>{
            't': 'message',
            'id': m.id,
            'at': _iso(m.at),
            'updatedAt': _iso(m.updatedAt),
            'role': m.role.name,
            'messageId': m.messageId,
            'parent': m.parentToolCallId,
            'blocks': <JsonMap>[for (final b in m.blocks) b.json],
          },
        final ThoughtEntry th => <String, dynamic>{
            't': 'thought',
            'id': th.id,
            'at': _iso(th.at),
            'updatedAt': _iso(th.updatedAt),
            'closed': th.closed,
            'parent': th.parentToolCallId,
            'blocks': <JsonMap>[for (final b in th.blocks) b.json],
          },
        final ToolCallEntry tc => <String, dynamic>{
            't': 'tool_call',
            'id': tc.id,
            'at': _iso(tc.at),
            'updatedAt': _iso(tc.updatedAt),
            'finishedAt': _iso(tc.finishedAt),
            'toolCallId': tc.toolCallId,
            'title': tc.title,
            'name': tc.name,
            'kind': tc.kind.wire,
            'rawKind': tc.rawKind,
            'status': tc.status.wire,
            'display': tc.displayStatus.name,
            'content': <JsonMap>[for (final c in tc.content) c.json],
            'skipped': tc.skippedContent,
            'locations': <JsonMap>[for (final l in tc.locations) l.json],
            'rawInput': tc.rawInput,
            'rawOutput': tc.rawOutput,
            'meta': tc.meta,
            'createdFromUpdate': tc.createdFromUpdate,
            'cancelledLocally': tc.cancelledLocally,
            'parent': tc.parentToolCallId,
            'isSubagent': tc.isSubagent,
            'children': <JsonMap>[for (final c in tc.children) _entryJson(c)],
          },
        final PlanCardEntry p => <String, dynamic>{
            't': 'plan',
            'id': p.id,
            'at': _iso(p.at),
            'planId': p.planId,
            'stable': p.isStable,
            'type': p.type.name,
            'items': <JsonMap>[
              for (final i in p.items) <String, dynamic>{'content': i.content, 'priority': i.priority.name, 'status': i.status.name},
            ],
            'uri': p.uri,
            'markdown': p.markdown,
            'removed': p.removed,
            'dismissed': p.dismissed,
          },
        final CompactionEntry c => <String, dynamic>{
            't': 'compaction',
            'id': c.id,
            'at': _iso(c.at),
            'compactionId': c.compactionId,
            'status': c.status,
            'summary': c.summary == null ? null : <JsonMap>[for (final b in c.summary!) b.json],
            'chunks': <JsonMap>[for (final b in c.chunks) b.json],
            'error': c.error,
          },
        final PermissionEntry p => <String, dynamic>{'t': 'permission', 'id': p.id, 'at': _iso(p.at), 'requestId': p.requestId},
        final ElicitationEntry el => <String, dynamic>{'t': 'elicitation', 'id': el.id, 'at': _iso(el.at), 'requestId': el.requestId},
        final TurnEntry t => <String, dynamic>{
            't': 'turn',
            'id': t.id,
            'at': _iso(t.at),
            'endedAt': _iso(t.endedAt),
            'n': t.n,
            'prompt': <JsonMap>[for (final b in t.prompt) b.json],
            'stopReason': t.stopReason,
            'usage': t.usage?.toJson(),
          },
        _ => <String, dynamic>{'t': 'unknown', 'id': e.id},
      };
}

/// 多会话表 + 跨会话共享的队列 / 终端 / agent 状态。`acp/*` 事件的信封在这里拆。
class Sessions extends ChangeNotifier {
  Sessions({Clock? clock}) : _clock = clock ?? DateTime.now;

  final Clock _clock;
  final PendingQueue pending = PendingQueue();
  final TerminalStore terminals = TerminalStore();
  final AgentStateStore agents = AgentStateStore();
  final Map<String, SessionStore> _byId = <String, SessionStore>{};

  int _requestScopeSeq = 0;

  DateTime get now => _clock();
  Iterable<SessionStore> get all => _byId.values;
  SessionStore? maybe(String sessionId) => _byId[sessionId];

  /// 忘掉一个会话（R6）：`session/delete` 成功后、或 `session/load` 失败要把刚建的空壳收回时用。
  /// 队列里属于它的挂起项一并清掉（agent 已经不会再等回应了）。
  void forget(String sessionId) {
    final s = _byId.remove(sessionId);
    if (s == null) return;
    s.removeListener(notifyListeners);
    pending.forgetSession(sessionId);
    // 不 dispose：在途的那一轮（`session/prompt` 还没返回）还握着这个 store，回来时会调 `endTurn()`；
    // 对 dispose 过的 ChangeNotifier 再 notify 会 assert。摘掉监听就够了，没有别的资源要释放。
    notifyListeners();
  }

  SessionStore session(String sessionId, {String? agentId}) {
    final s = _byId.putIfAbsent(sessionId, () {
      final store = SessionStore(sessionId: sessionId, agentId: agentId, pending: pending, terminals: terminals, clock: _clock);
      store.addListener(notifyListeners);
      return store;
    });
    if (agentId != null && s.agentId == null) s.agentId = agentId;
    return s;
  }

  /// `acp/session_update`：`{agentId, sessionId, update}`，update 是 SessionNotification 原样 JSON。
  void applySessionUpdateEnvelope(JsonMap payload) {
    final env = SessionUpdateEnvelope(payload);
    final n = env.notification;
    final sid = env.sessionId ?? n.sessionId;
    if (sid == null) return;
    session(sid, agentId: env.agentId).applyNotification(n);
  }

  /// `acp/client_request`：`{agentId, requestId, method, params}`；requestId null 的是通知。
  void applyClientRequestEnvelope(JsonMap payload) {
    final env = ClientRequestEnvelope(payload);
    final sid = env.isPermission ? env.permission.sessionId : (env.isElicitation ? env.elicitation.sessionId : null);
    if (env.requestId == null) {
      // 通知：按 elicitationId / requestId 找到队列项，不依赖会话；所属会话的 SessionStore 也要通知，转录卡才会刷新（审查 P2）。
      final now = _clock();
      TranscriptEntry? touched;
      switch (env.method) {
        case 'elicitation/complete':
          final id = env.params['elicitationId'];
          if (id is String) touched = pending.completeElicitation(id, now: now);
        case r'$/cancel_request':
          final id = env.params['requestId'];
          if (id != null) {
            touched = pending.byRequestId(id.toString());
            pending.withdraw(id.toString(), now: now);
          }
        default:
          return;
      }
      final owner = switch (touched) {
        final PermissionEntry p => p.sessionId,
        final ElicitationEntry el => el.sessionId,
        _ => null,
      };
      if (owner != null) _byId[owner]?._changed();
      notifyListeners();
      return;
    }
    if (sid != null) {
      session(sid, agentId: env.agentId).applyClientRequest(env);
      return;
    }
    // requestScope（无会话）：只进队列。
    if (env.isElicitation) {
      pending.addElicitation(env, now: _clock(), newId: () => 'elicitation_rs_${++_requestScopeSeq}');
      notifyListeners();
    }
  }

  /// `acp/agent_state` payload 原样。
  void applyAgentState(JsonMap payload) => agents.apply(payload);

  /// `acp/terminal_output`：`{terminalId, source, bytes(base64)}` 或 `{terminalId, source, exitStatus}`。
  void applyTerminalOutputEvent(JsonMap payload, {required String Function(String base64) decode}) {
    final id = payload['terminalId'];
    if (id is! String) return;
    final exit = payload['exitStatus'];
    if (exit is Map) {
      final code = exit['exitCode'];
      terminals.ensure(id).exit(code: code is num ? code.toInt() : null, sig: exit['signal'] as String?);
    } else {
      final b64 = payload['bytes'];
      if (b64 is String) terminals.ensure(id).append(decode(b64));
    }
    notifyListeners();
  }

  /// 按帧合并：把一批事件的应用包在一次通知里。
  void batch(void Function() body) {
    final stores = List<SessionStore>.of(_byId.values);
    for (final s in stores) {
      s.beginBatch();
    }
    try {
      body();
    } finally {
      for (final s in stores) {
        s.endBatch();
      }
    }
  }

  JsonMap debugSnapshot() => <String, dynamic>{
        'sessions': <String, dynamic>{for (final s in _byId.values) s.sessionId: s.debugSnapshot()},
        'requestScope': <String>[for (final e in pending.requestScope) e.requestId],
        'agents': agents.debugSnapshot(),
      };
}
