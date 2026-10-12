// 输入框超长内容封顶与内部滚动测试（所有者报障）：
// ① 输入内容过多时，文本区高度封顶在 [t.Geometry.composerInputMaxHeight]，不再无上限撑满屏幕；
// ② 内容不足上限时按内容自适应高度（不低于最小高度）；
// ③ 超长内容在输入框内部可滚动查看（支持鼠标滚轮与拖拽滚动）。

import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/shell/composer.dart';
import 'package:acp_agent_client/ui/shell/shell_common.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpComposer(
    WidgetTester tester, {
    required TextEditingController controller,
    required FocusNode focusNode,
  }) {
    return tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Overlay(
          initialEntries: <OverlayEntry>[
            OverlayEntry(
              builder: (context) => Align(
                alignment: Alignment.bottomCenter,
                child: Composer(
                  controller: controller,
                  focusNode: focusNode,
                  placeholder: 'Message to Agent',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  ScrollableState scrollerOf(WidgetTester tester) => tester.state<ScrollableState>(
        find.descendant(of: find.byType(AcpTextField), matching: find.byType(Scrollable)),
      );

  testWidgets('短内容时输入框按内容高度展示，不产生内部滚动', (tester) async {
    final controller = TextEditingController(text: '第一行\n第二行');
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await pumpComposer(tester, controller: controller, focusNode: focusNode);

    final fieldSize = tester.getSize(find.byType(AcpTextField));
    expect(fieldSize.height, lessThan(t.Geometry.composerInputMaxHeight));
    expect(scrollerOf(tester).position.maxScrollExtent, 0);
  });

  testWidgets('超长内容时输入框高度封顶在 composerInputMaxHeight，且内部可滚动查看', (tester) async {
    final longText = List<String>.generate(40, (i) => '第 ${i + 1} 行：这是一段用于验证输入框高度封顶与内部滚动的测试内容。').join('\n');
    final controller = TextEditingController(text: longText);
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await pumpComposer(tester, controller: controller, focusNode: focusNode);

    final fieldSize = tester.getSize(find.byType(AcpTextField));
    expect(fieldSize.height, equals(t.Geometry.composerInputMaxHeight));

    final scroller = scrollerOf(tester);
    expect(scroller.position.maxScrollExtent, greaterThan(0), reason: '超长内容必须在输入框内部产生可滚动区域');
    expect(scroller.position.pixels, 0);

    // 鼠标滚轮向下滚动查看
    final center = tester.getCenter(find.byType(AcpTextField));
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: center,
        scrollDelta: const Offset(0, 120),
      ),
    );
    await tester.pumpAndSettle();

    expect(scroller.position.pixels, greaterThan(0), reason: '鼠标滚轮应能在输入框内向下滚动查看内容');
  });

  testWidgets('长内容清空后，输入框高度自动缩回且滚动范围重置', (tester) async {
    final longText = List<String>.generate(30, (i) => '行 $i').join('\n');
    final controller = TextEditingController(text: longText);
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await pumpComposer(tester, controller: controller, focusNode: focusNode);
    expect(tester.getSize(find.byType(AcpTextField)).height, equals(t.Geometry.composerInputMaxHeight));

    controller.text = '';
    await tester.pump();

    final emptySize = tester.getSize(find.byType(AcpTextField));
    expect(emptySize.height, lessThan(t.Geometry.composerInputMaxHeight));
    expect(emptySize.height, greaterThanOrEqualTo(t.Controls.input + t.Spacing.s8));
    expect(scrollerOf(tester).position.maxScrollExtent, 0);
  });

  testWidgets('极端无换行长文本自动软折行，超出后同样封顶在 composerInputMaxHeight', (tester) async {
    final longLine = '这是一段极长的没有换行符的连续文本。' * 50;
    final controller = TextEditingController(text: longLine);
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await pumpComposer(tester, controller: controller, focusNode: focusNode);

    expect(tester.getSize(find.byType(AcpTextField)).height, equals(t.Geometry.composerInputMaxHeight));
    expect(scrollerOf(tester).position.maxScrollExtent, greaterThan(0));
  });
}
