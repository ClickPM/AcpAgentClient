// 认证页（画板 52，R5）的整个状态机（R7.5 从 workbench_controller.dart 拆出）：右栏 Agents 标签里、对应 agent 的一页。
// 三个入口（`session/new` 回 `-32000`、画板 51 的登录键、画板 34 的登录键）都到 [open]；requestScope 的 URL elicitation
// 落在本页（docs/design.md § 5 第 5 条）。认证成功后的「自动重试新会话」是会话控制器的事，经 [onAuthenticated] 交回去；
// 右栏标签、当前项目目录、registry 展示名、当前 agent 都经回调向组合根要。

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../projection/agent_state.dart';
import '../projection/entries.dart';
import '../projection/session_store.dart';
import '../projection/tool_calls.dart';
import '../projection/wire.dart';
import '../ui/registry/auth_page.dart';
import 'core_bridge.dart';
import 'guarded.dart';

class AuthState extends ChangeNotifier with GuardedNotifier {
  AuthState({
    required this.bridge,
    required this.sessions,
    required this._cwd,
    required this._connect,
    required this._registryName,
    required this._currentAgentId,
    required this._openAgentsTab,
    required this._ensureAgentsTab,
    required this._showWorkbench,
    required this._onAuthenticated,
  });

  final CoreCommands? bridge;

  /// 投影层：agent 状态表（authMethods / `initialize` 落地）、requestScope 队列、终端缓冲。
  final Sessions sessions;

  /// 当前项目目录（自动重试新会话的 cwd 缺省从它来）。
  final String? Function() _cwd;

  /// 连 agent（`agent_connect` + 落 `initialize`）：经会话控制器连，连接换了一代它要记账
  /// （iteration-09：不然这个 agent 名下内存里的会话还当自己挂着，发出去撞 `-32602 unknown session`）。
  final Future<void> Function(String agent, String? cwd) _connect;

  /// registry.json 里的展示名（没连上时会话头 / 认证页的标题退到它）。
  final String? Function(String id) _registryName;

  /// 当前会话的 agent（画板 34 状态条的登录键从它进）。
  final String? Function() _currentAgentId;

  /// 右栏切到 Agents 标签（认证页就在那一页上）。
  final void Function() _openAgentsTab;

  /// 右栏当前不是 Agents 标签时才切过去（elicitation 到达那一路：正开着终端标签时不抢）。
  final void Function() _ensureAgentsTab;

  /// 认证成功后回到工作台页（只换页，不通知；本页随后的 `touch` 会带上）。
  final void Function() _showWorkbench;

  /// 认证成功：`session` 非空时（terminal 型认证由核心顺手开好的会话）会话控制器直接采用它；
  /// 否则在这个 cwd 上开一条新会话（docs/design.md § 5 第 5 条的自动重试）。
  final Future<void> Function(String agent, String cwd, JsonMap? session) _onAuthenticated;

  String? agentId;
  AuthPhase phase = AuthPhase.choose;
  String? methodId;
  String? error;
  String? terminalLabel;
  String? _retryCwd;

  /// 认证页的「代际」：[open] / [close] 各加一；在途的 [start] 每个 await 之后核对，页已收起或重开就不再改状态
  /// （审查第 2 轮 P2：否则旧的失败会画到新页上、旧的成功会把新页清掉并切走工作台）。
  int _generation = 0;

  /// 无会话阶段的 URL elicitation（挂起 / 已打开 / 已完成都留在页上，直到离开认证页）。
  final List<ElicitationEntry> elicitations = <ElicitationEntry>[];

  AgentConnection? get connection => agentId == null ? null : sessions.agents[agentId!];

  List<JsonMap> get methods => connection?.authMethods ?? const <JsonMap>[];

  String get agentName {
    final c = connection;
    final id = agentId ?? '';
    return c?.agentTitle ?? c?.agentName ?? _registryName(id) ?? id;
  }

