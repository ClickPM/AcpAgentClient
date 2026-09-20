# AcpAgent Client

> 一个好看的多 agent ACP 桌面客户端。Flutter 壳，Rust 核心（flutter_rust_bridge 进程内桥接），前端按 Claude Design 设计稿实现。

Agent 一律经 [Agent Client Protocol（ACP）](https://agentclientprotocol.com/) 接入：Claude Agent、Codex、Cursor、pi、DeepSeek Harness，以及以独立 sidecar 形式接入的 Zed 内置 agent。官方 registry 里的 agent 像 Zed 一样安装即用。

## 状态

2026-09-11 建仓，完成三轮可行性分析；2026-09-12 技术栈调整为 Flutter + Rust（frb v2）；2026-09-14 设计工具改回 Claude Design，同日 40 张画板设计稿收口入库；2026-09-15 按设计稿完成轮次拆解（R0–R8，见 [`ROUNDS.md`](ROUNDS.md)）。

- **R0–R7 已完成**（2026-09-15 至 2026-09-17）：脚手架、Rust 核心主线、富文本 spike、25 张转录卡片、工作台壳与接线、fs / terminal 回调与文件 / 终端面板、registry / 安装 / 认证 / 设置、会话生命周期与五 agent 全通、zed-agent-acp sidecar。每轮都过独立审查的缺陷门禁后合并 `main`，进度与审查轮数见 `ROUNDS.md` § 7。
- **2026-09-17 起在 `main` 上直接修所有者手测报障**（R7 合并后、R8 之前）：新增画板 05「转场规格」与 06「侧栏会话活动指示」，废弃画板 10；dsh-acp-interactive 改为核心内建条目、正式 logo 与应用图标、随包 CJK 字体、图片粘贴与附件芯片条、悬停提示、会话配置固定档序平铺等；2026-09-18 又合并了五个并行会话的一批（侧栏按用户最后发消息时间倒序、侧栏只列当前项目的会话、Restore / Regenerate 改按用户气泡定位、权限卡范围下拉浮到 Overlay 并去掉快捷键标签），主会话自审整改后构建并替换了本地安装版。清单见 `ROUNDS.md` § 7「main 直改」行，设计稿因此待补的注记在 `rounds/BACKLOG.md`。
- **2026-09-20 发布 v1.0.0**：源码 release，同日补上 `LICENSE`（GPL-3.0-or-later 全文）与 `NOTICE`（Zed 派生文件清单、上游钉版本、随包字体与图标的许可证）。
- **R8（打包与发布）未开始**：Windows zip / 安装器、macOS 构建、干净机验收。许可证文件已随 v1.0.0 落地，R8 只剩打包本身。

## 文档

| 文件 | 内容 |
|---|---|
| [`docs/background.md`](docs/background.md) | 为什么做：前作、为什么是 ACP、为什么是 Flutter + Rust |
| [`docs/requirements.md`](docs/requirements.md) | 必须 / 不做 / 依赖白名单 / 五个一等 agent |
| [`docs/research.md`](docs/research.md) | 源码级研究结论：Zed 的 ACP 代码、rust-sdk v2、registry、五个 agent、sidecar 接入点、被排除的路线、Flutter + Rust 桥接、Claude Design 交付链路 |
| [`docs/acp-projection.md`](docs/acp-projection.md) | 可投影内容清单：15 个 `session/update` 变体、能力门总表、协议不给必须客户端自造的 8 项、容错与丢失风险 |
| [`docs/design.md`](docs/design.md) | 进程模型、分层来源、核心与前端契约、认证、registry（含内置条目）、终端与 fs、sidecar、前端（Flutter）既定决策、数据目录 |
| [`docs/review-workflow.md`](docs/review-workflow.md) | 独立审查：cursor CLI + grok 4.6 high 首选，硬失败回落 Claude Code 子代理；发起、取回与回落条件 |
| [`ROUNDS.md`](ROUNDS.md) | 轮次拆解：R0–R8 各轮目标 / 交付物 / 验收 / 裁定门，画板 → 轮次 → widget 文件对应表，五 agent 全通矩阵，进度表 |
| [`design/README.md`](design/README.md) | 画板索引：42 张画板（含已废弃的 10）的 `.dc.html` 源、PNG 基准与实现状态；`design/brand/` 是应用图标与标记，不是画板 |
| [`rounds/BACKLOG.md`](rounds/BACKLOG.md) | 跨轮次问题与待裁定项；「设计稿补注记」条目记录实现先行、设计稿待补的部分 |
| [`CLAUDE.md`](CLAUDE.md) | 开发约定、轮次流程与硬性规则（`AGENTS.md` 是给审查者的指针） |

## 架构一图

```
Flutter 宿主进程（Dart 前端 ⇄ frb v2 ⇄ Rust 核心 cdylib）
   │ stdio · ACP JSON-RPC
   ├── claude-agent-acp / codex-acp / pi-acp     npx
   ├── cursor `agent acp`                        binary
   ├── dsh-acp-interactive                       custom（核心内建条目，免配置）
   └── zed-agent-acp                             sidecar（headless gpui + Zed 内置 agent；核心内建条目，随包分发）
```

主进程里没有 gpui；前端只消费 ACP 原样 JSON；registry、安装、认证、终端、fs 回调都在 Rust 核心。dsh 与 Zed 这两个官方 registry 里没有的 agent 由核心合成成内置的 custom 条目（不落 `settings.json`），见 `docs/design.md` § 6。

## 上游钉版本

开发期钉死的上游源码列在 [`pins/upstream.json`](pins/upstream.json)，源码放在 `vendor/upstream/`（不入库）：

```powershell
powershell -File scripts/fetch-upstream.ps1          # 首次填充
powershell -File scripts/fetch-upstream.ps1 -Check   # 验证钉版本
```

Git Bash：`scripts/fetch-upstream.sh [--check]`。`pins/upstream.json` 里的 `deepseek-harness` 只作资产来源（dsh 的图标复制成 `rust/acp-core/assets/dsh-icon.svg`），没有代码依赖。

## 构建与运行

前置（Rust stable、Flutter stable、`flutter_rust_bridge_codegen`、VS 2022「使用 C++ 的桌面开发」、Node ≥ 22）与本机坑见 [`CLAUDE.md`](CLAUDE.md)「本地开发」。

```powershell
powershell -File scripts/validate.ps1            # 编译 + 测试 + 契约检查（-Quick 只跑静态检查；不含 sidecar）
powershell -File scripts/build.ps1               # flutter build windows --release（-Smoke 跑一次无头自检）
powershell -File scripts/build-sidecar.ps1       # zed-agent-acp sidecar（独立 cargo workspace，冷编译约 50 分钟）
```

主程序产物在 `build/windows/x64/runner/<Debug|Release>/`；sidecar 先落 `build/sidecar/`，再由 runner 的 CMake install 规则放到应用目录旁，缺了不报错、只是 agent 列表里没有 Zed Agent。

## 许可证

**GPL-3.0-or-later**，全文见 [`LICENSE`](LICENSE)。开源、不商用。

许可证由复用 Zed 源码决定：`rust/` 与 `sidecar/` 里共 15 个文件是 Zed 的复制改写或转写，各自文件头标注了上游路径与 commit，汇总在 [`NOTICE`](NOTICE)。`NOTICE` 同时列出 ACP 规范 / rust-sdk / registry（Apache-2.0）、随包字体（OFL-1.1）与图标的来源，以及商标声明。
