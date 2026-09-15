# Round 00 — 脚手架、token 表与契约检查

> 状态：已完成（审查收口 2026-09-15；待合并 `main`）

## 目标

Flutter Windows 桌面项目与 `rust/` workspace（cdylib）经 frb v2 打通一次命令（`ping`）+ 一条事件流（`acp/agent_state`）往返；`tokens.dart` 从 `00-tokens` 逐值提炼；fixtures / gallery / validate / build 四套基础设施落地；`flutter build windows --release` 在本机通过，并在含中文与空格的目录再过一次。范围 = ROUNDS.md § 3「R0」。

## 前置

- `scripts/fetch-upstream.ps1 -Check` 全绿（2026-09-15 实测 8 个 OK）。
- 本机：Flutter 3.47.4 stable / Dart 3.13.3、Rust 1.98.1（`rust-toolchain.toml` 钉）、`flutter_rust_bridge_codegen` 2.13.0、cargo-expand 1.0.126、Node 24.11.1、CMake 4.4.3、VS 2022 生成工具 17.14（C++ 桌面工作负载）。
- 无参照 agent。

## 交付物

| 路径 | 内容 |
|---|---|
| `pubspec.yaml`、`analysis_options.yaml`、`.metadata` | Flutter 项目；依赖只有 `flutter_rust_bridge 2.13.0`（dev：flutter_test、flutter_lints）；字体资产声明 |
| `flutter_rust_bridge.yaml` | `rust_input: crate::api`、`rust_root: rust/bridge/`、`dart_output: lib/bridge` |
| `rust-toolchain.toml` | `1.98.1` + rustfmt / clippy |
| `rust/Cargo.toml` | workspace：`bridge`（包名 `acp_bridge`，cdylib）、`acp-core`、`registry`、`pty`、`fs`、`settings`、`tools/acp-smoke`；rust-sdk 以 git rev 钉到 `pins/upstream.json` 的 commit，feature `unstable`；workspace lint `unsafe_code = deny` |
| `rust/bridge/src/api.rs` | `core_init(data_dir)`、`ping(echo)`（async）、五条 `StreamSink<String>` 注册、`dropped_event_count`；`BridgeError {code, message}`；`catch_unwind` 兜底 |
| `rust/bridge/src/runtime.rs` | sink 表与唯一 `Core` 实例（在 `api` 之外，不被 frb 扫描） |
| `rust/bridge/src/frb_generated.rs`、`lib/bridge/*.dart` | frb 生成物，入库 |
| `rust/acp-core` | `Core`（tokio runtime、数据目录、`ping`、`core_ready` 事件）、`EventChannel` / `EventSink`、`CoreError`、`meta_keys`（`_meta` 键唯一出处）；`tests/fixtures.rs` |
| `rust/registry` / `pty` / `fs` / `settings` | 空壳：错误枚举 + `Result` 边界 + 主结构体签名，标注填实轮次 |
| `rust/tools/acp-smoke` | `acp-smoke ping [--data-dir] [--echo]`，事件按 JSON 行打 stdout；R1 扩 |
| `lib/main.dart`、`lib/app/` | 组合根：`CoreBridge`（加载 cdylib、订阅五条流、JSON 解码）、`paths.dart`（数据目录）、`smoke.dart`（`ACP_SMOKE_REPORT` 无头自检）、`smoke_screen.dart`（R0 开发页，R3 替换） |
| `lib/theme/tokens.dart` | 见下方对照表 |
| `assets/fonts/` | `Geist-Variable.ttf`、`GeistMono-Variable.ttf`（google/fonts `ofl/geist`、`ofl/geistmono`，OFL 1.1，`OFL-*.txt` 入库） |
| `lib/projection/wire.dart`、`fixture_line.dart` | 15 变体 + 5 内容块 + 3 工具卡内容 + permission / elicitation 形状的薄封装；fixtures 行封装 |
| `test/fixtures/*.jsonl` + `README.md` | 61 行，9 个场景文件；`90-rejected.jsonl` 是 `notice` 与 `artifact_update` 两条故意行 |
| `lib/gallery/` + `test/gallery_test.dart` | 画板 00 样板页；离屏渲染到 `build/gallery/00-tokens.png` |
| `test/projection/wire_test.dart`、`test/app/paths_test.dart` | Dart 单测 |
| `scripts/validate.ps1`、`scripts/build.ps1` | 验证门与 release 构建（`-Smoke` 跑无头往返） |
| `windows/` | `flutter create` 的 runner；`windows/CMakeLists.txt` 里 `apply_cargokit` + install 规则 |
| `cargokit/` | frb 2.13.0 模板自带的 cargokit 副本；`cmake/cargokit.cmake` 加了 `CARGO_TARGET_DIR` 补丁（有注释） |

