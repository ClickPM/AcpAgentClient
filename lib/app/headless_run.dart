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
// R4 追加（同一个口子，报告多几段；缺省都不做）：
//   ACP_R4_KILL_BG_AFTER  第一轮里出现「进行中且嵌了终端」的工具卡后多少秒点停止方块（`terminal_kill`；配 fake-agent `--terminal-bg`）
//   ACP_R4_LOCAL_SHELL    `1` = 开一个本地 shell 标签、敲一条命令、看输出、关掉（画板 61 / 验收 4）
//   ACP_R4_FILES          `1` = 文件面板：树、git 徽章、打开第一轮里 locations 指到的文件并定位到行（画板 60 / 验收 1）
//   ACP_R4_FOLLOW         `1` = 第一轮前打开 Follow，看 locations 到达时文件面板有没有跟过去

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../projection/agent_state.dart';
import '../projection/entries.dart';
import '../projection/session_store.dart';
import '../theme/tokens.dart' as t;
import '../ui/files/file_tree.dart';
import '../ui/popovers/composer_popovers.dart';
import '../ui/popovers/topbar_popovers.dart';
import '../ui/terminal/local_terminal.dart';
import 'core_bridge.dart';
import 'workbench_controller.dart';

const String r3ReportEnv = 'ACP_R3_REPORT';

String? r3ReportPathFromEnvironment() {
  final v = Platform.environment[r3ReportEnv];
  return (v == null || v.trim().isEmpty) ? null : v.trim();
}

String? _env(String name) {
  final v = Platform.environment[name];
  return (v == null || v.trim().isEmpty) ? null : v.trim();
}

int _envInt(String name, int fallback) => int.tryParse(_env(name) ?? '') ?? fallback;

/// 逐步落盘的进度（`<报告>.trace.log`）：报告只在结束时写，中途卡住时靠它看停在哪一步。
void Function(String) _tracer(String reportPath) {
  final file = File('$reportPath.trace.log');
  try {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('');
  } on Object catch (_) {
    return (_) {};
  }
  return (step) {
    try {
      file.writeAsStringSync('${DateTime.now().toIso8601String()} $step\n', mode: FileMode.append, flush: true);
    } on Object catch (_) {}
  };
}

