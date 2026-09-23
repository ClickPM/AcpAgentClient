// 会话挂载（iteration-07，BACKLOG P0「会话身份与生命周期」）：ACP 里一条会话只属于创建或载入它的那条 agent 连接。
// 连接换了（重载 agent、进程崩溃后重连、认证页重连），内存里那些会话的 sessionId 在新进程里就不存在了，
// 直接发消息撞 `-32602 unknown session`。这里记两件事：每个 agent 的连接换过几代、哪些会话挂空了；
// 连同挂回（`session/load` / `session/resume`）与关闭态——关掉也是「不挂在连接上」的一种。
//
// 以前一直拿「内存里有没有转录（`store`）」代替这件事，两头都错：载不回转录的会话被当成「还没有会话」，
// 发消息另开一条把它静默顶掉；换过进程的会话被当成「还活着」，直接发出去。
//
// **缺省是挂着的**：内存里有转录、又不在挂空集合里的会话，就是挂在当前这一代连接上——`session/new` 与载入成功
// 之后本来就是这样；`session/update` 顺带建出来的 store、测试与 fixtures 直接建的 store 也按这个口径。
//
// 会话控制器混入它（从 session_controller.dart 拆出，lib/app 行数门）；它要的会话控制器状态与动作列在下面的抽象成员里。

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../projection/agent_state.dart';
import '../projection/batcher.dart';
import '../projection/session_store.dart';
import '../projection/wire.dart';
import 'core_bridge.dart';
import 'guarded.dart';
import 'workspace_state.dart';

/// 一条会话相对于它 agent 当前那条连接的状态（一轮对话的 `send` 按它分流）。
enum SessionAttach {
  /// 还没有会话（画板 01 状态 1）：第一条消息现开一条。
  none,

  /// 挂在活着的连接上：直接发。
  attached,

  /// 没挂上，但可能挂回来（声明了 `loadSession` 或 `resume`，或本次还没连过、能力未知）：先挂回再发。
  detached,

  /// 能力已知且挂不回来（既没有 `loadSession` 也没有 `resume`，或 `session/list` 校对出 agent 侧已经没有这条）：
  /// 发送只能照 R3 新开一条。
  unattachable,
}

