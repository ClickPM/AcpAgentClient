# round-1.4.9 — Active 行精简与 Reload Agent 文案发版

## 授权与基线

- 所有者要求：基于最新 main 发布 1.4.9，更新本地安装版；成功之后清历史 Rust 构建缓存，只留最新版在用产物。
- 所有者明确授权直接操作现有 `D:\variFlight_work\AcpAgentClient-release`，不必附加到 Delta。
- 基线：`main = a784f42`；上一发布 `v1.4.8 = f4e5e57`。产品改动仅 iteration-21 的 Active 行精简、iteration-22 的 Reload Agent tooltip。
- 版本号：`pubspec.yaml` / `rust/Cargo.toml` 与 Cargo.lock 七个本地 crate 改为 1.4.9；不改依赖版本。
- 本轮不修 BACKLOG 中 Send Now / Close 竞态，不把问题登记写成修复。

## 主会话 review

已逐处核对 `v1.4.8..a784f42` 非文档 / 非设计稿 diff：产品仅两处 UI 文案与相应侧栏测试，未改生命周期、协议与重载逻辑。历史发版脚本未改产品，清理前单独核对范围与守卫。未发现需整改问题。

## 验证与代码审查

待在 release 工作区执行完整 validate，随后 Cursor CLI `grok-4.7-high-fast` 审查发布范围。结果回填本段；硬失败停下，不回落子代理。

## 发布、安装与清理

待执行 build / smoke、package / verify-package、推两个远端、创建 GitHub release、安装目录镜像与隔离 APPDATA smoke；全部成功后才清理缓存。
