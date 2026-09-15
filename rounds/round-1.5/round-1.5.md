# Round 1.5 — 富文本渲染 spike（裁定门）

<!-- 保存为 rounds/round-1.5/round-1.5.md；spike 结论与对比矩阵在同目录 spike.md，截图在 shots/，原始测量在 data/。 -->

> 状态：已完成（spike 与 2 轮审查收口 2026-09-15；所有者同日裁定「按推荐项」，六项全部进规则 1 白名单，画板 15 / 32 不改；已落 CLAUDE.md 规则 1 / requirements § 8 / design § 9 / validate.ps1 / BACKLOG / ROUNDS）

## 目标

为画板 12–16、32（audio）、60（Markdown 预览）与 21（diff）选库：Markdown（GFM）、代码高亮、数学公式、Mermaid、音频播放、diff 六项各给出一个**推荐项 + 备选**，附同一份语料下的截图、流式追加成本、选择复制与链接回调、大文件 diff 耗时、Windows 真机音频播放的实测数据；所有者裁定后写进 CLAUDE.md 规则 1 与 `docs/requirements.md` § 8。范围 = ROUNDS.md § 3「R1.5」。spike 代码只在 `round-01.5` 分支，不合并。

## 前置

- R0 / R1 已合并 `main`（ddf22b3 / 5466609）；worktree `D:\variFlight_work\AcpAgentClient-r15`（`vendor/upstream` 用目录联接指向主工作树），`scripts/fetch-upstream.ps1 -Check` 8 个上游全 OK。
- 本机：Flutter 3.47.4 / Dart 3.13.3（R0 钉），Windows 11 26200。音频真机测试用一次性 Flutter app（`D:\cargo-target\AcpAgentClient\audio-spike`，不入库）。
- 参照 agent：无（spike 只用画板语料）。

## 交付物

| 路径 | 内容 |
|---|---|
| `rounds/round-1.5/spike.md` | 对比矩阵、每个候选的截图链接、测量数据、六项裁定建议、白名单改动稿 |
| `rounds/round-1.5/shots/*.png` | 五个 Markdown 候选 × 3 张（完整语料 800 宽 / CJK 窄列 360 宽 / 流式中间态三联）+ 高亮对照 + 公式 + Mermaid + diff，共 19 张 |
| `rounds/round-1.5/data/*.json` | 流式逐帧计时（1× / 4× 语料）、选择与链接、diff 耗时、首帧、音频真机事件时间线 |
| `lib/spike/`、`test/spike/`（仅本分支） | 统一语料（画板 12 / 13 / 14 / 15 / 16 / 21 原文）、五个候选的统一接口、自写渲染候选、高亮 / 公式 / Mermaid / diff 对照板、截图 / 流式 / 选择 / diff / 诊断测试 |
| `pubspec.yaml`（仅本分支） | 15 个候选包 + `objective_c` 9.4.1 override（原因见 spike.md § 7） |

## 验收

| # | 检查 | 命令 / 期望 |
|---|---|---|
| 1 | 五个 Markdown 候选渲染同一份语料（画板 12 + 13 + 14 + 16 拼接）出图，与画板 PNG 逐项对照（标题 / 列表 / 任务清单 / 行内代码 / 引用 / 链接 / 分割线 / 删除线 / 代码块 / 表格 / 公式） | `flutter test test/spike/shots_test.dart` → `shots/12-14-16-<id>.png`；对照结论见 spike.md § 2 |
| 2 | 流式追加：同一语料按 24 字符步长喂，逐帧计时（只计 pump），并记「先到块的 Element 是否保住」；三种中间态（围栏已开未闭 / 表头行刚出 / 块级公式已开未闭）截图 | `flutter test test/spike/stream_test.dart`（单独跑）→ `data/stream.json`；`shots/stream-<id>.png` |
| 3 | `SelectionArea` 从内容左上拖到右下，标题 / 列表 / 代码块 / 表格单元 / 删除线 / 引用六处文字都在 `plainText` 里；相对路径链接点击回调带回 href 原文 | `flutter test test/spike/select_test.dart` → `data/select.json` |
| 4 | 代码高亮两库同色表渲染 powershell / dart / rust / json；公式行内 + 块级 + 错误回落；Mermaid 两库渲染画板 15 的 graph TD | `shots/13-highlight.png`、`16-math.png`、`15-mermaid.png` |
| 5 | diff 两库对画板 21 样例给出 +3 −1 且旧 / 新文本可从行序列还原；5,000 / 20,000 行与全异 2,000 行的耗时 | `flutter test test/spike/diff_test.dart` → `data/diff.json` |
| 6 | 音频：Windows 真机播放内存 base64 WAV（BytesSource）与临时文件两条路径，duration / position / complete 事件齐，pause 后位置停住、resume 后 seek 落点正确 | 一次性 app 无头跑 → `data/audio-report.json` |
| 7 | 六项各有「推荐 + 备选 + 一句理由」；白名单改动稿可直接粘进 CLAUDE.md 规则 1 与 `docs/requirements.md` § 8 | spike.md § 6 / § 8 |

## 禁止

继承 TEMPLATE 三条。本轮额外：不写任何画板 widget（`lib/ui/` 不动，R2 的事）；不改 `lib/theme/tokens.dart`；不碰 `rust/`；spike 代码与 `pubspec.yaml` 的候选依赖不得进 `main`（本分支不合并，只有 `rounds/round-1.5/` 与裁定落文档进 `main`）。

## 代码审查

<!-- spike 分支不合并，没有进入 main 的代码；审查对象是 spike.md 的结论是否被测量支撑（方法是否作假、数字是否对得上截图与 JSON）。 -->

