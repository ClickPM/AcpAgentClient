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

/// 字体栈，四个轴：界面西文 [sans] / 界面中文 [cjk] / 代码西文 [mono] / 代码中文 [codeCjk]。
/// 随包默认是 Geist / Geist Mono / Noto Sans SC（都是 OFL），系统字体只做兜底。
///
/// **为什么中西文能分轴**：Geist / Geist Mono 对 U+4E00–9FFF 的 cmap 覆盖是 0，中文一个字都不走
/// [sans] / [mono]，整段由 [cjkFallback] / [codeCjkFallback] 的第一项渲染。反过来说，
/// **西文轴上不能放含 CJK 字形的字体**（Noto Sans SC、MiSans 这类），否则它把中文也吃掉，中文轴就失效了——
/// 设置页的两组下拉因此互不重叠，见 `lib/app/font_prefs.dart` 的候选表。
///
/// 回退链尾的两项兜中文字体没有的字（生僻字等），不随轴变。为什么 CJK 首项优先随包的 Noto Sans SC 而不是
/// 系统的 Microsoft YaHei UI：YaHei 的字形是按 GDI full hinting 调的，而 Flutter 桌面只做灰度抗锯齿、
/// 不吃那套 hinting，中文因此比拉丁文更虚。
///
/// 四个轴是**运行时可变**的（画板 70「外观」小节）：值由 `lib/app/font_prefs.dart` 经 [apply] 灌进来，
/// tokens 这一层不认识持久化，只持有当前值并派生 [styles]。
abstract final class Fonts {
  /// 随包默认，也是各轴的缺省值。**唯一一份默认字体名**——Rust 侧 `Appearance` 四个字段一律 `Option`，
  /// 没设过就是 null，由这里兜底（同 `ui_state` 的口径：默认值只在 token 里写一次）。
  static const String defaultSans = 'Geist';
  static const String defaultMono = 'Geist Mono';
  static const String defaultCjk = 'Noto Sans SC';

  /// 回退链尾的系统兜底，不随轴变。
  static const List<String> systemCjkFallback = <String>['Microsoft YaHei UI', 'PingFang SC'];

  static String _sans = defaultSans;
  static String _mono = defaultMono;
  static String _cjk = defaultCjk;
  static String _codeCjk = defaultCjk;

  /// 界面西文。
  static String get sans => _sans;

  /// 代码等宽西文。
  static String get mono => _mono;

  /// 界面中文（[cjkFallback] 首项）。
  static String get cjk => _cjk;

  /// 代码等宽中文（[codeCjkFallback] 首项）。
  static String get codeCjk => _codeCjk;

  /// 界面文字的 CJK 回退链。
  static List<String> get cjkFallback => <String>[_cjk, ...systemCjkFallback];

  /// 等宽文字的 CJK 回退链（代码块 / 终端 / diff / kbd）。
  ///
  /// 独立于 [cjkFallback]：等宽场景下中文宽度应当正好是拉丁的两倍，否则终端的字符网格会错位，
  /// 而界面场景不在乎这个。两条链因此分开，默认值相同但可以各自换。
  static List<String> get codeCjkFallback => <String>[_codeCjk, ...systemCjkFallback];

  static FontStyles _styles = FontStyles.build();
  static int _generation = 0;

  /// 当前这套字体下派生出的全部字阶。[TextStyles] 与 [Kbd] 都从这里取。
  static FontStyles get styles => _styles;

  /// 换字体的代数，每次 [apply] 真的改了值就 +1。
  ///
  /// 给**没法每帧重算**的下游用：把带 family 的东西（高亮 span、TextPainter 量出来的宽高）
  /// 长期存在 State 里的地方，记下算它时的代数，跟当前不一致就重算。
  /// 能每帧现取的（[TextStyles] / [CardText] 这些 getter）不需要它。
  static int get generation => _generation;

