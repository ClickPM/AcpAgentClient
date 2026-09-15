# R1.5 富文本渲染 spike —— 对比记录与裁定建议

> 分支 `round-01.5`（worktree，不合并）；实测 2026-09-15，Windows 11 26200，Flutter 3.47.4 / Dart 3.13.3。
> 所有候选渲染**同一份语料**（画板 12 / 13 / 14 / 16 的原文拼接，1,812 字符）、同一份 tokens 主题、同一宽度（800；CJK 窄列 360），截图在 [`shots/`](shots/)，原始测量在 [`data/`](data/)，复现命令在 § 10。
> 裁定门写法沿用 ROUNDS.md：每项**一个加粗的推荐 + 备选 + 一句理由**；裁定结果写回 CLAUDE.md 规则 1 与 `docs/requirements.md` § 8（§ 9 有改动稿）。

## 0. 结论先行

| # | 需求（画板） | 推荐 | 备选 | 一句理由 |
|---|---|---|---|---|
| 1 | Markdown / GFM（12、13、14、60） | **`package:markdown` 7.3.1 解析 + 自写渲染** | `flutter_markdown_plus` 1.0.12 | 四个库都要靠 builder 覆盖代码块 / 复选框 / 公式才能贴画板，覆盖完剩下的只有「解析 + 段落排版」：解析器 `package:markdown` 是 Dart 团队维护的，段落排版 spike 里约 390 行、样式全部从 tokens 来、没有第三方结构要绕，白名单只多一个解析器。④ 是同一解析器的成熟渲染层，若不想维护这约 400 行就选它（§ 2.6 列了代价）。流式成本与稳定性两者接近（§ 2.3），不是决定因素 |
| 2 | 代码高亮（13、60） | **`re_highlight` 0.0.3** | `highlight` 0.7.0（markdown_widget 自带） | hljs 11.9 语法：powershell / dart / rust / json 四段都着色正确；`highlight` 0.7 是 hljs 10（2021），powershell 几乎不着色、dart 只认一半（§ 3） |
| 3 | 数学公式（16） | **`flutter_math_fork` 0.7.4** | 只做源码态（改画板 16） | 行内 + 块级 + 矩阵 / 分式 / 根号都对，错误公式经 `onErrorFallback` 回落源码；唯一成熟的纯 Dart TeX 渲染器（§ 4）。附带事项：它传递依赖 `provider`（状态管理库），要所有者明确「传递依赖不算规则 1 的引入」 |
| 4 | Mermaid（15） | **(d) `mermaid_flutter` 0.3.0 + `mermaid_core` 0.3.0** | (b) 只做源码态 + 复制，改画板 15 | ROUNDS 拆解时 Dart 没有成熟渲染器，2026-09-08 出的 mermaid.js 纯 Dart 移植把画板 15 的 graph TD（含 CJK 与全角括号）一次渲染正确（§ 5）；(a) WebView 与「不依赖 WebView2」冲突且 Windows 侧无官方实现；(c) 自写不做 |
| 5 | 音频（32） | **`audioplayers` 6.8.1** | 不可渲染兜底卡（改画板 32） | Windows 真机：内存 base64 WAV 直接 `BytesSource` 播放，duration / position / complete 事件齐，pause / resume / seek 正确（§ 6）；`just_audio` 官方无 Windows 实现，排除。代价：13 个直接依赖 + Dart 3.13.3 下要 `objective_c` override（§ 8） |
| 6 | diff（21） | **`diffutil_dart` 5.0.0** | `diff_match_patch` 0.4.1 | 行级 Myers、零依赖、2026-06 仍在发版；5,000 行 3.7 ms、20,000 行 17.7 ms、2,000 行全异 41.5 ms，对手分别 8.8 / 50.9 / 564 ms 且行模式要自己把行映射成字符（§ 7） |

不改画板：按推荐项裁定后画板 15 与 32 都不用改设计稿。

## 1. 方法

