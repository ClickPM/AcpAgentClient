// 无头验收驱动的入口 —— **不是产品入口**。R3 / R5 / R6 的三个无头实跑模式与剪贴板探针都从这里进，
// 靠环境变量选模式（各模式的变量见 lib/app/headless_run.dart 文件头）。
//
// 为什么单独一个入口：这些驱动是验收脚本，此前挂在 lib/main.dart 上，发布包里带着它们、而且任何人设一个
// 环境变量就能把桌面应用切成无头模式。Flutter 自带多入口（`-t`），产品的 main.dart 不再 import 它们。
// 用法（与以前只差一个 -t）：
//   flutter build windows --release -t lib/main_headless.dart
//   $env:ACP_R3_REPORT="build\r3.json"; …; Start-Process build\windows\x64\runner\Release\acp_agent_client.exe -Wait
// 没给任何模式变量时按产品入口起窗口，同一份构建也能手测。

import 'package:flutter/widgets.dart';

import 'app/headless_run.dart';
import 'main.dart' as product;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  // 剪贴板探针（规则 9 的 Windows 实测口子）：读一次剪贴板里的图，写 JSON 报告后退出。
  final probeReport = clipboardProbePathFromEnvironment();
  if (probeReport != null) {
    await runClipboardProbe(reportPath: probeReport);
    return;
  }
  await product.main();
}
