# 画板索引

> **设计稿是功能边界**（CLAUDE.md 规则 3）：设计稿没有的功能一律不做。清单与计数以本文为准。
> 设计工具是 **Claude Design**（所有者裁定 2026-09-14，替代 2026-09-12 裁定的 Figma Make）。产物是每画板一个 `.dc.html` 文件加一份 `canvas.json` 布局清单，**源文件与每画板一张 PNG 快照都入库**：`.dc.html` 是设计的唯一事实来源，PNG 是审查与验收的基准。画布（claude.ai/design，或 Claude Code 内 `/design` 发布的画布）上的后续改动不影响已开工轮次；改设计走「先拉回 `.dc.html`、重导 PNG、更新本索引，再进轮次」。
> **画板编号只增不改、不重排**；废弃的画板留「已废弃」占位。

## 约定

- 每个设计轮一个目录 `design/round-NN/`：
  - `input/`：整个目录交给 Claude Design。含 `design-prompt.md` 设计简报（风格与 token 约束，以及对 `docs/acp-projection.md` 可投影面的覆盖要求）、附件（原型与截图副本、参考文档快照）、预排的 `canvas.json` 与用法说明 `README.md`。
  - `NN-<画板短名>.dc.html`：画板源，一画板一文件，文件名即画板身份，编号与下表一致；文件名只用字母、数字、连字符与下划线。
  - `canvas.json`：画布布局清单，记各画板的位置与 frame 尺寸。桌面画板的 frame 尺寸在首轮 `design-prompt.md` 里定一次，后续画板沿用。
  - `NN-<画板短名>.png`：画板快照，由 `scripts/render-design.ps1` 从同名 `.dc.html` 渲染（headless Edge，scale 1，尺寸 = 文件内的 `$preview`），编号与 `.dc.html` 一致。画布自带的 PNG 导出件不作基准，它的字体度量与浏览器不同，会出现假换行。
  - `support.js`：Claude Design 的画板运行时，与 `.dc.html` 同目录才能直接用浏览器打开；每轮一份副本。
- **首个设计轮先出 `00-tokens` 画板**（色阶 / 字阶 / 间距 / 圆角 / 动效时长），页面画板都从它取值。
- token 提炼：只从 `00-tokens` 画板的 `.dc.html`（`<helmet><style>` 与内联样式）提炼到 `lib/theme/tokens.dart`，不从页面画板反推；该文件是样式唯一来源，每次设计轮结束时同步更新并在下表「token 变更」列记一句。
- `.dc.html` 是 HTML 加内联样式，**只作设计源，不复用为代码**；组件全部从画板手写（CLAUDE.md 规则 1 / 3）。
- 画布上 Save 过的改动，先读回仓库覆盖 `design/round-NN/` 里的源文件，再跑 `scripts/render-design.ps1` 重渲染 PNG；不在画布与仓库两边各改一份。
- 每张画板的实现轮次与 widget 文件见仓库根 `ROUNDS.md` § 2；实现轮收口时把下表「状态」改为 `已实现（R<N>）`。

## 画板

