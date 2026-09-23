#include "acp_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>
#include <commctrl.h>
#include <dwmapi.h>
#include <windowsx.h>

#include <cstdlib>
#include <memory>

#include "acp_clipboard.h"

namespace {

// 缩放热区宽度，**逻辑**像素（无边框窗口没有可拖的系统边框，这里自己留出来）。
// 取值与系统边框一致：`SM_CXSIZEFRAME`(4) + `SM_CXPADDEDBORDER`(4)。
// 不能写死物理像素：R3 原来的「8 物理像素」在 175% 缩放下只剩 4.6 逻辑像素，
// 边上又没有任何可见边框可瞄，所有者实测「四边四角拉不动」（2026-09-17）。
constexpr int kResizeBorder = 8;

// 四角的对角热区比边宽一倍（系统也是这样）：贴着角的那几像素要能直接拉对角，而不是只拉到单边。
constexpr int kResizeCorner = kResizeBorder * 2;

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

// 上一次 `startDragging` 的时刻与光标位置，用来自己判双击（见 ConsumeDoubleClick）。
ULONGLONG g_last_drag_ms = 0;
POINT g_last_drag_point{};

// 逻辑像素按窗口当前 DPI 换成物理像素（`WM_NCHITTEST` 的坐标是物理像素）。
int ToPhysical(HWND window, int logical) {
  UINT dpi = ::FlutterDesktopGetDpiForHWND(window);
  if (dpi == 0) {
    dpi = USER_DEFAULT_SCREEN_DPI;
  }
  return ::MulDiv(logical, static_cast<int>(dpi), USER_DEFAULT_SCREEN_DPI);
}

// 顶栏双击 = 最大化 / 还原。Flutter 侧顶栏空白处每次 pointer down 都调 `startDragging`，
// 而 `SendMessage(WM_NCLBUTTONDOWN)` 是合成消息，系统不会把连着的两次配成 `WM_NCLBUTTONDBLCLK`，
// 所以双击只能在这里自己判：两次调用的间隔与位移都在系统阈值内就算双击。
bool ConsumeDoubleClick() {
  POINT cursor{};
  if (!::GetCursorPos(&cursor)) {
    return false;
  }
  const ULONGLONG now = ::GetTickCount64();
  const ULONGLONG previous_ms = g_last_drag_ms;
  const POINT previous_point = g_last_drag_point;
  g_last_drag_ms = now;
  g_last_drag_point = cursor;
  if (previous_ms == 0 || now - previous_ms > ::GetDoubleClickTime()) {
    return false;
  }
  if (std::abs(cursor.x - previous_point.x) > ::GetSystemMetrics(SM_CXDOUBLECLK) / 2 ||
      std::abs(cursor.y - previous_point.y) > ::GetSystemMetrics(SM_CYDOUBLECLK) / 2) {
    return false;
  }
  // 三击不要再判成「第二次双击」，否则连点会来回抽。
  g_last_drag_ms = 0;
  return true;
}

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
// 显示器按 `rect`（系统提议的新窗口矩形）找，不能按窗口当前位置：最大化窗口从最小化还原时，
// 这条消息到的那一刻窗口还停在 (-32000,-32000)，`MonitorFromWindow(DEFAULTTONULL)` 回 NULL，
// 修正被跳过，整个画面四边各溢出屏幕一圈边框（所有者报障「用一阵后顶栏与底栏按钮偏移」，2026-09-23）。
// Chromium 的 HWNDMessageHandler::OnNCCalcSize 在同一处有同样的说明。
void AdjustMaximizedClientRect(HWND window, RECT& rect) {
  if (!IsWindowMaximized(window)) {
    return;
  }
  HMONITOR monitor = ::MonitorFromRect(&rect, MONITOR_DEFAULTTONEAREST);
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
  const int border = ToPhysical(window, kResizeBorder);
  const int corner = ToPhysical(window, kResizeCorner);
  const bool left = cursor.x < rect.left + border;
  const bool right = cursor.x >= rect.right - border;
  const bool top = cursor.y < rect.top + border;
  const bool bottom = cursor.y >= rect.bottom - border;
  // 角：一轴落在边框带里、另一轴落在更宽的角带里就算角（两条边各自向内延出一段对角区）。
  const bool corner_left = cursor.x < rect.left + corner;
  const bool corner_right = cursor.x >= rect.right - corner;
  const bool corner_top = cursor.y < rect.top + corner;
  const bool corner_bottom = cursor.y >= rect.bottom - corner;
  if ((top && corner_left) || (left && corner_top)) return HTTOPLEFT;
  if ((top && corner_right) || (right && corner_top)) return HTTOPRIGHT;
  if ((bottom && corner_left) || (left && corner_bottom)) return HTBOTTOMLEFT;
  if ((bottom && corner_right) || (right && corner_bottom)) return HTBOTTOMRIGHT;
  if (left) return HTLEFT;
  if (right) return HTRIGHT;
  if (top) return HTTOP;
  if (bottom) return HTBOTTOM;
  // 其余都交给 Flutter；顶栏的拖拽由 Dart 侧的 startDragging 发起。
  return HTCLIENT;
}

// FLUTTERVIEW 的 subclass：只拦 `WM_NCHITTEST`，落在缩放带里就回 `HTTRANSPARENT`，
// 系统才会继续往下问到父窗口（见 acp_window.h 的说明）。其余消息原样交回 Flutter。
LRESULT CALLBACK ChildHitTestProc(HWND child, UINT message, WPARAM wparam, LPARAM lparam,
                                  UINT_PTR id, DWORD_PTR data) {
  switch (message) {
    case WM_NCHITTEST: {
      HWND parent = ::GetParent(child);
      if (parent != nullptr && HitTest(parent, lparam) != HTCLIENT) {
        return HTTRANSPARENT;
      }
      break;
    }
    case WM_NCDESTROY:
      ::RemoveWindowSubclass(child, ChildHitTestProc, id);
      break;
    default:
      break;
  }
  return ::DefSubclassProc(child, message, wparam, lparam);
}

}  // namespace

void AcpWindowAttachChildHitTest(HWND child) {
  ::SetWindowSubclass(child, ChildHitTestProc, 1, 0);
}

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
          if (ConsumeDoubleClick()) {
            // 双击顶栏 = 最大化 / 还原（和系统标题栏一致）。
            ::ShowWindow(window, IsWindowMaximized(window) ? SW_RESTORE : SW_MAXIMIZE);
          } else {
            // 交回系统拖窗口：和拖标题栏完全一样（含贴边 / 甩动最大化）。
            ::ReleaseCapture();
            ::SendMessage(window, WM_NCLBUTTONDOWN, HTCAPTION, 0);
          }
          result->Success();
        } else if (method == "readClipboardImages") {
          // 剪贴板图片（acp_clipboard.h）：Dart 侧的 Ctrl+V 不再拉 powershell 读剪贴板。
          result->Success(AcpClipboardReadImages());
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
