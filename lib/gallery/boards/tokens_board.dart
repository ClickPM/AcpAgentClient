// 画板 00 · Token 表 的样板页：把 lib/theme/tokens.dart 的每个 token 按画板布局摆一遍，
// 供 build/gallery/00-tokens.png 与 design/round-design/00-tokens.png 并排对照。
// 样式只取 tokens；画板自身的示例几何（色块高度、示意条宽度）是样板页局部常量，不是 token。

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import '../../ui/transcript/icons.dart';

// 样板页的示例几何（对应画板里色块 / 示意条的尺寸，不进 tokens）。
const double _swatchLight = 52;
const double _swatchDark = 44;
const double _swatchAccent = 40;
const double _softBar = 14;
const double _surfaceDemo = 96;
const double _surfacePanelDemo = 36;
const double _radiusDemoWidth = 44;
const double _toggleTrackWidth = 28;
const double _toggleKnobInset = 2;
const double _spacingBarHeight = 16;
const double _kbdSampleHeight = 16;

class TokensBoard extends StatelessWidget {
  const TokensBoard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: t.Neutral.canvas,
      padding: const EdgeInsets.fromLTRB(t.Spacing.s24, t.Spacing.s24, t.Spacing.s24, t.Spacing.s16),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Header(),
          SizedBox(height: t.Spacing.s16),
          _Section(title: '中性色阶 · 浅色（同一色相偏移，饱和度 ≤ 0.02）', child: _LightNeutrals()),
          SizedBox(height: t.Spacing.s16),
          _Section(title: '中性色阶 · 深色（本轮只备，不出深色页面画板）', child: _DarkNeutrals()),
          SizedBox(height: t.Spacing.s16),
          _ColorRow(),
          SizedBox(height: t.Spacing.s16),
          _BottomRow(),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(bottom: t.Spacing.s8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Text('00 · Token 表', style: t.TextStyles.title),
          const SizedBox(width: t.Spacing.s12),
          Flexible(child: Text('AcpAgent Client · 本表是唯一样式来源，将直接翻成 tokens.dart；任何画板不得出现表外数值', style: t.TextStyles.meta)),
          const SizedBox(width: t.Spacing.s12),
          Flexible(child: Text('色相 5（accent + 4 语义）· 圆角 3 / 4 / 6（+ pill 例外）· 字阶 11 / 12 / 13 / 15 / 20', style: t.TextStyles.monoMeta, textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: t.TextStyles.label),
        const SizedBox(height: t.Spacing.s8),
        child,
      ],
    );
  }
}

/// 色块 + 名字 + 值。
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.name,
    required this.value,
    required this.height,
    this.border,
    this.child,
  });

  final Color color;
  final String name;
  final String value;
  final double height;
  final Color? border;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          height: height,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            borderRadius: t.Radii.control,
            border: border == null ? null : Border.all(color: border!, width: t.Borders.width),
          ),
          child: child,
        ),
        const SizedBox(height: t.Spacing.s4),
        Text(name, style: t.TextStyles.monoMeta.copyWith(color: t.Neutral.text)),
        Text(value, style: t.TextStyles.monoMeta),
      ],
    );
  }
}

/// 等宽网格：children 平分一行，间隙 4。
class _Grid extends StatelessWidget {
  const _Grid({required this.children, this.gap = t.Spacing.s4});

  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (var i = 0; i < children.length; i++) ...<Widget>[
          if (i > 0) SizedBox(width: gap),
          Expanded(child: children[i]),
        ],
      ],
    );
  }
}

class _LightNeutrals extends StatelessWidget {
  const _LightNeutrals();

  @override
  Widget build(BuildContext context) {
    const h = _swatchLight;
    return const _Grid(children: <Widget>[
      _Swatch(color: t.Neutral.canvas, name: 'n.canvas', value: '#fbfbfc', height: h, border: t.Borders.subtle),
      _Swatch(color: t.Neutral.panel, name: 'n.panel', value: '#f4f4f6', height: h, border: t.Borders.subtle),
      _Swatch(color: t.Neutral.surface, name: 'n.surface', value: '#eeeef1', height: h, border: t.Borders.subtle),
      _Swatch(color: t.Neutral.hoverSolid, name: 'n.hover.solid', value: '#e7e7eb', height: h, border: t.Borders.subtle),
      _Swatch(color: t.Neutral.borderSubtle, name: 'n.border.subtle', value: '#e2e2e7', height: h, border: t.Borders.base),
      _Swatch(color: t.Neutral.border, name: 'n.border', value: '#d3d3da', height: h),
      _Swatch(color: t.Neutral.placeholder, name: 'n.placeholder', value: '#8b8b96', height: h),
      _Swatch(color: t.Neutral.muted, name: 'n.muted', value: '#62626e', height: h),
      _Swatch(color: t.Neutral.text, name: 'n.text', value: '#33333d', height: h),
      _Swatch(color: t.Neutral.strong, name: 'n.strong', value: '#1e1e26', height: h),
    ]);
  }
}

