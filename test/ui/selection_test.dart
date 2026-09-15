// R2 验收 6：SelectableRegion 跨消息选择实测——从用户气泡拖到工具卡，plainText 里要有用户气泡、助手正文、代码块、工具卡标题四段。

import 'package:acp_agent_client/gallery/fixtures_source.dart';
import 'package:acp_agent_client/ui/transcript/transcript_list.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../gallery_harness.dart';

void main() {
  testWidgets('drag selection spans user bubble, assistant markdown, code block and tool card', (tester) async {
    const width = 800.0;
    const height = 2400.0;
    tester.view.physicalSize = const Size(width, height);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await loadGalleryFonts();
      await precacheIcons();
    });

    final r = FixtureReplay.replay(<String>['01-connect', '11-rich-text', '13-tool-kinds']);
    String? selected;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(width, height)),
          child: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(builder: (_) => TranscriptList(r.session, onSelectionChanged: (SelectedContent? s) => selected = s?.plainText)),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    final userBubble = find.textContaining('加一项校验');
    final toolTitle = find.text('Read file').first;
    expect(userBubble, findsWidgets);
    expect(toolTitle, findsOneWidget);
    final start = tester.getTopLeft(userBubble.first) + const Offset(2, 2);
    final end = tester.getBottomRight(toolTitle) + const Offset(2, 2);

    final gesture = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(selected, isNotNull);
    final text = selected!;
    debugPrint('[selection] ${text.length} chars');
    expect(text, contains('加一项校验'), reason: '用户气泡');
    expect(text, contains('样式字面量校验'), reason: '助手正文标题');
    expect(text, contains('Assert-NoStyleLiteral'), reason: '代码块');
    expect(text, contains('Read file'), reason: '工具卡标题');
  });
}
