// 画板 32 的 `image` 块（工具卡内容里的非文本块）：预览区 + 元信息行。
// iteration-18：base64 只解一次。agent 回来的图落在 `tool_call` / `tool_call_update` 的内容里（实测一份
// 155–275 KB base64，同一张图两条消息各带一份），而转录区在流式期间按帧重建——每帧重解一次会让
// `Image.memory` 的缓存键每帧都变（`MemoryImage` 比的是 `bytes` 的同一性），同一张图被反复解成位图再上传
// （核显上那块显存就是系统内存）。所有者 2026-09-29 报障内存冲到 100%，这条不变量就是那次的地基。

import 'dart:typed_data';

import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/ui/transcript/content_blocks.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 1×1 的 PNG（与 `composer_attachments_test.dart` 同一份）。
const String pngPixel = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  ContentBlockWire block(String? data) => ContentBlockWire(<String, dynamic>{
        'type': 'image',
        if (data != null) 'data': data,
        'mimeType': 'image/png',
      });

  // 与 terminal_card_truncation_test.dart 同一套壳。
  Future<void> pump(WidgetTester tester, ContentBlockWire b) => tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(900, 1200)),
            child: Align(alignment: Alignment.topLeft, child: SizedBox(width: 900, child: ContentBlockView(b))),
          ),
        ),
      );

  /// 现在挂在树上的那张图拿到的字节对象。
  Uint8List decoded(WidgetTester tester) => (tester.widget<Image>(find.byType(Image)).image as MemoryImage).bytes;

  testWidgets('重建不重解：同一份 data 重建之后还是同一个字节对象', (tester) async {
    await pump(tester, block(pngPixel));
    final first = decoded(tester);

    // 流式期间每帧都这样：同一份内容、新的块实例。
    await pump(tester, block(pngPixel));
    expect(identical(decoded(tester), first), isTrue, reason: '重建后又解了一遍 base64，ImageCache 会一直不命中');
  });

  testWidgets('data 真变了才重解', (tester) async {
    await pump(tester, block(pngPixel));
    final first = decoded(tester);

    await pump(tester, block('AAECAwQ='));
    expect(identical(decoded(tester), first), isFalse);
  });

  testWidgets('没有 data 或解不开：不挂预览，显示「无法解码」', (tester) async {
    await pump(tester, block(null));
    expect(find.byType(Image), findsNothing);
    expect(find.text('image · image/png · 无法解码'), findsOneWidget);

    await pump(tester, block('not-base64!!'));
    expect(find.byType(Image), findsNothing);
    expect(find.text('image · image/png · 无法解码'), findsOneWidget);
  });
}
