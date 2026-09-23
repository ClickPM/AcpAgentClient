// R3 的无头实跑（验收 3 / 4 / 5 / 6 / 10）：`ACP_R3_REPORT=<报告文件>` 时不起窗口，直接驱动
// [WorkbenchController]——也就是 UI 点下去会走的那条接线——对真实 agent 跑一遍完整流程，把每步结果写 JSON。
// 无头、写报告、退出码即结论。**入口是 lib/main_headless.dart（`flutter build -t`），不在产品的 main.dart 上**：
// 这些是验收脚本，不随发布包编进去。
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
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../projection/agent_state.dart';
import '../projection/entries.dart';
import '../projection/session_store.dart';
import '../projection/wire.dart';
import '../theme/tokens.dart' as t;
import '../ui/files/file_tree.dart';
import '../ui/popovers/composer_popovers.dart';
import '../ui/popovers/topbar_popovers.dart';
import '../ui/registry/auth_page.dart';
import '../ui/terminal/local_terminal.dart';
import 'clipboard_image.dart';
import 'core_bridge.dart';
import 'workbench_controller.dart';

const String r3ReportEnv = 'ACP_R3_REPORT';
const String r5ReportEnv = 'ACP_R5_REPORT';
const String r6ReportEnv = 'ACP_R6_REPORT';

String? r6ReportPathFromEnvironment() {
  final v = Platform.environment[r6ReportEnv];
  return (v == null || v.trim().isEmpty) ? null : v.trim();
}

