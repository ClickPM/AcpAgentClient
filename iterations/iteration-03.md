# Iteration 03 — BACKLOG P0 收尾：附件与剪贴板

<!-- 保存为 iterations/iteration-NN.md。一个迭代一个文件、一项一行；流程正本见 iterations/README.md，不在这里复述。 -->

> 状态：进行中　起止：2026-09-23 –　基线：`main` = `8b56dbc`（v1.4.2 发版之后）

v1.4.2 之后的第一批：BACKLOG P0「附件与剪贴板」两条，所有者 2026-09-23 当场裁定——一条按产品取舍关闭，一条取上限 20 张修掉。

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | fix | 剪贴板文件列表没有张数门：`promptImageCountLimit = 20`（一条消息的总数，连同输入框里已有的），剪贴板与 `+` → Image 两条路共用；`readClipboardImages({maxImages})` 判在读文件 / 编码之前、回 `skippedTooMany`，`pasteImageFromClipboard` 落进输入框时再判一次（连按两下 Ctrl+V 并发），`addImageBytes` 满了不收；提示单独一句 | BACKLOG P0「附件与剪贴板」第 2 条；所有者裁定 2026-09-23 取 20 张 | `claude/attachments-clipboard-p0-19efea` → `006bd0f`（快进；合 main 时 BACKLOG 两处登记冲突按「两边都留」解，P0 10 → 7、合计 75 → 72） | 未构建（所有者指定）；相关两份 `flutter test` 全绿，`validate.ps1 -Quick` 见备注 | 未审查（所有者指定） | 已合并 |
| 2 | tidy | 编辑带图的消息会把图弄丢 → **按产品取舍关闭，不修**：编辑历史消息只改文字、不保留原图（与 Claude Code 一致）；只在 `UserMessage.plainText` 的文档注释里写明裁定 | BACKLOG P0「附件与剪贴板」第 1 条；所有者裁定 2026-09-23 | 同上 | 只改注释与文档 | 未审查（所有者指定） | 已合并 |
| 3 | fix | 最大化窗口最小化再还原后，画面四边各溢出屏幕一圈边框（顶栏标题与三键、底栏「设置 / 文件 / Agents / 终端」看着偏了 8 逻辑像素）：`windows/runner/acp_window.cpp` 的 `AdjustMaximizedClientRect` 找显示器改用 `MonitorFromRect(&rect, MONITOR_DEFAULTTONEAREST)`（按系统提议的新窗口矩形），不再用 `MonitorFromWindow(DEFAULTTONULL)`——还原那一刻窗口还在 (-32000,-32000)，后者回 NULL、修正被跳过 | 所有者报障 2026-09-23（「用一阵后顶部和底部的按钮位置偏移」） | `claude/top-bottom-button-offset-101c55` → `e3c0e25`（快进） | 未构建（所有者指定）；独立 Win32 小程序复现与验证修法，见备注 | 未审查（所有者指定） | 已合并 |
| 4 | fix | `+` → Files & Directories 选不了目录：原生文件对话框（`openFiles`）只有「选文件」模式，点目录只会进到下一级。改成照 Zed 往输入框插 `@`、弹画板 42 的 `@` 菜单（根目录一层的文件与目录，接着打字就是搜索），`ComposerState.startMention` | 所有者报障 2026-09-23（改法按推荐项裁定） | `claude/directory-selector-check-fab211`（基线 `8b56dbc`）→ `4b4a3b0`（合入 `main` 2a7c2e9 的合并提交，与第 1 项的张数门合并，见备注；快进） | validate 全绿（整改后 432 项；合 `main` 后 441 项）；headless 构建 + 真剪贴板探针，见「备注 · 第 4 / 5 项」 | 3 轮 / cursor CLI `grok-4.7-high-fast`（`-Scope worktree`）：2 → 2 → 1，high 0；P2 5 条采纳 3、不采纳 2 → **0 high 收口**；合 `main` 后全量复审（`main...HEAD`）1 轮 **0 条** | 已合并 |
| 5 | ux | Ctrl+V 粘贴资源管理器里复制的文件与目录：**默认按路径**加成 `resource_link`（`@名字`），agent 收图时图片文件照旧成芯片，空的与超限的图片文件退回路径；不收图时通道带 `{"bitmap": false}`，runner 不取位图。读取仍是 runner 的 Win32 `CF_HDROP`（`acp_clipboard.cpp`，不拉 powershell） | 所有者 2026-09-23 当场要求 | 同上 | 同上 | 同上 | 已合并 |
| 6 | fix | 终端面板里空格之后打的字看不见：终端主题的 ANSI 白 / 亮白取了 `n.canvas`（= 底色），而 PSReadLine 给参数 / 成员 / 类型上色用 `ESC[37m`、数字用 `ESC[97m`。`terminalTokenTheme` 改成白 = `n.text`、亮白 = `n.strong`（终端卡、terminal auth 共用这张表，一并修好），画板 07 § 2.9 的取值记 `design/DIVERGENCE.md` 第 31 条 | 所有者报障 2026-09-23（截图：`cc` 之后的参数不显示） | 直改 `main` | validate 全绿；未构建、未手测 | 1 轮 / cursor CLI `grok-4.7-high-fast`（`-Scope worktree`）：**0 条** | 已合并 |

