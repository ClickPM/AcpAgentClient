# Round 11 — Zed v1.25.2 复用代码与 ACP v1 依赖升级

> 状态：未开始（总体核查与实施计划已完成，2026-10-23）。本文登记计划，不表示版本或代码已经升级。
> 依据：所有者 2026-10-23 要求在一个 round 内跟进 Zed `v1.25.2`，由主会话评估 SDK；明确排除 ACP v2。

- 计划分支：`round-11`，开工时从最新 `main` 建立；计划核查基线 `main@f80a26ae6d3a9769d20c59d70d86ad10212ca3be`。
- 核查正本：[`upstream-audit.md`](upstream-audit.md)，包含版本证据、10 个本地派生文件映射、45 个相关提交的处置和 tag 外排除项。
- 无新画板；保持现有产品范围、Flutter 布局与 token。应用发版版本另定，不把 Zed 版本当作本应用版本。

## 目标

在一个 round 内将现存 Zed 派生代码的核对基线从 `d9e1c024f393832765a03f4de204d6c8cd9abcb2` 提升到 **Zed v1.25.2 / `d25fa01ccd788d812f236810b71af4feff6b2e38`**，吸收适用的 ACP v1 可靠性修复，并将 Rust SDK 升至该发布版使用的 **3.3.0**；所有线上握手仍为 `protocolVersion: 1`，不启用、不实现 ACP v2。

这里的 Zed 升级是复制／转写代码的逐项同步，不恢复已在 iteration-16 删除的内置 agent、sidecar、gpui 或 Zed 数据导入。

## 前置

1. 开工时复查本任务卡、`AGENTS.md`、`docs/agent-notes/README.md` 与工作区状态；不覆盖其他会话改动。
2. 按规则 4：先改 pins，再改 `docs/research.md`，再 fetch 并使 `scripts/fetch-upstream.ps1 -Check` 全绿。本文中的目标版本不是已经生效的 pin。
3. 新 worktree 中，未换版本的 vendor 可以沿用目录联接；Zed、SDK、协议源码换版本的副本独立取，避免把其他 worktree 的 vendor 改到新基线。
4. 使用独立 `CARGO_TARGET_DIR=D:\cargo-target\AcpAgentClient-round-11`；Windows 为必验平台，macOS 验证不能用 Windows 结果代替。

## 版本与能力决策

| 项 | 本轮方案 | 原因／边界 |
|---|---|---|
| Zed 来源 | `v1.25.2`，commit `d25fa01ccd788d812f236810b71af4feff6b2e38` | 固定 release 标签，不混入之后的 main |
| rust-sdk | `v3.3.0`，commit `199532c7433f1aec207dd0cada299901a5621ece` | 与目标 release 一致；有 v1 可用的 ordered prepared requests、取消句柄及连接 drain 修复 |
| 协议／Rust schema 来源 | 协议仓库 `v1.11.0`，commit `4cf3dd858c819fc3ab99ae53f76883ede0345a10`；Rust schema `1.11.0`，JSON Schema v1 `1.25.0` | 与 SDK 3.3.0 精确依赖一致；不要混淆这三个版本号 |
| 线上协议 | ACP v1 | 不开 `unstable_protocol_v2`；不用 v2 的状态机、消息快照、子会话或权限接口 |
| SDK features | 显式保留 `unstable_end_turn_token_usage`、`unstable_llm_providers`、`unstable_mcp_over_acp`、`unstable_plan_operations`、`unstable_session_fork` | 替代自动扩大的 `unstable` 伞；`session_compaction` 与 `tool_call_name` 已稳定，不再是 feature；不启用新 `unstable_subagents` |
| SDK 可选适配器 | 默认不加 `process`、`stdio`、`schemars` | 我们自己拉进程、使用通用 `Lines`；若实际编译发现消费者需要，先给出具体引用证据，不照抄 Zed feature 集 |
| notices | 本轮不声明 `session.notices`，不加 notice UI | 新 schema 能解析 notice 不等于产品已经支持；更新旧文档中“编译不出”的解释，保留未知／未支持通知的可观察性 |
| Node | Zed tag 内为 `24.21.0`；**实施建议使用官方安全版 `24.22.1`，作为唯一明确的 Node 安全补丁例外** | 该版 10-21 发布且官方标为 security release，不能假称它属于 Zed v1.25.2；系统 Node ≥22 的既定优先策略不改 |
| 其他上游／工具链 | 保持现有 pin 与 Flutter／Rust／frb 版本 | registry、五个 agent、dsh 不因这次 Zed 同步顺带追最新；仅在新 SDK 的兼容性有具体需要时单列变更证据 |

不机械复制 Zed 的 Cargo features：目标 tag 自己编译了 v2 代码，但本项目明确禁用它。开工时将规则 10 的“对齐 Zed”说明修正为上述有意差异，编号不改。

## 交付物与实施顺序

### A. 钉版本、来源与当前规范

