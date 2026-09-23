// Hoverable 的 onHoverChanged（iteration-04 收拢五处自带 hover 时加的）：报的是交给 builder 的那个值，
// forceHover 时移出也仍报 true —— 路径芯片靠它让工具卡放开裁剪，gallery 的悬浮样张不能因为鼠标扫过就收回去。

import 'package:acp_agent_client/ui/shell/shell_common.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({required ValueChanged<bool> onHoverChanged, bool forceHover = false, required List<bool> built}) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(
    child: Hoverable(
      forceHover: forceHover,
      onHoverChanged: onHoverChanged,
      builder: (context, hovered) {
        built.add(hovered);
        return const SizedBox.square(dimension: 40);
      },
    ),
  ),
);

Future<TestGesture> _mouseOutside(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  return gesture;
}

void main() {
  testWidgets('进出各报一次，值与 builder 拿到的一致', (tester) async {
    final reported = <bool>[];
    final built = <bool>[];
    await tester.pumpWidget(_host(onHoverChanged: reported.add, built: built));
    final gesture = await _mouseOutside(tester);

    await gesture.moveTo(tester.getCenter(find.byType(SizedBox)));
    await tester.pump();
    await gesture.moveTo(Offset.zero);
    await tester.pump();

    expect(reported, <bool>[true, false]);
    expect(built.last, isFalse);
    expect(built, contains(true));
  });

  testWidgets('forceHover：移出仍报 true，builder 一直是悬浮态', (tester) async {
    final reported = <bool>[];
    final built = <bool>[];
    await tester.pumpWidget(_host(onHoverChanged: reported.add, forceHover: true, built: built));
    final gesture = await _mouseOutside(tester);

    await gesture.moveTo(tester.getCenter(find.byType(SizedBox)));
    await tester.pump();
    await gesture.moveTo(Offset.zero);
    await tester.pump();

    expect(reported, <bool>[true, true]);
    expect(built, everyElement(isTrue));
  });
}
