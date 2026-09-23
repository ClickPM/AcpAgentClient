// iteration-07：BACKLOG P0「会话身份与生命周期」四条在「UI 点下去会走的那条路」上的行为。
// - 载会话中途失败：原先有转录的原样留着（不是半份），原先没有的空壳收回；
// - 发送按四态分流：载不回不另开一条顶掉它（这一轮以失败收在转录里）、能力未知先连上再判、挂不回照 R3 新开且占位文案先说；
// - 重载 / 崩溃 / 认证页重连之后：同一 agent 名下的其它会话标成挂空，切过去或再发（含 Regenerate、下拉）时先挂回；
// - 认证期间换了项目：会话登记在原目录，不切成当前会话。

import 'dart:async';

import 'package:acp_agent_client/app/core_bridge.dart';
import 'package:acp_agent_client/app/session_attach.dart';
import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/projection/session_store.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/ui/popovers/topbar_popovers.dart';
import 'package:acp_agent_client/ui/shell/shell_common.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_core.dart';

const String _agent = 'a';
const String _a = 'sess_a';
const String _b = 'sess_b';
const String _cwd = 'D:/repo';
const String _other = 'D:/other';

JsonMap _initialize({bool loadSession = true, List<String> caps = const <String>['list', 'close']}) => <String, dynamic>{
      'protocolVersion': 1,
      'agentInfo': <String, dynamic>{'name': _agent},
      'agentCapabilities': <String, dynamic>{
        'loadSession': loadSession,
        'sessionCapabilities': <String, dynamic>{for (final k in caps) k: <String, dynamic>{}},
      },
    };

class _AttachCore extends FakeCore {
  _AttachCore({JsonMap? initialize}) : initialize = initialize ?? _initialize();

  JsonMap initialize;

  /// 命令的先后（断言「先挂回再发」要看顺序）。
  final List<String> calls = <String>[];

  /// `agent_connect` 抛这个错（缺 Node 等）。
  CoreCommandError? connectError;

  /// 堵住 `agent_connect`（拉起进程要数秒的那个窗口）。
  Completer<void>? connectGate;

  /// `session/new` 抛这个错（认证等）。
  CoreCommandError? newError;

  /// `session/load` 期间的动作：用例在这里「重放」（往 batcher 里塞 update）或抛错。
  Future<JsonMap> Function(String sessionId)? onLoad;

  int _newCount = 0;

  @override
  Future<JsonMap> agentConnect(String agentId, {String? cwd}) async {
    calls.add('connect');
    await connectGate?.future;
    final e = connectError;
    if (e != null) throw e;
    return <String, dynamic>{'agentId': agentId, 'initialize': initialize};
  }

  @override
  Future<JsonMap> agentDisconnect(String agentId) async {
    calls.add('disconnect');
    return <String, dynamic>{};
  }

  @override
  Future<JsonMap> sessionNew(String agentId, String cwd) async {
    calls.add('new');
    final e = newError;
    if (e != null) throw e;
    return <String, dynamic>{'sessionId': 'sess_new_${++_newCount}'};
  }

  @override
  Future<JsonMap> sessionLoad(String agentId, String sessionId, String cwd) async {
    calls.add('load:$sessionId');
    return await onLoad?.call(sessionId) ?? <String, dynamic>{};
  }

  @override
  Future<JsonMap> sessionResume(String agentId, String sessionId, String cwd) async {
    calls.add('resume:$sessionId');
    return <String, dynamic>{};
  }

  @override
  Future<JsonMap> sessionPrompt(String agentId, String sessionId, List<Object?> prompt) async {
    calls.add('prompt:$sessionId');
    return super.sessionPrompt(agentId, sessionId, prompt);
  }

  @override
  Future<JsonMap> sessionSetMode(String agentId, String sessionId, String modeId) async {
    calls.add('set_mode:$sessionId');
    return super.sessionSetMode(agentId, sessionId, modeId);
  }
}

