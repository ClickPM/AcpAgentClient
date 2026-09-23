// 组合根接线的单测（R3 验收 10）：Restore / Regenerate 截断时，落在截断范围里、仍挂起的请求
// **必须**逐条 `acp_respond`——permission 回 `{outcome: cancelled}`、elicitation 回 `{action: cancel}`，
// 否则 agent 会一直等着（`RestoreResult` 的两组 id，见 lib/projection/session_store.dart 的注释）。
// 另外核对：`session/cancel` 由核心自动回 cancelled，前端不得再回一遍（api.rs 的契约）。

import 'dart:async';
import 'dart:io';

import 'package:acp_agent_client/app/app.dart';
import 'package:acp_agent_client/app/clipboard_image.dart';
import 'package:acp_agent_client/app/composer_state.dart';
import 'package:acp_agent_client/app/core_bridge.dart';
import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/app/workbench_screen.dart';
import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/ui/popovers/inline_menus.dart';
import 'package:acp_agent_client/ui/popovers/topbar_popovers.dart';
import 'package:acp_agent_client/ui/shell/shell_common.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../gallery_harness.dart';
import 'fake_core.dart';

/// 第一次 `session/prompt` 挂着不返回，直到 [release]；用来复现「回合进行中点 Restore」。
class SlowCore extends FakeCore {
  final List<String> order = <String>[];
  final Completer<void> _gate = Completer<void>();
  bool _first = true;

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<JsonMap> sessionPrompt(String agentId, String sessionId, List<Object?> prompt) async {
    order.add('prompt');
    if (_first) {
      _first = false;
      await _gate.future;
      return <String, dynamic>{'stopReason': 'cancelled'};
    }
    return super.sessionPrompt(agentId, sessionId, prompt);
  }

  @override
  Future<JsonMap> sessionCancel(String agentId, String sessionId) {
    order.add('cancel');
    return super.sessionCancel(agentId, sessionId);
  }
}

/// 「装了两个 agent、本地索引里最近一条属于 zed、有一个最近项目」的现场（首次启动的常见样子）。
class _InstalledCore extends FakeCore {
  _InstalledCore() {
    sessionIndex.addAll(<JsonMap>[
      <String, dynamic>{'agentId': 'codex', 'sessionId': 'older', 'title': '旧的', 'updatedAt': 1000, 'cwd': r'D:\proj'},
      <String, dynamic>{'agentId': 'zed', 'sessionId': 'recent', 'title': '最近的', 'updatedAt': 2000, 'cwd': r'D:\proj'},
    ]);
  }

  /// `workspace_recent` 的返回；置空 = 干净机上还没打开过任何目录。
  List<Object?> projects = <Object?>[
    <String, dynamic>{'path': r'D:\proj', 'name': 'proj'},
  ];

  @override
  Future<JsonMap> agentSettingsGet() async => <String, dynamic>{
        'agent_servers': <String, dynamic>{
          'codex': <String, dynamic>{'type': 'custom', 'command': 'codex-acp'},
          'zed': <String, dynamic>{'type': 'custom', 'command': 'zed-agent-acp', 'name': 'Zed Agent'},
        },
      };

  @override
  Future<JsonMap> workspaceRecent() async => <String, dynamic>{'projects': projects};
}

/// 换项目后要补齐的三件（分支 / Rules / 文件树）全都挂在 [gate] 上：用来验「`workspace_open` 一回来就通知」
/// 与「三件是并发的，不是一件等一件」。[peakInFlight] 是同时在飞的命令数的峰值。
class _SlowHydrationCore extends _InstalledCore {
  /// 可以换一个新的：验第二次换项目的窗口时，第一次已经放行过了。
  Completer<void> gate = Completer<void>();
  int inFlight = 0;
  int peakInFlight = 0;

  Future<JsonMap> _gated(JsonMap value) async {
    inFlight++;
    if (inFlight > peakInFlight) peakInFlight = inFlight;
    await gate.future;
    inFlight--;
    return value;
  }

  @override
  Future<JsonMap> workspaceOpen(String path) async => <String, dynamic>{
        'project': <String, dynamic>{'path': path, 'name': 'proj'},
        'projects': projects,
      };

  @override
  Future<JsonMap> gitBranches(String cwd) => _gated(<String, dynamic>{
        'available': true,
        'isRepo': true,
        'current': 'main',
        'branches': <Object?>[
          <String, dynamic>{'name': 'main'},
        ],
      });

  /// Rules 计数与文件树各列一次根目录：两次都走这里，所以两次都被卡住。
  @override
  Future<JsonMap> fsListDir(String r, String path) => _gated(<String, dynamic>{
        'path': path,
        'entries': <Object?>[
          <String, dynamic>{'name': 'CLAUDE.md', 'path': '$path/CLAUDE.md', 'parent': '', 'isDir': false, 'size': 1},
        ],
      });

  @override
  Future<JsonMap> gitStatus(String cwd) =>
      _gated(<String, dynamic>{'available': true, 'isRepo': true, 'root': cwd, 'entries': <Object?>[]});

  @override
  Stream<JsonMap> fsWatch(String r) => const Stream<JsonMap>.empty();
}

/// 转录偏好在 `core_init` 之前到核心会回 not_initialized：复现「读盘排在 init 前面」那个启动顺序。
class _PrefsAfterInitCore extends _InstalledCore {
  _PrefsAfterInitCore() {
    transcriptPrefs = <String, dynamic>{'collapse_finished_turns': false};
  }

