# Round 7.6 — 字体切换（四轴）

> 状态：已完成，3 轮审查清零后随 v1.1.0 合入 `main`（2026-09-20，见 ROUNDS.md § 7）；验收 10 待所有者提供字体文件（放 `assets/fonts/optional/`，协议的点击同意不可由工具绕过）

## 目标

设置页「外观」小节里，**界面西文 / 界面中文 / 代码等宽西文 / 代码等宽中文**四个轴各能独立换字体，
改完立即全局生效（转录、终端、弹层、diff 一起变）并持久化；MiSans 与 HarmonyOS Sans 可直接选中。

所有者裁定 2026-09-20：① 字体属**聚合物**（GPL 侧风险由所有者承担，依据：Flutter 的 assets 是独立文件、
不链接进二进制，字体是可选项、缺了程序照跑）；② 随包直选而不是「去安装入口」；③ 按两组互不重叠的下拉。

## 前置

- R7 已完成；本轮在独立 worktree `D:/variFlight_work/AcpAgentClient-fonts`、分支 `font-switching`，从 `main` 出。
  原因：主工作副本当时正被另一会话占着开发 `session-timeline`（工作区有未提交改动且在改 `lib/theme/tokens.dart`）。
- `scripts/fetch-upstream.ps1 -Check` 全绿（9 条 OK，2026-09-20）。`vendor/upstream` 用目录联接指向主副本。

## 交付物

**Rust**
- `rust/settings/src/lib.rs`：新增 `Appearance`（四个 `Option<String>`，键名与 Zed 同形取
  `ui_font_family` / `buffer_font_family`，两个 `*_cjk_font_family` 是本客户端自己的）、`sane_family` 形状校验、
  `SettingsStore::appearance` / `set_appearance`；**并给 `Settings` 补 `#[serde(flatten)] extra`**（见「顺带修掉的既有缺陷」）。
- `rust/acp-core/src/core.rs`：`appearance_get` / `appearance_set`。
- `rust/bridge/src/api.rs`：同名两个 bridge 函数；frb codegen 重新生成（`lib/bridge/`、`rust/bridge/src/frb_generated.rs`）。

**Dart**
- `lib/theme/tokens.dart`：`Fonts` 从编译期常量改为**运行时四轴** + `apply` / `reset`；新增 `codeCjkFallback`
  （等宽轴独立于界面轴）；9 个字阶从 `static const TextStyle` 改为 getter，实例由 `FontStyles` 缓存
  （同一套字体下返回同一个对象，`==` 短路与 `const` 时代一致）。
- `lib/app/font_prefs.dart`（新）：四轴枚举、候选表 `fontCatalog`、`FontPrefs` 模型、`FontRegistry`
  （可选字体的探测与 `FontLoader` 注册）、`FontPrefsController`（读写 + 生效 + 通知）。
- `lib/ui/settings/appearance_card.dart`（新）：四行下拉，沿用画板 41 / 42 的弹层三件套。
- `lib/ui/settings/settings_page.dart`：加「外观」小节（`fonts` 为 null 时整节不出现）。
- `lib/app/app.dart` / `lib/app/workbench_screen.dart` / `lib/app/core_bridge.dart`：接线。
- 33 处 `const` 移除（9 个字阶变 getter 的连带），`dart fix` 把仍可 const 的位置补回。

**构建与仓库**
- `windows/CMakeLists.txt`：install 时把 `assets/fonts/optional/*.{ttf,otf}` 拷到可执行文件旁的 `fonts/`；
  目录不存在不是错误（照 sidecar 那条规则的写法）。
- `.gitignore`：`assets/fonts/optional/*` 永不入库，只放行 `README.md`。
- `assets/fonts/optional/README.md`（新）：放法、许可、体积与「必须注明」的约束。

**测试**
- `test/app/font_prefs_test.dart`（新，19 条）、`test/ui/appearance_card_test.dart`（新，5 条）。
- `test/app/fake_core.dart`：补 `appearanceGet` / `appearanceSet`。

## 验收

| # | 检查 | 命令 / 期望 | 结果 |
|---|---|---|---|
| 1 | 上游钉版本 | `scripts/fetch-upstream.ps1 -Check` 9 条 OK | PASS |
| 2 | 全量验证 | `scripts/validate.ps1` → `VALIDATE OK`，合并 `main` 后 318 测试全过 | PASS |
| 3 | 分析器零新增 | `flutter analyze` 零 error / warning；14 条 info 与合并后的 `main` 基线逐条相同 | PASS |
| 4 | 两组候选互不重叠 | `font_prefs_test` 的「西文两轴与中文两轴的 family 不得有交集」 | PASS |
| 5 | 四轴互不干扰 | 换界面轴不动代码轴，反之亦然；kbd 跟等宽轴 | PASS |
| 6 | Rust 往返与脏值 | `cargo test -p settings` 15 条，含空串 / 超长 / 控制字符 | PASS |
| 7 | 未知顶层键不被抹掉 | `unknown_top_level_keys_survive_a_save` | PASS |
| 8 | 无字体文件也能构建 | 仓库内零可选字体文件，validate 全绿 | PASS |
| 9 | 派生字阶不被冻住 | `CardText.*` / `mermaidTokenTheme` 跟着 `Fonts.apply` 走；扫源码禁止新的一次求值样式缓存 | PASS（审查第 1 轮整改） |
| 10 | **随包字体真机渲染** | 放入 MiSans / HarmonyOS 后 `build.ps1` 出包、设置里切换肉眼确认 | **待所有者**（缺字体文件，见下） |