- **语料**：`lib/spike/corpus.dart`，逐字取自画板 12（标题 / 段落 / 有序列表 / 任务清单 / 行内代码 / 引用 / 文件链接 / 分割线 / 删除线）、13（powershell 围栏 + 长行）、14（四列对齐表格）、16（行内 + 块级公式）、15（graph TD）、21（BACKLOG 片段的旧 / 新文本）；另一段 CJK 混排（中英 + 行内代码 + 链接 + 超长英文 token）验窄列换行。
- **宿主**：`lib/spike/spike_theme.dart` —— MaterialApp + tokens 派生的主题（gpt_markdown / streamdown 从 `Theme.of` 取色，所以五个候选统一套同一份），正文 `TextStyles.body`（13 / 1.5）、代码 Geist Mono 12.5、高亮色表按画板 13 注释：accent 关键字、success 字符串、warning 类型 / 数字、placeholder 注释。
- **五个 Markdown 候选走同一个接口**（`lib/spike/candidates.dart`）：`build(text)` 一次性渲染；`buildStream(stream)` 默认「累积字符串后整体重建」（四个库的真实用法），streamdown 覆写为原生流。
- **测什么**：① 画板对照截图（`shots_test.dart`）；② 流式追加逐帧计时 + Element 是否保住（`stream_test.dart`，单独跑）；③ SelectionArea 跨块选择 + 相对路径链接回调（`select_test.dart`）；④ diff 正确性与耗时（`diff_test.dart`）；⑤ 音频 Windows 真机（一次性 app，§ 6）；⑥ 两个诊断（`mw_diag_test.dart`、`gpt_diag_test.dart`）。
- **局限**：`flutter test` 的离屏渲染是 debug 模式、无 GPU，绝对毫秒数只用于候选之间比较，不代表 release 帧时间；flutter_tester 不装包字体 / 图标字体、不做平台字体回退，截图里的方块要按 § 8 区分「测试环境让步」与「库的真缺陷」。

## 2. Markdown：五个候选

### 2.1 候选与元数据（pub.dev 2026-09-15，`data/pubmeta.json`）

| 候选 | 版本 / 发布 | 许可证 | pub 点数 / likes / 30 天下载 | 直接依赖 | 解析器 |
|---|---|---|---|---|---|
| ① `package:markdown` + 自写渲染 | 7.3.1 / 2026-03-18 | BSD-3 | 160 / 367 / 2.55 M | args, meta | 自己（CommonMark + GFM 扩展集） |
| ② `markdown_widget` | 2.3.2+8 / 2025-04-26 | MIT | 160 / 411 / 5.8 K | flutter_highlight, highlight, markdown, scroll_to_index, url_launcher, visibility_detector | package:markdown |
| ③ `gpt_markdown` | 1.2.1 / 2026-08-23 | BSD-3 | 160 / 322 / 150 K | flutter_math_fork | 自研正则组件（非 CommonMark） |
| ④ `flutter_markdown_plus` | 1.0.12 / 2026-07-10 | BSD-3 | 160 / 143 / 550 K | markdown, meta, path | package:markdown（官方 flutter_markdown 停维后的社区延续） |
| ⑤ `streamdown` | 0.1.1 / 2026-05-28 | BSD-3 | 160 / 7 / 69 | flutter_highlight, flutter_math_fork, url_launcher | 自研增量 tokenizer |

没实测的：`flutter_smooth_markdown` 0.8.1（拉 cached_network_image → flutter_cache_manager / sqflite 等重依赖，先排除）；官方 `flutter_markdown` 0.7.7+1（已停维，④ 就是它的延续）。

### 2.2 画板对照（`shots/12-14-16-<id>.png`，宽 800）

对照 `design/round-design/12-assistant-text.png`、`13-code-block.png`、`14-gfm-table.png`、`16-math.png`，看文案 / 状态 / 层级 / 控件是否缺，像素差异不算。

