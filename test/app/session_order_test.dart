// 侧栏顺序的口径（所有者裁定 2026-09-18）：按**用户最后一次发消息的时间**倒序。
// 核心按索引的 `updatedAt` 排（rust/settings/src/index.rs 的 `IndexStore::sessions`），所以这里验的是
// 控制器往索引里写的 `updatedAt`：
// - 发消息时打成现在，且在 `session/prompt` 发出之前就写好；
// - 收轮只刷消息计数，不动时间（早发出去、晚跑完的会话不会在收轮时插队）；
// - 改名不动时间；
// - 再发一条才再打。

import 'dart:async';

import 'package:acp_agent_client/app/session_index.dart';
import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/projection/session_store.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/ui/popovers/topbar_popovers.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_core.dart';

/// `session/prompt` 可以挂住不回：验「发出去之前就打好时间、收轮不再改」要把发与收拆开。
class _GatedCore extends FakeCore {
  Completer<JsonMap>? gate;

  @override
  Future<JsonMap> sessionPrompt(String agentId, String sessionId, List<Object?> prompt) async {
    prompts.add(prompt);
    final g = gate;
    if (g != null) return g.future;
    return <String, dynamic>{'stopReason': 'end_turn'};
  }
}

/// 发消息那次索引写「落地了、但返回晚」：核心是每条命令各起一个任务（`rust/bridge/src/api.rs` 的 `on_core`），
/// 一轮跑得比索引写回来还快时，收轮那次索引写读到的本地镜像还是旧时间。
class _LaggyIndexCore extends FakeCore {
  /// 设了就把下一次 upsert 的**返回**挂在它上（写本身照常落地）。
  Completer<void>? holdNextUpsert;

  @override
  Future<JsonMap> sessionIndexUpsert(JsonMap entry) async {
    final result = await super.sessionIndexUpsert(entry);
    final hold = holdNextUpsert;
    if (hold == null) return result;
    holdNextUpsert = null;
    await hold.future;
    return sessionIndexList();
  }
}

/// 发消息那次索引写**还没落地**（不是「落地了但返回晚」，那是 _LaggyIndexCore）：
/// 核心每条命令各起一个任务，upsert 与 remove 谁先做不定，这里把 upsert 按住来固定那个最坏顺序。
class _SlowUpsertCore extends FakeCore {
  Completer<void>? delayNextUpsert;

  @override
  Future<JsonMap> sessionIndexUpsert(JsonMap entry) async {
    final delay = delayNextUpsert;
    if (delay != null) {
      delayNextUpsert = null;
      await delay.future;
    }
    return super.sessionIndexUpsert(entry);
  }
}

/// 删除命令**已经发出、还没落地**：核心里它与随后再发的 upsert 并行，删除先落、upsert 后落就是幽灵行。
/// 这里把 remove 按住，验「删除在途时同一条会话的写不发」。
class _SlowRemoveCore extends FakeCore {
  Completer<void>? delayNextRemove;
  int upserts = 0;

  @override
  Future<JsonMap> sessionIndexUpsert(JsonMap entry) {
    upserts++;
    return super.sessionIndexUpsert(entry);
  }

  @override
  Future<JsonMap> sessionIndexRemove(String agentId, String sessionId) async {
    final delay = delayNextRemove;
    if (delay != null) {
      delayNextRemove = null;
      await delay.future;
    }
    return super.sessionIndexRemove(agentId, sessionId);
  }
}

JsonMap _entryOf(FakeCore core, String sessionId) =>
    core.sessionIndex.singleWhere((e) => e['sessionId'] == sessionId);

int _updatedAtOf(FakeCore core, String sessionId) => (_entryOf(core, sessionId)['updatedAt'] as num).toInt();

