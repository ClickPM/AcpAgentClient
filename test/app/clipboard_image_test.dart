// 剪贴板图片（lib/app/clipboard_image.dart）：位图那条路的 PNG 编码在 Dart 侧用 dart:ui 做，
// 这里验「BGRA 进、PNG 出、解回来颜色不变」；runner 不在（flutter_tester）时整个读取回空。
// 张数门（一条消息最多 20 张）连同输入框那一侧的余量计算也在这里验：两边都要 mock `acp/window` 通道。

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:acp_agent_client/app/clipboard_image.dart';
import 'package:acp_agent_client/app/composer_state.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
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

  group('readClipboardImages 对 runner 回来的条目', () {
    const channel = MethodChannel('acp/window');
    List<Object?> reply = const <Object?>[];

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'readClipboardImages');
        return reply;
      });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('位图 → 一张 image/png，没有路径', () async {
      reply = <Object?>[
        <Object?, Object?>{'width': 2, 'height': 1, 'bgra': Uint8List.fromList(<int>[0, 0, 255, 255, 255, 0, 0, 255])},
      ];
      final result = await readClipboardImages();
      expect(result.images, hasLength(1));
      expect(result.images.single.mimeType, 'image/png');
      expect(result.images.single.path, isNull);
      expect(result.images.single.bytes.sublist(0, 4), <int>[0x89, 0x50, 0x4E, 0x47]);
      expect(result.skippedTooLarge, isFalse);
    });

    test('runner 因太大只回尺寸不给像素 → 记 skippedTooLarge、不编码', () async {
      reply = <Object?>[
        <Object?, Object?>{'width': 9000, 'height': 9000},
      ];
      final result = await readClipboardImages();
      expect(result.images, isEmpty);
      expect(result.skippedTooLarge, isTrue);
    });

    test('文件列表：不存在的路径与非图片扩展名都跳过，不抛', () async {
      reply = <Object?>[
        <Object?, Object?>{'path': r'Z:\no\such\dir\shot.png'},
        <Object?, Object?>{'path': r'Z:\no\such\dir\notes.txt'},
      ];
      final result = await readClipboardImages();
      expect(result.images, isEmpty);
      expect(result.skippedTooLarge, isFalse);
    });

    // 张数门（所有者裁定 2026-09-23：一条消息最多 promptImageCountLimit 张）：资源管理器里全选复制的文件列表
    // 一次能有上百条，多出来的一张都不该读进内存。
    group('张数门', () {
      late Directory dir;

      setUp(() => dir = Directory.systemTemp.createTempSync('acp_clipboard_count_'));
      tearDown(() => dir.deleteSync(recursive: true));

      /// n 个磁盘上真实存在的 `.png`（内容只要非空：文件那条路不解码）。
      List<Object?> files(int n) => <Object?>[
            for (var i = 0; i < n; i++)
              <Object?, Object?>{
                'path': (File('${dir.path}${Platform.pathSeparator}shot$i.png')..writeAsBytesSync(<int>[i + 1])).path,
              },
          ];

      test('文件列表多于余量：按顺序只收前 maxImages 张，记 skippedTooMany', () async {
        reply = files(3);
        final result = await readClipboardImages(maxImages: 2);
        expect(result.images.map((i) => i.path!.split(Platform.pathSeparator).last), <String>['shot0.png', 'shot1.png']);
        expect(result.skippedTooMany, isTrue);
        expect(result.skippedTooLarge, isFalse, reason: '张数门与大小门是两件事，别混进同一个旗标');
      });

      test('刚好收满（= 余量）：不记 skippedTooMany', () async {
        reply = files(2);
        final result = await readClipboardImages(maxImages: 2);
        expect(result.images, hasLength(2));
        expect(result.skippedTooMany, isFalse, reason: '门是「还有下一张」才报，边界这一张要放行');
      });

      test('不传 maxImages 时按 promptImageCountLimit 收', () async {
        reply = files(promptImageCountLimit + 1);
        final result = await readClipboardImages();
        expect(result.images, hasLength(promptImageCountLimit));
        expect(result.skippedTooMany, isTrue);
      });

      test('余量为 0：剪贴板里真有图才报，空剪贴板 / 非图片 / 读不到的路径不误报', () async {
        reply = files(1);
        expect((await readClipboardImages(maxImages: 0)).skippedTooMany, isTrue);

        reply = <Object?>[
          <Object?, Object?>{'width': 2, 'height': 1, 'bgra': Uint8List.fromList(<int>[0, 0, 255, 255, 255, 0, 0, 255])},
        ];
        final bitmap = await readClipboardImages(maxImages: 0);
        expect(bitmap.images, isEmpty);
        expect(bitmap.skippedTooMany, isTrue, reason: '位图那条路同一道门');

        final notes = File('${dir.path}${Platform.pathSeparator}notes.txt')..writeAsStringSync('x');
        for (final r in <List<Object?>>[
          const <Object?>[],
          <Object?>[<Object?, Object?>{'path': notes.path}],
          <Object?>[<Object?, Object?>{'path': r'Z:\no\such\dir\shot.png'}],
        ]) {
          reply = r;
          expect((await readClipboardImages(maxImages: 0)).skippedTooMany, isFalse, reason: '$r');
        }
      });

      group('粘贴进输入框（ComposerState.pasteImageFromClipboard）', () {
        setUp(() {
          // 剪贴板里没有文本：`Clipboard.getData` 回 null，才会去读图。
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
        });
        tearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null);
        });

        ComposerState composer() => ComposerState(
              bridge: null,
              store: () => null,
              cwd: () => null,
              canCompose: () => true,
              canPromptImage: () => true,
            );
        const tooMany = '一条消息最多带 $promptImageCountLimit 张图，多出来的没有加进输入框';

        test('余量按输入框里已有的图算：已有 18 张，再贴 5 张只收 2 张并提示', () async {
          final c = composer();
          for (var i = 0; i < promptImageCountLimit - 2; i++) {
            c.addImage('AA==', 'image/png');
          }
          reply = files(5);

          await c.pasteImageFromClipboard();

          expect(c.pendingImages, hasLength(promptImageCountLimit));
          expect(c.lastError, tooMany);
          c.dispose();
        });

        test('连按两下 Ctrl+V（两次读取并发）：合起来也不超过上限', () async {
          final c = composer();
          reply = files(15);

          await Future.wait(<Future<void>>[c.pasteImageFromClipboard(), c.pasteImageFromClipboard()]);

          expect(c.pendingImages, hasLength(promptImageCountLimit));
          expect(c.lastError, tooMany);
          c.dispose();
        });

        test('没到上限：照常收下，lastError 不动', () async {
          final c = composer();
          reply = files(3);

          await c.pasteImageFromClipboard();

          expect(c.pendingImages, hasLength(3));
          expect(c.lastError, isNull);
          c.dispose();
        });
      });
    });
  });
}
