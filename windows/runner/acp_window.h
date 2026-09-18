// 无边框窗口与窗口控制的平台通道（docs/design.md § 9 裁定 2026-09-15：runner 自写，不引 window_manager 类库）。
//
// 两件事：
//   1. 去掉系统标题栏，但保留系统的缩放、贴边（Snap）与阴影：`WM_NCCALCSIZE` 吃掉非客户区，
//      `WM_NCHITTEST` 只留四边 / 四角的缩放热区（画板 01–04 的 — ☐ ✕ 画在应用自己的顶栏里）。
//      热区宽度按窗口 DPI 换算，和系统边框一样宽；四角更宽一档。
//   2. MethodChannel `acp/window`：minimize / toggleMaximize / close / isMaximized / startDragging。
//      拖拽区由 Flutter 侧决定——顶栏上没有控件的地方收到 pointer down 就调 `startDragging`，
//      runner 转成 `WM_NCLBUTTONDOWN + HTCAPTION` 交回系统拖窗口。这样顶栏里的按钮与芯片照常可点。
//      连着两次 `startDragging` 落在系统双击阈值内 = 双击标题栏，切最大化 / 还原（合成消息配不出
//      `WM_NCLBUTTONDBLCLK`，系统不会替我们判）。

#ifndef RUNNER_ACP_WINDOW_H_
#define RUNNER_ACP_WINDOW_H_

#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <optional>

// 注册 `acp/window` 通道。`window` 是顶层 HWND。
void AcpWindowRegisterChannel(flutter::FlutterEngine* engine, HWND window);

// 给 Flutter 的子窗口（FLUTTERVIEW）挂一层 subclass，让它在缩放带上回 `HTTRANSPARENT`。
// 不挂这层，四边四角**根本拉不动**：子窗口铺满整个客户区，系统对真实鼠标的命中测试只问它，
// 它回 HTCLIENT，顶层那套 `WM_NCHITTEST` 压根轮不上（2026-09-18 实测：把子窗口缩进 30px
// 就能拉了；而从外部 `SendMessage(WM_NCHITTEST)` 探顶层一直是对的，所以这条骗过了第一次排查）。
void AcpWindowAttachChildHitTest(HWND child);

// 无边框窗口要自己处理的消息；返回 std::nullopt 表示交回默认处理。
std::optional<LRESULT> AcpWindowHandleMessage(HWND window, UINT message,
                                              WPARAM wparam, LPARAM lparam);

#endif  // RUNNER_ACP_WINDOW_H_
