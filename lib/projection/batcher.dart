// 按帧合并 `session/update`（docs/design.md § 9）：事件先进队列，一帧只让投影层通知一次监听者。
// 调度器注入：app 侧传 `SchedulerBinding.instance.scheduleFrameCallback`（lib/app/），测试传手动 flush；
// 缺省用微任务，纯 Dart 环境也能跑。不依赖 widget。

import 'dart:async';

import 'session_store.dart';

typedef FlushScheduler = void Function(void Function() flush);

class UpdateBatcher {
  UpdateBatcher(this.sessions, {FlushScheduler? scheduler}) : _scheduler = scheduler ?? _microtask;

  final Sessions sessions;
  final FlushScheduler _scheduler;
  final List<void Function()> _queue = <void Function()>[];
  bool _scheduled = false;
  int _holds = 0;

  int get pendingCount => _queue.length;
  bool get isScheduled => _scheduled;

  static void _microtask(void Function() flush) => scheduleMicrotask(flush);

  /// 排队一次应用（例如 `() => sessions.applySessionUpdateEnvelope(payload)`）。
  void enqueue(void Function() apply) {
    _queue.add(apply);
    if (!_scheduled && _holds == 0) {
      _scheduled = true;
      _scheduler(flush);
    }
  }

  /// `session/load` 的整段重放期间挂起刷新（R6，ROUNDS § 3「重放期间不逐条刷新 UI」）：
  /// 重放的几百条 `session/update` 照常入队，但一条都不落到 UI，直到 [release] 一次性刷完。
  /// 可重入（计数），调用方必须配 `try/finally`，否则异常会把 UI 永久挂起。
  void hold() => _holds++;

  void release() {
    if (_holds > 0) _holds--;
    if (_holds == 0) flush();
  }

  bool get isHeld => _holds > 0;

  /// 把队列里的全部应用包在一次 `Sessions.batch` 里执行；可手动调用（测试 / 需要立即刷新时）。
  void flush() {
    _scheduled = false;
    if (_holds > 0 || _queue.isEmpty) return;
    final work = List<void Function()>.of(_queue);
    _queue.clear();
    sessions.batch(() {
      for (final f in work) {
        f();
      }
    });
  }
}
