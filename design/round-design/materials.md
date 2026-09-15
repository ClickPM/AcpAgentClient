# round-design 设计原料

> 本文是设计轮的事实底稿：来源清单、演示入口黑名单、**画板清单（编号在此锁定）**、覆盖矩阵、审核清单、疑点。
> 喂给 Claude Design 的是 `input/` 整个目录（简报 `input/design-prompt.md` 与附件，用法见 `input/README.md`）；两处不一致时以本文为准并回去改简报。

## 0. 本轮流程

1. 主会话写好 `input/` 输入包（简报、原型与截图副本、两份参考、`canvas.json`、使用说明）与本文（本轮交付物）。
2. 所有者把 `input/` 整个目录交给 Claude Design，按画布分页 P1 → P4 出稿，可分多次。
3. 所有者提供画布链接，主会话按 § 5 审核，findings 回填 `rounds/round-design/round-design.md`。
4. 整改收口后：`.dc.html`、`canvas.json`、`support.js` 入库到 `design/round-design/`，PNG 由 `scripts/render-design.ps1` 从入库的 `.dc.html` 渲染（headless Edge，scale 1，尺寸 = `$preview`），`design/README.md` 索引填齐，状态 `待实现`。画布自带的 PNG 导出件不作基准：它的字体度量与浏览器不同，会出现假换行与假截断。

## 1. 来源清单

| 来源 | 用途 | 位置 |
|---|---|---|
| 界面骨架原型 | 信息层级与交互的唯一来源；上传给 Claude Design | `prototype/index.html` |
| 壳的两种布局截图 | 右栏折叠 / 展开时的三栏比例 | `prototype/assets/mockplus-default-view.png`、`mockplus-expanded-view.png` |
| 会话区 22 项交互表 | 转录卡片清单与各自的投影来源（所有者 2026-09-14 照 Zed Agent 实测截图定） | `prototype/README.md` § index.html |
| 可投影内容清单 | 覆盖上限：15 个 `session/update` 变体、4 个投影面、7 项客户端自造态、5 种内容块 | `docs/acp-projection.md` |
| 契约与页面清单 | `acp/*` 事件、认证流程、registry 安装流程、五个页面、数据目录 | `docs/design.md` § 3 / § 5 / § 6 / § 9 / § 10 |
| 必须与不做 | 范围边界 | `docs/requirements.md` |
| Zed One Light 色板 | 「同一色系」的参照锚点 | `vendor/upstream/zed/assets/themes/one/one.json`，抽取值见下 |
| Notion 参照值 | 纸感与 hover 叠色的参照锚点 | 底色 `#ffffff`、侧栏 `#f7f6f3`、正文 `#37352f`、hover `rgba(55,53,47,0.08)` |
| 输入包 | 上面各项交给 Claude Design 的副本（原型、截图、22 项表节选、可投影清单快照）加 `canvas.json` 与使用说明 | `design/round-design/input/` |

Zed One Light 抽取值（钉版本源码，2026-09-14 抽取）：

| 角色 | 值 |
|---|---|
| editor.background | `#fafafa` |
| panel / surface / elevated_surface | `#ebebec` |
| title_bar / status_bar | `#dcdcdd` |
| border / border.variant | `#c9c9ca` / `#dfdfe0` |
| text / text.muted / text.placeholder | `#242529` / `#58585a` / `#7e8086` |
| element.hover / element.active / selected | `#dfdfe0` / `#cacaca` / `#cacaca` |
| text.accent / icon.accent / info | `#5c78e2` |
| error / warning / success | `#d36151` / `#a48819` / `#669f59` |

要取的是方法：整条中性色阶同一色相、一个强调色、语义色明度与饱和度对齐；不照抄数值。

## 2. 演示入口黑名单（设计稿零出现）

原型里只为逐项验收存在的东西，设计稿任何画板不得出现：

