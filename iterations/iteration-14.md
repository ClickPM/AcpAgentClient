# Iteration 14 — 风扇狂转（二）：常驻动画走共用低频时钟

<!-- 保存为 iterations/iteration-NN.md。一个迭代一个文件、一项一行；流程正本见 iterations/README.md，不在这里复述。 -->

> 状态：已合并（未构建，不发版；所有者 2026-09-24 指示）；Impeller 取舍待裁定　起止：2026-09-24 –　基线：`main` = `ec0678a`

所有者 2026-09-24 报障：agent 跑长命令（十几分钟）期间风扇一直狂转、发热。实测是安装版 v1.4.5 自己在烧：
agent 进程 CPU 为 0、键鼠 30 秒没动，应用仍占 AMD 780M 核显 3D 引擎 ~72%、CPU ~1.4 核（dwm 与 System 的 copy 引擎在同一块卡上再陪 ~14% / ~17%）。
iteration-02 第 7 项给 `Spinner` 与侧栏扫掠线加的 `RepaintBoundary` 已在这个构建里，没有压下来。所有者看过调研与方案后裁定「按推荐改」（第一档 + 第二档 A 只测），
第二档 B 与第三档记 BACKLOG。契约零 diff、没有新依赖。

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | fix | 常驻动画（`Spinner`、侧栏扫掠线）不再逐帧跑：改挂共用低频时钟 `AmbientClock`（`lib/ui/shell/motion.dart`），一个定时器、一跳只出一帧，按窗口状态分档（前台 `Motion.ambientInterval` ≈ 15 跳/秒、失焦 `Motion.ambientIntervalInactive` 4 跳/秒、最小化停表），没有订阅者时定时器不存在；相位按帧时间戳取模；`TickerMode` 关掉的子树不订阅。新单测 `test/ui/ambient_clock_test.dart`；`validate.ps1` 加静态门「`lib/` 里不许 `.repeat(`」 | 所有者报障 2026-09-24 | `claude/ambient-motion-throttle`（`c00f442` + 回填）→ `main` 快进 | validate 全绿（569 项 flutter test）；`build.ps1` release 构建 + 实机实测（见备注） | 1 轮：**0**（cursor `grok-4.7-high-fast`，`.claude/reviews/20260924-131415-review.out.md`） | 已合并 |
| 2 | tidy | 实测：同一场景（fake-agent `--hang-on-prompt`，隔离 `APPDATA`）改前 / 改后的核显与 CPU；外加 Impeller 开 / 关对照（只测不改） | 同上（第二档 A） | 同上（只动本文） | 两轮实测，数据一致 | —（登记文档） | 已合并 |

## 收口

- 构建 / 手测：2026-09-24 `scripts/build.ps1` 通过（本分支 `c00f442`；另有一份关 Impeller 的对照构建只用于实测，`main.cpp` 构建后即还原、未提交）。所有者手测项（真 agent，Windows）：
  1. **跑长命令时风扇**：让 agent 跑一条几分钟的命令，窗口留在前台 → 风扇不再持续狂转；任务管理器「GPU」列里本应用个位数。
  2. **转圈与扫掠线的观感**：会话头 / 卡片上的 spinner 与侧栏扫掠线约 15 帧/秒步进（spinner 每步 30°），能接受就不调；想更顺改 `Motion.ambientInterval`。
  3. **失焦 / 最小化**：切到别的窗口时动画明显放慢（4 帧/秒），最小化再还原后照常转。
- **待裁定**：Windows 上关掉 Impeller（`windows/runner/main.cpp` 设 `ImpellerSwitch::Disabled`）——同一场景每帧 GPU 成本约为 Skia 的 2.4 倍（备注「实测」）；过了方案定的「差一倍以上」门槛，但官方说这个开关以后会移除，且要对画板做一遍视觉核对。所有者定做不做。
- 发版：待定（所有者定）。
- 移出项去向：第二档 B（读 Windows「动画效果」与节电模式，降成静态指示）、第三档（长任务显示已用时间）记 `rounds/BACKLOG.md` P2，待所有者裁定。
- 设计稿补注记：`design/DIVERGENCE.md` 第 35 条（常驻动画按低帧率步进，画板写的是连续匀速）。

## 备注

### 根因（Flutter 3.47.4 源码核实 + 调研）