### 与 ROUNDS.md 拆解的偏离

1. **Rust 核心不走 pub 插件（`rust_builder`）。** frb 标准集成把 cargokit 包在一个 ffi 插件里，`flutter pub get` 要给插件建符号链接，Windows 上需要开发者模式；R0 开工时本机未开启（`AppModelUnlock\AllowDevelopmentWithoutDevLicense` 不存在），`flutter_rust_bridge_codegen create` 的模板工程在本机也因此失败；所有者已于 2026-09-15 当天开启（注册表值 = 1，同一模板工程 `flutter pub get` 通过），R0 的 runner 级布局保留不改。改为在 `windows/CMakeLists.txt` 直接 `apply_cargokit(acp_bridge_ffi ../rust/bridge acp_bridge "")` 并 `install(FILES …)` 把 `acp_bridge.dll` 放到 runner 旁；Dart 侧 `frb_generated.dart` 按 stem `acp_bridge` 加载。macOS（R8）要在 Xcode 侧另加 cargokit 脚本阶段。R3 起引入 url_launcher / file_selector 时仍需开发者模式，已告知所有者。
2. **包名 `acp_bridge`，目录仍是 `rust/bridge`。** frb 与 cargokit 都拿 `[package].name` 当 DLL 名（`bridge.dll` 太泛），`cargo tree -p acp_bridge`。
3. **`acp/agent_state` 多一个 `core_ready`。** 验收第 2 项要求核心主动推一条事件；R1 前没有 agent 生命周期，`Core::new` 与幂等的 `core_init` 各发一条 `{agentId: null, state: "core_ready", dataDir, coreVersion, droppedUpdates: 0}`，形状对齐 R1 的 payload。已补进 `docs/design.md` § 3。
4. **`cargokit/cmake/cargokit.cmake` 改了一处**：`CARGO_TARGET_DIR` 环境变量存在时用它作 cargo `--target-dir`（原版固定在 CMake 二进制目录，即项目路径之下，与所有者「纯 ASCII 路径」裁定冲突）。
5. **`rust-toolchain.toml` 钉 `1.98.1`，但 cargokit 固定用 `rustup run stable`**（它的 `toolchain` 选项只认 stable / beta / nightly）。本机 stable = 1.98.1，两者一致；stable 升级后 Flutter 构建会用新版，`validate.ps1` 的 cargo 用钉版本。记 BACKLOG。
6. **fixtures 里的假密钥改成显式假值**（`FAKE-TOKEN-FOR-REDACTION-TEST`），避免密钥扫描误报（规则 8）。

## tokens.dart 对照表（token 名 → 00 画板位置 → 值）

