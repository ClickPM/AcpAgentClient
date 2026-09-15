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
  // 报告文件是唯一正式通道；写不出报告（目录不可写）也必须 exit，否则无头进程常驻、build.ps1 -Smoke 无限等待。
  try {
    final file = File(reportPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  } on Object catch (_) {
    exitCode = 1;
  }
  // stdout 只是顺带：无控制台的 Windows GUI 进程里句柄无效，写入可能抛异常或 flush 永不完成（R0 实测），
  // 所以既不 await flush、也不让它影响退出码。
  try {
    stdout.writeln('ACP_SMOKE ${report['ok'] == true ? 'OK' : 'FAIL'} $reportPath');
  } on Object catch (_) {
    // 忽略：没有控制台。
  }
  exit(exitCode);
}
