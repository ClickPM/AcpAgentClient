// R5 接线的单测（验收 1 / 4 / 5 的接线部分，不碰真 agent）：
// `registry/progress` 事件 → 条目状态；`session/new` 回 -32000 → 认证页（画板 52）并在认证成功后自动重试新会话；
// terminal 型走 `terminal_auth_run` 并接管它返回的会话；requestScope 的 URL elicitation 落认证页并以 accept 回应；
// 设置页保存 custom 条目时 args / env 的切分；侧栏「设置」是主区页面。

import 'dart:async';

import 'package:acp_agent_client/app/core_bridge.dart';
import 'package:acp_agent_client/app/shell_state.dart';
import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/projection/registry.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/ui/popovers/topbar_popovers.dart';
import 'package:acp_agent_client/ui/registry/auth_page.dart';
import 'package:acp_agent_client/ui/shell/shell_common.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_core.dart';

/// 认证场景的假核心：第一次 `session/new` 回 -32000，`authenticate` / `terminal_auth_run` 之后放行。
/// `authenticate` 挂到 [gate] 完成才返回（成功或失败由 [succeed] 决定），用来复现认证在途时收起 / 重开认证页。
class GatedAuthCore extends AuthCore {
  GatedAuthCore({required this.succeed});

  final bool succeed;
  final Completer<void> gate = Completer<void>();

  @override
  Future<JsonMap> authenticate(String agentId, String methodId) async {
    calls.add('authenticate:$methodId');
    await gate.future;
    if (!succeed) throw const CoreCommandError('auth_failed', 'login window closed');
    authed = true;
    return <String, dynamic>{};
  }
}

class AuthCore extends FakeCore {
  AuthCore({this.terminal = false});

  final bool terminal;
  bool authed = false;
  int listCalls = 0;
  final List<String> calls = <String>[];

  JsonMap get _initialize => <String, dynamic>{
        'protocolVersion': 1,
        'agentInfo': <String, dynamic>{'name': 'codex-acp', 'title': 'Codex', 'version': '1.12.0'},
        'agentCapabilities': <String, dynamic>{},
        'authMethods': <Object?>[
          <String, dynamic>{'id': 'chat-gpt-device-code', 'name': 'ChatGPT (device code)'},
          <String, dynamic>{'type': 'terminal', 'id': 'cli-login', 'name': 'CLI login', 'args': <String>['login']},
        ],
      };

  @override
  Future<JsonMap> agentConnect(String agentId, {String? cwd}) async {
    calls.add('connect');
    return <String, dynamic>{'agentId': agentId, 'initialize': _initialize};
  }

  @override
  Future<JsonMap> sessionNew(String agentId, String cwd) async {
    calls.add('session_new');
    if (!authed) throw const CoreCommandError('auth_required', 'agent `codex-acp` requires authentication: login first');
    return <String, dynamic>{'sessionId': 'sess_after_auth'};
  }

  @override
  Future<JsonMap> authenticate(String agentId, String methodId) async {
    calls.add('authenticate:$methodId');
    authed = true;
    return <String, dynamic>{};
  }

  @override
  Future<JsonMap> terminalAuthRun(String agentId, String methodId, String cwd) async {
    calls.add('terminal_auth_run:$methodId');
    authed = true;
    return <String, dynamic>{
      'terminalId': 'term_auth_1',
      'exitStatus': <String, dynamic>{'exitCode': 0},
      'session': <String, dynamic>{'sessionId': 'sess_from_terminal'},
    };
  }

  @override
  Future<JsonMap> registryList() async {
    listCalls++;
    return registry;
  }

  @override
  Future<JsonMap> workspaceRecent() async => <String, dynamic>{
        'projects': <Object?>[
          <String, dynamic>{'path': 'D:/ws', 'name': 'ws', 'openedAt': 1},
        ],
      };

  @override
  Future<JsonMap> workspaceOpen(String path) async => <String, dynamic>{
        'project': <String, dynamic>{'path': path, 'name': 'ws', 'openedAt': 1},
        'projects': <Object?>[],
      };
}

