// 画板 08 B · 回合折叠的摘要行。两态同一个入口：
// - **折叠**：`fold.row` 容器（padding 7/10 · radius 6 · panel 底 · 1px subtle 边），`›` + 「处理详情 · N 条消息 · N 次工具调用」，
//   第二行是本回合开始时的模型名；没有模型信息时退化成单行（画板「无模型信息时 · 单行」样张）。
// - **展开**：无容器无底色的标题行，`⌄` + 「处理详情」+ 一行 11px 灰色摘要（模型名 · 计数）。
//
// 整行可点（非只有 chevron）、是 tab 停靠点、Enter / Space 切换、带 `button` + `expanded` 语义。
// 键盘聚焦复用 `fold.hover` 那一档底色——这一组 token 里只有它是「整行可点的反馈」，不另造焦点环。
// 折叠 / 展开**不做高度过渡**（画板：长转录做高度动画必抽动），淡入由调用方给（画板 05 的 motion.fast）。

import 'package:flutter/widgets.dart';

import '../../projection/turn_fold.dart';
import '../../theme/tokens.dart' as t;
import '../shell/shell_common.dart';
import 'card_chrome.dart';
import 'icons.dart';

class TurnFoldRow extends StatelessWidget {
  const TurnFoldRow({super.key, required this.fold, required this.collapsed, this.onToggle, this.forceHover = false});

  final TurnFold fold;
  final bool collapsed;
  final VoidCallback? onToggle;

  /// gallery 出悬浮样张用。
  final bool forceHover;

  /// 「N 条消息 · N 次工具调用」。计数口径见画板：条消息 = 被折叠的块数（含思考块与中间的 agent 文本段），
  /// 次工具调用 = tool_call 块数（失败与取消计入）。
  String get _counts => '${fold.messages} 条消息 · ${fold.toolCalls} 次工具调用';

  String get _failures => '${fold.failures} 项失败';

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      expanded: !collapsed,
      label: '处理详情，$_counts${fold.failures > 0 ? '，$_failures' : ''}',
      onTap: onToggle,
      child: _Activatable(
        onActivate: onToggle,
        builder: (context, focused) => Hoverable(
          onTap: onToggle,
          forceHover: forceHover,
          builder: (context, hovered) => collapsed
              ? _collapsed(highlighted: hovered || focused)
              : _expanded(highlighted: focused),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 折叠态

  Widget _collapsed({required bool highlighted}) {
    final Widget first = _firstLine();
    final String? model = fold.turn.model;
    return Container(
      padding: t.Fold.rowPadding,
      decoration: BoxDecoration(
        color: highlighted ? t.Fold.hover : t.Fold.bg,
        borderRadius: t.Fold.radius,
        border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
      ),
      child: model == null
          ? first
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                first,
                const SizedBox(height: t.Fold.lineGap),
                Padding(
                  padding: const EdgeInsets.only(left: t.Fold.secondLineIndent),
                  child: Text(model, style: t.TextStyles.meta, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
    );
  }

  Widget _firstLine() => Row(
        children: <Widget>[
          AcpIcon(AcpIcons.chevronRight, color: t.Neutral.muted, size: t.IconSizes.toolbar),
          const SizedBox(width: t.Spacing.s8),
          Flexible(child: Text('处理详情', style: CardText.headerTitle, maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: t.Spacing.s8),
          Flexible(child: Text(_counts, style: _countStyle, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (fold.failures > 0) ...<Widget>[
            const SizedBox(width: t.Spacing.s8),
            Text(_failures, style: _countStyle.copyWith(color: t.Semantic.error)),
          ],
        ],
      );

  // ---------------------------------------------------------------- 展开态

  Widget _expanded({required bool highlighted}) {
    final String? model = fold.turn.model;
    final String meta = model == null ? _counts : '$model · $_counts';
    return Container(
      padding: t.Fold.headerPadding,
      decoration: BoxDecoration(color: highlighted ? t.Fold.hover : null, borderRadius: t.Fold.radius),
      child: Row(
        children: <Widget>[
          AcpIcon(AcpIcons.chevronDown, color: t.Neutral.muted, size: t.IconSizes.toolbar),
          const SizedBox(width: t.Spacing.s8),
          Text('处理详情', style: CardText.headerTitle),
          const SizedBox(width: t.Spacing.s8),
          Flexible(child: Text(meta, style: t.TextStyles.meta, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (fold.failures > 0) ...<Widget>[
            const SizedBox(width: t.Spacing.s8),
            Text(_failures, style: t.TextStyles.meta.copyWith(color: t.Semantic.error)),
          ],
        ],
      ),
    );
  }

  /// 13 / muted / 等宽数字：计数变化时不推着后面的文字左右跳。
  static TextStyle get _countStyle =>
      CardText.headerTitle.copyWith(color: t.Neutral.muted, fontFeatures: const <FontFeature>[FontFeature.tabularFigures()]);
}

/// Enter / Space 激活 + tab 停靠点。把「聚焦了没有」交给 builder，由调用方决定怎么表达。
class _Activatable extends StatefulWidget {
  const _Activatable({required this.builder, this.onActivate});

  final Widget Function(BuildContext context, bool focused) builder;
  final VoidCallback? onActivate;

  @override
  State<_Activatable> createState() => _ActivatableState();
}

class _ActivatableState extends State<_Activatable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => FocusableActionDetector(
        enabled: widget.onActivate != null,
        onFocusChange: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            widget.onActivate?.call();
            return null;
          }),
        },
        child: widget.builder(context, _focused),
      );
}
