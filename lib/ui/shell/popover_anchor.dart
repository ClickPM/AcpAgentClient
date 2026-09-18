// 弹层锚点：把触发控件（顶栏的项目名 / 分支名、线程头的 ≡、输入框的 + 与三个下拉…）与画板 40 / 41 / 42 的弹层连起来。
// 壳的 widget 只负责「把自己包进锚点」并在点击时回调；弹层内容由组合根给（`PopoverHandle.show`），
// 这样接线阶段不需要改任何 widget 的布局与 token（CLAUDE.md 规则 3）。
//
// 用 `OverlayPortal` + `CompositedTransformFollower`：弹层浮在 Overlay 上，位置跟着触发控件走，
// 点弹层之外的任何地方关闭（画板上弹层都是点外即关的临时表面）。

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import 'motion.dart';

/// 一个弹层的句柄：组合根持有（放在 State 里，别每帧新建），传给壳的 widget 做锚点。
class PopoverHandle {
  final LayerLink link = LayerLink();

  /// 「要不要显示」归句柄自己管，不放在 `OverlayPortalController` 里：controller 只认**一个**
  /// `_OverlayPortalState`，而 `_OverlayPortalState.dispose()` 是**无条件**把它的 `_attachTarget` 置空的
  /// （Flutter 3.47 `widgets/overlay.dart`）。触发控件那一行只要增删兄弟节点——线程头连上 agent 后多出
  /// 铅笔与重载两个按钮——没写 key 的 `PopoverAnchor` 元素就会被拆掉重建，新元素先 attach、旧元素在帧末
  /// dispose 时又把它解绑：此后 `show()` 只改 controller 自己的 z 序，没有任何 `OverlayPortal` 渲染它，
  /// 点一下「没反应」、再点一下 `isShowing` 翻回 false，于是一次不出一次不出地烙下去
  /// （所有者手测 2026-09-17「有时候点 + 无反应」的成因）。
  /// 改成由 [PopoverAnchor] 在 `initState` 里按这个 notifier 重建自己那只 controller 的状态，
  /// 元素怎么拆怎么建都还原得回来。
  final ValueNotifier<bool> _visible = ValueNotifier<bool>(false);

  /// 弹层内容。组合根在 [show] 时给；`OverlayPortal` 每帧重建 overlay child，
  /// 所以 builder 要直接读组合根的当前状态（别捕获快照），弹层才会跟着投影层刷新。
  WidgetBuilder _builder = _empty;
  Alignment _targetAnchor = Alignment.bottomLeft;
  Alignment _followerAnchor = Alignment.topLeft;
  Offset _offset = t.Geometry.popoverBelow;

  /// 出场位移的方向（画板 05 D 组）：向下弹的弹层从上方 `-motion.pop` 落下，
  /// 向上弹的从下方 `+motion.pop` 升起。[showAbove] 会把它置 true。
  bool _fromAbove = false;

  /// 「点弹层之外关闭」时要回收的组合根状态。侧栏删除确认要清 `confirmingDeleteId`，
  /// 否则那一行会一直停在悬浮态（锚点还挂着）。每次 [show] 都重设，不传就是没有。
  VoidCallback? _onDismiss;

  bool get isShowing => _visible.value;

  void show(
    WidgetBuilder builder, {
    Alignment targetAnchor = Alignment.bottomLeft,
    Alignment followerAnchor = Alignment.topLeft,
    Offset offset = t.Geometry.popoverBelow,
    VoidCallback? onDismiss,
    bool fromAbove = false,
  }) {
    _builder = builder;
    _targetAnchor = targetAnchor;
    _followerAnchor = followerAnchor;
    _offset = offset;
    _onDismiss = onDismiss;
    _fromAbove = fromAbove;
    _visible.value = true;
  }

  /// 输入框上方的弹层（`+`、模型 / 思考强度 / 模式、用量）：向上展开。
  void showAbove(WidgetBuilder builder, {Alignment targetAnchor = Alignment.topLeft, Alignment followerAnchor = Alignment.bottomLeft}) =>
      show(builder,
          targetAnchor: targetAnchor, followerAnchor: followerAnchor, offset: t.Geometry.popoverAbove, fromAbove: true);

  void hide() => _visible.value = false;

  /// 点弹层之外：关掉并回收 [show] 时登记的状态（组合根那边的「正在确认」之类）。
  void _dismiss() {
    final onDismiss = _onDismiss;
    _onDismiss = null;
    hide();
    onDismiss?.call();
  }

