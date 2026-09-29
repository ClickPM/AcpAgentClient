// 画板 80 的 `acp/traffic` 投影：环形缓冲、stderr 尾巴、变体标签、响应行回填方法名、表外变体计数。
// iteration-18：展开用的缩进 JSON 改成按需算 + 记忆化——它是整条线里最大的一份数据（带图 prompt 一行
// 900 KB，缩进后 1 MB 出头），而 TrafficStore 收一条存一条、保 2000 行，谁都没展开也照样常驻一份。
// 缩进挪走之后「解析」这一步必须还在原地：`id` / `method` / 变体标签都靠它，所以那几个行为一并守在这里。

import 'package:acp_agent_client/projection/traffic.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  JsonMap envelope(String line, {String direction = 'in', String agentId = 'a', int ts = 1000}) =>
      <String, dynamic>{'agentId': agentId, 'direction': direction, 'line': line, 'ts': ts};

  test('缩进 JSON 按需算：JSON 行给出缩进串，不是 JSON 的行给 null（面板退回 raw）', () {
    final store = TrafficStore();
    store.apply(envelope('{"jsonrpc":"2.0","id":1}'));
    store.apply(envelope('not json at all'));

    expect(store.lines[0].pretty, '{\n  "jsonrpc": "2.0",\n  "id": 1\n}');
    expect(store.lines[1].pretty, isNull);
    expect(store.lines[1].label, 'raw');
  });

  test('缩进 JSON 记忆化：算过之后是同一个对象（面板每帧重建也不重算）', () {
    final store = TrafficStore();
    store.apply(envelope('{"jsonrpc":"2.0","id":1}'));

    final line = store.lines.single;
    expect(identical(line.pretty, line.pretty), isTrue);
  });

  test('响应行按 id 回填方法名（解析这一步没有跟着缩进一起挪走）', () {
    final store = TrafficStore();
    store.apply(envelope('{"jsonrpc":"2.0","id":7,"method":"session/prompt"}'));
    store.apply(envelope('{"jsonrpc":"2.0","id":7,"result":{"stopReason":"end_turn"}}'));

    expect(store.lines[1].method, 'session/prompt');
    expect(store.lines[1].label, 'response · stopReason end_turn');
  });

  test('表外变体标 unknown · dropped 并计数', () {
    final store = TrafficStore();
    store.apply(envelope('{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"notice"}}}'));

    expect(store.lines.single.label, 'unknown · dropped');
    expect(store.lines.single.dropped, isTrue);
    expect(store.droppedCount, 1);
  });

  test('stderr 不进环形缓冲，只进尾巴', () {
    final store = TrafficStore();
    store.apply(envelope('boom: token=***', direction: 'stderr'));

    expect(store.lines, isEmpty);
    expect(store.stderr['a'], <String>['boom: token=***']);
  });

  test('环形缓冲保 2000 行，最旧的丢', () {
    final store = TrafficStore();
    for (var i = 0; i < TrafficStore.maxLines + 3; i++) {
      store.apply(envelope('{"jsonrpc":"2.0","id":$i}'));
    }

    expect(store.lines.length, TrafficStore.maxLines);
    expect(store.lines.first.pretty, '{\n  "jsonrpc": "2.0",\n  "id": 3\n}');
  });
}
