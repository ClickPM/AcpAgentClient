# Backlog

跨轮次发现的问题与想法都记这里，不当场顺手改；新功能类条目须经所有者裁定才可进轮次。

**本文只留未关闭条目。** 已处理的连同结论原样移到 [`BACKLOG-CLOSED.md`](BACKLOG-CLOSED.md)；
实现与画板不一致的地方（实现先行 / 画板画错 / 实现有意少做）收在 [`design/DIVERGENCE.md`](../design/DIVERGENCE.md)，
按所有者裁定 2026-09-20 **不要求补设计稿**，本文不再重备一份（CLAUDE.md 规则 3）。

## 怎么读这份表

按「谁会撞上、撞上有多疼」分档（所有者 2026-09-20 要的**产品 + 技术双视角**）。每条三行：

- **标题**是一句话说清这是什么问题；
- **产品**是用户会撞上什么、看到什么；
- **技术**是在哪、为什么、最小修法或为什么没修，末尾括号里是发现时的轮次与日期。

| 档 | 条数 | 这档是什么 |
|---|---|---|
| **P0 真缺陷** | 0 | 会丢内容、作用到错对象、吃光资源、静默失败。撞上就是事故，排进最近的轮次。 |
| **P1 看得见的粗糙** | 3 | 用户看得见的不一致、缺等待态、行为不符直觉。能用，膈应；攒批做。 |
| **P2 功能缺口** | 1 | 该有没有的能力。**全部需所有者裁定才能进轮次**，多数还要先改设计稿。 |
| P3 设计稿欠账 | — | **已整体释放**到 `design/DIVERGENCE.md`，见下面的占位小节 |
| P4 平台与分发 | — | **已清空**（2026-09-23）：跨平台暂不做、构建链两条关闭、sidecar 两条移到 `BACKLOG-ZED.md`，见下面的占位小节；以后平台与分发的新问题照常记这一档 |
| **P5 内部工程与验收** | 1 | 测试、行数门、验收自动化这类用户无感的问题（2026-09-23 曾整档清空，16 条收在 iteration-04，见下面该节首段） |
| X 卡在上游 / 协议 | — | **已撤档**：不是本项目的问题不进本表（所有者裁定 2026-09-23），见下面的占位小节 |
| | **5** | |

**新增条目**：挑一档追在该档末尾，照同样的三行格式写。不新开档位；一条只进一档。
**只收本项目自己的问题**：问题出在上游（agent、zed、xterm 等依赖）或协议本身的，不进本表（所有者裁定 2026-09-23，X 档因此撤掉）；其中实现因此与画板对不上的，照规则 3 记 [`design/DIVERGENCE.md`](../design/DIVERGENCE.md)。
**agent 的私有协议扩展目前不接**（所有者裁定 2026-09-23）：某个 agent 自定的 `_meta` 键或私有流程（如 codex-acp 的 `api-key` / `gateway` 认证）不是 ACP 标准，接它就是按 agent 特判（规则 2），这类诉求不进本表。
**内置 Zed agent（sidecar）的问题不进本表**：记 [`BACKLOG-ZED.md`](BACKLOG-ZED.md)（所有者裁定 2026-09-23：原先本表的 4 条连同统筹时新盘点出的 5 条都移到那里，**当前不修**）；背景与上游限制见 [`docs/zed-agent.md`](../docs/zed-agent.md)。
**关闭条目**：把**技术行连同结论压成一行** `- [x]` 剪到 [`BACKLOG-CLOSED.md`](BACKLOG-CLOSED.md) 末尾（那份是平铺存档，不分档），本文删掉这三行。

## P0 · 真缺陷（0）

2026-09-23 全仓只读审查（v1.4.4 之后的 `main`，Rust 核心 / 文件与终端 / Dart 状态层 / 投影与转录四路）登记的 7 条已全部关闭：「本地状态文件的读改写没有串行化」由 iteration-10、「资源与静默失败」一小节三条由 iteration-11、「请求与会话路由」一小节三条由 iteration-12 修掉（均未在 Windows 实机复现，按代码路径与单测判定）；所有者同日报障的「dsh 的会话存到哪里跟着进程工作目录走」已由 round-dsh-1.3.2 在上游修掉。各条结论见 [`BACKLOG-CLOSED.md`](BACKLOG-CLOSED.md) 末尾。以后的真缺陷照常追在这里。

