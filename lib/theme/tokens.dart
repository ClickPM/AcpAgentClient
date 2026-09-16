// 样式唯一来源（CLAUDE.md 规则 3）。逐值提炼自 design/round-design/00-tokens.dc.html，
// 「token 名 → 00 画板位置 → 值」对照表在 rounds/round-00/round-00.md。
// 画板 widget 文件里不得出现颜色 / 字号 / 间距 / 圆角 / 时长字面量（scripts/validate.ps1 Assert-NoStyleLiteral）。
// 用法：import 'package:acp_agent_client/theme/tokens.dart' as t;  →  t.Accent.base、t.TextStyles.body。

import 'package:flutter/widgets.dart';

/// 中性色阶 · 浅色（画板 00「中性色阶 · 浅色」，n.*）。
abstract final class Neutral {
  static const Color canvas = Color(0xFFFBFBFC);
  static const Color panel = Color(0xFFF4F4F6);
  static const Color surface = Color(0xFFEEEEF1);
  static const Color hoverSolid = Color(0xFFE7E7EB);
  static const Color borderSubtle = Color(0xFFE2E2E7);
  static const Color border = Color(0xFFD3D3DA);
  static const Color placeholder = Color(0xFF8B8B96);
  static const Color muted = Color(0xFF62626E);
  static const Color text = Color(0xFF33333D);
  static const Color strong = Color(0xFF1E1E26);
}

/// 中性色阶 · 深色（画板 00「中性色阶 · 深色」，d.*）。只备常量，不接主题切换（BACKLOG）。
abstract final class Dark {
  static const Color canvas = Color(0xFF17171C);
  static const Color panel = Color(0xFF1D1D23);
  static const Color surface = Color(0xFF24242B);
  static const Color hoverSolid = Color(0xFF2C2C34);
  static const Color borderSubtle = Color(0xFF303039);
  static const Color border = Color(0xFF43434E);
  static const Color placeholder = Color(0xFF7E7E8A);
  static const Color muted = Color(0xFF9B9BA6);
  static const Color text = Color(0xFFD5D5DC);
  static const Color accent = Color(0xFF8B96EC);
}

/// 强调色（画板 00「强调色（唯一）」）：主按钮 / 焦点环 / 链接 / 选中 / spinner；hover 统一用 [active]。
abstract final class Accent {
  static const Color base = Color(0xFF5566D8);
  static const Color active = Color(0xFF3D4CB5);
  static const Color soft = Color(0xFFECEDFA);
  static const Color text = Color(0xFF4A59C9);

  /// 强调色底上的文字（primary 按钮）。
  static const Color onAccent = Color(0xFFFFFFFF);

  /// border.on-accent：强调色底上的 kbd 边框。
  static const Color borderOnAccent = Color.fromRGBO(255, 255, 255, 0.45);
}

/// 语义色 4 × 2（画板 00「语义色（4）」）：只用于状态图标 / 状态文字 / 细状态条。
abstract final class Semantic {
  static const Color error = Color(0xFFBC4E39);
  static const Color errorSoft = Color(0xFFFBEEEA);
  static const Color warning = Color(0xFF8A6F12);
  static const Color warningSoft = Color(0xFFF7F2E2);
  static const Color success = Color(0xFF477F40);
  static const Color successSoft = Color(0xFFECF3EA);
  static const Color info = Color(0xFF5566D8);
  static const Color infoSoft = Color(0xFFECEDFA);
}

/// 三级表面（画板 00「三级表面 · 边框两级 · 阴影」）。
abstract final class Surface {
  static const Color canvas = Color(0xFFFBFBFC);
  static const Color panel = Color(0xFFF4F4F6);
  static const Color popover = Color(0xFFFFFFFF);
}

/// 边框两级，宽 1。
abstract final class Borders {
  static const Color subtle = Color(0xFFE2E2E7);
  static const Color base = Color(0xFFD3D3DA);
  static const double width = 1.0;
}

/// 阴影：仅弹层。shadow.popover = 0 4 12 rgba(28,28,35,.10)。
abstract final class Shadows {
  static const BoxShadow popover = BoxShadow(
    offset: Offset(0, 4),
    blurRadius: 12,
    color: Color.fromRGBO(28, 28, 35, 0.10),
  );
}

