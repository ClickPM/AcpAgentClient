// 画板 46 · 侧栏 PINNED 分区与首条用户指令悬停卡片。
// 守住：挂着的置顶会话留在 ACTIVE；没挂上的置顶按 pinnedAt 倒序聚在 PINNED，不进 HISTORY；
// HISTORY 折叠不收走 PINNED；行内第一枚是置顶；有首条指令才在 150ms 后出卡片，点击不吃命中。

import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/shell/sidebar.dart';
import 'package:acp_agent_client/ui/shell/tooltip.dart';
import 'package:acp_agent_client/ui/transcript/card_chrome.dart';
import 'package:acp_agent_client/ui/transcript/icons.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../gallery_harness.dart';

final DateTime _now = DateTime(2026, 10, 10, 12);

SidebarSession _session(
  String id,
  String title, {
  bool pinned = false,
  DateTime? pinnedAt,
  String? firstPrompt,
  String? agentName,
}) =>
    SidebarSession(
      id: id,
      title: title,
      updatedAt: _now.subtract(const Duration(minutes: 8)),
      messageCount: 4,
      isPinned: pinned,
      pinnedAt: pinnedAt,
      firstPrompt: firstPrompt,
      agentName: agentName,
    );

Future<void> _pump(WidgetTester tester, Sidebar sidebar) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: t.Geometry.sidebarWidth, child: sidebar))));
  await tester.pump();
}

Future<TestGesture> _hover(WidgetTester tester, String id) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  final row = find.byWidgetPredicate((w) => w is SidebarSessionRow && w.session.id == id);
  await mouse.moveTo(tester.getCenter(row));
  await tester.pump();
  return mouse;
}

void main() {
  setUpAll(() async {
    await loadGalleryFonts();
  });

  testWidgets('三区分组：挂着的置顶留在 ACTIVE，其余置顶按 pinnedAt 倒序，不进 HISTORY', (tester) async {
    final activePinned = _session('a', '在线但已置顶', pinned: true, pinnedAt: _now);
    final newer = _session('n', '较新的置顶', pinned: true, pinnedAt: _now.subtract(const Duration(minutes: 1)));
    final older = _session('o', '较早的置顶', pinned: true, pinnedAt: _now.subtract(const Duration(hours: 2)));
    final history = _session('h', '普通历史');

    await _pump(
      tester,
      Sidebar(
        sessions: <SidebarSession>[history, older, activePinned, newer],
        activeIds: const <String>{'a'},
        now: _now,
        searchController: TextEditingController(),
        searchFocusNode: FocusNode(),
      ),
    );

    expect(find.text('PINNED'), findsOneWidget);
    expect(tester.getTopLeft(find.text('ACTIVE')).dy, lessThan(tester.getTopLeft(find.text('在线但已置顶')).dy));
    expect(tester.getTopLeft(find.text('在线但已置顶')).dy, lessThan(tester.getTopLeft(find.text('PINNED')).dy));
    expect(tester.getTopLeft(find.text('PINNED')).dy, lessThan(tester.getTopLeft(find.text('较新的置顶')).dy));
    expect(tester.getTopLeft(find.text('较新的置顶')).dy, lessThan(tester.getTopLeft(find.text('较早的置顶')).dy));
    expect(tester.getTopLeft(find.text('较早的置顶')).dy, lessThan(tester.getTopLeft(find.text('HISTORY')).dy));
    expect(tester.getTopLeft(find.text('HISTORY')).dy, lessThan(tester.getTopLeft(find.text('普通历史')).dy));
  });

  testWidgets('没有置顶时不画 PINNED；HISTORY 折叠不收走置顶行', (tester) async {
    await _pump(
      tester,
      Sidebar(
        sessions: <SidebarSession>[_session('h', '普通历史')],
        now: _now,
        searchController: TextEditingController(),
        searchFocusNode: FocusNode(),
      ),
    );
    expect(find.text('PINNED'), findsNothing);

    await _pump(
      tester,
      Sidebar(
        sessions: <SidebarSession>[
          _session('p', '置顶历史', pinned: true, pinnedAt: _now),
          _session('h', '普通历史'),
        ],
        historyCollapsed: true,
        now: _now,
        searchController: TextEditingController(),
        searchFocusNode: FocusNode(),
      ),
    );
    expect(find.text('置顶历史'), findsOneWidget);
    expect(find.text('普通历史'), findsNothing);
    expect(find.textContaining('已折叠'), findsNothing);
  });

  testWidgets('悬浮第一枚是置顶；已置顶是实心图钉，点了把 id 交出去', (tester) async {
    String? toggled;
    await _pump(
      tester,
      Sidebar(
        sessions: <SidebarSession>[_session('p', '置顶历史', pinned: true, pinnedAt: _now)],
        now: _now,
        searchController: TextEditingController(),
        searchFocusNode: FocusNode(),
        onTogglePin: (id) => toggled = id,
      ),
    );

    expect(find.byWidgetPredicate((w) => w is IconButtonGhost && w.icon == AcpIcons.pinFilled), findsNothing);
    await _hover(tester, 'p');
    final buttons = tester.widgetList<IconButtonGhost>(find.byType(IconButtonGhost)).toList();
    expect(buttons.first.icon, AcpIcons.pinFilled);
    expect(buttons.first.color, t.Accent.base);
    expect(
      tester.widgetList<AcpTooltip>(find.byType(AcpTooltip)).map((tip) => tip.message),
      contains('Unpin session'),
    );
    await tester.tap(find.byWidgetPredicate((w) => w is IconButtonGhost && w.icon == AcpIcons.pinFilled));
    expect(toggled, 'p');
  });

  testWidgets('有首条指令才在悬停后出卡片，卡片不吃点击', (tester) async {
    await _pump(
      tester,
      Sidebar(
        sessions: <SidebarSession>[
          _session('p', '有指令', firstPrompt: '请把侧栏分成三区\n并记住这句', agentName: 'Codex'),
          _session('q', '无指令'),
        ],
        now: _now,
        searchController: TextEditingController(),
        searchFocusNode: FocusNode(),
      ),
    );

    final mouse = await _hover(tester, 'q');
    await tester.pump(t.QueryPreview.hoverDelay);
    expect(find.text('INITIAL QUERY'), findsNothing);

    final row = find.byWidgetPredicate((w) => w is SidebarSessionRow && w.session.id == 'p');
    await mouse.moveTo(tester.getCenter(row));
    await tester.pump();
    await tester.pump(t.QueryPreview.hoverDelay);
    expect(find.text('INITIAL QUERY'), findsOneWidget);
    expect(find.textContaining('请把侧栏分成三区'), findsOneWidget);
    expect(find.text('Agent: Codex'), findsOneWidget);
    final blockers = tester.widgetList<IgnorePointer>(
      find.ancestor(of: find.text('INITIAL QUERY'), matching: find.byType(IgnorePointer)),
    );
    expect(blockers.any((w) => w.ignoring), isTrue, reason: '卡片不吃点击');
  });
}
