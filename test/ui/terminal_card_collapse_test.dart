// 跑完自动收起（终端卡，所有者裁定 2026-09-18）：协议里没有「折叠」这回事（ToolCall 只给 status），
// 这是客户端自定的呈现规则，所以守在这里——跑的时候展开着能看，转 completed / failed（或终端自己 exit）的那一下让位给后面的输出；
// 用户手动点过头行就不再替他做主；只认「转换」的那一下，生来就结束的卡由 initiallyExpanded 定
//（画板 22 的展开态照旧，转录列表给历史卡传的是折叠）。

import 'package:acp_agent_client/gallery/fixtures_source.dart';
import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/ui/transcript/terminal_card.dart';
import 'package:acp_agent_client/ui/transcript/transcript_list.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart' as xt;

import '../gallery_harness.dart';

void main() {
  /// 展开体 = xterm 的输出区：在树上就是展开，不在就是折叠。
  final Finder body = find.byType(xt.TerminalView);

  Future<void> pump(WidgetTester tester, Widget child, {double? height}) async {
    await tester.runAsync(() async {
      await loadGalleryFonts();
      await precacheIcons();
    });
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(900, 1200)),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 900, height: height, child: child),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// 停在「命令还在跑」：terminal/create 之后、terminal/kill 之前（fixtures 21 的第 8 行起是停止）。
  FixtureReplay running() => FixtureReplay.replay(<String>['01-connect', '21-terminal-running'], upTo: 8);

  testWidgets('终端 exit 的那一下自动收起', (tester) async {
    final r = running();
    final e = r.tool('call_exec_r1');
    final buffer = r.sessions.terminals['term_run']!;
    expect(e.isFinished, isFalse);
    expect(buffer.exited, isFalse);

    await pump(tester, TerminalCard(e, buffer: buffer, cwd: r.session.cwd));
    expect(body, findsOneWidget, reason: '跑的时候展开着');

    buffer.exit(code: 0);
    await tester.pump();
    expect(body, findsNothing, reason: '跑完让位');
  });

  testWidgets('status 转 completed 也算跑完：转录列表重建时收起', (tester) async {
    final r = running();
    final e = r.tool('call_exec_r1');
    final buffer = r.sessions.terminals['term_run']!;
    late StateSetter rebuild;
    await pump(tester, StatefulBuilder(builder: (BuildContext context, StateSetter setState) {
      rebuild = setState;
      return TerminalCard(e, buffer: buffer, cwd: r.session.cwd);
    }));
    expect(body, findsOneWidget);

    // 投影层就是这样就地改同一个 ToolCallEntry 的：卡拿不到新对象，只能靠重建时的这一下看出来。
    e.status = ToolStatus.completed;
    rebuild(() {});
    await tester.pump();
    expect(body, findsNothing);
  });

  testWidgets('用户手动点过头行：跑完不再替他收', (tester) async {
    final r = running();
    final e = r.tool('call_exec_r1');
    final buffer = r.sessions.terminals['term_run']!;

    await pump(tester, TerminalCard(e, buffer: buffer, cwd: r.session.cwd));
    await tester.tap(find.text(e.title));
    await tester.pump();
    expect(body, findsNothing, reason: '点一下收起');
    await tester.tap(find.text(e.title));
    await tester.pump();
    expect(body, findsOneWidget, reason: '再点一下展开');

    buffer.exit(code: 0);
    await tester.pump();
    expect(body, findsOneWidget, reason: '他自己表过态，跑完就不动了');
  });

  testWidgets('生来就结束的卡按 initiallyExpanded 走：画板 22 的展开态照旧', (tester) async {
    final r = FixtureReplay.replay(<String>['01-connect', '24-terminal-git-log']);
    final e = r.tool('call_exec_git');
    expect(e.isFinished, isTrue);

    await pump(tester, TerminalCard(e, buffer: r.sessions.terminals['term_7f31']!, cwd: r.session.cwd));
    expect(body, findsOneWidget);
  });

  testWidgets('转录列表：已跑完的终端卡生来就是折叠的（session/load 回放的历史不再满屏输出）', (tester) async {
    final r = FixtureReplay.replay(<String>['01-connect', '24-terminal-git-log']);
    await pump(
      tester,
      Overlay(initialEntries: <OverlayEntry>[OverlayEntry(builder: (_) => TranscriptList(r.session))]),
      height: 1200,
    );

    expect(find.byType(TerminalCard), findsOneWidget);
    expect(body, findsNothing);
  });
}