| 原型元素 | 位置 | id / class |
|---|---|---|
| `载入投影样例` | 转录区顶部工具条 | `txReplayBtn` |
| `清空会话` | 同上 | 同一工具条 |
| `全部展开` | 同上 | `txExpandAllBtn` |
| `投影来源`（给每个块打 ACP 变体标签） | 同上；标签本身 | `txOriginBtn`、`.tx-origin` |
| `投影清单 22`（逐项跳转高亮） | 同上；弹层 | `txIndexBtn`、`txIndexPopover` |
| 「要看 22 项 ACP 投影样式，点上方的『载入投影样例』」 | 空态提示第二行 | 空态文案 |
| 整条转录区顶部工具条本身 | 线程头之下 | 工具条容器 |

以下**不是**演示入口，是产品功能，必须保留：`txStopTurnBtn`（停止本轮）、`txScopeBtn`（权限范围下拉）、`txUsageBtn`（用量圆环）、`txPendingBar`（Awaiting 悬浮条）、`txPlan`（计划卡）、`txTurnEnd`（回合结束行）、`Restore Checkpoint` 分隔线。

## 3. 画板清单（编号锁定，只增不改）

frame：整页画板宽 1440（页面容器 1440×900）；转录卡片宽 800；弹层合集宽 1200；画板高按状态数与注释顺延，`.dc.html` 里的 `$preview` 高 = PNG 高（第 2 轮审核对 F2 取方案 ①，2026-09-14）。文件名 `NN-<英文短名>.dc.html`。

