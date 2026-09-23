// 壳级提示（toast）的状态（设计稿之外的增补，所有者 2026-09-23 直接要求；画在 lib/ui/shell/toast.dart）。
//
// 两路来源：
//   错误 —— 组合根把各对象 [GuardedNotifier.reportError] 接到 [Toasts.error]：谁的 `lastError` 写进一句，
//          原先只进 `debugPrint` 的那一行（新建 / 删除会话失败、附件超限、载不回历史……）就照原文摆到前台
//          （BACKLOG「失败没有出口，用户看到的是『点了没反应』」）。
//   正在载 —— 不存在这里：它跟着会话控制器的状态走（`SessionController.loadingSession`），由 [visible] 现拼，
//          切到别的会话就不显示、切回来还没载完就又显示（BACKLOG「点开旧会话时没有『正在载』」）。
//
// 自动收起的计时在 widget 里（`ToastCard`），这里只存列表：无头实跑与单测没有 widget，也就没有挂着的 Timer。

import 'package:flutter/foundation.dart';

import '../ui/shell/toast.dart';

class Toasts extends ChangeNotifier {
  /// 同时挂着的错误最多几条：再来一条就把最早的挤掉。
  static const int maxErrors = 3;

  static const String sessionLoadingText = '会话正在加载中，请稍后';

  static const ToastMessage _sessionLoading =
      ToastMessage(id: 'session-loading', kind: ToastKind.loading, text: sessionLoadingText);

  final List<ToastMessage> _errors = <ToastMessage>[];
  int _nextId = 0;
  bool _disposed = false;

  List<ToastMessage> get errors => List<ToastMessage>.unmodifiable(_errors);

  /// 最近报过的一句（收起了也还在）：无头实跑的失败报告读它，原先只读 `session.lastError`（BACKLOG 原 P5 条目）。
  String? latest;

  /// 界面上这一刻该挂的提示：正在载的那条（有的话）在最上，错误按先后往下排。
  List<ToastMessage> visible({required bool loadingSession}) =>
      <ToastMessage>[if (loadingSession) _sessionLoading, ..._errors];

  /// 报一句错误。同一句已经挂着就撤掉旧的、在最下面重新挂一条（重新计时），不叠两条：连点两下失败两次不刷屏。
  void error(String text) {
    if (_disposed) return;
    latest = text;
    _errors.removeWhere((ToastMessage m) => m.text == text);
    _errors.add(ToastMessage(id: _nextId++, kind: ToastKind.error, text: text));
    if (_errors.length > maxErrors) _errors.removeRange(0, _errors.length - maxErrors);
    notifyListeners();
  }

  /// 到时间或点了 ×。正在载的那条不在列表里，撤不掉也不用撤。
  void dismiss(ToastMessage toast) {
    if (_disposed) return;
    if (_errors.remove(toast)) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
