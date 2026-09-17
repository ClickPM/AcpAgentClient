// 画板 01 / 02 / 03 / 04 / 40 / 41 / 42 / 80 的 gallery 页（R3）：整窗画板按 1440 × 900 的 frame 渲染，
// 合集画板沿用 R2 的 BoardPage 版式。数据源：协议面（会话流 / configOptions / 命令 / 用量 / 流量）一律来自
// test/fixtures 回放；协议之外的本地态（会话索引、项目与分支列表、已安装 agent、@ 提及候选）是本地假数据，
// 接线阶段换成 `sessions.json` / `projects.json` / git CLI / `fs_search`，widget 不动（CLAUDE.md 规则 3）。

import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../../projection/entries.dart';
import '../../projection/fixture_line.dart';
import '../../projection/session_store.dart';
import '../../projection/traffic.dart';
import '../../projection/wire.dart';
import '../../theme/tokens.dart' as t;
import '../../ui/popovers/composer_popovers.dart';
import '../../ui/popovers/inline_menus.dart';
import '../../ui/popovers/topbar_popovers.dart';
import '../../ui/files/file_tree.dart';
import '../../ui/files/files_panel.dart';
import '../../ui/shell/app_shell.dart';
import '../../ui/shell/composer.dart';
import '../../ui/shell/right_panel.dart';
import '../../ui/shell/shell_common.dart';
import '../../ui/shell/sidebar.dart';
import '../../ui/shell/thread_header.dart';
import '../../ui/shell/topbar.dart';
import '../../ui/shell/transcript_empty.dart';
import '../../ui/traffic/traffic_page.dart';
import '../../ui/transcript/awaiting_bar.dart';
import '../../ui/transcript/plan_card.dart';
import '../../ui/transcript/transcript_list.dart';
import '../board_page.dart';
import '../fixtures_source.dart';
import '../gallery.dart';

// ---------------------------------------------------------------- 本地假数据（协议之外）

/// gallery 的「现在」：会话项的相对时间按它算（fixtures 回放时钟同一起点）。
final DateTime _now = DateTime.utc(2026, 9, 15, 12);

final List<SidebarSession> _sessions = <SidebarSession>[
  SidebarSession(id: 's1', title: '主流桌面客户端设计风格参考', updatedAt: _now.subtract(const Duration(minutes: 15)), messageCount: 2),
  SidebarSession(id: 's2', title: 'Pi用户级安装Figma插件', updatedAt: _now.subtract(const Duration(minutes: 30)), messageCount: 10),
  SidebarSession(id: 's3', title: '项目转Flutter工具链', updatedAt: _now.subtract(const Duration(hours: 1)), messageCount: 10),
  SidebarSession(id: 's4', title: 'AgentACPClient项目立项', updatedAt: _now.subtract(const Duration(days: 3)), messageCount: 10),
];

const String _project = 'deepseek-harness';
const String _branch = 'main';

const List<ProjectRef> _openProjects = <ProjectRef>[
  ProjectRef(path: 'D:/variFlight_work/AcpAgentClient', name: 'AcpAgentClient'),
  ProjectRef(path: 'D:/work/deepseek-harness', name: 'deepseek-harness'),
  ProjectRef(path: 'D:/work/GPUI-Pi', name: 'GPUI-Pi'),
  ProjectRef(path: 'D:/work/agent-xray', name: 'agent-xray'),
];

const List<ProjectRef> _recentProjects = <ProjectRef>[
  ProjectRef(path: 'D:/work/variflight-coupon-tools', name: 'variflight-coupon-tools'),
];

const List<BranchRef> _branches = <BranchRef>[
  BranchRef(name: 'main', author: 'ClickPM', when: 'Yesterday', subject: '更新框架'),
  BranchRef(name: 'feat/acp-client', author: 'ClickPM', when: '3 days ago', subject: '接入 ACP client 与基础投影'),
];

