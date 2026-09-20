# Round quality — 代码质量清理（七原则评估的第 1–5 项）

> 状态：实现完成、validate 全绿、Windows 实测全过；审查中

## 目标

按所有者给的七条原则（真的需要吗 / 库里已有吗 / 标准库能否 / 平台原生能否 / 已装依赖能否 / 能否一行 / 最小代码）
把 2026-09-20 评估报告里的第 1–5 项落地，**行为零变化**（除报告里点名的两处：文件面板 GB 档、图标按钮整块可点），
validate 全绿、独立审查清零后合 `main`。第 6 项（桥的四层手写转发）与第 7 项（`appearance_prefs` 的 data-class 样板）
按报告只记 `rounds/BACKLOG.md`，本轮不动。

## 前置

- 从 `main`（`4ddaf2e`）出分支 `quality-cleanup`，独立 worktree `D:/variFlight_work/AcpAgentClient-quality`
  （主工作副本正被 R8 会话占着，有未提交改动）。`vendor/upstream` 用目录联接指向主副本。
- `scripts/fetch-upstream.ps1 -Check` 9 条 OK（2026-09-20）。

## 交付物

**1. 死代码（原则 1）**
- 删 `lib/app/smoke_screen.dart`（R3 起无引用，却在字体切换与深色模式两个提交里还被改过）。
- 删三个无人调用的 `pub fn`：`Core::adopt_connection`、`NodeStatus::usable`、`AgentServer::is_registry`。
- 删 `lib/ui/transcript/card_chrome.dart` 的 `TextAction`（整个类没人用；此前是公开的，analyzer 看不见）。

**2. 复用（原则 2）**
- `formatBytes` 三份 → 一份 `lib/ui/format.dart`（支持到 GB、null → 空串）；registry / 文件面板 / 内容块 / 附件芯片改引它。
- `write_atomic` 两份 → 只留 `rust/fs` 一份：`settings` / `registry` 加 `fs` 依赖，各补一条 `From<fs::FsError>`；
  settings 那份连同它的写盘测试删掉（fs 的测试覆盖同一形状）。
- `IconButtonGhost` 改成 `Hoverable` 上的 StatelessWidget 并带 `selected`；`PanelIconButton` 删掉，4 处调用改
  `IconButtonGhost(size: t.Geometry.panelIconButton)`。
- 只在自己文件里用的公开类改 `_` 前缀（38 个改名；9 个因出现在公开 API 签名里由 analyzer 判回公开：
  `ReplayClock` / `ConfigChoice` / `ConfigGroup` / `AwaitingKind` / `DiffLine` / `DiffKind` / `LinkRecognizers` /
  `TranscriptRow` / `TurnEndRow`）。私有化之后 analyzer 立刻报出 30 个从没人传过的可选参数（26 个 `super.key`、
  `_UsageRing.size`、`_TextAction` 的四个）——这正是「可见性过宽让死代码检测失效」那条的实证，一并删掉。

**3. 验收驱动挪出产品入口（原则 1 / 3）**
- 新增 `lib/main_headless.dart`：R3 / R5 / R6 三个无头模式 + 剪贴板探针从这里进（`flutter build -t`），
  没给模式变量时回落产品入口。`lib/main.dart` 只剩 smoke 自检（发布包的 `build.ps1 -Smoke` / `verify-package.ps1` 用它）。
- `lib/app/headless_run.dart`：三处复制的报告收尾合成 `_finish`；加 `ACP_CLIPBOARD_PROBE` 探针模式（规则 9 的实测口子）。
- `rounds/round-7.5/baseline/run-report.ps1` 头注释记新的构建命令；CLAUDE.md 仓库结构行、`validate.ps1` 注释同步。

**4. 剪贴板走 runner 原生通道（原则 4）**
- 新增 `windows/runner/acp_clipboard.{h,cpp}`：`OpenClipboard`（重试 10 × 20 ms）→ CF_HDROP 给路径列表；
  否则 CF_BITMAP 经 `GetDIBits` 取 32 位自上而下 BGRA（alpha 置不透明，与此前 `Image.FromHbitmap` 一致）。
  挂在既有的 `acp/window` 通道上（`readClipboardImages`）。