  bool initialized = false;

  @override
  Future<JsonMap> init(String dataDir) {
    initialized = true;
    return super.init(dataDir);
  }

  @override
  Future<JsonMap> transcriptPrefsGet() {
    if (!initialized) throw StateError('not_initialized: call core_init(data_dir) first');
    return super.transcriptPrefsGet();
  }
}

/// `session/new` 挂着不回，直到 [gate] 完成：复现「等待期里做别的事」。
class _GatedNewCore extends _InstalledCore {
  final Completer<JsonMap> gate = Completer<JsonMap>();

  @override
  Future<JsonMap> sessionNew(String agentId, String cwd) => gate.future;
}

/// `session/prompt` 直接抛错（连接断了 / agent 已退出）。
class FailingCore extends FakeCore {
  @override
  Future<JsonMap> sessionPrompt(String agentId, String sessionId, List<Object?> prompt) async {
    throw StateError('not_connected');
  }
}

const String _agent = 'a';
const String _session = 'sess_1';

/// 建一个「一轮里既有挂起的 permission 又有挂起的 elicitation」的控制器。
/// `running: false` = 这一轮已经结束、但两条请求还挂着（Restore 的 `_respondCancelled` 走这条路）。
/// 第三个返回值是那条用户气泡（Restore / Regenerate 的截断点就是它，见 `SessionStore.restoreTo`）。
(WorkbenchController, FakeCore, MessageEntry) _scenario({bool running = true}) {
  final core = FakeCore();
  final c = WorkbenchController(source: DataSource.bridge, bridge: core)
    ..session.agentId = _agent
    ..session.sessionId = _session;
  final store = c.sessions.session(_session, agentId: _agent);
  store.startTurn(<ContentBlockWire>[
    const ContentBlockWire(<String, dynamic>{'type': 'text', 'text': '原始提示'}),
  ]);
  final bubble = store.entries.whereType<MessageEntry>().first;
  c.sessions.applyClientRequestEnvelope(<String, dynamic>{
    'agentId': _agent,
    'requestId': 'req_perm',
    'method': 'session/request_permission',
    'params': <String, dynamic>{
      'sessionId': _session,
      'toolCall': <String, dynamic>{'toolCallId': 'call_1', 'title': '删文件'},
      'options': <Object?>[
        <String, dynamic>{'optionId': 'ok', 'name': 'Allow', 'kind': 'allow_once'},
      ],
    },
  });
  c.sessions.applyClientRequestEnvelope(<String, dynamic>{
    'agentId': _agent,
    'requestId': 'req_elic',
    'method': 'elicitation/create',
    'params': <String, dynamic>{
      'mode': 'form',
      'message': '选一个环境',
      'sessionId': _session,
      'requestedSchema': <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}},
    },
  });
  if (!running) store.endTurn(stopReason: 'end_turn');
  return (c, core, bubble);
}

/// `@` 菜单的过期判据用：`fs_search` 回结果**之前**先跑一下 [beforeReturn]，
/// 用来复现「用户在等 fs 的这几十到几百毫秒里改了词 / 点走了」。
class _StaleFsCore extends FakeCore {
  _StaleFsCore(this.beforeReturn);

  final void Function() beforeReturn;
  int searches = 0;

  @override
  Future<JsonMap> fsSearch(String root, String query, {int limit = 10}) async {
    searches++;
    beforeReturn();
    return <String, dynamic>{
      'files': <Object?>[
        <String, dynamic>{'path': r'D:\proj\a.dart', 'name': 'a.dart', 'parent': 'proj', 'isDir': false},
      ],
      'directories': <Object?>[],
    };
  }
}

/// `+` → Files & Directories 用：根目录一层一个文件、一个目录（`fs_list_dir` 的线上形状）。
class _RootListingCore extends FakeCore {
  final List<String> listed = <String>[];

  @override
  Future<JsonMap> fsListDir(String root, String path) async {
    listed.add(path);
    return <String, dynamic>{
      'path': path,
      'entries': <Object?>[
        <String, dynamic>{'name': 'scripts', 'path': r'D:\proj\scripts', 'parent': 'proj', 'isDir': true},
        <String, dynamic>{'name': 'README.md', 'path': r'D:\proj\README.md', 'parent': 'proj', 'isDir': false},
      ],
    };
  }
}

