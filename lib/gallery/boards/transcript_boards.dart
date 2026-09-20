// 画板 11–34 的 gallery 页（R2；10 已废弃）：每张画板一页，复刻设计画板的分节与文案，数据全部来自 test/fixtures 回放
// （lib/gallery/fixtures_source.dart）；协议之外的状态（agent_state、elicitation/complete）在这里用投影层 API 构造。
// 只在 debug / test 编入。

import 'package:flutter/widgets.dart';

import '../../projection/entries.dart';
import '../../theme/tokens.dart' as t;
import '../../ui/transcript/assistant_text.dart';
import '../../ui/transcript/code_block.dart';
import '../../ui/transcript/mermaid_block.dart';
import '../../ui/transcript/thinking_block.dart';
import '../../ui/transcript/user_message.dart';
import '../board_page.dart';
import '../fixtures_source.dart';
import '../gallery.dart';

/// flutter_tester 不做平台字体回退，Mermaid 主题只能给一个家族名：gallery 里用随包的 Noto Sans SC
/// （即 tokens 的 `Fonts.cjkFallback` 首项，真机用 `Fonts.sans` + 平台回退），不再依赖本机的微软雅黑。
const String galleryMermaidFont = 'Noto Sans SC';

/// 取 Markdown 文本里第一个围栏的正文。
String fenceBody(String md) {
  final m = RegExp(r'```[^\n]*\n([\s\S]*?)```').firstMatch(md);
  return m?.group(1) ?? md;
}

MessageEntry _agentMessage(FixtureReplay r, String messageId) =>
    r.all<MessageEntry>().firstWhere((m) => m.messageId == messageId && m.role == MessageRole.agent);

MessageEntry _userMessage(FixtureReplay r, String messageId) =>
    r.all<MessageEntry>().firstWhere((m) => m.messageId == messageId && m.role == MessageRole.user);

GalleryBoard _page(String id, String title, Widget Function() build) =>
    GalleryBoard(id: id, title: title, frame: const Size(BoardPage.width, 0), fitContent: true, build: (_) => build());

