// 画板 43 接线：线程头 history → 时间线弹层 → 点一行转录区跳到那一条。
// 守住三件事：按钮的显示条件与选中态、弹层列的是当前会话的轮、跳转真的把惰性列表滚到目标那一条
// 并把「跟随底部」停掉（不停的话下一条流式块立刻又把视口拽回最底下，跳了等于没跳）。

import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/app/workbench_screen.dart';
import 'package:acp_agent_client/projection/session_store.dart';
import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/popovers/session_timeline.dart';
import 'package:acp_agent_client/ui/transcript/icons.dart';
import 'package:acp_agent_client/ui/transcript/transcript_list.dart';
import 'package:acp_agent_client/ui/transcript/user_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../gallery_harness.dart';
import 'fake_core.dart';

const String _agent = 'a';
const String _session = 'sess_1';

final Finder _list = find.descendant(of: find.byType(TranscriptList), matching: find.byType(ListView));
final Finder _historyButton = find.byWidgetPredicate((w) => w is AcpIcon && w.body == AcpIcons.history);

ScrollPosition _pos(WidgetTester tester) => tester.widget<ListView>(_list).controller!.position;

/// 跟随与跳转都在 post-frame 里做，惰性构建还要连纠正几帧；不用 pumpAndSettle（spinner 是永不停的动画）。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 造 [turns] 轮问答，每轮的回复长到一屏装不下，这样目标行一定在视口之外、走估位那条路。
void _converse(SessionStore store, int turns) {
  for (var i = 1; i <= turns; i++) {
    store.applyUpdateJson(<String, dynamic>{
      'sessionUpdate': 'user_message_chunk',
      'content': <String, dynamic>{'type': 'text', 'text': '第 $i 个问题'},
    });
    store.applyUpdateJson(<String, dynamic>{
      'sessionUpdate': 'agent_message_chunk',
      'messageId': 'a$i',
      'content': <String, dynamic>{'type': 'text', 'text': '第 $i 个回答：先读一遍现有脚本，再决定插在编译之前还是之后。' * 12},
    });
  }
}

/// 最近一次 [_pumpShell] 用的假核心（断言「有没有真发出去 prompt」用）。
late FakeCore _core;

Future<(WorkbenchController, SessionStore)> _pumpShellWithCore(WidgetTester tester, {int turns = 8}) =>
    _pumpShell(tester, turns: turns);

Future<(WorkbenchController, SessionStore)> _pumpShell(WidgetTester tester, {int turns = 8, bool withSession = true}) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.runAsync(loadGalleryFonts);
  await tester.runAsync(precacheIcons);

  final core = FakeCore();
  _core = core;
  final c = WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask)
    ..agentId = _agent;
  addTearDown(c.dispose);
  late SessionStore store;
  if (withSession) {
    c.sessionId = _session;
    store = c.sessions.session(_session, agentId: _agent);
    _converse(store, turns);
  } else {
    store = SessionStore(sessionId: 'unused');
  }

  await tester.pumpWidget(MaterialApp(home: WorkbenchScreen(controller: c)));
  await _settle(tester);
  return (c, store);
}

Future<void> _openTimeline(WidgetTester tester) async {
  await tester.tap(_historyButton);
  await _settle(tester);
}

