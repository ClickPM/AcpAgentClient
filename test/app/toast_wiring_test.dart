// 壳级提示（toast）的接线（设计稿之外的增补，所有者 2026-09-23）：
// - 各对象的 `lastError` 每写进一句就落成一条错误 toast（BACKLOG「失败没有出口」）：会话、输入框、一轮对话、终端、组合根自己；
//   同一句不叠两条、最多挂 [Toasts.maxErrors] 条、写 null 不报、终端那句不经壳再抄一遍；
// - 侧栏点开一条内存里没有转录的会话，载回来之前挂「会话正在加载中」，按**当前**会话判（BACKLOG「点开旧会话时没有正在载」）；
//   载着的时候再点同一条不会再连一遍 agent。

import 'dart:async';
import 'dart:typed_data';

import 'package:acp_agent_client/app/clipboard_image.dart';
import 'package:acp_agent_client/app/core_bridge.dart';
import 'package:acp_agent_client/app/toasts.dart';
import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/ui/popovers/topbar_popovers.dart';
import 'package:acp_agent_client/ui/shell/toast.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_core.dart';

const String _agent = 'a';
const String _session = 'sess_1';
const String _cwd = 'D:/repo';

final JsonMap _initialize = <String, dynamic>{
  'protocolVersion': 1,
  'agentInfo': <String, dynamic>{'name': _agent},
  'agentCapabilities': <String, dynamic>{'loadSession': true},
};

class _Core extends FakeCore {
  /// 挡住 `agent_connect`（拉进程 + `initialize` 那几秒）。
  Completer<void>? connectGate;
  int connects = 0;

  Object? initError;
  Object? newSessionError;
  Object? terminalOpenError;

  @override
  Future<JsonMap> init(String dataDir) async {
    if (initError != null) throw initError!;
    return super.init(dataDir);
  }

  @override
  Future<JsonMap> agentConnect(String agentId, {String? cwd}) async {
    connects++;
    await connectGate?.future;
    return <String, dynamic>{'agentId': agentId, 'initialize': _initialize};
  }

  @override
  Future<JsonMap> sessionNew(String agentId, String cwd) async {
    if (newSessionError != null) throw newSessionError!;
    return super.sessionNew(agentId, cwd);
  }

  @override
  Future<JsonMap> terminalOpen(String cwd, {required int cols, required int rows}) async {
    if (terminalOpenError != null) throw terminalOpenError!;
    return super.terminalOpen(cwd, cols: cols, rows: rows);
  }
}

/// 本地索引里有一条还没载进内存的会话，agent 还没连。
Future<(WorkbenchController, _Core)> _controller() async {
  final core = _Core();
  await core.sessionIndexUpsert(<String, dynamic>{'agentId': _agent, 'sessionId': _session, 'title': _session, 'cwd': _cwd});
  final c = WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask)
    ..workspace.project = const ProjectRef(path: _cwd, name: 'repo');
  await c.index.refresh();
  return (c, core);
}

List<String> _errorTexts(WorkbenchController c) => <String>[for (final m in c.toasts.errors) m.text];

