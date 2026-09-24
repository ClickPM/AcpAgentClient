// 待处理队列（docs/design.md § 3「前端状态规则」）：permission 与 elicitation 按 sessionId 索引，另有一个无会话的
// requestScope 队列（认证阶段的 elicitation，落画板 52 而不是转录）。
// 硬要求（docs/acp-projection.md § 3.1）：发出 session/cancel 后挂起的权限请求 MUST 以 cancelled 回应。
// `$/cancel_request`（agent 撤回）与 `elicitation/complete`（URL 收尾）以 requestId null 的通知到达（design.md § 3）。
// 纯 Dart。
//
// **键是 (agentId, requestId)**（iteration-12，BACKLOG P0「请求与会话路由」第 1 条）：`requestId` 是每条连接自己的
// JSON-RPC id、从小整数起步，两个 agent 同时挂着请求时撞号的机会不低；只按裸 requestId 当键的话，
// 在一边点「允许」会命中另一边的卡。同一个 agent 重连之后 id 又从头数，所以删键时还要认条目本身（见 [forgetSession]）。

import 'package:flutter/foundation.dart';

import 'entries.dart';
import 'wire.dart';

class PendingQueue extends ChangeNotifier {
  final Map<(String, String), TranscriptEntry> _byKey = <(String, String), TranscriptEntry>{};
  final List<TranscriptEntry> _order = <TranscriptEntry>[];

  /// 仍在等用户的项（先到先出）。
  List<TranscriptEntry> get pending => <TranscriptEntry>[
        for (final e in _order)
          if (_isPending(e)) e,
      ];

  List<TranscriptEntry> forSession(String sessionId) => <TranscriptEntry>[
        for (final e in pending)
          if (_sessionOf(e) == sessionId) e,
      ];

  /// 每条会话仍在等用户的**最早那一项**（sessionId → 项，先到先出与 [forSession] 同序）。
  /// 画板 09 的「等你处理」：侧栏标记取它的种类、切换器徽标按它的键数会话。requestScope 的不在里面。
  Map<String, TranscriptEntry> firstBySession() {
    final out = <String, TranscriptEntry>{};
    for (final e in pending) {
      final sid = _sessionOf(e);
      if (sid == null || sid.isEmpty) continue;
      out.putIfAbsent(sid, () => e);
    }
    return out;
  }

  /// requestScope（无会话）的 elicitation。
  List<ElicitationEntry> get requestScope => <ElicitationEntry>[
        for (final e in pending)
          if (e is ElicitationEntry && e.isRequestScope) e,
      ];

  /// [agentId] 是发出这条请求的 agent（信封里的 `agentId`）；同一个 requestId 在别的 agent 名下的条目不算。
  TranscriptEntry? byRequestId(String? agentId, String requestId) => _byKey[_key(agentId, requestId)];

  PermissionEntry addPermission(ClientRequestEnvelope env, {required DateTime now, required String Function() newId}) {
    final p = env.permission;
    final entry = PermissionEntry(
      id: newId(),
      at: now,
      requestId: _reqId(env.requestId),
      agentId: env.agentId,
      sessionId: p.sessionId ?? '',
      toolCallPatch: p.toolCall,
      options: p.options,
    );
    _add(entry, now);
    return entry;
  }

  ElicitationEntry addElicitation(ClientRequestEnvelope env, {required DateTime now, required String Function() newId}) {
    final entry = ElicitationEntry(
      id: newId(),
      at: now,
      requestId: _reqId(env.requestId),
      agentId: env.agentId,
      wire: env.elicitation,
    );
    _add(entry, now);
    return entry;
  }

  /// 回应权限请求；返回 `acp_respond` 的 result 载荷（`{outcome: {outcome: selected, optionId}}`）。
  JsonMap? answerPermission(String? agentId, String requestId, String optionId, {required DateTime now}) {
    final e = byRequestId(agentId, requestId);
    if (e is! PermissionEntry || e.status != PendingStatus.pending) return null;
    e
      ..status = PendingStatus.answered
      ..chosenOptionId = optionId
      ..answeredAt = now;
    notifyListeners();
    return <String, dynamic>{
      'outcome': <String, dynamic>{'outcome': 'selected', 'optionId': optionId},
    };
  }

  /// 回应 elicitation：action ∈ accept / decline / cancel；accept 时带 content。
  JsonMap? answerElicitation(String? agentId, String requestId, String action, {JsonMap? content, required DateTime now}) {
    final e = byRequestId(agentId, requestId);
    if (e is! ElicitationEntry || e.status != PendingStatus.pending) return null;
    e
      ..status = PendingStatus.answered
      ..action = action
      ..values = content
      ..answeredAt = now;
    notifyListeners();
    return action == 'accept'
        ? <String, dynamic>{'action': 'accept', 'content': content ?? <String, dynamic>{}}
        : <String, dynamic>{'action': action};
  }