| tokens.dart | 00 画板位置 | 值 |
|---|---|---|
| `Neutral.canvas / panel / surface / hoverSolid / borderSubtle / border / placeholder / muted / text / strong` | 中性色阶 · 浅色，n.* 十格 | `#fbfbfc #f4f4f6 #eeeef1 #e7e7eb #e2e2e7 #d3d3da #8b8b96 #62626e #33333d #1e1e26` |
| `Dark.canvas / panel / surface / hoverSolid / borderSubtle / border / placeholder / muted / text / accent` | 中性色阶 · 深色，d.* 十格 | `#17171c #1d1d23 #24242b #2c2c34 #303039 #43434e #7e7e8a #9b9ba6 #d5d5dc #8b96ec` |
| `Accent.base / active / soft / text` | 强调色（唯一）四格 | `#5566d8 #3d4cb5 #ecedfa #4a59c9` |
| `Accent.borderOnAccent` | 强调色第五格 border.on-accent | `rgba(255,255,255,.45)` |
| `Accent.onAccent` | 按钮四态 primary 的文字色 / 第五格 kbd 文字 | `#ffffff` |
| `Semantic.error / warning / success / info` | 语义色（4）主色 | `#bc4e39 #8a6f12 #477f40 #5566d8` |
| `Semantic.errorSoft / warningSoft / successSoft / infoSoft` | 语义色（4）.soft 条 | `#fbeeea #f7f2e2 #ecf3ea #ecedfa` |
| `Surface.canvas / panel / popover` | 三级表面 | `#fbfbfc #f4f4f6 #ffffff` |
| `Borders.subtle / base / width` | 边框两级 | `#e2e2e7 #d3d3da 1px` |
| `Shadows.popover` | shadow.popover | `0 4 12 rgba(28,28,35,.10)` |
| `Fonts.sans / mono / cjkFallback` | helmet 字体声明 | Geist / Geist Mono / Microsoft YaHei UI, PingFang SC |
| `Weights.regular / medium`（+ `FontVariation`） | 字阶 · 字重 400 / 500 | 400 / 500 |
| `LineHeights.body / control`（倍率）、`LineHeights.kbdPx`（像素） | text.body 注 lh 1.5（控件 1.35）；kbd line-height 16 | 1.5 / 1.35 / 16px |
| `TextStyles.display / title / body / secondary / meta` | 字阶（5 档） | 20/500 · 15/500 · 13/400 · 12/400 · 11/400 |
| `TextStyles.mono` | mono 12.5 · tabular-nums | 12.5，`FontFeature.tabularFigures` |
| `TextStyles.monoMeta` | 各 token 名 / 注释行（mono 11） | 11 |
| `TextStyles.label` | 各分组标题（11 / 500 / letter-spacing .06em） | 11 / 500 / 0.66 |
| `Spacing.s4 / s8 / s12 / s16 / s24` | 间距（4px 网格）五条 | 4 8 12 16 24 |
| `Spacing.chip` | space.chip | 1px 5px |
| `Spacing.kbd` | kbd 用 0 4px | 0 4px |
| `Radii.r3 / r4 / r6`（`chip / control / card`） | 圆角三档 | 3 / 4 / 6 |
| `Radii.pill(h)` | radius.pill 例外 | 轨道高度一半 |
| `Controls.compact / standard / input` | 控件高度 | 24 / 28 / 32 |
| `Controls.padCompact / padStandard / padInput` | 三个控件样例的 padding | 0 8 / 0 8 / 0 10 |
| `Overlays.hover / active / selected` | 按钮四态 hover 6% / active 10% / selected | `rgba(30,30,38,.06)` / `.10` / `.10` |
| `FocusRing.width / offset / color` | focus ring 1.5 / +1 | 1.5 / 1 / accent |
| `IconSizes.base / toolbar / stroke` | icon 16 / 工具栏 14 · stroke 1.5 | 16 / 14 / 1.5 |
| `Kbd.*` | kbd · mono 11 · radius 3 · 边框 1 #d3d3da | 组合 |
| `Motion.fast / base / curve` | motion.fast 120ms / motion.base 160ms ease-out | 120 / 160 / easeOut |
| `Spinner.color / strokeWidth` | spinner accent · 1.5px 弧 | accent / 1.5 |

无表外值：`tokens.dart` 里每个字面量都能在上表找到画板位置；画板上的每个数值都有 token（样板页自己的示例几何——色块高 52 / 44 / 40、示意条等——是 `lib/gallery/boards/tokens_board.dart` 的局部常量，不是 token）。