  /// terminal 型认证的可见终端：核心的 `authenticating` 事件带 terminalId。
  String? get terminalId => connection?.authenticatingTerminalId;

  TerminalBuffer? get terminalBuffer {
    final id = terminalId;
    return id == null || terminalLabel == null ? null : sessions.terminals.ensure(id);
  }

  /// 进认证页：三个入口（`-32000`、画板 51 的登录键、画板 34 的登录键）都到这里。没连上的先 `initialize`（authMethods 从它来）。
  Future<void> open(String agent, {String? retryCwd, String? methodId}) async {
    agentId = agent;
    phase = AuthPhase.choose;
    error = null;
    terminalLabel = null;
    _retryCwd = retryCwd ?? _cwd();
    _generation++;
    _cancelElicitations();
    _openAgentsTab();
    final b = bridge;
    // 「没连上的」这句判据原先只看 `authMethods.isEmpty`：已经连上、且 `initialize` 里本来就没有 authMethods 的
    // agent 从画板 51 / 34 的登录键进来会白白重连一次，把它上面正在跑的会话全杀掉（与 `newSession` 同一个坑）。
    // 重连也换不出新的 authMethods（它就是从 `initialize` 来的），所以连上了就不重连。
    if (b != null && methods.isEmpty && sessions.agents[agent]?.state != AgentLifecycle.initialized) {
      await guard(() => _connect(agent, _retryCwd));
    }
    this.methodId = methodId ?? methods.firstOrNull?['id'] as String?;
    touch();
  }

  void selectMethod(String id) {
    methodId = id;
    touch();
  }

  /// 开始认证：agent 型调 `authenticate`（URL elicitation 会经 requestScope 落到本页）；terminal 型在 pty 里重拉同一个 agent，
  /// 核心等它退出后自动重试 `session/new`。成功后回到刚才的新会话，失败留在失败态（可重试、可换方式）。
  Future<void> start() async {
    final b = bridge;
    final agent = agentId;
    final id = methodId ?? methods.firstOrNull?['id'] as String?;
    if (b == null || agent == null || id == null) return;
    final method = methods.where((m) => m['id'] == id).firstOrNull ?? const <String, dynamic>{};
    final cwd = _retryCwd ?? _cwd();
    final generation = _generation;
    bool stale() => generation != _generation;
    phase = AuthPhase.running;
    error = null;
    touch();
    try {
      if (AuthPage.methodType(method) == 'terminal') {
        if (cwd == null) throw StateError('先选一个项目目录，terminal auth 在它里面跑');
        terminalLabel = method['name'] as String? ?? id;
        touch();
        final result = await b.terminalAuthRun(agent, id, cwd);
        if (stale()) return;
        phase = AuthPhase.succeeded;
        touch();
        final session = result['session'];
        if (session is Map) {
          await _onAuthenticated(agent, cwd, session.cast<String, dynamic>());
        } else {
          await _onAuthenticated(agent, cwd, null);
        }
      } else {
        await b.authenticate(agent, id);
        if (stale()) return;
        phase = AuthPhase.succeeded;
        touch();
        if (cwd != null) await _onAuthenticated(agent, cwd, null);
      }
      if (stale()) return;
      close();
      _showWorkbench();
    } on CoreCommandError catch (e) {
      if (stale()) return;
      phase = AuthPhase.failed;
      error = '${e.message} (${e.code})';
    } catch (e) {
      if (stale()) return;
      phase = AuthPhase.failed;
      error = e.toString();
    }
    touch();
  }

  /// 失败态的「重试」：同一方法再来一次。
  Future<void> retry() => start();

  /// 失败态的「换一种方式」：回到选方法。
  void changeMethod() {
    phase = AuthPhase.choose;
    error = null;
    terminalLabel = null;
    touch();
  }

