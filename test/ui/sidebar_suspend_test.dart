// iteration-19 · 侧栏 Active 行的「挂起」（BACKLOG P1「会话菜单的 Resume / Close 没有入口」的收尾）：
// 挂起 = 把这一行那条会话交给 agent 的 `session/close`（核心侧就是先 cancel 再释放），本地转录留着只读，
// 它随即从 Active 区沉到 History；在 History 里点它那一行由 `selectSession` → `ensureLoaded` 挂回来
// （agent 声明了 `loadSession` 就 `session/load` 重放）。画板 45 的行内动作只画了改名与删除，
// 挂起是本迭代加上去的（design/DIVERGENCE.md A-37）。
//
// 守住四件事：给了「这条 agent 声明了 close」才出图标、只出在 Active 行上、点了打的是这条会话
// （不是当前会话）、挂起与挂回是同一条会话的同一条命令面。

import 'package:acp_agent_client/app/session_attach.dart';
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

const String _agent = 'test-agent';
const String _session = 'sess-1';
const String _cwd = 'D:/repo';

final DateTime _now = DateTime(2026, 9, 30, 12, 0);

/// 画板 45 + `session/close`：声明 `loadSession`（挂回来走重放）与可选的 `sessionCapabilities.close`
/// （挂起按钮的能力门）。`declareLoad = false` 造「只有 close、挂不回来」的 agent（挂起入口也不该出）。
class _SuspendCore extends FakeCore {
  _SuspendCore({this.declareClose = true, this.declareLoad = true});

  final bool declareClose;
  final bool declareLoad;

  @override
  Future<Map<String, dynamic>> agentConnect(String agentId, {String? cwd}) async => <String, dynamic>{
        'agentId': agentId,
        'initialize': <String, dynamic>{
          'agentCapabilities': <String, dynamic>{
            'loadSession': declareLoad,
            if (declareClose) 'sessionCapabilities': <String, dynamic>{'close': <String, dynamic>{}},
          },
        },
      };

  /// 索引里那条会话的 id：`session/new` 回同一个 id，用例可以先把它开成 Active 再验挂起的能力门
  /// （点 History 那条路对「只有 close」的 agent 挂不上，会是 unattachable，验不到能力门）。
  @override
  Future<Map<String, dynamic>> sessionNew(String agentId, String cwd) async => <String, dynamic>{'sessionId': _session};
}

final Finder _pauseIcon = find.byWidgetPredicate((w) => w is IconButtonGhost && w.icon == AcpIcons.pause);
final Finder _pencilIcon = find.byWidgetPredicate((w) => w is IconButtonGhost && w.icon == AcpIcons.pencil);
final Finder _trashIcon = find.byWidgetPredicate((w) => w is IconButtonGhost && w.icon == AcpIcons.trash);

SidebarSession _makeSession(String id, String title) => SidebarSession(
      id: id,
      title: title,
      updatedAt: _now.subtract(const Duration(minutes: 5)),
      messageCount: 3,
    );

/// 鼠标停在某一行上（行内动作只在悬浮时出）。
Future<TestGesture> _hoverRow(WidgetTester tester, String id) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  final row = find.byWidgetPredicate((w) => w is SidebarSessionRow && w.session.id == id);
  await mouse.moveTo(tester.getCenter(row));
  await tester.pump();
  return mouse;
}

