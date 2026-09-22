// 输入框的图片粘贴（Ctrl+V / Cmd+V）：Flutter 的 `Clipboard` 只给 text/plain，位图与文件列表都取不到，
// 第三方剪贴板包又在 CLAUDE.md 规则 1 的清单之外，所以 Windows（规则 9 首发）由 runner 直接走 Win32 读一次
// 剪贴板（`acp/window` 通道的 `readClipboardImages`，windows/runner/acp_clipboard.cpp）：先看文件列表
// （资源管理器里复制的图片文件），再看位图（截图工具 / 企业微信截图）。位图回来的是 BGRA 像素，PNG 编码在
// 这里用 dart:ui 自带的编码器做，不落临时文件、不拉子进程。
// macOS 走系统原生 AppKit NSPasteboard（osascript 双通道），Linux 暂时返回空。

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'window_controls.dart';

/// 剪贴板里的一张图。
class ClipboardImage {
  const ClipboardImage({required this.bytes, required this.mimeType, this.path});

  final Uint8List bytes;

  /// ACP `image` 块的 `mimeType`。
  final String mimeType;

  /// 来自磁盘上的图片文件时的原路径：芯片按它显示文件名，`image` 块带上 `uri`。
  /// 截图（位图）没有路径。
  final String? path;
}

/// 扩展名 → mimeType。列表之外的文件不当图片看（剪贴板里的文件列表什么都可能有）。
const Map<String, String> imageMimeTypes = <String, String>{
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'bmp': 'image/bmp',
};

/// 单张图的字节上限。base64 之后整块进 `session/prompt` 的 JSON，一张几十 MB 的图会把一条 prompt
/// 撑到桥接与 agent 都难受，超了的直接跳过并回报（调用方写进错误条）。位图按编码后的 PNG 算。
const int clipboardImageSizeLimit = 20 * 1024 * 1024;

/// 位图**像素缓冲**的上限（BGRA 原始字节，编码前），与 runner 的 `kMaxBitmapBytes` 是同一个数：runner 超过它只回尺寸
/// 不给像素，这里按同一个数判成「太大」，不先编码再量。256 MB = 8192×8192 的 32 位位图，8K 整屏（133 MB）也在内。
const int clipboardBitmapBytesLimit = 256 * 1024 * 1024;

/// 读一次剪贴板里的图片。`skippedTooLarge` = 有图但因为太大被跳过了 —— 两道门共用这个旗标：
/// 编码后的 PNG / 磁盘上的文件超 [clipboardImageSizeLimit]，或位图的像素缓冲超 [clipboardBitmapBytesLimit]。
/// 两道门的数不一样，所以提示文案不能写死某一个数（调用方 `ComposerState.pasteImageFromClipboard`）。
/// 没有 runner（flutter_tester、非 Windows）或剪贴板读不到时回空：粘贴文本那一下已经由输入框自己做完了，
/// 这里只是没捞到图，不该把粘贴这件事搞砸。
Future<({List<ClipboardImage> images, bool skippedTooLarge})> readClipboardImages() async {
  const empty = (images: <ClipboardImage>[], skippedTooLarge: false);
  try {
    final items = await AppWindow.invoke<List<Object?>>('readClipboardImages');
    if (items == null) {
      if (Platform.isMacOS) return _readClipboardImagesMac();
      return empty;
    }
    final images = <ClipboardImage>[];
    var skipped = false;
    for (final item in items) {
      if (item is! Map) continue;
      final path = item['path'];
      final Uint8List bytes;
      final String mime;
      if (path is String) {
        final fileMime = imageMimeTypes[_extensionOf(path)];
        if (fileMime == null) continue;
        final file = File(path);
        if (!file.existsSync()) continue;
        final length = await file.length();
        if (length == 0) continue;
        if (length > clipboardImageSizeLimit) {
          skipped = true;
          continue;
        }
        bytes = await file.readAsBytes();
        mime = fileMime;
      } else {
        final width = item['width'];
        final height = item['height'];
        if (width is! int || height is! int) continue;
        if (width * height * 4 > clipboardBitmapBytesLimit) {
          // runner 超过同一个数时只回尺寸、不给像素，所以这里判的是「它已经放弃了」。
          skipped = true;
          continue;
        }
        final bgra = item['bgra'];
        if (bgra is! Uint8List) continue; // 形状不对（不该发生）：不是尺寸问题，别报成「太大」
        final png = await encodePngFromBgra(width, height, bgra);
        if (png == null) continue;
        if (png.length > clipboardImageSizeLimit) {
          skipped = true;
          continue;
        }
        bytes = png;
        mime = 'image/png';
      }
      images.add(ClipboardImage(bytes: bytes, mimeType: mime, path: path is String ? path : null));
    }
    return (images: images, skippedTooLarge: skipped);
  } catch (e) {
    // 剪贴板读不到不该把粘贴这件事搞砸：文本粘贴已经由输入框自己做完了，这里只是没捞到图。
    debugPrint('[clipboard] read failed: $e');
    return empty;
  }
}

