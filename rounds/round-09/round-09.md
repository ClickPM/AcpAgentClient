# Round 09 — macOS 平台支持与打包

> 从 `rounds/TEMPLATE.md` 复制，依据 `ROUNDS.md` 与所有者前置裁定填写。硬性规则以 `AGENTS.md` 为准。

## 状态

- 分支：`round-09`
- 状态：进行中
- 合并提交：

## 本轮目标

在现有 Windows 实现的基础上落地 **macOS 桌面端平台支持与打包**：生成并整理 `macos/` 原生宿主工程，接入仓库内 `cargokit` 构建 `rust/bridge`（`libacp_bridge.dylib`），在原生 Swift 层实现无边框透明标题栏与 `acp/window` 通道（窗口缩放/最小化/关闭、标题栏拖拽与双击缩放、剪贴板文件 URL 与 BGRA 位图读取），在 Flutter 层适配 macOS 原生红绿灯安全边距与三键隐藏、补充 macOS 字体探测目录，在 Rust 核心层补齐 macOS GUI 启动 `PATH`、实现无 `unsafe` 的 Unix 进程组整树回收（`kill_tree`）及终端登录 Shell 参数，并提供 macOS 验证、构建与打包脚本。

## 前置依赖

- 上游钉版本（`pins/upstream.json`）：不改动（`scripts/fetch-upstream.sh --check` 全绿）
- 前序轮次：R0–R8

## 范围与交付物

- [x] `macos/` 原生宿主工程与 Cargokit 集成：
  - `macos/Runner/Configs/AppInfo.xcconfig`、`macos/Runner/Info.plist`（应用名 `acp_agent_client`、展示名 `AcpAgent Client`、Bundle ID `com.clickpm.acpAgentClient`）
  - `macos/Runner/Assets.xcassets/AppIcon.appiconset/`（由 `scripts/render-icon-macos.sh` 从 `design/brand/app-icon.svg` 渲染 16–1024 七档尺寸 PNG）
  - `macos/Runner/DebugProfile.entitlements` 与 `macos/Runner/Release.entitlements`（`com.apple.security.app-sandbox = false`）
  - `macos/Scripts/bundle_rust_and_fonts.sh` + `cargokit/build_tool/lib/src/build_pod.dart`（Xcode 构建阶段经 `cargokit/build_pod.sh` → `cargokit/run_build_tool.sh` 编译 `acp_bridge`，将 `libacp_bridge.dylib` 打入 `Contents/Frameworks/`，并同步拷入 `assets/fonts/optional/` 字体）
- [x] 原生窗口与剪贴板通道（`macos/Runner/MainFlutterWindow.swift`）：
  - 无边框透明标题栏 + 左上角系统原生红绿灯（`titleVisibility = .hidden`、`titlebarAppearsTransparent = true`、`styleMask.insert(.fullSizeContentView)`、`isMovableByWindowBackground = false`、最小尺寸 `960×600`、初始尺寸 `1280×800`）
  - `acp/window` MethodChannel：`minimize`、`toggleMaximize`（`zoom`）、`close`、`isMaximized`（`isZoomed`）、`startDragging`（`performDrag(with:)` + 标题栏双击 `performZoom`）、`readClipboardImages`（先读 `NSPasteboard.general` 文件/目录 URL，无文件且 `bitmap == true` 时读取 PNG / TIFF 转自上而下 32 位不透明 BGRA 字节并遵守 `256 MB` `kMaxBitmapBytes` 上限）
- [x] Flutter / Dart 层适配：
  - `lib/app/window_controls.dart`（`AppWindow.supported` 放开 `Platform.isMacOS`）
  - `lib/app/core_bridge.dart`（macOS App Bundle 下优先从 `Contents/Frameworks/libacp_bridge.dylib` 加载 cdylib）
  - `lib/theme/tokens.dart`（新增 `Geometry.macosTrafficLightInset = 72`）
  - `lib/ui/shell/topbar.dart`、`lib/ui/shell/sidebar.dart`、`lib/app/workbench_screen.dart`（macOS 隐藏右上角 `WindowControls`，侧栏展开时在 `SidebarTitleBar` 左侧预留 `72px` 红绿灯避让、侧栏收起时在 `TopBar` 左侧预留 `72px` 红绿灯避让）
  - `lib/app/appearance_prefs.dart`（`defaultProbeDirs` 增加 `/System/Library/Fonts`、`/Library/Fonts`、`$HOME/Library/Fonts`；`defaultLoadDirs` 兼容 `Contents/Resources/fonts`）
  - `test/ui/shell_alignment_test.dart`、`test/app/appearance_prefs_test.dart`（新增 macOS 顶栏/侧栏避让、三键隐藏、字体目录探测单测）
