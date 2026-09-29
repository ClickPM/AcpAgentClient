# round-1.4.8 — v1.4.7 之后的两项内容发版（2026-09-29）

发版轮（不走轮次流程，无审查轮）：把 v1.4.7 之后合入 `main` 的 iteration-19、20 出包、镜像到日用安装目录、推 github 与 origin 并建 GitHub release。

**审查门禁**：iteration-19 合并前经 cursor（`grok-4.7-high-fast`）三轮审到 **0 条**（R1 high 0 / P2 1，R2 high 0 / P2 2，R3 0 条，整改全部落地）；iteration-20 只动文档与代码注释、**无 Dart / Rust 逻辑变更**，经所有者裁定免审（原话「本轮以该文档和代码中的注释为核心，没有 dart 和 rust 代码变更的话无需进行 cursor review」）。本轮按发版口径只做**主会话 review**：`git diff v1.4.7..main -- . ':(exclude)*.md' ':(exclude)design/**'` 逐处核过 —— 非文档改动里 **32 个文件是 `CLAUDE.md` → `AGENTS.md` 的纯注释改名**（diff 里只有注释行，零逻辑），Dart 的真改动只有 iteration-19 那 5 个文件（`session_attach` / `session_controller` / `turn_controller` / `sidebar` / `workbench_screen`）+ 1 个新测试文件与 1 个改动的测试，其余是 round-1.4.7 入库的打扫脚本与注释性改动，**无新问题** → 不开新审查轮。

## 内容

| 项 | 要点 | 提交 |
|---|---|---|
| iteration-19 | 侧栏 Active 行的「挂起」：`session/close` 把会话交还 agent（先 cancel 再释放），转录留只读、行从 Active 沉到 History，点 History 那一行走 `loadSession`（退 `resume`）挂回来。按钮只给 Active 行且**会话自己的** agent 声明了 `close` 且挂得回来（`canSuspendSession`，按会话能力判不按 agent 名判）；`closeSession({String? id})` 的 agent 按 `ownerOf(target)` 取，后台会话也能挂。顺带修掉被挂起后发消息时指向不存在入口的那句 Resume 提示（按「agent 侧已无这条 / 能力上挂不回」分开说）。补 6 条用例（`test/ui/sidebar_suspend_test.dart`）+ 3 条关闭态提示用例，回补画板 45 § ② 与画板 04 注记并重渲 PNG | `265ca4e` → … → `0c23286`，合并 `491a63d` |
| iteration-20 | 规范正本 `CLAUDE.md` → 跨 agent 的 `AGENTS.md`（`CLAUDE.md` 退 3 行指针）；审查执行器收窄为「cursor 硬失败就停下喊人、不自动回落子代理」；上一代 agent 的项目私有记忆整批内联成 `docs/agent-notes/`（索引 + 8 册 + 1 份执行器坑）；活引用 53 文件 / 83 处改写，历史记录原样保留 + 别名映射 | `f752859` |

## 版本号与提交

- `f4e5e57`「版本号 1.4.8：pubspec.yaml 与 rust/Cargo.toml 两处 + Cargo.lock 里 7 个本地 crate」：`pubspec.yaml` `1.4.8+1`、`rust/Cargo.toml` `[workspace.package] version = "1.4.8"`、`rust/Cargo.lock` 里 7 个本地 crate（`cargo metadata --offline` 重写，diff 恰 7 增 7 删）。同一提交里 README.md / README.en.md 登记 v1.4.8 并写上两项内容（两处「当前 / Current release」行都改）。
- 附注 tag **`v1.4.8`**（对象 `d3de021`）打在 `f4e5e57` 上；`main` `1421394 → f4e5e57`、tag 均推 **github**（`ClickPM/AcpAgentClient`）与 **origin**（`origin.cursor.com/ckbigdemon/AcpAgentClient`）两个远端，`git push` 回显两处都是 `1421394..f4e5e57  main -> main` 与 `* [new tag] v1.4.8 -> v1.4.8`。
- 无 sidecar 步骤（iteration-16 起产品里已无 `zed-agent-acp`，`sidecar/` 目录与 `D:\cargo-target\AcpAgentClient-sidecar` 都不存在）。

## 出包与验收（release worktree `D:\variFlight_work\AcpAgentClient-release`，`release-build` = `f4e5e57`）

- `scripts\validate.ps1` 全量：**17 道门全绿**，`flutter test` **622 项**通过（`All tests passed!`）。
- `scripts\build.ps1 -Smoke`：`acp_agent_client.exe` 123,392 B / `acp_bridge.dll` 13,006,848 B；无头往返 `ok: true`、`coreVersion 1.4.8`、`droppedEvents 0`。
- `scripts\package.ps1`：payload 84.1 MB、Inno Setup 6 出安装器。
- `scripts\verify-package.ps1`：**VERIFY OK** —— zip 解压即用（空数据目录 + 无头往返）与安装器静默装 → 跑通 → 静默卸载两段都过，两处 banner 都是 `AcpAgentClient 1.4.8 (release, windows/x86_64)`。

