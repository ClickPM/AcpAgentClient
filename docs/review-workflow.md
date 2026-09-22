# 独立审查工作流（首选 cursor CLI + grok 4.7 high fast，回落 Claude Code 子代理）

> **本文只管「谁来审、怎么发起、结果怎么取回、什么时候回落」。审查的策略**（范围口径 / 复审收口标准 / 审查边界）
> **正本在 [`CLAUDE.md`](../CLAUDE.md)「开发模式：轮次与迭代」与 [`iterations/README.md`](../iterations/README.md) § 2，本文不复述、只引用。**
> 审查者读的任务书是 [`.claude/cursor-review-prompt.md`](../.claude/cursor-review-prompt.md)（入库，改契约改它，两级共用）；
> cursor 路径的启动脚本是 [`.claude/cursor-review.ps1`](../.claude/cursor-review.ps1)，与 agent-xray 的同名脚本**逐字节一致**
> （2026-09-15 两边同步把 `--plan` 换成 `--mode ask`，原因见「四条容易踩的」第 4 条；2026-09-20 两边同步把默认 `-Model` 换成 `cursor-grok-4.6-high-fast`；2026-09-22 两边同步换成 `grok-4.7-high-fast`（`cursor-agent --list-models` 确认，4.7 起 grok 系列不再带 `cursor-` 前缀）；**改一边就要同步另一边**）。

## 0. 执行器（所有者裁定 2026-09-11，沿用 agent-xray）

| 级 | 执行器 | 形态 | 何时用 |
|---|---|---|---|
| ① | cursor CLI（`cursor-agent`）+ `grok-4.7-high-fast` | `.claude/cursor-review.ps1` 后台拉起的独立进程，读实例化后的任务书 | 首选 |
| ② | Claude Code 子代理 | 主会话用 Agent 工具委派一个只读子代理，读同一份任务书 | ① 硬失败 |

**硬失败的定义**：`cursor-agent` 未安装 / 未登录 / 启动失败 / 限流 / 后台进程已死而 `.out` 仍空。「等得久」「改动小」不是回落理由。
R0 实测（2026-09-15）：曾两次拿到空 `.out` 并据此误判为硬失败 —— 真因是脚本当时发的是 `--plan`，终稿被 plan 通道吞掉（见下方「四条容易踩的」第 4 条），进程其实跑满了 7–10 分钟、退出码 0、审查也做完了。**空 `.out` 且退出码为 0 不算硬失败**，先查发起参数，再谈回落。
回落原因写进任务卡「代码审查」段；同一轮审查只用一个执行器，免得两份 findings 编号打架。

流程与策略对两级完全一样：Claude Code solo 开发 + 独立审查者做缺陷门禁；
「前两轮全量 / 第 3 轮起只审整改 diff」「不得带 high 级 findings 收口」「审查不代替设计、非严重 finding 不许机制类修复」三条一字不改。

## 1. 路径 ①：cursor CLI（在仓库根跑）

```powershell
# 前两轮：全量分支 diff（main...HEAD）
powershell -File .claude\cursor-review.ps1

# 第 3 轮起：只审上一轮 findings 整改后的 diff
powershell -File .claude\cursor-review.ps1 -Scope since -Base <上一轮已审提交>

# 零已提交基线的轮次：审未提交的改动
powershell -File .claude\cursor-review.ps1 -Scope worktree

# 质疑设计取舍那一档
powershell -File .claude\cursor-review.ps1 -Kind adversarial

# 小 diff 想直接看结果：前台阻塞跑
powershell -File .claude\cursor-review.ps1 -Wait
```

参数：`-Base`（默认 `main`）、`-Scope branch|since|worktree`（默认 `branch` = `<Base>...HEAD`；`since` = `<Base>..HEAD`；`worktree` = 未提交改动）、
`-Kind review|adversarial`、`-Model`（默认 `grok-4.7-high-fast`）、`-Note "<本轮要点>"`、`-Wait`。

