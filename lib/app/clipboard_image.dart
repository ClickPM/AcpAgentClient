// 输入框的图片粘贴（Ctrl+V）：Flutter 的 `Clipboard` 只给 text/plain，位图与文件列表都取不到，
// 第三方剪贴板包又在 CLAUDE.md 规则 1 的清单之外，所以 Windows（规则 9 首发）借 PowerShell 的
// `System.Windows.Forms.Clipboard` 读一次剪贴板：先看文件列表（资源管理器里复制的图片文件），
// 再看位图（截图工具 / 企业微信截图），位图存成临时 PNG 再读回字节，读完删临时目录。
// 非 Windows 暂时返回空（macOS / Linux 的实现记在 rounds/BACKLOG.md）。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

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
/// 撑到桥接与 agent 都难受，超了的直接跳过并回报（调用方写进错误条）。
const int clipboardImageSizeLimit = 20 * 1024 * 1024;

/// 读一次剪贴板里的图片。`skippedTooLarge` = 有图但超过 [clipboardImageSizeLimit] 被跳过了。
Future<({List<ClipboardImage> images, bool skippedTooLarge})> readClipboardImages() async {
  if (!Platform.isWindows) return (images: const <ClipboardImage>[], skippedTooLarge: false);
  Directory? temp;
  try {
    temp = await Directory.systemTemp.createTemp('acp_clipboard');
    final out = '${temp.path}/clipboard.png';
    final result = await Process.run(
      'powershell.exe',
      const <String>['-NoProfile', '-NonInteractive', '-Sta', '-Command', _script],
      environment: <String, String>{_outVar: out},
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 15));
    if (result.exitCode != 0) {
      debugPrint('[clipboard] powershell exit ${result.exitCode}: ${result.stderr}');
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
      // 0 字节也跳过：脚本里 `$img.Save(...)` 抛异常（GDI+ 报错 / 磁盘满 / 杀软占用）时 PowerShell
      // 只终止那一条语句、照常打印 `bitmap|<路径>` 且退出码 0，不判下限就会发出一个空的 `image` 块。
      if (length == 0) continue;
      if (length > clipboardImageSizeLimit) {
        skipped = true;
        continue;
      }
      images.add(ClipboardImage(bytes: await file.readAsBytes(), mimeType: mime, path: fromFile ? value : null));
    }
    return (images: images, skippedTooLarge: skipped);
  } catch (e) {
    // 剪贴板读不到不该把粘贴这件事搞砸：文本粘贴已经由输入框自己做完了，这里只是没捞到图。
    debugPrint('[clipboard] read failed: $e');
    return (images: const <ClipboardImage>[], skippedTooLarge: false);
  } finally {
    try {
      await temp?.delete(recursive: true);
    } catch (e) {
      debugPrint('[clipboard] temp cleanup failed: $e');
    }
  }
}

/// 按扩展名判 mimeType；认不出来按 PNG 报（Windows 上 file_selector 常常不给 mimeType）。
String imageMimeOf(String path) => imageMimeTypes[_extensionOf(path)] ?? 'image/png';

String _extensionOf(String path) {
  final dot = path.lastIndexOf('.');
  return dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
}

/// 临时 PNG 的落点走环境变量，不拼进脚本文本：省掉一层引号转义，路径含空格 / 中文也不用管（规则 9）。
const String _outVar = 'ACP_CLIPBOARD_OUT';

/// 输出一行一项：`file|<路径>`（剪贴板里的文件列表）或 `bitmap|<临时 PNG>`（剪贴板里的位图）。
/// 两者都只输出路径，字节由 Dart 侧读——base64 走 stdout 会撞上 PowerShell 的重定向换行宽度。
const String _script = r"[Console]::OutputEncoding = [Text.Encoding]::UTF8; "
    r"Add-Type -AssemblyName System.Windows.Forms; "
    r"Add-Type -AssemblyName System.Drawing; "
    r"$files = [Windows.Forms.Clipboard]::GetFileDropList(); "
    r"if ($files.Count -gt 0) { foreach ($p in $files) { Write-Output ('file|' + $p) }; exit 0 }; "
    r"$img = [Windows.Forms.Clipboard]::GetImage(); "
    r"if ($img -ne $null) { $img.Save($env:ACP_CLIPBOARD_OUT, [Drawing.Imaging.ImageFormat]::Png); $img.Dispose(); "
    r"Write-Output ('bitmap|' + $env:ACP_CLIPBOARD_OUT) }";
