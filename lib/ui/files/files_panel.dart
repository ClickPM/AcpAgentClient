// 画板 60 · 文件面板：左列文件树（头行「文件浏览器」+ 搜索开关 / 全部折叠 / 刷新，过滤输入，24 高的树行：折叠箭头 · 文件夹 / 文件图标 ·
// 名字 · git 徽章），右侧查看器（头行：文件名 · 路径 · Source / Preview 分段 · 复制；正文：标题 + 「language · N lines · size」元信息 +
// Preview（Markdown，R1.5 裁定的 package:markdown 自写渲染）或 Source（re_highlight 高亮 + 行号，可高亮并滚到某一行）；空态）。
// 查看器头行取画板 03（2026-09-16 改稿后）的 36 高，树列宽取画板 60 的 240；数据全部由调用方给（树模型 file_tree.dart、
// 内容 [FileViewerData]），接线阶段只换数据源（CLAUDE.md 规则 3）。
// 树列宽可拖（复用画板 04 的分栏把手 [ColumnSplitter]），头行那个「缩小」按钮收起整列、只留查看器——收起后由查看器头行
// 左侧的按钮放回来（所有者裁定 2026-09-17；原先那个按钮是「全部折叠」，换成收起列后 [FileTree.collapseAll] 不再有入口）。

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import '../format.dart';
import '../shell/shell_common.dart';
import '../shell/splitter.dart';
import '../transcript/card_chrome.dart';
import '../transcript/code_block.dart';
import '../transcript/icons.dart';
import '../transcript/markdown_body.dart';
import 'file_tree.dart';

enum FileViewMode { source, preview }

/// 查看器里打开的一个文件（`fs_read` 的结果 + 展示用的派生字段）。
class FileViewerData {
  const FileViewerData({
    required this.name,
    required this.relPath,
    required this.text,
    this.language = const FileLanguage('text', null),
    this.lineCount = 0,
    this.sizeBytes = 0,
    this.binary = false,
    this.truncated = false,
  });

  final String name;

  /// 相对项目根的路径，带前导 `/`（画板 60 的 `/AGENTS.md`）。
  final String relPath;
  final String text;
  final FileLanguage language;
  final int lineCount;
  final int sizeBytes;

  /// 不是文本：查看器只给提示。
  final bool binary;

  /// 超过 `fs_read` 的上限，只拿到了前一段。
  final bool truncated;

  bool get isMarkdown => language.highlight == 'markdown';

  /// 「markdown · 168 lines · 13.1 KB」。
  String get meta => '${language.label} · $lineCount lines · ${formatBytes(sizeBytes)}';
}

/// 语言：展示名 + re_highlight 的语言 id（null = 不高亮）。
class FileLanguage {
  const FileLanguage(this.label, this.highlight);

  final String label;
  final String? highlight;
}

const Map<String, FileLanguage> _languagesByExtension = <String, FileLanguage>{
  'md': FileLanguage('markdown', 'markdown'),
  'markdown': FileLanguage('markdown', 'markdown'),
  'dart': FileLanguage('dart', 'dart'),
  'rs': FileLanguage('rust', 'rust'),
  'ts': FileLanguage('typescript', 'typescript'),
  'tsx': FileLanguage('typescript', 'typescript'),
  'js': FileLanguage('javascript', 'javascript'),
  'mjs': FileLanguage('javascript', 'javascript'),
  'cjs': FileLanguage('javascript', 'javascript'),
  'jsx': FileLanguage('javascript', 'javascript'),
  'json': FileLanguage('json', 'json'),
  'jsonl': FileLanguage('json lines', 'json'),
  'yaml': FileLanguage('yaml', 'yaml'),
  'yml': FileLanguage('yaml', 'yaml'),
  'toml': FileLanguage('toml', 'ini'),
  'ini': FileLanguage('ini', 'ini'),
  'ps1': FileLanguage('powershell', 'powershell'),
  'psm1': FileLanguage('powershell', 'powershell'),
  'sh': FileLanguage('shell', 'bash'),
  'bash': FileLanguage('shell', 'bash'),
  'bat': FileLanguage('batch', 'dos'),
  'cmd': FileLanguage('batch', 'dos'),
  'py': FileLanguage('python', 'python'),
  'html': FileLanguage('html', 'xml'),
  'htm': FileLanguage('html', 'xml'),
  'xml': FileLanguage('xml', 'xml'),
  'svg': FileLanguage('svg', 'xml'),
  'css': FileLanguage('css', 'css'),
  'c': FileLanguage('c', 'c'),
  'h': FileLanguage('c', 'c'),
  'cpp': FileLanguage('c++', 'cpp'),
  'cc': FileLanguage('c++', 'cpp'),
  'hpp': FileLanguage('c++', 'cpp'),
  'java': FileLanguage('java', 'java'),
  'kt': FileLanguage('kotlin', 'kotlin'),
  'go': FileLanguage('go', 'go'),
  'sql': FileLanguage('sql', 'sql'),
  'cmake': FileLanguage('cmake', 'cmake'),
  'gradle': FileLanguage('gradle', 'gradle'),
  'swift': FileLanguage('swift', 'swift'),
  'txt': FileLanguage('text', null),
  'lock': FileLanguage('text', null),
  'log': FileLanguage('text', null),
};