| 判据 | ① 自写 | ② markdown_widget | ③ gpt_markdown | ④ flutter_markdown_plus | ⑤ streamdown |
|---|---|---|---|---|---|
| 标题 / 段落 / 有序无序列表 | ✔ | ✔（h2 / h3 默认带分割线，序号紧贴文字 `1.扫描面`） | ✔ | ✔ | ✔ |
| 任务清单 | ✔（自绘复选框） | ⚠ 默认复选框在正文 13px 下算出**负内边距**（§ 8），须自带 `CheckBoxConfig.builder` | ⚠ 复选框前多画一个 `•` 项目符号，行距偏大 | ✔（`checkboxBuilder` 注入） | ✔ |
| 行内代码 | ✔ | ✔ | ✔（自家带边框芯片样式，可配） | ✔ | ✔ |
| 引用 / 分割线 / 删除线 | ✔ | ✔ | ✔ | ✔（`del` / `em` / `strong` 不显式给就没有：手写 `MarkdownStyleSheet` 缺省是 null） | ✔ |
| 文件链接（相对路径） | ✔ | ✔ | ✔ | ✔ | ✔ |
| 代码块：语言标签 + Copy + 高亮 + 横向滚动 | ✔（CodeCard） | ⚠ 默认无标签 / Copy（要 `wrapper`），高亮走 highlight 0.7（§ 3） | ⚠ 自带标签 + Copy，默认无高亮（spike 里没换 builder；`codeBuilder` 可接 CodeCard，与 ④ 同一条路） | ✔（`builders['code']` 注入 CodeCard） | ⚠ 自带标签 + 高亮（flutter_highlight），Copy 只有图标；行内 / 块内字体写死 `'monospace'`（§ 8） |
| GFM 表格：对齐 / 表头面 / 斑马纹 / 超宽横滚 | ✔ | ✔（列按内容宽） | ⚠ 表格不撑满、无斑马纹，风格可配但结构自家的 | ⚠ 默认列宽 flex 均分（窄列时单元格折行），要设 `tableColumnWidth` | ⚠ 单元格里 `_meta` 被当成强调渲染成斜体 *meta*（下划线不按 CommonMark 词内规则） |
| 公式 `$…$` / `$$…$$` | ✔（自写 InlineSyntax + flutter_math_fork） | ✔（`SpanNodeGeneratorWithTag` 接同一扩展；块级不居中） | ⚠ 块级 ✔，**行内 `$…$` 整篇失效**：`useDollarSignsForLatex` 的行内转换以全文不含 `\(` 为前提，代码块里的正则 `Color\(0x` 就把它关掉了（`gpt_diag_test.dart`：单独渲染画板 16 语料时行内正常） | ✔（`builders['latex']` 接同一扩展） | ✔（`latex: true`） |
| CJK 窄列（`shots/cjk-<id>.png`，宽 360） | ✔ 中英 / 行内代码 / 长 URL 都按字折行 | ✔ | ✔ | ✔ | ✔ |

### 2.3 流式追加（`data/stream.json`，`shots/stream-<id>.png`）

同一语料按 24 字符步长喂，逐帧计时，`stream_test.dart` 单独跑。**计时窗口 = `controller.add` 之后的 `idle` + `pump`**：①–④ 的流监听只做 setState + 写缓冲、`package:markdown` 的全量解析在 build 里（pump 内），⑤ streamdown 的增量解析在流监听里（idle 内），两段都计入五个库口径才对称（第 1 轮审查 P2 指出只计 pump 会漏掉 ⑤ 的解析，已改）。两项「先到的块是否保住」都是直接测量：**标题 Element** = 第 25% 帧时首个标题的 Element 到最后一帧仍是同一个对象；**代码块横滚** = 第 80% 帧时把最宽的横向 Scrollable 滚到 30 px，最后一帧读回是否还是 30。

| 候选 | 1× 语料 1.8 KB · 76 帧：p50 / p95 / max ms | 4× 语料 7.2 KB · 303 帧：p50 / p95 / max ms | 标题 Element | 代码块横滚位置 | 围栏已开未闭 | 表头行刚出 | 块级公式已开未闭 |
|---|---|---|---|---|---|---|---|
| ① 自写 | 12.7 / 37.3 / 213 ¹ | 28.2 / 44.2 / 72.0 | ✔ | ✔ | 立即成代码卡 | 按段落显示 `\| 检查项 \| …`，分隔行到了才成表（CommonMark 规则） | 原文 `$$\sum_{i=1}^{` |
| ② markdown_widget | 17.7 / 30.6 / 104 | 32.1 / 79.6 / 123 | ✔ | ✔ | 立即成代码卡 | 同上 | 原文 |
| ③ gpt_markdown | 24.8 / 41.4 / 61.9 | 51.4 / 102 / 144 | ✔ | ✔ | 立即成代码卡 | 同上 | 原文 |
| ④ flutter_markdown_plus | 15.1 / 28.0 / 36.6 | 39.5 / 74.2 / 109 | **✘**（每帧新建） | ✔ | 立即成代码卡 | 同上 | 原文 |
| ⑤ streamdown | 9.6 / 24.1 / 49.2 | 28.8 / 59.0 / 80.8 | ✔ | ✔ | 立即成代码卡 | 不显示，等分隔行 | 不显示，等闭合 |

¹ 213 ms 是含代码块的第一帧：re_highlight 首次高亮 powershell 时才编译该语言的语法（惰性），之后不再发生（4× 跑里 max 72 ms）。R2 可在启动时预热常用语言。