- [x] Rust 核心层适配：
  - `rust/fs/src/lib.rs`、`rust/fs/src/git.rs`、`rust/registry/src/lib.rs`、`rust/registry/src/node.rs`、`rust/acp-core/src/command.rs`、`rust/acp-core/src/agent.rs`、`rust/acp-core/src/core.rs`：新增 `fs::effective_path()`，通过登录 shell（`$SHELL -l -c 'printenv PATH'`，带 2s 超时与进程组清理）及标准路径（`/opt/homebrew/bin`、`/usr/local/bin`、`~/.cargo/bin`、`~/.local/bin`）补齐 macOS GUI 启动 `PATH`（全程零 `unsafe`）
  - `rust/acp-core/src/command.rs`、`rust/registry/src/lib.rs`、`rust/registry/src/node.rs`、`rust/pty/src/lib.rs`：Unix 下子进程设置 `process_group(0)`，并在 `kill_tree` / PTY `kill` 中通过 `/bin/kill -TERM -- -<pid>` 与 `-KILL` 回收整棵子进程树（遵守规则 6 严禁 `unsafe`）
  - `rust/pty/src/shell.rs`、`rust/pty/src/lib.rs`、`rust/fs/src/watch.rs`：POSIX 交互式终端传 `-l` 登录 shell 参数；修复 `ShellKind::of_program` 在非 Windows 下解析反斜杠路径、非 Windows 下跳过 ConPTY DSR 探询缓冲、以及 macOS FSEvents `/private/var` 软链路径归一
- [x] 构建、验证与文档：
  - `scripts/fetch-upstream.sh`（兼容 `python3`）、`scripts/validate.sh`、`scripts/build-macos.sh`、`scripts/package-macos.sh`、`scripts/render-icon-macos.sh`
  - 更新 `design/DIVERGENCE.md`、`ROUNDS.md`、`README.md`、`README.en.md`、`AGENTS.md`、`scripts/README.md`、`design/brand/README.md`

## 非目标（本轮不做）

- Linux 桌面端支持与打包
- Apple Developer 付费证书签名与公证（Notarization），与 Windows 端（R8）保持一致采用未签名/ad-hoc 构建
- 新画板设计（平台窗口框体差异记入 `design/DIVERGENCE.md`）

## 验收标准

每一项必须可由命令或操作客观判定，禁止主观描述。

1. [x] `scripts/fetch-upstream.sh --check` 全绿
2. [x] `scripts/validate.sh` 静态门与全量编译测试全绿（`cargo build --workspace`、`cargo test --workspace`、`cargo clippy --workspace --all-targets -- -D warnings`、`cargo tree --workspace` 无 `gpui`、`flutter analyze --no-fatal-infos`、`flutter test` 全绿）
3. [x] `macos/Runner/*.swift` 通过 `swiftc -typecheck`（对齐 macOS SDK 与 `FlutterMacOS.framework`），且 `macos/Scripts/bundle_rust_and_fonts.sh` 实跑产出 `Contents/Frameworks/libacp_bridge.dylib`（`@rpath/libacp_bridge.dylib`）
4. [x] 独立代码审查通过，无未处理的阻塞性问题

## 实测记录

```text
1. scripts/fetch-upstream.sh --check:
   OK      agent-client-protocol @ 1ce24ea67a6f
   OK      rust-sdk @ 3a6d0ae88dba
   OK      registry @ 26773d16ae92
   OK      claude-agent-acp @ 6b7473b1afb4
   OK      codex-acp @ 51d6247ac744
   OK      pi-acp @ d1cffc047ab3
   OK      dsh-acp-interactive @ e39fd482d574
   OK      deepseek-harness @ 47f943859bef

2. Rust 全工作区测试与 Clippy：
   cd rust && cargo test --workspace --locked && cargo clippy --workspace --all-targets --locked -- -D warnings
   - acp-core: 25 passed; 0 failed (unit) + 1 passed (fixtures) + 11 passed (scripted)
   - fs: 23 passed; 0 failed
   - pty: 11 passed; 0 failed
   - registry: 20 passed; 0 failed
   - settings: 20 passed; 0 failed
   - clippy: 0 warnings

3. Swift 原生层类型检查与 Cargokit dylib 打包实测：
   - swiftc -typecheck macos/Runner/MainFlutterWindow.swift macos/Runner/AppDelegate.swift -> 0 errors
   - bash macos/Scripts/bundle_rust_and_fonts.sh -> 产出 Contents/Frameworks/libacp_bridge.dylib (install_name: @rpath/libacp_bridge.dylib)
   -注：本机当前仅安装 CommandLineTools（未装完整 Xcode.app），flutter build macos --release 待安装 Xcode.app 后由 scripts/build-macos.sh --smoke 执行。
```

## 偏离与取舍

- macOS 窗口控制与红绿灯避让：按所有者前置裁定，macOS 采用系统原生左上角红绿灯，隐藏 `TopBar` 与 `RightPanel` 右上角 Windows 三键，并在侧栏展开时于 `SidebarTitleBar` 左侧、侧栏折叠时于 `TopBar` 左侧预留 `72px`（`Geometry.macosTrafficLightInset`）安全边距，已记入 `design/DIVERGENCE.md` 第 42 条。
- Rust 2024 下 `std::env::set_var` 为 `unsafe fn`（违反规则 6），因此 GUI `PATH` 补齐采用无 `unsafe` 的 `fs::effective_path()`（`OnceLock` 缓存登录 shell 探测结果 + 标准路径去重合并）并在命令解析与子进程拉起时显式注入 `PATH`。

## 代码审查

- **执行器由所有者指定：Codex CLI (`gpt-6.1-sol`, `reasoning: medium`, read-only)**
