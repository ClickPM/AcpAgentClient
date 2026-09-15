# 核心诉求

> 本文是范围的权威定义：写在「必须」里的要做，写在「不做」里的不做，两边都没有的进 `rounds/BACKLOG.md` 等所有者裁定。

## 一句话

一个好看的、多 agent 的 ACP 桌面客户端：Flutter 壳，Rust 核心（进程内 cdylib，经 flutter_rust_bridge 桥接），前端按 Claude Design 设计稿实现；agent 一律经 ACP 接入，registry 里的 agent 像 Zed 一样安装即用，Zed 内置 agent 也能用。

## 必须

1. **Agent 交互只走 ACP。** 前端看到的就是 ACP 线上消息（`session/update`、`session/request_permission`、`elicitation/create` 等）的原样投影；不自造第二套协议，不给任何 agent 做私有通道。
2. **registry 安装即用。** 拉官方 `registry.json`；分发类型支持 `npx` 与 `binary`（与 Zed 对齐），binary 校验 sha256；npx 依赖系统 Node ≥ 22，缺失时按 Zed 的方式下载受管 Node；认证两种都实现：Agent Auth（调 `authenticate`，agent 自己开浏览器）与 Terminal Auth（在内置终端跑 agent 给的命令，退出后重试 `session/new`）。
3. **五个重点 agent 是一等公民**，各自的「安装 → 认证 → 新会话 → 一轮含工具调用与权限的对话 → 终端 → 取消 → 重开并加载历史」必须全通：

   | agent | 分发 | 认证 | 依赖的客户端能力 |
   |---|---|---|---|
   | claude-agent-acp | npx | agent auth / terminal auth，也认环境变量 | fs 读写、交互与后台终端、elicitation、权限 |
   | codex-acp | npx（内置 codex 二进制） | ChatGPT 登录走 URL elicitation；或 `OPENAI_API_KEY` | 终端、fs、权限、URL elicitation；三种 mode，config options |
   | Cursor（`agent acp`） | 六平台 binary 压缩包 | 先 `agent login`（terminal auth）或 `--api-key` | fs 与终端可声明为 false；三种 mode |
   | pi-acp | npx | terminal auth `--terminal-login`；密钥在 pi 自己的配置里 | 不用客户端 fs 与终端；`session/load`；slash 命令 |
   | dsh-acp-interactive | custom 命令 | terminal auth `--setup`；`session/new` 回 `auth_required` | 读 `_meta.terminal_output`、`elicitation.form`、`session.configOptions.boolean`；权限预设是 config option |

4. **Zed 内置 agent 可用。** 以独立 sidecar `zed-agent-acp` 经 ACP stdio 接入，与其他 agent 走同一条路。
5. **前端完全自研。** Claude Design 设计稿是功能边界：设计稿没有的功能不做，设计稿有的逐画板对照实现；每个画板的 `.dc.html` 源与 PNG 快照入库，PNG 作验收基准（见 `design/README.md`）。
6. **开源、不商用。** 因复用 Zed 源码，许可证拟为 GPL-3.0-or-later。
7. **尽量复用，少造轮子。** 白名单内能复用的都复用，方式分三级：直接链接 crate、复制文件后改写、只作参考转写。每一处复用在文件头标注来源仓库、路径与 commit。
8. **依赖白名单。** 实现层只允许来自下列来源（钉版本见 `pins/upstream.json`）：
   - 官方协议仓库 `agentclientprotocol/agent-client-protocol`（规范与 `schema/v1` JSON Schema）
   - 官方 `agentclientprotocol/rust-sdk`
   - 官方 `agentclientprotocol/registry`
   - `zed-industries/zed`
   - 五个 agent：`claude-agent-acp`、`codex-acp`、Cursor CLI ACP（仅文档）、`svkozak/pi-acp`、`ClickPM/dsh-acp-interactive`

   **界定：** 白名单约束的是「ACP 客户端逻辑、agent 状态模型、会话 UI」这类实现来源。语言级基础库与工具（Rust 侧 tokio、serde、serde_json、reqwest、sha2、portable-pty、notify、flutter_rust_bridge；Dart 侧 Flutter SDK 自带的 Material / Cupertino、flutter_rust_bridge、xterm、url_launcher、file_selector、flutter_svg（所有者裁定 2026-09-15）、一个 diff 库、一个 Markdown 渲染库（所有者裁定 2026-09-12：**spike 选型后再进白名单**，spike 之前不得引入）；构建期的 schema 代码生成器与 frb codegen）属于工具，不受白名单限制，清单之外的新增要在任务卡写明理由；任何实现了 ACP 客户端、agent 会话状态或会话 UI 的第三方库（例如 acp-components、acp-ui、pi-web）一律不引入，第三方 UI 组件库（shadcn_ui、GetWidget、fluent_ui 及同类）与状态管理库（riverpod、bloc、getx 及同类）同样不引入。
9. **平台。** Windows 首发；macOS 随后；Linux 尽量。

## 不做

- 不做代码编辑器；不做 Zed 的 Project / Buffer / LSP 模型。`fs/read_text_file` 就是读磁盘，不存在「编辑器未保存内容」。
- 不做 pi RPC 直连；GPUI-Pi 的 `pi-rpc` 不复用，pi 走 pi-acp。
- 不做 Zed 的 remote、collab、cloud 相关能力；不接 Zed 账号。
- 不引入任何第三方 ACP UI 或状态库；不参考 pi-web、acp-components 的代码。
- 首期不做 `uvx` 分发（记 backlog）。
- `_meta` 私约只实现 Zed 已用的键（见 `design.md` § 4），不为单个 agent 增加新键。
- 不做 Web 版、移动版。

## 验收视角

- 每个必须项都能落成任务卡里可证伪的验收行（命令 + 期望）。
- 「安装即用」的判据是：在一台只有系统 Node 的干净 Windows 上，从 registry 面板点安装到发出第一条 prompt，不需要看文档。
