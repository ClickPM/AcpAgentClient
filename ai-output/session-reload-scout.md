# 调研：会话头 Reload 能否做成 session 级（BACKLOG P0「会话头 Reload 实际重启整个 agent」）

> 调研日期 2026-09-30。**只读调研，未改任何实现 / 设计稿。**
> 对应条目：`rounds/BACKLOG.md:46-48`（工作副本里未提交，`git diff --stat rounds/BACKLOG.md` = 11+/3-，为所有者 2026-09-30 当日新登记）。
> 结论先行：**可以新增一个「session 级重建」，但它不是 Reload，也替代不了 Reload。** ACP v1 没有任何 session 级 restart/reload 原语；session 级能做的只是 `session/close` + `session/load|resume`（同一连接内重建会话运行时，**不重启 agent 进程**），而 Reload 这个按钮存在的目的是让升级后的 agent 二进制生效——那必须是进程级重启。

---

## 0. TL;DR（给所有者的一屏）

1. **现状**：会话头 reload 图标与 ≡ 菜单 `Reload Agent` 是同一个动作 `SessionController.reloadAgent()`。它按 **agentId** 断开整条连接（`agent_disconnect` → 杀进程树），把该 agent 名下**所有**会话标成挂空，只自动 `session/load` 回当前会话，其余靠用户点开 / 再发时懒挂回（`lib/app/session_controller.dart:540-583`、`lib/app/session_attach.dart:117-121`、`rust/acp-core/src/core.rs:290-296`）。
2. **协议**：钉版本 ACP v1 的 session 方法只有 `new / load / resume / close / delete / list / cancel / prompt / set_mode / set_config_option / update / request_permission`——**没有 reload / restart**（`vendor/upstream/agent-client-protocol` 里 `grep -rn -i "reload\|restart"` 在 session 相关 schema/文档零命中，只有一句「persistence across restarts」讲 `session/load` 的用途）。
3. **可组合的 session 级动作**：`session/close`（cancel 在途工作 + 释放资源）→ `session/load`（重放历史 + 恢复上下文）或 `session/resume`（只恢复上下文，不重放）。客户端三件都已实现（iteration-19 的挂起 = close；≡ 菜单 Resume；`ensureLoaded` = load）。但它**不重启进程**，所以升级后的二进制还是旧的那份。
4. **能力矩阵**（钉版本源码，见 §3）：claude / codex / dsh 三家的 `close + (load|resume)` 齐；**pi 没有 close 也没有 resume**，且它的 load/new 会顺手关掉同连接其它 pi 会话（上游限制）；cursor 是专有二进制，只能运行时由 `initialize` 读能力；registry 里的其它 agent 同理。
5. **推荐裁定**：
   - **不要**把会话头 Reload 改成 session 级——那会让画板 53「已升级 · 待重载」的升级流程静默失效（`docs/design.md:133`、`lib/ui/registry/registry_entry.dart:170-173`、`design/round-design/53-registry-upgrade.dc.html:80` 明写「会话头 Reload Agent 或重开应用后生效」）。
   - 最小整改：**改文案**——把会话头 tooltip `'Reload this session'`（`lib/ui/shell/session_header.dart:124`）改成与画板 41 / 状态条一致的「agent 级」措辞，并在 tooltip 里点明「会重启该 agent 进程，打断它名下所有会话」。设计稿里 reload 图标本来就没有 tooltip（`01/02-workbench-*.dc.html` 无 `title`），这句是实现自造的，属规则 3 的既有偏离。
   - 若所有者确实想要一个 session 作用域的动作，**另加一个入口**（如 ≡ 菜单「Restart this session」），能力门 = `sessionCapabilities.close` 且 (`loadSession` 或 `sessionCapabilities.resume`)，实现复用已有的 close / resume / ensureLoaded，**不新增机制**；并在入口处写明「不重启 agent 进程，不会让升级后的版本生效」。**这属新功能，画板没有 → 按规则 3 先改设计稿再进轮次。**

---

## 1. 现状完整调用链：为什么波及同 agent 的所有会话

### 1.1 UI 触发点

| 位置 | 文本 / 语义 | 代码 |
|---|---|---|
| 会话头 reload 图标 | tooltip **`Reload this session`**（实现自造，画板无此文案） | `lib/ui/shell/session_header.dart:123-124` |
| 会话头 ≡ 菜单 | 行文案 **`Reload Agent`**（与画板 41 一致） | `lib/ui/popovers/topbar_popovers.dart:326` |
| 画板 34 连接状态条 | 按钮文案 **`重启 agent`** | `lib/ui/shell/agent_state_bar.dart:102` |

