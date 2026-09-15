// fixtures 回放器：把 test/fixtures/*.jsonl 的线上行喂进 Sessions（Dart 单测与 gallery 共用；R6 的 session/load 重放同形）。
// 行格式见 test/fixtures/README.md。规则：
//   out session/prompt   → 该会话开一轮（TurnEntry），记 id 以便配对响应
//   out session/cancel   → 本地取消（工具卡 cancelled + 挂起权限 cancelled）
//   in  session/update   → 投影
//   in  request_permission / elicitation/create（带 id）→ 入队；autoAnswer 时按 awaits 自动回应
//   in  result           → 配对 out 请求：session/prompt → 轮结束；initialize → agent 状态；session/new → modes / configOptions
//   out result           → 配对 in 请求：terminal/create → 终端缓冲建立（outputByteLimit）
//   in  terminal/release / kill → 终端标记
//   local terminal_output / terminal_exit → 终端缓冲；stderr → agent 的 stderr 行
// 纯 Dart。

import 'entries.dart';
import 'fixture_line.dart';
import 'session_store.dart';
import 'wire.dart';

class _Call {
  const _Call(this.method, this.params, {this.outbound = true});

  final String method;
  final JsonMap? params;

  /// true = 客户端发出的请求（响应在 in 行）；false = agent 发出的请求（响应在 out 行）。
  final bool outbound;
}

class FixtureReplayer {
  FixtureReplayer(this.sessions, {this.agentId = 'fixture-agent', this.autoAnswer = false});

  final Sessions sessions;
  final String agentId;

  /// true：权限请求自动选第一个 allow_* 选项，elicitation 自动 accept（空 content）；false：留在队列（画板 25 / 26 / 27 / 28）。
  final bool autoAnswer;

  final Map<String, _Call> _calls = <String, _Call>{};

  /// 每行喂入前按行的 `delay`（毫秒）回调；gallery 用它推进假时钟，让思考耗时 / 轮耗时按 fixtures 的节奏走。
  void Function(int ms)? onDelay;

  /// 最近一次 prompt 所属的会话（local / stderr 行没有 sessionId 时用）。
  String? lastSessionId;
  String? _newSessionCwd;
  int fed = 0;

  void feedAll(Iterable<FixtureLine> lines) {
    for (final l in lines) {
      feed(l);
    }
  }

  void feed(FixtureLine line) {
    fed++;
    onDelay?.call(line.delayMs);
    switch (line.dir) {
      case FixtureDir.out:
        _out(line);
      case FixtureDir.inbound:
        _in(line);
      case FixtureDir.local:
        _local(line);
      case FixtureDir.stderr:
        final text = line.line;
        if (text != null) sessions.agents.appendStderr(agentId, text);
      case FixtureDir.unknown:
        return;
    }
  }

  void _out(FixtureLine line) {
    final method = line.method;
    final params = line.params;
    if (method != null) {
      final id = line.id;
      if (id != null) _calls[id.toString()] = _Call(method, params);
      switch (method) {
        case 'session/prompt':
          final sid = params?['sessionId'];
          if (sid is String) {
            lastSessionId = sid;
            final blocks = params?['prompt'];
            sessions.session(sid, agentId: agentId).startTurn(<ContentBlockWire>[
              if (blocks is List)
                for (final b in blocks)
                  if (b is Map) ContentBlockWire(b.cast<String, dynamic>()),
            ]);
          }
        case 'session/cancel':
          final sid = params?['sessionId'];
          if (sid is String) sessions.session(sid, agentId: agentId).cancel();
        case 'session/new':
          _newSessionCwd = params?['cwd'] as String?;
        default:
          break;
      }
      return;
    }
    // out 响应：配对 agent 发出的请求。
    final result = line.result;
    final id = line.id;
    if (result == null || id == null) return;
    final key = id.toString();
    final call = _calls.remove(key);
    if (call == null) return;
    switch (call.method) {
      case 'terminal/create':
        final tid = result['terminalId'];
        if (tid is String) {
          final limit = call.params?['outputByteLimit'];
          sessions.terminals.ensure(tid, limit: limit is num ? limit.toInt() : null);
        }
      case 'session/request_permission':
        // fixtures 里记录的用户回应：selected → 选项；cancelled → 已由 cancel 处理（队列里可能已是 cancelled）。
        final outcome = result['outcome'];
        if (outcome is Map && outcome['outcome'] == 'selected') {
          final optionId = outcome['optionId'];
          final sid = call.params?['sessionId'];
          if (optionId is String && sid is String) {
            sessions.session(sid, agentId: agentId).answerPermission(key, optionId);
          }
        }
      case 'elicitation/create':
        final action = result['action'];
        if (action is String) {
          final content = result['content'];
          final sid = call.params?['sessionId'];
          final values = content is Map ? content.cast<String, dynamic>() : null;
          if (sid is String) {
            sessions.session(sid, agentId: agentId).answerElicitation(key, action, content: values);
          } else {
            sessions.pending.answerElicitation(key, action, content: values, now: sessions.now);
          }
        }
      default:
        break;
    }
  }