  /// 组合根持有句柄，释放时调一次（审查 P3：`_visible` 是 `ValueNotifier`，不释放就一直活到进程结束）。
  void dispose() => _visible.dispose();

  void toggle(WidgetBuilder builder, {Alignment targetAnchor = Alignment.bottomLeft, Alignment followerAnchor = Alignment.topLeft}) {
    if (isShowing) {
      hide();
    } else {
      show(builder, targetAnchor: targetAnchor, followerAnchor: followerAnchor);
    }
  }

  static Widget _empty(BuildContext context) => const SizedBox.shrink();
}

/// 把 [child]（触发控件）包成锚点。`handle` 为 null 时原样返回，gallery 里就不需要 Overlay。
class PopoverAnchor extends StatefulWidget {
  const PopoverAnchor({super.key, required this.handle, required this.child});

  final PopoverHandle? handle;
  final Widget child;

  @override
  State<PopoverAnchor> createState() => _PopoverAnchorState();
}

class _PopoverAnchorState extends State<PopoverAnchor> {
  /// 每个锚点元素一只 controller（见 [PopoverHandle._visible] 的注释：共用一只会被拆掉的旧元素解绑）。
  final OverlayPortalController _controller = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    widget.handle?._visible.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(PopoverAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 元素被复用给另一个句柄（线程头那排动作增删兄弟节点时会发生）：换订阅，并按新句柄的状态重新对齐。
    if (oldWidget.handle != widget.handle) {
      oldWidget.handle?._visible.removeListener(_sync);
      widget.handle?._visible.addListener(_sync);
      if (oldWidget.handle == null) {
        // 上一帧 handle 为 null 时 [build] 直接返回 child、没有 OverlayPortal，controller 还没挂上：
        // 这时 show() 只记个序号，这一帧建出的 OverlayPortal 挂上就显示——侧栏删除确认走的就是这条路
        //（行里的 PopoverAnchor 只在「正在确认」时才拿到句柄），必须当帧生效。
        _sync();
      } else {
        // 已经挂上的 controller 在 build 里 show() / hide() 会 setState during build
        //（`_OverlayPortalState.show` 对此有断言，debug 下直接炸）。推到这一帧结束再对齐；晚一帧看不出来。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _sync();
        });
      }
    }
  }

  @override
  void dispose() {
    widget.handle?._visible.removeListener(_sync);
    super.dispose();
  }

  /// 句柄说显示就显示。`hide()` 在没显示时会 assert，所以两边都先比一下再动。
  void _sync() {
    final visible = widget.handle?.isShowing ?? false;
    if (visible == _controller.isShowing) return;
    if (visible) {
      _controller.show();
    } else {
      _controller.hide();
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.handle;
    if (h == null) return widget.child;
    return CompositedTransformTarget(
      link: h.link,
      child: OverlayPortal(
        controller: _controller,
        overlayChildBuilder: (context) => Stack(
          children: <Widget>[
            // 点弹层之外关闭。
            Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: h._dismiss)),
            CompositedTransformFollower(
              link: h.link,
              targetAnchor: h._targetAnchor,
              followerAnchor: h._followerAnchor,
              offset: h._offset,
              showWhenUnlinked: false,
              // widthFactor / heightFactor 必须给：Stack 的非定位子节点拿到的是「整屏」的松约束，
              // 不收紧的话 Align 会撑满整屏，`followerAnchor` 算的就是**整屏**的角而不是弹层自己的角 ——
              // `showAbove`（followerAnchor: bottomLeft）于是把弹层顶到屏幕顶上去了
              //（所有者手测 2026-09-17「消息发送区的下拉窗口位置全部漂移」的成因；
              // 顶栏那些 followerAnchor: topLeft 的弹层因为两个角重合，才一直看着是对的）。
              // 画板 05 D 组：出场 opacity 0 → 1 + `motion.pop` 位移，`motion.base` 160ms；
              // 不缩放，阴影跟着弹层自己那一条时间线；**关闭不做动画**，`OverlayPortal` 直接卸载即可。
              // 没有 epoch：重播靠的就是这次卸载与下次挂载。
              child: Align(
                alignment: Alignment.topLeft,
                widthFactor: 1,
                heightFactor: 1,
                child: MotionEnter(
                  epoch: null,
                  distance: h._fromAbove ? t.Motion.pop : -t.Motion.pop,
                  duration: t.Motion.base,
                  child: h._builder(context),
                ),
              ),
            ),
          ],
        ),
        child: widget.child,
      ),
    );
  }
}
