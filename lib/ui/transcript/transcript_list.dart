// 转录列表：ListView.builder 惰性构建（docs/design.md § 9），按 TranscriptEntry 类型分发到画板 widget；
// 跨消息文本选择用 SelectableRegion。轮开始不出行（画板 10 的 Restore Checkpoint 分隔线已废弃，所有者裁定 2026-09-17：
// 它与画板 11 用户气泡上的 Restore 是同一个动作），轮结束 → 结束行（31）；
// 工具调用按内容分发：子代理（24）> 终端（22 / 23）> diff（21）> 标准卡（18 / 19 / 20）。

import 'dart:math' as math;

import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/widgets.dart';

import '../../projection/entries.dart';
import '../../projection/session_store.dart';
import '../../theme/tokens.dart' as t;
import 'assistant_text.dart';
import 'awaiting_bar.dart';
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

/// 用户消息所属的轮：它前面最近的一条 `TurnEntry`。画板 11 的 Restore / Regenerate 按这轮截断。
TurnEntry? turnOf(List<TranscriptEntry> entries, TranscriptEntry e) {
  for (var i = entries.indexOf(e); i >= 0; i--) {
    final c = entries[i];
    if (c is TurnEntry) return c;
  }
  return null;
}

/// 把条目列表展开成行：每个已结束的轮在其最后一个条目之后加一行结束行。
/// `TurnEntry` 本身不出行——轮开始不画任何东西（画板 10 的分隔线已废弃，见文件头），它只用来切轮与定位 Restore。
List<TranscriptRow> buildRows(List<TranscriptEntry> entries) {
  final rows = <TranscriptRow>[];
  TurnEntry? open;
  for (final e in entries) {
    if (e is TurnEntry) {
      if (open != null && !open.isRunning) rows.add(TurnEndRow(open));
      open = e;
      continue;
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
    this.onRegenerate,
    this.onAnswerPermission,
    this.onAnswerElicitation,
    this.onSelectionChanged,
    this.onKillTerminal,
  });

  final SessionStore store;

  /// 画板 23 的停止方块：结束该终端里的进程（`terminal_kill`；R4 接线）。
  final void Function(String terminalId)? onKillTerminal;

  /// 跨消息选择的结果（SelectableRegion）。
  final ValueChanged<SelectedContent?>? onSelectionChanged;
  final ScrollController? controller;
  final String? agentName;
  final void Function(String href)? onLink;
  final void Function(String path, int? line)? onGoToFile;
  final void Function(TurnEntry turn)? onRestore;

  /// 画板 11 编辑态的 Regenerate：截断该轮后用新文本同会话重发。
  final void Function(TurnEntry turn, String text)? onRegenerate;
  final void Function(String requestId, String optionId)? onAnswerPermission;
  final void Function(String requestId, String action, Map<String, dynamic>? content)? onAnswerElicitation;

  @override
  Widget build(BuildContext context) {
    // 队列项的本地态（url 已打开 / 本地 cancelled）只经 PendingQueue 通知，所以两者都听。
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[store, store.pending]),
      builder: (context, _) {
        final rows = buildRows(store.entries);
        return SelectableRegion(
          selectionControls: emptyTextSelectionControls,
          onSelectionChanged: onSelectionChanged,
          // 滚动区铺满整块面板（左右留白里滚滚轮也要能滚），内容列靠内边距居中到 contentMaxWidth——
          // 不能用 ConstrainedBox 把 ListView 自己夹到 800，那样留白不在滚动命中区里。
          child: LayoutBuilder(
            builder: (context, constraints) {
              final gutter = constraints.hasBoundedWidth ? math.max(0.0, (constraints.maxWidth - t.Geometry.contentMaxWidth) / 2) : 0.0;
              return ListView.builder(
                controller: controller,
                padding: EdgeInsets.fromLTRB(gutter + t.Spacing.s24, t.Spacing.s16, gutter + t.Spacing.s24, t.Spacing.s16),
                itemCount: rows.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: t.Spacing.s4),
                  child: buildRow(rows[i]),
                ),
              );
            },
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
      case final MessageEntry m:
        if (m.role != MessageRole.user) return AssistantText(m, onLink: onLink);
        final turn = turnOf(store.entries, m);
        return UserMessage(
          m,
          onOpenMention: onLink,
          onRestore: onRestore == null || turn == null ? null : () => onRestore!(turn),
          onRegenerate: onRegenerate == null || turn == null ? null : (text) => onRegenerate!(turn, text),
        );
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
          // 画板 28：Open = 打开浏览器 + 本地记已打开 + 首次回 accept（elicitation/create 是 JSON-RPC 请求，必须回应；
          // 再点只是再打开，照 Zed）。Cancel 只在已打开后出现：请求已 accept，没有第二个响应可发，照 Zed 本地标 cancelled。
          return ElicitationUrlCard(
            el,
            agentName: agentName,
            onOpen: () {
              onLink?.call(el.wire.url ?? '');
              if (el.status == PendingStatus.pending) {
                store.pending.markOpened(el.requestId);
                onAnswerElicitation?.call(el.requestId, 'accept', null);
              }
            },
            onCancel: () {
              if (el.status == PendingStatus.pending) {
                onAnswerElicitation?.call(el.requestId, 'cancel', null);
              } else {
                store.pending.cancelRequest(el.requestId, now: store.now);
              }
            },
          );
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
      final buffer = store.terminals.ensure(terminalId);
      return TerminalCard(
        tc,
        buffer: buffer,
        cwd: buffer.cwd ?? cwd,
        // 生来就结束的卡（session/load 回放的历史、滚出视口又滚回来的卡）直接给折叠态，与「跑完自动收起」是同一条规则。
        initiallyExpanded: !tc.isFinished && !buffer.exited,
        onKill: onKillTerminal == null ? null : () => onKillTerminal!(terminalId),
      );
    }
    final diffs = tc.diffs.toList();
    if (diffs.isNotEmpty) {
      return DiffCard(tc, diff: diffs.first, cwd: cwd, onLocate: onGoToFile == null ? null : (p, l) => onGoToFile!(p, l));
    }
    return ToolCallCard(tc, cwd: cwd, onGoToFile: onGoToFile);
  }
}