**迭代流程的档位**（`iterations/`，2026-09-22 起；正本在 `iterations/README.md` § 2）：默认**一轮** `-Scope since -Base <分支基线提交>`（小 diff 加 `-Wait`，未提交时 `-Scope worktree`）；有采纳整改再一轮只审整改 diff；直到 0 条 high 才合并。执行器、硬失败判定、回落条件与本文其余部分完全一样；免审只认所有者逐项指定。

脚本做四件事：验 `cursor-agent` 在位且已登录 → 验 git 范围非空（空 diff 直接拒）→
把任务书模板实例化（填入范围与要点，`review` 档删掉 adversarial 专属段）→ 后台起 `cursor-agent`，
把 stdout / stderr 落到 `.claude/reviews/<时间戳>-<kind>.{out.md,err.log}`（整个目录 gitignored）。

发起时用的固定档位：`--mode ask`（CLI 强制只读，审查者不许改文件）+ `--force`（**承重，不是图省事**：本机 `~/.cursor/cli-config.json` 的 `approvalMode` 是 `auto-review`，不压住就会对一部分工具调用弹审批，而后台跑没有 TTY = 永远挂起、`.out` 永远空）+ `--trust` + `--output-format text`。**别换成 `--plan`**，原因见下方第 4 条。

### 取回结果

- **结果在结束时一次性落地** `.out.md`；中途没有任何输出是正常的。
- **`.err.log` 通常一直是 0 字节**：`--output-format text` 下 cursor-agent 不往 stderr 写心跳。**别拿「err 是空的」判它死了**，
  判死活看进程树：`Get-CimInstance Win32_Process -Filter "Name='node.exe'"` 里找命令行带 `index.js -p` 的那个。
- 轮询 `.out.md` 非空，或 `tasklist /FI "PID eq <pid>"`（脚本打印的 pid 是 `cmd` 壳，真正干活的是它的 node 子进程）；
  **Git Bash 里先 `export MSYS_NO_PATHCONV=1`**，否则 `/FI` 被当路径改写、永远报「进程已死」。
- **耗时基线**（本项目 R6 实测 2026-09-16，同机）：30 文件 / 约 +2,800 行的全量分支 diff **12 分 03 秒**；
  同一分支多 300 行的第 2 轮全量 **11 分 26 秒**。（agent-xray 同机：单文件 diff 5 分钟，13 文件 / 825 行的全量分支 diff 7 分 35 秒。）
- **「等待期间不要改仓库里的文件」是认真的**（R6 第 1 轮踩到）：审查者按自己的节奏读工作树，中途改动会让它报出你已经修掉的东西，
  收 findings 时得逐条拿当前代码核对才分得清「真缺陷」与「你看到的是旧版」。要自查就等审查结束再动。

### 七条容易踩的

