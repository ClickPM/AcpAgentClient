# AcpAgent Client 设计稿修订 09 · Agents 面板的进程与内存（画板 54）

> 本次修订对应轮次：`round-10`（任务卡 `rounds/round-10/round-10.md`，目标版本 v1.6.0）。
> 本次**只做一件事**：新增画板 54「Agents 面板 · 进程与内存」。**画板 50 / 51 / 53 不重绘**：画板 54 定义的是叠加在它们之上的运行态，未连接的条目与它们完全一致。
> 本稿由主会话直接写 `.dc.html` 入库（2026-10-18），未经 Claude Design 画布；要在画布上继续改，先把本地文件推上去，改完照 `design/README.md` 的约定拉回、重渲 PNG。

## 0. 要解决的问题与裁定

两条诉求（所有者 2026-10-18）：

1. 看本应用及其子进程一共吃了多少内存。
2. 能停掉任何一个正在跑的 agent：pi-acp、agy 等不声明 `sessionCapabilities.close`，侧栏「挂起」对它们不出现，拉起后界面上没有办法停。

裁定（所有者 2026-10-18）：

- 进程与内存在 Rust 核心里用 `sysinfo` 采样（进白名单）。
- 内存口径：**专用内存**（Windows Private Bytes），合计按子进程求和、带「约」。
- 位置：**并进 Agents 面板**（画板 50）：标题行下资源概览条，运行中的条目加运行行 / 进程树 / Stop。不加右栏新标签、不加顶栏徽标。
- 终端：**只展示**，归「终端」段，不在这里给停止。

## 1. 画板 54 的内容（1200 × 1830，page-4 `x 5360, y 0`）

- **A · 面板全貌 + 规格表 A / B / C**：
  - 资源概览条：本机内存合计（大字）、口径名 + info 悬停整句、三段分段条（本应用 `Neutral.placeholder` / Agents `Accent.base` / 终端 `Neutral.border`）、图例行。
  - 过滤行加 `Running N`（待所有者确认，见任务卡）。
  - 运行中的条目：名字行 `运行中` 芯片（success + 6px 圆点）；描述下运行行 `PID · N 个进程 · 约 X MB · 已运行时长 · N 个会话`，chevron 展开进程树（名字 / PID / 专用内存，缩进 16 px 一级；agent 开的终端顶层显示并标 `agent 终端 <terminalId>`）；右侧 `Stop`（ghost 中性按钮 + 画板 23 的红色停止方块），顺序 Stop · Update · Remove。
  - 连接中：运行行换 spinner + 「连接中…」，不出 Stop。
- **B · 停止流程**：B1 有会话 → 确认弹层（画板 41 删除确认的样式）；B2 有回合在跑 / 等你处理 → 弹层里加 warning 色块说明后果，按钮「仍然停止」；B3 停止中（无会话时直接进这一态，不弹确认）：spinner + 「正在停止…」+ 小字「先请 agent 自行退出，3 秒后仍在就结束整棵进程树」，Stop 置灰。
- **C · 概览条其他态**：没有 agent 在运行；首次采样中（图例行留高）；采样失败（「无法读取进程信息」+ 刷新图标，停表等手动重试）。
- **新增 token**（只有几何）：`resource.barHeight` 4、`resource.legendSwatch` 8、`resource.sampleInterval` 2 s、`processTree.rowHeight` 22、`processTree.indent` 16、`processTree.pidWidth` / `bytesWidth` 64 / 84。颜色全部复用画板 00 / 07，深色按画板 07 逐项对位，不另画。

## 2. 明确不做

不做「全部停止」、空闲自动停止、内存阈值告警、历史曲线；不在侧栏 / 顶栏 / 会话头加入口；终端不给停止；Stop 不按 agent 能力或名字裁剪。
