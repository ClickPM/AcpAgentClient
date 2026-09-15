// 待处理队列（docs/design.md § 3「前端状态规则」）：permission 与 elicitation 按 sessionId 索引，另有一个无会话的
// requestScope 队列（认证阶段的 elicitation，落画板 52 而不是转录）。
// 硬要求（docs/acp-projection.md § 3.1）：发出 session/cancel 后挂起的权限请求 MUST 以 cancelled 回应。
// `$/cancel_request`（agent 撤回）与 `elicitation/complete`（URL 收尾）以 requestId null 的通知到达（design.md § 3）。
// 纯 Dart。

import 'package:flutter/foundation.dart';

import 'entries.dart';
import 'wire.dart';

class PendingQueue extends ChangeNotifier {
  final Map<String, TranscriptEntry> _byRequestId = <String, TranscriptEntry>{};
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

  /// requestScope（无会话）的 elicitation。
  List<ElicitationEntry> get requestScope => <ElicitationEntry>[
        for (final e in pending)
          if (e is ElicitationEntry && e.isRequestScope) e,
      ];

  TranscriptEntry? byRequestId(String requestId) => _byRequestId[requestId];

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
    _add(entry.requestId, entry);
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
    _add(entry.requestId, entry);
    return entry;
  }

  /// 回应权限请求；返回 `acp_respond` 的 result 载荷（`{outcome: {outcome: selected, optionId}}`）。
  JsonMap? answerPermission(String requestId, String optionId, {required DateTime now}) {
    final e = _byRequestId[requestId];
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
  JsonMap? answerElicitation(String requestId, String action, {JsonMap? content, required DateTime now}) {
    final e = _byRequestId[requestId];
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
  void markOpened(String requestId) {
    final e = _byRequestId[requestId];
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

  static const JsonMap cancelledOutcome = <String, dynamic>{
    'outcome': <String, dynamic>{'outcome': 'cancelled'},
  };

  /// elicitation 的取消回应载荷。
  static const JsonMap cancelledAction = <String, dynamic>{'action': 'cancel'};

  /// 把一条请求标成 cancelled。挂起的（Restore Checkpoint 截断时用）要回应：permission 回 [cancelledOutcome]、
  /// elicitation 回 [cancelledAction]；已 accept 的 URL elicitation 也可本地标 cancelled（画板 28 已打开后的 Cancel，
  /// 照 Zed `cancel_accepted_url_elicitations`）——这种没有第二个响应可发，调用方按调用前的 status 区分。
  bool cancelRequest(String requestId, {required DateTime now}) {
    final e = _byRequestId[requestId];
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

  /// `$/cancel_request`：agent 撤回了自己的请求。
  bool withdraw(String requestId, {required DateTime now}) {
    final e = _byRequestId[requestId];
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

  /// `elicitation/complete`：URL elicitation 由 agent 收尾（已回应过的也标 completed，画板 28 第三态）。
  ElicitationEntry? completeElicitation(String elicitationId, {required DateTime now}) {
    for (final e in _order) {
      if (e is ElicitationEntry && e.wire.elicitationId == elicitationId) {
        e
          ..status = PendingStatus.completed
          ..answeredAt = now;
        notifyListeners();
        return e;
      }
    }
    return null;
  }

  void _add(String requestId, TranscriptEntry e) {
    _byRequestId[requestId] = e;
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

  /// 队列键：核心把 requestId 归一化成字符串（design.md § 3），数字 id 也按 Display 形状转。
  static String _reqId(Object? id) => id == null ? '' : id.toString();

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
