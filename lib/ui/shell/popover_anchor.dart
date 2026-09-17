// 弹层锚点：把触发控件（顶栏的项目名 / 分支名、线程头的 ≡、输入框的 + 与三个下拉…）与画板 40 / 41 / 42 的弹层连起来。
// 壳的 widget 只负责「把自己包进锚点」并在点击时回调；弹层内容由组合根给（`PopoverHandle.show`），
// 这样接线阶段不需要改任何 widget 的布局与 token（CLAUDE.md 规则 3）。
//
// 用 `OverlayPortal` + `CompositedTransformFollower`：弹层浮在 Overlay 上，位置跟着触发控件走，
// 点弹层之外的任何地方关闭（画板上弹层都是点外即关的临时表面）。

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;

/// 一个弹层的句柄：组合根持有（放在 State 里，别每帧新建），传给壳的 widget 做锚点。
class PopoverHandle {
  final LayerLink link = LayerLink();
  final OverlayPortalController controller = OverlayPortalController();

  /// 弹层内容。组合根在 [show] 时给；`OverlayPortal` 每帧重建 overlay child，
  /// 所以 builder 要直接读组合根的当前状态（别捕获快照），弹层才会跟着投影层刷新。
  WidgetBuilder _builder = _empty;
  Alignment _targetAnchor = Alignment.bottomLeft;
  Alignment _followerAnchor = Alignment.topLeft;
  Offset _offset = t.Geometry.popoverBelow;

  /// 「点弹层之外关闭」时要回收的组合根状态。侧栏删除确认要清 `confirmingDeleteId`，
  /// 否则那一行会一直停在悬浮态（锚点还挂着）。每次 [show] 都重设，不传就是没有。
  VoidCallback? _onDismiss;

  bool get isShowing => controller.isShowing;

  void show(
    WidgetBuilder builder, {
    Alignment targetAnchor = Alignment.bottomLeft,
    Alignment followerAnchor = Alignment.topLeft,
    Offset offset = t.Geometry.popoverBelow,
    VoidCallback? onDismiss,
  }) {
    _builder = builder;
    _targetAnchor = targetAnchor;
    _followerAnchor = followerAnchor;
    _offset = offset;
    _onDismiss = onDismiss;
    controller.show();
  }

  /// 输入框上方的弹层（`+`、模型 / 思考强度 / 模式、用量）：向上展开。
  void showAbove(WidgetBuilder builder, {Alignment targetAnchor = Alignment.topLeft, Alignment followerAnchor = Alignment.bottomLeft}) =>
      show(builder, targetAnchor: targetAnchor, followerAnchor: followerAnchor, offset: t.Geometry.popoverAbove);

  void hide() => controller.hide();

  /// 点弹层之外：关掉并回收 [show] 时登记的状态（组合根那边的「正在确认」之类）。
  void _dismiss() {
    final onDismiss = _onDismiss;
    _onDismiss = null;
    controller.hide();
    onDismiss?.call();
  }

  void toggle(WidgetBuilder builder, {Alignment targetAnchor = Alignment.bottomLeft, Alignment followerAnchor = Alignment.topLeft}) {
    if (controller.isShowing) {
      controller.hide();
    } else {
      show(builder, targetAnchor: targetAnchor, followerAnchor: followerAnchor);
    }
  }

  static Widget _empty(BuildContext context) => const SizedBox.shrink();
}

/// 把 [child]（触发控件）包成锚点。`handle` 为 null 时原样返回，gallery 里就不需要 Overlay。
class PopoverAnchor extends StatelessWidget {
  const PopoverAnchor({super.key, required this.handle, required this.child});

  final PopoverHandle? handle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final h = handle;
    if (h == null) return child;
    return CompositedTransformTarget(
      link: h.link,
      child: OverlayPortal(
        controller: h.controller,
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
              child: Align(alignment: Alignment.topLeft, widthFactor: 1, heightFactor: 1, child: h._builder(context)),
            ),
          ],
        ),
        child: child,
      ),
    );
  }
}
