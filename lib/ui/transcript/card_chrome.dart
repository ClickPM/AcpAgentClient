// 转录卡片的共用壳（画板 17–34 共用的形状）：卡片容器、32px 头行、底部收起条、分节标签、等宽块、徽章、按钮、kbd。
// 样式全部取 tokens；画板上非 4px 网格的内边距（10px）一律就近取 s8 / s12（R0 起的既定做法，像素差不作 finding）。

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/re_highlight.dart';

import '../../theme/tokens.dart' as t;
import 'icons.dart';

/// 从 tokens 派生的组合样式（不含字面量）。
abstract final class CardText {
  /// 代码 / 等宽块正文：mono 12.5 · lh 1.5。
  static final TextStyle code = t.TextStyles.mono.copyWith(height: t.LineHeights.body);

  /// 行内代码：mono 12.5 · surface 底。
  static final TextStyle inlineCode = t.TextStyles.mono.copyWith(backgroundColor: t.Neutral.surface);

  /// 头行副标题：mono 12.5 · muted。
  static final TextStyle subtitle = t.TextStyles.mono.copyWith(color: t.Neutral.muted);

  /// 链接：accent 文字。
  static final TextStyle link = t.TextStyles.body.copyWith(color: t.Accent.text);

  /// 加粗正文（13 / 500 / strong）。
  static final TextStyle strong = t.TextStyles.body.copyWith(
    fontWeight: t.Weights.medium,
    fontVariations: t.Weights.mediumVariation,
    color: t.Neutral.strong,
  );

  /// 卡片标题（13 / 500，text 色）。
  static final TextStyle cardTitle = t.TextStyles.body.copyWith(
    fontWeight: t.Weights.medium,
    fontVariations: t.Weights.mediumVariation,
    height: t.LineHeights.control,
  );

  /// 头行标题（13 / 400，text 色，控件行高）。
  static final TextStyle headerTitle = t.TextStyles.body.copyWith(height: t.LineHeights.control);

  /// 12 / 400 muted，控件行高。
  static final TextStyle secondary = t.TextStyles.secondary.copyWith(height: t.LineHeights.control);

  /// 按钮文字（13 / 400 / 控件行高）。
  static final TextStyle button = t.TextStyles.body.copyWith(height: t.LineHeights.control);

  /// 主按钮文字：accent 底上的白字。
  static final TextStyle buttonPrimary = button.copyWith(color: t.Accent.onAccent);

  /// 错误文本（mono）。
  static final TextStyle codeError = code.copyWith(color: t.Semantic.error);
}

/// 卡片容器：1px subtle 边框、radius 6、canvas 底、裁剪圆角。
class TranscriptCard extends StatelessWidget {
  const TranscriptCard({super.key, required this.child, this.background = t.Surface.canvas, this.clip = Clip.antiAlias});

  final Widget child;
  final Color background;
  final Clip clip;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: clip,
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
        borderRadius: t.Radii.card,
      ),
      child: child,
    );
  }
}

/// 卡片头行：32px · 0 10px · gap 8 · [前导图标][标题][副标题（mono，可省略）][尾部控件…]。
class CardHeader extends StatelessWidget {
  const CardHeader({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.subtitleWidget,
    this.trailing = const <Widget>[],
    this.onTap,
    this.titleStyle,
    this.height = t.Controls.input,
  });

  final Widget? leading;
  final String title;
  final String? subtitle;

  /// 副标题位置放自定义 widget（例如可点的路径芯片）。
  final Widget? subtitleWidget;
  final List<Widget> trailing;
  final VoidCallback? onTap;
  final TextStyle? titleStyle;
  final double height;

  @override
  Widget build(BuildContext context) {
    final row = SizedBox(
      height: height,
      child: Padding(
        padding: t.Controls.padInput,
        child: Row(
          children: <Widget>[
            if (leading != null) ...<Widget>[leading!, const SizedBox(width: t.Spacing.s8)],
            Text(title, style: titleStyle ?? CardText.headerTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (subtitleWidget != null) ...<Widget>[
              const SizedBox(width: t.Spacing.s8),
              Flexible(child: subtitleWidget!),
            ] else if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
              const SizedBox(width: t.Spacing.s8),
              Flexible(child: Text(subtitle!, style: CardText.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
            const Spacer(),
            for (var i = 0; i < trailing.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(width: t.Spacing.s8),
              trailing[i],
            ],
          ],
        ),
      ),
    );
    if (onTap == null) return row;
    return MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: row));
  }
}

/// 折叠 / 展开箭头（14 · placeholder 色）。
class Chevron extends StatelessWidget {
  const Chevron({super.key, required this.expanded, this.color = t.Neutral.placeholder});

  final bool expanded;
  final Color color;