三者都接同一个回调 `c.session.reloadAgent`（`lib/app/workbench_screen.dart:414` 会话头、`:518` 状态条）。**同一个动作，三个名字，会话头那个名字是错的**——这就是所有者报障的直接来源。

画板侧：画板 01/02 画了 reload 图标但**没有 tooltip 文案**（`design/round-design/01-workbench-empty.dc.html`、`02-workbench-running.dc.html` 内 `title=` 只有 `session/cancel`）；画板 41 的菜单行写的是 `Reload Agent`（`41-topbar-popovers.dc.html:62`）；画板 53 的升级态文案写「在会话头 Reload Agent 或重开应用后生效」（`53-registry-upgrade.dc.html:80`）。

### 1.2 `reloadAgent()`（`lib/app/session_controller.dart:540-583`）逐句

```
540  Future<void> reloadAgent() async {
541    hidePopover(sessionMenuAnchor);          // 只关 ≡ 菜单，不关别的
...
546    onClearAgentQueues?.call(id);            // ← 按 agent 清光所有会话的「未发送」发送队列
...
550    if (waitingForAgent || attachInFlight || _connecting.isNotEmpty) return;  // 重入守卫
551    final previous = sessionId;              // 只记当前这两条
...
556    waitingForAgent = true;
...
561    await b.agentDisconnect(id);             // ← 核心断开整条 agent 连接（进程树）
...
566      await _connectOnce(b, id, cwd);        // ← 重新 agent_connect：connectionReplaced 把该 agent 名下全部会话标挂空
567      if (!canLoadSessionOf(id) || !await loadSession(id, previous, ...)) {
...
575        await createSession(id, cwd);        // 不支持 / 载失败：开新会话
...
580      if (loaded) sessionEpoch++;
581      waitingForAgent = false;
```

- `546` → `onClearAgentQueues`：绑定在 `lib/app/workbench_controller.dart:69`（`session.onClearAgentQueues = turn.clearQueuesForAgent`），实现在 `lib/app/turn_controller.dart:358-365`：**按 `registeredOwner(sessionId) == agentId` 遍历，清空该 agent 下每条会话的发送队列**（注释写明「裁定 c：agent 断开 / 重载 / 卸载时」）。注意它只清**未发出**的队列，**不发 `session/cancel`**。
- `561` → `agentDisconnect(id)`：`lib/app/core_bridge.dart:187` → `rust/bridge/src/api.rs:135` → `rust/acp-core/src/core.rs:290-296`：
  ```rust
  290  pub async fn agent_disconnect(&self, agent_id: &str) -> Result<Value> {
  291      let connection = lock(&self.agents).remove(agent_id)...
  293      connection.disconnect().await;
  ```
  核心的连接表是 **`agents: Mutex<HashMap<String, Arc<AgentConnection>>>`，键就是 agentId、每 agent 至多一条**（`rust/acp-core/src/core.rs:35`、`:146`）。断开动作是 `AgentConnection::disconnect`（`rust/acp-core/src/agent.rs:1160`，`disconnect()` 实现在 `:1225`）：先关 stdin 让 agent 自己退，超过宽限就结束进程树。
- `566` → `_connectOnce` → `_connect`：`lib/app/session_controller.dart:479-501`，`agent_connect` 成功后 `:497` 调 `connectionReplaced(agent)`。
- `connectionReplaced`（`lib/app/session_attach.dart:117-121`）：
  ```dart
  117  void connectionReplaced(String agent) {
  118    _generation[agent] = generationOf(agent) + 1;
  119    for (final s in sessions.all) {
  120      if ((s.agentId ?? registeredOwner(s.sessionId)) == agent) _detached.add(s.sessionId);
  ```
  **把该 agent 名下内存里的每条会话都标成挂空**（这正是 iteration-09 的设计：ACP 会话属于创建/载入它的那条连接，连接换代则旧 sessionId 失效）。
- `567` 只对 `previous`（当前会话）发 `session/load`；`575` 失败才新开。**其它会话不在这里被载回**，它们靠用户点开（`selectSession` → `ensureLoaded`，`session_attach.dart:199`）或再发消息（`reattach`，`:259`）时懒挂回。

### 1.3 被波及会话的实际损失