/// 文件名 → 语言（按扩展名；`CMakeLists.txt` / `Dockerfile` 这类按名字）。
FileLanguage languageForName(String name) {
  final lower = name.toLowerCase();
  if (lower == 'cmakelists.txt') return const FileLanguage('cmake', 'cmake');
  if (lower == 'dockerfile') return const FileLanguage('dockerfile', 'dockerfile');
  if (lower == 'makefile') return const FileLanguage('makefile', 'makefile');
  final dot = lower.lastIndexOf('.');
  if (dot < 0 || dot == lower.length - 1) return const FileLanguage('text', null);
  return _languagesByExtension[lower.substring(dot + 1)] ?? const FileLanguage('text', null);
}

/// 把高亮结果（一棵 TextSpan）按换行切成每行一个 span，样式跟着叶子走；行数与 `text.split('\n')` 一致。
List<TextSpan> splitSpanLines(TextSpan root) {
  final lines = <TextSpan>[];
  var current = <InlineSpan>[];
  void visit(InlineSpan span, TextStyle? inherited) {
    if (span is! TextSpan) return;
    final style = inherited == null ? span.style : (span.style == null ? inherited : inherited.merge(span.style));
    final text = span.text;
    if (text != null && text.isNotEmpty) {
      final parts = text.split('\n');
      for (var i = 0; i < parts.length; i++) {
        if (i > 0) {
          lines.add(TextSpan(children: current));
          current = <InlineSpan>[];
        }
        if (parts[i].isNotEmpty) current.add(TextSpan(text: parts[i], style: style));
      }
    }
    for (final c in span.children ?? const <InlineSpan>[]) {
      visit(c, style);
    }
  }

  visit(root, null);
  lines.add(TextSpan(children: current));
  return lines;
}

class FilesPanel extends StatelessWidget {
  const FilesPanel({
    super.key,
    required this.tree,
    required this.filterController,
    required this.filterFocusNode,
    this.searchMode = false,
    this.searchResults = const <FileEntry>[],
    this.selectedPath,
    this.viewer,
    this.viewMode = FileViewMode.preview,
    this.highlightLine,
    this.onToggleSearch,
    this.onRefresh,
    this.onFilterChanged,
    this.onOpen,
    this.onToggleDir,
    this.onViewMode,
    this.onLink,
    this.treeWidth = t.Geometry.filesTreeWidth,
    this.treeCollapsed = false,
    this.onToggleTree,
    this.onResizeTree,
    this.onResizeTreeEnd,
    this.onResetTreeWidth,
    this.hoveredPath,
  });

  final FileTree tree;
  final TextEditingController filterController;
  final FocusNode filterFocusNode;

  /// 搜索开关（头行第一个图标）：开着时输入走 `fs_search`，列表是 [searchResults] 的扁平结果。
  final bool searchMode;
  final List<FileEntry> searchResults;
  final String? selectedPath;
  final FileViewerData? viewer;
  final FileViewMode viewMode;