  @override
  Widget build(BuildContext context) => AcpIcon(expanded ? AcpIcons.chevronUp : AcpIcons.chevronDown, color: color, size: t.IconSizes.toolbar);
}

/// 卡片展开体：上边框 + 8/12 内边距 + 子项间距 8。
class CardBody extends StatelessWidget {
  const CardBody({super.key, required this.children, this.padding});

  final List<Widget> children;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
      padding: padding ?? const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var i = 0; i < children.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: t.Spacing.s8),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// 底部收起条（画板 18 / 19：整宽的 ⌃ 条）。画板高 20，就近取控件高 24。
class CollapseBar extends StatelessWidget {
  const CollapseBar({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: t.Controls.compact,
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
        alignment: Alignment.center,
        child: const Chevron(expanded: true),
      ),
    );
  }
}

/// 分节标签（「Raw Input:」「Output:」「stderr 尾巴」）：11 / 500 / muted。
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: t.Spacing.s4),
        child: Text(text, style: t.TextStyles.label),
      );
}

/// 等宽文本块：panel 底、radius 4、8/12 内边距、pre-wrap。`background` 可换 error.soft 等。
class MonoBlock extends StatelessWidget {
  const MonoBlock({super.key, this.text, this.span, this.background = t.Neutral.panel, this.style, this.softWrap = true});

  final String? text;
  final InlineSpan? span;
  final Color background;
  final TextStyle? style;
  final bool softWrap;

  @override
  Widget build(BuildContext context) {
    final s = style ?? CardText.code;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(color: background, borderRadius: t.Radii.control),
      padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
      child: span != null ? Text.rich(span!, style: s, softWrap: softWrap) : Text(text ?? '', style: s, softWrap: softWrap),
    );
  }
}

/// JSON 语法着色（Raw Input / 权限请求的 toolCall）：键 accent、字符串 success、数字 warning（画板 18 / 25 的注释）。
abstract final class JsonHighlight {
  static final Highlight _hl = Highlight()..registerLanguage('json', langJson);

  static final Map<String, TextStyle> theme = <String, TextStyle>{
    'attr': const TextStyle(color: t.Accent.text),
    'string': const TextStyle(color: t.Semantic.success),
    'number': const TextStyle(color: t.Semantic.warning),
    'literal': const TextStyle(color: t.Accent.text),
    'punctuation': const TextStyle(color: t.Neutral.muted),
  };

  static String pretty(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  static TextSpan span(Object? value) {
    final text = pretty(value);
    final r = _hl.highlight(code: text, language: 'json');
    final renderer = TextSpanRenderer(CardText.code, theme);
    r.render(renderer);
    return renderer.span ?? TextSpan(text: text, style: CardText.code);
  }
}

/// 徽章 / 芯片：mono 11 · radius 3 · space.chip。
class Chip extends StatelessWidget {
  const Chip(this.text, {super.key, required this.background, required this.color, this.style});

  final String text;
  final Color background;
  final Color color;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: background, borderRadius: t.Radii.chip),
      padding: t.Spacing.chip,
      child: Text(text, style: (style ?? t.TextStyles.monoMeta).copyWith(color: color)),
    );
  }
}

/// 语义徽章：success / warning / error / neutral 四色（画板 31 的 stopReason、21 的 +N −M、29 的 priority）。
enum ChipTone { success, warning, error, neutral, accent }

class ToneChip extends StatelessWidget {
  const ToneChip(this.text, {super.key, required this.tone, this.style});

  final String text;
  final ChipTone tone;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (tone) {
      ChipTone.success => (t.Semantic.successSoft, t.Semantic.success),
      ChipTone.warning => (t.Semantic.warningSoft, t.Semantic.warning),
      ChipTone.error => (t.Semantic.errorSoft, t.Semantic.error),
      ChipTone.neutral => (t.Neutral.surface, t.Neutral.muted),
      ChipTone.accent => (t.Accent.soft, t.Accent.text),
    };
    return Chip(text, background: bg, color: fg, style: style);
  }
}

/// kbd：mono 11 · 1px 边框 · radius 3 · 0 4px · 行框 16。`onAccent` = 强调色底上的版本（border.on-accent + 白字）。
class Kbd extends StatelessWidget {
  const Kbd(this.text, {super.key, this.onAccent = false});

  final String text;
  final bool onAccent;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: t.Kbd.lineHeightPx,
      padding: t.Kbd.padding,
      decoration: BoxDecoration(
        border: Border.all(color: onAccent ? t.Accent.borderOnAccent : t.Kbd.border, width: t.Borders.width),
        borderRadius: t.Kbd.radius,
      ),
      alignment: Alignment.center,
      child: Text(text, style: onAccent ? t.Kbd.text.copyWith(color: t.Accent.onAccent) : t.Kbd.text),
    );
  }
}

/// 按钮四态（tokens「控件高度 · 按钮四态」）：primary / ghost（透明底，hover 6%）/ outline（popover 底 + 边框）。
enum ButtonKind { primary, ghost, outline }