class _DarkNeutrals extends StatelessWidget {
  const _DarkNeutrals();

  @override
  Widget build(BuildContext context) {
    const h = _swatchDark;
    return const _Grid(children: <Widget>[
      _Swatch(color: t.Dark.canvas, name: 'd.canvas', value: '#17171c', height: h),
      _Swatch(color: t.Dark.panel, name: 'd.panel', value: '#1d1d23', height: h),
      _Swatch(color: t.Dark.surface, name: 'd.surface', value: '#24242b', height: h),
      _Swatch(color: t.Dark.hoverSolid, name: 'd.hover.solid', value: '#2c2c34', height: h),
      _Swatch(color: t.Dark.borderSubtle, name: 'd.border.subtle', value: '#303039', height: h),
      _Swatch(color: t.Dark.border, name: 'd.border', value: '#43434e', height: h),
      _Swatch(color: t.Dark.placeholder, name: 'd.placeholder', value: '#7e7e8a', height: h),
      _Swatch(color: t.Dark.muted, name: 'd.muted', value: '#9b9ba6', height: h),
      _Swatch(color: t.Dark.text, name: 'd.text', value: '#d5d5dc', height: h),
      _Swatch(color: t.Dark.accent, name: 'd.accent', value: '#8b96ec', height: h),
    ]);
  }
}

/// 强调色 / 语义色 / 表面三列。
class _ColorRow extends StatelessWidget {
  const _ColorRow();

  @override
  Widget build(BuildContext context) {
    return const _Grid(gap: t.Spacing.s24, children: <Widget>[
      _Section(title: '强调色（唯一）· 主按钮 / 焦点环 / 链接 / 选中 / spinner；hover 统一用 .active', child: _AccentSwatches()),
      _Section(title: '语义色（4）· 只用于状态图标 / 状态文字 / 细状态条', child: _SemanticSwatches()),
      _Section(title: '三级表面 · 边框两级 · 阴影（仅弹层）', child: _SurfaceDemo()),
    ]);
  }
}

class _AccentSwatches extends StatelessWidget {
  const _AccentSwatches();

  @override
  Widget build(BuildContext context) {
    const h = _swatchAccent;
    return _Grid(children: <Widget>[
      const _Swatch(color: t.Accent.base, name: 'accent', value: '#5566d8', height: h),
      const _Swatch(color: t.Accent.active, name: '.active', value: '#3d4cb5', height: h),
      const _Swatch(color: t.Accent.soft, name: '.soft', value: '#ecedfa', height: h, border: t.Borders.subtle),
      _Swatch(
        color: t.Neutral.canvas,
        name: '.text',
        value: '#4a59c9',
        height: h,
        border: t.Borders.subtle,
        child: Text('Aa', style: t.TextStyles.body.copyWith(color: t.Accent.text, height: t.LineHeights.control)),
      ),
      const _Swatch(
        color: t.Accent.base,
        name: 'border.on-accent',
        value: 'rgba(255,255,255,.45)',
        height: h,
        child: _Kbd(label: 'Alt-A', onAccent: true),
      ),
    ]);
  }
}

class _SemanticSwatches extends StatelessWidget {
  const _SemanticSwatches();

  @override
  Widget build(BuildContext context) {
    return const _Grid(children: <Widget>[
      _SemanticSwatch(color: t.Semantic.error, soft: t.Semantic.errorSoft, name: 'error', value: '#bc4e39', softValue: '.soft #fbeeea'),
      _SemanticSwatch(color: t.Semantic.warning, soft: t.Semantic.warningSoft, name: 'warning', value: '#8a6f12', softValue: '.soft #f7f2e2'),
      _SemanticSwatch(color: t.Semantic.success, soft: t.Semantic.successSoft, name: 'success', value: '#477f40', softValue: '.soft #ecf3ea'),
      _SemanticSwatch(color: t.Semantic.info, soft: t.Semantic.infoSoft, name: 'info', value: '#5566d8', softValue: '.soft #ecedfa'),
    ]);
  }
}

