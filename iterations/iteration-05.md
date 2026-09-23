# Iteration 05 — 终端里看得见正在组的字

<!-- 保存为 iterations/iteration-NN.md。一个迭代一个文件、一项一行；流程正本见 iterations/README.md，不在这里复述。 -->

> 状态：进行中　起止：2026-09-23 –　基线：`main` = `34e66be`

BACKLOG P1「等待与反馈」第 1 条。原条目的结论是「要在光标处画出组字串得自己叠一层浮层，属于扩边界，先改设计稿」；
复核发现 xterm 自己就能画（`RenderTerminal.composingText` 是公开 setter），所有者 2026-09-23 裁定按这条做、**不补画板**，偏离记 `design/DIVERGENCE.md` 第 32 条。

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | ux | 终端组字期间在光标处画出正在组的字：`TerminalIme` 把整串写进 xterm 的 `RenderTerminal.composingText`（终端字体 + 下划线），上屏 / 取消 / 失焦 / 连接被关时清掉；前面垫一格，实心块光标不盖首字母；`_ComposingKeeper` 在同一帧 layout 阶段写回（TerminalView 随 shell 输出重建会把它清回 null）。用例 `test/ui/terminal_panel_test.dart` 1 条 | BACKLOG P1「等待与反馈」第 1 条；所有者裁定 2026-09-23 | `claude/floating-layer-stacking-5efef0`（`92edf2b`） | validate 全绿 | 1 轮（cursor），0 条 | 待合并 |

## 收口

- 构建 / 手测：未做。手测项：终端面板里用微软拼音打 `nihao`，光标后出现带下划线的 `nihao`、首字母不被光标盖住；选词上屏后组字串消失、shell 收到「你好」；Esc 取消后组字串消失；组字到一半点到别处（失焦）后组字串消失；跑一个持续输出的命令（如 `ping -t 127.0.0.1`）时组字，组字串不闪；浅色 / 深色两套主题下组字串底色（`Neutral.panel`）与面板底的差别能接受。
- 发版：—
- 移出项去向：—
- 设计稿补注记：`design/DIVERGENCE.md` 第 32 条（画板 61 没画组字态）。

## 备注

### 为什么不叠浮层、也不让系统画

- xterm 4.0.0 的 `RenderTerminal` 本来就有组字串绘制（`_paintComposingText`，从光标格起、终端字体、下划线、底色取主题 background），只是喂它的 `TerminalView._composingText` 是私有状态、只有它自带的 `CustomTextEdit` 会写。渲染对象上的 `composingText` setter 是公开的，`TerminalViewState.renderTerminal` 也是公开的（`_updateCaret` 原本就在用），所以绕开 widget 层直接写渲染对象即可。
- 让系统画（在 runner 的 FLUTTERVIEW subclass 里把 `ISC_SHOWUICOMPOSITIONWINDOW` 加回去、组字消息放给 `DefWindowProc`）的代价：`WM_IME_COMPOSITION` 放给 `DefWindowProc` 会把上屏串再发一遍 `WM_CHAR`；对整窗生效，输入框会双显，要按终端焦点开关就得加平台通道；系统组字窗的长相不受 tokens 管。没选。

### 两处毛刺怎么处理的

- **重建冲掉**：`_TerminalView.updateRenderObject` 每次都 `..composingText = composingText`（那份恒为 null），而 `TerminalPanel` 的 `ListenableBuilder` 在 `LocalTerminal.writeBytes` 每来一段输出都重建。post-frame 写回会先画出一帧空的，输出不断时组字串一直闪；`_ComposingKeeper`（`RenderProxyBox`）在 `updateRenderObject` 里 `markNeedsLayout`，`performLayout` 里写回——build 之后、paint 之前，同一帧生效。它拿到的是紧约束，是 relayout boundary，重排不外溢。
- **块光标盖首字母**：`RenderTerminal._paint` 先画组字串、再在光标格上画实心块光标（`Accent.base`，不透明）。组字串前垫一个空格，光标落在空格那格上。

### 验证

- `flutter test test/ui/terminal_panel_test.dart`：8 条全过（新增 1 条）。
- 反证（临时改实现、跑完换回）：去掉前导空格 → 段落宽度断言红（`Expected: 37.5 (±0.5)`，`Actual: 25.0`，即只有两格）；把 `_ComposingKeeper` 换成 post-frame 写回 → `renderTerminal.debugNeedsPaint` 断言红（`Expected: false`，`Actual: true`，即还要再补一帧）。
- `powershell -File scripts/validate.ps1`（没动 `rust/`，用默认 target）：**VALIDATE OK**。`flutter test` 463 条全过；`flutter analyze` 16 条 info 与基线相同，改动的两个文件没有新增。

### 审查（1 轮，cursor CLI + `grok-4.7-high-fast`）

- `cursor-review.ps1 -Scope since -Base 34e66be -Wait`，产物 `.claude/reviews/20260923-134518-review.out.md`：**findings: 0**。审查对照了 pub 缓存里 xterm 4.0.0 的 `composingText` / `_paintComposingText` 与 `updateRenderObject` 的清回路径。