解读：
- 五个库对「围栏已开未闭」都不闪（`package:markdown` 按 CommonMark 把未闭合围栏当代码块到文末；streamdown 是设计目标）。「表头行刚出」的那一跳是 GFM 规则本身：没有分隔行就不是表。要消掉只能在渲染层做「疑似表头行先按表渲染」的启发式，四个 `package:markdown` 系候选都能在自己的层做，streamdown 内置了。
- 数字是 debug、无 GPU、单次运行，只用于横比且差距要够大才算数：4× 时 ①⑤ 一档（28 ms）、②④ 一档（32–40 ms）、③ 最高（51 ms），方向与 1× 一致；①⑤ 之间的 0.6 ms 不算差异。每帧成本随文档长度线性涨，与解析器是否增量关系不大（7 KB 量级的解析已小于整列 layout / paint），真正的解法是 `docs/design.md` § 9 已定的三件事（按帧合并 `session/update`、投影层独立、`ListView.builder` 惰性构建），任何候选都需要。
- ④「标题 Element 每帧新建」是结构性的（widget 列表无 key），但代码块横滚位置仍保住了：同一位置同一类型的 Scrollable 状态被 Flutter 按位复用。也就是说本轮测到的 ④ 与其它四者的差别只有标题 Element 身份，没有测出用户可见的后果；选区在流式中途没有单独测。③ 最高是自研正则解析逐行重扫。

### 2.4 选择复制与链接（`data/select.json`）

鼠标从内容左上拖到右下，看 `SelectionArea.onSelectionChanged` 的 `plainText`：

| 候选 | 选中字符数 | 标题 | 列表 | 代码块 | 表格单元 | 删除线 | 引用 | 链接回调带回 `docs/acp-projection.md` |
|---|---|---|---|---|---|---|---|---|
| ① 自写 | 1,452 | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| ② markdown_widget | 1,408 | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| ③ gpt_markdown | 1,586 | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| ④ flutter_markdown_plus | 1,452 | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| ⑤ streamdown | 722 | ✔ | ✔ | **✘**（代码块不进选区） | ✔ | ✔ | ✔ | ✔ |

自写渲染的一个坑（已修、R2 要记）：`RichText` 命中测试只看最内层 `TextSpan` 的 `recognizer`，链接的识别器要下推到每个叶子 span，挂在父 span 上永远不触发（markdown_widget 的 `_toLinkInlineSpan` 就是这么做的）。

### 2.5 可配置性、维护状态与依赖闭包

| 候选 | 样式能否全部来自 tokens | 维护 | 依赖闭包（对本项目的增量） |
|---|---|---|---|
| ① 自写 | ✔ 天然（widget 就是我们的） | 解析器由 Dart 团队维护；渲染层约 390 行自己维护（`custom_md.dart` 288 + `code_card.dart` 84 + `md_ext.dart` 17；R2 估 500–600 行含嵌套列表 / 图片 / HTML 块 / 脚注的兜底） | markdown（+ args, meta） |
| ② markdown_widget | 大体可（每个 tag 一个 Config；标题分割线、列表序号间距要绕） | 最近发版 2025-04（17 个月），issue 处理慢 | + url_launcher、visibility_detector、scroll_to_index、highlight、flutter_highlight（后两者 2021 停更） |
| ③ gpt_markdown | 可（StyleSheet + 十几个 builder），但结构是自家的（复选框 + 项目符号、芯片式行内代码） | 活跃（2026-08） | + flutter_math_fork（含 provider、tuple） |
| ④ flutter_markdown_plus | ✔（MarkdownStyleSheet 全字段 + builders；缺省 null 要自己填满） | 活跃（2026-07） | + markdown、path |
| ⑤ streamdown | ⚠ 标题只能经 Material `textTheme`，行内代码字体写死、无入口；代码块可换 builder | 单人项目，0.1.1，7 likes | + flutter_highlight / highlight（2021）、flutter_math_fork、url_launcher |

### 2.6 推荐与理由

**推荐 ①：`package:markdown` 7.3.1 解析 + 自写渲染（+ re_highlight + flutter_math_fork）。**

先说清一件事（第 1 轮审查的取舍质疑）：矩阵里 ① 的「判据全过」是**自写渲染层 + 共用的 CodeCard / 复选框 / 公式扩展**贴到画板上的结果，不是解析器独有的能力；④ 注入同一套之后，差距只剩「先到的块是否保住」与表格列宽 / 缺省样式两处。所以推荐 ① 的理由不是「它更快」，而是下面三条：

1. 贴画板的代价最低：四个库要贴画板 12 / 13 / 14 都得用 builder 把代码块、复选框、表格、公式换成自己的（④ 在 spike 里就换了三样，② 换了复选框还得再换代码块 wrapper），换完剩下的只有「解析 + 段落排版」，而这部分自写约 390 行、样式全部从 `tokens.dart` 来（规则 3 零成本满足），没有第三方结构要绕。
2. 流式行为完全在自己手里：每个顶层块套 `ValueKey`，标题 Element 与代码块横滚位置都保住（§ 2.3）；将来「疑似表头行先按表渲染」「尾块重解析」这类优化不用等上游。这条是可控性，不是测出来的性能差距——④ 的横滚位置同样保住了，两者每帧成本 4× 时 28 vs 40 ms、方向一致但只是单次 debug 数字。
3. 白名单最小：只多 `markdown`（解析器）。规则 1 的精神是「会话 UI 自己写」，Markdown 段落就是会话 UI 的一部分。

