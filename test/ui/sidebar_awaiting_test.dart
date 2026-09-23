// 画板 09 · 等你处理的 UI 接线：后台会话卡在权限请求上时，侧栏那一行出「待授权」、扫掠亮点停下而行高不变，
// 顶栏切换钮出等你徽标；回应之后标记淡出、扫掠回来、徽标换回在跑数。另验切换器每一行的两枚徽标与触发钮的整句 tooltip。
// 这正是 BACKLOG 那两条「挂着请求、界面上没痕迹」的回归：请求所属的会话**不是**当前会话（画板 26 的停靠条管不到它）。

import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/app/workbench_screen.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/popovers/topbar_popovers.dart';
import 'package:acp_agent_client/ui/shell/running_badge.dart';
import 'package:acp_agent_client/ui/shell/sidebar.dart';
import 'package:acp_agent_client/ui/shell/tooltip.dart';
import 'package:acp_agent_client/ui/shell/topbar.dart';
import 'package:acp_agent_client/ui/transcript/awaiting_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../app/fake_core.dart';
import '../gallery_harness.dart';

const String _agent = 'a';
const String _session = 'sess_bg';
const String _cwd = 'D:/repo';

/// 扫掠亮点线是私有 widget，按类型名找（画板 06 A）。
final Finder _sweep = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_SessionSweepLine');

Finder _tooltip(String message) => find.byWidgetPredicate((w) => w is AcpTooltip && w.message == message);

void main() {
  testWidgets('后台会话挂着权限请求：侧栏出「待授权」、亮点停下、行高仍 58，切换钮出等你徽标；回应后复原', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(loadGalleryFonts);

    final core = FakeCore();
    await core.sessionIndexUpsert(<String, dynamic>{
      'agentId': _agent,
      'sessionId': _session,
      'title': '整理构建脚本',
      'cwd': _cwd,
      'messageCount': 8,
    });
    final c = WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask);
    addTearDown(c.dispose);
    // start() 才把会话表接到控制器的通知上（后台会话来了请求，侧栏与顶栏要跟着重画）。项目在它之后设，免得被恢复逻辑覆盖。
    await tester.runAsync(c.start);
    c.workspace.project = const ProjectRef(path: _cwd, name: 'repo');
    await c.index.refresh();

    // 当前会话是空的（sessionId == null）：这条是后台会话，停靠条不管它。
    final store = c.sessions.session(_session, agentId: _agent)..cwd = _cwd;
    store.startTurn(<ContentBlockWire>[
      const ContentBlockWire(<String, dynamic>{'type': 'text', 'text': 'go'}),
    ]);

    await tester.pumpWidget(MaterialApp(home: WorkbenchScreen(controller: c)));
    await tester.pump();
    expect(_sweep, findsOneWidget, reason: '在跑：扫掠');
    expect(find.byType(RunningBadge), findsOneWidget);

    c.sessions.applyClientRequestEnvelope(<String, dynamic>{
      'agentId': _agent,
      'requestId': 'req_perm',
      'method': 'session/request_permission',
      'params': <String, dynamic>{
        'sessionId': _session,
        'toolCall': <String, dynamic>{'toolCallId': 'call_1', 'title': '删文件'},
        'options': <Object?>[
          <String, dynamic>{'optionId': 'ok', 'name': 'Allow', 'kind': 'allow_once'},
        ],
      },
    });
    await tester.pump();
    await tester.pump(t.Motion.fast);

    expect(find.text('待授权'), findsOneWidget);
    expect(_sweep, findsNothing, reason: '等你处理期间亮点停下');
    expect(tester.getSize(find.byType(SidebarSessionRow)).height, t.Geometry.sidebarRowRunning, reason: '行高不因等你改变');
    expect(find.byType(AwaitingBadge), findsOneWidget, reason: '切换钮出等你徽标');
    expect(find.byType(RunningBadge), findsNothing, reason: '等你的会话不再计入在跑数');
    expect(_tooltip('1 个会话等你处理 · 1 个工作区'), findsOneWidget);

    store.answerPermission('req_perm', 'ok');
    await tester.pump();
    expect(_sweep, findsOneWidget, reason: '回应后同帧恢复扫掠');
    expect(find.byType(RunningBadge), findsOneWidget);
    expect(find.byType(AwaitingBadge), findsNothing);
    await tester.pump(t.Motion.fast * 2);
    expect(find.text('待授权'), findsNothing, reason: '标记淡出后从布局里移除');
  });

  testWidgets('会话项：待输入换图标与文字；给了在跑也以等你为准（三者互斥）', (tester) async {
    await tester.runAsync(() async {
      await loadGalleryFonts();
      await precacheIcons();
    });
    final session = SidebarSession(id: 's', title: '迁移 settings.json 的读取', updatedAt: DateTime.utc(2026, 9, 23), messageCount: 6);
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(400, 200)),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: t.Geometry.sidebarWidth,
            child: SidebarSessionRow(session, now: DateTime.utc(2026, 9, 23), running: true, unread: true, awaiting: AwaitingKind.input),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('待输入'), findsOneWidget);
    expect(find.text('待授权'), findsNothing);
    expect(_sweep, findsNothing);
  });

  testWidgets('切换器：等你与在跑各自挂在所属那一行、各有 tooltip；触发钮整句省略为 0 的那段', (tester) async {
    await tester.runAsync(() async {
      await loadGalleryFonts();
      await precacheIcons();
    });
    const ProjectRef open = ProjectRef(path: r'D:\repo-a', name: 'repo-a');
    const List<ProjectRef> recent = <ProjectRef>[
      ProjectRef(path: r'D:\repo-b', name: 'repo-b'),
      ProjectRef(path: r'D:\repo-c', name: 'repo-c'),
    ];
    final running = <String, int>{r'D:\repo-a': 1, r'D:\repo-b': 1};
    final awaiting = <String, int>{r'D:\repo-b': 1, r'D:\repo-c': 2};
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(800, 600)),
        child: Overlay(
          initialEntries: <OverlayEntry>[
            OverlayEntry(
              builder: (_) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const TopBar(projectName: 'repo-a', windowControls: false, awaitingTotal: 3, activeWorkspaces: 2),
                  ProjectSwitcherPopover(
                    openProjects: const <ProjectRef>[open],
                    recentProjects: recent,
                    currentPath: open.path,
                    searchController: TextEditingController(),
                    searchFocusNode: FocusNode(),
                    runningOf: (p) => running[p.path] ?? 0,
                    awaitingOf: (p) => awaiting[p.path] ?? 0,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();

    // 触发钮：只有等你（在跑为 0 的那段省略）。切换器：repo-b 两枚并排，repo-c 只有等你，repo-a 只有在跑。
    expect(_tooltip('3 个会话等你处理 · 2 个工作区'), findsOneWidget);
    expect(find.byType(AwaitingBadge), findsNWidgets(3));
    expect(find.byType(RunningBadge), findsNWidgets(2));
    expect(_tooltip('该工作区 1 个会话等你处理'), findsOneWidget);
    expect(_tooltip('该工作区 2 个会话等你处理'), findsOneWidget);
    expect(_tooltip('该工作区 1 个会话在运行'), findsNWidgets(2));

    // 并排时等你在左、在跑在右。
    final row = find.ancestor(of: _tooltip('该工作区 1 个会话等你处理'), matching: find.byType(ActivityBadges));
    final left = tester.getCenter(find.descendant(of: row, matching: find.byType(AwaitingBadge))).dx;
    final right = tester.getCenter(find.descendant(of: row, matching: find.byType(RunningBadge))).dx;
    expect(left, lessThan(right));
  });
}
