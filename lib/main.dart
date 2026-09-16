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
  // R5 的无头实跑（验收 1–6 的接线部分）：registry → 安装 → 新会话 → 认证 → 一轮 → Remove。
  final r5Report = r5ReportPathFromEnvironment();
  if (r5Report != null) {
    await runR5(reportPath: r5Report);
    return;
  }
  // R6 的无头实跑（验收 1 / 2 / 4 / 5 / 6）：会话生命周期 —— 新会话 → 一轮 → list 校对 → 重连 → load 重放 → resume / close / delete。
  final r6Report = r6ReportPathFromEnvironment();
  if (r6Report != null) {
    await runR6(reportPath: r6Report);
    return;
  }
  final source = DataSource.fromEnvironment();
  final bridge = source == DataSource.bridge ? await CoreBridge.load() : null;
  runApp(AcpApp(source: source, bridge: bridge));
}
