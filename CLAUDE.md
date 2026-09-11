# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

> **本文只留五块**：项目定位、仓库结构、开发模式与轮次流程、硬性规则、本地开发。
> 背景 / 诉求 / 研究 / 设计都在 `docs/`，轮次拆解在仓库根 `ROUNDS.md`（首轮拆解时建立），按需读。
> **书写约定：硬性规则编号只增不改、不重排**（代码注释会引用「CLAUDE.md 规则 N」）；删掉的规则留「已废弃」占位。
> `AGENTS.md` 是给**外部审查者**的指针文件，指向本文，无需双份维护。

## 项目定位

**AcpAgent Client**：Tauri 桌面客户端，Rust 核心用官方 `agent-client-protocol` rust-sdk v2 以 ACP 接入多个 agent（Claude Agent、Codex、Cursor、pi、DeepSeek Harness，以及以 sidecar 形式接入的 Zed 内置 agent），registry 里的 agent 像 Zed 一样安装即用；前端完全按 Claude Design 设计稿实现。开源、不商用，许可证拟为 GPL-3.0-or-later（因复用 Zed 源码）。

- **功能范围的唯一边界是设计稿**：[`design/`](design/)（当前为空；首轮出稿后建立 `design/README.md` 画板索引，画板编号只增不改）。设计稿没有的功能一律不做，想到的进 `rounds/BACKLOG.md` 等所有者裁定。
- 诉求与非目标：[`docs/requirements.md`](docs/requirements.md)；架构与既定决策：[`docs/design.md`](docs/design.md)；研究依据：[`docs/research.md`](docs/research.md)；背景：[`docs/background.md`](docs/background.md)。

**用户回复默认中文**；代码、命令、路径、技术术语保持英文。

## 仓库结构

```
AcpAgentClient/
├── CLAUDE.md / AGENTS.md / README.md      约定、指针、简介
├── ROUNDS.md                              轮次总览与 roadmap（首轮拆解时建立）
├── docs/                                  background / requirements / research / design
├── design/                                设计稿与提示词：design/round-NN/{design-prompt.md, *.dc.html}
│                                          + design/README.md 画板索引（首轮出稿后建立）
├── rounds/                                轮次任务卡：rounds/round-NN/round-NN.md、BLOCKED.md、BACKLOG.md
├── pins/upstream.json                     上游钉版本清单（提交进仓库；改版本先改这里）
├── scripts/                               fetch-upstream.ps1 / .sh；R0 起 validate / build
├── vendor/upstream/<name>/                钉版本源码（gitignored；fetch 脚本按 pins 填充）
├── src-tauri/                             （R0）Rust 核心：acp-core / registry / pty / fs / settings
├── src/                                   （R0）前端
└── sidecar/zed-agent-acp/                 （R6）独立 cargo workspace，path 依赖 vendor/upstream/zed
```

## 开发模式与轮次流程

**Claude Code solo 开发，独立审查做缺陷门禁，有 UI 的轮次按设计稿逐画板对照。**

```
设计轮（有 UI 变动时先做）：design/round-NN/design-prompt.md → Claude Design 出稿 → .dc.html 入库 → 更新 design/README.md
                                                                              ↓
开工：建 rounds/round-NN/round-NN.md 任务卡（目标 / 前置 / 交付物 / 验收 / 禁止），范围对齐 ROUNDS.md
  → 每个 worktree 第一步：scripts/fetch-upstream.ps1 且 -Check 全绿（规则 4）
  → 实现（遵守规则 1 / 2 / 3 / 5）
  → 验证：scripts/validate.ps1 + 任务卡验收项全过（R0 落地 validate）
  → 独立审查：优先 codex 插件 /codex:review（质疑取舍用 /codex:adversarial-review）；不可用时 /code-review，并在任务卡写明降级原因
  → findings 逐条处理（采纳整改 / 不采纳写明理由），回填任务卡「代码审查」段；有采纳整改则复审一轮
  → commit + 更新 ROUNDS.md 进度表
```

