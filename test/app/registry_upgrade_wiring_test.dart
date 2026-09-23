// 画板 53 / 50 的接线（round-board-53 验收 4，不碰真 agent）：Update → `registry_update`；失败态的「重试」按升级 / 首装分流；
// 标题行的检查更新 → `registry_refresh(force)` 且期间是「检查中」；打开 Agents 标签 → 节流的 `registry_refresh`；
// 待重载的 agent 重连 / 退出 → 重读列表把提示撤掉，别的 agent 进出不白读。

import 'dart:async';

import 'package:acp_agent_client/app/core_bridge.dart';
import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/ui/shell/shell_common.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_core.dart';

class UpgradeCore extends FakeCore {
  final List<String> calls = <String>[];
  int listCalls = 0;
  final List<bool> refreshes = <bool>[];

  /// 挂着的联网刷新（用例手动放行，看「检查中」）。
  Completer<void>? refreshGate;

  @override
  Future<JsonMap> registryList() async {
    listCalls++;
    return registry;
  }

  @override
  Future<JsonMap> registryRefresh({bool force = false}) async {
    refreshes.add(force);
    await refreshGate?.future;
    return registry;
  }

  @override
  Future<JsonMap> registryInstall(String agentId) async {
    calls.add('install:$agentId');
    return <String, dynamic>{'agentId': agentId, 'started': true};
  }

  @override
  Future<JsonMap> registryUpdate(String agentId) async {
    calls.add('update:$agentId');
    return <String, dynamic>{'agentId': agentId, 'started': true};
  }
}

JsonMap _entry(String id, {bool installed = true, String? update, String? reload}) => <String, dynamic>{
      'id': id,
      'name': id,
      'version': '2.0.0',
      'description': 'd',
      'distribution': 'npx',
      'supported': true,
      'installed': installed ? <String, dynamic>{'kind': 'npx', 'version': '1.0.0', 'authStatus': 'unknown', 'command': 'node', 'args': <String>['x']} : null,
      'installing': false,
      'updateAvailable': update,
      'reloadPending': reload,
    };

Future<WorkbenchController> _start(UpgradeCore core, List<JsonMap> agents) async {
  core.registry = <String, dynamic>{'agents': agents, 'fetching': false, 'node': <String, dynamic>{}};
  final c = WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask);
  await c.start();
  // 启动时后台那次联网刷新（不 await）落定，下面的计数从干净的起点开始。
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  return c;
}

Future<void> _settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('Update → registry_update；重试：升级失败走升级、首装失败走首装', () async {
    final core = UpgradeCore();
    final c = await _start(core, <JsonMap>[_entry('claude-acp', update: '2.0.0'), _entry('amp-acp', installed: false)]);
    await c.agents.upgrade('claude-acp');
    expect(core.calls, <String>['update:claude-acp']);

    core.emit(CoreEvent.registryProgress, <String, dynamic>{'agentId': 'claude-acp', 'kind': 'npx', 'step': 'failed', 'error': 'x', 'upgrade': true});
    core.emit(CoreEvent.registryProgress, <String, dynamic>{'agentId': 'amp-acp', 'kind': 'npx', 'step': 'failed', 'error': 'y'});
    await _settle();
    expect(c.agents.registry.byId('claude-acp')!.isUpgradeFailed, isTrue);
    expect(c.agents.registry.byId('amp-acp')!.isUpgradeFailed, isFalse);
    await c.agents.retry('claude-acp');
    await c.agents.retry('amp-acp');
    expect(core.calls, <String>['update:claude-acp', 'update:claude-acp', 'install:amp-acp']);
    c.dispose();
  });

  test('检查更新：registry_refresh(force) 期间是「检查中」，已在检查就不再发', () async {
    final core = UpgradeCore();
    final c = await _start(core, <JsonMap>[_entry('claude-acp')]);
    core.refreshes.clear();
    core.refreshGate = Completer<void>();
    final pending = c.agents.checkForUpdates();
    await _settle();
    expect(c.agents.registry.fetching, isTrue);
    await c.agents.checkForUpdates();
    expect(core.refreshes, <bool>[true], reason: '在途时再点不再发');
    core.refreshGate!.complete();
    await pending;
    expect(c.agents.registry.fetching, isFalse);
    c.dispose();
  });

  test('打开 Agents 标签 → 节流的 registry_refresh；已经在这个标签上不再发', () async {
    final core = UpgradeCore();
    final c = await _start(core, <JsonMap>[_entry('claude-acp')]);
    core.refreshes.clear();
    c.shell.openTab(ShellTab.agents);
    await _settle();
    expect(core.refreshes, <bool>[false]);
    c.shell.openTab(ShellTab.agents);
    await _settle();
    expect(core.refreshes, <bool>[false], reason: '没有换标签');
    c.shell.openTab(ShellTab.files);
    c.shell.openTab(ShellTab.agents);
    await _settle();
    expect(core.refreshes, <bool>[false, false]);
    c.dispose();
  });

  test('待重载的 agent 重连 / 退出 → 重读列表；别的 agent 进出不读', () async {
    final core = UpgradeCore();
    final c = await _start(core, <JsonMap>[_entry('claude-acp', reload: '1.0.0'), _entry('amp-acp')]);
    final before = core.listCalls;
    core.emit(CoreEvent.agentState, <String, dynamic>{'agentId': 'amp-acp', 'state': 'initialized', 'droppedUpdates': 0, 'initialize': <String, dynamic>{}});
    await _settle();
    expect(core.listCalls, before, reason: 'amp-acp 没有待重载');
    core.registry = <String, dynamic>{
      'agents': <JsonMap>[_entry('claude-acp'), _entry('amp-acp')],
      'fetching': false,
      'node': <String, dynamic>{},
    };
    core.emit(CoreEvent.agentState, <String, dynamic>{'agentId': 'claude-acp', 'state': 'initialized', 'droppedUpdates': 0, 'initialize': <String, dynamic>{}});
    await _settle();
    expect(core.listCalls, greaterThan(before));
    expect(c.agents.registry.byId('claude-acp')!.reloadPending, isNull);
    c.dispose();
  });
}