/// BGRA 原始像素（32 位）→ PNG 字节。抽出来是为了单测能独立喂像素。
/// 宽高非法或像素数对不上回 null。编码由 dart:ui 在引擎内部做（libpng），单张大图 ~20-50ms。
Future<Uint8List?> encodePngFromBgra(int width, int height, Uint8List bgra) async {
  if (width <= 0 || height <= 0) return null;
  final expected = width * height * 4;
  if (bgra.length != expected) return null;
  final desc = ui.ImageDescriptor.raw(
    await ui.ImmutableBuffer.fromUint8List(bgra),
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.bgra8888,
  );
  final codec = await desc.instantiateCodec();
  final frame = await codec.getNextFrame();
  final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  frame.image.dispose();
  desc.dispose();
  codec.dispose();
  return png?.buffer.asUint8List();
}

/// 按扩展名判 mimeType；认不出来按 PNG 报（Windows 上 file_selector 常常不给 mimeType）。
String imageMimeOf(String path) => imageMimeTypes[_extensionOf(path)] ?? 'image/png';

String _extensionOf(String path) {
  final dot = path.lastIndexOf('.');
  return dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
}

Future<({List<ClipboardImage> images, bool skippedTooLarge})> _readClipboardImagesMac() async {
  Directory? temp;
  try {
    temp = await Directory.systemTemp.createTemp('acp_clipboard');
    final out = '${temp.path}/clipboard.png';
    final result = await Process.run(
      'osascript',
      const <String>['-e', _macScript],
      environment: <String, String>{'ACP_CLIPBOARD_OUT': out},
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 15));
    if (result.exitCode != 0) {
      debugPrint('[clipboard] osascript exit ${result.exitCode}: ${result.stderr}');
      return (images: const <ClipboardImage>[], skippedTooLarge: false);
    }
    final images = <ClipboardImage>[];
    var skipped = false;
    for (final line in const LineSplitter().convert(result.stdout as String)) {
      final sep = line.indexOf('|');
      if (sep <= 0) continue;
      final kind = line.substring(0, sep);
      final value = line.substring(sep + 1).trim();
      if (value.isEmpty) continue;
      final fromFile = kind == 'file';
      final mime = fromFile ? imageMimeTypes[_extensionOf(value)] : 'image/png';
      if (mime == null) continue;
      final file = File(value);
      if (!file.existsSync()) continue;
      final length = await file.length();
      if (length == 0) continue;
      if (length > clipboardImageSizeLimit) {
        skipped = true;
        continue;
      }
      images.add(ClipboardImage(bytes: await file.readAsBytes(), mimeType: mime, path: fromFile ? value : null));
    }
    return (images: images, skippedTooLarge: skipped);
  } catch (e) {
    debugPrint('[clipboard] mac read failed: $e');
    return (images: const <ClipboardImage>[], skippedTooLarge: false);
  } finally {
    try {
      await temp?.delete(recursive: true);
    } catch (e) {
      debugPrint('[clipboard] temp cleanup failed: $e');
    }
  }
}

/// macOS AppleScript（AppKit NSPasteboard）：格式与 Windows 一致（file|<路径> 或 bitmap|<临时 PNG>）。
const String _macScript = '''
use framework "Foundation"
use framework "AppKit"
use scripting additions

set pb to current application's NSPasteboard's generalPasteboard()
set fileUrls to pb's readObjectsForClasses:{current application's NSURL} options:(missing value)
if fileUrls is not missing value and (count of fileUrls) > 0 then
    set outList to ""
    repeat with aUrl in fileUrls
        if aUrl's isFileURL() as boolean then
            set outList to outList & "file|" & (aUrl's |path|() as text) & linefeed
        end if
    end repeat
    if length of outList > 0 then
        return outList
    end if
end if

set imgData to pb's dataForType:(current application's NSPasteboardTypePNG)
if imgData is missing value then
    set tiffData to pb's dataForType:(current application's NSPasteboardTypeTIFF)
    if tiffData is not missing value then
        set imgRep to (current application's NSBitmapImageRep's imageRepsWithData:tiffData)'s firstObject()
        set imgData to imgRep's representationUsingType:(current application's NSBitmapImageFileTypePNG) |properties|:(missing value)
    end if
end if

if imgData is not missing value then
    set outPath to (system attribute "ACP_CLIPBOARD_OUT")
    if outPath is not missing value and outPath is not "" then
        set urlOut to current application's NSURL's fileURLWithPath:outPath
        imgData's writeToURL:urlOut atomically:true
        return "bitmap|" & outPath
    end if
end if
return ""
''';