  /// 换字体：只覆盖给到的轴，`null` 表示这一轴不动。改完重算 [styles]。
  ///
  /// 调用方负责触发重建（`lib/app/font_prefs.dart` 用 [ChangeNotifier]）——tokens 不持有 widget 树。
  /// 返回是否真的变了，没变就不必重建。
  static bool apply({String? sans, String? mono, String? cjk, String? codeCjk}) {
    final String nextSans = sans ?? _sans;
    final String nextMono = mono ?? _mono;
    final String nextCjk = cjk ?? _cjk;
    final String nextCodeCjk = codeCjk ?? _codeCjk;
    if (nextSans == _sans && nextMono == _mono && nextCjk == _cjk && nextCodeCjk == _codeCjk) return false;
    _sans = nextSans;
    _mono = nextMono;
    _cjk = nextCjk;
    _codeCjk = nextCodeCjk;
    _styles = FontStyles.build();
    _generation++;
    return true;
  }

  /// 四个轴回到随包默认（测试与「恢复默认」按钮用）。
  static bool reset() => apply(sans: defaultSans, mono: defaultMono, cjk: defaultCjk, codeCjk: defaultCjk);
}

/// 一套字体下的全部字阶实例，由 [Fonts.apply] 一次性重算并缓存。
///
/// 为什么要缓存而不是每次 getter 现造：`const TextStyle` 时代同一档取到的永远是同一个对象，
/// widget 的 `==` 因此命中；现造会每次给出新对象，让原本能短路的比较全部落空、多出无谓重建。
/// 缓存后同一套字体下仍然是同一个对象，行为与 `const` 时代一致。
class FontStyles {
  const FontStyles({
    required this.display,
    required this.title,
    required this.body,
    required this.secondary,
    required this.meta,
    required this.label,
    required this.labelTabular,
    required this.mono,
    required this.monoMeta,
    required this.kbd,
  });

  factory FontStyles.build() {
    final String sans = Fonts.sans;
    final String mono = Fonts.mono;
    final List<String> cjk = Fonts.cjkFallback;
    final List<String> codeCjk = Fonts.codeCjkFallback;
    return FontStyles(
      display: TextStyle(
        fontFamily: sans,
        fontFamilyFallback: cjk,
        fontSize: 20,
        fontWeight: Weights.medium,
        fontVariations: Weights.mediumVariation,
        color: Neutral.strong,
      ),
      title: TextStyle(
        fontFamily: sans,
        fontFamilyFallback: cjk,
        fontSize: 15,
        fontWeight: Weights.medium,
        fontVariations: Weights.mediumVariation,
        color: Neutral.strong,
      ),
      body: TextStyle(
        fontFamily: sans,
        fontFamilyFallback: cjk,
        fontSize: 13,
        fontWeight: Weights.regular,
        fontVariations: Weights.regularVariation,
        height: LineHeights.body,
        color: Neutral.text,
      ),
      secondary: TextStyle(
        fontFamily: sans,
        fontFamilyFallback: cjk,
        fontSize: 12,
        fontWeight: Weights.regular,
        fontVariations: Weights.regularVariation,
        color: Neutral.muted,
      ),
      meta: TextStyle(
        fontFamily: sans,
        fontFamilyFallback: cjk,
        fontSize: 11,
        fontWeight: Weights.regular,
        fontVariations: Weights.regularVariation,
        color: Neutral.placeholder,
      ),
      label: TextStyle(
        fontFamily: sans,
        fontFamilyFallback: cjk,
        fontSize: 11,
        fontWeight: Weights.medium,
        fontVariations: Weights.mediumVariation,
        letterSpacing: 0.66,
        color: Neutral.muted,
      ),
      labelTabular: TextStyle(
        fontFamily: sans,
        fontFamilyFallback: cjk,
        fontSize: 11,
        fontWeight: Weights.medium,
        fontVariations: Weights.mediumVariation,
        letterSpacing: 0.66,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        color: Neutral.placeholder,
      ),
      mono: TextStyle(
        fontFamily: mono,
        fontFamilyFallback: codeCjk,
        fontSize: 12.5,
        fontWeight: Weights.regular,
        fontVariations: Weights.regularVariation,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        color: Neutral.text,
      ),
      monoMeta: TextStyle(
        fontFamily: mono,
        fontFamilyFallback: codeCjk,
        fontSize: 11,
        fontWeight: Weights.regular,
        fontVariations: Weights.regularVariation,
        color: Neutral.placeholder,
      ),
      kbd: TextStyle(
        fontFamily: mono,
        fontFamilyFallback: codeCjk,
        fontSize: 11,
        fontWeight: Weights.regular,
        fontVariations: Weights.regularVariation,
        color: Neutral.muted,
      ),
    );
  }