- `lib/app/clipboard_image.dart` 重写：不再拉 `powershell.exe`、不落临时目录、没有 15 s 超时；位图的 PNG 编码用
  `dart:ui`（`ImageDescriptor.raw` + `toByteData(png)`），大小门按编码后的 PNG 算。`AppWindow._invoke` 公开为 `invoke`。
- 新增 `test/app/clipboard_image_test.dart`（BGRA → PNG → 解回同色；尺寸不合回 null；无 runner 回空）。
- `docs/design.md` § 9 那一句、`composer.dart` 注释同步。

**5. base64 直接依赖（原则 5）**
- `rust/Cargo.toml` 工作区依赖加 `base64 = "0.22"`（Cargo.lock 里本就有 0.22.1，来自 reqwest 那条线；lock 只多 4 行边）；
  `acp-core` 与 `acp-smoke` 各删一份手写编码 / 解码与参考向量测试。CLAUDE.md 规则 1 与 `docs/requirements.md` 第 8 条的
  Rust 清单加 `base64`（所有者裁定 2026-09-20）。

## 验收

| # | 检查 | 命令 / 期望 | 结果 |
|---|---|---|---|
| 1 | 上游钉版本 | `scripts/fetch-upstream.ps1 -Check` 9 条 OK | PASS（2026-09-20，联接到主副本） |
| 2 | 全量验证 | `scripts/validate.ps1` → `VALIDATE OK` | PASS（整改后重跑）：15 项全 PASS，`flutter test` 346 项通过（整改前 343，+3 是第 1 轮 finding 2 带来的 mock 通道用例） |
| 3 | analyzer 零 warning、info 不多于 main 基线（14） | `flutter analyze` | PASS：14 条 info，与 main 基线逐条相同（全在 gallery / test），0 warning。中途曾多一条 `unnecessary_import`（`dart:typed_data`，foundation 已导出），已删 |
| 4 | Rust 侧 `--locked` | `cargo test / clippy -D warnings --locked` 全过 | PASS（Cargo.lock 只多 4 行：acp-core / acp-smoke → base64 0.22.1 的边） |
| 5 | 发布包不再带验收驱动 | `flutter build windows --release` 的 exe 在 `ACP_R3_REPORT` 下照常起窗口而不是进无头；`-t lib/main_headless.dart` 那份才进 | PASS：product 构建在 `ACP_R3_REPORT` 下 6 s 后仍活着且有主窗口（`alive=True mainWindow=13110254 reportWritten=False`）；headless 构建在同一变量下进 R3 模式，`ACP_R3_AGENT=no-such-agent` 使其 exit=1 并写出报告（`ok:false`，error「新会话失败…」）。AOT 快照 `data/app.so`：product 15,041,416 B，headless 15,270,792 B（多出的 229,376 B 就是三个驱动 + 探针） |
| 6 | 剪贴板位图（规则 9） | 探针：PowerShell 放一张已知颜色的位图 → `ACP_CLIPBOARD_PROBE` 报告里 `image/png`、尺寸对、左上角像素对 | PASS：`Clipboard::SetImage` 放 64×48 位图（左上红、其余蓝）→ 报告 `image/png`、201 B、64×48、`topLeftRgba [255,0,0,255]`（BGRA → PNG 的通道与行序都对） |
| 7 | 剪贴板文件列表（规则 9） | 探针：`SetFileDropList` 放一个含中文名的 PNG + 一个非图片 → 报告里只有那张 PNG、路径原样 | PASS：`SetFileDropList([截图 测试.png, notes.txt])` → 只有那张 PNG，`path` 原样 `D:\cargo-target\AcpAgentClient\quality\run\截图 测试.png`（UTF-16 → UTF-8 没丢字），224 B，解出 64×48、左上红；纯文本剪贴板 → `images: []`、`ok:true` |
| 8 | smoke 自检仍在产品入口 | `scripts/build.ps1 -Smoke` 过 | PASS：product 构建的 exe 在隔离 `APPDATA` 下 `ACP_SMOKE_REPORT` → exit 0，`ok:true`（init / ping / core_ready，coreVersion 1.3.0，droppedEvents 0） |