  /// 取消：terminal 在跑的先关掉（核心等到退出后照常重试 `session/new`，失败会以 failed 收尾）；回 registry 列表。
  Future<void> cancel() async {
    final b = bridge;
    final terminal = terminalId;
    if (b != null && terminal != null && phase == AuthPhase.running) {
      await guard(() => b.terminalClose(terminal));
    }
    close();
  }

  void close() {
    _generation++;
    agentId = null;
    phase = AuthPhase.choose;
    methodId = null;
    error = null;
    terminalLabel = null;
    _retryCwd = null;
    _cancelElicitations();
    touch();
  }

  /// 卸载了 agent：开着它的认证页就收起。
  void closeIfAgent(String id) {
    if (agentId == id) close();
  }

  /// 认证页收起 / 重开前：还挂着的 requestScope elicitation 逐条回 `cancel`。不回响应，agent 那边在途的 `authenticate`
  /// 会永远等这条 JSON-RPC 回应（审查 finding high，2026-09-16）；已 accept 的（浏览器已打开）没有第二个响应可发，只从页上拿掉。
  void _cancelElicitations() {
    for (final e in List<ElicitationEntry>.of(elicitations)) {
      if (e.status == PendingStatus.pending) unawaited(cancelElicitation(e));
    }
    elicitations.clear();
  }

  Future<void> stopTerminal() async {
    final b = bridge;
    final terminal = terminalId;
    if (b == null || terminal == null) return;
    await guard(() => b.terminalClose(terminal));
  }

  Future<void> terminalInput(String data) async {
    final b = bridge;
    final terminal = terminalId;
    if (b == null || terminal == null) return;
    await guard(() => b.terminalWrite(terminal, data));
  }

  /// requestScope 的 elicitation 到达：落认证页（没开的话打开对应 agent 的一页），不落转录（docs/design.md § 5 第 5 条）。
  /// 组合根把它挂在 `sessions.pending` 上。
  void onPendingChanged() {
    final pending = sessions.pending.requestScope;
    if (pending.isEmpty) return;
    var added = false;
    for (final e in pending) {
      if (elicitations.any((x) => x.requestId == e.requestId)) continue;
      elicitations.add(e);
      added = true;
    }
    if (!added) return;
    final agent = pending.first.agentId;
    if (agentId == null && agent != null) {
      agentId = agent;
      phase = AuthPhase.running;
      methodId ??= methods.firstOrNull?['id'] as String?;
      _retryCwd ??= _cwd();
    }
    _ensureAgentsTab();
    touch();
  }

  /// 「Open in browser」：回 `accept`（挂起的）并记已打开；返回要打开的 URL（打开本身由组合根的 `url_launcher` 做）。
  Future<String?> acceptUrl(ElicitationEntry e) async {
    final b = bridge;
    final agent = e.agentId ?? agentId;
    if (e.status == PendingStatus.pending && b != null && agent != null) {
      final payload = sessions.pending.answerElicitation(e.requestId, 'accept', now: sessions.now);
      if (payload != null) await guard(() => b.acpRespond(agent, e.requestId, payload));
    }
    sessions.pending.markOpened(e.requestId);
    touch();
    return e.wire.url;
  }

  /// 已打开后的 Cancel：挂起的回 `cancel`；已 accept 的只本地标 cancelled（没有第二个响应可发）。
  Future<void> cancelElicitation(ElicitationEntry e) async {
    final b = bridge;
    final agent = e.agentId ?? agentId;
    if (e.status == PendingStatus.pending && b != null && agent != null) {
      final payload = sessions.pending.answerElicitation(e.requestId, 'cancel', now: sessions.now);
      if (payload != null) await guard(() => b.acpRespond(agent, e.requestId, payload));
    } else {
      sessions.pending.cancelRequest(e.requestId, now: sessions.now);
    }
    touch();
  }

  /// 画板 34 状态条的登录键：进认证页（画板 52），方法预选。
  Future<void> authenticate(String methodId) async {
    final id = _currentAgentId();
    if (id == null) return;
    await open(id, retryCwd: _cwd(), methodId: methodId);
  }
}
