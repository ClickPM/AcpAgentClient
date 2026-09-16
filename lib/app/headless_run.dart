// R3 的无头实跑（验收 3 / 4 / 5 / 6 / 10）：`ACP_R3_REPORT=<报告文件>` 时不起窗口，直接驱动
// [WorkbenchController]——也就是 UI 点下去会走的那条接线——对真实 agent 跑一遍完整流程，把每步结果写 JSON。
// 和 R0 的 `ACP_SMOKE_REPORT` 是同一个口子的第二个模式：无头、写报告、退出码即结论。
//
// 为什么走控制器而不是直接调桥：要验的就是「接线」本身（谁发 acp_respond、cancel 之后谁不再回、
// Restore 的两组 id 有没有漏），直接调桥等于绕过被验对象。
//
// 环境变量（都可选，除 REPORT 外都有缺省）：
//   ACP_R3_REPORT     报告文件路径（必填，给了才进本模式）
//   ACP_R3_AGENT      agent id，缺省取 settings.json 里的第一个
//   ACP_R3_CWD        项目目录，缺省取 projects.json 里最近的一个
//   ACP_R3_CONFIG     `id=value` 逗号分隔，session/new 之后逐条 set_config_option（value 是 JSON 或 select 的 value id）
//   ACP_R3_PROMPT     第一轮提示词
//   ACP_R3_PROMPT2    第二轮提示词（发出后到点发 session/cancel）
//   ACP_R3_CANCEL_AFTER  第二轮多久后取消（秒，缺省 4）
//   ACP_R3_PERMISSION allow_once | allow_always | reject_once | reject_always | none（缺省 allow_once）
//   ACP_R3_NEW_BRANCH 给了就在当前项目里 `git switch -c <name>`，再切回原分支（验收 5）
//   ACP_R3_KILL       `1` = 第一轮之后 taskkill 掉 agent 进程树，等 exited 事件，再重载看能不能起回来（验收 6）
//   ACP_R3_TIMEOUT    单步超时（秒，缺省 120）

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../projection/agent_state.dart';
import '../projection/entries.dart';
import '../ui/popovers/topbar_popovers.dart';
import '../ui/registry/auth_page.dart';
import 'core_bridge.dart';
import 'workbench_controller.dart';

const String r3ReportEnv = 'ACP_R3_REPORT';
const String r5ReportEnv = 'ACP_R5_REPORT';

String? r5ReportPathFromEnvironment() {
  final v = Platform.environment[r5ReportEnv];
  return (v == null || v.trim().isEmpty) ? null : v.trim();
}

