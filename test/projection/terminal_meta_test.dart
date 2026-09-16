// R4：终端 provider 通道（`tool_call_update._meta.{terminal_info, terminal_output, terminal_exit}`，docs/design.md § 4 入站识别键，
// 所有者裁定待确认）。回放 test/fixtures/26-terminal-meta.jsonl：输出追加、退出码 / 信号二选一、cwd 进缓冲；
// 键存在但没有 terminal_id 的整项跳过；与 terminal/create 路径共用同一份 TerminalBuffer（画板 22 / 23 不分数据源）。

import 'package:acp_agent_client/gallery/fixtures_source.dart';
import 'package:acp_agent_client/projection/session_store.dart';
import 'package:acp_agent_client/projection/tool_calls.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('26-terminal-meta：两张终端卡的缓冲由 _meta 填满', () {
    final r = FixtureReplay.replay(<String>['01-connect', '26-terminal-meta']);
    final s = r.session;
    final first = r.tool('toolu_meta_1');
    expect(first.terminalIds, <String>['toolu_meta_1']);
    final b1 = s.terminals['toolu_meta_1']!;
    expect(b1.cwd, 'D:/variFlight_work/AcpAgentClient');
    expect(b1.output, '   Compiling acp-core v0.0.1\n    Finished test [unoptimized] in 4.20s\ntest result: ok. 27 passed; 0 failed; 0 ignored\n');
    expect(b1.exitCode, 0);
    expect(b1.signal, isNull);
    expect(b1.exited, isTrue);

    final b2 = s.terminals['toolu_meta_2']!;
    expect(b2.output, startsWith(' M rust/fs/src/lib.rs\n'));
    expect(b2.exitCode, isNull);
    expect(b2.signal, 'SIGTERM');
    expect(r.tool('toolu_meta_2').displayStatus.name, 'failed');
  });

  test('TerminalMetaEvent.parse：顺序 info → output → exit；缺 terminal_id 的项跳过', () {
    final events = TerminalMetaEvent.parse(<String, dynamic>{
      'terminal_exit': <String, dynamic>{'terminal_id': 't', 'exit_code': 3},
      'terminal_output': <String, dynamic>{'terminal_id': 't', 'data': 'x'},
      'terminal_info': <String, dynamic>{'terminal_id': 't', 'cwd': '/w'},
    });
    expect(events.map((e) => e.kind), <TerminalMetaKind>[TerminalMetaKind.info, TerminalMetaKind.output, TerminalMetaKind.exit]);
    expect(events[2].exitCode, 3);
    expect(TerminalMetaEvent.parse(<String, dynamic>{'terminal_output': <String, dynamic>{'data': 'no id'}}), isEmpty);
    expect(TerminalMetaEvent.parse(<String, dynamic>{'terminal_output': 'garbage'}), isEmpty);
    expect(TerminalMetaEvent.parse(null), isEmpty);
  });

  test('tool_call 自带的 _meta 也算；输出经 update 到达时不重复', () {
    var now = DateTime.utc(2026, 9, 16);
    final s = SessionStore(sessionId: 'x', clock: () => now = now.add(const Duration(seconds: 1)));
    s.applyUpdateJson(<String, dynamic>{
      'sessionUpdate': 'tool_call',
      'toolCallId': 'c1',
      'title': 'ls',
      'kind': 'execute',
      'status': 'in_progress',
      'content': <JsonMap>[<String, dynamic>{'type': 'terminal', 'terminalId': 'c1'}],
      '_meta': <String, dynamic>{'terminal_output': <String, dynamic>{'terminal_id': 'c1', 'data': 'a\n'}},
    });
    s.applyUpdateJson(<String, dynamic>{
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'c1',
      'status': 'completed',
      '_meta': <String, dynamic>{
        'terminal_output': <String, dynamic>{'terminal_id': 'c1', 'data': 'b\n'},
        'terminal_exit': <String, dynamic>{'terminal_id': 'c1', 'exit_code': 0, 'signal': null},
      },
    });
    expect(s.terminals['c1']!.output, 'a\nb\n');
    expect(s.terminals['c1']!.exitCode, 0);
    // update 上的 _meta 不并进 entry.meta（sdk 语义不变）。
    expect(s.toolCalls['c1']!.meta!.containsKey('terminal_output'), isTrue);
  });
}