## 验收

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | Windows release 构建；再在含中文与空格的目录构建一次 | `powershell -File scripts/build.ps1`；复制仓库到 `D:\测试 目录\AcpAgentClient` 后再跑一次，两次都产出 `acp_agent_client.exe` + `acp_bridge.dll` |
| 2 | Dart 调 `ping` 得到返回；核心主动推 `acp/agent_state`，Dart 收到 | `powershell -File scripts/build.ps1 -Smoke`：`build/smoke-report.json` 里 `ping.pong == "smoke"`、`coreReady.state == "core_ready"`、`ok: true`，退出码 0 |
| 3 | `validate.ps1` 全绿；样式字面量被拦 | `powershell -File scripts/validate.ps1` → `VALIDATE OK`；往 `lib/app/smoke_screen.dart` 塞 `Color(0xFF000000)` 后 `-Quick` 跑 → `FAIL Assert-NoStyleLiteral` 并列出该行（记录输出后撤掉） |
| 4 | tokens 对照表逐值核对；gallery 00 与 PNG 并排 | 上表；`flutter test test/gallery_test.dart` 产出 `build/gallery/00-tokens.png`，与 `design/round-design/00-tokens.png` 并排看：分组、名称、值、样例全部在 |
| 5 | fixtures 在 Rust 侧反序列化 | `cargo test -p acp-core --test fixtures`：59 行成功、2 行（`notice`、`artifact_update`）失败并被断言；15 个变体全部出现 |
| 6 | 中文 IME 组合窗实测 | 起 `flutter run -d windows`，在自检页 TextField 输入中文，记录组合窗 / 候选 / 上屏行为 |

## 禁止

继承 TEMPLATE 三条。本轮额外：不接任何 agent（R1）；不做画板 01+ 的任何 widget（R2 / R3）；不引 Markdown / 高亮 / diff 库（R1.5 裁定前）；不在 `cargokit/` 之外复制 frb 模板的其它文件。

## 代码审查

- 审查方式：`cursor-review.ps1`（默认档）两次硬失败 → 回落主会话委派的 Claude Code 只读子代理（同一份任务书 `.claude/cursor-review-prompt.md`）。
- cursor 失败原因：两次（`20260915-105111`、`20260915-110026`）进程都在 7–10 分钟后正常退出，`.out.md` 只有一个换行、`.err.log` 0 字节；同一时刻 `cursor-agent -p "Reply with exactly PONG"` 20 秒正常返回，登录态正常。属于文档定义的「后台进程已死而 `.out` 仍空」。
  **后查明属误判**：所有者旁路会话当天查出真因是脚本发的 `--plan` 把终稿吞进 plan 通道（进程跑满、退出码 0、审查其实做完了），已把 `.claude/cursor-review.ps1` 改成 `--mode ask` 并把实测写进 `docs/review-workflow.md`「容易踩的」第 4 条；按改后的定义「空 `.out` 且退出码 0 不算硬失败」。本轮的审查与复审已全部走子代理，不回头重跑 cursor（同一轮只用一个执行器）；**R1 首次审查即是 `--mode ask` 的实测**。旁路会话对脚本与文档的改动被本会话的 `git add -A` 一并扫进了提交 `03b9ee1`（非本会话所改，记录在此）。
