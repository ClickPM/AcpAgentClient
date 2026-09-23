# Backlog · Zed agent

内置 Zed agent（`zed-agent-acp` sidecar）专属的台账。**所有者裁定 2026-09-23：Zed agent 的问题从 [`BACKLOG.md`](BACKLOG.md) 整体移到这里，当前不修**——不排进轮次，也不进迭代候选；哪天重启 Zed agent 的工作，由所有者从这里点名捞回。

- 背景、版本、sidecar 化方案、与本客户端的集成、**已知上游限制**都在 [`docs/zed-agent.md`](../docs/zed-agent.md)；看条目前先看那份。
- 收什么：内置 Zed agent 与 sidecar 自己的问题（sidecar 源码、构建、打包、与客户端的接线、相关文档欠账）。**出在 zed 上游或协议本身的仍不收**，记 `docs/zed-agent.md` § 4（与 `BACKLOG.md` 同一条裁定，2026-09-23）。
- 格式与 `BACKLOG.md` 相同：每条「标题 / **产品** / **技术**」三行，技术行末尾括号里是发现时的轮次与日期；移入的条目注明原档位。新增条目追在对应小节末尾。
- 关闭：同 `BACKLOG.md`，把技术行连同结论压成一行 `- [x]` 剪到 [`BACKLOG-CLOSED.md`](BACKLOG-CLOSED.md) 末尾（平铺存档，与主台账共用一份）。
- sidecar 源码注释里写的「记 BACKLOG」（`src/session.rs` 文件头与压缩那一支），现在指的是本文或 `docs/zed-agent.md` § 4；改 `.rs` 注释会触发 176 MB 重链，所以那两处没改。

| 小节 | 条数 |
|---|---|
| 功能缺口 | 2 |
| 构建与打包 | 2 |
| 工程与文档 | 4 |
| 待所有者确认的裁定 | 1 |
| | **9** |

## 功能缺口（2）

- [ ] **Zed agent 的斜杠命令发出去只是普通消息**（原 `BACKLOG.md` P2 · agent 接入，2026-09-23 移入）
  - **产品**：`/` 菜单里看得到 `compact`，点了没有压缩效果；MCP prompt 与 skill 调用同理。
  - **技术**：R7 sidecar 不走 `NativeAgentConnection::prompt` 而是直接消费 `Thread::send` 的事件流（理由见 `sidecar/zed-agent-acp/src/session.rs` 文件头），于是 Zed 的斜杠命令分流（`/compact`、MCP prompt、skill 调用）没有接上：`available_commands_update` 照常投影（前端 `/` 菜单能看到 `compact`），但发出去只是一条普通消息。要接上得把那段分流逻辑复制出来（`agent.rs` 的 `Command::parse` 一大段），或等上游把 `handle_thread_events` 公开 (2026-09-17)

- [ ] **Zed agent 的子代理不投影**（原 `BACKLOG.md` P2 · 投影与输入，2026-09-23 移入）
  - **产品**：Zed agent 开的子代理在界面上完全看不见，只进日志。
  - **技术**：R7 Zed 的子代理（`ThreadEvent::SubagentSpawned`）是**另一条会话**，事件不经过本轮的流；画板 24 的子代理卡只认 `docs/design.md` § 4 清单里的 `_meta` 键，而清单里没有 Zed 的键，所以 sidecar 只记日志、不投影。要做得先给 § 4 加键并进所有者裁定 (2026-09-17)

## 构建与打包（2）

- [ ] **sidecar 缺 languages crate，Zed agent 的语法工具退化**（原 `BACKLOG.md` P4 · 构建链，2026-09-23 移入）
  - **产品**：Zed agent 读超过 16 KB 的文件又没给行号时，只拿到**前 1 KB 原文**而不是带行号的文件大纲（`vendor/upstream/zed/crates/agent/src/outline.rs` 的 `AUTO_OUTLINE_SIZE = 16384`）；跳转类工具退化成纯文本；编辑、终端、grep、权限不受影响。装上 VS 的「Spectre 缓解库」组件即可恢复。
  - **技术**：R7 sidecar 没带 `languages` crate（它唯一地依赖 `pet`，`pet` 打开 `msvc_spectre_libs` 的 `error` 特性，本机 VS 2022 BuildTools 没装「Spectre 缓解库」组件，build.rs 直接 panic）。代价：sidecar 里 `LanguageRegistry` 为空，Zed agent 靠语法树的工具（`read_file` 的 outline 模式、跳转类工具）退化成纯文本。修法：构建机的 VS Installer 给 BuildTools 勾「MSVC v143 - VS 2022 C++ x64/x86 Spectre 缓解库（最新）」（2026-09-23 核对：`VC/Tools/MSVC/14.44.35207/lib` 下仍没有 `spectre` 目录）→ 取消 `sidecar/zed-agent-acp/Cargo.toml` 里 `languages` 那一行的注释 → `src/headless.rs` 补回 `languages::init`（并改文件头改动清单的第 4 条）→ 重编 sidecar（新 crate 要编、176 MB 全量重链至少十几分钟；产物会变大，大多少未测）→ `-Selftest` + 应用内实跑一次大文件读取 (2026-09-17)

