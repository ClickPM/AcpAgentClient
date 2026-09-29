# Flutter 与 Windows 的坑

> 相关：`AGENTS.md`「本地开发」（命令表 / `objective_c` override / 开发者模式 / 非 ASCII 路径）、
> [`build-and-cache.md`](build-and-cache.md)、[`harness-pitfalls.md`](harness-pitfalls.md)（工具栈专属的那些）。

这里的每条都是「命令看着正常、结果是挂死或假失败」那一类。R0（2026-09-15）起在本项目逐条实测。

## 1. 构建与运行

- **开发者模式**：未开启时 Flutter 给 pub 插件建符号链接会失败，`flutter pub get` 直接报错。
  判据 = 注册表 `AppModelUnlock\AllowDevelopmentWithoutDevLicense`。R0 开工时没有，因此把 cargokit 直接挂进
  `windows/CMakeLists.txt`（不走 frb 的 `rust_builder` 插件）—— **这个 runner 级布局保留不改**。
  所有者 2026-09-15 已开启（R3 起引入 url_launcher / file_selector 无障碍）。换机器第一件事就是看它。
- **项目路径含中文 / 空格时 `flutter build windows` 必败**：不是 Rust 那段，是 Flutter 自己的 `flutter_assemble`
  MSBuild 规则把路径按 GBK 转码成 `锟斤拷`（报 `Unable to read file: D:\锟斤拷锟斤拷 目录\...\.dart_tool\flutter_build\...\app.dill`）。
  `scripts/build.ps1` 用 `mklink /J` 建 ASCII 目录联接后从联接路径构建可过。失败一次后要清
  `build/ .dart_tool/ windows/flutter/ephemeral/`（会留下空的 `cpp_client_wrapper/`，不清会连续失败）。
- **超长路径下 CMake 直接失败**：`flutter build windows` 在 `%TEMP%\claude\...\scratchpad` 这种路径下报
  「CMake will not be able to correctly generate this project」（日志 GBK 乱码看不出原因）。换到
  `D:\cargo-target\AcpAgentClient\<name>` 短 ASCII 路径就过。一次性测试 app 就放那里。