- 审查器与模型：Claude Code 子代理（general-purpose，Fable 5.1），只读；范围 `main...HEAD`（第 1 轮，全量）。
- findings：8（high 0 / P2 4 / P3 4），逐条：
  1. [P2] 五个 `*_stream` 注册与 `core_init` 都是 frb normal 任务，线程池不保证先后，`core_ready` 可能在 sink 就位前发出被丢 → **采纳**：注册函数加 `#[frb(sync)]`，重跑 codegen。
  2. [P2] `validate.ps1` 的 `_meta` 字面量键检查用 `-notmatch '"_meta"'` 把该查的行整行排除 → **采纳**：先去掉 `"_meta"` 再匹配字面量。
  3. [P2] `settings` crate 的 `custom` 形状（`command: {path,args,env}`）与钉版本 Zed（`command` 字符串 + 顶层 `args` / `env`）不同，单测按错形状假通过 → **采纳**：按 Zed 扁平形状改，测试改用真实条目并加序列化回写断言。`docs/research.md` § 3 的 `command: {path, args, env}` 写法是错的，一并改。
  4. [P2] `CLAUDE.md:98` 与本任务卡的路径混入 `\a` / `\b` / `\f` 解码出的控制字符 → **采纳**：脚本写回反斜杠，`grep -P '[[:cntrl:]]'` 复核为 0。
  5. [P3] `runSmoke` 写报告失败时到不了 `exit`，无头进程常驻 → **采纳**：报告写入进 try，`exit` 放 finally。
  6. [P3] `fs::ensure_inside` 不拒绝 `..`，词法 `starts_with` 可绕出工作区 → **采纳**：含 `ParentDir` 分量即拒绝，加测试。
  7. [P3] `Assert-NoStyleLiteral` 漏 `height:` / `width:` / `Border.all(width:)` / `Radius.elliptical(` 等 → **部分采纳**：补 `height|width|min*|max*`、`Border.all(width:)`、`strokeWidth` 三类；`Radius.elliptical` / `Offset` 是 gallery 图标路径几何，R2 画板图标改用 `flutter_svg` 内联 SVG 后再纳入，记 BACKLOG。
  8. [P3] `SmokeScreen._boot` 在 `await` 后订阅没有 `mounted` 检查 → **采纳**：加 `if (!mounted) return;`。
- 复审（第 2 轮，全量 `main...HEAD`，Claude Code 子代理，**opus**——所有者 2026-09-15 要求回落子代理用 opus、不继承 Fable）：2 条（high 0 / P2 1 / P3 1），八条整改逐条复核通过，其中：
  1. [P2] 第 5 条整改把 stdout 写入并进了报告的 try，stdout 若抛异常会让成功路径也 `exit(1)` → **采纳**：stdout 单独 try/catch、不碰退出码；注释改成「可能抛异常或 flush 永不完成」（实测 smoke 退出码 0，但写法确实脆）。
  2. [P3] `LineHeights.kbd = 16` 是像素、同类里 `body / control` 是倍率，同名同类型易误用 → **采纳**：改名 `kbdPx` / `Kbd.lineHeightPx`，注释标明不是 `height` 倍率。
- 复审（第 3 轮，只审整改 diff `b60faf2..HEAD`，opus 子代理）：3 条（high 0 / P2 0 / P3 3），两条第 2 轮整改复核通过：
  1. [P3] stdout 标签仍取自 `report['ok']`，报告写失败时会打 `OK` 却 `exit(1)` → **采纳**：标签改按最终 `exitCode`。
  2. [P3] 任务卡「本轮实测」还写着「try / finally」，与整改后代码不符 → **采纳**：改文案。
  3. [P3] 第 2 轮整改改了 smoke 的退出路径，卡里没有改后重跑记录 → **采纳**：补记（改后 `build.ps1 -Smoke` 退出码 0、`ok: true`）。
- 复审（第 4 轮，只审整改 diff `f4d74f4..HEAD`，opus 子代理）：3 条（high 0 / P2 1 / P3 2），第 3 轮的三条整改本身复核通过：
  1. [P2] 任务卡新补的「第 2 / 3 轮整改后 smoke 复验」实际没跑过——审查者用 `app.so` / `smoke-report.json` 的时间戳（11:29）对照 `smoke.dart` 改动时间（11:45）证明的 → **采纳，事实如此**：那两次的 `build exit=0` 是 PowerShell 管道里 Select-String 出错 / 未执行后残留的旧 `$LASTEXITCODE`。已对 `03b9ee1` 版代码真跑一次（记录见「本轮实测 · 验收 2」），任务卡改成真话。
  2. [P3] 任务卡的回落理由与旁路会话改过的 `docs/review-workflow.md` 互斥 → **采纳**：补「后查明属误判」一段（见上）。
  3. [P3] `cursor-review.ps1` 改了发起参数（`--plan` → `--mode ask`）但任务卡无实测记录 → **采纳为记录**：改动来自所有者旁路会话，实测在 `docs/review-workflow.md` 第 4 条；本仓库 `.claude/reviews/` 尚无 `--mode ask` 产物，R1 首次审查补。
