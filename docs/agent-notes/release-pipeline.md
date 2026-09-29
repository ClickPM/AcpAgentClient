# 发版流水线

> 相关：`AGENTS.md` 规则 11（版本号两处、sidecar 不跟）、[`review-runbook.md`](review-runbook.md)（发版前那轮审查怎么跑）、
> [`build-and-cache.md`](build-and-cache.md)（发完版清缓存）、[`git-and-parallel-sessions.md`](git-and-parallel-sessions.md)（worktree 与合并）。

## 1. 所有者「review 完就发版」的整条流水线

2026-09-23（v1.4.3）所有者一次性交代的口径：对上个版本以来 main 上的全部提交做一次**主会话 review**、修掉问题，
再走 cursor 审查「直至 findings 为 0」，**涉及文档改动的部分不审不改**；完成后依次：

1. main 推 `github` 与 `origin`；
2. 正式发 release（构建并上传 zip 与 exe）；
3. 更新本地安装版；
4. 清掉新版本之前的构建缓存、只留最新；
5. 清掉已合并的本地分支与 worktree。

**这是连续动作，中间不要逐步确认。**「findings 为 0」是**字面要求** —— 第 1 轮只有一条「不采纳的 P2」时也要再发一轮，
带上核实结论（`-Note`）让 cursor 真出 0 条。

- 「**主会话 review**」= 自己逐文件读 diff，**不委派子代理**；范围用
  `git diff <上个 tag>..main -- . ':(exclude)*.md' ':(exclude)design/**'`。
  （2026-09-22 的 1.4.1 复审轮是例外：所有者当时的指示是委派 4 个只读子代理并行审、每批一个，那是他指定的，不是默认做法。
  1.4.1 的工作分支是 `claude/review-1.4.1`、任务卡 `rounds/round-1.4.1/round-1.4.1.md`，
  cursor 第 1 遍 `-Scope since -Base v1.4.0`。）
- **审查意见只做最小处理，不借它加机制**（所有者 2026-09-23 v1.4.4 原话：「不要用审计来过度设计」）：
  采纳 = 改判断 / 改常量 / 补用例；反驳 = 拿证据写进 `-Note` 与任务卡，不为此重构测试或代码。
- 所有者口误过版本号（说成「1.4.1」，实际是下一个版本），**「X 之前」按「新版本之前的全部」理解**（他选的推荐项）。
- 发版登记（README「当前版本」行、`ROUNDS.md` § 7 一行、`rounds/round-<ver>/` 任务卡）**不算「文档改动的审查」**，照历次惯例更新。
- 合并 main 由这句指示授权；**没有这类明确指示时仍要先问**（见 [`owner-rulings.md`](owner-rulings.md)）。
- cursor 轮数不止两轮是常态（v1.4.4 四轮：全量 → 全量 → 整改 diff → 同范围带核实结论）；第 3 轮起 `-Scope since -Base <上一轮已审提交>`。
  每轮 13–20 分钟，等 `.out.md` 非空或 cursor-agent 进程消失，**期间不改仓库任何文件**。

## 2. 日常用的那份安装版（`（本机）`）

