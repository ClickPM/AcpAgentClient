// 画板 61 的模型与 widget（R4 画板阶段）：本地终端的分块 UTF-8 解码（跨块的汉字不切坏）、退出状态与耗时、
// 状态行文案、停止方块只在运行中出现、右栏标签的相等性。

import 'dart:convert';

import 'package:acp_agent_client/ui/shell/right_panel.dart';
import 'package:acp_agent_client/ui/shell/shell_common.dart';
import 'package:acp_agent_client/ui/terminal/local_terminal.dart';
import 'package:acp_agent_client/ui/terminal/terminal_panel.dart';
import 'package:acp_agent_client/ui/transcript/terminal_card.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart' show TerminalKey;

Widget host(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(800, 600)),
        child: Overlay(initialEntries: <OverlayEntry>[OverlayEntry(builder: (_) => child)]),
      ),
    );

/// xterm 主缓冲区里当前所有非空行的文本。
List<String> screenLines(LocalTerminal t) {
  final b = t.terminal.buffer;
  return <String>[
    for (var i = 0; i < b.height; i++)
      if (b.lines[i].getText().trim().isNotEmpty) b.lines[i].getText().trimRight(),
  ];
}

void main() {
  test('writeBytes：一个汉字被切成两块到达，解码后仍是一个字', () {
    final t = LocalTerminal(id: 't', title: 'x', cwd: 'D:/w');
    final bytes = utf8.encode('中文\r\n');
    t.writeBytes(bytes.sublist(0, 2)); // 「中」的三个字节只到了两个
    t.writeBytes(bytes.sublist(2));
    expect(screenLines(t).first, '中文');
  });

  test('exit 记退出码与耗时；running 翻转', () {
    final started = DateTime.utc(2026, 9, 16, 10);
    final t = LocalTerminal(id: 't', title: 'x', cwd: 'D:/w', startedAt: started);
    expect(t.running, isTrue);
    t.exit(code: 1, at: started.add(const Duration(milliseconds: 900)));
    expect(t.running, isFalse);
    expect(t.elapsed, const Duration(milliseconds: 900));
    expect(TerminalExitLine.formatElapsed(t.elapsed!), '0.9s');
    expect(TerminalExitLine.formatElapsed(const Duration(milliseconds: 120)), '0.1s');
    expect(TerminalExitLine.formatElapsed(const Duration(seconds: 75)), '1m 15s');
  });

  test('键盘输入经 onInput 交出去（xterm 的 onOutput）', () {
    final sent = <String>[];
    final t = LocalTerminal(id: 't', title: 'x', cwd: 'D:/w', onInput: sent.add);
    t.terminal.textInput('ls');
    t.terminal.keyInput(TerminalKey.enter);
    expect(sent.join(), 'ls\r');
  });

  testWidgets('状态行：运行中显示 cwd + 停止方块；退出后显示退出码且没有停止方块', (tester) async {
    final t = LocalTerminal(id: 't', title: 'x', cwd: r'D:\work\proj');
    var stops = 0;
    await tester.pumpWidget(host(TerminalPanel(terminal: t, onStop: () => stops++)));
    expect(find.text(r'D:\work\proj'), findsOneWidget);
    await tester.tap(find.byType(StopSquareButton));
    expect(stops, 1);

    t.exit(code: 1);
    await tester.pump();
    expect(find.text('已退出 · exitCode 1 · signal none'), findsOneWidget);
    expect(find.byType(StopSquareButton), findsNothing);
    expect(find.textContaining('Exit Code'), findsOneWidget);
  });

  test('PanelTab：面板标签按 ShellTab 相等，终端标签按 id 相等', () {
    expect(const PanelTab.shell(ShellTab.files), const PanelTab.shell(ShellTab.files));
    expect(const PanelTab.terminal('a', 'x'), const PanelTab.terminal('a', 'y'));
    expect(const PanelTab.terminal('a', 'x') == const PanelTab.terminal('b', 'x'), isFalse);
    expect(const PanelTab.terminal('a', 'x').isTerminal, isTrue);
    expect(const PanelTab.shell(ShellTab.terminal).isTerminal, isFalse);
  });
}
