// 转录卡片的共用壳（画板 17–34 共用的形状）：卡片容器、32px 头行、底部收起条、分节标签、等宽块、徽章、按钮、kbd。
// 样式全部取 tokens；画板上非 4px 网格的内边距（10px）一律就近取 s8 / s12（R0 起的既定做法，像素差不作 finding）。

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/re_highlight.dart';

import '../../theme/tokens.dart' as t;
import 'icons.dart';
import '../shell/shell_common.dart';

/// 从 tokens 派生的组合样式（不含字面量）。
/// 卡片里的派生字阶。
///
/// 各档是 **getter 而不是 `static final`**：`static final` 只在首次访问时求值一次，之后 family 就冻住了——
/// 而首帧几乎必然碰到这个类，早于启动时的字体扫描与 [t.Fonts.apply]，于是换字体对转录 / 终端 / 弹层 /
/// diff 全都不起作用（R7.6 审查抓到的 high）。getter 每次从当前 [t.TextStyles] 派生，下游照常写
/// `CardText.code`，不用改。底层实例由 [t.Fonts] 缓存，所以这里只多一次 `copyWith`。
abstract final class CardText {
  /// 代码 / 等宽块正文：mono 12.5 · lh 1.5。
  static TextStyle get code => t.TextStyles.mono.copyWith(height: t.LineHeights.body);

  /// 行内代码：mono 12.5 · surface 底。
  static TextStyle get inlineCode => t.TextStyles.mono.copyWith(backgroundColor: t.Neutral.surface);

  /// 头行副标题：mono 12.5 · muted。
  static TextStyle get subtitle => t.TextStyles.mono.copyWith(color: t.Neutral.muted);

  /// 链接：accent 文字。
  static TextStyle get link => t.TextStyles.body.copyWith(color: t.Accent.text);

  /// 加粗正文（13 / 500 / strong）。
  static TextStyle get strong => t.TextStyles.body.copyWith(
    fontWeight: t.Weights.medium,
    fontVariations: t.Weights.mediumVariation,
    color: t.Neutral.strong,
  );

  /// 卡片标题（13 / 500，text 色）。
  static TextStyle get cardTitle => t.TextStyles.body.copyWith(
    fontWeight: t.Weights.medium,
    fontVariations: t.Weights.mediumVariation,
    height: t.LineHeights.control,
  );

  /// 头行标题（13 / 400，text 色，控件行高）。
  static TextStyle get headerTitle => t.TextStyles.body.copyWith(height: t.LineHeights.control);

  /// 12 / 400 muted，控件行高。
  static TextStyle get secondary => t.TextStyles.secondary.copyWith(height: t.LineHeights.control);

  /// 按钮文字（13 / 400 / 控件行高）。
  static TextStyle get button => t.TextStyles.body.copyWith(height: t.LineHeights.control);

  /// 主按钮文字：accent 底上的白字。
  static TextStyle get buttonPrimary => button.copyWith(color: t.Accent.onAccent);

  /// 错误文本（mono）。
  static TextStyle get codeError => code.copyWith(color: t.Semantic.error);
}

/// 卡片容器：1px subtle 边框、radius 6、canvas 底、裁剪圆角。
class TranscriptCard extends StatelessWidget {
  const TranscriptCard({super.key, required this.child, this.background, this.clip = Clip.antiAlias});

  final Widget child;