  void _in(FixtureLine line) {
    final method = line.method;
    if (method != null) {
      final id = line.id;
      final params = line.params ?? const <String, dynamic>{};
      switch (method) {
        case 'session/update':
          final sid = params['sessionId'];
          if (sid is String) lastSessionId = sid;
          sessions.applySessionUpdateEnvelope(<String, dynamic>{'agentId': agentId, 'sessionId': sid, 'update': params});
        case 'session/request_permission':
        case 'elicitation/create':
          sessions.applyClientRequestEnvelope(<String, dynamic>{
            'agentId': agentId,
            'requestId': id?.toString(),
            'method': method,
            'params': params,
          });
          if (autoAnswer && id != null) _autoAnswer(method, id.toString(), params);
        case 'elicitation/complete':
        case r'$/cancel_request':
          sessions.applyClientRequestEnvelope(<String, dynamic>{'agentId': agentId, 'requestId': null, 'method': method, 'params': params});
        case 'terminal/release':
          final tid = params['terminalId'];
          if (tid is String) sessions.terminals.ensure(tid).markReleased();
        case 'terminal/kill':
          final tid = params['terminalId'];
          if (tid is String) sessions.terminals.ensure(tid).markKilled();
        default:
          break;
      }
      if (id != null) _calls[id.toString()] = _Call(method, params, outbound: false);
      return;
    }
    final result = line.result;
    final id = line.id;
    if (id == null) return;
    final call = _calls.remove(id.toString());
    if (call == null || result == null) return;
    switch (call.method) {
      case 'session/prompt':
        final sid = call.params?['sessionId'];
        if (sid is String) {
          sessions.session(sid, agentId: agentId).endTurn(
                stopReason: result['stopReason'] as String?,
                usage: result['usage'] is Map ? (result['usage'] as Map).cast<String, dynamic>() : null,
              );
        }
      case 'initialize':
        sessions.agents.applyInitializeResult(agentId, result);
      case 'session/new':
        final sid = result['sessionId'];
        if (sid is String) {
          lastSessionId = sid;
          sessions.session(sid, agentId: agentId)
            ..cwd = _newSessionCwd
            ..applyNewSession(result);
        }
      default:
        break;
    }
  }

  void _local(FixtureLine line) {
    final tid = line.terminalId;
    if (tid == null) return;
    switch (line.localKind) {
      case 'terminal_output':
        final chunk = line.chunk;
        if (chunk != null) _terminalSession()?.applyTerminalText(tid, chunk);
      case 'terminal_exit':
        final es = line.exitStatus;
        final code = es?['exitCode'];
        _terminalSession()?.applyTerminalExit(tid, exitCode: code is num ? code.toInt() : null, signal: es?['signal'] as String?);
      default:
        break;
    }
  }

  SessionStore? _terminalSession() {
    final sid = lastSessionId;
    return sid == null ? null : sessions.session(sid, agentId: agentId);
  }

  void _autoAnswer(String method, String requestId, JsonMap params) {
    final entry = sessions.pending.byRequestId(requestId);
    if (entry is PermissionEntry) {
      final options = entry.options;
      PermissionOptionWire? pick;
      for (final o in options) {
        if (o.kind == 'allow_once') {
          pick = o;
          break;
        }
      }
      pick ??= options.isEmpty ? null : options.first;
      final sid = entry.sessionId;
      final optionId = pick?.optionId;
      if (optionId != null) sessions.session(sid, agentId: agentId).answerPermission(requestId, optionId);
    } else if (entry is ElicitationEntry) {
      final sid = entry.sessionId;
      if (sid != null) {
        sessions.session(sid, agentId: agentId).answerElicitation(requestId, 'accept', content: <String, dynamic>{});
      } else {
        sessions.pending.answerElicitation(requestId, 'accept', content: <String, dynamic>{}, now: sessions.now);
      }
    }
  }
}
