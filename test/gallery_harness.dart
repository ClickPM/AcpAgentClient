// gallery / UI 测试共用：字体加载（Geist + 本机 CJK + flutter_math_fork 的 KaTeX 包字体）、内联 SVG 预热、
// 内容尺寸截图落盘。flutter_tester 不装包字体、不做平台字体回退、也不会在 FakeAsync 里等 isolate 解码 SVG，
// 所以这里都要手动做（R0 / R1.5 的坑）。

import 'dart:io';
import 'dart:ui' as ui;

import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/transcript/icons.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

bool _fontsLoaded = false;

Future<void> loadGalleryFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;
  final geist = FontLoader('Geist')..addFont(rootBundle.load('assets/fonts/Geist-Variable.ttf'));
  final mono = FontLoader('Geist Mono')..addFont(rootBundle.load('assets/fonts/GeistMono-Variable.ttf'));
  // CJK 回退的第一项随包（tokens 的 Fonts.cjkFallback），gallery 因此不再依赖本机装没装中文字体。
  final notoSC = FontLoader('Noto Sans SC')..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'));
  await geist.load();
  await mono.load();
  await notoSC.load();
  // 系统兜底的后两项：装了才加载，缺了不影响 gallery（中文已由 Noto Sans SC 兜住）。
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
  const katex = <String, List<String>>{
    'KaTeX_Main': <String>['Main-Regular', 'Main-Italic', 'Main-Bold', 'Main-BoldItalic'],
    'KaTeX_Math': <String>['Math-Italic', 'Math-BoldItalic'],
    'KaTeX_AMS': <String>['AMS-Regular'],
    'KaTeX_Caligraphic': <String>['Caligraphic-Regular', 'Caligraphic-Bold'],
    'KaTeX_Fraktur': <String>['Fraktur-Regular', 'Fraktur-Bold'],
    'KaTeX_SansSerif': <String>['SansSerif-Regular', 'SansSerif-Bold', 'SansSerif-Italic'],
    'KaTeX_Script': <String>['Script-Regular'],
    'KaTeX_Typewriter': <String>['Typewriter-Regular'],
    'KaTeX_Size1': <String>['Size1-Regular'],
    'KaTeX_Size2': <String>['Size2-Regular'],
    'KaTeX_Size3': <String>['Size3-Regular'],
    'KaTeX_Size4': <String>['Size4-Regular'],
  };
  for (final entry in katex.entries) {
    final loader = FontLoader('packages/flutter_math_fork/${entry.key}');
    for (final file in entry.value) {
      loader.addFont(rootBundle.load('packages/flutter_math_fork/lib/katex_fonts/fonts/KaTeX_$file.ttf'));
    }
    await loader.load();
  }
}

/// 预热全部内联图标：SvgPicture.string 在 isolate 里解码，FakeAsync 等不到；先在 runAsync 里解码进 svg.cache。
Future<void> precacheIcons() async {
  // icons.dart 用到的三种 stroke 宽度：IconSizes.stroke / Spinner.strokeWidth / 复选框对勾 stroke * 2。
  final widths = <double>[];
  for (final w in <double>[t.IconSizes.stroke, t.Spinner.strokeWidth, t.IconSizes.stroke * 2]) {
    if (!widths.contains(w)) widths.add(w);
  }
  for (final body in AcpIcons.all) {
    for (final w in widths) {
      // loadBytes 自己写 svg.cache；命中后 SvgPicture 拿到 SynchronousFuture，FakeAsync 里也能同帧出图。
      await SvgStringLoader(AcpIcons.document(body, strokeWidth: w)).loadBytes(null);
    }
  }
}

/// 在宽 [width]、高不限的视口里 pump，返回 RepaintBoundary 的 key；截图是内容尺寸。
Future<GlobalKey> pumpBoard(WidgetTester tester, Widget child, {double width = 800, double viewportHeight = 6000}) async {
  tester.view.physicalSize = Size(width, viewportHeight);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.runAsync(() async {
    await loadGalleryFonts();
    await precacheIcons();
  });
  final key = GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: MediaQueryData(size: Size(width, viewportHeight)),
        child: SingleChildScrollView(
          clipBehavior: Clip.none,
          child: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(key: key, child: SizedBox(width: width, child: child)),
          ),
        ),
      ),
    ),
  );
  // 图标解码结果与 Image.memory 都经真实异步回来（FakeAsync 等不到）：先在 runAsync 里让出一段真实时间，再 pump 几帧落地。
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return key;
}

/// 把 key 对应的 RepaintBoundary 渲染成 PNG（内容尺寸），同步写盘。
Future<int> writeShot(WidgetTester tester, GlobalKey key, String path) async {
  final bytes = await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  });
  final file = File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes!);
  debugPrint('[gallery] wrote ${file.path} (${bytes.length} bytes)');
  return bytes.length;
}
