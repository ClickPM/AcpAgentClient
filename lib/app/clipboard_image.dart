// 输入框的图片粘贴（Ctrl+V）：Flutter 的 `Clipboard` 只给 text/plain，位图与文件列表都取不到，
// 第三方剪贴板包又在 CLAUDE.md 规则 1 的清单之外，所以 Windows（规则 9 首发）由 runner 直接走 Win32 读一次
// 剪贴板（`acp/window` 通道的 `readClipboardImages`，windows/runner/acp_clipboard.cpp）：先看文件列表
// （资源管理器里复制的图片文件），再看位图（截图工具 / 企业微信截图）。位图回来的是 BGRA 像素，PNG 编码在
// 这里用 dart:ui 自带的编码器做，不落临时文件、不拉子进程。
// 非 Windows 暂时返回空（macOS / Linux 的实现记在 rounds/BACKLOG.md）。

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
    if (items == null) return empty;
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
    debugPrint('[clipboard] read failed: $e');
    return empty;
  }
}

/// 自上而下的 BGRA 像素 → PNG（dart:ui 自带的编码器，不引图像库）。像素数与尺寸对不上、或引擎编不出来时回 null，
/// 不抛：四个 native 对象各自建成多少就释放多少（任一步抛错都不能把前面的留在引擎里）。
Future<Uint8List?> encodePngFromBgra(int width, int height, Uint8List bgra) async {
  if (width <= 0 || height <= 0 || bgra.length != width * height * 4) return null;
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bgra);
    descriptor = ui.ImageDescriptor.raw(buffer, width: width, height: height, pixelFormat: ui.PixelFormat.bgra8888);
    codec = await descriptor.instantiateCodec();
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (e) {
    debugPrint('[clipboard] png encode failed: $e');
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// 按扩展名判 mimeType；认不出来按 PNG 报（Windows 上 file_selector 常常不给 mimeType）。
String imageMimeOf(String path) => imageMimeTypes[_extensionOf(path)] ?? 'image/png';

String _extensionOf(String path) {
  final dot = path.lastIndexOf('.');
  return dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
}
