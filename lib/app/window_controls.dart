// 窗口控制的 Dart 端（docs/design.md § 9 裁定）：MethodChannel `acp/window`，实现在
// windows/runner/acp_window.cpp 与 macos/Runner/MainFlutterWindow.swift。
// Windows：— ☐ ✕ 画在应用自己的顶栏里（画板 01–04），拖拽转成 `WM_NCLBUTTONDOWN + HTCAPTION`；
// macOS：使用左上角原生 traffic lights，拖拽走 `performDrag(with:)`，双击标题栏触发 `performZoom`。

import 'dart:io';

import 'package:flutter/services.dart';

abstract final class AppWindow {
  static const MethodChannel _channel = MethodChannel('acp/window');

  static bool get supported => Platform.isWindows || Platform.isMacOS;

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
