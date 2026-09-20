// 线程头「新建会话 · 选 agent」弹层（画板 01 的 + 与画板 41 的弹层）的 UI 接线回归测试。
// 所有者手测 2026-09-17 报了两件事：① 有时候点 + 没反应；② 出得来的时候选择框被窗口右边缘截断。
// ① 的成因是元素重建把 OverlayPortalController 解绑（见 PopoverHandle._visible 的注释）——
//    连上 agent 后线程头多出铅笔与重载两个按钮，没写 key 的 PopoverAnchor 元素随之拆建，
//    此后 show() 没人渲染、isShowing 还在一开一关地翻，表现就是一次不出一次不出。
// ② 是弹层左对齐在 + 上，而 + 贴着窗口右边缘。

import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/app/workbench_screen.dart';
import 'package:acp_agent_client/ui/popovers/topbar_popovers.dart';
import 'package:acp_agent_client/ui/transcript/card_chrome.dart';
import 'package:acp_agent_client/ui/transcript/icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../app/fake_core.dart';
import '../gallery_harness.dart';

const Size _window = Size(1440, 900);

final Finder _plus = find.byWidgetPredicate((w) => w is IconButtonGhost && w.icon == AcpIcons.plusSquare);
final Finder _popover = find.byType(NewSessionAgentPopover);

Future<WorkbenchController> _pumpShell(WidgetTester tester) async {
  tester.view.physicalSize = _window;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // flutter_tester 不装包字体也不做 CJK 回退，缺字体时会算宽撑破（gallery_harness 的注释）。
  await tester.runAsync(loadGalleryFonts);

  final c = WorkbenchController(source: DataSource.bridge, bridge: FakeCore(), scheduler: WorkbenchController.scheduleOnMicrotask)
    ..workspace.project = const ProjectRef(path: 'D:/repo', name: 'repo')
    ..installedAgents = const <AgentRef>[AgentRef(id: 'zed', name: 'Zed Agent')];
  addTearDown(c.dispose);

  await tester.pumpWidget(MaterialApp(home: WorkbenchScreen(controller: c)));
  await tester.pump();
  return c;
}

void main() {
  testWidgets('建完会话后再点 +：弹层照样出得来（锚点元素重建不该把它烙死）', (tester) async {
    final c = await _pumpShell(tester);

    await tester.tap(_plus);
    await tester.pump();
    expect(_popover, findsOneWidget);

    // 选一个 agent → 连上 → hasAgent 翻 true → 线程头多出铅笔与重载，+ 的锚点元素被拆掉重建。
    await tester.tap(find.text('Zed Agent'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.hasAgent, isTrue);
    expect(c.newSessionAnchor.isShowing, isFalse, reason: '建完会话要收起来');
    expect(_popover, findsNothing);

    await tester.tap(_plus);
    await tester.pump();
    expect(c.newSessionAnchor.isShowing, isTrue);
    expect(_popover, findsOneWidget, reason: 'controller 被旧元素解绑的话这里只翻标志位、不渲染');
  });

  testWidgets('弹层右对齐在 + 上：不越出窗口右边缘', (tester) async {
    await _pumpShell(tester);
    await tester.tap(_plus);
    await tester.pump();

    final plus = tester.getRect(_plus);
    final popover = tester.getRect(_popover);
    expect(popover.right, lessThanOrEqualTo(_window.width), reason: '越界就是所有者看到的「被截断」');
    expect(popover.left, greaterThanOrEqualTo(0));
    expect(popover.right, moreOrLessEquals(plus.right, epsilon: 0.5), reason: '右边对齐 + 按钮');
    expect(popover.top, greaterThanOrEqualTo(plus.bottom), reason: '在 + 底下展开');
  });
}