代价要认：渲染层是我们维护的代码，CommonMark 边角（嵌套列表的松紧、HTML 块、图片、脚注、自动链接）要在 R2 逐个兜底；spike 代码不合并，R2 按画板重写一遍（可参考 `lib/spike/candidates/custom_md.dart`）。

**备选 ④ `flutter_markdown_plus` 1.0.12**：官方血统、活跃、同一解析器、builders 齐；若所有者不想维护约 400 行渲染层就选它，代价三条：手写 `MarkdownStyleSheet` 的缺省全是 null（`del` / `em` / `strong` / 表格样式都要显式给）、表格列宽默认 flex 均分要配 `tableColumnWidth`、每个 chunk 重建全部 widget（§ 2.3 测到标题 Element 每帧新建、代码块横滚位置仍保住；选区没有单独测，每帧成本比 ① 高约三成）。

不推荐 ②（停更 17 个月、拉 5 个包、13px 下复选框崩）、③（非 CommonMark 解析、行内 `$` 公式被代码块里的 `\(` 关掉、每帧成本最高）、⑤（0.1.1 单人项目、代码块不可选、行内代码字体写死、下划线强调规则错）。

## 3. 代码高亮（`shots/13-highlight.png`）

同一份 tokens 色表、同四段代码（画板 13 的 powershell + dart / rust / json）：

| | `highlight` 0.7.0（markdown_widget / streamdown 自带） | `re_highlight` 0.0.3 |
|---|---|---|
| 版本 / 发布 / 许可证 | 0.7.0 / 2021-03-07 / MIT，停更 | 0.0.3 / 2024-02-05 / MIT，Reqable 产品子模块，与 hljs 11.9 同步并过全部用例 |
| 语法 | hljs 10；190 种 | hljs 11.9；197 种（含 powershell / dart / rust / json / bash / yaml / typescript / toml→ini） |
| powershell | 关键字 / 内建命令 / 字符串几乎不着色，只有注释灰 | `function` / `param` / `if` / `throw` 关键字、`Get-ChildItem` 内建、字符串、`$hits` 变量、注释全着色 |
| dart / rust / json | dart 只认注释与部分类型，rust 只认注释，json 只认字符串；且渲染出的等宽文本字距不齐（多段 span 合成） | 三段完整着色（关键字 / 类型 / 字符串 / 数字 / 注释），字距正常 |
| 主题 | `Map<String, TextStyle>` 按 className | `Map<String, TextStyle>` 按 scope（含 `title.function_` 这类点分 scope），`TextSpanRenderer` 直接给 TextSpan |
| 依赖 | collection | collection, path |
| 成本 | — | 注册全部 197 种语言是存 Mode 不编译；某语言首次高亮时编译一次（powershell 约 150 ms，debug 测试进程里测得），之后不再 |

**推荐 `re_highlight` 0.0.3**；备选 `highlight` 0.7.0（只在选 ② / ⑤ 时顺带得到，本身不值得单独进白名单）。风险：re_highlight 版本号低、最近发版 2024-02，但它是 highlight.js 的机械翻译（语法文件自动生成），上游更新时同步成本低；坏了可以自己 fork。

## 4. 数学公式（`shots/16-math.png`）

`flutter_math_fork` 0.7.4（2025-05-21，Apache-2.0，pub 140 分 / 172 likes / 264 K 下载）：

- 行内 `MathStyle.text`：`O(n)`、`n` 与正文基线对齐；块级 `MathStyle.display`：画板 16 的 `\sum_{i=1}^{4} t_i = 1.7\,\mathrm{s} \le T_{\mathrm{budget}} = 5\,\mathrm{s}` 正确；矩阵 / 分式 / 根号 / 希腊字母 / 箭头抽查正确。
- 错误公式 `\frac{1}{` 经 `onErrorFallback` 回落为源码 + error 色，不抛异常。
- 依赖：flutter_svg（已在白名单）、**provider**（状态管理库，规则 1 明文不引；它只是传递依赖、我们的代码不用）、tuple、collection、meta。
- 字体是包内 13 个 KaTeX 家族，真机由资源清单自动装入；flutter_tester 要手动 `FontLoader`（`test/spike/_harness.dart`）。
- 定界符：库只管 TeX 本身，`$…$` / `$$…$$` / `\(…\)` 的识别在 Markdown 层做（自写渲染是一个 15 行的 `InlineSyntax`）。