class _SemanticSwatch extends StatelessWidget {
  const _SemanticSwatch({required this.color, required this.soft, required this.name, required this.value, required this.softValue});

  final Color color;
  final Color soft;
  final String name;
  final String value;
  final String softValue;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _Swatch(color: color, name: name, value: value, height: _swatchAccent),
        const SizedBox(height: t.Spacing.s4),
        Container(
          height: _softBar,
          decoration: BoxDecoration(
            color: soft,
            borderRadius: t.Radii.chip,
            border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
          ),
        ),
        Text(softValue, style: t.TextStyles.monoMeta),
      ],
    );
  }
}

class _SurfaceDemo extends StatelessWidget {
  const _SurfaceDemo();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Container(
            constraints: const BoxConstraints(minHeight: _surfaceDemo),
            padding: const EdgeInsets.all(t.Spacing.s8),
            decoration: BoxDecoration(
              color: t.Surface.canvas,
              borderRadius: t.Radii.card,
              border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('surface.canvas', style: t.TextStyles.monoMeta),
                const SizedBox(height: t.Spacing.s4),
                Container(
                  height: _surfacePanelDemo,
                  padding: const EdgeInsets.all(t.Spacing.s4),
                  decoration: BoxDecoration(
                    color: t.Surface.panel,
                    borderRadius: t.Radii.card,
                    border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
                  ),
                  child: Text('surface.panel', style: t.TextStyles.monoMeta),
                ),
                const SizedBox(height: t.Spacing.s4),
                Container(
                  height: t.Controls.compact,
                  padding: t.Controls.padCompact,
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: t.Surface.popover,
                    borderRadius: t.Radii.card,
                    border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
                    boxShadow: const <BoxShadow>[t.Shadows.popover],
                  ),
                  child: Text('surface.popover', style: t.TextStyles.monoMeta),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: t.Spacing.s8),
        Expanded(
          child: DefaultTextStyle(
            style: t.TextStyles.monoMeta.copyWith(color: t.Neutral.muted, height: t.LineHeights.body),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('canvas #fbfbfc'),
                Text('panel #f4f4f6'),
                Text('popover #ffffff'),
                Text('border.subtle 1px #e2e2e7'),
                Text('border 1px #d3d3da'),
                Text('shadow.popover 0 4 12 rgba(28,28,35,.10)'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 下半区：字阶 / 间距与圆角 / 控件与按钮 / 图标 kbd 动效。
class _BottomRow extends StatelessWidget {
  const _BottomRow();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(top: t.Spacing.s12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(flex: 115, child: _Section(title: '字阶（5 档）· 字重 400 / 500', child: _TypeScale())),
          SizedBox(width: t.Spacing.s24),
          Expanded(flex: 100, child: _Section(title: '间距（4px 网格）· 圆角（3 档 + pill 例外）', child: _SpacingAndRadius())),
          SizedBox(width: t.Spacing.s24),
          Expanded(flex: 100, child: _Section(title: '控件高度 · 按钮四态', child: _ControlsAndButtons())),
          SizedBox(width: t.Spacing.s24),
          Expanded(flex: 100, child: _Section(title: '图标 · kbd · 动效', child: _IconsKbdMotion())),
        ],
      ),
    );
  }
}

class _TypeLine extends StatelessWidget {
  const _TypeLine({required this.sample, required this.note});

  final Widget sample;
  final String note;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Flexible(child: sample),
        const SizedBox(width: t.Spacing.s8),
        Flexible(child: Text(note, style: t.TextStyles.monoMeta)),
      ],
    );
  }
}

class _TypeScale extends StatelessWidget {
  const _TypeScale();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _TypeLine(sample: Text('New Thread', style: t.TextStyles.display), note: 'text.display 20 / 500 · 空态'),
        const SizedBox(height: t.Spacing.s8),
        _TypeLine(sample: Text('ACP Registry', style: t.TextStyles.title), note: 'text.title 15 / 500'),
        const SizedBox(height: t.Spacing.s8),
        _TypeLine(sample: Text('正文与控件基准 Body', style: t.TextStyles.body), note: 'text.body 13 / 400 · lh 1.5（控件 1.35）'),
        const SizedBox(height: t.Spacing.s8),
        _TypeLine(sample: Text('次要说明 Secondary', style: t.TextStyles.secondary), note: 'text.secondary 12 / 400'),
        const SizedBox(height: t.Spacing.s8),
        _TypeLine(sample: Text('15 分钟前 · 2 条消息', style: t.TextStyles.meta), note: 'text.meta 11 / 400'),
        const SizedBox(height: t.Spacing.s8),
        _TypeLine(sample: Text('10,240 tokens · \$0.021 · 4.2s', style: t.TextStyles.mono), note: 'mono 12.5 · tabular-nums'),
      ],
    );
  }
}

