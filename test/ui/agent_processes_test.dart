// 画板 54（R10）：`ResourceBar` 四态、`StopAgentConfirm` B1 / B2 两态、`RegistryEntryRow` 运行态 / 连接中 / 停止中 /
// 采样不可用降级 / 进程树展开与内置 agent Stop 按钮的 widget 单测。

import 'package:acp_agent_client/projection/process_snapshot.dart';
import 'package:acp_agent_client/projection/registry.dart';
import 'package:acp_agent_client/ui/registry/registry_entry.dart';
import 'package:acp_agent_client/ui/registry/resource_bar.dart';
import 'package:acp_agent_client/ui/registry/stop_agent_confirm.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const RegistryEntryData _claude = RegistryEntryData(
  id: 'claude-acp',
  name: 'Claude Agent',
  version: '0.78.2',
  description: 'ACP wrapper for Claude.',
  installed: true,
  installedVersion: '0.78.2',
  authStatus: AuthStatus.authenticated,
);

const RegistryEntryData _builtinDsh = RegistryEntryData(
  id: 'dsh-acp',
  name: 'DSH ACP Agent',
  version: '1.3.2',
  description: 'Builtin agent.',
  installed: true,
  installedVersion: '1.3.2',
  builtin: true,
);

ProcessSnapshot _snapshot() => ProcessSnapshot.fromJson(<String, dynamic>{
  'metric': 'private',
  'takenAt': 1760000000000,
  'app': <String, dynamic>{'pid': 1234, 'bytes': 281432064},
  'agents': <Object?>[
    <String, dynamic>{
      'agentId': 'claude-acp',
      'rootPid': 18324,
      'bytes': 641728512,
      'startedAt': 1759995680000,
      'processes': <Object?>[
        <String, dynamic>{
          'pid': 18324,
          'parentPid': 1234,
          'name': 'cmd.exe',
          'bytes': 1990656,
          'depth': 0,
        },
        <String, dynamic>{
          'pid': 18410,
          'parentPid': 18324,
          'name': 'node.exe',
          'bytes': 401185177,
          'depth': 1,
        },
      ],
      'terminals': <Object?>[
        <String, dynamic>{
          'terminalId': 'term_3',
          'pid': 21004,
          'name': 'pwsh.exe',
          'bytes': 57042944,
        },
      ],
    },
  ],
  'terminals': <String, dynamic>{
    'count': 2,
    'bytes': 96048742,
    'items': <Object?>[],
  },
  'other': <String, dynamic>{'bytes': 0},
  'total': 1288000000,
});

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: const MediaQueryData(size: Size(1200, 900)),
      child: Overlay(
        key: UniqueKey(),
        initialEntries: <OverlayEntry>[
          OverlayEntry(
            builder: (_) => Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 680, child: child),
            ),
          ),
        ],
      ),
    ),
  ),
);

Finder _rich(String text) => find.textContaining(text, findRichText: true);

