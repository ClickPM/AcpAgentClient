// 画板 54（R10）：`AgentsState` 采样定时器生命周期、Stop 停止流程与 B1 / B2 / B3 确认弹层分流的接线单测。

import 'dart:async';

import 'package:acp_agent_client/app/core_bridge.dart';
import 'package:acp_agent_client/app/session_attach.dart';
import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/ui/shell/shell_common.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_core.dart';

JsonMap _entry(String id, {String name = 'Claude Agent'}) => <String, dynamic>{
  'id': id,
  'name': name,
  'version': '1.0.0',
  'description': 'd',
  'distribution': 'npx',
  'supported': true,
  'installed': <String, dynamic>{
    'kind': 'npx',
    'version': '1.0.0',
    'authStatus': 'authenticated',
    'command': 'node',
    'args': <String>['x'],
  },
  'installing': false,
};

JsonMap _snapshotWith(List<String> agentIds) => <String, dynamic>{
  'metric': 'private',
  'takenAt': 1760000000000,
  'app': <String, dynamic>{'pid': 1000, 'bytes': 281432064},
  'agents': <Object?>[
    for (final id in agentIds)
      <String, dynamic>{
        'agentId': id,
        'rootPid': 18324,
        'bytes': 641728512,
        'startedAt': 1759995680000,
        'processes': <Object?>[
          <String, dynamic>{
            'pid': 18324,
            'parentPid': 1000,
            'name': 'node.exe',
            'bytes': 641728512,
            'depth': 0,
          },
        ],
        'terminals': <Object?>[],
      },
  ],
  'terminals': <String, dynamic>{'count': 0, 'bytes': 0, 'items': <Object?>[]},
  'other': <String, dynamic>{'bytes': 0},
  'total': 281432064 + agentIds.length * 641728512,
};

Future<WorkbenchController> _start(FakeCore core) async {
  core.registry = <String, dynamic>{
    'agents': <JsonMap>[_entry('claude-acp'), _entry('pi-acp', name: 'pi ACP')],
    'fetching': false,
    'node': <String, dynamic>{},
  };
  final c = WorkbenchController(
    source: DataSource.bridge,
    bridge: core,
    scheduler: WorkbenchController.scheduleOnMicrotask,
  );
  await c.start();
  await _settle();
  return c;
}

