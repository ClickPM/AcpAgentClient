// 画板 60 / 61 的 gallery 页（R4）：整窗画板按 1440 × 900 的 frame 渲染，两张「局部」样张按画板给的 680 宽。
// 文件树、文件内容、本地 shell 的输出都是协议之外的本地态，这里用本地假数据；接线阶段换成 `fs_list_dir` / `fs_read` /
// `acp/terminal_output`（source = local），widget 不动（CLAUDE.md 规则 3）。

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import '../../ui/files/file_tree.dart';
import '../../ui/files/files_panel.dart';
import '../../ui/popovers/composer_popovers.dart';
import '../../ui/shell/app_shell.dart';
import '../../ui/shell/composer.dart';
import '../../ui/shell/right_panel.dart';
import '../../ui/shell/shell_common.dart';
import '../../ui/shell/sidebar.dart';
import '../../ui/shell/thread_header.dart';
import '../../ui/shell/topbar.dart';
import '../../ui/shell/transcript_empty.dart';
import '../../ui/terminal/local_terminal.dart';
import '../../ui/terminal/terminal_panel.dart';
import '../fixtures_source.dart';
import '../gallery.dart';
import 'shell_boards.dart';

// ---------------------------------------------------------------- 本地假数据

const String _root = 'D:/variFlight_work/VariFlightWork';

FileEntry _dir(String rel) => FileEntry(name: rel.split('/').last, path: '$_root/$rel', parent: _parentOf(rel), isDir: true);
FileEntry _file(String rel, int size) => FileEntry(name: rel.split('/').last, path: '$_root/$rel', parent: _parentOf(rel), size: size);
String _parentOf(String rel) {
  final i = rel.lastIndexOf('/');
  return i < 0 ? '' : '${rel.substring(0, i)}/';
}

/// 画板 60 的树：三个展开的目录 + 三个折叠的 + 三个根文件（AGENTS.md 选中）。
final Map<String, List<FileEntry>> _dirs = <String, List<FileEntry>>{
  _root: <FileEntry>[
    _dir('产品文档'),
    _dir('代码逻辑'),
    _dir('.agents'),
    _dir('design'),
    _dir('docs'),
    _dir('prototype'),
    _file('.gitignore', 210),
    _file('AGENTS.md', 13414),
    _file('README.md', 2048),
  ],
  '$_root/产品文档': <FileEntry>[_file('产品文档/01-产品需求文档.md', 9000), _file('产品文档/02-用户旅程与状态机.md', 7200)],
  '$_root/代码逻辑': <FileEntry>[_file('代码逻辑/projection-engine.md', 4100)],
  '$_root/docs': <FileEntry>[_file('docs/acp-projection.md', 30000), _file('docs/design.md', 25000), _file('docs/research.md', 40000)],
};

FileTree _tree() {
  final tree = FileTree(root: _root, loader: (path) async => _dirs[path] ?? const <FileEntry>[]);
  tree.seed(_dirs, expanded: <String>{'$_root/产品文档', '$_root/代码逻辑', '$_root/docs'});
  tree.setBadges(<String, String>{'$_root/产品文档/01-产品需求文档.md': 'M'});
  return tree;
}

const String _agentsMd = '''
This file provides guidance to pi (and other AGENTS.md-based agents) when working in this repository. It is kept in sync with CLAUDE.md（Claude Code reads CLAUDE.md）。

## 规则

1. 钉上游版本：pins/upstream.json 是唯一来源，改动需同步 docs/research.md。
2. 不在前端做任何 agent 特判：差异靠能力位区分。
3. 样式唯一来源是 lib/theme/tokens.dart，widget 文件禁止样式字面量。
''';

const FileViewerData _agentsViewer = FileViewerData(
  name: 'AGENTS.md',
  relPath: '/AGENTS.md',
  text: _agentsMd,
  language: FileLanguage('markdown', 'markdown'),
  lineCount: 168,
  sizeBytes: 13414,
);

const String _esc = '\x1b';

/// 画板 61「运行中」的输出（ANSI：绿 ok / 黄 warn / 灰尾行）。
final String _runningOutput = <String>[
  'Microsoft Windows [版本 10.0.26200.9445]',
  '(c) Microsoft Corporation。保留所有权利。',
  '',
  r'D:\variFlight_work\VariFlightWork> powershell -File scripts/validate.ps1 -All',
  '[1/4] 钉版本一致 ... $_esc[32mok$_esc[0m',
  '[2/4] gpui 不进主进程 ... $_esc[32mok$_esc[0m',
  '[3/4] 样式字面量扫描 lib/ ... $_esc[32mok$_esc[0m',
  '[4/4] _meta 键白名单 ... $_esc[33mwarn$_esc[0m（2 处未在白名单，见日志）',
  '$_esc[90m正在收尾并写入 logs/validate-2026-09-14.log ...$_esc[0m',
].join('\r\n');

/// 画板 61「已退出」的输出。
final String _exitedOutput = <String>[
  r'D:\variFlight_work\VariFlightWork> powershell -File scripts/validate.ps1 -Only NoStyleLiteral',
  '  规则 3 违规: lib/pages/workbench.dart:142',
  '$_esc[31m发现 1 处样式字面量，样式唯一来源是 lib/theme/tokens.dart$_esc[0m',
].join('\r\n');

