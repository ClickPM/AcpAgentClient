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
- 官方 Rust SDK v2（`agent-client-protocol` 2.1.0，2026-09-04）已 Send 化，直接跑在 tokio 上，与 Tauri 同一运行时。

## 为什么是 Tauri，而不是 GPUI 或 Electron

- 前端要用 Claude Design 出设计稿并 1:1 实现。设计稿产物是 `.dc.html`，Web 技术栈是与它距离最近的实现载体；GPUI-Pi 已经证明原生绘制复刻 UI 的成本。
- Rust 后端可以直接使用官方 rust-sdk，并在 GPL-3.0 下复用 Zed 源码。
- 避开 Electron 的体积与双运行时问题。

## 时间线

- 2026-09-11：三轮可行性分析（源码级核对 Zed、rust-sdk、registry 与五个 agent），结论收敛为「Rust 核心 + 严格 ACP 投影 + Zed agent 独立 sidecar」，建仓。
