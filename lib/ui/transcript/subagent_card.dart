// 画板 24 · 子代理委派卡：只按 docs/design.md § 4 的入站 _meta 键分组（claudeCode.parentToolUseId / claudeCode.subagent /
// dsh_subagent），代码里没有 agent 名。进行中 = spinner + 停止方块；完成后展开 = 嵌套工具行 · ↳ Subagent Output · 反馈图标。
// dsh 把子代理转录折进父卡 content[]，这里当作输出正文显示。

import 'package:flutter/widgets.dart';

import '../../projection/entries.dart';
import '../../projection/wire.dart';
import '../../theme/tokens.dart' as t;
import 'assistant_text.dart';
import 'card_chrome.dart';
import 'icons.dart';
import 'markdown_body.dart';
import 'terminal_card.dart';
import 'thinking_block.dart';
import 'tool_call_card.dart';

class SubagentCard extends StatefulWidget {
  const SubagentCard(this.entry, {super.key, this.cwd, this.initiallyExpanded, this.onStop, this.onLink});

  final ToolCallEntry entry;
  final String? cwd;

  /// 缺省：完成后展开、进行中折叠。
  final bool? initiallyExpanded;
  final VoidCallback? onStop;
  final LinkCallback? onLink;

  @override
  State<SubagentCard> createState() => _SubagentCardState();
}

class _SubagentCardState extends State<SubagentCard> {
  late bool _expanded = widget.initiallyExpanded ?? widget.entry.isFinished;

  Widget _outputLabel() => Row(
        children: <Widget>[
          AcpIcon(AcpIcons.cornerDownRight, color: t.Neutral.muted, size: t.IconSizes.toolbar),
          const SizedBox(width: t.Spacing.s4),
          Text('Subagent Output', style: CardText.secondary),
        ],
      );

  List<Widget> _children(ToolCallEntry e, bool hasOutput) {
    final out = <Widget>[];
    var labelled = false;
    for (final c in e.children) {
      switch (c) {
        case final ToolCallEntry tool:
          out.add(ToolCallCard(tool, cwd: widget.cwd));
        case final ThoughtEntry th:
          out.add(ThinkingBlock(th));
        case final MessageEntry m:
          if (!labelled) {
            out.add(_outputLabel());
            labelled = true;
          }
          out.add(AssistantText(m, onLink: widget.onLink));
        default:
          break;
      }
    }
    // dsh 把子代理转录折进父卡 content[]（没有嵌套 MessageEntry）时，标签放在 content 正文之前。
    if (!labelled && hasOutput) out.add(_outputLabel());
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final running = !e.isFinished;
    final contentText = e.content
        .map((c) => c.content)
        .whereType<ContentBlockWire>()
        .where((b) => b.type == ContentBlockType.text)
        .map((b) => b.text ?? '')
        .join('\n');
    final hasOutput = e.children.any((c) => c is MessageEntry) || contentText.isNotEmpty;
    final hasBody = e.children.isNotEmpty || contentText.isNotEmpty;
    return TranscriptCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CardHeader(
            leading: running ? Spinner(size: t.IconSizes.base) : ToolStatusIcon(e.displayStatus),
            title: e.title,
            trailing: <Widget>[
              if (running) StopSquareButton(onTap: widget.onStop),
              Chevron(expanded: _expanded),
            ],
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded && hasBody)
            CardBody(
              padding: const EdgeInsets.all(t.Spacing.s12),
              children: <Widget>[
                // 嵌套条目按到达顺序：工具行 / 思考块（审查 P2：投影已分组的 ThoughtEntry 不能丢）/ 输出前先给「↳ Subagent Output」。
                ..._children(e, hasOutput),
                if (contentText.isNotEmpty) MarkdownBody(contentText, onLink: widget.onLink),
                if (hasOutput) ...<Widget>[
                  const Row(
                    children: <Widget>[
                      IconButtonGhost(icon: AcpIcons.thumbsUp, size: t.Controls.compact),
                      IconButtonGhost(icon: AcpIcons.thumbsDown, size: t.Controls.compact),
                      IconButtonGhost(icon: AcpIcons.copy, size: t.Controls.compact),
                      IconButtonGhost(icon: AcpIcons.externalLink, size: t.Controls.compact),
                    ],
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }
}
