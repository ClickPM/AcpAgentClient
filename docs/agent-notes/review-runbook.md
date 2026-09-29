# 审查 runbook（审查者速记 + 发起 / 取回 / 坑）

> **口径的层级**：`AGENTS.md`「开发模式」是**长期口径**，[`.claude/cursor-review-prompt.md`](../../.claude/cursor-review-prompt.md)
> 是**每轮口径**（由 `.claude/cursor-review.ps1` 实例化后给审查者），**冲突时以任务书为准**。
> 发起命令、参数清单、七条容易踩的在 [`docs/review-workflow.md`](../review-workflow.md)（那里是操作正本，本文不复述、只补记忆里的判据）。

## 1. 执行器（所有者裁定 2026-09-11，2026-09-29 复核）

| 级 | 执行器 | 何时用 |
|---|---|---|
| ① | **cursor CLI（`cursor-agent`）+ `grok-4.7-high-fast`**，由 `.claude/cursor-review.ps1` 后台拉起 | 默认，唯一 |
| ② | **停下喊人** | ① 硬失败时 |

**② 不是「自动回落子代理」**（这一条 2026-09-29 由所有者明确收窄：*cursor 不可用时中断喊人，不随便回落其他子代理*）。
命中硬失败 → 把失败现象与证据（`.err.log` / 退出码 / `.out.md` 是否为空）写进任务卡「代码审查」段，**停下来等所有者指示**。
只有所有者点名换执行器时才换，且换的必须是**只读**子代理。

**换执行器时唯一不许动的东西是「审查者的独立性」**：

- 模型必须**独立于主会话**（不让子代理继承主会话的模型）。Claude Code 家族的默认值是 `opus`
  —— 所有者 2026-09-15 原话：「回落 Claude 子代理审核的时候，使用 opus 模型，不继承 fable 5.1」。
  理由与用哪个模型无关：主会话与审查者同一个模型会削弱门禁，换的只是「视角」。
- 提示词固定为「读 `.claude/cursor-review-prompt.md`，把 `{{RANGE}}` 当作 `<范围>`、`{{NOTE}}` 当作 `<要点>` 执行，只输出结论不改文件」，
  并写死「不许修改 / 创建 / 删除文件，不许 git 写操作，不许跑构建 / 测试」。
- 范围口径不变；子代理的输出直接回填任务卡，不落 `.claude/reviews/`；任务卡写明「执行器由所有者指定」。
- 同一轮审查只用一个执行器，不混两份 findings（免得编号打架）。

**硬失败只认这几条**：`cursor-agent` 未安装 / 未登录 / 启动失败 / 限流 / 后台进程已死而 `.out` 仍空。
**「等得久」「改动小」不是理由。**

## 2. 审查者速记（长期口径）

主会话 / 任务卡之外的**恒定判据**。审查者的职责边界与严重级在任务书 § 2–§ 4，这里是与项目规则一一对应的**阻断级速查**：

- 功能范围唯一边界 = `design/` 的全部画板（清单与计数以 `design/README.md` 为准）；设计稿没有的功能一律判超范围。
  **`design/DIVERGENCE.md` 里列到的几处以实现为准**，PNG 不再是它们的验收基准。
- **审查是缺陷门禁，不负责长出方案**：只判定并报告缺陷与严重级别；finding 若指向设计缺陷，标明「设计层面」即可，由所有者重定方案。
- **非严重阻塞性 finding 不得建议机制类修复**（新队列 / 新协议 / 新抽象 / 新配置 / 新导出面）：只建议最小改动或记 `rounds/BACKLOG.md`。
- 依赖白名单（规则 1）：出现白名单之外的 ACP 客户端、agent 状态或会话 UI 库，或引入第三方 UI 组件库 / 状态管理库，判**阻断级**；
  通用库允许清单以 `AGENTS.md` 规则 1 当前文本为准，清单之外的新增没写理由判一般级。
- 严格 ACP 投影（规则 2）：前端里出现 agent 特判、核心里出现协议之外的私有消息、`_meta` 出现 `docs/design.md` § 4 之外的键，判阻断级。
- 前端样式零改动（规则 3）：接后端只许换数据源，`lib/theme/tokens.dart`、画板 widget 文件的布局 / widget 树 / token 的 diff 都应质疑；
  widget 文件里出现样式字面量判一般级。