## 禁止

默认三条之外，本轮额外：不给 `pubspec.yaml` 加任何可选字体声明（会让缺文件时构建直接失败）；
不引新依赖（探测只用 `dart:io` 与 `FontLoader`，没碰 `ttf-parser` 之类）；不做系统字体全量枚举（记 BACKLOG）。

## 顺带修掉的既有缺陷

`Settings` 原本没有 `#[serde(flatten)] extra`，而 `save` 是整份覆盖写 —— 用户手写进 `settings.json`
的任何未知顶层键会在下一次写盘时被**静默抹掉**（规则 7「不动用户数据」）。R7 之前只有改 agent 设置才写盘，
所以少见；外观设置让写盘变频繁，必须先堵。已补 `extra` 并加回归测试。

## 代码审查

### 第 1 轮（2026-09-20）

- 审查方式：`cursor-review.ps1`（默认档，后台）
- 审查器与模型：cursor CLI `cursor-grok-4.6-high`
- 审查范围与基准提交：`branch`（`main...HEAD`，40 文件）；产物 `.claude/reviews/20260920-103957-review.out.md`
- findings：3 条（high 1 / P2 2），**全部采纳整改**

**[high] 换字体后转录 / 终端 / 弹层 / markdown 仍用第一次读到的 family** —— `lib/ui/transcript/card_chrome.dart:17`。
`TextStyles` 改成 getter 之后 family 能变了，但 `CardText.code` / `strong` / `button` 等仍是
`static final TextStyle = t.TextStyles.*.copyWith(...)`，**首次访问就把当时的 family 焊死**；
而首帧建 `WorkbenchScreen` 几乎必然碰到它，早于启动时的扫盘与 `Fonts.apply`。之后整树重建也没用。
应用里大部分文字（转录卡、终端、diff、权限卡、侧栏、弹层、按钮）走的正是 `CardText`
—— 也就是说**「全局生效」这条验收原本是假的**，而我自己的单测只断言 `t.TextStyles.*`，所以假通过。
已核实属实。同一种冻结还有 `gfm_table.dart:26` 的 `_head` / `_cell` 与 `mermaid_block.dart:15`
的顶层 `final mermaidTokenTheme`（审查一并点到）。
整改：这三处共 14 个缓存全改 getter；新增 3 条测试直接断言 `CardText.*` 与 `mermaidTokenTheme`
跟着 `Fonts.apply` 走，外加一条**扫源码**的回归测试，禁止 `lib/` 里再出现「带初始化式的 static final
TextStyle」或「顶层 final TextStyle」——这类冻结不会报任何错，只能靠扫源码挡。
（顺带核过：`JsonHighlight.theme` 与 `codeHighlightTheme` 只存颜色、不带 family，安全；
`highlightCode` 与 `CodeBlock.build` 都是调用时现取，安全。）

**[P2] 文件预览把带 family 的高亮 span 缓存在 State 里** —— `lib/ui/files/files_panel.dart:781`。
`_prepare()` 生成的 `_spans` 带 `fontFamily`，`_lineHeight` / `_gutter` / `_maxLineWidth` 又是
`TextPainter` 按当时字体量出来的，而 `didUpdateWidget` 只在 `text` / `language` 变时重跑。
这些东西贵到不能每帧现算，所以整改用**字体代数**：`tokens.dart` 新增 `Fonts.generation`（`apply`
真的改了值才 +1），`_SourceViewState` 记下算缓存时的代数，`build` 里对不上就 `_prepare()`。

**[P2] `FontPrefsController.start` 在 dispose 之后仍会 `notifyListeners`** —— `lib/app/font_prefs.dart:410`。
`start()` 要先 `await` 扫盘，期间关窗就会对已 dispose 的 notifier 发通知（debug 断言失败）。
整改：加 `_disposed` 挡板，`dispose` 里置位，三个入口的 await 之后一律先判。

- 结论：整改后待复审

### 第 2 轮（复审，2026-09-20）

- 审查方式：`cursor-review.ps1`（默认档，后台）
- 审查器与模型：cursor CLI `cursor-grok-4.6-high`
- 审查范围与基准提交：`branch`（`main...HEAD`，3 个提交 / 42 文件；CLAUDE.md：前两轮都用全量）；
  产物 `.claude/reviews/20260920-105329-review.out.md`
- findings：**0 条**。三条整改逐一确认成立且无新缺陷：① getter 化无自递归（`buttonPrimary` /
  `codeError` 只单向再调一次兄弟 getter），`TextStyle.==` 是值比较、不会让 `RenderParagraph` 多余 layout，
  `MermaidTheme` 实现值相等、按 `(source, theme)` 记忆的场景不会整图重解析；② `_prepare()` 只改本 State
  字段、不 `setState`，换字体时外层本就在重建，`_lineHeight` 仍是 `fontSize * height` 与现有 `ListView` 兼容；
  ③ 三个入口与 `_applyLocally` 都判了 `_disposed`，无漏掉的通知路径。
  规则 1 / 2 / 3 / 4 / 6 / 7 / 8 / 10 一并核过。
