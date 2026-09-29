# Git、worktree 与并行会话

> 相关：`AGENTS.md`「开发模式」（审查范围 / 合并 / 分支口径）、[`owner-rulings.md`](owner-rulings.md)（合并时机归所有者）、
> [`build-and-cache.md`](build-and-cache.md)（独立 target 目录的清理）。

**前提事实**：这个仓库的工作副本 `D:\variFlight_work\AcpAgentClient` **会被多个会话同时改**（所有者习惯并行开会话，
一度同时开着 8+ 个 worktree）。2026-09-17 实测：会话开始时 `git status` 全干净，十几分钟后凭空多出 5 个文件的修改，
期间对方还落了一个 commit。**下面全部规则都从这一条推出来。**

## 1. 提交：只 add 自己的路径，commit 后必须核对

- 提交前**重新**跑 `git status`，不要信会话开始时那份快照；只 `git add` 自己碰过的路径，
  **永远不用 `git commit -a` / `git add -A`**（它会把对方的在途改动一起扫进提交）。
- **`git commit --amend --only <paths>` 是补救时的陷阱**：`--only` / `-- <paths>` 提交的是**工作区**内容而不是 index，
  对方的整份 WIP 会被卷进来（2026-09-17 第二次踩）。补救走
  `git reset --soft HEAD~1` → `git restore --staged <file>` 重建 index → 重打自己的 hunk → **不带路径**的 `git commit`；全程别碰工作区（不 `--hard`、不 checkout 文件）。
- **自己和对方改了同一个文件时**：`git show HEAD:<path>` 取出 HEAD 版、在副本上打自己的改动、
  `git hash-object -w --no-filters` + `git update-index --cacheinfo` 精确暂存那一份。
  同一个文件里两边的改动交织时，按 hunk 挑：`git diff -U3 -- <file>` 的输出按 `@@` 切块、只留含自己关键字的块，
  拼回补丁后 `git apply --cached`（context 匹配，行号偏了也能落）。
- **⚠️ 这招防不住对方在你 commit 之前先 commit**：对方的 `git add` 会覆盖你在 index 里的那条，你的 commit 就静默少一个文件
  （当时的表现是 stat 说 8 files 而不是 9）。所以 **commit 之后必须 `git show --stat HEAD` 逐个核对文件数**，少了就补一个 commit。
  那次少的正是 `sidebar.dart`，而同一个 commit 已经删了它引用的符号，**main 一度编译不过**。
- **更狠的一层：自己在共享副本上永远不要跨命令处于 staged 状态。** 对方 30 秒内就能提交掉你的文件
  （2026-09-18 那次我 `git add` 之后隔一条命令才 commit，文件进了对方的 commit；我随后用临时索引打出来的是**空提交**）。
  所以：① 对方活动期间**默认**走临时索引，不要等到「对方已暂存」才用；② 用共享 index 时，核对与提交必须在**同一条命令**里并用结果做门：

  ```bash
  [ "$(git diff --cached --name-only | sort | paste -sd ' ' -)" = "<期望的路径列表>" ] && git commit -F "$SP/msg.txt"
  ```

  （命令里别写反斜杠 —— Bash 工具会把它吞掉。）不相等就停下重看。③ 发现卷进了对方的文件，先 `git log -1` 看 HEAD 是否还是自己的 commit，
  对方已经在上面提交就只能**如实上报，不要改写历史**。④ commit 后除了核对文件数，还要核对 **diff 非空**（`git diff --stat HEAD~1 HEAD`）；
  空提交说明你的文件被别人卷走了。删空提交 / 改写都属「Git Destructive」，只能如实上报让所有者手动 `git reset --soft HEAD~1`。
- **临时索引的用法**（全程不碰共享 index）：

  ```bash
  export GIT_INDEX_FILE=<scratchpad>/commit-index
  git read-tree HEAD
  git add -- <自己的路径>              # 交织文件用 git show HEAD:<path> 重建「HEAD + 自己的 hunk」再 hash-object -w + update-index --cacheinfo
  git commit
  ```

  **但提交完共享 index 会变成「暂存了一次回退」**：它里面还是老 blob、HEAD 却前进了，`git status` 对我改的文件显示 `MM`，
  对方一旦按 index 提交就把我的改动 revert 掉。所以 commit 之后要把共享 index 同步回来：自己独占的文件直接 `git add`，
  交织文件取 `git show :<path>` 的暂存版、打上自己的 hunk 再 `update-index --cacheinfo`，保住对方的暂存意图。

## 2. 分支：对方在活动时不要在共享副本上开分支