LocalTerminal _running() => LocalTerminal(id: 'term_local_1', title: 'VariFlightWork', cwd: r'D:\variFlight_work\VariFlightWork')
  ..write(_runningOutput);

LocalTerminal _exited() {
  final started = DateTime.utc(2026, 9, 15, 12);
  return LocalTerminal(id: 'term_local_2', title: 'VariFlightWork', cwd: r'D:\variFlight_work\VariFlightWork', startedAt: started)
    ..write(_exitedOutput)
    ..exit(code: 1, at: started.add(const Duration(seconds: 1)));
}

// ---------------------------------------------------------------- 取数小工具

TextEditingController _c([String text = '']) => TextEditingController(text: text);

String _agentTitle(FixtureReplay r) {
  final a = r.sessions.agents[FixtureReplay.agentId];
  return a?.agentTitle ?? a?.agentName ?? 'Agent';
}

String _threadTitle(FixtureReplay r) => r.session.title ?? 'New ${_agentTitle(r)} Thread';

String? _currentName(FixtureReplay r, String category) {
  for (final o in r.session.configOptions) {
    if (o.category == category) return configCurrentName(o);
  }
  return null;
}

/// 整窗画板：`SelectableRegion` / `EditableText` / xterm 需要 Overlay 祖先（真实应用由 `MaterialApp` 提供）。
GalleryBoard _window(String id, String title, WidgetBuilder build) => GalleryBoard(
      id: id,
      title: title,
      frame: const Size(1440, 900),
      build: (context) => Overlay(initialEntries: <OverlayEntry>[OverlayEntry(builder: build)]),
    );

/// 「局部」样张：画板给的 680 宽，外框 1px base 边框。
GalleryBoard _partial(String id, String title, double height, WidgetBuilder build) => GalleryBoard(
      id: id,
      title: title,
      frame: Size(_partialWidth, height),
      build: (context) => Overlay(
        initialEntries: <OverlayEntry>[
          OverlayEntry(
            builder: (context) => Container(
              decoration: BoxDecoration(color: t.Surface.canvas, border: Border.all(color: t.Borders.base, width: t.Borders.width)),
              child: build(context),
            ),
          ),
        ],
      ),
    );

/// 画板 60 / 61 局部样张的宽度（canvas 上量得）。
const double _partialWidth = 680;

/// 中栏（与画板 01 状态 1 同一套：空转录 + 输入框）。
Widget _mainColumn(FixtureReplay r, {bool menuSelected = true}) {
  final s = r.session;
  return WorkbenchColumn(
    topBar: const TopBar(projectName: galleryProject, branch: galleryBranch, windowControls: false),
    threadHeader: ThreadHeader(title: _threadTitle(r), menuSelected: menuSelected),
    body: NewThreadEmpty(title: _threadTitle(r)),
    composer: Composer(
      controller: _c(),
      focusNode: FocusNode(),
      placeholder: 'Message to ${_agentTitle(r)} , @ to include context , / for commands',
      usage: s.usage,
      model: _currentName(r, 'model'),
      thoughtLevel: _currentName(r, 'thought_level'),
      mode: _currentName(r, 'mode'),
    ),
  );
}

Widget _sidebar(ShellTab active) => Sidebar(
      sessions: gallerySessions,
      now: galleryNow,
      selectedId: 's1',
      activeTab: active,
      searchController: _c(),
      searchFocusNode: FocusNode(),
    );

// ---------------------------------------------------------------- 画板

final List<GalleryBoard> panelBoards = <GalleryBoard>[
  _window('60a-files-panel', '文件面板', (_) {
    final r = FixtureReplay.replay(<String>['01-connect', '25-config-options', '19-usage'], upTo: 1);
    final files = const PanelTab.shell(ShellTab.files);
    return AppShell(
      sidebar: _sidebar(ShellTab.files),
      main: _mainColumn(r),
      rightPanel: RightPanel(
        tabs: <PanelTab>[files, const PanelTab.terminal('term_local_1', 'VariFlightWork')],
        active: files,
        body: FilesPanel(
          tree: _tree(),
          filterController: _c(),
          filterFocusNode: FocusNode(),
          selectedPath: '$_root/AGENTS.md',
          viewer: _agentsViewer,
        ),
      ),
    );
  }),
  _partial('60b-files-empty', '文件面板 · 查看器空态（局部）', 260, (_) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          height: t.Controls.input,
          padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
          alignment: Alignment.centerLeft,
          child: const Text('查看器空态', style: t.TextStyles.monoMeta),
        ),
        const Expanded(child: FileViewerEmpty()),
      ],
    );
  }),
  _window('61a-terminal-panel', '终端面板 · 运行中', (_) {
    final r = FixtureReplay.replay(<String>['01-connect', '25-config-options', '19-usage'], upTo: 1);
    const first = PanelTab.terminal('term_local_1', 'VariFlightWork');
    return AppShell(
      sidebar: _sidebar(ShellTab.terminal),
      main: _mainColumn(r),
      rightPanel: RightPanel(
        tabs: const <PanelTab>[first, PanelTab.terminal('term_local_2', 'AcpAgentClient')],
        active: first,
        body: TerminalPanel(terminal: _running()),
      ),
    );
  }),
  _partial('61b-terminal-exited', '终端面板 · 已退出（局部）', 200, (_) => TerminalPanel(terminal: _exited())),
];