const List<MentionItem> _mentionFiles = <MentionItem>[
  MentionItem(path: 'D:/repo/scripts/validate.ps1', name: 'validate.ps1', parent: 'scripts/'),
  MentionItem(path: 'D:/repo/scripts/validate-all.ps1', name: 'validate-all.ps1', parent: 'scripts/'),
];
const List<MentionItem> _mentionDirs = <MentionItem>[
  MentionItem(path: 'D:/repo/scripts', name: 'scripts/', parent: 'AcpAgentClient/', isDirectory: true),
];
const List<MentionItem> _mentionRecent = <MentionItem>[
  MentionItem(path: 'D:/repo/docs/acp-projection.md', name: 'acp-projection.md', parent: 'docs/'),
  MentionItem(path: 'D:/repo/rounds/BACKLOG.md', name: 'BACKLOG.md', parent: 'rounds/'),
];

// ---------------------------------------------------------------- 输入控件（gallery 里都是只读样张）

TextEditingController _c([String text = '']) => TextEditingController(text: text);

// ---------------------------------------------------------------- 取数小工具

String _agentTitle(FixtureReplay r) {
  final a = r.sessions.agents[FixtureReplay.agentId];
  return a?.agentTitle ?? a?.agentName ?? 'Agent';
}

String _agentName(FixtureReplay r) {
  final a = r.sessions.agents[FixtureReplay.agentId];
  return a?.agentName ?? FixtureReplay.agentId;
}

String _threadTitle(FixtureReplay r) => r.session.title ?? 'New ${_agentTitle(r)} Thread';

String _composerPlaceholder(FixtureReplay r) => 'Message to ${_agentTitle(r)} , @ to include context , / for commands';

ConfigOptionWire? _option(SessionStore s, String category) {
  for (final o in s.configOptions) {
    if (o.category == category) return o;
  }
  return null;
}

List<ConfigOptionWire> _booleans(SessionStore s) => <ConfigOptionWire>[
      for (final o in s.configOptions)
        if (o.type == 'boolean') o,
    ];

/// 未识别 category（不在 mode / model / model_config / thought_level）的 select 条目。
List<ConfigOptionWire> _unknownCategory(SessionStore s) => <ConfigOptionWire>[
      for (final o in s.configOptions)
        if (o.type == 'select' && !const <String>['mode', 'model', 'model_config', 'thought_level'].contains(o.category)) o,
    ];

String? _currentName(SessionStore s, String category) {
  final o = _option(s, category);
  return o == null ? null : configCurrentName(o);
}

/// 把 fixtures 的线上行按 `acp/traffic` 的 payload 形状喂进 TrafficStore（核心侧做的就是这件事）。
TrafficStore _traffic(List<String> files, {required String agentId}) {
  final store = TrafficStore();
  var ts = DateTime(2026, 9, 15, 14, 1, 58, 204).millisecondsSinceEpoch;
  for (final file in files) {
    for (final line in FixtureReplay.load(file)) {
      ts += line.delayMs;
      final msg = line.msg;
      if (msg != null) {
        store.apply(<String, dynamic>{
          'agentId': agentId,
          'direction': line.dir == FixtureDir.out ? 'out' : 'in',
          'line': jsonEncode(msg),
          'ts': ts,
        });
      } else if (line.dir == FixtureDir.stderr && line.line != null) {
        store.apply(<String, dynamic>{'agentId': agentId, 'direction': 'stderr', 'line': line.line, 'ts': ts});
      }
    }
  }
  return store;
}

/// 转录列表（整窗画板里）：与真实壳同一条装配路径（滚动区铺满面板宽，内容由 TranscriptList 自己居中）。
Widget _transcript(FixtureReplay r) => Padding(
      padding: const EdgeInsets.only(top: t.Spacing.s16),
      child: TranscriptList(r.session, agentName: _agentName(r)),
    );

/// 整窗画板：`SelectableRegion` 与 `EditableText` 需要 Overlay 祖先（真实应用由 `MaterialApp` 提供）。
GalleryBoard _window(String id, String title, WidgetBuilder build) => GalleryBoard(
      id: id,
      title: title,
      frame: const Size(1440, 900),
      build: (context) => Overlay(initialEntries: <OverlayEntry>[OverlayEntry(builder: build)]),
    );