1. **`cursor-agent` 不在 PATH**：Windows 装在 `%LOCALAPPDATA%\cursor-agent\cursor-agent.cmd`，Git Bash 里裸敲是 command not found。脚本按绝对路径找，不要自己改成裸命令。
2. **必须先 `cursor-agent login`**：未登录时它会等交互输入，后台跑就是**永远不结束、`.out` 永远空**。脚本起手先跑 `cursor-agent status` 拦这一种。
3. **审查期间不要改仓库里的文件**：审查器是**实时读工作树**的，改了它读到的就是半新半旧的代码、findings 对不上提交。等待期间只做 scratchpad 里的准备。**同一工作树里并行跑着另一个开发会话也算改**（R0 实测踩过）。
4. **只读要靠 `--mode ask`，不能用 `--plan`**：plan 模式下模型的终稿走 `createPlanRequestQuery` 这条独立通道，而 `-p` 非交互模式没有 plan 面板可落（响应里 `planUri` 是空串），CLI 直接丢弃；stdout 只剩工具调用之间的旁白，模型不说旁白时就是**一个换行**。表现是跑满 7–10 分钟、退出码 0、`.err.log` 0 字节、`.out.md` 1 字节，极像「进程已死」，其实是 token 全烧完才丢结果。`--mode ask` 同样由 CLI 强制只读（实测拒绝创建文件、`git diff` 照常能跑），但终稿走正常 text 通道。要确认结果去哪了，用 `--output-format stream-json` 抓流看 `interaction_query` / `tool_call` 事件。
5. **项目级 `.cursor/cli.json` 只认 `permissions` 一个键**（2026-09-15 实测）：`model` / `approvalMode` / `sandbox` / `subagentModels` / `exploreSubagentModel` 等写进去一律 `unrecognized_keys`，而且是**硬失败 exit 1、整个 CLI 起不来**（连 `cursor-agent -p "ok"` 都跑不了）。想按仓库钉模型或审批档只能改 home 的 `~/.cursor/cli-config.json`，那是全局生效。别照搬 `update-cli-config` skill 里那张设置表——那张表描述的是 home config，项目覆盖的 schema 窄得多。
6. **Zed 开着时 cursor-agent 起不来**（2026-09-15 R1 实测）：`cursor-agent` 启动要原子重写 `~/.cursor/cli-config.json`（写临时文件再 rename），本机 Zed 会一直占着这个文件，于是进程在启动瞬间退出、`.out.md` 0 字节、`.err.log` 只有一行 `Error: EPERM: operation not permitted, rename '...cli-config.json.<pid>.<uuid>.tmp' -> '...cli-config.json'`，而 `cursor-agent status` 照常显示已登录（它不写配置）。判据：PowerShell 里 `[System.IO.File]::Open('C:\Users\<user>\.cursor\cli-config.json','Open','ReadWrite','None')` 抛「正由另一进程使用」。解法：关掉 Zed（或释放占用）再发起；锁着时算「启动失败」硬失败，可回落子代理，但只要能关 Zed 就优先重试 cursor。
7. **cursor 中途掉线会卡死而不是退出**（2026-09-17 R7 第 3 轮实测）：`.err.log` 里出现 `Connection lost, reconnecting to …cursor.sh (attempt 1)` / `Retry attempt 1...`，工作进程没了而 `.out.md` 一直空（那次空了 58 分钟）。这是瞬时故障：**重发同一轮 cursor 即可**（重发后 10 分钟内正常出结果），不必回落子代理；只有重发仍复现才按「启动失败」硬失败处理。

## 2. 路径 ②：Claude Code 子代理（cursor 硬失败时）

主会话用 Agent 工具委派一个**只读**子代理（`Explore` 或 `general-purpose`，禁用 Edit / Write），提示词固定为：

```
读 .claude/cursor-review-prompt.md，把其中的 {{RANGE}} 当作 <范围>、{{NOTE}} 当作 <要点>，
严格按第 1 到 6 节执行审查；只输出第 5 节格式的结论，不修改任何文件。
```

- **模型固定 opus**（所有者裁定 2026-09-15）：Agent 工具显式传 `model: "opus"`，不让子代理继承主会话的模型（主会话是 Fable 5.1 时尤其如此）——独立审查要换一个视角。子代理类型 `general-purpose`，提示词里写死「不许修改、创建、删除文件，不许 git 写操作，不许跑构建 / 测试」。
- 范围口径与路径 ① 相同：前两轮 `main...HEAD`；第 3 轮起 `<上一轮已审提交>..HEAD`；零已提交基线用 `HEAD`。
- 质疑取舍那一档：提示词里加一句「保留第 3b 节」。
- 子代理的输出直接回填任务卡；不落 `.claude/reviews/`。
- 子代理与主会话共享上下文规则（它自动读 `CLAUDE.md`），任务书里的判据清单是它的每轮口径。

## 3. 两级共用

- findings 逐条处理后回填任务卡「代码审查」段（采纳整改 / 不采纳及理由），审查产物本体不入库，任务卡里记结论与条数。
- 审查者拿到的项目上下文：cursor-agent 在仓库根自动读 **`AGENTS.md`**，那份是指针 → `CLAUDE.md`（硬性规则 1–11）；Claude Code 子代理直接读 `CLAUDE.md`。任务书另给了判据清单与严重级口径，两级都**不依赖**编辑器侧配置。
- `vendor/upstream/` 里的上游源码对审查者是只读对照，任务书与 AGENTS.md 都已声明它不在审查范围。