- `pins/upstream.json`：恢复 zed **仅作源码参考／派生来源**的条目（不是构建依赖）；更新 rust-sdk 和 agent-client-protocol 的 commit。不开 sidecar。
- `docs/research.md`：更新当前 SDK、schema、Zed 参考基线及 feature 差异；历史 sidecar 内容保留归档属性。
- `rust/Cargo.toml` / `rust/Cargo.lock`：升级 SDK，锁定 schema，使用显式 feature。只更新本轮所需依赖闭包，不整份照抄 Zed lock。
- `docs/design.md` § 4、`docs/acp-projection.md`：稳定压缩、稳定 tool name、notice 未声明策略及实际编译面的重新核对。先改文档，再改实现。
- `AGENTS.md` 中与此次版本、规则 10／11、当前复用关系直接相关的过时描述收口；不改历史任务卡。
- `NOTICE` 与 10 个派生文件头逐个核对后更新到新来源 commit；无源码改动的模块也必须记录“已核对、差异不适用／无差异”。保持现有来源门，不靠批量换 SHA 冒充升级。

### B. 连接、创建与退出顺序

- `rust/acp-core/src/agent.rs`：参考 #65339，用 SDK prepared request 的有序响应处理完成会话注册，再放行依赖该会话的后续请求；回调里不等待同一连接后续流量，避免 dispatch 自锁。
- `lib/app/session_controller.dart`、`lib/projection/session_store.dart`、必要的 `batcher.dart`：先为 `_adoptSession` 清除提前更新的风险建立确定性复现；区分旧会话内容与这次创建的在途更新，保留既有“同 ID 新会话不得带入旧转录”的保护。只修本轮时序缺口，不引入第二套会话模型。
- 参考 #64603、#65282：按传输结束和事件顺序收尾，不只等固定 200 ms；进程退出前的已接受输出应有界排空，stderr 自独立管道采样；裸 EOF／传输错误即使进程不退出，也能结束等待和撤回 permission／elicitation。保留显式 Stop 的进程树回收。
- 参考 #64717：检查载入时关闭、失败后重试、同 ID 重开、调用方放弃后的清理；只修实际存在的问题，不移植 gpui 的 weak entity／foreground 队列。
- 保留 `AuthRequired`、数字错误码和结构化 data；不把 v2 的共享错误模型强塞进 v1。

### C. 压缩、权限、标题、终端的 v1 语义

- `lib/projection/compaction.dart`、`wire.dart`、`session_store.dart`：验证首个 chunk 建 in-progress 记录、完成后迟到 chunk 按序追加、补丁省略／null／空数组、位置不变及 metadata 作用域；复用画板 33，不新增呈现。
- `rust/acp-core/src/capabilities.rs`：保留已支持的 plan／压缩，禁止新 notices／subagents 能力泄入 initialize。
- `lib/projection/pending.dart` 与 Rust pending：对同 tool 的多个 request、旧请求迟到清理、取消和空闲会话权限补回归。我们已有按 `(agentId, requestId)` 的队列，只吸收缺口。
- 标题 null 清空、配置响应全量替换：本地已有对应处理，复核并保留，不添加 Zed 的默认配置功能。
- provider terminal 的显示缓冲与 client-owned PTY 分开判归属；先验证重复 Created／Exit、late output、signal-only exit、完整退出码及 Stop 路由。对确认存在的错误控制只做现有画板内的最小行为修正；必要时按规则 3 记录 DIVERGENCE。

### D. 安装、Node、Shell 与发送队列

- `rust/registry/src/node.rs`：升级受管 Node（上表安全补丁例外），核验官方包／校验和与 Windows npm 路径；不改用户系统 Node，不迁移或删除用户运行时。
- `rust/pty/src/shell.rs`：复核 #55727 的含空格参数与 #62473 的自定义 Scoop 根目录，按现有 shell 探测范围采纳；不新增 shell 类型、远程 SSH 或任务系统。
- `rust/registry/src/{index,install,archive,download}.rs`：按审计表逐项核对。`license_url` 与已有 `license` 不是同一个字段；本轮不新增许可证链接 UI。下载／解压原实现的取消、校验和、路径边界及原子提交继续保持。
- `lib/app/send_queue.dart`：核对目标 tag，维持现有 v1 队列；不移入 tag 外 #65674 的失败恢复，也不采用 Zed 的 v2 内容类型。
- 检查 SDK 迁移后普通错误／日志是否带私密 payload；必要整改使用现有脱敏边界，不为此升级到 tag 外 SDK 3.5。

### E. 验证、审查、收口

先完成下表回归和全量 validate，再按规则发起独立审查；有采纳 findings 就整改并复审。应用合并、出包、发布分别记录，未执行不得标完成。

## 验收

