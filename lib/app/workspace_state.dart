// 项目与分支（R7.5 从 workbench_controller.dart 拆出）：当前项目与最近项目（画板 41 的项目切换器）、分支区
// （画板 04 的分支切换器）、Rules 计数（画板 30 / 40）、`workspace_open` 的接线与两组输入控件。
// 会话不归它管：换项目对会话的影响（侧栏重投影、放下别的目录的会话）由组合根经 [onProjectChanged] 接到会话控制器，
// 等待期守卫经 [busy] 读。

import 'dart:io';

import 'package:flutter/widgets.dart';

import '../ui/popovers/topbar_popovers.dart';
import '../ui/shell/popover_anchor.dart';
import 'core_bridge.dart';
import 'files_state.dart';
import 'guarded.dart';

/// 项目根下算作「规则文件」的名字（docs/design.md § 9 的 Rules 行，清单在 R3 任务卡定）。
const List<String> ruleFileNames = <String>['AGENTS.md', 'CLAUDE.md', '.rules'];

class WorkspaceState extends ChangeNotifier with GuardedNotifier {
  WorkspaceState({
    required this.bridge,
    required this.files,
    required this._busy,
    required this._onProjectChanged,
  });

  final CoreCommands? bridge;

  /// 文件面板（画板 60）：换项目要重建它的树。持有者是组合根，这里只用。
  final FilesState files;

  /// 等待期（`session/new` / 重载在途）里不换项目：判据在会话控制器那边（`waitingForAgent`）。
  final bool Function() _busy;

  /// 换了项目：侧栏只留这个目录下的会话、正开着的会话若属于别的目录就从会话区放下（会话控制器的事）。
  final void Function() _onProjectChanged;

  List<ProjectRef> recentProjects = const <ProjectRef>[];
  ProjectRef? project;
  String? branch;
  List<BranchRef> branches = const <BranchRef>[];

  /// 顶栏分支区是否渲染：找得到 git 且当前项目是 git 工作区。
  bool branchAreaVisible = false;
  int rulesCount = 0;

  final TextEditingController projectSearch = TextEditingController();
  final FocusNode projectSearchFocus = FocusNode();
  final TextEditingController branchInput = TextEditingController();
  final FocusNode branchFocus = FocusNode();

  // ---- 弹层锚点（画板 40 / 41）
  final PopoverHandle projectAnchor = PopoverHandle();
  final PopoverHandle branchAnchor = PopoverHandle();

