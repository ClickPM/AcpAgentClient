// 画板 05「转场规格」的入场件。A（会话内容整块替换）/ B 阶段③（重载完成）/ C（右栏标签切换）
// 三组共用同一条规格，所以只有这一个件：
//   旧内容 —— 触发瞬间直接移除，**不做淡出**（A 组反例行：新旧内容任何一帧都不得同时可读）；
//   新内容 —— opacity 0 → 1、translateY `motion.rise` 8px → 0，`motion.transition` 200ms，`motion.ease`。
// 因此这里不是 AnimatedSwitcher：那个会把旧子树留下来反向播一遍，正好是画板禁止的做法。
//
// 另有常驻动画（spinner、侧栏扫掠线）共用的低频时钟 [AmbientClock]，见文件末尾。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;

/// 内容整块替换时的入场。默认是 A / B / C 三组那条规格；D 组（弹层）换 [distance] 与 [duration] 复用同一个件。
///
/// [epoch] 每变一次重播一次；旧内容由调用方直接换掉，本件不持有它。
/// 传 null 就只在首次挂载时播一次 —— 弹层靠 `OverlayPortal` 挂载 / 卸载重播，没有 epoch 可给。
/// [delay] 只给成组错开用（画板 05 A 组：空态三层按 `motion.stagger` 40ms 递增，最多 3 个）。
class MotionEnter extends StatefulWidget {
  const MotionEnter({
    super.key,
    required this.epoch,
    required this.child,
    this.delay = Duration.zero,
    this.distance = t.Motion.rise,
    this.duration = t.Motion.transition,
  });

  final Object? epoch;
  final Duration delay;

  /// 起点相对终点的纵向偏移：正数从下方升上来（`motion.rise`、向上弹的弹层），
  /// 负数从上方落下来（向下弹的弹层）。终点一律是 0。
  final double distance;
  final Duration duration;
  final Widget child;

  @override
  State<MotionEnter> createState() => _MotionEnterState();
}

class _MotionEnterState extends State<MotionEnter> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: widget.delay + widget.duration)..forward();

  /// 错开靠 [Interval] 的起点，不靠延后 `forward()`：延后启动那段时间里 `value` 还是 0，
  /// 但 controller 已经在跑，`epoch` 若在延迟中途又变一次就会错位。
  late final CurvedAnimation _enter = CurvedAnimation(parent: _controller, curve: _interval(widget));

  /// 两者都是零时总长为零，按「不错开」算：`0 / 0` 是 NaN，[Interval] 的断言会炸。
  static Interval _interval(MotionEnter w) {
    final int total = (w.delay + w.duration).inMicroseconds;
    return Interval(total == 0 ? 0 : w.delay.inMicroseconds / total, 1, curve: t.Motion.curve);
  }

  @override
  void didUpdateWidget(MotionEnter oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 同一元素被复用而时长 / 延迟变了：下一次播放按新参数走，不冻在首次 build 的那一套上。
    if (oldWidget.delay != widget.delay || oldWidget.duration != widget.duration) {
      _controller.duration = widget.delay + widget.duration;
      _enter.curve = _interval(widget);
    }
    if (oldWidget.epoch != widget.epoch) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    // `CurvedAnimation` 自己订阅了 parent，不释放会被 leak tracker 记一笔。
    _enter.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _enter,
      // child 不进 builder 的闭包：入场期间每帧只重建 Opacity / Transform 两层，子树本身不重建。
      child: widget.child,
      builder: (BuildContext context, Widget? child) => Opacity(
        opacity: _enter.value,
        child: Transform.translate(offset: t.Motion.offsetY(widget.distance * (1 - _enter.value)), child: child),
      ),
    );
  }
}