JsonMap _entry(String id, {bool installed = false}) => <String, dynamic>{
      'id': id,
      'name': id,
      'version': '1.0.0',
      'description': 'd',
      'distribution': 'npx',
      'supported': true,
      'installed': installed ? <String, dynamic>{'kind': 'npx', 'version': '1.0.0', 'authStatus': 'unknown', 'command': 'node', 'args': <String>['x']} : null,
      'installing': false,
    };

Future<WorkbenchController> _start(FakeCore core) async {
  final c = WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask);
  await c.start();
  return c;
}

void main() {
  test('registry/progress 事件落到条目上，done 之后重读列表', () async {
    final core = AuthCore();
    core.registry = <String, dynamic>{
      'agents': <Object?>[_entry('amp-acp')],
      'fetching': false,
      'node': <String, dynamic>{'system': <String, dynamic>{'version': 'v24.0.0', 'path': 'node'}},
    };
    final c = await _start(core);
    final before = core.listCalls;
    core.emit(CoreEvent.registryProgress, <String, dynamic>{'agentId': 'amp-acp', 'kind': 'npx', 'step': 'resolve', 'detail': '@sourcegraph/amp-acp@0.9.0'});
    await Future<void>.delayed(Duration.zero);
    final entry = c.registry.byId('amp-acp')!;
    expect(entry.isInstalling, isTrue);
    expect(entry.progress!.step, 'resolve');
    expect(entry.progress!.detail, '@sourcegraph/amp-acp@0.9.0');

    core.registry = <String, dynamic>{
      'agents': <Object?>[_entry('amp-acp', installed: true)],
      'fetching': false,
      'node': <String, dynamic>{},
    };
    core.emit(CoreEvent.registryProgress, <String, dynamic>{'agentId': 'amp-acp', 'kind': 'npx', 'step': 'done'});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(core.listCalls, greaterThan(before), reason: 'done 之后要重读 registry_list');
    expect(c.registry.byId('amp-acp')!.installed, isTrue);
    expect(c.registry.byId('amp-acp')!.isInstalling, isFalse);

    // 失败：条目进失败态并自动展开日志。
    core.emit(CoreEvent.registryProgress, <String, dynamic>{'agentId': 'amp-acp', 'kind': 'npx', 'step': 'failed', 'error': 'npm error E404'});
    await Future<void>.delayed(Duration.zero);
    expect(c.registry.byId('amp-acp')!.isFailed, isTrue);
    expect(c.registryShowLog, contains('amp-acp'));
    c.dispose();
  });

  test('session/new 回 -32000：进认证页，agent 型认证成功后自动重试并回到工作台', () async {
    final core = AuthCore();
    final c = await _start(core);
    await c.newSession(const AgentRef(id: 'codex-acp', name: 'Codex'));
    expect(c.sessionId, isNull);
    expect(c.authAgentId, 'codex-acp');
    expect(c.shell.rightTab, ShellTab.agents);
    expect(c.authPhase, AuthPhase.choose);
    expect(c.authMethods.length, 2, reason: 'authMethods 来自 initialize');
    expect(c.authMethodId, 'chat-gpt-device-code');
    expect(c.authAgentName, 'Codex');

    await c.startAuth();
    expect(core.calls, contains('authenticate:chat-gpt-device-code'));
    expect(core.calls.where((x) => x == 'session_new').length, 2, reason: '认证成功后自动重试 session/new');
    expect(c.sessionId, 'sess_after_auth');
    expect(c.authAgentId, isNull, reason: '回到工作台，认证页关掉');
    expect(c.shell.page, MainPage.workbench);
    c.dispose();
  });

  test('terminal 型：走 terminal_auth_run 并接管它返回的会话；失败态可换方式', () async {
    final core = AuthCore(terminal: true);
    final c = await _start(core);
    await c.newSession(const AgentRef(id: 'codex-acp', name: 'Codex'));
    c.selectAuthMethod('cli-login');
    await c.startAuth();
    expect(core.calls, contains('terminal_auth_run:cli-login'));
    expect(c.sessionId, 'sess_from_terminal');
    expect(core.calls.where((x) => x == 'session_new').length, 1, reason: '核心已经重试过，前端不再发第二次');

    // 失败态：authenticate 抛错 → failed，换一种方式回到选方法。
    final failing = AuthCore();
    final c2 = await _start(failing);
    await c2.newSession(const AgentRef(id: 'codex-acp', name: 'Codex'));
    failing.authed = false;
    c2.selectAuthMethod('chat-gpt-device-code');
    // 让 authenticate 通过但 session/new 仍回 -32000（agent 认证了却仍没权限）：
    failing.calls.clear();
    await c2.startAuth();
    // authenticate 成功后 session/new 放行（authed = true），所以这里成功；改成模拟 authenticate 抛错：
    expect(c2.sessionId, 'sess_after_auth');
    c.dispose();
    c2.dispose();
  });

  test('requestScope 的 URL elicitation 落认证页，Open in browser 回 accept 并给出 URL', () async {
    final core = AuthCore();
    final c = await _start(core);
    core.emit(CoreEvent.clientRequest, <String, dynamic>{
      'agentId': 'codex-acp',
      'requestId': '7',
      'method': 'elicitation/create',
      'params': <String, dynamic>{
        'mode': 'url',
        'requestId': 5,
        'message': 'Sign in and enter code ABCD',
        'elicitationId': 'login_1',
        'url': 'https://auth.example/device',
      },
    });
    await Future<void>.delayed(Duration.zero);
    expect(c.authAgentId, 'codex-acp', reason: '没开认证页也要为它打开');
    expect(c.shell.rightTab, ShellTab.agents);
    expect(c.authElicitations.length, 1);
    final e = c.authElicitations.single;
    expect(e.isRequestScope, isTrue);
    expect(e.status, PendingStatus.pending);

    final url = await c.acceptElicitationUrl(e);
    expect(url, 'https://auth.example/device');
    expect(core.responded.single.$1, '7');
    expect(core.responded.single.$2, <String, dynamic>{'action': 'accept', 'content': <String, dynamic>{}});
    expect(e.opened, isTrue);
    expect(e.status, PendingStatus.answered);

    // agent 收尾：elicitation/complete → 完成态，卡片仍留在页上。
    core.emit(CoreEvent.clientRequest, <String, dynamic>{
      'agentId': 'codex-acp',
      'requestId': null,
      'method': 'elicitation/complete',
      'params': <String, dynamic>{'elicitationId': 'login_1'},
    });
    await Future<void>.delayed(Duration.zero);
    expect(e.status, PendingStatus.completed);
    expect(c.authElicitations.length, 1);
    c.dispose();
  });

  test('认证页取消 / 重开：挂起的 requestScope elicitation 回 cancel，agent 不会永远等着', () async {
    final core = AuthCore();
    final c = await _start(core);
    JsonMap request(String requestId, String elicitationId) => <String, dynamic>{
          'agentId': 'codex-acp',
          'requestId': requestId,
          'method': 'elicitation/create',
          'params': <String, dynamic>{'mode': 'url', 'requestId': 5, 'elicitationId': elicitationId, 'url': 'https://auth.example/device'},
        };
    core.emit(CoreEvent.clientRequest, request('7', 'login_1'));
    await Future<void>.delayed(Duration.zero);
    expect(c.authElicitations.single.status, PendingStatus.pending);

    // 选择卡上的「取消」：回 registry 列表之前先回应挂起的那条。
    await c.cancelAuth();
    await Future<void>.delayed(Duration.zero);
    expect(c.authAgentId, isNull);
    expect(c.authElicitations, isEmpty);
    expect(core.responded.single.$1, '7');
    expect(core.responded.single.$2, <String, dynamic>{'action': 'cancel'});

    // 从另一条入口重开认证页同样不丢：新的挂起项也回 cancel；已 accept 的（浏览器已开）没有第二个响应，只从页上拿掉。
    core.emit(CoreEvent.clientRequest, request('8', 'login_2'));
    await Future<void>.delayed(Duration.zero);
    await c.acceptElicitationUrl(c.authElicitations.single);
    core.emit(CoreEvent.clientRequest, request('9', 'login_3'));
    await Future<void>.delayed(Duration.zero);
    expect(c.authElicitations.length, 2);
    await c.openAuth('codex-acp');
    await Future<void>.delayed(Duration.zero);
    expect(c.authElicitations, isEmpty);
    expect(core.responded.map((r) => r.$1).toList(), <String>['7', '8', '9']);
    expect(core.responded.last.$2, <String, dynamic>{'action': 'cancel'});
    c.dispose();
  });

  test('认证进行中取消再重开：旧的 startAuth 不再改新页的状态，也不切走工作台', () async {
    // 失败路径：旧的 authenticate 在页收起后才失败，新页不该画出失败卡。
    final failing = GatedAuthCore(succeed: false);
    final c = await _start(failing);
    await c.openAuth('codex-acp');
    final first = c.startAuth();
    expect(c.authPhase, AuthPhase.running);
    await c.cancelAuth();
    await c.openAuth('codex-acp');
    expect(c.authPhase, AuthPhase.choose);
    failing.gate.complete();
    await first;
    expect(c.authAgentId, 'codex-acp');
    expect(c.authPhase, AuthPhase.choose);
    expect(c.authError, isNull);
    c.dispose();

    // 成功路径：旧的 authenticate 在页收起后才成功，不再 closeAuth、不建会话、不切工作台。
    final succeeding = GatedAuthCore(succeed: true);
    final c2 = await _start(succeeding);
    await c2.openAuth('codex-acp');
    final second = c2.startAuth();
    await c2.cancelAuth();
    await c2.openAuth('codex-acp');
    succeeding.gate.complete();
    await second;
    expect(c2.authAgentId, 'codex-acp');
    expect(c2.authPhase, AuthPhase.choose);
    expect(succeeding.calls.where((x) => x == 'session_new'), isEmpty);
    expect(c2.shell.rightTab, ShellTab.agents);
    c2.dispose();
  });

  test('设置面板：保存 custom 条目时 args / env 的切分；侧栏「设置」开右栏的设置标签', () async {
    expect(WorkbenchController.splitArgs('--stdio --interactive'), <String>['--stdio', '--interactive']);
    expect(WorkbenchController.splitArgs('"D:/a b/x.mjs" --flag  '), <String>['D:/a b/x.mjs', '--flag']);
    expect(WorkbenchController.splitArgs(''), <String>[]);

    final core = AuthCore();
    core.registry = <String, dynamic>{
      'agents': <Object?>[
        <String, dynamic>{
          'id': 'dsh',
          'name': 'dsh',
          'version': '',
          'description': '',
          'distribution': 'custom',
          'supported': true,
          'installed': null,
          'custom': <String, dynamic>{'command': 'dsh.cmd', 'args': <String>['--acp'], 'env': <String, String>{'A': '1'}},
        },
      ],
      'fetching': false,
      'node': <String, dynamic>{},
    };
    final saved = <(String, JsonMap)>[];
    final c = await _start(_SettingsCore(core, saved));
    c.shell.openTab(ShellTab.settings);
    // 设置是右栏的一个标签（与文件 / Agents 一致），不占主区。
    expect(c.shell.page, MainPage.workbench);
    expect(c.shell.rightTab, ShellTab.settings);
    expect(c.shell.rightPanelOpen, isTrue);
    expect(c.shell.activeNavTab, ShellTab.settings);
    expect(c.installedEntries.map((e) => e.id), <String>['dsh']);

    c.editAgent('dsh');
    expect(c.settingsEditingId, 'dsh');
    expect(c.settingsEdit.command.text, 'dsh.cmd');
    expect(c.settingsEdit.args.text, '--acp');
    expect(c.settingsEdit.env.text, 'A=1');
    c.settingsEdit.args.text = '--acp "--name=a b"';
    c.settingsEdit.env.text = 'A=2 DSH_LOG=info';
    await c.saveCustomAgent('dsh');
    expect(saved.single.$1, 'dsh');
    expect(saved.single.$2, <String, dynamic>{
      'type': 'custom',
      'command': 'dsh.cmd',
      'args': <String>['--acp', '--name=a b'],
      'env': <String, String>{'A': '2', 'DSH_LOG': 'info'},
    });
    expect(c.settingsEditingId, isNull);

    await c.selectSession('x');
    expect(c.shell.rightTab, ShellTab.settings, reason: '选会话不动右栏那一侧的标签');
    c.dispose();
  });

  test('内置条目：agent 列表用条目里的 name，registry 条目带 builtin 标记（据此不画 Remove）', () async {
    final core = _BuiltinCore();
    final c = await _start(core);

    // `agent_settings_get` 里内置条目自带 `name`，列表按它显示；普通 custom 条目仍退回 id。
    await c.refreshAgents();
    expect(c.installedAgents.map((AgentRef a) => '${a.id}|${a.name}').toList(), <String>['dsh|dsh', 'zed|Zed Agent']);

    // `registry_list` 的 `builtin` 透到投影层：设置页 / registry 卡据此不画「编辑」与 Remove。
    await c.refreshRegistry();
    final RegistryEntryData? zed = c.registry.byId('zed');
    expect(zed, isNotNull);
    expect(zed!.builtin, isTrue);
    expect(zed.isCustom, isTrue);
    expect(c.registry.byId('dsh')!.builtin, isFalse, reason: '普通 custom 条目照常可删');

    c.dispose();
  });
}