- **在途那一轮直接失败**：其它会话若正在 `session/prompt`，进程被杀后核心 `race_exit` 返回 `exited`（`rust/acp-core/src/agent.rs:1173-1195`），前端 `_runTurn` 的 catch 分支把这一轮以错误收进转录（`lib/app/turn_controller.dart:196-213`），结束行显示错误、队列按「裁定 d」置 Paused（`turn_controller.dart:221-235`）。
- **未发送队列被清空**：`clearQueuesForAgent`（`turn_controller.dart:358`；队列本身是纯内存态，`lib/app/send_queue.dart` 头注「断开连接 / 关闭会话清空」）。所以「正在执行的任务被打断 + 排队消息丢失」都是真的。
- **懒挂回不是免费的**：其它会话下一次被点开 / 再发时会走 `ensureLoaded` / `reattach` → `session/load`（重放整段历史）或 `session/resume`（`session_attach.dart:249-257`）。对长会话这条重放可能明显耗时；pi 还会顺手关掉同连接其它会话（见 §3.3）。
- **跨 agent 不受影响**：连接表按 agentId 分键，断开只动 `id` 那一条（`core.rs:35/146/290`），所以「同 agent 两条并跑会话」是这条 backlog 的准确范围。

### 1.4 设计文档里已有的既定口径

- `docs/design.md:95`：「新建会话**不重连 agent**……重载 agent（会话头 reload）仍是断开 + 重拉」。
- `docs/design.md:96`：「**会话挂在哪条连接上是前端本地态**（iteration-09）……每次 `agent_connect`（重载、崩溃后重连、认证页连接）都把这个 agent 名下内存里的会话标成挂空，切过去或再发时先挂回」。
- `docs/design.md:133`（registry 升级，画板 53）：「**不打断运行中的连接**……`reloadPending`……会话头 Reload Agent 或重开应用后生效」。
- `docs/design.md:146` 是内置 Zed agent 的映射（现已随 iteration-16 移除，见 §4.5）。
- BACKLOG-CLOSED「重载或崩溃之后，别的会话发不出去」条（`rounds/BACKLOG-CLOSED.md:125`）：懒挂回正是这一条修出来的既定行为。

**结论**：当前实现不是「漏了」session 级处理，而是 Reload 的既定语义就是 agent 级；真正的缺陷是**会话头那行文案把这件 agent 级的事说成了会话级**。

---

## 2. ACP（钉版本）到底支不支持 session 级 close / reopen / load / resume

钉版本：`pins/upstream.json` → agent-client-protocol `1ce24ea67a6f0598b0f5aff637993d9836306a28`（schema/v1）、rust-sdk `3a6d0ae88dbaa09fcb74e26761e3643a75b2015e`（crate 2.1.0），`docs/acp-projection.md:114/118` 是本项目对这套能力的既有摘要。

### 2.1 没有 reload / restart 原语

```bash
cd vendor/upstream/agent-client-protocol
grep -o '"x-method": "[a-z/_]*"' schema/v1/schema.json | sort -u
# → authenticate / elicitation/complete / elicitation/create / fs/read_text_file / fs/write_text_file
#   / initialize / logout / session/{cancel,close,delete,list,load,new,prompt,request_permission,
#     resume,set_config_option,set_mode,update} / terminal/{create,kill,output,release,wait_for_exit}
grep -rn -i "reload\|restart" schema/v1/schema.json docs/protocol/v1/*.mdx docs/protocol/v1/draft/*.mdx
# → 仅 session-setup.mdx:85「persistence across restarts」（讲 load 的用途），无 reload/restart 方法
```

**没有任何「重启会话运行时」的方法。** session 级能做的全部算子就是上表里那 12 个 session 方法。

### 2.2 三个会话生命周期算子的规范语义

| 方法 | 能力声明 | 规范语义（原文要点） | 证据 |
|---|---|---|---|
| `session/load` | `agentCapabilities.loadSession` | 恢复会话上下文、连接 MCP、**MUST 用 `session/update` 重放整段历史**再返回；用于「跨重启 / 跨客户端实例」 | `docs/protocol/v1/session-setup.mdx:83-104`、`:85` |
| `session/resume` | `sessionCapabilities.resume` | 恢复上下文、连 MCP，**MUST NOT 重放**；「reconnect to an existing session」 | `session-setup.mdx:190-213`、`:243` |
| `session/close` | `sessionCapabilities.close` | **MUST 先 cancel 在途工作（等同 `session/cancel`）再释放资源**；规范允许 agent 对「不存在 / 不处于 active」的会话报错 | `session-setup.mdx:255-278`、schema `CloseSessionRequest` 描述（`schema/v1/schema.json:4363-4367`） |

关键区分（BACKLOG ① 要求的那点）：
- **`session/load` 只保证「重放转录」，不保证「重建运行时」**。是否重建取决 agent 实现，见 §3。
- **`session/close` 才是「释放 + cancel」这个副作用的正主**。想「重启一个会话」= 先 `close`（把运行态释放掉）再 `load|resume`（把上下文重新挂回来），**顺序不能省**：钉版本里 dsh 对「已 active 的 id」调 load/resume 直接 `-32602`（`vendor/upstream/dsh-acp-interactive/src/index.ts:536`），pi 的 load 会自己先把同 id 关掉（`pi-acp/src/acp/agent.ts:938`）——即「对活着的会话调 load」行为是 agent 自定义的，客户端不能假定它是重启。

