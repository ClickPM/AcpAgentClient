# Iteration 17 — 侧栏会话区 Active 与 History 分组展示及折叠收纳（画板 45）

<!-- 保存为 iterations/iteration-NN.md。一个迭代一个文件、一项一行；流程正本见 iterations/README.md，不在这里复述。 -->

> 状态：进行中　起止：2026-09-29 –　基线：`main` = `9c73c50`

所有者需求（2026-09-29）：「对会话区进行区分：1. 区分 Active 和 History 会话，将已经连接的会话放到 Active 区；已折叠状态下无需展示“已折叠”3个字，其他没有问题。按照仓库约定开一轮迭代实现本功能。」

解决的核心问题：此前客户端侧栏所有会话呈扁平平铺，存活连接的会话（有后台活跃 agent 进程）与历史归档会话无法感知区分；大列表缺乏分类折叠收纳机制。

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | board | 画板 45「侧栏会话区分组规范」入库：Active 区与 History 区规格、在线绿标、折叠展开态（无多余“已折叠”字样）、搜索过滤态、浅色对位；更新 `design/README.md` 与 `canvas.json`，导出同名 PNG | 所有者需求 2026-09-29 | `claude/iter-17-active-history-sessions` | validate 全绿 | 待审查 | 进行中 |
| 2 | ux | 侧栏 `Sidebar` 与 `SessionController` 支持 Active 与 History 分组呈现与折叠：按 `SessionAttachment` 挂载状态（`SessionAttach.attached`）分流；Active 区常驻显示在线绿标与连接态；History 区支持一键折叠/展开；搜索保持分组；点击 History 触发 `ensureLoaded` 挂载升格；断开/关闭自动沉降 | 所有者需求 2026-09-29 | `claude/iter-17-active-history-sessions` | validate 全绿 | 待审查 | 进行中 |
| 3 | fix | 补齐 Active / History 侧栏分组渲染、折叠切换、搜索过滤与生命周期流转的单元测试 | 同上 | `claude/iter-17-active-history-sessions` | 单元测试全绿 | 待审查 | 进行中 |

## 收口

- 构建 / 手测：待完成
- 发版：—
- 移出项去向：—
- 设计稿补注记：画板 45 入库，已折叠状态下不展示文字。

## 备注

### 架构与生命周期映射

1. **Active 区口径**：
   - 判定标准：会话挂在当前存活的 Agent 连接上（`SessionAttach.attached`，即内存中有 session 且不在 `_detached` 集合中）；或者正在创建/载入（`_attaching`）。
   - 视觉特征：带 `6px` 发光在线指示灯（`Semantic.success`）、数量胶囊 `chip-active`；条目包含连通性绿标，运行中保持 58px 扫掠亮点线。
2. **History 区口径**：
   - 判定标准：本地索引中未挂载到活跃连接的会话（`detached` 或 `unattachable`）。
   - 视觉特征：标题行配有 Chevron（`chevronDown` / `chevronRight`），数量胶囊 `chip-history`；折叠时不显示“已折叠”文字；点击历史会话自动触发挂载。
3. **零样式字面量**：
   - 完全复用 `t.Neutral.panel`、`t.TextStyles.label`、`t.Semantic.success`、`t.Borders.subtle` 等既有 tokens。