| # | 检查 | 命令／期望 |
|---|---|---|
| 1 | pins 与来源一致 | `powershell -NoProfile -File scripts/fetch-upstream.ps1 -Check`；三个目标 commit 全绿；NOTICE／10 个来源头门通过 |
| 2 | SDK 版本与 feature | `cargo tree --manifest-path rust/Cargo.toml -e features -i agent-client-protocol` 与 `-i agent-client-protocol-schema`；3.3.0／1.11.0；生产与测试依赖均无 `unstable_protocol_v2`／`unstable_subagents` |
| 3 | 实际线上 v1 | fake-agent 捕获 initialize：`protocolVersion: 1`；无 notices／subagents 新能力；既有 `_meta` 清单不扩张 |
| 4 | 首批消息与新建碰号 | new 响应后立即推 chunk／config／回调，前后端不丢；同时保证真正旧内容不会串入重用 ID 的新会话。确定性调度，不用延长 sleep 掩盖 |
| 5 | 最后输出与诊断 | agent 连续写最后回复／prompt 响应／stderr 后立即退出，退出事件前应有内容完整且脱敏；继承管道不关闭时在有界时间收尾 |
| 6 | 传输断开 | 仅关 stdout／返回 I/O 错误、进程仍活着；在途请求落定，空闲和 requestScope 的交互撤回；Stop／shutdown 不留进程 |
| 7 | 载入生命周期 | load 中关闭、失败重试、同 ID 重开、重放途中断连；旧转录保护、cwd 授权和资源释放正确 |
| 8 | 类型与恶意／畸形值 | Rust fixtures 全量；`terminal/create` 错误 args／env／cwd／limit、terminal auth 错误 args／env、fs 错误 line／limit 必须拒绝，不悄悄降为缺省执行 |
| 9 | 已有投影 | 压缩 chunk／patch、title:null、配置完整替换、权限旧请求清理与重复 ID 隔离、provider terminal 生命周期；未知通知仍可排障 |
| 10 | Windows 真跑 | PowerShell 5.1／可用时 pwsh 7，含中文与空格路径、`.cmd`、空参数与引号；terminal auth、取消、重载、Stop；记录实际命令与输出 |
| 11 | Node 与 registry | 隔离应用数据目录中 `node_download` 后 `node --version` 为目标值；官方包 SHA-256、`npm-cli.js`、npx 启动成功；安装取消／失败回滚／升级后重载不退化 |
| 12 | 真实 agent 矩阵 | claude-agent-acp、codex-acp、Cursor、pi、dsh 分别 initialize／new／prompt／cancel；按各自声明验 list／load／resume／close；至少一次 fs、终端、权限及可用的 elicitation。缺凭据明确待验，不用 fake 冒充 |
| 13 | 全量检查与构建 | `powershell -NoProfile -File scripts/validate.ps1 -CargoTargetDir D:\cargo-target\AcpAgentClient-round-11`；`scripts/build.ps1 -Smoke`；不新增 unsafe／gpui，规则 3、来源、版本门通过 |
| 14 | macOS 回归 | 在 macOS 跑 `scripts/validate.sh`、`scripts/build-macos.sh --smoke` 及 shell／Node／退出实测；未取得环境则记待验，不宣称跨平台完成 |
| 15 | 独立审查 | cursor CLI `grok-4.7-high-fast`；前两轮 `main...HEAD`，第 3 轮起上一轮整改 diff；阻塞 bug／漏洞清零才合并 |

## 禁止

- 不实现、不协商 ACP v2，不用 `schema::v2`／`Client.v2()`／双协议路由，不启用 unstable subagents。
- 不恢复 Zed sidecar、内置 agent、gpui、数据库或配置导入，不复制 Zed UI 与状态管理。
- 不新增 notices 页面／卡片、默认模型设置、远程连接、Git checkpoint、新 Shell 支持等设计稿之外的功能。
- 不按 main 最新功能扩张本轮，不顺带升级 agent／Flutter／Rust／frb，不修改 `vendor/upstream/` 源码。
- 不放宽错误处理、路径限制、脱敏、来源门或验收来让升级通过；不删除用户数据与旧安装。
- 本轮不绑定发版号、不自动合并／发布；Node 安全补丁的来源必须与 Zed tag 基线分别记录。

## 代码审查

- 审查方式：待实施和验证后，使用 `.claude/cursor-review.ps1`。
- 审查器与模型：cursor CLI `grok-4.7-high-fast`；硬失败按仓库规则原样重试一次（仅适用瞬时故障），仍硬失败就停下，不自动换执行器。
- 审查范围与基准提交：待开工记录；前两轮全量 `main...HEAD`，后续按整改范围。
- findings 处理：待实施。
- 结论：未发起；此刻仅计划，不能写 PASS。

## 失败处理

同一验收项针对性整改后连续两次仍不过，写本目录 `BLOCKED.md` 并停止该项呼人；不靠降低验收、升级到 main 或开启 v2 绕过。

## 本轮实测

2026-10-23 已完成 GitHub release／tag、相关源码和 schema 的只读静态核查，详见审计表。尚未改 pins、升级依赖、编译、运行行为复现或发起代码审查；Windows／macOS 与真实 agent 验收均待实施。
