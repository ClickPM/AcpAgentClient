// 组合根与它的八个子对象共用的通知与错误边界（R7.5 组合根拆分）：原 `WorkbenchController` 的
// `_guard` / `_touch` / `_disposed` / `lastError` 原样搬到这里，一份代码九个对象混入。
// `FilesState` / `LocalTerminals` / `FontPrefsController` 各自还有一份同样的挡板，本轮不收编（记 rounds/BACKLOG.md）。

import 'package:flutter/foundation.dart';

import '../ui/shell/popover_anchor.dart';
import 'core_bridge.dart';

mixin GuardedNotifier on ChangeNotifier {
  /// 最近一次桥命令的错误：谁的命令谁记，组合根不再聚合（BACKLOG「`lastError` 在产品 UI 上没有出口」那条做壳级提示位时再聚合）。
  String? lastError;

  bool _disposed = false;

  /// 已经 dispose：之后的 [touch] 不再通知。
  bool get disposed => _disposed;

  /// 命令统一的错误边界：桥抛出的 `BridgeError` 记到 [lastError]，不让它掀掉整棵树。
  Future<T?> guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (e) {
      lastError = describeError(e);
      debugPrint('[workbench] ${describeError(e)}');
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
