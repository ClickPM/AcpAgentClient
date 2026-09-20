// 外观偏好（画板 70「外观」小节 + 画板 07「深色 Token 对位表」）：四个字体轴各选一款字体，
// 外加浅色 / 深色主题，全局生效。
//
// 四个轴是「界面西文 / 界面中文 / 代码西文 / 代码中文」。为什么这么分而不是一个「界面字体」下拉：
// Flutter 里中西文分轴是靠 `fontFamily` + `fontFamilyFallback` 天然成立的——西文字体对 CJK 的 cmap
// 覆盖为 0，中文一个字都吃不下，必然落到 fallback 首项。前提是**西文轴上不能出现含 CJK 字形的字体**，
// 否则它把中文也吃掉、中文轴就失效了。所以两组候选严格互不重叠，见 [fontCatalog] 与它的单测。
//
// 代码中文单独一轴而不是跟着界面中文：等宽场景下中文宽度应当正好是拉丁的两倍，否则终端的字符网格会错位
// （随包的 Noto Sans SC 汉字是全角 1em，而 Geist Mono 的 advance 约 0.6em，2×0.6 ≠ 1，现在就是歪的）。
// 更纱黑体 Sarasa Mono SC 专门做了 2:1 对齐，是这一轴的推荐项。界面场景不在乎这个，所以两轴分开。
//
// 主题只有浅色 / 深色两档（画板 07：深色只换颜色，间距 / 圆角 / 字阶 / 控件高度 / 动效时长全都一样）。
// 切换入口是侧栏标题条右端那个按钮（`lib/ui/shell/sidebar.dart`）；画板 70 的「外观」小节还没有这一行，
// 见 rounds/BACKLOG.md 的「设计稿补注记」。
//
// 持久化在 `settings.json` 的 `appearance` 段（Rust 侧 `settings::Appearance`，字体键名与 Zed 同形取
// `ui_font_family` / `buffer_font_family`，主题是我们自己的 `theme`）。生效方式是把值灌进 `tokens.dart`
// 的 [t.Fonts.apply] / [t.Theming.apply]，再 [notifyListeners] 触发重建——tokens 是样式唯一来源（规则 3），
// 这一层只负责选择与落盘。
//
// **`appearance` 段是整段替换的**（Rust 侧 `set_appearance`），所以它只能有一个写者：就是
// [AppearanceController]。要加新的外观项就加在 [AppearancePrefs] 上，不要另起一个控制器去写同一段。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart' as t;
import 'core_bridge.dart';
import 'paths.dart';

/// 四个字体轴。
enum FontAxis {
  /// 界面西文（`TextStyle.fontFamily`，非等宽档）。
  uiLatin,

  /// 界面中文（非等宽档的 `fontFamilyFallback` 首项）。
  uiCjk,

  /// 代码等宽西文。
  codeLatin,

  /// 代码等宽中文（等宽档的 `fontFamilyFallback` 首项）。
  codeCjk,
}

extension FontAxisLabel on FontAxis {
  /// 设置页行标题。
  String get label => switch (this) {
    FontAxis.uiLatin => '界面西文',
    FontAxis.uiCjk => '界面中文',
    FontAxis.codeLatin => '代码等宽西文',
    FontAxis.codeCjk => '代码等宽中文',
  };

  /// `settings.json` 里的键名。
  String get settingsKey => switch (this) {
    FontAxis.uiLatin => 'ui_font_family',
    FontAxis.uiCjk => 'ui_cjk_font_family',
    FontAxis.codeLatin => 'buffer_font_family',
    FontAxis.codeCjk => 'buffer_cjk_font_family',
  };

  /// 这一轴是不是等宽轴（决定候选表与默认值）。
  bool get isCode => this == FontAxis.codeLatin || this == FontAxis.codeCjk;

  /// 这一轴是不是 CJK 轴。
  bool get isCjk => this == FontAxis.uiCjk || this == FontAxis.codeCjk;
}

/// 候选字体的来源。
enum FontSource {
  /// 随包且在 `pubspec.yaml` 注册，永远可用。
  bundled,

