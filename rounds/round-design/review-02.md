# round-design 设计稿审核 · 第 2 轮（2026-09-14）

审核对象：所有者按 `input/revision-01.md` 修订后导出的 `设计系统文档审核v2.0.zip`（`delivery/`：40 张 `.dc.html`、`support.js`、`canvas.json`、`png/` 40 张、`README.md`）。
范围：第 1 轮约定只核 F1、F7、F8–F14 与 PNG；另全量重跑静态检查确认无回退。

## 复核结果

| 项 | 结论 | 证据 |
|---|---|---|
| F1 头部说明 | 过 | 「投影来源」0 命中，「协议来源」31 张 |
| F3 表外值 | 过 | 00 登记 `border.on-accent`；全 40 张颜色字面量 35 个，表外 0 个 |
| F4 死 token | 过 | `#4858c9` 全套 0 次；`a:hover` 用 `accent.active` |
| F5 胶囊圆角 | 过 | 00 登记 `radius.pill`，8px 只剩布尔开关轨道 |
| F6 芯片内边距 | 部分 | 00 登记 `space.chip = 1px 5px`；kbd 改 `0 4px` 12 处，**03 有 1 处、31 有 5 处 kbd 仍是 `1px 5px`**，入库时机械改掉 |
| F7 交付物 | 过 | PNG 40 张、`canvas.json`、`support.js` 齐 |
| F8 窗口控制 | 过 | 03 / 50 / 60 / 61 的 — ☐ ✕ 都在右栏标签栏最右 |
| F9 42 被裁 | 过 | 绝对定位去掉，frame 高 900，两个菜单完整可见 |
| F10 宽度约束 | 过 | 01 / 02 / 03 转录与输入框都 `max-width:800px`，02 里两者对齐 |
| F11 25 下拉 | 过 | 改向下展开，五项完整可见 |
| F12 停止控件 | 过 | 02 改成 ghost 容器 + error 小方块，与 23 / 31 一致 |
| F13 50 已登录 | 过 | Claude Agent 条目有徽章 |
| F14 61 清屏 | 过 | cwd 行右侧多一个 ghost 图标 |
| F15 01 默认态 | 过 | 状态 1 里只剩侧栏当前会话项是选中容器；状态 2 的底栏 Agents 选中是引导，合理 |
| F16 11 芯片 | 过 | 提及改成 accent.soft 底芯片，另画了默认 / 悬浮 |
| 回退检查 | 过 | 黑名单 0；无渐变 / 模糊；圆角 3 / 4 / 6 + pill + 圆形；字阶字重全在表内 |

## 新发现

- **画布导出的 PNG 有假换行 / 假截断**：01 的线程头标题折成两行、02 的待授权条折行、03 / 50 / 60 / 61 的标题被截成「Thre…」。同一份 `.dc.html` 用 Chromium（headless Edge）渲染全是单行，v1 与 v2 的标题标记完全相同，可确认是导出器的字体度量问题，不是设计缺陷。处置：仓库的 PNG 基准改由 `scripts/render-design.ps1` 从 `.dc.html` 渲染（可复现），画布导出件不入库；`design/README.md` 与 `materials.md` 的约定同步改。
- **F2 口径**：取方案 ①。`$preview` 高按导出件测得的内容高校准（+24 余量），`canvas.json` 的 h 同步，PNG 尺寸 = `$preview` 由脚本保证。

## 入库时在仓库里做的改动（画布若继续编辑需同步）

- 03、31 共 6 处 kbd `padding:1px 5px` → `padding:0 4px`（F6 收尾）。
- 40 张的 `$preview` 高度校准为内容高（多数缩小，01 / 02 / 03 / 13 / 27 / 60 放大）；`canvas.json` 的 h 与 y 随之重排，页与顺序不变。

## 结论

**收口。** 收口标准「§ 5 第 1 到 3 全过、第 4 到 10 无 high」全部满足。入库清单：40 个 `.dc.html`、`support.js`、`canvas.json`、40 张 PNG（脚本渲染）、`design/README.md` 索引 40 行。