  /// url 模式：本地记「已打开浏览器」（画板 28 第二态）。
  void markOpened(String? agentId, String requestId) {
    final e = byRequestId(agentId, requestId);
    if (e is ElicitationEntry) {
      e.opened = true;
      notifyListeners();
    }
  }

  /// § 3.1：cancel 后该会话所有挂起的权限请求回 cancelled。返回要回应的 requestId（载荷 `{outcome: {outcome: cancelled}}`）。
  List<String> cancelSession(String sessionId, {required DateTime now}) {
    final ids = <String>[];
    for (final e in _order) {
      if (e is PermissionEntry && e.status == PendingStatus.pending && e.sessionId == sessionId) {
        e
          ..status = PendingStatus.cancelled
          ..answeredAt = now;
        ids.add(e.requestId);
      }
    }
    if (ids.isNotEmpty) notifyListeners();
    return ids;
  }

  /// 同上，但管的是 elicitation（载荷 [cancelledAction]）。核心侧的 `session/cancel` 只自动回权限请求，
  /// elicitation 不回就一直挂在 agent 那边（审查 finding high，2026-09-15）。
  List<String> cancelSessionElicitations(String sessionId, {required DateTime now}) {
    final ids = <String>[];
    for (final e in _order) {
      if (e is ElicitationEntry && e.status == PendingStatus.pending && e.sessionId == sessionId) {
        e
          ..status = PendingStatus.cancelled
          ..answeredAt = now;
        ids.add(e.requestId);
      }
    }
    if (ids.isNotEmpty) notifyListeners();
    return ids;
  }

  static const JsonMap cancelledOutcome = <String, dynamic>{
    'outcome': <String, dynamic>{'outcome': 'cancelled'},
  };

  /// elicitation 的取消回应载荷。
  static const JsonMap cancelledAction = <String, dynamic>{'action': 'cancel'};

  /// 把一条请求标成 cancelled。挂起的（Restore Checkpoint 截断时用）要回应：permission 回 [cancelledOutcome]、
  /// elicitation 回 [cancelledAction]；已 accept 的 URL elicitation 也可本地标 cancelled（画板 28 已打开后的 Cancel，
  /// 照 Zed `cancel_accepted_url_elicitations`）——这种没有第二个响应可发，调用方按调用前的 status 区分。
  bool cancelRequest(String? agentId, String requestId, {required DateTime now}) {
    final e = byRequestId(agentId, requestId);
    if (e is PermissionEntry && e.status == PendingStatus.pending) {
      e
        ..status = PendingStatus.cancelled
        ..answeredAt = now;
    } else if (e is ElicitationEntry &&
        (e.status == PendingStatus.pending || (e.isUrl && e.status == PendingStatus.answered && e.action == 'accept'))) {
      e
        ..status = PendingStatus.cancelled
        ..action = 'cancel'
        ..answeredAt = now;
    } else {
      return false;
    }
    notifyListeners();
    return true;
  }

  /// `$/cancel_request`：agent 撤回了自己的请求（[agentId] 是发通知的那个，别的 agent 同号的卡不动）。
  bool withdraw(String? agentId, String requestId, {required DateTime now}) {
    final e = byRequestId(agentId, requestId);
    if (e == null) return false;
    if (e is PermissionEntry && e.status == PendingStatus.pending) {
      e
        ..status = PendingStatus.withdrawn
        ..answeredAt = now;
    } else if (e is ElicitationEntry && e.status == PendingStatus.pending) {
      e
        ..status = PendingStatus.withdrawn
        ..answeredAt = now;
    } else {
      return false;
    }
    notifyListeners();
    return true;
  }

  /// agent 进程退出 / 连接断开（`acp/agent_state: exited`）：核心那边的挂起表在 `Shared::finish` 里已经清空，
  /// 这些请求再也回不去了。挂起项一律标 [PendingStatus.withdrawn]（口径与 `$/cancel_request` 同：agent 不再等这条），
  /// 卡片跟着从「等你选」变成已收尾——不标的话按钮还能点，点下去只会撞核心的 unknown_request
  /// （审查 finding，2026-09-22）。**不发 `acp_respond`**：连接已经没了。
  /// 返回受影响的项所属 sessionId（调用方通知对应的 SessionStore 重画；requestScope 的是空串）。
  List<String> withdrawAgent(String agentId, {required DateTime now}) {
    final sessions = <String>[];
    for (final e in _order) {
      if (!_isPending(e) || _agentOf(e) != agentId) continue;
      switch (e) {
        case final PermissionEntry p:
          p
            ..status = PendingStatus.withdrawn
            ..answeredAt = now;
        case final ElicitationEntry el:
          el
            ..status = PendingStatus.withdrawn
            ..answeredAt = now;
        default:
          continue;
      }
      sessions.add(_sessionOf(e) ?? '');
    }
    if (sessions.isNotEmpty) notifyListeners();
    return sessions;
  }

