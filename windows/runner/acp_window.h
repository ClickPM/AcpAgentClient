// 无边框窗口与窗口控制的平台通道（docs/design.md § 9 裁定 2026-09-15：runner 自写，不引 window_manager 类库）。
//
// 两件事：
//   1. 去掉系统标题栏，但保留系统的缩放、贴边（Snap）与阴影：`WM_NCCALCSIZE` 吃掉非客户区，
//      `WM_NCHITTEST` 只留四边 / 四角的缩放热区（画板 01–04 的 — ☐ ✕ 画在应用自己的顶栏里）。
//   2. MethodChannel `acp/window`：minimize / toggleMaximize / close / isMaximized / startDragging。
//      拖拽区由 Flutter 侧决定——顶栏上没有控件的地方收到 pointer down 就调 `startDragging`，
//      runner 转成 `WM_NCLBUTTONDOWN + HTCAPTION` 交回系统拖窗口。这样顶栏里的按钮与芯片照常可点。

#ifndef RUNNER_ACP_WINDOW_H_
#define RUNNER_ACP_WINDOW_H_

#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <optional>

// 注册 `acp/window` 通道。`window` 是顶层 HWND。
void AcpWindowRegisterChannel(flutter::FlutterEngine* engine, HWND window);

// 无边框窗口要自己处理的消息；返回 std::nullopt 表示交回默认处理。
std::optional<LRESULT> AcpWindowHandleMessage(HWND window, UINT message,
                                              WPARAM wparam, LPARAM lparam);

#endif  // RUNNER_ACP_WINDOW_H_
