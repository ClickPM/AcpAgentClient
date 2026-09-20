// 画板 70「外观」小节：四个字体轴的下拉。
//
// 建**真的 SettingsPage**、点真的按钮，不做「断言投影层标志」那种空测（同 settings_builtin_test 的口径）。
// 重点是两条：① 下拉里出现的是这一轴的候选、且西文轴里不会冒出中文字体；② 选中后 tokens 真的换了。

import 'dart:io';

import 'package:acp_agent_client/app/font_prefs.dart';
import 'package:acp_agent_client/projection/registry.dart';
import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/settings/settings_page.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 不碰磁盘的 registry：本机「什么可选字体都没装」，这样候选的可用态是确定的。
FontRegistry _emptyRegistry() => FontRegistry(loadDirs: const <Directory>[], probeDirs: const <Directory>[]);

Future<void> _pump(WidgetTester tester, FontPrefsController fonts) => tester.pumpWidget(
  Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: const MediaQueryData(size: Size(1200, 900)),
      child: Overlay(
        initialEntries: <OverlayEntry>[
          OverlayEntry(
            builder: (BuildContext context) =>
                SettingsPage(agents: const <RegistryEntryData>[], dataDir: r'C:\data', fonts: fonts),
          ),
        ],
      ),
    ),
  ),
);

void main() {
  tearDown(t.Fonts.reset);

  testWidgets('四个轴各一行，默认显示随包字体', (WidgetTester tester) async {
    final FontPrefsController fonts = FontPrefsController(registry: _emptyRegistry());
    addTearDown(fonts.dispose);
    await _pump(tester, fonts);

    for (final FontAxis axis in FontAxis.values) {
      expect(find.text(axis.label), findsOneWidget, reason: '${axis.label} 这一行没画出来');
    }
    // 默认：界面 Geist / Noto Sans SC，代码 Geist Mono / Noto Sans SC。
    expect(find.text('Geist'), findsWidgets);
    expect(find.text('Geist Mono'), findsWidgets);
  });

  testWidgets('界面中文的下拉里有 MiSans 与 HarmonyOS，且不含任何西文候选', (WidgetTester tester) async {
    final FontPrefsController fonts = FontPrefsController(registry: _emptyRegistry());
    addTearDown(fonts.dispose);
    await _pump(tester, fonts);

    // 点「界面中文」那一行的触发按钮：它显示当前值 Noto Sans SC 的 label。
    await tester.tap(find.text('Noto Sans SC 思源黑体').first);
    await tester.pumpAndSettle();

    expect(find.text('MiSans 小米兰亭'), findsOneWidget);
    expect(find.text('HarmonyOS Sans 鸿蒙黑体'), findsOneWidget);
    // 西文候选绝不该出现在中文轴的菜单里（分轴机制成立的前提）。
    expect(find.text('Inter'), findsNothing);
    expect(find.text('JetBrains Mono'), findsNothing);
  });

  testWidgets('选中 MiSans 之后界面档的中文回退首项跟着换，代码档不受影响', (WidgetTester tester) async {
    final FontPrefsController fonts = FontPrefsController(registry: _emptyRegistry());
    addTearDown(fonts.dispose);
    await _pump(tester, fonts);

    await tester.tap(find.text('Noto Sans SC 思源黑体').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('MiSans 小米兰亭'));
    await tester.pumpAndSettle();

    expect(fonts.prefs.resolved(FontAxis.uiCjk), 'MiSans');
    expect(t.TextStyles.body.fontFamilyFallback!.first, 'MiSans');
    // 代码等宽中文是另一根轴，没动。
    expect(t.TextStyles.mono.fontFamilyFallback!.first, t.Fonts.defaultCjk);
  });

  testWidgets('本机没有的字体选中后给出回退提示与「去下载」', (WidgetTester tester) async {
    final FontPrefsController fonts = FontPrefsController(registry: _emptyRegistry());
    addTearDown(fonts.dispose);
    final List<String> opened = <String>[];
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(1200, 900)),
          child: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (BuildContext context) => SettingsPage(
                  agents: const <RegistryEntryData>[],
                  dataDir: r'C:\data',
                  fonts: fonts,
                  onOpenUrl: opened.add,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await fonts.setAxis(FontAxis.uiCjk, 'MiSans');
    await tester.pumpAndSettle();

    expect(find.textContaining('本机未找到这款字体'), findsOneWidget);
    await tester.tap(find.text('去下载'));
    await tester.pumpAndSettle();
    expect(opened.single, contains('hyperos.mi.com'));
  });

  testWidgets('不给 fonts 时整个「外观」小节不出现（gallery / 单测口径）', (WidgetTester tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(size: Size(1200, 900)),
          child: SettingsPage(agents: <RegistryEntryData>[], dataDir: r'C:\data'),
        ),
      ),
    );
    expect(find.text('外观'), findsNothing);
    expect(find.text(FontAxis.uiLatin.label), findsNothing);
  });
}
