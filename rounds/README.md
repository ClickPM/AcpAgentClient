# rounds 目录约定

`rounds/` 保存轮次任务卡与轮次级管理产出，不保存源码、构建产物或大体积原始日志。轮次总览与 roadmap 见仓库根 `ROUNDS.md`（各轮的目标 / 交付物 / 验收 / 裁定门在它的 § 3，任务卡按对应节填）。

## 目录结构

```text
rounds/
├── README.md
├── TEMPLATE.md
├── BACKLOG.md          # 台账：只留未关闭条目，按 P0-P5 / X 分档，每条「产品 + 技术」两行
├── BACKLOG-CLOSED.md   # 台账：已处理条目，连结论原样存档
└── round-NN/
    ├── round-NN.md      # 任务卡（开工时从 TEMPLATE.md 建立）
    ├── BLOCKED.md       # 仅在触发阻塞规则时创建
    └── <其他轮次级文档>.md
```

## 放置规则

- `rounds/` 根目录只放跨轮次文件：本说明、任务卡模板、全局 backlog（未关闭 / 已关闭两份）。
- 每轮开工第一步：`cp rounds/TEMPLATE.md rounds/round-NN/round-NN.md`，按 ROUNDS.md 对应轮的拆解填好目标 / 交付物 / 验收，再开始实现。
- 任务卡范围**不得超出 ROUNDS.md 的功能边界**（设计稿全部画板，清单与计数以 `design/README.md` 为准；`docs/requirements.md` 的必须与不做；`docs/design.md` 的既定决策）。
- 设计轮的产出放 `design/round-NN/`（简报 `design-prompt.md`、每画板一个 `.dc.html` 源、`canvas.json` 与每画板一张 PNG 快照；画布 URL 记在 `design/README.md`），任务卡里只引用路径。
- 实测记录默认回填任务卡；内容过长时拆成同目录独立 Markdown 并从任务卡链接。
- 独立审查的 findings 处理记录（逐条：采纳整改 / 不采纳及理由）回填任务卡「代码审查」段；审查器与发起方式见 [`docs/review-workflow.md`](../docs/review-workflow.md)（cursor CLI + grok 4.6 high fast），运行日志落 `.claude/reviews/`（gitignored），不复制进轮次目录。
- 阻塞报告固定为 `rounds/round-NN/BLOCKED.md`：同一验收项针对性整改后连续 2 次验证仍不过 → 写 BLOCKED 停下呼人，禁止放宽验收自我通过。
- 源码、脚本、测试放各自标准位置（`rust/`、`lib/`、`test/`、`sidecar/`、`scripts/`），不复制进轮次目录；大日志放 gitignored 位置，任务卡只记结论与路径。
- 跨轮次发现的问题写进 `BACKLOG.md`，不当场顺手改；`BACKLOG.md` **只留未关闭条目**，按「谁会撞上、撞上有多疼」分 P0–P5 / X 六档，每条三行（标题 / **产品** 用户撞上什么 / **技术** 在哪、为什么、最小修法）。新增条目挑一档追在该档末尾，不新开档位、一条只进一档。
- 条目处理完成（已落地 / 已裁定 / 已实测出结论）时，把整条剪到 `BACKLOG-CLOSED.md` 对应位置并改成 `- [x]`；已关闭那份只作台账查阅。
- **实现与画板不一致的不进 BACKLOG**：记 [`design/DIVERGENCE.md`](../design/DIVERGENCE.md)，按所有者裁定 2026-09-20 不要求补设计稿（CLAUDE.md 规则 3）。
