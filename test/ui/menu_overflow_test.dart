// 弹层的两桩手测缺陷（所有者 2026-09-18）：
// ① `/` 与 `@` 菜单、以及输入框右下的模型选择器，高度不封顶也不能在内部滚 ——
//    命令装到几十条时菜单顶出窗口，下面的条目既看不见也选不中。
// ② 菜单只有「选中一条」才会消失：点页面空白不关，鼠标在别处点过之后连 Esc 都不再有反应
//    （那一下把焦点带离了输入框，键事件不再经过输入框的焦点链）。

import 'package:acp_agent_client/app/app.dart';
import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/app/workbench_screen.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/popovers/inline_menus.dart';
import 'package:acp_agent_client/ui/popovers/menu.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../app/fake_core.dart';
import '../gallery_harness.dart';

/// 装了一个 agent、有一个最近项目、项目根下有一打文件：`@` 菜单一敲就有东西可选。
class _Core extends FakeCore {
  @override
  Future<JsonMap> agentSettingsGet() async => <String, dynamic>{
        'agent_servers': <String, dynamic>{
          'codex': <String, dynamic>{'type': 'custom', 'command': 'codex-acp'},
        },
      };

  @override
  Future<JsonMap> workspaceRecent() async => <String, dynamic>{
        'projects': <Object?>[
          <String, dynamic>{'path': r'D:\proj', 'name': 'proj'},
        ],
      };

  @override
  Future<JsonMap> fsListDir(String root, String path) async => <String, dynamic>{
        'entries': <Object?>[
          for (var i = 0; i < 12; i++)
            <String, dynamic>{'path': 'D:\\proj\\f$i.dart', 'name': 'f$i.dart', 'parent': 'proj', 'isDir': false},
        ],
      };
}