- 钉版本（规则 4）：`vendor/upstream/` 内的改动、`pins/upstream.json` 与 `docs/research.md` 不同步，判阻断级；**`vendor/upstream/` 本身不在审查范围**。
- gpui 不进主进程（规则 5）：`rust/` 依赖树里出现 gpui，判阻断级；复制自 Zed 的文件缺来源头注释，判一般级。
- `unsafe`（规则 6）、明文密钥入库或入日志（规则 8）、对用户数据目录的破坏性写（规则 7）、未走钉版本流程改动协议特性集（规则 10），都是阻断级。
- Windows 首发（规则 9）：子进程拉起相关改动没有 Windows 实测记录，判一般级并要求补测。
- **审查范围口径**：轮次流程前两轮全量分支 diff，第 3 轮起只审上一轮整改 diff；迭代流程（`iterations/`，2026-09-22 起）
  默认一轮 `<分支基线>..HEAD`，有整改再审整改 diff。**两者范围之外的既有问题都不报**，记 BACKLOG。
- **审查者拿到的项目上下文**：`cursor-agent` 在仓库根自动读 `AGENTS.md`（开发规范正本，硬性规则 1–11）；
  任务书另给了判据清单与严重级口径，**不依赖编辑器侧配置**。换执行器时，新执行器要读的两份是
  `AGENTS.md` + `.claude/cursor-review-prompt.md`（+ 本轮相关的那几份 `docs/agent-notes/`）。

## 3. 取回结果与判死活

- **结果在结束时一次性落地** `.claude/reviews/<时间戳>-<kind>.out.md`；中途没有任何输出是正常的。
- **`.err.log` 通常一直是 0 字节**：`--output-format text` 下 cursor-agent 不往 stderr 写心跳。**别拿「err 是空的」判它死了**，
  判死活看进程树：`Get-CimInstance Win32_Process -Filter "Name='node.exe'"` 里找命令行带 `index.js -p` 的那个。
- 轮询 `.out.md` 非空，或 `tasklist /FI "PID eq <pid>"`（脚本打印的 pid 是 `cmd` 壳，真正干活的是它的 node 子进程）；
  **Git Bash 里先 `export MSYS_NO_PATHCONV=1`**，否则 `/FI` 被当路径改写、永远报「进程已死」。
- **耗时基线**（R6 实测 2026-09-16，同机）：30 文件 / 约 +2,800 行的全量分支 diff **12 分 03 秒**；
  同一分支多 300 行的第 2 轮全量 **11 分 26 秒**。轮次流程里 13–20 分钟一轮是常态，**脚本的 PowerShell 包装会阻塞到审查结束**，不是启动失败。

## 4. 四个实测过的坑

### 4.1 `-Wait` 的产物是 UTF-16 LE

`powershell -File .claude\cursor-review.ps1 -Wait ...` 从工具的后台任务发起时，
`.claude/reviews/<时间戳>-review.out.md` 落成 **UTF-16 LE + BOM**（`fffe 6600` 开头），
`cat` / Read 工具读出来全是穿插 NUL 的乱码；**不带 `-Wait` 后台跑出来的是 UTF-8**（2026-09-15 实测）。
内容完整，只是编码不同 —— 三轮审查里两轮先以为文件坏了。

读法：`iconv -f UTF-16LE -t UTF-8 <file>`，或直接读后台任务的 output 文件（里面已是解码后的全文）。任务卡引用产物路径时照常写 `.out.md`。

### 4.2 别把脚本 stdout 接管道

**不带 `-Wait` 发起时也别把脚本 stdout 接管道（`| tail`）** —— 后台起的 cursor-agent 继承了这条管道，
`tail` 会一直等到审查结束才返回，工具 120 s 超时后转后台（R4，2026-09-16）。
直接跑或 `run_in_background: true`，结果看 `.claude/reviews/<时间戳>-review.out.md` 非空。

### 4.3 掉线 / 启动 EPERM 是瞬时故障，先同执行器重试

