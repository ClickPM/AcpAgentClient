# Iteration 14 — 风扇狂转（二）：常驻动画走共用低频时钟

<!-- 保存为 iterations/iteration-NN.md。一个迭代一个文件、一项一行；流程正本见 iterations/README.md，不在这里复述。 -->

> 状态：进行中　起止：2026-09-24 –　基线：`main` = `ec0678a`

所有者 2026-09-24 报障：agent 跑长命令（十几分钟）期间风扇一直狂转、发热。实测是安装版 v1.4.5 自己在烧：
agent 进程 CPU 为 0、键鼠 30 秒没动，应用仍占 AMD 780M 核显 3D 引擎 ~72%、CPU ~1.4 核（dwm 与 System 的 copy 引擎在同一块卡上再陪 ~14% / ~17%）。
iteration-02 第 7 项给 `Spinner` 与侧栏扫掠线加的 `RepaintBoundary` 已在这个构建里，没有压下来。所有者看过调研与方案后裁定「按推荐改」（第一档 + 第二档 A 只测），
第二档 B 与第三档记 BACKLOG。契约零 diff、没有新依赖。

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | fix | 常驻动画（`Spinner`、侧栏扫掠线）不再逐帧跑：改挂共用低频时钟 `AmbientClock`（`lib/ui/shell/motion.dart`），一个定时器、一跳只出一帧，按窗口状态分档（前台 `Motion.ambientInterval` ≈ 15 跳/秒、失焦 `Motion.ambientIntervalInactive` 4 跳/秒、最小化停表），没有订阅者时定时器不存在；相位按帧时间戳取模；`TickerMode` 关掉的子树不订阅。新单测 `test/ui/ambient_clock_test.dart`；`validate.ps1` 加静态门「`lib/` 里不许 `.repeat(`」 | 所有者报障 2026-09-24 | `claude/ambient-motion-throttle` | | | 进行中 |
| 2 | tidy | 实测：同一场景（fake-agent `--hang-on-prompt`，隔离 `APPDATA`）改前 / 改后的核显与 CPU；外加 Impeller 开 / 关对照（只测不改） | 同上（第二档 A） | 同上 | — | — | 进行中 |

## 收口

- 构建 / 手测：
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

### 实测

（待填：改前 / 改后 / Impeller 对照，命令与输出。）