### 2.3 所以「session 级 Reload」在协议上的最大能力边界

- 能做到：**在同一个 agent 进程内，只释放并重建目标会话的运行时**（= `cancel + close + resume|load`），其它会话在协议层不受影响（pi 例外，见 §3.3）。这是 **进程内** 的重建。
- 做不到：**只重启目标会话所依赖的 agent 进程 / 只让目标会话换用升级后的二进制**。ACP 的 `initialize` 是连接级的，连接 = 一个进程；「升级生效」必须重新 spawn 进程 = 断开整条连接 = 当前 Reload 的行为。
- 想「只为目标会话起一个新进程、其它会话留在旧进程」需要**每 agent 多条连接**并把会话在连接间迁移：本项目核心按 agentId 单键存连接（`core.rs:35`），协议也没有「把活着的会话搬到另一条连接」的原语（只有 load = 从磁盘重建）。这是结构性改动，**不建议**纳入本条。

---

## 3. 逐 agent 证据（钉版本源码）+ 能力矩阵

> 规则 2：客户端不按 agent 名判，只读 `initialize` 回的 `agentCapabilities`（`lib/app/session_controller.dart:343-357`）。下面的矩阵是**当前钉版本的事实记录**，不是客户端判据；换钉版本 / 用户装 registry 里别的 agent 都会变。

### 3.1 能力矩阵（`loadSession` / `sessionCapabilities`）

| agent | 钉版本 | `loadSession` | `resume` | `close` | `list` / `delete` | 同连接多会话隔离 | 能否做 session 级重建（close+load/resume） |
|---|---|---|---|---|---|---|---|
| Claude Agent（claude-agent-acp） | commit `6b7473b`，pkg 0.76.0 | ✅ | ✅ | ✅ | ✅ / ✅ | ✅（每会话一个 SDK query，`this.sessions` 字典） | ✅（须先 close；见 3.1） |
| Codex（codex-acp） | commit `51d6247`，pkg 1.11.0 | ✅ | ✅ | ✅ | ✅ / ✅ | ✅（共享一个 codex app-server 进程，每会话一条 thread 订阅） | ✅（close = thread/unsubscribe，resume = thread/resume；见 3.2） |
| pi（pi-acp） | commit `d1cffc0`，pkg 0.0.33 | ✅ | ❌ | ❌ | ✅ / ✅ | **❌ 每连接只留一个 pi 子进程** | ❌ 缺 close/resume；且 load/new 会关掉其它会话 |
| DeepSeek Harness（dsh-acp-interactive） | commit `e39fd48`，pkg 1.3.2 | ✅ | ✅ | ✅ | ✅ / ❌ | ✅（每会话一条 record/子进程） | ✅ 且**必须**先 close（对 active 直接 -32602） |
| Cursor（registry `cursor`，专有二进制 2026.09.02） | 无源码（`pins/upstream.json` 的 `docs_only`） | 运行时才知道 | 运行时才知道 | 运行时才知道 | 运行时才知道 | 运行时才知道 | 运行时才知道（由 `initialize` 能力驱动） |
| registry 其它 agent（claude-acp/codex-acp/pi 之外的 30+ 条） | 各自版本 | 各自声明 | 各自声明 | 各自声明 | 各自声明 | 各自声明 | 各自声明 |

### 3.2 claude-agent-acp（`6b7473b`）

- 能力声明：`src/acp-agent.ts:2061-2069` `sessionCapabilities = { additionalDirectories, close, delete, fork, list, resume, subagents }`；`:2099` `loadSession: true`。
- `closeSession`：`:6392-6398` → `teardownSession(id)`，随后从 `this.sessions` 删除。
- `load/resume` 共用 `getOrCreateSession`（`:7673-7705`）：**同 id 的会话若已存在且会话定义指纹没变，直接返回既有会话、不 teardown**（`session/load` 只额外重放历史）——**所以「对活着的会话 load」不是重启**；指纹变了才 teardown + 以 `resume: sessionId` 重建。
- ⟹ 对 claude，**session 级重建 = 先 `session/close` 再 `session/load|resume`**，能拿到一个新的 SDK query；但对「load 一下就完事」的写法不成立。

### 3.3 codex-acp（`51d6247`，pkg 1.11.0）

