# Round dsh-1.3.2 — dsh 会话根目录移出进程工作目录（上游修 + 升钉版本）

<!-- 改钉版本按 iterations/README.md § 0 走轮次；所有者 2026-09-24 当面指示开工，不另设裁定门。 -->

> 状态：已完成，2026-09-24 快进合入 `main`（所有者指示；未构建，所有者指定）

## 目标

内置 dsh 条目拉起的 dsh 把会话存在与进程工作目录无关的固定位置：换项目后重载 / 重启应用，原会话能载回来，项目根目录不再多出 `.sessions`。

## 前置

- 所有者 2026-09-23 报障，登记在 `rounds/BACKLOG.md` P0「dsh 的会话存到哪里跟着进程工作目录走」。
- 所有者 2026-09-24 指示：根因在上游（dsh-acp-interactive 是所有者自己的仓库），先拉上游最新、在上游改、发布 npm 1.3.2，再调整本项目；**不动旧会话**。
- `scripts/fetch-upstream.ps1 -Check` 全绿（本 worktree 的 `vendor/upstream/` 里 dsh 是按新钉版本单独拉的一份，其余 8 个是指向主副本的目录联接）。

## 交付物

**上游（ClickPM/dsh-acp-interactive，`cfb2260`（1.3.1）→ `e39fd48`（1.3.2））**

- `config/cordis.yml`：持久化根目录 `DSH_ACP_SESSIONS_ROOT ?? './.sessions'` → `DSH_ACP_SESSIONS_ROOT || dshHomePath('acp-sessions')`（缺省 `~/.dsh/acp-sessions`，随 `$DSH_HOME` 走；空值视为未设置）。
- `tests/bin.spec.ts`：真 launcher 用例——从一个进程工作目录写会话、另一个工作目录起的 launcher 列出并载回，两处都不出现 `.sessions`。
- 版本 1.3.2：`package.json` / `package-lock.json` / `registry/agent.json` / `docs/compatibility*.md`；`CHANGELOG*.md`、`README*.md`；Agent Note `docs/agent-notes/2026-09-24-home-sessions-root.md`。
- 发布：推 `github` 远端 `main` 与 tag `v1.3.2`，`release.yml` 经 trusted publishing 发 npm。

**本项目**

- `pins/upstream.json`：dsh-acp-interactive `0b10058` → `e39fd48`（规则 4）。
- `docs/research.md` § 5 dsh 那条：补会话存储位置与 1.3.2 的变化。
- `rust/acp-core/src/builtin.rs`：`DSH_PACKAGE` `@1.3.0` → `@1.3.2`（npx 回退）。
- `rust/acp-core/src/command.rs`：`build_command` 注释删掉「dsh 把会话存在 cwd 下」。
- `rounds/BACKLOG.md` 那条 P0 关闭，压成一行剪到 `rounds/BACKLOG-CLOSED.md`。

**不做**：内置条目不塞 `DSH_ACP_SESSIONS_ROOT`（用户在 `settings.json` 里写的同名条目优先，会绕过去；且与其他客户端里的 dsh 存储位置分叉）；不迁移、不删除各项目 `.sessions` 里的旧会话（所有者指示）；前端零改动（Dart 侧没有依赖进程 cwd 的逻辑）。

## 验收

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | 上游全套门禁 | `npm run typecheck` / `npm test` / `npm run test:harness` / `npm run check:profile` / `npm run check:registry` / `npm run verify:packed` / `npm pack --dry-run` / `git diff --check` 全过 |
| 2 | 新用例确实覆盖缺陷 | 换回旧 `config/cordis.yml` 时新用例失败，新配置下通过 |
| 3 | npm 上有 1.3.2 | `npm view deepseekharness-acp-interactive@1.3.2 version` → `1.3.2` |
| 4 | 钉版本一致 | `scripts/fetch-upstream.ps1 -Check` 9 项 OK |
| 5 | 本项目验证门 | `scripts/validate.ps1 -CargoTargetDir D:\cargo-target\AcpAgentClient-dsh132` 全绿 |
| 6 | Windows 实测（规则 9）· 拉起 | 内置条目走 `npx -y deepseekharness-acp-interactive@1.3.2`（PATH 上摘掉全局安装），含中文与空格的项目目录下 initialize / `session/new` / `session/prompt` 成功 |
| 7 | Windows 实测 · 报障场景 | 已发布的 1.3.2 经 npx：进程 cwd = 项目 A、会话 cwd = 项目 B，close 后从 B 起的新进程 list 得到、load 得回；两个项目下都没有 `.sessions`；同一脚本换 1.3.1 复现原报错 |

## 禁止

默认三条（规则 3 / 4）之外：不动任何已有的 `.sessions` 目录；不改 Dart 侧会话挂载逻辑；不把 dsh 的存储路径写进核心。

## 代码审查