## 收口

- 构建 / 手测：未构建（所有者指定）。第 1 项的手测项：资源管理器里选 25 张图 Ctrl+C，输入框 Ctrl+V → 芯片条只出 20 张；再 Ctrl+V 一次 → 一张不加；删掉一张芯片后 `+` → Image 挑一张 → 收下，再挑一张 → 不收。**提示文案用户暂时看不到**：它记在 `composer.lastError`，而 `lastError` 在产品 UI 上还没有出口（BACKLOG P0「资源与静默失败」的「失败没有出口，用户看到的是『点了没反应』」，那条本来就点名了附件超限；「图片太大」那句也一样），手测只能看芯片数。第 3 项的手测项：最大化 → 点任务栏图标最小化 → 再点回来（Win+D 两次同理）→ 顶栏标题垂直居中、右上三键与左上品牌不贴屏幕边，底栏「设置 / 文件 / Agents / 终端」下沿完整。
- 第 4 / 5 项：headless 版已构建、剪贴板探针实测过（见备注「第 4 / 5 项」的验证段），产品 GUI 的手测项也列在那里。
- 发版：—
- 移出项去向：—
- 设计稿补注记：两项都不改画板、无偏离可记——张数门的提示走既有的 `lastError`（与大小门同一处，那处本身在界面上还没有出口，见上）；编辑重发只带文字是画板 11 本来的样子（编辑框里只有文字）。第 6 项改的是画板 07 § 2.9 的终端白色取值，记 `design/DIVERGENCE.md` 第 31 条（手测项见「备注 · 第 6 项」）。

## 备注

### 第 1 项 · 为什么按「一条消息」算、而不是按「一次粘贴」

BACKLOG 原文的症状是一次粘贴收下上百张；只按单次粘贴设门的话，连贴五次还是一百张进同一条 `session/prompt`，内存与 prompt 体积的问题一样在。所以门按输入框里已有的图算余量，文件选择器那条路（一次一张）也吃同一道门。
余量为 0 时照样去读剪贴板、由读取那一侧判「真有图才报」：不读就判的话，满 20 张之后按一下空剪贴板的 Ctrl+V 也会弹提示。

### 第 1 项 · 验证

- `flutter test test/app/clipboard_image_test.dart test/app/workbench_wiring_test.dart`：40 项全绿。新增 8 项：读取侧 4 项（多于余量只收前 N 张、刚好收满不报、默认按 20、余量 0 时只对真有图报）、粘贴侧 3 项（按已有的算余量、连按两下并发不超、没到上限不报）、文件选择器侧 1 项。
- 反证：临时去掉 `pasteImageFromClipboard` 里「落进输入框时再判一次」，「连按两下」那项红（收了 30 张），恢复后绿。
- `validate.ps1 -Quick`：规则 1 / 2 / 3 / 5 / 6、版本门、lib/app 行数门与依赖方向门全过；唯一的红是 `fetch-upstream -Check`——本 worktree 没填 `vendor/upstream`（没做目录联接），与本次改动无关（不动 Rust 与钉版本）。全量 `validate.ps1` 含编译，按所有者「不构建」没跑。
- `flutter analyze lib test`：0 error / 0 warning；改动文件上唯一一条 info 是 `clipboard_image_test.dart` 原有的 `dart:typed_data` 冗余 import，不是这次引入的，没顺手动。

### 第 3 项 · 复现与验证（2026-09-23，Windows 11，2880×1800 @ 150%）

