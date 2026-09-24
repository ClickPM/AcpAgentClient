# Iteration 11 — BACKLOG P0「资源与静默失败」三条

<!-- 保存为 iterations/iteration-NN.md。一个迭代一个文件、一项一行；流程正本见 iterations/README.md，不在这里复述。 -->

> 状态：进行中　起止：2026-09-24 –　基线：`main` = `7dcdfbe`

所有者 2026-09-24 点名「资源与静默失败」一小节的三条一起做，在 worktree 分支里做。三条互不相干：一条纯前端（终端卡），两条纯核心（fs / pty + acp-core）。
**编号**：开工时 `main` 最新是 iteration-09，另一个 worktree（`claude/backlog-optimization-990610`，状态文件串行化）未提交的文件里已占 10，本文取 **11**；合 `main` 时按当时的最大号再定终号。

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | fix | 终端输出超过 64 K 字符后，终端卡的画面就冻住了：`TerminalBuffer` 加只增不减的累计写入量 `total`，画板 22 / 23 的终端卡与画板 52 的认证终端都按它写增量；没写到的那段已被截掉时清屏重写留存段 | BACKLOG P0「资源与静默失败」第 1 条 | `claude/optimize-three-p0-issues-6b5905` | | | 待审查 |
| 2 | fix | agent 读大文件时整份读进内存：`fs/read_text_file` 改成按 `line` / `limit` 流式读（跳过的行只数不存），回出去的内容超过 16 MiB 回 invalid params | BACKLOG P0「资源与静默失败」第 2 条 | 同上 | | | 待审查 |
| 3 | fix | agent 开终端不释放时，最终会把整个客户端拖死：每条连接同时持有的终端上限 64（先占名额再拉起，超限回错、不拉进程）；`terminal/wait_for_exit` 与 terminal auth 的等退出改成 pty 等待线程回调 + oneshot，不再占 tokio 阻塞池线程，连接先结束就不等 | BACKLOG P0「资源与静默失败」第 3 条 | 同上 | | | 待审查 |

## 收口

- 构建 / 手测：<待定>。所有者手测项（Windows，真 agent）：
  1. **终端卡不冻**（codex 这类在 `_meta` 里带终端输出的 agent，或 fake-agent）：让 agent 跑一条输出很多的命令（`cargo build -v`、`npm install --verbose`，或 `1..5000 | % { "line $_" }`），终端卡一路滚到最后一行，尾巴（退出码、报错）看得见。
  2. **读大文件**：工作区里放一个几百 MB 的日志，让 agent「读一下最后几行」→ 应用内存不暴涨；让它「把整个文件读进来」→ agent 收到一条要它分段读的错误，应用不闪退。
  3. **终端照常**（钉版本的真 agent 都不发 `terminal/create`，用 `test/fake-agent/fake-agent.mjs --terminal` 当自定义 agent）：终端卡照常出输出与退出码，停止方块照常能停。
- 发版：<待定>
- 移出项去向：—
- 设计稿补注记：—（三条都没有画板可见的变化）

## 备注

### 取值（实现时的默认，待所有者确认）

- **`fs/read_text_file` 上限 16 MiB**（`rust/fs/src/lib.rs` `READ_TEXT_FILE_LIMIT`）：比查看器的 2 MiB（`READ_FILE_LIMIT`）宽，因为 agent 的编辑工具常见「整份读 → 改 → 整份写回」，几 MB 的锁文件 / 打包产物要读得动；再大的整份读超过任何上下文窗口，对 agent 没用。超限回 `-32602`，消息叫它带 `line` / `limit` 分段读。带 `line` / `limit` 的读不受文件大小限制（跳过的行只数不存，峰值只有一块 64 KiB 读缓冲 + 回出去的那段）。
- **每条连接终端上限 64**（`rust/acp-core/src/agent.rs` `MAX_TERMINALS_PER_CONNECTION`）：数的是「建了还没 release」的，含已退出没 release 的（它们各留着最多 4 MiB 的输出缓冲）与正在拉起的。钉版本的五个 agent 源码里没有一个发 `terminal/create`（codex-acp 只在 `_meta` 里带终端输出），内置 Zed agent 的终端也在 sidecar 进程内跑（`sidecar/zed-agent-acp/src/translate.rs` 第 1 条），正常用法撞不上。超限回 `-32603`，消息叫它先 `terminal/release`。
- 没给 tokio runtime 设 `max_blocking_threads`：等退出不再占阻塞线程之后，剩下的 `spawn_blocking`（fs 回调、create、kill 最多 5 秒、release）都是有界的。

### 实现要点

