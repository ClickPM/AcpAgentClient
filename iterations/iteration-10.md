# Iteration 10 — 本地状态文件的读改写串行化

<!-- 保存为 iterations/iteration-NN.md。一个迭代一个文件、一项一行；流程正本见 iterations/README.md，不在这里复述。 -->

> 状态：进行中　起止：2026-09-24 –　基线：`main` = `7dcdfbe`

BACKLOG P0「数据一致性」的「本地状态文件的读改写没有串行化」。它的 `settings.json` 那一半就是 2026-09-23 关掉的「settings.json 的各段写入没有串行化」，
当时的理由是「现有交互做不到同时改外观和拨转录开关」；新证据是 `settings.json` 还有一个不靠用户点击的写入方（后台安装 / 升级任务的 `write_registry_settings`），
另外 `sessions.json` 在会话并跑之后会被多条会话各自写。所有者 2026-09-24 复议后重开，与 `sessions.json` / `projects.json` / `ui-state.json` 一起在本迭代修。

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | fix | 本地状态文件的「读 → 改 → 写」加进程内写锁：`rust/settings` 给四份文件各加一把 `static *_WRITES: Mutex<()>`（共用 `lib.rs` 的 `write_lock`，写法照 `rust/registry/src/manifest.rs`），罩住 `settings.json` 的 `upsert` / `set_appearance` / `set_transcript` / `remove` / `import_zed`、`sessions.json` 的 `upsert_session` / `remove_session`、`projects.json` 的 `open_project`、`ui-state.json` 的 `merge`；core / 桥 / 前端零改动。用例 4 条 | BACKLOG P0「数据一致性」第 1 条（所有者 2026-09-24 复议重开 `BACKLOG-CLOSED.md`「settings.json 的各段写入没有串行化」） | `claude/backlog-optimization-990610` | validate 全绿（独立 `-CargoTargetDir`；527 项 flutter test）；未构建、未手测 | 待审查 | 待审查 |

## 收口

- 构建 / 手测：待定。并发窗口只有几毫秒，手测复现不出来，靠用例兜。
- 发版：待所有者定。
- 移出项去向：—
- 设计稿补注记：无（纯核心侧修复，无界面变化）。

## 备注

### 为什么锁在 store 里、为什么是 `static`

- **锁在 store 方法里**：写入方散在 `core.rs`（外观、转录、设置页、索引、ui-state）、`registry_ops.rs`（安装 / 升级 / 移除 / 回滚）和 `zed_import.rs`，锁在调用方那边就得一处处补，漏一处就还有洞；锁在「load → save」所在的方法里，所有调用方自动覆盖。
- **`static` 而不是 store 的字段**：`SettingsStore` 等都是 `Clone` 的路径包装，锁放字段里的话，两个实例指向同一份文件时各拿各的锁，等于没锁；进程级 `static` 管的是文件本身。测试里多个 store 指向不同临时目录时会被一起串行，只是慢一点，不影响对错。
- **一个文件一把**：`settings.json` / `sessions.json` / `projects.json` / `ui-state.json` 互不相干，用四把锁，一份文件的慢写不挡另一份。
- **std `Mutex` 不跨 `.await`**：这些方法都是同步的，持锁期间只有一次读文件与一次原子写，锁不会跨到 await 之后；核心本来就在 worker 线程上做这些阻塞 IO，锁最多让同一份文件的下一笔多等一次写盘。
- **锁住的方法之间不互调**（`Mutex` 不可重入）：`upsert` / `set_*` / `remove` / `import_zed` 只调 `load` 与 `save`，这两个不拿锁。

### 这把锁不管的

- **先后**：锁只保证两笔写不交叉，不保证先发的先落地（桥的每条命令各起一个任务）。同一条会话「写与删」的先后仍由前端 `lib/app/session_index.dart` 的 `_inFlight` / `_removing` 管，这些不能因为有了锁就删；`BACKLOG-CLOSED.md`「连着改两次外观可能丢一次」是先后问题，维持关闭。
- **查了再写**：`write_registry_settings` 与 `agent_settings_set` 是「`get` 一次 → 再 `upsert`」两次拿锁，中间留一个极小的空档（空档里有人建了同名条目）。它不会再冲掉别的段，不为它另加机制。

### 用例与反证

四条用例都是多线程同时写之后核对：`settings.json` 8 个线程各写 8 条 agent 条目，另两个线程同时改外观与转录，最后 64 条一条不少、外观与转录都在；`sessions.json` 8 个线程各写 8 条新会话，中途各删一条旧会话，最后 64 条新的都在、旧的一条不复活；`projects.json` 8 个线程各开自己的目录；`ui-state.json` 四个线程各写一个字段，每轮从空文件起、各写一次就核对，共 32 轮（同一线程反复写的话，被盖掉的值会被它自己下一次写补回来，测不出来——第一版这么写，去掉锁时 10 次只红 2 次）。

反证：把 `write_lock` 临时改成每次一把新锁（等于没锁），`cargo test -p settings concurrent` 连跑 10 次，**10 次四条全红**，失败都是断言（条目数不对、旧会话复活），不是 rename 报错；换回之后全量 `cargo test -p settings` 连跑 10 次全绿（21 passed）。
