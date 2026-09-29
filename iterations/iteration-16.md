# Iteration 16 — 彻底去 Zed 化（从产品、功能与构建体系彻底移除 Zed）

<!-- 保存为 iterations/iteration-NN.md。一个迭代一个文件、一项一行；流程正本见 iterations/README.md，不在这里复述。 -->

> 状态：待审查　起止：2026-09-24 – 2026-09-29　基线：`main` = `2d67f24`

所有者指示 2026-09-24：「从产品和功能上拿掉 Zed。我们借鉴的其他能力需要完全保留，不需要强制修改协议。走迭代。开发完整后需要 cursor 审查。」

本迭代目标：在产品、界面、构建与内置体系中**彻底剔除 Zed 的一切功能与存在**（免去 50 分钟冷编译与 VS CMake 依赖，客户端对外无任何 Zed 痕迹），底层已转写的通用技术代码（下载、解压、Pty Shell、send_queue）完全保留，协议维持 GPL。

**编号**：开工时 `main` 最新是 iteration-15，DIVERGENCE 最新是 36。本文取 **16**、DIVERGENCE 取 **37**。

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | tidy | 彻底移除 `sidecar/zed-agent-acp/` 独立工程及构建脚本 `scripts/build-sidecar.ps1`，移除 `windows/CMakeLists.txt` 的 sidecar 安装规则 | 所有者需求 2026-09-24 | `claude/iter-16-remove-zed` → 待合并 | cargo test ✓ flutter test ✓ | 待审查 | 完成 |
| 2 | tidy | 改造 `rust/acp-core/src/builtin.rs` 与 `core.rs`：仅保留 `dsh-acp-interactive` 为内置 agent，移除 sidecar 探测与合成逻辑；移除 `assets/zed-icon.svg` 与启动 banner 的 sidecar 记录 | 同上 | `claude/iter-16-remove-zed` → 待合并 | cargo test ✓ flutter test ✓ | 待审查 | 完成 |
| 3 | tidy | 移除「从 Zed 导入」配置功能：清理 `rust/settings/src/zed_import.rs`、`agent_settings_import_zed` 桥接口与 paths 传递；重新生成 FRB 桥接代码；前端画板 70 设置页移除该按钮与整行展示 | 同上 | `claude/iter-16-remove-zed` → 待合并 | cargo test ✓ flutter test ✓ FRB codegen ✓ | 待审查 | 完成 |
| 4 | tidy | 打包与门禁收敛：`scripts/package.ps1` 移除双包逻辑统为单包；`scripts/verify-package.ps1` 移除 sidecar 验收；`scripts/validate.ps1` 简化版本门与扫描；更新 `NOTICE` 与 `pins/upstream.json`；归档 `docs/zed-agent.md` | 同上 | `claude/iter-16-remove-zed` → 待合并 | analyze ✓ clippy ✓ | 待审查 | 完成 |
| 5 | fix | 测试用例适配：清理 Flutter/Dart 与 Rust 单元测试中对 zed 的硬编码与 fixture 断言（agent_logo_test、settings_builtin_test、registry_wiring_test、workbench_wiring_test、fake_core） | 同上 | `claude/iter-16-remove-zed` → 待合并 | 597 tests ✓ cargo test ✓ | 待审查 | 完成 |

## 收口

- 构建 / 手测：cargo test ✓ (全 workspace)、flutter test ✓ (597/597)、flutter analyze ✓ (0 error/warning)、cargo clippy -D warnings ✓
- 发版：不发（合入 `main` 后待所有者后续发版安排）
- 移出项去向：—
- 设计稿补注记：`design/DIVERGENCE.md` 第 37 条。

## 备注

### 决策与边界

- **产品与功能彻底去 Zed**：删掉内置 `zed-agent-acp` sidecar 可执行文件、删掉设置页「从 Zed 导入」、删掉 Zed 图标与名称、客户端无论安装还是运行均不留任何 Zed 专有功能痕迹。
- **保留通用技术代码复用**：`rust/acp-core/src/agent.rs`、`rust/pty/src/shell.rs`、`rust/registry/`（archive, download, index, install, node）、`lib/app/send_queue.dart` 等已转写的纯技术实现完全保留，项目许可证维持 `GPL-3.0-or-later`，在 `NOTICE` 中继续合规披露。

### 验证记录（2026-09-29）

- `cargo test --manifest-path rust/Cargo.toml --workspace`：全部通过
- `flutter test`：597 通过、0 失败
- `flutter analyze --no-fatal-infos`：0 error、0 warning、19 info（均为 `prefer_const_constructors`，测试文件中既有的）
- `cargo clippy --workspace --all-targets -- -D warnings`：0 warning
- 总变更：44 文件，+250 −18114 行
