// 文件面板的接线状态（R4 接线阶段）：把画板 60 的 widget（lib/ui/files/）接到桥命令——树走 `fs_list_dir`、内容走 `fs_read`、
// 搜索走 `fs_search`、徽章走 `git_status`、刷新走 `fs_watch` 流。widget 只拿数据与回调，不知道桥的存在（CLAUDE.md 规则 3）。
// 「Go to File」/ diff 行 / `@` 芯片 / Follow 都落到 [openPath]。

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../projection/wire.dart';
import '../theme/tokens.dart' as t;
import '../ui/files/file_tree.dart';
import '../ui/files/files_panel.dart';
import 'core_bridge.dart';

class FilesState extends ChangeNotifier {
  FilesState({this.bridge});

  final CoreCommands? bridge;

  final TextEditingController filter = TextEditingController();
  final FocusNode filterFocus = FocusNode();

  String? root;
  FileTree? tree;
  bool searchMode = false;
  List<FileEntry> searchResults = const <FileEntry>[];
  String? selectedPath;
  FileViewerData? viewer;
  FileViewMode viewMode = FileViewMode.preview;
  int? highlightLine;
  String? lastError;

  /// git 徽章的原始条目（`git_status` 的 entries；非仓库为空）。
  bool gitAvailable = false;

  StreamSubscription<JsonMap>? _watch;
  Timer? _searchDebounce;
  bool _disposed = false;

  /// 搜索去抖：`fs_search` 是一次目录遍历，逐键触发没有意义。取动效 token 的 base（160ms）当去抖窗口。
  static const Duration searchDebounce = t.Motion.base;

  /// `@` 提及与面板搜索共用的结果上限。
  static const int searchLimit = 50;

  // ---------------------------------------------------------------- 项目切换

  /// 换项目：重建树、重启监视、清掉查看器。
  Future<void> setProject(String? path) async {
    if (path == root && tree != null) return;
    final previous = root;
    // 不等 cancel：frb 流的取消是 Dart 侧关端口，Rust 侧监视器由 `fs_unwatch` 明确停掉。
    unawaited(_watch?.cancel());
    _watch = null;
    if (previous != null && bridge != null) unawaited(_guard(() => bridge!.fsUnwatch(previous)));
    tree?.removeListener(_forward);
    tree = null;
    root = path;
    selectedPath = null;
    viewer = null;
    highlightLine = null;
    searchResults = const <FileEntry>[];
    _touch();
    final b = bridge;
    if (path == null || b == null) return;
    final t = FileTree(root: path, loader: (dir) => _list(b, path, dir));
    t.addListener(_forward);
    tree = t;
    await _guard(() => t.reload());
    await refreshBadges();
    _watch = b.fsWatch(path).listen(_onChanges, onError: (Object e) => lastError = describeError(e));
  }

  Future<List<FileEntry>> _list(CoreCommands b, String rootPath, String dir) async {
    final listing = await b.fsListDir(rootPath, dir);
    final raw = listing['entries'];
    return <FileEntry>[
      if (raw is List)
        for (final e in raw)
          if (e is Map) FileEntry.fromJson(e.cast<String, dynamic>()),
    ];
  }

  /// `fs_watch` 的一批变化：受影响的目录重列；`.git` 变了刷新徽章；打开着的文件在变化目录下就重读（agent 刚改过它）。
  Future<void> _onChanges(JsonMap change) async {
    final t = tree;
    if (t == null) return;
    final dirs = change['dirs'];
    if (dirs is List) {
      for (final d in dirs) {
        if (d is String) await _guard(() => t.refreshDir(d));
      }
      final open = selectedPath;
      if (open != null && dirs.any((d) => d is String && _isParentOf(d, open))) {
        await _reopen(open);
      }
    }
    if (change['git'] == true || (dirs is List && dirs.isNotEmpty)) await refreshBadges();
  }

  static bool _isParentOf(String dir, String file) {
    final f = pathKey(file);
    final i = f.lastIndexOf('/');
    return i > 0 && f.substring(0, i) == pathKey(dir);
  }

