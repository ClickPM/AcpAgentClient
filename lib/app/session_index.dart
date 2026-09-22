// 本地会话索引 `sessions.json` 的内存镜像（R7.5 从 workbench_controller.dart 拆出）：原始条目（cwd 等字段接线要用）
// 与三条桥命令（list / upsert / remove）的接线。**不是 notifier**：谁写谁负责让侧栏重投影——每次条目变化都经
// [onChanged] 通知会话控制器（侧栏项与 sessionId → agentId 的登记都在那边从条目算出来），它自己不通知 UI。

import '../projection/entries.dart';
import '../projection/session_store.dart';
import '../projection/wire.dart';
import 'core_bridge.dart';

class SessionIndex {
  SessionIndex({required this.bridge, required this._onChanged});

  final CoreCommands? bridge;

  /// 条目变了（读回 / 写回 / 删除之后）：持有侧栏投影的一方重投影一次。
  final void Function() _onChanged;

  /// 本地索引原始条目（`sessions.json` 的投影；侧栏项只留了展示要用的字段，cwd 在这里）。
  List<JsonMap> entries = const <JsonMap>[];

  /// 每条会话最近一次发消息时打的 `updatedAt`（[upsert] 的 promptSent 那次）。[entries] 只在那条
  /// 命令**回来**之后才带上新时间，而它是不 await 的（见会话控制器的 `stampPromptSent`）；核心又是每条命令各起一个任务
  /// （`rust/bridge/src/api.rs` 的 `on_core`），不保证先发的先回——一轮跑得比索引写回来还快时，收轮那次
  /// [upsert] 从 [entries] 读到的还是发消息之前的旧时间、把刚打的盖回去（概率很低，但顺序不该靠运气）。
  /// 这里记一份本地的，[updatedAtOf] 取两者里大的（合并复审 2026-09-18）。
  final Map<String, int> _promptSentAt = <String, int>{};

  /// 在途的 upsert，按 (agentId, sessionId) 记。
  /// 桥的每条命令在核心那边**各起一个任务**（`rust/bridge/src/api.rs` 的 `on_core`），先发的不保证先做，
  /// 而发消息时那次 `stampPromptSent` 是不 await 的（见 `SessionController.stampPromptSent` 里为什么）：
  /// 用户在这几毫秒里删掉这条会话，remove 可能先落、upsert 后落，被删的那行又被写回 `sessions.json`，
  /// 侧栏多一条怎么都删不掉的幽灵条目（审查 finding，2026-09-22）。
  /// 修法是 [remove] **只等这一条会话在途的 upsert 落地**再发删除——不排队（排队会让收轮那次 `saveIndex`
  /// （是 await 的）挡在发消息那次不 await 的写后面，本来解耦的两件事又绑上了），也不立墓碑（复审 high，
  /// 2026-09-22：永不过期的墓碑会把删掉之后**再新建的同 id 会话**静默删掉——fake-agent 不带 `--sessions` 时
  /// 每次 `session/new` 都回 `sess_fake_1`，侧栏里那条新会话根本不出现、重启后彻底没有）。
  final Map<(String, String), Set<Future<void>>> _inFlight = <(String, String), Set<Future<void>>>{};