void main() {
  test('轮已结束但请求还挂着时 Restore：两组 id 都要 acp_respond（permission cancelled / elicitation cancel）', () async {
    final (c, core, bubble) = _scenario(running: false);
    final store = c.sessions.session(_session);
    expect(store.pending.forSession(_session).length, 2, reason: '两条都还挂着');

    await c.turn.restore(bubble);

    final byId = <String, JsonMap>{for (final r in core.responded) r.$1: r.$2};
    expect(byId.keys.toSet(), <String>{'req_perm', 'req_elic'}, reason: '一条都不能漏，否则 agent 挂起');
    expect(byId['req_perm'], <String, dynamic>{'outcome': <String, dynamic>{'outcome': 'cancelled'}});
    expect(byId['req_elic']!['action'], 'cancel');
    expect(store.pending.forSession(_session), isEmpty);
    expect(core.cancels, 0, reason: '轮已经结束，不该再发 session/cancel');
    // 截断后用原 prompt 同会话重发。
    expect(core.prompts.single.length, 1);
    expect((core.prompts.single.single as JsonMap)['text'], '原始提示');
    c.dispose();
  });

  test('Regenerate 用新文本重发，同样先回应被截断的挂起请求', () async {
    final (c, core, bubble) = _scenario(running: false);
    await c.turn.restore(bubble, newText: '改过的提示');

    expect(core.responded.length, 2);
    expect(core.prompts.single.length, 1);
    expect((core.prompts.single.single as JsonMap)['text'], '改过的提示');
    c.dispose();
  });

  test('session/load 重放回来的历史（一条轮边界都没有）也能 Restore / Regenerate（所有者报障 2026-09-18）', () async {
    final core = FakeCore();
    final c = WorkbenchController(source: DataSource.bridge, bridge: core)
      ..session.agentId = _agent
      ..session.sessionId = _session;
    final store = c.sessions.session(_session, agentId: _agent);
    // 重放的形状：只有 agent 发来的 update，客户端一次 startTurn 都没做过。
    for (final u in <JsonMap>[
      <String, dynamic>{'sessionUpdate': 'user_message_chunk', 'content': <String, dynamic>{'type': 'text', 'text': '第一句'}},
      <String, dynamic>{'sessionUpdate': 'agent_message_chunk', 'content': <String, dynamic>{'type': 'text', 'text': '答第一句'}},
      <String, dynamic>{'sessionUpdate': 'user_message_chunk', 'content': <String, dynamic>{'type': 'text', 'text': '第二句'}},
      <String, dynamic>{'sessionUpdate': 'agent_message_chunk', 'content': <String, dynamic>{'type': 'text', 'text': '答第二句'}},
    ]) {
      store.applyUpdateJson(u);
    }
    expect(store.entries.whereType<TurnEntry>(), isEmpty, reason: '轮边界回不来（docs/design.md § 3）');
    final bubbles = store.entries.whereType<MessageEntry>().where((m) => m.role == MessageRole.user).toList();

    await c.turn.restore(bubbles.last, newText: '改过的第二句');

    expect(core.prompts.single.length, 1, reason: '点了要真发出去，不能是死键');
    expect((core.prompts.single.single as JsonMap)['text'], '改过的第二句');
    // 被截断的那条气泡与它后面的回答都没了，重发的那一轮接在第一轮后面。
    final texts = store.entries.whereType<MessageEntry>().map((m) => m.text).toList();
    expect(texts, <String>['第一句', '答第一句', '改过的第二句']);
    c.dispose();
  });

  test('重放回来的历史按 ↺ 原样重发：用那条气泡自己的块', () async {
    final core = FakeCore();
    final c = WorkbenchController(source: DataSource.bridge, bridge: core)
      ..session.agentId = _agent
      ..session.sessionId = _session;
    final store = c.sessions.session(_session, agentId: _agent);
    store.applyUpdateJson(<String, dynamic>{
      'sessionUpdate': 'user_message_chunk',
      'content': <String, dynamic>{'type': 'text', 'text': '原样这句'},
    });

    await c.turn.restore(store.entries.whereType<MessageEntry>().single);

    expect((core.prompts.single.single as JsonMap)['text'], '原样这句');
    c.dispose();
  });

  test('轮还在进行时 Restore：权限交给核心的 cancel、elicitation 前端回 cancel，队列清空', () async {
    final (c, core, bubble) = _scenario();
    final store = c.sessions.session(_session);
    expect(store.isRunning, isTrue);

    await c.turn.restore(bubble);

    final byId = <String, JsonMap>{for (final r in core.responded) r.$1: r.$2};
    expect(core.cancels, 1, reason: '先把在途那一轮收掉');
    expect(byId.keys.toSet(), <String>{'req_elic'}, reason: 'req_perm 由核心 session_cancel 自动回，前端再回会撞 unknown_request');
    expect(byId['req_elic'], <String, dynamic>{'action': 'cancel'});
    expect(store.pending.forSession(_session), isEmpty);
    c.dispose();
  });

  test('session/cancel：权限交给核心，elicitation 前端必须自己回 cancel（审查 finding high）', () async {
    final (c, core, _) = _scenario();
    await c.turn.cancel();

    expect(core.cancels, 1);
    // 权限请求由核心 session_cancel 自动回 cancelled，前端再回一遍会撞 unknown_request。
    expect(core.responded.map((r) => r.$1), isNot(contains('req_perm')));
    // elicitation 核心不管：不回 agent 会一直等着。
    final byId = <String, JsonMap>{for (final r in core.responded) r.$1: r.$2};
    expect(byId.keys.toSet(), <String>{'req_elic'});
    expect(byId['req_elic'], <String, dynamic>{'action': 'cancel'});
    c.dispose();
  });

  test('回合进行中点 Restore：先 cancel 并等在途的 session/prompt 结束，再截断重发（审查 finding high）', () async {
    final core = SlowCore();
    final c = WorkbenchController(source: DataSource.bridge, bridge: core)
      ..session.agentId = _agent
      ..session.sessionId = _session;
    final store = c.sessions.session(_session, agentId: _agent);
    c.composer.editor.text = '第一轮';
    final sending = c.turn.send();
    expect(store.isRunning, isTrue);
    final bubble = store.entries.whereType<MessageEntry>().first;

    // 第一轮还没返回就点 Restore。
    final restoring = c.turn.restore(bubble, newText: '改过的提示');
    core.release();
    await Future.wait(<Future<void>>[sending, restoring]);

    expect(core.cancels, 1, reason: '截断之前要把在途那一轮收掉');
    expect(core.order, <String>['prompt', 'cancel', 'prompt'], reason: '两次 prompt 不能重叠');
    final turns = store.entries.whereType<TurnEntry>().toList();
    expect(turns.length, 1, reason: '旧轮被截断，只剩重发的那一轮');
    expect(turns.single.stopReason, 'end_turn',
        reason: '剩下的是重发那一轮、带它自己的结束值；先返回的那次（cancelled）没有打到它头上');
    c.dispose();
  });

  test('session/prompt 失败也要收轮，否则会话头一直转 spinner（审查第 2 轮 finding P2）', () async {
    final core = FailingCore();
    final c = WorkbenchController(source: DataSource.bridge, bridge: core)
      ..session.agentId = _agent
      ..session.sessionId = _session;
    final store = c.sessions.session(_session, agentId: _agent);
    c.composer.editor.text = '会失败的一轮';

    await c.turn.send();

    expect(store.isRunning, isFalse, reason: 'currentTurn 不收，停止键与 spinner 就永远去不掉');
    final turn = store.entries.whereType<TurnEntry>().single;
    expect(turn.endedAt, isNotNull);
    expect(turn.stopReason, isNull, reason: '连接断了没有协议给的结束值，不编一个');
    expect(turn.error, contains('not_connected'),
        reason: '原因必须落在轮上：lastError 界面上没人读，只记它等于什么都没说（2026-09-18）');
    expect(c.turn.lastError, contains('not_connected'));
    c.dispose();
  });

  test('无已安装 agent：空态 + 「打开 Agents 面板」切右栏 Agents 标签（验收 7）', () async {
    final core = FakeCore(); // agentSettingsGet 回空 agent_servers
    final c = WorkbenchController(source: DataSource.bridge, bridge: core);
    await c.start();

    expect(c.agents.installed, isEmpty);
    expect(c.session.hasAgent, isFalse, reason: '画板 01 状态 2：会话头 No Agent、输入框禁用');
    expect(c.session.sessionTitle, 'No Agent');
    expect(c.session.composerPlaceholder, '安装并选择一个 agent 后即可输入');
    expect(c.shell.rightTab, isNull);

    c.shell.openTab(ShellTab.agents);
    expect(c.shell.rightTab, ShellTab.agents);
    expect(c.shell.openTabs, <ShellTab>[ShellTab.agents]);
    c.dispose();
  });

  test('装着 agent 时启动：画板 01 状态 1（不是「还没有已安装的 agent」），会话等第一条消息才开', () async {
    final core = _InstalledCore();
    final c = WorkbenchController(source: DataSource.bridge, bridge: core);
    await c.start();

    expect(c.session.hasAgent, isTrue, reason: '状态 2 只在一个 agent 都没装时出现');
    expect(c.session.agentId, 'zed', reason: '本地索引里最近用过、且还装着的那个');
    expect(c.session.hasSession, isFalse, reason: '启动不拉 agent 进程');
    expect(c.session.sessionTitle, 'New Zed Agent Session', reason: '展示名从已安装列表来，不是裸 id');
    expect(c.session.canCompose, isTrue);
    expect(c.session.composerPlaceholder, 'Message to Zed Agent , @ to include context , / for commands');

    c.composer.editor.text = '第一条';
    await c.turn.send();

    expect(c.session.sessionId, 'sess_fake', reason: '第一条消息把会话现开出来');
    expect(core.prompts.single.length, 1);
    expect((core.prompts.single.single as JsonMap)['text'], '第一条');
    c.dispose();
  });

  test('装着 agent 但还没选项目：输入框禁用并说明原因，发送不静默失败', () async {
    final core = _InstalledCore()..projects = const <Object?>[];
    final c = WorkbenchController(source: DataSource.bridge, bridge: core);
    await c.start();

    expect(c.session.hasAgent, isTrue);
    expect(c.workspace.project, isNull);
    expect(c.session.canCompose, isFalse);
    expect(c.session.composerPlaceholder, '先选一个项目目录，新会话的 cwd 从它来');

    c.composer.editor.text = '发不出去';
    await c.turn.send();
    expect(c.session.sessionId, isNull);
    expect(core.prompts, isEmpty);
    expect(c.composer.editor.text, '发不出去', reason: '没发出去就不能把输入清掉');
    c.dispose();
  });

  test('换项目：侧栏只留当前目录下的会话，正开着的别的目录的会话从会话区放下', () async {
    final core = _InstalledCore()
      ..sessionIndex.add(<String, dynamic>{
        'agentId': 'zed',
        'sessionId': 'other',
        'title': '别的项目里的',
        'updatedAt': 1500,
        'cwd': r'D:\other',
      });
    final c = WorkbenchController(source: DataSource.bridge, bridge: core);
    await c.start();
    expect(c.workspace.project?.path, r'D:\proj');
    expect(c.session.sidebarSessions.map((s) => s.id), unorderedEquals(<String>['older', 'recent']), reason: '别的目录下的会话不露出来');

    c.session.sessionId = 'recent';
    // 同一个目录换种写法（分隔符 / 尾斜杠）：还是这个 workspace，会话与侧栏都不动。
    await c.workspace.openProject(const ProjectRef(path: 'D:/proj/', name: 'proj'));
    expect(c.session.sessionId, 'recent');
    expect(c.session.sidebarSessions.map((s) => s.id), unorderedEquals(<String>['older', 'recent']));

    await c.workspace.openProject(const ProjectRef(path: r'D:\other', name: 'other'));
    expect(c.session.sidebarSessions.map((s) => s.id), <String>['other']);
    expect(c.session.sessionId, isNull, reason: '正开着的会话属于旧目录：会话区回到空态，下一条消息在新目录里现开');
    expect(c.session.canCompose, isTrue, reason: '空态下照样能发：agent 与项目都在');

    await c.workspace.openProject(const ProjectRef(path: r'D:\proj', name: 'proj'));
    expect(c.session.sidebarSessions.map((s) => s.id), unorderedEquals(<String>['older', 'recent']));
    expect(c.session.sessionId, isNull, reason: '切回来不替用户自动选会话');
    c.dispose();
  });

  test('换项目：workspace_open 一回来就通知，分支 / Rules / 文件树并发在后台补齐', () async {
    final core = _SlowHydrationCore();
    final c = WorkbenchController(source: DataSource.bridge, bridge: core);
    var notifications = 0;
    c.addListener(() => notifications++);

    final opening = c.workspace.openProject(const ProjectRef(path: r'D:\proj', name: 'proj'));
    await pumpEventQueue();
    expect(c.workspace.project?.path, r'D:\proj', reason: '`workspace_open` 只是往本地索引写一条，回来就该认这个项目');
    expect(notifications, greaterThan(0), reason: '顶栏项目名与输入框的 canCompose 不等分支与文件树');
    expect(c.workspace.branchAreaVisible, isFalse, reason: '这时三件都还卡着');
    expect(core.peakInFlight, 3, reason: '分支 / Rules 列根 / 文件树列根同时在飞，不是一件等一件');

    core.gate.complete();
    await opening;
    expect(c.workspace.branch, 'main');
    expect(c.workspace.rulesCount, 1);
    expect(c.files.root, r'D:\proj');
    c.dispose();
  });

  test('换项目的补齐窗口里不留旧项目的分支表：那会儿点弹层的一行会对新项目跑 git switch（审查 P2 2026-09-22）', () async {
    final core = _SlowHydrationCore();
    final c = WorkbenchController(source: DataSource.bridge, bridge: core);
    // 第一个项目整个补齐：分支区可见、分支表里有 main。
    final first = c.workspace.openProject(const ProjectRef(path: r'D:\proj', name: 'proj'));
    core.gate.complete();
    await first;
    expect(c.workspace.branchAreaVisible, isTrue);
    expect(c.workspace.branches.map((b) => b.name), <String>['main']);
    expect(c.workspace.rulesCount, 1);

    // 换到第二个项目，三件补齐全卡住：`workspace_open` 回来的那一下顶栏已经是新项目了。
    core.gate = Completer<void>();
    final second = c.workspace.openProject(const ProjectRef(path: r'D:\other', name: 'other'));
    await pumpEventQueue();
    expect(c.workspace.project?.path, r'D:\other');
    expect(c.workspace.branchAreaVisible, isFalse, reason: '补齐回来之前分支区不渲染');
    expect(c.workspace.branch, isNull);
    expect(c.workspace.branches, isEmpty, reason: '旧项目的分支表还挂着的话，这段窗口里 switchBranch 会拿新项目的 cwd 去 git switch');
    expect(c.workspace.rulesCount, 0);

    core.gate.complete();
    await second;
    expect(c.workspace.branch, 'main');
    expect(c.workspace.rulesCount, 1);
    c.dispose();
  });

  test('转录偏好在 core_init 之后才读：盘上存的「关」读得回来、开关也存得下（发布前审查 high 2026-09-22）', () async {
    final core = _PrefsAfterInitCore();
    final c = WorkbenchController(source: DataSource.bridge, bridge: core);
    await c.start();
    await pumpEventQueue();
    expect(c.folds.autoCollapse, isFalse, reason: '读盘排在 core_init 前面那一下核心回 not_initialized，盘上的「关」就读不回来');
    await c.folds.setAutoCollapse(true);
    expect(core.transcriptPrefs, <String, dynamic>{'collapse_finished_turns': true}, reason: '启动那一趟读失败会让开关永远不落盘');
    c.dispose();
  });

  test('换项目时正在改名的那条不在新目录里：改名态一起撤掉（合并复审 2026-09-18）', () async {
    final core = _InstalledCore();
    final c = WorkbenchController(source: DataSource.bridge, bridge: core);
    await c.start();
    c.session.startRename('recent');
    expect(c.session.renamingSessionId, 'recent');
    await c.workspace.openProject(const ProjectRef(path: r'D:\other', name: 'other'));
    expect(c.session.renamingSessionId, isNull, reason: '那一行随侧栏一起没了，改名态不能悬着');
    await c.workspace.openProject(const ProjectRef(path: r'D:\proj', name: 'proj'));
    expect(c.session.renamingSessionId, isNull);
    c.dispose();
  });

  test('等待期里换项目被挡住：在途的 session/new 回来后仍挂在原目录、侧栏里找得到（合并复审 2026-09-18）', () async {
    final core = _GatedNewCore();
    final c = WorkbenchController(source: DataSource.bridge, bridge: core);
    await c.start();
    final creating = c.session.newSession(const AgentRef(id: 'zed', name: 'Zed Agent'));
    expect(c.session.waitingForAgent, isTrue);
    await c.workspace.openProject(const ProjectRef(path: r'D:\other', name: 'other'));
    expect(c.workspace.project?.path, r'D:\proj', reason: '等待期里不换项目：不然回来的会话挂在旧目录、侧栏里找不到');
    core.gate.complete(<String, dynamic>{'sessionId': 'fresh'});
    await creating;
    expect(c.session.waitingForAgent, isFalse);
    expect(c.session.sessionId, 'fresh');
    expect(c.session.sidebarSessions.map((s) => s.id), contains('fresh'));
    await c.workspace.openProject(const ProjectRef(path: r'D:\other', name: 'other'));
    expect(c.workspace.project?.path, r'D:\other');
    expect(c.session.sessionId, isNull);
    c.dispose();
  });

  test('权限与 elicitation 的回应载荷原样来自投影层', () async {
    final (c, core, _) = _scenario();
    await c.turn.answerPermission('req_perm', 'ok');
    await c.turn.answerElicitation('req_elic', 'accept', <String, dynamic>{'env': 'dev'});

    final byId = <String, JsonMap>{for (final r in core.responded) r.$1: r.$2};
    expect(byId['req_perm'], <String, dynamic>{
      'outcome': <String, dynamic>{'outcome': 'selected', 'optionId': 'ok'},
    });
    expect(byId['req_elic'], <String, dynamic>{
      'action': 'accept',
      'content': <String, dynamic>{'env': 'dev'},
    });
    c.dispose();
  });

  // 分栏宽度（画板 04 的把手，所有者裁定 2026-09-16）：夹取与落盘时机都在组合根，widget 只报位移。
  test('分栏宽度：夹取在范围内、松手才落盘、下次启动读回', () async {
    final core = FakeCore();
    final c = WorkbenchController(source: DataSource.bridge, bridge: core);

    c.shell.resizeSidebar(1000);
    expect(c.shell.sidebarWidth, t.Geometry.sidebarMaxWidth, reason: '拖过头也不能超上限');
    c.shell.resizeRightPanel(-1000);
    expect(c.shell.rightPanelWidth, t.Geometry.rightPanelMinWidth, reason: '往回拖也不能低于下限');
    expect(core.uiState, isEmpty, reason: '拖拽途中不落盘');

    await c.shell.saveUiState();
    expect(core.uiState['sidebarWidth'], t.Geometry.sidebarMaxWidth);
    expect(core.uiState['rightPanelWidth'], t.Geometry.rightPanelMinWidth);

    c.shell.resetSidebarWidth();
    expect(c.shell.sidebarWidth, t.Geometry.sidebarWidth, reason: '双击复位到画板缺省');
    // 复位自己就该落盘（双击之后没有「松手」）。这里不能再补一次 saveUiState：
    // 补了的话，把复位里那次落盘删掉，这条用例照样绿。
    await pumpEventQueue();
    expect(core.uiState['sidebarWidth'], t.Geometry.sidebarWidth, reason: '复位要自己落盘');
    c.dispose();

    final next = WorkbenchController(source: DataSource.bridge, bridge: core);
    await next.start();
    expect(next.shell.rightPanelWidth, t.Geometry.rightPanelMinWidth, reason: '下次启动读回上次拖出来的宽度');
    expect(next.shell.sidebarWidth, t.Geometry.sidebarWidth);
    next.dispose();
  });

  test('ui-state.json 里的宽度落在范围外时按 token 夹一遍（改过 token 的旧文件）', () async {
    final core = FakeCore()..uiState = <String, dynamic>{'sidebarWidth': 99999, 'rightPanelWidth': 1};
    final c = WorkbenchController(source: DataSource.bridge, bridge: core);
    await c.start();
    expect(c.shell.sidebarWidth, t.Geometry.sidebarMaxWidth);
    expect(c.shell.rightPanelWidth, t.Geometry.rightPanelMinWidth);
    c.dispose();
  });

  // 所有者手测 2026-09-16：Release 里满屏文字挂着黄色双下划线。`MaterialApp` 把「没有 Material 祖先」的
  // 兜底样式（红字 + 黄色双下划线）装成环境 `DefaultTextStyle`，而这个壳一个 Material widget 都不用；
  // `Text` 的 token 样式只覆盖字体与字号，`decoration` 原样继承下来。组合根必须自己铺一层基准字样。
  testWidgets('组合根铺了无装饰的基准字样（不吃 MaterialApp 的黄线兜底）', (tester) async {
    // 默认 800×600 的测试视口装不下整壳（侧栏 280 + 右栏 580），按画板的 1440×900 来。
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // flutter_tester 不装包字体也不做 CJK 回退，缺字体时侧栏底部导航会算宽 21px 撑破（gallery_harness 的注释）。
    await tester.runAsync(loadGalleryFonts);
    await tester.pumpWidget(AcpApp(source: DataSource.bridge, bridge: FakeCore()));

    final style = DefaultTextStyle.of(tester.element(find.byType(WorkbenchScreen))).style;
    expect(style.decoration, anyOf(isNull, TextDecoration.none), reason: '继承到下划线就是满屏黄线');
    expect(style.fontFamily, t.Fonts.sans, reason: '基准字样只能来自 token');
  });

  testWidgets('装着 agent 时开应用，主区是状态 1 的新会话空态，不是「还没有已安装的 agent」', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(loadGalleryFonts);
    await tester.pumpWidget(AcpApp(source: DataSource.bridge, bridge: _InstalledCore()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('还没有已安装的 agent'), findsNothing, reason: '所有者 2026-09-17 报的：装了 agent 还画状态 2');
    expect(find.text('New Zed Agent Session'), findsWidgets, reason: '会话头与空态标题都是它');
  });

  // ---------------------------------------------------------------- 输入框（ComposerState）的两条回归

  ComposerState composerOn(CoreCommands bridge) => ComposerState(
        bridge: bridge,
        store: () => null, // 没有会话：`@` 的根回落到下面这个项目目录
        cwd: () => r'D:\proj',
        canCompose: () => true,
        canPromptImage: () => true,
      );

  group('从文件选择器加图的大小门与张数门（BACKLOG P0，门在 ComposerState、判在 base64 之前）', () {
    test('超上限：不进 pendingBlocks，记 lastError', () {
      final c = composerOn(FakeCore());

      c.addImageBytes(Uint8List(clipboardImageSizeLimit + 1), 'image/png', path: r'D:\proj\huge.png');

      expect(c.pendingBlocks, isEmpty, reason: '超了就不该整块塞进 session/prompt');
      expect(c.lastError, '图片太大，没有加进输入框', reason: '与剪贴板那条路同一句、不写死 MB 数');
      c.dispose();
    });

    test('刚好不超（= 上限）：照常加进去，lastError 不动', () {
      final c = composerOn(FakeCore());

      c.addImageBytes(Uint8List(clipboardImageSizeLimit), 'image/png', path: r'D:\proj\ok.png');

      expect(c.pendingBlocks, hasLength(1), reason: '门是「严格大于」才拦，边界这一张要放行');
      expect(c.pendingBlocks.single['type'], 'image');
      expect(c.pendingBlocks.single['mimeType'], 'image/png');
      expect((c.pendingBlocks.single['data'] as String).isNotEmpty, isTrue, reason: '放行的这张才编码');
      expect(c.lastError, isNull);
      c.dispose();
    });

    test('张数门（一条消息最多 promptImageCountLimit 张，与剪贴板共用）：满了再挑一张不收，记张数提示', () {
      final c = composerOn(FakeCore());
      for (var i = 0; i < promptImageCountLimit; i++) {
        c.addImageBytes(Uint8List(1), 'image/png');
      }
      expect(c.pendingImages, hasLength(promptImageCountLimit), reason: '边界这一张要放行');
      expect(c.lastError, isNull);

      c.addImageBytes(Uint8List(1), 'image/png', path: r'D:\proj\one-more.png');

      expect(c.pendingImages, hasLength(promptImageCountLimit));
      expect(c.lastError, '一条消息最多带 $promptImageCountLimit 张图，多出来的没有加进输入框');
      c.dispose();
    });
  });

  // 锁的是「正文里的 token 变了就丢结果」这一条，不是整条 BACKLOG 症状：Esc / 点外面不动正文，
  // 一个字没改时这条判据判不出来，那半边仍记在 BACKLOG（审查 P2，2026-09-22）。
  group('`@` 菜单的过期判据（改词 / 清空之后回来的 fs 结果要丢掉）', () {
    // 产品里 `onChanged` 是 `EditableText` 在把新值写进 controller **之后**回调的，两者永远一致；
    // 过期判据就是拿回调时的 token 和事后的 `editor.text` 比，所以这里也得照这个顺序来。
    Future<void> type(ComposerState c, String text) {
      c.editor.text = text;
      return c.onChanged(text);
    }

    test('fs 结果回来时光标处的 token 已经变了：丢掉结果，不开菜单也不通知', () async {
      late final ComposerState c;
      // 等结果的这段时间里用户把 `@ab` 改成了别的话：回来的这份属于已经不存在的那个 token。
      final core = _StaleFsCore(() => c.editor.text = '换个说法 ');
      c = composerOn(core);
      var notifications = 0;
      c.addListener(() => notifications++);

      await type(c, '@ab');

      expect(core.searches, 1, reason: '查询本身照发，改的只是回来之后写不写回');
      expect(c.inlineMenuOpen, isFalse, reason: '结果属于已经不存在的那个 token，菜单不该自己弹出来');
      expect(c.inlineMenu, isNull);
      expect(notifications, 0, reason: '丢掉的结果不写回也不 touch');
      c.dispose();
    });

    test('词没变：同一条路照常把菜单开出来（反面，锁住上面那桩不是「永远不写回」）', () async {
      final core = _StaleFsCore(() {});
      final c = composerOn(core);

      await type(c, '@ab');

      expect(core.searches, 1);
      expect(c.inlineMenuOpen, isTrue);
      expect(c.inlineMenu, isA<MentionMenu>());
      c.dispose();
    });
  });

  // 所有者报障 2026-09-23：原生文件对话框点目录只会进到下一级，目录加不进来；改成弹 `@` 菜单（照 Zed）。
  group('`+` → Files & Directories：插 `@` 弹菜单，目录也能挑', () {
    test('空输入框：正文成 `@`，菜单列根目录一层；挑目录得到指向目录的 resource_link', () async {
      final core = _RootListingCore();
      final c = composerOn(core);

      await c.startMention();

      expect(c.editor.text, '@');
      expect(c.editor.selection, const TextSelection.collapsed(offset: 1), reason: '光标在 `@` 之后，接着打字就是搜索');
      expect(core.listed, <String>[r'D:\proj'], reason: '裸 `@` 列的是项目根一层');
      expect(c.inlineMenu, isA<MentionMenu>());

      // 高亮顺序是「文件在前、目录在后」（与 MentionMenu 的拼接一致）：往下一格就是 scripts/。
      c.moveInlineMenuSelection(1);
      c.pickInlineMenuSelection();

      expect(c.editor.text, '@scripts ');
      expect(c.pendingBlocks, hasLength(1));
      expect(c.pendingBlocks.single['type'], 'resource_link');
      expect(c.pendingBlocks.single['name'], 'scripts');
      expect(c.pendingBlocks.single['uri'], Uri.file(r'D:\proj\scripts', windows: true).toString());
      expect(c.inlineMenuOpen, isFalse);
      c.dispose();
    });

    test('已有正文：`@` 前补一个空格，否则 token 粘在上一个词上认不出来', () async {
      final c = composerOn(_RootListingCore());
      c.editor.text = '看看';

      await c.startMention();

      expect(c.editor.text, '看看 @');
      expect(c.inlineMenuOpen, isTrue);
      c.dispose();
    });

    test('正文以空白结尾：不再多补空格', () async {
      final c = composerOn(_RootListingCore());
      c.editor.text = '看看\n';

      await c.startMention();

      expect(c.editor.text, '看看\n@');
      expect(c.inlineMenuOpen, isTrue);
      c.dispose();
    });
  });

  // 所有者 2026-09-23：资源管理器里复制的文件 / 目录 Ctrl+V 进输入框，默认按路径引用（项目外的也加得进来）。
  group('Ctrl+V 粘贴复制的文件与目录：按路径加成 resource_link', () {
    const window = MethodChannel('acp/window');
    late Directory tmp;
    late String dir;
    late String png;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      tmp = Directory.systemTemp.createTempSync('acp_paste_');
      dir = (Directory('${tmp.path}${Platform.pathSeparator}outside dir')..createSync()).path;
      png = (File('${tmp.path}${Platform.pathSeparator}shot.png')..writeAsBytesSync(<int>[1, 2, 3])).path;
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      // 剪贴板里没有文本（资源管理器复制文件时本来就不带 CF_UNICODETEXT）。
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
      messenger.setMockMethodCallHandler(window, (call) async => <Object?>[
            <Object?, Object?>{'path': dir},
            <Object?, Object?>{'path': png},
          ]);
    });
    tearDown(() {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockMethodCallHandler(window, null);
      tmp.deleteSync(recursive: true);
    });

    test('agent 不收图：目录与图片文件都成 `@名字` + resource_link，顺序照剪贴板', () async {
      final c = ComposerState(
        bridge: FakeCore(),
        store: () => null,
        cwd: () => r'D:\proj',
        canCompose: () => true,
        canPromptImage: () => false,
      );

      await c.pasteFromClipboard();

      expect(c.editor.text, '@outside dir @shot.png ');
      expect(c.pendingBlocks.map((b) => b['type']), <String>['resource_link', 'resource_link']);
      expect(c.pendingBlocks.map((b) => b['name']), <String>['outside dir', 'shot.png']);
      expect(c.pendingBlocks.first['uri'], Uri.file(dir, windows: true).toString());
      expect(c.pendingImages, isEmpty);
      expect(c.lastError, isNull);
      c.dispose();
    });

    test('先点 Files & Directories 开着 `@` 菜单再粘贴：菜单关掉，Enter 不会去挑菜单项（审查 P2）', () async {
      final c = ComposerState(
        bridge: _RootListingCore(),
        store: () => null,
        cwd: () => r'D:\proj',
        canCompose: () => true,
        canPromptImage: () => false,
      );
      await c.startMention();
      expect(c.inlineMenuOpen, isTrue, reason: '前提：菜单开着');

      await c.pasteFromClipboard();

      expect(c.editor.text, '@outside dir @shot.png ', reason: '触发用的裸 `@` 被第一条补全吃掉，不留在正文里发出去');
      expect(c.inlineMenuOpen, isFalse);
      expect(c.inlineMenu, isNull);
      c.pickInlineMenuSelection(); // Enter 走的那条：菜单已关，什么都不该发生
      expect(c.pendingBlocks.map((b) => b['name']), <String>['outside dir', 'shot.png']);
      c.dispose();
    });

    test('正文里已有话再敲 `@` 后粘贴：只吃掉末尾那个裸 `@`，前面的话原样留着', () async {
      final c = ComposerState(
        bridge: FakeCore(),
        store: () => null,
        cwd: () => r'D:\proj',
        canCompose: () => true,
        canPromptImage: () => false,
      );
      c.editor.text = '看看 @';

      await c.pasteFromClipboard();

      expect(c.editor.text, '看看 @outside dir @shot.png ');
      c.dispose();
    });
  });
}