  final TextStyle display;
  final TextStyle title;
  final TextStyle body;
  final TextStyle secondary;
  final TextStyle meta;
  final TextStyle label;
  final TextStyle labelTabular;
  final TextStyle mono;
  final TextStyle monoMeta;
  final TextStyle kbd;
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
///
/// 各档是 **getter 而不是 `const`**：字体轴要能在运行时切换（画板 70「外观」小节），
/// 而 `const TextStyle` 在编译期就把 family 焊死了。调用点写法不变（还是 `t.TextStyles.body`），
/// 只有原本写在 `const` 上下文里的那些要去掉 `const`。实例由 [Fonts] 缓存，取到的是同一个对象。
abstract final class TextStyles {
  /// text.display 20 / 500 · 空态。
  static TextStyle get display => Fonts.styles.display;

  /// text.title 15 / 500。
  static TextStyle get title => Fonts.styles.title;

  /// text.body 13 / 400 · lh 1.5（控件用 [LineHeights.control]）。
  static TextStyle get body => Fonts.styles.body;

  /// text.secondary 12 / 400。
  static TextStyle get secondary => Fonts.styles.secondary;

  /// text.meta 11 / 400。
  static TextStyle get meta => Fonts.styles.meta;

  /// 分组标题：11 / 500 / letter-spacing .06em（画板 00 各分组的标题行）。
  static TextStyle get label => Fonts.styles.label;

  /// 画板 43 标题行：[label] 加等宽数字。不是新字阶——同一档字开 tabular-nums，
  /// 这样 `Session timeline · N turns` 里的计数变化时标题不会左右跳。
  static TextStyle get labelTabular => Fonts.styles.labelTabular;

  /// mono 12.5 · tabular-nums（用量 / 耗时 / 计数）。
  static TextStyle get mono => Fonts.styles.mono;

  /// mono 11（token 名、kbd、注释性元信息）。
  static TextStyle get monoMeta => Fonts.styles.monoMeta;
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
  /// getter 而非 `const`：随代码等宽轴走，理由同 [TextStyles]。
  static TextStyle get text => Fonts.styles.kbd;
  static const EdgeInsets padding = Spacing.kbd;
  static const BorderRadius radius = Radii.chip;
  static const Color border = Borders.base;
  /// 行框高 16px（绝对值）。
  static const double lineHeightPx = LineHeights.kbdPx;
}

/// 动效（画板 00 的动效小节，规格图在画板 05）：曲线只有一条，时长三档，位移两档。
abstract final class Motion {
  /// `motion.ease` = `cubic-bezier(.215,.61,.355,1)`。Flutter 里叫 [Curves.easeOutCubic]；
  /// **不是** `Curves.easeOut`（那条是 `cubic-bezier(.0,.0,.58,1)`，比画板定的钝）。
  static const Curve curve = Curves.easeOutCubic;

  /// `motion.fast`：hover 进出、颜色、等待态变暗。
  static const Duration fast = Duration(milliseconds: 120);

  /// `motion.base`：展开折叠、弹层出现。
  static const Duration base = Duration(milliseconds: 160);

  /// `motion.transition`：内容整块替换的入场（画板 05 的 A / B / C 组）。
  static const Duration transition = Duration(milliseconds: 200);

  /// `motion.rise`：整块替换入场时的上移距离。
  static const double rise = 8;

  /// `motion.pop`：弹层出现时的位移距离（向下弹用负值，向上弹用正值）。
  static const double pop = 4;

  /// `motion.stagger`：成组元素入场的错开步长，最多错开 3 个。
  static const Duration stagger = Duration(milliseconds: 40);

  /// 悬停提示的出现延迟（设计稿之外的增补）：动效 token 里没有这一档，取 [fast] 的 4 倍（480ms）——
  /// 鼠标扫过一排按钮时不会一路弹提示，停下来又不用等太久。
  static final Duration tooltipDelay = fast * 4;