| 编号 | 文件 | 名称 | 页面 | frame | 投影来源 |
|---|---|---|---|---|---|
| 00 | `00-tokens` | Token 表 | 全局 | 1440×900 | 无（样式源） |
| 01 | `01-workbench-empty` | 工作台 · 新会话 | 会话工作台 | 1440×900 | `initialize` 能力驱动的可用动作；`session_info_update` 标题 |
| 02 | `02-workbench-running` | 工作台 · 进行中的一轮 | 会话工作台 | 1440×900 | 回合进行中的组合态 |
| 03 | `03-workbench-done` | 工作台 · 回合结束 + 右栏展开 | 会话工作台 + 文件面板 | 1440×900 | end-turn `usage`、`plan` 折叠 |
| 04 | `04-sidebar-states` | 侧栏与顶栏状态 | 会话工作台 | 1440×900 | `session/list`、客户端本地时间戳 |
| 10 | `10-checkpoint` | Restore Checkpoint 分隔线 | 转录 | 800 | 客户端本地态 |
| 11 | `11-user-message` | 用户消息气泡 | 转录 | 800 | `user_message_chunk`、消息分组 |
| 12 | `12-assistant-text` | 助手富文本正文 | 转录 | 800 | `agent_message_chunk · text` |
| 13 | `13-code-block` | 代码块卡片 | 转录 | 800 | 同上 |
| 14 | `14-gfm-table` | GFM 表格 | 转录 | 800 | 同上 |
| 15 | `15-mermaid` | Mermaid 图 | 转录 | 800 | 同上（客户端渲染） |
| 16 | `16-math` | 数学公式 | 转录 | 800 | 同上 |
| 17 | `17-thinking` | 思考折叠块 | 转录 | 800 | `agent_thought_chunk`、折叠单元本地态 |
| 18 | `18-tool-call` | 标准工具调用卡 | 转录 | 800 | `tool_call` + `tool_call_update`、`kind`、`status`、`locations` |
| 19 | `19-tool-failed` | 工具调用失败卡 | 转录 | 800 | `status: failed` |
| 20 | `20-tool-cancelled` | 工具已取消卡 | 转录 | 800 | 客户端本地态 |
| 21 | `21-diff-card` | 文件差异对比卡 | 转录 | 800 | `tool_call.content[] · diff`（只读） |
| 22 | `22-terminal-card` | 嵌入式终端控制台卡 | 转录 | 800 | `tool_call.content[] · terminal`、release 后留存 |
| 23 | `23-terminal-running` | 终端进行中卡 | 转录 | 800 | `terminal/*` 本地流、`terminal/kill` |
| 24 | `24-subagent` | 子代理委派卡 | 转录 | 800 | `tool_call · _meta.claudeCode.subagent`（见 § 6） |
| 25 | `25-permission` | 权限授权卡 | 转录 | 800 | `session/request_permission`、四种 `kind` |
| 26 | `26-awaiting` | Awaiting Confirmation | 转录 + 输入框上方 | 800 | 客户端本地态 |
| 27 | `27-elicitation-form` | 表单模式交互卡 | 转录 | 800 | `elicitation/create · form`（string / enum / array / number / boolean） |
| 28 | `28-elicitation-url` | 链接跳转交互卡 | 转录 | 800 | `elicitation/create · url`、`elicitation/complete` |
| 29 | `29-plan` | 计划卡 | 转录 | 800 | `plan`、`plan_update`（items / file / markdown）、`plan_removed` |
| 30 | `30-context-window` | 上下文窗口浮窗 | 输入框 | 800 | `usage_update`（used / size / cost） |
| 31 | `31-turn-state` | 回合态与结束 | 线程头 + 输入框 + 转录 | 800 | `stopReason` 五种、end-turn `usage`、`session/cancel` |
| 32 | `32-content-blocks` | 非文本内容块 | 转录 | 800 | `ContentBlock` image / audio / resource_link / resource |
| 33 | `33-compaction` | 上下文压缩卡 | 转录 | 800 | `compaction_update`、`compaction_summary_chunk` |
| 34 | `34-agent-state` | agent 状态与错误 | 线程头下 / 转录 | 800 | `acp/agent_state`、未知变体丢弃告警、JSON-RPC 错误码 |
| 40 | `40-composer-popovers` | 输入框弹层合集 | 会话工作台 | 1200×800 | `config_option_update`（select 扁平 / 分组、boolean、未知分类）、`current_mode_update`、`usage_update` |
| 41 | `41-topbar-popovers` | 顶栏与侧栏弹层合集 | 会话工作台 | 1200×800 | `session/new`（选 agent）、会话索引 |
| 42 | `42-inline-menus` | 输入框内联菜单 | 会话工作台 | 1200×800 | `available_commands_update`、`@` 提及（promptCapabilities） |
| 50 | `50-registry` | Agents 面板（ACP Registry） | agent 管理 | 1440×900 | registry.json、安装状态 |
| 51 | `51-registry-states` | Registry 条目状态 | agent 管理 | 1200×800 | npx / binary 安装流程、受管 Node、`uvx` 暂不支持、custom |
| 52 | `52-auth` | agent 认证 | agent 管理 | 1200×800 | `authMethods`（agent / terminal 型）、`auth_required`、`-32000` |
| 60 | `60-files-panel` | 文件面板 | 文件面板 | 1440×900 | `fs_list_dir` / `fs_read` / `fs_search`、文件定位 |
| 61 | `61-terminal-panel` | 终端面板 | 文件面板（右栏） | 1440×900 | `acp/terminal_output`、terminal auth |
| 70 | `70-settings` | 设置 | 设置 | 1440×900 | `agent_settings_get/set`、`agent_settings_import_zed`、Node、数据目录 |
| 80 | `80-traffic` | ACP 流量调试 | ACP 流量调试 | 1440×900 | `acp/traffic`（脱敏）、丢弃计数、stderr 尾巴 |

共 40 张。画布分页：P1 = 00 到 04；P2 = 10 到 34；P3 = 40 到 42；P4 = 50 到 80。

## 4. 覆盖矩阵（`docs/acp-projection.md` → 画板）