  /// 要有字体文件才可用。三个来源：随安装包放在可执行文件旁的 `fonts/`、用户丢进数据目录的 `fonts/`、
  /// 或者装进了系统。前两者启动时由 [FontRegistry] 用 `FontLoader` 注册，后者由平台按家族名直接解析。
  ///
  /// 为什么这几款不进 `pubspec.yaml`：MiSans 与 HarmonyOS Sans 的协议禁止「在独立基础上再分发字体文件」，
  /// 文件不能入库；而 `pubspec.yaml` 里声明了却没有文件，`flutter build` 会直接失败。走运行时注册之后，
  /// 仓库里一个字体文件都没有也能正常构建，文件放进去就自动点亮。
  optional,
}

/// 一个候选字体。
@immutable
class FontChoice {
  const FontChoice({
    required this.family,
    required this.label,
    required this.source,
    this.fileStems = const <String>[],
    this.note,
    this.downloadUrl,
  });

  /// 传给 `TextStyle.fontFamily` 的家族名，也是 `FontLoader` 注册用的名字。
  final String family;

  /// 下拉里显示的名字。
  final String label;

  final FontSource source;

  /// 探测用的文件名主干（规范化后比对，见 [normalizeFileStem]）。命中即认为本机有这款字体。
  final List<String> fileStems;

  /// 下拉项下面的一行小字。
  final String? note;

  /// [FontSource.optional] 且本机没有时，给一个「去下载」的去处。
  final String? downloadUrl;

  @override
  String toString() => 'FontChoice($family)';
}

