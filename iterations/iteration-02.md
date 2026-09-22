# Iteration 02 — BACKLOG 收尾：会话索引 / 输入框 / 主题重建三组

<!-- 保存为 iterations/iteration-NN.md。一个迭代一个文件、一项一行；流程正本见 iterations/README.md，不在这里复述。 -->

> 状态：进行中　起止：2026-09-22 –　基线：`main` = 022079b

## 工作项

<!-- 类型：fix 缺陷 / ux 交互 / tidy 工程收尾 / board 单画板（设计稿先入库）。
     状态：待开工 / 进行中 / 待审查 / 待合并 / 已合并 / 移出（写去向）。
     验证：validate 全绿 / validate -Quick / 未构建（所有者指定）。
     审查：<轮数> 轮，<条数>（high n / P2 n / P3 n）；或 未审查（所有者指定）。 -->

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 3 | fix | 换主题 / 换字体后界面只切一半：`MarkdownBody` 按 `Fonts.generation` 判过期 + 10 个叶子 widget 摘掉 `const` 构造 | BACKLOG「P1 · 主题与渲染」第 1–2 条 | `claude/theme-font-partial-rebuild-471573` → `<sha>` | validate 全绿（16 道门，flutter test 408 项） | | 待审查 |

## 收口

- 构建 / 手测：<日期、`build.ps1` 结果、手测项与结论>
- 发版：<版本号 + 三件产物，或「不发」>
- 移出项去向：<下个迭代 / 回 BACKLOG / 立项开轮>
- 设计稿补注记：<本迭代实现先行的项，已记 BACKLOG 的条目>

## 备注

### 第 3 组（主题重建）

**根因一条**：同一个 widget 实例 → `Element.updateChild` 见 `child.widget == newWidget` 直接复用旧 element、不再 build，于是 build 里现取颜色 token 的代码根本没被重新执行。颜色 token 都是 getter、能每帧现取，出问题的只是「element 压根没重建」的地方。

**① 转录正文**（`lib/ui/transcript/markdown_body.dart`）：`_MarkdownBodyState` 把块 widget 实例缓存在 `_blocks`（有意为之：父级重建时子树不重建，recognizer 才不会随 build 反复登记），`didUpdateWidget` 只比 data / onLink / mermaidFontFamily / baseStyle，换主题这四个都没变。照 `files_panel.dart` 的 `_SourceView` 抄同一句：State 里记下算 `_blocks` 时的 `t.Fonts.generation`，`build()` 开头对不上就 `_rebuild()`。换字体与换主题都会推进这个代数（`tokens.dart` 的 `rebuildStyles()`），一个代数覆盖两件事。7 个调用点（assistant_text / content_blocks / plan_card / subagent_card / thinking_block / 文件面板 md 预览）一次都覆盖到，没一个传 `baseStyle`，所以 `didUpdateWidget` 那条路从来不会替它们重建。

**在 build 里调 `_links.disposeAll()` 安全吗——结论：安全，按原方案在 build 里重建，没有改成「标脏 + 下一帧」。** 三条依据：(a) 这不是新增的风险面——`didUpdateWidget` 那条路径每到一段流式 chunk 就 `disposeAll()` 一次，早就在跑；(b) 触发条件收得很紧：代数只由 `Fonts.apply` / `Theming.apply` 推进，而这两处的入口是侧栏标题条的主题开关与设置页的外观卡，那一下用户的指针在开关上、不在转录的链接上（启动时读盘落定那一次也走这条，但那是头几帧）；(c) 真撞上了也只是那一次点击被取消、不会挂：`OneSequenceGestureRecognizer.dispose()` 先 `resolve(GestureDisposition.rejected)`、再把 `_trackedPointers` 的路由摘掉，之后才 `assert(_entries.isEmpty)`。另外 `_rebuild()` 同帧就把新块返回给 `build()`，旧 recognizer 不会在渲染树里多活一帧。

**② `const` 叶子 widget**：按所有者裁定摘**构造函数声明**上的 `const`（不是逐处加 `// ignore: prefer_const_constructors`）——构造函数不再是 const，`dart fix` 与 lint 就回改不了调用点。代价是声明那一行要带 `// ignore: prefer_const_constructors_in_immutables`：这条 lint 会让 `dart fix` 把 `const` 加回构造函数、等于把修复整个撤销，所以这 10 个 ignore 是必须的，不是可省的装饰。备选「换主题时给 `home` 换 `ValueKey(theme)` 整树重建」按裁定不采用（丢滚动位置与焦点等瞬时态）。

