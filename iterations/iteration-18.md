# Iteration 18 — 内存冲到 100% 的两处按帧重算：工具卡里的图片解码缓存化、流量行的缩进 JSON 按需

<!-- 保存为 iterations/iteration-NN.md。一个迭代一个文件、一项一行；流程正本见 iterations/README.md，不在这里复述。 -->

> 状态：已合并（未构建）　起止：2026-09-29 – 2026-09-29　基线：`main` = `9c73c50`

所有者 2026-09-29 报障：AAC 最近多次严重内存泄漏、占用接近 100%，当天 19:06 那次由所有者在任务管理器强杀。
先查系统与应用侧证据，再按所有者圈定的两项（**1 图片解码**、**2 缩进 JSON**）开工；第 3 项（会话 LRU 淘汰）所有者当场裁定**暂不做**。

## 工作项

<!-- 类型：fix 缺陷 / ux 交互 / tidy 工程收尾 / board 单画板（设计稿先入库）。
     状态：待开工 / 进行中 / 待审查 / 待合并 / 已合并 / 移出（写去向）。
     验证：validate 全绿 / validate -Quick / 未构建（所有者指定）。
     审查：<轮数> 轮，<条数>（high n / P2 n / P3 n）；或 未审查（所有者指定）。 -->

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | fix | 工具卡内容里的 `image` 块不再每帧重解 base64：`_ImageBlock` 改 `StatefulWidget`，只在 `data` 值变了时重解（`lib/ui/transcript/content_blocks.dart`）；新单测 `test/ui/content_blocks_image_test.dart`（改前红、改后绿） | 所有者报障 2026-09-29 | `claude/iter-18-transcript-memory` → `main`（快进） | validate 全绿（审查时 606 项；并入 iter-17 后 614 项） | 1 轮：**0** 条（cursor `grok-4.7-high-fast`，`.claude/reviews/20260929-194416-review.out.md`） | 已合并 |
| 2 | fix | 流量面板的缩进 JSON 从「收一条算一条」改成按需算 + 记忆化（`lib/projection/traffic.dart`）；新单测 `test/projection/traffic_test.dart` | 所有者报障 2026-09-29 | 同上 | 同上 | 同上（同一轮全范围覆盖） | 已合并 |

## 收口

- **合并（2026-09-29，所有者指示）**：先在本分支并进已完成的 iter-17（合并提交 `a3647da`，两个 parent = `a8f44f0` + `e7153e7`）——冲突只有 `iterations/README.md` 一处，逐文件核过：两边碰过的 18 个文件里 17 个（含全部 `lib/` `test/` `design/`）逐字节等于某一侧，只有 README 是解冲突时手写的 ⇒ **合并这一步代码零改动**，按所有者「仅文档冲突、无代码改动则不重发 review」的条件没有另发审查。随后 `validate.ps1` 在这棵合并后的树上全绿（17 项、`flutter test` 614 项），把 `main` **快进**到本分支。**未 push**：本地 `main` 现在领先 `origin/main` 9 笔、与 `github/main` 的关系见提交说明，推不推由所有者定。
- 构建 / 手测：**未构建**（所有者定时机）。要手测的三项：① 让 agent 跑一个结果里带图的工具（本机 pi-acp 的设计稿类任务就会回 PNG），把那张工具卡展开、再让 agent 继续流式输出几分钟——任务管理器里本应用的内存应保持平稳（改前是台阶式上涨）；把卡卷出视口再滚回来，图片照常显示。② 打开流量面板（画板 80）跑一段带图 / 大 JSON 的会话：开关面板前后内存差别不大，展开某一条大行仍然看到缩进好的 JSON。③ 回归：工具卡里的图片预览、点图打开链接照常。
- 发版：不发（所有者定）。
- 移出项去向：第 3 项「会话转录无 LRU 淘汰」所有者当场裁定暂不做；它的机制与已有条目 [`rounds/BACKLOG.md`](../rounds/BACKLOG.md) P1「会话菜单的 Resume / Close 没有入口」同源（同一份 Zed 保活 5 条的调研笔记，`docs/research.md` § 4.1），不另开条目。
- 设计稿补注记：无（两项都不动 UI 结构、不动 token，画板零 diff）。

