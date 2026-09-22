// 画板 25 权限卡（所有者 2026-09-18 手测报障）：范围下拉之前画在卡片自己的 Stack 里，转录里下一张卡把它压住；
// 改成走 PopoverAnchor 浮在 Overlay 上。三个从没接过按键的快捷键标签（Alt-Shift-A / Alt-Shift-X / Ctrl-Alt-A）一并去掉。
// 不加载字体（只验层级与回调，不出图）；卡里有 SVG 图标异步解码，只 pump 不 pumpAndSettle。

import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/projection/session_store.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/transcript/card_chrome.dart';
import 'package:acp_agent_client/ui/transcript/permission_card.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const String sid = 'sess_p';

/// 与 test/fixtures/15-permission-kinds.jsonl 同一组五个选项：两个 allow_always、一个 allow_once、两个 reject_*。
const JsonMap permissionRequest = <String, dynamic>{
  'agentId': 'a',
  'requestId': 'p1',
  'method': 'session/request_permission',
  'params': <String, dynamic>{
    'sessionId': sid,
    'toolCall': <String, dynamic>{'toolCallId': 'tc1', 'kind': 'delete', 'rawInput': <String, dynamic>{'path': 'design/x.txt'}},
    'options': <JsonMap>[
      <String, dynamic>{'optionId': 'allow-delete-always', 'name': 'Always for delete path', 'kind': 'allow_always'},
      <String, dynamic>{'optionId': 'allow-dir-always', 'name': 'Always for design/', 'kind': 'allow_always'},
      <String, dynamic>{'optionId': 'allow-once', 'name': 'Only this time', 'kind': 'allow_once'},
      <String, dynamic>{'optionId': 'reject-once', 'name': 'Reject this time', 'kind': 'reject_once'},
      <String, dynamic>{'optionId': 'reject-delete-always', 'name': 'Always reject delete path', 'kind': 'reject_always'},
    ],
  },
};

PermissionEntry newEntry() {
  var now = DateTime.utc(2026, 9, 18, 12);
  final s = SessionStore(sessionId: sid, clock: () => now = now.add(const Duration(seconds: 1)));
  s.applyClientRequest(const ClientRequestEnvelope(permissionRequest));
  return s.pending.byRequestId('p1')! as PermissionEntry;
}

final Key belowKey = UniqueKey();

/// 卡片 + 紧挨在下面的一块不透明区域（模拟转录里的下一张卡，绘制顺序更晚）。
Widget host(PermissionEntry e, {void Function(String)? onAnswer, VoidCallback? onBelowTap}) => Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(800, 600)),
        child: Overlay(
          initialEntries: <OverlayEntry>[
            OverlayEntry(
              builder: (_) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  PermissionCard(e, onAnswer: onAnswer),
                  Expanded(
                    child: GestureDetector(
                      key: belowKey,
                      behavior: HitTestBehavior.opaque,
                      onTap: onBelowTap,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

/// 弹层有 `motion.base` 的出场动画，给它两帧落定。
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(t.Motion.base);
}

void main() {
  testWidgets('三个快捷键标签已去掉：按钮上没有 kbd', (tester) async {
    await tester.pumpWidget(host(newEntry()));
    await tester.pump();
    expect(find.byType(Kbd), findsNothing);
    for (final label in <String>['Alt-Shift-A', 'Alt-Shift-X', 'Ctrl-Alt-A']) {
      expect(find.text(label), findsNothing, reason: label);
    }
    expect(find.text('允许'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);
    expect(find.text('Only this time'), findsOneWidget);
  });

  testWidgets('范围下拉浮在 Overlay 上：盖住下面的内容，点得中、选得上', (tester) async {
    var belowTaps = 0;
    final answers = <String>[];
    await tester.pumpWidget(host(newEntry(), onAnswer: answers.add, onBelowTap: () => belowTaps++));
    await tester.pump();

    await tester.tap(find.text('Only this time'));
    await settle(tester);
    // 菜单列出全部五项（含 kind 的 mono 文案）。
    expect(find.text('allow_always'), findsNWidgets(2));
    expect(find.text('reject_always'), findsOneWidget);

    // 菜单第一项落在「下一张卡」的矩形里 —— 之前正是这一块把菜单压住。
    final item = find.text('Always for delete path');
    final center = tester.getCenter(item);
    expect(tester.getRect(find.byKey(belowKey)).contains(center), isTrue, reason: '菜单应伸进下方区域');

    await tester.tapAt(center);
    await settle(tester);
    expect(belowTaps, 0, reason: '点的是菜单，不该穿透到下面');
    expect(find.text('allow_always'), findsNothing, reason: '选完即收起');
    // 范围按钮换成选中的那项。
    expect(find.text('Always for delete path'), findsOneWidget);

    await tester.tap(find.text('允许'));
    await tester.pump();
    expect(answers, <String>['allow-delete-always']);
  });

  testWidgets('点菜单之外收起：不穿透、chevron 复位、再点还能开', (tester) async {
    var belowTaps = 0;
    await tester.pumpWidget(host(newEntry(), onBelowTap: () => belowTaps++));
    await tester.pump();

    await tester.tap(find.text('Only this time'));
    await settle(tester);
    expect(find.text('reject_once'), findsOneWidget);

    // 点下方区域靠左的位置（菜单靠右，不会碰到）。
    final below = tester.getRect(find.byKey(belowKey));
    await tester.tapAt(Offset(below.left + t.Spacing.s16, below.bottom - t.Spacing.s16));
    await settle(tester);
    expect(find.text('reject_once'), findsNothing);
    expect(belowTaps, 0, reason: '关闭那一下被弹层的遮罩吃掉');

    await tester.tap(find.text('Only this time'));
    await settle(tester);
    expect(find.text('reject_once'), findsOneWidget);
  });
}
