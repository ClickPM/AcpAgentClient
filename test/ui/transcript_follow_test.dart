// 转录跟随底部（所有者手测 2026-09-17：「流式回复不会自动跟随展示，页面固定不动」）的回归测试。
// 守住三件事：默认贴着底部、用户往上翻之后新内容不再把他拽下去、他自己滚回底部跟随要接上。
// 组合根 lib/app/workbench_screen.dart 里那一套（store 通知 → 下一帧 jumpTo 到 maxScrollExtent）
// 一旦摘掉，第一条与第三条立刻挂。

import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/app/workbench_screen.dart';
import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/projection/session_store.dart';
import 'package:acp_agent_client/ui/transcript/icons.dart';
import 'package:acp_agent_client/ui/transcript/transcript_list.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../app/fake_core.dart';
import '../gallery_harness.dart';

const String _agent = 'a';
const String _session = 'sess_1';

final Finder _list = find.descendant(of: find.byType(TranscriptList), matching: find.byType(ListView));
final Finder _send = find.byWidgetPredicate((w) => w is AcpIcon && w.body == AcpIcons.arrowUp);

/// 一段助手回复（流式分块在投影层已经合并成一条 MessageEntry，这里按「又来了一段」造）。
void _say(SessionStore store, int from, int count) {
  for (var i = from; i < from + count; i++) {
    store.applyUpdateJson(<String, dynamic>{
      'sessionUpdate': 'agent_message_chunk',
      'messageId': 'a$i',
      'content': <String, dynamic>{'type': 'text', 'text': '第 $i 段回复：先读一遍现有脚本，再决定插在编译之前还是之后。' * 12},
    });
  }
}

ScrollPosition _pos(WidgetTester tester) => tester.widget<ListView>(_list).controller!.position;

/// 跟随是 post-frame 里做的，惰性构建还可能要连纠正几帧：给足帧数，但不用 pumpAndSettle
/// （回合进行中会话头的 spinner 是永不停的动画，会把 pumpAndSettle 拖到超时）。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 滚轮（桌面上用户就是这么翻的）：dy < 0 = 往上翻，dy > 0 = 往下滚，滚过头由 physics 夹到底。
/// 触屏的拖拽在这里不能用来模拟：转录整块包在 SelectableRegion 里，touch 的拖拽被它吃掉，
/// 列表一格都不动（实测）。
Future<void> _wheel(WidgetTester tester, double dy) async {
  final mouse = TestPointer(1, PointerDeviceKind.mouse);
  mouse.hover(tester.getCenter(_list));
  await tester.sendEventToBinding(mouse.scroll(Offset(0, dy)));
  await _settle(tester);
}

/// 一格一格往下滚，直到真的到底（每滚一格都会重新布局、maxScrollExtent 随之收敛）。
Future<void> _wheelToBottom(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    final p = _pos(tester);
    if (p.maxScrollExtent - p.pixels <= 0.5) return;
    await _wheel(tester, 400);
  }
}

/// 起壳：一条已连上的会话，转录里先垫够超过一屏的内容。
Future<(WorkbenchController, SessionStore)> _pumpShell(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // flutter_tester 不装包字体也不做 CJK 回退，缺字体时侧栏底部导航会算宽撑破（gallery_harness 的注释）。
  await tester.runAsync(loadGalleryFonts);

  final core = FakeCore();
  final c = WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask)
    ..session.agentId = _agent
    ..session.sessionId = _session;
  final store = c.sessions.session(_session, agentId: _agent);
  addTearDown(c.dispose);
  _say(store, 0, 8);

  await tester.pumpWidget(MaterialApp(home: WorkbenchScreen(controller: c)));
  await _settle(tester);
  expect(_pos(tester).maxScrollExtent, greaterThan(0), reason: '内容没超过一屏，这几条测试就什么也没测');
  return (c, store);
}

void main() {
  testWidgets('默认跟随：新内容一到就贴着底部', (tester) async {
    final (_, store) = await _pumpShell(tester);
    expect(_pos(tester).pixels, moreOrLessEquals(_pos(tester).maxScrollExtent, epsilon: 0.5), reason: '开会话先落在最新一条');

    final before = _pos(tester).maxScrollExtent;
    _say(store, 8, 4);
    await _settle(tester);

    expect(_pos(tester).maxScrollExtent, greaterThan(before), reason: '内容确实长了');
    expect(_pos(tester).pixels, moreOrLessEquals(_pos(tester).maxScrollExtent, epsilon: 0.5), reason: '流式回复要自己跟到最新');
  });

  testWidgets('用户往上翻：停在他翻到的地方，新内容不再把他拽下去', (tester) async {
    final (_, store) = await _pumpShell(tester);
    await _wheel(tester, -300);
    final stopped = _pos(tester).pixels;
    expect(stopped, lessThan(_pos(tester).maxScrollExtent - 32), reason: '确实翻上去了');

    _say(store, 8, 4);
    await _settle(tester);

    expect(_pos(tester).pixels, moreOrLessEquals(stopped, epsilon: 0.5), reason: '人在看旧内容，别把他拽回底部');
  });

  testWidgets('滚回底部：跟随自动接上', (tester) async {
    final (_, store) = await _pumpShell(tester);
    await _wheel(tester, -300);
    _say(store, 8, 2);
    await _settle(tester);
    expect(_pos(tester).pixels, lessThan(_pos(tester).maxScrollExtent - 32));

    // 用户自己滚回底部：惰性列表的 maxScrollExtent 是估的，一格一格滚才会收敛到真正的底
    // （一次滚 1200 只会落到当时估出来的那个底）。
    await _wheelToBottom(tester);
    expect(_pos(tester).pixels, moreOrLessEquals(_pos(tester).maxScrollExtent, epsilon: 0.5));

    _say(store, 10, 4);
    await _settle(tester);
    expect(_pos(tester).pixels, moreOrLessEquals(_pos(tester).maxScrollExtent, epsilon: 0.5), reason: '回到底部就该重新跟随');
  });

  testWidgets('发送：翻上去看过旧内容，发出去的这条还是要看得见', (tester) async {
    final (c, _) = await _pumpShell(tester);
    await _wheel(tester, -300);
    expect(_pos(tester).pixels, lessThan(_pos(tester).maxScrollExtent - 32));

    c.composer.editor.text = '继续';
    await tester.tap(_send);
    await _settle(tester);

    expect(c.session.store!.entries.whereType<TurnEntry>(), hasLength(1), reason: '这一轮真的发出去了');
    expect(_pos(tester).pixels, moreOrLessEquals(_pos(tester).maxScrollExtent, epsilon: 0.5));
  });
}