  /// `elicitation/complete`：URL elicitation 由 agent 收尾（已回应过的也标 completed，画板 28 第三态）。
  /// 只认 [agentId] 名下的、从最新的往前找：elicitationId 是 agent 自己起的，别的 agent、或同一个 agent
  /// 重连前的那一代可能用过同一个值（与 requestId 同一类撞号，iteration-12）。
  ElicitationEntry? completeElicitation(String? agentId, String elicitationId, {required DateTime now}) {
    for (final e in _order.reversed) {
      if (e is ElicitationEntry && e.wire.elicitationId == elicitationId && (e.agentId ?? '') == (agentId ?? '')) {
        e
          ..status = PendingStatus.completed
          ..answeredAt = now;
        notifyListeners();
        return e;
      }
    }
    return null;
  }

  /// `session/load` 重放前清空这个会话的队列项（R6）：它们属于重放之前那一份转录，
  /// agent 已经不会再等我们的回应（`session/load` 之前要么断开过、要么 agent 自己把旧回合收了）。
  /// requestScope 的（无 sessionId，认证页）不动。返回被移除的 requestId。
  List<String> forgetSession(String sessionId) {
    final removed = <TranscriptEntry>[
      for (final e in _order)
        if (_sessionOf(e) == sessionId) e,
    ];
    if (removed.isEmpty) return const <String>[];
    _order.removeWhere((e) => _sessionOf(e) == sessionId);
    for (final e in removed) {
      // 键此刻指向的可能已经是别的条目：同一个 agent 重连后新一代的请求从同一个 id 数起，把这个键占过去了。
      // 那时只按键删会把新卡从表里摘掉，它就成了点不动的死按钮（iteration-12）。
      final key = _key(_agentOf(e), _requestIdOf(e));
      if (identical(_byKey[key], e)) _byKey.remove(key);
    }
    notifyListeners();
    return <String>[for (final e in removed) _requestIdOf(e)];
  }

  static String _requestIdOf(TranscriptEntry e) => switch (e) {
        final PermissionEntry p => p.requestId,
        final ElicitationEntry el => el.requestId,
        _ => '',
      };

  void _add(TranscriptEntry e, DateTime now) {
    final key = _key(_agentOf(e), _requestIdOf(e));
    // 同一个键又来一条：核心那边按连接记的挂起表同样是按这个 id 覆盖的，旧那条的回应通道已经没了。
    // 还挂着就标 withdrawn，卡片收尾成不可点，而不是留一个点下去撞 unknown_request 的按钮。
    switch (_byKey[key]) {
      case final PermissionEntry p when p.status == PendingStatus.pending:
        p
          ..status = PendingStatus.withdrawn
          ..answeredAt = now;
      case final ElicitationEntry el when el.status == PendingStatus.pending:
        el
          ..status = PendingStatus.withdrawn
          ..answeredAt = now;
      default:
        break;
    }
    _byKey[key] = e;
    _order.add(e);
    notifyListeners();
  }

  static bool _isPending(TranscriptEntry e) => switch (e) {
        final PermissionEntry p => p.status == PendingStatus.pending,
        final ElicitationEntry el => el.status == PendingStatus.pending,
        _ => false,
      };

  static String? _sessionOf(TranscriptEntry e) => switch (e) {
        final PermissionEntry p => p.sessionId,
        final ElicitationEntry el => el.sessionId,
        _ => null,
      };

  static String? _agentOf(TranscriptEntry e) => switch (e) {
        final PermissionEntry p => p.agentId,
        final ElicitationEntry el => el.agentId,
        _ => null,
      };

  /// requestId：核心把它归一化成字符串（design.md § 3），数字 id 也按 Display 形状转。
  static String _reqId(Object? id) => id == null ? '' : id.toString();

  /// 队列键：(agentId, requestId)。核心发来的信封总带 agentId；缺省按空串算，只和同样缺省的条目相认。
  static (String, String) _key(String? agentId, String requestId) => (agentId ?? '', requestId);

  List<JsonMap> debugSnapshot() => <JsonMap>[
        for (final e in _order)
          switch (e) {
            final PermissionEntry p => <String, dynamic>{
                'kind': 'permission',
                'requestId': p.requestId,
                'sessionId': p.sessionId,
                'toolCallId': p.toolCallId,
                'status': p.status.name,
                'chosen': p.chosenOptionId,
                'options': p.options.length,
              },
            final ElicitationEntry el => <String, dynamic>{
                'kind': 'elicitation',
                'requestId': el.requestId,
                'mode': el.wire.mode,
                'sessionId': el.sessionId,
                'scopeRequestId': el.wire.requestId,
                'status': el.status.name,
                'action': el.action,
                'values': el.values,
              },
            _ => <String, dynamic>{'kind': 'unknown'},
          },
      ];
}
