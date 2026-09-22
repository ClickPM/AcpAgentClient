// 画板 08 B「回合结束后，过程默认折叠为一行摘要」的分组规则。纯 Dart，不依赖 widget——
// 转录列表（lib/ui/transcript/transcript_list.dart）按它决定哪些条目收进折叠块、摘要行放在哪一位。
//
// 折叠范围照画板 08 的「折叠范围与例外」表：
// - **折叠**：思考 / 工具调用（含 diff / 终端 / 子代理）/ 压缩标记，外加**工具调用之间穿插的 agent 文本**。
// - **不折叠**：用户消息、该回合**最后一段连续的 agent 文本**、回合页脚（页脚不是条目，由列表另外出行）、
//   Plan 条与检查点标记（画板 29 / 10 的常驻元素，不属于某一回合的过程）。
// - **偏离（画板未写）**：权限卡与 elicitation 卡不折叠。画板的两列都没列到它们；挂起的那张必须看得见，
//   已回应的那张是「授权过什么」的记录，藏起来不合适。记 rounds/round-board-08 任务卡，待所有者确认。
//
// 「最后一段连续的 agent 文本」= 从回合末尾往前数，直到遇上第一个非 agent-文本的块为止的那一段
// （所有者裁定 2026-09-22）。一个回合里 agent 文本可能有好几段，只有最后这一段是结论。

import 'entries.dart';

/// 一个回合的折叠分组结果。
class TurnFold {
  TurnFold({
    required this.turn,
    required this.folded,
    required this.toolCalls,
    required this.failures,
    required this.cancelled,
  }) : _folded = Set<TranscriptEntry>.identity()..addAll(folded);

  /// [contains] 的索引：转录行是逐行问的，用 identity set 而不是在 [folded] 上线性找。
  final Set<TranscriptEntry> _folded;

  final TurnEntry turn;

  /// 进折叠块的条目，按原顺序。摘要行出在**第一条**的位置上（画板：折叠块永远压在用户消息与最终助手文本之间）。
  final List<TranscriptEntry> folded;

  /// 「N 次工具调用」：折叠块里的 `tool_call` 块数，失败与取消计入。
  final int toolCalls;

  /// 「N 项失败」：折叠块里 `failed` 的工具调用数。取消**不**算失败（它有自己的一列）。
  final int failures;

  /// 折叠块里被取消的工具调用数。只用于判「不自动折叠」，不出现在摘要行上。
  final int cancelled;

  /// 「N 条消息」：折叠块里的块数（含思考块与中间的 agent 文本段）。
  int get messages => folded.length;

  /// 一条都没收进来就不渲染摘要行（画板：不渲染空的「处理详情 · 0 条消息」）。
  bool get isEmpty => folded.isEmpty;

  /// 折叠块的第一条：摘要行插在它前面。
  TranscriptEntry get anchor => folded.first;

  /// 这一轮可不可以**自动**折叠。含失败 / 被取消 / 出错的回合保持展开（画板：不藏坏消息；用户仍可手动折叠）。
  /// `max_tokens` / `refusal` 不在此列：它们是协议给的正常结束值，画板 31 的页脚本来就会标出来，而页脚不参与折叠。
  bool get autoCollapsible =>
      !turn.isRunning && failures == 0 && cancelled == 0 && turn.error == null && turn.stopReason != 'cancelled';

  /// 本回合的条目属不属于折叠块（列表折叠态据此跳过）。
  bool contains(TranscriptEntry e) => _folded.contains(e);
}

/// 这一类条目本身就是「过程」，一律进折叠块。agent 文本另算（要先分出最后一段连续的那一段）。
bool _isProcess(TranscriptEntry e) => e is ThoughtEntry || e is ToolCallEntry || e is CompactionEntry;

bool _isAgentText(TranscriptEntry e) => e is MessageEntry && e.role == MessageRole.agent;

/// 把整份转录按轮切开，算出每轮的折叠分组。只有**产生了折叠块**的轮才进结果。
/// 键是 `TurnEntry.id`——它是本地序号，同一个 store 里唯一。
Map<String, TurnFold> foldsOf(List<TranscriptEntry> entries) {
  final out = <String, TurnFold>{};
  TurnEntry? open;
  var bucket = <TranscriptEntry>[];
  void close() {
    final t = open;
    if (t == null) return;
    final fold = foldOfTurn(t, bucket);
    if (fold != null) out[t.id] = fold;
  }

  for (final e in entries) {
    if (e is TurnEntry) {
      close();
      open = e;
      bucket = <TranscriptEntry>[];
      continue;
    }
    if (open != null) bucket.add(e);
  }
  close();
  return out;
}

/// 这个条目被收进了哪一轮的折叠块（都没有就回 null）。画板 43 的时间线跳转要先展开目标所在的那一轮。
TurnFold? foldContaining(Iterable<TurnFold> folds, TranscriptEntry e) {
  for (final f in folds) {
    if (f.contains(e)) return f;
  }
  return null;
}

/// 单个回合的分组。`body` 是这一轮里的条目（不含 [TurnEntry] 本身），按到达顺序。
/// 没有任何可折叠的块时回 null（那一轮不出摘要行）。
TurnFold? foldOfTurn(TurnEntry turn, List<TranscriptEntry> body) {
  // 从末尾往前数出「最后一段连续的 agent 文本」，它不参与折叠。
  var tail = body.length;
  while (tail > 0 && _isAgentText(body[tail - 1])) {
    tail--;
  }

  final folded = <TranscriptEntry>[];
  var toolCalls = 0;
  var failures = 0;
  var cancelled = 0;
  for (var i = 0; i < tail; i++) {
    final e = body[i];
    if (!_isProcess(e) && !_isAgentText(e)) continue;
    folded.add(e);
    if (e is ToolCallEntry) {
      toolCalls++;
      switch (e.displayStatus) {
        case ToolDisplayStatus.failed:
          failures++;
        case ToolDisplayStatus.cancelled:
          cancelled++;
        case ToolDisplayStatus.pending:
        case ToolDisplayStatus.inProgress:
        case ToolDisplayStatus.completed:
          break;
      }
    }
  }
  if (folded.isEmpty) return null;
  return TurnFold(turn: turn, folded: folded, toolCalls: toolCalls, failures: failures, cancelled: cancelled);
}