- 能力声明：`src/CodexAcpServer.ts:340-347` `sessionCapabilities = { resume, list, close, delete, fork, additionalDirectories, subagents }`；`:361` `loadSession: true`。
- `closeSession`：`CodexAcpServer.ts:859-892`（interrupt 在途轮 → `closeSession` 到 app-server → 清会话态）；底层 `src/CodexAcpClient.ts:636-642` = `threadUnsubscribe` + 清 handler → 即「退订一条 thread」。
- `resumeSession`：`CodexAcpClient.ts:530-549` = `thread/resume`（`excludeTurns: true`）；`loadSession`：`:570-605` = `thread/resume` + 读历史。
- **证据：codex 的 app-server 进程是 agent 级共享的**——`CodexAcpServer.ts:1019-1055` 在 provider 变更时「Restarting Codex app-server」并**逐条** `replacement.resumeSession({sessionId...})` 把所有会话重新挂上。⟹ session 级 close/resume 只重建 thread 订阅，**进程不动**。

### 3.4 pi-acp（`d1cffc0`，pkg 0.0.33）——本条的硬约束

- 能力声明：`src/acp/agent.ts:254-268` `loadSession: true`，`sessionCapabilities = { list, delete }`——**没有 `close`，没有 `resume`**。
- `loadSession`（`src/acp/agent.ts:930-963`）：先 `this.sessions.close(params.sessionId)`（对已在跑的 id 主动关），重建后执行
  ```ts
  955  // Policy: within a single ACP connection (one client window), keep only one live pi subprocess.
  956  // This avoids leaking subprocesses ...
  957  ;(this.sessions as any).closeAllExcept?.(session.sessionId)
  ```
  `newSession` 同样在 `:377` 调 `closeAllExcept`；`closeAllExcept` 定义在 `src/acp/session.ts:180-184`。
- ⟹ **pi 连接上任何 load/new 都会把该连接里其它 pi 会话的子进程关掉**（BACKLOG 里说的「pi-acp 新建 / 加载会话内部关闭其他会话的问题，另向上游反馈」正是这条）。所以：
  - pi 没有 close/resume，**无法构造 session 级重建**；
  - 连「session 级只重载一条」这个验收目标对 pi 也不成立——重载一条必然打断另一条。这条属上游行为，按所有者裁定不进本表（`rounds/BACKLOG.md:48`）。

### 3.5 dsh-acp-interactive（`e39fd48`，pkg 1.3.2）

- 能力声明：`src/index.ts:811-819` `loadSession: true`，`sessionCapabilities = { list, resume, close }`。
- `resumeRecord`（load/resume 共用，`:524-540`）：**`sessions.has(id) || startingSessions.has(id)` → `invalidParams("session is already active in this ACP connection: …")`（`:536`）；`agents.get(id) !== undefined` → `"session is already active outside this ACP connection"`（`:539`）**。
- `loadSession`：`:918-931`（重放）；`resumeSession`：`:933-945`（不重放）；`closeSession`：`:947-965`（释放 record）。
- ⟹ dsh 是最标准的「close 然后 load/resume」模型；客户端现有的 `closeSession` + `resumeSession` / `ensureLoaded` 就能拼出来。

### 3.6 Cursor

- `pins/upstream.json` 记为 `docs_only`（`cursor-cli-acp`，registry entry `cursor` = 2026.09.02，专有二进制、命令 `agent acp`）；仓库里**没有源码可核**。
- 客户端本来就在 `initialize` 后按声明的能力裁剪动作（`session_controller.dart:343-357`、`docs/acp-projection.md:114`），所以 session 级动作的能力门会自动生效，不需要也不允许按名字特判。

### 3.7 内置 Zed agent（sidecar）——**已不在产品里，本条不适用**

- BACKLOG 原文让核「内置 Zed agent」，但 `sidecar/zed-agent-acp/` 已由 **iteration-16（2026-09-24→29）彻底从产品、构建体系与 pins 移除**：`iterations/iteration-16.md:1`「彻底去 Zed 化」、工作项 1-5；`docs/zed-agent.md:1-6` 已标「已归档（Iteration 16，2026-09-29）」；`pins/upstream.json` 已无 zed 条目；`rust/acp-core/src/builtin.rs:1` 只剩 `dsh-acp-interactive`。
- 所以矩阵里**不应再列内置 Zed agent**；BACKLOG 这句是 2026-09-30 登记时留下的旧口径，建议随手改掉（本节即证据）。

### 3.8 代表性 ACP 客户端 Zed 的参照行为（钉版本 `d9e1c02`，本地参考副本）

> 注：`vendor/upstream/zed` 随 iteration-16 一并移除；本机参考副本在 `D:\variFlight_work\_references\zed`，`git log -1` = `d9e1c024f393832765a03f4de204d6c8cd9abcb2`，与旧钉版本一致。