所有者的日常 release 整份复制在 **`D:\tools\AcpAgentClient\`**，桌面快捷方式「AcpAgent Client.lnk」指这里
（不再指仓库 `build\...\Release`，一清构建缓存就没了）。应用数据在 `%APPDATA%\AcpAgentClient`，**与程序位置无关**。

**要从仓库外出包**：主副本常有别的会话的未提交改动，`flutter build` 编的是工作区、WIP 会混进 release。
常驻 worktree 是 **`D:\variFlight_work\AcpAgentClient-release`**（分支 `release-build`，纯 ASCII 路径不用 `ascii-root` 联接；
`vendor\upstream` 是指向主副本的目录联接）。

## 3. 出包六步

1. **切到发版提交**：`git -C <wt> checkout -q -B release-build <main 的 sha>`。
   **别用 detached HEAD**：`cargo test` 的 `fs::git::tests::branches_of_this_repo` 断言当前分支在分支列表里，detached 下必挂（与代码无关）。
   纯 Dart 改动那条最短路径那条实测过：`checkout -B release-build <sha>` 后 validate 全量 4 分 22 秒。
2. **sidecar**：`scripts/build-sidecar.ps1 -Selftest` **在主副本跑**（`sidecar/` 没 WIP 时安全；换到 worktree 路径会冷编译约 27.5 分钟，
   主副本增量约 14 分钟、源码没变时几秒）。产物 `build\sidecar\zed-agent-acp.exe` 复制到 `<wt>\build\sidecar\`，
   `windows/CMakeLists.txt` 的 install 规则从那里取。先 `sha256sum` 对一下安装目录里那份：**一样就说明上次已含当前 sidecar 源码** ——
   mirror 时 `/XF zed-agent-acp.exe` 跳过它，既省 185 MB 又躲开可能残留的孤儿进程。
   **别用 `build-sidecar.ps1 -Check` 来「确认新鲜」**：它是对整个 zed 依赖树跑 `cargo check`（check 产物与 release build 不共用，等于从头 check 一遍），
   会白跑十几分钟；要确认 sidecar 没变，比 exe 哈希即可。
   **版本号一动它必然重编重链**（185 MB 的 exe，链接那段占大头）：主副本约 14–17 分钟，release worktree 里 32.9 分钟。
3. **别假设 main 是绿的**：release worktree 里跑**完整** `powershell -File scripts\validate.ps1`
   （首次要 `flutter pub get --offline`；cargo 对新路径要重编 workspace crate、依赖走缓存）。
   2026-09-18 出包时才发现 main 自己过不了门禁，两处都是前一天提交带进来的：规则 3 的样式字面量扫描扫到新 widget 文件里的 `Offset(`；
   两条弹层用例只 `pump()` 一帧、量到了新加的入场动画 t=0 那一帧。**不能只跑 `test/app/` 或只信上一次的绿。**
   同一天下午又撞一次：规则 3 的扫描命中 `EdgeInsets.only(top: cond ? t.Spacing.s8 : 0)` 那个 **ternary 里的裸 0** ——
   写条件内边距要用 `cond ? const EdgeInsets.only(...) : EdgeInsets.zero`（仓库既有写法见 `lib/ui/transcript/assistant_text.dart`）。
4. **构建**：`scripts\build.ps1 -Smoke`（增量实测 12.7–198 秒不等）。要省时间可以两次：
   先不带 `-Smoke` 预热（与 sidecar 并行）、拿到新 sidecar 后 `Copy-Item` 进 `<wt>\build\sidecar\` 再跑一次带 `-Smoke` 的（install 规则会把新 exe 抓进 Release）。
5. **看占用、再镜像**：`tasklist` 看 `acp_agent_client.exe` / `zed-agent-acp.exe`；**所有者常开着应用，开着时不 kill、不 mirror，留给他**。
   判占用要看进程的 `ExecutablePath`（`Get-CimInstance Win32_Process`）——
   按名字 `Get-Process` 会把别的会话在自己的 worktree 里跑的同名 exe 误判成「所有者还开着」，只有路径落在 `D:\tools\AcpAgentClient` 的才挡覆盖。
   没在跑就
   `robocopy <wt>\build\windows\x64\runner\Release D:\tools\AcpAgentClient /MIR`
   （**退出码 0–7 都是成功**，PowerShell 工具会报成 error；在 PowerShell 里末尾 `exit 0`）。
   主程序关了之后 **`zed-agent-acp.exe` 子进程可能活下来**锁住那份 exe（7afad04 修了孤儿进程，但老版本起的还会有）；字节没变就 `/XF zed-agent-acp.exe`。
   **核一致性用 `Compare-Object` 比两边递归文件清单**（43 = 43 完全一致），比盯 robocopy 的 Extras 计数省事。
6. **验收**：`Get-FileHash` 两边核**五处** —— exe / `acp_bridge.dll` / sidecar / `data\app.so` / `FontManifest.json`；
   再对**安装目录里那份**跑一次 smoke（`Start-Process -Wait -PassThru` + `ACP_SMOKE_REPORT`），要求 `ok: true`、`coreVersion <版本>`、`droppedEvents 0`。
   **smoke 要用临时 `APPDATA`**：v1.4.3 起 `core_init` 会在后台清扫 `agents/<id>/` 下不在用的旧版本目录（画板 53），
   拿真实数据目录跑 smoke 等于替所有者跑了一次清扫。
   exe 元数据核 `1.4.x+1`；`zed-agent-acp --version` 核 zed 钉版本（规则 11）。
   mirror 会删掉安装目录里旧的 `native_assets.json`（45 字节空清单，worktree 的 build 没产出它），smoke 照过、无影响；
   也会删掉旧的 `fonts\OFL-*.txt`（runner 的 install 规则只 glob `*.ttf` / `*.otf`，许可证文本本来就不随包）。

## 4. 发 release

```powershell
# annotated tag（别用 heredoc 传中文正文）
git tag -a v<x> <sha> -F <文件>
git push github main v<x>          # github = ClickPM/AcpAgentClient
git push origin main v<x>          # origin = Cursor 托管
# 正文模板直接从上一版取来改（「怎么构建」「许可证」「已知限制」三节可原样复用）
gh release create v<x> --title "AcpAgent Client <x>" --notes-file <文件> --verify-tag --latest
```

- 三件产物约 232 MB，**`gh release create` 上传会超过 600 s 被转后台**：release 在上传期间是 draft、`assets=0`，
  **别误判成失败**，等任务通知或轮询 `gh release view --json isDraft,assets`；下次直接 `run_in_background: true` 起（后台跑约 20 分钟）。
- `gh release view --json` **没有 `isLatest` 字段**，要核用 `gh api repos/ClickPM/AcpAgentClient/releases/latest -q .tag_name`。
- 事后核远端 digest：`gh release view --json assets`。

## 5. 版本号与文档登记

- **三处版本号**（规则 11）：`pubspec.yaml` 的 `version`、`rust/Cargo.toml` 的 `[workspace.package].version`，
  加上 `Cargo.lock` 里 7 个本地 crate 的版本。`sidecar/zed-agent-acp/Cargo.toml` **不跟应用版本**（跟 zed 钉版本）。
- **`README.md` 的「当前版本」段是累加的**：新段插在上一版那段**之前**，别替换。
  **`README.en.md` 自 v1.4.6 起也是累加的**，还要改它的「Current release」行。
- 版本号提交**可以在 release worktree 上做**（validate 全绿后 ff 进 main），也可以在分支上先改。

## 6. 两个反复踩的判据

- **工作区时间戳不能用来判「构建上了没有」**：只有 Dart 改动时 `acp_agent_client.exe` 与 `acp_bridge.dll` 不动，
  看 `data\app.so` 与 `data\flutter_assets\`；新加的随包资源去 `FontManifest.json` 里核。
- **上一个会话的后台 `package.ps1` 会在会话退出时被一并杀掉**（停在 "Building Windows application..."、`dist\` 没产出）。
  新会话先查 `dist\` 与 `Release\` 的时间戳再决定要不要重跑。
- 出包+验收、镜像+smoke、cargo debug 剪枝、拆已合并 worktree 与分支这四类脚本已入库在 **`rounds/round-1.4.4/*.ps1`**
  （纯 ASCII，`powershell -File` 直接跑）；其中 `release-package.ps1` 里写死了 `1.4.4`（dist 通配），
  **每次出包要先把它 `sed` 成新版本号**，其余三个与版本无关直接跑。

## 7. 快捷方式图标的坑

（2026-09-17）「AcpAgent Client.lnk」改指 `D:\tools` 时只改了 Target，**IconLocation 还是仓库 `build\...\Release\acp_agent_client.exe,0`**（清构建缓存就变空白图标）。
改 `.lnk` 的 IconLocation 并 `Save()`、`SHChangeNotify(SHCNE_ASSOCCHANGED)`、`ie4uinit.exe -show` 三步刷新；
还不行再删 `%LOCALAPPDATA%\Microsoft\Windows\Explorer\iconcache_*.db` + 重启 explorer。
抽 exe 里实际嵌的图标用 `[System.Drawing.Icon]::ExtractAssociatedIcon(<exe>)` 存 PNG。

## 8. 历次发布记录（可核的基线）

| 版本 | 提交 | 日期 | 备注 |
|---|---|---|---|
| v1.0.0 | `8eacfe7` | 2026-09-20 | LICENSE / NOTICE + 三处版本号 0.0.1 → 1.0.0；sidecar 在 release worktree 里编了 32.9 分钟 |
| v1.1.0 | `f62520f` | 2026-09-20 | sidecar 改在主副本编，17.0 分钟；`build.ps1` 跑两次（预热 + `-Smoke`） |
| v1.2.0 | `7c9c592` | 2026-09-20 | 画板 07 深色模式 + Thread → Session 收敛 + 字体扫描修复 |
| v1.3.0 | `4ddaf2e` | 2026-09-20 | R7.5 组合根拆分合入；validate 15 项 340 例 |
| v1.4.0 | — | 2026-09-21/22 | 1.4.1 复审轮的基线（`-Base v1.4.0`） |
| v1.4.1 | `f1fb10c` | 2026-09-22 | 六批 main 改动整体复审（22 条 findings）；纯 Dart 改动那条最短路径实测 |
| v1.4.2 | `901f36d` | 2026-09-23 | iteration-02 七项；16 门 + flutter test 422 项 |
| v1.4.3 | `dea12b8` | 2026-09-23 | 主会话复审 + cursor 两轮全量 0 条；smoke 起改用临时 `APPDATA` |
| v1.4.4 | `12dfbef` | 2026-09-23 | cursor 四轮（2 high → 1 high → 1 P2 不采纳 → 0）；`rounds/round-1.4.4/*.ps1` 四脚本入库 |
| v1.4.5 | `f006300` | 2026-09-24 | iteration-10 ～ 13 + round dsh-1.3.2 |
| v1.4.6 | `e08bffd` | 2026-09-24 | iteration-14 / 15 + README.en；validate 154 s（17 门）、flutter test 575 项 |
| v1.4.7 | `1421394` | 2026-09-29 | 发版记录与打扫脚本 |