- 复审（第 5 轮，只审整改 diff `03b9ee1..HEAD`，opus 子代理）：2 条（high 0 / P2 0 / P3 2），第 4 轮三条整改逐条核对与事实相符（日志、`app.so` / 报告时间戳、脚本参数、reviews 目录产物都对上）：
  1. [P3] 「本轮四次审查」与同一提交新增的第 5 轮条目矛盾 → **采纳**：去掉数量词。
  2. [P3] 「第三次复验同样是假的」断言超出时间戳证据能覆盖的范围 → **采纳**：收窄为只说 smoke 没跑。
  两条都是任务卡文字、不涉代码，按 CLAUDE.md「低危改进项可写明理由放行」在收口时直接改正，不再发第 6 轮。
- 结论：**整改后 PASS**。5 轮合计 18 条（high 0 / P2 6 / P3 12），全部采纳或改正，无遗留；两条 P3 门禁覆盖项记 BACKLOG（gallery 图标几何扫描、cargokit 工具链漂移）。

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-00/BLOCKED.md`，停下呼人。禁止放宽验收标准自我通过。

## 本轮实测

全部在本机（Windows 11 25H2，`CKROG14AIR`，用户名 `Click`）实测，2026-09-15。

### 验收 1 · release 构建（本机 + 含中文与空格的目录）

- `powershell -File scripts/build.ps1 -Smoke`（首次，含 cargokit 冷编译 rust-sdk 依赖）：`Building Windows application... 97.7s`；产物 `build\windows\x64\runner\Release\acp_agent_client.exe`（91,136 B）+ `acp_bridge.dll`（593,408 B）+ `flutter_windows.dll`。cargo 的 target 实际落在 `D:\cargo-target\AcpAgentClient\cargokit\x86_64-pc-windows-msvc\release\`（cargokit 补丁生效，项目目录下没有 `target/`）。
- 含中文与空格的目录：`robocopy` 到 `D:\测试 目录\AcpAgentClient`（排除 `.git / build / vendor / design / prototype`）后同一命令：第一次在 Flutter 自己的 `flutter_assemble` 步骤失败（`CUSTOMBUILD : error : Unable to read file: D:\锟斤拷锟斤拷 目录\AcpAgentClient\.dart_tool\flutter_build\…\app.dill`，项目路径被 MSBuild 自定义生成规则按系统代码页转码；此时还没轮到 Rust / cargokit）。针对性整改：`build.ps1` 检测到项目路径含非可打印 ASCII 字符时，在 `CARGO_TARGET_DIR` 下建目录联接 `ascii-root`（`mklink /J`，不需要开发者模式）指向项目根，从联接路径起构建。整改后清空 `build/ .dart_tool/ windows/flutter/ephemeral/` 重建：`Building Windows application... 43.2s`，产物同样是 `acp_agent_client.exe`（91,136 B）+ `acp_bridge.dll`（593,408 B），落在 `D:\测试 目录\AcpAgentClient\build\…\Release\`；`-Smoke` 报告与本机一致（`ok: true`）。中间一次失败是脏状态（首次失败留下的空 `ephemeral/cpp_client_wrapper/`），不是整改本身的问题。结论：**Rust / cargokit 这段对中文路径没问题，Flutter 自己的构建链有，`build.ps1` 已兜住；裸 `flutter build windows` 在中文路径下仍会失败**（写进 CLAUDE.md「本地开发」）。
- 构建链不需要 Windows 开发者模式（没有 pub 插件，无符号链接）。

### 验收 2 · ping 往返 + `acp/agent_state` 事件

`build.ps1 -Smoke` 以 `ACP_SMOKE_REPORT=build\smoke-report.json` 起 release exe（无 UI），报告：

```json
{ "ok": true,
  "init": { "dataDir": "C:\\Users\\Click\\AppData\\Roaming\\AcpAgentClient", "coreVersion": "0.0.1" },
  "ping": { "pong": "smoke", "sequence": 1, "coreVersion": "0.0.1" },
  "coreReady": { "agentId": null, "state": "core_ready", "dataDir": "…\\AcpAgentClient", "coreVersion": "0.0.1", "droppedUpdates": 0 },
  "droppedEvents": 0 }