- 连接级重启：`crates/agent_ui/src/agent_connection_store.rs:127-141` `restart_connection(key: Agent, …)`——**按 `Agent`（连接）为键，丢掉缓存连接、下次请求重新 spawn 进程**。没有 session 级 restart API。
- 重试 = 丢连接 + 只重挂当前 thread：`crates/agent_ui/src/conversation_view.rs:985-1004` `retry_connection` 注释「Drops the cached connection for this agent (so the next request spawns a fresh server process) and rebuilds the thread state from scratch.」，`reset()` 里把当前 thread 的 `resume_session_id` 取出后重建 `initial_state`。
- Zed 自己也有「重启 vs 保留 thread」的同族竞态，被测试固化：`crates/agent_ui/src/agent_panel.rs:13505-13540` `test_retained_thread_reset_race_disassociates_session`（重启连接 → 保留的 thread 被判 `has_thread_error` → reset → 两个 load 抢同一 session）。
- ⟹ **代表性客户端同样只有 agent/连接级 restart**；session 作用域里它也只有 close / load。这与本项目当前实现同构，佐证「session 级 Reload」不是业界已有的原语。

---

## 4. 需要 agent 支持 / 不能保证的条件（逐条）

1. **能构造 session 级重建**：必须 `sessionCapabilities.close` **且**（`loadSession` 或 `sessionCapabilities.resume`）。缺任一则做不到（pi 就是）。
2. **顺序必须 close → load/resume**：对 active 会话直接 load/resume 的行为是 agent 自定义的（dsh 报 `-32602`；pi 自己关掉同 id 再重建；claude 未变指纹时是 no-op 不重建）。客户端不能在「没 close」时假定 load 是重启。
3. **「重建」≠「重启进程」**：即使 close+load/resume 成功，agent 进程没换；升级后的二进制 / 进程级配置（环境变量、启动参数、provider 重启）不会生效。codex 更是共享一个 app-server 进程（`CodexAcpServer.ts:1019-1055`）。
4. **close 会取消在途工作**：规范要求 `session/close` 等同先 `cancel`（`session-setup.mdx:257`、schema 描述）。所以 session 级重建同样会打断**目标**会话正在跑的那一轮（这是这个动作语义的一部分，不是副作用）。
5. **不能保证同连接其它会话不受影响**：协议层不会，但 agent 实现可以——pi 每连接只留一个子进程，load/new 都 `closeAllExcept`（`pi-acp/src/acp/agent.ts:377/957`），且它没有 close/resume 让客户端自己控制。
6. **不能保证恢复成功**：`session/load` 失败时客户端已有既定退路——这次重放整段作废、原转录留着、会话仍标挂空（`session_attach.dart:295-360`，`_load` 的 `failed` 分支）；不能以「重放」冒充「运行时已重建」。
7. **能力未知时不能猜**：本次还没连过的 agent，`capsOf` 为 null（`session_controller.dart:343`），动作要不要显示得等 `initialize` 回来；现有 `attachOf` 对能力未知按「可能挂回来」处理（`session_attach.dart:186-196`），session 级动作若做，应沿用同一口径或直接不显示。
8. **不能以 agent 名判**：规则 2。矩阵是钉版本事实，运行时一律读 `agentCapabilities`。
9. **不能静默降级**：所有者已明确「若确需 agent 级重启，必须明确其影响范围，不能以『当前 session』名义静默中断其他会话」（`rounds/BACKLOG.md:48` ③）。

---

## 5. 结论 / 推荐 owner 裁定文本（草稿）

> 以下为建议文本，供所有者改写后落进 BACKLOG / 任务卡；**本次调研不改任何文件**。

### 裁定 A（推荐，最小整改，可立即执行）

**会话头的 reload 是 agent 级动作，按 agent 级正名；不改为 session 级。** 依据：ACP v1 无 session 级 restart 原语；Reload 的唯一产品职责是让升级后的 agent 二进制生效（`docs/design.md:133`、画板 53），而 session 级动作不换进程、无法达成；画板 41 与状态条本来就写 `Reload Agent` / `重启 agent`。

具体：
1. `lib/ui/shell/session_header.dart:124` 的 tooltip `'Reload this session'` **改文案**为 agent 级措辞，并点明影响范围（例：`Reload agent — restarts this agent's process and interrupts all of its sessions`；中文口径与状态条 `重启 agent` 统一）。
2. 会话头 reload 图标与 ≡ 菜单 `Reload Agent` **保持同一动作**（现状即如此），不再各自命名。
3. 记一条 `design/DIVERGENCE.md`（规则 3）：画板 01/02 的 reload 图标未定义 tooltip，实现补了文案——以实现为准，不改画板。
4. 验收：同 agent 两条并跑会话，点 reload 后另一条的失败轮以错误收尾、原因可见（画板 31 结束行）、点回去能挂回；跨 agent 会话完全不动（fake_core 调用表断言没有跨 agent 的 disconnect/connect）。