// 画板 10（Restore Checkpoint 分隔线）已废弃（所有者裁定 2026-09-17）：它点下去与画板 11 用户气泡上的 Restore
// 是同一个动作（本地截断 + 同会话重发），且工作台画板 01 / 02 / 03 的转录里本来就没有这条线。对照页一并撤掉。
final List<GalleryBoard> transcriptBoards = <GalleryBoard>[
  _page('11-user-message', '用户消息气泡', () {
    final r = FixtureReplay.replay(<String>['01-connect', '11-rich-text']);
    final msg = _userMessage(r, 'msg_u2');
    return BoardPage(
      number: '11',
      title: '用户消息气泡',
      source: 'user_message_chunk（content: ContentBlock）· 消息边界与分组为客户端本地态',
      sections: <BoardSection>[
        BoardSection('默认（@ 提及芯片可点，落右栏文件面板）', child: UserMessage(msg)),
        BoardSection('点击聚焦', child: UserMessage(msg, initialState: UserMessageState.focused)),
        BoardSection(
          '悬浮出 Edit · Copy · Restore',
          child: Padding(
            padding: const EdgeInsets.only(top: t.Spacing.s12),
            child: UserMessage(msg, initialState: UserMessageState.hovered),
          ),
        ),
        BoardSection('编辑中（改文本 → Regenerate 截断后续并重起一轮）', child: UserMessage(msg, initialState: UserMessageState.editing)),
        BoardSection(
          '@ 提及芯片 · 默认 / 悬浮（等宽 12.5 · accent 文字 · accent.soft 底 · 圆角 3 · 悬浮出 6% 深色容器）',
          child: Row(
            children: <Widget>[
              const MentionChip(label: '@scripts/validate.ps1'),
              const SizedBox(width: t.Spacing.s16),
              const MentionChip(label: '@scripts/validate.ps1', hoveredInitially: true),
              const SizedBox(width: t.Spacing.s16),
              Text('左：默认 · 右：悬浮', style: t.TextStyles.secondary),
            ],
          ),
        ),
      ],
      footnote: 'chunk 流里只有可选 messageId；把连续 chunk 合成一条气泡的规则由客户端定（acp-projection.md § 7 第 2 条）。',
    );
  }),
  _page('12-assistant-text', '助手富文本正文', () {
    final r = FixtureReplay.replay(<String>['01-connect', '11-rich-text']);
    return BoardPage(
      number: '12',
      title: '助手富文本正文',
      source: 'agent_message_chunk · ContentBlock text（Markdown / GFM）',
      sections: <BoardSection>[
        BoardSection('标题 · 段落 · 有序无序列表 · 任务清单 · 行内代码 · 引用 · 文件链接 · 分割线 · 删除线', child: AssistantText(_agentMessage(r, 'msg_r1'), onLink: (_) {})),
      ],
      footnote: '文件链接与任务清单复选框可点：链接落右栏文件面板，复选框只改本地呈现态，不回写 agent。',
    );
  }),
  _page('13-code-block', '代码块卡片', () {
    final r = FixtureReplay.replay(<String>['01-connect', '11-rich-text']);
    final code = fenceBody(_agentMessage(r, 'msg_r2').text);
    final longLine = fenceBody(_agentMessage(r, 'msg_r3').text);
    return BoardPage(
      number: '13',
      title: '代码块卡片',
      source: 'agent_message_chunk · text（fenced code block）',
      sections: <BoardSection>[
        BoardSection('默认（语言标签 + Copy）', child: CodeBlock(code: code, language: 'powershell')),
        BoardSection(
          'Copy 点击后变 Copied',
          child: CodeBlock(code: code.split('\n').where((l) => l.contains('Write-Host')).join('\n'), language: 'powershell', copiedInitially: true),
        ),
        BoardSection('长行横向滚动（不换行，出横向滚动条）', child: CodeBlock(code: longLine, language: 'powershell')),
      ],
      footnote: '语法着色只用中性色阶 + accent（关键字）+ success（字符串）+ warning（类型 / 数字）+ n.placeholder（注释），不引入表外色相。',
    );
  }),
  _page('14-gfm-table', 'GFM 表格', () {
    final r = FixtureReplay.replay(<String>['01-connect', '11-rich-text']);
    return BoardPage(
      number: '14',
      title: 'GFM 表格',
      source: 'agent_message_chunk · text（GFM table）',
      sections: <BoardSection>[
        BoardSection('列对齐（左 / 左 / 居中 / 右）· 斑马纹 · 超宽时横向滚动', child: AssistantText(_agentMessage(r, 'msg_r4'))),
      ],
      footnote: '表头用 surface #eeeef1，斑马行用 panel #f4f4f6；数字列开 tabular-nums。',
    );
  }),
  _page('15-mermaid', 'Mermaid 图', () {
    final r = FixtureReplay.replay(<String>['01-connect', '11-rich-text']);
    final msg = _agentMessage(r, 'msg_r5');
    return BoardPage(
      number: '15',
      title: 'Mermaid 图',
      source: 'agent_message_chunk · text（```mermaid 围栏，客户端渲染）',
      sections: <BoardSection>[
        BoardSection('图形态', child: AssistantText(msg, mermaidFontFamily: galleryMermaidFont)),
        BoardSection('源码态', child: MermaidBlock(source: fenceBody(msg.text).trimRight(), initialView: MermaidView.source, fontFamily: galleryMermaidFont)),
      ],
      footnote: '渲染在客户端完成；节点只用中性色阶的两级表面，不引入配色。',
    );
  }),
  _page('16-math', '数学公式', () {
    final r = FixtureReplay.replay(<String>['01-connect', '11-rich-text']);
    return BoardPage(
      number: '16',
      title: '数学公式',
      source: 'agent_message_chunk · text（LaTeX，客户端渲染）',
      sections: <BoardSection>[
        BoardSection('行内公式 + 块级公式', child: AssistantText(_agentMessage(r, 'msg_r6'))),
      ],
      footnote: '公式用等宽 + 斜体变量；块级公式上下各留 12，用发丝线与正文分隔；数字开 tabular-nums。',
    );
  }),
  _page('17-thinking', '思考折叠块', () {
    final streaming = FixtureReplay.replay(<String>['01-connect', '12-thinking'], upTo: 4);
    final done = FixtureReplay.replay(<String>['01-connect', '12-thinking']);
    return BoardPage(
      number: '17',
      title: '思考折叠块',
      source: 'agent_thought_chunk（纯流；折叠单元是客户端本地态）',
      sections: <BoardSection>[
        BoardSection('流式中', child: ThinkingBlock(streaming.first<ThoughtEntry>())),
        BoardSection('结束折叠', child: ThinkingBlock(done.first<ThoughtEntry>())),
        BoardSection('展开', child: ThinkingBlock(done.first<ThoughtEntry>(), initiallyExpanded: true)),
      ],
      footnote: '思考块没有「一段思考」的协议边界，分段与折叠规则由客户端定（acp-projection.md § 7 第 6 条）；耗时是客户端本地打的时间戳。',
    );
  }),
];