- `git switch -c` 会把 HEAD 换成你的分支，**对方接下来的 commit 就落到你的分支上**（2026-09-18 遇上：对方 2 分钟前刚提交、文件 6 分钟前还在改）。
  判据是 `ls -l --time-style=full-iso <对方改的文件>` 与 `git log -1 --date=iso` 的时间。
- 正确做法是**另开 worktree**：`git worktree add -b <branch> ../AcpAgentClient-<用途> main`，改完在那边提交，主副本的 HEAD 一动不动。
  新 worktree 跑 `flutter test` 前先 `flutter pub get`（包都在缓存里，十几秒）；`.dart_tool` 各自独立，反而不会和对方的 flutter 撞。
- **分支也会被对方换掉**：会话开始时 `git status` 快照写着 `main`，提交时 HEAD 已经是对方 `git switch -c` 出来的轮次分支了
  （2026-09-18 实测：commit 打在 `round-06-session-activity` 上）。**`git commit` 前先 `git branch --show-current`。**
  已经提错、且 main 没被任何 worktree 检出时，把 main 指到那个 sha（`git branch -f main <sha>`）即可 ——
  不动工作区、不打扰对方；对方的轮次分支基线往前挪一格，等价于「从带这条 commit 的 main 上开的分支」，他们的 `main...HEAD` 审查范围反而干净。
- **用临时索引提交到自己的分支之后，想把 HEAD 切过去会被挡两次**（2026-09-20 R8 实测）：
  共享 index 还停在旧 tree，于是 `git checkout <自己的分支>` 先报「未跟踪文件会被覆盖」，删掉它们再切又报「本地改动会被覆盖」。
  删之前先证明内容一致：`git show <分支>:<path> | tr -d '\r' | sha1sum` 比 `tr -d '\r' < <path> | sha1sum`（行尾会被 autocrlf 转换，必须两边归一化）。
  正确顺序是**让共享 index 对齐目标树再切**：`git checkout <分支> -- <自己新建的路径>` + `git add -- <自己改过的路径>` → `git checkout <分支>`。
  切完对方的未提交改动原样还在工作树里（它们在两个分支上内容相同，checkout 不碰）。
- **发审查前 HEAD 必须在自己的分支上**：`.claude/cursor-review.ps1` 的范围是写死的 `<Base>...HEAD`。
  切过去之后审查器读到的工作树里仍有对方的在途改动，用 `-Note` 明确点名
  「这几个文件是另一个会话未提交的改动，不属本轮范围、不要报」，审查器会照办（R8 三轮都没误报）。

## 3. `scripts/validate.ps1` 会把对方的在途改动算到你头上

它分析 / 测的是**工作区**，不是你的 commit。2026-09-20 发 v1.0.0 时只改了 4 个 Cargo 文件，
`flutter analyze` 却报 `lib/app/workbench_screen.dart` 的 `RenderAbstractViewport` 未定义 —— 是对方正在写的会话大纲功能少了
`package:flutter/rendering.dart` 的 import。**判据：报错文件不在你 `git diff --cached --name-only` 里。**

做法是在**干净的 worktree**（`D:\variFlight_work\AcpAgentClient-release`）上 `git merge --ff-only <自己的 sha>` 再跑一次 validate；
Rust 侧的 `cargo build/test/clippy` 不受影响（它们读的是 `rust/`，对方一般不碰）。

## 4. worktree 的 `vendor/upstream` 用目录联接

新开的 git worktree 里 `vendor/upstream/` 不存在（gitignored）；`scripts/fetch-upstream.ps1 -Check` 会先建一个空目录再报 8 个 pin 全缺。

```powershell
Remove-Item <worktree>\vendor\upstream          # 先删掉 -Check 建出来的空目录
cmd /c mklink /J "<worktree>\vendor\upstream" "D:/variFlight_work/AcpAgentClient/vendor/upstream"
```

之后 `-Check` 全绿。**为什么**：8 个上游仓库几百 MB，每个 worktree 各拉一份既慢又占盘；钉版本内容只读（规则 4），共用无副作用。
`sidecar/`（R7）path 依赖 `vendor/upstream/zed` 同样走联接。

**拆 worktree 时必须先拆联接本身，再删 worktree 目录** —— 直接对 worktree 递归删有把主副本 `vendor/upstream` 一并带走的风险：

```powershell
# 逐个删（第二个参数 $false = 不递归，只删链接）
[System.IO.Directory]::Delete($link, $false)
# 判据
(Get-Item $link -Force).Attributes -band [IO.FileAttributes]::ReparsePoint
```

