// 画板 45 · 侧栏 Active（已连接）与 History（历史会话）分组展示及折叠收纳测试。
// 守住核心契约：
// 1. 明确区分 ACTIVE 与 HISTORY 两大分组，连接状态由在线绿标表达，行内不重复「已连接」文字；
// 2. HISTORY 支持点击一键折叠/展开；折叠状态下绝无“已折叠”多余文字；
// 3. 搜索过滤保持分组拓扑上下文；
// 4. 冷启动/未连接空态轻量提示；
// 5. 与 SessionAttachment 挂载生命周期联动（History 点击挂载升格，断开/关闭沉降）。

import 'package:acp_agent_client/app/session_attach.dart';
import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/app/workbench_screen.dart';
import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/popovers/topbar_popovers.dart';
import 'package:acp_agent_client/ui/shell/sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../app/fake_core.dart';
import '../gallery_harness.dart';

class _AttachCore extends FakeCore {
  @override
  Future<Map<String, dynamic>> agentConnect(String agentId, {String? cwd}) async => <String, dynamic>{
        'agentId': agentId,
        'initialize': <String, dynamic>{
          'agentCapabilities': <String, dynamic>{
            'loadSession': true,
          },
        },
      };

  @override
  Future<Map<String, dynamic>> sessionLoad(String agentId, String sessionId, String cwd) async => <String, dynamic>{
        'sessionId': sessionId,
      };
}

final DateTime _now = DateTime(2026, 9, 29, 12, 0);

SidebarSession _makeSession(String id, String title, {int count = 2}) => SidebarSession(
      id: id,
      title: title,
      updatedAt: _now.subtract(const Duration(minutes: 5)),
      messageCount: count,
    );