## 备注

### 证据（2026-09-29，只读排查，不改任何东西）

- **系统侧**：`HKLM\SOFTWARE\Microsoft\RADAR\HeapLeakDetection\DiagnosedApplications\acp_agent_client.exe` 在册，`LastDetectionTime` = 2026-09-17 16:43:54；同刻 `Microsoft-Windows-Resource-Exhaustion-Resolver/Operational` 有事件 1014「收到执行内存泄漏诊断的通知」，该类事件 09-16 ~ 09-28 反复出现。`System` 日志 2026-09-29 18:48 的 `Kernel-Power` 41 + `EventLog` 6008 记着「上一次系统的 10:50:59 在 2026/9/29 上的关闭是意外的」——当天上午那次 AAC 会话（10:21 起）以非正常关机收场，与所有者说的「多次」吻合。
- **应用侧**：`logs/acp-2026-09-29.log`——18:59:08 起核心（1.4.6），19:00:04 所有者发出带 2880×1716 截图的消息，19:06:58 `Microsoft-Windows-Diagnosis-DPS/Operational` 跑了一次诊断场景 `{739ff6cf-5033-428c-9e2f-582096482dd5}`（模块 `radardt.dll` / `radarrs.dll`，即资源消耗检测那条线），19:08:14 回合 `end_turn`，19:08:50 应用被强杀后重启（当前实例 PID 5640）。
- **一条要澄清的**：Windows 的「虚拟内存不足」事件（资源消耗检测器 1003 / 1008）最近一次是 **2026-09-08**，**今天没有**。这次是物理内存 / 显存被吃满，不是提交量（commit）耗尽那条告警触发的；所以别拿「事件日志里没有 1003」当反证。

### 根因（工作项 1）：agent 回来的图落在工具卡内容里，而卡片每帧重建

- 实测方向与体量（按日志行的方向统计）：`acp-2026-09-28.log` 里 `in` 方向带 `"type":"image"` 的行 **31** 条（其中 30 条含 `iVBORw0KGgo` 的 PNG base64），单条 **155–275 KB**，且**成对出现**——`tool_call` 与随后的 `tool_call_update` 各带一份同图；`acp-2026-09-29.log` 2 条。
- 这些块经 `ToolCallEntry.content` → `tool_call_card.dart` 第 204 行 `ContentBlockView(b)` → `_ImageBlock` → `Image.memory` 渲染（不是用户消息那条路：用户附的图在气泡里只出芯片）。
- 改前 `_ImageBlock` 是 `StatelessWidget`、`base64Decode` 写在 `build` 里：转录区在流式期间按帧重建 ⇒ 每帧解出一个新 `Uint8List`；而 `Image.memory` 建出的 `MemoryImage` 缓存键就是 `bytes` 的**同一性**（`MemoryImage.==` 比的是 `other.bytes == bytes`），于是每帧缓存都不命中 ⇒ 同一张图被反复解成位图、再经 GPU 上传。核显上那块显存就是系统内存（本机 Radeon 780M），所以它直接表现为系统内存被吃满。
- **红 → 绿**：把 `content_blocks.dart` 单独 `git stash` 回改前，`test/ui/content_blocks_image_test.dart` 的 1 号用例（`identical(first, second)`）红（`test/ui/content_blocks_image_test.dart:44`）；`git stash pop` 恢复后三个用例全绿。另外两个用例守「`data` 真变了要重解」与「没有 `data` / 解不开时不挂预览」。

### 工作项 2 的体量要说清：它是清账，不是那次事故的主因

