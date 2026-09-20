// 画板 43 · 会话时间线的数据派生：把 `SessionStore.entries` 摊成「每轮一条用户 query 首行 + 该轮最终回答首行」。
// 纯 Dart、不依赖 widget（同 entries.dart），也**不新增** `docs/acp-projection.md` § 7 的自造态 ——
// 它整个是 `entries` 的函数，没有自己的状态，转录变了重算一遍即可。
//
// 轮的切分按**顶层用户消息**，不按 `TurnEntry`：轮边界只有我们自己 `startTurn` 时才放，
// `session/load` 重放回来的历史一条都没有（同一个坑在 `session_store.dart` 的 `restoreTo` 注释里，
// 2026-09-18 修 Restore 死键那次踩过）。按轮边界切的话，重开应用或切回旧会话之后时间线会是空的。

import 'entries.dart';
import 'wire.dart';

/// 时间线上的一轮：一条用户 query，外加这一轮到目前为止**最后一条** agent 文本。
///
/// [answer] 为 null = 这一轮至今没有任何 agent 文本（被取消、失败，或正在跑还没出字）：
/// 画板 43 规定这种轮只画编号行，不画 `A` 行、不补 spinner 与占位文案。
class TimelineTurn {
  const TimelineTurn({
    required this.n,
    required this.entryId,
    required this.query,
    this.answer,
    this.answerEntryId,
  });

  /// 轮次序号，从 1 起（画板 43 里显示成两位的 `01`、`02`…）。按轮次序递增，不因删除或压缩重排。
  final int n;

  /// 用户气泡的条目 id：点编号行就跳到它。
  final String entryId;

  /// 用户消息的首行。
  final String query;

  /// 该轮最终回答的首行；null = 这一轮还没有任何 agent 文本。
  final String? answer;

  /// 最终回答那条消息的条目 id；[answer] 为 null 时也为 null。
  final String? answerEntryId;
}

/// 从转录条目派生时间线。[entries] 是 `SessionStore.entries`（顶层列表）。
List<TimelineTurn> buildTimeline(List<TranscriptEntry> entries) {
  final turns = <TimelineTurn>[];
  for (final e in entries) {
    if (e is! MessageEntry) continue;
    // 子代理卡里嵌套的消息不入时间线（与 Restore 的截断点同口径）。正常情况下它们在
    // `ToolCallEntry.children` 里、压根不在这个列表，但父卡建不出来时 `_containerFor` 会把它们
    // 落回顶层（见 session_store.dart），那时这一条才起作用。
    if (e.parentToolCallId != null) continue;
    if (e.role == MessageRole.user) {
      turns.add(TimelineTurn(n: turns.length + 1, entryId: e.id, query: timelineUserLine(e)));
      continue;
    }
    // 第一条用户消息之前的 agent 文本不挂在任何一轮上（挂不上去，也不该自己开一轮）。
    if (turns.isEmpty) continue;
    final line = timelineAgentLine(e);
    if (line.isEmpty) continue;
    // 同一轮里后来的 agent 文本覆盖前面的：要的是「这一轮最后说了什么」，
    // 工具调用之间的中间文本因此自然不会留下（投影层遇到工具卡就另起一条消息）。
    final open = turns.removeLast();
    turns.add(TimelineTurn(
      n: open.n,
      entryId: open.entryId,
      query: open.query,
      answer: line,
      answerEntryId: e.id,
    ));
  }
  return turns;
}

/// 用户行的首行：text 块原样，提及写成 `@name` **纯文本**（时间线里不画画板 11 那种芯片）。
/// 整条没有文字时退到第一个非文本块的名字（`image` / `audio`，与画板 11 气泡里那些芯片同一套叫法）。
String timelineUserLine(MessageEntry m) {
  final buffer = StringBuffer();
  String? fallback;
  for (final block in m.blocks) {
    switch (block.type) {
      case ContentBlockType.text:
        buffer.write(block.text ?? '');
      case ContentBlockType.resourceLink:
        buffer.write('@${block.name ?? block.title ?? block.uri ?? ''}');
      case ContentBlockType.resource:
        buffer.write('@${_lastSegment(block.resource?.uri)}');
      case ContentBlockType.image:
        fallback ??= 'image';
      case ContentBlockType.audio:
        fallback ??= 'audio';
      case ContentBlockType.unknown:
        break;
    }
  }
  final line = _firstNonEmptyLine(buffer.toString());
  if (line.isNotEmpty) return line;
  return fallback ?? '';
}

/// `A` 行的首行：取 agent 文本的第一个非空行，去掉行首的 Markdown 标记
/// （`#` 标题、`-` / `*` / `+` 无序、`1.` 有序、`>` 引用、`[ ]` 任务勾）；代码围栏那一行整行跳过。
/// 去完是空的就往下取一行。
String timelineAgentLine(MessageEntry m) {
  for (final raw in m.text.split('\n')) {
    final line = _stripMarkdownPrefix(raw.trim());
    if (line.isNotEmpty) return line;
  }
  return '';
}

/// 行首可以反复剥掉的 Markdown 标记（引用里套列表这种组合要剥不止一次）。
final RegExp _markdownPrefix = RegExp(r'^(?:>+\s*|#{1,6}\s*|[-*+]\s+|\d+[.)]\s+|\[[ xX]\]\s*)');

String _stripMarkdownPrefix(String line) {
  // 代码围栏行本身没有可显示的内容（```dart 只是语言标签），整行跳过、取下一行。
  if (line.startsWith('```') || line.startsWith('~~~')) return '';
  var s = line;
  while (true) {
    final m = _markdownPrefix.firstMatch(s);
    if (m == null || m.end == 0) break;
    s = s.substring(m.end);
  }
  return s.trim();
}

String _firstNonEmptyLine(String text) {
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return '';
}

/// `file:///d:/proj/lib/main.dart` → `main.dart`（与画板 11 气泡里提及芯片的取名一致）。
String _lastSegment(String? uri) {
  if (uri == null) return '';
  final segments = Uri.tryParse(uri)?.pathSegments ?? const <String>[];
  return segments.isEmpty ? uri : segments.last;
}
