# Iteration 26 — 画板 46 侧栏置顶与首 Query 悬浮

> 状态：已合并　起止：2026-10-10 – 2026-10-10　基线：`main` = `ff57f36`（画板 46 已在这条上）

21–25 已被别的迭代占用。本迭代是功能实现，不是设计稿。

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | board | 画板 46：`isPinned` / `pinnedAt` / `firstPrompt`；ACTIVE → PINNED → HISTORY；行内 Pin / Unpin；悬停 150ms 出首条指令卡片 | 画板 46（`ff57f36`） | `da3abdc` | 落地后 validate 全绿（651）；release 构建成功；smoke ok（临时 APPDATA） | R1–R3 索引 high 已清；R4 对照画板 P2 1 已改；R5 findings 0 | 已合并 |

## 收口

- 构建 / 手测：落地后 `validate.ps1` 全绿（flutter test 651），`build.ps1` release 成功，smoke `ok: true`、`coreVersion 1.5.1`、`droppedEvents 0`（临时 APPDATA）。未手测。安装目录未覆盖：`acp_agent_client.exe` 仍在 `D:\tools\AcpAgentClient` 运行
- 发版：不发
- 设计稿补注记：圆角与徽章的两处 token 名对不上，记 `design/DIVERGENCE.md` A-40。PNG 仍是验收基准

## 备注

- 实现最初落在过期的 `458cff0` 上，没看到 `ff57f36` 的画板，误记了「源文件未入库」。已快进到 `local/main` 并删掉那条。画板以入库的 `.dc.html` / PNG 为准。
- 卡片圆角用 `Radii.card`（6px）。规格表写成 `Radii.control (6px)`，control 在 token 里是 4px。
- PINNED 数量胶囊用 `Badge.accentBg`。索引写的 `Accent.mutedBg` 不存在。
- 补记 `firstPrompt` 不带 `isPinned` / `pinnedAt`。置顶与补记的 `updatedAt` 取索引与本地发送时间里大的；Rust 更新时也不接受更小的 `updatedAt`。
- 没有单独的列表位移动画。挂上或挂起后按分组判定换区。

## 代码审查

- R1：Delta reviewer，`openai-subscribed/gpt-6.1-sol` medium。findings: 2（high 2）。补记去掉置顶字段；`updatedAt` 不回退。已改。
- R2：同一执行器。findings: 1（high 1）。置顶 / 补记整行展开会把已落盘的新标题和消息数盖回去。已改成这两条写入只带自己的字段，核心对缺键的 title / cwd / messageCount 留盘上的现值。
- R3：同一执行器复审该整改。**findings: 0**（high 0 / P2 0 / P3 0）。只读，未重跑测试。
- R4（对照画板 46）：同一执行器。findings: 1（high 0 / P2 1 / P3 0）。Query 卡片留白被收成 8px，源稿是 padding 10/12、标题间距 4、块间距 6、分割线单侧 5。已按源稿改 `QueryPreview` 的几何 token。
- R5：同一执行器复审该留白。**findings: 0**（high 0 / P2 0 / P3 0）。只读，未重跑测试。
- 验证：合入 `da3abdc` 之后在 release worktree 重跑 `scripts/validate.ps1` 全绿（flutter test 651），覆盖索引修复和卡片留白。