  /// 发一条 upsert 并登记在途；落地（成功或失败）即注销。
  Future<JsonMap> _upsertTracked(CoreCommands b, JsonMap entry) {
    final agentId = entry['agentId'];
    final sessionId = entry['sessionId'];
    final call = b.sessionIndexUpsert(entry);
    if (agentId is! String || sessionId is! String) return call;
    final key = (agentId, sessionId);
    final pending = _inFlight.putIfAbsent(key, () => <Future<void>>{});
    late final Future<void> done;
    done = call.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      pending.remove(done);
      if (pending.isEmpty) _inFlight.remove(key);
    });
    pending.add(done);
    return call;
  }

  Future<void> refresh() async {
    final b = bridge;
    if (b == null) return;
    final result = await b.sessionIndexList();
    apply(result['sessions']);
  }

  /// 本地索引落地：原始条目更新，再让侧栏重投影。
  void apply(Object? raw) {
    entries = <JsonMap>[
      if (raw is List)
        for (final item in raw)
          if (item is Map) item.cast<String, dynamic>(),
    ];
    _onChanged();
  }

  /// 侧栏按索引的 `updatedAt` 倒序（核心 `IndexStore::sessions`），而 `updatedAt` 的口径是**用户最后一次发消息的时间**
  /// （所有者裁定 2026-09-18）：只在 `session/prompt` 发出时打新时间（[promptSent]），收轮、改名、补标题都沿用
  /// 索引里已有的值——按收轮时间打的话，一条早发出去、晚跑完的会话会在收轮时跳到刚发过消息的那条前面。
  /// 索引里还没有这条（刚 `session/new`）时不传，核心打当前时间：新会话按创建时间排最上面。
  /// [agentFallback] / [titleFallback]：store 上没有时用的 agentId 与标题（会话控制器给当前 agent 与会话头标题）。
  Future<void> upsert(
    SessionStore s, {
    required String agentFallback,
    required String titleFallback,
    bool promptSent = false,
  }) async {
    final b = bridge;
    if (b == null) return;
    final updatedAt = promptSent ? DateTime.now().millisecondsSinceEpoch : updatedAtOf(s.sessionId);
    if (promptSent && updatedAt != null) _promptSentAt[s.sessionId] = updatedAt;
    final result = await _upsertTracked(b, <String, dynamic>{
      'agentId': s.agentId ?? agentFallback,
      'sessionId': s.sessionId,
      'title': s.title ?? titleFallback,
      'cwd': s.cwd,
      'messageCount': s.entries.whereType<MessageEntry>().length,
      'updatedAt': ?updatedAt,
    });
    apply(result['sessions']);
  }

  /// 整行替换地写一条（改名 / `session/list` 补标题）：核心的 upsert 是整行替换，调用方少给一个字段就是把它抹成默认值。
  Future<void> upsertEntry(JsonMap entry) async {
    final b = bridge;
    if (b == null) return;
    final result = await _upsertTracked(b, entry);
    apply(result['sessions']);
  }

  /// 按 (agentId, sessionId) 精确匹配删除一条。先等这条会话在途的 upsert 落地（见 [_inFlight]），再发删除：
  /// 删除总排在它们之后到核心，被删的行不会再被写回来；之后再来的 upsert（删掉再新建的同 id 会话）照常写入。
  Future<void> remove(String agentId, String sessionId) async {
    final b = bridge;
    if (b == null) return;
    final key = (agentId, sessionId);
    // 等的时候可能又有新的起来（收轮那次 saveIndex），循环到没有在途的为止。
    for (var pending = _inFlight[key]; pending != null && pending.isNotEmpty; pending = _inFlight[key]) {
      await Future.wait<void>(pending.toList(growable: false));
    }
    final result = await b.sessionIndexRemove(agentId, sessionId);
    apply(result['sessions']);
  }

  /// 本地索引（`sessions.json`）里这条会话的原始条目；没有为 null。
  JsonMap? entryOf(String sessionId) {
    for (final e in entries) {
      if (e['sessionId'] == sessionId) return e;
    }
    return null;
  }

  /// 本地索引里这条记录登记的 agentId（删 / 改索引都按 (agentId, sessionId) 匹配）。
  String? agentOf(String sessionId) {
    for (final s in entries) {
      if (s['sessionId'] == sessionId) {
        final agent = s['agentId'];
        if (agent is String) return agent;
      }
    }
    return null;
  }

  /// 本地索引里这条记录的 cwd（非空才算有）。
  String? cwdOf(String sessionId) {
    for (final s in entries) {
      if (s['sessionId'] == sessionId) {
        final cwd = s['cwd'];
        if (cwd is String && cwd.isNotEmpty) return cwd;
      }
    }
    return null;
  }

  /// 索引里这条会话的 `updatedAt`，与本地记的最近一次发消息时间（[_promptSentAt]）取大；
  /// 没有这条或还没打过时间时为 null。
  int? updatedAtOf(String sessionId) {
    var at = (entryOf(sessionId)?['updatedAt'] as num?)?.toInt() ?? 0;
    final sent = _promptSentAt[sessionId];
    if (sent != null && sent > at) at = sent;
    return at <= 0 ? null : at;
  }

  /// 本地索引（`sessions.json`）里 `updatedAt` 最大的那条会话的 agent，限于还装着的。
  String? lastUsedAgentId(Set<String> installed) {
    String? best;
    var bestAt = -1;
    for (final e in entries) {
      final id = e['agentId'];
      if (id is! String || !installed.contains(id)) continue;
      final at = (e['updatedAt'] as num?)?.toInt() ?? 0;
      if (at > bestAt) {
        bestAt = at;
        best = id;
      }
    }
    return best;
  }

  /// 删除会话时把本地记的发消息时间一并忘掉。
  void forgetPromptSent(String sessionId) => _promptSentAt.remove(sessionId);
}