- **审查边界**：审查是缺陷门禁，不负责长出方案；非阻塞 finding 不得建议机制类修复（新队列 / 新协议 / 新抽象 / 新配置），只建议最小改动或记 BACKLOG。
- **阻塞**：同一验收项经针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-NN/BLOCKED.md` 停下呼人，禁止放宽验收自我通过。
- **不跨轮次改动**：发现前面轮次的问题写进 `rounds/BACKLOG.md`。
- **任务卡格式**照 agent-xray：目标 / 前置 / 交付物表 / 验收表（命令 + 期望）/ 禁止 / 本轮实测 / 代码审查。

## 硬性规则

1. **依赖白名单。** 实现层只允许来自：官方协议仓库（规范 + `schema/v1`）、官方 `rust-sdk`、官方 `registry`、`zed-industries/zed`、五个 agent（claude-agent-acp、codex-acp、Cursor CLI ACP 文档、pi-acp、dsh-acp-interactive）。语言级基础库与工具（tokio、serde、reqwest、sha2、portable-pty、notify、tauri 及官方插件、构建期代码生成器）不受限；**任何实现了 ACP 客户端、agent 会话状态或会话 UI 的第三方库一律不引入**（acp-components、acp-ui、pi-web 等已被裁定排除）。界定有疑问时按 `docs/requirements.md` 第 8 条，仍有疑问问所有者。
2. **严格 ACP 投影。** 前端只消费 ACP 线上消息的原样 JSON（契约见 `docs/design.md` § 3）；不自造第二套协议；前端不做任何 agent 特判；`_meta` 只允许 `docs/design.md` § 4 列出的键，增键先改文档再进所有者裁定。
3. **设计稿是功能边界。** 设计稿没有的功能不做；接后端只换数据源，不改样式、布局、className 与 token。扩边界的唯一正确顺序是「先改设计稿、再进轮次」。
4. **钉版本。** `pins/upstream.json` 是上游唯一事实来源，`vendor/upstream/` 永不入库；改版本先改 pins，再改 `docs/research.md` 对应段，再 fetch。禁止在 `vendor/upstream/` 里改代码：要改就复制出来（规则 5）。
5. **gpui 不进主进程；复用要标来源。** 主进程（`src-tauri/`）不得依赖任何含 gpui 的 crate；需要 gpui 的东西只能放 `sidecar/`。复用 Zed 代码的三种方式（直接链接 crate / 复制后改写 / 参考转写）都要在文件头标注 `// Derived from zed-industries/zed <path> @ <commit> (GPL-3.0-or-later)`。
6. **Rust 禁 `unsafe`。** 需要时问所有者，不自行放行。
7. **不动用户数据。** Zed 的 `threads.db` 与 `settings.json`、`~/.pi`、各 agent 自己的会话目录：能只读就只读，必须写走「临时文件 + rename」；sidecar 同样适用。禁止任何破坏性操作。
8. **密钥不入库、不入日志。** ACP 流量日志与调试面板对 `Authorization`、`api_key`、`token` 类字段打码；`.env*` 与 `*.pem` 已在 `.gitignore`。
9. **Windows 首发。** 涉及子进程拉起（`.cmd` 包装、引号、路径含中文与空格）的改动必须在 Windows 实测并在任务卡记录命令与输出；不得只在 macOS / Linux 验证。
10. **协议对齐。** rust-sdk 的 `unstable` 特性集与 Zed 钉版本对齐（见 `docs/research.md` § 2）；改特性集视为改钉版本，走规则 4。

## 本地开发

- **前置**：Rust stable（`rust-toolchain.toml` 在 R0 钉）、Node ≥ 22、Tauri 2 的 Windows 前置（WebView2 Runtime、VS C++ 生成工具）；sidecar 另需 Zed 的构建前置（Windows SDK ≥ 10.0.20348、CMake，见 `vendor/upstream/zed/docs/src/development/windows.md`）。
- **上游源码**：`powershell -File scripts/fetch-upstream.ps1`（首次填充）、`-Check`（验证钉版本）；Git Bash 用 `scripts/fetch-upstream.sh [--check]`。
- **本机坑**（沿用全局记忆）：用户名含中文与全角括号，含中文的 `.ps1` 必须 UTF-8 with BOM；Bash 工具里 `\\` 会塌成 `\`；`%TEMP%` 是 8.3 短名，路径比较要双边规范化。
- **命令**：R0 起提供 `scripts/validate.ps1`（编译 + 测试 + 契约检查）与 `scripts/build.ps1`；在此之前本节只有 fetch。