## P1 · 看得见的粗糙（3）

### 壳与交互（1）

- [ ] **会话菜单的 Resume / Close 没有入口**（暂不处理）
  - **产品**：两个动作已经接通也有单测，但产品界面上点不到（Delete 有入口）。实际缺的只有 Close：侧栏点开一条会话时已经自动 load（agent 不支持 load 时退回 resume），Resume 的用途被覆盖了；Close 是让 agent 放掉这条会话占的资源而不删它，现在打开过的会话在 agent 侧一直占着，直到 agent 断开。
  - **技术**：R6 会话头 ≡ 的语义在画板 03（右栏展开的选中态）与画板 41（会话菜单）之间冲突。所有者裁定 2026-09-16：**≡ 保持右栏开关，会话菜单要入口先改设计稿**。R6 已把菜单的动作接通并做了单测（`resumeSession` / `closeSession` / `deleteSession` + 能力裁剪），产品 UI 里 **Delete 有入口（侧栏删除图标，画板 04）、Resume / Close 没有**。下个设计轮给会话菜单定一个入口（改画板 41 / 03），再接上 `SessionMenuPopover` (2026-09-16) → **所有者裁定 2026-09-23：暂不处理**。当天查过 Zed 的做法：它也**没有**手动 Resume / Close 入口，而是在切走会话时后台自动 close，只保活最近 5 条空闲且 agent 支持 `loadSession` 的会话，切回被回收的会话走 `session/load`。机制全文、源码行号和与我们的对照记在 [`docs/research.md`](../docs/research.md) § 4.1，以后做自动 close 从那里开工。当时评估的方案是 `selectSession` 切走时回收、保活上限 5，还差一个裁定点：切回时 resume 优先（内存里的转录还在、不重放），还是照 Zed 一律 load。本次不做 (2026-09-23)

### 转录（2）

- [ ] **代码块的 Copy 点完「Copied」一闪就回去**
  - **产品**：点代码块右上角的 Copy，内容确实进了剪贴板，但「✓ Copied」只停一眨眼就变回 Copy，用户看不清有没有复制成功，容易再点一次。
  - **技术**：`lib/ui/transcript/code_block.dart` 的 `_copy()` 把 Copied 态的**保持时长**写成了 `Future.delayed(t.Motion.fast)`，而 `motion.fast` 是 120ms 的过渡时长，不是停留时长。画板 13 只画了「点击后变 Copied」、没给停留多久；动效 token 里也没有「停留」这一档，样式字面量扫描又不放行毫秒字面量，所以当时就近借了 `fast`。最小修法：照 `Motion.tooltipDelay`（`fast * 4`）的先例在 `tokens.dart` 派生一个停留时长（常见取值 1.5–2s），并在 DIVERGENCE 记一行（所有者 2026-09-24 实机报障）
- [ ] **转录里用鼠标选中文字后 Ctrl+C 有时复制不上**（未复现，待查）
  - **产品**：在转录里拖选一段文字按 Ctrl+C，有时剪贴板里就是选中的内容，有时什么都没进去；复制不上的那次，闪烁光标还停在底部输入框里。时好时坏，用户只能反复试或改用右键。
  - **技术**：转录的跨消息选择是 `lib/ui/transcript/transcript_list.dart` 的 `SelectableRegion`（没传 `focusNode`，用它自带的）。Flutter 3.47.4 里它的 Ctrl+C（`CopySelectionTextIntent` → `_CopySelectionAction`）只在**它自己拿着键盘焦点**时生效，要焦点只在三个地方：鼠标单击 / 拖选按下（`_startNewMouseSelectionGesture` 的单击分支）、触屏长按、右键按下；失焦就 `clearSelection`。所以复制不上说明按键时主焦点不在选区里，而选区还显示着（没走到失焦清空）。待验证的两个方向：① 拖选起点落在转录里自带手势的子 widget 上（链接 recognizer、可点的卡片头、气泡上的按钮等），手势竞技场被子 widget 赢走、选区靠拖动建起来却没走那条单击分支，焦点留在输入框；② 选完之后有别的路径把焦点拉回了输入框（`lib/app/composer_state.dart` 里的 `focus.requestFocus()` 都是用户操作触发的，不太像，但其他面板的 autofocus / 焦点恢复也要排除）。先按「从哪里开始拖」实机复现锁定是哪一种，再定最小修法（比如在转录区的 pointer down 上显式给选区要焦点）（所有者 2026-09-24 实机报障）

