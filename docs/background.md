# 背景

> 本文回答「为什么要做这个项目」。诉求见 [`requirements.md`](requirements.md)，研究依据见 [`research.md`](research.md)，方案见 [`design.md`](design.md)。

## 起点

所有者同时重度使用 Zed 与 Claude Code。Zed 的 Agent 面板通过 **Agent Client Protocol（ACP）** 挂载多个外部 agent（Claude Agent、Codex、Cursor、pi ACP、DeepSeek Harness）这一设计是想要的；Zed 客户端本身的视觉与交互不想要。

此前有两个前作，都只服务 pi 一个 agent，协议是 pi 的私有 RPC：

| 前作 | 形态 | 结论 |
|---|---|---|
| pi-web-desktop | Electron 壳包 pi-web（Next.js）+ 内置 Node/Python 运行时 | 开箱即用，但 500MB+，双运行时，UI 不是自己的 |
| GPUI-Pi | GPUI + gpui-component 原生绘制，内核 `pi --mode rpc` 子进程 | 体积可控，但 18 轮里大量时间花在手工复刻 UI |

另有自研的 **dsh-acp-interactive**：面向编辑器的 ACP 服务器，已在 Zed 里跑通权限请求、terminal auth、elicitation、session config options、`session/list` / `session/load`、进程内子代理等全部交互面。它既是本项目的一等 agent，也是第一轮的参照 agent。

## 为什么是 ACP

- 已成事实标准：官方 registry 收录 50 个 agent；客户端侧有 Zed、JetBrains、Neovim、Emacs、Obsidian 以及多个桌面端。
- 自己写的 agent 天然可接，不需要为客户端做任何私有适配。
- 官方 Rust SDK v2（`agent-client-protocol` 2.1.0，2026-09-04）已 Send 化，直接跑在 tokio 上，可以作为 cdylib 在任何宿主进程里起自己的 runtime。

## 为什么是 Flutter + Rust，而不是 Tauri、GPUI 或 Electron

- **Rust 核心是不变量**：直接使用官方 rust-sdk，并在 GPL-3.0 下复用 Zed 源码；壳只负责渲染，核心与壳之间只传 ACP 原样 JSON。壳可以换，核心不动。
- **2026-09-11 选 Tauri** 的理由是「Claude Design 出的是 `.dc.html`，Web 栈离它最近」。**2026-09-12 改 Flutter**：设计稿只作视觉基准（源文件与 PNG 入库）不复用代码，前端框架不再被设计工具绑定；Flutter 不依赖 WebView2，列表、动效、字体是原生能力；Rust 以 cdylib 经 flutter_rust_bridge 进程内加载，单进程。取舍见 `research.md` § 9。
- 不选 GPUI：GPUI-Pi 已经证明原生绘制手工复刻 UI 的成本，且 gpui 与任何宿主事件循环冲突（`research.md` § 1.3）。
- 不选 Electron：体积与双运行时。

## 时间线

- 2026-09-11：三轮可行性分析（源码级核对 Zed、rust-sdk、registry 与五个 agent），结论收敛为「Rust 核心 + 严格 ACP 投影 + Zed agent 独立 sidecar」，建仓。
- 2026-09-12：技术栈调整（编码尚未开始）：壳 Tauri → Flutter（frb v2，进程内 cdylib），设计 Claude Design → Figma Make；Rust 核心与 ACP 契约不变。Markdown 渲染库待 spike 后进白名单。
- 2026-09-14：设计工具改回 Claude Design（`.dc.html` 源与 PNG 入库，见 `design/README.md`）；Flutter + Rust 技术栈不变。
- 2026-09-15：按设计稿完成轮次拆解（R0–R8，`ROUNDS.md`）；当日 R0 脚手架、R1 Rust 核心主线、R1.5 富文本 spike、R2 转录卡片、R3 工作台壳与接线收口合并 `main`。
- 2026-09-16：R4 fs / terminal 与文件 / 终端面板、R5 registry / 认证 / 设置、R6 会话生命周期与五 agent 全通合并 `main`。
- 2026-09-17：R7 zed-agent-acp sidecar 合并 `main`（`44cd33a`）。此后所有者手测报障的修复直接在 `main` 上做（`ROUNDS.md` § 7「main 直改」行）。
- 2026-09-20：画板 43 会话时间线、R7.6 字体切换、画板 07 深色模式、R7.5 组合根拆分、R8 Windows 端打包先后合并 `main`，同日发布 v1.0.0 到 v1.4.0（v1.4.0 是首个带安装包的 release）。
- 2026-09-22：画板 08 交互增强合并 `main`；同日 1.4.1 复审轮把 v1.4.0 之后合入 `main` 的六批改动（其中三批此前没走过独立审查）整体复审一遍、22 条 findings 处理完毕后发 v1.4.1。R0–R8 主体完成，进入敏捷迭代阶段——日常的缺陷修复、交互优化、工程收尾与单画板功能走 `iterations/` 的迭代流程，轮次流程保留给核心大迭代（`CLAUDE.md`「开发模式」）。
