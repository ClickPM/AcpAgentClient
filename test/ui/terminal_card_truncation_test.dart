// 终端缓冲写满之后卡片照样刷新（BACKLOG P0「终端输出超过 64 K 字符后，终端卡的画面就冻住了」，2026-09-24）：
// TerminalBuffer 写满后只留最后 limit 个字符、长度恒定，卡片原先只按「长度变长就写增量」判断，从此不再往 xterm 写。
// 现在卡片按缓冲只增不减的累计写入量（TerminalBuffer.total）记位置。画板 22 / 23 的终端卡与画板 52 的认证终端同一套同步逻辑，两张都守。
// 用小上限（40 个字符）代替 64 K，行为一样。

import 'package:acp_agent_client/gallery/fixtures_source.dart';
import 'package:acp_agent_client/projection/tool_calls.dart';
import 'package:acp_agent_client/ui/registry/auth_page.dart';
import 'package:acp_agent_client/ui/transcript/terminal_card.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart' as xt;

void main() {
  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(900, 1200)),
          child: Align(alignment: Alignment.topLeft, child: SizedBox(width: 900, child: child)),
        ),
      ),
    );
    await tester.pump();
  }

  /// xterm 里现在画着的全部文本（含回滚区）。
  String shown(WidgetTester tester) => tester.widget<xt.TerminalView>(find.byType(xt.TerminalView)).terminal.buffer.getText();

  /// 每行 8 个字符：`line-00\n` … 十行 80 个，40 的上限写到第五行就开始截。
  void writeLines(TerminalBuffer b, int from, int to) {
    for (var i = from; i < to; i++) {
      b.append('line-${i.toString().padLeft(2, '0')}\n');
    }
  }

  test('累计写入量只增不减：截断后 output 长度不变，total 照样往上走', () {
    final b = TerminalBuffer('term_small', limit: 40);
    writeLines(b, 0, 10);
    expect(b.truncated, isTrue);
    expect(b.output.length, 40);
    expect(b.total, 80);
    b.append('TAIL\n');
    expect(b.output.length, 40);
    expect(b.total, 85);
    expect(b.output, endsWith('TAIL\n'));
  });

  group('画板 22 / 23 终端卡', () {
    TerminalCard card(TerminalBuffer buffer) {
      final r = FixtureReplay.replay(<String>['01-connect', '21-terminal-running'], upTo: 8);
      return TerminalCard(r.tool('call_exec_r1'), buffer: buffer, cwd: r.session.cwd);
    }

    testWidgets('写满之后的输出照样进 xterm（原先停在写满那一刻）', (tester) async {
      final b = TerminalBuffer('term_small', limit: 40);
      await pump(tester, card(b));
      writeLines(b, 0, 10);
      expect(b.truncated, isTrue);
      b.append('TAIL-MARK\n');
      await tester.pump();
      final text = shown(tester);
      expect(text, contains('line-09'));
      expect(text, contains('TAIL-MARK'));
      // 增量写：视图自己留着的早先几行不因缓冲截断而被清掉。
      expect(text, contains('line-00'));
    });

    testWidgets('一次写入超过上限：没来得及写的那段已被截掉，清屏重写留存的尾巴', (tester) async {
      final b = TerminalBuffer('term_small', limit: 40);
      await pump(tester, card(b));
      writeLines(b, 0, 2);
      b.append('${'x' * 60}\nBIG-END\n');
      await tester.pump();
      final text = shown(tester);
      expect(text, contains('BIG-END'));
      expect(text, isNot(contains('line-00')), reason: '重写的是留存段，之前画的清掉');
    });

    testWidgets('卡片在截断之后才建：直接画留存的那段', (tester) async {
      final b = TerminalBuffer('term_small', limit: 40);
      writeLines(b, 0, 10);
      await pump(tester, card(b));
      final text = shown(tester);
      expect(text, contains('line-09'));
      expect(text, isNot(contains('line-00')));
      b.append('AFTER\n');
      await tester.pump();
      expect(shown(tester), contains('AFTER'));
    });
  });

  testWidgets('画板 52 认证终端：写满之后的输出照样进 xterm', (tester) async {
    final b = TerminalBuffer('term_auth', limit: 40);
    await pump(tester, AuthTerminalCard(label: 'login', buffer: b));
    writeLines(b, 0, 10);
    b.append('TAIL-MARK\n');
    await tester.pump();
    final text = shown(tester);
    expect(text, contains('line-09'));
    expect(text, contains('TAIL-MARK'));
  });
}
