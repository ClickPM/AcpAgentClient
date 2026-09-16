// 画板 50 / 51 / 52 / 70 的 gallery 页（R5）：50 与 70 是整窗画板（1440 × 900），51 与 52 是状态合集（BoardPage 版式）。
// 数据源：协议面（会话流 / authMethods / elicitation）来自 test/fixtures 回放或按 docs/design.md § 3 的 payload 形状构造；
// registry 条目、安装进度、Node 状态、设置项是本地假数据，接线阶段换成 registry_list / registry/progress / node_status /
// agent_settings_get 的结果，widget 不动（CLAUDE.md 规则 3）。

import 'package:flutter/widgets.dart';

import '../../projection/entries.dart';
import '../../projection/pending.dart';
import '../../projection/registry.dart';
import '../../projection/tool_calls.dart';
import '../../projection/wire.dart';
import '../../theme/tokens.dart' as t;
import '../../ui/registry/auth_page.dart';
import '../../ui/registry/registry_entry.dart';
import '../../ui/registry/registry_panel.dart';
import '../../ui/settings/settings_page.dart';
import '../../ui/shell/app_shell.dart';
import '../../ui/shell/composer.dart';
import '../../ui/shell/right_panel.dart';
import '../../ui/shell/shell_common.dart';
import '../../ui/shell/sidebar.dart';
import '../../ui/shell/thread_header.dart';
import '../../ui/shell/topbar.dart';
import '../../ui/shell/transcript_empty.dart';
import '../board_page.dart';
import '../fixtures_source.dart';
import '../gallery.dart';

// ---------------------------------------------------------------- 本地假数据（协议之外）

final DateTime _now = DateTime.utc(2026, 9, 15, 12);

final List<SidebarSession> _sessions = <SidebarSession>[
  SidebarSession(id: 's1', title: '主流桌面客户端设计风格参考', updatedAt: _now.subtract(const Duration(minutes: 15)), messageCount: 2),
  SidebarSession(id: 's2', title: 'Pi用户级安装Figma插件', updatedAt: _now.subtract(const Duration(minutes: 30)), messageCount: 10),
  SidebarSession(id: 's3', title: '项目转Flutter工具链', updatedAt: _now.subtract(const Duration(hours: 1)), messageCount: 10),
  SidebarSession(id: 's4', title: 'AgentACPClient项目立项', updatedAt: _now.subtract(const Duration(days: 3)), messageCount: 10),
];

const String _project = 'deepseek-harness';
const String _branch = 'main';

/// registry.json 形状的条目（name / version / description / id / repository），安装状态是本地态。
const List<RegistryEntryData> _registry = <RegistryEntryData>[
  RegistryEntryData(
    id: 'claude-acp',
    name: 'Claude Agent',
    version: '0.76.0',
    description: "ACP wrapper for Anthropic's Claude. Frontier language models with computer use and advanced tool execution.",
    repository: 'https://github.com/agentclientprotocol/claude-agent-acp',
    installed: true,
    installedVersion: '0.76.0',
    authStatus: AuthStatus.authenticated,
  ),
  RegistryEntryData(
    id: 'codex-acp',
    name: 'Codex',
    version: '1.11.0',
    description: "ACP adapter for OpenAI's coding assistant with reasoning, editing, and terminal integration.",
    repository: 'https://github.com/agentclientprotocol/codex-acp',
    installed: true,
    installedVersion: '1.11.0',
  ),
  RegistryEntryData(
    id: 'dsh-acp',
    name: 'DSH ACP Agent',
    version: '0.5.2',
    description: 'VariFlight DSH intelligent coding assistant and ACP protocol language server integration.',
    repository: 'https://github.com/ClickPM/dsh-acp-interactive',
    installed: true,
    installedVersion: '0.5.2',
  ),
  RegistryEntryData(
    id: 'agoragentic-acp',
    name: 'Agoragentic',
    version: '1.3.0',
    description: 'Agent marketplace with 174+ AI capabilities. Browse, invoke, and pay for agent services settled in cryptographic escrow.',
    repository: 'https://github.com/agoragentic/agoragentic-acp',
  ),
  RegistryEntryData(
    id: 'amp-acp',
    name: 'Amp',
    version: '0.9.0',
    description: 'ACP wrapper for Amp - the frontier coding agent designed for rapid reasoning and codebase synthesis.',
    repository: 'https://github.com/sourcegraph/amp-acp',
    kind: DistributionKind.binary,
  ),
  RegistryEntryData(
    id: 'auggie',
    name: 'Auggie CLI',
    version: '0.36.0',
    description: "Augment Code's powerful software agent, backed by industry-leading context engine and real-time codebase indexing.",
    repository: 'https://github.com/augmentcode/auggie',
  ),
  RegistryEntryData(id: 'cline', name: 'Cline', version: '3.0.61', description: 'Autonomous coding agent right in your IDE.', repository: 'https://github.com/cline/cline'),
  RegistryEntryData(id: 'gemini', name: 'Gemini CLI', version: '0.59.0', description: 'An open-source AI agent that brings the power of Gemini directly into your terminal.', repository: 'https://github.com/google-gemini/gemini-cli'),
  RegistryEntryData(id: 'goose', name: 'Goose', version: '1.50.0', description: 'An open source, extensible AI agent that goes beyond code suggestions.', repository: 'https://github.com/block/goose', kind: DistributionKind.binary),
  RegistryEntryData(id: 'kilo', name: 'Kilo', version: '7.6.2', description: 'The open source coding agent.', repository: 'https://github.com/Kilo-Org/kilocode', kind: DistributionKind.binary),
  RegistryEntryData(id: 'opencode', name: 'OpenCode', version: '1.18.30', description: 'The open source coding agent.', repository: 'https://github.com/sst/opencode', kind: DistributionKind.binary),
  RegistryEntryData(id: 'qwen-code', name: 'Qwen Code', version: '0.23.3', description: 'Coding agent that lives in digital world.', repository: 'https://github.com/QwenLM/qwen-code'),
];