- **Windows 嵌入层没有局部重绘**：`engine/src/flutter/shell/platform/windows/compositor_opengl.cc` 的 `Present` 每帧把整张后备缓冲 blit 到窗口再 `SwapBuffers`，整个目录里没有任何 damage 跟踪（`grep -rl damage` 为空）。`RepaintBoundary` 只省重录，省不了合成与上屏。
- **帧率跟显示器走、应用设不了上限**：`flutter_windows_engine.cc` 的 `FrameInterval()` 取 `DwmGetCompositionTimingInfo` 的刷新率；唯一的覆盖口子 `frame_interval_override_` 只给测试用。flutter/flutter#171880（165Hz 下一个 `CircularProgressIndicator` 占 GPU 80–85%，团队成员答复「目前没有办法调」）、#159797（FPS 上限，P3 未做）。
- **最小化已自动停帧，失焦不停**：`windows_lifecycle_manager.cc` 把 `SIZE_MINIMIZED` / `WM_SHOWWINDOW(0)` 映射成 `hidden`、`WM_KILLFOCUS` 映射成 `inactive`；`SchedulerBinding.handleAppLifecycleStateChanged` 只在 `hidden` / `paused` / `detached` 停帧。被别的窗口挡住不报。
- **Windows 的「动画效果」开关传不到 Dart**：`FlutterWindowsEngine::SendAccessibilityFeatures` 只发 HighContrast，`MediaQuery.disableAnimations` 在 Windows 上恒 false——扫掠线的 reduced-motion 分支在 Windows 上走不到（第二档 B 的由来）。
- **Impeller 在 Windows 上默认开**（`flutter_windows_engine.cc` 里 `enable_impeller = true`，走 ANGLE 的 GLES）；Windows 上的 Impeller 还有两条未关的变慢（#191353、#192994：同一画面 Impeller 光栅 30ms、Skia 2.7ms）。
- 同类做法：VS Code 光标闪烁 13% CPU 改 `setInterval`（microsoft/vscode#22900）；lottie-flutter 定时器节流 120 → 30 fps、CPU 13.8% → 6.3%（xvrh/lottie-flutter#426）；Zed GPUI 失焦窗口 30 fps（`WindowOptions.inactive_frame_interval`），它自己的 agent 面板 spinner 也有同一个 issue（zed#55949）。

### 实测（2026-09-24，Windows 11，Radeon 780M 核显，显示器 120Hz；规则 9 口径）

同一场景、同一窗口尺寸（隔离 `APPDATA` 的首启缺省 1280×720 逻辑 = 2240×1260 物理像素）：fake-agent `--hang-on-prompt` 挂住回合，
屏上是会话头 spinner + 侧栏扫掠线 + 顶栏在跑数（与所有者截图里「终端卡在跑、回合挂着」同一类常驻动画）。每组 8 × 2 秒采样取均值；
测了两轮，第二轮在机器上没有别的本应用实例时重跑，并逐次记下渲染所在的显卡（三份都在 LUID `0x131a3` = AMD 核显，dwm 也在这块）。

| 构建 · 窗口状态 | 核显 3D 引擎（第 1 轮 / 第 2 轮） | CPU 占单核（第 1 轮 / 第 2 轮） |
|---|---|---|
| v1.4.5 安装版副本（改前，Impeller）· 前台 | **45.8% / 44.6%** | 72.0% / 66.0% |
| v1.4.5 · 最小化 | 1.7% | ~3% |
| 本分支 `c00f442`（Impeller）· 前台 | **6.0% / 5.9%**（第 1 轮另有一次复测 5.9%） | 11.5% / 10.2% |
| 本分支 · 失焦（别的窗口在前台） | 1.5% | 6.0% |
| 本分支 · 最小化 | 0.1% | 2.5% |
| 本分支关 Impeller（Skia，仅对照构建）· 前台 | **2.5% / 2.5%** | 8.7% / 8.0% |

- 改前 → 改后（前台）：核显 −87%、CPU −85%。改前不分前台 / 失焦（逐帧 ticker 不看窗口状态），改后失焦再降到 1.5%。
  所有者自己的窗口更大（最大化），改前是 72%。
- **Impeller vs Skia**：同为 ≈ 15 帧/秒时核显 6.0% vs 2.5%，每帧 GPU 成本 Impeller ≈ Skia 的 2.4 倍（CPU 差得少）；与 flutter/flutter#192994 方向一致。只测不改，见收口段「待裁定」。
- 所有者在实测期间把自己那份安装版（`D:\tools\AcpAgentClient\acp_agent_client.exe`）在 Windows「图形设置」里改成了独显：那条设置按 exe 完整路径生效
  （`HKCU\Software\Microsoft\DirectX\UserGpuPreferences`），测试副本在 `D:\cargo-target\...\iter14\bin-*\` 下不受影响；第 2 轮按显卡记录复核过，结论不变。
  第 1 轮最早一次基线采样（23–38%，窗口多数时间不在前台、与所有者那份抢核显）作废，未计入。
- 做法：`D:\cargo-target\AcpAgentClient\iter14\`（不入库）——`appdata-template/`（`settings.json` 一条 custom agent `fake`、`projects.json` 一条项目、
  `sessions.json` 一条 agentId=fake 的旧会话，让启动即选中项目与 fake）、`driver.ps1`（Win32：Alt + `SetForegroundWindow`、`PrintWindow` 只截测试窗口、
  `SetCursorPos` + `mouse_event`、`SendKeys "123{ENTER}"`）、`measure.ps1`（`Get-Counter '\GPU Engine(*pid_<pid>*)\Utilization Percentage'` 的 `engtype_3d` 求和 +
  `TotalProcessorTime` 差值）。关 Impeller 的对照构建是临时在 `windows/runner/main.cpp` 加 `project.set_impeller_switch(flutter::ImpellerSwitch::Disabled)`，
  构建后立即 `git checkout` 还原（release 构建不认 `FLUTTER_ENGINE_SWITCHES`：`engine_switches.cc` 整段 `#ifndef FLUTTER_RELEASE`；注释只能写 ASCII，全角字符触发 C4819 → C2220）。
