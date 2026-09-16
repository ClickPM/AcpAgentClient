// R6 组合根接线的单测：会话生命周期五件事在「UI 点下去会走的那条路」上的行为。
// 覆盖 ROUNDS § 3 R6 的交付物与验收 4：
// - 侧栏点一条内存里没有的会话 → 连 agent → `session/load`，整段重放只刷一次 UI；agent 没声明 loadSession 就不发；
// - ≡ 菜单的 Resume / Close / Delete 按 `sessionCapabilities` 裁剪，动作各自打到对的命令上；
// - 删除：声明了 delete 的 agent 先删 agent 侧再删本地索引；agent 侧失败时本地不动；没声明 / 没连只删本地；
// - 侧栏删除图标：声明里没有 delete 的 agent 不给，能力未知（没连过）时给；
// - `session/list` 校对：分页取完、只补标题不覆盖本地改名、agent 有本地没有的不进侧栏；
// - modes 回退：没有 `category == mode` 的 configOptions 时模式下拉走 `session/set_mode`；
// - 重载 agent：声明 loadSession 的重连后自动 load 回原会话，没声明的退回新会话。

import 'package:acp_agent_client/app/core_bridge.dart';
import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/projection/session_store.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/ui/popovers/topbar_popovers.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_core.dart';

const String _agent = 'a';
const String _session = 'sess_1';
const String _cwd = 'D:/repo';

/// `initialize` 的能力声明；`caps` 是 `sessionCapabilities` 的键。
JsonMap _initialize({bool loadSession = true, List<String> caps = const <String>['list', 'resume', 'close', 'delete']}) =>
    <String, dynamic>{
      'protocolVersion': 1,
      'agentInfo': <String, dynamic>{'name': _agent},
      'agentCapabilities': <String, dynamic>{
        'loadSession': loadSession,
        'sessionCapabilities': <String, dynamic>{for (final k in caps) k: <String, dynamic>{}},
      },
    };

class _LifecycleCore extends FakeCore {
  _LifecycleCore({JsonMap? initialize}) : initialize = initialize ?? _initialize();

  JsonMap initialize;
  final List<String> calls = <String>[];

  /// `session/delete` 失败（agent 说没有这条）。
  bool deleteFails = false;

  @override
  Future<JsonMap> agentConnect(String agentId, {String? cwd}) async {
    calls.add('connect:$agentId');
    return <String, dynamic>{'agentId': agentId, 'initialize': initialize};
  }

  @override
  Future<JsonMap> agentDisconnect(String agentId) async {
    calls.add('disconnect:$agentId');
    return <String, dynamic>{};
  }

  @override
  Future<JsonMap> sessionNew(String agentId, String cwd) async {
    calls.add('new:$agentId');
    return <String, dynamic>{'sessionId': 'sess_new'};
  }

  @override
  Future<JsonMap> sessionDelete(String agentId, String sessionId) async {
    calls.add('delete:$sessionId');
    if (deleteFails) throw const CoreCommandError('acp', 'no such session');
    return super.sessionDelete(agentId, sessionId);
  }
}

/// 起一个已连上、本地索引里有一条会话的控制器（会话还没载进内存）。
Future<(WorkbenchController, _LifecycleCore)> _connected({
  JsonMap? initialize,
  bool indexOnly = false,
}) async {
  final core = _LifecycleCore(initialize: initialize);
  await core.sessionIndexUpsert(<String, dynamic>{
    'agentId': _agent,
    'sessionId': _session,
    'title': _session,
    'cwd': _cwd,
    'messageCount': 3,
  });
  final c = WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask)
    ..project = const ProjectRef(path: _cwd, name: 'repo');
  await c.refreshSessionIndex();
  if (!indexOnly) {
    c.sessions.agents.applyInitializeResult(_agent, core.initialize);
    c.agentId = _agent;
  }
  return (c, core);
}