- 审查方式：`cursor-review.ps1 -Kind adversarial`（第 1 轮；`-Note` 指定只审 spike.md 的结论是否被 lib/spike + test/spike 的测量支撑、方法是否作假或偏袒、数字是否与 data/*.json 一致、§ 8 的方块归类是否站得住），后台跑 12 分钟，`.out.md` 6.4 KB。
- 审查器与模型：cursor CLI `cursor-grok-4.6-high`（`--mode ask`）。
- 审查范围与基准提交：第 1 轮 `main...HEAD`（全量，基准 d1eaa07）。
- findings（第 1 轮）：4（high 0 / P2 3 / P3 1）+ 4 条取舍质疑，逐条：
  1. [P2] 流式计时只计 `pump`：①–④ 的 `package:markdown` 全量解析在 build 里被计入，⑤ streamdown 的增量解析在流监听里（`idle`）被漏掉，1×「仅次于 streamdown」的排序不成立 → **采纳**：计时窗口改成 `add` 之后的 `idle` + `pump` 全计入（`stream_test.dart`），重跑，spike.md § 2.3 表与 § 0 / § 2.6 的理由全部重写，删掉所有快慢排序句。
  2. [P2] 「Element 保住」只对标题做了 `identical`，却被写成「代码块横向滚动位置、选区随每个 chunk 丢失」 → **采纳**：补一项直接测量（第 80% 帧把最宽横向 Scrollable 滚到 30 px，末帧读回），结果五个库**都保住**（④ 标题 Element 每帧新建但滚动位置靠同位置复用保住了），spike.md 只写测到的两项，删掉未测的选区推论。
  3. [P2] § 8 第 4 条把 flutter_mermaid 的 CJK 方块归成测试环境，而同一张截图里配了同一字体的 mermaid_flutter 正常 → **采纳**：§ 8 第 4 条拆成两半，flutter_mermaid 的「字体配置不生效」并入 § 5 的排除理由。
  4. [P3] 「4× 反超 / 五者最低」被同节自己的方法局限削弱，不宜当推荐主因 → **采纳**：推荐 ① 的理由去掉性能排序，只留贴画板代价、可控性、白名单三条，并写明 ①④ 差距只是单次 debug 数字。
  取舍质疑 4 条：①「判据全过」是共用 CodeCard / 复选框 / 公式扩展的结果不是解析器独有 → **采纳**，§ 2.6 开头明写，④ 作为「不想维护渲染层」时的备选；③「无高亮」改成「默认无高亮（未换 builder）」→ **采纳**；`just_audio` 只按官方平台标签排除、社区 Windows 实现未测 → **采纳**，§ 6 改写；mermaid 28 种图是库声明不是实测 → **采纳**，§ 5 改写。
  顺带（不是 findings）：自写渲染层行数按实际 390 行改（原写 330）；补 Windows 真机字体探针（`data/font-probe.json`）把 § 8 第 2 条「`monospace` 退到比例字体」从推断变成测量。整改提交 0b8b1f4。
- 复审（第 2 轮，全量 `main...HEAD`，cursor CLI `cursor-grok-4.6-high`，`--mode ask`，`20260915-155218`，12 分钟）：1 条（high 0 / P2 0 / P3 1）。五项复核全部通过（计时窗口对五库对称；横滚判据成立、1× 第 80% 帧时测到的确是代码块；表内数字与 `stream.json` 一致、排序句已删；§ 5 / § 6 / § 8 归类分清；`font-probe.json` 撑得住 § 8 第 2 条）。
  1. [P3] § 8 第 8 条仍写整改前的 191 ms，与 § 2.3 脚注的 213 不一致 → **采纳**：改成引用 `stream.json` 的 `custom x1.maxms`（213）。
- 结论：**整改后 PASS**。2 轮合计 5 条（high 0 / P2 3 / P3 2）+ 4 条取舍质疑，全部采纳整改；无遗留。第 2 轮唯一的 P3 是文档里一个数字的口径不一致，整改只改这一个数，按 CLAUDE.md「低危改进项可放行」不再发第 3 轮。分支不合并，`rounds/round-1.5/` 以纯文档进 `main`。

## 失败处理

同一验收项针对性整改后连续 2 次验证仍不过 → 写 `rounds/round-1.5/BLOCKED.md`，停下呼人。禁止放宽验收标准自我通过。

## 本轮实测

见 [`spike.md`](spike.md)。踩坑与偏离摘要：

- `audioplayers` → `path_provider_foundation 2.6.0` → `objective_c ^9.2.1` 解析到 9.6.1，其构建钩子在 Dart 3.13.3 上编不过（`Architecture.arm64e`），`flutter test` 在「Building native assets」阶段整体失败；本分支 `dependency_overrides: objective_c: 9.4.1` 绕过。若裁定采纳 audioplayers，R2 的 `pubspec.yaml` 也要带这条 override（或升 Flutter，走规则 4 的钉版本流程）。
- 一次性音频 app 放在 `%TEMP%\claude\...\scratchpad` 下 `flutter build windows` 因超长路径在 CMake `project()` 失败，换到 `D:\cargo-target\AcpAgentClient\audio-spike` 通过；构建产物与报告不入库。
- flutter_tester 不装包字体 / 图标字体、不做平台字体回退：截图里的方块都是字体问题（spike.md § 7 逐条说明哪些是测试环境让步、哪些是库的真缺陷）。
- markdown_widget 默认复选框在正文 13px 下算出负内边距（debug 断言、release 里 ErrorWidget 在无界高度下撑到 20 万像素），改用自带 builder 后正常；是库的真缺陷，记进矩阵。
- 计时类测试与其它文件并发跑时数字被抬高 1.5–3 倍；`data/stream.json` 是 `stream_test.dart` 单独跑的结果。