**范围是重新扫出来的，比 BACKLOG 那份清单多六个。** 判据两条：在 `lib/ui` / `lib/app`（不含 `lib/gallery`）有 `const` 调用点，且 build 里读随主题走的 token（`Neutral` / `Accent` / `Semantic` / `Surface` / `Borders` / `Shadows` / `TextStyles` / `CardText` / `Overlays` / `FocusRing` / `SvgTint` / `Kbd` / `Spinner` / `Sweep` / `UnreadDot` / `Timeline` / `Fold` / `Badge`）。结果 10 个 widget、62 处调用点：

| widget | 声明 | 调用点 | 为什么算 |
|---|---|---|---|
| `ToneChip` | `card_chrome.dart` | 11 | `Semantic.*Soft` / `Neutral.surface` / `Accent.soft` |
| `Chevron` | `card_chrome.dart` | 9 | `Neutral.placeholder` |
| `SectionLabel` | `card_chrome.dart` | 4 | `TextStyles.label`（颜色烘在字阶里） |
| `MonoBlock` | `card_chrome.dart` | 1 | `Neutral.panel` + `CardText.code` |
| `Spinner` | `icons.dart` | 20 | `Spinner.color` = `Accent.base`，浅 `#5566D8` ↔ 深 `#8B96EC` |
| `AwaitingRow` | `awaiting_bar.dart` | 1 | `CardText.headerTitle`，里面还套着 `Spinner` |
| `FileViewerEmpty` | `files_panel.dart` | 3 | `Surface.canvas` / `Borders.base` / `TextStyles.*` |
| `_TreeNote` | `files_panel.dart` | 1 | `TextStyles.*` |
| `_Diamond` | `registry_entry.dart` | 2 | `Neutral.placeholder` |
| `AuthSucceededCard` | `auth_page.dart` | 2 | `Semantic.success` / `TextStyles.*` |

两种**隐式 const** 也一并摘（原清单没列，靠编译器暴露）：`thinking_block.dart` 的 `trailing: const <Widget>[Chevron(…)]` 两处、`files_panel.dart` 与 `gallery/boards/panel_boards.dart` 的 `const Expanded(child: FileViewerEmpty())`。

**没动的两类**，各有理由：
- 弹层里的 `MenuDivider` / `MenuGroupLabel` / `_TimelineEmpty`：所有者已裁定不在范围内（每次打开都新建 element）。
- 只在 `lib/gallery` 里写 `const` 的 14 个（`TopBar` / `SessionHeader` / `MentionMenu` / `NoAgentEmpty` / `AuthFailedCard` / `AuthMethodPicker` / `ManagedNodePrompt` / `SessionTimelinePopover` / `RunningBadge` / `BoardSection` / `ComposerRunning` / `TokensBoard` / `_ButtonSample` / `_Kbd`）：gallery 全程不调 `Theming.apply`（`loadGalleryFonts` 只往引擎里注册 family，不碰 `Fonts.apply`），一张画板只渲染一次，撞不上这个 bug；摘了反而白丢 const 的好处。

**回归用例**：`test/ui/theme_rebuild_test.dart`，5 条，**全部先验证过「退回修复即红」**（修复前 5 红、修复后 5 绿）。关键是一律从**真实调用点**渲染——在测试里自己 `ToneChip(...)` 新造一个实例测不出来，新实例本来就会重建、退回修复也不会红。覆盖：`MarkdownBody`（正文字色 + 行内代码底色）、`RegistryEntryRow` → `ToneChip` + `_Diamond`、`CollapseBar` → `Chevron`、`AwaitingRow` → `Spinner`、`FilesPanel` → `FileViewerEmpty`。

**验证**
- `powershell -File scripts/validate.ps1` 全绿（16 道门；`flutter test` 408 项，新增 5 项）。首跑只挂在 `fetch-upstream -Check`，是 worktree 的 `vendor/upstream` 是空目录——按惯例换成指向主副本的目录联接（`mklink /J`）后全绿，与本次改动无关。
- `flutter analyze`：16 条 info 全是既有的（4 条在 `lib/gallery`、12 条在 `test/`），本次改动一条不增；0 error / 0 warning。
- **画板对照**：在 `022079b` 上开一个临时 worktree 渲染同一批画板，与本分支的 `build/gallery/` **45 张 PNG 逐字节一致**（`md5sum` 全等）。摘 `const` 不改变任何单次渲染的输出，`Fonts.generation` 那一句在 gallery 里是恒假分支。
- 手测：**未构建**（本组只动 `lib/ui` 与测试，随迭代收口时统一构建手测；手测项＝浅→深→浅看 registry 徽章 / 设置页徽章 / 工具卡 Canceled 徽章 / 各处 chevron / 文件面板空态 / spinner / 整段对话正文，全部不 reload 会话就跟着变）。

**与设计稿的关系**：这次是把实现改回画板 07 定义的深色表现，不是偏离，**不记** `design/DIVERGENCE.md`。
