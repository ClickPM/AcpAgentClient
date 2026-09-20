// 侧栏删除（画板 04 的删除图标 + 画板 41 的确认弹层）的 UI 接线回归测试。
// 所有者手测 2026-09-17：点删除图标「没反应」。成因是弹层的「点外面关闭」蒙层盖住整屏、吃掉命中测试，
// 会话行的 MouseRegion 随即 onExit，而删除图标（以及挂在它上面的 PopoverAnchor / OverlayPortal）
// 只在悬浮时才渲染 —— 弹层出现一帧就被连根摘掉。这里守住三件事：
// 弹层留得住、确认能真的删、点外面关掉后行不会卡在悬浮态。

import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/app/workbench_screen.dart';
import 'package:acp_agent_client/ui/popovers/topbar_popovers.dart';
import 'package:acp_agent_client/ui/shell/sidebar.dart';
import 'package:acp_agent_client/ui/transcript/card_chrome.dart';
import 'package:acp_agent_client/ui/transcript/icons.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../app/fake_core.dart';
import '../gallery_harness.dart';

const String _agent = 'a';
const String _session = 'sess_1';
const String _cwd = 'D:/repo';

final Finder _trash = find.byWidgetPredicate((w) => w is IconButtonGhost && w.icon == AcpIcons.trash);

/// 起壳：本地索引里一条会话，agent 没连过（能力未知 → 侧栏照给删除图标，但不发 session/delete）。
Future<(WorkbenchController, FakeCore)> _pumpShell(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // flutter_tester 不装包字体也不做 CJK 回退，缺字体时侧栏底部导航会算宽撑破（gallery_harness 的注释）。
  await tester.runAsync(loadGalleryFonts);

  final core = FakeCore();
  await core.sessionIndexUpsert(<String, dynamic>{
    'agentId': _agent,
    'sessionId': _session,
    'title': '一条会话',
    'cwd': _cwd,
    'messageCount': 3,
  });
  final c = WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask)
    ..workspace.project = const ProjectRef(path: _cwd, name: 'repo');
  await c.index.refresh();
  addTearDown(c.dispose);

  await tester.pumpWidget(MaterialApp(home: WorkbenchScreen(controller: c)));
  await tester.pump();
  return (c, core);
}

/// 鼠标停在会话行上（行内动作只在悬浮时出），返回这只鼠标以便之后移动。
Future<TestGesture> _hoverRow(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(tester.getCenter(find.byType(SidebarSessionRow)));
  await tester.pump();
  return mouse;
}

void main() {
  testWidgets('点删除图标：确认弹层留得住（蒙层夺走悬浮态也不塌）', (tester) async {
    final (c, _) = await _pumpShell(tester);
    await _hoverRow(tester);
    expect(_trash, findsOneWidget, reason: '悬浮时才出删除图标（画板 04）');

    await tester.tap(_trash);
    await tester.pump();
    expect(c.confirmingDeleteId, _session);
    expect(find.byType(DeleteSessionConfirm), findsOneWidget);

    // 蒙层吃掉命中测试 → 行 onExit → 重建。弹层必须还在（旧实现在这一帧被销毁）。
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(DeleteSessionConfirm), findsOneWidget, reason: '弹层不能被行的悬浮态收走');
  });

  testWidgets('确认弹层点「删除」：本地索引里这条没了，侧栏也不再有这一行', (tester) async {
    final (c, core) = await _pumpShell(tester);
    await _hoverRow(tester);
    await tester.tap(_trash);
    await tester.pump();

    await tester.tap(find.text('删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(core.sessionIndex, isEmpty);
    expect(c.sidebarSessions, isEmpty);
    expect(find.byType(SidebarSessionRow), findsNothing);
    expect(find.byType(DeleteSessionConfirm), findsNothing);
    expect(c.confirmingDeleteId, isNull);
  });

  testWidgets('点弹层之外：弹层关掉，「正在确认」也清掉（行不卡在悬浮态）', (tester) async {
    final (c, core) = await _pumpShell(tester);
    final mouse = await _hoverRow(tester);
    await tester.tap(_trash);
    await tester.pump();
    expect(find.byType(DeleteSessionConfirm), findsOneWidget);

    // 蒙层盖住整屏：点转录区那边就是「点外面」。
    await tester.tapAt(const Offset(1000, 700));
    await mouse.moveTo(const Offset(1000, 700));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(DeleteSessionConfirm), findsNothing);
    expect(c.confirmingDeleteId, isNull, reason: '不清掉这一行会一直停在悬浮态');
    expect(core.sessionIndex, hasLength(1), reason: '点外面只是关弹层，不能顺手删了');
    expect(_trash, findsNothing, reason: '鼠标已经不在行上，行内动作要收回去');
  });
}
