// R0 验收第 2 项的无头自检：环境变量 `ACP_SMOKE_REPORT=<报告文件>` 时，不起 UI，
// 订阅事件 → core_init → ping → 等 `acp/agent_state: core_ready` → 写 JSON 报告 → 退出（0 = 全过）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../projection/wire.dart';
import 'core_bridge.dart';
import 'paths.dart';

const String smokeReportEnv = 'ACP_SMOKE_REPORT';

String? smokeReportPathFromEnvironment() {
  final v = Platform.environment[smokeReportEnv];
  return (v == null || v.trim().isEmpty) ? null : v.trim();
}

Future<void> runSmoke({required String reportPath}) async {
  final report = <String, dynamic>{'ok': false};
  var exitCode = 1;
  try {
    final bridge = await CoreBridge.load();
    final ready = Completer<JsonMap>();
    final sub = bridge.on(CoreEvent.agentState).listen((e) {
      final json = e.json;
      if (json != null && AgentStateWire(json).state == 'core_ready' && !ready.isCompleted) {
        ready.complete(json);
      }
    });
    final dataDir = defaultDataDir();
    report['init'] = await bridge.init(dataDir);
    report['ping'] = await bridge.ping('smoke');
    report['coreReady'] = await ready.future.timeout(const Duration(seconds: 5));
    report['droppedEvents'] = bridge.droppedEventCount;
    await sub.cancel();
    final ping = report['ping'] as JsonMap;
    final ok = ping['pong'] == 'smoke' && ping['sequence'] == 1 && report['droppedEvents'] == 0;
    report['ok'] = ok;
    exitCode = ok ? 0 : 1;
  } catch (e, st) {
    report['error'] = e.toString();
    report['stack'] = st.toString();
  }
  final file = File(reportPath);
  await file.parent.create(recursive: true);
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  // 无控制台的 Windows GUI 进程里 stdout 句柄无效，写它会抛异常并让进程挂在这里；报告文件才是正式通道。
  try {
    stdout.writeln('ACP_SMOKE ${report['ok'] == true ? 'OK' : 'FAIL'} $reportPath');
  } on Object catch (_) {
    // 忽略：没有控制台。
  } finally {
    exit(exitCode);
  }
}
