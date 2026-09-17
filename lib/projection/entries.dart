// 转录条目模型（R2）。docs/acp-projection.md § 7 的 8 项自造态全部落在这些呈现态字段上：
// ① 工具调用的本地 cancelled（ToolCallEntry.cancelledLocally）② 消息分组（MessageEntry.messageId 与角色连续合并）
// ③ 本地时间戳（每个条目的 at / updatedAt）④ 先到的 tool_call_update 凭空建卡（ToolCallEntry.createdFromUpdate）
// ⑤ 终端释放后输出留存（TerminalBuffer 跟卡走，见 tool_calls.dart）⑥ 思考折叠单元（ThoughtEntry）⑦ 轮边界（TurnEntry）
// ⑧ 用户消息的本地回显（MessageEntry.optimistic）。
// 纯 Dart，不依赖 widget；规则来自 prototype/assets/projection.js，只搬规则不搬代码。

import 'wire.dart';

enum MessageRole { user, agent }

/// 转录里的一条投影块。`id` 是本地序号（不是协议 id），`at` 是本地时间戳（§ 7 第 3 条）。
abstract class TranscriptEntry {
  TranscriptEntry({required this.id, required this.at});

  final String id;
  final DateTime at;

  /// 归属的父工具调用（子代理卡里的嵌套条目，画板 24）；顶层条目为 null。
  String? get parentToolCallId => null;
}

/// 用户 / 助手消息：连续 chunk 合成一条气泡（§ 7 第 2 条）。
class MessageEntry extends TranscriptEntry {
  MessageEntry({required super.id, required super.at, required this.role, this.messageId, this.parentToolCallId, this.optimistic = false})
      : updatedAt = at;

  final MessageRole role;

  /// 协议 messageId；本地回显的那条先是 null，agent 回显同一批块时认领回来（§ 7 第 8 条）。
  String? messageId;

  /// § 7 第 8 条：`session/prompt` 发出时本地回显的用户气泡（不是 agent 发来的）。
  final bool optimistic;
  @override
  final String? parentToolCallId;
  final List<ContentBlockWire> blocks = <ContentBlockWire>[];
  DateTime updatedAt;

  /// 所有 text 块拼接（Markdown 渲染的输入）。
  String get text => blocks.where((b) => b.type == ContentBlockType.text).map((b) => b.text ?? '').join();
}

/// 思考折叠单元（§ 7 第 6 条）：连续 agent_thought_chunk 合成一段，其它条目到达或轮结束时关闭。
class ThoughtEntry extends TranscriptEntry {
  ThoughtEntry({required super.id, required super.at, this.parentToolCallId}) : updatedAt = at;

  @override
  final String? parentToolCallId;
  final List<ContentBlockWire> blocks = <ContentBlockWire>[];
  DateTime updatedAt;
  bool closed = false;

  Duration get elapsed => updatedAt.difference(at);
  String get text => blocks.where((b) => b.type == ContentBlockType.text).map((b) => b.text ?? '').join();
}

/// `ToolKind`：Rust 侧 `#[serde(other)]`，未知值落 [other]。
enum ToolKind {
  read('read'),
  edit('edit'),
  delete('delete'),
  move('move'),
  search('search'),
  execute('execute'),
  think('think'),
  fetch('fetch'),
  switchMode('switch_mode'),
  other('other');

  const ToolKind(this.wire);

  final String wire;

  static ToolKind? tryParse(String? wire) {
    for (final k in values) {
      if (k.wire == wire) return k;
    }
    return null;
  }
}

/// `ToolCallStatus`：没有 cancelled，也没有 catch-all（未知值让整条通知丢弃，§ 8.1）。
enum ToolStatus {
  pending('pending'),
  inProgress('in_progress'),
  completed('completed'),
  failed('failed');

  const ToolStatus(this.wire);

  final String wire;

  static ToolStatus? tryParse(String? wire) {
    for (final s in values) {
      if (s.wire == wire) return s;
    }
    return null;
  }
}

/// 呈现用状态 = 协议状态 + 本地 cancelled（§ 7 第 1 条）。
enum ToolDisplayStatus { pending, inProgress, completed, failed, cancelled }

class ToolCallEntry extends TranscriptEntry {
  ToolCallEntry({
    required super.id,
    required super.at,
    required this.toolCallId,
    required this.title,
    this.parentToolCallId,
    this.isSubagent = false,
    this.createdFromUpdate = false,
  }) : updatedAt = at;

  final String toolCallId;
  String title;
  String? name;
  ToolKind kind = ToolKind.other;