mixin SessionAttachment on ChangeNotifier, GuardedNotifier {
  // ---------------------------------------------------------------- 会话控制器提供

  CoreCommands? get bridge;
  Sessions get sessions;
  UpdateBatcher get batcher;
  WorkspaceState get workspace;
  String? get sessionId;
  bool get waitingForAgent;
  set waitingForAgent(bool value);
  int get sessionEpoch;
  set sessionEpoch(int value);

  /// `session/list` 校对出来的「agent 侧已经没有了」的会话。
  Set<String> get missingOnAgent;

  /// 本地登记的这条会话的 agent（索引里记的、新建 / 载入时记的），没登记回 null。
  @protected
  String? registeredOwner(String sessionId);
  @protected
  void registerOwner(String sessionId, String agent);

  /// 登记的 agent，退到当前连接的；都没有回空串。
  @protected
  String ownerOf(String sessionId);

  /// 这条会话的 cwd：本地索引里登记的，退到内存里那份转录的。
  @protected
  String? cwdOf(String sessionId);

  @protected
  JsonMap? capsOf(String? agent);
  @protected
  JsonMap sessionCapsOf(String? agent);
  bool canLoadSessionOf(String? agent);

  /// 已经连着就不动它；没连上 / 进程没了才 `agent_connect`（连接换代在那里记 [connectionReplaced]）。
  @protected
  Future<void> ensureConnected(String agent, String cwd);

  /// 连 agent 失败的共用出口：原因写进 `lastError`，认证页 / 缺 Node 的去处安排好。
  @protected
  Future<void> onConnectError(CoreCommandError e, String agent, String cwd);

  // ---------------------------------------------------------------- 账本

  /// 每个 agent 的连接换过几代（`agent_connect` 成功一次加一）。
  final Map<String, int> _generation = <String, int>{};

  /// 内存里有转录、但没挂在它 agent 当前那条连接上的会话。
  final Set<String> _detached = <String>{};

  /// 关过的会话（`session/close`）：再点开要重新挂回，不能拿内存里那份当还活着。
  final Set<String> _closedSessions = <String>{};

  /// 每条会话被 `session/close` 的次数：`session/load` 用它判断「我在途时有没有人把它关了」。
  final Map<String, int> _closeEpoch = <String, int>{};

  /// 正在 `session/load` 的会话（同一条不并发）：值是那一次的结果，挂回时等它而不是另发一次。
  final Map<String, Future<bool>> _loadsInFlight = <String, Future<bool>>{};

  @protected
  int generationOf(String agent) => _generation[agent] ?? 0;

  /// 换上了一条新连接：这个 agent 名下内存里的会话全部挂空，切过去（[ensureLoaded]）或再发（[reattach]）时自动挂回。
  @protected
  void connectionReplaced(String agent) {
    _generation[agent] = generationOf(agent) + 1;
    for (final s in sessions.all) {
      if ((s.agentId ?? registeredOwner(s.sessionId)) == agent) _detached.add(s.sessionId);
    }
  }

  /// 挂上了。只认发起时那一代：期间连接又换过的话，它挂的是那条旧连接，仍算挂空。
  void _attached(String id, String agent, int generation) {
    if (generationOf(agent) == generation) _detached.remove(id);
  }

  /// `session/new`（含认证页顺手开的）开在当前这条连接上：同 id 的旧会话（fake-agent 不带 `--sessions` 时
  /// 总回同一个 id）留下的挂空标记作废。
  @protected
  void attachedNew(String id) => _detached.remove(id);

  /// ≡ 菜单 Resume 成功（发起时是第 [generation] 代）。
  @protected
  void markResumed(String id, String agent, int generation) {
    _closedSessions.remove(id);
    _attached(id, agent, generation);
  }

  /// ≡ 菜单 Close 成功：本地转录留着只读。
  @protected
  void markClosed(String id) {
    _closeEpoch[id] = (_closeEpoch[id] ?? 0) + 1;
    _closedSessions.add(id);
  }

  /// 会话删掉了：挂载相关的记录一并清掉。
  @protected
  void forgetAttachment(String id) {
    _closedSessions.remove(id);
    _closeEpoch.remove(id);
    _detached.remove(id);
  }

  bool get sessionClosed => sessionId != null && _closedSessions.contains(sessionId);

  // ---------------------------------------------------------------- 四态

  /// 一条会话相对于它 agent 当前那条连接的状态。关掉的（`session/close`）与进程已经没了（`exited`、还没重连）的
  /// 都不算挂着。
  SessionAttach attachOf(String? id) {
    if (id == null) return SessionAttach.none;
    final owner = ownerOf(id);
    final gone = sessions.agents[owner]?.state == AgentLifecycle.exited;
    if (sessions.maybe(id) != null && !_detached.contains(id) && !_closedSessions.contains(id) && !gone) {
      return SessionAttach.attached;
    }
    if (missingOnAgent.contains(id)) return SessionAttach.unattachable;
    // 能力未知（本次还没连过）按「可能挂回来」算：连上之后再判，不在未知时猜。
    final known = capsOf(owner) != null;
    return !known || canLoadSessionOf(owner) || sessionCapsOf(owner).containsKey('resume')
        ? SessionAttach.detached
        : SessionAttach.unattachable;
  }

  // ---------------------------------------------------------------- 挂回

  /// 侧栏点到一条没挂在连接上的会话：连上它的 agent 再挂回来（[_attach]）。内存里没有转录的、关过的、
  /// 连接换过一代的（重载 / 崩溃之后）都走这里。挂不回（没有 load 也没有 resume）就什么都不做：
  /// 转录空着或留着只读，发送时按 R3 新开一条。
  @protected
  Future<void> ensureLoaded(String id) async {
    final b = bridge;
    final owner = registeredOwner(id);
    if (b == null || owner == null || owner.isEmpty) return;
    // 同一条正在载入（连点两下，或点完马上发）：等那一次的结果，不另发一次。
    final inFlight = _loadsInFlight[id];
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final state = attachOf(id);
    if (state == SessionAttach.attached) return;
    final cwd = cwdOf(id) ?? workspace.project?.path;
    if (cwd == null) return;
    if (missingOnAgent.contains(id)) {
      lastError = '$id 在 agent 侧已经不存在了，载不回历史';
      touch();
      return;
    }
    if (state == SessionAttach.unattachable) return;
    try {
      await ensureConnected(owner, cwd);
    } on CoreCommandError catch (e) {
      await onConnectError(e, owner, cwd);
      touch();
      return;
    } catch (e) {
      lastError = describeError(e);
      touch();
      return;
    }
    await guard(() => _attach(b, owner, id, cwd));
    touch();
  }

  /// 把一条会话挂到 [owner] 当前这条连接上：声明了 `loadSession` 就 `session/load`（重放）；没有但有 `resume`
  /// 就 `session/resume`（agent 侧把上下文挂回来，转录只有内存里这份，不重放，规范如此）。挂上返回 true。
  Future<bool> _attach(CoreCommands b, String owner, String id, String cwd) async {
    if (canLoadSessionOf(owner)) return loadSession(owner, id, cwd);
    if (!sessionCapsOf(owner).containsKey('resume')) return false;
    _detached.add(id);
    final generation = generationOf(owner);
    await b.sessionResume(owner, id, cwd);
    sessions.session(id, agentId: owner).cwd = cwd;
    markResumed(id, owner, generation);
    return true;
  }

  /// 发送前把当前会话挂回它 agent 当前那条连接：连上（进程没了就重拉）→ load / resume。
  /// 返回挂回之后的状态：attached 可以发；unattachable 是连上之后才知道挂不回（按 R3 新开一条）；
  /// detached 是挂回失败，原因在 `lastError`。等待期（画板 05 B 组）与新建会话同一套：时长不可预知的整块替换。
  Future<SessionAttach> reattach() async {
    final id = sessionId;
    if (id == null) return SessionAttach.none;
    lastError = null;
    final wasWaiting = waitingForAgent;
    waitingForAgent = true;
    touch();
    try {
      await ensureLoaded(id);
    } finally {
      waitingForAgent = wasWaiting;
      touch();
    }
    final after = attachOf(id);
    // 载回来的转录整块换过：补一次入场触发（画板 05 阶段 ③，与重载 agent 载回原会话同一处理）。
    if (after == SessionAttach.attached && canLoadSessionOf(ownerOf(id))) sessionEpoch++;
    if (after == SessionAttach.detached) lastError ??= '这条会话没能重新挂到 agent 上';
    return after;
  }

  /// 挂回失败时承接这一轮的转录（一轮对话 `send` 用）：内存里没有就建一份，挂空标记留着——
  /// 下次点开或再发时照常挂回，载入成功就被整段重放换掉。
  SessionStore? detachedStore() {
    final id = sessionId;
    if (id == null) return null;
    final owner = ownerOf(id);
    final s = sessions.session(id, agentId: owner.isEmpty ? null : owner);
    s.cwd ??= cwdOf(id) ?? workspace.project?.path;
    _detached.add(id);
    return s;
  }

  // ---------------------------------------------------------------- 载入

  /// `session/load`（R6）：整段历史由 agent 用 `session/update` 重放，**重放期间不逐条刷新 UI**——
  /// 事件照常入队，但 batcher 挂起到命令返回后一次性刷完。成功返回 true。
  Future<bool> loadSession(String agent, String id, String cwd) {
    final b = bridge;
    // 同一条会话不并发 load：连点两下（或重载 agent 撞上侧栏点击）会重放两遍。
    if (b == null || _loadsInFlight.containsKey(id)) return Future<bool>.value(false);
    final load = _load(b, agent, id, cwd);
    _loadsInFlight[id] = load;
    return load.whenComplete(() {
      _loadsInFlight.remove(id);
    });
  }

  Future<bool> _load(CoreCommands b, String agent, String id, String cwd) async {
    final fresh = sessions.maybe(id) == null;
    final s = sessions.session(id, agentId: agent)..cwd = cwd;
    registerOwner(id, agent);
    _detached.add(id);
    final generation = generationOf(agent);
    final closeEpoch = _closeEpoch[id] ?? 0;
    // 失败时这次重放整段作废（BACKLOG P0「载会话中途失败会留半份转录」）：清空与重放都挂在 batcher 里，
    // 这些闭包到 release 才跑，而那时候成败已经知道了。失败就不清空、并把夹在中间的重放丢掉——原先有转录的
    // 原样留着（关掉 / 重载 / 崩溃之后重点开的唯一一份就在这儿，审查 finding high），原先没有的把空壳收回。
    // 以前分「一条都没重放 / 重放到一半」两种处理，后一种会留下半份转录。
    var failed = false;
    // hold 与 release 必须严格配对：中间任何一步抛出都得 release，否则 UI 从此不再刷新。
    batcher.hold();
    try {
      // 清空排进同一条挂起队列：清空与重放在 UI 上是一步，中间不会闪一下空转录。
      batcher.enqueue(() {
        if (failed) {
          sessions.discardUpdates(id);
        } else {
          s.resetForReplay();
        }
      });
      final result = await b.sessionLoad(agent, id, cwd);
      batcher.enqueue(() => s.applyLoadSession(result));
      // 这中间要是有人把它 close 了，别把「已关闭」标记抹掉（审查 finding P2：load 与 close 并发）。
      if ((_closeEpoch[id] ?? 0) == closeEpoch) _closedSessions.remove(id);
      _attached(id, agent, generation);
      return true;
    } catch (e) {
      failed = true;
      lastError = describeError(e);
      debugPrint('[workbench] session/load $id: ${describeError(e)}');
      batcher.enqueue(() {
        sessions.acceptUpdates(id);
        if (fresh) sessions.forget(id);
      });
      return false;
    } finally {
      batcher.release();
    }
  }
}