/// 字体栈：Geist / Geist Mono（OFL），CJK 回退 Microsoft YaHei UI / PingFang SC。
abstract final class Fonts {
  static const String sans = 'Geist';
  static const String mono = 'Geist Mono';
  static const List<String> cjkFallback = <String>['Microsoft YaHei UI', 'PingFang SC'];
}

/// 字重 400 / 500。Geist 是可变字体，`fontWeight` 之外还要带 `fontVariations`。
abstract final class Weights {
  static const FontWeight regular = FontWeight.w400;
  static const FontWeight medium = FontWeight.w500;
  static const List<FontVariation> regularVariation = <FontVariation>[FontVariation('wght', 400)];
  static const List<FontVariation> mediumVariation = <FontVariation>[FontVariation('wght', 500)];
}

/// 行高：正文 1.5，控件 1.35 是 `TextStyle.height` 倍率；kbd 是 16px 的绝对行框高（带 Px 后缀，不能当 `height` 倍率用）。
abstract final class LineHeights {
  static const double body = 1.5;
  static const double control = 1.35;
  static const double kbdPx = 16.0;
}

/// 字阶五档 + mono 12.5（画板 00「字阶（5 档）」）。颜色按画板样例带上，需要时 copyWith。
abstract final class TextStyles {
  /// text.display 20 / 500 · 空态。
  static const TextStyle display = TextStyle(
    fontFamily: Fonts.sans,
    fontFamilyFallback: Fonts.cjkFallback,
    fontSize: 20,
    fontWeight: Weights.medium,
    fontVariations: Weights.mediumVariation,
    color: Neutral.strong,
  );

  /// text.title 15 / 500。
  static const TextStyle title = TextStyle(
    fontFamily: Fonts.sans,
    fontFamilyFallback: Fonts.cjkFallback,
    fontSize: 15,
    fontWeight: Weights.medium,
    fontVariations: Weights.mediumVariation,
    color: Neutral.strong,
  );

  /// text.body 13 / 400 · lh 1.5（控件用 [LineHeights.control]）。
  static const TextStyle body = TextStyle(
    fontFamily: Fonts.sans,
    fontFamilyFallback: Fonts.cjkFallback,
    fontSize: 13,
    fontWeight: Weights.regular,
    fontVariations: Weights.regularVariation,
    height: LineHeights.body,
    color: Neutral.text,
  );

  /// text.secondary 12 / 400。
  static const TextStyle secondary = TextStyle(
    fontFamily: Fonts.sans,
    fontFamilyFallback: Fonts.cjkFallback,
    fontSize: 12,
    fontWeight: Weights.regular,
    fontVariations: Weights.regularVariation,
    color: Neutral.muted,
  );

  /// text.meta 11 / 400。
  static const TextStyle meta = TextStyle(
    fontFamily: Fonts.sans,
    fontFamilyFallback: Fonts.cjkFallback,
    fontSize: 11,
    fontWeight: Weights.regular,
    fontVariations: Weights.regularVariation,
    color: Neutral.placeholder,
  );

  /// 分组标题：11 / 500 / letter-spacing .06em（画板 00 各分组的标题行）。
  static const TextStyle label = TextStyle(
    fontFamily: Fonts.sans,
    fontFamilyFallback: Fonts.cjkFallback,
    fontSize: 11,
    fontWeight: Weights.medium,
    fontVariations: Weights.mediumVariation,
    letterSpacing: 0.66,
    color: Neutral.muted,
  );

  /// mono 12.5 · tabular-nums（用量 / 耗时 / 计数）。
  static const TextStyle mono = TextStyle(
    fontFamily: Fonts.mono,
    fontFamilyFallback: Fonts.cjkFallback,
    fontSize: 12.5,
    fontWeight: Weights.regular,
    fontVariations: Weights.regularVariation,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
    color: Neutral.text,
  );

  /// mono 11（token 名、kbd、注释性元信息）。
  static const TextStyle monoMeta = TextStyle(
    fontFamily: Fonts.mono,
    fontFamilyFallback: Fonts.cjkFallback,
    fontSize: 11,
    fontWeight: Weights.regular,
    fontVariations: Weights.regularVariation,
    color: Neutral.placeholder,
  );
}

/// 间距（4px 网格）+ space.chip 例外 + kbd 内边距。
abstract final class Spacing {
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s24 = 24;

  /// space.chip 1px 5px：徽章内边距，唯一非 4px 网格例外。
  static const EdgeInsets chip = EdgeInsets.symmetric(vertical: 1, horizontal: 5);