- **终端卡**（`lib/ui/transcript/terminal_card.dart`、`lib/ui/registry/auth_page.dart` 的 `AuthTerminalCard`）：`_written` 从「`output` 的长度」改成「累计流里的位置」；留存段在累计流里是 `[total - output.length, total)`，`_written` 落在它之前（一次写入超过上限、或卡片在截断之后才建）就清屏重写留存段，否则只写 `output.substring(_written - start)`。换 buffer 时终端卡也清屏（原先只有认证终端清，终端卡会把新缓冲接在旧画面后面）。
- **流式读**（`rust/fs/src/lib.rs` `read_lines`）：行口径与原先的 `slice_lines` 逐字一致（`\n` 切行、`line: 0` 同缺省、末尾换行之后算一个空行、读过文件尾的报错带最后一行行号与长度）；原 `slice_lines` 删掉，它的用例改由测试里同名的小函数跑在 `read_lines` 上。lossy 解码挪到收完之后整段做，按 `\n` 切段与整份解码结果一样（`\n` 不会是多字节字符的一部分）。唯一的口径差：「读过文件尾」报错里最后一行的长度按原始字节算，原先按 lossy 解码后的字节算，只在最后一行含非 UTF-8 字节时不同。
- **等退出**（`rust/pty/src/lib.rs` `TerminalManager::on_exit`）：`ExitCell` 里加一张回调表，退出那一下锁外逐个调一次，已退出就当场调；pty 仍不依赖 tokio。acp-core 的 `wait_terminal_exit` 挂一个 oneshot；`on_wait_for_terminal_exit` 与连接的 `wait_exit()` 赛跑，连接先结束就回错不等（终端已随 `finish` → `release_owned_terminals` 释放）。登记后 release 掉终端也照样回调（release 先 kill，等待线程收尾时 set）。terminal auth（`core.rs` `terminal_auth_run`）同一条路：登录可能要等用户几分钟，原先同样钉一条阻塞线程。
- **终端上限**：`Shared` 加 `creating_terminals`（只在持 `owned_terminals` 锁时改）。create 先在锁内判 `owned.len() + creating >= 上限` 并占名额，拉起之后在同一把锁里把名额换成登记（或撤掉），两次判断之间并发的 create 不会多看出空位；拉起失败、连接已退出这两条原有的路径都先撤名额。

### 测试

- `test/ui/terminal_card_truncation_test.dart` 5 项：缓冲层 `total` 只增不减；终端卡写满之后的输出照样进 xterm、一次写入超过上限清屏重写、截断之后才建的卡；认证终端写满之后照样刷新。上限用 40 个字符代替 64 K。
- `rust/fs` 新增 2 项：3 字节读缓冲下的流式切行（行与多字节字符都切在块边界上）、上限只卡回出去的内容、正好等于上限可以、坏字节 lossy；真文件（16 MiB + 1 KiB）整份读被拒、带 `line` / `limit` 能读到中间两行与最后一行。原 `slice_lines` 的用例照旧跑，补一条「读过文件尾」报错的原文。
- `rust/pty` 新增 1 项：跑着时登记的两个回调在 release（先 kill）之后各回一次、只回一次；退出之后登记的当场回；release 后的 id 报 `UnknownTerminal`。
- `rust/acp-core/tests/scripted.rs` 新增 1 项（新场景 `terminal_limits`）：运行时只给**一条**阻塞线程，测试侧先替连接登记 63 个占位终端；agent 建一个长命令终端顶满、连发三个 `wait_for_exit` 不等回 → 读文件 10 秒内拿到内容 → 再建被拒（`-32603`，消息含 `too many terminals`）→ kill 后三个等待都拿到非零退出 → release 空出名额 → 短命令照常建 / 等 / 放。
- **反向核对**：终端卡与认证终端退回按长度比 → 4 项 widget 测试全红；`wait_for_exit` 退回 `spawn_blocking(wait)` → 新集成测试在「读文件」一步超时变红（60 秒）；去掉上限判断 → 同一项在「再建被拒」一步变红。

### Windows 实测（规则 9）

终端的拉起路径没改（仍经 `spawn_shell_command` → PowerShell），新增用例在 Windows 11 26200 上经 PowerShell / cmd 真拉进程跑：

```
$ CARGO_TARGET_DIR=D:/cargo-target/AcpAgentClient-p0-three cargo test -p acp-core --test scripted
test terminal_waits_do_not_pin_blocking_threads_and_creates_are_capped ... ok
test fs_and_terminal_callbacks_through_the_client_handlers ... ok
test result: ok. 11 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 2.01s
$ cargo test -p pty
test tests::on_exit_fires_once_on_exit_and_immediately_after ... ok
test result: ok. 14 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 1.25s
```

### 代码审查

- <待审>