- 结论：**PASS**（缺陷门禁清零）

### 第 3 轮（合并 `main` 之后的全量复审，2026-09-20）

- 起因：与画板 43（会话时间线）并行开发，两轮都动了 `lib/theme/tokens.dart`。按「并行轮次合并」，
  后合的一方（本轮）先把 `main` 合进来解冲突、重出生成物、再全量复审（同 R4 的第 4 轮）。
- 合并提交 `1bf7eb8`；冲突只有 `ROUNDS.md` 进度表一处（保留 main 的「画板 43」正式行，
  删掉本分支占位的 R7.5 行，R7.6 改为已完成）。
- **真正的接点是 `TextStyles.labelTabular`**：画板 43 那轮加的，是 `static const TextStyle` 且引用
  `Fonts.sans` —— 本轮把它改成了 getter，所以合并后编译不过（**由编译器挡住，不是静默漏过**）。
  已并进 `FontStyles.build()`，字号 / 字重 / letter-spacing / `tabularFigures` / 颜色与 main 原定义
  逐项一致，并加专测守住它跟着界面轴走。
- 生成物无需重出：`main` 这段没动过 `rust/bridge/src/api.rs` 与 `lib/bridge/`，`.dc.html` 也没改。
- 审查器与模型：cursor CLI `cursor-grok-4.6-high`；范围 `branch`（`main...HEAD`，含合并提交）；
  产物 `.claude/reviews/20260920-112214-review.out.md`
- findings：**0 条**。另确认画板 43 的 UI 没有带 family 的缓存（标题 / 编号 / 正文都在 `build` 现取，
  State 只存 `_rows` / `_selected` / 焦点与滚动），弹层开着换字体也能跟上（`OverlayPortal` 随锚点重建）。
- 结论：**PASS**（可合并 `main`）

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-7.6/BLOCKED.md`，停下呼人。

## 本轮实测

**架构选型**。四轴能成立的根据是 Geist / Geist Mono 对 U+4E00–9FFF 的 cmap 覆盖为 0，中文必然落到
`fontFamilyFallback` 首项；代价是**西文轴上不能出现含 CJK 字形的字体**，否则它把中文吃掉、中文轴失效。
候选表因此严格分组，并用单测守住这条不变量。

运行时切换有两条路：(A) 字阶改 getter + 全树重建；(B) 固定 family 别名 + `FontLoader` 运行时覆盖。
选 A：B 依赖「同名 family 再次注册会覆盖」这个 Flutter 没有保证的行为。A 的代价是 33 处 `const` 要摘掉
（`const TextStyle` 编译期焊死 family），用分析器定位 + 脚本批量摘、再 `dart fix` 把仍可 const 的补回。
为避免每次 getter 现造对象导致 `==` 全部落空、多出无谓重建，实例在 `Fonts.apply` 时一次性重算并缓存，
同一套字体下返回同一个对象 —— 有单测 `identical` 守着。

**可选字体不进 `pubspec.yaml`**。两个原因：许可证（不能入库）与构建（声明了没文件则 `flutter build` 直接失败）。
改为启动时从三处探测：可执行文件旁的 `fonts/`（随安装包）、数据目录的 `fonts/`（用户自己丢的）、系统字体目录。
前两处用 `FontLoader` 注册，系统目录**只探测不注册**（Windows 上装进系统的字体由平台按家族名直接解析）。

**代码等宽中文单列一轴**是本轮发现的、独立于本功能的既有问题：等宽渲染按字符格子走，中文必须正好是拉丁的
两倍宽，而 Noto Sans SC 的汉字是全角 1em、Geist Mono 的 advance 约 0.6em，2×0.6 ≠ 1 —— **终端面板里出现中文
时格子现在就是歪的**。更纱黑体 Sarasa Mono SC 专门做了 2:1 对齐，列为这一轴的推荐项；但它只是给了用户一条
出路，根因（默认组合仍然错位）没解，已记 BACKLOG。

**踩的坑**：`\\u` 经 Bash 工具塌成 `\u` 撞上 Python 转义两次（CLAUDE.md 记过），改用 raw 字符串与 Write 工具；
`dart fix --apply` 会顺带动无关文件，用 `--code=` 限定到单条 lint 才干净。

### 还差什么（阻塞验收 10）

仓库里**没有任何可选字体文件**，所以 MiSans / HarmonyOS Sans 目前在设置里显示「本机未找到」。
这两款的下载页都是点击同意协议后由 JS 动态取地址（MiSans 下载页指向 zip/ttf 的 `<a href>` 实测为 0 个），
**必须由所有者本人下载**——那个点击同意正是合规凭据，不该由工具绕过。
拿到后放进 `assets/fonts/optional/`（放法见该目录 README），重跑 `scripts/build.ps1` 即随包生效。
