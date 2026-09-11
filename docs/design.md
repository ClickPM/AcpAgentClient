# 整体设计

> 本文是架构与既定决策。范围以 [`requirements.md`](requirements.md) 为准，依据在 [`research.md`](research.md)。轮次拆解在仓库根 `ROUNDS.md`（首轮拆解时建立），本文 § 11 只是草案。

## 1. 进程模型

```
Tauri 主进程
├── WebView2 前端（TypeScript；按 design/ 设计稿实现；只消费 ACP 原样 JSON）
└── Rust 核心
    ├── acp-core    官方 rust-sdk v2 Client 角色；每个 agent 一条 stdio 连接，多会话复用
    ├── registry    registry.json 拉取 / 缓存 / 图标；npx 与 binary 安装；受管 Node
    ├── pty         terminal/* 回调（portable-pty）；terminal auth 用的可见终端
    ├── fs          fs/read_text_file、fs/write_text_file；工作区文件树与搜索
    └── settings    Zed 兼容的 agent_servers JSON；数据目录；从 Zed settings.json 导入
         │ stdio · ACP JSON-RPC（v1）
         ├── claude-agent-acp     npx
         ├── codex-acp            npx
         ├── cursor `agent acp`   binary
         ├── pi-acp               npx
         ├── dsh-acp-interactive  custom
         └── zed-agent-acp        sidecar（GPL；headless gpui + Zed NativeAgent；随主程序打包）
```

规则：主进程里没有 gpui；所有 agent，包括 Zed 内置 agent，都是子进程；前端与核心之间只传 ACP 形状的数据。

## 2. 分层与来源

| 层 | 来源 | 用法 |
|---|---|---|
| 协议客户端 | rust-sdk v2 | `Client::builder().on_receive_request(...)` 注册回调；`AcpAgentConfig` 拉起子进程；`unstable` 特性集与 Zed 对齐 |
| 前端类型 | 协议仓库 `schema/v1/schema.json` | 构建期生成 TypeScript 类型并入库；运行期零协议依赖 |
| registry 与安装 | Zed `agent_registry_store.rs`、`agent_server_store.rs` | 整体复制；删 remote / collab 路径；`Entity` / `Task` 换 tokio；`fs::Fs` 换 `tokio::fs`；结构体对照官方 `agent.schema.json` |
| Node 与下载 | Zed `node_runtime`、`http_client`、`reqwest_client`、`paths`、`util` | 直接 git 依赖（不含 gpui） |
| 连接与认证语义 | Zed `agent_servers/acp.rs` 非测试部分 | 转写：能力声明、AuthRequired 映射、terminal auth、session 控制、config options、elicitation、流量日志 |
| 终端回调语义 | Zed `acp_thread/terminal.rs` | 转写：输出字节上限、wait_for_exit、kill、release |
| 文件面板 | 自研 | `std::fs` + `notify`；不做索引服务 |
| Zed 内置 agent | Zed `agent` + `eval_cli` | sidecar，见 § 8 |
| UI | Claude Design 设计稿 | 全部自研 |

## 3. 核心与前端的契约（严格 ACP 投影）

**事件（核心 → 前端）**

| 事件 | payload |
|---|---|
| `acp/session_update` | `{agentId, sessionId, update}`；`update` 是 `SessionNotification` 的原样 JSON（SDK 类型 serde 直出） |
| `acp/client_request` | `{agentId, requestId, method, params}`；用于需要用户参与的客户端请求：`session/request_permission`、`elicitation/create`；前端必须以 `acp_respond` 回应 |
| `acp/agent_state` | 连接生命周期：spawned / initialized / auth_required(authMethods) / exited(code, stderr tail) |
| `acp/terminal_output` | terminal auth 与内置终端的输出流（非协议消息，仅用于可见终端） |
| `acp/traffic` | 原始 JSON-RPC 行（脱敏后），供调试面板 |

**命令（前端 → 核心）**

- 连接与会话：`agent_connect`、`agent_disconnect`、`session_new`、`session_load`、`session_list`、`session_close`、`session_prompt`、`session_cancel`、`session_set_mode`、`session_set_config_option`、`acp_respond`
- 认证：`authenticate`（agent 类型）、`terminal_auth_run`（terminal 类型；完成后核心自动重试 `session/new`）
- registry 与设置：`registry_refresh`、`registry_list`、`registry_install`、`agent_settings_get/set`、`agent_settings_import_zed`
- 文件面板：`fs_list_dir`、`fs_read`、`fs_watch`、`fs_search`

**前端状态规则**

- 按 `sessionId` 累积 `update`；`tool_call` 与 `tool_call_update` 按协议合并（同 id 覆盖，content 为替换语义）。
- `user_message_chunk` / `agent_message_chunk` / `agent_thought_chunk` 按顺序追加。
- 待处理的 permission 与 elicitation 是队列，回应后出队。
- 不在前端做任何 agent 特判。

## 4. initialize 能力声明

照 Zed 的 `client_capabilities_for_agent`：`fs.readTextFile`、`fs.writeTextFile`、`terminal`、`auth.terminal`、`session.configOptions.boolean`、`elicitation.form`、`elicitation.url`；`_meta` 里 `terminal_output: true`、`terminal-auth: true`。对 Cursor 追加参数化模型选择器键。**这是允许的 `_meta` 键的全部清单**，增加新键要改本节并进所有者裁定。

## 5. 认证流程