/// R5 的无头实跑（验收 1–6 的接线部分）：驱动 [WorkbenchController] 走一遍 registry → 安装 → 新会话 → 认证 → 一轮 → Remove，
/// 每步结果写 JSON。与 R3 同一个口子的第三个模式。
///
/// 环境变量（都可选，除 REPORT 外都有缺省）：
///   ACP_R5_REPORT        报告文件路径（必填）
///   ACP_R5_CWD           项目目录（缺省 projects.json 里最近的一个）
///   ACP_R5_REFRESH       `1` = 联网刷新 registry（force）
///   ACP_R5_NODE_DOWNLOAD `1` = 下载受管 Node（验收 3）
///   ACP_R5_INSTALL       要安装的 registry id（验收 1 / 2），装完等 done / failed / cancelled
///   ACP_R5_CANCEL_AFTER  安装开始 N 秒后取消（验证取消路径；按时间，落点看机器快慢）
///   ACP_R5_CANCEL_AT     看到某个安装步骤（resolve / write_settings / handshake / download …）的进度事件就取消（确定性落点）
///   ACP_R5_AGENT         起会话的 agent id（缺省 = ACP_R5_INSTALL）
///   ACP_R5_AUTH_METHOD   `-32000` 时用的方法 id（缺省第一个）
///   ACP_R5_AUTH_INPUT    terminal 型：拉起后延时写进终端的一行（模拟键盘）
///   ACP_R5_AUTH_INPUT_DELAY  写入前等待秒数（缺省 5）
///   ACP_R5_AUTH_TIMEOUT  等认证完成的秒数（缺省 300；agent 型的浏览器登录要人来点）
///   ACP_R5_PROMPT        一轮提示词
///   ACP_R5_IMPORT_ZED    `1` = 从 Zed 导入（验收 4）
///   ACP_R5_REMOVE        `1` = 末尾 Remove 安装的 agent（验收 5）
///   ACP_R5_TIMEOUT       单步超时（秒，缺省 600）
Future<void> runR5({required String reportPath}) async {
  final report = <String, dynamic>{'ok': false, 'steps': <String, dynamic>{}};
  final steps = report['steps'] as Map<String, dynamic>;
  final timeout = Duration(seconds: _envInt('ACP_R5_TIMEOUT', 600));
  var exitCode = 1;
  WorkbenchController? controller;
  try {
    final bridge = await CoreBridge.load();
    final c = WorkbenchController(source: DataSource.bridge, bridge: bridge, scheduler: WorkbenchController.scheduleOnMicrotask);
    controller = c;
    await c.start();
    final cwd = _env('ACP_R5_CWD');
    if (cwd != null) await c.openProject(_projectOf(cwd));
    if (_env('ACP_R5_REFRESH') == '1') await c.refreshRegistry(network: true, force: true).timeout(timeout);
    steps['registry'] = _registrySummary(c);

    // ---- 受管 Node（验收 3）
    if (_env('ACP_R5_NODE_DOWNLOAD') == '1') {
      final before = c.registry.node;
      await c.downloadNode().timeout(timeout);
      steps['nodeDownload'] = <String, dynamic>{
        'before': <String, dynamic>{'system': before.system?.version, 'managed': before.managed?.version},
        'after': <String, dynamic>{'system': c.registry.node.system?.version, 'managed': c.registry.node.managed?.version, 'managedPath': c.registry.node.managed?.path},
        'error': c.lastError,
      };
    }

    // ---- 安装（验收 1 / 2）
    final install = _env('ACP_R5_INSTALL');
    if (install != null) {
      final seen = <String>[];
      final watch = _ProgressWatch(c, bridge, install, seen, cancelAt: _env('ACP_R5_CANCEL_AT'));
      watch.attach();
      final started = DateTime.now();
      await c.installAgent(install);
      final cancelAfter = _envInt('ACP_R5_CANCEL_AFTER', 0);
      if (cancelAfter > 0) Timer(Duration(seconds: cancelAfter), () => c.cancelInstall(install));
      await watch.done.future.timeout(timeout);
      watch.detach();
      // 收尾事件之后组合根会（不等待地）重读列表；这里再读一次，`installed` 才是落盘后的状态。
      await c.refreshRegistry();
      final entry = c.registry.byId(install);
      steps['install'] = <String, dynamic>{
        'agentId': install,
        'stepsSeen': seen,
        'elapsedMs': DateTime.now().difference(started).inMilliseconds,
        'installed': entry?.installed,
        'installedVersion': entry?.installedVersion,
        'launch': entry?.launch == null ? null : <String, dynamic>{'command': entry!.launch!.command, 'args': entry.launch!.args},
        'failure': entry?.failure,
        'error': c.lastError,
      };
    }

    // ---- 新会话（-32000 → 认证页）
    final agentId = _env('ACP_R5_AGENT') ?? install;
    if (agentId != null && (cwd != null || c.project != null)) {
      await c.newSession(AgentRef(id: agentId, name: agentId)).timeout(timeout);
      steps['newSession'] = <String, dynamic>{
        'sessionId': c.sessionId,
        'authRequired': c.authAgentId == agentId,
        'authMethods': <String?>[for (final m in c.authMethods) '${m['id']}/${AuthPage.methodType(m)}'],
        'rightTab': c.rightTab?.name,
        'error': c.lastError,
      };
      if (c.authAgentId == agentId) {
        final methodId = _env('ACP_R5_AUTH_METHOD') ?? c.authMethodId;
        if (methodId != null) c.selectAuthMethod(methodId);
        final input = _env('ACP_R5_AUTH_INPUT');
        final urls = <String>[];
        final elicitation = _ElicitationWatch(c, urls)..attach();
        if (input != null) {
          Timer(Duration(seconds: _envInt('ACP_R5_AUTH_INPUT_DELAY', 5)), () => c.authTerminalInput('$input\r'));
        }
        final authStarted = DateTime.now();
        await c.startAuth().timeout(Duration(seconds: _envInt('ACP_R5_AUTH_TIMEOUT', 300)));
        elicitation.detach();
        steps['auth'] = <String, dynamic>{
          'methodId': methodId,
          'phase': c.authPhase.name,
          'error': c.authError,
          'elapsedMs': DateTime.now().difference(authStarted).inMilliseconds,
          'requestScopeUrls': urls,
          'terminalId': c.authTerminalId,
          'sessionId': c.sessionId,
          'authPageClosed': c.authAgentId == null,
          'authStatus': c.registry.byId(agentId)?.authStatus.wire,
        };
      }
    }

    // ---- 一轮（验收 1 / 2 的「一轮对话」）
    final prompt = _env('ACP_R5_PROMPT');
    if (prompt != null && c.sessionId != null) {
      final answers = <Map<String, dynamic>>[];
      final watcher = _AutoAnswer(c, 'allow_once', answers)..attach();
      c.composer.text = prompt;
      await c.send().timeout(timeout);
      watcher.detach();
      steps['turn'] = _turnSummary(c, prompt)..['answers'] = answers;
    }

    // ---- 从 Zed 导入（验收 4）
    if (_env('ACP_R5_IMPORT_ZED') == '1') {
      final before = c.registry.entries.where((e) => e.installed).map((e) => e.id).toList();
      await c.importZed().timeout(timeout);
      steps['importZed'] = <String, dynamic>{
        'zedSettingsPath': c.zedSettingsPath,
        'result': c.zedImportResult,
        'installedBefore': before,
        'installedAfter': c.registry.entries.where((e) => e.installed).map((e) => e.id).toList(),
        'error': c.lastError,
      };
    }

    // ---- Remove（验收 5）
    if (_env('ACP_R5_REMOVE') == '1' && install != null) {
      final dir = '${c.dataDir}${Platform.pathSeparator}agents${Platform.pathSeparator}$install';
      final existedBefore = Directory(dir).existsSync();
      await c.removeAgent(install).timeout(timeout);
      final settings = await bridge.agentSettingsGet();
      steps['remove'] = <String, dynamic>{
        'agentId': install,
        'dirExistedBefore': existedBefore,
        'dirExistsAfter': Directory(dir).existsSync(),
        'settingsHasEntry': (settings['agent_servers'] as Map?)?.containsKey(install) ?? false,
        'installedNow': c.registry.byId(install)?.installed,
        'otherDirs': Directory('${c.dataDir}').listSync().map((e) => e.path.split(Platform.pathSeparator).last).toList()..sort(),
        'error': c.lastError,
      };
    }

    steps['registryAfter'] = _registrySummary(c);
    report['ok'] = true;
    exitCode = 0;
  } catch (e, st) {
    report['error'] = e.toString();
    report['stack'] = st.toString();
    report['lastError'] = controller?.lastError;
  }
  try {
    final file = File(reportPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  } on Object catch (_) {
    exitCode = 1;
  }
  exit(exitCode);
}

Map<String, dynamic> _registrySummary(WorkbenchController c) => <String, dynamic>{
      'count': c.registry.entries.length,
      'installed': c.registry.entries.where((e) => e.installed).map((e) => '${e.id}:${e.kind.wire}:${e.authStatus.wire}').toList(),
      'fetchError': c.registry.fetchError,
      'fetchedAt': c.registry.fetchedAt?.toIso8601String(),
      'node': <String, dynamic>{'system': c.registry.node.system?.version, 'managed': c.registry.node.managed?.version, 'systemError': c.registry.node.systemError},
      'paths': <String, dynamic>{'dataDir': c.dataDir, 'logPath': c.logPath, 'zed': c.zedSettingsPath},
      'sample': <String>[for (final e in c.registry.entries.take(6)) '${e.id} v${e.version} ${e.kind.wire}${e.supported ? '' : ' unsupported'}'],
    };

/// 盯着一个条目的安装进度，收到终态就放行。
/// 直接听 `registry/progress` 原始事件（投影在 done / cancelled 到达时会把进度清空，从投影上分不出这两种收尾——
/// 2026-09-16 实测按投影推断把 done 认成了 cancelled）。`cancelAt` 指定的步骤一到就发取消，落点确定。
class _ProgressWatch {
  _ProgressWatch(this.c, this.bridge, this.agentId, this.seen, {this.cancelAt});

  final WorkbenchController c;
  final CoreBridge bridge;
  final String agentId;
  final List<String> seen;
  final String? cancelAt;
  final Completer<void> done = Completer<void>();
  StreamSubscription<CoreEventRecord>? _sub;
  String? _last;
  bool _cancelSent = false;

  void attach() => _sub = bridge.on(CoreEvent.registryProgress).listen(_onEvent);

  void detach() {
    unawaited(_sub?.cancel());
    _sub = null;
  }

  void _onEvent(CoreEventRecord e) {
    final json = e.json;
    if (json == null || json['agentId'] != agentId) return;
    final step = json['step'] as String? ?? '';
    final terminal = step == 'done' || step == 'failed' || step == 'cancelled';
    final key = terminal ? step : '${json['kind']}:$step';
    if (key != _last) {
      _last = key;
      final progress = json['done'] is num && json['total'] is num ? ' ${json['done']}/${json['total']}' : '';
      seen.add('$key$progress');
    }
    if (!_cancelSent && cancelAt != null && step == cancelAt) {
      _cancelSent = true;
      seen.add('(cancel sent at $step)');
      unawaited(c.cancelInstall(agentId));
    }
    if (terminal && !done.isCompleted) done.complete();
  }
}

/// requestScope 的 URL elicitation 一到就 accept 并记下 URL（无头没有浏览器，人要自己打开）。
class _ElicitationWatch {
  _ElicitationWatch(this.c, this.urls);

  final WorkbenchController c;
  final List<String> urls;
  final Set<String> _done = <String>{};

  void attach() => c.addListener(_tick);

  void detach() => c.removeListener(_tick);

  void _tick() {
    for (final e in c.authElicitations) {
      if (e.status != PendingStatus.pending || !_done.add(e.requestId)) continue;
      unawaited(c.acceptElicitationUrl(e).then((url) {
        if (url != null) {
          urls.add(url);
          stderr.writeln('[r5] open in browser: $url');
        }
      }));
    }
  }
}

String? r3ReportPathFromEnvironment() {
  final v = Platform.environment[r3ReportEnv];
  return (v == null || v.trim().isEmpty) ? null : v.trim();
}

String? _env(String name) {
  final v = Platform.environment[name];
  return (v == null || v.trim().isEmpty) ? null : v.trim();
}

int _envInt(String name, int fallback) => int.tryParse(_env(name) ?? '') ?? fallback;

Future<void> runR3({required String reportPath}) async {
  final report = <String, dynamic>{'ok': false, 'steps': <String, dynamic>{}};
  final steps = report['steps'] as Map<String, dynamic>;
  final timeout = Duration(seconds: _envInt('ACP_R3_TIMEOUT', 120));
  var exitCode = 1;
  WorkbenchController? controller;
  try {
    final bridge = await CoreBridge.load();
    // 无头进程没有 vsync：按帧批量的调度器永远不回调，改用微任务。
    final c = WorkbenchController(
      source: DataSource.bridge,
      bridge: bridge,
      scheduler: WorkbenchController.scheduleOnMicrotask,
    );
    controller = c;
    await c.start();
    steps['start'] = <String, dynamic>{
      'agents': <String>[for (final a in c.installedAgents) a.id],
      'project': c.project?.path,
      'branchAreaVisible': c.branchAreaVisible,
      'branch': c.branch,
      'branches': <String>[for (final b in c.branches) b.name],
      'rulesCount': c.rulesCount,
      'sidebarSessions': c.sidebarSessions.length,
    };

    // ---- 项目（验收 5：切项目后新会话的 cwd 正确）
    final cwd = _env('ACP_R3_CWD');
    if (cwd != null) {
      await c.openProject(_projectOf(cwd));
      steps['openProject'] = <String, dynamic>{
        'path': c.project?.path,
        'branchAreaVisible': c.branchAreaVisible,
        'branch': c.branch,
        'branches': <String>[for (final b in c.branches) b.name],
        // 画板 30 / 40 的 Rules 行：项目根下 AGENTS.md / CLAUDE.md / .rules 的计数。
        'rulesCount': c.rulesCount,
      };
    }

    // ---- 分支（验收 5：分支列表与 git branch 一致；新建分支后顶栏立即更新；非 git 目录整块隐藏）
    final newBranch = _env('ACP_R3_NEW_BRANCH');
    if (newBranch != null && c.branchAreaVisible) {
      final before = c.branch;
      await c.createBranch(newBranch);
      final created = c.branch;
      if (before != null) await c.switchBranch(before);
      steps['branches'] = <String, dynamic>{
        'before': before,
        'afterCreate': created,
        'createdIsCurrent': created == newBranch,
        'afterSwitchBack': c.branch,
        'list': <String>[for (final b in c.branches) b.name],
        'error': c.lastError,
      };
    }

    // ---- 新会话（验收 3）
    final agentId = _env('ACP_R3_AGENT') ?? (c.installedAgents.isEmpty ? null : c.installedAgents.first.id);
    if (agentId == null) throw StateError('settings.json 里没有 agent_servers，也没有给 ACP_R3_AGENT');
    await c.newSession(_agentOf(agentId));
    if (c.sessionId == null) throw StateError('新会话失败：${c.lastError}');
    final store = c.store!;
    steps['newSession'] = <String, dynamic>{
      'agentId': c.agentId,
      'sessionId': c.sessionId,
      'cwd': store.cwd,
      'cwdMatchesProject': store.cwd == c.project?.path,
      'agentName': c.connection?.agentName,
      'agentTitle': c.connection?.agentTitle,
      'threadTitle': c.threadTitle,
      'capabilities': c.connection?.capabilityNames,
      'configOptions': <String, dynamic>{
        for (final o in store.configOptions) o.id ?? '?': <String, dynamic>{'category': o.category, 'type': o.type},
      },
      'commands': <String?>[for (final x in store.commands) x.name],
      'modelDropdown': c.optionOf('model')?.id,
      'thoughtDropdown': c.optionOf('thought_level')?.id,
      'modeDropdown': c.optionOf('mode')?.id,
    };

    // ---- config option（验收 3 末：改一个 config option 后弹层与线程头同步刷新）
    final config = _env('ACP_R3_CONFIG');
    if (config != null) {
      final applied = <String, dynamic>{};
      for (final pair in config.split(',')) {
        final i = pair.indexOf('=');
        if (i <= 0) continue;
        final id = pair.substring(0, i).trim();
        final raw = pair.substring(i + 1).trim();
        Object? decoded;
        try {
          decoded = jsonDecode(raw);
        } on FormatException {
          decoded = raw;
        }
        await (decoded is bool ? c.toggleConfigBoolean(id, decoded) : c.selectConfigValue(id, '$decoded'));
        applied[id] = <String, dynamic>{
          'requested': decoded,
          'afterwards': <String, dynamic>{
            for (final o in store.configOptions) o.id ?? '?': o.currentValue,
          },
        };
      }
      steps['setConfigOption'] = applied;
    }

    // ---- 第一轮（验收 3：权限 / elicitation / 计划 / 回合结束行）
    final permission = _env('ACP_R3_PERMISSION') ?? 'allow_once';
    final answers = <Map<String, dynamic>>[];
    final watcher = _AutoAnswer(c, permission, answers);
    watcher.attach();
    final prompt1 = _env('ACP_R3_PROMPT');
    if (prompt1 != null) {
      c.composer.text = prompt1;
      await c.send().timeout(timeout);
      steps['turn1'] = _turnSummary(c, prompt1)..['answers'] = List<Map<String, dynamic>>.of(answers);
      // 验收 4：这时的丢弃计数是画板 34 告警条的数字，与画板 80 的 dropped 行同源；
      // 行数也在这里量——后面的 reloadAgent 会再走一遍 initialize / session/new，把行数与计数都冲掉。
      steps['afterTurn1'] = <String, dynamic>{
        'trafficLines': c.traffic.lines.length,
        'trafficDropped': c.traffic.droppedCount,
        'agentDroppedUpdates': c.droppedUpdates,
        'bothWarningsVisible': c.droppedUpdates > 0 && c.traffic.droppedCount > 0,
      };
    }

    // ---- 第二轮：中途 session/cancel（验收 3）
    final prompt2 = _env('ACP_R3_PROMPT2');
    if (prompt2 != null) {
      answers.clear();
      c.composer.text = prompt2;
      final turn = c.send();
      Timer(Duration(seconds: _envInt('ACP_R3_CANCEL_AFTER', 4)), () => c.cancel());
      await turn.timeout(timeout);
      steps['turn2Cancelled'] = _turnSummary(c, prompt2)
        ..['answers'] = List<Map<String, dynamic>>.of(answers)
        ..['cancelledToolCalls'] = <String>[
          for (final e in c.store!.entries)
            if (e is ToolCallEntry && e.cancelledLocally) e.toolCallId,
        ];
    }
    watcher.detach();

    // ---- 杀掉 agent（验收 6：34 的 exited 条 + 重启可用；应用不崩）
    if (_env('ACP_R3_KILL') == '1') {
      final pid = c.connection?.pid?.toInt();
      final kill = pid == null
          ? <String, dynamic>{'skipped': 'no pid in spawned event'}
          : await Process.run('taskkill', <String>['/F', '/T', '/PID', '$pid']).then(
              (r) => <String, dynamic>{'pid': pid, 'exitCode': r.exitCode, 'stdout': '${r.stdout}'.trim()},
            );
      // 等 exited 事件落到投影层（画板 34 的 exited 条就是它）。
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (c.connection?.state != AgentLifecycle.exited && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      steps['killAgent'] = <String, dynamic>{
        'taskkill': kill,
        'state': c.connection?.state.wire,
        'exitCode': c.connection?.exitCode,
        'stderrTail': c.connection?.stderrTail,
        'stderrLines': c.connection?.stderrLines.length,
      };
    }

    // ---- 重载 agent（验收 3 / 6）
    final before = c.sessionId;
    await c.reloadAgent().timeout(timeout);
    steps['reloadAgent'] = <String, dynamic>{
      'sessionBefore': before,
      'sessionAfter': c.sessionId,
      'newSession': before != c.sessionId,
      'agentState': c.connection?.state.wire,
      'transcriptOfOldSessionKept': c.sessions.maybe(before ?? '')?.entries.isNotEmpty ?? false,
      'error': c.lastError,
    };

    // ---- 流量（验收 4）
    steps['traffic'] = <String, dynamic>{
      'lines': c.traffic.lines.length,
      'droppedCount': c.traffic.droppedCount,
      'byLabel': _tally(<String>[for (final l in c.traffic.lines) l.label]),
      'stderrTails': <String, int>{for (final e in c.traffic.stderr.entries) e.key: e.value.length},
      // 规则 8：核心侧已脱敏；这里核对一次「原始行里没有裸密钥形状」。
      'looksRedacted': !c.traffic.lines.any((l) => RegExp(r'sk-[A-Za-z0-9]{8,}').hasMatch(l.raw)),
    };
    steps['droppedUpdates'] = c.droppedUpdates;

    report['ok'] = true;
    exitCode = 0;
  } catch (e, st) {
    report['error'] = e.toString();
    report['stack'] = st.toString();
    report['lastError'] = controller?.lastError;
  }
  try {
    final file = File(reportPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  } on Object catch (_) {
    exitCode = 1;
  }
  exit(exitCode);
}

Map<String, dynamic> _turnSummary(WorkbenchController c, String prompt) {
  final store = c.store!;
  final turns = store.entries.whereType<TurnEntry>().toList();
  final last = turns.isEmpty ? null : turns.last;
  return <String, dynamic>{
    'prompt': prompt,
    'stopReason': last?.stopReason,
    'usage': last?.usage?.toJson(),
    'elapsedMs': last?.elapsed?.inMilliseconds,
    'entries': _tally(<String>[for (final e in store.entries) e.runtimeType.toString()]),
    'seen': Map<String, int>.of(store.seen),
    'plans': store.plans.all.length,
    'sessionUsage': store.usage?.toJson(),
    'pendingLeft': store.pending.forSession(store.sessionId).length,
    'title': store.title,
  };
}

Map<String, int> _tally(List<String> items) {
  final out = <String, int>{};
  for (final i in items) {
    out[i] = (out[i] ?? 0) + 1;
  }
  return out;
}

/// 队列里一出现挂起项就按参数自动回应（等价于用户点画板 25 / 27 的按钮），并记账。
class _AutoAnswer {
  _AutoAnswer(this.c, this.permission, this.log);

  final WorkbenchController c;
  final String permission;
  final List<Map<String, dynamic>> log;
  final Set<String> _done = <String>{};

  void attach() => c.sessions.pending.addListener(_tick);

  void detach() => c.sessions.pending.removeListener(_tick);

  void _tick() {
    final store = c.store;
    if (store == null) return;
    // requestScope 的 elicitation（无 sessionId，认证阶段）不在会话队列里：R3 没有认证页（画板 52 归 R5），
    // 但不回应 agent 会一直等，所以验收脚本这里一并代答，并在报告里标出来。
    final queue = <TranscriptEntry>[...store.pending.forSession(store.sessionId), ...c.sessions.pending.requestScope];
    for (final e in queue) {
      if (e is PermissionEntry && _done.add(e.requestId)) {
        if (permission == 'none') continue;
        final option = _pick(e);
        log.add(<String, dynamic>{
          'kind': 'permission',
          'requestId': e.requestId,
          'title': e.toolCallPatch.title,
          'options': <String?>[for (final o in e.options) '${o.optionId}/${o.kind}'],
          'answered': option,
        });
        if (option != null) unawaited(c.answerPermission(e.requestId, option));
      } else if (e is ElicitationEntry && _done.add(e.requestId)) {
        log.add(<String, dynamic>{
          'kind': 'elicitation',
          'requestId': e.requestId,
          'mode': e.wire.mode,
          'scope': e.isRequestScope ? 'request' : 'session',
          'message': e.wire.message,
          'answered': 'accept',
        });
        if (e.isRequestScope) {
          // 队列项不属于任何会话：直接经 PendingQueue 回应。
          final payload = c.sessions.pending.answerElicitation(e.requestId, 'accept', now: c.sessions.now);
          final bridge = c.bridge;
          final agent = e.agentId ?? c.agentId;
          if (payload != null && bridge != null && agent != null) {
            unawaited(bridge.acpRespond(agent, e.requestId, payload));
          }
        } else {
          unawaited(c.answerElicitation(e.requestId, 'accept', e.wire.isUrl ? null : <String, dynamic>{}));
        }
      }
    }
  }

  String? _pick(PermissionEntry e) {
    for (final o in e.options) {
      if (o.kind == permission) return o.optionId;
    }
    // 没有完全匹配的 kind 就退到第一个同向（allow_* / reject_*）的选项。
    final wantAllow = permission.startsWith('allow');
    for (final o in e.options) {
      if ((o.kind ?? '').startsWith(wantAllow ? 'allow' : 'reject')) return o.optionId;
    }
    return e.options.isEmpty ? null : e.options.first.optionId;
  }
}

/// `ProjectRef` / `AgentRef` 在 `lib/ui/popovers/topbar_popovers.dart`，这里只给两个构造糖。
ProjectRef _projectOf(String path) =>
    ProjectRef(path: path, name: path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).last);

AgentRef _agentOf(String id) => AgentRef(id: id, name: id);
