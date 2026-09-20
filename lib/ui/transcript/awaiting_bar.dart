// 画板 26 · Awaiting Confirmation：挂起的 permission / elicitation 队列（客户端本地态）。
// 卡片下方的等待行（spinner + Awaiting Confirmation）；输入框上方的停靠条（待授权 warning 图标 / 待输入 info 图标 + Scroll）。
// elicitation 可能是 requestScope（无 sessionId），队列不能只按会话索引，停靠条按队列首项显示。

import 'package:flutter/widgets.dart';

import '../../projection/entries.dart';
import '../../theme/tokens.dart' as t;
import 'card_chrome.dart';
import 'icons.dart';
import 'tool_call_card.dart';

/// 卡片下方的等待行。
class AwaitingRow extends StatelessWidget {
  const AwaitingRow({super.key, this.label = 'Awaiting Confirmation'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: t.Controls.standard,
      child: Padding(
        padding: t.Controls.padInput,
        child: Row(
          children: <Widget>[
            const Spinner(),
            const SizedBox(width: t.Spacing.s8),
            Text(label, style: CardText.headerTitle),
          ],
        ),
      ),
    );
  }
}

enum AwaitingKind { permission, input }

/// 输入框上方的停靠条。`onScroll` 把转录滚到对应卡片（R3 接）。
class AwaitingDock extends StatelessWidget {
  const AwaitingDock({super.key, required this.kind, required this.text, this.onScroll});

  final AwaitingKind kind;
  final String text;
  final VoidCallback? onScroll;

  /// 由队列首项生成停靠条：permission → 「Awaiting Permission · 标题 路径」；elicitation → 「Awaiting Input · agent 请求表单填写」。
  static AwaitingDock? forPending(TranscriptEntry? first, {ToolCallEntry? toolCall, String? cwd, String? agentName, VoidCallback? onScroll}) {
    switch (first) {
      case final PermissionEntry p:
        final title = p.toolCallPatch.title ?? toolCall?.title ?? '';
        final path = toolCall == null ? '' : toolSubtitle(toolCall, cwd: cwd);
        return AwaitingDock(kind: AwaitingKind.permission, text: 'Awaiting Permission · $title${path.isEmpty ? '' : ' $path'}', onScroll: onScroll);
      case final ElicitationEntry el:
        final who = agentName ?? el.agentId ?? 'agent';
        return AwaitingDock(kind: AwaitingKind.input, text: 'Awaiting Input · $who ${el.isUrl ? '请求打开链接' : '请求表单填写'}', onScroll: onScroll);
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final icon = kind == AwaitingKind.permission
        ? AcpIcon(AcpIcons.alertTriangle, color: t.Semantic.warning)
        : AcpIcon(AcpIcons.info, color: t.Accent.base);
    return Container(
      decoration: BoxDecoration(color: t.Neutral.panel, borderRadius: t.Radii.card),
      padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
      child: Row(
        children: <Widget>[
          icon,
          const SizedBox(width: t.Spacing.s8),
          Expanded(child: Text(text, style: CardText.headerTitle, maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: t.Spacing.s12),
          AcpButton(label: 'Scroll', kind: ButtonKind.outline, height: t.Controls.compact, onTap: onScroll),
        ],
      ),
    );
  }
}
