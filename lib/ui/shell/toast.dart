// 壳级提示（toast，设计稿之外的增补，所有者 2026-09-23 直接要求）：浮在中栏正文区顶部居中（会话头正下方），两种——
//   正在做、要等 —— spinner + 一句话，跟着状态出现与消失，不计时、不能关；
//   出错了 —— 红色图标 + 原因，[t.Toast.errorDuration] 后自己收起，鼠标停在上面时不计时，也可以点 × 关掉。
// 这里只管画与计时；谁在什么时候出哪一条由 lib/app/toasts.dart 决定。
// 样式只取 tokens（CLAUDE.md 规则 3）：底色 / 边框 / 阴影借弹层（[Popover]），几何与时长在 `t.Toast`。

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';
import 'motion.dart';
import 'shell_common.dart';

enum ToastKind { loading, error }

/// 一条提示。[id] 是它在界面上的身份：同一 id 的提示条重建时保留计时与悬停态，换了 id 就是新的一条（重新计时）。
@immutable
class ToastMessage {
  const ToastMessage({required this.id, required this.kind, required this.text});

  final Object id;
  final ToastKind kind;
  final String text;
}

/// 把 [toasts] 叠在 [child] 上：顶部居中、自上而下排；提示条以外的地方点击照常落到 [child]。
///
/// 没有提示时也保持同一个 `Stack`：[child] 的位置不随提示出没变，转录的滚动位置与卡片展开态不会因此重建丢掉。
class ToastLayer extends StatelessWidget {
  const ToastLayer({super.key, required this.toasts, required this.child, this.onDismiss});

  final List<ToastMessage> toasts;
  final Widget child;

  /// 错误提示到了时间，或点了 ×。
  final ValueChanged<ToastMessage>? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Stack(
      // expand：[child] 原来拿的是 `Expanded` 给的紧约束，叠一层之后仍然是。
      fit: StackFit.expand,
      children: <Widget>[
        child,
        if (toasts.isNotEmpty)
          Positioned(
            top: t.Toast.top,
            left: t.Toast.sideMargin,
            right: t.Toast.sideMargin,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final (int i, ToastMessage toast) in toasts.indexed) ...<Widget>[
                  if (i > 0) const SizedBox(height: t.Toast.gap),
                  ToastCard(
                    key: ValueKey<Object>(toast.id),
                    toast: toast,
                    onDismiss: onDismiss == null ? null : () => onDismiss!(toast),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// 一条提示条。出现时照弹层的规格从上方落下（画板 05 D 组：`motion.pop` + `motion.base`），收起不做动画。
class ToastCard extends StatefulWidget {
  const ToastCard({super.key, required this.toast, this.onDismiss});

  final ToastMessage toast;
  final VoidCallback? onDismiss;

  @override
  State<ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<ToastCard> {
  Timer? _timer;

  bool get _isError => widget.toast.kind == ToastKind.error;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(ToastCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.toast.kind != widget.toast.kind) _arm();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 错误提示开始（重新）计时；正在等的那种跟着状态走，不计时。
  void _arm() {
    _timer?.cancel();
    _timer = _isError ? Timer(t.Toast.errorDuration, _dismiss) : null;
  }

  void _dismiss() {
    _timer?.cancel();
    _timer = null;
    widget.onDismiss?.call();
  }

  /// 鼠标停在提示条上是在读它：停表；移开后从头计。
  void _onHover(bool hovered) {
    if (!_isError) return;
    if (hovered) {
      _timer?.cancel();
      _timer = null;
    } else {
      _arm();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Hoverable(
        cursor: MouseCursor.defer,
        onHoverChanged: _onHover,
        builder: (BuildContext context, bool hovered) => MotionEnter(
          epoch: null,
          distance: -t.Motion.pop,
          duration: t.Motion.base,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: t.Toast.maxWidth),
            child: Popover(padding: t.Toast.padding, child: _row()),
          ),
        ),
      ),
    );
  }

  /// 最小高度加在行上而不是弹层外面：弹层里是个 `Stack`，外面给的最小高度撑大的是它，行会贴在顶上。
  /// 加在行上，单行时图标、文字与 × 在 [t.Toast.minHeight] 里竖向居中。
  Widget _row() {
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: t.Toast.minHeight - t.Toast.padding.vertical),
      child: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (_isError) AcpIcon(AcpIcons.slashCircle, color: t.Semantic.error, size: t.IconSizes.toolbar) else Spinner(),
        const SizedBox(width: t.Toast.gap),
        Flexible(
          child: Text(widget.toast.text, style: t.TextStyles.body, maxLines: t.Toast.maxLines, overflow: TextOverflow.ellipsis),
        ),
        if (_isError) ...<Widget>[
          const SizedBox(width: t.Toast.gap),
          IconButtonGhost(icon: AcpIcons.x, size: t.Controls.compact, onTap: _dismiss),
        ],
      ],
      ),
    );
  }
}