  /// 入场位移只发生在纵轴上（[rise] 上移、[pop] 上下弹），横轴恒 0。
  /// 这个「横轴恒 0」也是几何字面量，按规则 3 归 tokens.dart，widget 文件里不写 `Offset(0, …)`。
  static Offset offsetY(double dy) => Offset(0, dy);
}

/// 不透明度（画板 00 的动效小节）。
abstract final class Opacities {
  /// `opacity.pending`：等待期内容的减弱（画板 05 B 组，配 [Motion.fast]）。
  static const double pending = 0.5;
}

/// spinner：accent · 1.5px 弧。
abstract final class Spinner {
  static const Color color = Accent.base;
  static const double strokeWidth = 1.5;
}

/// 画板 06 A 组「运行中 · 会话项底部的扫掠亮点线」的 token（画板自己列的「本画板新增 token」表）。
abstract final class Sweep {
  /// `sweep.track` 1px · border.subtle：全宽常亮底线。
  static const Color track = Borders.subtle;
  static const double trackWidth = Borders.width;

  /// `sweep.focus` 96px · accent：亮点宽度与颜色。
  static const Color focus = Accent.base;
  static const double focusWidth = 96;

  /// 亮点的横向渐变：中心不透明度 1、两端 0（线性）。两端那两个色值是 [focus] 的全透明版。
  static const List<Color> focusGradient = <Color>[Color(0x005566D8), focus, Color(0x005566D8)];
  static const List<double> focusStops = <double>[0, 0.5, 1];

  /// `sweep.cycle` 1400ms · linear · infinite：亮点从线左端外走到线右端外的一个周期。
  /// **这是全系统唯一允许用 linear 的动效**（其余一律 [Motion.curve]）：匀速才读得出「在动」而不是「在进度」。
  static const Duration cycle = Duration(milliseconds: 1400);

  /// `sweep.band` 8px：轨道带高度，线居中于带内。
  static const double band = 8;

  /// `sweep.inset` 12px：左右内缩，与会话项文字对齐。
  static const double inset = Spacing.s12;

  /// 轨道带贴会话项底边的距离（画板 06 A 组几何 `bottom:6px`）。
  static const double bottom = 6;
}

/// 画板 06 B 组「完成 ·『N 条消息』后的绿点」的 token：`dot.unread`。
abstract final class UnreadDot {
  /// 6px 实心圆 · success，无描边无光晕。
  static const double size = 6;
  static const Color color = Semantic.success;

  /// 与条数文字之间的间距。
  static const double gap = 6;
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

  /// 01–04：顶栏 / 会话头 / 侧栏头 / 侧栏底部导航的条高。
  static const double barHeight = 36;

  /// 06：运行中的会话项行高 `row.running`（默认态是 48 = [Controls.input] + [Spacing.s16]）。
  /// 48 ↔ 58 不做过渡（画板 06 A 组规格表：避免列表在流式期间抽动）。
  static const double sidebarRowRunning = 58;

  /// 06：运行中那 58px 里留给内容的高度——「文字块仍垂直居中于上方 50px」，余下 8px 归扫掠轨道带。
  static const double sidebarRowRunningContent = 50;

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

  /// 40 / 41 / 42：弹层内容区的最高高度。超过就在弹层内部滚动（条目多到出屏时选不中下面的条目，
  /// 所有者手测 2026-09-18）；这一档约十来行，短窗口里也还能完整落在触发控件上方。
  static const double menuMaxHeight = 320;

  /// 80：方法名列宽，也是过滤输入框宽。
  static const double trafficMethodWidth = 220;

  /// 04：侧栏搜索无结果时的占位区高。
  static const double sidebarEmptyHeight = 96;

  /// 01：转录空态的文本最大宽度。
  static const double emptyStateMaxWidth = 520;

  /// 03：输入框里模型下拉的最大宽度（名字长时截断）。
  static const double composerModelMaxWidth = 170;

  /// 03：输入框顶部附件芯片悬浮出的预览上限（芯片本身走 [Controls.compact] 高、[Radii.chip] 圆角）。
  static const double attachmentPreviewMaxWidth = 320;
  static const double attachmentPreviewMaxHeight = 240;

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

  /// 60：树列宽度的可拖范围（面板内的分栏把手）；双击复位到 [filesTreeWidth]。
  static const double filesTreeMinWidth = 160;
  static const double filesTreeMaxWidth = 480;

