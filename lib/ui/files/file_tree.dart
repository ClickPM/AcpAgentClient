// 画板 60 · 文件树的模型（纯 Dart，无 widget 依赖）：懒加载的目录节点、展开 / 折叠、按名过滤、按路径定位（展开祖先）、
// git 状态徽章。目录内容由注入的 [DirLoader] 给：gallery 用本地假数据，接线阶段换 `fs_list_dir`，widget 不动（CLAUDE.md 规则 3）。

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// `fs_list_dir` 的一条（Rust `fs::Entry` 的形状）。
class FileEntry {
  const FileEntry({required this.name, required this.path, this.parent = '', this.isDir = false, this.size});

  factory FileEntry.fromJson(Map<String, dynamic> json) => FileEntry(
        name: json['name'] as String? ?? '',
        path: json['path'] as String? ?? '',
        parent: json['parent'] as String? ?? '',
        isDir: json['isDir'] == true,
        size: (json['size'] as num?)?.toInt(),
      );

  final String name;

  /// 绝对路径。
  final String path;

  /// 相对根的所在目录，末尾带 `/`（根目录下是空串）。
  final String parent;
  final bool isDir;
  final int? size;
}

typedef DirLoader = Future<List<FileEntry>> Function(String path);

/// 路径比较用的键：统一斜杠、去尾斜杠；Windows 不分大小写（agent 给的 `locations[].path` 与 `fs_list_dir` 的盘符大小写可能不同）。
String pathKey(String path) {
  var p = path.replaceAll(r'\', '/');
  while (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return Platform.isWindows ? p.toLowerCase() : p;
}

/// `path` 相对 `root` 的路径（正斜杠）；不在 root 之内返回 null。
String? relativeTo(String root, String path) {
  final r = pathKey(root);
  final p = pathKey(path);
  if (p == r) return '';
  if (!p.startsWith('$r/')) return null;
  // 用原始文本切，保留大小写。
  final norm = path.replaceAll(r'\', '/');
  return norm.substring(norm.length - (p.length - r.length - 1));
}

class FileNode {
  FileNode({required this.entry, required this.depth});

  final FileEntry entry;
  final int depth;
  bool expanded = false;
  bool loading = false;
  bool loaded = false;
  String? error;
  List<FileNode> children = const <FileNode>[];

  String get path => entry.path;
  String get name => entry.name;
  bool get isDir => entry.isDir;
}

class FileTree extends ChangeNotifier {
  FileTree({required this.root, required this.loader});

  final String root;
  final DirLoader loader;

  List<FileNode> _top = const <FileNode>[];
  final Map<String, FileNode> _byKey = <String, FileNode>{};

  /// git 状态徽章：路径键 → 单字母（`M` / `A` / `D` / `?`），非 git 目录为空。
  Map<String, String> _badges = const <String, String>{};

  /// 过滤文本（画板 60 的「过滤文件名...」；大小写不敏感，只作用于已加载的节点）。
  String filter = '';

  bool loadedRoot = false;
  String? rootError;

  List<FileNode> get top => _top;

  /// 同步灌一棵树（gallery 与测试）：`dirs` 是「目录绝对路径 → 该目录的条目」，`expanded` 是要展开的目录路径；
  /// 之后的懒加载仍走 [loader]。
  void seed(Map<String, List<FileEntry>> dirs, {Set<String> expanded = const <String>{}}) {
    final byKey = <String, List<FileEntry>>{for (final e in dirs.entries) pathKey(e.key): e.value};
    final open = <String>{for (final p in expanded) pathKey(p)};
    _byKey.clear();
    List<FileNode> build(String dir, int depth) {
      final nodes = _nodesOf(byKey[pathKey(dir)] ?? const <FileEntry>[], depth: depth);
      for (final n in nodes) {
        if (n.isDir && byKey.containsKey(pathKey(n.path))) {
          n.children = build(n.path, depth + 1);
          n.loaded = true;
          n.expanded = open.contains(pathKey(n.path));
        }
      }
      return nodes;
    }

    _top = build(root, 0);
    loadedRoot = true;
    rootError = null;
    notifyListeners();
  }

  FileNode? nodeOf(String path) => _byKey[pathKey(path)];

  String? badgeOf(String path) => _badges[pathKey(path)];

  void setBadges(Map<String, String> byPath) {
    _badges = <String, String>{for (final e in byPath.entries) pathKey(e.key): e.value};
    notifyListeners();
  }

  void setFilter(String text) {
    if (filter == text) return;
    filter = text;
    notifyListeners();
  }

  /// 首次加载 / 刷新根目录：已展开的目录保持展开（重新加载它们的内容）。
  Future<void> reload() async {
    final expandedPaths = <String>{
      for (final n in _byKey.values)
        if (n.isDir && n.expanded) pathKey(n.path),
    };
    _byKey.clear();
    try {
      _top = _nodesOf(await loader(root), depth: 0);
      loadedRoot = true;
      rootError = null;
    } catch (e) {
      _top = const <FileNode>[];
      loadedRoot = true;
      rootError = e.toString();
    }
    notifyListeners();
    // 按深度逐层恢复展开（父目录先加载，子目录的节点才存在）。
    var frontier = List<FileNode>.of(_top);
    while (frontier.isNotEmpty) {
      final next = <FileNode>[];
      for (final n in frontier) {
        if (n.isDir && expandedPaths.contains(pathKey(n.path))) {
          await expand(n);
          next.addAll(n.children);
        }
      }
      frontier = next;
    }
  }

  List<FileNode> _nodesOf(List<FileEntry> entries, {required int depth}) {
    final nodes = <FileNode>[];
    for (final e in entries) {
      final n = FileNode(entry: e, depth: depth);
      _byKey[pathKey(e.path)] = n;
      nodes.add(n);
    }
    return nodes;
  }

  void _forget(FileNode n) {
    for (final c in n.children) {
      _forget(c);
    }
    _byKey.remove(pathKey(n.path));
  }

  /// 展开一个目录（首次展开时加载内容）。
  Future<void> expand(FileNode n) async {
    if (!n.isDir) return;
    n.expanded = true;
    if (n.loaded || n.loading) {
      notifyListeners();
      return;
    }
    await _load(n);
  }

  Future<void> _load(FileNode n) async {
    n.loading = true;
    notifyListeners();
    try {
      final entries = await loader(n.path);
      for (final c in n.children) {
        _forget(c);
      }
      n.children = _nodesOf(entries, depth: n.depth + 1);
      n.loaded = true;
      n.error = null;
    } catch (e) {
      n.children = const <FileNode>[];
      n.loaded = true;
      n.error = e.toString();
    } finally {
      n.loading = false;
    }
    notifyListeners();
  }

  void collapse(FileNode n) {
    if (!n.expanded) return;
    n.expanded = false;
    notifyListeners();
  }

  Future<void> toggle(FileNode n) => n.expanded ? Future<void>.sync(() => collapse(n)) : expand(n);

  /// 画板 60 头行的「全部折叠」：只折叠，不丢已加载的内容。
  void collapseAll() {
    for (final n in _byKey.values) {
      n.expanded = false;
    }
    notifyListeners();
  }

  /// 某个目录下的内容变了（`fs_watch`）：已加载的重新加载，没加载过的不管；根目录变了重载根。
  Future<void> refreshDir(String dirPath) async {
    if (pathKey(dirPath) == pathKey(root)) {
      await reload();
      return;
    }
    final n = nodeOf(dirPath);
    if (n == null || !n.isDir || !n.loaded) return;
    final wasExpanded = <String>{
      for (final c in n.children)
        if (c.isDir && c.expanded) pathKey(c.path),
    };
    await _load(n);
    for (final c in n.children) {
      if (wasExpanded.contains(pathKey(c.path))) await expand(c);
    }
  }

  /// 定位（画板 18 的 Go to File、21 的行点击、11 的 `@` 芯片、Follow）：逐级展开祖先并返回该节点；
  /// 不在 root 之内或路径不存在返回 null。
  Future<FileNode?> reveal(String path) async {
    final rel = relativeTo(root, path);
    if (rel == null || rel.isEmpty) return null;
    if (!loadedRoot) await reload();
    final segments = rel.split('/').where((s) => s.isNotEmpty).toList();
    List<FileNode> level = _top;
    FileNode? found;
    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      FileNode? match;
      for (final n in level) {
        if (_sameName(n.name, seg)) {
          match = n;
          break;
        }
      }
      if (match == null) return null;
      found = match;
      if (i < segments.length - 1) {
        if (!match.isDir) return null;
        await expand(match);
        level = match.children;
      }
    }
    return found;
  }

  static bool _sameName(String a, String b) => Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;

  /// 当前可见的行：按展开状态深度优先展平；有过滤文本时只留名字命中的文件 / 目录，以及含命中后代的目录（展开着显示）。
  List<FileNode> get visibleRows {
    final out = <FileNode>[];
    final q = filter.trim().toLowerCase();
    if (q.isEmpty) {
      void walk(List<FileNode> nodes) {
        for (final n in nodes) {
          out.add(n);
          if (n.isDir && n.expanded) walk(n.children);
        }
      }

      walk(_top);
      return out;
    }
    bool walk(List<FileNode> nodes) {
      var any = false;
      for (final n in nodes) {
        final selfHit = n.name.toLowerCase().contains(q);
        final mark = out.length;
        out.add(n);
        final childHit = n.isDir && n.loaded ? walk(n.children) : false;
        if (selfHit || childHit) {
          any = true;
        } else {
          out.removeRange(mark, out.length);
        }
      }
      return any;
    }

    walk(_top);
    return out;
  }
}
