// 「贴右」的三处装配（所有者手测 2026-09-16 报的按钮位置）：`Flexible` 与 `Spacer` 并列时两者 flex 都是 1，
// 余量被五五分，右侧那组就停在「内容与右边缘的中点」上——画板要的是 `margin-left:auto`（贴右）。
// gallery 对照没拦住它：偏移量随窗口宽度与文本长度变，单看一张图不容易认出来，所以在这里钉死数值。

import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/shell/right_panel.dart';
import 'package:acp_agent_client/ui/shell/shell_common.dart';
import 'package:acp_agent_client/ui/shell/thread_header.dart';
import 'package:acp_agent_client/ui/shell/topbar.dart';
import 'package:acp_agent_client/ui/transcript/card_chrome.dart';
import 'package:acp_agent_client/ui/transcript/icons.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 测试视口默认 800×600 逻辑像素，被测件必须放得下，否则量到的是被裁掉的位置。
  Future<void> pump(WidgetTester tester, Widget child, {required double width, required double height}) {
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

    double closeRight(WidgetTester tester) => tester.getTopRight(find.byType(IconButtonGhost)).dx;
    double controlsLeft(WidgetTester tester) => tester.getTopLeft(find.byType(WindowControls)).dx;

    testWidgets('面板关闭键紧挨窗口控制，不随标签数量漂移', (tester) async {
      await pump(
        tester,
        const RightPanel(tabs: <ShellTab>[ShellTab.files], active: ShellTab.files),
        width: t.Geometry.rightPanelWidth,
        height: height,
      );
      final one = closeRight(tester);
      expect(one, closeTo(controlsLeft(tester), 0.5), reason: '画板 03：关闭键与窗口控制之间没有空档');

      await pump(
        tester,
        const RightPanel(tabs: ShellTab.values, active: ShellTab.terminal),
        width: t.Geometry.rightPanelWidth,
        height: height,
      );
      expect(closeRight(tester), closeTo(controlsLeft(tester), 0.5));
      expect(closeRight(tester), closeTo(one, 0.01), reason: '开几个标签都不该动关闭键');
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
  });
}