## 禁止

默认三条（不改样式 / 不加设计稿没有的功能 / 不改 `vendor/upstream/`）；另：不动 `lib/theme/tokens.dart`；不做第 6 / 7 项（只记 BACKLOG）；
`AcpButton` 等其它自带 hover 的 widget 不在本轮范围。

## 代码审查

- 审查方式：cursor-review.ps1（默认档）
- 审查器与模型：cursor CLI `cursor-grok-4.6-high-fast`
- 审查范围与基准提交：第 1 轮 branch `main...HEAD`（`8e9fb5a`）；第 2 轮 branch `main...HEAD`（整改后全量）；第 3 轮起 since `<上一轮已审提交>..HEAD`
- findings 处理：
  - **第 1 轮**（2026-09-20 18:08–18:13，产物 `.claude/reviews/20260920-180826-review.out.md`）：3 条（high 0 / P2 3 / P3 0），全部采纳整改：
    1. [P2] `encodePngFromBgra` 在拿到 frame 之前抛错会漏 `ImmutableBuffer` / `ImageDescriptor` / `Codec` → 四个 native 对象改成可空局部变量，`try` 从第一个对象建成前就开始、`finally` 逆序释放建成的那几个；编不出来回 null 而不是抛（否则外层 `catch` 会把整次粘贴收成空）。
    2. [P2] 位图在编码前没有大小门：超大 `CF_BITMAP` 让 runner 按 width×height×4 分配，`bad_alloc` 穿过 MethodChannel 回调会 terminate 整个进程（旧的 PowerShell 是独立进程，炸了只丢这一次粘贴）→ C++ 加 `kMaxBitmapBytes`（256 MB，8K 整屏 133 MB 在内）：超过只回尺寸不给像素；`AcpClipboardReadImages` 整体 `try / catch (std::exception)` 回空列表；Dart 侧按同一个数（`clipboardBitmapBytesLimit`）判成 `skippedTooLarge`，不先编码再量。加 mock 通道用例覆盖「只回尺寸」这条路。
    3. [P2] `From<fs::FsError>` 吃的是 Display 全文：settings 对外变成 `settings: io: fs: io: <inner>`，registry 从 `Settings` 变体变成 `Io("fs: io: …")` → 两处改成只取 `FsError::Io` 的内层文案；registry 落 `Io` 变体（`CoreError::code()` 对 `Settings` / `Io` 都是 `registry`，没有行为差别，文案从 `settings: io: <inner>` 变 `io: <inner>`）。
  - **第 2 轮**（2026-09-20 18:23，全量 `main...HEAD` 到 `a61981f`，产物 `.claude/reviews/20260920-182321-review.out.md`）：2 条（high 0 / P2 1 / P3 1），全部采纳整改。第 1 轮那 3 条的整改本身经复核成立（`item` 在 `std::move` 之后不再用、`catch` 里 `items.clear()` 清的是未完成的这一次、settings 对外仍是 `settings: io: <inner>`）。
    1. [P2] 第 1 轮 finding 2 的整改把**两道门共用了一个 `skippedTooLarge` 旗标**，而 `ComposerState` 的提示文案写死 `clipboardImageSizeLimit`（20 MB）：一张 9000×9000 的位图（像素 324 MB，但 PNG 可能只有几百字节）会被报成「图片超过 20 MB」→ 文案改成不写死数字的「图片太大，没有加进输入框」（两道门的数不一样，写死任一个都会谎报）；顺带把「runner 少给 `bgra`」从尺寸门里分出来静默跳过（形状不对不是尺寸问题）。旗标本身保留：静默丢图比文案不精确更糟。
    2. [P3] `rounds/BACKLOG.md` 那条剪贴板条目的句尾还写着「每次粘贴要拉一次 powershell（几百毫秒）」→ 改成「剪贴板里是文本时提前 return，不去读位图」。
  - **第 3 轮**：待填（范围 `a61981f..HEAD`，只审整改 diff）
