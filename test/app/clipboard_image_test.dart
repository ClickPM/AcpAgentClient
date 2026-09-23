// 剪贴板读取（lib/app/clipboard_image.dart）：位图那条路的 PNG 编码在 Dart 侧用 dart:ui 做，
// 这里验「BGRA 进、PNG 出、解回来颜色不变」、复制的文件与目录怎么分成「读成图」与「按路径引用」两份；
// runner 不在（flutter_tester）时整个读取回空。

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:acp_agent_client/app/clipboard_image.dart';
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

  test('readClipboard：没有 runner 时回空、不抛', () async {
    final result = await readClipboard(images: true);
    expect(result.images, isEmpty);
    expect(result.paths, isEmpty);
    expect(result.skippedTooLarge, isFalse);
  });

  group('readClipboard 对 runner 回来的条目', () {
    const channel = MethodChannel('acp/window');
    List<Object?> reply = const <Object?>[];
    Object? arguments;

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'readClipboardImages');
        arguments = call.arguments;
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
      final result = await readClipboard(images: true);
      expect(arguments, <String, Object?>{'bitmap': true});
      expect(result.images, hasLength(1));
      expect(result.images.single.mimeType, 'image/png');
      expect(result.images.single.path, isNull);
      expect(result.images.single.bytes.sublist(0, 4), <int>[0x89, 0x50, 0x4E, 0x47]);
      expect(result.paths, isEmpty);
      expect(result.skippedTooLarge, isFalse);
    });

    test('runner 因太大只回尺寸不给像素 → 记 skippedTooLarge、不编码', () async {
      reply = <Object?>[
        <Object?, Object?>{'width': 9000, 'height': 9000},
      ];
      final result = await readClipboard(images: true);
      expect(result.images, isEmpty);
      expect(result.skippedTooLarge, isTrue);
    });

    test('agent 不收图：不向 runner 要位图；万一给了也不收、不报太大', () async {
      reply = <Object?>[
        <Object?, Object?>{'width': 9000, 'height': 9000},
      ];
      final result = await readClipboard(images: false);
      expect(arguments, <String, Object?>{'bitmap': false});
      expect(result.images, isEmpty);
      expect(result.skippedTooLarge, isFalse);
    });

    test('文件列表：不存在的路径跳过，不抛', () async {
      reply = <Object?>[
        <Object?, Object?>{'path': r'Z:\no\such\dir\shot.png'},
        <Object?, Object?>{'path': r'Z:\no\such\dir\notes.txt'},
      ];
      final result = await readClipboard(images: true);
      expect(result.images, isEmpty);
      expect(result.paths, isEmpty);
      expect(result.skippedTooLarge, isFalse);
    });

    group('文件列表的分流（磁盘上真有的文件与目录）', () {
      late Directory tmp;
      late String dir;
      late String txt;
      late String png;
      late String empty;
      late String huge;

      setUp(() async {
        tmp = Directory.systemTemp.createTempSync('acp_clipboard_');
        dir = (Directory('${tmp.path}${Platform.pathSeparator}src')..createSync()).path;
        txt = (File('${tmp.path}${Platform.pathSeparator}notes.txt')..writeAsStringSync('hi')).path;
        final bgra = Uint8List.fromList(<int>[0, 0, 255, 255]);
        png = (File('${tmp.path}${Platform.pathSeparator}shot.PNG')..writeAsBytesSync((await encodePngFromBgra(1, 1, bgra))!)).path;
        empty = (File('${tmp.path}${Platform.pathSeparator}empty.png')..createSync()).path;
        // 稀疏地撑到上限 + 1，不真写 20 MB。
        huge = File('${tmp.path}${Platform.pathSeparator}huge.jpg').path;
        final raf = File(huge).openSync(mode: FileMode.write);
        raf.truncateSync(clipboardImageSizeLimit + 1);
        raf.closeSync();
      });
      tearDown(() => tmp.deleteSync(recursive: true));

      test('agent 收图：图片文件读成图（扩展名不分大小写），目录 / 非图片 / 空图 / 超限图一律按路径，顺序照剪贴板', () async {
        reply = <Object?>[
          for (final p in <String>[dir, txt, png, empty, huge]) <Object?, Object?>{'path': p},
        ];
        final result = await readClipboard(images: true);
        expect(result.images, hasLength(1));
        expect(result.images.single.path, png);
        expect(result.images.single.mimeType, 'image/png');
        expect(result.paths, <String>[dir, txt, empty, huge], reason: '超限的图片文件退回路径，不丢也不报太大');
        expect(result.skippedTooLarge, isFalse);
      });

      test('一个图片文件读不了（被别的句柄锁住）：它退回路径，前后已分好的不丢（审查 P2）', () async {
        final raf = File(png).openSync(mode: FileMode.append);
        raf.lockSync(); // Windows 的 LockFileEx 是按句柄的：别的句柄读这段会 ERROR_LOCK_VIOLATION
        try {
          reply = <Object?>[
            for (final p in <String>[dir, png, txt]) <Object?, Object?>{'path': p},
          ];
          final result = await readClipboard(images: true);
          expect(result.images, isEmpty);
          expect(result.paths, <String>[dir, png, txt]);
        } finally {
          raf.unlockSync();
          raf.closeSync();
        }
      }, skip: !Platform.isWindows);

      test('agent 不收图：图片文件也按路径引用', () async {
        reply = <Object?>[
          for (final p in <String>[png, dir]) <Object?, Object?>{'path': p},
        ];
        final result = await readClipboard(images: false);
        expect(result.images, isEmpty);
        expect(result.paths, <String>[png, dir]);
      });
    });
  });
}