- **掉线**（2026-09-22 实测）：`.err.log` 里出现 `Connection lost, reconnecting to …cursor.sh (attempt 1)` /
  `RetriableError: Agent turn stopped after repeated resume attempts made no progress` / `command failed unexpectedly`，
  `.claude/reviews/` 里只有 `.prompt.md`、没有 `.out.md`，**而脚本仍 exit 0**。
  另一处实测（R7 第 3 轮 2026-09-17）：工作进程没了而 `.out.md` 一直空（那次空了 58 分钟）。
  **先原样重跑一次**（同范围同 `-Note`，注明是重试）—— 第二次也报了两次 `Connection lost`，agent 仍完成并给出 `findings: 0`。第二次仍失败才算硬失败。
  **判据是 `.out.md` 有没有写出来，别只看 exit code。**
- **启动 EPERM**（R1 实测 2026-09-15）：`~/.cursor/cli-config.json` 被 Zed 占着（`cursor-agent` 启动要原子重写它），
  进程在启动瞬间退出、`.out.md` 0 字节、`.err.log` 只有一行
  `Error: EPERM: operation not permitted, rename '...cli-config.json.<pid>.<uuid>.tmp' -> '...cli-config.json'`，
  **而 `cursor-agent status` 照常显示已登录**（它不写配置）。
  判据：`[System.IO.File]::Open('C:\Users\<user>\.cursor\cli-config.json','Open','ReadWrite','None')` 抛「正由另一进程使用」。
  解法：关掉 Zed（或释放占用）再发起；能满足就优先重试 cursor，别急着喊换执行器。
- **项目级 `.cursor/cli.json` 只认 `permissions` 一个键**（2026-09-15 实测）：
  `model` / `approvalMode` / `sandbox` / `subagentModels` / `exploreSubagentModel` 等写进去一律 `unrecognized_keys`，
  而且是**硬失败 exit 1、整个 CLI 起不来**（连 `cursor-agent -p "ok"` 都跑不了）。
  想按仓库钉模型或审批档只能改 home 的 `~/.cursor/cli-config.json`（全局生效）。别照搬 `update-cli-config` skill 里那张设置表。

### 4.4 只读靠 `--mode ask`，不能用 `--plan`

plan 模式下模型的终稿走 `createPlanRequestQuery` 这条独立通道，而 `-p` 非交互模式没有 plan 面板可落（响应里 `planUri` 是空串），
CLI 直接丢弃；stdout 只剩工具调用之间的旁白，模型不说旁白时就是**一个换行**。
表现是跑满 7–10 分钟、退出码 0、`.err.log` 0 字节、`.out.md` 1 字节，**极像「进程已死」，其实是 token 全烧完才丢结果**
（R0 实测 2026-09-15，曾据此两次误判为硬失败）。
`--mode ask` 同样由 CLI 强制只读（实测拒绝创建文件、`git diff` 照常能跑），但终稿走正常 text 通道。
要确认结果去哪了，用 `--output-format stream-json` 抓流看 `interaction_query` / `tool_call` 事件。

## 5. 审查期间：不改仓库里的文件、不跑构建

- **审查者按自己的节奏实时读工作树**，中途改动会让它报出你已经修掉的东西，收 findings 时得逐条拿当前代码核对才分得清「真缺陷」与「你看到的是旧版」。
  要自查就等审查结束再动。**同一工作树里并行跑着另一个开发会话也算改。**
- 所有者 2026-09-22 的指示（1.4.1 复审轮）：「**review 期间不要跑构建**」。整改完成后才跑 `validate.ps1`
  ——它是 `AGENTS.md` 要求的审查前门禁；runner 的 C++ 改动因此可能留到 release 构建时才编译。
- 每轮审查的 `-Note` 要点里可以点名「这几个文件是另一个会话未提交的改动，不属本轮范围、不要报」。
- 不采纳的 finding 尽量补一条用例把行为锁住，再在下一轮 `-Note` 里点名
  「已核实前提不成立，勿重复报除非给出反例」。反驳要拿证据（把整改 `git stash` 掉再跑那条用例看它是否真的失败；
  并发顺序之争写个十行的 `dart run` 脚本实测），不为此重构测试或代码。
- 主会话第 1 遍判「不整改」的 P3 可能被 cursor 用反例翻案（2026-09-23：关窗 8 秒超时盖不住收尾最坏的 12 秒）
  —— **写「不整改」理由时把数字算清**，别只写「窗口窄」。
