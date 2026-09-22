# scripts

仓库级脚本一览（都在仓库根跑 `powershell -File scripts/<名>.ps1`；参数与坑写在各脚本文件头）。轮次 / 迭代专用的探针与基线脚本不放这里，放各自的任务卡目录并从任务卡链接。

| 脚本 | 做什么 | 什么时候跑 |
|---|---|---|
| `fetch-upstream.ps1` / `.sh` | 按 `pins/upstream.json` 填充或校验 `vendor/upstream/`（`-Check` / `--check` 只校验） | 每个 worktree 第一步；改钉版本后 |
| `validate.ps1` | 编译 + 测试 + 契约检查（规则 1 / 2 / 3 / 4 / 5 / 6 / 11、lib/app 行数门与依赖方向门；`-Quick` 只跑静态检查；不含 sidecar） | 每次提交前 |
| `build.ps1` | `flutter build windows`（`-Debug`；`-Smoke` 构建后跑一次无头往返自检）；项目路径含中文 / 空格时只能用它 | 出可运行产物 |
| `build-sidecar.ps1` | 构建 `sidecar/zed-agent-acp`（独立 cargo workspace；`-Check` / `-Clippy` / `-Selftest`；冷编译约 50 分钟） | 改 sidecar 或换 zed 钉版本后 |
| `package.ps1` | zip（含 / 不含 sidecar）+ Inno Setup 安装器 → `dist/`（`-SkipBuild` / `-NoInstaller`） | 发版 |
| `verify-package.ps1` | 在全新空数据目录上验收打包产物：解压即用、随包 sidecar 自检、静默装 → 跑 → 静默卸（`-ZipOnly`） | 发版前 |
| `render-design.ps1` | `design/<轮>/*.dc.html` → 同名 PNG（headless Edge / Chrome，尺寸 = `$preview`；`-Round` / `-Only`） | 改画板源后必跑 |
| `render-icon.ps1` | `design/brand/app-icon.svg` → `windows/runner/resources/app_icon.ico`（七帧） | 改应用图标后 |

另有两处不在本目录的脚本：独立审查的启动脚本 `.claude/cursor-review.ps1`（契约在同目录 `cursor-review-prompt.md`，流程在 `docs/review-workflow.md`）；frb 生成 `flutter_rust_bridge_codegen generate`（改 `rust/bridge/src/api.rs` 后必跑，生成物入库）。