/// R6 的无头实跑（验收 1 / 2 / 4 / 5 / 6）：驱动 [WorkbenchController] 走一遍会话生命周期——
/// 连接 → 新会话 → 一轮 → `session/list` 校对 → **断开重连（等价于关掉应用重开）** → 侧栏点击 → `session/load`
/// 重放 → 转录比对 → resume / close / delete，每步结果写 JSON。与 R3 / R5 是同一个口子的第四个模式。
///
/// 环境变量（都可选，除 REPORT 外都有缺省）：
///   ACP_R6_REPORT      报告文件路径（必填，给了才进本模式）
///   ACP_R6_AGENT       agent id，缺省取 settings.json 里的第一个
///   ACP_R6_CWD         项目目录，缺省取 projects.json 里最近的一个
///   ACP_R6_PROMPT      第一轮提示词（不给就只验生命周期，不发 prompt）
///   ACP_R6_PROMPT2     第二轮提示词（重连 + load 之后发，验「载回来的会话还能接着对话」）
///   ACP_R6_PROMPT3     第三轮提示词（发出后到点发 `session/cancel`，验收 5 的 `cancelled`）
///   ACP_R6_CANCEL_AFTER 第三轮多久后取消（秒；0 = 不做）
///   ACP_R6_PERMISSION  allow_once | allow_always | reject_once | reject_always | none（缺省 allow_once）
///   ACP_R6_MODE        切到这个模式（走 configOptions 或 modes 回退，报告里记走了哪条）
///   ACP_R6_RELOAD      `1` = 先验一次「重载 agent」（声明 loadSession 的应当自动 load 回原会话）
///   ACP_R6_CLOSE       `1` = 末尾 `session/close`
///   ACP_R6_RESUME      `1` = close 之后再 `session/resume` 挂回来（要配 ACP_R6_CLOSE，且 agent 声明 resume）
///   ACP_R6_DELETE      `1` = 末尾删除会话（有 delete 能力就连 agent 侧一起删）
///   ACP_R6_TIMEOUT     单步超时（秒，缺省 180）
Future<void> runR6({required String reportPath}) async {
  final report = <String, dynamic>{'ok': false, 'steps': <String, dynamic>{}};
  final steps = report['steps'] as Map<String, dynamic>;
  final timeout = Duration(seconds: _envInt('ACP_R6_TIMEOUT', 180));
  final trace = _tracer(reportPath);
  var exitCode = 1;
  WorkbenchController? controller;
  try {
    trace('load bridge');
    final bridge = await CoreBridge.load();
    final c = WorkbenchController(source: DataSource.bridge, bridge: bridge, scheduler: WorkbenchController.scheduleOnMicrotask);
    controller = c;
    await c.start();
    final cwd = _env('ACP_R6_CWD');
    if (cwd != null) await c.workspace.openProject(_projectOf(cwd));
    final agentId = _env('ACP_R6_AGENT') ?? (c.agents.installed.isEmpty ? null : c.agents.installed.first.id);
    if (agentId == null) throw StateError('settings.json 里没有 agent_servers，也没有给 ACP_R6_AGENT');
    if (c.workspace.project == null) throw StateError('没有项目目录：给 ACP_R6_CWD 或先打开一个项目');

    // ---- 新会话（顺带把能力声明记下来：矩阵的「能力」列与 ≡ 菜单裁剪都看它）
    trace('newSession');
    await c.session.newSession(_agentOf(agentId)).timeout(timeout);
    if (c.session.sessionId == null) throw StateError('新会话失败：${c.session.lastError}');
    final sessionId = c.session.sessionId!;
    steps['capabilities'] = _capabilitySummary(c);
    steps['newSession'] = <String, dynamic>{
      'agentId': c.session.agentId,
      'sessionId': sessionId,
      'cwd': c.session.store?.cwd,
      'agentName': c.session.connection?.agentName,
      'sessionTitle': c.session.sessionTitle,
      'commands': <String?>[for (final x in c.session.store!.commands) x.name],
      'modeDropdown': _modeDropdownSummary(c),
    };

    // ---- 第一轮（验收 5 / 6：stopReason 与回合级 usage 在真实 agent 上各出现一次）
    final answers = <Map<String, dynamic>>[];
    final watcher = _AutoAnswer(c, _env('ACP_R6_PERMISSION') ?? 'allow_once', answers)..attach();
    final prompt1 = _env('ACP_R6_PROMPT');
    if (prompt1 != null) {
      trace('turn1');
      c.composer.editor.text = prompt1;
      await c.turn.send().timeout(timeout);
      steps['turn1'] = _turnSummary(c, prompt1)..['answers'] = List<Map<String, dynamic>>.of(answers);
    }

    // ---- 模式（configOptions 优先，没有就走 modes 回退 → session/set_mode）
    final mode = _env('ACP_R6_MODE');
    if (mode != null) {
      trace('setMode');
      final option = c.turn.optionOf('mode');
      if (option != null) await c.turn.selectConfigValue(option.id ?? '', mode).timeout(timeout);
      steps['setMode'] = <String, dynamic>{
        'requested': mode,
        'via': option?.id == SessionStore.modeFallbackId ? 'session/set_mode（modes 回退）' : 'session/set_config_option',
        'currentModeId': c.session.store?.currentModeId,
        'dropdown': _modeDropdownSummary(c),
        'error': c.turn.lastError,
      };
    }

    // ---- session/list 校对（侧栏以本地索引为准，只补标题）
    if (c.session.canListSessions) {
      trace('reconcile');
      final listed = <Map<String, dynamic>>[];
      String? cursor;
      for (var page = 0; page < 20; page++) {
        final result = await bridge.sessionList(agentId, cwd: c.workspace.project?.path, cursor: cursor).timeout(timeout);
        listed.add(<String, dynamic>{
          'cursor': cursor,
          'sessions': <String?>[
            for (final s in (result['sessions'] as List? ?? const <Object?>[]))
              if (s is Map) '${s['sessionId']}｜${s['title'] ?? ''}',
          ],
          'nextCursor': result['nextCursor'],
        });
        final next = result['nextCursor'];
        if (next is! String || next.isEmpty) break;
        cursor = next;
      }
      await c.session.reconcileSessions();
      steps['sessionList'] = <String, dynamic>{
        'pages': listed,
        'containsCurrent': listed.any((p) => (p['sessions'] as List).any((s) => '$s'.startsWith(sessionId))),
        'sidebar': <String>[for (final s in c.session.sidebarSessions) '${s.id}｜${s.title}'],
        'missingOnAgent': c.session.missingOnAgent.toList(),
      };
    }

    // ---- 重载 agent（声明 loadSession 的应当重连后自动 load 回原会话）
    if (_env('ACP_R6_RELOAD') == '1') {
      trace('reloadAgent');
      final before = _transcriptDigest(c.session.store!);
      await c.session.reloadAgent().timeout(timeout);
      final after = c.session.sessionId == sessionId ? _transcriptDigest(c.session.store!) : null;
      steps['reloadAgent'] = <String, dynamic>{
        'sessionIdBefore': sessionId,
        'sessionIdAfter': c.session.sessionId,
        'sameSession': c.session.sessionId == sessionId,
        'digestMatches': after == before,
        // 重放来自 agent 侧的历史，客户端本地态（轮边界 TurnEntry、权限 / elicitation 卡）不在里面：
        // 两份摘要都记下来，差在哪一眼能看出来，不靠一个 bool 下结论。
        'beforeDigest': before,
        'afterDigest': after,
        'error': c.session.lastError,
      };
    }

    // ---- 关掉应用重开（验收 2）：断开 agent、忘掉内存里的转录，再照侧栏点击那条路走一遍
    trace('reconnect');
    final before = _transcriptDigest(c.session.store!);
    final beforeEntries = c.session.store!.entries.length;
    await bridge.agentDisconnect(agentId);
    c.sessions.forget(sessionId);
    c.session.sessionId = null;
    await c.session.selectSession(sessionId).timeout(timeout);
    final after = c.sessions.maybe(sessionId);
    // agent 可以在 `session/load` 返回之后才补发 `available_commands_update`（pi-acp 就是这样，2026-09-16 实测），
    // 立刻取样会看到空的 `/` 菜单：等一小会儿再照一张，两张都记。
    final commandsAtReturn = <String?>[for (final x in after?.commands ?? const <AvailableCommandWire>[]) x.name];
    await Future<void>.delayed(const Duration(seconds: 3));
    c.batcher.flush();
    final afterDigest = after == null ? null : _transcriptDigest(after);
    steps['reopen'] = <String, dynamic>{
      'loadSessionDeclared': c.session.canLoadSessionOf(agentId),
      'sessionId': c.session.sessionId,
      'beforeEntries': beforeEntries,
      'afterEntries': after?.entries.length,
      'digestMatches': afterDigest == before,
      'beforeDigest': before,
      'afterDigest': afterDigest,
      'title': after?.title,
      'commandsAtReturn': commandsAtReturn,
      'commands': <String?>[for (final x in after?.commands ?? const <AvailableCommandWire>[]) x.name],
      'modeDropdown': _modeDropdownSummary(c),
      'error': c.session.lastError,
    };

    // ---- 载回来的会话还能接着对话
    final prompt2 = _env('ACP_R6_PROMPT2');
    if (prompt2 != null && c.session.sessionId != null) {
      trace('turn2');
      c.composer.editor.text = prompt2;
      await c.turn.send().timeout(timeout);
      steps['turn2AfterLoad'] = _turnSummary(c, prompt2)..['answers'] = List<Map<String, dynamic>>.of(answers);
    }

    // ---- 取消一轮（验收 5 的 `cancelled`：五种 stopReason 要在真实 agent 上见到）
    final prompt3 = _env('ACP_R6_PROMPT3');
    final cancelAfter = _envInt('ACP_R6_CANCEL_AFTER', 0);
    if (prompt3 != null && cancelAfter > 0 && c.session.sessionId != null) {
      trace('cancel');
      c.session.lastError = null;
      c.composer.editor.text = prompt3;
      Timer(Duration(seconds: cancelAfter), () => c.turn.cancel());
      await c.turn.send().timeout(timeout);
      steps['cancelledTurn'] = _turnSummary(c, prompt3)
        ..['cancelAfterSeconds'] = cancelAfter
        ..['cancelledToolCalls'] = <String>[
          for (final e in c.session.store!.entries)
            if (e is ToolCallEntry && e.cancelledLocally) e.toolCallId,
        ];
    }

    // ---- close → resume → delete（按能力）。顺序不能反：`session/resume` 是给「没在本连接上活着的会话」
    // 重新挂上下文用的，活着的会话上发它 dsh 1.3.0 直接回 -32602（2026-09-16 实测）。
    if (_env('ACP_R6_CLOSE') == '1' && c.session.canCloseSession) {
      trace('close');
      c.session.lastError = null;
      await c.session.closeSession().timeout(timeout);
      steps['close'] = <String, dynamic>{
        'sessionIdAfter': c.session.sessionId,
        'closed': c.session.sessionClosed,
        'canResumeNow': c.session.canResumeSession,
        'canCloseNow': c.session.canCloseSession,
        'error': c.session.lastError,
      };
    }
    if (_env('ACP_R6_RESUME') == '1' && c.session.canResumeSession) {
      trace('resume');
      c.session.lastError = null;
      final entriesBefore = c.session.store!.entries.length;
      await c.session.resumeSession().timeout(timeout);
      steps['resume'] = <String, dynamic>{
        'entriesBefore': entriesBefore,
        'entriesAfter': c.session.store?.entries.length,
        'noReplay': c.session.store?.entries.length == entriesBefore,
        'closedAfter': c.session.sessionClosed,
        'error': c.session.lastError,
      };
    }
    if (_env('ACP_R6_DELETE') == '1') {
      trace('delete');
      c.session.lastError = null;
      final onAgent = c.session.deletesOnAgent(sessionId);
      await c.session.deleteSession(sessionId).timeout(timeout);
      final listedAfter = <String>[];
      if (c.session.canListSessions) {
        String? cursor;
        for (var page = 0; page < 20; page++) {
          final result = await bridge.sessionList(agentId, cwd: c.workspace.project?.path, cursor: cursor).timeout(timeout);
          for (final s in (result['sessions'] as List? ?? const <Object?>[])) {
            if (s is Map && s['sessionId'] is String) listedAfter.add(s['sessionId'] as String);
          }
          final next = result['nextCursor'];
          if (next is! String || next.isEmpty) break;
          cursor = next;
        }
      }
      steps['delete'] = <String, dynamic>{
        'sentToAgent': onAgent,
        'inSidebar': c.session.sidebarSessions.any((s) => s.id == sessionId),
        'inAgentList': listedAfter.contains(sessionId),
        'agentListAfter': listedAfter,
        'error': c.session.lastError,
      };
    }
    watcher.detach();
    report['ok'] = true;
    exitCode = 0;
  } catch (e, st) {
    report['error'] = e.toString();
    report['stack'] = st.toString();
    report['lastError'] = controller?.toasts.latest;
  }
  await _shutdown(controller, report);
  _finish(reportPath, report, exitCode, 'r6');
}

