// 画板 60 的模型与 widget（R4 画板阶段）：文件树的懒加载 / 过滤 / 全部折叠 / 定位（展开祖先）、路径键的 Windows 口径、
// 高亮结果按行切分、扩展名 → 语言、字节格式化；面板的点击回调与 Source / Preview 切换。不加载字体（只验回调与状态）。

import 'package:acp_agent_client/ui/files/file_tree.dart';
import 'package:acp_agent_client/ui/files/files_panel.dart';
import 'package:acp_agent_client/ui/transcript/code_block.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const String root = 'D:/ws/proj';

FileEntry d(String rel) => FileEntry(name: rel.split('/').last, path: '$root/$rel', isDir: true);
FileEntry f(String rel, [int size = 1]) => FileEntry(name: rel.split('/').last, path: '$root/$rel', size: size);

/// 记录被加载过的目录，模拟 `fs_list_dir`。
class Loader {
  Loader(this.dirs);

  final Map<String, List<FileEntry>> dirs;
  final List<String> loaded = <String>[];

  Future<List<FileEntry>> call(String path) async {
    loaded.add(path);
    final list = dirs[path];
    if (list == null) throw StateError('no such dir: $path');
    return list;
  }
}

Loader loader() => Loader(<String, List<FileEntry>>{
      root: <FileEntry>[d('docs'), d('src'), f('README.md'), f('AGENTS.md')],
      '$root/docs': <FileEntry>[f('docs/design.md'), f('docs/research.md')],
      '$root/src': <FileEntry>[d('src/ui'), f('src/main.dart')],
      '$root/src/ui': <FileEntry>[f('src/ui/panel.dart')],
    });

Widget host(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(data: const MediaQueryData(size: Size(900, 600)), child: child),
    );

