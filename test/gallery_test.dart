// 画板对照（ROUNDS.md § 0 第 5 条）：把 lib/gallery/ 里的每张画板以 frame 尺寸离屏渲染成 build/gallery/<id>.png，
// 与 design/round-design/<id>.png 并排看。字体从 assets/ 真实加载，否则测试环境只有 Ahem 方块字。

import 'dart:io';
import 'dart:ui' as ui;

import 'package:acp_agent_client/gallery/gallery.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _loadFonts() async {
  final geist = FontLoader('Geist')..addFont(rootBundle.load('assets/fonts/Geist-Variable.ttf'));
  final mono = FontLoader('Geist Mono')..addFont(rootBundle.load('assets/fonts/GeistMono-Variable.ttf'));
  await geist.load();
  await mono.load();
  // flutter_tester 不带系统字体：CJK 回退（tokens.dart 的 Fonts.cjkFallback）从本机字体目录读，没有就跳过（中文会显示为方块）。
  final cjk = <String, String>{
    'Microsoft YaHei UI': r'C:\Windows\Fonts\msyh.ttc',
    'PingFang SC': '/System/Library/Fonts/PingFang.ttc',
  };
  for (final entry in cjk.entries) {
    final file = File(entry.value);
    if (!file.existsSync()) continue;
    final bytes = await file.readAsBytes();
    final loader = FontLoader(entry.key)..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();
  }
}

void main() {
  final outDir = Directory('build/gallery');

  setUpAll(() async {
    await outDir.create(recursive: true);
  });

  for (final board in galleryBoards) {
    testWidgets('gallery ${board.id} renders at frame size', (tester) async {
      tester.view.physicalSize = board.frame;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.runAsync(_loadFonts);

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
