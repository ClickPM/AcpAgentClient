// 无边框窗口的拖拽区（docs/design.md § 9，审查 finding P2）：拖拽层铺在顶栏容器**里面**、控件行**下面**，
// 空白处的 pointer 落到它上面去调 `startDragging`，按钮与芯片照常先吃掉自己的。
// 垫在顶栏外面是不行的：`BoxDecoration.hitTest` 对矩形一律返回 true，那层 Container 会把 pointer 全吃掉。
// 这个装配只有跑起来才看得出对不对（任务卡里 GUI 那一半没法自动化），所以在这里钉死。

import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/shell/topbar.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 测试视口默认 800×600 逻辑像素，顶栏宽度必须放得下，否则点在视口外、根本没有命中。
  const double width = 700;

  /// 与 `lib/app/workbench_screen.dart` 的 `_topBar()` 同一种装配。
  Future<List<Offset>> pumpAndTap(WidgetTester tester, List<Offset> points, {String? branch}) async {
    final dragged = <Offset>[];
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: t.Geometry.barHeight,
            child: TopBar(
              projectName: 'deepseek-harness',
              branch: branch,
              onToggleSidebar: () {},
              onProject: () {},
              onBranch: () {},
              onMinimize: () {},
              onMaximize: () {},
              onClose: () {},
              dragArea: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (e) => dragged.add(e.localPosition),
              ),
            ),
          ),
        ),
      ),
    );
    for (final p in points) {
      await tester.tapAt(p);
      await tester.pump();
    }
    return dragged;
  }

  testWidgets('顶栏空白处的 pointer 落到下层 Listener（拖拽窗口）', (tester) async {
    // 项目名与分支挤在左侧、窗口控制在右侧，中间那一大片是空的。
    final x = width - t.Geometry.windowButtonWidth * 3 - t.Spacing.s24;
    final dragged = await pumpAndTap(tester, <Offset>[Offset(x, t.Geometry.barHeight / 2)], branch: 'main');
    expect(dragged, hasLength(1), reason: '空白处必须能拖窗口');
  });

  testWidgets('顶栏上的控件自己吃掉 pointer（不会误触发拖拽）', (tester) async {
    // 折叠开关（左起 8 + 12）、项目名芯片、窗口控制中间那一格。
    final toggle = Offset(t.Spacing.s8 + t.Controls.compact / 2, t.Geometry.barHeight / 2);
    final project = Offset(t.Spacing.s8 + t.Controls.compact + t.Spacing.s4 + t.Spacing.s24, t.Geometry.barHeight / 2);
    final maximize = Offset(width - t.Geometry.windowButtonWidth * 1.5, t.Geometry.barHeight / 2);
    final dragged = await pumpAndTap(tester, <Offset>[toggle, project, maximize], branch: 'main');
    expect(dragged, isEmpty, reason: '按钮与芯片上的点击不该变成拖拽');
  });
}