```

坑：无控制台的 Windows GUI 进程里 Dart `stdout` 句柄无效，第一次 smoke 写完报告后进程不退出（`exit()` 没执行到，`stdout` 写入 / flush 卡住）；现在报告写入与 stdout 各自 try/catch、`exit` 在函数末尾无条件执行，报告文件是唯一正式通道，stdout 只是顺带。

绕过 frb 的同一条路（`acp-smoke`）：

```text
> cargo run -q -p acp-smoke -- ping --data-dir D:\cargo-target\AcpAgentClient\smoke-data --echo "hello 你好"
{"event":"acp/agent_state","payload":"{\"agentId\":null,\"state\":\"core_ready\",\"dataDir\":\"D:\\\\cargo-target\\\\AcpAgentClient\\\\smoke-data\",\"coreVersion\":\"0.0.1\",\"droppedUpdates\":0}"}
{"result":"ping","payload":{"pong":"hello 你好","sequence":1,"coreVersion":"0.0.1"}}
> cargo run -q -p acp-smoke -- ping --data-dir relative
core init failed: invalid data dir: relative   (exit 1)
```

审查整改（五个 `*_stream` 改 `#[frb(sync)]` 等 8 条）后复验：`validate.ps1` 全量再次 `VALIDATE OK`，release 重建 32.3 s，`acp_bridge.dll` 595,968 B，smoke 报告 `ok: true`。
第 2 轮复审整改（smoke 退出路径拆分、`kbdPx` 改名）后：`validate.ps1` 全量 `VALIDATE OK`（有 `.rustc_info.json` / `unit_test_assets` 11:39 的产物为证）；**但同一条命令链里的 `build.ps1 -Smoke` 没有真正执行**——PowerShell 管道里的 Select-String 出错后上游未跑、`$LASTEXITCODE` 仍是上一步的 0，我把它记成了「退出码 0、ok: true」，第 3 轮整改后记的那次 `build.ps1 -Smoke` 同样没跑（`flutter analyze` / `validate.ps1 -Quick` 不落时间戳产物，无法复核）（第 4 轮复审用 `app.so` 11:29:18 与 `smoke-report.json` 11:29:20 的时间戳对照 `smoke.dart` 11:45 的改动时间抓出来的）。
真实的复验：2026-09-15 11:54 对 `03b9ee1` 版 `smoke.dart` 跑 `powershell -File scripts/build.ps1 -Smoke`（输出整段落 `D:\cargo-target\AcpAgentClient\r0-smoke-round3.log`）：`Building Windows application... 27.5s`，`acp_agent_client.exe` 91,136 B、`acp_bridge.dll` 595,968 B，`app.so` 11:54:04、`smoke-report.json` 11:54:07 重新生成，`OK smoke round trip`，`build.ps1` 退出码 0，报告 `ok: true`、`droppedEvents: 0`（`Start-Process -WindowStyle Hidden` 起的无控制台 GUI 进程正常退出）。教训：smoke 是否跑过以报告文件的时间戳为准，别信管道尾部的退出码。

### 验收 3 · validate.ps1 与样式字面量拦截

- `scripts/validate.ps1`：全量 `VALIDATE OK`：11 项全 PASS（fetch-upstream 8 个 OK、rust-sdk pin、unsafe 扫描、`_meta` 键、Zed 头注释、pubspec 白名单、Assert-NoStyleLiteral、cargo build / test / clippy、cargo tree 无 gpui、flutter analyze「No issues found」、flutter test 10 项）。
- 拦截实测：往 `lib/app/smoke_screen.dart` 末尾加 `const Color kTripwire = Color(0xFF000000);` 后 `validate.ps1 -Quick`：