**推荐 `flutter_math_fork` 0.7.4**；备选：不渲染，公式按源码态显示（那要改画板 16）。附带裁定：`provider` 作为传递依赖是否可接受 —— 建议接受，并把「传递依赖不算规则 1 的引入，validate.ps1 只核对 pubspec.yaml 直接依赖」写进规则 1 的说明。

## 5. Mermaid（`shots/15-mermaid.png`）

ROUNDS.md 拆解时给的三选一 (a) WebView / (b) 只做源码态并改画板 / (c) 自写子集，spike 时发现了第四条路：

| 方案 | 现状 | 判断 |
|---|---|---|
| (a) WebView 渲染 mermaid.js | `webview_flutter` 4.14.1 官方**无 Windows 平台**；`webview_windows` 0.4.0 2024-02 停更；`flutter_inappwebview` 6.1.5（2024-10）有 Windows 但整包很重，且与 § 9 裁定 Flutter 时「不依赖 WebView2」的收益直接冲突 | 不建议 |
| (b) 源码态 + 复制按钮 | 零依赖；画板 15 要删掉「图形」态并重渲染 PNG | 可做，是兜底 |
| (c) 自写子集 | 画板 15 只是一条链，但 agent 会发任意 flowchart / sequence | 不做 |
| **(d) `mermaid_flutter` 0.3.0 + `mermaid_core` 0.3.0** | 2026-09-08，MIT，mermaid.js 的纯 Dart 移植：库声明 28 种图（本轮只实测 flowchart 一种）、elk 布局、`TextPainter` 测字、`CustomPainter` 绘制，无 WebView / 平台视图；`MermaidDiagram(source, theme, errorBuilder)`，主题 16 个必填色 + fontFamily 全能从 tokens 灌（`lib/spike/mermaid_board.dart`） | **推荐** |
| `flutter_mermaid` 0.1.0 | 2026-03-05，MIT，独立实现的 flowchart / sequence / pie / gantt 子集；画板 15 语料渲染出来边标签压在节点上、边穿过节点；`MermaidStyle.fontFamily` 给了微软雅黑仍不生效，标签 CJK 在同一张截图里是方块（真缺陷，不是测试环境） | 排除（截图下半） |

(d) 的实测：画板 15 的 graph TD（7 个节点、7 条边、两条回边、CJK 与全角括号标签）解析 + 布局 + 绘制一次成功；布局把 `Proj → UI` 排成第二列（mermaid.js 对带回边的图也会这样），节点色 / 边色 / 边标签底色都按 tokens。风险：0.x、单人维护、2 likes；依赖 `elk` 0.2.0（纯 Dart 分层布局）、`katex_dart`、`path_parsing`；`TextStyleSpec` 只有一个 `fontFamily`，CJK 靠平台字体回退（flutter_tester 不回退，截图里配的是微软雅黑，真机表现本轮没测）；其余 27 种图形是库声明，本轮没测；两个库首帧（含 flutter_mermaid）在 debug 测试里 163–195 ms。

**推荐 (d)**，接入时用 `errorBuilder` 回落到源码态（画板 15 的「源码」按钮本来就有），任何解析失败都不影响转录；R2 接入时先在真机验一次 CJK 回退。备选 (b)。

## 6. 音频（画板 32，`data/audio-report.json`）

| | `audioplayers` 6.8.1 | `just_audio` 0.10.6 |
|---|---|---|
| 发布 / 许可证 | 2026-06-27 / MIT，3,441 likes | 2026-06-29 / MIT，4,148 likes |
| Windows | 官方 `audioplayers_windows`（Media Foundation） | **官方无 Windows**（pub 平台标签只有 android / ios / macos / web），要社区 `just_audio_windows` 0.2.3 或 `just_audio_media_kit`（拉 mpv） |
| 内存字节源 | `BytesSource(bytes, mimeType)`，Windows 侧 `SHCreateMemStream` 喂 Media Foundation | 需自定义 StreamAudioSource |
| 直接依赖 | 13 个：6 个平台包 + file, http, meta, path_provider, synchronized, uuid | 12 个 |

真机（一次性 Flutter app，release 构建，无头跑，3 秒 440 Hz 单声道 WAV 132 KB）：

| 用例 | 结果 |
|---|---|
| A `BytesSource`（内存 base64 解码后直接播） | `play()` 返回前 783 ms 拿到 duration 3000 ms；position 事件 367 个（约 120 Hz），0 → 3001 ms；`onPlayerComplete` 在 +3.8 s 到 |
| B base64 → 临时文件 → `DeviceFileSource` | duration 162 ms 到；position 398 个；complete 到 |
| C pause / resume / seek（BytesSource） | 900 ms 时 pause → 位置 910 ms，等 700 ms 再读仍是 910（停住）；resume 后 seek 2500 → 读回 2500；complete 到 |

