// 壳级提示（toast）的 widget（lib/ui/shell/toast.dart，设计稿之外的增补，所有者 2026-09-23）：
// 错误到时间自己收、鼠标停着不收、点 × 收；正在载的那条不计时、没有 ×；提示出没不重建底下的正文。

import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/shell/toast.dart';
import 'package:acp_agent_client/ui/transcript/icons.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const ToastMessage _error = ToastMessage(id: 1, kind: ToastKind.error, text: 'spawn failed');
const ToastMessage _loading = ToastMessage(id: 'loading', kind: ToastKind.loading, text: '会话正在加载中，请稍后');

Widget _host(List<ToastMessage> toasts, {ValueChanged<ToastMessage>? onDismiss, Widget body = const SizedBox.expand()}) => Directionality(
  textDirection: TextDirection.ltr,
  child: ToastLayer(toasts: toasts, onDismiss: onDismiss, child: body),
);

/// 底下正文的替身：记自己被建过几次 State。
class _Body extends StatefulWidget {
  const _Body(this.states);

  final List<Object> states;

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  @override
  void initState() {
    super.initState();
    widget.states.add(this);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  testWidgets('错误提示到时间自己收起', (tester) async {
    final dismissed = <ToastMessage>[];
    await tester.pumpWidget(_host(<ToastMessage>[_error], onDismiss: dismissed.add));
    expect(find.text('spawn failed'), findsOneWidget);

    await tester.pump(t.Toast.errorDuration - const Duration(milliseconds: 1));
    expect(dismissed, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(dismissed, <ToastMessage>[_error]);
  });

  testWidgets('鼠标停在上面不计时，移开后从头计', (tester) async {
    final dismissed = <ToastMessage>[];
    await tester.pumpWidget(_host(<ToastMessage>[_error], onDismiss: dismissed.add));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);

    await gesture.moveTo(tester.getCenter(find.text('spawn failed')));
    await tester.pump(t.Toast.errorDuration * 2);
    expect(dismissed, isEmpty, reason: '在读它');

    await gesture.moveTo(Offset.zero);
    await tester.pump(t.Toast.errorDuration - const Duration(milliseconds: 1));
    expect(dismissed, isEmpty, reason: '移开后是从头计，不是接着上次');
    await tester.pump(const Duration(milliseconds: 1));
    expect(dismissed, <ToastMessage>[_error]);
  });

  testWidgets('点 × 立刻收起', (tester) async {
    final dismissed = <ToastMessage>[];
    await tester.pumpWidget(_host(<ToastMessage>[_error], onDismiss: dismissed.add));
    await tester.tap(find.byWidgetPredicate((w) => w is AcpIcon && w.body == AcpIcons.x));
    expect(dismissed, <ToastMessage>[_error]);
  });

  testWidgets('正在载的那条：spinner、没有 ×、不计时', (tester) async {
    final dismissed = <ToastMessage>[];
    await tester.pumpWidget(_host(<ToastMessage>[_loading], onDismiss: dismissed.add));
    expect(find.text('会话正在加载中，请稍后'), findsOneWidget);
    expect(find.byType(Spinner), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is AcpIcon && w.body == AcpIcons.x), findsNothing);
    await tester.pump(t.Toast.errorDuration * 2);
    expect(dismissed, isEmpty);
    // spinner 一直在转：换掉整棵树，别让 pumpAndSettle 类的收尾等它。
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('提示出现与收起都不重建底下的正文（转录的滚动位置与卡片展开态靠它）', (tester) async {
    final states = <Object>[];
    await tester.pumpWidget(_host(const <ToastMessage>[], body: _Body(states)));
    await tester.pumpWidget(_host(<ToastMessage>[_error], body: _Body(states)));
    await tester.pumpWidget(_host(const <ToastMessage>[], body: _Body(states)));
    expect(states, hasLength(1));
  });

  testWidgets('提示条以外的地方点击照常落到正文', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(
      <ToastMessage>[_error],
      body: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => taps++, child: const SizedBox.expand()),
    ));
    final card = tester.getRect(find.byType(ToastCard));
    // 与提示条同一高度、在它左边的空白处。
    await tester.tapAt(Offset(card.left / 2, card.center.dy));
    expect(taps, 1);
    await tester.pump(t.Toast.errorDuration);
  });
}