```text
---- Assert-NoStyleLiteral (规则 3)
FAIL  Assert-NoStyleLiteral (规则 3): style literals outside tokens.dart:
D:\variFlight_work\AcpAgentClient\lib\app\smoke_screen.dart:170: const Color kTripwire = Color(0xFF000000);
VALIDATE FAILED: Assert-NoStyleLiteral (规则 3)
```

  撤掉后 `git diff` 为空。开发过程中它还真实拦下三处：`Duration(seconds: 5)` 超时（判定为逻辑不是样式，规则收窄为 `Duration(milliseconds:`）、图标路径里的 `Radius.circular(2)`（改为具名几何常量 `_iconCorner`）。
- 其它检查在开发中各拦下一次：`_meta` 清单发现 `docs/design.md` § 4 没把 Cursor 的键名写出来（已补 `parameterizedModelPicker`）；Zed 头注释检查拦下 `registry/src/lib.rs` 注释里的 `zed-industries/zed` 字样（改了措辞，检查保持严格）。
- 含中文的 `.ps1` 没带 BOM 时 PowerShell 5.1 直接解析失败（全局记忆的坑重现）：两个脚本已加 BOM + CRLF。

### 验收 4 · tokens 对照表与 gallery 00

- 对照表见上文，逐值核对通过；`tokens.dart` 里没有对照表之外的字面量。
- `flutter test test/gallery_test.dart` 产出 `build/gallery/00-tokens.png`（1440 × 924，约 152 KB），与 `design/round-design/00-tokens.png` 并排：分组标题、20 个中性色块（名 + 值）、强调色 5 格、语义色 4 × 2、三级表面示意与清单、字阶 6 行、间距条 5 根、圆角 3 档 + pill 开关、控件高度 3 档、按钮 7 态、图标 3 个、kbd 2 个、动效 3 行全部在。像素级差异：分组间距我只用 4px 网格 token（画板本身用了 6 / 7 / 10 / 14px 的非网格间距），下半区四列宽度按 1.15 : 1 : 1 : 1；不作 finding。
- 坑：flutter_tester 没有系统字体，CJK 回退要在测试里从 `C:\Windows\Fonts\msyh.ttc` 加载，否则中文是方块；测试 zone 是 FakeAsync，真实文件 IO 必须用同步 API 或放进 `runAsync`，否则 `flutter test` 挂死（第一次就挂了）。

### 验收 5 · fixtures 在 Rust 侧反序列化

`cargo test -p acp-core --test fixtures`：61 行里 59 行协议 / 本地行通过（局部 / stderr 行 6 条不进类型），`notice` 与 `artifact_update` 两条按预期失败并被断言；15 个变体各至少出现一次。**它抓到一处原型不合规**：`elicitation/create` 缺必填 `message`（`CreateElicitationRequest.message: String`），fixtures 已补，原型不改（记 BACKLOG）。

其它 Rust：`cargo build --workspace` 首次 35.9s（debug）；`cargo test --workspace` 5 个测试全过；`cargo clippy --workspace --all-targets -- -D warnings` 零告警（frb 生成物按模块 allow `unsafe_code / unwrap_used / unimplemented / todo`）。

### 验收 6 · 中文 IME 组合窗

**待所有者手测**（无法自动化）。步骤：`flutter run -d windows` → 自检页「IME TEST」的 TextField → 切中文输入法输入「你好世界」→ 观察：组合窗是否贴在光标处、候选窗是否跟随、上屏后是否出现重复字符或残留拼音、Backspace 是否按字删除。结果回填此处并同步 `docs/research.md` § 8。

### 耗时与体量

- Rust workspace 6 crate + 1 bin，约 900 行；Dart 约 1,900 行（含生成物 ~1,100 行）；fixtures 61 行。
- 首次 `flutter pub get` 31 个包；`flutter analyze` 8 s；`flutter test` 约 60 s（gallery 渲染占大头）。
