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

## 收口

- 构建 / 手测：未构建（所有者指定）。第 1 项的手测项：资源管理器里选 25 张图 Ctrl+C，输入框 Ctrl+V → 芯片条只出 20 张；再 Ctrl+V 一次 → 一张不加；删掉一张芯片后 `+` → Image 挑一张 → 收下，再挑一张 → 不收。**提示文案用户暂时看不到**：它记在 `composer.lastError`，而 `lastError` 在产品 UI 上还没有出口（BACKLOG P0「资源与静默失败」的「失败没有出口，用户看到的是『点了没反应』」，那条本来就点名了附件超限；「图片太大」那句也一样），手测只能看芯片数。第 3 项的手测项：最大化 → 点任务栏图标最小化 → 再点回来（Win+D 两次同理）→ 顶栏标题垂直居中、右上三键与左上品牌不贴屏幕边，底栏「设置 / 文件 / Agents / 终端」下沿完整。
- 发版：—
- 移出项去向：—
- 设计稿补注记：两项都不改画板、无偏离可记——张数门的提示走既有的 `lastError`（与大小门同一处，那处本身在界面上还没有出口，见上）；编辑重发只带文字是画板 11 本来的样子（编辑框里只有文字）。

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