void main() {
  Future<void> pumpMenu(WidgetTester tester, {required int rows, int selected = -1, MenuSearchField? search}) {
    return tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: MenuPopover(
            children: <Widget>[
              if (search != null) search,
              for (var i = 0; i < rows; i++) MenuRow(label: 'row $i', selected: i == selected, onTap: () {}),
            ],
          ),
        ),
      ),
    );
  }

  ScrollableState scrollerOf(WidgetTester tester) => tester.state<ScrollableState>(
        find.descendant(of: find.byType(MenuPopover), matching: find.byType(Scrollable)),
      );

  testWidgets('条目多到装不下时弹层封顶，并在内部滚动', (tester) async {
    await pumpMenu(tester, rows: 40);

    // Popover 自己的 padding 4 与 1px 边框在 [Geometry.menuMaxHeight] 之外。
    const double chrome = 2 * t.Spacing.s4 + 2 * t.Borders.width;
    expect(tester.getSize(find.byType(MenuPopover)).height, lessThanOrEqualTo(t.Geometry.menuMaxHeight + chrome));
    expect(scrollerOf(tester).position.maxScrollExtent, greaterThan(0), reason: '封顶之后必须能在弹层内部滚');
  });

  testWidgets('条目装得下时弹层还是按内容收窄（画板上那些三五行的菜单外观不变）', (tester) async {
    await pumpMenu(tester, rows: 3);

    expect(tester.getSize(find.byType(MenuPopover)).height, lessThan(t.Geometry.menuMaxHeight));
    expect(scrollerOf(tester).position.maxScrollExtent, 0);
  });

  testWidgets('高亮项在滚动区外时自动露出（键盘上下键走到下面的条目）', (tester) async {
    await pumpMenu(tester, rows: 40);
    expect(scrollerOf(tester).position.pixels, 0);

    await pumpMenu(tester, rows: 40, selected: 30);
    await tester.pumpAndSettle();

    expect(scrollerOf(tester).position.pixels, greaterThan(0));
    final menu = tester.getRect(find.byType(MenuPopover));
    final row = tester.getRect(find.text('row 30'));
    expect(menu.contains(row.topLeft) && menu.contains(row.bottomRight), isTrue, reason: '高亮项得落在可见区里');
  });

  testWidgets('搜索框钉在滚动区之外：滚动不挪它（敲字过滤时不会被推出视口）', (tester) async {
    final searchController = TextEditingController();
    final searchFocus = FocusNode();
    addTearDown(searchController.dispose);
    addTearDown(searchFocus.dispose);

    await pumpMenu(
      tester,
      rows: 40,
      search: MenuSearchField(controller: searchController, focusNode: searchFocus, placeholder: '搜索'),
    );
    // 这一条要排在下面那个 state 查找之前：搜索框被塞回滚动区时它连带 EditableText 的 Scrollable
    // 一起进去，下面的 finder 会先因命中两个而抛「Too many elements」，报错文本指向 finder 而不是
    // 真正回退的那条性质（复审 P3）。
    expect(
      find.descendant(of: find.byType(SingleChildScrollView), matching: find.byType(MenuSearchField)),
      findsNothing,
      reason: '搜索框不该在滚动区里',
    );
    // 搜索框自己带一个 Scrollable（EditableText），所以这里按 SingleChildScrollView 定位弹层那个。
    final body = tester.state<ScrollableState>(
      find.descendant(of: find.byType(SingleChildScrollView), matching: find.byType(Scrollable)),
    );
    final before = tester.getRect(find.byType(MenuSearchField));

    expect(body.position.maxScrollExtent, greaterThan(0), reason: '条目还是得能滚');
    body.position.jumpTo(body.position.maxScrollExtent);
    await tester.pump();

    expect(tester.getRect(find.byType(MenuSearchField)), before, reason: '搜索框不在滚动区里，滚到底也不该动');
  });

  testWidgets('点输入框之外关掉 `@` 菜单，鼠标点过之后 Esc 仍然管用', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(loadGalleryFonts);
    await tester.pumpWidget(AcpApp(source: DataSource.bridge, bridge: _Core()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final c = tester.widget<WorkbenchScreen>(find.byType(WorkbenchScreen)).controller;

    // 先按下鼠标把焦点从输入框挪走（所有者手测的那一步），再按 Esc。
    // `editor.text` 要跟着敲的内容一起给：产品里 `onChanged` 是 `EditableText` 写完 controller 才回调的，
    // 而 fs 结果回来时的过期判据就拿 `editor.text` 复核（留空的话结果会被判成过期丢掉）。
    c.composer.editor.text = '@';
    await c.composer.onChanged('@');
    await tester.pump();
    expect(find.byType(MentionMenu), findsOneWidget);
    await tester.tapAt(tester.getCenter(find.text('Files')));
    await tester.pump();
    expect(find.byType(MentionMenu), findsOneWidget, reason: '点在菜单自己身上不算「点外面」');
    // `flutter_test` 的 defaultTargetPlatform 是 android，而 `EditableText` 的「点外面失焦」只在桌面
    // 平台生效，所以上面那一下点不走焦点；显式挪走，让下面的 Esc 真落在「焦点不在输入框」这个前提上
    //（不然这桩用旧的「Esc 走输入框焦点链」实现也照样通过，锁不住那个回归）。
    c.composer.focus.unfocus();
    await tester.pump();
    expect(find.byType(MentionMenu), findsOneWidget, reason: '挪焦点本身不该关菜单，下面那一下必须是 Esc 关的');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(MentionMenu), findsNothing, reason: '焦点已不在输入框，Esc 也得关掉菜单');

    // 点页面空白（转录区）：直接关。
    c.composer.editor.text = '@';
    await c.composer.onChanged('@');
    await tester.pump();
    expect(find.byType(MentionMenu), findsOneWidget);
    await tester.tapAt(const Offset(700, 200));
    await tester.pump();
    expect(find.byType(MentionMenu), findsNothing);
  });
}
