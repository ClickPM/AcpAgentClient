// 画板 54（R10）：`process_snapshot` 投影层与 `RegistryFilter.running` 的纯 Dart 单测。

import 'package:acp_agent_client/projection/process_snapshot.dart';
import 'package:acp_agent_client/projection/registry.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:flutter_test/flutter_test.dart';

JsonMap _sampleSnapshotJson() => <String, dynamic>{
  'metric': 'private',
  'takenAt': 1760000000000,
  'app': <String, dynamic>{'pid': 1234, 'bytes': 280000000},
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
    'items': <Object?>[
      <String, dynamic>{
        'terminalId': 'term_1',
        'source': 'local',
        'pid': 3001,
        'bytes': 48000000,
      },
      <String, dynamic>{
        'terminalId': 'term_2',
        'source': 'auth',
        'pid': 3002,
        'bytes': 48048742,
      },
    ],
  },
  'other': <String, dynamic>{'bytes': 1432064},
  'total': 1019209318,
};

void main() {
  test('归属与合计：app + other 归本应用段，agent 子树与 agent 终端归该 agent，0 字节段不画', () {
    final snap = ProcessSnapshot.fromJson(_sampleSnapshotJson());
    expect(snap.metric, MemoryMetric.private);
    expect(snap.metricLabel, '专用内存');
    expect(snap.metricSummary, '专用内存 · 每 2 秒采样');
    expect(snap.metricTooltip, contains('Private Bytes'));
    expect(snap.appBytes, 281432064, reason: 'app.bytes + other.bytes 归本应用段');
    expect(snap.agentsBytes, 641728512);
    expect(snap.terminalsBytes, 96048742);
    expect(snap.terminalCount, 2);
    expect(snap.showTerminalsLegend, isTrue);
    expect(snap.totalBytes, 1019209318);
    expect(snap.barSegments.map((s) => s.kind).toList(), <ResourceSegmentKind>[
      ResourceSegmentKind.app,
      ResourceSegmentKind.agents,
      ResourceSegmentKind.terminals,
    ]);

    final claude = snap.agent('claude-acp')!;
    expect(claude.rootPid, 18324);
    expect(claude.processCount, 3, reason: '2 个子进程 + 1 个 agent 终端');
    expect(claude.uptimeText(), '已运行 1 小时 12 分');
    expect(claude.rows, hasLength(3));
    expect(claude.rows[0].isIndented, isFalse);
    expect(claude.rows[0].prefix, '');
    expect(claude.rows[1].isIndented, isTrue);
    expect(claude.rows[1].prefix, '└ ');
    expect(claude.rows[2].isAgentTerminal, isTrue);
    expect(claude.rows[2].depth, 0, reason: 'agent 终端顶层显示');
    expect(claude.rows[2].terminalSuffix, ' · agent 终端 term_3');
  });

  test(
    'C1 无 agent 与无终端：0 字节段从 barSegments 省略，终端数为 0 时省略终端图例；resident 口径切换',
    () {
      final snap = ProcessSnapshot.fromJson(<String, dynamic>{
        'metric': 'resident',
        'takenAt': 1760000000000,
        'app': <String, dynamic>{'pid': 1234, 'bytes': 271200000},
        'agents': <Object?>[],
        'terminals': <String, dynamic>{
          'count': 0,
          'bytes': 0,
          'items': <Object?>[],
        },
        'other': <String, dynamic>{'bytes': 0},
      });
      expect(snap.metric, MemoryMetric.resident);
      expect(snap.metricLabel, '常驻内存');
      expect(snap.metricTooltip, contains('Resident Memory'));
      expect(snap.runningAgentCount, 0);
      expect(snap.showTerminalsLegend, isFalse);
      expect(snap.totalBytes, 271200000);
      expect(
        snap.barSegments.map((s) => s.kind).toList(),
        <ResourceSegmentKind>[ResourceSegmentKind.app],
      );
    },
  );

  test('采样不可用降级与运行时长格式化', () {
    const fallback = AgentEntryRuntime(
      phase: AgentRunPhase.running,
      pid: 18324,
    );
    expect(fallback.hasSample, isFalse);
    expect(fallback.canExpand, isFalse);
    expect(fallback.effectivePid, 18324);
    expect(fallback.processCount, isNull);
    expect(fallback.bytes, isNull);

    expect(formatProcessUptime(const Duration(seconds: 45)), '已运行 < 1 分');
    expect(formatProcessUptime(const Duration(minutes: 26)), '已运行 26 分');
    expect(formatProcessUptime(const Duration(hours: 2)), '已运行 2 小时');
    expect(
      formatProcessUptime(const Duration(hours: 1, minutes: 12)),
      '已运行 1 小时 12 分',
    );
  });

  test('RegistryState.visible 支持 RegistryFilter.running', () {
    final state = RegistryState()
      ..entries = const <RegistryEntryData>[
        RegistryEntryData(
          id: 'claude-acp',
          name: 'Claude Agent',
          version: '1.0.0',
          description: '',
          installed: true,
        ),
        RegistryEntryData(
          id: 'pi-acp',
          name: 'pi ACP',
          version: '1.0.0',
          description: '',
          installed: true,
        ),
        RegistryEntryData(
          id: 'amp-acp',
          name: 'Amp',
          version: '1.0.0',
          description: '',
          installed: false,
        ),
      ];
    final running = state.visible(
      RegistryFilter.running,
      '',
      runningIds: const <String>{'pi-acp'},
    );
    expect(running.map((e) => e.id).toList(), <String>['pi-acp']);
    final notInstalled = state.visible(
      RegistryFilter.notInstalled,
      '',
      runningIds: const <String>{'pi-acp'},
    );
    expect(notInstalled.map((e) => e.id).toList(), <String>['amp-acp']);
  });
}