### 裁定 B（可选，若所有者确要「只影响当前会话」的动作；属新功能）

**新增一个 session 作用域的动作（建议放 ≡ 菜单，名如 `Restart this session` / 「重新载入本会话」），与 agent 级 `Reload Agent` 并存；不替换。** 语义 = `session/cancel`（若在跑）→ `session/close` → `session/load|resume`，等价于「在同一个 agent 进程内重建这条会话」。

- **能力门**（规则 2，读 `agentCapabilities`，不按名字）：`sessionCapabilities.close` **且**（`loadSession` 或 `sessionCapabilities.resume`），且该会话当前是 `attached`（与 iteration-19 的 `canSuspendSession` 同门，`session_attach.dart:167-173`）；不满足就整行不渲染并给出理由。
- **必须写明**：不重启 agent 进程，**不会让 registry 升级后的版本生效**（那要 `Reload Agent` 或重开应用）。
- **复用现有原语，不新增机制**：`closeSession`（`session_controller.dart:633-647`）、`resumeSession`（`:607-624`）、`ensureLoaded`/`loadSession`（`session_attach.dart:199/268`）、`_releaseSessionRequests`（`:657+`）都在；本动作基本是「关掉再挂回」的组合。
- **pi / cursor 等不满足能力门的 agent 就不出这个入口**；pi 上游 load 会 `closeAllExcept` 的行为另向上游反馈（不进本表，`rounds/BACKLOG.md:48`）。
- **开工前先改设计稿**：画板没有这个入口，按规则 3 先出画板再进轮次。
- **验收**（对齐 BACKLOG ④）：① 同 agent 两条并跑会话只重建目标那条，另一条的 `attach` 状态与在途 `session/prompt` 不受影响（fake_core 调用表只出现目标 id 的 cancel/close/load|resume）；② 跨 agent 会话不受影响；③ 能力不足时不显示 / 给出理由；④ 恢复失败（load 返回错误）时旧转录原样保留、不静默新开一条、错误可见；⑤ 若目标会话正在跑，动作先 cancel、转录以「被取消」而非「失败」收尾。

### 明确不建议

- **不建议**把 Reload 改成 session 级（会让画板 53 升级流程静默失效）。
- **不建议**为「真正的 session 级进程重启」改成每 agent 多条连接 / 每会话一个 agent 进程：核心连接表按 agentId 单键（`core.rs:35`），协议无会话跨连接迁移原语，属结构性改动且会成倍增加进程与认证/MCP 启动成本。
- **不建议**在 agent 级 Reload 里顺手把该 agent 名下所有会话都重新 `session/load`：在途工作照样丢，长会话重放更重，pi 上还会互相 `closeAllExcept` 抖动；如要做须单独裁定。

---

## 6. 命令证据（可复跑）

```bash
# 1) 协议里没有 reload/restart 原语
cd vendor/upstream/agent-client-protocol
grep -o '"x-method": "[a-z/_]*"' schema/v1/schema.json | sort -u
grep -rn -i "reload\|restart" schema/v1/schema.json docs/protocol/v1/*.mdx docs/protocol/v1/draft/*.mdx

# 2) 客户端调用链
grep -n "reloadAgent\|onClearAgentQueues\|agentDisconnect\|_connectOnce\|connectionReplaced" \
  lib/app/session_controller.dart lib/app/session_attach.dart lib/app/turn_controller.dart lib/app/workbench_screen.dart
grep -n "Reload this session\|Reload Agent\|重启 agent" \
  lib/ui/shell/session_header.dart lib/ui/popovers/topbar_popovers.dart lib/ui/shell/agent_state_bar.dart

# 3) 核心连接粒度
grep -n "agents: Mutex<HashMap\|pub async fn agent_connect\|pub async fn agent_disconnect" rust/acp-core/src/core.rs

# 4) 各 agent 能力声明
grep -n "sessionCapabilities\|loadSession: true" vendor/upstream/claude-agent-acp/src/acp-agent.ts vendor/upstream/codex-acp/src/CodexAcpServer.ts
grep -n "sessionCapabilities: {" -A6 vendor/upstream/pi-acp/src/acp/agent.ts
grep -n "sessionCapabilities:" -A6 vendor/upstream/dsh-acp-interactive/src/index.ts

# 5) Zed 参照（本地参考副本）
cd /d/variFlight_work/_references/zed && git log -1 --format=%H
grep -n "fn restart_connection\|fn retry_connection" crates/agent_ui/src/agent_connection_store.rs crates/agent_ui/src/conversation_view.rs

# 6) 内置 Zed agent 已移除
sed -n '1,6p' docs/zed-agent.md
git log --oneline -1 791d2ee
grep -n "zed" pins/upstream.json            # 无命中
ls sidecar 2>/dev/null                       # 不存在
```