const CustomCommand _dshCommand = CustomCommand(
  command: r'D:\variFlight_work\dsh-acp-interactive\target\release\dsh-acp.exe',
  args: <String>['--stdio', '--interactive'],
  env: <String, String>{'DSH_LOG': 'info'},
);

TextEditingController _c([String text = '']) => TextEditingController(text: text);

/// 画板 51 的安装进度样张：进度对象直接按 `registry/progress` 的 payload 形状经 [RegistryState.applyProgress] 构造，
/// 速率与剩余时间由两次采样算出（和真实事件流同一条路）。
InstallProgress _progressOf(List<JsonMap> events, {String agentId = 'x'}) {
  final state = RegistryState()..entries = <RegistryEntryData>[RegistryEntryData(id: agentId, name: agentId, version: '', description: '')];
  var at = _now;
  for (final e in events) {
    state.applyProgress(<String, dynamic>{'agentId': agentId, ...e}, now: at);
    at = at.add(const Duration(seconds: 1));
  }
  return state.entries.first.progress!;
}

/// requestScope 的 URL elicitation（无 sessionId，requestId 是在途 authenticate 的请求 id；docs/design.md § 3）。
ElicitationEntry _requestScopeElicitation({bool opened = false}) {
  final queue = PendingQueue();
  final env = ClientRequestEnvelope(<String, dynamic>{
    'agentId': 'codex-acp',
    'requestId': '7',
    'method': 'elicitation/create',
    'params': <String, dynamic>{
      'mode': 'url',
      'requestId': 5,
      'message': 'Sign in to ChatGPT and enter this code: JHQD-7F2K',
      'elicitationId': 'login_1',
      'url': 'https://auth.openai.com/device',
    },
  });
  final e = queue.addElicitation(env, now: _now, newId: () => 'elicitation_rs_1');
  if (opened) {
    queue.answerElicitation(e.requestId, 'accept', now: _now);
    queue.markOpened(e.requestId);
  }
  return e;
}

/// terminal auth 的可见终端样张（画板 52 的四行）。
TerminalBuffer _authTerminal() => TerminalBuffer('term_auth_1')
  ..append('\$ codex-acp --stdio --login\n')
  ..append('Opening https://auth.openai.com/device ...\n')
  ..append('Enter the code: \x1b[33mJHQD-7F2K\x1b[0m\n')
  ..append('Waiting for authorization');

/// codex-acp 形状的 authMethods（agent 型 + terminal 型；terminal 型是把 args 追加到已配置的调用上）。
const List<JsonMap> _codexAuthMethods = <JsonMap>[
  <String, dynamic>{'id': 'chat-gpt', 'name': 'Sign in with ChatGPT', 'description': 'agent 自己打开系统浏览器完成授权，完成后由 elicitation/complete 收尾。'},
  <String, dynamic>{'type': 'terminal', 'id': 'codex-login', 'name': 'Sign in with Codex CLI', 'args': <String>['--login']},
];