void main() {
  testWidgets('ResourceBar 四态：正常态、C1 无 agent 运行、C2 首次采样中、C3 采样失败与重试点击', (
    WidgetTester tester,
  ) async {
    await _pump(tester, ResourceBar(snapshot: _snapshot()));
    expect(find.text('约 1.2 GB'), findsOneWidget);
    expect(find.text('专用内存 · 每 2 秒采样'), findsOneWidget);
    expect(find.text('本应用 268.4 MB'), findsOneWidget);
    expect(find.text('Agents · 1 个运行中 · 612.0 MB'), findsOneWidget);
    expect(find.text('终端 · 2 个 · 91.6 MB'), findsOneWidget);

    // C1：没有 agent 在运行，且终端数为 0 时终端图例省略。
    final idle = ProcessSnapshot.fromJson(<String, dynamic>{
      'metric': 'private',
      'takenAt': 1760000000000,
      'app': <String, dynamic>{'pid': 1234, 'bytes': 284373811},
      'agents': <Object?>[],
      'terminals': <String, dynamic>{
        'count': 0,
        'bytes': 0,
        'items': <Object?>[],
      },
      'other': <String, dynamic>{'bytes': 0},
      'total': 284373811,
    });
    await _pump(tester, ResourceBar(snapshot: idle));
    expect(find.text('Agents · 无运行'), findsOneWidget);
    expect(find.textContaining('终端 ·'), findsNothing);

    // C2：首次采样中。
    await _pump(tester, ResourceBar());
    expect(find.text('—'), findsOneWidget);
    expect(find.text('采样中…'), findsOneWidget);

    // C3：采样失败 + 点刷新重试。
    var retried = 0;
    await _pump(tester, ResourceBar(error: 'failed', onRetry: () => retried++));
    expect(find.text('无法读取进程信息'), findsOneWidget);
    expect(find.text('原因写进日志；Stop 不受影响'), findsOneWidget);
    await tester.tap(find.byType(GestureDetector).first);
    expect(retried, 1);
  });

  testWidgets(
    'RegistryEntryRow：运行行展开/收起进程树、采样不可用降级、内置 agent 运行中同样出 Stop、连接中与停止中',
    (WidgetTester tester) async {
      final snap = _snapshot().agent('claude-acp')!;
      var toggled = 0;
      var stopped = 0;

      // 展开态：运行中芯片、运行行、进程树行（含缩进与 agent 终端）、Stop + Remove。
      await _pump(
        tester,
        RegistryEntryRow(
          _claude,
          runtime: AgentEntryRuntime(
            phase: AgentRunPhase.running,
            snapshot: snap,
            sessionCount: 2,
            expanded: true,
          ),
          actions: RegistryEntryActions(
            onToggleProcesses: () => toggled++,
            onStop: () => stopped++,
          ),
        ),
      );
      expect(find.text('运行中'), findsOneWidget);
      expect(find.text('PID 18324'), findsOneWidget);
      expect(find.text('3 个进程'), findsOneWidget);
      expect(find.text('约 612.0 MB'), findsOneWidget);
      expect(find.text('已运行 1 小时 12 分'), findsOneWidget);
      expect(find.text('2 个会话'), findsOneWidget);
      expect(_rich('cmd.exe'), findsOneWidget);
      expect(_rich('└ node.exe'), findsOneWidget);
      expect(_rich('pwsh.exe · agent 终端 term_3'), findsOneWidget);
      await tester.tap(find.text('PID 18324'));
      await tester.tap(find.text('Stop'));
      expect(toggled, 1);
      expect(stopped, 1);

      // 采样不可用：只留 PID 18324，无进程数与内存，不可展开。
      await _pump(
        tester,
        const RegistryEntryRow(
          _claude,
          runtime: AgentEntryRuntime(phase: AgentRunPhase.running, pid: 18324),
        ),
      );
      expect(find.text('PID 18324'), findsOneWidget);
      expect(find.textContaining('个进程'), findsNothing);

      // 内置 agent：未运行时无按钮，运行中出 Stop（不出 Remove）。
      await _pump(tester, const RegistryEntryRow(_builtinDsh));
      expect(find.text('Stop'), findsNothing);
      expect(find.text('Remove'), findsNothing);

      await _pump(
        tester,
        const RegistryEntryRow(
          _builtinDsh,
          runtime: AgentEntryRuntime(phase: AgentRunPhase.running, pid: 9999),
        ),
      );
      expect(find.text('Stop'), findsOneWidget);
      expect(find.text('Remove'), findsNothing);

      // 连接中：出「连接中…」，不出 Stop。
      await _pump(
        tester,
        const RegistryEntryRow(
          _builtinDsh,
          runtime: AgentEntryRuntime(phase: AgentRunPhase.connecting),
        ),
      );
      expect(find.text('连接中…'), findsOneWidget);
      expect(find.text('Stop'), findsNothing);

      // B3 停止中：出「正在停止…」与宽限期说明，Stop 置灰禁用。
      var stopTappedWhenDisabled = 0;
      await _pump(
        tester,
        RegistryEntryRow(
          _claude,
          runtime: const AgentEntryRuntime(phase: AgentRunPhase.stopping),
          actions: RegistryEntryActions(onStop: () => stopTappedWhenDisabled++),
        ),
      );
      expect(find.text('正在停止…'), findsOneWidget);
      expect(find.text('先请 agent 自行退出，3 秒后仍在就结束整棵进程树'), findsOneWidget);
      await tester.tap(find.text('Stop'));
      expect(stopTappedWhenDisabled, 0);
    },
  );

  testWidgets('StopAgentConfirm：B1 与 B2 两态文案及按钮动作', (
    WidgetTester tester,
  ) async {
    final actions = <String>[];
    await _pump(
      tester,
      StopAgentConfirm(
        agentName: 'Claude Agent',
        sessionCount: 2,
        processCount: 5,
        bytes: 641728512,
        onCancel: () => actions.add('cancel'),
        onConfirm: () => actions.add('confirm'),
      ),
    );
    expect(find.text('停止 Claude Agent？'), findsOneWidget);
    expect(
      find.textContaining('结束它的全部 5 个进程（约 612.0 MB）。挂在它上面的 2 个会话会断开'),
      findsOneWidget,
    );
    expect(find.text('停止'), findsOneWidget);
    expect(find.text('仍然停止'), findsNothing);
    await tester.tap(find.text('停止'));
    expect(actions, <String>['confirm']);

    await _pump(
      tester,
      StopAgentConfirm(
        agentName: 'Claude Agent',
        sessionCount: 2,
        runningSessions: 1,
        awaitingSessions: 1,
        processCount: 5,
        bytes: 641728512,
        onCancel: () => actions.add('cancel'),
        onConfirm: () => actions.add('confirm2'),
      ),
    );
    expect(
      find.text('1 个会话正在运行回合，1 个会话在等你授权。停止会中断回合，未回答的请求作废，排队的消息清空。'),
      findsOneWidget,
    );
    expect(find.text('仍然停止'), findsOneWidget);
    await tester.tap(find.text('仍然停止'));
    expect(actions, <String>['confirm', 'confirm2']);
  });

  testWidgets('升级中与升级失败：旧连接运行中或停止中时保留升级操作并同时展示 Stop', (
    WidgetTester tester,
  ) async {
    final taps = <String>[];
    final upgrading = _claude.copyWith(
      progress: InstallProgress(
        kind: 'npx',
        step: 'resolve',
        at: DateTime(2026, 10, 18),
        upgrade: true,
      ),
    );
    await _pump(
      tester,
      RegistryEntryRow(
        upgrading,
        runtime: const AgentEntryRuntime(
          phase: AgentRunPhase.running,
          pid: 18324,
        ),
        actions: RegistryEntryActions(
          onStop: () => taps.add('stop'),
          onCancel: () => taps.add('cancel'),
        ),
      ),
    );
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await tester.tap(find.text('取消'));
    expect(taps, <String>['stop', 'cancel']);

    final upgradeFailed = _claude.copyWith(failure: 'npm error ETIMEDOUT');
    await _pump(
      tester,
      RegistryEntryRow(
        upgradeFailed,
        runtime: const AgentEntryRuntime(phase: AgentRunPhase.stopping),
        actions: RegistryEntryActions(
          onStop: () => taps.add('stop_disabled'),
          onRetry: () => taps.add('retry'),
          onViewLog: () => taps.add('log'),
        ),
      ),
    );
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('查看日志'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await tester.tap(find.text('重试'));
    expect(taps, <String>['stop', 'cancel', 'retry']);
  });
}
