# 画板索引

> **设计稿是功能边界**（CLAUDE.md 规则 3）：设计稿没有的功能一律不做。清单与计数以本文为准。
> 设计工具是 **Figma Make**（所有者裁定 2026-09-12），产物在 Figma 云端；本仓库只入库**每个画板一张 PNG 快照**作为审查与验收的基准。Make 文件后续改动不影响已开工轮次；改设计走「先更新 PNG 与本索引，再进轮次」。
> **画板编号只增不改、不重排**；废弃的画板留「已废弃」占位。

## 约定

- 每个设计轮一个目录 `design/round-NN/`：
  - `design-prompt.md`：喂给 Figma Make 的提示词（含对 `docs/acp-projection.md` 可投影面的覆盖要求）。
  - `NN-<画板短名>.png`：画板快照，编号与下表一致；宽度按 Make 原型的桌面断点导出，不缩放。
- token 提炼：从 Make 产物提炼颜色 / 字号 / 间距 / 圆角 / 动效时长到 `lib/theme/tokens.dart`，该文件是样式唯一来源；每次设计轮结束时同步更新并在下表「token 变更」列记一句。
- Figma MCP（`get_screenshot` / `get_design_context` / `get_variable_defs`）只作对照与提炼辅助，输出不直接入库；组件全部从画板手写。

## 画板

| 编号 | 名称 | 页面 | 设计轮 | Make URL | PNG | 状态 | token 变更 |
|---|---|---|---|---|---|---|---|
| | | | | | | | |

状态取值：`待实现` / `已实现（R<N>）` / `已废弃`。

## 页面与画板的对应

按 `docs/design.md` § 9 的页面清单：会话工作台、agent 管理、文件面板、设置、ACP 流量调试。每个页面至少一张画板；会话工作台需覆盖 `docs/acp-projection.md` 列出的 15 个 `session/update` 变体、权限请求、elicitation（form / url）、终端、5 种内容块、多计划载荷与压缩卡片。
