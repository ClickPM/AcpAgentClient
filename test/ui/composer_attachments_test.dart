// 输入框顶部的附件芯片条（所有者 2026-09-18 要求，对齐 Zed 的图片粘贴交互）：
// 待发的 ACP `image` 块一块一枚芯片、名字取自可选的 `uri`、悬浮浮出预览、× 把那一块去掉。
// 预览的落点与画板 40 的弹层同一套算法（见 popover_anchor_test.dart 的那条教训：
// overlay 里的 `Align` 不收紧约束的话会按整屏的角算位置，预览会飞到窗口顶上）。

import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/shell/composer_attachments.dart';
import 'package:acp_agent_client/ui/transcript/card_chrome.dart';
import 'package:acp_agent_client/ui/transcript/icons.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 1×1 的 PNG：解得开就够了，这里量的是芯片与预览的位置，不是画质。
const String pngPixel =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  ContentBlockWire image({String? uri}) => ContentBlockWire(<String, dynamic>{
        'type': 'image',
        'data': pngPixel,
        'mimeType': 'image/png',
        if (uri != null) 'uri': uri,
      });

  Future<void> pump(WidgetTester tester, List<ContentBlockWire> blocks, {ValueChanged<ContentBlockWire>? onRemove}) {
    return tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Overlay(
          initialEntries: <OverlayEntry>[
            OverlayEntry(
              builder: (context) => Stack(
                children: <Widget>[
                  // 靠下摆：预览向上展开才有地方（测试视口 800×600）。
                  Positioned(
                    left: 100,
                    top: 400,
                    child: ComposerAttachments(blocks: blocks, onRemove: onRemove),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('芯片名字：有 uri 显示文件名，截图这类没有来源的显示 Image', (tester) async {
    await pump(tester, <ContentBlockWire>[image(), image(uri: 'file:///d:/tmp/shot%20one.png')]);

    expect(find.byType(AttachmentChip), findsNWidgets(2));
    expect(find.text('Image'), findsOneWidget);
    expect(find.text('shot one.png'), findsOneWidget);
  });

  testWidgets('悬浮芯片：预览贴在芯片上沿之上，不显示时不在树上', (tester) async {
    await pump(tester, <ContentBlockWire>[image()]);
    expect(find.byType(Popover), findsNothing);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    final chip = tester.getRect(find.byType(AttachmentChip));
    await gesture.moveTo(chip.center);
    // 预览有入场位移（画板 05 D 组），要 settle 才量得到静止位置。
    await tester.pumpAndSettle();

    final preview = tester.getRect(find.byType(Popover));
    expect(preview.left, chip.left);
    expect(preview.bottom, chip.top - t.Spacing.s4);

    await gesture.moveTo(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byType(Popover), findsNothing, reason: '鼠标离开芯片，预览要收掉');
  });

  testWidgets('× 把那一块去掉：回调拿到的是被点的那一块', (tester) async {
    final blocks = <ContentBlockWire>[image(), image(uri: 'file:///d:/tmp/b.png')];
    final removed = <ContentBlockWire>[];
    await pump(tester, blocks, onRemove: removed.add);

    // 芯片本身也走 Hoverable（iteration-04），所以按 × 图标找，不按「芯片里的 Hoverable」找。
    await tester.tap(find.descendant(
      of: find.byType(AttachmentChip).last,
      matching: find.byWidgetPredicate((w) => w is AcpIcon && w.body == AcpIcons.x),
    ));
    await tester.pump();

    expect(removed, <ContentBlockWire>[blocks[1]]);
  });
}