  /// kbd 0 4px（配 [LineHeights.kbdPx] 的 16px 行框，不是 `height` 倍率）。
  static const EdgeInsets kbd = EdgeInsets.symmetric(horizontal: 4);
}

/// 圆角 3 / 4 / 6 + pill 例外（布尔开关轨道 / 全圆徽章 = 轨道高度一半）。
abstract final class Radii {
  /// radius.3 芯片 / kbd。
  static const Radius r3 = Radius.circular(3);

  /// radius.4 按钮 / 输入。
  static const Radius r4 = Radius.circular(4);

  /// radius.6 卡片 / 弹层。
  static const Radius r6 = Radius.circular(6);

  static const BorderRadius chip = BorderRadius.all(r3);
  static const BorderRadius control = BorderRadius.all(r4);
  static const BorderRadius card = BorderRadius.all(r6);

  /// radius.pill：轨道高度的一半。
  static BorderRadius pill(double trackHeight) => BorderRadius.all(Radius.circular(trackHeight / 2));
}

/// 控件高度 24 / 28 / 32 与各自的水平内边距（画板 00「控件高度 · 按钮四态」）。
abstract final class Controls {
  static const double compact = 24;
  static const double standard = 28;
  static const double input = 32;

  static const EdgeInsets padCompact = EdgeInsets.symmetric(horizontal: Spacing.s8);
  static const EdgeInsets padStandard = EdgeInsets.symmetric(horizontal: Spacing.s8);
  static const EdgeInsets padInput = EdgeInsets.symmetric(horizontal: 10);
}

/// 按钮四态叠色：hover 6% / active 10%（rgba(30,30,38,·)），selected = active 叠色 + [Accent.text]。
abstract final class Overlays {
  static const Color hover = Color.fromRGBO(30, 30, 38, 0.06);
  static const Color active = Color.fromRGBO(30, 30, 38, 0.10);
  static const Color selected = active;
}

/// 焦点环 1.5 / +1（outline 1.5px accent，offset 1px）。
abstract final class FocusRing {
  static const double width = 1.5;
  static const double offset = 1;
  static const Color color = Accent.base;
}

/// 图标 16 / 工具栏 14 · stroke 1.5。
abstract final class IconSizes {
  static const double base = 16;
  static const double toolbar = 14;
  static const double stroke = 1.5;
}

/// kbd：mono 11 · 边框 1 [Borders.base] · radius 3 · 0 4px · line-height 16。
abstract final class Kbd {
  static const TextStyle text = TextStyle(
    fontFamily: Fonts.mono,
    fontFamilyFallback: Fonts.cjkFallback,
    fontSize: 11,
    fontWeight: Weights.regular,
    fontVariations: Weights.regularVariation,
    color: Neutral.muted,
  );
  static const EdgeInsets padding = Spacing.kbd;
  static const BorderRadius radius = Radii.chip;
  static const Color border = Borders.base;
  /// 行框高 16px（绝对值）。
  static const double lineHeightPx = LineHeights.kbdPx;
}

/// 动效：fast 120ms ease-out（hover / 颜色），base 160ms ease-out（展开 / 弹层）。
abstract final class Motion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration base = Duration(milliseconds: 160);
  static const Curve curve = Curves.easeOut;
}

/// spinner：accent · 1.5px 弧。
abstract final class Spinner {
  static const Color color = Accent.base;
  static const double strokeWidth = 1.5;
}

/// 几何（所有者裁定 2026-09-15，R2 审查留下的 7 个局部常量收进来）：它们不是画板 00 的 token，而是画板上量出来的
/// 单点尺寸；集中在这里是为了「widget 文件里不出现裸数字」。第 6 条是时长不是尺寸，按裁定与其余六条同组收纳。
abstract final class Geometry {
  /// 画板 32 image 块的预览区高度。
  static const double imagePreviewHeight = 220;

  /// 画板 32 audio 块的进度条高度。
  static const double audioBarHeight = 3;

  /// 画板 25 权限「范围」下拉的宽度。
  static const double permissionMenuWidth = 330;

  /// 画板 30 上下文窗口浮窗的宽度。
  static const double contextPopoverWidth = 266;

  /// 画板 22 / 23 终端卡的回滚行数上限（xterm `maxLines`）。
  static const int terminalScrollbackLines = 2000;