- **只有 Dart 改动时 `acp_agent_client.exe` 与 `acp_bridge.dll` 的时间戳不会变**，别误判成「没构建上」：
  C++ runner 与 Rust cdylib 源码没动就不重链，Dart 全部 AOT 进 `data\app.so`（看它的时间戳与 `data\flutter_assets\` 才算数）。
  同理，新加的随包资源要去 `data\flutter_assets\` 与 `FontManifest.json` 里核。
- **无控制台的 Windows GUI 进程里 Dart `stdout` 句柄无效**：写入 / flush 卡住，后面的 `exit()` 执行不到，进程挂着不退。
  无头自检只靠**报告文件**，stdout 单独 try/catch、不影响退出码。
- **别信管道尾部的退出码**：`cmd | Select-String -Pattern ...` 的模式一旦非法（比如末尾裸 `\`），上游命令根本不会执行，
  而 `$LASTEXITCODE` 还是上一条命令的 0 —— R0 有两次「smoke 通过」就是这么记假的，被复审用 `app.so` / 报告文件的时间戳抓出来。
  **判构建 / smoke 是否跑过，看产物 mtime**；过滤输出用 `Out-File` 落日志再 `Get-Content | Where-Object`。

## 2. `flutter test` 与 gallery

- **测试 zone 是 FakeAsync**：`runAsync` 之外的真实文件 IO（`File.writeAsBytes`）**永远不完成**，进程挂死、没有任何输出。
  写文件用同步 API；`toImage` / 字体加载放 `runAsync`。
- **flutter_tester 不装包内字体、不装 Material 图标字体、不做平台字体回退**：黑色实心方块 = 字体家族不存在
  （回落到 Ahem 测试字体），空心方块 = 字体缺字形（CJK 无回退）。**别把方块当成库的缺陷记进 findings。**
  截图测试里要手动 `FontLoader`：包字体的家族名是 `packages/<pkg>/<family>`、资源路径 `packages/<pkg>/lib/...`
  （flutter_math_fork 的 KaTeX 13 个家族就是这么装的）；`Icons.*` 一律显示成方块，画板对照的图标用 CustomPaint / SVG。
  CJK 要从 `C:\Windows\Fonts\msyh.ttc` 手动 `FontLoader`。写法沿用 `test/spike/_harness.dart`。
- **gallery 一次只能出一张**：`flutter test test/gallery_test.dart --plain-name <id>`；
  同一条命令带多个 `--plain-name` 或改用 `--name <regex>` 都**匹配不到任何用例**（0 张图、不报错）。逐张跑。
- **两个 `flutter test` 同时跑会互相卡死**（dartvm 进程都在、都不动），只能 `taskkill` 掉 dart/dartvm 再串行跑；
  `flutter build` 与 `flutter test` / `analyze` 也别并行。**并发会话里更要注意别和对方的 `flutter test` 撞 `.dart_tool`。**
- **全量 `flutter test` 偶发报两三个文件 `loading <path>` 失败**（不是断言失败，是加载阶段炸）；单跑那几个文件全过。
  这是它自己并行编译测试文件的锅，`flutter test --concurrency=1` 串行跑就稳（2026-09-17 复现）。**别把这种失败当成自己改坏了。**
- **计时类测试要单独一个文件单独跑**，否则数字被别的文件抬高 1.5–3 倍。
- **`SelectionArea` 跨块选择可以在 widget test 里验**：`startGesture(kind: mouse)` → `moveTo` → `up`，
  `onSelectionChanged` 拿 `plainText`；无界高度的宿主用 `SingleChildScrollView(clipBehavior: none)` 包 `RepaintBoundary`，
  `toImage` 得到内容尺寸的 PNG（`OverflowBox(maxHeight: infinity)` 会让个别库的 WidgetSpan 断言）。
- **RichText 的 `TapGestureRecognizer` 只在最内层 TextSpan 生效**：挂在带 children 的父 span 上永远不触发；
  链接要把 recognizer 下推到每个叶子。测试里点链接别点整段文字 widget 的中心（撑满行宽时中心是空白），用 `getTopLeft + 偏移`。
- **`objective_c` / path_provider 链条**见 `AGENTS.md`「本地开发」：任何把 `path_provider` 拉进来的包都会复发
  `Building native assets` 阶段的整体失败，要继续带 `dependency_overrides: objective_c: 9.4.1`。

## 3. 「改完画板有没有变」要字节比，不要肉眼比

`git worktree add --detach <scratch> <基线 sha>` → 在那个临时副本里 `flutter test test/gallery_test.dart` **全量出一遍图**
（45 张约 20 秒，比逐张 `--plain-name` 快得多）→ `md5sum` 与本分支的 `build/gallery/` 对。
**不要用 `git stash`**：stash 栈是全仓库共享的，别的会话会 pop 掉。完事 `git worktree remove --force`。（2026-09-22 实测）

## 4. 无头真跑（`ACP_R3_REPORT` 口子）

用 `$p = Start-Process <exe> -PassThru; $p.WaitForExit()`。
**`Start-Process -Wait` 会等整个子进程树**，agent 的 node 子进程或本地 shell 没收干净时脚本就「挂住」。

一次跑失败要先 `Get-Process acp_agent_client` 看有没有残留实例 —— exe 被占着时 `build.ps1` 报失败但旧 exe 还在，
**下一次跑的还是旧代码**。含中文的脚本存 UTF-8 with BOM。跑真跑前后各查一次进程表。

## 5. 无边框窗口：拉不动边框的根因是 FLUTTERVIEW 子窗口

（2026-09-18 实测）子窗口铺满整个客户区，系统对**真实鼠标**的命中测试只问它、它回 `HTCLIENT`，
顶层 runner 的 `WM_NCHITTEST` 压根轮不上 —— 不是热区宽度的问题。
修法是给子窗口 `SetWindowSubclass`，落在缩放带里回 `HTTRANSPARENT`（`windows/runner/acp_window.cpp`）。

**排查时最容易被骗的一点**：从外部 `SendMessage(hwnd, WM_NCHITTEST, ...)` 探顶层**永远回正确的** `HTLEFT` / `HTBOTTOMRIGHT`，
看起来完全正常 —— 那条路绕过了子窗口。要判真假只能看真实输入：

- `SendInput` 注入拖拽后比对 `GetWindowRect`，再用「顶栏拖拽能移动窗口」当对照组。
- 悬停时 `GetCursorInfo` 还是 `ARROW`，就是系统没用我们的命中结果。
- `mouse_event` 那套不可用，要用 `SendInput` + 正确的 `INPUT` 布局（**x64 是 40 字节**，多塞 padding 字段会 `LastError=87` 静默失败）。
- `Start-Process` 起的 app 会继承调用方的 STARTUPINFO 显示状态（实测起来是最小化 / 最大化），
  每次测前先 `ShowWindow(9)` + `SetWindowPos` 定尺寸并核对 —— **最大化时 `HitTest` 按设计回 `HTCLIENT`，不复位就会把「正常行为」当成 bug**。

**runner 里新加的 C++ 源文件含中文注释必须带 UTF-8 BOM**（quality 轮 2026-09-20 实测）：MSVC 在 GBK 代码页下按本地编码读无 BOM 的 UTF-8，
C4819 在 `/WX` 下变 C2220，后面跟一百多条把注释字节当代码解出来的语法错误（`error C2059: 语法错误:"for"` 之类），
**表现像文件整个写坏了**。`acp_window.cpp` 本身带 BOM；新文件用 Write 工具生成后要补上（`head -c 3 | xxd` 看 `efbbbf`）。
与「含中文的 `.ps1` 必须 BOM」是同一个坑。**`windows/runner/main.cpp` 里临时加的注释只能写 ASCII**，全角字符同样触发 C4819 → C2220。

## 6. 真窗口里测 GPU / CPU

iteration-14（2026-09-24）实测常驻动画成本时搭的一套，脚本留在 `D:\cargo-target\AcpAgentClient\iter14\`
（`driver.ps1` 点源、`measure.ps1` 采样）：

- **隔离环境**：`APPDATA` 指到 D 盘的模板副本，里面放
  `settings.json`（`agent_servers.fake` = `type: custom` + node 绝对路径 + `test/fake-agent/fake-agent.mjs --hang-on-prompt`，
  `env.FAKE_AGENT_AUTHED=1`）、`projects.json`（一条项目 → 启动自动打开）、
  `sessions.json`（一条 `agentId=fake` 的旧会话 → 「当前 agent」选中 fake）。
  启动即停在「New fake Session」空态，发一条纯数字消息（避开中文输入法）回合就永远挂着。
- **computer-use 用不上**：它只认开始菜单里已安装的应用，便携 exe 授权不了；改用 PowerShell 的 Win32
  （Alt 键 + `SetForegroundWindow`、`PrintWindow(…, 2)` 只截测试窗口、`SetCursorPos` + `mouse_event`、`SendKeys`）。
  **先确认 `Focus-Window` 返回 True 再点击输入**，否则按键会落到别的窗口。
- **release 构建不认 `FLUTTER_ENGINE_SWITCHES`**（`engine_switches.cc` 整段 `#ifndef FLUTTER_RELEASE`）：
  要关 Impeller 得临时改 `windows/runner/main.cpp` 加 `project.set_impeller_switch(flutter::ImpellerSwitch::Disabled)`。
- 采样：`Get-Counter '\GPU Engine(*pid_<pid>*)\Utilization Percentage'` 取 `engtype_3d` 求和；CPU 用 `TotalProcessorTime` 差值。
- **别用记事本抢焦点测「失焦」**：Win11 记事本启动时会恢复上次的窗口与标签页，
  把所有者的私人文件（2026-09-24 那次是一个恢复码 txt）摆到屏幕上，而且 `notepad.exe` 的 PID 转手给商店版进程、按 PID 拿不到窗口。
  要一个无副作用的前台窗口就自己起一个空 WinForms 窗体。
