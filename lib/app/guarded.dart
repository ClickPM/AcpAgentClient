// 组合根与它的八个子对象共用的通知与错误边界（R7.5 组合根拆分）：原 `WorkbenchController` 的
// `_guard` / `_touch` / `_disposed` / `lastError` 原样搬到这里，一份代码九个对象混入。
// iteration-04 又收编了 `FilesState` / `LocalTerminals` / `AppearanceController` / `TranscriptFolds` 各自那份挡板
// （后两者没有桥命令的错误边界，只用 [GuardedNotifier.disposed] 与 [GuardedNotifier.touch]）。

import 'package:flutter/foundation.dart';

import '../ui/shell/popover_anchor.dart';
import 'core_bridge.dart';

mixin GuardedNotifier on ChangeNotifier {
  /// 最近一次桥命令的错误：谁的命令谁记。写进来的每一句（非 null）同时交给 [reportError]——
  /// 组合根把它接到壳级提示（toast，`lib/app/toasts.dart`）上，于是二十几处 `lastError = …` 不用逐处改就都有了前台出口。
  String? get lastError => _lastError;
  set lastError(String? value) {
    _lastError = value;
    if (value != null) reportError?.call(value);
  }

  String? _lastError;

  /// 错误的前台出口，组合根构造时接线；单测里单独 new 的对象不接，就只记不报。
  void Function(String message)? reportError;

  bool _disposed = false;

  /// 已经 dispose：之后的 [touch] 不再通知。
  bool get disposed => _disposed;

  /// [guard] 打日志的前缀：组合根与八个子对象都是 `workbench`，文件面板 / 本地终端各用自己的。
  @protected
  String get logTag => 'workbench';

  /// 命令统一的错误边界：桥抛出的 `BridgeError` 记到 [lastError]，不让它掀掉整棵树。
  Future<T?> guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (e) {
      lastError = describeError(e);
      debugPrint('[$logTag] ${describeError(e)}');
      if (!_disposed) notifyListeners();
      return null;
    }
  }

  void touch() {
    if (!_disposed) notifyListeners();
  }

  /// [dispose] 正文一开始就立旗：释放子对象的过程中不再往外通知（组合根的 dispose 要先收流再 super）。
  @protected
  void markDisposed() => _disposed = true;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 关弹层：没在显示的不调 `hide()`——`OverlayPortalController.hide()` 在没挂到 widget 树、也没 show 过时会 assert
/// （无头实跑与单测里没有 Overlay；产品路径永远有锚点，`isShowing` 在未挂载时不会 assert）。
void hidePopover(PopoverHandle handle) {
  if (handle.isShowing) handle.hide();
}