## P2 · 功能缺口（1）

「主题没有跟随系统」iteration-07 做掉；「Windows 的「动画效果」开关与节电模式」所有者裁定 2026-09-24 不做（结论均见 [`BACKLOG-CLOSED.md`](BACKLOG-CLOSED.md) 末尾）。以后该有没有的能力照常追在这里。

- [ ] **长时间运行的卡片只有转圈，没有已用时间**（待裁定，要先出设计稿）
  - **产品**：agent 跑一条十几分钟的命令时，卡片上只有一只一直转的 spinner，看不出跑了多久、是不是卡住；回合结束行才有耗时。
  - **技术**：NN/g 的口径是等待超过约 10 秒就该给已用时间或进度（`nngroup.com/articles/progress-indicators`），Codex / Claude Code 的做法是 `mm:ss` 每秒一跳，这一个 1Hz 定时器同时当「还活着」的信号，spinner 可以随之停下或更慢。涉及终端卡 / 工具调用卡 / 计划 / 会话头等多张画板（22 / 23 / 18 / 29 / 31 …），按规则 3 先改设计稿，张数可能够轮次门槛（iteration-14 调研, 2026-09-24）

## P3 · 设计稿欠账 —— 已整体释放

所有者裁定 2026-09-20：**不要求补设计稿**。原先这一档的 23 条连同结论搬到
[`design/DIVERGENCE.md`](../design/DIVERGENCE.md)，按「实现已超越画板 / 画板画错 / 实现有意少做」
分三节记着，那几处以实现为准、PNG 不再是它们的验收基准。档位留空占位，不重排编号。

## P4 · 平台与分发 —— 已清空

所有者裁定 2026-09-23，这一档的 7 条都已移出，档位留空占位，不重排编号：「跨平台」2 条关闭（目前没有 mac 设备，
macOS / Linux 暂不做）；「构建链」里中文路径兜底与 Rust 版本漂移 2 条关闭；sidecar 体积 1 条关闭（R8 已给出两个数字）；
sidecar 的另 2 条（languages crate、`0-dev` 目录名）移到 [`BACKLOG-ZED.md`](BACKLOG-ZED.md)。以后平台与分发的新问题照常追在这里。

## P5 · 内部工程与验收（1）

所有者裁定 2026-09-23，这一档的 16 条整档收掉，档位留空占位，不重排编号：7 条在 iteration-04 改完代码关闭，8 条按裁定不做 / 不修 / 视为已覆盖，「headless 报告的 lastError」并入 P0「失败没有出口」那条；各条结论见 [`BACKLOG-CLOSED.md`](BACKLOG-CLOSED.md) 末尾。以后内部工程与验收的新问题照常追在这里。

- [ ] **Rust 集成测试「agent 断开时释放它建的终端」在负载下偶发失败**
  - **产品**：用户无感；`scripts/validate.ps1` 偶尔在 `cargo test` 一步红掉，重跑就过，容易被当成本分支引入的问题去查。
  - **技术**：`rust/acp-core/tests/scripted.rs` 的 `owned_terminals_are_released_when_the_agent_disconnects` 在 `connection.disconnect().await` 返回后立刻断言 `terminals.output(&id)` 已是 `UnknownTerminal`（`terminal must be released` 那一句），而终端是在连接收尾（`Shared::finish` → `release_owned_terminals`）里释放的，负载高时断言可能抢在收尾之前。iteration-12 的 validate 撞上一次（`rust/` 零 diff 的分支；同一个测试二进制随后单跑 3 次、整组 10 项连跑 2 次都过）。最小修法：断言前按短超时轮询到释放为止，或让 `disconnect` 等收尾跑完再返回 (2026-09-24)

## X · 卡在上游 / 协议 —— 已撤档

所有者裁定 2026-09-23：**不是本项目的问题不进 BACKLOG**。原先这一档的 6 条连同结论压成一行剪到
[`BACKLOG-CLOSED.md`](BACKLOG-CLOSED.md) 末尾；其中「终端当前搜索命中」同时是画板 07 § 2.9 的偏离，
另记 [`design/DIVERGENCE.md`](../design/DIVERGENCE.md) C-28。档位留空占位，不重排编号。