GalleryBoard _window(String id, String title, WidgetBuilder build) => GalleryBoard(
      id: id,
      title: title,
      frame: const Size(1440, 900),
      build: (context) => Overlay(initialEntries: <OverlayEntry>[OverlayEntry(builder: build)]),
    );

GalleryBoard _page(String id, String title, Widget Function() build) =>
    GalleryBoard(id: id, title: title, frame: const Size(BoardPage.width, 0), fitContent: true, build: (_) => build());

/// 画板 51 / 52 的状态卡：560 宽、左对齐。
Widget _card(Widget child) => Align(alignment: Alignment.centerLeft, child: SizedBox(width: t.Geometry.stateCardWidth, child: child));

// ---------------------------------------------------------------- 画板

final List<GalleryBoard> agentBoards = <GalleryBoard>[
  _window('50-registry', 'Agents 面板（ACP Registry）', (_) {
    final r = FixtureReplay.replay(<String>['01-connect', '25-config-options', '19-usage'], upTo: 1);
    final s = r.session;
    final agent = r.sessions.agents[FixtureReplay.agentId];
    final title = 'New ${agent?.agentTitle ?? agent?.agentName ?? 'Agent'} Thread';
    final installed = _registry.where((e) => e.installed).length;
    return AppShell(
      sidebar: Sidebar(sessions: _sessions, now: _now, selectedId: 's1', activeTab: ShellTab.agents, searchController: _c(), searchFocusNode: FocusNode()),
      main: WorkbenchColumn(
        topBar: const TopBar(projectName: _project, branch: _branch, windowControls: false),
        threadHeader: ThreadHeader(title: title, menuSelected: true),
        body: NewThreadEmpty(title: title),
        composer: Composer(
          controller: _c(),
          focusNode: FocusNode(),
          placeholder: 'Message to ${agent?.agentTitle ?? 'Agent'} , @ to include context , / for commands',
          usage: s.usage,
        ),
      ),
      rightPanel: RightPanel(
        tabs: const <ShellTab>[ShellTab.agents],
        active: ShellTab.agents,
        body: RegistryPanel(
          entries: _registry,
          searchController: _c(),
          searchFocusNode: FocusNode(),
          installedCount: installed,
          notInstalledCount: _registry.length - installed,
          node: const NodeStatus(system: NodeInfo(version: 'v22.14.0', path: r'C:\Program Files\nodejs\node.exe')),
        ),
      ),
      rightPanelWidth: t.Geometry.registryPanelWidth,
    );
  }),
  _page('51-registry-states', 'Registry 条目状态', () {
    final npx = _progressOf(<JsonMap>[
      <String, dynamic>{'kind': 'npx', 'step': 'resolve', 'detail': '@sourcegraph/amp-acp@0.9.0'},
    ]);
    final binary = _progressOf(<JsonMap>[
      <String, dynamic>{'kind': 'binary', 'step': 'download', 'detail': 'cortex-code-windows-x64.zip', 'done': 10800000, 'total': 21100000},
      <String, dynamic>{'kind': 'binary', 'step': 'download', 'detail': 'cortex-code-windows-x64.zip', 'done': 13000000, 'total': 21100000},
    ]);
    const amp = RegistryEntryData(
      id: 'amp-acp',
      name: 'Amp',
      version: '0.9.0',
      description: 'ACP wrapper for Amp - the frontier coding agent designed for rapid reasoning and codebase synthesis.',
      packageSpec: '@sourcegraph/amp-acp@0.9.0',
    );
    return BoardPage(
      number: '51',
      title: 'Registry 条目状态',
      source: 'registry.json + 本地安装流程（npx / binary / custom）· authMethods · 受管 Node',
      sections: <BoardSection>[
        BoardSection('未安装', child: _card(const RegistryEntryCard(amp))),
        BoardSection('安装中 · npx 解析', child: _card(RegistryEntryCard(amp.copyWith(progress: npx)))),
        BoardSection('安装中 · binary（下载 → sha256 校验 → 解压）',
            child: _card(RegistryEntryCard(
              const RegistryEntryData(id: 'cortex-code', name: 'Cortex Code', version: '1.0.73', description: '', kind: DistributionKind.binary).copyWith(progress: binary),
            ))),
        BoardSection('已安装', child: _card(RegistryEntryCard(_registry[0]))),
        BoardSection('需要认证',
            child: _card(RegistryEntryCard(const RegistryEntryData(
              id: 'codex-acp',
              name: 'Codex',
              version: '1.11.0',
              description: '',
              installed: true,
              installedVersion: '1.11.0',
              authStatus: AuthStatus.needsAuth,
            )))),
        BoardSection('安装失败（可重试、看日志）',
            child: _card(RegistryEntryCard(const RegistryEntryData(
              id: 'auggie',
              name: 'Auggie CLI',
              version: '0.36.0',
              description: '',
              failure: 'npm error code E404\nnpm error 404 Not Found - GET https://registry.npmjs.org/@augmentcode%2fauggie-acp',
            )))),
        BoardSection('uvx 暂不支持',
            child: _card(RegistryEntryCard(const RegistryEntryData(id: 'goose', name: 'Goose', version: '1.2.0', description: '', kind: DistributionKind.uvx)))),
        BoardSection('自定义命令的 agent 条目',
            child: _card(RegistryEntryCard(const RegistryEntryData(
              id: 'dsh-acp-interactive',
              name: 'dsh-acp-interactive',
              version: '',
              description: '',
              kind: DistributionKind.custom,
              installed: true,
              custom: _dshCommand,
            )))),
        BoardSection('缺 Node 时的受管 Node 提示', child: _card(const ManagedNodePrompt())),
      ],
      footnote: '安装状态是本地态，不是协议内容；已登录徽章来自本地记录的 session/new 结果（成功 = 已登录，-32000 = 需要认证），'
          'agent 型与 terminal 型的差异见画板 52。偏离：npx 第二步写的是 settings.json（数据目录里没有 agents.json，见 docs/design.md § 10）；'
          '「需要认证」的描述不写死 ChatGPT（规则 2）。',
    );
  }),
  _page('52-auth', 'agent 认证', () {
    return BoardPage(
      number: '52',
      title: 'agent 认证',
      source: 'authMethods（agent / terminal 型）· authenticate · -32000 · requestScope 的 elicitation',
      sections: <BoardSection>[
        BoardSection('认证方式选择',
            child: _card(const AuthMethodPicker(agentName: 'Codex', authMethods: _codexAuthMethods, selectedMethodId: 'chat-gpt'))),
        BoardSection('terminal auth · 运行中的可见终端',
            child: _card(AuthTerminalCard(label: 'codex-acp --login', buffer: _authTerminal()))),
        BoardSection('成功后自动重试新会话', child: _card(const AuthSucceededCard())),
        BoardSection('失败态', child: _card(const AuthFailedCard(error: 'authenticate failed: device code expired (-32000)'))),
        BoardSection('无会话阶段的 URL elicitation（requestScope）',
            child: _card(RequestScopeElicitationCard(_requestScopeElicitation(), agentName: 'codex-acp'))),
        BoardSection('同上 · 已打开浏览器，等 elicitation/complete',
            child: _card(RequestScopeElicitationCard(_requestScopeElicitation(opened: true), agentName: 'codex-acp'))),
      ],
      footnote: 'terminal 型登录是把 args / env 追加到已配置的调用上重新拉起同一个 agent；需要客户端声明 auth.terminal 能力。'
          '认证成功后自动重试原来的 session/new。requestScope 卡的说明文字用 elicitation 自带的 message。',
    );
  }),
  _window('70-settings', '设置', (_) {
    final agents = <RegistryEntryData>[
      _registry[0],
      const RegistryEntryData(id: 'codex-acp', name: 'Codex', version: '1.11.0', description: '', installed: true, installedVersion: '1.11.0', authStatus: AuthStatus.needsAuth),
      const RegistryEntryData(id: 'dsh-acp-interactive', name: 'dsh-acp-interactive', version: '', description: '', kind: DistributionKind.custom, installed: true, custom: _dshCommand),
    ];
    return AppShell(
      sidebar: Sidebar(sessions: _sessions, now: _now, selectedId: 's1', activeTab: ShellTab.settings, searchController: _c(), searchFocusNode: FocusNode()),
      main: Container(
        color: t.Surface.canvas,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const TopBar(projectName: _project, branch: _branch),
            Expanded(
              child: SettingsPage(
                agents: agents,
                dataDir: r'C:\Users\Click\AppData\Roaming\AcpAgentClient',
                logPath: r'C:\Users\Click\AppData\Roaming\AcpAgentClient\logs\acp-2026-09-14.log',
                zedSettingsPath: r'C:\Users\Click\AppData\Roaming\Zed\settings.json',
                node: const NodeStatus(system: NodeInfo(version: 'v22.14.0', path: r'C:\Program Files\nodejs\node.exe')),
                editingId: 'dsh-acp-interactive',
                editFields: CustomEditFields(
                  command: _c(_dshCommand.command),
                  args: _c(_dshCommand.argsText),
                  env: _c(_dshCommand.envText),
                  focus: FocusNode(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }),
];