- 审查方式：`cursor-review.ps1 -Wait`（默认档，1 轮）
- 审查器与模型：cursor CLI `grok-4.7-high-fast`
- 审查范围与基准提交：`main...HEAD`（`7dcdfbe...2a4d12f`，8 个文件）；产物 `.claude/reviews/20260924-091955-review.out.md`
- findings 处理：0 条。审查器核对了钉版本三处一致（pins commit = 上游 HEAD `e39fd48`、`DSH_PACKAGE` `@1.3.2`、research.md 与上游 `cordis.yml` 的写法），并确认 `rust/` 与 `lib/` 里没有把会话根目录绑在进程 cwd 或 `./.sessions` 上的遗留
- 结论：PASS（无采纳整改，不复审）
- 合并：所有者 2026-09-24 指示合入、不构建。先把 `main@4f1c057`（iteration-10 / 11）合进分支：冲突只有 `rounds/BACKLOG.md` 与 `rounds/BACKLOG-CLOSED.md` 两份登记文档，代码全部自动合并、与本轮改的 `builtin.rs` / `command.rs` 不重叠 → **无代码改动不复审**；BACKLOG 以 main 为底删掉 dsh 那条连同变空的「数据一致性」小节，逐小节重数（P0 3 / P1 3 / P2 0，合计 6），CLOSED 两边都留、本条排在 main 的四行之后；合并后 validate 全绿再快进 `main`
- 上游 dsh-acp-interactive 的改动不在本仓库审查范围：它有自己的门禁（验收 1），并经 CI / Release / Registry auth check 三条 workflow 通过

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-dsh-1.3.2/BLOCKED.md`，停下呼人。禁止放宽验收标准自我通过。

## 本轮实测

- **根因核对**（上游源码）：`dsh-session-persistence-jsonl` 在插件启动时 `resolve(config.root)` 一次，之后所有日志落 `<root>/<projectKey(会话 cwd)>/<id>/`；`cordis.yml` 另两处 `process.cwd()`（`sandbox-policy.workspaceRoot`、`fs-sandbox.cwd`）只是无会话调用的兜底，每次调用优先用会话头的 cwd，不受影响。harness 官方 bundle（`packages/bundle/base/cordis.patch.yml`）用的是 `dshHomePath('sessions')`；dsh-acp-interactive 那一行抄自 `examples/acp-agent/*.cordis.yml` 的 `./.sessions`。`dsh-app-boot` 的 `boot()` 把 `dshHomePath` `provide` 进 loader 作用域，`!!js` 里可直接调。1.3.1（2026-09-23 发布）仍是旧写法。
- **为什么用 `acp-sessions` 而不共用 `sessions`**：本包钉自己的 harness 基线，与同机其他 harness 界面的版本不一定一致；README 也写明 ACP 与其他界面的会话相互隔离。
- **上游门禁的两个环境坑**：① `test:harness` 在 Git Bash 里报 `spawnSync tar EOF`（GNU tar），PowerShell 里用 Windows 自带 bsdtar 通过；另需先 `git fetch upstream tag dsh-v0.1.5-rc.3` 给兄弟目录 `deepseek-harness` 补上钉住的 tag。② `check:profile` 读兄弟目录的**工作区**（已在 `dsh-v0.1.6-alpha.2`），报 `dsh-workflow-ptc` 漂移；用 `DSH_HARNESS_ROOT` 指向 `dsh-v0.1.5-rc.3` 的临时检出后通过——漂移来自上游前进，与本改动无关（1.3.1 同样会报）。临时检出放 `D:\hrc3`（scratchpad 路径超 MAX_PATH），用完 `git worktree remove`。
- **发布**：`release.yml` 全部步骤成功，发布日志 `+ deepseekharness-acp-interactive@1.3.2`（带 provenance）；随后自动触发的 Registry auth check 在发布后 5 秒启动、npm 尚未可见，`notarget` 失败——与 1.3.1 同一竞态，npm 可见（`latest: 1.3.2`）后 `gh workflow run registry-auth.yml --ref v1.3.2 -f version=1.3.2` 重跑通过；`main` 上的 CI 也通过。
- **验收 1–5**：上游八项全过（`test:harness` / `check:profile` 的环境处理见上）；新用例在旧配置下失败、新配置下通过；`fetch-upstream.ps1 -Check` 9 项 OK；`validate.ps1 -CargoTargetDir D:\cargo-target\AcpAgentClient-dsh132` → `VALIDATE OK`（flutter test 527 项全过）。
- **验收 6（拉起）**：`acp-smoke run --agent dsh-acp-interactive --cwd "<…>\实测 项目A" --prompt /plan`，PATH 摘掉 `%APPDATA%\npm`、`ACP_DSH_PATH` 置空 → `acp/agent_state` 报 `program: npx, args: ["-y","deepseekharness-acp-interactive@1.3.2"]`，`agentInfo.version` = `1.3.2`，`session/prompt` → `end_turn`，exit 0。
  - acp-smoke 验不了存储位置：它 prompt 完就 `taskkill /F` 整棵进程树、不发 `session/close`，而 dsh 只在模型请求前 / 工具派发 / 一步完成时做 checkpoint，`/plan` 这类本地命令三样都不沾，于是什么都没落盘（换真文本 prompt、假 key 下模型请求被拒，也没落出日志）。改用验收 7 的脚本。
  - 另一个坑：scratchpad 在 `C:\Users\Click\` 下，工具看到的那一片是虚拟视图（见记忆），存储类的判断一律放 `D:\`（本 worktree 的 `build/dsh-smoke/`，gitignored）。
- **验收 7（报障场景）**：`build/dsh-smoke/reported-scenario.mjs`（不入库；用 dsh 仓库 node_modules 里的 ACP SDK 1.4.0 当客户端，`DSH_HOME` 指临时目录、假 key）。
  - 1.3.2：会话落在 `<DSH_HOME>\acp-sessions\--…-scenario-~9879~76EE~0020B--\<id>`，`dotSessionsInA/B` 均 false，从 B 起的进程 `listSessions` 列出它、`loadSession` 回 `plan` 模式。
  - 1.3.1：`storedUnderHome` 为空、项目 A 下出现 `.sessions`、B 列不出，`loadSession` 报 `Internal error: session restore failed: session "…" not found`，与所有者报障原文一致。
- **本机日常安装不会自动生效**：内置条目先找 PATH 上的全局安装，本机 `%APPDATA%\npm` 里是 1.3.0；要 `npm i -g deepseekharness-acp-interactive@1.3.2` 之后，日常用的应用（以及 Zed）才换到新行为。npx 回退只在没有全局安装的机器上走钉版本。