void main() {
  setUpAll(() async {
    await loadGalleryFonts();
  });

  group('画板 45 · Sidebar 纯 UI 分组渲染', () {
    testWidgets('区分 ACTIVE 与 HISTORY 两个分组头及数量胶囊', (tester) async {
      final sActive = _makeSession('s1', '活跃会话');
      final sHistory = _makeSession('s2', '历史会话');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Sidebar(
              sessions: <SidebarSession>[sActive, sHistory],
              activeIds: const <String>{'s1'},
              now: _now,
              searchController: TextEditingController(),
              searchFocusNode: FocusNode(),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('ACTIVE'), findsOneWidget);
      expect(find.text('HISTORY'), findsOneWidget);

      // ACTIVE 数量为 1，HISTORY 数量为 1
      expect(find.text('1'), findsNWidgets(2));
      // 活跃项副标题不重复「已连接」，保留时间与消息数
      expect(find.textContaining('已连接'), findsNothing);
      expect(find.text('5 分钟前 · 2 条消息'), findsNWidgets(2));
      // 分组头包含 Connected 提示
      expect(find.text('Connected'), findsOneWidget);
    });

    testWidgets('Active 运行中展示 running 计数', (tester) async {
      final sActive = _makeSession('s1', '在跑会话');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Sidebar(
              sessions: <SidebarSession>[sActive],
              activeIds: const <String>{'s1'},
              runningIds: const <String>{'s1'},
              now: _now,
              searchController: TextEditingController(),
              searchFocusNode: FocusNode(),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('1 running'), findsOneWidget);
    });

    testWidgets('Active 为空时展示轻量提示行，HISTORY 正常展开', (tester) async {
      final sHistory = _makeSession('s2', '历史会话');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Sidebar(
              sessions: <SidebarSession>[sHistory],
              activeIds: const <String>{},
              now: _now,
              searchController: TextEditingController(),
              searchFocusNode: FocusNode(),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('ACTIVE'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
      expect(find.text('暂无已连接会话 · 点选下方历史自动载入'), findsOneWidget);
      expect(find.text('历史会话'), findsOneWidget);
    });

    testWidgets('HISTORY 折叠时不渲染列表项，且绝无“已折叠”多余文字', (tester) async {
      final sActive = _makeSession('s1', '活跃会话');
      final sHistory = _makeSession('s2', '历史会话');
      var toggleCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Sidebar(
              sessions: <SidebarSession>[sActive, sHistory],
              activeIds: const <String>{'s1'},
              historyCollapsed: true,
              onToggleHistoryCollapsed: () => toggleCount++,
              now: _now,
              searchController: TextEditingController(),
              searchFocusNode: FocusNode(),
            ),
          ),
        ),
      );
      await tester.pump();

      // 活跃会话渲染
      expect(find.text('活跃会话'), findsOneWidget);
      // 折叠后的历史会话不在树上
      expect(find.text('历史会话'), findsNothing);
      // 严格检查：绝无“已折叠”字样
      expect(find.textContaining('已折叠'), findsNothing);
      expect(find.textContaining('可折叠'), findsNothing);

      // 点击 HISTORY 分组头触发切换
      await tester.tap(find.text('HISTORY'));
      await tester.pump();
      expect(toggleCount, 1);
    });

    testWidgets('搜索过滤：保持 ACTIVE 与 HISTORY 双区分组上下文', (tester) async {
      final s1 = _makeSession('s1', 'pi active session');
      final s3 = _makeSession('s3', 'pi history session');

      var toggleCount = 0;
      final searchCtrl = TextEditingController(text: 'pi');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Sidebar(
              sessions: <SidebarSession>[s1, s3], // visibleSessions 只留匹配的
              activeIds: const <String>{'s1'},
              query: 'pi',
              historyCollapsed: true, // 搜索时即便之前折叠也临时展开
              onToggleHistoryCollapsed: () => toggleCount++,
              now: _now,
              searchController: searchCtrl,
              searchFocusNode: FocusNode(),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('ACTIVE'), findsOneWidget);
      expect(find.text('HISTORY'), findsOneWidget);
      expect(find.text('pi active session'), findsOneWidget);
      expect(find.text('pi history session'), findsOneWidget);
      // 搜索状态下不出现“暂无已连接”空态占位
      expect(find.text('暂无已连接会话 · 点选下方历史自动载入'), findsNothing);

      // 搜索期间点击 HISTORY 头不触发折叠切换（避免清空搜索后意外折叠）
      await tester.tap(find.text('HISTORY'));
      await tester.pump();
      expect(toggleCount, 0);
    });

    testWidgets('全部为空态时展示占位', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Sidebar(
              sessions: const <SidebarSession>[],
              now: _now,
              searchController: TextEditingController(),
              searchFocusNode: FocusNode(),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('还没有会话'), findsOneWidget);
    });

    test('onlineGlow 随主题动态取色且浅色无阴影', () {
      t.Theming.apply(t.AppTheme.light);
      expect(t.SidebarSection.onlineGlow, isNull);

      t.Theming.apply(t.AppTheme.dark);
      final glow = t.SidebarSection.onlineGlow;
      expect(glow, isNotNull);
      expect(glow!.first.color, t.Semantic.success.withValues(alpha: 0.45));

      // 恢复缺省
      t.Theming.reset();
    });
  });

  group('画板 45 · 工作台与生命周期联动', () {
    testWidgets('初始会话属于 History，挂载成功后升格至 Active', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      const agent = 'test-agent';
      const session = 'sess-1';
      const cwd = 'D:/repo';

      final core = _AttachCore();
      await core.sessionIndexUpsert(<String, dynamic>{
        'agentId': agent,
        'sessionId': session,
        'title': '测试会话',
        'cwd': cwd,
        'messageCount': 2,
      });

      final c = WorkbenchController(
        source: DataSource.bridge,
        bridge: core,
        scheduler: WorkbenchController.scheduleOnMicrotask,
      )..workspace.project = const ProjectRef(path: cwd, name: 'repo');
      await c.index.refresh();
      addTearDown(c.dispose);

      await tester.pumpWidget(MaterialApp(home: WorkbenchScreen(controller: c)));
      await tester.pump();

      // 刚启动，未连过 agent：会话尚未 attached，在 History 区
      expect(c.session.attachOf(session), SessionAttach.detached);
      expect(c.session.attachedSessionIds.contains(session), isFalse);

      // 点选该历史会话，触发 load / resume 挂载
      await tester.tap(find.text('测试会话'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 挂载成功后，进入 attached 状态并升入 Active
      expect(c.session.attachOf(session), SessionAttach.attached);
      expect(c.session.attachedSessionIds.contains(session), isTrue);
      final rowConnectedText = find.descendant(
        of: find.byType(SidebarSessionRow),
        matching: find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains('已连接')),
      );

      // 挂载后行内不重复显示已连接，在线标识仍由 attached 驱动
      expect(rowConnectedText, findsNothing);
      expect(tester.widgetList<SidebarSessionRow>(find.byType(SidebarSessionRow)).single.attached, isTrue);

      // 关闭会话后，解除挂载，沉降回 History 区，Active 区变为 0 态
      await c.session.closeSession();
      await tester.pump();
      expect(c.session.attachOf(session), SessionAttach.detached);
      expect(c.session.attachedSessionIds.contains(session), isFalse);
      expect(rowConnectedText, findsNothing);
      expect(find.text('暂无已连接会话 · 点选下方历史自动载入'), findsOneWidget);
    });
  });
}
