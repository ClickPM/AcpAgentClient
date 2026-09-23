// 窗口控制的 Dart 端（docs/design.md § 9 裁定）：MethodChannel `acp/window`，实现在 windows/runner/acp_window.cpp。
// 无边框窗口：— ☐ ✕ 画在应用自己的顶栏里（画板 01–04），拖拽由顶栏空白处的 pointer down 触发 `startDragging`
// （runner 转成 `WM_NCLBUTTONDOWN + HTCAPTION`，系统照常给贴边与甩动最大化）。
// 只有 Windows 有实现；其他平台调用静默忽略（macOS 在 R8 用原生 traffic lights）。

import 'dart:io';

import 'package:flutter/services.dart';

abstract final class AppWindow {
  static const MethodChannel _channel = MethodChannel('acp/window');

  static bool get supported => Platform.isWindows;

  static Future<void> minimize() => invoke<void>('minimize');

  static Future<void> toggleMaximize() => invoke<void>('toggleMaximize');

  static Future<void> close() => invoke<void>('close');

  static Future<bool> isMaximized() async => await invoke<bool>('isMaximized') ?? false;

  /// 顶栏空白处按下鼠标时调用：把拖拽交回系统。
  static Future<void> startDragging() => invoke<void>('startDragging');

  /// 调 runner 的一个方法；没有实现（flutter test / 其他平台）时回 null。壳之外也用它（剪贴板读取）。
  static Future<T?> invoke<T>(String method, [Object? arguments]) async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      // flutter test / 其他平台没有 runner 侧实现。
      return null;
    } on PlatformException {
      return null;
    }
  }
}