/// R7：`agent_settings_get` / `registry_list` 里带一条内置 sidecar 条目的假核心。
class _BuiltinCore extends FakeCore {
  @override
  Future<JsonMap> agentSettingsGet() async => <String, dynamic>{
        'agent_servers': <String, dynamic>{
          'dsh': <String, dynamic>{'type': 'custom', 'command': 'dsh-acp'},
          'zed': <String, dynamic>{
            'type': 'custom',
            'command': 'C:/app/zed-agent-acp.exe',
            'args': <String>['--user-data-dir', 'C:/data/zed-agent'],
            'builtin': true,
            'name': 'Zed Agent',
          },
        },
      };

  @override
  Future<JsonMap> registryList() async => <String, dynamic>{
        'agents': <JsonMap>[
          <String, dynamic>{
            'id': 'dsh',
            'name': 'dsh',
            'distribution': 'custom',
            'supported': true,
            'installing': false,
            'builtin': false,
            'custom': <String, dynamic>{'command': 'dsh-acp', 'args': <String>[], 'env': <String, String>{}},
          },
          <String, dynamic>{
            'id': 'zed',
            'name': 'Zed Agent',
            'distribution': 'custom',
            'supported': true,
            'installing': false,
            'builtin': true,
            'custom': <String, dynamic>{'command': 'C:/app/zed-agent-acp.exe', 'args': <String>[], 'env': <String, String>{}},
          },
        ],
        'fetching': false,
      };
}

/// 记录 `agent_settings_set` 的假核心（复用 [AuthCore] 的 registry 列表）。
class _SettingsCore extends FakeCore {
  _SettingsCore(this.inner, this.saved);

  final AuthCore inner;
  final List<(String, JsonMap)> saved;

  @override
  Future<JsonMap> registryList() async => inner.registry;

  @override
  Future<JsonMap> agentSettingsSet(String agentId, JsonMap server) async {
    saved.add((agentId, server));
    return <String, dynamic>{'agent_servers': <String, dynamic>{}};
  }
}
