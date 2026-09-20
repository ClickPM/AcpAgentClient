import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'app/core_bridge.dart';
import 'app/smoke.dart';
import 'app/workbench_controller.dart';

/// 组合根入口（lib/app/）。加载 cdylib → 起工作台壳；`ACP_SMOKE_REPORT=<file>` 时跑无头往返自检并退出
/// —— 那是发布包自己的自检口子（scripts/build.ps1 -Smoke 与 verify-package.ps1 用它），留在产品入口里。
/// `--dart-define=DATA_SOURCE=fixtures` 时不碰 cdylib，直接回放 test/fixtures（gallery 与开发用）。
/// R3 / R5 / R6 的无头验收驱动**不在这里**：它们是验收脚本，入口是 lib/main_headless.dart（`flutter build -t`）。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final smokeReport = smokeReportPathFromEnvironment();
  if (smokeReport != null) {
    await runSmoke(reportPath: smokeReport);
    return;
  }
  final source = DataSource.fromEnvironment();
  final bridge = source == DataSource.bridge ? await CoreBridge.load() : null;
  runApp(AcpApp(source: source, bridge: bridge));
}