void main() {
  test('侧栏点一条内存里没有的会话：连 agent → session/load，整段重放只刷一次 UI', () async {
    final (c, core) = await _connected(indexOnly: true);
    core.onSessionLoad = (agentId, sessionId) async {
      // 重放走事件通路（与 `_enqueue` 同一条路：事件先进 batcher，挂起期间一条都不落到 UI）。
      for (var i = 0; i < 40; i++) {
        final payload = <String, dynamic>{
          'agentId': agentId,
          'sessionId': sessionId,
          'update': <String, dynamic>{
            'sessionUpdate': 'agent_message_chunk',
            'messageId': 'm_$i',
            'content': <String, dynamic>{'type': 'text', 'text': '第 $i 条'},
          },
        };
        c.batcher.enqueue(() => c.sessions.applySessionUpdateEnvelope(payload));
      }
      expect(c.batcher.isHeld, isTrue, reason: '重放期间 batcher 必须是挂起的');
      return <String, dynamic>{
        'modes': <String, dynamic>{
          'currentModeId': 'ask',
          'availableModes': <JsonMap>[
            <String, dynamic>{'id': 'ask', 'name': 'Ask'},
          ],
        },
      };
    };
    var notifications = 0;
    c.addListener(() => notifications++);

    await c.selectSession(_session);

    expect(core.calls, contains('connect:$_agent'));
    expect(core.loadedSessions, <(String, String, String)>[(_agent, _session, _cwd)]);
    final store = c.sessions.maybe(_session)!;
    expect(store.entries, hasLength(40), reason: '整段历史都在');
    expect(store.currentModeId, 'ask', reason: 'LoadSessionResponse 的 modes 落进来了');
    expect(c.sessionId, _session);
    // 40 条更新 + 一次重置合并成一次投影层通知（另外几次是 selectSession / _ensureLoaded 自己的 _touch）。
    expect(notifications, lessThan(5), reason: '重放不得逐条刷新，实得 $notifications');
  });

  test('agent 没声明 loadSession：点会话只切过去，不发 session/load', () async {
    final (c, core) = await _connected(indexOnly: true, initialize: _initialize(loadSession: false, caps: <String>[]));
    await c.selectSession(_session);
    expect(core.loadedSessions, isEmpty);
    expect(c.sessionId, _session);
    c.dispose();
  });

  test('已经在内存里的会话再点不会重复 load；close 之后再点会重新 load', () async {
    final (c, core) = await _connected();
    c.sessions.session(_session, agentId: _agent).cwd = _cwd;

    await c.selectSession(_session);
    expect(core.loadedSessions, isEmpty, reason: '内存里已经有转录了');

    await c.closeSession();
    expect(core.closedSessions, <(String, String)>[(_agent, _session)]);
    expect(c.sessionId, _session, reason: '关掉之后转录留着只读，还是当前会话');
    expect(c.sessionClosed, isTrue);

    c.sessionId = null; // 换到别处再点回来（等价于点侧栏另一条再点回这条）
    await c.selectSession(_session);
    expect(core.loadedSessions, hasLength(1), reason: '关过的会话要重新 load');
    expect(c.sessionClosed, isFalse, reason: 'load 成功后不再是关闭态');
    c.dispose();
  });

  test('Close / Resume 的能力门跟会话是死是活走（dsh 对活着的会话 resume 回 -32602）', () async {
    final (c, _) = await _connected();
    c.sessionId = _session;
    c.sessions.session(_session, agentId: _agent).cwd = _cwd;
    expect(c.canCloseSession, isTrue);
    expect(c.canResumeSession, isFalse, reason: '还活着的会话不给 Resume');

    await c.closeSession();
    expect(c.canCloseSession, isFalse, reason: '关过了不再给 Close');
    expect(c.canResumeSession, isTrue);

    await c.resumeSession();
    expect(c.sessionClosed, isFalse);
    expect(c.canResumeSession, isFalse);
    expect(c.canCloseSession, isTrue);
    c.dispose();
  });

  test('没有 loadSession 但有 resume 的 agent：点会话用 session/resume 挂回上下文（不重放）', () async {
    final (c, core) = await _connected(indexOnly: true, initialize: _initialize(loadSession: false, caps: <String>['resume']));
    await c.selectSession(_session);
    expect(core.loadedSessions, isEmpty);
    expect(core.resumedSessions, <(String, String, String)>[(_agent, _session, _cwd)]);
    c.dispose();
  });

  test('load 失败（内存里本来就没有）：空壳收回去，下次点击还能重试', () async {
    final (c, core) = await _connected(indexOnly: true);
    core.onSessionLoad = (_, _) async => throw const CoreCommandError('acp', 'gone');
    await c.selectSession(_session);
    expect(c.sessions.maybe(_session), isNull);
    expect(c.lastError, contains('gone'));
    await c.selectSession(_session);
    expect(core.loadedSessions, hasLength(2), reason: '失败之后还能再试');
    c.dispose();
  });

  test('load 失败（内存里已有转录、一条历史都没重放）：转录原样留着，不丢本地唯一一份', () async {
    final (c, core) = await _connected();
    c.sessionId = _session;
    final store = c.sessions.session(_session, agentId: _agent)..cwd = _cwd;
    store.applyUpdateJson(<String, dynamic>{
      'sessionUpdate': 'agent_message_chunk',
      'messageId': 'm1',
      'content': <String, dynamic>{'type': 'text', 'text': '关掉之前的这一条不能没'},
    });
    expect(store.entries, hasLength(1));

    await c.closeSession();
    c.sessionId = null;
    core.onSessionLoad = (_, _) async => throw const CoreCommandError('acp', 'gone');
    await c.selectSession(_session);

    expect(core.loadedSessions, hasLength(1));
    expect(c.sessions.maybe(_session), isNotNull, reason: '原先就在内存里的不该被摘掉');
    expect(c.sessions.maybe(_session)!.entries, hasLength(1), reason: '一条都没重放就失败 → 转录原样');
    expect(c.sessionClosed, isTrue, reason: 'load 没成，还是关闭态');
    c.dispose();
  });

  test('load 与 close 并发：load 回来时不把刚关掉的会话又标成活的', () async {
    final (c, core) = await _connected();
    c.sessionId = _session;
    c.sessions.session(_session, agentId: _agent).cwd = _cwd;
    await c.closeSession();
    c.sessionId = null;
    // load 在途时又被关了一次。
    core.onSessionLoad = (_, _) async {
      c.sessionId = _session;
      await c.closeSession();
      return <String, dynamic>{};
    };
    await c.selectSession(_session);
    expect(core.loadedSessions, hasLength(1));
    expect(c.sessionClosed, isTrue, reason: '在途期间的 close 不能被 load 的成功路径抹掉');
    c.dispose();
  });

  test('close / delete 之前把挂起的 elicitation 回 cancel（核心只管权限请求）', () async {
    final (c, core) = await _connected();
    c.sessionId = _session;
    c.sessions.session(_session, agentId: _agent).cwd = _cwd;
    c.sessions.applyClientRequestEnvelope(<String, dynamic>{
      'agentId': _agent,
      'requestId': 'req_elic',
      'method': 'elicitation/create',
      'params': <String, dynamic>{
        'mode': 'form',
        'sessionId': _session,
        'message': '要不要提交？',
        'requestedSchema': <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}},
      },
    });
    expect(c.sessions.pending.forSession(_session), hasLength(1));

    await c.closeSession();

    expect(core.responded.map((r) => r.$1), <String>['req_elic']);
    expect(core.responded.single.$2, <String, dynamic>{'action': 'cancel'});
    expect(c.sessions.pending.forSession(_session), isEmpty);
    c.dispose();
  });

  test('关掉的会话不能再发 prompt', () async {
    final (c, core) = await _connected();
    c.sessionId = _session;
    c.sessions.session(_session, agentId: _agent).cwd = _cwd;
    await c.closeSession();

    c.composer.text = '还想说点什么';
    await c.send();

    expect(core.prompts, isEmpty);
    expect(c.lastError, contains('已经关闭'));
    c.dispose();
  });

  test('Resume：不重放，响应为空也不能把已有的 modes / configOptions 抹掉', () async {
    final (c, core) = await _connected();
    c.sessionId = _session;
    final store = c.sessions.session(_session, agentId: _agent)..cwd = _cwd;
    await c.closeSession(); // 产品路径：Resume 只在 Close 之后给
    store.applyNewSession(<String, dynamic>{
      'modes': <String, dynamic>{
        'currentModeId': 'code',
        'availableModes': <JsonMap>[
          <String, dynamic>{'id': 'code', 'name': 'Code'},
        ],
      },
    });

    await c.resumeSession();

    expect(core.resumedSessions, <(String, String, String)>[(_agent, _session, _cwd)]);
    expect(store.currentModeId, 'code');
    expect(store.modeFallbackOption, isNotNull);
    c.dispose();
  });

  group('删除（验收 4）', () {
    test('声明了 delete：先删 agent 侧，成功后才删本地索引', () async {
      final (c, core) = await _connected();
      c.sessionId = _session;
      c.sessions.session(_session, agentId: _agent);

      await c.deleteSession(_session);

      expect(core.deletedSessions, <(String, String)>[(_agent, _session)]);
      expect(core.sessionIndex, isEmpty);
      expect(c.sidebarSessions, isEmpty);
      expect(c.sessions.maybe(_session), isNull);
      expect(c.sessionId, isNull);
      c.dispose();
    });

    test('agent 侧删成功、本地那步失败：重试不再往 agent 发第二次', () async {
      final (c, core) = await _connected();
      core.indexRemoveFailsOnce = true;

      await c.deleteSession(_session);
      expect(core.deletedSessions, hasLength(1));
      expect(core.sessionIndex, hasLength(1), reason: '本地那步失败了');

      await c.deleteSession(_session);
      expect(core.deletedSessions, hasLength(1), reason: 'agent 侧已经没有这条了，再发一次只会被拒');
      expect(core.sessionIndex, isEmpty, reason: '重试要能把本地这条删掉');
      c.dispose();
    });

    test('agent 侧删除失败：本地索引不动（可以重试）', () async {
      final (c, core) = await _connected();
      core.deleteFails = true;

      await c.deleteSession(_session);

      expect(core.sessionIndex, hasLength(1), reason: 'agent 侧没删掉就不能只删本地，两边会岔开');
      expect(c.sidebarSessions, hasLength(1));
      expect(c.lastError, contains('no such session'));
      c.dispose();
    });

    test('没声明 delete 的 agent：不发 session/delete，只删本地索引；侧栏也不出删除图标', () async {
      final (c, core) = await _connected(initialize: _initialize(caps: <String>['list', 'close']));
      await c.refreshSessionIndex();
      expect(c.sidebarSessions.single.canDelete, isFalse);
      expect(c.canDeleteSession, isFalse);

      await c.deleteSession(_session);

      expect(core.deletedSessions, isEmpty);
      expect(core.sessionIndex, isEmpty);
      c.dispose();
    });

    test('能力未知（agent 本次没连过）：侧栏照给删除图标，删除只动本地索引', () async {
      final (c, core) = await _connected(indexOnly: true);
      expect(c.sidebarSessions.single.canDelete, isTrue);
      await c.deleteSession(_session);
      expect(core.deletedSessions, isEmpty);
      expect(core.sessionIndex, isEmpty);
      c.dispose();
    });
  });

  test('≡ 菜单按 sessionCapabilities 裁剪', () async {
    final (full, _) = await _connected();
    full.sessionId = _session;
    expect(<bool>[full.canResumeSession, full.canCloseSession, full.canDeleteSession], <bool>[false, true, true]);
    await full.closeSession();
    expect(<bool>[full.canResumeSession, full.canCloseSession], <bool>[true, false]);
    full.dispose();

    // pi-acp 的声明：loadSession + list + delete，没有 resume / close。
    final (pi, _) = await _connected(initialize: _initialize(caps: <String>['list', 'delete']));
    pi.sessionId = _session;
    expect(<bool>[pi.canResumeSession, pi.canCloseSession, pi.canDeleteSession], <bool>[false, false, true]);
    expect(pi.canListSessions, isTrue);
    expect(pi.canLoadSession, isTrue);
    pi.dispose();

    // 没有会话时三个动作都不给（菜单挂在当前会话上）。
    final (none, _) = await _connected();
    expect(<bool>[none.canResumeSession, none.canCloseSession, none.canDeleteSession], <bool>[false, false, false]);
    none.dispose();
  });

  group('session/list 校对（裁定 2026-09-15）', () {
    test('分页取完；只补标题；agent 有本地没有的不进侧栏', () async {
      final (c, core) = await _connected();
      core.sessionListResult = (cursor) => switch (cursor) {
            null => <String, dynamic>{
                'sessions': <JsonMap>[
                  <String, dynamic>{'sessionId': _session, 'cwd': _cwd, 'title': 'agent 侧的标题'},
                ],
                'nextCursor': 'p2',
              },
            'p2' => <String, dynamic>{
                'sessions': <JsonMap>[
                  <String, dynamic>{'sessionId': 'sess_only_on_agent', 'cwd': _cwd, 'title': '别处建的'},
                ],
              },
            _ => <String, dynamic>{'sessions': <Object?>[]},
          };

      await c.reconcileSessions();

      expect(core.listedSessions.map((e) => e.$3), <String?>[null, 'p2'], reason: 'nextCursor 要取完');
      expect(c.sidebarSessions.map((s) => s.id), <String>[_session], reason: 'agent 有、本地没有的不自动出现');
      expect(c.sidebarSessions.single.title, 'agent 侧的标题', reason: '本地没标题（占位等于 id）时用 agent 的补上');
      expect(c.missingOnAgent, isEmpty);
      c.dispose();
    });

    test('本地改过的名字不被 agent 的标题盖回去；agent 侧没有的记进 missingOnAgent', () async {
      final (c, core) = await _connected();
      c.startRename(_session);
      await c.commitRename('我改的名字');
      core.sessionListResult = (_) => <String, dynamic>{'sessions': <Object?>[]};

      await c.reconcileSessions();

      expect(c.sidebarSessions.single.title, '我改的名字');
      expect(c.missingOnAgent, <String>{_session});
      c.dispose();
    });

    test('没声明 list 的 agent 不发 session/list', () async {
      final (c, core) = await _connected(initialize: _initialize(caps: <String>['delete']));
      await c.reconcileSessions();
      expect(core.listedSessions, isEmpty);
      c.dispose();
    });
  });

  test('modes 回退：模式下拉选中走 session/set_mode，不当成 configId 发出去', () async {
    final (c, core) = await _connected();
    c.sessionId = _session;
    final store = c.sessions.session(_session, agentId: _agent);
    store.applyNewSession(<String, dynamic>{
      'modes': <String, dynamic>{
        'currentModeId': 'ask',
        'availableModes': <JsonMap>[
          <String, dynamic>{'id': 'ask', 'name': 'Ask'},
          <String, dynamic>{'id': 'code', 'name': 'Code'},
        ],
      },
    });
    final option = c.optionOf('mode')!;
    expect(option.id, SessionStore.modeFallbackId);

    await c.selectConfigValue(option.id!, 'code');

    expect(store.currentModeId, 'code');
    expect(c.optionOf('mode')!.currentValue, 'code');
    c.dispose();
  });

  test('重载 agent：声明 loadSession 的重连后自动 load 回原会话；没声明的退回新会话', () async {
    final (c, core) = await _connected();
    c.sessionId = _session;
    c.sessions.session(_session, agentId: _agent).cwd = _cwd;

    await c.reloadAgent();

    expect(core.calls, <String>['disconnect:$_agent', 'connect:$_agent']);
    expect(core.loadedSessions, <(String, String, String)>[(_agent, _session, _cwd)]);
    expect(c.sessionId, _session, reason: '还是原来那个会话');
    c.dispose();

    final (plain, plainCore) = await _connected(initialize: _initialize(loadSession: false, caps: <String>[]));
    plain.sessionId = _session;
    plain.sessions.session(_session, agentId: _agent).cwd = _cwd;

    await plain.reloadAgent();

    expect(plainCore.loadedSessions, isEmpty);
    expect(plainCore.calls, contains('new:$_agent'));
    expect(plain.sessionId, 'sess_new');
    plain.dispose();
  });
}