GalleryBoard _page(String id, String title, Widget Function() build) =>
    GalleryBoard(id: id, title: title, frame: const Size(BoardPage.width, 0), fitContent: true, build: (_) => build());

// ---------------------------------------------------------------- 画板

final List<GalleryBoard> shellBoards = <GalleryBoard>[
  _window('01a-workbench-empty', '工作台 · 新会话（状态 1：有 agent 的新会话）', (_) {
    // 用量取 19-usage 的第一条（1% · 10k / 1M，无 cost）；configOptions 取 25 的第一条（mode = Write）。
    final r = FixtureReplay.replay(<String>['01-connect', '25-config-options', '19-usage'], upTo: 1);
    final s = r.session;
    return AppShell(
      sidebar: Sidebar(
        sessions: _sessions,
        now: _now,
        selectedId: 's1',
        searchController: _c(),
        searchFocusNode: FocusNode(),
      ),
      main: WorkbenchColumn(
        topBar: const TopBar(projectName: _project, branch: _branch),
        threadHeader: ThreadHeader(title: _threadTitle(r)),
        body: NewThreadEmpty(title: _threadTitle(r)),
        composer: Composer(
          controller: _c(),
          focusNode: FocusNode(),
          placeholder: _composerPlaceholder(r),
          usage: s.usage,
          model: _currentName(s, 'model'),
          thoughtLevel: _currentName(s, 'thought_level'),
          mode: _currentName(s, 'mode'),
        ),
      ),
    );
  }),
  _window('01b-workbench-noagent', '工作台 · 新会话（状态 2：尚无已安装 agent）', (_) {
    return AppShell(
      sidebar: Sidebar(
        sessions: const <SidebarSession>[],
        now: _now,
        activeTab: ShellTab.agents,
        searchController: _c(),
        searchFocusNode: FocusNode(),
      ),
      main: WorkbenchColumn(
        topBar: const TopBar(projectName: _project, branch: _branch),
        threadHeader: const ThreadHeader(title: 'No Agent', hasAgent: false, canRename: false, canReload: false),
        body: const NoAgentEmpty(),
        composer: Composer(
          controller: _c(),
          focusNode: FocusNode(),
          placeholder: '安装并选择一个 agent 后即可输入',
          enabled: false,
        ),
      ),
    );
  }),
  _window('02-workbench-running', '工作台 · 进行中的一轮', (_) {
    // 停在挂起的权限请求上：回合仍在进行（线程头 spinner + 发送位是停止方块 + Awaiting 停靠条）。
    final r = FixtureReplay.replay(
      <String>['01-connect', '25-config-options', '02-turn-read', '03-permission-edit'],
      untilTag: 'session/request_permission',
    );
    final s = r.session;
    final first = s.pending.forSession(s.sessionId).firstOrNull;
    final permission = first is PermissionEntry ? first : null;
    return AppShell(
      sidebar: Sidebar(
        sessions: _sessions,
        now: _now,
        selectedId: 's1',
        searchController: _c(),
        searchFocusNode: FocusNode(),
      ),
      main: WorkbenchColumn(
        topBar: const TopBar(projectName: _project, branch: _branch),
        threadHeader: ThreadHeader(title: _threadTitle(r), running: s.isRunning),
        body: _transcript(r),
        composer: Composer(
          controller: _c(),
          focusNode: FocusNode(),
          placeholder: _composerPlaceholder(r),
          running: s.isRunning,
          usage: s.usage,
          model: _currentName(s, 'model'),
          thoughtLevel: _currentName(s, 'thought_level'),
          mode: _currentName(s, 'mode'),
          docks: <Widget>[
            ?AwaitingDock.forPending(
              first,
              toolCall: permission?.toolCallId == null ? null : s.toolCalls[permission!.toolCallId!],
              cwd: s.cwd,
              agentName: _agentName(r),
            ),
          ],
        ),
      ),
    );
  }),
  _window('03-workbench-done', '工作台 · 回合结束 + 右栏展开', (_) {
    final r = FixtureReplay.replay(<String>['01-connect', '25-config-options', '02-turn-read', '08-end-turn']);
    final s = r.session;
    final plan = s.plans[PlanCardEntry.stablePlanId];
    return AppShell(
      sidebar: Sidebar(
        sessions: _sessions,
        now: _now,
        selectedId: 's1',
        activeTab: ShellTab.files,
        searchController: _c(),
        searchFocusNode: FocusNode(),
      ),
      main: WorkbenchColumn(
        topBar: const TopBar(projectName: _project, branch: _branch, windowControls: false),
        threadHeader: ThreadHeader(title: _threadTitle(r), menuSelected: true),
        body: _transcript(r),
        composer: Composer(
          controller: _c(),
          focusNode: FocusNode(),
          placeholder: _composerPlaceholder(r),
          usage: s.usage,
          model: _currentName(s, 'model'),
          thoughtLevel: _currentName(s, 'thought_level'),
          mode: _currentName(s, 'mode'),
          docks: <Widget>[if (plan != null) PlanCard(plan, initiallyCollapsed: true, cwd: s.cwd)],
        ),
      ),
      // 右栏内容归 R4（ROUNDS § 3 R3「右栏内容 R4」）：画板 03 的文件面板（树 + AGENTS.md 预览）。
      rightPanel: RightPanel(
        tabs: const <PanelTab>[PanelTab.shell(ShellTab.files)],
        active: const PanelTab.shell(ShellTab.files),
        body: FilesPanel(
          tree: _board03Tree(),
          filterController: _c(),
          filterFocusNode: FocusNode(),
          selectedPath: '$_board03Root/AGENTS.md',
          viewer: const FileViewerData(
            name: 'AGENTS.md',
            relPath: '/AGENTS.md',
            text: 'This file provides guidance to pi (and other AGENTS.md-based agents) when working in this repository. '
                'It is kept in sync with CLAUDE.md.',
            language: FileLanguage('markdown', 'markdown'),
            lineCount: 168,
            sizeBytes: 13414,
          ),
        ),
      ),
    );
  }),
  _page('04-sidebar-states', '侧栏与顶栏状态', () {
    final r = FixtureReplay.replay(<String>['01-connect']);
    // ignore: unused_local_variable
    final renaming = _sessions[2];
    return BoardPage(
      number: '04',
      title: '侧栏与顶栏状态',
      source: 'session/list（会话项与标题）、session_info_update（标题 / updatedAt）、客户端本地时间戳',
      sections: <BoardSection>[
        BoardSection('会话项 · 默认 / 悬浮（出重命名 · 删除）/ 选中（当前会话）/ 重命名中（行内编辑）',
            child: _panel(<Widget>[
              SidebarSessionRow(_sessions[1], now: _now),
              SidebarSessionRow(_sessions[1], now: _now, forceHover: true),
              SidebarSessionRow(_sessions[0], now: _now, selected: true),
              SidebarSessionRow(renaming, now: _now, renaming: true, renameController: _c(renaming.title), renameFocusNode: FocusNode()),
            ])),
        BoardSection('搜索 · 输入中（命中片段高亮）',
            child: _panel(<Widget>[
              SidebarSearchField(controller: _c('Flutter'), focusNode: FocusNode()),
              SidebarSessionRow(_sessions[2], now: _now, query: 'Flutter'),
            ])),
        BoardSection('搜索 · 无结果',
            child: _panel(<Widget>[
              SidebarSearchField(controller: _c('registry'), focusNode: FocusNode()),
              const SizedBox(height: t.Geometry.sidebarEmptyHeight, child: SidebarEmpty(searching: true)),
            ])),
        const BoardSection('顶栏 · 项目名悬浮（可切换项目）',
            child: TopBar(projectName: _project, branch: _branch, windowControls: false, hoverProject: true)),
        const BoardSection('顶栏 · 分支悬浮（可切换分支）',
            child: TopBar(projectName: _project, branch: _branch, windowControls: false, hoverBranch: true)),
        const BoardSection('侧栏折叠后的顶栏（折叠开关为选中态；顶栏左移，窗口控制不变）',
            child: TopBar(projectName: _project, branch: _branch, sidebarCollapsed: true)),
        const BoardSection('顶栏 · 非 git 目录（分支区整块隐藏）',
            child: TopBar(projectName: 'notes', windowControls: false)),
        const BoardSection('侧栏底部导航 · 默认 / 悬浮 / 选中',
            child: SidebarNav(active: ShellTab.agents, hoveredTab: ShellTab.files)),
      ],
      footnote: '会话项时间戳是客户端本地态（协议只给 SessionInfo.updatedAt）；「N 条消息」由本地消息分组计数得出。'
          '删除会话需 sessionCapabilities.delete，无此能力时删除图标不渲染（确认弹层见画板 41）；'
          '本画板的样张按「有 delete 能力」画，01-connect 的 initialize 给的是 ${_sessionCaps(r).keys.join(' / ')}。',
    );
  }),
  _page('40-composer-popovers', '输入框弹层合集', () {
    final r = FixtureReplay.replay(<String>['01-connect', '25-config-options'], upTo: 1);
    final s = r.session;
    final usage = FixtureReplay.replay(<String>['01-connect', '19-usage'], upTo: 1).session.usage;
    final model = _option(s, 'model')!;
    final thought = _option(s, 'thought_level')!;
    final mode = _option(s, 'mode')!;
    return BoardPage(
      number: '40',
      title: '输入框弹层合集',
      source: 'config_option_update（select 扁平 / 分组、boolean、未知分类）· current_mode_update · usage_update',
      sections: <BoardSection>[
        BoardSection('模型选择器（category model，分组 + 当前项对勾）',
            child: _left(ConfigSelectPopover(
              option: model,
              searchController: _c(),
              searchFocusNode: FocusNode(),
              showLeadingMark: true,
              hoveredValue: 'gpt-5-6-terra',
            ))),
        BoardSection('思考强度（category thought_level）',
            child: _left(ConfigSelectPopover(option: thought, title: thought.name, width: t.Geometry.menuWidthNarrow))),
        BoardSection('模式（current_mode_update；configOptions 优先，modes 仅回退）',
            child: _left(ConfigSelectPopover(option: mode, width: t.Geometry.menuWidthNarrow))),
        BoardSection('布尔型会话选项（需声明 session.configOptions.boolean）',
            child: _left(BooleanOptionsPopover(options: _booleans(s)))),
        BoardSection('未知分类的兜底渲染',
            child: _left(UnknownCategoryPopover(options: _unknownCategory(s)))),
        const BoardSection('+ 的上下文加入弹层', child: _Left(PlusPopover())),
        BoardSection('用量弹层', child: _left(UsagePopover(usage: usage, rulesCount: 1))),
        BoardSection('Follow 提示', child: _left(FollowTip(agentName: _agentName(r)))),
      ],
      footnote: 'configOptions 是全量替换：set_config_option 返回整份列表。同时给了 configOptions 与 modes 时只用 configOptions。'
          '弹层是唯一带阴影的表面；当前项用「按下态容器 + accent 文字 + 对勾」表示。'
          '偏离：画板给模型行画了 provider 图标与 Latest 徽章，SessionConfigSelectOption 只有 value / name / description，'
          '图标位用中性占位、Latest 省略（记 BACKLOG，归下个设计轮）。',
    );
  }),
  _page('41-topbar-popovers', '顶栏与侧栏弹层合集', () {
    final r = FixtureReplay.replay(<String>['01-connect']);
    final sessionCaps = _sessionCaps(r);
    final renaming = _sessions[2];
    return BoardPage(
      number: '41',
      title: '顶栏与侧栏弹层合集',
      source: 'session/new（选 agent）· session/list · session/delete · 会话索引',
      sections: <BoardSection>[
        BoardSection('项目切换（This Window / Recent Projects / Open Local Folders）',
            child: _left(ProjectSwitcherPopover(
              openProjects: _openProjects,
              recentProjects: _recentProjects,
              currentPath: _openProjects[1].path,
              searchController: _c(),
              searchFocusNode: FocusNode(),
            ))),
        BoardSection('分支切换 · 默认（列本地分支，当前分支出对勾）',
            child: _left(BranchSwitcherPopover(
              branches: _branches,
              current: _branch,
              controller: _c(),
              focusNode: FocusNode(),
            ))),
        BoardSection('分支切换 · 输入了新名字（列表按搜索过滤，末尾是 Create branch … from …）',
            child: _left(BranchSwitcherPopover(
              branches: _branches,
              current: _branch,
              controller: _c('feat/tokens'),
              focusNode: FocusNode(),
              query: 'feat/tokens',
            ))),
        BoardSection('新建会话 · 选 agent（图标位是单色占位，R5 registry 带来各 agent 的 logo）',
            child: _left(NewSessionAgentPopover(agents: <AgentRef>[
              AgentRef(id: FixtureReplay.agentId, name: _agentTitle(r)),
            ]))),
        BoardSection('线程头 ≡ 菜单（动作由 sessionCapabilities 驱动）',
            child: _left(ThreadMenuPopover(
              canResume: sessionCaps.containsKey('resume'),
              canClose: sessionCaps.containsKey('close'),
              canDelete: sessionCaps.containsKey('delete'),
            ))),
        BoardSection('会话项 · 重命名（行内编辑）',
            child: _panel(<Widget>[
              SidebarSessionRow(renaming, now: _now, renaming: true, renameController: _c(renaming.title), renameFocusNode: FocusNode()),
            ])),
        BoardSection('会话项 · 删除确认', child: _left(DeleteSessionConfirm(title: renaming.title))),
      ],
      footnote: '没有 sessionCapabilities.close / delete / resume 时对应菜单项不渲染（acp-projection.md § 5）；'
          '本画板的能力来自 01-connect 的 initialize：${sessionCaps.keys.join(' / ')}（没有 delete，所以 Delete Session 不出现）。'
          '动作本身在 R6 接。',
    );
  }),
  _page('42-inline-menus', '输入框内联菜单', () {
    final r = FixtureReplay.replay(<String>['01-connect']);
    final commands = r.session.commands;
    return BoardPage(
      number: '42',
      title: '输入框内联菜单',
      source: 'available_commands_update（全量列表，input: unstructured）· @ 提及（promptCapabilities）',
      sections: <BoardSection>[
        BoardSection('@ 提及菜单（文件 / 文件夹 / 最近）',
            child: _left(const MentionMenu(files: _mentionFiles, directories: _mentionDirs, recent: _mentionRecent))),
        BoardSection('输入框里的 @ 提及（菜单浮在输入框上方）',
            child: Composer(
              controller: _c('给 @val'),
              focusNode: FocusNode(),
              placeholder: '',
              mode: _currentName(r.session, 'mode'),
              inlineMenu: const MentionMenu(files: _mentionFiles, directories: _mentionDirs, recent: _mentionRecent),
            )),
        BoardSection('/ 命令菜单（命令名 + 描述 + 参数提示）', child: _left(SlashCommandMenu(commands: commands))),
        BoardSection('输入框里的 / 命令',
            child: Composer(
              controller: _c('/co'),
              focusNode: FocusNode(),
              placeholder: '',
              mode: _currentName(r.session, 'mode'),
              inlineMenu: SlashCommandMenu(commands: commands),
            )),
      ],
      footnote: '命令清单来自 available_commands_update 的全量列表，input 目前只有 unstructured（hint 即参数提示）；'
          '@ 能塞什么由 promptCapabilities.{image, audio, embeddedContext} 决定，缺能力时对应分组不出现。'
          '分组按所有者裁定 2026-09-15 只渲染单组 Commands（AvailableCommand 没有分组与来源字段）。',
    );
  }),
  _window('80-traffic', 'ACP 流量调试', (_) {
    final r = FixtureReplay.replay(<String>['01-connect', '02-turn-read', '08-end-turn']);
    final agentId = _agentName(r);
    final store = _traffic(<String>['01-connect', '02-turn-read', '90-rejected', '08-end-turn'], agentId: agentId);
    // 展开被丢弃的未知变体（原文 + 说明），其余行收起，这样告警行与高亮行在首屏都看得到。
    final expanded = <int>{
      for (final l in store.lines)
        if (l.dropped) l.seq,
    };
    return AppShell(
      sidebar: Sidebar(
        sessions: _sessions,
        now: _now,
        selectedId: 's1',
        searchController: _c(),
        searchFocusNode: FocusNode(),
      ),
      main: Container(
        color: t.Surface.canvas,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const TopBar(projectName: _project, branch: _branch),
            Expanded(
              child: TrafficPage(
                store: store,
                filterController: _c(),
                filterFocusNode: FocusNode(),
                stderrAgentId: agentId,
                initiallyExpanded: expanded,
              ),
            ),
          ],
        ),
      ),
    );
  }),
];

