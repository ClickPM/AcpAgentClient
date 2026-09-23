// 画板 07 · 侧栏标题条右端的主题切换按钮：浅色 → 深色 → 跟随系统三档循环。
//
// 建**真的 Sidebar** + 真的 [AppearanceController]、点真的按钮（同 appearance_card_test 的口径）：
// 重点是四条：① 按钮显示的是**当前**那一档（太阳 / 月亮 / 显示器），每档都有悬停文案；② 点一下 tokens
// 真的换套、界面跟着重建；③ 跟随系统时系统一切换界面就跟着换；④ 不给回调时不画按钮（画板 01–04 的对照页要保持原样）。

import 'dart:io';

import 'package:acp_agent_client/app/appearance_prefs.dart';
import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/shell/app_logo.dart';
import 'package:acp_agent_client/ui/shell/sidebar.dart';
import 'package:acp_agent_client/ui/shell/tooltip.dart';
import 'package:acp_agent_client/ui/transcript/icons.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

/// 不碰磁盘的 registry：用例只关心主题，不想让字体扫描去读系统目录。
AppearanceController _controller({Brightness platformBrightness = Brightness.light}) => AppearanceController(
  registry: FontRegistry(loadDirs: const <Directory>[], probeDirs: const <Directory>[]),
  platformBrightness: platformBrightness,
);

/// 按钮三档的图标：任一时刻标题条里只该有其中一个。
const List<String> _themeIcons = <String>[AcpIcons.sun, AcpIcons.moon, AcpIcons.monitor];

/// 包着某个图标按钮的那层 [AcpTooltip] 的文案。
String _tooltipOf(WidgetTester tester, String icon) => tester
    .widget<AcpTooltip>(find.ancestor(of: _inTitleBar(_icon(icon)), matching: find.byType(AcpTooltip)))
    .message;

Finder _icon(String body) =>
    find.byWidgetPredicate((Widget w) => w is AcpIcon && w.body == body, description: 'AcpIcon(body)');

/// [AppLogo.document] 里写进 SVG 的 `#RRGGBB` 形式。
String _hex(Color c) => '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

/// 侧栏底部导航里的「设置」也是齿轮，这里按标题条那一段找，避免撞名。
Finder _inTitleBar(Finder f) => find.descendant(of: find.byType(SidebarTitleBar), matching: f);