  /// 不给就是 [t.Surface.canvas]。**可空而不是默认值**：颜色 token 换成了 getter（主题切换），进不了 `const` 默认值。
  final Color? background;
  final Clip clip;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: clip,
      decoration: BoxDecoration(
        color: background ?? t.Surface.canvas,
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
    final Widget? sub = subtitleWidget ??
        (subtitle != null && subtitle!.isNotEmpty
            ? Text(subtitle!, style: CardText.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis)
            : null);
    final row = SizedBox(
      height: height,
      child: Padding(
        padding: t.Controls.padInput,
        child: Row(
          children: <Widget>[
            if (leading != null) ...<Widget>[leading!, const SizedBox(width: t.Spacing.s8)],
            // 标题与副标题吃掉余量、trailing 贴右（画板 18）。`Flexible` 与 `Spacer` 并列不行：
            // 两者 flex 都是 1，余量被五五分，副标题短的卡 trailing 就停在中间、各行还对不齐。
            Expanded(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints box) {
                  // 标题只能用「按头行宽度算出来的上限」约束，不能改成 `Flexible`：
                  // 那样它与副标题 flex 各半，副标题短的卡标题会被提前截断。而不约束的话 Row 给非 flex 子节点的是
                  // 无上限约束，终端卡那种「标题 = 整条命令」就原样铺出去，盖住状态图标与卡片右边框
                  //（所有者手测 2026-09-17「命令内容覆盖容器样式」）。副标题在场时留出它俩之间的 8。
                  final double titleMax = sub == null ? box.maxWidth : (box.maxWidth - t.Spacing.s8).clamp(0.0, double.infinity);
                  return Row(
                    children: <Widget>[
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: titleMax),
                        child: Text(title, style: titleStyle ?? CardText.headerTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                      if (sub != null) ...<Widget>[
                        const SizedBox(width: t.Spacing.s8),
                        Flexible(child: sub),
                      ],
                    ],
                  );
                },
              ),
            ),
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
///
/// **构造函数不带 `const`**（所有者裁定 2026-09-22，iteration-02）：build 里现取颜色 token 的 widget
/// 一旦在调用点写成 `const`，实例被规范化成同一个对象，换主题时父级重建走 `Element.updateChild`
/// 见到 `child.widget == newWidget` 就直接复用旧 element、不再 build，颜色于是冻在首次构建那一套上
/// （0c95a84 修掉的 `AppLogo` 是同一类）。摘的是构造函数而不是在几十个调用点逐处加 `// ignore:`——
/// 构造函数不是 const，`prefer_const_constructors` 与 `dart fix` 就回改不了调用点。
/// 声明这一行的 `ignore` 是必须的：`prefer_const_constructors_in_immutables` 会让 `dart fix`
/// 把 `const` 加回构造函数，等于把这次修复整个撤销。
/// 同此的还有本文件的 [SectionLabel] / [MonoBlock] / [ToneChip]，以及 `icons.dart` 的 Spinner、
/// `awaiting_bar.dart` 的 AwaitingRow、`files_panel.dart` 的 FileViewerEmpty / _TreeNote、
/// `registry_entry.dart` 的 _Diamond、`auth_page.dart` 的 AuthSucceededCard。
/// 弹层里那些（MenuDivider / MenuGroupLabel / _TimelineEmpty）每次打开都新建，不在此列。
class Chevron extends StatelessWidget {
  // ignore: prefer_const_constructors_in_immutables
  Chevron({super.key, required this.expanded, this.color});

  final bool expanded;

  /// 不给就是 [t.Neutral.placeholder]。**可空而不是默认值**：颜色 token 换成了 getter（主题切换），进不了 `const` 默认值。
  final Color? color;

  @override
  Widget build(BuildContext context) =>
      AcpIcon(expanded ? AcpIcons.chevronUp : AcpIcons.chevronDown, color: color ?? t.Neutral.placeholder, size: t.IconSizes.toolbar);
}

/// 卡片展开体：上边框 + 8/12 内边距 + 子项间距 8。
class CardBody extends StatelessWidget {
  const CardBody({super.key, required this.children, this.padding});

  final List<Widget> children;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
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
        decoration: BoxDecoration(border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
        alignment: Alignment.center,
        child: Chevron(expanded: true),
      ),
    );
  }
}

/// 分节标签（「Raw Input:」「Output:」「stderr 尾巴」）：11 / 500 / muted。
/// 构造函数不带 `const`：build 里现取颜色 token，换主题要重建（理由见 card_chrome.dart 的 Chevron）。
class SectionLabel extends StatelessWidget {
  // ignore: prefer_const_constructors_in_immutables
  SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: t.Spacing.s4),
        child: Text(text, style: t.TextStyles.label),
      );
}

/// 等宽文本块：panel 底、radius 4、8/12 内边距、pre-wrap。`background` 可换 error.soft 等。
/// 构造函数不带 `const`：build 里现取颜色 token，换主题要重建（理由见 card_chrome.dart 的 Chevron）。
class MonoBlock extends StatelessWidget {
  // ignore: prefer_const_constructors_in_immutables
  MonoBlock({super.key, this.text, this.span, this.background, this.style, this.softWrap = true});

  final String? text;
  final InlineSpan? span;

  /// 不给就是 [t.Neutral.panel]。**可空而不是默认值**：颜色 token 换成了 getter（主题切换），进不了 `const` 默认值。
  final Color? background;
  final TextStyle? style;
  final bool softWrap;

  @override
  Widget build(BuildContext context) {
    final s = style ?? CardText.code;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(color: background ?? t.Neutral.panel, borderRadius: t.Radii.control),
      padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
      child: span != null ? Text.rich(span!, style: s, softWrap: softWrap) : Text(text ?? '', style: s, softWrap: softWrap),
    );
  }
}

/// JSON 语法着色（Raw Input / 权限请求的 toolCall）：键 accent、字符串 success、数字 warning（画板 18 / 25 的注释）。
abstract final class JsonHighlight {
  static final Highlight _hl = Highlight()..registerLanguage('json', langJson);

