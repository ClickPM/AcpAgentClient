# Round 05 — registry、安装、受管 Node、认证页与设置页

<!-- 保存为 rounds/round-05/round-05.md；该轮其他管理产出放同一目录。 -->

> 状态：进行中

## 目标

按画板 50 / 51 / 52 / 70 落地 agent 管理页：registry 面板从拉取到安装到首次握手全通（npx 与 binary 两型、取消、
Remove、受管 Node），认证页覆盖 agent 型、terminal 型与 requestScope 的 URL elicitation（R3 留下的「requestScope 没有落点」
在本轮关闭），设置页四块（agent 配置含 custom 型行内编辑、从 Zed 导入、Node 运行时、数据目录与日志）落地。
参照 agent：codex-acp（npx；ChatGPT 登录走 URL elicitation；`OPENAI_API_KEY` 路径）与 Cursor（binary；terminal auth）。

可证伪：ROUNDS.md § 3 R5 的 7 条验收要点逐条有命令与输出；`git diff <画板阶段收口提交>..HEAD -- lib/theme lib/ui` 为空。

## 前置

- 轮次：R3 已完成（`4b888d7`，整改合并 `d6b6e31`）。R4 与本轮并行开发（另一 worktree，尚无提交），本轮基于 `main`；
  右栏框架用 R3 的 `lib/ui/shell/right_panel.dart`（Agents 标签的正文本轮填）。
- `powershell -File scripts/fetch-upstream.ps1`（本 worktree 首次填充）后 `-Check` 全绿（2026-09-16，8 个钉版本全 OK）。
- 本机版本：Flutter 3.47.4 stable（Dart 3.13.3）、rustc / cargo 1.98.1、Node v24.11.1（系统 Node，≥ 22）、
  `flutter_rust_bridge_codegen` 2.13.0、`C:\Windows\System32\tar.exe`（bsdtar 3.8.8，解 zip / tar.gz 用）。
- 网络：`https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json` 可达（2026-09-16：version 1.0.0，41 个 agent；
  与钉版本 registry 仓库比，cursor 已从 2026.09.02 升到 2026.09.10，列表以线上为准、仓库只作 schema 对照）。
- 参照 agent 凭据：codex-acp 走 ChatGPT 登录（device code，URL elicitation）与 `OPENAI_API_KEY`；Cursor 走 `agent login`。
- 本机 Zed `settings.json`（`%APPDATA%\Zed\settings.json`）里有 `agent_servers` 五条（cursor / codex-acp / pi-acp / claude-acp 四条
  registry 型 + dsh-acp-interactive custom 型，带 `default_config_options`），是验收 4 的输入。

## 交付物

### 画板阶段（只用本地假数据 / fixtures）

- `lib/theme/tokens.dart`：`Geometry` 组新增画板 50 / 51 / 52 / 70 量得的单点尺寸（agent 图标框 28、图标框内菱形 10、
  条目状态卡宽 560、设置页内容宽 860、设置页标签列宽 160、进度条高 3、单选圆 14 / 点 6、认证终端最小高）。
- `lib/ui/registry/registry_panel.dart`（50：标题 + Learn More、搜索、All / Installed / Not Installed 计数、条目列表、
  缺 Node 提示卡）
- `lib/ui/registry/registry_entry.dart`（51：未安装 / 安装中 npx 三步 / 安装中 binary 三步 + 进度条 / 已安装 / 需要认证 /
  安装失败 / uvx 暂不支持 / custom 条目 / 受管 Node 提示卡；条目数据模型 `RegistryEntryData`）
- `lib/ui/registry/auth_page.dart`（52：认证方式选择、terminal auth 可见终端、成功后自动重试、失败态、requestScope 的 URL elicitation）
- `lib/ui/settings/settings_page.dart`（70：agent 配置列表含 custom 型行内编辑 cmd / args / env、从 Zed 导入、Node 运行时、
  数据目录与日志路径的打开 / 复制）
- `lib/ui/transcript/icons.dart`：新增 `download` 一枚（50 / 51 / 70 的 Install / 下载受管 Node）
- `lib/projection/registry.dart`：`registry_list` 与 `registry/progress` 的投影（条目状态机、下载速率与剩余时间估算）
- `lib/gallery/boards/agent_boards.dart`：50 / 51 / 52 / 70 四张 gallery 画板

### 接线阶段（只换数据源；`lib/theme` 与 `lib/ui` 零 diff）

