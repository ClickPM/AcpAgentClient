# 品牌标记

> 应用图标与应用内标记。**不是画板**：不进 `design/README.md` 的画板索引，也不走 `scripts/render-design.ps1`。
> 画板 01–04 里侧栏顶部画的那个方框 ☒ 是 R3 的占位，已由本标记取代。

## 定稿

字母 **A** 的横杠画成**三节点链路**——ACP 把多个 agent 串成一条协议链路。所有者裁定 2026-09-17。

取稿自 `gemini-3.1-flash-image` 生成的候选（`app-logo-reference.jpg`，1024×1024 JPEG，位图只作来源留档、不参与构建）。
裁定后按该候选的几何矢量重绘为 `app-icon.svg`：位图没法出 16px 与多尺寸 `.ico`，也对不上 token 配色。

配色只用 `lib/theme/tokens.dart` 的值：底板 `Neutral.canvas` `#FBFBFC`、字母 `Neutral.strong` `#1E1E26`、链路 `Accent.base` `#5566D8`。

## 两份产物，一份几何

| 用处 | 文件 | 说明 |
|---|---|---|
| Windows 应用图标 | `app-icon.svg` → `windows/runner/resources/app_icon.ico` | 带底板。跑 `powershell -File scripts/render-icon.ps1` 重出，含 16 / 24 / 32 / 48 / 64 / 128 / 256 七帧，每帧 PNG 压缩、底板圆角外透明 |
| 应用内标记（侧栏顶部） | `lib/ui/shell/app_logo.dart` | 无底板，viewBox 收到标记外框；SVG 在 Dart 里按 token 拼，规则 3 不许写颜色字面量，所以不读本目录的 `.svg` |

**几何是同一份**（256 视口，A 的路径 `M69 190 L128 61 L187 190` / 描边 28 / 链路 y=149 三点 x=53,128,203）。
改了形状要两边一起改，再跑 `scripts/render-icon.ps1`。

macOS / Linux 的 runner 目录还没建（R8），到时候的图标一并从 `app-icon.svg` 出。