  /// getter 而不是 `static final`：理由同 [CardText]，存成 final 会冻在首次访问时的那一套主题。
  static Map<String, TextStyle> get theme => <String, TextStyle>{
    'attr': TextStyle(color: t.Accent.text),
    'string': TextStyle(color: t.Semantic.success),
    'number': TextStyle(color: t.Semantic.warning),
    'literal': TextStyle(color: t.Accent.text),
    'punctuation': TextStyle(color: t.Neutral.muted),
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

/// 构造函数不带 `const`：build 里现取颜色 token，换主题要重建（理由见 card_chrome.dart 的 Chevron）。
class ToneChip extends StatelessWidget {
  // ignore: prefer_const_constructors_in_immutables
  ToneChip(this.text, {super.key, required this.tone, this.style});

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
  /// 按下态是按钮自己的；悬浮态走 [Hoverable]。
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final disabled = !widget.enabled;
    return Hoverable(
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      builder: (context, hovered) => GestureDetector(
        onTapDown: disabled ? null : (_) => setState(() => _down = true),
        onTapUp: disabled ? null : (_) => setState(() => _down = false),
        onTapCancel: disabled ? null : () => setState(() => _down = false),
        onTap: disabled ? null : widget.onTap,
        child: _body(hovered),
      ),
    );
  }

  Widget _body(bool hovered) {
    final primary = widget.kind == ButtonKind.primary;
    final disabled = !widget.enabled;
    Color? bg;
    Color fg;
    switch (widget.kind) {
      case ButtonKind.primary:
        bg = disabled ? t.Neutral.surface : (_down ? t.Accent.active : (hovered ? t.Accent.active : t.Accent.base));
        fg = disabled ? t.Neutral.placeholder : t.Accent.onAccent;
      case ButtonKind.ghost:
        bg = _down ? t.Overlays.active : (hovered ? t.Overlays.hover : null);
        fg = widget.labelColor ?? t.Neutral.text;
      case ButtonKind.outline:
        bg = _down ? t.Overlays.active : (hovered ? t.Neutral.hoverSolid : t.Surface.popover);
        fg = widget.labelColor ?? t.Neutral.text;
    }
    final iconColor = widget.iconColor ?? fg;
    return Container(
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
  }
}

/// 图标按钮（20 / 24 / 28 方块，hover 6% 叠色）。悬浮态走 [Hoverable]，不再自己搓一遍 MouseRegion。
/// [selected] 是面板头行那种带选中态的档（画板 60 的搜索开关）：selected 叠色 + accent 图标。
class IconButtonGhost extends StatelessWidget {
  const IconButtonGhost({
    super.key,
    required this.icon,
    this.color,
    this.onTap,
    this.size = t.Controls.standard,
    this.selected = false,
    this.child,
  });

  final String icon;

  /// 不给就是 [t.Neutral.muted]。**可空而不是默认值**：颜色 token 换成了 getter（主题切换），进不了 `const` 默认值。
  final Color? color;
  final VoidCallback? onTap;
  final double size;
  final bool selected;

  /// 替代图标的自定义内容（例如停止方块）。
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Hoverable(
      onTap: onTap,
      builder: (context, hovered) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: selected ? t.Overlays.selected : (hovered ? t.Overlays.hover : null),
          borderRadius: t.Radii.control,
        ),
        alignment: Alignment.center,
        child: child ?? AcpIcon(icon, color: selected ? t.Accent.text : (color ?? t.Neutral.muted), size: t.IconSizes.toolbar),
      ),
    );
  }
}

/// 弹层容器：popover 底、subtle 边框、radius 4、shadow.popover + 顶边 1px 提亮。
///
/// 提亮那一条对应画板 07 § 2.5 路线 B 的 `inset 0 1px 0`：深底上加重黑影只会把周围变得更黑、边界依旧糊，
/// 顶部一条亮线才直接给出「上边缘」。Flutter 的 [BoxShadow] 没有 inset，所以改画一条 1px 顶线；
/// 颜色取 [t.Shadows.topHighlight]，浅色下它是全透明，两套主题走同一条代码路径。
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
        boxShadow: <BoxShadow>[t.Shadows.popover],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: <Widget>[
            Padding(padding: padding ?? EdgeInsets.zero, child: child),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SizedBox(height: t.Borders.width, child: ColoredBox(color: t.Shadows.topHighlight)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 可点文本（链接样式，recognizer 挂在叶子 span 上）。
InlineSpan linkSpan(String text, {VoidCallback? onTap, TextStyle? style}) {
  return TextSpan(text: text, style: style ?? CardText.link, recognizer: onTap == null ? null : (TapGestureRecognizer()..onTap = onTap));
}