void main() {
  testWidgets('有会话才出 history 按钮，且弹层列的是本会话的轮', (tester) async {
    await _pumpShell(tester, turns: 3);
    expect(_historyButton, findsOneWidget);

    await _openTimeline(tester);
    expect(find.byType(SessionTimelinePopover), findsOneWidget);
    expect(find.text('Session timeline · 3 turns'), findsOneWidget);
    expect(find.text('第 1 个问题'), findsWidgets, reason: '编号行的文案就是用户消息首行');
  });

  testWidgets('没有会话时不渲染 history 按钮（与 reload 同规则）', (tester) async {
    await _pumpShell(tester, withSession: false);
    expect(_historyButton, findsNothing);
  });

  testWidgets('点一行：转录跳到那一条，跟随底部停掉', (tester) async {
    final (_, store) = await _pumpShell(tester);
    final bottom = _pos(tester).pixels;
    expect(bottom, moreOrLessEquals(_pos(tester).maxScrollExtent, epsilon: 0.5), reason: '开局贴着底部');

    await _openTimeline(tester);
    // 弹层里第 1 轮的编号行（转录区里同样有这句，所以按弹层限定 finder）。
    await tester.tap(find.descendant(of: find.byType(SessionTimelinePopover), matching: find.text('第 1 个问题')).first);
    await _settle(tester);

    expect(find.byType(SessionTimelinePopover), findsNothing, reason: '跳完弹层立刻关掉');
    expect(_pos(tester).pixels, lessThan(bottom - t.Spacing.s16), reason: '确实从底部跳上去了');
    expect(find.text('第 1 个问题'), findsWidgets, reason: '目标那一条在视口里');

    // 跟随停掉：再来一段流式回复，视口不该被拽回底部。
    final landed = _pos(tester).pixels;
    store.applyUpdateJson(<String, dynamic>{
      'sessionUpdate': 'agent_message_chunk',
      'messageId': 'tail',
      'content': <String, dynamic>{'type': 'text', 'text': '又来一段。' * 80},
    });
    await _settle(tester);
    expect(_pos(tester).pixels, moreOrLessEquals(landed, epsilon: 0.5), reason: '人在看旧内容，别把他拽回底部');
  });

  testWidgets('跳到用户气泡：落地后它进入画板 11 的点击聚焦态，再点别处就撤', (tester) async {
    await _pumpShell(tester, turns: 4);
    await _openTimeline(tester);
    await tester.tap(find.descendant(of: find.byType(SessionTimelinePopover), matching: find.text('第 2 个问题')).first);
    await _settle(tester);

    final focused = tester.widgetList<UserMessage>(find.byType(UserMessage)).where((w) => w.focused);
    expect(focused, hasLength(1), reason: '只有跳过来的那一条是聚焦态');
    expect(focused.single.entry.text, '第 2 个问题');

    // 转录区里点一下别处：聚焦态撤掉。
    await tester.tapAt(tester.getCenter(_list));
    await _settle(tester);
    expect(tester.widgetList<UserMessage>(find.byType(UserMessage)).where((w) => w.focused), isEmpty);
  });

  // 发布前审查 P2（2026-09-20，cursor）：弹层原来用 `HardwareKeyboard` 全局处理器接键、不抢输入框焦点，
  // 而那条路**挡不住焦点链**（全局处理器跑完，同一下按键还会无条件发给焦点链）。于是弹层开着时那一下
  // Enter 照样被输入框当成「发送」，把没写完的草稿发了出去。改成弹层自己拿焦点。
  testWidgets('刚打开还没高亮时按 Enter：不发草稿，也不跳', (tester) async {
    final (c, _) = await _pumpShellWithCore(tester, turns: 3);
    // 真实路径是「用户正打着字 → 输入框有焦点 → 点 history 开弹层」：按钮是 Hoverable / GestureDetector，
    // 点它不夺焦点，所以开着弹层时焦点仍在输入框上。测试里必须把这一步做出来，否则焦点链是空的、复现不出来。
    c.composer.text = '还没写完的草稿';
    c.composerFocus.requestFocus();
    await tester.pump();
    expect(c.composerFocus.hasFocus, isTrue, reason: '这条测试的前提');
    await _openTimeline(tester);
    expect(c.composerFocus.hasFocus, isFalse, reason: '弹层开着时键盘归它（关掉会还回去，见下一条）');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester);

    expect(_core.prompts, isEmpty, reason: '这一下 Enter 必须被弹层吃掉，不能落到输入框');
    expect(c.composer.text, '还没写完的草稿', reason: '草稿原样留着');
    expect(find.byType(SessionTimelinePopover), findsOneWidget, reason: '没有高亮就什么也不做，弹层照常开着');

    // 同一个根因的另一半：方向键也不该串到输入框里去移动光标。
    c.composer.selection = const TextSelection.collapsed(offset: 3);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await _settle(tester);
    expect(c.composer.selection.baseOffset, 3, reason: '光标不该被方向键挪走');
  });

  // 复审 P2（2026-09-20，cursor）：改成抢焦点之后，`_onKey` 没吃的键会沿焦点链落到 WidgetsApp 的默认
  // Shortcuts —— Tab / Shift+Tab / 左右方向键是 Next/Previous/DirectionalFocusIntent，会把键盘交回输入框，
  // 而弹层还开着；此后 Enter 又走输入框的「发送」。弹层开着时键盘必须完全归它。
  testWidgets('弹层开着时 Tab 与左右键不把焦点交回输入框，之后 Enter 也发不出草稿', (tester) async {
    final (c, _) = await _pumpShellWithCore(tester, turns: 3);
    c.composer.text = '还没写完的草稿';
    c.composerFocus.requestFocus();
    await tester.pump();
    await _openTimeline(tester);
    expect(c.composerFocus.hasFocus, isFalse);

    for (final key in <LogicalKeyboardKey>[
      LogicalKeyboardKey.tab,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowLeft,
    ]) {
      await tester.sendKeyEvent(key);
      await _settle(tester);
      expect(c.composerFocus.hasFocus, isFalse, reason: '$key 把焦点带回输入框了');
      expect(find.byType(SessionTimelinePopover), findsOneWidget, reason: '$key 之后弹层还该开着');
    }

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester);
    expect(_core.prompts, isEmpty, reason: '焦点没被带走，这一下 Enter 仍归弹层');
    expect(c.composer.text, '还没写完的草稿');
  });

  testWidgets('弹层关掉后焦点还回输入框（用户能接着打字）', (tester) async {
    final (c, _) = await _pumpShellWithCore(tester, turns: 3);
    c.composerFocus.requestFocus();
    await tester.pump();
    await _openTimeline(tester);
    expect(c.composerFocus.hasFocus, isFalse, reason: '开着时键盘归弹层');

    await tester.tapAt(tester.getCenter(_list));
    await _settle(tester);

    expect(find.byType(SessionTimelinePopover), findsNothing);
    expect(c.composerFocus.hasFocus, isTrue, reason: '关掉要把焦点还回去，不然得再点一下才能打字');
  });

  testWidgets('Esc 关掉弹层：它是唯一放行的键，靠 EscapeDismissible 的全局处理器', (tester) async {
    final (c, _) = await _pumpShellWithCore(tester, turns: 3);
    await _openTimeline(tester);
    expect(c.timelineAnchor.isShowing, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);

    expect(c.timelineAnchor.isShowing, isFalse);
    expect(find.byType(SessionTimelinePopover), findsNothing);
  });

  testWidgets('点弹层之外关掉它，按钮的选中容器跟着撤', (tester) async {
    final (c, _) = await _pumpShell(tester, turns: 3);
    await _openTimeline(tester);
    expect(c.timelineAnchor.isShowing, isTrue);

    // 点转录区中间：那一下先落到弹层的透明遮罩上。
    await tester.tapAt(tester.getCenter(_list));
    await _settle(tester);

    expect(c.timelineAnchor.isShowing, isFalse);
    expect(find.byType(SessionTimelinePopover), findsNothing);
  });
}