/// 文件名规范化：小写、只留字母数字。`MiSans-Regular.ttf` 与 `misans_regular.otf` 都归到 `misansregular`。
String normalizeFileStem(String name) {
  final int dot = name.lastIndexOf('.');
  final String stem = dot > 0 ? name.substring(0, dot) : name;
  return stem.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

/// 四个轴的候选表。
///
/// **不变量：西文两轴与中文两轴的 family 不得有交集**（理由见文件头），由 `test/app/appearance_prefs_test.dart` 守住。
/// 西文轴只放对 CJK 覆盖为 0 的纯拉丁字体；中文轴只放 CJK 字体。
const Map<FontAxis, List<FontChoice>> fontCatalog = <FontAxis, List<FontChoice>>{
  FontAxis.uiLatin: <FontChoice>[
    FontChoice(family: t.Fonts.defaultSans, label: 'Geist', source: FontSource.bundled, note: '随包 · 默认'),
    FontChoice(
      family: 'Inter',
      label: 'Inter',
      source: FontSource.optional,
      fileStems: <String>['inter', 'intervariable'],
      note: 'OFL 1.1',
      downloadUrl: 'https://rsms.me/inter/',
    ),
  ],
  FontAxis.uiCjk: <FontChoice>[
    FontChoice(family: t.Fonts.defaultCjk, label: 'Noto Sans SC 思源黑体', source: FontSource.bundled, note: '随包 · 默认'),
    FontChoice(
      family: 'MiSans',
      label: 'MiSans 小米兰亭',
      source: FontSource.optional,
      fileStems: <String>['misans'],
      note: '小米自有协议 · 免费商用',
      downloadUrl: 'https://hyperos.mi.com/font/download',
    ),
    FontChoice(
      family: 'HarmonyOS Sans SC',
      label: 'HarmonyOS Sans 鸿蒙黑体',
      source: FontSource.optional,
      fileStems: <String>['harmonyossanssc', 'harmonyossans'],
      note: '华为自有协议 · 免费商用',
      downloadUrl: 'https://developer.huawei.com/consumer/cn/design/resource/',
    ),
  ],
  FontAxis.codeLatin: <FontChoice>[
    FontChoice(family: t.Fonts.defaultMono, label: 'Geist Mono', source: FontSource.bundled, note: '随包 · 默认'),
    FontChoice(
      family: 'JetBrains Mono',
      label: 'JetBrains Mono',
      source: FontSource.optional,
      fileStems: <String>['jetbrainsmono'],
      note: 'OFL 1.1',
      downloadUrl: 'https://www.jetbrains.com/lp/mono/',
    ),
    FontChoice(
      family: 'Cascadia Mono',
      label: 'Cascadia Mono',
      source: FontSource.optional,
      fileStems: <String>['cascadiamono'],
      note: 'OFL 1.1 · Windows 可能已自带',
      downloadUrl: 'https://github.com/microsoft/cascadia-code/releases',
    ),
  ],
  FontAxis.codeCjk: <FontChoice>[
    FontChoice(family: t.Fonts.defaultCjk, label: 'Noto Sans SC 思源黑体', source: FontSource.bundled, note: '随包 · 默认'),
    FontChoice(
      family: 'Sarasa Mono SC',
      label: '更纱黑体 Sarasa Mono SC',
      source: FontSource.optional,
      fileStems: <String>['sarasamonosc', 'sarasamonoscregular'],
      note: 'OFL 1.1 · 汉字正好是拉丁的两倍宽，终端不错位（推荐）',
      downloadUrl: 'https://github.com/be5invis/Sarasa-Gothic/releases',
    ),
    FontChoice(
      family: 'MiSans',
      label: 'MiSans 小米兰亭',
      source: FontSource.optional,
      fileStems: <String>['misans'],
      note: '小米自有协议 · 非等宽对齐',
      downloadUrl: 'https://hyperos.mi.com/font/download',
    ),
    FontChoice(
      family: 'HarmonyOS Sans SC',
      label: 'HarmonyOS Sans 鸿蒙黑体',
      source: FontSource.optional,
      fileStems: <String>['harmonyossanssc', 'harmonyossans'],
      note: '华为自有协议 · 非等宽对齐',
      downloadUrl: 'https://developer.huawei.com/consumer/cn/design/resource/',
    ),
  ],
};

/// 某一轴的默认 family。
String defaultFamilyFor(FontAxis axis) => switch (axis) {
  FontAxis.uiLatin => t.Fonts.defaultSans,
  FontAxis.codeLatin => t.Fonts.defaultMono,
  FontAxis.uiCjk || FontAxis.codeCjk => t.Fonts.defaultCjk,
};

/// 四个轴的当前选择。`null` = 用默认（不往 `settings.json` 里写死默认名，口径同 `ui_state`）。
@immutable
class FontPrefs {
  const FontPrefs({this.uiLatin, this.uiCjk, this.codeLatin, this.codeCjk});

  factory FontPrefs.fromJson(Map<String, Object?> json) => FontPrefs(
    uiLatin: _str(json[FontAxis.uiLatin.settingsKey]),
    uiCjk: _str(json[FontAxis.uiCjk.settingsKey]),
    codeLatin: _str(json[FontAxis.codeLatin.settingsKey]),
    codeCjk: _str(json[FontAxis.codeCjk.settingsKey]),
  );

  static String? _str(Object? v) {
    if (v is! String) return null;
    final String s = v.trim();
    return s.isEmpty ? null : s;
  }

  final String? uiLatin;
  final String? uiCjk;
  final String? codeLatin;
  final String? codeCjk;

  /// 某一轴的选择，没选过就是 `null`。
  String? raw(FontAxis axis) => switch (axis) {
    FontAxis.uiLatin => uiLatin,
    FontAxis.uiCjk => uiCjk,
    FontAxis.codeLatin => codeLatin,
    FontAxis.codeCjk => codeCjk,
  };

  /// 某一轴最终生效的 family（没选过 → 默认）。
  String resolved(FontAxis axis) => raw(axis) ?? defaultFamilyFor(axis);

  FontPrefs withAxis(FontAxis axis, String? family) {
    // 选回默认项时存 null 而不是默认名：这样以后改了默认值，没动过设置的用户会跟着走。
    final String? v = (family == null || family == defaultFamilyFor(axis)) ? null : family;
    return switch (axis) {
      FontAxis.uiLatin => FontPrefs(uiLatin: v, uiCjk: uiCjk, codeLatin: codeLatin, codeCjk: codeCjk),
      FontAxis.uiCjk => FontPrefs(uiLatin: uiLatin, uiCjk: v, codeLatin: codeLatin, codeCjk: codeCjk),
      FontAxis.codeLatin => FontPrefs(uiLatin: uiLatin, uiCjk: uiCjk, codeLatin: v, codeCjk: codeCjk),
      FontAxis.codeCjk => FontPrefs(uiLatin: uiLatin, uiCjk: uiCjk, codeLatin: codeLatin, codeCjk: v),
    };
  }

  Map<String, Object?> toJson() => <String, Object?>{
    for (final FontAxis a in FontAxis.values)
      if (raw(a) != null) a.settingsKey: raw(a),
  };

  @override
  bool operator ==(Object other) =>
      other is FontPrefs &&
      other.uiLatin == uiLatin &&
      other.uiCjk == uiCjk &&
      other.codeLatin == codeLatin &&
      other.codeCjk == codeCjk;

  @override
  int get hashCode => Object.hash(uiLatin, uiCjk, codeLatin, codeCjk);

  @override
  String toString() => 'FontPrefs(${toJson()})';
}

/// 外观设置的全量：四个字体轴 + 主题。`appearance` 段整段落盘，所以这里一次给全。
@immutable
class AppearancePrefs {
  const AppearancePrefs({this.fonts = const FontPrefs(), this.theme});

  factory AppearancePrefs.fromJson(Map<String, Object?> json) =>
      AppearancePrefs(fonts: FontPrefs.fromJson(json), theme: parseTheme(json[themeSettingsKey]));

  /// `settings.json` 里 `appearance` 段内的键名。不是顶层 `theme`——那个是 Zed 的主题名，我们不碰（规则 7）。
  static const String themeSettingsKey = 'theme';

  /// 落盘取值：`"light"` / `"dark"`，与 Rust 侧 `settings::sane_theme` 的白名单一致。
  static String themeValue(t.AppTheme mode) => mode.name;

  /// 读回来的字符串 → 主题。认不出来的（手写的脏值）一律 null = 没设置过，落回缺省。
  static t.AppTheme? parseTheme(Object? v) {
    if (v is! String) return null;
    final String name = v.trim().toLowerCase();
    for (final t.AppTheme mode in t.AppTheme.values) {
      if (mode.name == name) return mode;
    }
    return null;
  }

  final FontPrefs fonts;

  /// `null` = 没选过，用 [t.Theming.defaultMode]（不往 `settings.json` 里写死缺省值，口径同字体轴）。
  final t.AppTheme? theme;

  t.AppTheme get resolvedTheme => theme ?? t.Theming.defaultMode;

  AppearancePrefs withFonts(FontPrefs next) => AppearancePrefs(fonts: next, theme: theme);

  /// 选回缺省档时存 null 而不是档名，理由同 [FontPrefs.withAxis]。
  AppearancePrefs withTheme(t.AppTheme? mode) =>
      AppearancePrefs(fonts: fonts, theme: mode == t.Theming.defaultMode ? null : mode);

  Map<String, Object?> toJson() => <String, Object?>{
    ...fonts.toJson(),
    if (theme != null) themeSettingsKey: themeValue(theme!),
  };

  @override
  bool operator ==(Object other) => other is AppearancePrefs && other.fonts == fonts && other.theme == theme;

  @override
  int get hashCode => Object.hash(fonts, theme);

  @override
  String toString() => 'AppearancePrefs(${toJson()})';
}

/// 可选字体的探测与注册。
///
/// 三个来源按优先级：可执行文件旁的 `fonts/`（随安装包）→ 数据目录的 `fonts/`（用户自己丢的）→ 系统字体目录。
/// 前两个目录里的文件启动时用 `FontLoader` 注册进引擎；系统目录只做**探测**，不注册——Windows 上
/// 装进系统的字体由平台按家族名直接解析，再注册一遍纯属浪费内存。
class FontRegistry {
  FontRegistry({List<Directory>? loadDirs, List<Directory>? probeDirs})
    : _loadDirs = loadDirs ?? defaultLoadDirs(),
      _probeDirs = probeDirs ?? defaultProbeDirs();

  final List<Directory> _loadDirs;
  final List<Directory> _probeDirs;

  final Set<String> _available = <String>{};

  /// 本机可用的 family 名（随包的不在这里，它们永远可用，见 [isAvailable]）。
  Set<String> get availableOptional => Set<String>.unmodifiable(_available);

  /// 随安装包的字体目录 + 用户自己丢文件的地方。这两处的文件会被注册进引擎。
  static List<Directory> defaultLoadDirs() {
    final List<Directory> dirs = <Directory>[];
    try {
      final String exeDir = File(Platform.resolvedExecutable).parent.path;
      dirs.add(Directory('$exeDir${Platform.pathSeparator}fonts'));
    } on Object {
      // 拿不到可执行文件路径（测试环境）就只用数据目录。
    }
    dirs.add(Directory('${defaultDataDir()}${Platform.pathSeparator}fonts'));
    return dirs;
  }

  /// 系统字体目录，只探测不注册。
  static List<Directory> defaultProbeDirs() {
    if (!Platform.isWindows) return const <Directory>[];
    final Map<String, String> env = Platform.environment;
    final String windir = env['WINDIR'] ?? r'C:\Windows';
    final List<Directory> dirs = <Directory>[Directory('$windir\\Fonts')];
    final String? localAppData = env['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      // 「仅为我安装」的字体在这里，不在 C:\Windows\Fonts。
      dirs.add(Directory('$localAppData\\Microsoft\\Windows\\Fonts'));
    }
    return dirs;
  }

  /// 扫描三处目录，注册能注册的，返回本机可用的 optional family 集合。
  ///
  /// 全程不抛：字体目录读不动、文件坏了、注册失败，都只是这一款不可用，绝不能挡住启动。
  Future<Set<String>> discoverAndLoad() async {
    _available.clear();
    final Map<String, List<File>> byFamily = <String, List<File>>{};

    for (final Directory dir in _loadDirs) {
      for (final File f in _fontFilesIn(dir)) {
        final FontChoice? c = _matchChoice(f);
        if (c != null) (byFamily[c.family] ??= <File>[]).add(f);
      }
    }
    for (final Directory dir in _probeDirs) {
      for (final File f in _fontFilesIn(dir)) {
        final FontChoice? c = _matchChoice(f);
        // 系统里已有 → 只记可用，不注册。
        if (c != null) _available.add(c.family);
      }
    }

    for (final MapEntry<String, List<File>> e in byFamily.entries) {
      // 同一 family 的多个字重一起进同一个 FontLoader，w400 / w500 才都能匹配到。
      final FontLoader loader = FontLoader(e.key);
      int added = 0;
      for (final File f in e.value) {
        try {
          final Uint8List bytes = await f.readAsBytes();
          loader.addFont(Future<ByteData>.value(ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes)));
          added++;
        } on Object catch (err) {
          debugPrint('font: 读不了 ${f.path}: $err');
        }
      }
      if (added == 0) continue;
      try {
        await loader.load();
        _available.add(e.key);
      } on Object catch (err) {
        debugPrint('font: 注册 ${e.key} 失败: $err');
      }
    }
    return availableOptional;
  }

  /// 这款字体本机能不能用。随包的永远能用；optional 的要探测到文件。
  bool isAvailable(FontChoice choice) =>
      choice.source == FontSource.bundled || _available.contains(choice.family);

  static const Set<String> _fontExt = <String>{'.ttf', '.otf'};

  Iterable<File> _fontFilesIn(Directory dir) sync* {
    try {
      if (!dir.existsSync()) return;
      for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
        if (e is! File) continue;
        final String lower = e.path.toLowerCase();
        // .ttc 字体集合 FontLoader 吃不下，直接跳过而不是报错。
        if (_fontExt.any(lower.endsWith)) yield e;
      }
    } on Object catch (err) {
      debugPrint('font: 扫不了 ${dir.path}: $err');
    }
  }

  static FontChoice? _matchChoice(File f) {
    final String stem = normalizeFileStem(f.uri.pathSegments.last);
    if (stem.isEmpty) return null;
    for (final List<FontChoice> list in fontCatalog.values) {
      for (final FontChoice c in list) {
        if (c.source != FontSource.optional) continue;
        for (final String s in c.fileStems) {
          if (stem.startsWith(s)) return c;
        }
      }
    }
    return null;
  }
}

