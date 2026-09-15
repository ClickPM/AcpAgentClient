// 转录列表：ListView.builder 惰性构建（docs/design.md § 9），按 TranscriptEntry 类型分发到画板 widget；
// 跨消息文本选择用 SelectableRegion。轮边界 → 检查点分隔线（10），轮结束 → 结束行（31）；
// 工具调用按内容分发：子代理（24）> 终端（22 / 23）> diff（21）> 标准卡（18 / 19 / 20）。

import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/widgets.dart';

import '../../projection/entries.dart';
import '../../projection/session_store.dart';
import '../../theme/tokens.dart' as t;
import 'assistant_text.dart';
import 'awaiting_bar.dart';
import 'checkpoint_divider.dart';
import 'compaction_card.dart';
import 'diff_card.dart';
import 'elicitation_form_card.dart';
import 'elicitation_url_card.dart';
import 'permission_card.dart';
import 'plan_card.dart';
import 'subagent_card.dart';
import 'terminal_card.dart';
import 'thinking_block.dart';
import 'tool_call_card.dart';
import 'turn_state.dart';
import 'user_message.dart';

/// 列表行：一个条目，或某轮的结束行。
sealed class TranscriptRow {
  const TranscriptRow();
}

class EntryRow extends TranscriptRow {
  const EntryRow(this.entry);

  final TranscriptEntry entry;
}

class TurnEndRow extends TranscriptRow {
  const TurnEndRow(this.turn);

  final TurnEntry turn;
}

/// 把条目列表展开成行：每个已结束的轮在其最后一个条目之后加一行结束行。
List<TranscriptRow> buildRows(List<TranscriptEntry> entries) {
  final rows = <TranscriptRow>[];
  TurnEntry? open;
  for (final e in entries) {
    if (e is TurnEntry) {
      if (open != null && !open.isRunning) rows.add(TurnEndRow(open));
      open = e;
    }
    rows.add(EntryRow(e));
  }
  if (open != null && !open.isRunning) rows.add(TurnEndRow(open));
  return rows;
}

class TranscriptList extends StatelessWidget {
  const TranscriptList(
    this.store, {
    super.key,
    this.controller,
    this.agentName,
    this.onLink,
    this.onGoToFile,
    this.onRestore,
    this.onAnswerPermission,
    this.onAnswerElicitation,
    this.onSelectionChanged,
  });

  final SessionStore store;

  /// 跨消息选择的结果（SelectableRegion）。
  final ValueChanged<SelectedContent?>? onSelectionChanged;
  final ScrollController? controller;
  final String? agentName;
  final void Function(String href)? onLink;
  final void Function(String path, int? line)? onGoToFile;
  final void Function(TurnEntry turn)? onRestore;
  final void Function(String requestId, String optionId)? onAnswerPermission;
  final void Function(String requestId, String action, Map<String, dynamic>? content)? onAnswerElicitation;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final rows = buildRows(store.entries);
        return SelectableRegion(
          selectionControls: emptyTextSelectionControls,
          onSelectionChanged: onSelectionChanged,
          child: ListView.builder(
            controller: controller,
            padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s24, vertical: t.Spacing.s16),
            itemCount: rows.length,
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.symmetric(vertical: t.Spacing.s4),
              child: buildRow(rows[i]),
            ),
          ),
        );
      },
    );
  }

  Widget buildRow(TranscriptRow row) => switch (row) {
        TurnEndRow(:final turn) => KeyedSubtree(key: ValueKey<String>('${turn.id}-end'), child: TurnEndLine(turn, usage: store.usage)),
        EntryRow(:final entry) => KeyedSubtree(key: ValueKey<String>(entry.id), child: buildEntry(entry)),
      };

  Widget buildEntry(TranscriptEntry e) {
    final cwd = store.cwd;
    switch (e) {
      case final TurnEntry turn:
        return CheckpointDivider(turn: turn, onRestore: onRestore == null ? null : () => onRestore!(turn));
      case final MessageEntry m:
        return m.role == MessageRole.user ? UserMessage(m, onOpenMention: onLink) : AssistantText(m, onLink: onLink);
      case final ThoughtEntry th:
        return ThinkingBlock(th);
      case final ToolCallEntry tc:
        return buildToolCall(tc, cwd);
      case final PlanCardEntry p:
        return p.dismissed ? const SizedBox.shrink() : PlanCard(p, cwd: cwd, onDismiss: () => store.dismissPlan(p.planId), onOpenFile: onLink);
      case final CompactionEntry c:
        return CompactionCard(c);
      case final PermissionEntry p:
        final card = PermissionCard(
          p,
          toolCall: p.toolCallId == null ? null : store.toolCalls[p.toolCallId!],
          cwd: cwd,
          onAnswer: onAnswerPermission == null ? null : (id) => onAnswerPermission!(p.requestId, id),
          onOpenPath: onLink,
        );
        if (p.status != PendingStatus.pending) return card;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: <Widget>[card, const AwaitingRow()]);
      case final ElicitationEntry el:
        if (el.isUrl) {
          return ElicitationUrlCard(el, agentName: agentName, onOpen: () => onLink?.call(el.wire.url ?? ''));
        }
        return ElicitationFormCard(
          el,
          agentName: agentName,
          onAnswer: onAnswerElicitation == null ? null : (action, content) => onAnswerElicitation!(el.requestId, action, content),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget buildToolCall(ToolCallEntry tc, String? cwd) {
    if (tc.isSubagent) return SubagentCard(tc, cwd: cwd, onLink: onLink);
    final terminalId = tc.terminalIds.isEmpty ? null : tc.terminalIds.first;
    if (terminalId != null) {
      return TerminalCard(tc, buffer: store.terminals.ensure(terminalId), cwd: cwd);
    }
    final diffs = tc.diffs.toList();
    if (diffs.isNotEmpty) {
      return DiffCard(tc, diff: diffs.first, cwd: cwd, onLocate: onGoToFile == null ? null : (p, l) => onGoToFile!(p, l));
    }
    return ToolCallCard(tc, cwd: cwd, onGoToFile: onGoToFile);
  }
}
