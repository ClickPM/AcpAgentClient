// 转录列表：ListView.builder 惰性构建（docs/design.md § 9），按 TranscriptEntry 类型分发到画板 widget；
// 跨消息文本选择用 SelectableRegion。轮开始不出行（画板 10 的 Restore Checkpoint 分隔线已废弃，所有者裁定 2026-09-17：
// 它与画板 11 用户气泡上的 Restore 是同一个动作），轮结束 → 结束行（31）；
// 工具调用按内容分发：子代理（24）> 终端（22 / 23）> diff（21）> 标准卡（18 / 19 / 20）。

import 'dart:math' as math;

import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/widgets.dart';

import '../../app/transcript_folds.dart';
import '../../projection/entries.dart';
import '../../projection/session_store.dart';
import '../../projection/turn_fold.dart';
import '../../theme/tokens.dart' as t;
import '../shell/motion.dart';
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
import 'turn_fold_row.dart';
import 'turn_state.dart';
import 'user_message.dart';

/// 画板 43 的跳转落点：时间线点一行要滚到这个条目上，而惰性列表里只有**建出来的**行才有 RenderObject，
/// 所以给行挂一枚按条目对象取的 `GlobalKey`，跳转时按它拿真实位置（拿不到就说明还没建出来，见
/// `workbench_screen.dart` 的 `_jumpToEntry`）。键按 `TranscriptEntry` 实例取，不按 `entry.id` ——
/// 两个 store 里都有 `msg-1`，按 id 取会在同屏渲染两份转录时撞成重复 GlobalKey。
GlobalObjectKey<State<StatefulWidget>> transcriptRowKey(TranscriptEntry entry) => GlobalObjectKey<State<StatefulWidget>>(entry);

/// 画板 08 B 的滚动锚点要量某一轮的**页脚**位置（折叠块之后、结论之下的那一行），所以结束行也挂一枚
/// 按 [TurnEntry] 实例取的 GlobalKey。与 [transcriptRowKey] 同一条理由：按实例取不按 id，同屏两份转录才不撞。
/// `TurnEntry` 从不出 `EntryRow`（[buildRows] 把它跳过），所以两个键不会取到同一个对象。
GlobalObjectKey<State<StatefulWidget>> turnFooterKey(TurnEntry turn) => GlobalObjectKey<State<StatefulWidget>>(turn);

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

/// 画板 08 B 的摘要行。出在该轮**第一个被折叠的条目**那一位上，所以折叠块永远压在
/// 「用户消息」与「最终助手文本」之间，位置不因折叠改变。
class TurnFoldSummaryRow extends TranscriptRow {
  const TurnFoldSummaryRow(this.fold, {required this.collapsed});

  final TurnFold fold;
  final bool collapsed;
}

/// 把条目列表展开成行：每个已结束的轮在其最后一个条目之后加一行结束行。
/// `TurnEntry` 本身不出行——轮开始不画任何东西（画板 10 的分隔线已废弃，见文件头），它只用来切轮与定位 Restore。
///
/// 画板 08 B：给了 [folds] 就在每轮第一个被折叠的条目前插一行摘要行，[collapsed] 为真时把该轮折叠块里的条目
/// 整批跳过。**运行中的轮不出摘要行**——流式期间过程必须可见，摘要行是 `stop_reason` 到达之后才有的东西。
List<TranscriptRow> buildRows(
  List<TranscriptEntry> entries, {
  Map<String, TurnFold> folds = const <String, TurnFold>{},
  bool Function(TurnFold fold) collapsed = _neverCollapsed,
}) {
  final rows = <TranscriptRow>[];
  TurnEntry? open;
  TurnFold? fold;
  var foldCollapsed = false;
  for (final e in entries) {
    if (e is TurnEntry) {
      if (open != null && !open.isRunning) rows.add(TurnEndRow(open));
      open = e;
      fold = e.isRunning ? null : folds[e.id];
      foldCollapsed = fold != null && collapsed(fold);
      continue;
    }
    if (fold != null && fold.contains(e)) {
      if (identical(e, fold.anchor)) rows.add(TurnFoldSummaryRow(fold, collapsed: foldCollapsed));
      if (foldCollapsed) continue;
    }
    rows.add(EntryRow(e));
  }
  if (open != null && !open.isRunning) rows.add(TurnEndRow(open));
  return rows;
}