class _SpacingBar extends StatelessWidget {
  const _SpacingBar(this.width);

  final double width;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: width,
          height: _spacingBarHeight,
          decoration: const BoxDecoration(color: t.Accent.base, borderRadius: t.Radii.chip),
        ),
        const SizedBox(height: t.Spacing.s4),
        Text('${width.toInt()}', style: t.TextStyles.monoMeta.copyWith(color: t.Neutral.muted)),
      ],
    );
  }
}

class _RadiusDemo extends StatelessWidget {
  const _RadiusDemo({required this.radius, required this.label});

  final BorderRadius radius;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: _radiusDemoWidth,
          height: t.Controls.input,
          decoration: BoxDecoration(
            color: t.Neutral.surface,
            borderRadius: radius,
            border: Border.all(color: t.Borders.base, width: t.Borders.width),
          ),
        ),
        const SizedBox(height: t.Spacing.s4),
        Text(label, style: t.TextStyles.monoMeta.copyWith(color: t.Neutral.muted)),
      ],
    );
  }
}

class _PillToggle extends StatelessWidget {
  const _PillToggle();

  @override
  Widget build(BuildContext context) {
    const trackHeight = _spacingBarHeight;
    return Container(
      width: _toggleTrackWidth,
      height: trackHeight,
      padding: const EdgeInsets.all(_toggleKnobInset),
      alignment: Alignment.centerRight,
      decoration: BoxDecoration(color: t.Accent.base, borderRadius: t.Radii.pill(trackHeight)),
      child: const DecoratedBox(
        decoration: BoxDecoration(color: t.Accent.onAccent, shape: BoxShape.circle),
        child: SizedBox.expand(),
      ),
    );
  }
}

class _SpacingAndRadius extends StatelessWidget {
  const _SpacingAndRadius();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            _SpacingBar(t.Spacing.s4),
            SizedBox(width: t.Spacing.s8),
            _SpacingBar(t.Spacing.s8),
            SizedBox(width: t.Spacing.s8),
            _SpacingBar(t.Spacing.s12),
            SizedBox(width: t.Spacing.s8),
            _SpacingBar(t.Spacing.s16),
            SizedBox(width: t.Spacing.s8),
            _SpacingBar(t.Spacing.s24),
          ],
        ),
        const SizedBox(height: t.Spacing.s12),
        Text('space.chip 1px 5px（徽章内边距，唯一非 4px 网格例外；kbd 用 0 4px + line-height 16）', style: t.TextStyles.monoMeta),
        const SizedBox(height: t.Spacing.s8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Expanded(child: _RadiusDemo(radius: t.Radii.chip, label: 'radius.3 芯片 / kbd')),
            const SizedBox(width: t.Spacing.s8),
            const Expanded(child: _RadiusDemo(radius: t.Radii.control, label: 'radius.4 按钮 / 输入')),
            const SizedBox(width: t.Spacing.s8),
            const Expanded(child: _RadiusDemo(radius: t.Radii.card, label: 'radius.6 卡片 / 弹层')),
            const SizedBox(width: t.Spacing.s8),
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const SizedBox(height: t.Controls.input, child: Align(alignment: Alignment.centerLeft, child: _PillToggle())),
                  const SizedBox(height: t.Spacing.s4),
                  Text('radius.pill 例外：布尔开关轨道 / 全圆徽章（= 轨道高度一半）', style: t.TextStyles.monoMeta.copyWith(color: t.Neutral.muted)),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 一个按钮态的静态样例。
class _ButtonSample extends StatelessWidget {
  const _ButtonSample({
    required this.label,
    this.background,
    this.foreground = t.Neutral.text,
    this.padding = t.Controls.padStandard,
    this.focusRing = false,
  });

  final String label;
  final Color? background;
  final Color foreground;
  final EdgeInsets padding;
  final bool focusRing;

  @override
  Widget build(BuildContext context) {
    // Wrap 给的是有界约束：Container.alignment 或不带 widthFactor 的 Center 都会把按钮撑满整行。
    final button = Container(
      height: t.Controls.standard,
      padding: padding,
      decoration: BoxDecoration(color: background, borderRadius: t.Radii.control),
      child: Center(widthFactor: 1, child: Text(label, style: t.TextStyles.body.copyWith(color: foreground, height: t.LineHeights.control))),
    );
    if (!focusRing) return button;
    return Container(
      padding: const EdgeInsets.all(t.FocusRing.offset),
      decoration: BoxDecoration(
        borderRadius: t.Radii.card,
        border: Border.all(color: t.FocusRing.color, width: t.FocusRing.width),
      ),
      child: button,
    );
  }
}

class _ControlsAndButtons extends StatelessWidget {
  const _ControlsAndButtons();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            _ControlSample(height: t.Controls.compact, padding: t.Controls.padCompact, radius: t.Radii.chip, style: t.TextStyles.meta, label: '24 紧凑'),
            const SizedBox(width: t.Spacing.s8),
            _ControlSample(height: t.Controls.standard, padding: t.Controls.padStandard, radius: t.Radii.control, style: t.TextStyles.secondary, label: '28 标准'),
            const SizedBox(width: t.Spacing.s8),
            _ControlSample(height: t.Controls.input, padding: t.Controls.padInput, radius: t.Radii.control, style: t.TextStyles.body, label: '32 主输入'),
          ],
        ),
        const SizedBox(height: t.Spacing.s8),
        const Wrap(
          spacing: t.Spacing.s4,
          runSpacing: t.Spacing.s4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            _ButtonSample(label: '默认 ghost'),
            _ButtonSample(label: 'hover 6%', background: t.Overlays.hover),
            _ButtonSample(label: 'active 10%', background: t.Overlays.active),
            _ButtonSample(label: 'selected', background: t.Overlays.selected, foreground: t.Accent.text),
            _ButtonSample(label: 'primary', background: t.Accent.base, foreground: t.Accent.onAccent, padding: t.Controls.padInput),
            _ButtonSample(label: 'danger ghost', foreground: t.Semantic.error),
            _ButtonSample(label: 'focus ring 1.5 / +1', focusRing: true),
          ],
        ),
      ],
    );
  }
}