/// `initialize` 的 `agentCapabilities.sessionCapabilities`（画板 41 的 ≡ 菜单按它裁剪）。
Map<String, dynamic> _sessionCaps(FixtureReplay r) {
  final caps = r.sessions.agents[FixtureReplay.agentId]?.agentCapabilities?['sessionCapabilities'];
  return caps is Map ? caps.cast<String, dynamic>() : const <String, dynamic>{};
}

/// 侧栏样张的底衬（panel 底 + subtle 边框 + radius 6，画板 04 / 41 的展示容器）。
Widget _panel(List<Widget> children) => _left(Container(
      width: t.Geometry.sidebarWidth,
      decoration: BoxDecoration(
        color: t.Neutral.panel,
        border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
        borderRadius: t.Radii.card,
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children),
    ));

/// 弹层样张左对齐（BoardPage 的分节是整宽拉伸的）。
Widget _left(Widget child) => Align(alignment: Alignment.centerLeft, child: child);

class _Left extends StatelessWidget {
  const _Left(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) => Align(alignment: Alignment.centerLeft, child: child);
}

// ---------------------------------------------------------------- 画板 03 右栏的文件树（本地假数据）

const String _board03Root = 'D:/variFlight_work/VariFlightWork';

FileEntry _e(String rel, {bool dir = false, int size = 0}) {
  final i = rel.lastIndexOf('/');
  return FileEntry(
    name: rel.substring(i + 1),
    path: '$_board03Root/$rel',
    parent: i < 0 ? '' : '${rel.substring(0, i)}/',
    isDir: dir,
    size: dir ? null : size,
  );
}