- `rust/registry`：`index.rs`（registry.json 拉取 / 1 小时节流 / 磁盘缓存 / 图标按需拉取 / 按平台过滤 binary target；
  结构体对照官方 `agent.schema.json`；Derived from Zed `agent_registry_store.rs`）、`install.rs`（npx：解析包名与版本 →
  `npm install` 到 `agents/<id>/` → 读 `package.json` 的 `bin`；binary：下载 → sha256 → 解压到 `agents/<id>/<version>/` →
  记 cmd / args / env；取消；Remove 只删 `agents/<id>/`；Derived from Zed `agent_server_store.rs`）、`node.rs`（系统 Node ≥ 22
  检测；受管 Node v24.11.0 下载到 `node/`；参考转写 Zed `node_runtime`，见「偏离」）、`archive.rs`（系统 `tar` 解压，见「偏离」）、
  `manifest.rs`（`agents/<id>/install.json`：安装记录 + 认证状态）。
- `rust/settings`：`AgentServer` 两型补 Zed 同 schema 的 `default_mode` / `default_config_options` / `favorite_config_option_values`
  并保留未知字段；`import_zed`（读 `%APPDATA%/Zed/settings.json` 的 `agent_servers`，JSONC 去注释，导入为 custom 型，不覆盖同名）。
- `rust/acp-core`：registry 型的拉起（manifest → `LaunchSpec`，npx 型经系统 / 受管 Node）；`session/new` 成功与 `-32000`
  回写认证状态；`registry/progress` 事件通道；`logs/acp-<日期>.log`（脱敏后的流量行）。
- `rust/bridge/src/api.rs`：`registry_refresh` / `registry_list` / `registry_install` / `registry_cancel_install` /
  `registry_remove` / `node_status` / `node_download` / `agent_settings_import_zed` / `agent_settings_remove` /
  `terminal_close`；`registry_progress_stream` 第六条事件流；`flutter_rust_bridge_codegen generate` 生成物入库。
- `lib/app/`：`core_bridge.dart` 补命令与事件；`workbench_controller.dart` 接 registry / 认证页 / 设置页；
  `workbench_screen.dart` 把右栏 Agents 标签换成 `RegistryPanel` / `AuthPage`、设置作为主区页面；
  `headless_run.dart` 加 `ACP_R5_REPORT` 无头口子（安装 → 认证 → 一轮对话 → Remove）。

## 验收

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | codex-acp 全通 | 干净数据目录：Agents 面板搜索 codex → Install（51 三步可见）→ 新会话 `-32000` → 52 选 ChatGPT device code（URL elicitation，requestScope）→ 自动重试 → 一轮对话；再以 `OPENAI_API_KEY` 环境变量路径过一遍 |
| 2 | Cursor binary | 下载 + sha256 校验 + 解压（51 进度条）→ terminal auth → 一轮对话；人为篡改 sha256 → 安装失败态，可重试、可看日志 |
| 3 | 受管 Node | PATH 里剔除 Node → 51 的受管 Node 提示 → 下载 → npx 型 agent 可用；数据目录只多 `node/` |
| 4 | 从 Zed 导入 | `agent_servers` custom 条目进 70，同名不覆盖，registry 型条目按 id 匹配 |
| 5 | Remove | 条目回未安装、settings 条目消失、`agents/<id>/` 被清理，其他目录不动（规则 7） |
| 6 | registry 缓存 | 断网时列表仍可显示、安装报网络错误而不是崩 |
| 7 | gallery 与门禁 | gallery 50 / 51 / 52 / 70 对照；接线零 diff 判据；`scripts/validate.ps1` 全绿；Windows 实测记录（规则 9：`.cmd`、解压、sha256） |

## 禁止

默认继承三条：不改前端页面样式（CLAUDE.md 规则 3）；不加设计稿没有的功能（规则 3）；不在 `vendor/upstream/` 里改代码（规则 4）。
本轮另外：不做 `uvx`（BACKLOG 既定，只显示「暂不支持」）；不做外观设置（BACKLOG）；不碰 R4 的文件面板 / 终端面板文件
（`lib/ui/files/`、`lib/ui/terminal/`、`rust/fs` 的 watch / read、`rust/pty` 的 Zed 语义转写），只实现契约里本轮要用的
`terminal_close`（认证页的停止方块）。不动 Zed 的 `settings.json`（只读导入）。

## 代码审查

<!-- 完成后回填。 -->

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-05/BLOCKED.md`，停下呼人。禁止放宽验收标准自我通过。

## 本轮实测

<!-- 完成后回填 -->
