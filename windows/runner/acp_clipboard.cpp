#include "acp_clipboard.h"

#include <windows.h>
#include <shellapi.h>

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

#include "utils.h"

namespace {

// 剪贴板可能正被刚复制完的那个进程占着（.NET 的 Clipboard 也是重试若干次再放弃），最多等 200 ms。
bool OpenClipboardWithRetry() {
  for (int attempt = 0; attempt < 10; ++attempt) {
    if (::OpenClipboard(nullptr)) {
      return true;
    }
    ::Sleep(20);
  }
  return false;
}

struct ClipboardCloser {
  ~ClipboardCloser() { ::CloseClipboard(); }
};

// CF_HDROP：资源管理器里复制的文件。只给路径（UTF-8），是不是图片、字节多大都由 Dart 侧看。
bool ReadFileList(flutter::EncodableList& out) {
  HANDLE handle = ::GetClipboardData(CF_HDROP);
  if (handle == nullptr) {
    return false;
  }
  HDROP drop = static_cast<HDROP>(handle);
  const UINT count = ::DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  for (UINT i = 0; i < count; ++i) {
    const UINT length = ::DragQueryFileW(drop, i, nullptr, 0);
    if (length == 0) {
      continue;
    }
    std::wstring path(static_cast<size_t>(length) + 1, L'\0');
    if (::DragQueryFileW(drop, i, path.data(), length + 1) == 0) {
      continue;
    }
    path.resize(length);
    out.push_back(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("path"), flutter::EncodableValue(Utf8FromUtf16(path.c_str()))},
    }));
  }
  return true;
}

// CF_BITMAP：让 GetDIBits 按我们要的形状取 —— 32 位、自上而下（负高度）。剪贴板位图的 alpha 不可靠
// （截图多半整片是 0，照 alpha 解读就是全透明），一律置成不透明，与此前 System.Drawing 的
// Image.FromHbitmap 一致。
bool ReadBitmap(flutter::EncodableList& out) {
  HBITMAP bitmap = static_cast<HBITMAP>(::GetClipboardData(CF_BITMAP));
  if (bitmap == nullptr) {
    return false;
  }
  BITMAP info{};
  if (::GetObject(bitmap, sizeof(info), &info) == 0 || info.bmWidth <= 0 || info.bmHeight <= 0) {
    return false;
  }
  const int32_t width = static_cast<int32_t>(info.bmWidth);
  const int32_t height = static_cast<int32_t>(info.bmHeight);
  BITMAPINFO header{};
  header.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  header.bmiHeader.biWidth = width;
  header.bmiHeader.biHeight = -height;
  header.bmiHeader.biPlanes = 1;
  header.bmiHeader.biBitCount = 32;
  header.bmiHeader.biCompression = BI_RGB;
  std::vector<uint8_t> pixels(static_cast<size_t>(width) * static_cast<size_t>(height) * 4u);
  HDC dc = ::GetDC(nullptr);
  if (dc == nullptr) {
    return false;
  }
  const int lines = ::GetDIBits(dc, bitmap, 0, static_cast<UINT>(height), pixels.data(), &header, DIB_RGB_COLORS);
  ::ReleaseDC(nullptr, dc);
  if (lines != height) {
    return false;
  }
  for (size_t i = 3; i < pixels.size(); i += 4) {
    pixels[i] = 0xFF;
  }
  out.push_back(flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("width"), flutter::EncodableValue(width)},
      {flutter::EncodableValue("height"), flutter::EncodableValue(height)},
      {flutter::EncodableValue("bgra"), flutter::EncodableValue(std::move(pixels))},
  }));
  return true;
}

}  // namespace

flutter::EncodableValue AcpClipboardReadImages() {
  flutter::EncodableList items;
  if (!OpenClipboardWithRetry()) {
    return flutter::EncodableValue(items);
  }
  ClipboardCloser closer;
  // 顺序与原来一致：先文件列表，再位图。
  if (!ReadFileList(items)) {
    ReadBitmap(items);
  }
  return flutter::EncodableValue(items);
}