/// 能力声明（矩阵与 ≡ 菜单裁剪的依据；不按 agent 名判，规则 2）。
/// `declared` 是 agent 自己说的，`menuNow` 是这一刻 ≡ 菜单会不会渲染那一行——
/// Resume / Close 还要看会话是死是活，两者不是一回事。
Map<String, dynamic> _capabilitySummary(WorkbenchController c) {
  final raw = c.session.connection?.agentCapabilities?['sessionCapabilities'];
  final keys = raw is Map ? raw.keys.map((k) => '$k').toList() : const <String>[];
  return <String, dynamic>{
    'loadSession': c.session.canLoadSession,
    'declared': keys,
    'menuNow': <String, bool>{
      'list': c.session.canListSessions,
      'resume': c.session.canResumeSession,
      'close': c.session.canCloseSession,
      'delete': c.session.canDeleteSession,
    },
    'raw': raw,
  };
}

/// 模式下拉：走 configOptions 还是 modes 回退，当前值与候选。
Map<String, dynamic> _modeDropdownSummary(WorkbenchController c) {
  final option = c.turn.optionOf('mode');
  return <String, dynamic>{
    'id': option?.id,
    'source': option == null
        ? null
        : (option.id == SessionStore.modeFallbackId ? 'modes（回退）' : 'configOptions'),
    'current': option?.currentValue,
    'values': <Object?>[for (final o in option?.options ?? const <JsonMap>[]) o['value']],
  };
}