不构建应用（所有者指定），改用一个独立的 Win32 小程序（不入库）：`WS_OVERLAPPEDWINDOW` 窗口，`WM_NCCALCSIZE` 原样照搬 `acp_window.cpp` 的处理，依次「`SW_MAXIMIZE` → `WM_SYSCOMMAND SC_MINIMIZE` → `SC_RESTORE`（= 点任务栏按钮）」，再走一遍 `SW_MINIMIZE → SW_RESTORE`，每步比较客户区（屏幕坐标）与 `rcWork`。

- 改前：最大化后溢出 `0/0/0/0`；还原那条 `WM_NCCALCSIZE` 到达时 `GetWindowRect = (-32000,-32000,…)`、`MonitorFromWindow(DEFAULTTONULL) = NULL`，修正被跳过，客户区变成 `(-12,-12,2892,1728)`，四边各溢出 12 物理像素（= 8 逻辑像素 × 150%）。与所有者两张截图的差（缩到 2000 宽后约 8～9 px）对得上。
- 改后（`MonitorFromRect(&rect, MONITOR_DEFAULTTONEAREST)`）：两种还原路径溢出都是 `0/0/0/0`。
- 触发面：任务栏点图标最小化再点回、Win+D、Alt+Tab 切回最小化的窗口都走这条路，所以表现为「用一阵后就偏」；再有一次非最小化状态下的尺寸计算（如双击顶栏还原再最大化）会自愈。顺带：Win+Shift+方向键把最大化窗口挪到另一块屏幕时，原写法按旧位置找显示器会拿到旧屏的工作区，按提议矩形找也一并正确。

### 第 4 / 5 项（输入框加路径：`+` 选目录 / 粘贴复制的文件，2026-09-23）

**第 4 项的根因**：`file_selector` 的 `openFiles()` 在 Windows 上是 `IFileOpenDialog` 的选文件模式；系统对话框只有「选文件」与「选文件夹」（`FOS_PICKFOLDERS`）两种，没有两者都能选的模式，所以点目录只会进到下一级。Zed 的同名项根本不弹原生对话框（`thread_view.rs` 里 `insert_context_type("file")`，弹应用内的补全列表），我们的画板 42 `@` 菜单本来就把文件与目录分组列出，改法按所有者裁定的推荐项照 Zed：`ComposerState.startMention` 往正文末尾插 `@`（前面不是空白就先补一个空格）、聚焦、自己调 `onChanged`（程序改 `editor.text` 不触发输入框回调）。代价：这条路只列会话 cwd 下的东西，项目外的由第 5 项接。`openFiles` 那条路随之删掉，`file_selector` 仍给 Image 与 Open Local Folders 用。

**第 5 项**：runner 的 `CF_HDROP` 读取（`acp_clipboard.cpp`，2026-09-20 起就是 Win32 原生、不拉 powershell）本来就把**所有**路径（含目录）交给 Dart，只是 Dart 侧把非图片的丢了；这次 C++ 只加一个参数 `{"bitmap": false}`（agent 不收图时不取位图，截图像素不搬过通道），分流全在 `readClipboard`：目录 → 路径；文件在「agent 收图 + 图片扩展名 + 1 字节到 20 MB」时读成图，其余（非图片、空文件、超限、agent 不收图）→ 路径。超限的图片文件以前是报「图片太大」丢掉，现在退回路径（文件就在磁盘上，agent 按路径读得到）；截图位图超限仍报错。粘贴入口改名 `pasteImageFromClipboard` → `pasteFromClipboard`，Dart 函数 `readClipboardImages` → `readClipboard`；**通道方法名 `readClipboardImages` 没改**（C++ 少动一处，注释已写明它也给文件与目录）。