| 编号 | 名称 | 页面 | 设计轮 | .dc.html | PNG | 画布 URL | 状态 | token 变更 |
|---|---|---|---|---|---|---|---|---|
| 00 | Token 表 | 全局 | round-design | `design/round-design/00-tokens.dc.html` | `design/round-design/00-tokens.png` | — | 已实现（R0） | 首版 token 表（浅色 + 深色色阶、accent、语义色、字阶、圆角、间距、kbd、动效） |
| 01 | 工作台 · 新会话 | 会话工作台 | round-design | `design/round-design/01-workbench-empty.dc.html` | `design/round-design/01-workbench-empty.png` | — | 待实现 | — |
| 02 | 工作台 · 进行中的一轮 | 会话工作台 | round-design | `design/round-design/02-workbench-running.dc.html` | `design/round-design/02-workbench-running.png` | — | 待实现 | — |
| 03 | 工作台 · 回合结束 + 右栏展开 | 会话工作台 + 文件面板 | round-design | `design/round-design/03-workbench-done.dc.html` | `design/round-design/03-workbench-done.png` | — | 待实现 | — |
| 04 | 侧栏与顶栏状态 | 会话工作台 | round-design | `design/round-design/04-sidebar-states.dc.html` | `design/round-design/04-sidebar-states.png` | — | 待实现 | — |
| 10 | Restore Checkpoint 分隔线 | 转录 | round-design | `design/round-design/10-checkpoint.dc.html` | `design/round-design/10-checkpoint.png` | — | 已实现（R2） | — |
| 11 | 用户消息气泡 | 转录 | round-design | `design/round-design/11-user-message.dc.html` | `design/round-design/11-user-message.png` | — | 已实现（R2） | — |
| 12 | 助手富文本正文 | 转录 | round-design | `design/round-design/12-assistant-text.dc.html` | `design/round-design/12-assistant-text.png` | — | 已实现（R2） | — |
| 13 | 代码块卡片 | 转录 | round-design | `design/round-design/13-code-block.dc.html` | `design/round-design/13-code-block.png` | — | 已实现（R2） | — |
| 14 | GFM 表格 | 转录 | round-design | `design/round-design/14-gfm-table.dc.html` | `design/round-design/14-gfm-table.png` | — | 已实现（R2） | — |
| 15 | Mermaid 图 | 转录 | round-design | `design/round-design/15-mermaid.dc.html` | `design/round-design/15-mermaid.png` | — | 已实现（R2） | — |
| 16 | 数学公式 | 转录 | round-design | `design/round-design/16-math.dc.html` | `design/round-design/16-math.png` | — | 已实现（R2） | — |
| 17 | 思考折叠块 | 转录 | round-design | `design/round-design/17-thinking.dc.html` | `design/round-design/17-thinking.png` | — | 已实现（R2） | — |
| 18 | 标准工具调用卡 | 转录 | round-design | `design/round-design/18-tool-call.dc.html` | `design/round-design/18-tool-call.png` | — | 已实现（R2） | — |
| 19 | 工具调用失败卡 | 转录 | round-design | `design/round-design/19-tool-failed.dc.html` | `design/round-design/19-tool-failed.png` | — | 已实现（R2） | — |
| 20 | 工具已取消卡 | 转录 | round-design | `design/round-design/20-tool-cancelled.dc.html` | `design/round-design/20-tool-cancelled.png` | — | 已实现（R2） | — |
| 21 | 文件差异对比卡 | 转录 | round-design | `design/round-design/21-diff-card.dc.html` | `design/round-design/21-diff-card.png` | — | 已实现（R2） | — |
| 22 | 嵌入式终端控制台卡 | 转录 | round-design | `design/round-design/22-terminal-card.dc.html` | `design/round-design/22-terminal-card.png` | — | 已实现（R2） | — |
| 23 | 终端进行中卡 | 转录 | round-design | `design/round-design/23-terminal-running.dc.html` | `design/round-design/23-terminal-running.png` | — | 已实现（R2） | — |
| 24 | 子代理委派卡 | 转录 | round-design | `design/round-design/24-subagent.dc.html` | `design/round-design/24-subagent.png` | — | 已实现（R2） | — |
| 25 | 权限授权卡 | 转录 | round-design | `design/round-design/25-permission.dc.html` | `design/round-design/25-permission.png` | — | 已实现（R2） | — |
| 26 | Awaiting Confirmation | 转录 + 输入框上方 | round-design | `design/round-design/26-awaiting.dc.html` | `design/round-design/26-awaiting.png` | — | 已实现（R2） | — |
| 27 | 表单模式交互卡 | 转录 | round-design | `design/round-design/27-elicitation-form.dc.html` | `design/round-design/27-elicitation-form.png` | — | 已实现（R2） | — |
| 28 | 链接跳转交互卡 | 转录 | round-design | `design/round-design/28-elicitation-url.dc.html` | `design/round-design/28-elicitation-url.png` | — | 已实现（R2） | — |
| 29 | 计划卡 | 转录 | round-design | `design/round-design/29-plan.dc.html` | `design/round-design/29-plan.png` | — | 已实现（R2） | — |
| 30 | 上下文窗口浮窗 | 输入框 | round-design | `design/round-design/30-context-window.dc.html` | `design/round-design/30-context-window.png` | — | 已实现（R2） | — |
| 31 | 回合态与结束 | 线程头 + 输入框 + 转录 | round-design | `design/round-design/31-turn-state.dc.html` | `design/round-design/31-turn-state.png` | — | 已实现（R2） | — |
| 32 | 非文本内容块 | 转录 | round-design | `design/round-design/32-content-blocks.dc.html` | `design/round-design/32-content-blocks.png` | — | 已实现（R2） | — |
| 33 | 上下文压缩卡 | 转录 | round-design | `design/round-design/33-compaction.dc.html` | `design/round-design/33-compaction.png` | — | 已实现（R2） | — |
| 34 | agent 状态与错误 | 线程头下 / 转录 | round-design | `design/round-design/34-agent-state.dc.html` | `design/round-design/34-agent-state.png` | — | 已实现（R2） | — |
| 40 | 输入框弹层合集 | 会话工作台 | round-design | `design/round-design/40-composer-popovers.dc.html` | `design/round-design/40-composer-popovers.png` | — | 待实现 | — |
| 41 | 顶栏与侧栏弹层合集 | 会话工作台 | round-design | `design/round-design/41-topbar-popovers.dc.html` | `design/round-design/41-topbar-popovers.png` | — | 待实现 | — |
| 42 | 输入框内联菜单 | 会话工作台 | round-design | `design/round-design/42-inline-menus.dc.html` | `design/round-design/42-inline-menus.png` | — | 待实现 | — |
| 50 | Agents 面板（ACP Registry） | agent 管理 | round-design | `design/round-design/50-registry.dc.html` | `design/round-design/50-registry.png` | — | 待实现 | — |
| 51 | Registry 条目状态 | agent 管理 | round-design | `design/round-design/51-registry-states.dc.html` | `design/round-design/51-registry-states.png` | — | 待实现 | — |
| 52 | agent 认证 | agent 管理 | round-design | `design/round-design/52-auth.dc.html` | `design/round-design/52-auth.png` | — | 待实现 | — |
| 60 | 文件面板 | 文件面板 | round-design | `design/round-design/60-files-panel.dc.html` | `design/round-design/60-files-panel.png` | — | 待实现 | — |
| 61 | 终端面板 | 文件面板（右栏） | round-design | `design/round-design/61-terminal-panel.dc.html` | `design/round-design/61-terminal-panel.png` | — | 待实现 | — |
| 70 | 设置 | 设置 | round-design | `design/round-design/70-settings.dc.html` | `design/round-design/70-settings.png` | — | 待实现 | — |
| 80 | ACP 流量调试 | ACP 流量调试 | round-design | `design/round-design/80-traffic.dc.html` | `design/round-design/80-traffic.png` | — | 待实现 | — |

状态取值：`待实现` / `已实现（R<N>）` / `已废弃`。

## 变更记录（入库后对 `.dc.html` 的改动，PNG 已用 `scripts/render-design.ps1` 重渲染）

- 2026-09-15 画板 40：`+` 弹层删去 Symbols 与 Selection 两行。需要 LSP 与编辑器选区，与 `docs/requirements.md`「不做」冲突；所有者裁定，见 `ROUNDS.md` § 6。
- 2026-09-15 画板 42：`/` 命令菜单合并为单组（保留 Commands 标题），去掉 Skills 分组标题与右侧的 built-in / 项目名来源标签；`<path>` 参数提示保留。`AvailableCommand` 只有 name / description / input，没有分组与来源字段；所有者裁定，见 `ROUNDS.md` § 6。

## 页面与画板的对应

按 `docs/design.md` § 9 的页面清单：会话工作台、agent 管理、文件面板、设置、ACP 流量调试。每个页面至少一张画板；会话工作台需覆盖 `docs/acp-projection.md` 列出的 15 个 `session/update` 变体、权限请求、elicitation（form / url）、终端、5 种内容块、多计划载荷与压缩卡片。
