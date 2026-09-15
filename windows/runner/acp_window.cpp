#include "acp_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <dwmapi.h>
#include <windowsx.h>

#include <memory>

namespace {

// 缩放热区宽度（逻辑上与系统边框一致；无边框窗口没有可拖的系统边框，这里自己留出来）。
constexpr int kResizeBorder = 8;

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

// 注意不能叫 IsMaximized：winuser.h 把它 #define 成了 IsZoomed，会和系统的重载撞上。
bool IsWindowMaximized(HWND window) {
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(WINDOWPLACEMENT);
  if (!::GetWindowPlacement(window, &placement)) {
    return false;
  }
  return placement.showCmd == SW_SHOWMAXIMIZED;
}

// 最大化时客户区会比工作区大出一圈边框，手动缩回去，否则右边与下边会被裁掉。
void AdjustMaximizedClientRect(HWND window, RECT& rect) {
  if (!IsWindowMaximized(window)) {
    return;
  }
  HMONITOR monitor = ::MonitorFromWindow(window, MONITOR_DEFAULTTONULL);
  if (!monitor) {
    return;
  }
  MONITORINFO info{};
  info.cbSize = sizeof(MONITORINFO);
  if (!::GetMonitorInfo(monitor, &info)) {
    return;
  }
  rect = info.rcWork;
}

LRESULT HitTest(HWND window, LPARAM lparam) {
  POINT cursor{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
  RECT rect{};
  if (!::GetWindowRect(window, &rect)) {
    return HTCLIENT;
  }
  // 最大化时不给缩放热区（和系统行为一致）。
  if (IsWindowMaximized(window)) {
    return HTCLIENT;
  }
  const bool left = cursor.x < rect.left + kResizeBorder;
  const bool right = cursor.x >= rect.right - kResizeBorder;
  const bool top = cursor.y < rect.top + kResizeBorder;
  const bool bottom = cursor.y >= rect.bottom - kResizeBorder;
  if (top && left) return HTTOPLEFT;
  if (top && right) return HTTOPRIGHT;
  if (bottom && left) return HTBOTTOMLEFT;
  if (bottom && right) return HTBOTTOMRIGHT;
  if (left) return HTLEFT;
  if (right) return HTRIGHT;
  if (top) return HTTOP;
  if (bottom) return HTBOTTOM;
  // 其余都交给 Flutter；顶栏的拖拽由 Dart 侧的 startDragging 发起。
  return HTCLIENT;
}

}  // namespace

void AcpWindowRegisterChannel(flutter::FlutterEngine* engine, HWND window) {
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "acp/window",
      &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(
      [window](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const std::string& method = call.method_name();
        if (method == "minimize") {
          ::ShowWindow(window, SW_MINIMIZE);
          result->Success();
        } else if (method == "toggleMaximize") {
          ::ShowWindow(window, IsWindowMaximized(window) ? SW_RESTORE : SW_MAXIMIZE);
          result->Success(flutter::EncodableValue(IsWindowMaximized(window)));
        } else if (method == "close") {
          ::PostMessage(window, WM_CLOSE, 0, 0);
          result->Success();
        } else if (method == "isMaximized") {
          result->Success(flutter::EncodableValue(IsWindowMaximized(window)));
        } else if (method == "startDragging") {
          // 交回系统拖窗口：和拖标题栏完全一样（含贴边 / 甩动最大化）。
          ::ReleaseCapture();
          ::SendMessage(window, WM_NCLBUTTONDOWN, HTCAPTION, 0);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

std::optional<LRESULT> AcpWindowHandleMessage(HWND window, UINT message,
                                              WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_NCCALCSIZE: {
      // 返回 0 且不动矩形 = 客户区铺满整个窗口（无标题栏、无边框），系统仍保留缩放、Snap 与阴影。
      // 两种形态都要接：wParam TRUE 时 lParam 是 NCCALCSIZE_PARAMS（改大小时发），
      // wParam FALSE 时 lParam 是单个 RECT —— 建窗时的第一次计算走的正是这一支（R3 实测：
      // 只处理 TRUE 的话标题栏一直在，因为窗口建好后没再改过大小）。
      RECT* rect = wparam == TRUE
                       ? &reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam)->rgrc[0]
                       : reinterpret_cast<RECT*>(lparam);
      AdjustMaximizedClientRect(window, *rect);
      return 0;
    }
    case WM_NCHITTEST:
      return HitTest(window, lparam);
    default:
      return std::nullopt;
  }
}