- [ ] **sidecar 的数据目录落在 0-dev 下**（原 `BACKLOG.md` P4 · sidecar 打包，2026-09-23 移入）
  - **产品**：只影响目录名，数据已经隔离。
  - **技术**：R7 sidecar 的 release channel 解析成 `dev`（`ZED_RELEASE_CHANNEL` 没设，`release_channel` 的编译期缺省），所以它的 `db/` 落在 `0-dev` 下。数据已经隔离，这项只影响目录名；要对齐得在 sidecar 的 build.rs 里显式设一个 channel（动 `build.rs` 同样触发重链）。`iterations/iteration-01.md` 候选第 11 项即此条，已随本次移入撤出候选 (2026-09-17)

## 工程与文档（4）

以下四条是 2026-09-23 统筹 Zed agent 条目时盘点出来、此前没进任何台账的，直接记在这里。

- [ ] **sidecar 自检路径上的两条 ERROR**
  - **产品**：用户无感，不影响退出码；排障读 sidecar 的 stderr 时会被这两条误导。
  - **技术**：R8 `verify-package.ps1` 重跑时 sidecar `--selftest` 的 stderr 里有两条 ERROR：`prompt_store … environment already open in this program`（同一进程里 lmdb 环境开了两次），与 `settings_store Failed to write settings to file …\config\settings.json: 系统找不到指定的路径`（隔离数据目录下的 `config/` 没建就写；模型与密钥走 `--zed-settings` 只读那份，写不进去不影响功能）。R8 写了「属于 R7 遗留、记 BACKLOG」但没记（`rounds/round-08/round-08.md`「审查整改后重跑一遍」段）。未核实：真正的 ACP 会话路径上是否也出现；是我们的引导顺序（`src/headless.rs` 复制自 eval CLI）引起的，还是上游 eval CLI 本身也会报——后者按上游问题移到 `docs/zed-agent.md` § 4、从本文关闭 (R8, 2026-09-20)

- [ ] **sidecar 的单测没有任何脚本会跑**
  - **产品**：用户无感。
  - **技术**：`scripts/validate.ps1` 不碰 sidecar（只扫 `unsafe` / `_meta` / 派生文件头与版本门），`scripts/build-sidecar.ps1` 也没有测试开关，`src/translate.rs` 的单测（终端增量差分、权限选项摊平与去重、`_meta` 形状）只在有人手动进 `sidecar/zed-agent-acp/` 带同一个 `CARGO_TARGET_DIR` 跑 `cargo test` 时才跑。最小修法：`build-sidecar.ps1` 加一个 `-Test` 开关 (2026-09-23)

- [ ] **sidecar 源码里两处过时注释**
  - **产品**：用户无感。
  - **技术**：`src/session.rs` 的 `close_session` 注释引用 `lib/app/workbench_controller.dart` 的 `closeSession`，R7.5 拆分后它在 `lib/app/session_controller.dart`；`src/headless.rs` 文件头说「改动只有三处」，下面列的是四处。改 `.rs` 注释会让这个 crate 重编 + 176 MB 重链（只有 `Cargo.toml` 的注释不触发），等因别的原因改到这两个文件时顺手改 (2026-09-23)

- [ ] **`docs/acp-projection.md` § 9.1 发射表没有 Zed agent 一列**
  - **产品**：用户无感。
  - **技术**：§ 9.1 的 agent 发射表是 R6 按五个外部 agent 建的，没有 Zed agent 列；它实际发哪些变体目前只能看 `docs/zed-agent.md` § 2.5 的事件翻译表。补列时按 R6 的口径实测一遍，别照 sidecar 源码抄 (2026-09-23)

## 待所有者确认的裁定（1）

- [ ] **sidecar 数据「配置共用、数据隔离」待确认**
  - **产品**：本客户端里 Zed agent 的会话与本机 Zed 编辑器里的线程互相看不到。
  - **技术**：R7 实测与运行中的 Zed 共用 `threads.db` 会让 Zed 保存线程报 `database is locked`，按推荐项落地 `--zed-settings` 只读沿用 + `--user-data-dir <数据目录>/zed-agent`（`docs/zed-agent.md` § 2.6）。`docs/design.md` § 8 与 § 12、`ROUNDS.md` R7「裁定（开工前）」三处仍标着「待所有者确认」；确认后把这三处改成定稿措辞，要改回全共用只需在 `rust/acp-core/src/builtin.rs` 去掉 `--user-data-dir` (R7, 2026-09-17)

另有一项相关但**不是 Zed 专属**的待确认裁定，留在原处不搬：`docs/design.md` § 4 的终端 provider 通道（`_meta.terminal_info / terminal_output / terminal_exit`，claude-agent-acp、dsh、codex 也走它），sidecar 的终端输出完全依赖这条通道。

## 附 · 相关的已关闭条目（存档在 [`BACKLOG-CLOSED.md`](BACKLOG-CLOSED.md)）

- **sidecar 与运行中的 Zed 争用 `threads.db`** → R7 实测后按「配置共用、数据隔离」落地（2026-09-17），确认那一步见上一节。
- **新建会话弹层里的 agent 名与图标** → R7 起取条目里的 `name`，内置条目带自己的 `iconSvg`。
- **Zed agent 的上下文压缩投影不出去**、**读 threads.db 失败和真的没有会话长得一样** → 2026-09-23 按「上游 / 协议的问题不进台账」关闭，现记在 `docs/zed-agent.md` § 4.1 第 1、8 条。
- **macOS 构建还没把 cargokit 挂进 Xcode** → 2026-09-23 关闭（目前没有 mac 设备）；macOS / Linux 的 sidecar install 规则随之搁置。
- **sidecar 体积是打包时的大头** → 2026-09-23 关闭：R8 已给出含 / 不含 sidecar 的两个体积。