**推荐 `audioplayers` 6.8.1**（画板 32 只要播放 / 暂停 / 进度条，A 路径够用，不用落盘）；备选：不可渲染兜底卡并改画板 32。`just_audio` 只按「官方无 Windows 实现」排除，社区的 `just_audio_windows` 本轮没测。代价见 § 8 第 1 条（`objective_c` override）与依赖闭包（`http`、`uuid`、`path_provider` 等进入 lock 文件）。

## 7. diff（画板 21，`shots/21-diff.png`，`data/diff.json`）

| | `diffutil_dart` 5.0.0 | `diff_match_patch` 0.4.1 |
|---|---|---|
| 发布 / 许可证 / 依赖 | 2026-06-06 / Apache-2.0 / 无 | 2021-06-03 / Apache-2.0 / 无 |
| 算法 | Myers 列表 diff（Android DiffUtil 移植），`calculateListDiff(oldLines, newLines).getUpdatesWithData()` 直接给行级插 / 删 | 字符级 diff（Google dmp 移植）；行模式要自己把每行映射成一个 BMP 字符再映射回来（库内 `linesToChars` 没导出），天花板约 6.3 万个不同的行 |
| 画板 21 样例 | +3 −1，旧 / 新文本都能从行序列还原 | 同 |
| 5,000 行 / 50 处编辑 | **3.7 ms** | 8.8 ms |
| 20,000 行 / 200 处编辑 | **17.7 ms** | 50.9 ms |
| 2,000 行全部不同 | **41.5 ms** | 564 ms（触发它的 1 s 超时启发式） |
| 无 oldText（0 → 3,000 行） | 13.1 ms | 0.5 ms（一条 insert） |

`getUpdatesWithData()` 的更新序列从尾到头派发、位置以当前列表计，重建统一视图时删除行要留位（`lib/spike/diff_board.dart` 的 `indexOfLive`），四组用例的往返校验都过。

**推荐 `diffutil_dart` 5.0.0**（即规则 1 里的「一个 diff 库」）；备选 `diff_match_patch`。

## 8. 测试环境让步 vs 库的真缺陷

截图里凡是方块都先看这里，别当成库坏了：

| # | 现象 | 归类 | 说明 |
|---|---|---|---|
| 1 | `flutter test` / `flutter build` 在「Building native assets for package:objective_c」失败：`Architecture.arm64e` 不存在 | **工具链** | `audioplayers` → `path_provider` → `path_provider_foundation 2.6.0` → `objective_c ^9.2.1` 解析到 9.6.1，其 `hook/build.dart` 需要比 Dart 3.13.3 新的 SDK。本分支 `dependency_overrides: objective_c: 9.4.1` 绕过；采纳 audioplayers 就要一并带上，直到规则 4 流程升 Flutter |
| 2 | 公式、gpt_markdown 行内代码、streamdown 代码显示成实心黑块 | 测试环境 + 一条真缺陷 | flutter_tester 不装包字体（KaTeX、JetBrainsMono）、不认不存在的家族名（回落到 Ahem 测试字体）。KaTeX 已手动装；gpt_markdown 改配 Geist Mono；**streamdown 把 `'monospace'`（fallback `'Courier'`）写死且行内代码无入口**——测试里把 Geist Mono 登记成 `'monospace'` 让截图可读，而 Windows 真机探针（`data/font-probe.json`：同一 app 里 `TextPainter` 排 10 个 i 与 10 个 m）显示 `'monospace'`、`'Courier'`、不存在的家族名与默认字体宽度完全相同（48.4 / 172.3 px，比例字体），`Consolas` / `Courier New` 才等宽（110.0 / 120.0）。所以真机上 streamdown 的行内代码是比例字体，这条是**库的真缺陷** |
| 3 | 复选框、Copy 图标显示成空心方块 | 测试环境 | `Icons.*` 要 Material 图标字体；R2 画板图标本来就走 flutter_svg / CustomPaint（BACKLOG 已记） |
| 4 | Mermaid 标签 CJK 空心方块 | 分两半 | 上半 `mermaid_flutter`：`TextStyleSpec` 只有一个家族名、无 fallback，配了微软雅黑后 CJK 正常，配 Geist 时的方块是 flutter_tester 不做平台回退（真机回退本轮没测）。下半 `flutter_mermaid`：同一张图、同样配了微软雅黑仍是方块，字体配置不生效，是**库的真缺陷**（§ 5 已并入排除理由） |
| 5 | markdown_widget 默认复选框：debug 断言 `padding.isNonNegative`，release 里 ErrorWidget 在无界高度下撑到 20 万像素 | **库的真缺陷** | `input.dart:26` 按 `行高/2 − 12` 算上边距，正文 13 × 1.5 = 19.5 px 就是负数；ListView 子项就是无界高度，会在真机复现。`CheckBoxConfig.builder` 可绕 |
| 6 | gpt_markdown 行内 `$…$` 原样显示 | **库的真缺陷** | `useDollarSignsForLatex` 的行内转换以全文不含 `\(` 为前提（`gpt_markdown.dart` 约 406 行），代码块里的正则就能关掉整篇 |
| 7 | streamdown 表格单元 `_meta` → 斜体 *meta* | **库的真缺陷** | 下划线强调不按 CommonMark 的词内 / 左右侧规则 |
| 8 | 自写渲染流式里含代码块的第一帧 213 ms（`data/stream.json` 的 `custom x1.maxms`，与 § 2.3 脚注同一口径） | 一次性成本 | re_highlight 首次高亮某语言时编译语法；`data/first-frame.json` 里各候选首帧含测试进程预热，且自写排在第一个跑，数字不可横比 |
| 9 | 一次性音频 app 在 `%TEMP%\claude\…\scratchpad` 下 CMake `project()` 失败 | 工具链 | 超长路径；换 `D:\cargo-target\AcpAgentClient\audio-spike` 即过 |

