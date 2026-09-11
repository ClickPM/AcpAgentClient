# AcpAgent Client

> 一个好看的多 agent ACP 桌面客户端。Tauri 壳，Rust 核心，React 19 前端按 Claude Design 设计稿实现。

Agent 一律经 [Agent Client Protocol（ACP）](https://agentclientprotocol.com/) 接入：Claude Agent、Codex、Cursor、pi、DeepSeek Harness，以及以独立 sidecar 形式接入的 Zed 内置 agent。官方 registry 里的 agent 像 Zed 一样安装即用。

## 状态

2026-09-11 建仓，完成三轮可行性分析，尚未开始编码。轮次拆解将建立在 `ROUNDS.md`。

## 文档

| 文件 | 内容 |
|---|---|
| [`docs/background.md`](docs/background.md) | 为什么做：前作、为什么是 ACP、为什么是 Tauri |
| [`docs/requirements.md`](docs/requirements.md) | 必须 / 不做 / 依赖白名单 / 五个一等 agent |
| [`docs/research.md`](docs/research.md) | 源码级研究结论：Zed 的 ACP 代码、rust-sdk v2、registry、五个 agent、sidecar 接入点、被排除的路线 |
| [`docs/design.md`](docs/design.md) | 进程模型、分层来源、核心与前端契约、认证、registry、终端与 fs、sidecar、前端（React 19）、阶段草案 |
| [`docs/review-workflow.md`](docs/review-workflow.md) | 独立审查：cursor CLI + grok 4.6 high 首选，硬失败回落 Claude Code 子代理；发起、取回与回落条件 |
| [`CLAUDE.md`](CLAUDE.md) | 开发约定、轮次流程与硬性规则（`AGENTS.md` 是给审查者的指针） |

## 架构一图

```
Tauri 主进程（Rust 核心 + WebView 前端）
   │ stdio · ACP JSON-RPC
   ├── claude-agent-acp / codex-acp / pi-acp     npx
   ├── cursor `agent acp`                        binary
   ├── dsh-acp-interactive                       custom
   └── zed-agent-acp                             sidecar（headless gpui + Zed 内置 agent）
```

主进程里没有 gpui；前端只消费 ACP 原样 JSON；registry、安装、认证、终端、fs 回调都在 Rust 核心。

## 上游钉版本

开发期钉死的上游源码列在 [`pins/upstream.json`](pins/upstream.json)，源码放在 `vendor/upstream/`（不入库）：

```powershell
powershell -File scripts/fetch-upstream.ps1          # 首次填充
powershell -File scripts/fetch-upstream.ps1 -Check   # 验证钉版本
```

Git Bash：`scripts/fetch-upstream.sh [--check]`。

## 许可证

开源、不商用。因复用 Zed 源码，拟采用 GPL-3.0-or-later；LICENSE 文件待所有者确认后加入。