bool _neverCollapsed(TurnFold fold) => false;

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
    this.focusedEntryId,
    this.trackRows = false,
    this.folds,
    this.onToggleFold,
  });

  final SessionStore store;

  /// 画板 08 B 的回合折叠。null = 不折叠（gallery 的其它画板、单测里不关心折叠的那些）。
  final TranscriptFolds? folds;

  /// 点摘要行。工作台里接的是 `TranscriptFoldAnchor.toggle`：折 / 展前后要把视口挪回去，让这一轮的
  /// 结论停在原地（画板 08 B「滚动锚点」），而那件事要连自动折叠一起管，所以收在
  /// `lib/app/transcript_fold_anchor.dart`。**不给就退到直接 [TranscriptFolds.toggle]**——
  /// 只翻面、不校正（gallery 与单测里够用）。
  final void Function(TurnFold fold)? onToggleFold;

  /// 画板 43：时间线刚跳过来的那条用户气泡进入画板 11 的「点击聚焦」态；null = 没有。
  final String? focusedEntryId;

  /// 给每行挂 [transcriptRowKey]，让时间线能精确跳到某一条。**只有真正在用的那一份转录该开**
  /// （工作台里那一份）：gallery 与单测里同一个 fixture store 可能同屏渲染两次，开了就是重复 GlobalKey。
  final bool trackRows;

  /// 画板 23 的停止方块：结束该终端里的进程（`terminal_kill`；R4 接线）。
  final void Function(String terminalId)? onKillTerminal;

  /// 跨消息选择的结果（SelectableRegion）。
  final ValueChanged<SelectedContent?>? onSelectionChanged;
  final ScrollController? controller;
  final String? agentName;
  final void Function(String href)? onLink;
  final void Function(String path, int? line)? onGoToFile;
  /// 画板 11 气泡上的 ↺：从这条用户消息截断后原样重发。
  final void Function(MessageEntry message)? onRestore;

  /// 画板 11 编辑态的 Regenerate：从这条用户消息截断后用新文本同会话重发。
  final void Function(MessageEntry message, String text)? onRegenerate;
  final void Function(String requestId, String optionId)? onAnswerPermission;
  final void Function(String requestId, String action, Map<String, dynamic>? content)? onAnswerElicitation;

  @override
  Widget build(BuildContext context) {
    // 队列项的本地态（url 已打开 / 本地 cancelled）只经 PendingQueue 通知，所以三者都听
    // （折叠态是本地的，变了要重排行）。
    final TranscriptFolds? folds = this.folds;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[store, store.pending, ?folds]),
      builder: (context, _) {
        final rows = folds == null
            ? buildRows(store.entries)
            : buildRows(store.entries, folds: foldsOf(store.entries), collapsed: folds.isCollapsed);
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

  Widget buildRow(TranscriptRow row) {
    // 本地一份：字段是可空的，闭包里提升不了。
    final TranscriptFolds? folds = this.folds;
    return switch (row) {
        TurnEndRow(:final turn) => KeyedSubtree(
            key: trackRows ? turnFooterKey(turn) : ValueKey<String>('${turn.id}-end'),
            child: TurnEndLine(turn, usage: store.usage),
          ),
        // 摘要行淡入：只淡入这一块本身，不动周围内容，也不做高度过渡（画板 08 B「动效与滚动」）。
        TurnFoldSummaryRow(:final fold, :final collapsed) => KeyedSubtree(
            key: ValueKey<String>('${fold.turn.id}-fold'),
            child: MotionEnter(
              epoch: fold.turn.id,
              distance: 0,
              duration: t.Motion.fast,
              child: TurnFoldRow(
                fold: fold,
                collapsed: collapsed,
                // 没给 [onToggleFold] 就退到直接翻面（gallery 的样张、不关心滚动校正的单测）：
                // 有 `folds` 却点不动，与画板 08 的样张说明对不上（复审 P2，2026-09-22）。
                onToggle: folds == null ? null : () => (onToggleFold ?? folds.toggle)(fold),
              ),
            ),
          ),
      EntryRow(:final entry) =>
        KeyedSubtree(key: trackRows ? transcriptRowKey(entry) : ValueKey<String>(entry.id), child: buildEntry(entry)),
    };
  }

  Widget buildEntry(TranscriptEntry e) {
    final cwd = store.cwd;
    switch (e) {
      case final MessageEntry m:
        if (m.role != MessageRole.user) return AssistantText(m, onLink: onLink);
        return UserMessage(
          m,
          focused: m.id == focusedEntryId,
          onOpenMention: onLink,
          onRestore: onRestore == null ? null : () => onRestore!(m),
          onRegenerate: onRegenerate == null ? null : (text) => onRegenerate!(m, text),
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