## 9. 白名单改动稿（裁定后落文档）

按 § 0 推荐项全部采纳时，CLAUDE.md 规则 1 与 `docs/requirements.md` § 8 的 Dart 侧清单改成：

> Dart 侧 Flutter SDK 自带的 Material / Cupertino、flutter_rust_bridge、xterm、url_launcher、file_selector、flutter_svg、**`markdown`（只用解析器，渲染自写，R1.5 裁定 2026-09-15）、`re_highlight`（代码高亮）、`flutter_math_fork`（数学公式）、`mermaid_flutter` + `mermaid_core`（Mermaid）、`audioplayers`（音频块）、`diffutil_dart`（即「一个 diff 库」）**。传递依赖不算引入，`scripts/validate.ps1` 只核对 `pubspec.yaml` 的直接依赖；`pubspec.yaml` 里为工具链兼容而加的 `dependency_overrides` 要在注释里写明原因与解除条件。

`scripts/validate.ps1` 的 `$allowed` 数组同步加这 7 个名字。规则 1 里「Markdown 渲染库在 R1.5 spike 选型并经所有者裁定后才进清单」那句改成裁定结果；`rounds/BACKLOG.md` 两条 R1.5 条目打 `[x]`；ROUNDS.md 进度表 R1.5 行记裁定日期。

需要所有者明确的附带事项（都有推荐）：
1. `provider` 作为 `flutter_math_fork` 的传递依赖 —— **推荐接受**（我们的代码不 import 它）。
2. `objective_c` 9.4.1 override —— **推荐接受**，写进 pubspec 注释，升 Flutter 时复核。
3. 画板 15 / 32 —— **推荐不改**（推荐项都能渲染图形态与播放条）。
4. R2 渲染层的流式策略 —— **推荐**先按帧合并 + `ListView.builder`（design.md § 9 既定），尾块重解析等到 R2 实测 1,000 块转录后再定。

## 10. 复现

```powershell
# worktree：D:\variFlight_work\AcpAgentClient-r15（分支 round-01.5）
flutter pub get
flutter test test/spike/shots_test.dart      # 19 张截图 → rounds/round-1.5/shots/
flutter test test/spike/stream_test.dart     # 单独跑；→ build/spike/stream.json
flutter test test/spike/select_test.dart     # → build/spike/select.json
flutter test test/spike/diff_test.dart       # → build/spike/diff.json
flutter test test/spike/mw_diag_test.dart test/spike/gpt_diag_test.dart   # 两个诊断
```

音频与字体探针：一次性 app 的 `main.dart` 原样副本在 `lib/spike/audio_spike_app.dart`（字体探针 `font_probe.dart` 的逻辑见 § 8 第 2 条，10 行 `TextPainter`）；壳是 `flutter create --platforms=windows` + `audioplayers ^6.8.1` + 同一条 `objective_c` override，放在短 ASCII 路径（`D:\cargo-target\AcpAgentClient\audio-spike`），`flutter build windows --release` 后跑 `audio_spike.exe <报告路径>`，报告即 `data/audio-report.json` 与 `data/font-probe.json`。
