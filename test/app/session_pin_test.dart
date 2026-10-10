// 画板 46 · 会话索引的置顶与首条用户指令。
// 替身核心的 upsert 是合并写（与 Rust 侧「缺键即保留」同一结果）：收轮 / 再发一条不带这两个键，
// 置顶不被抹掉，首条指令也不被后一条盖掉；显式取消才清 `pinnedAt`。

import 'package:acp_agent_client/app/session_index.dart';
import 'package:acp_agent_client/projection/session_store.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_core.dart';

ContentBlockWire _text(String text) => ContentBlockWire(<String, dynamic>{'type': 'text', 'text': text});

void main() {
  test('首条指令只写一次，之后的整行替换与再发一条都不覆盖；取消置顶清掉 pinnedAt', () async {
    final core = FakeCore();
    final index = SessionIndex(bridge: core, onChanged: () {});
    final store = SessionStore(sessionId: 's1', agentId: 'agent')..cwd = 'D:/repo';
    store.startTurn(<ContentBlockWire>[_text('  first query  ')]);

    await index.upsert(store, agentFallback: 'agent', titleFallback: 'New', promptSent: true);
    expect(index.firstPromptOf('s1'), 'first query');

    await index.togglePinned('s1', agentId: 'agent');
    final pinned = index.entryOf('s1')!;
    expect(pinned['isPinned'], isTrue);
    expect(pinned['pinnedAt'], isA<int>());
    final pinnedAt = pinned['pinnedAt'];

    store.startTurn(<ContentBlockWire>[_text('second')]);
    await index.upsert(store, agentFallback: 'agent', titleFallback: 'New');
    final kept = index.entryOf('s1')!;
    expect(kept['isPinned'], isTrue, reason: '收轮那次整行不带 isPinned，不该取消置顶');
    expect(kept['pinnedAt'], pinnedAt);
    expect(index.firstPromptOf('s1'), 'first query', reason: '后一条用户指令不是首条');

    await index.togglePinned('s1', agentId: 'agent');
    final unpinned = index.entryOf('s1')!;
    expect(unpinned['isPinned'], isFalse);
    expect(unpinned['pinnedAt'], isNull);
    expect(index.firstPromptOf('s1'), 'first query');
  });

  test('载入后补记首条指令；已经记过的不再写', () async {
    final core = _CountingCore();
    final index = SessionIndex(bridge: core, onChanged: () {});
    await core.sessionIndexUpsert(<String, dynamic>{
      'agentId': 'agent',
      'sessionId': 's1',
      'title': 'old',
      'cwd': 'D:/repo',
      'messageCount': 2,
      'updatedAt': 10,
    });
    await index.refresh();
    final store = SessionStore(sessionId: 's1', agentId: 'agent');
    store.startTurn(<ContentBlockWire>[_text('from history')]);

    final before = core.upserts;
    expect(await index.rememberFirstPrompt(store), isTrue);
    expect(index.firstPromptOf('s1'), 'from history');
    expect(core.upserts, before + 1);
    expect(await index.rememberFirstPrompt(store), isFalse);
    expect(core.upserts, before + 1, reason: '已经记过就不再写索引');
  });

  test('补记首条指令不把已取消的置顶写回来，置顶也不把发送时间改小', () async {
    final core = FakeCore();
    final index = SessionIndex(bridge: core, onChanged: () {});
    final store = SessionStore(sessionId: 's1', agentId: 'agent')..cwd = 'D:/repo';
    store.startTurn(<ContentBlockWire>[_text('from history')]);
    await index.upsert(store, agentFallback: 'agent', titleFallback: 'New', promptSent: true);
    final sentAt = index.entryOf('s1')!['updatedAt'];

    await index.togglePinned('s1', agentId: 'agent');
    await index.togglePinned('s1', agentId: 'agent');
    expect(index.entryOf('s1')!['isPinned'], isFalse);

    // 模拟「补记读到的是置顶之前的旧行」：把 isPinned 塞回镜像，再补记。补记请求自己不能带这个键。
    index.entries = <JsonMap>[
      <String, dynamic>{...index.entryOf('s1')!, 'isPinned': true, 'pinnedAt': 1, 'firstPrompt': null, 'updatedAt': 100},
    ];
    expect(await index.rememberFirstPrompt(store), isTrue);
    final after = index.entryOf('s1')!;
    expect(after['isPinned'], isNot(true), reason: '补记不表达置顶');
    expect(after['pinnedAt'], isNull);
    expect(after['firstPrompt'], 'from history');
    expect(after['updatedAt'], sentAt, reason: '本地记的发送时间比镜像里的 100 新');
  });
}

class _CountingCore extends FakeCore {
  int upserts = 0;

  @override
  Future<JsonMap> sessionIndexUpsert(JsonMap entry) {
    upserts++;
    return super.sessionIndexUpsert(entry);
  }
}