Future<void> _untilPromptSent(FakeCore core) async {
  for (var i = 0; i < 100 && core.prompts.isEmpty; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(core.prompts, isNotEmpty, reason: 'session/prompt 没有发出去');
}

void main() {
  test('索引的 updatedAt 只在用户发消息时打：收轮、改名都不动它', () async {
    final core = _GatedCore();
    final c = WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask)
      ..workspace.project = const ProjectRef(path: 'D:/repo', name: 'repo');
    await c.session.newSession(const AgentRef(id: 'a', name: 'a'));
    final sid = c.session.sessionId!;
    expect(_updatedAtOf(core, sid), 0, reason: '刚建的会话控制器不传 updatedAt（核心打创建时间；假核心记 0）');

    // 发第一条：session/prompt 挂着不回，索引里已经打上发消息的时间。
    core.gate = Completer<JsonMap>();
    final before = DateTime.now().millisecondsSinceEpoch;
    c.composer.editor.text = '第一条';
    final sending = c.turn.send();
    await _untilPromptSent(core);
    final t1 = _updatedAtOf(core, sid);
    expect(t1, greaterThanOrEqualTo(before), reason: '发出去之前就该打好时间');

    // 隔一会儿再收轮：时间不该被刷成收轮时间。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    core.gate!.complete(<String, dynamic>{'stopReason': 'end_turn'});
    await sending;
    expect(_updatedAtOf(core, sid), t1, reason: '收轮只刷消息计数，不刷时间');
    expect(core.sessionIndex.single['messageCount'], 1);

    // 改名不动时间。
    c.session.startRename(sid);
    await c.session.commitRename('改了名');
    expect(core.sessionIndex.single['title'], '改了名');
    expect(_updatedAtOf(core, sid), t1, reason: '改名不是发消息');

    // 再发一条才再打。
    core.gate = null;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    c.composer.editor.text = '第二条';
    await c.turn.send();
    expect(_updatedAtOf(core, sid), greaterThan(t1));
    expect(core.sessionIndex.single['messageCount'], 2);
    c.dispose();
  });

  test('后台跑完那一轮刷的是它自己那条，不是前台选中的（BACKLOG「后台跑完的那轮，侧栏消息数不刷新」，iteration-02）', () async {
    final core = _GatedCore();
    final c = WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask)
      ..workspace.project = const ProjectRef(path: 'D:/repo', name: 'repo');
    // A：侧栏里另一条会话，索引里记着 3 条消息。
    await core.sessionIndexUpsert(<String, dynamic>{
      'agentId': 'a',
      'sessionId': 'sess_a',
      'title': 'A',
      'cwd': 'D:/repo',
      'messageCount': 3,
    });
    await c.index.refresh();

    // B：新建一条并发出去，`session/prompt` 挂着不回。
    await c.session.newSession(const AgentRef(id: 'a', name: 'a'));
    final b = c.session.sessionId!;
    expect(b, isNot('sess_a'));
    core.gate = Completer<JsonMap>();
    c.composer.editor.text = '后台这条';
    final sending = c.turn.send();
    await _untilPromptSent(core);

    // 用户切去看 A（2026-09-18 起新建会话不再重连，B 在后台照跑）。
    c.sessions.session('sess_a', agentId: 'a').cwd = 'D:/repo';
    c.session.sessionId = 'sess_a';

    core.gate!.complete(<String, dynamic>{'stopReason': 'end_turn'});
    await sending;

    expect(_entryOf(core, b)['messageCount'], 1, reason: '刷的是刚跑完那一轮的会话');
    expect(_entryOf(core, 'sess_a')['messageCount'], 3, reason: '前台那条没被动过');
    c.dispose();
  });

  test('删掉正在跑的会话：那一轮收轮时不把它写回索引（复审 high 2026-09-22 / iteration-02）', () async {
    // `deleteSession` 不发 `session/cancel`，在途那一轮照样会收；收轮那次 `saveIndex` 手里握着的是
    // 开轮时那个 store，会话表里已经没有它了（`sessions.forget`），写了就是把删掉的行写回去。
    final core = _GatedCore();
    final c = WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask)
      ..workspace.project = const ProjectRef(path: 'D:/repo', name: 'repo');
    await c.session.newSession(const AgentRef(id: 'a', name: 'a'));
    final sid = c.session.sessionId!;
    core.gate = Completer<JsonMap>();
    c.composer.editor.text = '跑着的那一轮';
    final sending = c.turn.send();
    await _untilPromptSent(core);

    await c.session.deleteSession(sid);
    expect(core.sessionIndex, isEmpty);

    core.gate!.complete(<String, dynamic>{'stopReason': 'end_turn'});
    await sending;
    expect(core.sessionIndex, isEmpty, reason: '删掉的会话不能被收轮那次写回来（侧栏幽灵条目）');
    c.dispose();
  });

  test('删掉的会话不会被在途的 upsert 写回来（审查 finding 2026-09-22）', () async {
    final core = _SlowUpsertCore();
    final index = SessionIndex(bridge: core, onChanged: () {});
    final store = SessionStore(sessionId: 'sess_1', agentId: 'a')..cwd = 'D:/repo';
    // 发消息那次 `stampPromptSent` 是不 await 的：这条 upsert 还没落地，用户就在侧栏把会话删了。
    // 核心每条命令各起一个任务、先发的不保证先做，这里按住 upsert 固定那个最坏顺序（remove 先落）。
    final hold = core.delayNextUpsert = Completer<void>();
    final stamping = index.upsert(store, agentFallback: 'a', titleFallback: '新会话', promptSent: true);
    final removing = index.remove('a', 'sess_1');
    await pumpEventQueue();
    expect(core.sessionIndex, isEmpty, reason: '删除要等在途的那笔 upsert 落地，这会儿两笔都还没到核心');

    hold.complete();
    await stamping;
    await removing;
    expect(core.sessionIndex, isEmpty, reason: '删掉的会话不能被在途的 upsert 写回来（侧栏幽灵条目）');
    expect(index.entries, isEmpty, reason: '内存镜像也不能留着那一行');
  });

  test('删掉再新建同 id 的会话：新的那条照常写进索引（复审 high 2026-09-22）', () async {
    // fake-agent 不带 `--sessions` 时每次 `session/new` 都回同一个 `sess_fake_1`：永不过期的墓碑会把
    // 删掉之后再新建的这条静默删掉，侧栏里根本不出现、重启后彻底没有。
    final core = _SlowUpsertCore();
    final index = SessionIndex(bridge: core, onChanged: () {});
    final first = SessionStore(sessionId: 'sess_fake_1', agentId: 'a')..cwd = 'D:/repo';
    final hold = core.delayNextUpsert = Completer<void>();
    final stamping = index.upsert(first, agentFallback: 'a', titleFallback: '第一条', promptSent: true);
    final removing = index.remove('a', 'sess_fake_1');
    hold.complete();
    await stamping;
    await removing;
    expect(core.sessionIndex, isEmpty);

    final second = SessionStore(sessionId: 'sess_fake_1', agentId: 'a')..cwd = 'D:/repo';
    await index.upsert(second, agentFallback: 'a', titleFallback: '第二条');
    expect(core.sessionIndex.map((e) => e['sessionId']), <String>['sess_fake_1'], reason: '删掉再新建的同 id 会话不能被静默删掉');
    expect(core.sessionIndex.single['title'], '第二条');
    expect(index.entries.map((e) => e['sessionId']), <String>['sess_fake_1']);
  });

  test('删除命令在途时这条会话再来的写不发；删除返回之后的写照常（cursor 复审 P2 2026-09-22）', () async {
    // `remove` 只等发删除之前就在途的 upsert；删除发出去之后收轮的 saveIndex 再写这条会话，与删除在核心里并行，
    // 删除先落、它后落又是幽灵行。所以删除在途期间同一条会话的写一律不发。
    final core = _SlowRemoveCore();
    final index = SessionIndex(bridge: core, onChanged: () {});
    final store = SessionStore(sessionId: 'sess_1', agentId: 'a')..cwd = 'D:/repo';
    await index.upsert(store, agentFallback: 'a', titleFallback: '会话');
    expect(core.upserts, 1);

    final hold = core.delayNextRemove = Completer<void>();
    final removing = index.remove('a', 'sess_1');
    await pumpEventQueue();
    final late = index.upsert(store, agentFallback: 'a', titleFallback: '会话', promptSent: true);
    await pumpEventQueue();
    expect(core.upserts, 1, reason: '删除在途，这笔写不能发出去');

    hold.complete();
    await removing;
    await late;
    expect(core.sessionIndex, isEmpty, reason: '删掉的行没有被写回来');
    expect(index.entries, isEmpty);

    // 删除返回之后的写（删掉再新建的同 id 会话）照常。
    await index.upsert(SessionStore(sessionId: 'sess_1', agentId: 'a')..cwd = 'D:/repo', agentFallback: 'a', titleFallback: '新的');
    expect(core.upserts, 2);
    expect(core.sessionIndex.map((e) => e['sessionId']), <String>['sess_1']);
  });

  test('删之前落地的 upsert 照常生效（删除只等同一条会话的在途写，不影响别的会话）', () async {
    final core = FakeCore();
    final index = SessionIndex(bridge: core, onChanged: () {});
    final kept = SessionStore(sessionId: 'sess_keep', agentId: 'a');
    final gone = SessionStore(sessionId: 'sess_gone', agentId: 'a');
    await index.upsert(kept, agentFallback: 'a', titleFallback: '留着');
    await index.upsert(gone, agentFallback: 'a', titleFallback: '删掉');
    await index.remove('a', 'sess_gone');
    await index.upsert(kept, agentFallback: 'a', titleFallback: '留着', promptSent: true);
    expect(core.sessionIndex.map((e) => e['sessionId']), <String>['sess_keep']);
  });

  test('发消息那次索引写还没回来、这一轮就收了：收轮不把时间盖回旧值（合并复审 2026-09-18）', () async {
    final core = _LaggyIndexCore();
    final c = WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask)
      ..workspace.project = const ProjectRef(path: 'D:/repo', name: 'repo');
    await c.session.newSession(const AgentRef(id: 'a', name: 'a'));
    final sid = c.session.sessionId!;

    final hold = core.holdNextUpsert = Completer<void>();
    final before = DateTime.now().millisecondsSinceEpoch;
    c.composer.editor.text = '一轮秒回';
    // 发消息那次 upsert 已落地但还没回来；prompt 立刻返回，收轮那次 upsert 先跑。
    await c.turn.send();
    expect(core.prompts, hasLength(1));
    expect(_updatedAtOf(core, sid), greaterThanOrEqualTo(before), reason: '收轮那次不能把发消息时打的时间盖回去');
    hold.complete();
    await Future<void>.delayed(Duration.zero);
    expect(_updatedAtOf(core, sid), greaterThanOrEqualTo(before));
    expect(core.sessionIndex.single['messageCount'], 1);
    c.dispose();
  });
}