/// 转录摘要：只留协议给的东西（条目类型 + 文本 + 工具卡 id / 状态），不含本地时间戳与本地序号，
/// 所以「关掉重开 + session/load 重放」的结果可以和关闭前逐字比。
String _transcriptDigest(SessionStore store) {
  final parts = <String>[];
  for (final e in store.entries) {
    switch (e) {
      case final MessageEntry m:
        parts.add('${m.role.name}:${m.text}');
      case final ThoughtEntry t:
        parts.add('thought:${t.text}');
      case final ToolCallEntry tc:
        parts.add('tool:${tc.toolCallId}:${tc.status.wire}:${tc.title}');
      case final PlanCardEntry p:
        parts.add('plan:${p.planId}:${p.items.length}');
      case final CompactionEntry cp:
        parts.add('compaction:${cp.compactionId}:${cp.status}');
      case final PermissionEntry p:
        parts.add('permission:${p.toolCallId ?? ''}');
      case final ElicitationEntry el:
        parts.add('elicitation:${el.wire.mode ?? ''}');
      case final TurnEntry t:
        parts.add('turn:${t.n}:${t.stopReason ?? ''}');
      default:
        parts.add(e.runtimeType.toString());
    }
  }
  return parts.join('\n');
}

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
///   ACP_R5_UPGRADE       要升级的 registry id（画板 53，round-board-53 验收 7）：在一轮之后、Remove 之前升级，等 done / failed / cancelled
///   ACP_R5_UPGRADE_CANCEL_AT  看到升级的某个步骤就取消（同 ACP_R5_CANCEL_AT）
///   ACP_R5_RELOAD        `1` = 升级完 Reload Agent（验证 reloadPending 被撤掉）
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
    if (cwd != null) await c.workspace.openProject(_projectOf(cwd));
    if (_env('ACP_R5_REFRESH') == '1') await c.agents.refreshRegistry(network: true, force: true).timeout(timeout);
    steps['registry'] = _registrySummary(c);

    // ---- 受管 Node（验收 3）
    if (_env('ACP_R5_NODE_DOWNLOAD') == '1') {
      final before = c.agents.registry.node;
      await c.agents.downloadNode().timeout(timeout);
      steps['nodeDownload'] = <String, dynamic>{
        'before': <String, dynamic>{'system': before.system?.version, 'managed': before.managed?.version},
        'after': <String, dynamic>{'system': c.agents.registry.node.system?.version, 'managed': c.agents.registry.node.managed?.version, 'managedPath': c.agents.registry.node.managed?.path},
        'error': c.agents.lastError,
      };
    }

    // ---- 安装（验收 1 / 2）
    final install = _env('ACP_R5_INSTALL');
    if (install != null) {
      final seen = <String>[];
      final watch = _ProgressWatch(c, bridge, install, seen, cancelAt: _env('ACP_R5_CANCEL_AT'));
      watch.attach();
      final started = DateTime.now();
      await c.agents.install(install);
      final cancelAfter = _envInt('ACP_R5_CANCEL_AFTER', 0);
      if (cancelAfter > 0) Timer(Duration(seconds: cancelAfter), () => c.agents.cancelInstall(install));
      await watch.done.future.timeout(timeout);
      watch.detach();
      // 收尾事件之后组合根会（不等待地）重读列表；这里再读一次，`installed` 才是落盘后的状态。
      await c.agents.refreshRegistry();
      final entry = c.agents.registry.byId(install);
      steps['install'] = <String, dynamic>{
        'agentId': install,
        'stepsSeen': seen,
        'elapsedMs': DateTime.now().difference(started).inMilliseconds,
        'installed': entry?.installed,
        'installedVersion': entry?.installedVersion,
        'launch': entry?.launch == null ? null : <String, dynamic>{'command': entry!.launch!.command, 'args': entry.launch!.args},
        'failure': entry?.failure,
        'error': c.agents.lastError,
      };
    }

    // ---- 新会话（-32000 → 认证页）
    final agentId = _env('ACP_R5_AGENT') ?? install;
    if (agentId != null && (cwd != null || c.workspace.project != null)) {
      await c.session.newSession(AgentRef(id: agentId, name: agentId)).timeout(timeout);
      steps['newSession'] = <String, dynamic>{
        'sessionId': c.session.sessionId,
        'authRequired': c.auth.agentId == agentId,
        'authMethods': <String?>[for (final m in c.auth.methods) '${m['id']}/${AuthPage.methodType(m)}'],
        'rightTab': c.shell.rightTab?.name,
        'error': c.session.lastError,
      };
      if (c.auth.agentId == agentId) {
        final methodId = _env('ACP_R5_AUTH_METHOD') ?? c.auth.methodId;
        if (methodId != null) c.auth.selectMethod(methodId);
        final input = _env('ACP_R5_AUTH_INPUT');
        final urls = <String>[];
        final elicitation = _ElicitationWatch(c, urls)..attach();
        if (input != null) {
          Timer(Duration(seconds: _envInt('ACP_R5_AUTH_INPUT_DELAY', 5)), () => c.auth.terminalInput('$input\r'));
        }
        final authStarted = DateTime.now();
        await c.auth.start().timeout(Duration(seconds: _envInt('ACP_R5_AUTH_TIMEOUT', 300)));
        elicitation.detach();
        steps['auth'] = <String, dynamic>{
          'methodId': methodId,
          'phase': c.auth.phase.name,
          'error': c.auth.error,
          'elapsedMs': DateTime.now().difference(authStarted).inMilliseconds,
          'requestScopeUrls': urls,
          'terminalId': c.auth.terminalId,
          'sessionId': c.session.sessionId,
          'authPageClosed': c.auth.agentId == null,
          'authStatus': c.agents.registry.byId(agentId)?.authStatus.wire,
        };
      }
    }

    // ---- 一轮（验收 1 / 2 的「一轮对话」）
    final prompt = _env('ACP_R5_PROMPT');
    if (prompt != null && c.session.sessionId != null) {
      final answers = <Map<String, dynamic>>[];
      final watcher = _AutoAnswer(c, 'allow_once', answers)..attach();
      c.composer.editor.text = prompt;
      await c.turn.send().timeout(timeout);
      watcher.detach();
      steps['turn'] = _turnSummary(c, prompt)..['answers'] = answers;
    }

    // ---- 升级（画板 53）：连着 agent 时升级 → reloadPending；ACP_R5_RELOAD=1 再 Reload Agent → 撤掉
    final upgrade = _env('ACP_R5_UPGRADE');
    if (upgrade != null) {
      await c.agents.refreshRegistry();
      Map<String, dynamic> snap() {
        final e = c.agents.registry.byId(upgrade);
        final dir = Directory('${c.dataDir}${Platform.pathSeparator}agents${Platform.pathSeparator}$upgrade');
        return <String, dynamic>{
          'installed': e?.installed,
          'installedVersion': e?.installedVersion,
          'updateAvailable': e?.updateAvailable,
          'reloadPending': e?.reloadPending,
          'launch': e?.launch == null ? null : <String, dynamic>{'command': e!.launch!.command, 'args': e.launch!.args},
          'failure': e?.failure,
          'agentDir': dir.existsSync() ? (dir.listSync().map((f) => f.path.split(Platform.pathSeparator).last).toList()..sort()) : null,
        };
      }

      final before = snap();
      final seen = <String>[];
      final watch = _ProgressWatch(c, bridge, upgrade, seen, cancelAt: _env('ACP_R5_UPGRADE_CANCEL_AT'));
      watch.attach();
      final started = DateTime.now();
      await c.agents.upgrade(upgrade);
      await watch.done.future.timeout(timeout);
      watch.detach();
      await c.agents.refreshRegistry();
      final result = <String, dynamic>{
        'agentId': upgrade,
        'connectedBefore': c.session.sessionId != null,
        'before': before,
        'stepsSeen': seen,
        'elapsedMs': DateTime.now().difference(started).inMilliseconds,
        'after': snap(),
        'error': c.agents.lastError,
      };
      if (_env('ACP_R5_RELOAD') == '1' && c.session.sessionId != null) {
        await c.session.reloadAgent().timeout(timeout);
        // 组合根收到 initialized 会不等待地重读一次列表；这里自己再读一次，拿落定的状态。
        await c.agents.refreshRegistry();
        result['afterReload'] = snap()..['sessionId'] = c.session.sessionId..['sessionError'] = c.session.lastError;
      }
      steps['upgrade'] = result;
    }

    // ---- 从 Zed 导入（验收 4）
    if (_env('ACP_R5_IMPORT_ZED') == '1') {
      final before = c.agents.registry.entries.where((e) => e.installed).map((e) => e.id).toList();
      await c.agents.importZed().timeout(timeout);
      steps['importZed'] = <String, dynamic>{
        'zedSettingsPath': c.zedSettingsPath,
        'result': c.agents.zedImportResult,
        'installedBefore': before,
        'installedAfter': c.agents.registry.entries.where((e) => e.installed).map((e) => e.id).toList(),
        'error': c.agents.lastError,
      };
    }

    // ---- Remove（验收 5）
    if (_env('ACP_R5_REMOVE') == '1' && install != null) {
      final dir = '${c.dataDir}${Platform.pathSeparator}agents${Platform.pathSeparator}$install';
      final existedBefore = Directory(dir).existsSync();
      await c.agents.remove(install).timeout(timeout);
      final settings = await bridge.agentSettingsGet();
      steps['remove'] = <String, dynamic>{
        'agentId': install,
        'dirExistedBefore': existedBefore,
        'dirExistsAfter': Directory(dir).existsSync(),
        'settingsHasEntry': (settings['agent_servers'] as Map?)?.containsKey(install) ?? false,
        'installedNow': c.agents.registry.byId(install)?.installed,
        'otherDirs': Directory('${c.dataDir}').listSync().map((e) => e.path.split(Platform.pathSeparator).last).toList()..sort(),
        'error': c.agents.lastError,
      };
    }

    steps['registryAfter'] = _registrySummary(c);
    report['ok'] = true;
    exitCode = 0;
  } catch (e, st) {
    report['error'] = e.toString();
    report['stack'] = st.toString();
    report['lastError'] = controller?.toasts.latest;
  }
  await _shutdown(controller, report);
  _finish(reportPath, report, exitCode, 'r5');
}