  /// Source 视图里要高亮并滚到的行（1-based；定位动作给）。
  final int? highlightLine;
  final VoidCallback? onToggleSearch;
  final VoidCallback? onRefresh;
  final ValueChanged<String>? onFilterChanged;

  /// 点了一个文件（树行或搜索结果）。
  final ValueChanged<FileEntry>? onOpen;
  final ValueChanged<FileNode>? onToggleDir;
  final ValueChanged<FileViewMode>? onViewMode;
  final void Function(String href)? onLink;
  final double treeWidth;

  /// 树列已收起：只剩查看器，放回来的按钮在查看器头行左侧。
  final bool treeCollapsed;

  /// 收起 / 放回（同一个动作，树列头行的「缩小」与查看器头行的按钮共用）。
  final VoidCallback? onToggleTree;

  /// 拖树列宽度的增量（逻辑像素，向右为正）；`null` = 不给把手（gallery 画板）。夹取与落盘是调用方的事。
  final ValueChanged<double>? onResizeTree;
  final VoidCallback? onResizeTreeEnd;
  final VoidCallback? onResetTreeWidth;

  /// gallery：预先呈现某一行的悬浮态。
  final String? hoveredPath;

  @override
  Widget build(BuildContext context) {
    if (treeCollapsed) return _viewer(leading: _restoreButton());
    return LayoutBuilder(builder: (context, constraints) {
      final double width = _fitTreeWidth(constraints.maxWidth);
      // 把手叠在树列右边框上、不占布局（同 AppShell：占了布局，分栏线宽度就和画板对不上了）。
      const double half = t.Geometry.splitterHit / 2;
      return Stack(
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(
                width: width,
                child: _FileTreeColumn(
                  tree: tree,
                  filterController: filterController,
                  filterFocusNode: filterFocusNode,
                  searchMode: searchMode,
                  searchResults: searchResults,
                  selectedPath: selectedPath,
                  onToggleSearch: onToggleSearch,
                  onCollapseTree: onToggleTree,
                  onRefresh: onRefresh,
                  onFilterChanged: onFilterChanged,
                  onOpen: onOpen,
                  onToggleDir: onToggleDir,
                  hoveredPath: hoveredPath,
                ),
              ),
              Expanded(child: _viewer()),
            ],
          ),
          if (onResizeTree != null)
            Positioned(
              left: width - half,
              top: 0,
              bottom: 0,
              width: t.Geometry.splitterHit,
              child: ColumnSplitter(onDelta: onResizeTree!, onDragEnd: onResizeTreeEnd, onReset: onResetTreeWidth),
            ),
        ],
      );
    });
  }

  /// 面板被拖窄时先压树列：查看器无论如何留 [t.Geometry.filesViewerMinWidth]，树列不低于自己的下限。
  double _fitTreeWidth(double available) {
    if (!available.isFinite) return treeWidth;
    return math.min(treeWidth, math.max(t.Geometry.filesTreeMinWidth, available - t.Geometry.filesViewerMinWidth));
  }

  Widget? _restoreButton() => onToggleTree == null ? null : IconButtonGhost(icon: AcpIcons.panelLeft, onTap: onToggleTree, size: t.Geometry.panelIconButton);

  /// 右半边：查看器（或空态）。[leading] 是树列收起时「放回来」的按钮，空态也得给得到，
  /// 不然树一收起就再也点不回来。
  Widget _viewer({Widget? leading}) {
    if (viewer != null) {
      return _FileViewer(
        viewer!,
        mode: viewMode,
        highlightLine: highlightLine,
        onViewMode: onViewMode,
        onLink: onLink,
        leading: leading,
      );
    }
    if (leading == null) return const FileViewerEmpty();
    return Container(
      color: t.Surface.canvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            height: t.Geometry.barHeight,
            padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s8),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
            alignment: Alignment.centerLeft,
            child: leading,
          ),
          const Expanded(child: FileViewerEmpty()),
        ],
      ),
    );
  }
}