---

## 7. 文件:行号索引（本报告引用）

| 主题 | 位置 |
|---|---|
| reload 主体 | `lib/app/session_controller.dart:540-583`（清队列 `:546`、disconnect `:563`、重连 `:566`、只 load 当前 `:567/571`、失败新开 `:575`） |
| 清某 agent 全部队列 | `lib/app/turn_controller.dart:358-365`（绑定 `lib/app/workbench_controller.dart:69`） |
| 在途轮失败收尾 | `lib/app/turn_controller.dart:196-213`、`:221-235` |
| 连接换代 → 全部挂空 | `lib/app/session_controller.dart:497`（`connectionReplaced`）、`lib/app/session_attach.dart:117-121` |
| 懒挂回 | `lib/app/session_attach.dart:199-246`（ensureLoaded）、`:259-285`（reattach）、`:317-345`（load 失败退路） |
| 会话级动作现有实现 | `closeSession` `lib/app/session_controller.dart:633-647`；`resumeSession` `:607-624`；能力门 `canSuspendSession` `lib/app/session_attach.dart:167-173` |
| 能力读取（不按名字） | `lib/app/session_controller.dart:343-357` |
| tooltip / 菜单 / 状态条 | `lib/ui/shell/session_header.dart:124`、`lib/ui/popovers/topbar_popovers.dart:326`、`lib/ui/shell/agent_state_bar.dart:102` |
| 升级要 Reload 才生效 | `docs/design.md:133`、`lib/ui/registry/registry_entry.dart:170-173`、`design/round-design/53-registry-upgrade.dc.html:80` |
| core 连接表 / 断开粒度 | `rust/acp-core/src/core.rs:35`、`:146`、`:262-296`；`rust/acp-core/src/agent.rs:1160`、`:1225-1245` |
| 桥接口 | `lib/app/core_bridge.dart:57-68`、`rust/bridge/src/api.rs:130-170` |
| spec 无原语 / 语义 | `vendor/upstream/agent-client-protocol/schema/v1/schema.json`（x-method 清单、`:4363-4367`）、`docs/protocol/v1/session-setup.mdx:83-104/190-213/243/255-278` |
| agent 能力与行为 | claude `acp-agent.ts:2061-2069/2099/2156-2186/6392-6398/7673-7705`；codex `CodexAcpServer.ts:340-347/361/774-817/859-892/1019-1055`、`CodexAcpClient.ts:530-549/570-605/636-642`；pi `agent.ts:254-268/377/930-963`、`session.ts:180-184`；dsh `index.ts:524-540/811-819/918-965` |
| Zed 参照（连接级 restart） | `crates/agent_ui/src/agent_connection_store.rs:127-141`、`crates/agent_ui/src/conversation_view.rs:985-1004`、`crates/agent_ui/src/agent_panel.rs:13505-13540`（本地副本 commit `d9e1c02`） |
| 内置 Zed agent 已移除 | `iterations/iteration-16.md:1`、`docs/zed-agent.md:1-6`、`pins/upstream.json`（无 zed）、`rust/acp-core/src/builtin.rs:1` |

---

## 8. 未核实 / 需要所有者或运行时确认的点

1. **cursor** 及各 registry agent 的实际 `sessionCapabilities`：仓库无源码，须在 Windows 实机连上后读 `initialize`（或看流量面板 / `logs/acp-*.log`）；本报告只给了「能力驱动」的判据，没有实测值。
2. **claude/codex 的 close→load 组合是否 100% 重建运行时**：源码路径支持（claude `teardownSession` 后重建；codex `threadUnsubscribe` 后 `threadResume`），但**未在 Windows 实机对「正在跑的会话 close 再 load」做往返实测**；若要落地 session 级动作，验收必须实测这条（BACKLOG ④ 第 4 点）。
3. **pi 上游的 `closeAllExcept`** 是否会在新版修掉：不在本项目控制范围，按 `rounds/BACKLOG.md:48` 另向上游反馈。
4. 会话头 reload 在**当前会话正在跑**时点下去的行为：`reloadAgent` 只挡 `waitingForAgent / attachInFlight / _connecting`，不挡「当前会话有在途轮」；所以点下去当前会话那一轮同样会被杀、队列被清。这一点与「只重载当前会话」的直觉也不符，属裁定 A 文案里要一起说清的影响范围（未做额外实测）。