/// 起壳：本地索引里一条会话，agent 尚未连过（第一次点选才连 + `session/load`）。
Future<(WorkbenchController, _SuspendCore)> _pumpShell(
  WidgetTester tester, {
  bool declareClose = true,
  bool declareLoad = true,
}) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.runAsync(loadGalleryFonts);

  final core = _SuspendCore(declareClose: declareClose, declareLoad: declareLoad);
  await core.sessionIndexUpsert(<String, dynamic>{
    'agentId': _agent,
    'sessionId': _session,
    'title': '测试会话',
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

/// 点侧栏里这一行（标题处的点击走 `onSelect`）。标题同时出现在会话头上，所以从行 widget 往下找。
Future<void> _tapRow(WidgetTester tester) async {
  final row = find.byWidgetPredicate((w) => w is SidebarSessionRow && w.session.id == _session);
  await tester.tap(find.descendant(of: row, matching: find.text('测试会话')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  group('侧栏挂起按钮的渲染（画板 45 行内动作扩展）', () {
    testWidgets('Active 且声明了 close：悬浮出挂起图标，点了把这一行的 id 交出来', (tester) async {
      await tester.runAsync(loadGalleryFonts);
      String? suspended;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Sidebar(
            sessions: <SidebarSession>[_makeSession('s1', '活跃会话')],
            activeIds: const <String>{'s1'},
            suspendableIds: const <String>{'s1'},
            now: _now,
            searchController: TextEditingController(),
            searchFocusNode: FocusNode(),
            onSuspend: (id) => suspended = id,
          ),
        ),
      ));
      await tester.pump();

      expect(_pauseIcon, findsNothing, reason: '行内动作只在悬浮时出');
      await _hoverRow(tester, 's1');
      expect(_pauseIcon, findsOneWidget);
      expect(_pencilIcon, findsOneWidget);
      expect(_trashIcon, findsOneWidget);

      await tester.tap(_pauseIcon);
      await tester.pump();
      expect(suspended, 's1');
    });

    testWidgets('agent 没声明 close（不进 suspendableIds）：Active 行不给挂起，改名 / 删除照给', (tester) async {
      await tester.runAsync(loadGalleryFonts);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Sidebar(
            sessions: <SidebarSession>[_makeSession('s1', '活跃会话')],
            activeIds: const <String>{'s1'},
            now: _now,
            searchController: TextEditingController(),
            searchFocusNode: FocusNode(),
            onSuspend: (_) {},
          ),
        ),
      ));
      await tester.pump();
      await _hoverRow(tester, 's1');

      expect(_pauseIcon, findsNothing);
      expect(_pencilIcon, findsOneWidget);
      expect(_trashIcon, findsOneWidget);
    });

    testWidgets('History 行不给挂起（挂起按钮只属于 Active 区）', (tester) async {
      await tester.runAsync(loadGalleryFonts);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Sidebar(
            sessions: <SidebarSession>[_makeSession('s1', '活跃会话'), _makeSession('s2', '历史会话')],
            activeIds: const <String>{'s1'},
            suspendableIds: const <String>{'s1'},
            now: _now,
            searchController: TextEditingController(),
            searchFocusNode: FocusNode(),
            onSuspend: (_) {},
          ),
        ),
      ));
      await tester.pump();
      await _hoverRow(tester, 's2');

      expect(_pauseIcon, findsNothing, reason: '历史会话要「启动」就点它自己那一行，不用先挂起');
      expect(find.text('历史会话'), findsOneWidget);
    });
  });

  group('挂起 → History → 点它挂回来（与 SessionAttachment 联动）', () {
    testWidgets('挂起打到这条会话的 session/close 上，它沉到 History；再点那一行走 load 挂回', (tester) async {
      final (c, core) = await _pumpShell(tester);

      // 点 History 里那一行：连 agent + session/load，升到 Active
      await _tapRow(tester);
      expect(c.session.attachOf(_session), SessionAttach.attached);
      expect(c.session.suspendableSessionIds, contains(_session));

      // 悬浮出挂起图标，点它
      await _hoverRow(tester, _session);
      expect(_pauseIcon, findsOneWidget);
      await tester.tap(_pauseIcon);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(core.closedSessions, <(String, String)>[(_agent, _session)],
          reason: '挂起就是这条会话的 session/close（先 cancel 再释放）');
      expect(c.session.sessionClosed, isTrue);
      expect(c.session.attachOf(_session), SessionAttach.detached);
      expect(c.session.attachedSessionIds, isNot(contains(_session)));
      expect(c.session.suspendableSessionIds, isEmpty, reason: '挂起过的会话不再是 Active 行');
      expect(find.text('暂无已连接会话 · 点选下方历史自动载入'), findsOneWidget);

      // 再点 History 里那一行：挂回来（声明了 loadSession 就走重放）
      final loadsBefore = core.loadedSessions.length;
      await _tapRow(tester);

      expect(core.loadedSessions.length, loadsBefore + 1);
      expect(c.session.sessionClosed, isFalse);
      expect(c.session.attachOf(_session), SessionAttach.attached);
      expect(c.session.attachedSessionIds, contains(_session));
      expect(c.session.suspendableSessionIds, contains(_session));
    });

    testWidgets('agent 没声明 close 时，挂起的入口整个不存在（能力门按这条会话自己的 agent 判）', (tester) async {
      final (c, core) = await _pumpShell(tester, declareClose: false);

      await _tapRow(tester);
      expect(c.session.attachOf(_session), SessionAttach.attached, reason: '照样能挂上（loadSession 有）');
      expect(c.session.canSuspendSession(_session), isFalse);
      expect(c.session.suspendableSessionIds, isEmpty);

      await _hoverRow(tester, _session);
      expect(_pauseIcon, findsNothing);
      expect(core.closedSessions, isEmpty, reason: '没有入口就不该有 session/close 出去');
    });

    testWidgets('只声明了 close、挂不回来的 agent：会话真挂在 Active 上也不给挂起入口', (tester) async {
      final (c, core) = await _pumpShell(tester, declareLoad: false);

      // 先让它真的 attached：走 session/new 那条路。点 History 那一行对「只有 close」的 agent 挂不上
      // （attachOf 会落到 unattachable），那样验的是「不在 Active」那一项，验不到「挂得回来」这个新条件
      // （审查 R2 P2：旧写法把新条件删掉照样绿）。
      await c.session.connectAgent(_agent, _cwd);
      await c.session.createSession(_agent, _cwd);
      await tester.pump();

      expect(c.session.attachOf(_session), SessionAttach.attached, reason: '挂在活着的连接上、转录在内存里');
      expect(c.session.attachedSessionIds, contains(_session));
      // 去掉 canSuspendSession 里「挂得回来」那个条件，这一条就会红（attached + close 都满足）
      expect(c.session.canSuspendSession(_session), isFalse, reason: '挂不回来的不给「挂起」这个名字');
      expect(c.session.suspendableSessionIds, isEmpty);

      await _hoverRow(tester, _session);
      expect(_pauseIcon, findsNothing);
      expect(core.closedSessions, isEmpty);
    });
  });
}