/// 树列：头行 + 过滤框 + 树。
class _FileTreeColumn extends StatelessWidget {
  const _FileTreeColumn({
    required this.tree,
    required this.filterController,
    required this.filterFocusNode,
    this.searchMode = false,
    this.searchResults = const <FileEntry>[],
    this.selectedPath,
    this.onToggleSearch,
    this.onCollapseTree,
    this.onRefresh,
    this.onFilterChanged,
    this.onOpen,
    this.onToggleDir,
    this.hoveredPath,
  });

  final FileTree tree;
  final TextEditingController filterController;
  final FocusNode filterFocusNode;
  final bool searchMode;
  final List<FileEntry> searchResults;
  final String? selectedPath;
  final VoidCallback? onToggleSearch;
  final VoidCallback? onCollapseTree;
  final VoidCallback? onRefresh;
  final ValueChanged<String>? onFilterChanged;
  final ValueChanged<FileEntry>? onOpen;
  final ValueChanged<FileNode>? onToggleDir;
  final String? hoveredPath;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: t.Neutral.panel,
        border: Border(right: BorderSide(color: t.Borders.subtle, width: t.Borders.width)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _header(),
          _filter(),
          Expanded(child: ListenableBuilder(listenable: tree, builder: (context, _) => _list())),
        ],
      ),
    );
  }

  Widget _header() => Container(
        height: t.Geometry.panelHeaderHeight,
        padding: const EdgeInsets.only(left: t.Spacing.s8, right: t.Spacing.s4),
        child: Row(
          children: <Widget>[
            Expanded(child: Text('文件浏览器', style: t.TextStyles.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
            IconButtonGhost(icon: AcpIcons.search, selected: searchMode, onTap: onToggleSearch, size: t.Geometry.panelIconButton),
            IconButtonGhost(icon: AcpIcons.collapseAll, onTap: onCollapseTree, size: t.Geometry.panelIconButton),
            IconButtonGhost(icon: AcpIcons.rotateCw, onTap: onRefresh, size: t.Geometry.panelIconButton),
          ],
        ),
      );

  Widget _filter() => Padding(
        padding: const EdgeInsets.only(left: t.Spacing.s8, right: t.Spacing.s8, bottom: t.Spacing.s4),
        child: Container(
          height: t.Controls.compact,
          decoration: BoxDecoration(
            color: t.Surface.canvas,
            border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
            borderRadius: t.Radii.control,
          ),
          padding: t.Controls.padCompact,
          alignment: Alignment.centerLeft,
          child: AcpTextField(
            controller: filterController,
            focusNode: filterFocusNode,
            style: CardText.secondary.copyWith(color: t.Neutral.text),
            placeholder: searchMode ? '搜索文件名...' : '过滤文件名...',
            placeholderStyle: CardText.secondary.copyWith(color: t.Neutral.placeholder),
            onChanged: onFilterChanged,
          ),
        ),
      );

  Widget _list() {
    if (searchMode && filterController.text.trim().isNotEmpty) {
      if (searchResults.isEmpty) return const _TreeNote('没有匹配的文件');
      return ListView.builder(
        padding: const EdgeInsets.all(t.Spacing.s4),
        itemExtent: t.Geometry.treeRowHeight,
        itemCount: searchResults.length,
        itemBuilder: (context, i) {
          final e = searchResults[i];
          return _FileTreeRow(
            name: e.name,
            isDir: e.isDir,
            depth: 0,
            secondary: e.parent,
            selected: selectedPath != null && pathKey(selectedPath!) == pathKey(e.path),
            forceHover: hoveredPath != null && pathKey(hoveredPath!) == pathKey(e.path),
            onTap: onOpen == null ? null : () => onOpen!(e),
          );
        },
      );
    }
    if (tree.rootError != null) return _TreeNote(tree.rootError!);
    final rows = tree.visibleRows;
    if (tree.loadedRoot && rows.isEmpty) return _TreeNote(tree.filter.trim().isEmpty ? '空目录' : '没有匹配的文件');
    return ListView.builder(
      padding: const EdgeInsets.all(t.Spacing.s4),
      itemExtent: t.Geometry.treeRowHeight,
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final n = rows[i];
        return _FileTreeRow(
          name: n.name,
          isDir: n.isDir,
          depth: n.depth,
          expanded: n.expanded,
          badge: tree.badgeOf(n.path),
          selected: selectedPath != null && pathKey(selectedPath!) == pathKey(n.path),
          forceHover: hoveredPath != null && pathKey(hoveredPath!) == pathKey(n.path),
          onTap: n.isDir
              ? (onToggleDir == null ? null : () => onToggleDir!(n))
              : (onOpen == null ? null : () => onOpen!(n.entry)),
        );
      },
    );
  }
}