- 结论：待填

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-quality/BLOCKED.md`，停下呼人。

## 本轮实测

**数字**：49 个已有文件改动 +6 新文件，+347 / −432 行（净减 85 行；其中 `Cargo.lock` +4）。`flutter test` 343 项、`cargo test --locked` 全过、
`clippy -D warnings --locked` 干净、analyzer 14 条 info 与 main 基线相同。product / headless 两份 release 构建（同一台机，
共用 `D:\cargo-target\AcpAgentClient`）。

**Windows 实测（规则 9）**：脚本随卡入库（`build-and-test.ps1` 起两份构建 + smoke + 探针；`clip-test.ps1` 用
`System.Windows.Forms.Clipboard` 放位图 / 文件列表 / 纯文本，再跑 headless 构建的 `ACP_CLIPBOARD_PROBE`）。跑法：

    powershell -NoProfile -File rounds\round-quality\build-and-test.ps1      # 路径写死在脚本头，换机器改两行

四份报告在 `D:\cargo-target\AcpAgentClient\quality\run\probe-*.json` 与 `smoke-report.json`（不入库），关键值已抄进验收表。
剪贴板的 Ctrl+V 产品路径（`ComposerState.pasteImageFromClipboard` → `readClipboardImages` → 芯片）本轮没有改，只换了
`readClipboardImages` 的实现；GUI 粘贴仍归所有者手测（本机没有 GUI 自动化通道，见 BACKLOG 的 `computer-use` 条）。

**踩的坑**
1. **runner 里新加的 C++ 源文件含中文注释必须带 UTF-8 BOM**：MSVC 在 GBK 代码页下按本地编码读无 BOM 的 UTF-8，C4819 在
   `/WX` 下变成 C2220，后面跟着一百多条把注释里的字节当代码解出来的语法错误（`acp_window.cpp` 本身就是带 BOM 的，
   新文件照抄这一点即可）。与 CLAUDE.md「含中文的 `.ps1` 必须 UTF-8 with BOM」是同一个坑。
2. 私有化那 38 个类之后 analyzer 才报出 30 个从没人传过的可选参数——`super.key` 有三种写法（行内、独占一行、尾随），
   批处理脚本按 analyzer 给的行号从大到小改，避免删行后行号漂移。
3. `library_private_types_in_public_api` 把 9 个类判回公开（它们出现在公开函数的返回值 / 公开 widget 的字段里），
   不是靠肉眼判的，是 analyzer 判的；`TranscriptRow` / `TurnEndRow` 与 `EntryRow` 保持同一可见性。
4. python 改完的两个 `.ps1` 行尾变成 LF（`.gitattributes` 要 CRLF），提交前转回；仓库里存的是 LF，diff 不受影响。

**偏离**：`write_atomic` 合并的方向是「`settings` / `registry` 依赖 `fs`」而不是反过来（原语在 fs 才顺；registry 本来就在跨 crate
调这个函数）。`IconButtonGhost` 改走 `Hoverable` 后整个方块都是点击热区（原来 `GestureDetector` 默认 `deferToChild`，只有
图标本身可点）——这是对齐悬浮高亮的范围，不是回归。

**BACKLOG 冲突面**：本分支只在 `rounds/BACKLOG.md` 上把两条剪贴板条目标成 `[x]` + 结论、改一条措辞、行数门那条补注、末尾追加四条；
R8 分支的未提交改动正在把 `[x]` 条目拆到 `BACKLOG-CLOSED.md`，后合并的一方要把这几行照那份新约定挪一下。

