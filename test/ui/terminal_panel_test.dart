// 画板 61 的模型与 widget（R4 画板阶段）：本地终端的分块 UTF-8 解码（跨块的汉字不切坏）、退出状态与耗时、
// 状态行文案、停止方块只在运行中出现、右栏标签的相等性。

import 'dart:convert';

import 'package:acp_agent_client/ui/shell/right_panel.dart';
import 'package:acp_agent_client/ui/shell/shell_common.dart';
import 'package:acp_agent_client/ui/terminal/local_terminal.dart';
import 'package:acp_agent_client/ui/terminal/terminal_panel.dart';
import 'package:acp_agent_client/ui/transcript/terminal_card.dart';
import 'package:flutter/services.dart';
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

  testWidgets('键盘打字到得了终端：字符键经 KeyEvent.character、回车经 keytab，都从 onInput 出去', (tester) async {
    final sent = <String>[];
    final t = LocalTerminal(id: 't', title: 'x', cwd: r'D:\w', onInput: sent.add);
    await tester.pumpWidget(host(TerminalPanel(terminal: t, autofocus: true)));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    // 走的是 hardwareKeyboardOnly 那条：xterm 默认的平台文本输入通道在 Windows 引擎上建不起来
    // （setClient 少 viewId 被拒），字符键会被静默丢掉。
    expect(sent.join(), 'ls\r');
    // 带修饰键的还是走 keytab / CtrlInputHandler，不会再把字符补一遍：Ctrl+C 只出 ETX。
    sent.clear();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(sent.join(), '\x03');
  });

  testWidgets('中文输入法：组字期间不外发、上屏整串交给终端；连接带 viewId（Windows 引擎缺它会拒掉 setClient）', (tester) async {
    final sent = <String>[];
    final term = LocalTerminal(id: 't', title: 'x', cwd: r'D:\w', onInput: sent.add);
    await tester.pumpWidget(host(TerminalPanel(terminal: term, autofocus: true)));
    await tester.pump(); // autofocus 结算
    await tester.pump(); // IME 层在首帧之后开连接

    expect(tester.testTextInput.setClientArgs, isNotNull, reason: '终端要有自己的文本输入连接，组字才进得来');
    expect(tester.testTextInput.setClientArgs!['viewId'], isA<int>(), reason: 'Windows 引擎 setClient 缺 viewId 直接拒');

    // 组字中（拼音还在候选框里）：一个字节都不该进 shell。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: 'nihao', composing: TextRange(start: 0, end: 5)),
    );
    await tester.pump();
    expect(sent, isEmpty);

    // 上屏。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: '你好', selection: TextSelection.collapsed(offset: 2)),
    );
    await tester.pump();
    expect(sent.join(), '你好');

    // 上屏之后编辑状态清回空串：下一次上屏不会把上一次的字再带一遍。
    sent.clear();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: '世界', selection: TextSelection.collapsed(offset: 2)),
    );
    await tester.pump();
    expect(sent.join(), '世界');
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
