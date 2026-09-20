// 外观偏好：字体（画板 70「外观」）的候选表不变量、四轴解析与落盘形状、tokens 的运行时生效、可选字体探测；
// 主题（画板 07「深色 Token 对位表」）的两套取值、落盘形状与切换。

import 'dart:async';
import 'dart:io';

import 'package:acp_agent_client/app/appearance_prefs.dart';
import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/transcript/card_chrome.dart';
import 'package:acp_agent_client/ui/transcript/code_block.dart';
import 'package:acp_agent_client/ui/transcript/mermaid_block.dart';
import 'package:acp_agent_client/ui/transcript/terminal_card.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_core.dart';

void main() {
  // Fonts / Theming 都是全局可变状态：每个用例跑完必须复位，否则会污染后面的用例与别的测试文件。
  tearDown(t.Fonts.reset);
  tearDown(t.Theming.reset);

  group('候选表', () {
    test('西文两轴与中文两轴的 family 不得有交集', () {
      // 这是整个分轴机制成立的前提：西文轴上出现含 CJK 字形的字体，它会把中文也吃掉，中文轴就失效了。
      final Set<String> latin = <String>{
        for (final FontChoice c in fontCatalog[FontAxis.uiLatin]!) c.family,
        for (final FontChoice c in fontCatalog[FontAxis.codeLatin]!) c.family,
      };
      final Set<String> cjk = <String>{
        for (final FontChoice c in fontCatalog[FontAxis.uiCjk]!) c.family,
        for (final FontChoice c in fontCatalog[FontAxis.codeCjk]!) c.family,
      };
      expect(latin.intersection(cjk), isEmpty, reason: '西文轴与中文轴的候选重叠了');
    });

    test('四个轴都有候选，且默认项在各自轴的候选里、来源是随包', () {
      for (final FontAxis axis in FontAxis.values) {
        final List<FontChoice> list = fontCatalog[axis]!;
        expect(list, isNotEmpty, reason: '$axis 没有候选');
        final Iterable<FontChoice> hit = list.where((FontChoice c) => c.family == defaultFamilyFor(axis));
        expect(hit.length, 1, reason: '$axis 的默认项应当在候选里且只有一条');
        expect(hit.first.source, FontSource.bundled, reason: '$axis 的默认项必须是随包的，否则装不上就没有兜底');
      }
    });

    test('optional 候选都给了探测用的文件名主干与下载去处', () {
      for (final MapEntry<FontAxis, List<FontChoice>> e in fontCatalog.entries) {
        for (final FontChoice c in e.value) {
          if (c.source != FontSource.optional) continue;
          expect(c.fileStems, isNotEmpty, reason: '${c.family} 没有 fileStems，永远探测不到');
          expect(c.downloadUrl, isNotNull, reason: '${c.family} 没有下载去处，用户装不上');
        }
      }
    });
  });

  group('FontPrefs', () {
    test('没设过的轴回默认，落盘形状里不出现该键', () {
      const FontPrefs p = FontPrefs();
      expect(p.raw(FontAxis.uiLatin), isNull);
      expect(p.resolved(FontAxis.uiLatin), t.Fonts.defaultSans);
      expect(p.resolved(FontAxis.uiCjk), t.Fonts.defaultCjk);
      expect(p.resolved(FontAxis.codeLatin), t.Fonts.defaultMono);
      expect(p.resolved(FontAxis.codeCjk), t.Fonts.defaultCjk);
      expect(p.toJson(), isEmpty);
    });

    test('选回默认项存的是 null 而不是默认名', () {
      // 这样以后改了默认字体，没动过设置的用户会跟着走。
      final FontPrefs p = const FontPrefs().withAxis(FontAxis.uiCjk, 'MiSans');
      expect(p.toJson(), <String, Object?>{'ui_cjk_font_family': 'MiSans'});
      final FontPrefs back = p.withAxis(FontAxis.uiCjk, t.Fonts.defaultCjk);
      expect(back.raw(FontAxis.uiCjk), isNull);
      expect(back.toJson(), isEmpty);
    });

    test('键名与 Rust 侧 Appearance 对得上，JSON 往返不掉字段', () {
      const FontPrefs p = FontPrefs(uiLatin: 'Inter', uiCjk: 'MiSans', codeLatin: 'JetBrains Mono', codeCjk: 'Sarasa Mono SC');
      expect(p.toJson(), <String, Object?>{
        'ui_font_family': 'Inter',
        'ui_cjk_font_family': 'MiSans',
        'buffer_font_family': 'JetBrains Mono',
        'buffer_cjk_font_family': 'Sarasa Mono SC',
      });
      expect(FontPrefs.fromJson(p.toJson()), p);
    });

    test('脏值当没设置：空串、纯空白、类型不对', () {
      final FontPrefs p = FontPrefs.fromJson(<String, Object?>{
        'ui_font_family': '',
        'ui_cjk_font_family': '   ',
        'buffer_font_family': 42,
        'buffer_cjk_font_family': '  Sarasa Mono SC  ',
      });
      expect(p.uiLatin, isNull);
      expect(p.uiCjk, isNull);
      expect(p.codeLatin, isNull);
      expect(p.codeCjk, 'Sarasa Mono SC', reason: '首尾空白要去掉');
    });
  });

  group('tokens 运行时生效', () {
    test('换轴之后字阶跟着换，界面轴与代码轴互不干扰', () {
      expect(t.TextStyles.body.fontFamily, t.Fonts.defaultSans);
      expect(t.TextStyles.mono.fontFamily, t.Fonts.defaultMono);

      t.Fonts.apply(sans: 'Inter', cjk: 'MiSans');
      expect(t.TextStyles.body.fontFamily, 'Inter');
      expect(t.TextStyles.body.fontFamilyFallback!.first, 'MiSans');
      // 代码轴没动，还是默认。
      expect(t.TextStyles.mono.fontFamily, t.Fonts.defaultMono);
      expect(t.TextStyles.mono.fontFamilyFallback!.first, t.Fonts.defaultCjk);

      t.Fonts.apply(mono: 'JetBrains Mono', codeCjk: 'Sarasa Mono SC');
      expect(t.TextStyles.mono.fontFamily, 'JetBrains Mono');
      expect(t.TextStyles.mono.fontFamilyFallback!.first, 'Sarasa Mono SC');
      expect(t.Kbd.text.fontFamilyFallback!.first, 'Sarasa Mono SC', reason: 'kbd 也是等宽档');
      // 界面轴不受代码轴影响。
      expect(t.TextStyles.body.fontFamilyFallback!.first, 'MiSans');
    });

    test('画板 43 的 labelTabular 也跟着界面轴走（并行分支合并接点）', () {
      // labelTabular 来自画板 43（会话时间线），合并进来时是 `static const TextStyle`——
      // 引用了已改成 getter 的 Fonts.sans，编译期就会拦住，所以一并并进 FontStyles。
      // 这条守住它不会在以后某次合并里被改回一次求值的写法。
      expect(t.TextStyles.labelTabular.fontFamily, t.Fonts.defaultSans);
      t.Fonts.apply(sans: 'Inter', cjk: 'MiSans');
      expect(t.TextStyles.labelTabular.fontFamily, 'Inter');
      expect(t.TextStyles.labelTabular.fontFamilyFallback!.first, 'MiSans');
      // 它是 label 档加 tabular-nums，不是新字阶：其余特征要和 label 一致。
      expect(t.TextStyles.labelTabular.fontSize, t.TextStyles.label.fontSize);
      expect(t.TextStyles.labelTabular.letterSpacing, t.TextStyles.label.letterSpacing);
      expect(t.TextStyles.labelTabular.fontFeatures, isNotEmpty);
    });

    test('回退链尾始终留着系统兜底', () {
      t.Fonts.apply(cjk: 'MiSans');
      expect(t.TextStyles.body.fontFamilyFallback, <String>['MiSans', ...t.Fonts.systemCjkFallback]);
    });

    test('同一套字体下取到的是同一个对象（`==` 短路与 const 时代一致）', () {
      final TextStyle a = t.TextStyles.body;
      final TextStyle b = t.TextStyles.body;
      expect(identical(a, b), isTrue);

      t.Fonts.apply(sans: 'Inter');
      expect(identical(t.TextStyles.body, a), isFalse, reason: '换了字体就该是新对象');
      expect(identical(t.TextStyles.body, t.TextStyles.body), isTrue);
    });

    test('apply 给同样的值返回 false，不触发无谓重建', () {
      expect(t.Fonts.apply(sans: t.Fonts.defaultSans), isFalse);
      expect(t.Fonts.apply(sans: 'Inter'), isTrue);
      expect(t.Fonts.apply(sans: 'Inter'), isFalse);
    });
  });

  group('派生字阶跟着换（R7.6 审查 high：static final 会把 family 冻在首次访问那一刻）', () {
    test('CardText 的各档跟着 Fonts.apply 走', () {
      // 应用里大部分文字（转录卡、终端、diff、弹层、按钮）走的是 CardText 而不是 TextStyles，
      // 只断言 TextStyles 会假通过——审查第 1 轮就是这么抓到的。
      expect(CardText.code.fontFamily, t.Fonts.defaultMono);
      expect(CardText.strong.fontFamily, t.Fonts.defaultSans);

      t.Fonts.apply(sans: 'Inter', cjk: 'MiSans', mono: 'JetBrains Mono', codeCjk: 'Sarasa Mono SC');

      expect(CardText.code.fontFamily, 'JetBrains Mono');
      expect(CardText.code.fontFamilyFallback!.first, 'Sarasa Mono SC');
      expect(CardText.inlineCode.fontFamily, 'JetBrains Mono');
      expect(CardText.subtitle.fontFamily, 'JetBrains Mono');
      expect(CardText.codeError.fontFamily, 'JetBrains Mono', reason: 'codeError 从 code 派生');
      expect(CardText.strong.fontFamily, 'Inter');
      expect(CardText.strong.fontFamilyFallback!.first, 'MiSans');
      expect(CardText.link.fontFamily, 'Inter');
      expect(CardText.cardTitle.fontFamily, 'Inter');
      expect(CardText.headerTitle.fontFamily, 'Inter');
      expect(CardText.secondary.fontFamily, 'Inter');
      expect(CardText.button.fontFamily, 'Inter');
      expect(CardText.buttonPrimary.fontFamily, 'Inter', reason: 'buttonPrimary 从 button 派生');
    });

    test('mermaid 主题的字体跟着界面西文轴走', () {
      expect(mermaidTokenTheme.fontFamily, t.Fonts.defaultSans);
      t.Fonts.apply(sans: 'Inter');
      expect(mermaidTokenTheme.fontFamily, 'Inter');
    });

    test('lib/ 里不得再出现会冻住 family 的样式缓存', () {
      // 这一条守的是「类」而不是「某一处」：只要谁再写一个一次求值的样式缓存，换字体就会对那一处
      // 不起作用，而且不会有任何报错——只能靠扫源码挡。
      //
      // 只认「带初始化式的 static final」与「顶层 final」这两种一次求值的写法。
      // 实例字段（`final TextStyle style;`，每个实例各一份）是好的，不在此列。
      //
      // 颜色也在内：画板 07 之后颜色 token 同样是 getter，把 Color / BoxShadow / 整张色表
      // 存成一次求值的缓存，换主题就对那一处不起作用（与冻住 family 是同一类 bug）。
      final Directory lib = Directory('lib');
      final RegExp frozen = RegExp(
        r'^(\s*static\s+final|final)\s+'
        r'(TextStyle|core\.MermaidTheme|Color|BoxShadow|List<Color>|Map<String, TextStyle>|xt\.TerminalTheme)'
        r'\s+\w+\s*=',
        multiLine: true,
      );
      final List<String> offenders = <String>[];
      for (final FileSystemEntity e in lib.listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final String src = e.readAsStringSync();
        for (final RegExpMatch m in frozen.allMatches(src)) {
          final int line = '\n'.allMatches(src.substring(0, m.start)).length + 1;
          offenders.add('${e.path}:$line  ${m.group(0)!.trim()}');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: '这些会把字体冻在首次访问那一刻，改成 getter：\n${offenders.join('\n')}',
      );
    });

    test('Fonts.generation 只在真的换了字体时 +1', () {
      // 带 family 的重计算（高亮 span、TextPainter 量出的宽高）贵到不能每帧现算，
      // 靠这个代数判断过期，见 lib/ui/files/files_panel.dart 的 _fontGeneration。
      final int g0 = t.Fonts.generation;
      t.Fonts.apply(sans: t.Fonts.defaultSans);
      expect(t.Fonts.generation, g0, reason: '值没变不该 +1');
      t.Fonts.apply(sans: 'Inter');
      expect(t.Fonts.generation, g0 + 1);
    });
  });

  group('可选字体探测', () {
    test('文件名规范化：大小写、连字符、下划线、扩展名都归一', () {
      expect(normalizeFileStem('MiSans-Regular.ttf'), 'misansregular');
      expect(normalizeFileStem('misans_regular.otf'), 'misansregular');
      expect(normalizeFileStem('HarmonyOS_Sans_SC_Regular.ttf'), 'harmonyossansscregular');
      expect(normalizeFileStem('noextension'), 'noextension');
    });

    test('系统目录里按文件名认出字体，只探测不注册', () async {
      final Directory dir = Directory.systemTemp.createTempSync('acp-fonts-probe');
      addTearDown(() => dir.deleteSync(recursive: true));
      // 内容无所谓：probe 路径只看文件名，不读字节、不往引擎里塞。
      File('${dir.path}${Platform.pathSeparator}MiSans-Regular.ttf').writeAsStringSync('not a real font');
      File('${dir.path}${Platform.pathSeparator}Sarasa-Mono-SC-Regular.ttf').writeAsStringSync('not a real font');
      File('${dir.path}${Platform.pathSeparator}SomethingElse.ttf').writeAsStringSync('not a real font');
      // .ttc 是字体集合，FontLoader 吃不下，不该被认出来。
      File('${dir.path}${Platform.pathSeparator}MiSans.ttc').writeAsStringSync('not a real font');

      final FontRegistry reg = FontRegistry(loadDirs: const <Directory>[], probeDirs: <Directory>[dir]);
      final Set<String> found = await reg.discoverAndLoad();

      expect(found, containsAll(<String>['MiSans', 'Sarasa Mono SC']));
      expect(found, isNot(contains('Inter')));
      expect(reg.isAvailable(fontCatalog[FontAxis.uiCjk]!.firstWhere((FontChoice c) => c.family == 'MiSans')), isTrue);
    });

    test('随包的永远可用，目录不存在也不报错', () async {
      final FontRegistry reg = FontRegistry(
        loadDirs: <Directory>[Directory('Z:${Platform.pathSeparator}no-such-dir')],
        probeDirs: <Directory>[Directory('Z:${Platform.pathSeparator}also-missing')],
      );
      final Set<String> found = await reg.discoverAndLoad();
      expect(found, isEmpty);
      final FontChoice bundled = fontCatalog[FontAxis.uiLatin]!.firstWhere((FontChoice c) => c.source == FontSource.bundled);
      expect(reg.isAvailable(bundled), isTrue);
      final FontChoice optional = fontCatalog[FontAxis.uiCjk]!.firstWhere((FontChoice c) => c.source == FontSource.optional);
      expect(reg.isAvailable(optional), isFalse);
    });
  });

  group('AppearanceController', () {
    test('没有桥时只在内存里生效，改轴会通知监听者', () async {
      final AppearanceController c = AppearanceController(
        registry: FontRegistry(loadDirs: const <Directory>[], probeDirs: const <Directory>[]),
      );
      addTearDown(c.dispose);
      int notified = 0;
      c.addListener(() => notified++);

      await c.start();
      // 扫描结果是设置页要用的状态，跟「选择有没有变」无关：哪怕四个轴都还是默认，
      // 也必须通知一次，否则设置页停在扫描前的「本机未找到」（所有者手测 2026-09-20 报障）。
      expect(notified, 1, reason: 'start() 扫完必须通知一次');

      await c.setAxis(FontAxis.uiCjk, 'MiSans');
      expect(notified, 2);
      expect(c.fonts.resolved(FontAxis.uiCjk), 'MiSans');
      expect(t.TextStyles.body.fontFamilyFallback!.first, 'MiSans');

      // 同一个值再设一次不重建。
      await c.setAxis(FontAxis.uiCjk, 'MiSans');
      expect(notified, 2);

      await c.resetAll();
      expect(notified, 3);
      expect(t.TextStyles.body.fontFamilyFallback!.first, t.Fonts.defaultCjk);
    });

    test('换主题：通知一次、tokens 换套、同值不重建', () async {
      final AppearanceController c = AppearanceController(
        registry: FontRegistry(loadDirs: const <Directory>[], probeDirs: const <Directory>[]),
      );
      addTearDown(c.dispose);
      int notified = 0;
      c.addListener(() => notified++);

      expect(c.theme, t.Theming.defaultMode);
      await c.toggleTheme();
      expect(notified, 1);
      expect(c.theme, t.AppTheme.dark);
      expect(t.Neutral.canvas, t.Theming.darkColors.canvas);
      expect(CardText.strong.color, t.Theming.darkColors.strong, reason: '派生字阶也要换套');

      // 已经是深色了，再设一次深色不重建。
      await c.setTheme(t.AppTheme.dark);
      expect(notified, 1);

      await c.toggleTheme();
      expect(notified, 2);
      expect(t.Neutral.canvas, t.Theming.lightColors.canvas);
    });

    test('读盘还没回来就点切换：不抹掉盘上已存的字体轴（发布前审查 high，2026-09-20）', () async {
      // 切换按钮首帧就能点，而 `start()` 要先扫一遍字体目录再读设置。这个窗口里 `_prefs` 还是空的，
      // 拿它算出来的全量快照四个字体轴都是缺省，而 `appearance` 段在 Rust 侧是**整段替换**的。
      final FakeCore core = FakeCore()..appearance = <String, dynamic>{'ui_font_family': 'Inter'};
      final Completer<void> gate = Completer<void>();
      core.appearanceGetGate = gate;
      final AppearanceController c = AppearanceController(
        bridge: core,
        registry: FontRegistry(loadDirs: const <Directory>[], probeDirs: const <Directory>[]),
      );
      addTearDown(c.dispose);

      final Future<void> starting = c.start();
      final Future<void> toggling = c.toggleTheme();
      expect(core.appearance, <String, dynamic>{'ui_font_family': 'Inter'}, reason: '读盘没回来之前不该写盘');

      gate.complete();
      await starting;
      await toggling;

      expect(c.theme, t.AppTheme.dark, reason: '用户那一下不能被读盘结果盖掉');
      expect(c.fonts.resolved(FontAxis.uiLatin), 'Inter', reason: '盘上已存的字体轴要留着');
      expect(core.appearance, <String, dynamic>{'ui_font_family': 'Inter', 'theme': 'dark'});
    });

    test('字体与主题一起改时两边都生效（别写成 `||` 短路）', () async {
      final AppearanceController c = AppearanceController(
        registry: FontRegistry(loadDirs: const <Directory>[], probeDirs: const <Directory>[]),
      );
      addTearDown(c.dispose);
      await c.setAxis(FontAxis.uiLatin, 'Inter');
      await c.setTheme(t.AppTheme.dark);
      expect(t.TextStyles.body.fontFamily, 'Inter');
      expect(t.Neutral.text, t.Theming.darkColors.text);
    });
  });

  group('主题（画板 07）', () {
    test('两套取值字段一一对应，没有漏项也没有深色专有项', () {
      // 画板 07 的规矩：一个浅色 token 名对应且只对应一个深色值。同一个类保证了字段集合相同，
      // 这里守的是「别偷懒把某一项在两套里写成同一个值」——除了本来就该相同的那几项。
      final t.ThemeColors l = t.Theming.lightColors;
      final t.ThemeColors d = t.Theming.darkColors;
      expect(l.canvas, isNot(d.canvas));
      expect(l.strong, isNot(d.strong));
      expect(l.accentBase, isNot(d.accentBase));
      expect(l.surfacePopover, isNot(d.surfacePopover));
      expect(l.overlayHover, isNot(d.overlayHover));
      // 画板 07 § 2.3 明写的同构：info = accent.base，info.soft = accent.soft，两套都成立。
      expect(l.info, l.accentBase);
      expect(d.info, d.accentBase);
      expect(l.infoSoft, l.accentSoft);
      expect(d.infoSoft, d.accentSoft);
      // § 2.5：浅色不画顶边提亮，取全透明（画法不分支）。
      expect(l.popoverTopHighlight.a, 0);
      expect(d.popoverTopHighlight.a, greaterThan(0));
    });

    test('Theming.apply 推进 Fonts.generation（字阶把颜色烘进去了）', () {
      final int g0 = t.Fonts.generation;
      t.Theming.apply(t.Theming.defaultMode);
      expect(t.Fonts.generation, g0, reason: '值没变不该 +1');
      t.Theming.apply(t.AppTheme.dark);
      expect(t.Fonts.generation, g0 + 1);
    });

    test('派生 token 跟着换套', () {
      t.Theming.apply(t.AppTheme.dark);
      expect(t.Borders.subtle, t.Theming.darkColors.borderSubtle);
      expect(t.Surface.popover, t.Theming.darkColors.surfacePopover);
      expect(t.Shadows.popover.color, t.Theming.darkColors.shadowPopover.color);
      expect(t.Overlays.selected, t.Overlays.active);
      expect(t.FocusRing.color, t.Theming.darkColors.accentBase);
      expect(t.Spinner.color, t.Theming.darkColors.accentBase);
      expect(t.Kbd.border, t.Theming.darkColors.border);
      expect(t.UnreadDot.color, t.Theming.darkColors.success);
      expect(t.Timeline.rail, t.Theming.darkColors.borderSubtle);
      expect(t.Timeline.nodeColor, t.Theming.darkColors.placeholder);
      expect(t.Sweep.track, t.Theming.darkColors.borderSubtle);
      // § 2.7：亮点渐变两端是 accent 的全透明版，不再硬编码某一套的 alpha 0 值。
      expect(t.Sweep.focusGradient[1], t.Theming.darkColors.accentBase);
      expect(t.Sweep.focusGradient.first.a, 0);
      expect(t.Sweep.focusGradient.first.r, t.Theming.darkColors.accentBase.r);
    });

    test('代码高亮与终端 ANSI 换套（画板 07 § 2.8 / § 2.9）', () {
      expect(codeHighlightTheme['keyword']!.color, t.Theming.lightColors.accentText);
      expect(terminalTokenTheme.background, t.Theming.lightColors.panel);

      t.Theming.apply(t.AppTheme.dark);

      expect(codeHighlightTheme['keyword']!.color, t.Theming.darkColors.accentText);
      expect(codeHighlightTheme['string']!.color, t.Theming.darkColors.success);
      expect(codeHighlightTheme['comment']!.color, t.Theming.darkColors.placeholder);
      expect(JsonHighlight.theme['attr']!.color, t.Theming.darkColors.accentText);
      // 黑 / 白两位是「反差最大的墨 / 等于背景」，不是照搬浅色值。
      expect(terminalTokenTheme.black, t.Theming.darkColors.strong);
      expect(terminalTokenTheme.white, t.Theming.darkColors.canvas);
      expect(terminalTokenTheme.brightBlack, t.Theming.darkColors.muted);
      expect(terminalTokenTheme.background, t.Theming.darkColors.panel);
      expect(terminalTokenTheme.cursor, t.Theming.darkColors.accentBase);
      expect(terminalTokenTheme.selection, t.Theming.darkColors.accentSoft);
      // 蓝与青不同色：蓝 = accent.base，青 = accent.text（画板 07 § 2.9 的列头）。
      expect(terminalTokenTheme.cyan, t.Theming.darkColors.accentText);
      expect(terminalTokenTheme.cyan, isNot(terminalTokenTheme.blue));
    });

    test('落盘形状：缺省档不落键，脏值当没设置过', () {
      expect(const AppearancePrefs().toJson(), isNot(contains('theme')));
      expect(const AppearancePrefs().resolvedTheme, t.Theming.defaultMode);

      const AppearancePrefs dark = AppearancePrefs(theme: t.AppTheme.dark);
      expect(dark.toJson()['theme'], 'dark');
      expect(AppearancePrefs.fromJson(dark.toJson()).theme, t.AppTheme.dark);

      // 选回缺省档存 null，不写死档名——以后改了缺省值，没动过设置的人会跟着走。
      expect(dark.withTheme(t.Theming.defaultMode).theme, isNull);

      expect(AppearancePrefs.fromJson(const <String, Object?>{'theme': '  DARK '}).theme, t.AppTheme.dark);
      expect(AppearancePrefs.fromJson(const <String, Object?>{'theme': 'system'}).theme, isNull);
      expect(AppearancePrefs.fromJson(const <String, Object?>{'theme': 7}).theme, isNull);
      expect(AppearancePrefs.fromJson(const <String, Object?>{}).theme, isNull);

      // 字体与主题同在 `appearance` 一段里，一次全给（Rust 侧整段替换）。
      final AppearancePrefs both = dark.withFonts(const FontPrefs().withAxis(FontAxis.uiLatin, 'Inter'));
      expect(both.toJson(), <String, Object?>{'ui_font_family': 'Inter', 'theme': 'dark'});
    });
  });
}
