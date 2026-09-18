// 弹层锚点的几何：`PopoverAnchor` 把弹层摆在触发控件的哪一侧。
// 所有者手测 2026-09-17：「消息发送区的下拉窗口位置全部漂移」——模型 / 思考强度 / 模式 / `+` 四个弹层
// 一律贴在窗口顶上，与输入框差着大半屏。成因是 overlay 里那个 `Align` 撑满了整屏，
// `CompositedTransformFollower` 于是拿整屏的角当 `followerAnchor` 算位置；向下展开的顶栏弹层
// 因为 topLeft 两个角重合而看不出来，向上展开的（`showAbove`）就整个飞了。
// 这里把两个方向的落点都钉死。

import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/shell/popover_anchor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 触发控件放在视口里靠下的位置，向上展开才有地方摆（测试视口 800×600）。
  const Rect trigger = Rect.fromLTWH(300, 500, 120, 32);
  const Size popover = Size(200, 160);

  Future<void> pump(WidgetTester tester, PopoverHandle handle) {
    return tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Overlay(
          initialEntries: <OverlayEntry>[
            OverlayEntry(
              builder: (context) => Stack(
                children: <Widget>[
                  Positioned(
                    left: trigger.left,
                    top: trigger.top,
                    child: PopoverAnchor(
                      handle: handle,
                      child: SizedBox(width: trigger.width, height: trigger.height),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget content(BuildContext context) => SizedBox(key: const ValueKey<String>('pop'), width: popover.width, height: popover.height);

  Rect rect(WidgetTester tester) => tester.getRect(find.byKey(const ValueKey<String>('pop')));

  testWidgets('showAbove：弹层底边贴着触发控件的上沿，不是窗口顶上', (tester) async {
    final handle = PopoverHandle();
    await pump(tester, handle);
    handle.showAbove(content);
    // 要 settle：画板 05 D 组给弹层加了入场位移（向上弹的从下方 `motion.pop` 升起），
    // 只 pump 一帧量到的是 t=0 那一帧、差一个 `pop`，而这条用例量的是静止位置。
    await tester.pumpAndSettle();

    final r = rect(tester);
    expect(r.left, trigger.left);
    expect(r.bottom, trigger.top - t.Spacing.s4);
    expect(r.size, popover, reason: '弹层不能被撑成整屏，否则 followerAnchor 算的是整屏的角');
  });

  testWidgets('show（默认向下）：弹层顶边贴着触发控件的下沿', (tester) async {
    final handle = PopoverHandle();
    await pump(tester, handle);
    handle.show(content);
    // 同上：向下弹的从上方 `-motion.pop` 落下，量静止位置要等动画走完。
    await tester.pumpAndSettle();

    final r = rect(tester);
    expect(r.left, trigger.left);
    expect(r.top, trigger.bottom + t.Spacing.s4);
    expect(r.size, popover);
  });
}
