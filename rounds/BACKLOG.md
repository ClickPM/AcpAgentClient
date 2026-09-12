# Backlog

跨轮次发现的问题与想法都记这里，不当场顺手改；新功能类条目须经所有者裁定才可进轮次。
格式：`- [ ] <发现轮次> <一句话> (发现日期)`

## 功能（需所有者裁定后才可进轮次）

- [ ] 立项 registry 的 `uvx` 分发类型：Zed 也未实现，首期不做；要做需引入 `uv` 的检测与下载 (2026-09-11)
- [x] 立项 是否声明 `plan` 与 `session.compaction` 两个 unstable 客户端能力 → 所有者裁定 2026-09-11：**都声明**，已写进 `docs/design.md` § 4 (2026-09-11)
- [ ] 立项 Gemini CLI 作为一等 agent：Zed 目前靠合成 terminal auth 方法过渡，等官方 auth methods 落地再议 (2026-09-11)

## 工程

- [ ] 立项 sidecar 与运行中的 Zed 争用 `threads.db`：R6 裁定「只读共用 / 隔离目录」，未发现 Zed 现成的数据目录覆盖变量 (2026-09-11)
- [ ] 立项 前端 Dart 类型来源二选一：从 `schema/v1/schema.unstable.json` 构建期生成后按 15 变体白名单裁剪（现方案，quicktype 或同类），或手写 15 变体薄封装；2026-09-12 前端改 Flutter 后「引官方 TS SDK 类型」选项失效；注意两份 schema 都不等于我们的编译面（稳定 11 / 全 unstable 16 / 我们 15），见 `docs/acp-projection.md` § 1 与 § 11.3 (2026-09-11)
- [ ] 立项 Markdown 渲染库选型：官方 `flutter_markdown` 已停维；R1.5 spike 比较 `package:markdown` 自写渲染 / `markdown_widget` / `gpt_markdown`（流式追加、GFM、代码高亮、CJK、选择复制），所有者裁定后进规则 1 白名单；spike 前不得引入 (2026-09-12)
- [ ] 立项 若 R0 在中文用户名路径下 `flutter build windows` 因 cargokit 路径失败，`CARGO_TARGET_DIR` 指 ASCII 路径仍不够时评估形态 B（独立 `acp-host.exe`），见 `docs/research.md` § 9.3 (2026-09-12)
- [ ] R1 `notice` 会话更新我们编译不出、收到即静默丢弃 → 所有者裁定 2026-09-11 取「不改 feature 集，计数 + 告警 + 落 `acp/traffic`」；**待办：R1 用 dsh 实测一次未知变体的丢弃路径后复议**；见 `docs/acp-projection.md` § 8.1 (2026-09-11)