  /// spinner 转一圈的时长：动效 token 里没有「旋转周期」，取 [Motion.base] 的 5 倍（800ms），只是转速。
  static final Duration spinnerPeriod = Motion.base * 5;

  /// 画板 27 / 40 布尔开关的轨道 28 × 16；`toggleKnobInset` 是滑块与轨道的间隙。
  static const double toggleTrackWidth = 28;
  static const double toggleTrackHeight = 16;
  static const double toggleKnobInset = 2;

  // ---- R3（画板 01–04 / 40 / 41 / 42 / 80 量得的单点尺寸）

  /// 01–04：侧栏宽。
  static const double sidebarWidth = 280;

  /// 01–04：顶栏 / 线程头 / 侧栏头 / 侧栏底部导航的条高。
  static const double barHeight = 36;

  /// 01–04：窗口控制三键的格宽（点击热区，图标仍是 [IconSizes.toolbar]）。
  static const double windowButtonWidth = 44;

  /// 03：右栏展开时的宽度。
  static const double rightPanelWidth = 580;

  /// 01–03 / 42：输入框与转录内容列的最大宽度。
  static const double contentMaxWidth = 800;

  /// 01–04 / 41：agent 标记方块（[IconSizes.base] 见方）里的菱形边长。
  static const double agentMarkDot = 6;

  /// 40 / 41 / 42：弹层分组标题的行高。
  static const double menuGroupLabelHeight = 22;

  /// 40 / 41 / 42：弹层宽度四档（真实弹层锚在触发控件上，宽度按内容类别取一档）。
  static const double menuWidthNarrow = 240;
  static const double menuWidth = 280;
  static const double menuWidthWide = 320;
  static const double menuWidthInline = 420;

  /// 80：方法名列宽，也是过滤输入框宽。
  static const double trafficMethodWidth = 220;

  /// 04：侧栏搜索无结果时的占位区高。
  static const double sidebarEmptyHeight = 96;

  /// 01：转录空态的文本最大宽度。
  static const double emptyStateMaxWidth = 520;

  /// 03：输入框里模型下拉的最大宽度（名字长时截断）。
  static const double composerModelMaxWidth = 170;

  /// 弹层与触发控件的间隙（向下 / 向上展开）。
  static const Offset popoverBelow = Offset(0, Spacing.s4);
  static const Offset popoverAbove = Offset(0, -Spacing.s4);

  // ---- 分栏把手（画板 01–04，所有者裁定 2026-09-16）

  /// 01–03：两条分栏线上的拖拽命中区宽度，跨在 1px 分割线两侧（不占布局，叠在上面）。
  static const double splitterHit = 4;

  /// 01–03：侧栏宽度的可拖范围；双击复位到 [sidebarWidth]。
  static const double sidebarMinWidth = 220;
  static const double sidebarMaxWidth = 480;

  /// 03：右栏宽度的可拖范围；双击复位到 [rightPanelWidth]。
  static const double rightPanelMinWidth = 360;
  static const double rightPanelMaxWidth = 900;

  /// 01–03：中栏无论怎么拖都要留下的宽度（窗口变窄时先压右栏、再压侧栏）。
  static const double mainMinWidth = 360;

  // ---- R4（画板 60 / 61 量得的单点尺寸；查看器头行取 03 的 36 = [barHeight]，见 rounds/round-04 任务卡）

  /// 60：右栏里文件树那一列的宽度。
  static const double filesTreeWidth = 240;

  /// 60 / 61：面板内的头行（树列的「文件浏览器」标签行、终端的状态行）。
  static const double panelHeaderHeight = 28;

  /// 60：面板头行里的小图标按钮（搜索 / 全部折叠 / 刷新）见方。
  static const double panelIconButton = 20;

  /// 60：文件树一行的高度。
  static const double treeRowHeight = 24;

  /// 60：文件树每深一层的缩进（顶层 8、次层 20）。
  static const double treeIndent = 12;

  /// 60：Source / Preview 分段控件——外框 [Controls.compact] 高、内缩 2，分段本身 20 高。
  static const double segmentedInset = 2;
  static const double segmentHeight = 20;

  /// 61：终端状态行的运行 / 退出圆点直径。
  static const double terminalDot = 6;

  /// 61：本地 shell 初始尺寸（列 × 行）；真实尺寸由 xterm 按视口回报后 `terminal_resize`。
  static const int terminalCols = 100;
  static const int terminalRows = 30;
}