/// 本地索引里有 [_a] 与 [_b] 两条（同一个 agent、同一个目录）。[connected] 时 agent 已经 `initialize` 过。
Future<(WorkbenchController, _AttachCore)> _controller({JsonMap? initialize, bool connected = true}) async {
  final core = _AttachCore(initialize: initialize);
  for (final id in <String>[_a, _b]) {
    await core.sessionIndexUpsert(<String, dynamic>{'agentId': _agent, 'sessionId': id, 'title': id, 'cwd': _cwd, 'messageCount': 1});
  }
  final c = WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask)
    ..workspace.project = const ProjectRef(path: _cwd, name: 'repo');
  await c.index.refresh();
  c.session.agentId = _agent;
  if (connected) c.sessions.agents.applyInitializeResult(_agent, core.initialize);
  return (c, core);
}

/// 内存里已经有转录、挂在当前连接上的一条会话（等价于本次运行里开过 / 载过它）。
SessionStore _live(WorkbenchController c, String id, List<String> texts) {
  final s = c.sessions.session(id, agentId: _agent)..cwd = _cwd;
  for (var i = 0; i < texts.length; i++) {
    s.applyUpdateJson(<String, dynamic>{
      'sessionUpdate': 'agent_message_chunk',
      'messageId': '${id}_m$i',
      'content': <String, dynamic>{'type': 'text', 'text': texts[i]},
    });
  }
  return s;
}

/// 重放一条 agent 消息（走与 `_enqueue` 同一条路：事件先进 batcher）。
void _replay(WorkbenchController c, String id, String messageId, String text) {
  final payload = <String, dynamic>{
    'agentId': _agent,
    'sessionId': id,
    'update': <String, dynamic>{
      'sessionUpdate': 'agent_message_chunk',
      'messageId': messageId,
      'content': <String, dynamic>{'type': 'text', 'text': text},
    },
  };
  c.batcher.enqueue(() => c.sessions.applySessionUpdateEnvelope(payload));
}

List<String> _texts(SessionStore s) => <String>[
      for (final e in s.entries)
        if (e is MessageEntry) e.blocks.map((b) => b.text ?? '').join(),
    ];

