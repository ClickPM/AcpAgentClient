// 画板对照（ROUNDS.md § 0 第 5 条）：把 lib/gallery/ 里的每张画板离屏渲染成 build/gallery/<id>.png，
// 与 design/round-design/<id>.png 并排看。固定 frame 的画板（00）按 frame 尺寸截；画板页（10–34）宽 800、高随内容。
// 字体 / 图标预热见 gallery_harness.dart。

import 'dart:io';
import 'dart:ui' as ui;

import 'package:acp_agent_client/gallery/gallery.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gallery_harness.dart';

void main() {
  final outDir = Directory('build/gallery');

  setUpAll(() async {
    await outDir.create(recursive: true);
  });

  for (final board in galleryBoards) {
    testWidgets('gallery ${board.id} renders', (tester) async {
      if (board.fitContent) {
        final key = await pumpBoard(tester, Builder(builder: board.build), width: board.frame.width);
        final err = tester.takeException();
        expect(err, isNull, reason: '${board.id}: $err');
        final size = await writeShot(tester, key, '${outDir.path}/${board.id}.png');
        expect(size, greaterThan(0));
        return;
      }

      tester.view.physicalSize = board.frame;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(loadGalleryFonts);

      final key = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: MediaQueryData(size: board.frame),
            child: RepaintBoundary(key: key, child: Builder(builder: board.build)),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      final bytes = await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data!.buffer.asUint8List();
      });
      // 测试 zone 是 FakeAsync：真实 IO 的 Future 在 runAsync 之外永远不会完成，所以用同步写。
      final file = File('${outDir.path}/${board.id}.png')..writeAsBytesSync(bytes!);
      debugPrint('[gallery] wrote ${file.path} (${bytes.length} bytes)');
      expect(file.lengthSync(), greaterThan(0));
    });
  }
}
