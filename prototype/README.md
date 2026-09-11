# prototype

**这里的东西不是设计稿，也不是产品代码。** 它是开工前用来验证「严格 ACP 投影」能不能成立的一次性原型：把 ACP 线上消息喂进一个投影状态机，看转录里长出什么。

- **样式不作数。** 功能边界与视觉一律以 `design/` 的画板为准（CLAUDE.md 规则 3）。原型用的是中性的开发者工具样式，只为看清结构，不要拿它当 UI 参照。
- **不进构建。** 纯 HTML + CSS + JS，无框架、无依赖、无构建步骤，双击 `session-projection.html` 即可跑。
- **可以丢。** R2 会话工作台按画板实现之后，这里的价值就只剩「状态机的参考实现」。

## session-projection.html — ACP 会话投影原型

回答的问题：[`docs/acp-projection.md`](../docs/acp-projection.md) 列的 15 个 `session/update` 变体 + 权限 + elicitation + 终端 + 5 种内容块，**投影到界面上到底是什么样，够不够，哪里不够**。

打开后按「播放」，它会回放一段合成的 ACP 会话（客户端拉起 dsh-acp-interactive，让它给 `scripts/validate.ps1` 加一项校验）。左栏是会话级状态，中栏是转录，右栏是线上流量。

### 这段回放专门覆盖了这些点

| 点 | 在原型里怎么看 |
|---|---|
| 15 个变体全覆盖 | 右栏流量按变体打标；左栏「已投影变体」逐个点亮 |
| 新声明的 `plan` 能力 | 稳定 `plan` 之外，还有 `plan_update`（items 载荷）与 `plan_removed` |
| 新声明的 `session.compaction` | 压缩卡片：in_progress → 两段 `compaction_summary_chunk` → completed |
| `notice` 被丢弃（裁定的兜底方案） | 流量里标红「丢弃」，左栏丢弃计数 +1，转录里**什么都不出现** |
| 未知的未来变体 | 同上，用一个假想的 `artifact_update` 演示 |
| 工具调用合并语义 | `content` / `locations` 是**替换**不是追加，看 read 那张卡的三次更新 |
| 集合项跳过（`VecSkipError`） | 有一次 update 的 `content[]` 里混了未知类型，只丢那一项，卡上标「跳过 1 项」 |
| 未知 `kind` 回落 | 一次 `kind: "sculpt"` 落到 `other` |
| 凭空建卡 | 一条 `tool_call_update` 的 id 此前没出现过，直接建卡 |
| 客户端本地的「已取消」 | 流播放中点「取消本轮」：未完成的工具卡变 cancelled（协议里**没有**这个状态） |
| 权限请求 | 流会停下等你选；不选就不往下走 |
| elicitation（form 模式） | 同上，渲染受限 JSON Schema 的表单 |
| 终端 | 输出是**本地流**不是协议消息（流量里标 local）；`terminal/release` 之后输出仍然留在卡上 |
| 5 种内容块 | 最后一条消息里 text / image / audio / resource_link / embedded resource 各一 |
| 消息分组 | `messageId` 变了就另起一条气泡；没有 `messageId` 时按角色连续合并 |
| 轮边界 | 客户端自己切的，不是协议给的 |
| 密钥打码 | `session/new` 的 MCP 头与终端 env 里的 token 在流量面板里是 `***` |

### 目录

```text
prototype/
├── README.md
├── session-projection.html
└── assets/
    ├── projection.css      样式（不作数）
    ├── fixtures.js         合成的 ACP 线上流（wire script）
    ├── projection.js       投影状态机 —— 这一份是有参考价值的部分
    └── app.js              播放器与渲染
```

`projection.js` 刻意不碰 DOM：它只吃线上 JSON、吐状态。R0/R1 往 Rust + React 搬的时候，搬的是它的规则，不是它的代码。