  @override
  void dispose() {
    for (final c in <TextEditingController>[projectSearch, branchInput]) {
      c.dispose();
    }
    for (final f in <FocusNode>[projectSearchFocus, branchFocus]) {
      f.dispose();
    }
    for (final h in <PopoverHandle>[projectAnchor, branchAnchor]) {
      h.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------- 项目

  /// 启动时恢复最近一次打开的项目（没有就留空，顶栏显示 `—`，新建会话前要先选项目）。
  Future<void> restoreLastProject() async {
    final b = bridge;
    if (b == null) return;
    final result = await b.workspaceRecent();
    recentProjects = _toProjects(result['projects']);
    if (recentProjects.isNotEmpty) await openProject(recentProjects.first);
  }

  List<ProjectRef> _toProjects(Object? raw) => <ProjectRef>[
        if (raw is List)
          for (final p in raw)
            if (p is Map) ProjectRef(path: p['path'] as String? ?? '', name: p['name'] as String? ?? ''),
      ];

  Future<void> openProject(ProjectRef ref) async {
    hidePopover(projectAnchor);
    // 等待期（`session/new` / 重载在途）里顶栏仍可点（`IgnorePointer` 只包住 `_body()`）：这时换项目，
    // 在途那条 `session/new` 回来后 `_adoptSession` 会把它挂成当前会话，而它的 cwd 是旧目录——会话区开着一条
    // 侧栏（只投影当前 workspace）里找不到的会话。与 `newSession` / `reloadAgent` 同一道守卫：
    // 等待期里不换项目（合并复审 2026-09-18）。
    if (_busy()) return;
    final b = bridge;
    if (b == null) {
      project = ref;
      touch();
      return;
    }
    final epoch = ++_openEpoch;
    await guard(() async {
      final result = await b.workspaceOpen(ref.path);
      // 期间又换了项目（用户连点两个目录）：这一轮整个作废，别把旧目录写回去。
      if (epoch != _openEpoch) return;
      final p = result['project'];
      project = p is Map ? ProjectRef(path: p['path'] as String? ?? ref.path, name: p['name'] as String? ?? ref.name) : ref;
      recentProjects = _toProjects(result['projects']);
      _onProjectChanged();
      // 到这里界面就该能用了：`workspace_open` 只是往本地索引写一条（acp-core 的 `workspace_open`），
      // 顶栏项目名与输入框的 `canCompose` 不必等下面那三件。先通知一次，不让整块界面等着
      // 6 个 git 子进程 + 2 次目录列举 + 起文件监视跑完（大仓库上是秒级）。
      touch();
      await _hydrate(epoch);
    });
    touch();
  }

  /// [openProject] 的序号：换项目后要补齐的三件是并发的，回来时得认得出自己这一轮还算不算数。
  int _openEpoch = 0;

  /// 换项目后补齐的三件：分支区、Rules 计数、文件树（含 git 徽章与 `fs_watch`）。三者互不相干，
  /// 并发跑——核心侧每条命令各自在 `spawn_blocking` 上，是真并行——谁先回来谁先显示。
  /// 期间又换了项目就不再通知；各步自己也按 `project?.path` 核对一次，不拿旧目录的结果盖新项目。
  Future<void> _hydrate(int epoch) async {
    Future<void> step(Future<void> Function() body) async {
      await body();
      if (epoch == _openEpoch && !disposed) touch();
    }

    await Future.wait(<Future<void>>[
      step(refreshBranches),
      step(refreshRules),
      step(() => files.setProject(project?.path)),
    ]);
  }

  /// 这条索引记录属不属于当前 workspace。还没选项目时不过滤；没记 cwd 的老条目分不清归属，照给，
  /// 免得永远找不回来。两边路径同源（都是 `workspace_open` 回的那份），但仍按分隔符、尾斜杠与
  /// （Windows 上）大小写归一后再比，同一目录的两种写法不能被判成两个 workspace。
  bool inCurrentWorkspace(String? cwd) {
    final scope = project?.path;
    if (scope == null || cwd == null || cwd.isEmpty) return true;
    return normalizeCwd(cwd) == normalizeCwd(scope);
  }

  static String normalizeCwd(String path) {
    var p = path.replaceAll('\\', '/');
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return Platform.isWindows ? p.toLowerCase() : p;
  }

  // ---------------------------------------------------------------- 分支与规则

  Future<void> refreshBranches() async {
    final b = bridge;
    final cwd = project?.path;
    if (b == null || cwd == null) return;
    final result = await b.gitBranches(cwd);
    // 三件并发 + 用户连点：回来时项目可能已经换了，过期的分支区不能盖上去。
    if (project?.path != cwd) return;
    final available = result['available'] == true;
    final isRepo = result['isRepo'] == true;
    branchAreaVisible = available && isRepo;
    branch = branchAreaVisible ? result['current'] as String? : null;
    final raw = result['branches'];
    branches = <BranchRef>[
      if (raw is List)
        for (final x in raw)
          if (x is Map)
            BranchRef(
              name: x['name'] as String? ?? '',
              author: x['author'] as String?,
              when: x['when'] as String?,
              subject: x['subject'] as String?,
            ),
    ];
  }

  /// Rules 行（画板 30 / 40）：项目根下规则文件的计数。
  Future<void> refreshRules() async {
    final b = bridge;
    final cwd = project?.path;
    if (b == null || cwd == null) return;
    final listing = await b.fsListDir(cwd, cwd);
    if (project?.path != cwd) return;
    final entries = listing['entries'];
    var count = 0;
    if (entries is List) {
      for (final e in entries) {
        if (e is Map && e['isDir'] != true && ruleFileNames.contains(e['name'])) count++;
      }
    }
    rulesCount = count;
  }

  Future<void> switchBranch(String name) async {
    hidePopover(branchAnchor);
    branchInput.clear();
    final b = bridge;
    final cwd = project?.path;
    if (b == null || cwd == null) return;
    await guard(() async {
      await b.gitSwitch(cwd, name);
      await refreshBranches();
    });
    touch();
  }

  Future<void> createBranch(String name) async {
    hidePopover(branchAnchor);
    branchInput.clear();
    final b = bridge;
    final cwd = project?.path;
    if (b == null || cwd == null) return;
    await guard(() async {
      await b.gitCreateBranch(cwd, name);
      await refreshBranches();
    });
    touch();
  }
}