Map<String, dynamic> _registrySummary(WorkbenchController c) => <String, dynamic>{
      'count': c.agents.registry.entries.length,
      'installed': c.agents.registry.entries.where((e) => e.installed).map((e) => '${e.id}:${e.kind.wire}:${e.authStatus.wire}').toList(),
      'fetchError': c.agents.registry.fetchError,
      'fetchedAt': c.agents.registry.fetchedAt?.toIso8601String(),
      'node': <String, dynamic>{'system': c.agents.registry.node.system?.version, 'managed': c.agents.registry.node.managed?.version, 'systemError': c.agents.registry.node.systemError},
      'paths': <String, dynamic>{'dataDir': c.dataDir, 'logPath': c.logPath, 'zed': c.zedSettingsPath},
      'sample': <String>[for (final e in c.agents.registry.entries.take(6)) '${e.id} v${e.version} ${e.kind.wire}${e.supported ? '' : ' unsupported'}'],
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
    final key = '${json['upgrade'] == true ? 'upgrade/' : ''}${terminal ? step : '${json['kind']}:$step'}';
    if (key != _last) {
      _last = key;
      final progress = json['done'] is num && json['total'] is num ? ' ${json['done']}/${json['total']}' : '';
      seen.add('$key$progress');
    }
    if (!_cancelSent && cancelAt != null && step == cancelAt) {
      _cancelSent = true;
      seen.add('(cancel sent at $step)');
      unawaited(c.agents.cancelInstall(agentId));
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
    for (final e in c.auth.elicitations) {
      if (e.status != PendingStatus.pending || !_done.add(e.requestId)) continue;
      unawaited(c.auth.acceptUrl(e).then((url) {
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
      'agents': <String>[for (final a in c.agents.installed) a.id],
      'project': c.workspace.project?.path,
      'branchAreaVisible': c.workspace.branchAreaVisible,
      'branch': c.workspace.branch,
      'branches': <String>[for (final b in c.workspace.branches) b.name],
      'rulesCount': c.workspace.rulesCount,
      'sidebarSessions': c.session.sidebarSessions.length,
    };

    // ---- 项目（验收 5：切项目后新会话的 cwd 正确）
    trace('openProject');
    final cwd = _env('ACP_R3_CWD');
    if (cwd != null) {
      await c.workspace.openProject(_projectOf(cwd));
      steps['openProject'] = <String, dynamic>{
        'path': c.workspace.project?.path,
        'branchAreaVisible': c.workspace.branchAreaVisible,
        'branch': c.workspace.branch,
        'branches': <String>[for (final b in c.workspace.branches) b.name],
        // 画板 30 / 40 的 Rules 行：项目根下 AGENTS.md / CLAUDE.md / .rules 的计数。
        'rulesCount': c.workspace.rulesCount,
      };
    }

    // ---- 分支（验收 5：分支列表与 git branch 一致；新建分支后顶栏立即更新；非 git 目录整块隐藏）
    trace('branches');
    final newBranch = _env('ACP_R3_NEW_BRANCH');
    if (newBranch != null && c.workspace.branchAreaVisible) {
      final before = c.workspace.branch;
      await c.workspace.createBranch(newBranch);
      final created = c.workspace.branch;
      if (before != null) await c.workspace.switchBranch(before);
      steps['branches'] = <String, dynamic>{
        'before': before,
        'afterCreate': created,
        'createdIsCurrent': created == newBranch,
        'afterSwitchBack': c.workspace.branch,
        'list': <String>[for (final b in c.workspace.branches) b.name],
        'error': c.workspace.lastError,
      };
    }

    // ---- 新会话（验收 3）
    trace('newSession');
    final agentId = _env('ACP_R3_AGENT') ?? (c.agents.installed.isEmpty ? null : c.agents.installed.first.id);
    if (agentId == null) throw StateError('settings.json 里没有 agent_servers，也没有给 ACP_R3_AGENT');
    await c.session.newSession(_agentOf(agentId));
    if (c.session.sessionId == null) throw StateError('新会话失败：${c.session.lastError}');
    final store = c.session.store!;
    steps['newSession'] = <String, dynamic>{
      'agentId': c.session.agentId,
      'sessionId': c.session.sessionId,
      'cwd': store.cwd,
      'cwdMatchesProject': store.cwd == c.workspace.project?.path,
      'agentName': c.session.connection?.agentName,
      'agentTitle': c.session.connection?.agentTitle,
      'sessionTitle': c.session.sessionTitle,
      'capabilities': c.session.connection?.capabilityNames,
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
      'modelDropdown': c.turn.optionOf('model')?.id,
      'thoughtDropdown': c.turn.optionOf('thought_level')?.id,
      'modeDropdown': c.turn.optionOf('mode')?.id,
    };

    // ---- config option（验收 3 末：改一个 config option 后弹层与会话头同步刷新）
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
        await (decoded is bool ? c.turn.toggleConfigBoolean(id, decoded) : c.turn.selectConfigValue(id, '$decoded'));
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
    if (_env('ACP_R4_FOLLOW') == '1' && !c.shell.follow) c.shell.toggleFollow();
    final killAfter = _envInt('ACP_R4_KILL_BG_AFTER', 0);
    final killer = killAfter > 0 ? _BackgroundKiller(c, Duration(seconds: killAfter)) : null;
    killer?.attach();
    final prompt1 = _env('ACP_R3_PROMPT');
    if (prompt1 != null) {
      c.composer.editor.text = prompt1;
      await c.turn.send().timeout(timeout);
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
          for (final e in c.session.store!.entries)
            if (e is ToolCallEntry && e.terminalIds.isNotEmpty) e.toolCallId: <String, dynamic>{'status': e.displayStatus.name, 'terminals': e.terminalIds.toList()},
        },
        'toolCallsWithLocations': <String, dynamic>{
          for (final e in c.session.store!.entries)
            if (e is ToolCallEntry && e.locations.isNotEmpty)
              e.toolCallId: <String?>[for (final l in e.locations) '${l.path}:${l.line ?? ''}'],
        },
        // 每张工具卡的 content 种类（diff 卡 = 画板 21、terminal = 22 / 23、content = 普通）与 kind。
        'toolCallContent': <String, dynamic>{
          for (final e in c.session.store!.entries)
            if (e is ToolCallEntry)
              e.toolCallId: <String, dynamic>{
                'kind': e.kind.name,
                'status': e.status.wire,
                'content': _tally(<String>[for (final b in e.content) b.type.name]),
              },
        },
        'follow': <String, dynamic>{
          'on': c.shell.follow,
          'rightTab': c.shell.rightTab?.name,
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
        'agentDroppedUpdates': c.session.droppedUpdates,
        'bothWarningsVisible': c.session.droppedUpdates > 0 && c.traffic.droppedCount > 0,
      };
    }

    // ---- 第二轮：中途 session/cancel（验收 3）
    trace('turn1 done');
    final prompt2 = _env('ACP_R3_PROMPT2');
    if (prompt2 != null) {
      answers.clear();
      c.composer.editor.text = prompt2;
      final turn = c.turn.send();
      Timer(Duration(seconds: _envInt('ACP_R3_CANCEL_AFTER', 4)), () => c.turn.cancel());
      await turn.timeout(timeout);
      steps['turn2Cancelled'] = _turnSummary(c, prompt2)
        ..['answers'] = List<Map<String, dynamic>>.of(answers)
        ..['cancelledToolCalls'] = <String>[
          for (final e in c.session.store!.entries)
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
      final store = c.session.store;
      if (store != null) {
        for (final e in store.entries) {
          if (e is ToolCallEntry && e.locations.isNotEmpty && e.locations.first.path != null) {
            located = e.locations.first.path;
            locatedLine = e.locations.first.line?.toInt();
            break;
          }
        }
      }
      if (located != null) await c.shell.goToFile(located, line: locatedLine);
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
        'rightTab': c.shell.rightTab?.name,
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
      await c.shell.openTerminalTab(forceNew: true);
      final id = c.shell.activeTerminalId;
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
        shell['panelTabs'] = <String>[for (final t in c.shell.panelTabs) t.toString()];
        // 停止方块：进程退出、状态行变已退出。
        await c.shell.stopTerminalTab(term.id);
        final exited = await _waitFor(() => !term.running, timeout);
        shell['stoppedExited'] = exited;
        shell['exitCode'] = term.exitCode;
        shell['signal'] = term.signal;
        // 重启：同位置换新 shell；再关掉。
        await c.shell.restartTerminalTab(term.id);
        final fresh = c.shell.activeTerminalId;
        shell['restartedId'] = fresh;
        shell['restartedRunning'] = fresh == null ? null : c.terminals.byId(fresh)?.running;
        if (fresh != null) await c.shell.closeTerminalTab(fresh);
        shell['tabsAfterClose'] = c.terminals.tabs.length;
        shell['rightPanelOpen'] = c.shell.rightPanelOpen;
      }
      steps['localShell'] = shell;
    }

    // ---- 杀掉 agent（验收 6：34 的 exited 条 + 重启可用；应用不崩）
    trace('kill agent');
    if (_env('ACP_R3_KILL') == '1') {
      final pid = c.session.connection?.pid?.toInt();
      final kill = pid == null
          ? <String, dynamic>{'skipped': 'no pid in spawned event'}
          : await Process.run('taskkill', <String>['/F', '/T', '/PID', '$pid']).then(
              (r) => <String, dynamic>{'pid': pid, 'exitCode': r.exitCode, 'stdout': '${r.stdout}'.trim()},
            );
      // 等 exited 事件落到投影层（画板 34 的 exited 条就是它）。
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (c.session.connection?.state != AgentLifecycle.exited && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      steps['killAgent'] = <String, dynamic>{
        'taskkill': kill,
        'state': c.session.connection?.state.wire,
        'exitCode': c.session.connection?.exitCode,
        'stderrTail': c.session.connection?.stderrTail,
        'stderrLines': c.session.connection?.stderrLines.length,
      };
    }

    // ---- 重载 agent（验收 3 / 6）
    trace('reload agent');
    final before = c.session.sessionId;
    await c.session.reloadAgent().timeout(timeout);
    steps['reloadAgent'] = <String, dynamic>{
      'sessionBefore': before,
      'sessionAfter': c.session.sessionId,
      'newSession': before != c.session.sessionId,
      'agentState': c.session.connection?.state.wire,
      'transcriptOfOldSessionKept': c.sessions.maybe(before ?? '')?.entries.isNotEmpty ?? false,
      'error': c.session.lastError,
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
    steps['droppedUpdates'] = c.session.droppedUpdates;

    // ---- R4：退出收尾（验收 4：应用退出时子进程全部回收）——与关窗走同一条 `shutdown()`。
    trace('shutdown');
    await c.shutdown();
    steps['shutdown'] = <String, dynamic>{'agentState': c.session.connection?.state.wire, 'terminalTabs': c.terminals.tabs.length};

    report['ok'] = true;
    exitCode = 0;
  } catch (e, st) {
    report['error'] = e.toString();
    report['stack'] = st.toString();
    report['lastError'] = controller?.toasts.latest;
  }
  // 正常走完的那条上面已经收过尾（报告里的 `steps.shutdown`），这里再调一次是空转；中途出错跳出来的靠这一下。
  await _shutdown(controller, report);
  _finish(reportPath, report, exitCode, 'r3');
}

Map<String, dynamic> _turnSummary(WorkbenchController c, String prompt) {
  final store = c.session.store!;
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

/// 各模式在 [_finish] 之前都要走的一步：断开全部 agent、释放终端（与关窗同一条 `shutdown()`）。`exit()` 不跑析构，
/// 没断开的 agent 进程树会留成孤儿——R5 实测 Cursor 拉的 node.exe 在无头进程退出后还活着（BACKLOG P0「退出时 agent 的
/// 子进程没回收」）。出错跳出 try 的那条路也要走到这里，所以放在 try / catch 之后。`shutdown()` 可重复调。
Future<void> _shutdown(WorkbenchController? controller, Map<String, dynamic> report) async {
  try {
    await controller?.shutdown();
  } on Object catch (e) {
    report['shutdownError'] = e.toString();
  }
  controller?.dispose();
}

/// 各模式共用的收尾：写报告（目录不存在就建）、退出码即结论；报告写不出去也算失败。
Never _finish(String reportPath, Map<String, dynamic> report, int exitCode, String tag) {
  try {
    final file = File(reportPath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    stderr.writeln('[$tag] report → $reportPath (ok=${report['ok']})');
  } on Object catch (_) {
    exitCode = 1;
  }
  exit(exitCode);
}

const String clipboardProbeEnv = 'ACP_CLIPBOARD_PROBE';

String? clipboardProbePathFromEnvironment() => _env(clipboardProbeEnv);

/// 剪贴板探针（规则 9 的 Windows 实测口子）：读一次剪贴板（走 runner 的 `readClipboardImages`），每张图记来源 /
/// mimeType / 字节数；PNG 另解一遍记尺寸与左上角像素，验位图那条路的 BGRA → PNG 没把通道或行序弄反。
/// 按路径引用的那一份（复制的文件与目录）原样记进 `paths`。主读按「agent 收图」；另按「不收图」再读一次记进
/// `withoutImages`，验 runner 认 `{"bitmap": false}`（剪贴板里是截图时那一份应当什么都没有）。
Future<void> runClipboardProbe({required String reportPath}) async {
  final report = <String, dynamic>{'ok': false};
  var exitCode = 1;
  try {
    final result = await readClipboard(images: true);
    final images = <Map<String, dynamic>>[];
    for (final image in result.images) {
      final entry = <String, dynamic>{'mimeType': image.mimeType, 'path': image.path, 'bytes': image.bytes.length};
      if (image.mimeType == 'image/png') {
        final decoded = await decodeImageFromList(image.bytes);
        final rgba = await decoded.toByteData(format: ui.ImageByteFormat.rawRgba);
        entry['width'] = decoded.width;
        entry['height'] = decoded.height;
        entry['topLeftRgba'] = rgba?.buffer.asUint8List(rgba.offsetInBytes, 4).toList();
        decoded.dispose();
      }
      images.add(entry);
    }
    report['images'] = images;
    report['paths'] = result.paths;
    report['skippedTooLarge'] = result.skippedTooLarge;
    report['skippedTooMany'] = result.skippedTooMany;
    final plain = await readClipboard(images: false);
    report['withoutImages'] = <String, dynamic>{'images': plain.images.length, 'paths': plain.paths};
    report['ok'] = true;
    exitCode = 0;
  } catch (e, st) {
    report['error'] = e.toString();
    report['stack'] = st.toString();
  }
  _finish(reportPath, report, exitCode, 'clipboard');
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

  /// 已代答过的队列项，**按对象身份**去重而不是 requestId：agent 重连后 JSON-RPC id 从头再来
  /// （fake-agent 每个进程都从 100 开始），按 id 去重会把重连后的第一批请求当成「答过了」而不再回，
  /// agent 就一直等着（R6 实测 2026-09-16：载回会话后的第二轮 prompt 因此超时）。
  final Set<Object> _done = Set<Object>.identity();

  void attach() => c.sessions.pending.addListener(_tick);

  void detach() => c.sessions.pending.removeListener(_tick);

  void _tick() {
    final store = c.session.store;
    if (store == null) return;
    // requestScope 的 elicitation（无 sessionId，认证阶段）不在会话队列里：R3 没有认证页（画板 52 归 R5），
    // 但不回应 agent 会一直等，所以验收脚本这里一并代答，并在报告里标出来。
    final queue = <TranscriptEntry>[...store.pending.forSession(store.sessionId), ...c.sessions.pending.requestScope];
    for (final e in queue) {
      if (e is PermissionEntry && _done.add(e)) {
        if (permission == 'none') continue;
        final option = _pick(e);
        log.add(<String, dynamic>{
          'kind': 'permission',
          'requestId': e.requestId,
          'title': e.toolCallPatch.title,
          'options': <String?>[for (final o in e.options) '${o.optionId}/${o.kind}'],
          'answered': option,
        });
        if (option != null) unawaited(c.turn.answerPermission(e.requestId, option));
      } else if (e is ElicitationEntry && _done.add(e)) {
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
          final agent = e.agentId ?? c.session.agentId;
          if (payload != null && bridge != null && agent != null) {
            unawaited(bridge.acpRespond(agent, e.requestId, payload));
          }
        } else {
          unawaited(c.turn.answerElicitation(e.requestId, 'accept', e.wire.isUrl ? null : <String, dynamic>{}));
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
    final store = c.session.store;
    if (store == null) return;
    for (final e in store.entries) {
      if (e is! ToolCallEntry || e.isFinished) continue;
      for (final id in e.terminalIds) {
        final buffer = store.terminals[id];
        if (buffer == null || buffer.exited || _timers.containsKey(id)) continue;
        _timers[id] = Timer(delay, () {
          if (store.terminals[id]?.exited ?? true) return;
          killed.add(id);
          unawaited(c.turn.killTerminal(id));
        });
      }
    }
  }
}

/// `ProjectRef` / `AgentRef` 在 `lib/ui/popovers/topbar_popovers.dart`，这里只给两个构造糖。
ProjectRef _projectOf(String path) =>
    ProjectRef(path: path, name: path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).last);

AgentRef _agentOf(String id) => AgentRef(id: id, name: id);
