// 壳的几何不变量，两类都是所有者手测（2026-09-16）报出来、gallery 逐张对照没拦住的：
//
// 一、「贴右」的三处装配：`Flexible` 与 `Spacer` 并列时两者 flex 都是 1，
// 余量被五五分，右侧那组就停在「内容与右边缘的中点」上——画板要的是 `margin-left:auto`（贴右）。
// 偏移量随窗口宽度与文本长度变，单看一张图不容易认出来，所以在这里钉死数值。
//
// 二、三列头两行的行高：分割线是横穿整窗的，侧栏搜索行与右栏标签条取了 `Controls.input`（32）、
//     顶栏与线程头取条高（36），两条分割线就各错开 4px。这条在静态图上更难看出来，同样钉住。

import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/shell/right_panel.dart';
import 'package:acp_agent_client/ui/shell/shell_common.dart';
import 'package:acp_agent_client/ui/shell/sidebar.dart';
import 'package:acp_agent_client/ui/shell/thread_header.dart';
import 'package:acp_agent_client/ui/shell/topbar.dart';
import 'package:acp_agent_client/ui/transcript/card_chrome.dart';
import 'package:acp_agent_client/ui/transcript/icons.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../gallery_harness.dart';

void main() {
  // 测试视口默认 800×600 逻辑像素，被测件必须放得下，否则量到的是被裁掉的位置。
  Future<void> pump(WidgetTester tester, Widget child, {required double width, double? height}) {
    return tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, height: height, child: child),
        ),
      ),
    );
  }

  group('线程头（画板 01）', () {
    const double width = 700;
    // ≡ 图标在 standard 见方的按钮里居中，所以动作组贴右时图标右边缘落在这里。
    const double iconRight = width - t.Spacing.s8 - (t.Controls.standard - t.IconSizes.toolbar) / 2;

    double menuIconRight(WidgetTester tester) => tester
        .getTopRight(find.byWidgetPredicate((w) => w is AcpIcon && w.body == AcpIcons.menuLines))
        .dx;

    testWidgets('动作组贴右，且不随标题长短移动', (tester) async {
      await pump(tester, const ThreadHeader(title: '短'), width: width, height: t.Geometry.barHeight);
      final short = menuIconRight(tester);
      expect(short, closeTo(iconRight, 0.5), reason: '画板 01 的动作组是 margin-left:auto，必须贴右');

      await pump(
        tester,
        const ThreadHeader(title: 'New DeepSeek Harness Thread · 一个很长很长的会话标题'),
        width: width,
        height: t.Geometry.barHeight,
      );
      expect(menuIconRight(tester), closeTo(short, 0.01), reason: '动作组的位置不该随标题长短变');
    });
  });

  group('右栏标签条（画板 03）', () {
    const double height = 400;

    // 标签条左右各留 s4 内边距（lib/ui/shell/right_panel.dart 的 `_tabBar`），窗口控制贴右就是右边缘落在这里。
    const double controlsRightEdge = t.Geometry.rightPanelWidth - t.Spacing.s4;

    double controlsRight(WidgetTester tester) => tester.getTopRight(find.byType(WindowControls)).dx;

    // 画板 03 原有的面板关闭键已废弃（所有者裁定 2026-09-17：右栏的「关」挪到侧栏底部导航）。
    // 这里守的是它走后剩下的不变量：窗口控制贴右、不随标签数量漂移，标签条上也不再冒出别的独立按钮。
    testWidgets('窗口控制贴右，不随标签数量漂移；面板关闭键不再出现', (tester) async {
      // 四个标签全开时标签条接近 580 的宽：flutter_tester 的占位字体每个字形都是方块（12px 的 "ACP Registry" 量成 144），
      // 会把 Row 撑溢出、窗口控制被顶出去；按真实字体量（R5 把 Agents 标签文案对齐画板 50 的「ACP Registry」后触发）。
      await tester.runAsync(loadGalleryFonts);
      await pump(
        tester,
        const RightPanel(tabs: <PanelTab>[PanelTab.shell(ShellTab.files)], active: PanelTab.shell(ShellTab.files)),
        width: t.Geometry.rightPanelWidth,
        height: height,
      );
      final one = controlsRight(tester);
      expect(one, closeTo(controlsRightEdge, 0.5), reason: '画板 03：窗口控制是 margin-left:auto，必须贴右');
      expect(find.byType(IconButtonGhost), findsNothing, reason: '面板关闭键已废弃，标签条上不该再有独立按钮');

      await pump(
        tester,
        const RightPanel(tabs: <PanelTab>[PanelTab.shell(ShellTab.settings), PanelTab.shell(ShellTab.files), PanelTab.shell(ShellTab.agents), PanelTab.shell(ShellTab.terminal)], active: PanelTab.shell(ShellTab.terminal)),
        width: t.Geometry.rightPanelWidth,
        height: height,
      );
      expect(controlsRight(tester), closeTo(one, 0.01), reason: '开几个标签都不该动窗口控制');
      expect(find.byType(IconButtonGhost), findsNothing);
    });
  });

  group('三列的头两行（画板 01–03）', () {
    testWidgets('两行各自等高：分割线横穿窗口时不会错台', (tester) async {
      final row1 = <String, double>{};
      await pump(tester, const SidebarTitleBar(), width: t.Geometry.sidebarWidth);
      row1['侧栏标题栏'] = tester.getSize(find.byType(SidebarTitleBar)).height;
      await pump(tester, const TopBar(projectName: 'deepseek-harness'), width: 700);
      row1['顶栏'] = tester.getSize(find.byType(TopBar)).height;
      await pump(
        tester,
        const RightPanel(tabs: <PanelTab>[PanelTab.shell(ShellTab.files)], active: PanelTab.shell(ShellTab.files)),
        width: t.Geometry.rightPanelWidth,
        height: 400,
      );
      // 标签条是 Column 的第一格，正文紧接其下——正文的顶就是标签条的高。
      row1['右栏标签条'] = tester.getTopLeft(find.byType(RightPanelPlaceholder)).dy;

      final controller = TextEditingController();
      final node = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(node.dispose);
      final row2 = <String, double>{};
      await pump(
        tester,
        SidebarSearchField(controller: controller, focusNode: node),
        width: t.Geometry.sidebarWidth,
      );
      row2['侧栏搜索'] = tester.getSize(find.byType(SidebarSearchField)).height;
      await pump(tester, const ThreadHeader(title: 'New Thread'), width: 700);
      row2['线程头'] = tester.getSize(find.byType(ThreadHeader)).height;

      expect(row1.values.toSet(), hasLength(1), reason: '第 1 条分割线由这三行的高度决定：$row1');
      expect(row2.values.toSet(), hasLength(1), reason: '第 2 条分割线：$row2');
      expect(row2.values.first, row1.values.first, reason: '两行同高，画板 01–03 都是条高：$row1 / $row2');
    });
  });

  group('卡片头（画板 18）', () {
    const double width = 600;
    const Key trailing = Key('trailing');
    // `padInput` 的右内边距就是 trailing 离右边缘的距离。
    final double expected = width - t.Controls.padInput.right;

    Future<double> trailingRight(WidgetTester tester, String subtitle) async {
      await pump(
        tester,
        CardHeader(
          title: 'Read file',
          subtitle: subtitle,
          trailing: const <Widget>[SizedBox(key: trailing, width: t.IconSizes.toolbar, height: t.IconSizes.toolbar)],
        ),
        width: width,
        height: t.Controls.input,
      );
      return tester.getTopRight(find.byKey(trailing)).dx;
    }

    testWidgets('trailing 贴右，不随副标题长短漂移', (tester) async {
      final short = await trailingRight(tester, 'a.md');
      final long = await trailingRight(tester, 'docs/acp-projection.md (lines 1-85) · 很长的一段副标题');
      expect(short, closeTo(expected, 0.5), reason: '画板 18 的三行状态卡 trailing 是对齐的');
      expect(long, closeTo(short, 0.01), reason: 'trailing 的位置不该随副标题长短变');
    });

    // 终端卡的头行标题就是整条命令（lib/ui/transcript/terminal_card.dart），一条 powershell 命令轻松过千像素：
    // 标题不是 Flexible 的时候，Row 给它的是无上限约束，它就原样铺出去、盖住状态图标与卡片右边框
    //（所有者手测 2026-09-17 报的「命令内容覆盖容器样式」）。
    testWidgets('标题超长时自己省略，不越过 trailing', (tester) async {
      await tester.runAsync(loadGalleryFonts);
      const String command =
          r'''powershell -Command "Get-ChildItem -Path $env:USERPROFILE\.codex -Recurse -Filter '*config*' -ErrorAction SilentlyContinue | Select-Object FullName"''';
      await pump(
        tester,
        const CardHeader(
          title: command,
          subtitle: r'D:\variFlight_work\AcpAgentClient',
          trailing: <Widget>[SizedBox(key: trailing, width: t.IconSizes.toolbar, height: t.IconSizes.toolbar)],
        ),
        width: width,
        height: t.Controls.input,
      );
      expect(
        tester.getTopRight(find.text(command)).dx,
        lessThanOrEqualTo(tester.getTopLeft(find.byKey(trailing)).dx),
        reason: '标题要在 trailing 之前省略掉',
      );
      expect(tester.getTopRight(find.byKey(trailing)).dx, closeTo(expected, 0.5), reason: 'trailing 仍旧贴右');
    });
  });
}
