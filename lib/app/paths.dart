// 数据目录（docs/design.md § 10）：Windows `%APPDATA%/AcpAgentClient`，macOS `~/Library/Application Support/AcpAgentClient`，
// Linux `$XDG_DATA_HOME/AcpAgentClient`（缺省 `~/.local/share`）。纯 Dart，不依赖 widget。

import 'dart:io';

const String appDirName = 'AcpAgentClient';

String defaultDataDir({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  if (Platform.isWindows) {
    final appData = env['APPDATA'];
    if (appData != null && appData.isNotEmpty) return '$appData\\$appDirName';
    final profile = env['USERPROFILE'] ?? 'C:\\';
    return '$profile\\AppData\\Roaming\\$appDirName';
  }
  final home = env['HOME'] ?? '/';
  if (Platform.isMacOS) return '$home/Library/Application Support/$appDirName';
  final xdg = env['XDG_DATA_HOME'];
  final base = (xdg != null && xdg.isNotEmpty) ? xdg : '$home/.local/share';
  return '$base/$appDirName';
}
