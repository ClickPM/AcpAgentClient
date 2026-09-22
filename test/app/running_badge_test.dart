// 画板 08 C · 跨工作区在跑数：计数口径（按会话、按归一化 cwd 分组、合计含当前）与徽标的三态。
//
// 口径的关键前提是「换项目不关会话」（`SessionController.enterWorkspace` 的注释：放下不等于关掉），
// 所以这里的用例真的去换一次项目，验的是「切走之后那条仍计在原工作区名下」。

import 'dart:async';

import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/app/workspace_state.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/ui/popovers/topbar_popovers.dart';
import 'package:acp_agent_client/ui/shell/running_badge.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../gallery_harness.dart';
import 'fake_core.dart';

/// `session/prompt` 挂住不回：这样那一轮一直算「在跑」。
/// 另外给每条 `session/new` 发一个不同的 id —— `FakeCore` 默认回固定的 `sess_fake`，
/// 那样三次新建其实是同一条会话，这个用例就什么都没验到。
class _GatedCore extends FakeCore {
  final Map<String, Completer<JsonMap>> gates = <String, Completer<JsonMap>>{};
  int _seq = 0;

  @override
  Future<JsonMap> sessionNew(String agentId, String cwd) async => <String, dynamic>{'sessionId': 'sess_${++_seq}'};

  @override
  Future<JsonMap> sessionPrompt(String agentId, String sessionId, List<Object?> prompt) {
    prompts.add(prompt);
    return (gates[sessionId] ??= Completer<JsonMap>()).future;
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 在 [path] 这个项目里开一条会话并发一条消息（不回，于是一直在跑）。
Future<String> _startRunning(WorkbenchController c, _GatedCore core, String path) async {
  c.workspace.project = ProjectRef(path: path, name: path);
  await c.session.newSession(const AgentRef(id: 'a', name: 'a'));
  final sid = c.session.sessionId!;
  c.composer.editor.text = 'go';
  unawaited(c.turn.send());
  await _settle();
  return sid;
}

void main() {
  group('计数口径', () {
    test('按会话计数、按归一化 cwd 分组；换项目之后原工作区那条仍在跑', () async {
      final core = _GatedCore();
      final c = WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask);

      await _startRunning(c, core, r'D:\repo-a');
      await _startRunning(c, core, r'D:\repo-a'); // 同一个工作区第二条
      final sidB = await _startRunning(c, core, r'D:\repo-b');

      expect(c.session.runningTotal, 3);
      expect(c.session.runningWorkspaceCount, 2);
      expect(c.session.runningByWorkspace[WorkspaceState.normalizeCwd(r'D:\repo-a')], 2);
      expect(c.session.runningByWorkspace[WorkspaceState.normalizeCwd(r'D:\repo-b')], 1);

      // 同一目录的另一种写法（分隔符 / 尾斜杠 / 大小写）算同一个工作区。
      expect(c.session.runningByWorkspace[WorkspaceState.normalizeCwd('d:/repo-a/')], 2);

      // 那条跑完了就不再计入。
      core.gates[sidB]!.complete(<String, dynamic>{'stopReason': 'end_turn'});
      await _settle();
      expect(c.session.runningTotal, 2);
      expect(c.session.runningWorkspaceCount, 1);
      expect(c.session.runningByWorkspace.containsKey(WorkspaceState.normalizeCwd(r'D:\repo-b')), isFalse);
      c.dispose();
    });

    test('一条都没在跑时是空表、合计 0', () async {
      final core = FakeCore();
      final c = WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask)
        ..workspace.project = const ProjectRef(path: r'D:\repo', name: 'repo');
      await c.session.newSession(const AgentRef(id: 'a', name: 'a'));
      expect(c.session.runningTotal, 0);
      expect(c.session.runningByWorkspace, isEmpty);
      c.dispose();
    });
  });

  group('徽标', () {
    test('0 不渲染；> 99 显示 99+', () {
      expect(RunningBadge.maybe(0), isNull);
      expect(RunningBadge.maybe(-1), isNull);
      expect(RunningBadge.maybe(1), isNotNull);
      expect(RunningBadge.label(1), '1');
      expect(RunningBadge.label(12), '12');
      expect(RunningBadge.label(99), '99');
      expect(RunningBadge.label(100), '99+');
    });

    testWidgets('切换器里每一行按 runningOf 挂徽标，为 0 的行不挂', (tester) async {
      await tester.runAsync(() async {
        await loadGalleryFonts();
        await precacheIcons();
      });
      const ProjectRef open = ProjectRef(path: r'D:\repo-a', name: 'repo-a');
      const List<ProjectRef> recent = <ProjectRef>[
        ProjectRef(path: r'D:\repo-b', name: 'repo-b'),
        ProjectRef(path: r'D:\repo-c', name: 'repo-c'),
      ];
      final counts = <String, int>{r'D:\repo-a': 1, r'D:\repo-b': 2};
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(600, 600)),
            child: Overlay(
              initialEntries: <OverlayEntry>[
                OverlayEntry(
                  builder: (_) => Align(
                    alignment: Alignment.topLeft,
                    child: ProjectSwitcherPopover(
                      openProjects: const <ProjectRef>[open],
                      recentProjects: recent,
                      currentPath: open.path,
                      searchController: TextEditingController(),
                      searchFocusNode: FocusNode(),
                      runningOf: (p) => counts[p.path] ?? 0,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Recent Projects 里的行也挂徽标（本次运行打开过、还有会话在跑）——这正是画板 08 改口径的那一条。
      expect(find.byType(RunningBadge), findsNWidgets(2));
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      // 没有在跑会话的那一行一个徽标都没有。
      expect(find.text('0'), findsNothing);
    });
  });
}