| 产物 | 体积 | SHA-256 |
|---|---|---|
| `AcpAgentClient-1.4.8-windows-x64.zip` | 48,400,016 B（46.2 MiB） | `f24dec8f1be113fe4a447fd0803eab30a1c421a06447dd18fa0b020ec57055e3` |
| `AcpAgentClient-1.4.8-setup.exe` | 39,897,084 B（38.0 MiB） | `9f35225f692500fd760913bbca1c6b8ec398bb8d0671387ba2a607ed25234805` |

GitHub release <https://github.com/ClickPM/AcpAgentClient/releases/tag/v1.4.8> 带这两件产物（`gh release view --json assets` 两件都 `state=uploaded`，体积与上表一致；正文入库在 `rounds/round-1.4.8/release-notes.md`）。

**一处要记的异常**：本轮第一次跑完整 `validate.ps1` 时 `cargo test --workspace` 报失败（只留下 `VALIDATE FAILED: cargo test --workspace` 一行，没存下明细）；同一 worktree 紧接着重跑**全量 validate 即 17 门全绿**，单独按共用 target 目录（`CARGO_TARGET_DIR=D:\cargo-target\AcpAgentClient`）重跑 `cargo test --workspace --locked` 也全过（25 / 1 / 11 / 23 / 14 / 20 / 19 各套 + doc-tests 全 ok）。判定为**一次瞬态**（最可能是共用 target 目录的增量产物竞争），不是本次改动引入的缺陷；本版发布依据是那一次全绿的全量 validate 与随后的 `verify-package.ps1`。

## 镜像到日用安装目录

`rounds\round-1.4.8\release-mirror.ps1`（`robocopy /MIR`，先查应用未在跑；相比 1.4.7 那份去掉了 sidecar 残留检查——产品里已经没有它了）：

- 42 = 42 个文件，`acp_agent_client.exe` / `acp_bridge.dll` / `data\app.so` / `data\flutter_assets\FontManifest.json` 四处哈希与 dist 一致（`robocopy exit 1` = 有文件被替换，正常）。
- 临时 `APPDATA` 下 smoke：`coreVersion 1.4.8`、`droppedEvents 0`、`ok: true`；banner `AcpAgentClient 1.4.8 (release, windows/x86_64)`；exe 的 `FileVersion` / `ProductVersion` 都是 `1.4.8+1`。
- 快捷方式「AcpAgent Client.lnk」仍指 `D:\tools\AcpAgentClient`（1.4.7 那次已经把 `IconLocation` 指回 `%LOCALAPPDATA%\Programs\AcpAgentClient` 的安装路径口径，本轮未动它）。

## 打扫（本次构建之前的缓存、分支与 worktree）

- `rounds\round-1.4.8\cleanup-build-outputs.ps1`：`dist\stage` 84.1 MB、release worktree 的 `build\test_cache` 142.5 MB 与 `build\gallery` 4.3 MB、主 worktree 的 `build\test_cache` 66.2 MB 与 `build\gallery` 4.3 MB、1.4.7 的两件产物 84.3 MB、主 worktree 的 6 个旧 report json 0.02 MB，合计 **0.38 GB**（跑完 `dist\` 只剩 1.4.8 那两件）。
- `rounds\round-1.4.8\prune-cargo-debug.ps1`（沿用 1.4.7 那份，未改）：共用 target `D:\cargo-target\AcpAgentClient` 按 cargo 自报的在用 hash 集合剪枝（build 266 / test 273 / clippy 281 units，454 个 hash）：`deps` 删 74 个 **2.65 GB**、`build` 无可删、`incremental` 整删 **9.83 GB**，合计 **12.48 GB**；重跑三条 cargo **0 重编**，`debug` 目录口径 21 GB → 11.0 GB。
- `rounds\round-1.4.8\cleanup-worktrees.ps1`（在 1.4.7 那份上加了 `-ExtraTargets`，用来一并删分支自己的 target 目录）：注销 iter19 worktree（先拆 5 个 `ephemeral\.plugin_symlinks` 联接）、删掉已合入的 `claude/iter-19-session-suspend`，并删掉它专用的 `D:\cargo-target\AcpAgentClient-iter19`（**15.55 GB**，按文件长度和口径）；`vendor\upstream` 前后都是 8 项（守卫文件 `vendor\upstream\agent-client-protocol\Cargo.toml` 在）。
- 结果：D: 可用 273 GB → **297 GB（+24 GB）**（脚本口径合计 28.4 GB，差额来自 cargo target 目录里的硬链接——`du` 只算一次、且计的是占用而非文件长度）；worktree 只剩 `AcpAgentClient`（`main`）与 `AcpAgentClient-release`（`release-build`），分支只剩 `main` / `release-build` / `pr-1`。

## 留给下一轮 / 所有者

- `README.md` / `README.en.md` 的「状态」段已到 v1.4.8；本轮**没有**改 `ROUNDS.md`（§ 7「main 直改」行 2026-09-22 起已封存，1.4.x 这一串版本都不再追加）。
- `iterations/iteration-19.md` 的状态写的是「已合并（未构建）」——v1.4.7 的同类条目当时也没有回改成「已发布」，若要对齐口径说一声，一行改动。
- 共用 target 目录的增量竞争（本轮那次瞬态 `cargo test` 失败）没有深挖；下次再遇到就值得单开一条 BACKLOG，别当成缺陷顺手改。