void main() {
  group('FileTree', () {
    test('reload 只列根一层；展开目录才懒加载；折叠不丢内容', () async {
      final l = loader();
      final tree = FileTree(root: root, loader: l.call);
      await tree.reload();
      expect(tree.visibleRows.map((n) => n.name), <String>['docs', 'src', 'README.md', 'AGENTS.md']);
      expect(l.loaded, <String>[root]);

      final docs = tree.nodeOf('$root/docs')!;
      await tree.toggle(docs);
      expect(tree.visibleRows.map((n) => n.name), <String>['docs', 'design.md', 'research.md', 'src', 'README.md', 'AGENTS.md']);
      expect(tree.visibleRows[1].depth, 1);
      expect(l.loaded, <String>[root, '$root/docs']);

      await tree.toggle(docs);
      expect(tree.visibleRows.map((n) => n.name), <String>['docs', 'src', 'README.md', 'AGENTS.md']);
      await tree.toggle(docs);
      expect(l.loaded, <String>[root, '$root/docs'], reason: '再展开不重新加载');
    });

    test('reveal 逐级展开祖先并返回节点；根之外 / 不存在的路径返回 null', () async {
      final l = loader();
      final tree = FileTree(root: root, loader: l.call);
      final node = await tree.reveal(r'D:\ws\proj\src\ui\panel.dart');
      expect(node, isNotNull);
      expect(node!.name, 'panel.dart');
      expect(tree.nodeOf('$root/src')!.expanded, isTrue);
      expect(tree.nodeOf('$root/src/ui')!.expanded, isTrue);
      expect(tree.visibleRows.map((n) => n.name), contains('panel.dart'));

      expect(await tree.reveal('D:/other/x.dart'), isNull);
      expect(await tree.reveal('$root/src/nope.dart'), isNull);
    });

    test('过滤只留名字命中的行与含命中后代的目录（展开着）；全部折叠只折不丢', () async {
      final tree = FileTree(root: root, loader: loader().call);
      await tree.reload();
      await tree.expand(tree.nodeOf('$root/docs')!);
      await tree.expand(tree.nodeOf('$root/src')!);
      tree.setFilter('DESIGN');
      expect(tree.visibleRows.map((n) => n.name), <String>['docs', 'design.md']);
      tree.setFilter('');
      tree.collapseAll();
      expect(tree.visibleRows.map((n) => n.name), <String>['docs', 'src', 'README.md', 'AGENTS.md']);
      expect(tree.nodeOf('$root/docs')!.loaded, isTrue);
    });

    test('reload 保持已展开的目录；refreshDir 只重载已加载的目录', () async {
      final l = loader();
      final tree = FileTree(root: root, loader: l.call);
      await tree.reload();
      await tree.expand(tree.nodeOf('$root/src')!);
      l.dirs['$root/src'] = <FileEntry>[d('src/ui'), f('src/main.dart'), f('src/new.dart')];
      await tree.refreshDir('$root/src');
      expect(tree.visibleRows.map((n) => n.name), contains('new.dart'));
      expect(tree.nodeOf('$root/src')!.expanded, isTrue);

      l.dirs[root] = <FileEntry>[d('docs'), d('src'), f('README.md')];
      await tree.reload();
      expect(tree.visibleRows.map((n) => n.name), <String>['docs', 'src', 'ui', 'main.dart', 'new.dart', 'README.md']);
      // 没加载过的目录 refresh 是空操作。
      await tree.refreshDir('$root/docs');
      expect(l.loaded.where((p) => p == '$root/docs'), isEmpty);
    });

    test('seed 同步灌树（gallery）', () {
      final tree = FileTree(root: root, loader: (_) async => const <FileEntry>[]);
      tree.seed(<String, List<FileEntry>>{
        root: <FileEntry>[d('docs'), f('README.md')],
        '$root/docs': <FileEntry>[f('docs/design.md')],
      }, expanded: <String>{'$root/docs'});
      expect(tree.visibleRows.map((n) => n.name), <String>['docs', 'design.md', 'README.md']);
      tree.setBadges(<String, String>{r'D:\ws\proj\README.md': 'M'});
      expect(tree.badgeOf('$root/README.md'), 'M');
    });

    test('pathKey / relativeTo：统一斜杠、去尾斜杠', () {
      expect(pathKey(r'D:\ws\proj\'), pathKey('D:/ws/proj'));
      expect(relativeTo('D:/ws/proj', r'D:\ws\proj\src\a.dart'), 'src/a.dart');
      expect(relativeTo('D:/ws/proj', 'D:/ws/proj'), '');
      expect(relativeTo('D:/ws/proj', 'D:/ws/projects/a.dart'), isNull);
    });
  });

  group('查看器辅助', () {
    test('splitSpanLines 按换行切分、行数与 split 一致、样式跟叶子走', () {
      const code = 'fn main() {\n    let x = "a\\nb";\n}\n';
      final lines = splitSpanLines(highlightCode(code, 'rust'));
      expect(lines.length, code.split('\n').length);
      expect(lines[0].toPlainText(), 'fn main() {');
      expect(lines[1].toPlainText(), '    let x = "a\\nb";');
      expect(lines[3].toPlainText(), '');
      // 关键字 fn 的颜色来自高亮主题（不是纯文本）。
      expect(lines[0].children!.any((s) => s.style?.color != null), isTrue);
    });

    test('languageForName / formatBytes', () {
      expect(languageForName('AGENTS.md').label, 'markdown');
      expect(languageForName('validate.ps1').highlight, 'powershell');
      expect(languageForName('CMakeLists.txt').highlight, 'cmake');
      expect(languageForName('noext').highlight, isNull);
      expect(formatBytes(13414), '13.1 KB');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(3 * 1024 * 1024), '3.0 MB');
    });
  });

  group('FilesPanel widget', () {
    testWidgets('点文件走 onOpen、点目录走 onToggleDir；Source / Preview 切换走 onViewMode', (tester) async {
      final tree = FileTree(root: root, loader: (_) async => const <FileEntry>[]);
      tree.seed(<String, List<FileEntry>>{
        root: <FileEntry>[d('docs'), f('README.md')],
        '$root/docs': <FileEntry>[f('docs/design.md')],
      });
      final opened = <String>[];
      final toggled = <String>[];
      final modes = <FileViewMode>[];
      await tester.pumpWidget(host(FilesPanel(
        tree: tree,
        filterController: TextEditingController(),
        filterFocusNode: FocusNode(),
        viewer: const FileViewerData(name: 'README.md', relPath: '/README.md', text: '# hi\n', language: FileLanguage('markdown', 'markdown'), lineCount: 1, sizeBytes: 5),
        viewMode: FileViewMode.preview,
        onOpen: (e) => opened.add(e.path),
        onToggleDir: (n) => toggled.add(n.path),
        onViewMode: modes.add,
      )));
      await tester.tap(find.text('README.md').first);
      await tester.tap(find.text('docs'));
      await tester.pump();
      expect(opened, <String>['$root/README.md']);
      expect(toggled, <String>['$root/docs']);
      await tester.tap(find.text('Source'));
      await tester.pump();
      expect(modes, <FileViewMode>[FileViewMode.source]);
      expect(find.text('没有打开的文件'), findsNothing);
    });

    testWidgets('没有打开文件时是空态；非 Markdown 文件只给 Source', (tester) async {
      final tree = FileTree(root: root, loader: (_) async => const <FileEntry>[]);
      await tester.pumpWidget(host(FilesPanel(tree: tree, filterController: TextEditingController(), filterFocusNode: FocusNode())));
      expect(find.text('没有打开的文件'), findsOneWidget);

      await tester.pumpWidget(host(FilesPanel(
        tree: tree,
        filterController: TextEditingController(),
        filterFocusNode: FocusNode(),
        viewer: const FileViewerData(name: 'a.rs', relPath: '/a.rs', text: 'fn main() {}\n', language: FileLanguage('rust', 'rust'), lineCount: 1, sizeBytes: 13),
        highlightLine: 1,
      )));
      await tester.pump();
      expect(find.text('Preview'), findsNothing);
      expect(find.text('Source'), findsOneWidget);
      expect(find.text('rust · 1 lines · 13 B'), findsOneWidget);
    });
  });
}