/// 常驻动画（spinner、侧栏扫掠线）共用的低频时钟（iteration-14）。
///
/// 不用 `AnimationController.repeat()` 的原因：它每一帧都要一帧，而 Windows 嵌入层没有局部重绘——每一帧都是整窗重画、
/// 整块上屏（engine `shell/platform/windows/compositor_opengl.cc` 的 `Present`），帧率取 DWM 报的刷新率，应用侧设不了上限。
/// 一只 16px 的 spinner 就让 2880×1800 @ 120Hz 的整窗每秒重画 120 次（核显实测 72%、CPU 1.4 核）；
/// `RepaintBoundary` 只省重录，省不了合成与上屏。这里换成一个定时器：
/// - 所有订阅者挂在同一个定时器上，同一跳里一起弄脏，一跳只出一帧，屏上有几只 spinner 都一样；
/// - 间隔按窗口状态分档：前台 [t.Motion.ambientInterval]、失焦 [t.Motion.ambientIntervalInactive]、
///   最小化（`hidden` 及之后）停表——那几档框架本来就不出帧（`SchedulerBinding.handleAppLifecycleStateChanged`），定时器也不必空跳；
/// - 没有订阅者时定时器不存在。
///
/// 相位按帧时间戳取模（[SchedulerBinding.currentFrameTimeStamp]），不按跳数累加：定时器迟到不会让转速变慢，
/// 所有订阅者同相，测试的假时间下也是确定的（gallery 出图稳定）。
///
/// 用法：`AmbientClock.instance.phase(周期)` 当 [Animation] 交给 `RotationTransition` / `AnimatedBuilder`；
/// 调用方自己看 `TickerMode.valuesOf(context).enabled`，关掉时别订阅（与 `TickerProviderStateMixin` 同口径）。
class AmbientClock with WidgetsBindingObserver implements Listenable {
  AmbientClock._();

  /// 进程级单例，不释放。
  static final AmbientClock instance = AmbientClock._();

  final ObserverList<VoidCallback> _listeners = ObserverList<VoidCallback>();
  final Map<Duration, Animation<double>> _phases = <Duration, Animation<double>>{};
  Timer? _timer;
  Duration? _interval;
  bool _observing = false;
  Duration _frameTime = Duration.zero;

  /// 周期为 [period] 的 0 → 1 相位（linear、循环）。同一周期返回同一个对象：build 里现取不会让 `AnimatedWidget` 反复换订阅。
  Animation<double> phase(Duration period) => _phases.putIfAbsent(period, () => _AmbientPhase(this, period));

  /// 当前跳动间隔；null = 没在跳（没有订阅者，或窗口已 hidden）。
  @visibleForTesting
  Duration? get interval => _interval;

  /// 当前帧的时间戳；帧外（定时器回调里）沿用上一帧的——`currentFrameTimeStamp` 只在帧内有效。
  Duration get _now {
    final SchedulerBinding binding = SchedulerBinding.instance;
    if (binding.schedulerPhase != SchedulerPhase.idle) _frameTime = binding.currentFrameTimeStamp;
    return _frameTime;
  }

  @override
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
    _sync();
  }

  @override
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _sync();

  void _tick(Timer _) {
    // 回调里若有订阅者退订：先拷一份再逐个核对（与 AnimationLocalListenersMixin 同一做法）。
    for (final VoidCallback listener in _listeners.toList(growable: false)) {
      if (_listeners.contains(listener)) listener();
    }
  }

  void _sync() {
    final bool active = _listeners.isNotEmpty;
    if (active != _observing) {
      _observing = active;
      if (active) {
        WidgetsBinding.instance.addObserver(this);
      } else {
        WidgetsBinding.instance.removeObserver(this);
      }
    }
    final Duration? want = active ? _intervalFor(WidgetsBinding.instance.lifecycleState) : null;
    if (want == _interval) return;
    _timer?.cancel();
    _interval = want;
    _timer = want == null ? null : Timer.periodic(want, _tick);
  }

  static Duration? _intervalFor(AppLifecycleState? state) => switch (state) {
        null || AppLifecycleState.resumed => t.Motion.ambientInterval,
        AppLifecycleState.inactive => t.Motion.ambientIntervalInactive,
        AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached => null,
      };
}

/// [AmbientClock.phase] 的相位动画：值现算（帧时间戳对周期取模），通知挂在时钟上。没有终点，状态恒为 forward。
class _AmbientPhase extends Animation<double> {
  _AmbientPhase(this._clock, this._period);

  final AmbientClock _clock;
  final Duration _period;

  @override
  double get value {
    final int period = _period.inMicroseconds;
    return (_clock._now.inMicroseconds % period) / period;
  }

  @override
  AnimationStatus get status => AnimationStatus.forward;

  @override
  void addListener(VoidCallback listener) => _clock.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _clock.removeListener(listener);

  @override
  void addStatusListener(AnimationStatusListener listener) {}

  @override
  void removeStatusListener(AnimationStatusListener listener) {}
}
