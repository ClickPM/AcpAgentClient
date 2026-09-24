// 画板 08 B「回合结束后，过程默认折叠为一行摘要」的分组规则。纯 Dart，不依赖 widget——
// 转录列表（lib/ui/transcript/transcript_list.dart）按它决定哪些条目收进折叠块、摘要行放在哪一位。
//
// 折叠范围照画板 08 的「折叠范围与例外」表：
// - **折叠**：思考 / 工具调用（含 diff / 终端 / 子代理）/ 压缩标记，外加**工具调用之间穿插的 agent 文本**。
// - **整轮不自动折叠**：还在跑 / 被取消 / 本地出错的回合（见 [TurnFold.autoCollapsible]）。含失败工具调用
//   但正常收轮的回合**照常折叠**，失败数留在摘要行上（所有者裁定 2026-09-22）。
// - **不折叠**：用户消息、该回合**最后一段连续的 agent 文本**、回合页脚（页脚不是条目，由列表另外出行）、
//   Plan 条与检查点标记（画板 29 / 10 的常驻元素，不属于某一回合的过程）。
// - **偏离（画板未写）**：权限卡与 elicitation 卡不折叠。画板的两列都没列到它们；挂起的那张必须看得见，
//   已回应的那张是「授权过什么」的记录，藏起来不合适。记 rounds/round-board-08 任务卡，待所有者确认。
//
// 「最后一段连续的 agent 文本」= 从回合末尾往前数，直到遇上第一个非 agent-文本的块为止的那一段
// （所有者裁定 2026-09-22）。一个回合里 agent 文本可能有好几段，只有最后这一段是结论。
//
// **收轮之后才到的条目不进折叠块**（iteration-15，所有者报障 2026-09-24，记 design/DIVERGENCE.md）：
// agent 可以在 `session/prompt` 已经回了 `stopReason` 之后接着推 update（Claude Code 的后台命令 / 后台子代理
// 跑完把它唤醒，实测一次收轮后又跑了 10 分钟），这些条目仍排在这一轮里。只拿**收轮那一刻已有的条目**
// （`at` 不晚于 [TurnEntry.endedAt]）算折叠与「最后一段」：否则末尾换成新来的工具调用，原来的结论跟着被折进去，
// 新来的那些又全藏在一个已经收起的折叠块里，界面上看起来是「收轮了、却没有结论」。
// 收轮之后的条目按到达顺序排在结论后面照常显示，回合页脚仍在整轮最后。
//
// **轮的切分**（所有者裁定 2026-09-22）：有 [TurnEntry] 就按轮边界，没有就退到**顶层用户消息**。
// 轮边界只有我们自己 `session/prompt` 时才放，`session/load` 重放回来的历史一条都没有（R6 裁定，
// docs/design.md § 3），只认轮边界的话重开应用后整份历史都不会折（所有者报障 2026-09-22）。
// 同一口径画板 43 的会话时间线先用过（lib/projection/timeline.dart），Restore 的截断点也是它。
// 代价：历史轮没有 [TurnEntry]，摘要行第二行的模型名与回合页脚都没有数据源——摘要行退化成单行
// （画板 08 本来就画了这个退化态），页脚不出。记 design/DIVERGENCE.md。

import 'entries.dart';

/// 一个回合的折叠分组结果。
class TurnFold {
  TurnFold({
    required this.owner,
    required this.turn,
    required this.folded,
    required this.toolCalls,
    required this.failures,
    required this.cancelled,
  }) : _folded = Set<TranscriptEntry>.identity()..addAll(folded);

  /// [contains] 的索引：转录行是逐行问的，用 identity set 而不是在 [folded] 上线性找。
  final Set<TranscriptEntry> _folded;

  /// 这一轮的身份：实时轮是它的 [TurnEntry]，重放回来的历史轮是那条顶层用户消息（见文件头）。
  /// [foldsOf] 的键、摘要行的行 id、折叠态的记法（`TranscriptFolds` 的 Expando）全按它。
  final TranscriptEntry owner;

  /// 轮边界本身。**重放回来的历史轮没有**：模型名、`stopReason`、回合级 usage 那时都取不到。
  final TurnEntry? turn;

  /// 进折叠块的条目，按原顺序。摘要行出在**第一条**的位置上（画板：折叠块永远压在用户消息与最终助手文本之间）。
  final List<TranscriptEntry> folded;

  /// 「N 次工具调用」：折叠块里的 `tool_call` 块数，失败与取消计入。
  final int toolCalls;

  /// 「N 项失败」：折叠块里 `failed` 的工具调用数。取消**不**算失败（它有自己的一列）。
  /// 只喂摘要行上那一段红字，**不再参与** [autoCollapsible]（所有者裁定 2026-09-22）。
  final int failures;

  /// 折叠块里被取消的工具调用数。只用于判「不自动折叠」，不出现在摘要行上。
  final int cancelled;

  /// [foldsOf] 的键，也是摘要行行 id 的前缀（`<id>-fold`）。
  String get id => owner.id;

  /// 摘要行第二行的模型名（回合开始那一刻的快照）。重放历史轮取不到，摘要行退化成单行。
  String? get model => turn?.model;

