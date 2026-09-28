# AcpAgent Client 设计稿修订 08 · 回合进行中的发送队列（Send Queue）

> 本次修订对应轮次：`round-send-queue`（任务卡 `rounds/round-send-queue/round-send-queue.md`）。
> 状态机完全对齐 Zed `message_queue.rs`（三态：AutoProcess / Paused / AbsorbingCancel 与 fast-track 插队）。
> 本次**只做两件事**：① 新增画板 44「本地发送队列」；② 画板 02「工作台 · 进行中的一轮」补入停靠态。其余画板一律不重绘。
> 本次**不新增颜色、不新增 token**：严格复用画板 00 的 `radius.6`、`surfaceSubtle`（#eeeef1）、`borderDefault`（#e2e2e7）、`warning`（#8a6f12，Paused 态）与画板 26 已有的输入框停靠条规范。

## 0. 要解决的问题与裁定汇总

用户在 Agent 回合运行中无法输入或排队消息（过去输入框被禁用或吞键）。
本次裁定：
- **纯本地内存态**：每个会话独立维护发送队列，只用标准 ACP `session/prompt` 与 `session/cancel`，核心与桥零改动，不进投影层。
- **状态机三态**：
  - `AutoProcess`：正常排队，回合结束后自动按 FIFO 依次发出；
  - `Paused`：上一轮报错或用户手动 Stop 后挂起，防止错误连发放大，等用户恢复或再次发送；
  - `AbsorbingCancel`：用户触发 `Send Now` 插队，发送 `session/cancel` 吞掉在途回合后，立即只发出该条。
- **交互边界**：
  - 输入框上方一格 dock 停靠条（与等待条同一排）；
  - 折叠态：显示「N 条排队消息」+ 展开 / 全部清空；
  - 展开态：排队列表，每条支持 `Send Now ⏎`、挪回输入框编辑（`↑`）、删除；
  - 回合中输入框：保持可用，按 Enter 入队，不修改输入框既有样式和提示语。

---

## 1. 新增画板 44 · Send Queue

- 编号与标题：`44 · Send Queue`
- 副标：`本地发送队列`
- 协议来源行：`协议来源：客户端本地内存态（对齐 Zed message_queue.rs）`
- 说明行：`回合进行中按 Enter 入队，回合结束后自动按序发出；支持 Send Now 插队、编辑回退与清空`

### 内容构成
1. **输入框上方的停靠条 · 运行状态**：
   - AutoProcess：`2 条排队消息` + `展开` / `全部清空`
   - Paused：`队列已暂停 · 2 条排队消息`（警告黄）+ `恢复出队` / `清空`
   - AbsorbingCancel：`正在打断当前回合并发送...`（强调蓝）
2. **输入框上方的停靠条 · 展开态**：
   - 卡片明细，每行 `#N` 序号、文本与附件芯片、`Send Now ⏎`、挪回编辑、删除。
3. **工作台实景结合**：
   - 停靠条位于现有输入框上方，现有输入框完全 100% 保持 02 画板原样。
4. **状态机与键位口径表**：
   - 记录 Enter 入队、空框 Enter 插队、空框 ↑ 回退编辑、Paused 保护、多会话生命周期。

---

## 2. 修改画板 02 · 工作台 · 进行中的一轮

在画板 02 的输入框上方 docks 区域中，加入一行发送队列 dock 停靠条（1 条排队消息，展开/清空）。
