# R11 上游核查 — Zed v1.25.2，ACP v1

> 核查日期：2026-10-23；本地基线 `main@f80a26ae6d3a9769d20c59d70d86ad10212ca3be`。
> 性质：静态总体核查与迁移决策，不是代码升级完成报告。实施与验收在 [`round-11.md`](round-11.md)。

## 1. 固定范围与证据

历史派生来源 `d9e1c024f393832765a03f4de204d6c8cd9abcb2`（2026-09-11）是目标标签的祖先。
[GitHub compare](https://github.com/zed-industries/zed/compare/d9e1c024f393832765a03f4de204d6c8cd9abcb2...v1.25.2) 返回 ahead **512 个提交**、behind 0，merge-base 为该旧 commit。
比较接口只返回最多 300 个文件，**300 不是全部改动文件数**；本核查使用逐路径 commit 历史和目标版本源码补充，不能用 compare 首屏冒充全仓逐行审查。

重点覆盖 NOTICE 中 10 个本地派生文件的 7 个直接上游路径，以及 shell quoting、PowerShell discovery、terminal lifecycle 三个关联路径：合计 **10 个上游路径、45 个去重后的相关提交**。逐提交索引见 § 6；v1 相关行为审阅实现／补丁，v2 共享模型与接线按明确排除项归类。没有重新审查 Zed 全部编辑器、模型供应商、数据库或远程功能。

| 对象 | 目标事实 | 一手证据 |
|---|---|---|
| Zed | `v1.25.2`，2026-10-21；commit `d25fa01ccd788d812f236810b71af4feff6b2e38` | [Release](https://github.com/zed-industries/zed/releases/tag/v1.25.2)、[tag ref](https://api.github.com/repos/zed-industries/zed/git/ref/tags/v1.25.2) |
| Zed 的 SDK | `agent-client-protocol =3.3.0` | [Cargo.toml](https://github.com/zed-industries/zed/blob/v1.25.2/Cargo.toml)、[Cargo.lock](https://github.com/zed-industries/zed/blob/v1.25.2/Cargo.lock) |
| SDK 来源 | `v3.3.0` 解引用到 `199532c7433f1aec207dd0cada299901a5621ece`，不是 annotated tag 对象 SHA | [tag object](https://api.github.com/repos/agentclientprotocol/rust-sdk/git/tags/7f86bc09a899f9b009c584005086da31771a9943) |
| schema | SDK 精确依赖 `agent-client-protocol-schema =1.11.0`；协议仓库 `v1.11.0` commit `4cf3dd858c819fc3ab99ae53f76883ede0345a10`，对应 JSON Schema v1 `1.25.0` | [SDK workspace](https://github.com/agentclientprotocol/rust-sdk/blob/v3.3.0/Cargo.toml)、[schema release](https://github.com/agentclientprotocol/agent-client-protocol/releases/tag/schema-v1.25.0)、[tag object](https://api.github.com/repos/agentclientprotocol/agent-client-protocol/git/tags/13f4faa179c306807d53dc6ad933df6f9a7d97e2) |
| Node | Zed tag 内 `24.21.0`，最低系统 Node 仍为 `22.0.0` | [node_runtime.rs](https://github.com/zed-industries/zed/blob/v1.25.2/crates/node_runtime/src/node_runtime.rs) |
| 线上协议 | Zed 该发布源码仍以 v1 InitializeRequest 建立正常 ACP 连接；内部已存在 v2 共享类型／未启用的接线代码 | [acp.rs](https://github.com/zed-industries/zed/blob/v1.25.2/crates/agent_servers/src/acp.rs) |

## 2. 产品范围与文件映射

iteration-16 已删除 Zed sidecar 与其 pin。目前没有对 Zed crate 的直接构建链接；“升级 Zed”意味着重新核对和转写适用差异。GPL 来源继续保留，不恢复内置 agent。

| 本地派生文件 | 直接上游路径 | 目标 tag 的变化与处置 |
|---|---|---|
| `rust/acp-core/src/agent.rs` | `crates/agent_servers/src/acp.rs` | 35 个相关提交；重点采纳有序创建、退出排空、断线收尾。gpui foreground、共享 v2 类型不搬 |
| `rust/acp-core/src/capabilities.rs` | 同上 | 压缩已稳定；notice 新增稳定能力。保留现有 plan／压缩，不声明 notice／subagents |
| `rust/acp-core/src/terminal_auth.rs` | 同上 | 保留一等 terminal auth 与旧 `_meta` 回退；新 schema 对 args／env 的畸形值更严格，补拒绝执行用例 |
| `rust/pty/src/shell.rs` | `crates/util/src/shell_builder.rs` | 2 个提交：含空格参数用例、远程秘密传输；前者适用，后者的 SSH 实现不适用 |
| `rust/registry/src/archive.rs` | `crates/project/src/agent_server_store.rs` | 直接来源只增加 license 元数据测试适配，解压分类无该项行为变化；不更换我们用系统 tar 的实现 |
| `rust/registry/src/install.rs` | 同上 | 同上，不引入新安装机制；既有原子提交／取消／回滚必须保留 |
| `rust/registry/src/index.rs` | `crates/project/src/agent_registry_store.rs` | 新字段为 **license_url**；本地已有 license／authors 不能视为相同支持；不增加设计稿没有的链接 UI |
| `rust/registry/src/download.rs` | `crates/http_client/src/github_download.rs` | 该路径相对来源基线无新提交；核对后保留 |
| `rust/registry/src/node.rs` | `crates/node_runtime/src/node_runtime.rs` | 受管 Node 24.21.0、新 standalone 系统 Node 探测；升级受管版本，保留我们现有探测接口，不复制新公共抽象 |
| `lib/app/send_queue.dart` | `crates/agent_ui/src/conversation_view/message_queue.rs` | tag 内两次变更主要是 content 类型及读取待发候选的辅助方法；不用 v2 类型，不包含 tag 外失败恢复 |

关联路径：`crates/util/src/shell.rs`（远程秘密传输）；`crates/gpui_util/src/lib.rs`（自定义 `SCOOP`、依赖缩减）；`crates/acp_thread/src/terminal.rs`（provider lifecycle、v2 display patch 与依赖变化）。不将这些 crate 链进 Flutter 宿主。

## 3. SDK 决策：建议 2.1.0 → 3.3.0，仍然使用 ACP v1

证据：[SDK 3.3.0 累计 changelog](https://github.com/agentclientprotocol/rust-sdk/blob/v3.3.0/src/agent-client-protocol/CHANGELOG.md)、[v3 migration](https://github.com/agentclientprotocol/rust-sdk/blob/v3.3.0/md/migration-v3.md)、[feature manifest](https://github.com/agentclientprotocol/rust-sdk/blob/v3.3.0/src/agent-client-protocol/Cargo.toml)。

升级有实际 v1 收益：3.0 的连接所有权与 graceful drain，3.1 的发送前选择响应顺序处理，3.2 的 retained cancellation handle，3.3 的稳定 notice／compaction schema。#65339 正在使用这些有序请求 API 解决 session/new 注册窗口；继续 2.1.0 就要自己维护相似的 RPC 时序适配，不推荐。

主要破坏面及本项目暴露：

- SDK 默认 features 变为空；原生 `process`、`stdio` 与 `schemars` 分开可选。本项目生产代码使用自己管理的 tokio process 与通用 `Lines`，不使用 SDK `AcpAgent`／`Stdio` 子进程适配器，不照抄 Zed 的 feature 集。
- `ConnectTo::into_channel_and_future` 返回值变为 `Option<ConnectionDriver>`。本地代码未找到对此方法的直接调用／override，主要风险落在连接完成和测试 Channel 的收尾语义；仍需全量编译和 EOF 回归。
- raw JSON-RPC response／error 载体改变。生产代码以 typed request 和 JSON notification 边界为主，未找到直接匹配 `RawJsonRpcMessage::Response` 的逻辑；迁移仍要验证数字错误码、data:null／缺省与 AuthRequired。
- unstable MCP 改为 request-scoped。我们不实现 MCP bridge，也不把 SDK 的新 MCP 机制纳入范围；保留既有编译面，不新增协议功能。
- SDK 的 `unstable` 新增 `unstable_subagents`；本轮改为显式列出原有未稳定的 5 项。`unstable_protocol_v2` 继续关闭；`unstable_subagents` 也关闭。
- `unstable_session_compaction`、`unstable_tool_call_name` 已移除／稳定，不能继续把它们写为 feature。升级 Rust schema 后同步更新投影清单和原先 15 变体门的解释。

**不以 SDK 3.x 推导线上协议 v2。** SDK 3.3.0 文档仍提供稳定 v1 入口。本轮没有 v2 迁移阶段，也不为未来 v2 建新队列／共享模型。

### 3.1 schema 逐类型对照

比对旧 pin 与 `v1.11.0` 的 `schema/v1/schema.unstable.json`，并读取新稳定 `schema.json`：

- `ToolCall`、`ToolCallUpdate`、`CompactionUpdate`、`CompactionSummaryChunk` 去除说明文字后形状相同；不能因“稳定化”就重写现有压缩 UI。
- **v1 PromptResponse.stopReason 仍是原来的 5 个字符串。** 新出现的 `ErrorStopReason` 属于实验子会话／共享状态范围，不能把 Zed 共享模型的结构化停止值当成本项目 v1 prompt 已改变。
- `fs/read_text_file` 的 line／limit、`terminal/create` 的 args／env／cwd／outputByteLimit，以及 terminal auth 的 args／env，移除了畸形值默认化／跳过条目的宽容标记。升级后应拒绝有问题的执行参数，不回退执行另一条命令。
- 稳定 schema 有 14 个 session/update 变体（旧稳定 11 + notice + 两个 compaction）；保留 plan_operations 后还多 2 个。**16 个可编译不等于全部应呈现**：本轮仍只支持既有投影范围，不声明 notices；非协商发送的 notice 保持计数／traffic 可排障，避免原先的“不支持”因为新 SDK 可解析而变成静默吞掉。
- 已稳定的 compaction 定义明确：首个 chunk 建 in-progress 实体，后续 chunk 即使实体已结束也按序追加；实体补丁与 chunk metadata 作用域不同。现有实现大体符合，补针对性回归，不凭字面名称判断完成。

## 4. 本地已有等价处理与待复现风险

| 项 | 本地证据 | 处置 |
|---|---|---|
| 新建首批消息 | `Sessions.applySessionUpdateEnvelope` 对未知 ID 自动建壳；`SessionController._adoptSession` 发现 existing 就 resetForReplay | **存在清除提前更新的静态代码路径风险**，还未运行复现；同时 Rust 在 new 响应 await 后才 record_session，后续 fs／terminal 也可能先于 cwd 登记。先做确定性回归，再最小整改，不能删掉防碰号保护 |
| 退出排空 | `exit_watcher` 在 child.wait 后固定 sleep 200 ms，再 finish | 与上游有界等待 transport／foreground drain 不等价；核查最后更新、提示完成响应、stderr 与退出事件顺序 |
| 裸传输关闭 | `io.await` 后仅 `!has_process` 时 finish；有进程时依赖 exit watcher | 进程活着但协议管道断开时，空闲请求清理依赖不充分；需复现 EOF／错误两条路并验证终端与请求收尾 |
| 交互请求归属 | `PendingQueue` 已用 `(agentId, requestId)`；Rust 有 responder 表，前端 exited 会 withdrawAgent | 不移植 Zed request registry；补旧请求清理不得命中新请求、裸断线和 requestScope 的边界 |
| 标题／配置 | SessionStore 使用 `hasTitle` 区分 null；set_config_option 响应 `_setConfigOptions` 全量替换 | 已有对应语义。#65195、#65233 不能直接记为本项目待修 bug；回归验证即可，不添加默认配置设置 |
| provider terminal | 独立缓存已保留退出码与 signal；terminal_card 的 running Stop 与通用 onKill 路由仍需看归属 | 不认定整套生命周期缺失；验证 provider 显示缓冲不能冒充本地 PTY、重复通知不重置退出、late output 留存等 |
| Shell | 对 args 已按 shell quote；探测仅 PATH、ProgramFiles、系统 PowerShell | #55727 在 shell_builder 只加测试，不能误报为新 quoting 算法；自定义 SCOOP 探测可作现有功能修复，需 Windows 真跑 |

以上是源码核查结论；未运行 targeted reproducer，不能据此宣称已定位线上复现或修复完成。

## 5. 版本标签之外的明确排除与安全例外

前一轮答复同时参考了 release 和 main。固定目标后，以下不属于 v1.25.2，不能混记为该版本交付：

| 项 | 本轮处理 |
|---|---|
| #65607 ACP v1 适配器拆文件、#65822 新建前 provisional staging、#65850 defaults 限新建 | tag 外，不复制其架构；基于 tag 内 v1 实现解决本地已证实缺口 |
| #65674 inactive v2 cancellation／队列 restore_after_failed_send | tag 外；发送队列本轮不以此为升级依据 |
| #65892 beta v2 negotiation／v1 fallback | tag 外，且所有者明确排除 v2 |
| #65976 subagent association／child routing | tag 外；不新增能力与 UI |
| #65982 SDK 3.5.0 | tag 外；3.3.0 为本轮目标；其普通日志脱敏修复作为检查线索，不整体追 main |
| #65956 Node 24.22.1／TLS／Wasmtime 安全更新 | tag 外；Node 按下述明确安全例外建议纳入，其余先检查实际依赖与适用性 |
| #65280 pnpm／Yarn 项目 language server 安装 | tag 外，也不是本项目功能 |

**Node 安全例外的推荐依据**：[Node 24.22.1 官方公告](https://nodejs.org/en/blog/release/v24.22.1) 将 2026-10-21 版本标为 security release，列有 TLS、DNS、Brotli 等修复；[Zed 后续 #65956](https://github.com/zed-industries/zed/pull/65956) 也已将受管 Node 从 24.21.0 升到 24.22.1。建议本轮直接使用 24.22.1，来源与基线分开披露，避免刚升级完又分发旧安全版本。只更新我们下载的 runtime，不替用户改系统 Node。

本地 lock 有 `rustls-webpki 0.103.15`；[0.103.16 官方说明](https://github.com/rustls/webpki/releases/tag/v/0.103.16) 撤销信任部分 intermediate SPKI。但我们的 registry HTTP 使用 reqwest `native-tls`，Windows 用系统 Schannel，**不能仅凭 lock 判断 registry 的 TLS 受影响**。实施时先查实际生产依赖闭包和 TLS 调用，再决定必要的定向安全补丁；不引入 Zed 的整个 TLS／Wasmtime 栈。当前没有 sidecar，不追 Wasmtime 升级。

发布记录里的长会话 CPU／内存优化 #65244 是 Zed 的整线程序列化、压缩与 SQLite 保存；外部 prompt 卡住修复 #65304 是 Zed Git checkpoint。我们没有这两套实现，不移植；编辑器、Git Graph、SSH、语言服务器、模型供应商及二进制体积优化也不在本轮产品范围。

## 6. 45 个相关提交的逐项处置索引

本表去重于 § 1 的 10 个上游路径；“已有／验证”表示核查本地等价语义，不表示已跑过测试；“吸收”仍须先复现或有明确类型兼容需要。源码来源均可从对应 PR 到达，固定目标为上方 release commit。

| PR | 上游内容 | 本轮处置 |
|---|---|---|
| [#64077](https://github.com/zed-industries/zed/pull/64077) | ACP 2.1／futures 更新 | 本地已 SDK 2.1；随本轮统一到 3.3，不单独抄依赖 |
| [#64081](https://github.com/zed-industries/zed/pull/64081) | context compaction | 已有投影，复核稳定契约 |
| [#64178](https://github.com/zed-industries/zed/pull/64178) | registry license_url | 元数据差异登记；无新链接 UI |
| [#64262](https://github.com/zed-industries/zed/pull/64262) | application adapter／LLVM IR | Zed／gpui 架构，不搬 |
| [#55727](https://github.com/zed-industries/zed/pull/55727) | Windows worktree 空格参数 | 吸收测试场景；不新增 Zed task 变量 |
| [#62473](https://github.com/zed-industries/zed/pull/62473) | 自定义 Scoop pwsh 路径 | 在既有 shell 探测内最小适配、Windows 验证 |
| [#64544](https://github.com/zed-industries/zed/pull/64544) | provider terminal lifecycle | 验证并修本地归属／完成／退出码缺口 |
| [#64598](https://github.com/zed-industries/zed/pull/64598) | 提取 ACP stdio 构造 | 本地已有分工；不为结构对齐重构 |
| [#64603](https://github.com/zed-industries/zed/pull/64603) | 退出前 drain | 吸收有界排空语义 |
| [#64606](https://github.com/zed-industries/zed/pull/64606) | session notices | schema 可解析；不声明／不增加呈现 |
| [#64717](https://github.com/zed-industries/zed/pull/64717) | abandoned load 清理 | 验证本地 close／retry／reopen，按缺口整改 |
| [#64719](https://github.com/zed-industries/zed/pull/64719) | 从历史移除完成计划卡 | 产品呈现选择，不删现有画板的历史计划 |
| [#64862](https://github.com/zed-industries/zed/pull/64862) | 减少依赖 | 不照抄 Zed manifest |
| [#64765](https://github.com/zed-industries/zed/pull/64765) | 共享 v2 content 值 | 排除 v2 类型；队列 v1 保持 |
| [#64928](https://github.com/zed-industries/zed/pull/64928) | standalone Node discovery | 已有本地探测；核对路径／错误，不新增公共抽象 |
| [#64976](https://github.com/zed-industries/zed/pull/64976) | authoritative terminal display／snapshot | v2 patch／snapshot 排除；仅核对 legacy provider 不退化 |
| [#64985](https://github.com/zed-industries/zed/pull/64985) | v2 terminal decode | 排除 |
| [#65039](https://github.com/zed-industries/zed/pull/65039) | permission 按请求生命周期 | 已有请求表；验证旧请求／取消／重复工具 ID |
| [#65080](https://github.com/zed-industries/zed/pull/65080) | generic permission UI／v2 | 排除，不加新卡片 |
| [#65093](https://github.com/zed-industries/zed/pull/65093) | 共享 v2 config | 类型桥排除；v1 配置回归保留 |
| [#65176](https://github.com/zed-industries/zed/pull/65176) | dependency footprint | Zed 专用，不搬 |
| [#65165](https://github.com/zed-industries/zed/pull/65165) | outbound v2 content／队列候选 | v2 类型排除；辅助函数不构成必需功能 |
| [#65195](https://github.com/zed-industries/zed/pull/65195) | shared session info／title clear | v1 null 清空已有，验证用户重命名不被回写覆盖 |
| [#65230](https://github.com/zed-industries/zed/pull/65230) | v2 prompt capabilities | 排除共享类型，现有能力门回归 |
| [#65233](https://github.com/zed-industries/zed/pull/65233) | defaults 后 reasoning 配置 | 全量替换已有；不加 defaults 功能 |
| [#65235](https://github.com/zed-industries/zed/pull/65235) | shared v2 auth | 类型桥排除；terminal auth v1 回归 |
| [#65241](https://github.com/zed-industries/zed/pull/65241) | shared v2 notices | 排除，不声明 notices |
| [#65248](https://github.com/zed-industries/zed/pull/65248) | shared v2 elicitation | 排除共享类型，现有 form／url 回归 |
| [#65174](https://github.com/zed-industries/zed/pull/65174) | 远程 launcher 参数泄露秘密 | 无 SSH launcher；本地沿用 Command.envs，仍做凭据日志检查 |
| [#65282](https://github.com/zed-industries/zed/pull/65282) | EOF／错误取消 elicitation | 吸收断线清理，覆盖 idle／requestScope |
| [#65339](https://github.com/zed-industries/zed/pull/65339) | initial update／startup diagnostic 顺序 | 吸收 prepared request 与最小本地接线修复 |
| [#65373](https://github.com/zed-industries/zed/pull/65373) | Node 24.21.0 | 更新受管 runtime；建议追加明确安全例外 24.22.1 |
| [#65350](https://github.com/zed-industries/zed/pull/65350) | shared v2 IDs | 排除，不改本地 v1 标识 |
| [#65393](https://github.com/zed-industries/zed/pull/65393) | v2 tool events／permission choices | 排除共享类型；既有 v1 语义回归 |
| [#65414](https://github.com/zed-industries/zed/pull/65414) | SDK 3.3／稳定 notice、compaction | 升 SDK，压缩契约适配；notice 不声明；不移入 v2 stop reason |
| [#65518](https://github.com/zed-industries/zed/pull/65518) | process output 与 v1 解耦 | 本地已有独立 terminal buffer，保留；不新增共享抽象 |
| [#65520](https://github.com/zed-industries/zed/pull/65520) | modes/defaults 使用 config value | 保留 v1 modes 回退及完整响应处理，无新 defaults |
| [#65523](https://github.com/zed-industries/zed/pull/65523) | protocol error 归一与保留详情 | 验证 v1 AuthRequired／code／data，迁移需要则最小改 |
| [#65536](https://github.com/zed-industries/zed/pull/65536) | v2 message ingress | 排除 |
| [#65541](https://github.com/zed-industries/zed/pull/65541) | v2 tools／plans ingress | 排除 |
| [#65543](https://github.com/zed-industries/zed/pull/65543) | v2 terminals ingress | 排除 |
| [#65552](https://github.com/zed-industries/zed/pull/65552) | v2 session info／commands | 排除 |
| [#65553](https://github.com/zed-industries/zed/pull/65553) | v2 notices／compaction | 排除 |
| [#65556](https://github.com/zed-industries/zed/pull/65556) | v2 config／usage | 排除 |
| [#65558](https://github.com/zed-industries/zed/pull/65558) | v2 permission／elicitation | 排除 |

## 7. 验证状态

- 已完成：GitHub tag／release、SDK 精确版本与 feature、schema 新旧类型静态对照、相关路径提交索引与重点补丁核对、本地实现映射、round 计划。
- 未执行：pins 修改、vendor 更新、源码升级、依赖解析／构建、行为复现、Windows／macOS 真跑、真实 agent 全通矩阵、独立代码审查。
- 本次不触碰用户会话、配置、系统 Node 或安装版；不创建 sidecar，不改来源头冒充同步完成。
