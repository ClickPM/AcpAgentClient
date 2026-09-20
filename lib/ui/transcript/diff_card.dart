// 画板 21 · 文件差异对比卡：tool_call.content[] 的 { type: "diff", path, oldText, newText }（只读）。折叠 = 路径 + 增删计数；
// 展开 = 行号 · 增删行着色（success.soft / error.soft）· 行悬浮出「在文件面板中定位」（R4 接 onLocate）。
// 行级 diff 用 diffutil_dart（Myers；更新序列从尾到头派发，删除行留位）。不做 Zed 的 Edits 审阅条（既定裁定）。

import 'package:diffutil_dart/diffutil.dart' as du;
import 'package:flutter/widgets.dart';

import '../../projection/entries.dart';
import '../../projection/wire.dart';
import '../../theme/tokens.dart' as t;
import 'card_chrome.dart';
import 'icons.dart';
import 'tool_call_card.dart';

enum DiffKind { equal, insert, delete }

class DiffLine {
  const DiffLine(this.kind, this.text, {this.oldNo, this.newNo});

  final DiffKind kind;
  final String text;
  final int? oldNo;
  final int? newNo;
}

List<String> _lines(String s) {
  final l = s.split('\n');
  if (l.isNotEmpty && l.last.isEmpty) l.removeLast();
  return l;
}

List<DiffLine> _number(List<DiffLine> raw) {
  var o = 1, n = 1;
  return <DiffLine>[
    for (final l in raw)
      switch (l.kind) {
        DiffKind.equal => DiffLine(l.kind, l.text, oldNo: o++, newNo: n++),
        DiffKind.delete => DiffLine(l.kind, l.text, oldNo: o++),
        DiffKind.insert => DiffLine(l.kind, l.text, newNo: n++),
      },
  ];
}

/// 行级 diff：oldText 缺省时全部是新增行。
List<DiffLine> lineDiff(String? oldText, String newText) {
  final oldLines = oldText == null ? const <String>[] : _lines(oldText);
  final newLines = _lines(newText);
  final result = du.calculateListDiff<String>(oldLines, newLines, detectMoves: false);
  final work = <DiffLine>[for (final l in oldLines) DiffLine(DiffKind.equal, l)];
  int indexOfLive(int position) {
    var live = 0;
    for (var i = 0; i < work.length; i++) {
      if (work[i].kind == DiffKind.delete) continue;
      if (live == position) return i;
      live++;
    }
    return work.length;
  }

  for (final u in result.getUpdatesWithData()) {
    switch (u) {
      case du.DataInsert<String>(:final position, :final data):
        work.insert(indexOfLive(position), DiffLine(DiffKind.insert, data));
      case du.DataRemove<String>(:final position, :final data):
        work[indexOfLive(position)] = DiffLine(DiffKind.delete, data);
      case du.DataChange<String>(:final position, :final oldData, :final newData):
        final i = indexOfLive(position);
        work[i] = DiffLine(DiffKind.delete, oldData);
        work.insert(i + 1, DiffLine(DiffKind.insert, newData));
      case du.DataMove<String>():
        break;
    }
  }
  return _number(work);
}

class DiffCard extends StatefulWidget {
  const DiffCard(this.entry, {super.key, required this.diff, this.cwd, this.initiallyExpanded = false, this.onLocate, this.hoveredLineIndex});

  final ToolCallEntry entry;
  final ToolCallContentWire diff;
  final String? cwd;
  final bool initiallyExpanded;
  final void Function(String path, int line)? onLocate;

  /// gallery：预先呈现某一行的悬浮态。
  final int? hoveredLineIndex;

  @override
  State<DiffCard> createState() => _DiffCardState();
}

class _DiffCardState extends State<DiffCard> {
  late bool _expanded = widget.initiallyExpanded;
  late int? _hover = widget.hoveredLineIndex;

  /// 行号列宽：两位行号 + 间距，取 s24。
  static const double _gutter = t.Spacing.s24;

  @override
  Widget build(BuildContext context) {
    final d = widget.diff;
    final lines = lineDiff(d.oldText, d.newText ?? '');
    final added = lines.where((l) => l.kind == DiffKind.insert).length;
    final removed = lines.where((l) => l.kind == DiffKind.delete).length;
    final path = displayPath(d.path, cwd: widget.cwd);
    return TranscriptCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CardHeader(
            leading: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ToolStatusIcon(widget.entry.displayStatus),
                const SizedBox(width: t.Spacing.s8),
                AcpIcon(AcpIcons.columns, color: t.Neutral.muted),
              ],
            ),
            title: '',
            subtitleWidget: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Flexible(child: Text(path, style: CardText.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: t.Spacing.s8),
                Text('+$added', style: t.TextStyles.mono.copyWith(color: t.Semantic.success)),
                const SizedBox(width: t.Spacing.s4),
                Text('−$removed', style: t.TextStyles.mono.copyWith(color: t.Semantic.error)),
              ],
            ),
            trailing: <Widget>[Chevron(expanded: _expanded)],
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded)
            Container(
              decoration: BoxDecoration(border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
              padding: const EdgeInsets.symmetric(vertical: t.Spacing.s8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[for (var i = 0; i < lines.length; i++) _row(i, lines[i], d.path)],
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(int i, DiffLine l, String? path) {
    final bg = switch (l.kind) {
      DiffKind.insert => t.Semantic.successSoft,
      DiffKind.delete => t.Semantic.errorSoft,
      DiffKind.equal => null,
    };
    final sign = switch (l.kind) {
      DiffKind.insert => '+',
      DiffKind.delete => '-',
      DiffKind.equal => ' ',
    };
    final fg = switch (l.kind) {
      DiffKind.insert => t.Semantic.success,
      DiffKind.delete => t.Semantic.error,
      DiffKind.equal => t.Neutral.text,
    };
    final hovered = _hover == i;
    final lineNo = l.newNo ?? l.oldNo;
    final row = Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12),
      child: Row(
        children: <Widget>[
          SizedBox(width: _gutter, child: Text('${l.oldNo ?? ''}', style: t.TextStyles.mono.copyWith(color: t.Neutral.placeholder), textAlign: TextAlign.right)),
          const SizedBox(width: t.Spacing.s8),
          SizedBox(width: _gutter, child: Text('${l.newNo ?? ''}', style: t.TextStyles.mono.copyWith(color: t.Neutral.placeholder), textAlign: TextAlign.right)),
          const SizedBox(width: t.Spacing.s12),
          Text(sign, style: t.TextStyles.mono.copyWith(color: fg)),
          const SizedBox(width: t.Spacing.s8),
          Expanded(child: Text(l.text, style: t.TextStyles.mono.copyWith(color: fg), maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (hovered)
            Popover(
              padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s8, vertical: t.Spacing.s4),
              child: Text('在文件面板中定位', style: t.TextStyles.meta),
            ),
        ],
      ),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = i),
      onExit: (_) => setState(() => _hover = widget.hoveredLineIndex),
      child: GestureDetector(
        onTap: path == null || lineNo == null ? null : () => widget.onLocate?.call(path, lineNo),
        child: row,
      ),
    );
  }
}
