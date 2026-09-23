# Iteration 06 — 主题跟随系统（切换按钮三档）

> 状态：进行中　起止：2026-09-23 –　基线：`main` = 34e66be

## 工作项

| # | 类型 | 工作项 | 来源 | 分支 → 合并提交 | 验证 | 审查 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | ux | 主题加「跟随系统」：侧栏标题条那个按钮改成浅色 → 深色 → 跟随系统三档循环，图标显示当前档（太阳 / 月亮 / 显示器），每档都有 tooltip；设置页不加入口 | BACKLOG「P2 · 外观」第 1 条 + 所有者当场裁定 2026-09-23（不出设计稿） | `claude/system-theme-toggle-icon-fd8551` → | validate 全绿 | | 待审查 |

## 收口

- 构建 / 手测：<待定。手测项：① 三档循环，每档图标与 tooltip 对；② 选「跟随系统」后在 Windows 设置 → 个性化 → 颜色里切「选择模式」，应用不重启即跟着换套；③ 重启后仍是上次选的那一档；④ 手选浅色 / 深色时切系统深浅，应用不跟>
- 发版：<待定>
- 移出项去向：—
- 设计稿补注记：所有者裁定不出设计稿，偏离记 `design/DIVERGENCE.md` A-2（原条目扩写）

## 备注

- **图标显示当前档，不再是「切过去的那一档」**：两档时「显示目标」没有歧义；三档时「跟随系统」与手选的同色档看上去一模一样，只有显示当前档才分得出自己在哪一档。tooltip 两段都写：`<当前档> · Switch to <下一档>`，跟随系统那档括号里补一句系统眼下是深是浅。
- **缺省仍是手选浅色**：`t.Theming.defaultChoice = light`。没存过设置的人升级后看到的还是原来那套；「跟随系统」要自己点出来。
- **落盘**：`settings.json` 的 `appearance.theme` 多一个取值 `"system"`（`rust/settings` 的 `THEMES` 白名单同步，`docs/design.md` § 3 那段同步）。存的是**选择**，系统的深浅不落盘。旧版本读到 `"system"` 会当没设置、回浅色，不报错。
- **系统深浅的来源**：组合根 `lib/app/app.dart` 混入 `WidgetsBindingObserver`，开局把 `platformDispatcher.platformBrightness` 给 `AppearanceController`，之后每次 `didChangePlatformBrightness` 转一次 `setPlatformBrightness`；控制器不碰 binding。
- **踩到的一处**：`_applyLocally` 原先只在 tokens 真的换套时才通知。三档之后「颜色没变、选择变了」是常态（系统是深色时「深色 → 跟随系统」、系统是浅色时「跟随系统 → 浅色」），不通知按钮就停在上一档。现在选择变了也通知；widget 测试先红后绿抓到的。
- **用例**：`test/app/appearance_prefs_test.dart`（三档循环、系统切换跟随 / 不跟随、启动读回「跟随系统」、落盘形状）、`test/ui/theme_toggle_test.dart`（三档图标 + tooltip、跟随系统时系统切换按钮与文案跟着走）、`test/app/workbench_wiring_test.dart`（组合根把系统深浅转给控制器；去掉 `addObserver` 这一行时它会红，已实测）、`rust/settings` 的 `appearance_theme_only_takes_light_dark_or_system`。
- **编号**：写这份时 `iteration-05` 已被另外三个 worktree 各自占用（会话身份 P0 / 终端组字 / 通用 toast），这里取下一个空号 06；合并时若编号撞了按真实顺序再排。
