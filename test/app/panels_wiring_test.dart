// R4 接线单测：文件面板（FilesState ↔ fs_list_dir / fs_read / fs_search / git_status / fs_watch 流）、
// 终端面板（LocalTerminals ↔ terminal_open / write / resize / kill / close）、组合根的右栏标签（面板标签 + 终端标签）、
// `acp/terminal_output` 按 source 分流（local → 终端面板；agent → 转录终端卡，分块 UTF-8 解码不切坏汉字）、
// 停止方块 → terminal_kill、Follow → locations 到达即定位、退出收尾 → core_shutdown。假核心只记账。

import 'dart:async';
import 'dart:convert';

import 'package:acp_agent_client/app/core_bridge.dart';
import 'package:acp_agent_client/app/files_state.dart';
import 'package:acp_agent_client/app/local_terminals.dart';
import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/ui/files/files_panel.dart';
import 'package:acp_agent_client/ui/popovers/topbar_popovers.dart';
import 'package:acp_agent_client/ui/shell/right_panel.dart';
import 'package:acp_agent_client/ui/shell/shell_common.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workbench_wiring_test.dart' show FakeCore;

const String root = 'D:/ws/proj';

JsonMap entry(String rel, {bool dir = false, int size = 3}) {
  final i = rel.lastIndexOf('/');
  return <String, dynamic>{
    'name': rel.substring(i + 1),
    'path': '$root/$rel',
    'parent': i < 0 ? '' : '${rel.substring(0, i)}/',
    'isDir': dir,
    'size': dir ? null : size,
  };
}

/// 记账 + 可控的目录 / 文件 / 事件流。
class PanelsCore extends FakeCore {
  final Map<String, List<JsonMap>> dirs = <String, List<JsonMap>>{
    root: <JsonMap>[entry('docs', dir: true), entry('src', dir: true), entry('README.md')],
    '$root/docs': <JsonMap>[entry('docs/design.md', size: 12)],
    '$root/src': <JsonMap>[entry('src/main.dart', size: 30)],
  };
  final Map<String, String> texts = <String, String>{
    '$root/README.md': '# hi\n',
    '$root/docs/design.md': 'a\nb\nc\n',
    '$root/src/main.dart': 'void main() {}\n',
  };
  Map<String, String> badges = <String, String>{};
  final StreamController<JsonMap> watch = StreamController<JsonMap>.broadcast();
  final StreamController<CoreEventRecord> events = StreamController<CoreEventRecord>.broadcast();
  final List<String> listed = <String>[];
  final List<String> read = <String>[];
  int gitStatusCalls = 0;

  @override
  Stream<CoreEventRecord> on(CoreEvent channel) => events.stream.where((e) => e.channel == channel);

  void emit(CoreEvent channel, JsonMap json) => events.add(CoreEventRecord(channel, jsonEncode(json), json));

  @override
  Future<JsonMap> fsListDir(String r, String path) async {
    listed.add(path);
    return <String, dynamic>{'path': path, 'entries': dirs[path] ?? <JsonMap>[]};
  }

