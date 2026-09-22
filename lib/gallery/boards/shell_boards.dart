// 画板 01 / 02 / 03 / 04 / 06 / 40 / 41 / 42 / 80 的 gallery 页（R3；06 是 2026-09-18 的增补）：整窗画板按 1440 × 900 的 frame 渲染，
// 合集画板沿用 R2 的 BoardPage 版式。数据源：协议面（会话流 / configOptions / 命令 / 用量 / 流量）一律来自
// test/fixtures 回放；协议之外的本地态（会话索引、项目与分支列表、已安装 agent、@ 提及候选）是本地假数据，
// 接线阶段换成 `sessions.json` / `projects.json` / git CLI / `fs_search`，widget 不动（CLAUDE.md 规则 3）。

import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../../app/transcript_folds.dart';
import '../../projection/entries.dart';
import '../../projection/fixture_line.dart';
import '../../projection/session_store.dart';
import '../../projection/timeline.dart';
import '../../projection/traffic.dart';
import '../../projection/turn_fold.dart';
import '../../projection/wire.dart';
import '../../theme/tokens.dart' as t;
import '../../ui/popovers/composer_popovers.dart';
import '../../ui/popovers/inline_menus.dart';
import '../../ui/popovers/session_timeline.dart';
import '../../ui/popovers/topbar_popovers.dart';
import '../../ui/files/file_tree.dart';
import '../../ui/files/files_panel.dart';
import '../../ui/shell/app_shell.dart';
import '../../ui/shell/composer.dart';
import '../../ui/shell/right_panel.dart';
import '../../ui/shell/running_badge.dart';
import '../../ui/shell/shell_common.dart';
import '../../ui/shell/sidebar.dart';
import '../../ui/shell/session_header.dart';
import '../../ui/shell/topbar.dart';
import '../../ui/shell/transcript_empty.dart';
import '../../ui/traffic/traffic_page.dart';
import '../../ui/transcript/awaiting_bar.dart';
import '../../ui/transcript/plan_card.dart';
import '../../ui/transcript/transcript_list.dart';
import '../../ui/transcript/turn_fold_row.dart';
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

String _sessionTitle(FixtureReplay r) => r.session.title ?? 'New ${_agentTitle(r)} Session';

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