class AcpButton extends StatefulWidget {
  const AcpButton({
    super.key,
    required this.label,
    this.kind = ButtonKind.ghost,
    this.icon,
    this.iconColor,
    this.kbd,
    this.onTap,
    this.enabled = true,
    this.height = t.Controls.standard,
    this.labelColor,
    this.trailing,
  });

  final String label;
  final ButtonKind kind;
  final String? icon;
  final Color? iconColor;
  final String? kbd;
  final VoidCallback? onTap;
  final bool enabled;
  final double height;
  final Color? labelColor;
  final Widget? trailing;

  @override
  State<AcpButton> createState() => _AcpButtonState();
}

class _AcpButtonState extends State<AcpButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final primary = widget.kind == ButtonKind.primary;
    final disabled = !widget.enabled;
    Color? bg;
    Color fg;
    switch (widget.kind) {
      case ButtonKind.primary:
        bg = disabled ? t.Neutral.surface : (_down ? t.Accent.active : (_hover ? t.Accent.active : t.Accent.base));
        fg = disabled ? t.Neutral.placeholder : t.Accent.onAccent;
      case ButtonKind.ghost:
        bg = _down ? t.Overlays.active : (_hover ? t.Overlays.hover : null);
        fg = widget.labelColor ?? t.Neutral.text;
      case ButtonKind.outline:
        bg = _down ? t.Overlays.active : (_hover ? t.Neutral.hoverSolid : t.Surface.popover);
        fg = widget.labelColor ?? t.Neutral.text;
    }
    final iconColor = widget.iconColor ?? fg;
    final child = Container(
      height: widget.height,
      padding: widget.height == t.Controls.compact ? t.Controls.padCompact : t.Controls.padStandard,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: t.Radii.control,
        border: widget.kind == ButtonKind.outline ? Border.all(color: t.Borders.subtle, width: t.Borders.width) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (widget.icon != null) ...<Widget>[
            AcpIcon(widget.icon!, color: iconColor, size: t.IconSizes.toolbar),
            const SizedBox(width: t.Spacing.s4),
          ],
          Text(widget.label, style: CardText.button.copyWith(color: fg)),
          if (widget.kbd != null) ...<Widget>[
            const SizedBox(width: t.Spacing.s8),
            Kbd(widget.kbd!, onAccent: primary && !disabled),
          ],
          if (widget.trailing != null) ...<Widget>[const SizedBox(width: t.Spacing.s4), widget.trailing!],
        ],
      ),
    );
    return MouseRegion(
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: disabled ? null : (_) => setState(() => _down = true),
        onTapUp: disabled ? null : (_) => setState(() => _down = false),
        onTapCancel: disabled ? null : () => setState(() => _down = false),
        onTap: disabled ? null : widget.onTap,
        child: child,
      ),
    );
  }
}

/// 图标按钮（24 / 28 方块，hover 6% 叠色）。
class IconButtonGhost extends StatefulWidget {
  const IconButtonGhost({super.key, required this.icon, this.color = t.Neutral.muted, this.onTap, this.size = t.Controls.standard, this.child});

  final String icon;
  final Color color;
  final VoidCallback? onTap;
  final double size;

  /// 替代图标的自定义内容（例如停止方块）。
  final Widget? child;

  @override
  State<IconButtonGhost> createState() => _IconButtonGhostState();
}

class _IconButtonGhostState extends State<IconButtonGhost> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(color: _hover ? t.Overlays.hover : null, borderRadius: t.Radii.control),
          alignment: Alignment.center,
          child: widget.child ?? AcpIcon(widget.icon, color: widget.color, size: t.IconSizes.toolbar),
        ),
      ),
    );
  }
}

/// 弹层容器：popover 底、subtle 边框、radius 4、shadow.popover。
class Popover extends StatelessWidget {
  const Popover({super.key, required this.child, this.padding, this.radius = t.Radii.control});

  final Widget child;
  final EdgeInsets? padding;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: t.Surface.popover,
        border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
        borderRadius: radius,
        boxShadow: const <BoxShadow>[t.Shadows.popover],
      ),
      padding: padding,
      child: child,
    );
  }
}

/// 可点文本（链接样式，recognizer 挂在叶子 span 上）。
InlineSpan linkSpan(String text, {VoidCallback? onTap, TextStyle? style}) {
  return TextSpan(text: text, style: style ?? CardText.link, recognizer: onTap == null ? null : (TapGestureRecognizer()..onTap = onTap));
}

/// 文本按钮（无底色，13 文字，可带前导图标）。
class TextAction extends StatelessWidget {
  const TextAction(this.label, {super.key, this.onTap, this.color, this.icon, this.iconColor});

  final String label;
  final VoidCallback? onTap;
  final Color? color;
  final String? icon;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) => AcpButton(label: label, onTap: onTap, labelColor: color, icon: icon, iconColor: iconColor);
}