  /// 这一轮还在跑。重放回来的历史轮永远是假——它记的是已经结束的事。
  bool get isRunning => turn?.isRunning ?? false;

  /// 「N 条消息」：折叠块里的块数（含思考块与中间的 agent 文本段）。
  int get messages => folded.length;

  /// 一条都没收进来就不渲染摘要行（画板：不渲染空的「处理详情 · 0 条消息」）。
  bool get isEmpty => folded.isEmpty;

  /// 折叠块的第一条：摘要行插在它前面。
  TranscriptEntry get anchor => folded.first;

  /// 这一轮可不可以**自动**折叠。只有**没走到结束值**的回合保持展开：还在跑、被取消（本地标的工具卡，或
  /// `stop_reason == 'cancelled'`）、本地出错（[TurnEntry.error]）——那几种情况下过程就是现场；用户仍可手动折叠。
  ///
  /// **含失败工具调用、但正常收轮的回合照常折叠**（所有者裁定 2026-09-22，画板 08 已同步）：跑到了结论就收起来，
  /// 坏消息不藏——摘要行上的「N 项失败」照出，不必把整段过程摊开。
  /// `max_tokens` / `refusal` 同样照常折叠：它们是协议给的正常结束值，画板 31 的页脚本来就会标出来，而页脚不参与折叠。
  ///
  /// 重放回来的历史轮（[turn] 为 null）落在「可折」这一侧：重放里那三个拦住自动折叠的信号一个都回不来，
  /// 而它记的本就是已经结束的事。
  bool get autoCollapsible =>
      !isRunning && cancelled == 0 && turn?.error == null && turn?.stopReason != 'cancelled';

  /// 本回合的条目属不属于折叠块（列表折叠态据此跳过）。
  bool contains(TranscriptEntry e) => _folded.contains(e);
}

/// 这一类条目本身就是「过程」，一律进折叠块。agent 文本另算（要先分出最后一段连续的那一段）。
bool _isProcess(TranscriptEntry e) => e is ThoughtEntry || e is ToolCallEntry || e is CompactionEntry;

bool _isAgentText(TranscriptEntry e) => e is MessageEntry && e.role == MessageRole.agent;

/// 没有轮边界时的轮起点：**顶层**用户消息。子代理卡里嵌套的消息不算——正常情况下它们在
/// `ToolCallEntry.children` 里、压根不在顶层列表，父卡建不出来时才会落回来（同 `buildTimeline` 的口径）。
bool isTurnStart(TranscriptEntry e) =>
    e is MessageEntry && e.role == MessageRole.user && e.parentToolCallId == null;

/// 把整份转录按轮切开，算出每轮的折叠分组。只有**产生了折叠块**的轮才进结果。
/// 键是 [TurnFold.id]——实时轮是 `TurnEntry.id`，重放历史轮是那条用户消息的 id，都是本地序号、同一个 store 里唯一。
Map<String, TurnFold> foldsOf(List<TranscriptEntry> entries) {
  final out = <String, TurnFold>{};
  TurnEntry? turn;
  TranscriptEntry? owner;
  var bucket = <TranscriptEntry>[];
  void close() {
    final o = owner;
    if (o == null) return;
    final fold = foldOfTurn(o, bucket, turn: turn);
    if (fold != null) out[o.id] = fold;
  }

  for (final e in entries) {
    if (e is TurnEntry) {
      close();
      turn = e;
      owner = e;
      bucket = <TranscriptEntry>[];
      continue;
    }
    // 轮边界缺席时（重放历史）按顶层用户消息开一轮。实时轮里那条本地回显的用户消息紧跟在自己的
    // 轮边界之后，`turn != null` 拦住它，不会把同一轮切成两半。
    if (turn == null && isTurnStart(e)) {
      close();
      owner = e;
      bucket = <TranscriptEntry>[];
      continue;
    }
    if (owner != null) bucket.add(e);
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

/// 单个回合的分组。[owner] 是这一轮的身份（轮边界，或没有轮边界时那条顶层用户消息），
/// `body` 是这一轮里的条目（不含 [owner] 本身），按到达顺序。
/// 没有任何可折叠的块时回 null（那一轮不出摘要行）。
///
/// 已收轮的实时轮只看收轮那一刻已有的条目（见文件头）；重放回来的历史轮没有 [turn]，整段都算。
TurnFold? foldOfTurn(TranscriptEntry owner, List<TranscriptEntry> body, {TurnEntry? turn}) {
  final DateTime? endedAt = turn?.endedAt;
  final settled = endedAt == null ? body : <TranscriptEntry>[for (final e in body) if (!e.at.isAfter(endedAt)) e];

  // 从末尾往前数出「最后一段连续的 agent 文本」，它不参与折叠。
  var tail = settled.length;
  while (tail > 0 && _isAgentText(settled[tail - 1])) {
    tail--;
  }

  final folded = <TranscriptEntry>[];
  var toolCalls = 0;
  var failures = 0;
  var cancelled = 0;
  for (var i = 0; i < tail; i++) {
    final e = settled[i];
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
  return TurnFold(
    owner: owner,
    turn: turn,
    folded: folded,
    toolCalls: toolCalls,
    failures: failures,
    cancelled: cancelled,
  );
}