  Future<void> refreshBadges() async {
    final b = bridge;
    final r = root;
    final t = tree;
    if (b == null || r == null || t == null) return;
    await _guard(() async {
      final status = await b.gitStatus(r);
      gitAvailable = status['available'] == true && status['isRepo'] == true;
      final entries = status['entries'];
      final badges = <String, String>{};
      if (entries is List) {
        for (final e in entries) {
          if (e is Map && e['path'] is String && e['badge'] is String) badges[e['path'] as String] = e['badge'] as String;
        }
      }
      t.setBadges(badges);
    });
  }

  // ---------------------------------------------------------------- 树的动作（画板 60 头行与行）

  Future<void> refresh() async {
    final t = tree;
    if (t == null) return;
    await _guard(() => t.reload());
    await refreshBadges();
  }

  void collapseAll() => tree?.collapseAll();

  Future<void> toggleDir(FileNode node) async {
    final t = tree;
    if (t == null) return;
    await _guard(() => t.toggle(node));
  }

  void toggleSearch() {
    searchMode = !searchMode;
    searchResults = const <FileEntry>[];
    if (searchMode) {
      tree?.setFilter('');
      filterFocus.requestFocus();
      onFilterChanged(filter.text);
    } else {
      _searchDebounce?.cancel();
      tree?.setFilter(filter.text);
    }
    _touch();
  }

  void onFilterChanged(String text) {
    if (!searchMode) {
      tree?.setFilter(text);
      return;
    }
    _searchDebounce?.cancel();
    if (text.trim().isEmpty) {
      searchResults = const <FileEntry>[];
      _touch();
      return;
    }
    _searchDebounce = Timer(searchDebounce, () => _search(text));
  }

  Future<void> _search(String query) async {
    final b = bridge;
    final r = root;
    if (b == null || r == null) return;
    await _guard(() async {
      final result = await b.fsSearch(r, query, limit: searchLimit);
      List<FileEntry> of(Object? raw) => <FileEntry>[
            if (raw is List)
              for (final e in raw)
                if (e is Map) FileEntry.fromJson(e.cast<String, dynamic>()),
          ];
      // 只在结果还对应当前输入时才落地（慢的那次别覆盖快的）。
      if (filter.text.trim() != query.trim()) return;
      searchResults = <FileEntry>[...of(result['files']), ...of(result['directories'])];
    });
    _touch();
  }

  // ---------------------------------------------------------------- 查看器

  Future<void> open(FileEntry entry) async {
    if (entry.isDir) {
      final node = tree?.nodeOf(entry.path);
      if (node != null) await toggleDir(node);
      return;
    }
    await openPath(entry.path);
  }

  /// 定位：树里展开到该文件、查看器打开它；给了 `line` 就切到 Source 并高亮那一行（画板 18 / 21 / 11 / Follow）。
  Future<void> openPath(String path, {int? line}) async {
    final t = tree;
    if (t != null) await _guard(() => t.reveal(path));
    selectedPath = path;
    highlightLine = line;
    if (line != null) viewMode = FileViewMode.source;
    await _reopen(path);
  }

  Future<void> _reopen(String path) async {
    final b = bridge;
    final r = root;
    if (b == null || r == null) return;
    await _guard(() async {
      final c = await b.fsRead(r, path);
      final name = path.split(RegExp(r'[\\/]')).last;
      final rel = relativeTo(r, path);
      viewer = FileViewerData(
        name: name,
        relPath: '/${rel ?? name}',
        text: c['text'] as String? ?? '',
        language: languageForName(name),
        lineCount: (c['lines'] as num?)?.toInt() ?? 0,
        sizeBytes: (c['size'] as num?)?.toInt() ?? 0,
        binary: c['binary'] == true,
        truncated: c['truncated'] == true,
      );
    });
    _touch();
  }

  void setViewMode(FileViewMode mode) {
    viewMode = mode;
    _touch();
  }

  // ---------------------------------------------------------------- 杂项

  Future<T?> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (e) {
      lastError = describeError(e);
      debugPrint('[files] ${describeError(e)}');
      _touch();
      return null;
    }
  }

  void _forward() => _touch();

  void _touch() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _searchDebounce?.cancel();
    _watch?.cancel();
    // 取消 frb 流只关 Dart 端口，Rust 侧的监视器要 `fs_unwatch` 才停（审查 finding，2026-09-16）。
    final r = root;
    final b = bridge;
    if (r != null && b != null) unawaited(_guard(() => b.fsUnwatch(r)));
    tree?.removeListener(_forward);
    filter.dispose();
    filterFocus.dispose();
    super.dispose();
  }
}