**验证**
- `powershell -File scripts/validate.ps1` 全绿（16 道门；`flutter test` 429 项，新增 7 项：`+` 插 `@` 三条、粘贴接线一条、`readClipboard` 的分流三条——真临时目录，含大写扩展名、空图、稀疏撑到 20 MB + 1 的 jpg；审查整改又加 2 项，见下）。`flutter analyze` 不增 info（`workbench_wiring_test.dart` 加 `services` 导入带出的那条已顺手去掉）。
- **Windows 实测（规则 9）**：`flutter build windows --release -t lib/main_headless.dart`（225 s，runner C++ 无警告）→ 复制到 `D:\cargo-target\AcpAgentClient\dirsel\headless`，`pwsh -STA` 脚本（`D:\cargo-target\AcpAgentClient\dirsel\clip-files-test.ps1`，不入库，照 `rounds/round-quality/clip-test.ps1` 的路子）用 `System.Windows.Forms.Clipboard` 往真剪贴板放三样再跑 `ACP_CLIPBOARD_PROBE`：
  - 文件列表 `[项目 外\, notes.txt, 截图.png, huge.jpg(20 MB + 1)]`：收图档 `images` = `截图.png`（`image/png`、64×48、左上 `[255,0,0,255]`），`paths` = 其余三条且顺序照剪贴板；不收图档 0 图、四条全是路径。放文件列表后 `ContainsText=False`（粘贴不会被「剪贴板里有文本」那道判断挡掉；这是 .NET `SetFileDropList` 的剪贴板，资源管理器复制时是否同样不带文本归手测）。
  - 位图 64×48：收图档 1 张 PNG（201 B，左上像素对）；不收图档 **0 图 0 路径** —— runner 认了 `{"bitmap": false}`。
  - 纯文本：两档都空。
- 未做：GUI 里的 Ctrl+V 与 `+` 菜单（本机没有 GUI 自动化通道，见 BACKLOG 的 `computer-use` 条）。手测项：资源管理器里复制一个项目外的目录 + 一个 `.md` + 一张图 → 输入框里 Ctrl+V，看到 `@目录名 @x.md ` 与一枚图片芯片；换一个不收图的 agent 再贴，图也变成 `@x.png`；`+` → Files & Directories，看到 `@` 菜单列出根目录一层、能选目录。

**审查**（cursor CLI `grok-4.7-high-fast`，未回落；整批未提交，范围 `-Scope worktree`）
- 第 1 轮 2 条（high 0 / P2 2），**都采纳**，都是最小改动，各带一条「撤掉整改即红」的回归用例（撤掉后两条都红、恢复后全绿）：
  ① **粘贴时开着的 `@` / `/` 菜单不关**：先点 Files & Directories（`@` 菜单开着）再 Ctrl+V，`_appendToComposer` 改了正文却不清菜单，Enter 会去挑菜单项而不是发送；`/` 菜单开着时 Enter 还会把整段正文换成 `/命令 `，刚贴的 `@x` 从正文消失、`resource_link` 却留在待发块里。整改：`_appendToComposer` 末尾 `_clearInlineMenu()`（追加后正文以空格结尾，不可能还有 token；在途的 fs 结果按既有过期判据自己丢）。Sessions / Branch Diff 两条走同一个函数，一并受益。
  ② **一个图片文件读不了会清空整批**：`readClipboard` 整段循环一个 `try`，某张图 `readAsBytes` 抛（共享冲突 / 拒绝访问）就 `return empty`，前面分好的路径全丢、也不报错。整改：只把那一张的 `length` / `readAsBytes` 用 `on FileSystemException` 接住，读不了就退回路径。用例用 `RandomAccessFile.lockSync()` 锁住那张 PNG（Windows 的 `LockFileEx` 按句柄生效，别的句柄读会 `ERROR_LOCK_VIOLATION`；非 Windows 跳过）。
- 顺手改掉一条被本次改动弄过时的注释（`_canPromptImage` 上的「不支持图片的 agent 连剪贴板都不用读」）。
- 第 2 轮 2 条（high 0 / P2 2），都是冲着第 1 轮整改的：
  ③ **采纳**：先点 Files & Directories（正文 `@`）再贴路径，正文成 `@ @outside dir @shot.png `，那个裸 `@` 会跟着发出去。整改：`addResourceLink` 追加前若光标处是裸 `@`，先去掉它——贴进来的第一条就是它的补全（`看看 @` → `看看 @x `；`a@` 这种前面没空白的不算 token、不动）。只改这一处，Sessions / Branch Diff 的 `[名字]` 不吃 `@`。第 1 轮那条用例补断言正文、另加一条「前面有话」；撤掉整改两条都红。
  ④ **不采纳**：「只贴图片时开着的 `@` 菜单不关」。贴图不改正文，光标处的 `@` 还在，菜单与正文一致——手敲 `@` 再贴截图也是这样，改动之前就是这个行为；硬关掉反而留下一个没有菜单的活动 `@`（下一个按键又会弹出来）。不是缺陷，不记 BACKLOG。