Future<void> runR3({required String reportPath}) async {
  final report = <String, dynamic>{'ok': false, 'steps': <String, dynamic>{}};
  final steps = report['steps'] as Map<String, dynamic>;
  final timeout = Duration(seconds: _envInt('ACP_R3_TIMEOUT', 120));
  final trace = _tracer(reportPath);
  var exitCode = 1;
  WorkbenchController? controller;
  try {
    trace('load bridge');
    final bridge = await CoreBridge.load();
    // 无头进程没有 vsync：按帧批量的调度器永远不回调，改用微任务。
    final c = WorkbenchController(
      source: DataSource.bridge,
      bridge: bridge,
      scheduler: WorkbenchController.scheduleOnMicrotask,
    );
    controller = c;
    trace('controller.start');
    await c.start();
    trace('controller started');
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
    trace('openProject');
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
    trace('branches');
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
    trace('newSession');
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
      // R4：select 的候选值 id 与当前值，真跑换模型（ACP_R3_CONFIG）时照这里填。
      'configValues': <String, dynamic>{
        for (final o in store.configOptions)
          o.id ?? '?': <String, dynamic>{
            'current': o.currentValue,
            'options': <String>[for (final g in configGroups(o)) for (final choice in g.choices) choice.value],
          },
      },
      'commands': <String?>[for (final x in store.commands) x.name],
      'modelDropdown': c.optionOf('model')?.id,
      'thoughtDropdown': c.optionOf('thought_level')?.id,
      'modeDropdown': c.optionOf('mode')?.id,
    };

    // ---- config option（验收 3 末：改一个 config option 后弹层与线程头同步刷新）
    trace('session ready');
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
    trace('turn1');
    final permission = _env('ACP_R3_PERMISSION') ?? 'allow_once';
    final answers = <Map<String, dynamic>>[];
    final watcher = _AutoAnswer(c, permission, answers);
    watcher.attach();
    // R4：Follow 开着时 locations 到达即定位（验收 1 的「Follow 落右栏」）。
    if (_env('ACP_R4_FOLLOW') == '1' && !c.follow) c.toggleFollow();
    final killAfter = _envInt('ACP_R4_KILL_BG_AFTER', 0);
    final killer = killAfter > 0 ? _BackgroundKiller(c, Duration(seconds: killAfter)) : null;
    killer?.attach();
    final prompt1 = _env('ACP_R3_PROMPT');
    if (prompt1 != null) {
      c.composer.text = prompt1;
      await c.send().timeout(timeout);
      killer?.detach();
      steps['turn1'] = _turnSummary(c, prompt1)..['answers'] = List<Map<String, dynamic>>.of(answers);
      // R4：终端卡（terminal/create 路径与 _meta 通道共用一份缓冲）、停止方块、fs 回调落地的文件、Follow 的落点。
      steps['r4Turn1'] = <String, dynamic>{
        'terminals': <String, dynamic>{
          for (final t in c.sessions.terminals.all)
            t.terminalId: <String, dynamic>{
              'outputChars': t.output.length,
              'outputHead': t.output.length > 120 ? t.output.substring(0, 120) : t.output,
              'exitCode': t.exitCode,
              'signal': t.signal,
              'killed': t.killed,
              'released': t.released,
              'truncated': t.truncated,
            },
        },
        'killedByStopButton': killer?.killed ?? const <String>[],
        'toolCallsWithTerminal': <String, dynamic>{
          for (final e in c.store!.entries)
            if (e is ToolCallEntry && e.terminalIds.isNotEmpty) e.toolCallId: <String, dynamic>{'status': e.displayStatus.name, 'terminals': e.terminalIds.toList()},
        },
        'toolCallsWithLocations': <String, dynamic>{
          for (final e in c.store!.entries)
            if (e is ToolCallEntry && e.locations.isNotEmpty)
              e.toolCallId: <String?>[for (final l in e.locations) '${l.path}:${l.line ?? ''}'],
        },
        // 每张工具卡的 content 种类（diff 卡 = 画板 21、terminal = 22 / 23、content = 普通）与 kind。
        'toolCallContent': <String, dynamic>{
          for (final e in c.store!.entries)
            if (e is ToolCallEntry)
              e.toolCallId: <String, dynamic>{
                'kind': e.kind.name,
                'status': e.status.wire,
                'content': _tally(<String>[for (final b in e.content) b.type.name]),
              },
        },
        'follow': <String, dynamic>{
          'on': c.follow,
          'rightTab': c.rightTab?.name,
          'selectedPath': c.files.selectedPath,
          'highlightLine': c.files.highlightLine,
          'viewMode': c.files.viewMode.name,
        },
      };
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
    trace('turn1 done');
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

    // ---- R4：文件面板（画板 60）——树、git 徽章、Go to File 定位。
    trace('files panel');
    if (_env('ACP_R4_FILES') == '1') {
      final f = c.files;
      final tree = f.tree;
      String? located;
      int? locatedLine;
      final store = c.store;
      if (store != null) {
        for (final e in store.entries) {
          if (e is ToolCallEntry && e.locations.isNotEmpty && e.locations.first.path != null) {
            located = e.locations.first.path;
            locatedLine = e.locations.first.line?.toInt();
            break;
          }
        }
      }
      if (located != null) await c.goToFile(located, line: locatedLine);
      final badges = <String, String>{};
      if (tree != null) {
        for (final n in tree.visibleRows) {
          final b = tree.badgeOf(n.path);
          if (b != null) badges[n.name] = b;
        }
      }
      steps['files'] = <String, dynamic>{
        'root': f.root,
        'rootLoaded': tree?.loadedRoot,
        'topLevel': <String>[for (final n in tree?.top ?? const <FileNode>[]) n.name],
        'visibleRows': tree?.visibleRows.length,
        'gitAvailable': f.gitAvailable,
        'badges': badges,
        'goToFile': located,
        'goToLine': locatedLine,
        'rightTab': c.rightTab?.name,
        'selectedPath': f.selectedPath,
        'viewer': f.viewer == null
            ? null
            : <String, dynamic>{
                'name': f.viewer!.name,
                'relPath': f.viewer!.relPath,
                'lines': f.viewer!.lineCount,
                'size': f.viewer!.sizeBytes,
                'language': f.viewer!.language.label,
                'mode': f.viewMode.name,
                'highlightLine': f.highlightLine,
                'textHead': f.viewer!.text.length > 80 ? f.viewer!.text.substring(0, 80) : f.viewer!.text,
              },
        'error': f.lastError,
      };
    }

    // ---- R4：本地 shell（画板 61）——开标签、敲命令、看输出、关掉。
    trace('local shell');
    if (_env('ACP_R4_LOCAL_SHELL') == '1') {
      await c.openTerminalTab(forceNew: true);
      final id = c.activeTerminalId;
      final term = id == null ? null : c.terminals.byId(id);
      final shell = <String, dynamic>{'terminalId': id, 'title': term?.title, 'cwd': term?.cwd, 'openError': c.terminals.lastError};
      if (term != null) {
        // 等 shell 的提示符（PowerShell `PS …>` / cmd `…>` / sh `$`）出来再敲一条 echo，敲之前留一秒给 PSReadLine 初始化。
        final prompted = await _waitFor(() => RegExp(r'[>$#] *$').hasMatch(_screenText(term).trimRight()), timeout);
        shell['prompted'] = prompted;
        await Future<void>.delayed(const Duration(seconds: 1));
        term.onInput?.call('echo r4-local-shell-ok\r');
        // 命令的输出行（不是回显的输入行）：单独一行、只有这个词。
        final ok = await _waitFor(() => _screenText(term).split('\n').any((l) => l.trim() == 'r4-local-shell-ok'), timeout);
        shell['echoed'] = ok;
        shell['screenTail'] = _screenText(term).trimRight().split('\n').where((l) => l.trim().isNotEmpty).toList().reversed.take(3).toList().reversed.toList();
        shell['panelTabs'] = <String>[for (final t in c.panelTabs) t.toString()];
        // 停止方块：进程退出、状态行变已退出。
        await c.stopTerminalTab(term.id);
        final exited = await _waitFor(() => !term.running, timeout);
        shell['stoppedExited'] = exited;
        shell['exitCode'] = term.exitCode;
        shell['signal'] = term.signal;
        // 重启：同位置换新 shell；再关掉。
        await c.restartTerminalTab(term.id);
        final fresh = c.activeTerminalId;
        shell['restartedId'] = fresh;
        shell['restartedRunning'] = fresh == null ? null : c.terminals.byId(fresh)?.running;
        if (fresh != null) await c.closeTerminalTab(fresh);
        shell['tabsAfterClose'] = c.terminals.tabs.length;
        shell['rightPanelOpen'] = c.rightPanelOpen;
      }
      steps['localShell'] = shell;
    }

    // ---- 杀掉 agent（验收 6：34 的 exited 条 + 重启可用；应用不崩）
    trace('kill agent');
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
    trace('reload agent');
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
      // R4：按方向 + 方法计数——`in:fs/read_text_file` 等就是 agent 真的调了客户端回调的证据。
      'byMethod': _tally(<String>[
        for (final l in c.traffic.lines)
          if (l.method != null) '${l.direction.wire}:${l.method}',
      ]),
      'stderrTails': <String, int>{for (final e in c.traffic.stderr.entries) e.key: e.value.length},
      // 规则 8：核心侧已脱敏；这里核对一次「原始行里没有裸密钥形状」。
      'looksRedacted': !c.traffic.lines.any((l) => RegExp(r'sk-[A-Za-z0-9]{8,}').hasMatch(l.raw)),
    };
    steps['droppedUpdates'] = c.droppedUpdates;

    // ---- R4：退出收尾（验收 4：应用退出时子进程全部回收）——与关窗走同一条 `shutdown()`。
    trace('shutdown');
    await c.shutdown();
    steps['shutdown'] = <String, dynamic>{'agentState': c.connection?.state.wire, 'terminalTabs': c.terminals.tabs.length};

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
    // 最后一条 agent 消息的开头：一轮没发工具调用时，看这里就知道 agent 说了什么（如凭据错误）。
    'lastAgentMessage': _lastAgentMessage(store),
  };
}

