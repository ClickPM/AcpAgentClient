// 画板 18–34 的 gallery 页（承接 transcript_boards.dart）。数据来自 test/fixtures 回放；acp/agent_state 与 elicitation/complete
// 不是 fixtures 行（README「不进 fixtures 的两类数据」），在这里用投影层 API 构造。只在 debug / test 编入。

import 'package:flutter/widgets.dart';

import '../../projection/agent_state.dart';
import '../../projection/entries.dart';
import '../../projection/session_store.dart';
import '../../projection/wire.dart';
import '../../theme/tokens.dart' as t;
import '../../ui/shell/agent_state_bar.dart';
import '../../ui/transcript/awaiting_bar.dart';
import '../../ui/transcript/compaction_card.dart';
import '../../ui/transcript/content_blocks.dart';
import '../../ui/transcript/context_window.dart';
import '../../ui/transcript/diff_card.dart';
import '../../ui/transcript/elicitation_form_card.dart';
import '../../ui/transcript/elicitation_url_card.dart';
import '../../ui/transcript/permission_card.dart';
import '../../ui/transcript/plan_card.dart';
import '../../ui/transcript/subagent_card.dart';
import '../../ui/transcript/terminal_card.dart';
import '../../ui/transcript/tool_call_card.dart';
import '../../ui/transcript/turn_state.dart';
import '../board_page.dart';
import '../fixtures_source.dart';
import '../gallery.dart';
import 'board_helpers.dart';

String _agentName(FixtureReplay r) => r.sessions.agents[FixtureReplay.agentId]?.agentName ?? FixtureReplay.agentId;

