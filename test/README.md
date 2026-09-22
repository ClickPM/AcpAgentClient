# test

Dart 侧测试与共用测试资产的布局（Rust 侧测试在各 crate 的 `tests/` 与 `src` 内联，sidecar 的自检是 `--selftest`）。全部由 `scripts/validate.ps1` 的 `flutter test` 跑。

| 位置 | 是什么 |
|---|---|
| `fixtures/` | ACP 线上行（JSON Lines），Rust 测试 / Dart 单测 / gallery 三处共用的契约锚；格式与文件清单见 [`fixtures/README.md`](fixtures/README.md) |
| `fake-agent/fake-agent.mjs` | 离线、确定性的 ACP agent（Node），无头实跑与验收脚本用；不依赖任何凭据 |
| `projection/` | `lib/projection/` 投影状态层的单测（回放、合并语义、时间线、折叠、会话载入） |
| `app/` | `lib/app/` 组合根与各 `*State` / `*Controller` 的接线测试；`fake_core.dart` 是桥的假实现（`CoreCommands` 接口） |
| `ui/` | `lib/ui/` 画板 widget 的行为测试（弹层锚点、滚动、选择、折叠、主题切换等；不做像素比对） |
| `gallery_test.dart` + `gallery_harness.dart` | 画板对照：把每张画板的每个状态以 fixtures 数据渲染成 `build/gallery/NN-<状态>.png`（gitignored），与 `design/round-design/NN-*.png` 并排看；只断言 PNG 非零 |

约定：新增投影场景先加 fixtures（ROUNDS.md § 0 第 3 条）；新增桥命令要同步 `app/fake_core.dart`（编译器会逼着补）；测试里不写样式字面量（规则 3 的扫描不管 `test/`，但对照 `tokens.dart` 断言）。
