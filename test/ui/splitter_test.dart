// 画板 04 的分栏把手（所有者裁定 2026-09-16）。三件事只有跑起来才看得出对不对，钉在这里：
// 把手压在分栏线上（不是挨着它）、拖多少宽多少（夹取在组合根，不在 widget）、松手只落一次盘。
// 另外钉住「窗口装不下就先压右栏、再压侧栏」——不夹的话 Row 会直接溢出。

import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/shell/app_shell.dart';
import 'package:acp_agent_client/ui/shell/splitter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('侧栏把手：压在分栏线上、拖多少宽多少、松手落一次', (tester) async {
    double side = t.Geometry.sidebarWidth;
    var ends = 0;
    var resets = 0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: StatefulBuilder(
          builder: (context, setState) => AppShell(
            sidebar: const SizedBox.shrink(),
            main: const SizedBox.shrink(),
            sidebarWidth: side,
            onResizeSidebar: (d) => setState(() => side += d),
            onResizeEnd: () => ends++,
            onResetSidebar: () => resets++,
          ),
        ),
      ),
    );

    final splitter = find.byType(ColumnSplitter);
    expect(splitter, findsOneWidget, reason: '右栏没展开时只有一条把手');
    // 外框自绘 1px 边框，所以分栏线在 1 + 侧栏宽 上；把手中心必须正好压在那里。
    expect(tester.getCenter(splitter).dx, closeTo(t.Borders.width + side, 0.01));
    expect(tester.getSize(splitter).width, t.Geometry.splitterHit);

    // 触屏横扫不该拖分栏，所以把手只认鼠标 / 触控笔——测试也得用鼠标。
    await _dragBy(tester, tester.getCenter(splitter), 60);
    await tester.pump();
    expect(side, closeTo(t.Geometry.sidebarWidth + 60, 0.01), reason: 'widget 只报位移，不自己夹');
    expect(ends, 1, reason: '一次拖拽落一次盘');
    expect(tester.getCenter(splitter).dx, closeTo(t.Borders.width + side, 0.01), reason: '把手跟着分栏线走');

    await _doubleTap(tester, tester.getCenter(splitter));
    expect(resets, 1, reason: '双击复位');
    expect(ends, 1, reason: '双击不是拖拽，不该再落一次');
  });

  testWidgets('右栏把手：往右拖是变窄（组合根收到的是该栏宽度的增量）', (tester) async {
    double right = t.Geometry.rightPanelWidth;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: StatefulBuilder(
          builder: (context, setState) => AppShell(
            main: const SizedBox.shrink(),
            rightPanel: const SizedBox.shrink(),
            rightPanelWidth: right,
            onResizeRightPanel: (d) => setState(() => right += d),
            // 双击复位也接上：有它才有手势竞技场，越过 slop 的那一小段才会被吞掉（与组合根一致）。
            onResetRightPanel: () {},
          ),
        ),
      ),
    );

    await _dragBy(tester, tester.getCenter(find.byType(ColumnSplitter)), 40);
    await tester.pump();
    expect(right, closeTo(t.Geometry.rightPanelWidth - 40, 0.01));
    // 每次 pointer down 都会给双击识别器起一个 40ms 的计时器，跑完它再收尾。
    await tester.pump(kDoubleTapTimeout);
  });

  group('窗口装不下时的夹取（AppShell._fit）', () {
    const Key sideKey = Key('sidebar');
    const Key rightKey = Key('rightPanel');

    Future<(double, double)> pumpAt(WidgetTester tester, double viewport, double side, double right) async {
      tester.view.physicalSize = Size(viewport, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: AppShell(
            sidebar: const SizedBox.expand(key: sideKey),
            main: const SizedBox.shrink(),
            rightPanel: const SizedBox.expand(key: rightKey),
            sidebarWidth: side,
            rightPanelWidth: right,
          ),
        ),
      );
      return (tester.getSize(find.byKey(sideKey)).width, tester.getSize(find.byKey(rightKey)).width);
    }

    testWidgets('只差一点时只压右栏，侧栏一动不动', (tester) async {
      // 内宽 = 1200 − 2（外框）= 1198；缺省两栏加中栏下限 = 280 + 580 + 360 = 1220，差 22。
      // 压缩顺序写反的话让位的就是侧栏，所以这两条断言钉的正是「先右后左」。
      final (side, right) = await pumpAt(tester, 1200, t.Geometry.sidebarWidth, t.Geometry.rightPanelWidth);
      expect(side, closeTo(t.Geometry.sidebarWidth, 0.01), reason: '还轮不到压侧栏');
      expect(right, closeTo(t.Geometry.rightPanelWidth - 22, 0.01), reason: '差多少右栏让多少');
      expect(tester.takeException(), isNull);
    });

    testWidgets('右栏压到下限还不够，才接着压侧栏', (tester) async {
      final (side, right) = await pumpAt(tester, 800, t.Geometry.sidebarMaxWidth, t.Geometry.rightPanelMaxWidth);
      expect(right, closeTo(t.Geometry.rightPanelMinWidth, 0.01), reason: '右栏先压到下限');
      expect(side, closeTo(t.Geometry.sidebarMinWidth, 0.01), reason: '还不够就接着压侧栏');
      expect(tester.takeException(), isNull, reason: '压不下也不能溢出');
    });
  });
}

/// 越过 slop 的那一小段会被当成拖拽起点、不计入 `onUpdate`（`DragStartBehavior.start`），
/// 所以先走 4px 把 slop 用掉，再走要测的位移——这样报出来的就是干净的 1:1。
Future<void> _dragBy(WidgetTester tester, Offset from, double dx) async {
  final gesture = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
  await gesture.moveBy(const Offset(4, 0));
  await gesture.moveBy(Offset(dx, 0));
  await gesture.up();
}

Future<void> _doubleTap(WidgetTester tester, Offset at) async {
  final first = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
  await first.up();
  await tester.pump(kDoubleTapMinTime);
  final second = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
  await second.up();
  await tester.pump(kDoubleTapTimeout);
}