FileTree _board03Tree() {
  final dirs = <String, List<FileEntry>>{
    _board03Root: <FileEntry>[
      _e('产品文档', dir: true),
      _e('代码逻辑', dir: true),
      _e('.agents', dir: true),
      _e('design', dir: true),
      _e('docs', dir: true),
      _e('prototype', dir: true),
      _e('.gitignore', size: 210),
      _e('AGENTS.md', size: 13414),
    ],
    '$_board03Root/产品文档': <FileEntry>[_e('产品文档/01-产品需求文档.md', size: 9000), _e('产品文档/02-用户旅程与状态机.md', size: 7200)],
    '$_board03Root/docs': <FileEntry>[_e('docs/acp-projection.md', size: 30000), _e('docs/design.md', size: 25000), _e('docs/research.md', size: 40000)],
  };
  final tree = FileTree(root: _board03Root, loader: (path) async => dirs[path] ?? const <FileEntry>[]);
  tree.seed(dirs, expanded: <String>{'$_board03Root/产品文档', '$_board03Root/docs'});
  tree.setBadges(<String, String>{'$_board03Root/产品文档/01-产品需求文档.md': 'M'});
  return tree;
}

// ---------------------------------------------------------------- 给画板 60 / 61 复用的本地假数据

final List<SidebarSession> gallerySessions = _sessions;
final DateTime galleryNow = _now;
const String galleryProject = _project;
const String galleryBranch = _branch;
