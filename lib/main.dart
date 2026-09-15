import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'app/smoke.dart';

/// 组合根入口（lib/app/）。R0：加载 cdylib → 起壳；`ACP_SMOKE_REPORT=<file>` 时跑无头往返并退出。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final smokeReport = smokeReportPathFromEnvironment();
  if (smokeReport != null) {
    await runSmoke(reportPath: smokeReport);
    return;
  }
  runApp(const AcpApp());
}
