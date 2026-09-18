// 画板 05「转场规格」的入场件。A（会话内容整块替换）/ B 阶段③（重载完成）/ C（右栏标签切换）
// 三组共用同一条规格，所以只有这一个件：
//   旧内容 —— 触发瞬间直接移除，**不做淡出**（A 组反例行：新旧内容任何一帧都不得同时可读）；
//   新内容 —— opacity 0 → 1、translateY `motion.rise` 8px → 0，`motion.transition` 200ms，`motion.ease`。
// 因此这里不是 AnimatedSwitcher：那个会把旧子树留下来反向播一遍，正好是画板禁止的做法。

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
  late final CurvedAnimation _enter = CurvedAnimation(
    parent: _controller,
    curve: Interval(
      widget.delay.inMicroseconds / (widget.delay + widget.duration).inMicroseconds,
      1,
      curve: t.Motion.curve,
    ),
  );

  @override
  void didUpdateWidget(MotionEnter oldWidget) {
    super.didUpdateWidget(oldWidget);
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
        child: Transform.translate(offset: Offset(0, widget.distance * (1 - _enter.value)), child: child),
      ),
    );
  }
}
