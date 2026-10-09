// 画板 80 的 `acp/traffic` 投影：环形缓冲、stderr 尾巴、变体标签、响应行回填方法名、表外变体计数。
// iteration-18：展开用的缩进 JSON 改成按需算 + 记忆化——它是整条线里最大的一份数据（带图 prompt 一行
// 900 KB，缩进后 1 MB 出头），而 TrafficStore 收一条存一条、保 2000 行，谁都没展开也照样常驻一份。
// 缩进挪走之后「解析」这一步必须还在原地：`id` / `method` / 变体标签都靠它，所以那几个行为一并守在这里。

import 'dart:convert';

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

  // BACKLOG P0「超大 payload 进入 TrafficStore」（2026-10-08）：带 2 MB base64 图的 prompt 整行 jsonDecode、
  // 展开时再整串着色，内存暴涨卡死。超长行只解析 / 展示截过长字符串的那一份，标签照样认得出。
  group('超长行', () {
    final bigImage = 'A' * (2 * 1024 * 1024);
    final prompt = '{"jsonrpc":"2.0","id":9,"method":"session/prompt","params":{"sessionId":"s",'
        '"prompt":[{"type":"image","mimeType":"image/png","data":"$bigImage"}]}}';

    test('标签与回填不受截断影响，复制用的 raw 仍是整行', () {
      final store = TrafficStore();
      store.apply(envelope(prompt, direction: 'out'));
      store.apply(envelope('{"jsonrpc":"2.0","id":9,"result":{"stopReason":"end_turn"}}'));

      expect(store.lines[0].method, 'session/prompt');
      expect(store.lines[0].label, 'request');
      expect(store.lines[0].raw, prompt);
      expect(store.lines[1].method, 'session/prompt');
    });

    test('展开的缩进 JSON 只留长字符串的开头', () {
      final store = TrafficStore();
      store.apply(envelope(prompt, direction: 'out'));

      final pretty = store.lines.single.pretty!;
      expect(pretty.length, lessThan(TrafficStore.elideThreshold));
      expect(pretty, contains('"mimeType": "image/png"'));
      expect(pretty, contains('省略 ${bigImage.length - TrafficStore.elideKeep} 字符'));
    });

    test('不是 JSON 的超长行直接截断', () {
      final store = TrafficStore();
      store.apply(envelope('x' * (TrafficStore.elideThreshold + 1)));

      final line = store.lines.single;
      expect(line.pretty, isNull);
      expect(line.elidedRaw.length, lessThan(TrafficStore.elideKeep + 32));
    });

    test('截断点不切开转义序列，截完仍是合法 JSON', () {
      final s = '\\u00e9' * (TrafficStore.elideKeep); // 每个 6 个码元，截断点必然落在转义里附近
      final escaped = '{"a":"x$s","b":"\\"q\\""}';
      final out = elideLongStrings(escaped);
      expect(out, contains('省略'));
      expect(out, endsWith(',"b":"\\"q\\""}'));
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['b'], '"q"');
      expect((decoded['a'] as String).startsWith('xé'), isTrue);
    });

    test('短串原样', () {
      const line = '{"a":"short","b":[1,2]}';
      expect(elideLongStrings(line), same(line));
    });

    test('大量短元素的超长行不整份展开，方法名仍取得出', () {
      final items = List<String>.filled(20000, '"ab"').join(',');
      final raw = '{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"items":[$items]}}';
      expect(raw.length, greaterThan(TrafficStore.elideThreshold));
      final store = TrafficStore()..apply(envelope(raw, direction: 'out'));
      final line = store.lines.single;
      expect(line.method, 'session/prompt');
      expect(line.label, 'request');
      expect(line.elidedRaw.length, lessThan(1000));
      expect(line.pretty, isNull);
      expect(line.raw, raw);
    });

    test('截断点不切开转义形式的代理对', () {
      final text = '${'a' * 250}\\uD83D\\uDE00${'b' * 80}';
      final raw = '{"a":"$text"}';
      final out = elideLongStrings(raw);
      expect(out, contains(r'\uD83D\uDE00'));
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['a'], contains('😀'));
    });
  });
}
