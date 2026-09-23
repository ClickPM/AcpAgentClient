// 剪贴板读取（lib/app/clipboard_image.dart）：位图那条路的 PNG 编码在 Dart 侧用 dart:ui 做，
// 这里验「BGRA 进、PNG 出、解回来颜色不变」、复制的文件与目录怎么分成「读成图」与「按路径引用」两份；
// runner 不在（flutter_tester）时整个读取回空。
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
        final result = await readClipboard(images: true, maxImages: 2);
        expect(result.images.map((i) => i.path!.split(Platform.pathSeparator).last), <String>['shot0.png', 'shot1.png']);
        expect(result.skippedTooMany, isTrue);
        expect(result.skippedTooLarge, isFalse, reason: '张数门与大小门是两件事，别混进同一个旗标');
      });

      test('刚好收满（= 余量）：不记 skippedTooMany', () async {
        reply = files(2);
        final result = await readClipboard(images: true, maxImages: 2);
        expect(result.images, hasLength(2));
        expect(result.skippedTooMany, isFalse, reason: '门是「还有下一张」才报，边界这一张要放行');
      });

      test('不传 maxImages 时按 promptImageCountLimit 收', () async {
        reply = files(promptImageCountLimit + 1);
        final result = await readClipboard(images: true);
        expect(result.images, hasLength(promptImageCountLimit));
        expect(result.skippedTooMany, isTrue);
      });

      test('收满之后：多出来的图不读也不退回路径，后面的目录与非图片文件照样按路径收', () async {
        final sub = Directory('${dir.path}${Platform.pathSeparator}sub')..createSync();
        final notes = File('${dir.path}${Platform.pathSeparator}notes.txt')..writeAsStringSync('x');
        reply = <Object?>[
          ...files(3),
          <Object?, Object?>{'path': sub.path},
          <Object?, Object?>{'path': notes.path},
        ];
        final result = await readClipboard(images: true, maxImages: 2);
        expect(result.images, hasLength(2));
        expect(result.paths, <String>[sub.path, notes.path], reason: '张数门只管读成图的，不是 break 掉整批');
        expect(result.skippedTooMany, isTrue);
      });

      test('余量为 0：剪贴板里真有图才报，空剪贴板 / 非图片 / 读不到的路径不误报', () async {
        reply = files(1);
        expect((await readClipboard(images: true, maxImages: 0)).skippedTooMany, isTrue);

        reply = <Object?>[
          <Object?, Object?>{'width': 2, 'height': 1, 'bgra': Uint8List.fromList(<int>[0, 0, 255, 255, 255, 0, 0, 255])},
        ];
        final bitmap = await readClipboard(images: true, maxImages: 0);
        expect(bitmap.images, isEmpty);
        expect(bitmap.skippedTooMany, isTrue, reason: '位图那条路同一道门');

        final notes = File('${dir.path}${Platform.pathSeparator}notes.txt')..writeAsStringSync('x');
        for (final r in <List<Object?>>[
          const <Object?>[],
          <Object?>[<Object?, Object?>{'path': notes.path}],
          <Object?>[<Object?, Object?>{'path': r'Z:\no\such\dir\shot.png'}],
        ]) {
          reply = r;
          expect((await readClipboard(images: true, maxImages: 0)).skippedTooMany, isFalse, reason: '$r');
        }
      });

      group('粘贴进输入框（ComposerState.pasteFromClipboard）', () {
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

          await c.pasteFromClipboard();

          expect(c.pendingImages, hasLength(promptImageCountLimit));
          expect(c.lastError, tooMany);
          c.dispose();
        });

        test('连按两下 Ctrl+V（两次读取并发）：合起来也不超过上限', () async {
          final c = composer();
          reply = files(15);

          await Future.wait(<Future<void>>[c.pasteFromClipboard(), c.pasteFromClipboard()]);

          expect(c.pendingImages, hasLength(promptImageCountLimit));
          expect(c.lastError, tooMany);
          c.dispose();
        });

        test('没到上限：照常收下，lastError 不动', () async {
          final c = composer();
          reply = files(3);

          await c.pasteFromClipboard();

          expect(c.pendingImages, hasLength(3));
          expect(c.lastError, isNull);
          c.dispose();
        });
      });
    });
  });
}