class _ControlSample extends StatelessWidget {
  const _ControlSample({required this.height, required this.padding, required this.radius, required this.style, required this.label});

  final double height;
  final EdgeInsets padding;
  final BorderRadius radius;
  final TextStyle style;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: padding,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: t.Neutral.surface, borderRadius: radius),
      child: Text(label, style: style.copyWith(color: t.Neutral.muted, height: t.LineHeights.control)),
    );
  }
}

/// kbd 样例（画板：mono 11 · 边框 1 · radius 3 · 0 4px · line-height 16）。
class _Kbd extends StatelessWidget {
  const _Kbd({required this.label, this.onAccent = false});

  final String label;
  final bool onAccent;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _kbdSampleHeight,
      padding: t.Kbd.padding,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: t.Kbd.radius,
        border: Border.all(color: onAccent ? t.Accent.borderOnAccent : t.Kbd.border, width: t.Borders.width),
      ),
      child: Text(label, style: t.Kbd.text.copyWith(color: onAccent ? t.Accent.onAccent : t.Neutral.muted)),
    );
  }
}

class _IconsKbdMotion extends StatelessWidget {
  const _IconsKbdMotion();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const AcpIcon(AcpIcons.search, color: t.Neutral.text),
            const SizedBox(width: t.Spacing.s12),
            const AcpIcon(AcpIcons.file, color: t.Neutral.text),
            const SizedBox(width: t.Spacing.s12),
            const AcpIcon(AcpIcons.terminal, color: t.Neutral.text, size: t.IconSizes.toolbar),
            const SizedBox(width: t.Spacing.s12),
            Flexible(child: Text('icon 16 / 工具栏 14 · stroke 1.5', style: t.TextStyles.monoMeta)),
          ],
        ),
        const SizedBox(height: t.Spacing.s8),
        Row(
          children: <Widget>[
            const _Kbd(label: 'Alt-Shift-A'),
            const SizedBox(width: t.Spacing.s8),
            const _Kbd(label: 'Ctrl-Alt-A'),
            const SizedBox(width: t.Spacing.s8),
            Flexible(child: Text('kbd · mono 11 · radius 3', style: t.TextStyles.monoMeta)),
          ],
        ),
        const SizedBox(height: t.Spacing.s8),
        DefaultTextStyle(
          style: t.TextStyles.monoMeta.copyWith(color: t.Neutral.muted, height: t.LineHeights.body),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('motion.fast 120ms ease-out（hover / 颜色）'),
              Text('motion.base 160ms ease-out（展开 / 弹层）'),
              Text('spinner accent #5566d8 · 1.5px 弧'),
            ],
          ),
        ),
      ],
    );
  }
}
