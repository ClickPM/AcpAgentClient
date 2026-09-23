// 画板 53（round-board-53 验收 2）：`registry_list` 的 `updateAvailable` / `reloadPending` 与 `registry/progress` 的
// `upgrade` 在投影层的落点——有新版本、升级中（npx 两步）、升级失败（失败了但还是已安装）、名字旁显示本机装着的版本。

import 'package:acp_agent_client/projection/registry.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:flutter_test/flutter_test.dart';

JsonMap _installed(String id, {String registry = '0.78.2', String installed = '0.76.0', String? update, String? reload}) => <String, dynamic>{
      'id': id,
      'name': id,
      'version': registry,
      'description': 'd',
      'distribution': 'npx',
      'supported': true,
      'installed': <String, dynamic>{'kind': 'npx', 'version': installed, 'authStatus': 'authenticated', 'command': 'node', 'args': <String>['x']},
      'installing': false,
      'updateAvailable': update,
      'reloadPending': reload,
    };

JsonMap _notInstalled(String id) => <String, dynamic>{
      'id': id,
      'name': id,
      'version': '0.9.0',
      'description': 'd',
      'distribution': 'npx',
      'supported': true,
      'installed': null,
      'installing': false,
    };

RegistryState _state(List<JsonMap> agents) => RegistryState()..applyList(<String, dynamic>{'agents': agents, 'fetching': false, 'node': <String, dynamic>{}});

void main() {
  test('updateAvailable / reloadPending 落到条目上；已安装的名字旁是本机装着的版本', () {
    final state = _state(<JsonMap>[
      _installed('claude-acp', update: '0.78.2'),
      _installed('codex-acp', registry: '1.12.0', installed: '1.12.0', reload: '1.11.0'),
      _notInstalled('amp-acp'),
    ]);
    final claude = state.byId('claude-acp')!;
    expect(claude.hasUpdate, isTrue);
    expect(claude.displayVersion, '0.76.0');
    expect(claude.upgradeTarget, '0.78.2');
    expect(claude.reloadPending, isNull);

    final codex = state.byId('codex-acp')!;
    expect(codex.hasUpdate, isFalse);
    expect(codex.reloadPending, '1.11.0');
    expect(codex.displayVersion, '1.12.0');

    final amp = state.byId('amp-acp')!;
    expect(amp.hasUpdate, isFalse);
    expect(amp.displayVersion, '0.9.0', reason: '没装的显示 registry 当前版本');
  });

  test('npx 升级只有 resolve / handshake 两步；失败了仍是已安装 = 升级失败；done 撤掉进度', () {
    final state = _state(<JsonMap>[_installed('claude-acp', update: '0.78.2')]);
    state.applyProgress(<String, dynamic>{'agentId': 'claude-acp', 'kind': 'npx', 'step': 'resolve', 'detail': 'pkg@0.78.2', 'upgrade': true});
    var e = state.byId('claude-acp')!;
    expect(e.isUpgrading, isTrue);
    expect(e.progress!.steps, <String>['resolve', 'handshake']);
    expect(e.progress!.stateOf('resolve'), StepState.active);
    expect(e.progress!.stateOf('handshake'), StepState.pending);
    expect(e.progress!.stateOf('write_settings'), StepState.pending, reason: '升级没有这一步');

    state.applyProgress(<String, dynamic>{'agentId': 'claude-acp', 'kind': 'npx', 'step': 'failed', 'error': 'npm error code ETIMEDOUT', 'upgrade': true});
    e = state.byId('claude-acp')!;
    expect(e.isUpgrading, isFalse);
    expect(e.isFailed, isTrue);
    expect(e.isUpgradeFailed, isTrue);
    expect(e.failure, 'npm error code ETIMEDOUT');
    // 重读列表（失败后安装记录没变，仍可升级）：失败态保留在条目上。
    state.applyList(<String, dynamic>{'agents': <JsonMap>[_installed('claude-acp', update: '0.78.2')], 'fetching': false, 'node': <String, dynamic>{}});
    expect(state.byId('claude-acp')!.isUpgradeFailed, isTrue);
    expect(state.byId('claude-acp')!.hasUpdate, isTrue);

    state.applyProgress(<String, dynamic>{'agentId': 'claude-acp', 'kind': 'npx', 'step': 'resolve', 'upgrade': true});
    state.applyProgress(<String, dynamic>{'agentId': 'claude-acp', 'kind': 'npx', 'step': 'done', 'upgrade': true});
    e = state.byId('claude-acp')!;
    expect(e.progress, isNull);
    expect(e.isFailed, isFalse);
  });

  test('首装的进度与失败不算升级；binary 升级同三步', () {
    final state = _state(<JsonMap>[_notInstalled('amp-acp'), _installed('kilo', update: '7.7.0')]);
    state.applyProgress(<String, dynamic>{'agentId': 'amp-acp', 'kind': 'npx', 'step': 'resolve'});
    expect(state.byId('amp-acp')!.isUpgrading, isFalse);
    expect(state.byId('amp-acp')!.progress!.steps, InstallProgress.npxSteps);
    state.applyProgress(<String, dynamic>{'agentId': 'amp-acp', 'kind': 'npx', 'step': 'failed', 'error': 'E404'});
    expect(state.byId('amp-acp')!.isFailed, isTrue);
    expect(state.byId('amp-acp')!.isUpgradeFailed, isFalse, reason: '首装失败会回滚成未安装');

    state.applyProgress(<String, dynamic>{'agentId': 'kilo', 'kind': 'binary', 'step': 'download', 'done': 1, 'total': 2, 'upgrade': true});
    expect(state.byId('kilo')!.isUpgrading, isTrue);
    expect(state.byId('kilo')!.progress!.steps, InstallProgress.binarySteps);
  });
}