/// 画板 01 / 03 输入框里的三个下拉：PNG 是按「模型 · 思考强度 · 模式」排的，画板未按固定档序重出之前，
/// 对照板保持 PNG 的顺序与条目（真输入框已改成按档序把每条 configOption 都平铺出来，见 rounds/BACKLOG.md）。
List<ComposerOption> _composerOptions(
  SessionStore s, {
  List<String> categories = const <String>['model', 'thought_level', 'mode'],
}) {
  final options = <ComposerOption>[];
  for (final category in categories) {
    final label = _currentName(s, category);
    if (label == null) continue;
    options.add(ComposerOption(
      label: label,
      maxWidth: category == 'model' ? t.Geometry.composerModelMaxWidth : null,
    ));
  }
  return options;
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
        sessionHeader: SessionHeader(title: _sessionTitle(r)),
        body: NewSessionEmpty(title: _sessionTitle(r)),
        composer: Composer(
          controller: _c(),
          focusNode: FocusNode(),
          placeholder: _composerPlaceholder(r),
          usage: s.usage,
          options: _composerOptions(s),
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
        sessionHeader: const SessionHeader(title: 'No Agent', hasAgent: false, canRename: false, canReload: false),
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
    // 停在挂起的权限请求上：回合仍在进行（会话头 spinner + 发送位是停止方块 + Awaiting 停靠条）。
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
        sessionHeader: SessionHeader(title: _sessionTitle(r), running: s.isRunning),
        body: _transcript(r),
        composer: Composer(
          controller: _c(),
          focusNode: FocusNode(),
          placeholder: _composerPlaceholder(r),
          running: s.isRunning,
          usage: s.usage,
          options: _composerOptions(s),
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
        sessionHeader: SessionHeader(title: _sessionTitle(r), menuSelected: true),
        body: _transcript(r),
        composer: Composer(
          controller: _c(),
          focusNode: FocusNode(),
          placeholder: _composerPlaceholder(r),
          usage: s.usage,
          options: _composerOptions(s),
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
  _page('06-session-activity', '侧栏会话活动指示', () {
    return BoardPage(
      number: '06',
      title: '侧栏会话活动指示',
      source: 'session/prompt 在途（运行中）· stop_reason = end_turn / max_tokens / …（完成）· session/cancel ·「已读」为客户端本地态',
      sections: <BoardSection>[
        BoardSection('A · 运行中 · 会话项底部的扫掠亮点线（本页唯一动起来的元素；相邻会话项不动、不缩进、不变色）',
            child: _panel(<Widget>[
              SidebarSessionRow(_sessions[0], now: _now, selected: true, running: true),
              SidebarSessionRow(_sessions[1], now: _now),
            ])),
        BoardSection('A · 运行中 + 悬浮（重命名 / 删除照常出现，压在细线之上；细线不为它让位）',
            child: _panel(<Widget>[
              SidebarSessionRow(_sessions[2], now: _now, running: true, forceHover: true),
            ])),
        BoardSection('B · ① 运行中（无绿点）· ② 完成 t=0（细线已撤、行高回 48、绿点 opacity 0）· ③ 完成 t=120ms（绿点 opacity 1）· ④ 已读（绿点淡出后不占位）',
            child: _panel(<Widget>[
              SidebarSessionRow(_sessions[3], now: _now, running: true),
              SidebarSessionRow(_sessions[3], now: _now),
              SidebarSessionRow(_sessions[3], now: _now, unread: true),
              SidebarSessionRow(_sessions[3], now: _now, selected: true),
            ])),
        BoardSection('C · 列表全景（两条在跑、一条跑完未读；各自独立扫掠、不同步相位）',
            child: _panel(<Widget>[
              SidebarSessionRow(_sessions[0], now: _now, selected: true, running: true),
              SidebarSessionRow(_sessions[1], now: _now, unread: true),
              SidebarSessionRow(_sessions[2], now: _now),
              SidebarSessionRow(_sessions[3], now: _now, running: true),
            ])),
      ],
      footnote: '亮点线只表示「在动」，不表达进度：单向匀速、不回弹、不反向，亮点位置与完成度无关；'
          'sweep.cycle 是全系统唯一允许用 linear 的动效。绿点是「未读完成」标记而非状态灯，'
          '只在回合从运行中转为结束（stop_reason ≠ cancelled / refusal）时点亮，该会话被查看后淡出；'
          '取消与失败侧栏不表达，走画板 31 / 34。两者严格互斥，任何一帧都不同时出现。'
          '偏离：清除条件里的「窗口聚焦」这一维没有实现（宿主没给这个信号），按「当前会话 + 停在工作台页」判。',
    );
  }),
  _page('08-interaction-upgrades', '交互增强 · 回合折叠 / 跨工作区在跑数', () {
    final SessionStore twoLine = _foldSample(model: 'Gemini 3.8 Flash High (CLIProxy)');
    final SessionStore oneLine = _foldSample();
    final SessionStore failed = _foldSample(failures: 1);
    final TranscriptFolds collapsed = TranscriptFolds();
    final TranscriptFolds expanded = TranscriptFolds();
    expanded.expand(foldsOf(twoLine.entries).values.single);
    return BoardPage(
      number: '08',
      title: '交互增强 · 回合折叠 / 跨工作区在跑数',
      source: 'stop_reason · session/prompt 在途 · 会话所属工作区（本地）',
      sections: <BoardSection>[
        BoardSection('B · 摘要行 · 折叠（两行：第二行是回合开始时的模型名）',
            child: _left(SizedBox(width: _foldWidth, child: TurnFoldRow(fold: _foldOf(twoLine), collapsed: true)))),
        BoardSection('B · 摘要行 · 折叠 + 悬浮（fold.hover 是整行可点的唯一反馈）',
            child: _left(SizedBox(width: _foldWidth, child: TurnFoldRow(fold: _foldOf(twoLine), collapsed: true, forceHover: true)))),
        BoardSection('B · 无模型信息时 · 单行',
            child: _left(SizedBox(width: _foldWidth, child: TurnFoldRow(fold: _foldOf(oneLine), collapsed: true)))),
        BoardSection('B · 有失败项（首行末尾追加「N 项失败」，该回合不自动折叠）',
            child: _left(SizedBox(width: _foldWidth, child: TurnFoldRow(fold: _foldOf(failed), collapsed: true)))),
        BoardSection('B · 展开态标题行（无容器无底色，chevron 换成向下 + 一行 11px 摘要）',
            child: _left(SizedBox(width: _foldWidth, child: TurnFoldRow(fold: _foldOf(twoLine), collapsed: false)))),
        BoardSection('B · 转录里 · 折叠（折叠块压在用户消息与最终助手文本之间）',
            child: _transcriptSample(240, twoLine, collapsed)),
        BoardSection('B · 转录里 · 展开（同一轮，位置不因折叠改变）',
            child: _transcriptSample(460, twoLine, expanded)),
        BoardSection('C · 徽标三态（1 条 / 两位数 / 0 条不渲染）',
            child: _left(Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const RunningBadge(1),
                const SizedBox(width: t.Spacing.s24),
                const RunningBadge(12),
                const SizedBox(width: t.Spacing.s24),
                const RunningBadge(100),
                const SizedBox(width: t.Spacing.s24),
                Text('0 条在跑 · 无徽标、无灰底 0、不留占位', style: t.TextStyles.monoMeta),
              ],
            ))),
        const BoardSection('C · 触发钮（合计 = 所有工作区，含当前）',
            child: TopBar(projectName: _project, branch: _branch, windowControls: false, runningTotal: 3, runningWorkspaces: 2)),
        BoardSection('C · 切换器弹层（This Window 恒一行；Recent Projects 里本次运行开过、还有会话在跑的那行也挂徽标）',
            child: _left(ProjectSwitcherPopover(
              openProjects: _switcherOpen,
              recentProjects: _switcherRecent,
              currentPath: _switcherOpen.first.path,
              searchController: _c(),
              searchFocusNode: FocusNode(),
              runningOf: (p) => _switcherRunning[p.path] ?? 0,
            ))),
      ],
      footnote: 'A 段（回复中的 token 速度标签）已在设计阶段整段删除：流式期间协议给不出输出 token '
          '（usage_update.used 是会话级上下文占用，四家 agent 口径还各不相同；session/update 里也没有时间戳），'
          '回合级真值只有 PromptResponse.usage，回合结束才到 —— 那是画板 31 页脚已经在做的事。'
          '折叠只对本次会话里真正跑过的回合生效：session/load 的重放不带回轮边界（docs/design.md § 3），'
          '重放出来的历史里没有 TurnEntry，也就没有摘要行。'
          '偏离：权限卡与 elicitation 卡不折叠（画板两列都没列到它们，挂起的那张必须看得见）；'
          '徽标图标用既有的 AcpIcons.rotateCw（画板画的是同一个 lucide 字形的 r=8 版本，11px 下差别在 1px 以内）。',
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
        BoardSection('会话头 ≡ 菜单（动作由 sessionCapabilities 驱动）',
            child: _left(SessionMenuPopover(
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
              options: _composerOptions(r.session, categories: const <String>['mode']),
              inlineMenu: const MentionMenu(files: _mentionFiles, directories: _mentionDirs, recent: _mentionRecent),
            )),
        BoardSection('/ 命令菜单（命令名 + 描述 + 参数提示）', child: _left(SlashCommandMenu(commands: commands))),
        BoardSection('输入框里的 / 命令',
            child: Composer(
              controller: _c('/co'),
              focusNode: FocusNode(),
              placeholder: '',
              options: _composerOptions(r.session, categories: const <String>['mode']),
              inlineMenu: SlashCommandMenu(commands: commands),
            )),
      ],
      footnote: '命令清单来自 available_commands_update 的全量列表，input 目前只有 unstructured（hint 即参数提示）；'
          '@ 能塞什么由 promptCapabilities.{image, audio, embeddedContext} 决定，缺能力时对应分组不出现。'
          '分组按所有者裁定 2026-09-15 只渲染单组 Commands（AvailableCommand 没有分组与来源字段）。',
    );
  }),
  _page('43-session-timeline', '会话时间线弹层', () {
    return BoardPage(
      number: '43',
      title: '会话时间线弹层',
      source: 'session/prompt（轮边界）· user_message_chunk · agent_message_chunk',
      sections: <BoardSection>[
        BoardSection('B · 弹层 · 完整样张（5 轮，第 03 轮无 A 行）',
            child: _left(const SessionTimelinePopover(turns: _timelineSample, scrollToBottomOnOpen: false))),
        BoardSection('C · 行的四态（默认 / 悬浮 6% / 键盘高亮 10% / 没有 A 行的轮）',
            // 画板页宽 800，四份 420 的样张排一行装不下，按内容折行（画板上是横排四份）。
            child: Wrap(
              spacing: t.Spacing.s24,
              runSpacing: t.Spacing.s24,
              children: <Widget>[
                for (final sample in _timelineRowStates)
                  SessionTimelinePopover(
                    turns: sample.turns,
                    initialSelection: sample.selected,
                    forceHoverIndex: sample.hovered,
                    scrollToBottomOnOpen: false,
                  ),
              ],
            )),
        BoardSection('D · 封顶滚动（30 轮 · 高 675 = 900 × 0.75）',
            child: _left(SessionTimelinePopover(turns: _timelineLong, maxHeight: _timelineBoardMaxHeight))),
        BoardSection('E · 空态（有会话、还没有任何一轮）',
            child: _left(const SessionTimelinePopover(turns: <TimelineTurn>[]))),
      ],
      footnote: '轮按顶层用户消息切（不按 TurnEntry —— session/load 重放回来的历史里一条边界都没有）；'
          'A 行取该轮最后一条 agent 文本的首行，去掉行首 Markdown 标记；没有 A 行的轮只画编号行。'
          '点一行转录区 0ms 跳到该条，目标块顶边对齐转录区顶部内边距 16。',
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

// ---------------------------------------------------------------- 画板 43 的时间线样张（本地假数据）

/// 画板 43 B 组的 5 轮示例（第 03 轮被打断、没有 A 行）。
const List<TimelineTurn> _timelineSample = <TimelineTurn>[
  TimelineTurn(n: 1, entryId: 'msg-1', query: 'hi', answer: '你好！有什么可以帮你的？', answerEntryId: 'msg-2'),
  TimelineTurn(
      n: 2,
      entryId: 'msg-3',
      query: '你是什么模型',
      answer: '当前会话跑的是 deepseek-v4-flash（provider: deepseek），思考强度 high',
      answerEntryId: 'msg-4'),
  TimelineTurn(n: 3, entryId: 'msg-5', query: '你能看到这张图吗'),
  TimelineTurn(
      n: 4, entryId: 'msg-6', query: '你能看到这张图吗', answer: '能看到。这是 Pi Agent 桌面版的截图，里面有：', answerEntryId: 'msg-7'),
  TimelineTurn(n: 5, entryId: 'msg-8', query: '当前 会话的jsonl保存在哪里', answer: '当前会话的 JSONL：', answerEntryId: 'msg-9'),
];

/// C 组四态各自一份单轮数据（第四份没有 A 行）。
class _TimelineRowSample {
  const _TimelineRowSample(this.turns, {this.selected = -1, this.hovered = -1});

  final List<TimelineTurn> turns;
  final int selected;
  final int hovered;
}

const TimelineTurn _timelineRowTurn =
    TimelineTurn(n: 4, entryId: 'msg-6', query: '你能看到这张图吗', answer: '能看到。这是桌面版的截图', answerEntryId: 'msg-7');

const List<_TimelineRowSample> _timelineRowStates = <_TimelineRowSample>[
  _TimelineRowSample(<TimelineTurn>[_timelineRowTurn]),
  _TimelineRowSample(<TimelineTurn>[_timelineRowTurn], hovered: 0),
  _TimelineRowSample(<TimelineTurn>[_timelineRowTurn], selected: 1),
  _TimelineRowSample(<TimelineTurn>[TimelineTurn(n: 3, entryId: 'msg-5', query: '你能看到这张图吗')]),
];

/// D 组：30 轮，弹层按画板给的 675（= 900 × 0.75）封顶后在内部滚动。
final List<TimelineTurn> _timelineLong = <TimelineTurn>[
  for (var i = 1; i <= 30; i++)
    TimelineTurn(n: i, entryId: 'msg-$i', query: '第 $i 轮问的那句', answer: '第 $i 轮的回答', answerEntryId: 'a-$i'),
];

/// 画板 D 组按 1440 × 900 的窗口算出来的上限；真实弹层按当帧窗口高现算（见 [SessionTimelinePopover.maxHeight]）。
const double _timelineBoardMaxHeight = 900 * t.Timeline.maxHeightFactor;

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

// ---------------------------------------------------------------- 画板 08 的样张（本地假数据）

/// 摘要行样张的宽度：比 800 的画板页窄一档，看得出它不是整宽拉伸的。
const double _foldWidth = 520;

/// 转录整段样张。`TranscriptList` 里的 `SelectableRegion` 要一个 Overlay 祖先，
/// 而 BoardPage 的分节里没有（整窗画板是 `AppShell` 自带的），所以这里垫一层。
Widget _transcriptSample(double height, SessionStore store, TranscriptFolds folds) => SizedBox(
      height: height,
      child: Overlay(
        initialEntries: <OverlayEntry>[
          OverlayEntry(builder: (_) => TranscriptList(store, folds: folds)),
        ],
      ),
    );

/// 一轮：思考 1 + 工具调用 2（[failures] 条标成失败）+ 最终助手文本 1。
SessionStore _foldSample({String? model, int failures = 0}) {
  // 时钟一步一秒：思考块的耗时与回合页脚的耗时都从它来。
  // 不用毫秒档——`Duration(milliseconds:` 是 Assert-NoStyleLiteral（规则 3）扫的动效时长字面量之一。
  var clock = DateTime.utc(2026, 9, 22, 12);
  final s = SessionStore(
    sessionId: 'sess_fold_gallery',
    clock: () {
      clock = clock.add(const Duration(seconds: 1));
      return clock;
    },
  );
  if (model != null) {
    s.applyUpdateJson(<String, dynamic>{
      'sessionUpdate': 'config_option_update',
      'configOptions': <Object>[
        <String, dynamic>{
          'id': 'model',
          'category': 'model',
          'type': 'select',
          'currentValue': 'm',
          'options': <Object>[
            <String, dynamic>{'value': 'm', 'name': model},
          ],
        },
      ],
    });
  }
  s.startTurn(const <ContentBlockWire>[
    ContentBlockWire(<String, dynamic>{'type': 'text', 'text': '开始做第二阶段'}),
  ]);
  s.applyUpdateJson(<String, dynamic>{
    'sessionUpdate': 'agent_thought_chunk',
    'content': <String, dynamic>{'type': 'text', 'text': '先复核最新提交，确认 v0.4.0 的改动范围…'},
  });
  for (var i = 0; i < 2; i++) {
    s.applyUpdateJson(<String, dynamic>{
      'sessionUpdate': 'tool_call',
      'toolCallId': 'tc-$i',
      'title': i == 0 ? 'Read file' : 'Run',
      'status': i < failures ? 'failed' : 'completed',
    });
  }
  s.applyUpdateJson(<String, dynamic>{
    'sessionUpdate': 'agent_message_chunk',
    'content': <String, dynamic>{
      'type': 'text',
      'text': '第二阶段（吸纳核心开源插件）已全部开发完毕，并通过完整的 TypeScript 类型检查和自动化测试。',
    },
  });
  s.endTurn(stopReason: 'end_turn');
  return s;
}

TurnFold _foldOf(SessionStore s) => foldsOf(s.entries).values.single;

/// 画板 08 C 的切换器样张：本窗口只开着一个工作区，Recent 里有一个本次运行开过、还有 2 条在跑。
const List<ProjectRef> _switcherOpen = <ProjectRef>[
  ProjectRef(path: r'D:\variFlight_work\pi-cordis-toolbox', name: r'…ariFlight_work\pi-cordis-toolbox'),
];
const List<ProjectRef> _switcherRecent = <ProjectRef>[
  ProjectRef(path: r'D:\variFlight_work\VariFlightWork', name: r'…ariFlight_work\VariFlightWork'),
  ProjectRef(path: r'D:\variFlight_work\AcpAgentClient', name: r'…ariFlight_work\AcpAgentClient'),
  ProjectRef(path: r'D:\tmp\9ffdc02c\scratchpad\probe-cwd', name: r'…9ffdc02c\scratchpad\probe-cwd'),
  ProjectRef(path: r'D:\cargo-target\AcpAgentClient\r6-pi', name: r'…o-target\AcpAgentClient\r6-pi'),
];
const Map<String, int> _switcherRunning = <String, int>{
  r'D:\variFlight_work\pi-cordis-toolbox': 1,
  r'D:\variFlight_work\VariFlightWork': 2,
};