  /// 60：树列怎么拖都要给查看器留下的宽度（右栏本身可以拖到 [rightPanelMinWidth]）。
  static const double filesViewerMinWidth = 240;

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

  // ---- R5（画板 50 / 51 / 52 / 70 量得的单点尺寸）

  /// 50 / 51 / 70：agent 图标框（28 见方）与框内菱形（10）。
  static const double agentIconBox = 28;
  static const double agentIconDot = 10;

  /// 50：右栏展开成 Agents 面板时的宽度（画板里中栏 480、右栏占余下 680）。
  static const double registryPanelWidth = 680;

  /// 51 / 52：条目状态卡与认证卡的宽度（合集画板里一张卡的宽）。
  static const double stateCardWidth = 560;

  /// 51：安装进度条的高度。
  static const double installProgressHeight = 3;

  /// 52：认证方式单选圆（14）与圆点（6）。
  static const double radioSize = 14;
  static const double radioDot = 6;

  /// 52：terminal auth 可见终端的高度（画板只画了四行输出，xterm 要一个固定高）。
  static const double authTerminalHeight = 240;

  /// 70：设置页内容列宽、行标签列宽、custom 编辑块里 cmd / args / env 的标签宽。
  static const double settingsContentWidth = 860;
  static const double settingsLabelWidth = 160;
  static const double settingsFieldLabelWidth = 56;

  /// 70：设置行（标签列 + 值 + 尾部按钮）排得下的最窄宽度。设置现在是右栏的一个标签，
  /// 而右栏能拖到 [rightPanelMinWidth]（360）——比这还窄就整块横向滚，行不会被挤溢出。
  static const double settingsMinWidth = 420;

  // ---- 悬停提示（设计稿之外的增补，所有者 2026-09-18 直接要求；见 lib/ui/shell/tooltip.dart）

  /// 提示条与触发控件之间的间隙。
  static const double tooltipGap = Spacing.s8;

  /// 提示条贴到窗口边上时留的余量（上下左右同一档）。
  static const double tooltipMargin = Spacing.s8;

  /// 提示条的最大宽度：都是一行短说明，真超了就在这个宽度内折行。
  static const double tooltipMaxWidth = 240;

  /// 提示条的内边距。
  static const EdgeInsets tooltipPadding = EdgeInsets.symmetric(horizontal: Spacing.s8, vertical: Spacing.s4);

  /// 提示条在 Overlay 里的落点。位置由布局代理现算（见 lib/ui/shell/tooltip.dart），但 `Offset(…)` 本身
  /// 是几何字面量、按规则 3 归 tokens.dart，widget 文件里不写——与 [Motion.offsetY] 同一个道理。
  static Offset tooltipOffset(double dx, double dy) => Offset(dx, dy);
}

/// 画板 43「会话时间线弹层」的 token（画板自己列的「本画板新增 token」表；画板 00 未改，这组值只服务画板 43）。
abstract final class Timeline {
  /// `timeline.maxHeight` 主窗口高 × 0.75：弹层总高上限（含内边距与标题行）。
  /// 存的是系数不是像素——上限随窗口走，算的地方按当帧窗口高乘一次。
  static const double maxHeightFactor = 0.75;

  /// `timeline.width` 420：弹层宽。画板登记为 `menu.width.inline` 的别名（与画板 42 的 `@` / `/` 菜单同一档），
  /// 所以这里指过去而不是再写一个 420：改那一档时两边一起动。
  static const double width = Geometry.menuWidthInline;

  /// `timeline.rail` 1px · border.subtle：导轨竖线。
  static const Color rail = Borders.subtle;
  static const double railWidth = Borders.width;

  /// `timeline.railColumn` 16px：导轨列宽，线居中于列（x = 8）。
  static const double railColumn = 16;

  /// `timeline.node` 6px · #8b8b96：节点直径与颜色（用户行实心、`A` 行空心，空心的描边宽同 [railWidth]）。
  static const double node = 6;
  static const Color nodeColor = Neutral.placeholder;

  /// `timeline.label` 24px：标签列宽（两位编号 `01` 与字母 `A` 共用）。
  static const double label = 24;

  /// `timeline.turnGap` 4px：轮与轮之间的空隙（导轨竖线跨过它不断）。
  static const double turnGap = Spacing.s4;
}