final List<GalleryBoard> transcriptBoards2 = <GalleryBoard>[
  pageBoard('18-tool-call', '标准工具调用卡', () {
    final r = FixtureReplay.replay(<String>['01-connect', '13-tool-kinds']);
    final cwd = r.session.cwd;
    return BoardPage(
      number: '18',
      title: '标准工具调用卡',
      source: 'tool_call + tool_call_update（kind / status / locations / rawInput / rawOutput；集合字段是替换语义）',
      sections: <BoardSection>[
        BoardSection('折叠行（completed）', child: ToolCallCard(r.tool('call_read_k1'), cwd: cwd)),
        BoardSection('展开（Raw Input: / Output: / 底部收起条）', child: ToolCallCard(r.tool('call_read_k1'), cwd: cwd, initiallyExpanded: true)),
        BoardSection(
          '路径悬浮出 Go to File（落右栏文件面板，locations[] 的 path + line）',
          child: Padding(
            padding: const EdgeInsets.only(bottom: t.Spacing.s24),
            child: ToolCallCard(r.tool('call_read_k1'), cwd: cwd, pathHoveredInitially: true, onGoToFile: (_, _) {}),
          ),
        ),
        BoardSection(
          '状态：pending / in_progress / completed',
          child: BoardStack(<Widget>[
            ToolCallCard(r.tool('call_search_k1'), cwd: cwd),
            ToolCallCard(r.tool('call_exec_k1'), cwd: cwd),
            ToolCallCard(r.tool('call_read_k2'), cwd: cwd),
          ]),
        ),
        const BoardSection('kind 图标（read / search / execute / fetch / other）', child: KindIconRow()),
      ],
      footnote: '未知 kind 安全落到 other（Rust 侧 serde other）；先到的 tool_call_update 可凭空建卡，视觉与正常卡无差异（acp-projection.md § 7 第 4 条）。edit / delete / move / think / switch_mode 复用同一行结构，只换 kind 图标。',
    );
  }),
  pageBoard('19-tool-failed', '工具调用失败卡', () {
    final r = FixtureReplay.replay(<String>['01-connect', '13-tool-kinds']);
    final cwd = r.session.cwd;
    return BoardPage(
      number: '19',
      title: '工具调用失败卡',
      source: 'tool_call_update · status: failed',
      sections: <BoardSection>[
        BoardSection('折叠行（右侧 ✕ 常驻）', child: ToolCallCard(r.tool('call_read_fail'), cwd: cwd)),
        BoardSection('展开看错误', child: ToolCallCard(r.tool('call_read_fail'), cwd: cwd, initiallyExpanded: true)),
      ],
      footnote: '失败只换状态图标与 Output 底色（error.soft），不加左侧彩条、不给整卡着色。',
    );
  }),
  pageBoard('20-tool-cancelled', '工具已取消卡', () {
    final r = FixtureReplay.replay(<String>['01-connect', '10-cancel']);
    return BoardPage(
      number: '20',
      title: '工具已取消卡',
      source: '客户端本地态（ToolCallStatus 没有 cancelled）',
      sections: <BoardSection>[
        BoardSection('已取消（输出位置是 Error: tool call aborted）', child: ToolCallCard(r.tool('call_exec_c1'), cwd: r.session.cwd, initiallyExpanded: true)),
      ],
      footnote: '发出 session/cancel 后，客户端把本轮未完成的工具调用标成本地 cancelled；用中性徽章而不是 error 色，与「失败」区分（acp-projection.md § 7 第 1 条）。',
    );
  }),
  pageBoard('21-diff-card', '文件差异对比卡', () {
    final r = FixtureReplay.replay(<String>['01-connect', '13-tool-kinds']);
    final e = r.tool('call_edit_backlog');
    final diff = e.diffs.first;
    return BoardPage(
      number: '21',
      title: '文件差异对比卡',
      source: 'tool_call.content[] · { type: "diff", path, oldText, newText }（只读）',
      sections: <BoardSection>[
        BoardSection('折叠（路径 + 增删计数）', child: DiffCard(e, diff: diff, cwd: r.session.cwd)),
        BoardSection('展开（行号 · 增删行着色 · 行悬浮出「在文件面板中定位」）', child: DiffCard(e, diff: diff, cwd: r.session.cwd, initiallyExpanded: true, hoveredLineIndex: 8)),
      ],
      footnote: '既定裁定：不做 Zed 的 Edits 审阅条，没有 Keep / Reject / 逐文件接受；点行只在右栏文件面板定位。增删行用 success.soft / error.soft 打底，符号列与行号列都是等宽 tabular。',
    );
  }),
  pageBoard('22-terminal-card', '嵌入式终端控制台卡', () {
    final r = FixtureReplay.replay(<String>['01-connect', '24-terminal-git-log']);
    final e = r.tool('call_exec_git');
    final buffer = r.sessions.terminals['term_7f31']!;
    return BoardPage(
      number: '22',
      title: '嵌入式终端控制台卡',
      source: 'tool_call.content[] · { type: "terminal", terminalId } + terminal/output + terminal/wait_for_exit',
      sections: <BoardSection>[
        BoardSection('展开（ANSI 彩色输出 · Exit Code · release 后输出留存）', child: TerminalCard(e, buffer: buffer, cwd: r.session.cwd)),
        BoardSection('折叠', child: TerminalCard(e, buffer: buffer, cwd: r.session.cwd, initiallyExpanded: false)),
      ],
      footnote: 'ANSI 三色按语义色映射：黄 → warning、绿 → success、青 → info/accent，不引入表外色相。终端被嵌进工具卡后即使 terminal/release 也继续显示输出（规范 SHOULD，acp-projection.md § 4）。',
    );
  }),
  pageBoard('23-terminal-running', '终端进行中卡', () {
    final r = FixtureReplay.replay(<String>['01-connect', '21-terminal-running'], upTo: 8);
    final e = r.tool('call_exec_r1');
    return BoardPage(
      number: '23',
      title: '终端进行中卡',
      source: 'terminal/create → terminal/output（本地流）· terminal/kill',
      sections: <BoardSection>[
        BoardSection('进行中（spinner + 红色停止方块 → terminal/kill）', child: TerminalCard(e, buffer: r.sessions.terminals['term_run']!, cwd: r.session.cwd)),
      ],
      footnote: '停止方块是 ghost 容器里的 error 色小方块，不是红色填充按钮；输出按字符边界截断（规范硬要求）。',
    );
  }),
  pageBoard('24-subagent', '子代理委派卡', () {
    final r = FixtureReplay.replay(<String>['01-connect', '14-subagent']);
    final cwd = r.session.cwd;
    return BoardPage(
      number: '24',
      title: '子代理委派卡',
      source: 'tool_call（spawn_agent）· _meta.claudeCode.{ parentToolUseId, subagent, toolName }',
      sections: <BoardSection>[
        BoardSection('进行中（可停）', child: SubagentCard(r.tool('call_sub_1'), cwd: cwd)),
        BoardSection('完成后展开（嵌套工具行 · ↳ Subagent Output · 反馈图标）', child: SubagentCard(r.tool('call_sub_2'), cwd: cwd)),
        BoardSection('同一张卡吃 _meta.dsh_subagent（子代理转录折进父卡 content[]）', child: SubagentCard(r.tool('call_dsh_1'), cwd: cwd)),
      ],
      footnote: '疑点（不阻塞出稿）：本卡依赖 _meta.claudeCode.subagent，与「无 agent 特判」及 _meta 键白名单有张力，设计照原型出；不声明 AIR 能力时子代理输出仍进主转录，只是没有独立会话层级。',
    );
  }),
  pageBoard('25-permission', '权限授权卡', () {
    final r = FixtureReplay.replay(<String>['01-connect', '15-permission-kinds'], untilTag: 'session/request_permission');
    final p = r.first<PermissionEntry>();
    final tc = r.tool('toolu_014Qx9');
    final cwd = r.session.cwd;
    // 下拉菜单浮在 Overlay 上、画在卡片之外：最后一节自带一个 Overlay（真实应用由 MaterialApp 提供），
    // 高度 = 卡片本身（头行 + View Raw Input 行 + 底部按钮行 + 上下边框）+ 菜单高度；不裁剪，算少了也只是少留白。
    final cardHeight = t.Controls.input + t.Controls.standard + t.Spacing.s8 * 2 + t.Controls.standard + t.Borders.width * 2;
    final menuRoom = t.Controls.standard * p.options.length + t.Spacing.s16;
    return BoardPage(
      number: '25',
      title: '权限授权卡',
      source: 'session/request_permission · options[].kind = allow_once / allow_always / reject_once / reject_always',
      sections: <BoardSection>[
        BoardSection('默认（Raw Input 折叠）', child: PermissionCard(p, toolCall: tc, cwd: cwd)),
        BoardSection('View Raw Input 展开', child: PermissionCard(p, toolCall: tc, cwd: cwd, rawExpandedInitially: true)),
        BoardSection(
          '范围下拉展开（四种 kind 的文案；记忆语义由 agent 负责）',
          child: SizedBox(
            height: cardHeight + menuRoom,
            child: Overlay(
              clipBehavior: Clip.none,
              initialEntries: <OverlayEntry>[
                // Overlay 给非定位子节点的是紧约束，Align 松开后卡片才按内容高度画。
                OverlayEntry(
                  builder: (_) => Align(
                    alignment: Alignment.topCenter,
                    child: PermissionCard(p, toolCall: tc, cwd: cwd, scopeOpenInitially: true),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
      footnote: '回应只有 { outcome: "selected", optionId } 与 { outcome: "cancelled" }；发出 session/cancel 后所有挂起的权限请求 MUST 以 cancelled 回应。请求里带的是 ToolCallUpdate，可能只有 toolCallId，标题与 kind 要从已累积的 tool call 取。',
    );
  }),
  pageBoard('26-awaiting', 'Awaiting Confirmation', () {
    final r = FixtureReplay.replay(<String>['01-connect', '15-permission-kinds'], untilTag: 'session/request_permission');
    final p = r.first<PermissionEntry>();
    final tc = r.tool('toolu_014Qx9');
    final cwd = r.session.cwd;
    final r2 = FixtureReplay.replay(<String>['01-connect', '16-elicitation'], untilTag: 'elicitation/create');
    final el = r2.first<ElicitationEntry>();
    return BoardPage(
      number: '26',
      title: 'Awaiting Confirmation',
      source: '客户端本地态（挂起的 permission / elicitation 队列）',
      sections: <BoardSection>[
        BoardSection('卡片下方的等待行', child: BoardStack(<Widget>[PermissionCard(p, toolCall: tc, cwd: cwd), AwaitingRow()], gap: 0)),
        BoardSection('输入框上方的停靠条 · 待授权', child: AwaitingDock.forPending(p, toolCall: tc, cwd: cwd)!),
        BoardSection('输入框上方的停靠条 · 待输入', child: AwaitingDock.forPending(el, agentName: _agentName(r2))!),
      ],
      footnote: '停靠条常驻在输入框上方，Scroll 把转录滚到对应卡片；elicitation 可能是 requestScope（无 sessionId），队列不能只按会话索引（acp-projection.md § 3.2）。',
    );
  }),
  pageBoard('27-elicitation-form', '表单模式交互卡', () {
    final r = FixtureReplay.replay(<String>['01-connect', '16-elicitation'], untilTag: 'elicitation/create');
    final el = r.first<ElicitationEntry>();
    final who = _agentName(r);
    return BoardPage(
      number: '27',
      title: '表单模式交互卡',
      source: 'elicitation/create · mode "form"（requestedSchema：string / enum / array / number / integer / boolean）',
      sections: <BoardSection>[
        BoardSection('默认（已填；Submit 可用）', child: ElicitationFormCard(el, agentName: who)),
        BoardSection(
          '校验态（必填未填，Submit 禁用）',
          child: ElicitationFormCard(el, agentName: who, initialValues: const <String, dynamic>{'env': null, 'concurrency': null}, showValidationInitially: true),
        ),
      ],
      footnote: '回应 { action: "accept", content } / "decline" / "cancel"。未知 type 的属性客户端应忽略该字段；字段标题与描述一律取 schema 的 title / description，不自造文案。',
    );
  }),
  pageBoard('28-elicitation-url', '链接跳转交互卡', () {
    ElicitationEntry url(FixtureReplay r) => r.all<ElicitationEntry>().firstWhere((e) => e.isUrl);
    final a = FixtureReplay.replay(<String>['01-connect', '16-elicitation'], upTo: 4);
    final b = FixtureReplay.replay(<String>['01-connect', '16-elicitation'], upTo: 4);
    b.sessions.pending.markOpened(url(b).requestId);
    // 完成态由 fixtures 的 `elicitation/complete` 通知驱动（R3 补进方法表与 16-elicitation.jsonl）。
    final c = FixtureReplay.replay(<String>['01-connect', '16-elicitation'], untilTag: 'elicitation/complete');
    return BoardPage(
      number: '28',
      title: '链接跳转交互卡',
      source: 'elicitation/create · mode "url"（elicitationId + url）→ elicitation/complete',
      sections: <BoardSection>[
        BoardSection('默认 · Waiting for input', child: ElicitationUrlCard(url(a), agentName: _agentName(a))),
        BoardSection('已打开浏览器 · Waiting for completion...', child: ElicitationUrlCard(url(b), agentName: _agentName(b))),
        BoardSection('完成 · Completed', child: ElicitationUrlCard(url(c), agentName: _agentName(c))),
      ],
      footnote: '完成由 agent 发 elicitation/complete 通知收尾；无会话阶段（requestScope）也可能收到本卡，见画板 52。',
    );
  }),
  pageBoard('29-plan', '计划卡', () {
    final full = FixtureReplay.replay(<String>['01-connect', '17-plan-payloads']);
    final mid = FixtureReplay.replay(<String>['01-connect', '17-plan-payloads'], upTo: 5);
    final cwd = full.session.cwd;
    return BoardPage(
      number: '29',
      title: '计划卡',
      source: 'plan（整份替换）· plan_update（items / file / markdown，带 planId）· plan_removed',
      sections: <BoardSection>[
        BoardSection('展开（Plan · 5 Tasks · 1/5，条目带 status 与 priority）', child: PlanCard(full.session.plans[PlanCardEntry.stablePlanId]!)),
        BoardSection('折叠成 Current: … · N left（停靠在输入框上方）', child: PlanCard(full.session.plans[PlanCardEntry.stablePlanId]!, initiallyCollapsed: true)),
        BoardSection('plan_update · file 载荷', child: PlanCard(full.session.plans['plan_2']!, cwd: cwd)),
        BoardSection('plan_update · markdown 载荷', child: PlanCard(mid.session.plans['plan_3']!)),
        BoardSection(
          '两份计划并存（planId 各自增删）',
          child: BoardStack(<Widget>[
            PlanCard(mid.session.plans['plan_1']!, initiallyCollapsed: true),
            PlanCard(mid.session.plans['plan_3']!),
          ]),
        ),
        BoardSection('一份计划被移除', child: PlanCard(full.session.plans['plan_3']!)),
      ],
      footnote: '稳定版 plan 是整份替换、没有 id；unstable 的 plan_update / plan_removed 才有 planId 与三种载荷，需客户端声明 plan 能力（已裁定声明）。✕ 只隐藏本地呈现，不回写 agent。',
    );
  }),
  pageBoard('30-context-window', '上下文窗口浮窗', () {
    final low = FixtureReplay.replay(<String>['01-connect', '19-usage'], upTo: 1).session.usage;
    final cost = FixtureReplay.replay(<String>['01-connect', '19-usage'], upTo: 2).session.usage;
    final high = FixtureReplay.replay(<String>['01-connect', '19-usage']).session.usage;
    Widget withPopover(Widget popover, Widget strip) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[popover, const SizedBox(height: t.Spacing.s4), strip],
        );
    return BoardPage(
      number: '30',
      title: '上下文窗口浮窗',
      source: 'usage_update（used / size / cost?）',
      sections: <BoardSection>[
        BoardSection('输入框左下的圆环（默认）', child: ComposerUsageStrip(usage: low)),
        BoardSection('悬浮弹层（Context + Rules）', child: withPopover(ContextPopover(usage: low, rulesCount: 1), ComposerUsageStrip(usage: low))),
        BoardSection('带费用时多一行 cost', child: withPopover(ContextPopover(usage: cost, rulesCount: 1), ComposerUsageStrip(usage: cost))),
        BoardSection('高占用（圆环随 used / size 走）', child: ComposerUsageStrip(usage: high)),
      ],
      footnote: 'usage_update 是会话级上下文窗口，不是每轮增量；cost 可选（amount + ISO 4217 currency）。回合级 usage 走 session/prompt 的返回值，落在画板 31 的回合结束行。',
    );
  }),
  pageBoard('31-turn-state', '回合态与结束', () {
    final r = FixtureReplay.replay(<String>['01-connect', '02-turn-read', '03-permission-edit', '04-terminal', '05-elicitation-config', '06-compaction', '07-tolerance', '08-end-turn', '18-stop-reasons']);
    final agent = r.sessions.agents[FixtureReplay.agentId];
    final title = 'New ${agent?.agentTitle ?? agent?.agentName ?? 'Agent'} Session';
    return BoardPage(
      number: '31',
      title: '回合态与结束',
      source: 'stopReason 五种 + end-turn usage（unstable_end_turn_token_usage）· session/cancel',
      sections: <BoardSection>[
        BoardSection(
          '运行中（会话头 spinner + 发送位替换为停止方块）',
          child: BoardStack(<Widget>[SessionHeaderRunning(title: title, note: '会话头在回合进行中出 spinner'), const ComposerRunning()]),
        ),
        BoardSection(
          '五种 stopReason 的结束行',
          child: BoardStack(<Widget>[for (final turn in r.all<TurnEntry>()) TurnEndLine(turn, usage: r.session.usage)], gap: t.Spacing.s4),
        ),
      ],
      footnote: '轮的边界是客户端自己切的（协议流里没有轮开始 / 结束标记）；后四种 stopReason 用 warning / error / 中性徽章与正常结束区分，徽章文字即协议枚举原值。',
    );
  }),
  pageBoard('32-content-blocks', '非文本内容块', () {
    final r = FixtureReplay.replay(<String>['01-connect', '22-content-blocks']);
    final blocks = r.all<MessageEntry>().firstWhere((m) => m.messageId == 'msg_cb1').blocks;
    ContentBlockWire of(ContentBlockType type, {bool blob = false}) =>
        blocks.firstWhere((b) => b.type == type && (type != ContentBlockType.resource || (b.resource?.isBlob ?? false) == blob));
    return BoardPage(
      number: '32',
      title: '非文本内容块',
      source: 'ContentBlock：text / image / audio / resource_link / resource（输出方向没有能力门，必须全部能显示）',
      sections: <BoardSection>[
        BoardSection('image（内嵌预览）', child: ContentBlockView(of(ContentBlockType.image))),
        BoardSection(
          'audio（播放条）',
          child: ContentBlockView(of(ContentBlockType.audio), audioPreview: const AudioPreview(position: Duration(seconds: 14), duration: Duration(seconds: 37))),
        ),
        BoardSection('resource_link（文件卡）', child: ContentBlockView(of(ContentBlockType.resourceLink))),
        BoardSection('embedded resource · text（内嵌展示）', child: ContentBlockView(of(ContentBlockType.resource))),
        BoardSection('embedded resource · blob（不可渲染的兜底文件卡）', child: ContentBlockView(of(ContentBlockType.resource, blob: true))),
      ],
      footnote: 'promptCapabilities 只约束客户端往 session/prompt 塞什么，不约束 agent 发什么；五种块在消息、思考、工具卡内容里都可能出现。图像位是占位，实现里换成真实 base64 预览。',
    );
  }),
  pageBoard('33-compaction', '上下文压缩卡', () {
    CompactionEntry at(int upTo, String id) => FixtureReplay.replay(<String>['01-connect', '20-compaction-states'], upTo: upTo).session.compactions[id]!;
    final failed = FixtureReplay.replay(<String>['01-connect', '20-compaction-states']).session.compactions['cmp_42']!;
    return BoardPage(
      number: '33',
      title: '上下文压缩卡',
      source: 'compaction_update（status / summary? / error?）· compaction_summary_chunk',
      sections: <BoardSection>[
        BoardSection('in_progress（尚无摘要）', child: CompactionCard(at(1, 'cmp_41'))),
        BoardSection('摘要流式追加（compaction_summary_chunk）', child: CompactionCard(at(2, 'cmp_41'))),
        BoardSection('completed', child: CompactionCard(at(4, 'cmp_41'))),
        BoardSection('failed（画板写作 error）', child: CompactionCard(failed)),
      ],
      footnote: 'unstable 变体，需客户端声明 session.compaction（已裁定声明）；摘要按 chunk 追加，卡片高度随之增长。',
    );
  }),
  pageBoard('34-agent-state', 'agent 状态与错误', () {
    final r = FixtureReplay.replay(<String>['01-connect']);
    final agents = r.sessions.agents;
    const id = FixtureReplay.agentId;
    final program = agents[id]?.agentName ?? id;
    AgentConnection state(JsonMap payload) {
      final s = Sessions();
      s.agents.applyInitializeResult(id, agents[id]!.initialize!);
      s.agents.apply(<String, dynamic>{'agentId': id, 'droppedUpdates': 0, ...payload});
      return s.agents[id]!;
    }

    final spawned = state(<String, dynamic>{'state': 'spawned', 'pid': 18324, 'program': program, 'args': <String>[], 'cwd': r.session.cwd});
    final initialized = agents[id]!;
    final authRequired = state(<String, dynamic>{
      'state': 'auth_required',
      'message': 'DEEPSEEK_API_KEY is not configured',
      'authMethods': <JsonMap>[
        <String, dynamic>{'type': 'agent', 'id': 'pro-login', 'name': 'Pro 账号'},
        ...initialized.authMethods,
      ],
    });
    final exited = state(<String, dynamic>{
      'state': 'exited',
      'code': 1,
      'signal': null,
      'stderrTail': 'Error: API key is not set\n    at loadCredentials (auth.ts:42:11)\n    at startAgent (acp-agent.ts:118:5)\nnode:internal/process/promises:391\n    triggerUncaughtException(err, true)',
    });
    return BoardPage(
      number: '34',
      title: 'agent 状态与错误',
      source: 'acp/agent_state（spawned / initialized / auth_required / exited）· 未知变体丢弃告警 · JSON-RPC 错误码',
      sections: <BoardSection>[
        BoardSection('spawned', child: AgentStateBar(spawned)),
        BoardSection('initialized', child: AgentStateBar(initialized)),
        BoardSection('auth_required（列出认证方式入口）', child: AgentStateBar(authRequired)),
        BoardSection('exited（退出码 + stderr 尾巴可展开）', child: AgentStateBar(exited, initiallyExpanded: true)),
        const BoardSection('未知会话更新已丢弃（告警）', child: DroppedUpdatesBar(count: 3)),
      ],
      footnote: 'SessionUpdate 没有 catch-all 变体：未编译的变体（今天是 notice）会让整条通知反序列化失败，用户什么也看不到。核心侧对失败计数并经 acp/agent_state 上抛本条告警，原文落 acp/traffic（acp-projection.md § 8.1）。',
    );
  }),
];