  /// 未知 kind 落 other 时保留原文（调试 / 流量面板用）。
  String? rawKind;
  ToolStatus status = ToolStatus.pending;
  List<ToolCallContentWire> content = const <ToolCallContentWire>[];

  /// `content[]` 里被逐项跳过的未知项数（§ 8.3）。
  int skippedContent = 0;
  List<ToolCallLocationWire> locations = const <ToolCallLocationWire>[];
  Object? rawInput;
  Object? rawOutput;

  /// 创建时（`tool_call`）自带的 `_meta`，原样保留；update 的 `_meta` 不并进来（sdk `ToolCall::update` 语义）。
  JsonMap? meta;

  /// § 7 第 1 条：发出 session/cancel 后本地标记，协议里没有这个状态。
  bool cancelledLocally = false;

  /// § 7 第 4 条：由先到的 tool_call_update 凭空建卡。
  final bool createdFromUpdate;
  DateTime updatedAt;
  DateTime? finishedAt;

  /// 子代理分组（docs/design.md § 4 入站识别键，只看键是否存在）。
  @override
  String? parentToolCallId;
  bool isSubagent;

  /// 嵌套在本卡之下的条目（子代理的工具行与输出，画板 24）。
  final List<TranscriptEntry> children = <TranscriptEntry>[];

  ToolDisplayStatus get displayStatus {
    if (cancelledLocally) return ToolDisplayStatus.cancelled;
    return switch (status) {
      ToolStatus.pending => ToolDisplayStatus.pending,
      ToolStatus.inProgress => ToolDisplayStatus.inProgress,
      ToolStatus.completed => ToolDisplayStatus.completed,
      ToolStatus.failed => ToolDisplayStatus.failed,
    };
  }

  bool get isFinished => status == ToolStatus.completed || status == ToolStatus.failed || cancelledLocally;

  Iterable<String> get terminalIds =>
      content.where((c) => c.type == ToolCallContentType.terminal).map((c) => c.terminalId).whereType<String>();

  Iterable<ToolCallContentWire> get diffs => content.where((c) => c.type == ToolCallContentType.diff);
}

enum PlanPayloadType { items, file, markdown }

enum PlanPriority {
  high('high'),
  medium('medium'),
  low('low'),
  unknown('');

  const PlanPriority(this.wire);

  final String wire;

  static PlanPriority parse(String? wire) {
    for (final p in values) {
      if (p != unknown && p.wire == wire) return p;
    }
    return unknown;
  }
}

enum PlanItemStatus {
  pending('pending'),
  inProgress('in_progress'),
  completed('completed'),
  unknown('');

  const PlanItemStatus(this.wire);

  final String wire;

  static PlanItemStatus parse(String? wire) {
    for (final s in values) {
      if (s != unknown && s.wire == wire) return s;
    }
    return unknown;
  }
}

class PlanItem {
  const PlanItem({required this.content, required this.priority, required this.status});

  final String content;
  final PlanPriority priority;
  final PlanItemStatus status;
}

/// 计划卡：稳定 `plan`（整份替换、无 id，用 [stablePlanId]）或 unstable `plan_update` 的三种载荷之一。
class PlanCardEntry extends TranscriptEntry {
  PlanCardEntry({required super.id, required super.at, required this.planId, required this.isStable}) : updatedAt = at;

  static const String stablePlanId = '__stable__';

  final String planId;
  final bool isStable;
  PlanPayloadType type = PlanPayloadType.items;
  List<PlanItem> items = const <PlanItem>[];
  String? uri;
  String? markdown;

  /// `plan_removed` 到达：保留条目并打标（画板 29「一份计划被移除」）。
  bool removed = false;

  /// 本地 ✕：只隐藏本地呈现，不回写 agent。
  bool dismissed = false;
  DateTime updatedAt;

  int get completedCount => items.where((i) => i.status == PlanItemStatus.completed).length;

  /// 「N left」= 还没开始的条目（画板 29：5 条、1 完成、1 进行中 → 3 left）。
  int get leftCount => items.where((i) => i.status == PlanItemStatus.pending).length;

  /// 「Current: …」= 第一条 in_progress，没有就第一条 pending。
  PlanItem? get current {
    for (final i in items) {
      if (i.status == PlanItemStatus.inProgress) return i;
    }
    for (final i in items) {
      if (i.status == PlanItemStatus.pending) return i;
    }
    return null;
  }
}

/// 上下文压缩卡（unstable）：`compaction_update` 按 id 就地打补丁，`compaction_summary_chunk` 追加流式摘要。
class CompactionEntry extends TranscriptEntry {
  CompactionEntry({required super.id, required super.at, required this.compactionId}) : updatedAt = at;

