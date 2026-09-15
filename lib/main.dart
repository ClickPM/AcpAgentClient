import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'app/core_bridge.dart';
import 'app/headless_run.dart';
import 'app/smoke.dart';
import 'app/workbench_controller.dart';

/// 组合根入口（lib/app/）。加载 cdylib → 起工作台壳；`ACP_SMOKE_REPORT=<file>` 时跑无头往返并退出。
/// `--dart-define=DATA_SOURCE=fixtures` 时不碰 cdylib，直接回放 test/fixtures（gallery 与开发用）。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final smokeReport = smokeReportPathFromEnvironment();
  if (smokeReport != null) {
    await runSmoke(reportPath: smokeReport);
    return;
  }
  // R3 的无头实跑（验收 3–6）：驱动组合根对真实 agent 跑一遍，写 JSON 报告后退出。
  final r3Report = r3ReportPathFromEnvironment();
  if (r3Report != null) {
    await runR3(reportPath: r3Report);
    return;
  }
  final source = DataSource.fromEnvironment();
  final bridge = source == DataSource.bridge ? await CoreBridge.load() : null;
  runApp(AcpApp(source: source, bridge: bridge));
}
