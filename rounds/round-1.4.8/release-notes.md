v1.4.7 之后合入 `main` 的两项：侧栏 Active 区的会话行多了「挂起」——点一下把这条会话交还 agent（`session/close`），转录留着只读、行从 Active 沉到 History，回头点 History 里那一行由 `session/load`（退 `resume`）挂回来；`session/close` 以前只在 R6 接通了协议与单测、产品里一直没有入口（BACKLOG P1「会话菜单的 Resume / Close 没有入口」，本版关闭该条）。另一项是开发规范正本从 `CLAUDE.md` 迁到跨 agent 的 `AGENTS.md`、上一代的工程记忆整批内联到 `docs/agent-notes/`、审查执行器收窄为「cursor 硬失败就停下喊人」。挂起经 cursor（`grok-4.7-high-fast`）三轮审到 0 条，细目见 [`iterations/`](https://github.com/ClickPM/AcpAgentClient/blob/v1.4.8/iterations/iteration-19.md)。

## 下载哪一个

| 文件 | 体积 | 说明 |
|---|---|---|
| `AcpAgentClient-1.4.8-setup.exe` | 38.0 MB | **一般选这个**。per-user 安装，装进 `%LOCALAPPDATA%\Programs\AcpAgentClient`，不要管理员权限 |
| `AcpAgentClient-1.4.8-windows-x64.zip` | 46.2 MB | 免安装，解压即用 |

Windows 10 / 11 x64。其余 agent（Claude Agent、Codex、Cursor、pi、DeepSeek Harness）走 ACP registry 在应用内安装，npx 型的需要系统 Node ≥ 22（没有的话应用会下载一份受管 Node 到自己的数据目录）。

**安装包没有代码签名**，SmartScreen 首次会拦一下：「更多信息」→「仍要运行」。用户数据在 `%APPDATA%\AcpAgentClient`，卸载不会删它。

SHA-256：

```
f24dec8f1be113fe4a447fd0803eab30a1c421a06447dd18fa0b020ec57055e3  AcpAgentClient-1.4.8-windows-x64.zip
9f35225f692500fd760913bbca1c6b8ec398bb8d0671387ba2a607ed25234805  AcpAgentClient-1.4.8-setup.exe
```

## 变更

### 侧栏 Active 行的「挂起」：把会话交还 agent（iteration-19，画板 45 § ②）

- **点一下交还 agent**：挂起 = `session/close` —— 先 cancel 掉这条会话正在进行的工作（规范要求 agent 照 `session/cancel` 处理）再释放它占的资源，**不删**记录。本地转录留着**只读**，索引不动。
- **沉到 History、点回来**：挂起后这条会话不在连接上了，侧栏的分组判定（`attachedSessionIds`）当场就把它从 Active 分到 History —— 前端不需要另记一个「挂起中」的状态，一个协议动作同时完成了分组搬家；再点 History 里那一行走既有的 `selectSession` → `ensureLoaded` 挂回来（声明 `loadSession` 的 agent 重放历史，否则退 `session/resume`）。
- **按钮只出现在能挂起的行上**：只给 Active 行，且**这条会话自己的** agent 声明了 `sessionCapabilities.close` **并且**挂得回来（`loadSession` 或 `resume`）时才出。判据是会话能力、不是 agent 名（规则 2）。只有 close、挂不回来的 agent 干脆不给入口 —— 那关掉之后是「从此只读」，不是挂起；没声明 `close` 的 agent（实测 pi-acp）与 History 行照旧，只有改名 / 删除两枚。
- **后台会话也能挂**：挂起传的是那一行的 id，目标 agent 按这条会话自己的登记取（不读当前连接），所以挂起一条后台会话不会碰当前选中态与输入框。
- **顺带修掉的文案**：被挂起后按发送键，提示以前一律说「用 ≡ 菜单的 Resume 挂回来」，而那个入口产品里从来没有 —— 现在按能不能挂回来的两种原因分开说（agent 侧已经没有这条 / agent 不支持挂回来）。
- **挂起一条正在跑的会话是允许的**：那几秒里 History 行上还挂着运行中的扫掠线属正常，agent 收轮（`cancelled`）就到头，与「停止方块」同一条收尾路径。
- 补 6 条往返与能力门用例（`test/ui/sidebar_suspend_test.dart`）、3 条关闭态提示用例；回补画板 45 § ② 与规格表（Active 行的第三枚行内图标）、画板 04 的注记，PNG 已重渲染。
- Resume 仍不做单独入口：侧栏点开一条会话本来就是 load / resume 自动选一条，用途被覆盖（BACKLOG P1 的结论）。

### 开发规范与工程记忆去 Claude Code 绑定（iteration-20）

- 规范正本从 `CLAUDE.md` 迁到跨 agent 的 `AGENTS.md`（Codex / Cursor / DSH / pi / Zed 原生就读它），`CLAUDE.md` 退成 3 行指针；代码注释与脚本里的活引用改写 53 个文件 / 83 处，历史记录（已收口轮次卡、`BACKLOG-CLOSED`、已收口迭代文件、进度表、画板源）原样保留并在顶部留别名映射。
- 审查执行器收窄：cursor CLI 硬失败（未安装 / 未登录 / 启动失败 / 限流 / 后台进程已死而 `.out` 仍空）**停下来喊人，不自动回落任何子代理**；只有所有者点名才换，且换成只读、模型独立于主会话的。
- 上一代 agent 的项目私有记忆整批内联入库成 [`docs/agent-notes/`](https://github.com/ClickPM/AcpAgentClient/blob/v1.4.8/docs/agent-notes/README.md)（索引 + 8 份主题册 + 1 份执行器专属坑）：构建缓存怎么清、worktree 与并行会话怎么建拆、发版流水线、审查与真跑踩过的坑、所有者的裁定习惯都在那里。
- 只动文档与代码注释，**无 Dart / Rust 逻辑变更**，经所有者指定免审。

### 验收

release worktree（`f4e5e57`，纯 ASCII 路径）上完整 `validate.ps1` **17 道门全绿**、`flutter test` **622 项**；`package.ps1` 出包后 `verify-package.ps1` 跑 zip 解压运行与安装器静默安装 → 运行 → 卸载，**VERIFY OK**，banner 与 `coreVersion` 均为 `1.4.8`。