Future<void> _settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('采样定时器生命周期：仅在 Agents 标签可见且窗口未最小化时采样，切走或最小化立即停表', () async {
    final core = FakeCore()
      ..processSnapshotResult = _snapshotWith(<String>['claude-acp']);
    final c = await _start(core);
    expect(core.processSnapshotCalls, 0, reason: '未打开 Agents 标签前不采样');
    expect(c.agents.sampleTimerActive, isFalse);

    c.shell.openTab(ShellTab.agents);
    await _settle();
    expect(core.processSnapshotCalls, 1, reason: '打开即采一次');
    expect(c.agents.sampleTimerActive, isTrue);
    expect(c.agents.processSnapshot?.agent('claude-acp')?.rootPid, 18324);

    // 切到文件标签：立即停表。
    c.shell.openTab(ShellTab.files);
    expect(c.agents.sampleTimerActive, isFalse);

    // 切回 Agents 标签：恢复采样；最小化窗口：立即停表。
    c.shell.openTab(ShellTab.agents);
    await _settle();
    expect(core.processSnapshotCalls, 2);
    expect(c.agents.sampleTimerActive, isTrue);

    c.didChangeAppLifecycleState(AppLifecycleState.hidden);
    expect(c.agents.sampleTimerActive, isFalse);

    c.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await _settle();
    expect(core.processSnapshotCalls, 3);
    expect(c.agents.sampleTimerActive, isTrue);

    c.dispose();
  });

  test('采样失败：记录错误、清空快照并停掉定时器，点刷新图标重试恢复', () async {
    final core = FakeCore()
      ..processSnapshotError = const CoreCommandError(
        'internal',
        'sysinfo failed',
      );
    final c = await _start(core);

    c.shell.openTab(ShellTab.agents);
    await _settle();
    expect(core.processSnapshotCalls, 1);
    expect(c.agents.processSampleError, contains('sysinfo failed'));
    expect(c.agents.processSnapshot, isNull);
    expect(c.agents.sampleTimerActive, isFalse, reason: '失败后停掉定时器');

    // 修复后点刷新重试：恢复定时器并拿到新快照。
    core.processSnapshotError = null;
    core.processSnapshotResult = _snapshotWith(<String>['claude-acp']);
    await c.agents.retryProcessSample();
    expect(core.processSnapshotCalls, 2);
    expect(c.agents.processSampleError, isNull);
    expect(c.agents.processSnapshot, isNotNull);
    expect(c.agents.sampleTimerActive, isTrue);

    c.dispose();
  });

  test(
    'B3 无会话：点 Stop 不弹确认，直接进停止中态并调 agentDisconnect；收到 exited 后撤掉停止中态',
    () async {
      final core = FakeCore()
        ..processSnapshotResult = _snapshotWith(<String>['pi-acp'])
        ..agentDisconnectGate = Completer<void>();
      final c = await _start(core);
      core.emit(CoreEvent.agentState, <String, dynamic>{
        'agentId': 'pi-acp',
        'state': 'initialized',
        'droppedUpdates': 0,
      });
      await _settle();

      final stopFuture = c.agents.requestStop('pi-acp');
      await _settle();
      expect(c.agents.confirmingStop, isNull, reason: '无会话不弹确认（B3）');
      expect(c.agents.stoppingIds, contains('pi-acp'));
      expect(core.disconnectedAgents, <String>['pi-acp']);

      // 在途收到 exited 事件即撤掉停止中态。
      core.processSnapshotResult = _snapshotWith(<String>[]);
      core.emit(CoreEvent.agentState, <String, dynamic>{
        'agentId': 'pi-acp',
        'state': 'exited',
        'code': 0,
      });
      await _settle();
      expect(c.agents.stoppingIds, isNot(contains('pi-acp')));
      expect(c.agents.isAgentRunning('pi-acp'), isFalse);

      core.agentDisconnectGate!.complete();
      await stopFuture;
      c.dispose();
    },
  );

  test(
    'B1 有会话（无回合在跑、无等你处理）：弹 B1 确认，取消不发命令，确认调 agentDisconnect 并收尾会话',
    () async {
      final core = FakeCore()
        ..processSnapshotResult = _snapshotWith(<String>['claude-acp']);
      final c = await _start(core);
      core.emit(CoreEvent.agentState, <String, dynamic>{
        'agentId': 'claude-acp',
        'state': 'initialized',
        'droppedUpdates': 0,
      });
      c.sessions.session('s1', agentId: 'claude-acp');
      c.sessions.session('s2', agentId: 'claude-acp');
      await _settle();

      await c.agents.requestStop('claude-acp');
      final data = c.agents.confirmingStop;
      expect(data, isNotNull);
      expect(data!.hasActiveWork, isFalse, reason: 'B1 无活跃回合与挂起请求');
      expect(data.sessionCount, 2);
      expect(core.disconnectedAgents, isEmpty);

      // 取消：不发 agentDisconnect。
      c.agents.cancelStop();
      expect(c.agents.confirmingStop, isNull);
      expect(core.disconnectedAgents, isEmpty);

      // 再次点 Stop 并确认：发 agentDisconnect，会话变挂空。
      await c.agents.requestStop('claude-acp');
      await c.agents.confirmStop();
      expect(core.disconnectedAgents, <String>['claude-acp']);
      expect(c.session.attachOf('s1'), isNot(SessionAttach.attached));
      expect(c.session.attachOf('s2'), isNot(SessionAttach.attached));
      c.dispose();
    },
  );

  test('B2 有回合在跑或有会话在等你授权：弹 B2 确认（统计在跑与待授权会话数），确认后撤回挂起请求并清空队列', () async {
    final core = FakeCore()
      ..processSnapshotResult = _snapshotWith(<String>['claude-acp']);
    final c = await _start(core);
    core.emit(CoreEvent.agentState, <String, dynamic>{
      'agentId': 'claude-acp',
      'state': 'initialized',
      'droppedUpdates': 0,
    });
    final s1 = c.sessions.session('s1', agentId: 'claude-acp')
      ..startTurn(const <ContentBlockWire>[
        ContentBlockWire(<String, dynamic>{'type': 'text', 'text': 'hi'}),
      ]);
    c.sessions.session('s2', agentId: 'claude-acp');
    core.emit(CoreEvent.clientRequest, <String, dynamic>{
      'agentId': 'claude-acp',
      'requestId': 'req_1',
      'sessionId': 's2',
      'method': 'session/request_permission',
      'params': <String, dynamic>{
        'sessionId': 's2',
        'toolCall': <String, dynamic>{
          'toolCallId': 'tc_1',
          'title': 'Run bash',
        },
        'options': <Object?>[
          <String, dynamic>{
            'optionId': 'allow',
            'name': 'Allow',
            'kind': 'allow_once',
          },
        ],
      },
    });
    await _settle();
    expect(s1.isRunning, isTrue);

    await c.agents.requestStop('claude-acp');
    final data = c.agents.confirmingStop;
    expect(data, isNotNull);
    expect(data!.hasActiveWork, isTrue, reason: 'B2 有活跃工作');
    expect(data.sessionCount, 2);
    expect(data.runningSessions, 1);
    expect(data.awaitingSessions, 1);
    expect(data.awaitingVerb, '授权');

    await c.agents.confirmStop();
    expect(core.disconnectedAgents, <String>['claude-acp']);
    final perm = c.sessions.pending.byRequestId(
      'claude-acp',
      'req_1',
    ) as PermissionEntry?;
    expect(perm?.status, PendingStatus.withdrawn, reason: '挂起的权限请求标 withdrawn');
    c.dispose();
  });

  test('Stop 失败：走通用 toast 报错，条目回到运行态', () async {
    final core = FakeCore()
      ..processSnapshotResult = _snapshotWith(<String>['pi-acp'])
      ..agentDisconnectError = const CoreCommandError(
        'internal',
        'kill_tree failed',
      );
    final c = await _start(core);
    core.emit(CoreEvent.agentState, <String, dynamic>{
      'agentId': 'pi-acp',
      'state': 'initialized',
      'droppedUpdates': 0,
    });
    await _settle();

    await c.agents.requestStop('pi-acp');
    expect(c.agents.stoppingIds, isEmpty);
    expect(c.agents.isAgentRunning('pi-acp'), isTrue, reason: '失败后条目回到运行态');
    expect(c.toasts.errors, isNotEmpty, reason: '错误进通用 toast');
    expect(c.toasts.errors.last.text, contains('kill_tree failed'));
    c.dispose();
  });

  test(
    'Stop 在途收到旧 exited 并重连出新连接：旧 disconnect 返回后不误伤新连接状态、挂起请求与发送队列',
    () async {
      final gate = Completer<void>();
      final core = FakeCore()
        ..processSnapshotResult = _snapshotWith(<String>['pi-acp'])
        ..agentDisconnectGate = gate;
      final c = await _start(core);
      core.emit(CoreEvent.agentState, <String, dynamic>{
        'agentId': 'pi-acp',
        'state': 'initialized',
        'droppedUpdates': 0,
      });
      await _settle();

      final stopFuture = c.agents.requestStop('pi-acp');
      await _settle();
      expect(c.agents.stoppingIds, contains('pi-acp'));

      // 旧连接退出，紧接着拉起新连接并产生新挂起请求与发送队列。
      core.emit(CoreEvent.agentState, <String, dynamic>{
        'agentId': 'pi-acp',
        'state': 'exited',
        'code': 0,
      });
      core.emit(CoreEvent.agentState, <String, dynamic>{
        'agentId': 'pi-acp',
        'state': 'spawned',
        'pid': 29999,
      });
      core.emit(CoreEvent.agentState, <String, dynamic>{
        'agentId': 'pi-acp',
        'state': 'initialized',
        'droppedUpdates': 0,
      });
      await _settle();

      c.session.registerOwner('s_new', 'pi-acp');
      c.sessions.session('s_new', agentId: 'pi-acp');
      c.turn.queueFor('s_new').enqueue(const <JsonMap>[
        <String, dynamic>{'type': 'text', 'text': 'queued'},
      ]);
      core.emit(CoreEvent.clientRequest, <String, dynamic>{
        'agentId': 'pi-acp',
        'requestId': 'req_new',
        'sessionId': 's_new',
        'method': 'session/request_permission',
        'params': <String, dynamic>{
          'sessionId': 's_new',
          'toolCall': <String, dynamic>{'toolCallId': 'tc_new', 'title': 'Run'},
          'options': <Object?>[
            <String, dynamic>{
              'optionId': 'allow',
              'name': 'Allow',
              'kind': 'allow_once',
            },
          ],
        },
      });
      await _settle();

      // 放行旧连接的 agentDisconnect：新连接的状态、请求与队列均不得被改动。
      gate.complete();
      await stopFuture;
      await _settle();

      expect(c.agents.stoppingIds, isNot(contains('pi-acp')));
      expect(c.agents.isAgentRunning('pi-acp'), isTrue);
      final perm = c.sessions.pending.byRequestId(
        'pi-acp',
        'req_new',
      ) as PermissionEntry?;
      expect(perm?.status, PendingStatus.pending);
      expect(c.turn.queueFor('s_new').isEmpty, isFalse);
      c.dispose();
    },
  );

  test(
    '快速切换 Agents / Files 标签：在途采样未完成时不重复积压 processSnapshot，切回可见时待旧采样结束自动补采',
    () async {
      final gate = Completer<void>();
      final core = FakeCore()
        ..processSnapshotResult = _snapshotWith(<String>['claude-acp'])
        ..processSnapshotGate = gate;
      final c = await _start(core);

      c.shell.openTab(ShellTab.agents);
      await _settle();
      expect(core.processSnapshotCalls, 1);

      // 旧采样未完成期间反复切走再切回：不积压新的并发调用。
      c.shell.openTab(ShellTab.files);
      c.shell.openTab(ShellTab.agents);
      c.shell.openTab(ShellTab.files);
      c.shell.openTab(ShellTab.agents);
      await _settle();
      expect(core.processSnapshotCalls, 1, reason: '旧 Future 在途期间不并发积压');

      // 放行旧采样：旧 epoch 结果丢弃，因当前处于可见态自动补采一次新快照。
      core.processSnapshotGate = null;
      core.processSnapshotResult = _snapshotWith(<String>['pi-acp']);
      gate.complete();
      await _settle();
      expect(core.processSnapshotCalls, 2);
      expect(c.agents.processSnapshot?.agent('pi-acp'), isNotNull);
      c.dispose();
    },
  );

  test('auth_required 与 authenticating 状态：采样失败清空快照后仍识别为运行中并可 Stop', () async {
    final core = FakeCore()
      ..processSnapshotError = const CoreCommandError(
        'internal',
        'sample failed',
      );
    final c = await _start(core);
    core.emit(CoreEvent.agentState, <String, dynamic>{
      'agentId': 'claude-acp',
      'state': 'auth_required',
      'pid': 18324,
      'message': 'need login',
    });
    core.emit(CoreEvent.agentState, <String, dynamic>{
      'agentId': 'pi-acp',
      'state': 'authenticating',
      'pid': 22410,
      'methodId': 'login',
      'terminalId': 'term_auth_1',
    });
    c.shell.openTab(ShellTab.agents);
    await _settle();

    expect(c.agents.processSnapshot, isNull);
    expect(c.agents.isAgentRunning('claude-acp'), isTrue);
    expect(c.agents.isAgentRunning('pi-acp'), isTrue);
    expect(c.agents.runningIds, containsAll(<String>['claude-acp', 'pi-acp']));

    await c.agents.requestStop('claude-acp');
    expect(core.disconnectedAgents, <String>['claude-acp']);
    c.dispose();
  });
}
