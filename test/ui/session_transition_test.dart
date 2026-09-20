// 画板 05 B 组「带等待期的替换」的接线回归测试。
// 所有者手测 2026-09-18：会话头 + 选完 agent 之后，到新会话真的出来这几秒界面一动不动
// （「比较生硬」「reload 会话至少能看到灰色蒙层和 loading」）。成因是等待态只接到 reloadAgent 上，
// newSession 那条路从头到尾不翻任何标志，于是拉进程 + initialize + session/new 全程零反馈。
// 这里守两件事：等待期内转录区降到 opacity.pending 且不可交互、会话头转 spinner；会话到手后全部收掉。

import 'dart:async';

import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/app/workbench_screen.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/popovers/topbar_popovers.dart';
import 'package:acp_agent_client/ui/shell/session_header.dart';
import 'package:acp_agent_client/ui/transcript/card_chrome.dart';
import 'package:acp_agent_client/ui/transcript/icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../app/fake_core.dart';
import '../gallery_harness.dart';

const Size _window = Size(1440, 900);

final Finder _plus = find.byWidgetPredicate((w) => w is IconButtonGhost && w.icon == AcpIcons.plusSquare);
final Finder _body = find.byType(AnimatedOpacity);
final Finder _headerSpinner = find.descendant(of: find.byType(SessionHeader), matching: find.byType(Spinner));

/// `agent_connect` 挂在 [gate] 上不返回：拉起 agent 进程那几秒就是这个样子。
class _GatedCore extends FakeCore {
  Completer<void>? _gate;

  /// 重载 agent 会先 `agent_disconnect`：用它判断重入守卫有没有真的挡住。
  final List<String> disconnects = <String>[];

  void hold() => _gate = Completer<void>();

  void release() {
    final gate = _gate;
    _gate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  /// 拉起过几次进程：重入守卫真挡住了就只有一次。
  int connects = 0;

  @override
  Future<JsonMap> agentConnect(String agentId, {String? cwd}) async {
    connects++;
    await _gate?.future;
    return super.agentConnect(agentId, cwd: cwd);
  }

  @override
  Future<JsonMap> agentDisconnect(String agentId) async {
    disconnects.add(agentId);
    return super.agentDisconnect(agentId);
  }

  /// 建完会话 `refreshRegistry()` 会按这份设置重算 `installedAgents`，默认的空表会把弹层清空。
  @override
  Future<JsonMap> agentSettingsGet() async => <String, dynamic>{
        'agent_servers': <String, dynamic>{
          'zed': <String, dynamic>{'type': 'custom', 'command': 'zed-agent-acp', 'name': 'Zed Agent'},
        },
      };
}

/// 转录区那一层的目标不透明度（画板 05 B 组阶段 ①/②：`opacity.pending`）。
double _bodyOpacity(WidgetTester tester) => tester.widget<AnimatedOpacity>(_body).opacity;

/// 转录区是否被挡住不可交互（同一阶段的「不响应点击」）。
bool _bodyIgnoring(WidgetTester tester) => tester
    .widgetList<IgnorePointer>(find.ancestor(of: _body, matching: find.byType(IgnorePointer)))
    .any((IgnorePointer w) => w.ignoring);

/// 会话头 + → 弹层里点一个 agent。返回后 `newSession` 已经在途（门关着就停在 `agent_connect` 上）。
Future<void> _pickAgent(WidgetTester tester) async {
  await tester.tap(_plus);
  await tester.pump();
  await tester.tap(find.text('Zed Agent'));
  await tester.pump();
}

Future<WorkbenchController> _pumpShell(WidgetTester tester, _GatedCore core) async {
  tester.view.physicalSize = _window;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // flutter_tester 不装包字体也不做 CJK 回退，缺字体时会算宽撑破（gallery_harness 的注释）。
  await tester.runAsync(loadGalleryFonts);

  final c = WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask)
    ..workspace.project = const ProjectRef(path: 'D:/repo', name: 'repo')
    ..agents.installed = const <AgentRef>[AgentRef(id: 'zed', name: 'Zed Agent')];
  addTearDown(c.dispose);

  await tester.pumpWidget(MaterialApp(home: WorkbenchScreen(controller: c)));
  await tester.pump();
  return c;
}

void main() {
  testWidgets('会话头 + 选完 agent：会话还没到手就先进等待态（转录变暗不可点 + 会话头 spinner）', (tester) async {
    final core = _GatedCore();
    final c = await _pumpShell(tester, core);

    expect(_bodyOpacity(tester), 1, reason: '静止态不该是暗的');
    expect(_headerSpinner, findsNothing);

    core.hold();
    await _pickAgent(tester);
    // 弹层收起、等待态摆出来：`agent_connect` 还挂在门上，会话一时半会儿不会到。
    await tester.pump(t.Motion.fast);

    expect(c.session.waitingForAgent, isTrue);
    expect(c.session.sessionId, isNull, reason: '门还没开，会话确实还没建出来');
    expect(_bodyOpacity(tester), t.Opacities.pending, reason: '所有者报的就是这一下没有：选完 agent 之后界面一动不动');
    expect(_bodyIgnoring(tester), isTrue, reason: '等待期不响应点击（画板 05 B 组阶段 ①）');
    expect(_headerSpinner, findsOneWidget, reason: '借用已有那只 spinner，不新增元素');

    core.release();
    await tester.pump();
    await tester.pump(t.Motion.transition);

    expect(c.session.sessionId, 'sess_fake');
    expect(c.session.waitingForAgent, isFalse);
    expect(_bodyOpacity(tester), 1, reason: '阶段 ③：等待态收掉，亮度回 1');
    expect(_headerSpinner, findsNothing);
  });

  testWidgets('新会话在途时点重载：重入守卫照样挡住，不让 disconnect 撞上正在跑的 session/new', (tester) async {
    final core = _GatedCore();
    final c = await _pumpShell(tester, core);

    // 先有一条会话在手（重载按钮要 `hasSession` 才画出来），再开第二条把等待期支起来。
    await _pickAgent(tester);
    await tester.pump(t.Motion.transition);
    expect(c.session.sessionId, 'sess_fake');

    core.hold();
    await _pickAgent(tester);
    expect(c.session.waitingForAgent, isTrue);

    await c.session.reloadAgent();
    expect(core.disconnects, isEmpty, reason: '守卫判据换成 waitingForAgent 之后，新会话在途也算等待期');

    core.release();
    await tester.pump();
    await tester.pump(t.Motion.transition);
    expect(c.session.waitingForAgent, isFalse);
  });

  testWidgets('新会话在途时再选一次 agent：第二条被守卫挡住，只拉一次进程，等待态在会话到手后收掉', (tester) async {
    final core = _GatedCore();
    final c = await _pumpShell(tester, core);

    core.hold();
    await _pickAgent(tester);
    expect(c.session.waitingForAgent, isTrue);
    expect(core.connects, 1);

    // 等待期里会话头的 `+` 仍可点：再选一次。没有守卫的话第二条会再 `agent_connect` 一次（把第一条刚拉起的进程断掉），
    // 而且它存下的 wasWaiting 是 true，后返回时把等待态永久留在 true（发布前审查 P2，2026-09-18）。
    await _pickAgent(tester);
    expect(core.connects, 1, reason: '第二条 newSession 被重入守卫挡在门外');

    core.release();
    await tester.pump();
    await tester.pump(t.Motion.transition);
    expect(c.session.sessionId, 'sess_fake');
    expect(c.session.waitingForAgent, isFalse, reason: '等待态不能被交叠的第二条留在 true');
  });
}