1. `session/new` 返回 `AuthRequired` → 展示 `initialize` 返回的 `authMethods`。
2. 方法类型为 `agent` → 调 `authenticate`，agent 自己开浏览器；成功后重试 `session/new`。
3. 方法类型为 `terminal` → 在可见终端里跑给定命令；进程退出后重试 `session/new`。兼容旧版 `_meta.terminal-auth`。
4. URL elicitation（codex-acp 登录）走 § 3 的 `acp/client_request`，前端打开系统浏览器并等待 `elicitation/complete`。

## 6. registry 与安装

1. 拉取：`registry.json` 1 小时节流，磁盘缓存，图标按需拉取；结构体对照 `agent.schema.json`。
2. 列表：按当前平台过滤 `binary` 的 target；`uvx` 条目显示但标「暂不支持」。
3. 安装：`npx` 解析包名与版本，写入 settings；`binary` 下载压缩包 → 校验 sha256 → 解压到 `agents/<id>/<version>/` → 记录 `cmd` / `args` / `env`。
4. Node：优先系统 Node ≥ 22；缺失时复用 Zed `node_runtime` 下载受管 Node v24.11.0 到数据目录。
5. 设置：`agent_servers` 与 Zed 同 schema（`type: registry | custom`），提供从 `%APPDATA%/Zed/settings.json` 导入。

## 7. 终端与 fs

- pty：portable-pty；每个终端有输出字节上限；`terminal/wait_for_exit`、`terminal/kill`、`terminal/release` 语义转写自 `acp_thread/terminal.rs`；Windows 下 `.cmd` 包装与引号处理必须实测。
- fs：路径必须是绝对路径且在会话工作目录之内；`line` / `limit` 是 1-based；写文件直接落盘（temp + rename）。

## 8. zed-agent-acp sidecar

- 独立 cargo workspace（`sidecar/zed-agent-acp/`），path 依赖指向 `vendor/upstream/zed/crates/*`；GPL-3.0-or-later。
- 引导：复制 `eval_cli/src/headless.rs`；`session/new` 时 `Project::local` + `create_worktree(cwd)` + `NativeAgent::new`。
- 映射：`initialize` → 固定能力；`session/new` / `session/load` / `session/list` → `NativeAgent::open_thread` 与 `ThreadStore`；`session/prompt` → `Thread::send` 得到 `ThreadEvent` 流；`session/cancel` → `Thread` 取消；`session/set_mode` 与 config options → `model_selector` / 权限预设。
- 事件翻译：`ThreadEvent::{UserMessage, AgentText, AgentThinking, ToolCall, ToolCallUpdate, SubagentSpawned, Retry, ContextCompaction*}` → `session/update`；`ToolCallAuthorization` → `session/request_permission`，结果写回 `response`；`Elicitation` → `elicitation/create`；`Stop` → `PromptResponse`。
- 终端：实现 `ThreadEnvironment::create_terminal`，进程内用 Zed `terminal` crate。
- 数据：默认与本机 Zed 共用 `threads.db` 与 `settings.json`；是否隔离在 R6 裁定。
- 打包：作为 Tauri `externalBin` 随主程序分发。

## 9. 前端

- TypeScript；框架在 R0 裁定（React 或 Solid），样式按设计稿。
- 设计稿存 `design/`：每轮一个子目录，含 `design-prompt.md` 与 `.dc.html`；`design/README.md` 是画板索引，画板编号只增不改。
- 页面：会话工作台（消息、思考、工具卡、计划、用量、权限与 elicitation）；agent 管理（registry、custom、认证状态）；文件面板；设置；ACP 流量调试。
- 接后端只换数据源，不改样式。

## 10. 数据目录

Windows：`%APPDATA%/AcpAgentClient/{settings.json, registry-cache/, agents/, node/, logs/}`。会话数据归各 agent 自己（claude、codex、pi、dsh 各有自己的存储）；本客户端只存会话索引（agentId + sessionId + 标题 + cwd + 时间）。日志脱敏：`Authorization`、`api_key`、`token` 字段一律打码。

## 11. 阶段草案

| 轮 | 目标 | 参照 agent |
|---|---|---|
| R0 | 脚手架：Tauri 2 + Rust workspace + 前端骨架 + schema→TS 生成 + validate 脚本 | 无 |
| R1 | 主线：拉起、initialize、terminal auth、prompt、权限、取消 | dsh-acp-interactive |
| R2 | 会话工作台按设计稿实现 | dsh-acp-interactive |
| R3 | fs 与 terminal 回调 | claude-agent-acp |
| R4 | registry：拉取、npx / binary 安装、受管 Node；URL elicitation 登录 | codex-acp、Cursor |
| R5 | session/list、session/load、modes、config options、Zed 设置导入 | pi-acp、全部 |
| R6 | zed-agent-acp sidecar | Zed 内置 agent |
| R7 | 打包：Windows 免安装 zip 与安装器；macOS | 全部 |

设计轮插在实现轮之前：R2 之前先出会话工作台设计稿，R4 之前先出 agent 管理设计稿。

## 12. 风险与对策

| 风险 | 对策 |
|---|---|
| Windows 上 npx 类 agent 的 `.cmd` 包装与引号 | R1 第一项验收就是用 dsh 在 Windows 实测；转写 Zed `ShellBuilder` 的处理 |
| `unstable` 特性集漂移 | 钉 rust-sdk commit；改钉先改 `pins/upstream.json` 与 `research.md` |
| sidecar 与运行中的 Zed 争用 `threads.db` | R6 裁定：只读共用 / 隔离目录二选一 |
| Zed 构建环境重 | sidecar 独立 workspace，主程序不依赖它也能跑；CI 分开 |
| 设计稿范围蔓延 | 画板编号只增不改；设计稿没有的功能进 BACKLOG |