void main() {
  group('载会话中途失败（第 4 条）', () {
    test('原先有转录：重放到一半断了，转录原样留着，不是半份', () async {
      final (c, core) = await _controller();
      c.session.sessionId = _a;
      final s = _live(c, _a, <String>['第一条', '第二条']);
      await c.session.closeSession(); // 关掉之后再点开要重新 load
      c.session.sessionId = null;
      core.onLoad = (id) async {
        _replay(c, id, 'r1', '重放 1');
        _replay(c, id, 'r2', '重放 2');
        throw const CoreCommandError('acp', 'connection reset');
      };

      await c.session.selectSession(_a);

      expect(core.calls, contains('load:$_a'));
      expect(identical(c.sessions.maybe(_a), s), isTrue);
      expect(_texts(s), <String>['第一条', '第二条'], reason: '清空不生效、夹在中间的重放整段丢掉');
      expect(c.session.lastError, contains('connection reset'));
      expect(c.session.sessionClosed, isTrue, reason: 'load 没成，还是关闭态');

      // 窗口之外的更新照常落：丢弃只管那一次重放。
      c.sessions.applySessionUpdateEnvelope(<String, dynamic>{
        'agentId': _agent,
        'sessionId': _a,
        'update': <String, dynamic>{
          'sessionUpdate': 'agent_message_chunk',
          'messageId': 'later',
          'content': <String, dynamic>{'type': 'text', 'text': '之后的'},
        },
      });
      expect(_texts(s), <String>['第一条', '第二条', '之后的']);
      c.dispose();
    });

    test('原先没有转录：重放到一半断了，空壳收回，下次点击能重试且完整', () async {
      final (c, core) = await _controller(connected: false);
      core.onLoad = (id) async {
        _replay(c, id, 'r1', '重放 1');
        throw const CoreCommandError('acp', 'connection reset');
      };
      await c.session.selectSession(_a);
      expect(c.sessions.maybe(_a), isNull);

      core.onLoad = (id) async {
        _replay(c, id, 'r1', '重放 1');
        _replay(c, id, 'r2', '重放 2');
        return <String, dynamic>{};
      };
      c.session.sessionId = null;
      await c.session.selectSession(_a);
      expect(_texts(c.sessions.maybe(_a)!), <String>['重放 1', '重放 2']);
      c.dispose();
    });
  });

  group('发送按挂载状态分流（第 1 条）', () {
    test('载不回：不另开一条顶掉选中的会话，这一轮以失败收在转录里', () async {
      final (c, core) = await _controller(connected: false);
      core.onLoad = (_) async => throw const CoreCommandError('acp', 'history file is corrupt');
      await c.session.selectSession(_a);
      expect(c.sessions.maybe(_a), isNull);

      c.composer.editor.text = '接着聊';
      await c.turn.send();

      expect(core.calls.where((x) => x == 'new'), isEmpty, reason: '不能新开一条把选中的顶掉');
      expect(core.calls.where((x) => x.startsWith('prompt:')), isEmpty);
      expect(c.session.sessionId, _a, reason: '侧栏高亮不跳走');
      final s = c.sessions.maybe(_a)!;
      expect(_texts(s), <String>['接着聊'], reason: '用户的消息留在转录里');
      final turn = s.entries.whereType<TurnEntry>().single;
      expect(turn.error, contains('history file is corrupt'), reason: '画板 31 的结束行显示原因');
      expect(c.composer.editor.text, isEmpty);
      expect(c.session.waitingForAgent, isFalse);
      expect(c.session.attachOf(_a), SessionAttach.detached, reason: '仍是挂空，下次点开或再发时照常挂回');

      // 之后 agent 恢复了：再发一次，载入成功就被整段重放换掉，再发出去。
      core.onLoad = (id) async {
        _replay(c, id, 'h1', '真正的历史');
        return <String, dynamic>{};
      };
      c.composer.editor.text = '再试一次';
      await c.turn.send();
      expect(core.calls.last, 'prompt:$_a');
      expect(_texts(s).first, '真正的历史', reason: '本地那条失败轮被重放换掉');
      c.dispose();
    });

    test('能力未知（本次还没连过）：先连上、载回，再发到选中的会话', () async {
      final (c, core) = await _controller(connected: false);
      c.session.sessionId = _a; // 选中了但还没载（等价于启动后恢复的选中态）
      expect(c.session.attachOf(_a), SessionAttach.detached);

      c.composer.editor.text = '你好';
      await c.turn.send();

      expect(core.calls, <String>['connect', 'load:$_a', 'prompt:$_a']);
      expect(c.session.sessionId, _a);
      c.dispose();
    });

    test('挂不回（能力已知、没有 load 也没有 resume）：占位文案先说明，发送照 R3 新开一条', () async {
      final (c, core) = await _controller(initialize: _initialize(loadSession: false, caps: <String>[]));
      c.session.sessionId = _a;
      expect(c.session.attachOf(_a), SessionAttach.unattachable);
      expect(c.session.composerPlaceholder, contains('无法继续'));

      c.composer.editor.text = '你好';
      await c.turn.send();

      expect(core.calls, <String>['new', 'prompt:sess_new_1']);
      expect(c.session.sessionId, 'sess_new_1');
      expect(c.session.composerPlaceholder, startsWith('Message to'));
      c.dispose();
    });

    test('能力未知、连上才知道挂不回：新开一条', () async {
      final (c, core) = await _controller(initialize: _initialize(loadSession: false, caps: <String>[]), connected: false);
      c.session.sessionId = _a;
      expect(c.session.attachOf(_a), SessionAttach.detached, reason: '能力未知时不猜');

      c.composer.editor.text = '你好';
      await c.turn.send();

      expect(core.calls, <String>['connect', 'new', 'prompt:sess_new_1']);
      c.dispose();
    });

    test('挂回时连不上（缺 Node）：去处与新建会话一样安排，原因不被盖掉', () async {
      final (c, core) = await _controller(connected: false);
      c.session.sessionId = _a;
      core.connectError = const CoreCommandError('node_missing', 'Node.js not found');

      c.composer.editor.text = '你好';
      await c.turn.send();

      expect(c.shell.rightTab, ShellTab.agents, reason: '画板 51 的受管 Node 提示卡');
      expect(c.session.lastError, 'Node.js not found');
      expect(c.sessions.maybe(_a)!.entries.whereType<TurnEntry>().single.error, 'Node.js not found');
      expect(core.calls.where((x) => x == 'new'), isEmpty);
      c.dispose();
    });

    test('载入在途时发送：等那一次载入，不另发一次、消息不被重放抹掉', () async {
      final (c, core) = await _controller(connected: false);
      final gate = Completer<void>();
      core.onLoad = (id) async {
        _replay(c, id, 'h1', '历史');
        await gate.future;
        return <String, dynamic>{};
      };
      final selecting = c.session.selectSession(_a);
      await Future<void>.delayed(Duration.zero);
      c.composer.editor.text = '点完马上发';
      final sending = c.turn.send();
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await selecting;
      await sending;

      expect(core.calls.where((x) => x.startsWith('load:')), hasLength(1));
      expect(core.calls.last, 'prompt:$_a');
      expect(_texts(c.sessions.maybe(_a)!), <String>['历史', '点完马上发']);
      c.dispose();
    });

    test('点开没连上的旧会话、连接还在拉起时就发送：只连一次、只载一次，消息照常发到这条', () async {
      final (c, core) = await _controller(connected: false);
      final gate = Completer<void>();
      core.connectGate = gate;
      core.onLoad = (id) async {
        _replay(c, id, 'h1', '历史');
        return <String, dynamic>{};
      };
      final selecting = c.session.selectSession(_a);
      await Future<void>.delayed(Duration.zero);
      c.composer.editor.text = '马上发';
      final sending = c.turn.send();
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await selecting;
      await sending;

      expect(core.calls, <String>['connect', 'load:$_a', 'prompt:$_a'], reason: '第二次 agent_connect 会把刚拉起的那条断掉');
      expect(_texts(c.sessions.maybe(_a)!), <String>['历史', '马上发']);
      c.dispose();
    });

    test('另一条会话还在载时，这条的载入不提前报成功：发送等转录真的换过来再落', () async {
      final (c, core) = await _controller();
      final gateB = Completer<void>();
      core.onLoad = (id) async {
        if (id == _b) {
          await gateB.future;
        } else {
          _replay(c, id, 'h1', 'A 的历史');
        }
        return <String, dynamic>{};
      };
      final selectingB = c.session.selectSession(_b);
      await Future<void>.delayed(Duration.zero);
      final selectingA = c.session.selectSession(_a); // A 的 session/load 先回来，B 还挂着 batcher
      await Future<void>.delayed(Duration.zero);
      expect(c.session.attachOf(_a), SessionAttach.detached, reason: '清空与重放还没跑，不能算挂上');
      c.composer.editor.text = 'A 上的一句';
      final sending = c.turn.send();
      await Future<void>.delayed(Duration.zero);
      gateB.complete();
      await selectingB;
      await selectingA;
      await sending;

      expect(core.calls.where((x) => x == 'load:$_a'), hasLength(1));
      expect(core.calls.last, 'prompt:$_a');
      expect(_texts(c.sessions.maybe(_a)!), <String>['A 的历史', 'A 上的一句'], reason: '这句话不能被随后才跑的清空抹掉');
      c.dispose();
    });

    test('挂不回、内存里有转录、新开会话又没开出来：不把消息发给旧 sessionId，原因不被盖掉', () async {
      final (c, core) = await _controller(initialize: _initialize(loadSession: false, caps: <String>[]));
      _live(c, _a, <String>['A 的历史']);
      c.session.sessionId = _a;
      c.sessions.applyAgentState(<String, dynamic>{'agentId': _agent, 'state': 'exited', 'code': 1});
      expect(c.session.attachOf(_a), SessionAttach.unattachable);
      core.newError = const CoreCommandError('acp', 'quota exceeded');

      c.composer.editor.text = '你好';
      await c.turn.send();

      expect(core.calls.where((x) => x.startsWith('prompt:')), isEmpty);
      expect(c.session.sessionId, _a);
      expect(c.session.lastError, 'quota exceeded');
      expect(c.turn.lastError, isNull);
      expect(c.composer.editor.text, '你好', reason: '输入框里的文本原样留着');
      c.dispose();
    });

    test('挂回期间点了侧栏另一条：这条消息不改投别的会话，输入框原样留着', () async {
      final (c, core) = await _controller(connected: false);
      c.session.sessionId = _a;
      final gate = Completer<void>();
      core.onLoad = (id) async {
        if (id == _a) await gate.future;
        return <String, dynamic>{};
      };
      c.composer.editor.text = '给 A 的';
      final sending = c.turn.send();
      await Future<void>.delayed(Duration.zero);
      expect(c.session.waitingForAgent, isTrue);
      // B 的载入要等 A 那次放开 batcher 才算完（`loadSession` 的 Future 等排队的清空 / 重放真的跑完），所以先不 await。
      final selectingB = c.session.selectSession(_b);
      await Future<void>.delayed(Duration.zero);
      expect(c.session.sessionId, _b);
      gate.complete();
      await selectingB;
      await sending;

      expect(core.calls.where((x) => x.startsWith('prompt:')), isEmpty);
      expect(c.session.sessionId, _b);
      expect(c.composer.editor.text, '给 A 的');
      c.dispose();
    });
  });

  group('重载 / 崩溃之后（第 2 条）', () {
    test('重载 agent 之后切到同 agent 的另一条会话：先 load 回来再发，不撞 unknown session', () async {
      final (c, core) = await _controller();
      _live(c, _a, <String>['A 的历史']);
      _live(c, _b, <String>['B 的历史']);
      c.session.sessionId = _a;

      await c.session.reloadAgent();
      expect(core.calls, <String>['disconnect', 'connect', 'load:$_a']);
      expect(c.session.attachOf(_a), SessionAttach.attached);
      expect(c.session.attachOf(_b), SessionAttach.detached, reason: 'B 的 sessionId 在新进程里不存在');

      core.calls.clear();
      await c.session.selectSession(_b);
      expect(core.calls, <String>['load:$_b'], reason: '切过去就自动载回，不重连');
      c.composer.editor.text = '继续';
      await c.turn.send();
      expect(core.calls, <String>['load:$_b', 'prompt:$_b']);
      c.dispose();
    });

    test('进程崩溃（exited）之后在当前会话发消息：先重连、载回再发', () async {
      final (c, core) = await _controller();
      _live(c, _a, <String>['A 的历史']);
      c.session.sessionId = _a;
      c.sessions.applyAgentState(<String, dynamic>{'agentId': _agent, 'state': 'exited', 'code': 1});
      expect(c.session.attachOf(_a), SessionAttach.detached);

      c.composer.editor.text = '还在吗';
      await c.turn.send();

      expect(core.calls, <String>['connect', 'load:$_a', 'prompt:$_a']);
      c.dispose();
    });

    test('只有 resume 的 agent：重载后切回旧会话走 session/resume，本地转录不动', () async {
      final (c, core) = await _controller(initialize: _initialize(loadSession: false, caps: <String>['resume']));
      _live(c, _a, <String>['A 的历史']);
      final b = _live(c, _b, <String>['B 的历史']);
      c.session.sessionId = _a;

      await c.session.reloadAgent();
      expect(c.session.sessionId, 'sess_new_1', reason: '没有 loadSession：重载开新会话（R3）');

      core.calls.clear();
      await c.session.selectSession(_b);
      c.composer.editor.text = '继续';
      await c.turn.send();
      expect(core.calls, <String>['resume:$_b', 'prompt:$_b']);
      expect(_texts(b).first, 'B 的历史', reason: 'resume 不重放，转录用内存里这份');
      c.dispose();
    });

    test('认证页连 agent 也记一代：同 agent 名下的会话随之挂空', () async {
      final (c, core) = await _controller();
      _live(c, _b, <String>['B 的历史']);
      c.sessions.applyAgentState(<String, dynamic>{'agentId': _agent, 'state': 'exited', 'code': 1});

      await c.auth.open(_agent);

      expect(core.calls, <String>['connect']);
      expect(c.sessions.agents[_agent]!.state.name, 'initialized');
      expect(c.session.attachOf(_b), SessionAttach.detached, reason: '认证页换上的也是一条新连接');
      c.dispose();
    });

    test('Regenerate 与下拉在崩溃之后也先挂回（resume 不重放，气泡还在）', () async {
      final (c, core) = await _controller(initialize: _initialize(loadSession: false, caps: <String>['resume']));
      c.session.sessionId = _a;
      final s = _live(c, _a, const <String>[]);
      s.startTurn(<ContentBlockWire>[
        const ContentBlockWire(<String, dynamic>{'type': 'text', 'text': '原来那句'}),
      ]);
      s.endTurn(stopReason: 'end_turn');
      final bubble = s.entries.whereType<MessageEntry>().first;
      s.applyNewSession(<String, dynamic>{
        'modes': <String, dynamic>{
          'currentModeId': 'ask',
          'availableModes': <JsonMap>[
            <String, dynamic>{'id': 'ask', 'name': 'Ask'},
            <String, dynamic>{'id': 'code', 'name': 'Code'},
          ],
        },
      });

      c.sessions.applyAgentState(<String, dynamic>{'agentId': _agent, 'state': 'exited', 'code': 1});
      await c.turn.setMode('code');
      expect(core.calls, <String>['connect', 'resume:$_a', 'set_mode:$_a']);

      c.sessions.applyAgentState(<String, dynamic>{'agentId': _agent, 'state': 'exited', 'code': 1});
      core.calls.clear();
      await c.turn.restore(bubble);
      expect(core.calls, <String>['connect', 'resume:$_a', 'prompt:$_a']);
      c.dispose();
    });
  });

  group('认证期间换了项目（第 3 条）', () {
    Future<(WorkbenchController, _AuthCore)> authPending({bool terminal = false}) async {
      final core = _AuthCore();
      final c = WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask)
        ..workspace.project = const ProjectRef(path: _cwd, name: 'repo');
      await c.session.newSession(const AgentRef(id: _agent, name: _agent));
      expect(c.auth.agentId, _agent, reason: 'session/new 回 -32000 → 认证页');
      if (terminal) c.auth.selectMethod('cli-login');
      await c.workspace.openProject(const ProjectRef(path: _other, name: 'other'));
      expect(c.workspace.project!.path, _other);
      return (c, core);
    }

    for (final terminal in <bool>[false, true]) {
      test('${terminal ? 'terminal' : 'agent'} 型：会话登记在原目录，不切成当前会话；切回去才在侧栏里', () async {
        final (c, core) = await authPending(terminal: terminal);

        await c.auth.start();

        final sid = terminal ? 'sess_from_terminal' : 'sess_after_auth';
        expect(c.sessions.maybe(sid)?.cwd, _cwd);
        expect(c.session.sessionId, isNull, reason: '不顶掉当前项目里的状态');
        expect(core.sessionIndex.single['sessionId'], sid, reason: '索引按这条会话写，不是当前会话');
        expect(core.sessionIndex.single['cwd'], _cwd);
        expect(c.session.sidebarSessions, isEmpty, reason: '当前项目的侧栏里不该有它');
        expect(c.auth.agentId, isNull, reason: '认证页照常收起');

        await c.workspace.openProject(const ProjectRef(path: _cwd, name: 'repo'));
        expect(c.session.sidebarSessions.map((s) => s.id), <String>[sid]);
        c.dispose();
      });
    }
  });
}