/// 外观偏好的读写与生效。挂在组合根上，[AcpApp] 监听它重建整棵树。
class AppearanceController extends ChangeNotifier {
  AppearanceController({this.bridge, FontRegistry? registry}) : registry = registry ?? FontRegistry();

  /// 没有桥（gallery / 单测）就只在内存里生效，不落盘。
  final CoreCommands? bridge;
  final FontRegistry registry;

  AppearancePrefs _prefs = const AppearancePrefs();
  AppearancePrefs get prefs => _prefs;

  /// 四个字体轴的当前选择（设置页「外观」小节用）。
  FontPrefs get fonts => _prefs.fonts;

  /// 当前生效的主题。
  t.AppTheme get theme => _prefs.resolvedTheme;

  /// [start] 与 [setAxis] 里都有 `await`（扫盘、读写设置），期间窗口可能已经关掉。
  /// 对已 dispose 的 [ChangeNotifier] 调 [notifyListeners] 在 debug 下会断言失败，
  /// 而且那时候也没人再需要这次结果了。
  bool _disposed = false;

  /// [start] 这一趟读盘的完成信号（没跑过 [start] 的 gallery / 单测里是 null）。
  ///
  /// 改设置前必须先等它：读盘回来之前 `_prefs` 还是空的，拿它算出来的全量快照里
  /// 四个字体轴都是缺省，而 `appearance` 段在 Rust 侧是**整段替换**的（`set_appearance`），
  /// 于是盘上已存的字体设置会被这次写盘抹掉。切换按钮首帧就能点、而 `start()` 要先扫一遍
  /// 字体目录，这个窗口是真的（发布前审查 high，2026-09-20）。
  Future<void>? _hydration;