/// 让桥命令的 async 链走几步（不带 FakeAsync 的 `test` 里，零时长的 delay 就是清一轮微任务 + 一次事件循环）。
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('Toasts 本身', () {
    test('同一句不叠两条：撤掉旧的、在最下面重挂（新 id = 重新计时）', () {
      final t = Toasts();
      t.error('甲');
      t.error('乙');
      final firstId = t.errors.first.id;
      t.error('甲');
      expect(<String>[for (final m in t.errors) m.text], <String>['乙', '甲']);
      expect(t.errors.last.id, isNot(firstId));
      t.dispose();
    });

    test('最多挂 maxErrors 条，再来就挤掉最早的；latest 收起了也还在', () {
      final t = Toasts();
      for (var i = 0; i < Toasts.maxErrors + 2; i++) {
        t.error('e$i');
      }
      expect(t.errors, hasLength(Toasts.maxErrors));
      expect(t.errors.first.text, 'e2');
      for (final m in t.errors.toList()) {
        t.dismiss(m);
      }
      expect(t.errors, isEmpty);
      expect(t.latest, 'e${Toasts.maxErrors + 1}');
      t.dispose();
    });

    test('正在载的那条排在最上面，错误按先后往下', () {
      final t = Toasts()..error('坏了');
      final visible = t.visible(loadingSession: true);
      expect(visible.map((m) => m.kind), <ToastKind>[ToastKind.loading, ToastKind.error]);
      expect(visible.first.text, Toasts.sessionLoadingText);
      expect(t.visible(loadingSession: false).map((m) => m.kind), <ToastKind>[ToastKind.error]);
      t.dispose();
    });
  });

  group('lastError → 错误 toast', () {
    test('新建会话失败（桥报错 / 没选项目目录）：原先只进日志的那一句摆到前台', () async {
      final (c, core) = await _controller();
      core.newSessionError = const CoreCommandError('bridge', 'spawn failed');
      await c.session.newSession(c.session.agentRefOf(_agent));
      expect(_errorTexts(c), <String>['spawn failed']);

      c.workspace.project = null;
      await c.session.newSession(c.session.agentRefOf(_agent));
      expect(_errorTexts(c).last, '先选一个项目目录，新会话的 cwd 从它来');
      c.dispose();
    });

    test('连点两下失败两次只挂一条', () async {
      final (c, core) = await _controller();
      core.newSessionError = const CoreCommandError('bridge', 'spawn failed');
      await c.session.newSession(c.session.agentRefOf(_agent));
      await c.session.newSession(c.session.agentRefOf(_agent));
      expect(_errorTexts(c), <String>['spawn failed']);
      await _settle(); // 新建会话收尾那次不 await 的 registry 刷新落完再 dispose
      c.dispose();
    });

    test('输入框附件超限、组合根启动失败也有出口；写 null 不报', () async {
      final (c, core) = await _controller();
      c.composer.addImageBytes(Uint8List(clipboardImageSizeLimit + 1), 'image/png');
      expect(_errorTexts(c), <String>['图片太大，没有加进输入框']);

      core.initError = const CoreCommandError('io', 'disk full');
      await c.start();
      expect(_errorTexts(c).last, 'io: disk full');

      final before = c.toasts.errors.length;
      c.session.lastError = null;
      expect(c.toasts.errors, hasLength(before));
      await _settle(); // start() 末尾那次不 await 的联网刷新落完再 dispose
      c.dispose();
    });

    test('开终端失败只报一次；下次开成功不会把上次那句再报一遍', () async {
      final (c, core) = await _controller();
      core.terminalOpenError = const CoreCommandError('pty', 'no shell');
      await c.shell.openTerminalTab();
      expect(_errorTexts(c), <String>['pty: no shell']);

      c.toasts.dismiss(c.toasts.errors.single);
      core.terminalOpenError = null;
      await c.shell.openTerminalTab(forceNew: true);
      expect(c.terminals.tabs, hasLength(1));
      expect(c.toasts.errors, isEmpty, reason: '`terminals.lastError` 成功后不清，壳再抄一遍就会把旧错重报');
      c.dispose();
    });

    test('dispose 之后再写 lastError 不再往外报、也不抛', () async {
      final (c, _) = await _controller();
      c.dispose();
      expect(() => c.session.lastError = 'late', returnsNormally);
    });
  });

  group('点开旧会话：会话正在加载中', () {
    test('连 agent 与 session/load 期间挂着，载完撤掉；只按当前会话显示', () async {
      final (c, core) = await _controller();
      core.connectGate = Completer<void>();
      final load = Completer<JsonMap>();
      core.onSessionLoad = (_, _) => load.future;
      expect(c.session.loadingSession, isFalse);

      final selecting = c.session.selectSession(_session);
      await _settle();
      expect(c.session.loadingSession, isTrue, reason: '拉进程 + initialize 那几秒也算在载');
      expect(c.toasts.visible(loadingSession: c.session.loadingSession).single.kind, ToastKind.loading);

      // 切去一条内存里已有的会话：那条不在载，不挂「正在加载」。
      c.sessions.session('other', agentId: _agent).cwd = _cwd;
      await c.session.selectSession('other');
      expect(c.session.loadingSession, isFalse);

      // 还没连上就点回来：仍在载，且不会再连一遍（再一次 agent_connect 会断掉正在握手的进程）。
      final again = c.session.selectSession(_session);
      await _settle();
      expect(c.session.loadingSession, isTrue);
      await again;
      expect(core.connects, 1);

      core.connectGate!.complete();
      await _settle();
      expect(core.loadedSessions, hasLength(1));
      expect(c.session.loadingSession, isTrue, reason: 'session/load 还在重放');

      load.complete(<String, dynamic>{});
      await selecting;
      expect(c.session.loadingSession, isFalse);
      expect(c.toasts.visible(loadingSession: c.session.loadingSession), isEmpty);
      c.dispose();
    });

    test('载不回来：「正在加载」撤掉，换成那一句错误', () async {
      final (c, core) = await _controller();
      core.onSessionLoad = (_, _) async => throw const CoreCommandError('acp', 'gone');
      await c.session.selectSession(_session);
      expect(c.session.loadingSession, isFalse);
      expect(_errorTexts(c), <String>['acp: gone']);
      c.dispose();
    });
  });
}