String? _lastAgentMessage(SessionStore store) {
  final messages = store.entries.whereType<MessageEntry>().where((m) => m.role == MessageRole.agent).toList();
  if (messages.isEmpty) return null;
  final text = messages.last.text;
  return text.length > 300 ? text.substring(0, 300) : text;
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

/// xterm 主缓冲区里现在能看到的文本（本地 shell 的验收看这个）。
String _screenText(LocalTerminal term) {
  final b = term.terminal.buffer;
  return <String>[for (var i = 0; i < b.height; i++) b.lines[i].getText().trimRight()].join('\n');
}

Future<bool> _waitFor(bool Function() pred, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (!pred()) {
    if (DateTime.now().isAfter(deadline)) return false;
    // 轮询间隔取动效 token（样式字面量扫描不放行毫秒字面量）。
    await Future<void>.delayed(t.Motion.base);
  }
  return true;
}

/// R4：回合里出现「进行中且嵌了终端」的工具卡后，过 [delay] 点一次停止方块（= 用户在画板 23 上点红方块）。
class _BackgroundKiller {
  _BackgroundKiller(this.c, this.delay);

  final WorkbenchController c;
  final Duration delay;
  final List<String> killed = <String>[];
  final Map<String, Timer> _timers = <String, Timer>{};

  void attach() => c.sessions.addListener(_tick);

  void detach() {
    c.sessions.removeListener(_tick);
    for (final t in _timers.values) {
      t.cancel();
    }
  }

  void _tick() {
    final store = c.store;
    if (store == null) return;
    for (final e in store.entries) {
      if (e is! ToolCallEntry || e.isFinished) continue;
      for (final id in e.terminalIds) {
        final buffer = store.terminals[id];
        if (buffer == null || buffer.exited || _timers.containsKey(id)) continue;
        _timers[id] = Timer(delay, () {
          if (store.terminals[id]?.exited ?? true) return;
          killed.add(id);
          unawaited(c.killTerminal(id));
        });
      }
    }
  }
}

/// `ProjectRef` / `AgentRef` 在 `lib/ui/popovers/topbar_popovers.dart`，这里只给两个构造糖。
ProjectRef _projectOf(String path) =>
    ProjectRef(path: path, name: path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).last);

AgentRef _agentOf(String id) => AgentRef(id: id, name: id);