  /// 读设置**成功过**没有。没成功过就绝不能落盘：`appearance` 段是整段替换的，把一份
  /// 「读失败 → 全缺省」的快照写回去，等于把盘上已有的设置抹掉（复审 high，2026-09-20）。
  ///
  /// 文件不存在不算失败 —— Rust 侧 `appearance()` 读不到文件时回的是空外观，GET 正常返回 `{}`，
  /// 那种情况下盘上本来就没东西可丢。只有桥真的报错（核心还没 `core_init`、IPC 挂了）才是 false。
  bool _readSettingsOk = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// 启动：先扫字体文件，再读设置并生效。任何一步失败都只是回到缺省外观，不挡启动。
  Future<void> start() {
    final Future<void> hydration = _hydrate();
    _hydration = hydration;
    return hydration;
  }

  /// 等这一趟读盘走完。`start()` 自己已经把每一步的失败都降级成缺省值了，
  /// 这里再兜一层只是不让它挡住后续操作。
  Future<void> _awaitHydration() async {
    final Future<void>? hydration = _hydration;
    if (hydration == null) return;
    try {
      await hydration;
    } on Object {
      // 读盘失败不挡后续操作：`_prefs` 停在缺省值上，[_edit] 会再读一次，仍读不到就只改内存。
    }
  }

