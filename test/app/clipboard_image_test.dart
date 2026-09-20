// 剪贴板图片（lib/app/clipboard_image.dart）：位图那条路的 PNG 编码在 Dart 侧用 dart:ui 做，
// 这里验「BGRA 进、PNG 出、解回来颜色不变」；runner 不在（flutter_tester）时整个读取回空。

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:acp_agent_client/app/clipboard_image.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('encodePngFromBgra：BGRA 像素 → PNG，解回来是同样的颜色与尺寸', () async {
    // 2×1：左边纯红（B G R A = 00 00 FF FF），右边纯蓝。
    final bgra = Uint8List.fromList(<int>[0, 0, 255, 255, 255, 0, 0, 255]);
    final png = await encodePngFromBgra(2, 1, bgra);
    expect(png, isNotNull);
    expect(png!.sublist(0, 8), <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], reason: 'PNG 魔数');
    final image = await decodeImageFromList(png);
    expect(image.width, 2);
    expect(image.height, 1);
    final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    expect(rgba, <int>[255, 0, 0, 255, 0, 0, 255, 255]);
    image.dispose();
  });

  test('encodePngFromBgra：像素数与尺寸对不上 → null，不抛', () async {
    expect(await encodePngFromBgra(2, 2, Uint8List(4)), isNull);
    expect(await encodePngFromBgra(0, 1, Uint8List(0)), isNull);
  });

  test('readClipboardImages：没有 runner 时回空、不抛', () async {
    final result = await readClipboardImages();
    expect(result.images, isEmpty);
    expect(result.skippedTooLarge, isFalse);
  });
}