/// 树列里的一行提示（空目录 / 无匹配 / 读不到）。
class _TreeNote extends StatelessWidget {
  const _TreeNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(t.Spacing.s12),
        child: Text(text, style: t.TextStyles.meta),
      );
}

/// 树的一行：`[折叠箭头 | 占位] [文件夹 / 文件图标] 名字 … [徽章]`；选中 = 按下态容器 + accent 文字。
class _FileTreeRow extends StatelessWidget {
  const _FileTreeRow({
    required this.name,
    required this.isDir,
    this.depth = 0,
    this.expanded = false,
    this.badge,
    this.secondary,
    this.selected = false,
    this.forceHover = false,
    this.onTap,
  });

  final String name;
  final bool isDir;
  final int depth;
  final bool expanded;

  /// git 状态徽章（`M` 等，mono 11 warning）。
  final String? badge;

  /// 搜索结果行尾的所在目录。
  final String? secondary;
  final bool selected;
  final bool forceHover;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Hoverable(
      onTap: onTap,
      forceHover: forceHover,
      builder: (context, hovered) => Container(
        height: t.Geometry.treeRowHeight,
        padding: EdgeInsets.only(left: t.Spacing.s8 + depth * t.Geometry.treeIndent, right: t.Spacing.s8),
        decoration: BoxDecoration(
          color: selected ? t.Overlays.selected : (hovered ? t.Overlays.hover : null),
          borderRadius: t.Radii.control,
        ),
        child: Row(
          children: <Widget>[
            if (isDir)
              AcpIcon(expanded ? AcpIcons.chevronDown : AcpIcons.chevronRight, color: t.Neutral.placeholder, size: t.IconSizes.toolbar)
            else
              const SizedBox(width: t.IconSizes.toolbar),
            const SizedBox(width: t.Spacing.s4),
            AcpIcon(isDir ? AcpIcons.folder : AcpIcons.file, color: isDir ? t.Neutral.muted : t.Neutral.placeholder, size: t.IconSizes.toolbar),
            const SizedBox(width: t.Spacing.s4),
            Expanded(
              child: Text(
                name,
                style: CardText.secondary.copyWith(color: selected ? t.Accent.text : t.Neutral.text),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (secondary != null && secondary!.isNotEmpty) ...<Widget>[
              const SizedBox(width: t.Spacing.s8),
              Flexible(child: Text(secondary!, style: t.TextStyles.monoMeta, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
            if (badge != null && badge!.isNotEmpty) ...<Widget>[
              const SizedBox(width: t.Spacing.s8),
              Text(badge!, style: t.TextStyles.monoMeta.copyWith(color: t.Semantic.warning)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 查看器空态（画板 60「查看器空态」）。
class FileViewerEmpty extends StatelessWidget {
  const FileViewerEmpty({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: t.Surface.canvas,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: t.Controls.input,
            height: t.Controls.input,
            decoration: BoxDecoration(
              border: Border.all(color: t.Borders.base, width: t.Borders.width),
              borderRadius: t.Radii.card,
            ),
            alignment: Alignment.center,
            child: AcpIcon(AcpIcons.file, color: t.Neutral.placeholder),
          ),
          const SizedBox(height: t.Spacing.s8),
          Text('没有打开的文件', style: t.TextStyles.title),
          const SizedBox(height: t.Spacing.s8),
          Text('在左侧文件树中点击任意文件即可在此展示内容与预览', style: t.TextStyles.secondary),
        ],
      ),
    );
  }
}

/// Source / Preview 分段控件（画板 60 / 03）。
class _SegmentedToggle extends StatelessWidget {
  const _SegmentedToggle({required this.mode, this.onChanged, this.previewEnabled = true});

  final FileViewMode mode;
  final ValueChanged<FileViewMode>? onChanged;

  /// 非 Markdown 文件没有预览：Preview 段不渲染。
  final bool previewEnabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: t.Controls.compact,
      padding: const EdgeInsets.all(t.Geometry.segmentedInset),
      decoration: BoxDecoration(color: t.Neutral.surface, borderRadius: t.Radii.control),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _segment('源码', FileViewMode.source),
          if (previewEnabled) _segment('预览', FileViewMode.preview),
        ],
      ),
    );
  }

  Widget _segment(String label, FileViewMode value) {
    final active = mode == value;
    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged!(value),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          height: t.Geometry.segmentHeight,
          padding: t.Controls.padCompact,
          decoration: BoxDecoration(color: active ? t.Surface.canvas : null, borderRadius: t.Radii.chip),
          alignment: Alignment.center,
          child: Text(label, style: t.TextStyles.meta.copyWith(color: active ? t.Accent.text : t.Neutral.muted)),
        ),
      ),
    );
  }
}

/// 查看器：头行 + 正文。
class _FileViewer extends StatelessWidget {
  const _FileViewer(
    this.data, {
    this.mode = FileViewMode.preview,
    this.highlightLine,
    this.onViewMode,
    this.onLink,
    this.leading,
  });

  final FileViewerData data;
  final FileViewMode mode;
  final int? highlightLine;
  final ValueChanged<FileViewMode>? onViewMode;
  final void Function(String href)? onLink;

  /// 头行最左的附加按钮（树列收起时的「放回来」）。
  final Widget? leading;

  Future<void> _copy() => Clipboard.setData(ClipboardData(text: data.text));

  @override
  Widget build(BuildContext context) {
    final effective = data.isMarkdown ? mode : FileViewMode.source;
    return Container(
      color: t.Surface.canvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            height: t.Geometry.barHeight,
            padding: EdgeInsets.only(left: leading == null ? t.Spacing.s12 : t.Spacing.s8, right: t.Spacing.s8),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
            child: Row(
              children: <Widget>[
                if (leading != null) ...<Widget>[leading!, const SizedBox(width: t.Spacing.s8)],
                // 文件名优先占满自然宽度、路径吃余量（画板：两者 min-width:0 + ellipsis，右侧那组贴右）。
                // 右栏 580 宽时查看器只剩 340，路径先被省略、文件名尽量保全。
                Flexible(
                  flex: 3,
                  child: Text(
                    data.name,
                    style: t.TextStyles.body.copyWith(color: t.Neutral.strong, height: t.LineHeights.control),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: t.Spacing.s8),
                Expanded(child: Text(data.relPath, style: t.TextStyles.monoMeta, maxLines: 1, overflow: TextOverflow.ellipsis)),
                _SegmentedToggle(mode: effective, onChanged: onViewMode, previewEnabled: data.isMarkdown),
                const SizedBox(width: t.Spacing.s4),
                AcpButton(
                  label: '复制',
                  icon: AcpIcons.copy,
                  height: t.Controls.compact,
                  iconColor: t.Neutral.muted,
                  labelColor: t.Neutral.muted,
                  onTap: _copy,
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(t.Spacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: <Widget>[
                      Flexible(child: Text(data.name, style: t.TextStyles.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      const SizedBox(width: t.Spacing.s8),
                      Text(data.meta, style: t.TextStyles.monoMeta),
                    ],
                  ),
                  if (data.truncated) ...<Widget>[
                    const SizedBox(height: t.Spacing.s4),
                    Text('文件过大，只显示前 ${formatBytes(data.text.length)}', style: t.TextStyles.monoMeta.copyWith(color: t.Semantic.warning)),
                  ],
                  const SizedBox(height: t.Spacing.s8),
                  Expanded(child: _body(effective)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(FileViewMode effective) {
    if (data.binary) {
      return Align(alignment: Alignment.topLeft, child: Text('二进制文件，不预览', style: t.TextStyles.secondary));
    }
    if (effective == FileViewMode.preview) {
      return SingleChildScrollView(child: MarkdownBody(data.text, onLink: onLink));
    }
    return _SourceView(text: data.text, language: data.language.highlight, highlightLine: highlightLine);
  }
}

/// Source 视图：行号 + 高亮，行高固定（定位滚动按行算），长行横向滚动。
class _SourceView extends StatefulWidget {
  const _SourceView({required this.text, this.language, this.highlightLine});

  final String text;
  final String? language;
  final int? highlightLine;

  @override
  State<_SourceView> createState() => _SourceViewState();
}

class _SourceViewState extends State<_SourceView> {
  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();
  late List<String> _lines;
  late List<TextSpan> _spans;
  late double _lineHeight;
  late double _gutter;
  late double _maxLineWidth;

  @override
  void initState() {
    super.initState();
    _prepare();
    _scheduleReveal();
  }

  /// 算 [_spans] / [_lineHeight] / [_gutter] / [_maxLineWidth] 时用的字体代数。
  /// 这些都带 family（span 的 style、TextPainter 量出来的宽高），换字体后必须重算；
  /// 但它们又贵到不能每帧现算，所以按代数判断是否过期（`t.Fonts.generation`）。
  int _fontGeneration = t.Fonts.generation;

  @override
  void didUpdateWidget(_SourceView old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.language != widget.language) _prepare();
    if (old.highlightLine != widget.highlightLine || old.text != widget.text) _scheduleReveal();
  }

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _prepare() {
    _fontGeneration = t.Fonts.generation;
    final text = widget.text;
    _lines = text.split('\n');
    if (_lines.length > 1 && _lines.last.isEmpty) _lines.removeLast();
    final spans = splitSpanLines(highlightCode(text, widget.language));
    _spans = spans.length >= _lines.length
        ? spans.sublist(0, _lines.length)
        : <TextSpan>[for (final l in _lines) TextSpan(text: l)];
    _lineHeight = CardText.code.fontSize! * CardText.code.height!;
    final digits = math.max(2, '${_lines.length}'.length);
    _gutter = _measure('0' * digits);
    var longest = '';
    for (final l in _lines) {
      if (l.length > longest.length) longest = l;
    }
    _maxLineWidth = _measure(longest);
  }

  static double _measure(String s) {
    final p = TextPainter(text: TextSpan(text: s, style: CardText.code), textDirection: TextDirection.ltr)..layout();
    final w = p.width;
    p.dispose();
    return w;
  }

  /// 定位：把高亮行滚到视口上三分之一处。
  void _scheduleReveal() {
    final line = widget.highlightLine;
    if (line == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_vertical.hasClients) return;
      final viewport = _vertical.position.viewportDimension;
      final target = ((line - 1) * _lineHeight - viewport / 3).clamp(0.0, _vertical.position.maxScrollExtent);
      _vertical.jumpTo(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 换过字体就重算带 family 的那几样。放在 build 而不是监听器里：_SourceView 拿不到
    // AppearanceController，而组合根换字体时本来就会重建整棵树，这里只是顺带对一次代数。
    if (_fontGeneration != t.Fonts.generation) _prepare();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(constraints.maxWidth, _gutter + t.Spacing.s12 + _maxLineWidth + t.Spacing.s16);
        return SingleChildScrollView(
          controller: _horizontal,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            child: ListView.builder(
              controller: _vertical,
              itemExtent: _lineHeight,
              itemCount: _lines.length,
              itemBuilder: (context, i) => _row(i),
            ),
          ),
        );
      },
    );
  }

  Widget _row(int i) {
    final hit = widget.highlightLine == i + 1;
    return Container(
      color: hit ? t.Accent.soft : null,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: _gutter,
            child: Text('${i + 1}', style: t.TextStyles.monoMeta.copyWith(height: CardText.code.height), textAlign: TextAlign.right),
          ),
          const SizedBox(width: t.Spacing.s12),
          Text.rich(_spans[i], style: CardText.code, softWrap: false, maxLines: 1),
        ],
      ),
    );
  }
}
