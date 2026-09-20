// 画板 07 · 侧栏标题条右端的浅色 / 深色切换按钮。
//
// 建**真的 Sidebar** + 真的 [AppearanceController]、点真的按钮（同 appearance_card_test 的口径）：
// 重点是三条：① 按钮显示的是「切过去」的那一档；② 点一下 tokens 真的换套、界面跟着重建；
// ③ 不给回调时不画按钮（画板 01–04 的对照页要保持原样）。

import 'dart:io';

import 'package:acp_agent_client/app/appearance_prefs.dart';
import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/shell/app_logo.dart';
import 'package:acp_agent_client/ui/shell/sidebar.dart';
import 'package:acp_agent_client/ui/transcript/icons.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

/// 不碰磁盘的 registry：用例只关心主题，不想让字体扫描去读系统目录。
AppearanceController _controller() => AppearanceController(
  registry: FontRegistry(loadDirs: const <Directory>[], probeDirs: const <Directory>[]),
);

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
      dark: appearance?.theme == t.AppTheme.dark,
      onToggleTheme: appearance?.toggleTheme,
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

  testWidgets('浅色下出月亮，点一下换成深色并出太阳', (WidgetTester tester) async {
    final AppearanceController appearance = _controller();
    addTearDown(appearance.dispose);
    await pumpSidebar(tester, appearance: appearance);

    expect(_inTitleBar(_icon(AcpIcons.moon)), findsOneWidget, reason: '按钮显示的是切过去的那一档');
    expect(_inTitleBar(_icon(AcpIcons.sun)), findsNothing);

    await tester.tap(_inTitleBar(_icon(AcpIcons.moon)));
    await tester.pumpAndSettle();

    expect(appearance.theme, t.AppTheme.dark);
    expect(t.Neutral.panel, t.Theming.darkColors.panel, reason: 'tokens 要真的换套');
    expect(_inTitleBar(_icon(AcpIcons.sun)), findsOneWidget);
    expect(_inTitleBar(_icon(AcpIcons.moon)), findsNothing);

    await tester.tap(_inTitleBar(_icon(AcpIcons.sun)));
    await tester.pumpAndSettle();

    expect(appearance.theme, t.AppTheme.light);
    expect(t.Neutral.panel, t.Theming.lightColors.panel);
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
    await tester.tap(_inTitleBar(_icon(AcpIcons.moon)));
    await tester.pumpAndSettle();
    expect(panelOf(), t.Theming.darkColors.panel);
  });

  testWidgets('不给回调就不画这个按钮', (WidgetTester tester) async {
    await pumpSidebar(tester);
    expect(_inTitleBar(_icon(AcpIcons.moon)), findsNothing);
    expect(_inTitleBar(_icon(AcpIcons.sun)), findsNothing);
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

    await tester.tap(_inTitleBar(_icon(AcpIcons.moon)));
    await tester.pumpAndSettle();

    final String darkDoc = AppLogo.document();
    expect(darkDoc, isNot(lightDoc), reason: '两套主题的标记本来就该不同色，否则下一条断言恒真');
    expect(darkDoc, contains(_hex(t.Theming.darkColors.strong)), reason: '深色下标记取 d.strong（浅底上的深标记翻过来）');
    expect(logo(), SvgStringLoader(darkDoc), reason: '冻住的话这里还是 lightDoc');
  });
}