void main() {
  tearDown(t.Fonts.reset);
  tearDown(t.Theming.reset);

  Future<void> pumpSidebar(WidgetTester tester, {AppearanceController? appearance}) {
    final TextEditingController search = TextEditingController();
    final FocusNode focus = FocusNode();
    addTearDown(search.dispose);
    addTearDown(focus.dispose);
    Widget sidebar(BuildContext _) => Sidebar(
      sessions: const <SidebarSession>[],
      now: DateTime(2026, 9, 20),
      searchController: search,
      searchFocusNode: focus,
      themeChoice: appearance?.themeChoice ?? t.Theming.defaultChoice,
      dark: appearance?.theme == t.AppTheme.dark,
      onCycleTheme: appearance?.cycleTheme,
    );
    return tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(1200, 900)),
          child: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (BuildContext context) => appearance == null
                    ? sidebar(context)
                    // 组合根是在最外层监听控制器重建整棵树的（lib/app/app.dart），这里照同一个装配。
                    : ListenableBuilder(listenable: appearance, builder: (BuildContext c, Widget? _) => sidebar(c)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('三档循环：太阳 → 月亮 → 显示器 → 太阳，每档都有悬停文案', (WidgetTester tester) async {
    final AppearanceController appearance = _controller(platformBrightness: Brightness.dark);
    addTearDown(appearance.dispose);
    await pumpSidebar(tester, appearance: appearance);

    void expectOnly(String icon, String tooltip) {
      for (final String other in _themeIcons) {
        expect(
          _inTitleBar(_icon(other)),
          other == icon ? findsOneWidget : findsNothing,
          reason: '当前该出 ${_themeIcons.indexOf(icon)} 号图标，查的是 ${_themeIcons.indexOf(other)} 号',
        );
      }
      expect(_tooltipOf(tester, icon), tooltip);
    }

    expectOnly(AcpIcons.sun, 'Light mode · Switch to dark mode');
    expect(t.Neutral.panel, t.Theming.lightColors.panel, reason: '缺省手选浅色，系统是深色也不跟');

    await tester.tap(_inTitleBar(_icon(AcpIcons.sun)));
    await tester.pumpAndSettle();
    expect(appearance.themeChoice, t.ThemeChoice.dark);
    expect(t.Neutral.panel, t.Theming.darkColors.panel, reason: 'tokens 要真的换套');
    expectOnly(AcpIcons.moon, 'Dark mode · Switch to system mode');

    await tester.tap(_inTitleBar(_icon(AcpIcons.moon)));
    await tester.pumpAndSettle();
    expect(appearance.themeChoice, t.ThemeChoice.system);
    expect(t.Neutral.panel, t.Theming.darkColors.panel, reason: '系统眼下是深色');
    expectOnly(AcpIcons.monitor, 'System mode (dark) · Switch to light mode');

    await tester.tap(_inTitleBar(_icon(AcpIcons.monitor)));
    await tester.pumpAndSettle();
    expect(appearance.themeChoice, t.ThemeChoice.light);
    expect(t.Neutral.panel, t.Theming.lightColors.panel);
    expectOnly(AcpIcons.sun, 'Light mode · Switch to dark mode');
  });

  testWidgets('跟随系统：系统一切换界面就跟着换套，按钮与文案跟着走', (WidgetTester tester) async {
    final AppearanceController appearance = _controller();
    addTearDown(appearance.dispose);
    await appearance.setTheme(t.ThemeChoice.system);
    await pumpSidebar(tester, appearance: appearance);

    expect(t.Neutral.panel, t.Theming.lightColors.panel);
    expect(_tooltipOf(tester, AcpIcons.monitor), 'System mode (light) · Switch to light mode');

    appearance.setPlatformBrightness(Brightness.dark);
    await tester.pumpAndSettle();

    expect(t.Neutral.panel, t.Theming.darkColors.panel);
    expect(_inTitleBar(_icon(AcpIcons.monitor)), findsOneWidget, reason: '选择没变，还是跟随系统');
    expect(_tooltipOf(tester, AcpIcons.monitor), 'System mode (dark) · Switch to light mode');
  });

  testWidgets('侧栏底色跟着主题走', (WidgetTester tester) async {
    final AppearanceController appearance = _controller();
    addTearDown(appearance.dispose);
    await pumpSidebar(tester, appearance: appearance);

    Color panelOf() {
      final Container box = tester.widget<Container>(find.byType(Container).first);
      return ((box.decoration! as BoxDecoration).color)!;
    }

    expect(panelOf(), t.Theming.lightColors.panel);
    await tester.tap(_inTitleBar(_icon(AcpIcons.sun)));
    await tester.pumpAndSettle();
    expect(panelOf(), t.Theming.darkColors.panel);
  });

  testWidgets('不给回调就不画这个按钮', (WidgetTester tester) async {
    await pumpSidebar(tester);
    for (final String icon in _themeIcons) {
      expect(_inTitleBar(_icon(icon)), findsNothing);
    }
  });

  // 应用标记把当前主题的颜色烘进了 SVG 文本，所以它必须跟着换主题重建。踩过的坑：调用点写成
  // `const AppLogo()` 时，父级重建会因为 `identical(old, new)` 直接复用旧 element、不再 build，
  // 标记就冻在首次构建那一套颜色上——深色下是黑底黑标（2026-09-20 所有者报障）。
  testWidgets('应用标记跟着主题换色，不冻在首次构建那一套上', (WidgetTester tester) async {
    final AppearanceController appearance = _controller();
    addTearDown(appearance.dispose);
    await pumpSidebar(tester, appearance: appearance);

    BytesLoader logo() => tester
        .widget<SvgPicture>(find.descendant(of: find.byType(AppLogo), matching: find.byType(SvgPicture)))
        .bytesLoader;

    final String lightDoc = AppLogo.document();
    expect(logo(), SvgStringLoader(lightDoc));

    await tester.tap(_inTitleBar(_icon(AcpIcons.sun)));
    await tester.pumpAndSettle();

    final String darkDoc = AppLogo.document();
    expect(darkDoc, isNot(lightDoc), reason: '两套主题的标记本来就该不同色，否则下一条断言恒真');
    expect(darkDoc, contains(_hex(t.Theming.darkColors.strong)), reason: '深色下标记取 d.strong（浅底上的深标记翻过来）');
    expect(logo(), SvgStringLoader(darkDoc), reason: '冻住的话这里还是 lightDoc');
  });
}