  final String compactionId;

  /// 协议原值：in_progress / completed / failed / cancelled / 其它自定义值（schema 有 catch-all）。
  String status = 'in_progress';

  /// `compaction_update.summary`：整份替换的保留摘要（null = 尚未给）。
  List<ContentBlockWire>? summary;

  /// `compaction_summary_chunk` 追加的流式摘要。
  final List<ContentBlockWire> chunks = <ContentBlockWire>[];
  String? error;
  DateTime updatedAt;

  /// 显示文本：有整份 summary 用它，否则用 chunk 拼接。
  String get summaryText {
    final blocks = summary ?? chunks;
    return blocks.where((b) => b.type == ContentBlockType.text).map((b) => b.text ?? '').join();
  }
}

enum PendingStatus { pending, answered, cancelled, withdrawn, completed }

/// `session/request_permission`：请求里带的是 ToolCallUpdate，可能只有 toolCallId（§ 3.1）。
class PermissionEntry extends TranscriptEntry {
  PermissionEntry({
    required super.id,
    required super.at,
    required this.requestId,
    required this.sessionId,
    required this.toolCallPatch,
    required this.options,
    this.agentId,
  });

  final String requestId;
  final String? agentId;
  final String sessionId;

  /// 请求自带的 ToolCallUpdate 片段；标题 / kind 缺失时从已累积的 tool call 取。
  final ToolCallWire toolCallPatch;
  final List<PermissionOptionWire> options;
  PendingStatus status = PendingStatus.pending;
  String? chosenOptionId;
  DateTime? answeredAt;

  String? get toolCallId => toolCallPatch.toolCallId;
}

/// `elicitation/create`：form / url；sessionScope 或 requestScope（§ 3.2）。
class ElicitationEntry extends TranscriptEntry {
  ElicitationEntry({
    required super.id,
    required super.at,
    required this.requestId,
    required this.wire,
    this.agentId,
  });

  final String requestId;
  final String? agentId;
  final ElicitationRequestWire wire;
  PendingStatus status = PendingStatus.pending;

  /// accept / decline / cancel（回应后记录）。
  String? action;
  JsonMap? values;
  DateTime? answeredAt;

  /// url 模式：已在浏览器打开（本地态，画板 28 第二态）。
  bool opened = false;

  bool get isForm => wire.isForm;
  bool get isUrl => wire.isUrl;
  String? get sessionId => wire.sessionId;
  bool get isRequestScope => wire.isRequestScope;
}

/// 回合级用量（`PromptResponse.usage`，unstable_end_turn_token_usage）。
class TurnUsage {
  const TurnUsage({this.total, this.input, this.output, this.thought, this.cachedRead, this.cachedWrite});

  factory TurnUsage.fromJson(JsonMap json) {
    num? n(String k) => json[k] is num ? json[k] as num : null;
    return TurnUsage(
      total: n('totalTokens'),
      input: n('inputTokens'),
      output: n('outputTokens'),
      thought: n('thoughtTokens'),
      cachedRead: n('cachedReadTokens'),
      cachedWrite: n('cachedWriteTokens'),
    );
  }

  final num? total;
  final num? input;
  final num? output;
  final num? thought;
  final num? cachedRead;
  final num? cachedWrite;

  JsonMap toJson() => <String, dynamic>{
        'totalTokens': total,
        'inputTokens': input,
        'outputTokens': output,
        'thoughtTokens': thought,
        'cachedReadTokens': cachedRead,
        'cachedWriteTokens': cachedWrite,
      };
}

/// 轮边界（§ 7 第 7 条）：`session/prompt` 请求到响应之间是一轮；只用来切轮、挂 stopReason / usage（画板 31 的结束行）
/// 与定位 Restore 的截断点，转录里不自带任何呈现（画板 10 的分隔线已废弃，所有者裁定 2026-09-17）。
class TurnEntry extends TranscriptEntry {
  TurnEntry({required super.id, required super.at, required this.n, required this.prompt});

  final int n;

  /// 本轮发出的 prompt 块（Restore / Regenerate 用它在同一会话重发）。
  final List<ContentBlockWire> prompt;
  String? stopReason;
  TurnUsage? usage;
  DateTime? endedAt;

  bool get isRunning => endedAt == null;
  Duration? get elapsed => endedAt?.difference(at);
}

/// 被投影层丢弃的更新（未知变体 / 未知 ToolCallStatus），与 Rust 侧同口径（§ 8.1）。
class DroppedUpdate {
  const DroppedUpdate({required this.reason, required this.raw, required this.at});

  final String reason;
  final JsonMap raw;
  final DateTime at;
}