- **联接不止 `vendor\upstream` 一处**（2026-09-23 实测）：有的 worktree 是在 `vendor\upstream\` 下**逐个**建 9 个联接
  （顶层是真目录，**只看顶层属性会漏**）；每个跑过 flutter 的 worktree 还有
  `windows\flutter\ephemeral\.plugin_symlinks\` 下 5 个指向 **Pub Cache** 的符号链接
  （audioplayers / file_selector / jni / path_provider / url_launcher）。
  所以拆前用 `cmd /c "dir <wt> /al /s /b 2>nul"` 列出全部重解析点（不跟进链接），**按路径长度倒序**逐个删，再列一遍确认为 0 才递归删。
  `dir /al` 没命中时往 stderr 写 "File Not Found"，在 `$ErrorActionPreference = "Stop"` 下会腰斩脚本 —— **`2>nul` 要写在 cmd 的命令串里面**。
  脚本里再加一道保险：先认一个守卫文件（主副本 `vendor\upstream\zed\Cargo.toml`），每删一个 worktree 查一次它还在。
- 拆完顺手数一遍主副本 `vendor\upstream` 还是 9 个条目。
- **`git worktree remove --force` 在 `.claude\worktrees\` 下会「半成功」**（2026-09-22，一次拆 8 个）：
  `D:\variFlight_work\AcpAgentClient-*` 那几个干净利落；`.claude\worktrees\` 里的 6 个一律报 `Permission denied`，
  但**内容已经删光、注册记录也已经摘掉**（`git worktree list` 只剩该剩的），只留一个空壳目录删不掉 ——
  按着它的是那几轮会话残留的 CLI 进程（把 worktree 当 cwd）。**别把 `Permission denied` 当失败去重试**，
  报一句「空壳目录等会话进程退出 / 重启应用后再删」即可。
- **所有者要当场删空壳时**（2026-09-24 实测）：按着的是那个会话的 CLI 进程（父进程是桌面端主进程）**加上它终端面板的 `pwsh.exe`**
  （父进程是桌面端的 NodeService），两个都得结束。命令行里看不出 cwd，要读 PEB
  （scratchpad 里写过一个 `find-cwd-holders.ps1`：C# `Add-Type` → `NtQueryInformationProcess` → PEB+0x20 → ProcessParameters+0x38 的 `CurrentDirectory`；`-Kill` 才结束进程）。
  结束前先沿 `$PID` 的父链找到自己，排除掉；**先问所有者**（会话进程被结束后，侧栏里的会话还在）。
- **新 worktree 建议建在同级目录** `git worktree add ../AcpAgentClient-<slug>`（比 `.claude\worktrees\` 好拆）。

## 5. 合并：所有方向的合并时机都归所有者

**没有明确指示就先把「冲突面 + 解法」写进任务卡并问**，不自行合并 —— 哪怕任务卡的前置段写着可以先合。详见 [`owner-rulings.md`](owner-rulings.md)。

### 先探冲突面、别先合

`git merge-tree --write-tree <HEAD> <main>` 能在**完全不碰工作树**的前提下判有没有冲突（git 2.51 本机可用；退出 0 = 干净，非 0 时会列出冲突文件）。
收口汇报里给「merge-tree 的结论 + 双边都改过的文件逐个对照 hunk」，而不是已经合好的分支。
两个配套教训：

- **机械无冲突 ≠ 语义无冲突**，`Cargo.lock` 尤其（一边加依赖边、一边改版本号，在同一个 `[[package]]` 块里），合完必跑 `cargo build --locked`。
- `ROUNDS.md` § 7 进度表的**最后一行**常常正是对方那一轮，在其后追加新行会人为造一个冲突 —— 有意不在分支上加，留到合并时按 main 的最终表补。

### 两轮并行时后合并的一方

R4 与 R5 在两个 worktree 并行（2026-09-16），R5 先合入 main。R4 收口时的做法：
审查循环先在自己分支收口（high 0）→ `git merge --no-commit --no-ff main` 手工解冲突（18 个文件；生成物 `lib/bridge/*`、
`frb_generated.rs`、`Cargo.lock` **直接取 main 再** `flutter_rust_bridge_codegen generate` + `cargo build` 重出；fixtures 编号撞车让位先合入的一方）
→ validate 全量 + `build.ps1 -Smoke` + 真跑复核 → 合并（在干净 worktree 里验证过的 sha 合入 main）。

### 合完 main 之后要不要复审

**解冲突只动了文档 / 登记类文件、代码全是自动合并且改动区段不重叠时，不再发复审**，validate 全绿就直接合入，任务卡写「无代码改动不复审」
（所有者 2026-09-23 原话：「没有代码改动就不要复审啊」）。一轮全量要二十分钟，合并只动了文档时它什么也把不住。

- **只改注释的 `.dart` / `.rs` 也算「没有代码改动」**（iteration-05，2026-09-23）：main 带来三处 `.dart` 改动、全是把注释里的路径改指另一个文件，
  所有者明说「不是代码更新，不用再走 review」。先 `git diff <基线> main -- lib test rust` 逐 hunk 看一眼确认只动注释，再照上面的做法合入。
- 只有**解冲突时手改了代码**（或自动合并落在同一函数 / 同一段逻辑里）才发复审，范围也只审合并提交自己的改动。

### 把分支合进 `main` 时，挡路的往往是主副本里别人那份「其实已经提交过」的未提交改动

2026-09-20 合 Thread→Session 那次，主副本的 `ROUNDS.md` / `rounds/BACKLOG.md` 带着 R7.5 会话的在途改动，
而我的分支也改这两个文件，`git merge --ff-only` 必然被 `local changes would be overwritten` 挡住
（`main` 被主副本检出，`git push . HEAD:main` / `fetch . HEAD:main` 同样不行）。

**别直接 `git checkout --` 丢**，先证明它有备份：比 `git hash-object <主副本里的文件>` 与 `git rev-parse <对方分支>:<path>` 的 blob sha，
一致就说明内容已提交在对方分支上（那次是 `1e85ef1`），丢掉的只是主副本里的重复副本，对方合 main 时会照常带回来。
确认后 `git checkout -- <paths>` → `git -C <主副本> merge --ff-only <自己的分支>`。
全程用 `git -C <主副本>` **不要 cd**；未跟踪的目录（对方的 `rounds/round-7.5/` 之类）ff 不碰，不用管。
ff 合并后主副本的树与自己刚验证过的分支树逐字节相同，不必在主副本重跑 validate。

**另一种情况**：整改提交要落回带别人 WIP 的主副本时，`git merge --ff-only` 会因重叠文件被 git 拒绝；
「`update-ref` + 给工作树打 hunk + `reset` 同步 index」那套会被自动模式拦成 Modify Shared Resources。
可行的是让所有者在主副本自己跑三条：`git stash push -- <重叠文件>` → `git merge --ff-only release-build` → `git stash pop`
（hunk 不重叠时 pop 自动合并、stash 自动丢弃）；我负责事先核对 hunk 不重叠并把命令给他。

### `BACKLOG.md` 的档位计数：git 自动合出来的那个数多半是错的

（iteration-02 三会话并行，2026-09-22）两边各关掉 2 条 P1 时，双方都会把 `26` 改成 `24` —— 改动**逐字相同**，
git 于是**自动合成 `24` 且不报冲突**，而真实条数是 22；总计那一行同理。冲突标记只出现在双方数字不同的档（P0 那种）。

所以合完 `BACKLOG.md` 不要信自动合并的结果：按 `- [ ] ` 逐小节数一遍真实条数，再回写档位头、总表行与总计
（`## <档>` 与 `### <小节>` 两级都要核；注意扫脚本遇到下一个 `## ` 要把 `sec` 清空，否则末档的条目会被算进上一个小节）。
登记类冲突（`BACKLOG-CLOSED.md` 末尾、`iterations/iteration-NN.md` 的表）按所有者的「两边都留」解，
自己那项的序号要跟着 main 已有的行往后排（那次 3 → 6）。

`git merge -F-` 会报 `could not read file '-'`，**提交说明写临时文件再用 `-F <文件>`**。

## 6. 迭代与 DIVERGENCE 编号会被并行会话抢

（2026-09-23 实测，当时同时开着 8+ 个 worktree 会话）我开工时 `main` 最新是 iteration-04，起名 iteration-05；
做到一半 `main` 已合进另一条 iteration-05，某分支占了 06，另一个 worktree 的**未提交**文件里还有第三份 iteration-05；
`design/DIVERGENCE.md` 第 32 条同样被 main 和另一个未提交副本同时占用。改成 07 / 33 之后，合 main 时 07、08 又被别的迭代先合进去了，
只好再改成 **iteration-09 / DIVERGENCE 34**。

**结论：开工时定的号只是占位，合 `main` 那一刻才定终号。** 改号时只替换本分支自己那几行（main 上同号的行不能动，按「这一行在不在 main 的版本里」判）。

起名前查**三处**：

1. `git log main`（会话中途会前进，别信开工时的 `gitStatus` 快照）；
2. `for b in $(git branch --format='%(refname:short)'); do git ls-tree -r --name-only $b iterations/; done`；
3. 各 worktree 工作目录里的未提交 `iterations/iteration-*.md` 与 `design/DIVERGENCE.md` 最大编号（`git worktree list --porcelain`）。

取所有来源之上的下一个号；撞了就在迭代文件开头写一句改名原因，`BACKLOG` / `BACKLOG-CLOSED` / 代码注释里的 `iteration-NN` 一起替换。
合 main 仍要先问所有者；`BACKLOG` 档位计数冲突按上一节重算。