  @override
  Future<JsonMap> fsRead(String r, String path) async {
    read.add(path);
    // 定位动作给的可能是反斜杠路径（agent 的 locations），核心两种都认；假核心按正斜杠键查。
    final text = texts[path.replaceAll(r'\', '/')] ?? '';
    return <String, dynamic>{'path': path, 'text': text, 'size': text.length, 'lines': text.split('\n').length - 1, 'binary': false, 'truncated': false};
  }

  @override
  Future<JsonMap> fsSearch(String r, String query, {int limit = 10}) async {
    final q = query.toLowerCase();
    final hits = <JsonMap>[
      for (final list in dirs.values)
        for (final e in list)
          if (e['isDir'] != true && (e['name'] as String).toLowerCase().contains(q)) e,
    ];
    return <String, dynamic>{'files': hits, 'directories': <JsonMap>[], 'truncated': false};
  }

  @override
  Future<JsonMap> gitStatus(String cwd) async {
    gitStatusCalls++;
    return <String, dynamic>{
      'available': true,
      'isRepo': true,
      'root': cwd,
      'entries': <JsonMap>[for (final e in badges.entries) <String, dynamic>{'path': e.key, 'badge': e.value, 'code': ' ${e.value}'}],
    };
  }

  @override
  Stream<JsonMap> fsWatch(String r) => watch.stream;

  final List<String> unwatched = <String>[];

  @override
  Future<JsonMap> fsUnwatch(String r) async {
    unwatched.add(r);
    return <String, dynamic>{'root': r, 'removed': true};
  }
}

/// 核心不认识的终端 id（`_meta` 通道喂出来的 toolUseId）：`terminal_kill` 报 unknown terminal。
class UnknownKillCore extends PanelsCore {
  @override
  Future<JsonMap> terminalKill(String terminalId) async => throw StateError('pty: unknown terminal $terminalId');
}

WorkbenchController controller(PanelsCore core) =>
    WorkbenchController(source: DataSource.bridge, bridge: core, scheduler: WorkbenchController.scheduleOnMicrotask);

void main() {
  group('FilesState', () {
    test('setProject 列根、上徽章；openPath 展开祖先并读内容，给行就切 Source', () async {
      final core = PanelsCore()..badges = <String, String>{'$root/README.md': 'M'};
      final f = FilesState(bridge: core);
      await f.setProject(root);
      expect(f.tree!.visibleRows.map((n) => n.name), <String>['docs', 'src', 'README.md']);
      expect(f.tree!.badgeOf('$root/README.md'), 'M');
      expect(f.gitAvailable, isTrue);

      await f.openPath(r'D:\ws\proj\docs\design.md', line: 2);
      expect(f.tree!.nodeOf('$root/docs')!.expanded, isTrue);
      expect(f.selectedPath, r'D:\ws\proj\docs\design.md');
      expect(f.viewer!.name, 'design.md');
      expect(f.viewer!.relPath, '/docs/design.md');
      expect(f.viewer!.text, 'a\nb\nc\n');
      expect(f.viewer!.lineCount, 3);
      expect(f.viewer!.language.label, 'markdown');
      expect(f.viewMode, FileViewMode.source);
      expect(f.highlightLine, 2);
      f.dispose();
    });

    test('fs_watch 的一批变化：受影响目录重列、.git 变了刷徽章、打开着的文件重读', () async {
      final core = PanelsCore();
      final f = FilesState(bridge: core);
      await f.setProject(root);
      await f.openPath('$root/src/main.dart');
      final reads = core.read.length;
      final statuses = core.gitStatusCalls;
      core.dirs['$root/src'] = <JsonMap>[entry('src/main.dart', size: 30), entry('src/new.dart')];
      core.texts['$root/src/main.dart'] = 'void main() { print(1); }\n';
      core.watch.add(<String, dynamic>{'root': root, 'dirs': <String>['$root/src'], 'git': true});
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(f.tree!.visibleRows.map((n) => n.name), contains('new.dart'));
      expect(core.read.length, reads + 1, reason: '打开着的文件在变化目录下，重读一次');
      expect(f.viewer!.text, contains('print(1)'));
      expect(core.gitStatusCalls, greaterThan(statuses));
      f.dispose();
    });

    test('搜索开关：去抖后走 fs_search，结果是扁平列表；关掉回到过滤', () async {
      final core = PanelsCore();
      final f = FilesState(bridge: core);
      await f.setProject(root);
      f.toggleSearch();
      f.filter.text = 'main';
      f.onFilterChanged('main');
      await Future<void>.delayed(FilesState.searchDebounce * 3);
      expect(f.searchResults.map((e) => e.name), <String>['main.dart']);
      f.toggleSearch();
      expect(f.searchMode, isFalse);
      expect(f.tree!.filter, 'main');
      f.dispose();
    });
  });

  group('LocalTerminals', () {
    test('open / 输入 / 输出 / 退出 / stop / restart / close', () async {
      final core = PanelsCore();
      final lt = LocalTerminals(bridge: core);
      final id = await lt.open(r'D:\work\proj');
      expect(id, 'term_fake_1');
      final term = lt.byId(id!)!;
      expect(term.title, 'proj');
      expect(core.openedTerminals, 1);

      term.onInput!('ls\r');
      expect(core.writtenToTerminal, <(String, String)>[(id, 'ls\r')]);

      lt.applyOutput(<String, dynamic>{'terminalId': id, 'source': 'local', 'bytes': base64Encode(utf8.encode('hello\r\n'))});
      expect(term.terminal.buffer.lines[0].getText().trim(), 'hello');
      expect(term.running, isTrue);

      await lt.stop(id);
      expect(core.killedTerminals, <String>[id]);
      lt.applyOutput(<String, dynamic>{'terminalId': id, 'source': 'local', 'exitStatus': <String, dynamic>{'exitCode': 1, 'signal': null}});
      expect(term.running, isFalse);
      expect(term.exitCode, 1);

      final fresh = await lt.restart(id);
      expect(fresh, 'term_fake_2');
      expect(core.closedTerminals, <String>[id]);
      expect(lt.tabs.map((t) => t.id), <String>[fresh!]);
      expect(lt.tabs.single.cwd, r'D:\work\proj');

      await lt.close(fresh);
      expect(lt.tabs, isEmpty);
      expect(core.closedTerminals, <String>[id, fresh]);
      lt.dispose();
    });
  });

  group('WorkbenchController 右栏与分流', () {
    test('侧栏「终端」开本地 shell 标签；标签条 = 面板标签 + 终端标签；关闭与切换', () async {
      final core = PanelsCore();
      final c = controller(core);
      await c.start();
      c.project = const ProjectRef(path: root, name: 'proj');

      c.openTab(ShellTab.files);
      expect(c.activePanel, const PanelTab.shell(ShellTab.files));
      expect(c.navActiveTab, ShellTab.files);

      c.openTab(ShellTab.terminal);
      await Future<void>.delayed(Duration.zero);
      expect(c.activeTerminalId, 'term_fake_1');
      expect(c.activePanel!.isTerminal, isTrue);
      expect(c.navActiveTab, ShellTab.terminal);
      expect(c.panelTabs, <PanelTab>[const PanelTab.shell(ShellTab.files), const PanelTab.terminal('term_fake_1', 'proj')]);
      // 再点侧栏「终端」：切到已有的，不再开一个。
      c.openTab(ShellTab.terminal);
      await Future<void>.delayed(Duration.zero);
      expect(core.openedTerminals, 1);

      c.selectPanel(const PanelTab.shell(ShellTab.files));
      expect(c.activePanel, const PanelTab.shell(ShellTab.files));
      expect(c.panelTabs.length, 2, reason: '切走不关终端');

      await c.closePanel(const PanelTab.terminal('term_fake_1', 'proj'));
      expect(core.closedTerminals, <String>['term_fake_1']);
      expect(c.panelTabs, <PanelTab>[const PanelTab.shell(ShellTab.files)]);

      await c.closeRightPanel();
      expect(c.rightPanelOpen, isFalse);
      c.dispose();
    });

    test('acp/terminal_output 分流：local 进终端面板，agent 进转录缓冲且分块 UTF-8 不切坏汉字', () async {
      final core = PanelsCore();
      final c = controller(core);
      await c.start();
      c.project = const ProjectRef(path: root, name: 'proj');
      c.sessionId = 'sess_1';
      c.agentId = 'a';
      await c.openTerminalTab(forceNew: true);
      final local = c.terminals.byId('term_fake_1')!;

      core.emit(CoreEvent.terminalOutput, <String, dynamic>{'terminalId': 'term_fake_1', 'source': 'local', 'bytes': base64Encode(utf8.encode('shell\r\n'))});
      final bytes = utf8.encode('汉字\n');
      core.emit(CoreEvent.terminalOutput, <String, dynamic>{'terminalId': 'term_agent', 'source': 'agent', 'bytes': base64Encode(bytes.sublist(0, 2))});
      core.emit(CoreEvent.terminalOutput, <String, dynamic>{'terminalId': 'term_agent', 'source': 'agent', 'bytes': base64Encode(bytes.sublist(2))});
      core.emit(CoreEvent.terminalOutput, <String, dynamic>{'terminalId': 'term_agent', 'source': 'agent', 'exitStatus': <String, dynamic>{'exitCode': 0, 'signal': null}});
      await Future<void>.delayed(const Duration(seconds: 1));

      expect(local.terminal.buffer.lines[0].getText().trim(), 'shell');
      final agent = c.sessions.terminals['term_agent']!;
      expect(agent.output, '汉字\n');
      expect(agent.exitCode, 0);
      expect(c.sessions.terminals['term_fake_1'], isNull, reason: 'local 的不进转录缓冲');
      c.dispose();
    });

    test('停止方块 → terminal_kill 并本地标 killed；Follow 开着时 locations 到达即定位；shutdown → core_shutdown', () async {
      final core = PanelsCore();
      final c = controller(core);
      await c.start();
      c.project = const ProjectRef(path: root, name: 'proj');
      await c.files.setProject(root);
      c.sessionId = 'sess_1';
      c.agentId = 'a';
      final store = c.sessions.session('sess_1', agentId: 'a');
      store.applyUpdateJson(<String, dynamic>{
        'sessionUpdate': 'tool_call',
        'toolCallId': 'call_1',
        'title': 'run',
        'kind': 'execute',
        'status': 'in_progress',
        'content': <JsonMap>[<String, dynamic>{'type': 'terminal', 'terminalId': 'term_agent'}],
      });
      await c.killTerminal('term_agent');
      expect(core.killedTerminals, <String>['term_agent']);
      expect(store.terminals['term_agent']!.killed, isTrue);

      expect(c.follow, isFalse);
      c.toggleFollow();
      core.emit(CoreEvent.sessionUpdate, <String, dynamic>{
        'agentId': 'a',
        'sessionId': 'sess_1',
        'update': <String, dynamic>{
          'sessionUpdate': 'tool_call',
          'toolCallId': 'call_read',
          'title': 'Read',
          'kind': 'read',
          'status': 'completed',
          'locations': <JsonMap>[<String, dynamic>{'path': '$root/docs/design.md', 'line': 3}],
        },
      });
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(c.rightTab, ShellTab.files);
      expect(c.files.selectedPath, '$root/docs/design.md');
      expect(c.files.highlightLine, 3);
      expect(c.files.viewMode, FileViewMode.source);

      // 另一个会话的 locations 不跟。
      core.emit(CoreEvent.sessionUpdate, <String, dynamic>{
        'agentId': 'a',
        'sessionId': 'sess_other',
        'update': <String, dynamic>{
          'sessionUpdate': 'tool_call',
          'toolCallId': 'x',
          'title': 'Read',
          'kind': 'read',
          'status': 'completed',
          'locations': <JsonMap>[<String, dynamic>{'path': '$root/README.md'}],
        },
      });
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(c.files.selectedPath, '$root/docs/design.md');

      await c.shutdown();
      expect(core.shutdowns, 1);
      c.dispose();
    });

    test('审查整改：dispose 收掉监视器与 shell；停止方块碰到核心不认识的终端 id 不记错也不标 killed', () async {
      final core = UnknownKillCore();
      final files = FilesState(bridge: core);
      await files.setProject(root);
      files.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(core.unwatched, <String>[root]);

      final terminals = LocalTerminals(bridge: core);
      final id = await terminals.open(root);
      terminals.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(core.closedTerminals, <String>[id!]);

      final c = controller(core);
      await c.start();
      c.sessionId = 'sess_1';
      c.agentId = 'a';
      final store = c.sessions.session('sess_1', agentId: 'a');
      store.applyUpdateJson(<String, dynamic>{
        'sessionUpdate': 'tool_call',
        'toolCallId': 'toolu_1',
        'title': 'Bash',
        'kind': 'execute',
        'status': 'in_progress',
        'content': <JsonMap>[<String, dynamic>{'type': 'terminal', 'terminalId': 'toolu_1'}],
      });
      await c.killTerminal('toolu_1');
      expect(c.lastError, isNull);
      // 没有 `_meta.terminal_output` 到达前缓冲都不存在；有也不该被标 killed。
      expect(store.terminals['toolu_1']?.killed ?? false, isFalse);
      c.dispose();
    });
  });
}