- 实测 `TrafficStore` 环形缓冲的常驻量（取日志里 `in` / `out` 行的字符数，最后 2000 条）：`acp-2026-09-28.log` **2.6 MB**（单条最大 64.3 KB），`acp-2026-09-29.log` **0.6 MB**（单条最大 3.4 KB）。改前还要再常驻一份缩进串（同量级），所以工作项 2 省下的是**个位数 MB**，不是 GB 级。
- 它的价值在「进一条算一条」这个形状本身（`_parse` 里对每条都 `JsonEncoder.withIndent`），不在这次的内存曲线。真正的大头记在 [`rounds/BACKLOG.md`](../rounds/BACKLOG.md) P0 新登记的两条：工具卡与流量面板在 `build` 里重算 `JsonHighlight`（缩进 + `re_highlight` 词法分析 + `TextSpan` 树）、以及窗口最小化期间批处理器队列无上限堆积。两条都按代码路径判定、**未复现**，留给所有者裁定后进下一个迭代。
- 缩进「按需」本身在单测里不可观测（它只是把同一份计算挪到第一次访问），所以 `test/projection/traffic_test.dart` 守的是**语义没变**与**记忆化**（后者正是这次新引入的风险：不记忆化就退化成每帧重算）；另外四条守 `_parse` 没被这次挪动碰坏（响应行回填方法名、表外变体计数、stderr 尾巴、环形缓冲上限）。

### 现场测量（只读）

- 当前实例（PID 5640，19:08:50 起）：31 分钟时 WorkingSet 618 MB / Private 672 MB / Commit 5.97 GB / 句柄 1471 / 线程 113 / CPU 643.8 s。往前 22 分钟（19:17 → 19:39）三项基本平（607→618 MB、681→672 MB）——**这一段没有单调上涨**。也就是说这次报告的那次暴涨是短时间内的量级跳变（带图工具结果 + 每帧重解），不是一条稳定泄漏速率；复现要按「工具结果带图 / 带整份文件 + 卡片展开」的场景压，别按「放着不动」压。

### 审查（迭代流程：一轮 `<基线>..HEAD`）

- 执行器 **cursor CLI**（`cursor-agent` + `grok-4.7-high-fast`），命令 `powershell -File .claude\cursor-review.ps1 -Scope since -Base 9c73c50 -Wait`，范围 `9c73c50..HEAD`（`b6ab3a5`）、7 个文件；2026-09-29 19:44:16 发起、19:49:39 结果落地，`.claude/reviews/20260929-194416-review.out.md`。
- **0 条 findings**（high / P2 / P3 全 0）⇒ 没有需要采纳的整改、也没有复审轮；按收口标准（0 条 high）可以直接合并，合并时机由所有者定。审查者另外对照读了 `traffic_page.dart`（`pretty` 只在展开时读）、`tool_call_card.dart` / `card_chrome.dart` / `assistant_text.dart` / `transcript_list.dart`（图片块的槽位在流式重建时保得住 State）、`wire.dart` 的 `ContentBlockWire.data`，以及 `composer_attachments.dart` 里同一套解码写法。
- 发起时 Zed 没在跑（它占着会锁 `~/.cursor/cli-config.json`，`cursor-agent` 起不来，见 [`docs/review-workflow.md`](../docs/review-workflow.md) 第 6 条），`cursor-agent status` 显示已登录，所以没有回落子代理。

### 与流程有关的两条

- 本 worktree 的 `vendor/upstream/` 是从主 worktree 拷的（111 MB，8 个仓，iter-16 之后 `zed` 那条已从 pins 移除），拷完 `scripts/fetch-upstream.ps1 -Check` 八个全绿（规则 4）；不这么做得联网重拉 8 个仓。
- 编号取 18：17 已被 `claude/iter-17-active-history-sessions` 占用（该分支尚未合并，`iterations/README.md` 的清单行也还没进去）。本迭代那一行与 17 会落在同一处表尾，合并时按「编号只增」并排保留。