  Future<void> _hydrate() async {
    try {
      await registry.discoverAndLoad();
    } on Object catch (e) {
      debugPrint('appearance: 字体扫描失败，全部回默认: $e');
    }
    final AppearancePrefs? loaded = await _readSettings();
    if (_disposed) return;
    _applyLocally(loaded ?? const AppearancePrefs(), notify: false);
    // 扫描结果（哪些可选字体本机有）本身就是设置页要用的状态，**与「字体选择有没有变」无关**。
    // 没存过设置时 `Fonts.apply` 返回 false，若沿用 `_applyLocally` 的「变了才通知」，
    // 设置页就会一直停在扫描之前的「本机未找到」——所有者手测 2026-09-20 报的正是这个。
    // 启动只发这一次，代价可以忽略。
    notifyListeners();
  }

  /// 读一次盘。读到就返回（并记下 [_readSettingsOk]），读不动回 null —— 这跟「读到一份空设置」
  /// 是两回事，调用方必须分开处理。没有桥（gallery / 单测）也回 null，那时本来就不落盘。
  Future<AppearancePrefs?> _readSettings() async {
    final CoreCommands? bridge = this.bridge;
    if (bridge == null) return null;
    try {
      final AppearancePrefs loaded = AppearancePrefs.fromJson(await bridge.appearanceGet());
      _readSettingsOk = true;
      return loaded;
    } on Object catch (e) {
      debugPrint('appearance: 读设置失败，回默认: $e');
      return null;
    }
  }

  /// 改一个字体轴：立即生效 + 落盘。
  Future<void> setAxis(FontAxis axis, String? family) =>
      _edit((AppearancePrefs p) => p.withFonts(p.fonts.withAxis(axis, family)));

  /// 换主题（浅色 ↔ 深色）。
  Future<void> setTheme(t.AppTheme mode) => _edit((AppearancePrefs p) => p.withTheme(mode));

  /// 侧栏标题条那个按钮：在两档之间来回切。
  Future<void> toggleTheme() => _edit(
    (AppearancePrefs p) => p.withTheme(p.resolvedTheme == t.AppTheme.dark ? t.AppTheme.light : t.AppTheme.dark),
  );

  /// 整段外观回缺省（四个字体轴 + 主题）。
  Future<void> resetAll() => _edit((AppearancePrefs _) => const AppearancePrefs());

