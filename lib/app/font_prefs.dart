// 字体偏好（画板 70「外观」小节）：四个轴各选一款字体，全局生效。
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
// 持久化在 `settings.json` 的 `appearance` 段（Rust 侧 `settings::Appearance`，键名与 Zed 同形取
// `ui_font_family` / `buffer_font_family`）。生效方式是把值灌进 `tokens.dart` 的 [t.Fonts.apply]
// 再 [notifyListeners] 触发重建——tokens 是样式唯一来源（规则 3），这一层只负责选择与落盘。

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
/// **不变量：西文两轴与中文两轴的 family 不得有交集**（理由见文件头），由 `test/app/font_prefs_test.dart` 守住。
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

/// 字体偏好的读写与生效。挂在组合根上，[AcpApp] 监听它重建。
class FontPrefsController extends ChangeNotifier {
  FontPrefsController({this.bridge, FontRegistry? registry}) : registry = registry ?? FontRegistry();

  /// 没有桥（gallery / 单测）就只在内存里生效，不落盘。
  final CoreCommands? bridge;
  final FontRegistry registry;

  FontPrefs _prefs = const FontPrefs();
  FontPrefs get prefs => _prefs;

  /// 启动：先扫字体文件，再读设置并生效。任何一步失败都只是回到默认字体，不挡启动。
  Future<void> start() async {
    try {
      await registry.discoverAndLoad();
    } on Object catch (e) {
      debugPrint('font: 扫描失败，全部回默认: $e');
    }
    FontPrefs loaded = const FontPrefs();
    final CoreCommands? bridge = this.bridge;
    if (bridge != null) {
      try {
        loaded = FontPrefs.fromJson(await bridge.appearanceGet());
      } on Object catch (e) {
        debugPrint('font: 读设置失败，回默认: $e');
      }
    }
    _applyLocally(loaded, notify: true);
  }

  /// 改一个轴：立即生效 + 落盘。落盘失败不回滚（界面已经变了，下次启动回到旧值即可），只报错。
  Future<void> setAxis(FontAxis axis, String? family) async {
    final FontPrefs next = _prefs.withAxis(axis, family);
    if (next == _prefs) return;
    _applyLocally(next, notify: true);
    final CoreCommands? bridge = this.bridge;
    if (bridge == null) return;
    try {
      await bridge.appearanceSet(next.toJson());
    } on Object catch (e) {
      debugPrint('font: 存设置失败: $e');
    }
  }

  /// 四个轴一起回默认。
  Future<void> resetAll() async {
    if (_prefs == const FontPrefs()) return;
    _applyLocally(const FontPrefs(), notify: true);
    final CoreCommands? bridge = this.bridge;
    if (bridge == null) return;
    try {
      await bridge.appearanceSet(const <String, Object?>{});
    } on Object catch (e) {
      debugPrint('font: 存设置失败: $e');
    }
  }

  /// 灌进 tokens。`notify` 只在真的变了时才发，避免无谓重建。
  void _applyLocally(FontPrefs next, {required bool notify}) {
    _prefs = next;
    final bool changed = t.Fonts.apply(
      sans: next.resolved(FontAxis.uiLatin),
      cjk: next.resolved(FontAxis.uiCjk),
      mono: next.resolved(FontAxis.codeLatin),
      codeCjk: next.resolved(FontAxis.codeCjk),
    );
    if (notify && changed) notifyListeners();
  }
}