| 投影面 | 项 | 画板 |
|---|---|---|
| A 会话流 | `user_message_chunk` | 11 |
| A | `agent_message_chunk` | 12、13、14、15、16、32 |
| A | `agent_thought_chunk` | 17 |
| A | `tool_call` | 18 |
| A | `tool_call_update`（合并、替换语义、凭空建卡） | 18、19、20、21、22、23、24 |
| A | `plan` | 29 |
| A | `available_commands_update` | 42 |
| A | `current_mode_update` | 40 |
| A | `config_option_update`（select / boolean / 未知分类） | 40 |
| A | `session_info_update` | 01、04（线程头与会话项标题、时间） |
| A | `usage_update` | 30 |
| A | `plan_update`（items / file / markdown） | 29 |
| A | `plan_removed` | 29 |
| A | `compaction_update` | 33 |
| A | `compaction_summary_chunk` | 33 |
| A | `notice` 与未知变体（丢弃 + 告警） | 34、80 |
| A 内容块 | text / image / audio / resource_link / resource | 12、32 |
| B 请求 | `session/request_permission`（四种 kind、cancel 后回 cancelled） | 25、26、31 |
| B | `elicitation/create · form` | 27 |
| B | `elicitation/create · url` + `elicitation/complete` | 28 |
| B | requestScope 的 elicitation（无会话时） | 52 |
| C 回调 | `fs/read_text_file` / `fs/write_text_file` | 80（流量可见）、21 |
| C | `terminal/*`（create / output / wait / kill / release） | 22、23、61 |
| D 状态 | `initialize` 能力驱动可用动作 | 01（无能力时不显示的动作以注释标明） |
| D | `authMethods` agent / terminal 型 | 52 |
| D | modes 与 configOptions（configOptions 优先） | 40 |
| D | `session/list` / `load` / `resume` / `close` / `delete` | 04、41 |
| D | `stopReason` 五种 | 31 |
| D | 错误码（`-32000` 需认证等） | 34、52 |
| 自造 7 项 | 已取消态 | 20、31 |
| 自造 | 消息边界与分组 | 11、12 |
| 自造 | 时间戳 | 04、31 |
| 自造 | 先到的 `tool_call_update` | 18（无视觉差异，注释标明） |
| 自造 | 终端释放后留存 | 22 |
| 自造 | 思考折叠单元 | 17 |
| 自造 | 每轮边界 | 10、31 |
| 页面 | 会话工作台 / agent 管理 / 文件面板 / 设置 / ACP 流量调试 | 01–04 / 50–52 / 60–61 / 70 / 80 |

## 5. 审核清单（拿到画布链接后逐条核）

1. **黑名单零出现**：§ 2 的文案与元素在 40 张画板里 0 命中（`.dc.html` 入库后 grep 一遍复核）。
2. **清单完整**：§ 3 的 40 张全部存在，编号、文件名、名称一致，没有多余画板；多出的想法只以便签注释出现。
3. **覆盖矩阵**：§ 4 每一行都能在对应画板里指出来。
4. **风格硬约束**：圆角 ≤ 6 且只有 3 / 4 / 6；按钮默认无边框无填充、悬浮出深色容器；主按钮仅强调色填充；色相 ≤ 5；无渐变、模糊、emoji、左侧彩条；阴影只在弹层；字阶只有 11 / 12 / 13 / 15 / 20。
5. **token 一致性**：抽 01、18、25 三张，逐个数值对照 00-tokens，无表外值。
6. **frame 尺寸**：整页 1440×900，卡片宽 800，合集 1200×800。
7. **既定裁定**：无 Edits 审阅条；21 只读；文件定位落右栏文件面板。
8. **文案**：原型文案未翻译未润色；无 lorem ipsum；未编造硬数据。
9. **深色**：00-tokens 含深色中性色阶与强调色。
10. **渲染**：每画板一张 PNG，由 `scripts/render-design.ps1` 生成，尺寸 = `$preview`。

审核产出：findings 逐条（画板号 + 问题 + 建议），回填任务卡「代码审查」段；采纳的改动由所有者在画布改或主会话改 `.dc.html` 后再入库，收口标准是 1 到 3 全过、4 到 10 无 high。

## 6. 疑点（不阻塞出稿，实现前裁定；已记 `rounds/BACKLOG.md`）

- 画板 24 子代理卡依赖 `_meta.claudeCode.subagent`，与 CLAUDE.md 规则 2「无 agent 特判」及 `docs/design.md` § 4 的 `_meta` 键清单有张力；设计照原型出。
- 文件树上的 git 状态徽章（原型里的 `M`）不在任何文档里；设计照原型出。
- 画板 70 设置只按 docs 列四块，没有外观设置；要加先改设计稿。
- 深色主题本轮只在 00-tokens 出色阶，页面画板不出深色。
- 字体默认 Geist / Geist Mono，实现时作为资产打包；CJK 回退实现里指 Microsoft YaHei UI / PingFang SC。
