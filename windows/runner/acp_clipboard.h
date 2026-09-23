// 剪贴板图片的原生读取（`acp/window` 通道的 `readClipboardImages`，Dart 侧在 lib/app/clipboard_image.dart）。
//
// 此前 Dart 侧每次 Ctrl+V 都拉一个 powershell.exe、加载 System.Windows.Forms 读剪贴板、把位图存成临时 PNG
// 再读回来删掉；runner 里本来就有这条平台通道，直接走 Win32 就够：
//   - CF_HDROP（资源管理器里复制的文件与目录）→ 路径列表，分文件 / 目录、读字节与按扩展名分图片都在 Dart 侧；
//   - CF_BITMAP（截图工具 / 企业微信截图；系统会从 CF_DIB / CF_DIBV5 自动合成）→ GetDIBits 取 32 位 BGRA 像素，
//     PNG 编码在 Dart 侧用 dart:ui 做，这里不碰 GDI+ / WIC。`include_bitmap` 为 false 时不取位图（agent 不收图）。
// 返回 EncodableList，每项一个 map：{"path": <utf8 路径>} 或 {"width", "height", "bgra": <字节>}；
// 剪贴板打不开或里面既没有文件也没有图 → 空列表（不抛错：粘贴文本那一下不该因为剪贴板读不到而失败）。

#ifndef RUNNER_ACP_CLIPBOARD_H_
#define RUNNER_ACP_CLIPBOARD_H_

#include <flutter/encodable_value.h>

flutter::EncodableValue AcpClipboardReadImages(bool include_bitmap);

#endif  // RUNNER_ACP_CLIPBOARD_H_