- 第 3 轮 1 条（high 0 / P2 1），**不采纳**：审查认为正文是 `@\n`（菜单开着时 Shift+Enter）时 `_activeToken` 仍回 `@`、整改会删掉换行而非 `@`。前提不成立——那是 Python / PCRE 的 `$`（可匹配在结尾换行之前）；Dart 的 `RegExp` 按 ECMAScript，非 `multiLine` 的 `$` 只认输入末尾。实测同一个函数：`'@' → @`、`'@\n' → null`、`'看看 @\n' → null`、`'@\r\n' → null`、`'a@' → null`，所以以换行结尾时整改那行根本不触发，正文照旧 `@\n @名字 `（换行后的 `@` 已不是待补全的 token，留着合理）。无整改，**审查收口：0 high**。

**与设计稿的关系**：第 4 项不是偏离（画板 40 只画了这一行，没画点下去是什么；落到画板 42 已有的菜单）。第 5 项是实现先行，记 `design/DIVERGENCE.md` 第 29 条；`docs/design.md` § 9 粘贴那条下面补了一段。

**合 `main`（2026-09-23，所有者指示）**：与第 1 项（张数门）改的是同一段——第 1 项的 `readClipboardImages({maxImages})` / `pasteImageFromClipboard` 对上本项的 `readClipboard({images})` / `pasteFromClipboard`。合并口径：`readClipboard({required images, maxImages})`；张数门**只管会读成图的那些**，判在读字节之前；收满之后多出来的图跳过、记 `skippedTooMany`、**不退回路径**（第 1 项裁定的「多出来的没有加进输入框」）；第 1 项原来的 `break` 改成 `continue`——文件列表里图与目录、非图片文件混在一起时，`break` 会把后面的路径一起丢掉。路径不受张数门管（不进内存、不占图片额度）。`pasteFromClipboard` 沿用第 1 项的并发复核与「张数提示优先于太大」，另加路径那一圈。第 1 项的测试改用新 API 全部保留，另加一条「收满之后后面的目录与非图片照样按路径收」。`design/DIVERGENCE.md` 两边都用了 28 号：`main` 的（终端搜索）先进来，本项顺延成 29。
合并结果重跑：`validate.ps1` 全绿（16 道门，`flutter test` 441 项）；headless 版重编（108 s，runner 两边的 C++ 改动都在、无警告）后剪贴板探针三组结果与合并前一致（另多一个 `skippedTooMany: false`）；cursor 全量复审 `main...HEAD` **0 条**（`.claude/reviews/20260923-105129-review.out.md`）。

### 第 6 项 · 终端 ANSI 白（2026-09-23，直改 `main`）

**根因实测**：本机 pwsh 7.6.6（PSReadLine 2.4.5）与 Windows PowerShell 5.1 的 `Get-PSReadLineOption` 都是 `DefaultTokenColor = ESC[37m`、`MemberColor` / `TypeColor = ESC[37m`、`NumberColor = ESC[97m`、`InlinePredictionColor = ESC[97;2;3m`；命令 `cc` 是 `CommandColor = ESC[93m`（亮黄 → warning，截图里看得见的那一截）。xterm 4.0.0 的 `palette_builder.dart` 把调色板 7 **和 15** 都取 `theme.white`（15 不取 `brightWhite` 是库自己的问题），所以真正起作用的只有 `white` 一位：原来它是 `n.canvas`，终端面板的底也是 canvas，字与底同色。
**改法**：白 = `n.text`（与前景同色，对应 Windows 控制台「Gray 是默认前景」）、亮白 = `n.strong`；黑维持 `n.strong`。三处 `TerminalView`（终端面板、终端卡、terminal auth）共用 `terminalTokenTheme`，一起生效。代价与取舍记 `design/DIVERGENCE.md` 第 31 条。
**验证**：`validate.ps1` 全量 **VALIDATE OK**（`flutter test` 461 项，`flutter analyze` 16 条 info 与基线同数）；`appearance_prefs_test.dart` 深浅两套各锁 `white` / `brightWhite` 的取值，并断言两者都不等于 canvas 与 panel。未构建 release、未在 GUI 里手测。
**审查**：1 轮 cursor CLI `grok-4.7-high-fast`（`-Scope worktree`），**0 条**（`.claude/reviews/20260923-115436-review.out.md`）。
**手测项**：终端面板里敲 `git log --oneline -3`、`Get-ChildItem -Path .` 之类带参数的命令，空格后的参数、数字都看得见；深色主题下同样；agent 工具卡里的终端输出照常。
