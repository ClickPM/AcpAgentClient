// 壳级提示（toast）在真工作台里的落点（设计稿之外的增补，所有者 2026-09-23 指图：会话头正下方、正文区顶部居中）：
// - 侧栏点开一条没载过的会话：连 agent / `session/load` 期间挂「会话正在加载中」，载完撤掉（BACKLOG「点开旧会话时没有正在载」）；
// - 失败（这里拿新建会话失败）：原先只进日志的那一句出现在同一处，到时间自己收（BACKLOG「失败没有出口」）。

import 'dart:async';

import 'package:acp_agent_client/app/core_bridge.dart';
import 'package:acp_agent_client/app/toasts.dart';
import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/app/workbench_screen.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/popovers/topbar_popovers.dart';
import 'package:acp_agent_client/ui/shell/session_header.dart';
import 'package:acp_agent_client/ui/shell/toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../app/fake_core.dart';
import '../gallery_harness.dart';

const Size _window = Size(1440, 900);
const String _agent = 'a';
const String _session = 'sess_1';
const String _title = '抖音优惠券满减门槛设计';
const String _cwd = 'D:/repo';

class _Core extends FakeCore {
  Completer<void>? connectGate;
  Object? newSessionError;

  @override
  Future<JsonMap> agentConnect(String agentId, {String? cwd}) async {
    await connectGate?.future;
    return <String, dynamic>{
      'agentId': agentId,
      'initialize': <String, dynamic>{
        'protocolVersion': 1,
        'agentInfo': <String, dynamic>{'name': _agent},
        'agentCapabilities': <String, dynamic>{'loadSession': true},
      },
    };
  }

  @override
  Future<JsonMap> sessionNew(String agentId, String cwd) async {
    if (newSessionError != null) throw newSessionError!;
    return super.sessionNew(agentId, cwd);
  }
}

Future<(WorkbenchController, _Core)> _pumpShell(WidgetTester tester) async {
  tester.view.physicalSize = _window;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.runAsync(loadGalleryFonts);

  final core = _Core();
  await core.sessionIndexUpsert(<String, dynamic>{'agentId': _agent, 'sessionId': _session, 'title': _title, 'cwd': _cwd});
  final c = WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask)
    ..workspace.project = const ProjectRef(path: _cwd, name: 'repo');
  addTearDown(c.dispose);
  await tester.runAsync(c.index.refresh);
  c.session.agentId = _agent;

  await tester.pumpWidget(MaterialApp(home: WorkbenchScreen(controller: c)));
  await tester.pump();
  return (c, core);
}

void main() {
  testWidgets('侧栏点开一条没载过的会话：会话头正下方挂「会话正在加载中」，载完撤掉', (tester) async {
    final (c, core) = await _pumpShell(tester);
    core.connectGate = Completer<void>();

    await tester.tap(find.text(_title).first);
    await tester.pump();
    await tester.pump(t.Motion.base);

    expect(c.session.sessionId, _session);
    expect(find.text(Toasts.sessionLoadingText), findsOneWidget);
    final card = tester.getRect(find.byType(ToastCard));
    final header = tester.getRect(find.byType(SessionHeader));
    expect(card.top, header.bottom + t.Toast.top, reason: '会话头正下方');
    expect(card.center.dx, moreOrLessEquals(header.center.dx, epsilon: 1), reason: '中栏里水平居中');

    core.connectGate!.complete();
    await tester.pump();
    await tester.pump();
    expect(c.session.loadingSession, isFalse);
    expect(find.byType(ToastCard), findsNothing);
  });

  testWidgets('新建会话失败：那一句出现在同一处，到时间自己收', (tester) async {
    final (c, core) = await _pumpShell(tester);
    core.newSessionError = const CoreCommandError('bridge', 'spawn failed');

    await c.session.newSession(c.session.agentRefOf(_agent));
    await tester.pump();
    expect(find.text('spawn failed'), findsOneWidget);

    await tester.pump(t.Toast.errorDuration);
    await tester.pump();
    expect(find.text('spawn failed'), findsNothing);
    expect(c.toasts.errors, isEmpty);
  });
}