  /// 改一次外观：等读盘落定 → 算出新的全量 → 立即生效 + 落盘。
  /// 落盘失败不回滚（界面已经变了，下次启动回到旧值即可），只报错。
  ///
  /// 新值由 `change` 从**当时**的 `_prefs` 算出来，不是调用点先算好再传进来：等读盘的那一下
  /// `_prefs` 还会变（[_hydrate] 会把盘上的灌进来），先算好就等于拿空快照去整段覆盖。
  Future<void> _edit(AppearancePrefs Function(AppearancePrefs current) change) async {
    await _awaitHydration();
    if (_disposed) return;
    final CoreCommands? bridge = this.bridge;

    // 用户是按**界面上看得见的这一份**点的，相对操作（[toggleTheme]）必须对准它算。
    final AppearancePrefs seen = _prefs;
    AppearancePrefs next = change(seen);

    // 启动那一趟没读到（最常见的是核心还没 `core_init` 完 —— `AcpApp.initState` 里
    // `_appearance.start()` 排在 `_controller.start()` 前面，两个都不 await）就再读一次：
    // 多半只是早了几毫秒，这一下就能拿到盘上的真值。
    bool hydratedLate = false;
    if (bridge != null && !_readSettingsOk) {
      final AppearancePrefs? retried = await _readSettings();
      if (_disposed) return;
      if (retried != null) {
        next = _overlay(base: retried, seen: seen, edited: next);
        hydratedLate = true;
      }
    }

    // 补读成功时一定要走下去：哪怕这次改动本身是空操作，也得把刚读到的盘上快照灌进界面，
    // 否则界面会一直停在读失败时的缺省值上（`_readSettingsOk` 已经翻真，不会再补读第二次）。
    if (!hydratedLate && next == _prefs) return;
    _applyLocally(next, notify: true);
    if (bridge == null) return;
    if (!_readSettingsOk) {
      // 从没读到过盘上的设置，就不知道会覆盖掉什么。界面上这次改动照常生效，只是不落盘。
      debugPrint('appearance: 一直读不到设置，这次只改内存不落盘（怕整段覆盖抹掉已有设置）');
      return;
    }
    try {
      // `appearance` 段整段替换，所以每次都把全量给过去。
      await bridge.appearanceSet(next.toJson());
    } on Object catch (e) {
      debugPrint('appearance: 存设置失败: $e');
    }
  }

  /// 补读成功时的合并：以盘上的 `base` 为基底，把这次**真改到**的维度（`edited` 相对 `seen` 有差的那些）
  /// 盖上去。
  ///
  /// 两边都不能少（复审 high，2026-09-20）：直接拿 `edited` 落盘会把盘上没改到的项抹掉（`appearance`
  /// 段整段替换）；反过来先把 `base` 灌进 `_prefs` 再算，[toggleTheme] 这种相对操作就会对着**用户没看见
  /// 的**主题取反 —— 盘上是深色、界面因读失败显示浅色时，用户点「转深色」反而被写成浅色。
  ///
  /// [resetAll] 在这条路上只重置用户看得见的那些维度：没看见的以盘上为准。这条路要求「启动读盘失败 +
  /// 补读成功 + 正好点重置」，而重置目前也没有界面入口。
  static AppearancePrefs _overlay({
    required AppearancePrefs base,
    required AppearancePrefs seen,
    required AppearancePrefs edited,
  }) {
    FontPrefs fonts = base.fonts;
    for (final FontAxis axis in FontAxis.values) {
      if (edited.fonts.raw(axis) != seen.fonts.raw(axis)) fonts = fonts.withAxis(axis, edited.fonts.raw(axis));
    }
    return AppearancePrefs(fonts: fonts, theme: edited.theme != seen.theme ? edited.theme : base.theme);
  }

  /// 灌进 tokens。`notify` 只在真的变了时才发，避免无谓重建。
  void _applyLocally(AppearancePrefs next, {required bool notify}) {
    _prefs = next;
    final FontPrefs fonts = next.fonts;
    // 两个 apply 都要跑到：写成 `a || b` 会在字体已经变了的时候短路掉主题那一边。
    final bool fontsChanged = t.Fonts.apply(
      sans: fonts.resolved(FontAxis.uiLatin),
      cjk: fonts.resolved(FontAxis.uiCjk),
      mono: fonts.resolved(FontAxis.codeLatin),
      codeCjk: fonts.resolved(FontAxis.codeCjk),
    );
    final bool themeChanged = t.Theming.apply(next.resolvedTheme);
    if (notify && (fontsChanged || themeChanged) && !_disposed) notifyListeners();
  }
}