/// `session/new` 在认证之前回 -32000；两种认证方式都放行。
class _AuthCore extends FakeCore {
  bool authed = false;

  @override
  Future<JsonMap> agentConnect(String agentId, {String? cwd}) async => <String, dynamic>{
        'agentId': agentId,
        'initialize': <String, dynamic>{
          'protocolVersion': 1,
          'agentInfo': <String, dynamic>{'name': _agent},
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Object?>[
            <String, dynamic>{'id': 'device-code', 'name': 'Device code'},
            <String, dynamic>{'type': 'terminal', 'id': 'cli-login', 'name': 'CLI login', 'args': <String>['login']},
          ],
        },
      };

  @override
  Future<JsonMap> sessionNew(String agentId, String cwd) async {
    if (!authed) throw const CoreCommandError('auth_required', 'login first');
    return <String, dynamic>{'sessionId': 'sess_after_auth'};
  }

  @override
  Future<JsonMap> authenticate(String agentId, String methodId) async {
    authed = true;
    return <String, dynamic>{};
  }

  @override
  Future<JsonMap> terminalAuthRun(String agentId, String methodId, String cwd) async {
    authed = true;
    return <String, dynamic>{
      'terminalId': 'term_auth',
      'exitStatus': <String, dynamic>{'exitCode': 0},
      'session': <String, dynamic>{'sessionId': 'sess_from_terminal'},
    };
  }
}
