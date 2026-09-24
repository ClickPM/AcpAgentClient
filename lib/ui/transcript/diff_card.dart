// 画板 21 · 文件差异对比卡：tool_call.content[] 的 { type: "diff", path, oldText, newText }（只读）。折叠 = 路径 + 增删计数；
// 展开 = 行号 · 增删行着色（success.soft / error.soft）· 行悬浮出「在文件面板中定位」（R4 接 onLocate）。
// 行级 diff 用 diffutil_dart（Myers；更新序列从尾到头派发，删除行留位）。不做 Zed 的 Edits 审阅条（既定裁定）。
// 上千行的 diff（BACKLOG「流式渲染性能」）：diff 结果连同 +N / −N 按输入缓存在 State 里（转录每个流式 chunk 都重建视口里的卡）；
// 展开体按画板 21 的固定行高只建视口附近的行（见 [_DiffRows]）。

import 'dart:math' as math;

import 'package:diffutil_dart/diffutil.dart' as du;
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
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

/// 行级 diff：oldText 缺省时全部是新增行。
///
/// diffutil 的更新序列从尾到头派发、不带移动（`detectMoves: false`），所以每条更新的 `position` 都还是**旧文件里的原始下标**
/// （它前面的行一行都没动过）。据此一遍登记「哪几行删掉、哪个下标前插进哪几行」，再从头顺序拼出结果，整体线性
/// （原先逐条按「活行」下标现扫再 `List.insert`，大 diff 下是平方级）。结果与逐条模拟派发一致：同一处先删除行、后新增行，
/// 新增行按新文件顺序（`test/ui/diff_card_test.dart` 拿模拟派发的旧实现做对照）。
/// `DataChange` 只在「同一项、内容不同」时出现，逐行比字符串不会有；按删除行 + 紧跟其后的新增行处理。
List<DiffLine> lineDiff(String? oldText, String newText) {
  final oldLines = oldText == null ? const <String>[] : _lines(oldText);
  final newLines = _lines(newText);
  final result = du.calculateListDiff<String>(oldLines, newLines, detectMoves: false);
  final removed = List<bool>.filled(oldLines.length, false);
  final changedTo = <int, String>{};
  // 插在旧第 k 行之前（越过紧挨着它的删除段）的新增行；同一处按新文件行号从大到小派发，拼的时候倒回来。
  final insertedBefore = List<List<String>?>.filled(oldLines.length + 1, null);
  for (final u in result.getUpdatesWithData()) {
    switch (u) {
      case du.DataInsert<String>(:final position, :final data):
        (insertedBefore[position] ??= <String>[]).add(data);
      case du.DataRemove<String>(:final position):
        removed[position] = true;
      case du.DataChange<String>(:final position, :final newData):
        removed[position] = true;
        changedTo[position] = newData;
      case du.DataMove<String>():
        break;
    }
  }

  final out = <DiffLine>[];
  final pending = <String>[];
  var o = 1, n = 1;
  void flush() {
    for (final l in pending) {
      out.add(DiffLine(DiffKind.insert, l, newNo: n++));
    }
    pending.clear();
  }

  for (var k = 0; k <= oldLines.length; k++) {
    final inserted = insertedBefore[k];
    if (inserted != null) pending.addAll(inserted.reversed);
    if (k == oldLines.length) break;
    if (removed[k]) {
      out.add(DiffLine(DiffKind.delete, oldLines[k], oldNo: o++));
      final changed = changedTo[k];
      if (changed != null) out.add(DiffLine(DiffKind.insert, changed, newNo: n++));
      continue;
    }
    flush();
    out.add(DiffLine(DiffKind.equal, oldLines[k], oldNo: o++, newNo: n++));
  }
  flush();
  return out;
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

  /// [lineDiff] 的输入与结果：只在 oldText / newText 变了才重算。
  ({String? oldText, String newText})? _input;
  List<DiffLine> _lines = const <DiffLine>[];
  int _added = 0;
  int _removed = 0;

  void _diff() {
    final d = widget.diff;
    final input = (oldText: d.oldText, newText: d.newText ?? '');
    if (input == _input) return;
    _input = input;
    _lines = lineDiff(input.oldText, input.newText);
    _added = _lines.where((l) => l.kind == DiffKind.insert).length;
    _removed = _lines.where((l) => l.kind == DiffKind.delete).length;
  }

  /// 行上的「在文件面板中定位」。经 State 转一道：[DiffCard.onLocate] 是转录每次 build 新建的闭包，
  /// 而行 widget 是缓存的，捏住旧闭包就会调到过期的那一个。
  void _locate(String path, int line) => widget.onLocate?.call(path, line);

  @override
  Widget build(BuildContext context) {
    _diff();
    final d = widget.diff;
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
                Text('+$_added', style: t.TextStyles.mono.copyWith(color: t.Semantic.success)),
                const SizedBox(width: t.Spacing.s4),
                Text('−$_removed', style: t.TextStyles.mono.copyWith(color: t.Semantic.error)),
              ],
            ),
            trailing: <Widget>[Chevron(expanded: _expanded)],
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded)
            Container(
              decoration: BoxDecoration(border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
              padding: const EdgeInsets.symmetric(vertical: t.Spacing.s8),
              child: _DiffRows(lines: _lines, path: d.path, onLocate: _locate, pinnedHover: widget.hoveredLineIndex),
            ),
        ],
      ),
    );
  }
}

/// 展开体。画板 21 的行等高（mono 12.5 · line-height 1.7），所以按固定行高只建出转录视口附近的行（上下各多留一屏），
/// 其余只占高度：转录是一个 ListView、整张卡是其中一项，卡内逐行建 widget 的话，上千行的 diff 展开那一下要建上千行、
/// 排上千段字。可见窗口按外层竖向滚动位置算——滚动时当场算；卡被别的条目挪了位置（流式追加、折叠）没有滚动事件，
/// 但那时转录会重建本卡，重建后补算一次。建过的行按下标缓存，父级每帧重建时行不再跟着重建。
/// 外面没有竖向滚动（直接嵌在非滚动容器里）就全建。
class _DiffRows extends StatefulWidget {
  const _DiffRows({required this.lines, required this.path, required this.onLocate, this.pinnedHover});

  final List<DiffLine> lines;
  final String? path;
  final void Function(String path, int line) onLocate;
  final int? pinnedHover;

  @override
  State<_DiffRows> createState() => _DiffRowsState();
}

class _DiffRowsState extends State<_DiffRows> {
  /// 窗口按这么多行对齐，免得每滚一个像素都重建一次。
  static const int _page = 32;

  ScrollPosition? _position;

  /// 已建的行 [_first, _end)。`_end < 0` = 还没按布局算过，先建从头起的三屏（点开展开时卡头就在视口里）。
  int _first = 0;
  int _end = -1;

  final Map<int, Widget> _rows = <int, Widget>{};
  double _extent = 0;
  int _generation = t.Fonts.generation;
  bool _syncScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scrollable = Scrollable.maybeOf(context);
    final position = scrollable != null && scrollable.position.axisDirection == AxisDirection.down ? scrollable.position : null;
    if (position != _position) {
      _position?.removeListener(_onScroll);
      _position = position?..addListener(_onScroll);
      _end = -1;
    }
  }

  @override
  void didUpdateWidget(_DiffRows old) {
    super.didUpdateWidget(old);
    if (!identical(old.lines, widget.lines) || old.path != widget.path || old.onLocate != widget.onLocate || old.pinnedHover != widget.pinnedHover) {
      _rows.clear();
    }
    // 父级重建多半是转录在流式追加或折叠：本卡可能被挪了位置而没有滚动事件，布局完补算一次窗口。
    _scheduleSync();
  }

  @override
  void dispose() {
    _position?.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    // 滚动多由指针事件或动画驱动（不在 build / layout 阶段），当场重建；落在帧中间的挪到帧后。
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      _scheduleSync();
    } else {
      _sync();
    }
  }

  void _scheduleSync() {
    if (_syncScheduled || _position == null) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (mounted) _sync();
    });
  }

  void _sync() {
    final window = _window();
    if (window == null || (window.$1 == _first && window.$2 == _end)) return;
    setState(() {
      _first = window.$1;
      _end = window.$2;
    });
  }

  /// 视口看得见的行，上下各多留一屏、按 [_page] 对齐；算不出来（还没布局）返回 null。
  /// 不按行数截尾（build 时再截）：diff 变长时窗口里本来就该有的新行当帧就建出来。
  (int, int)? _window() {
    final position = _position;
    final box = context.findRenderObject();
    if (position == null || box is! RenderBox || !box.attached || !box.hasSize || _extent <= 0) return null;
    if (!position.hasPixels || !position.hasViewportDimension) return null;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return null;
    // 视口上沿落在本体的哪个纵坐标：本体顶端对齐视口上沿时的滚动量是 getOffsetToReveal(box, 0)。
    final top = position.pixels - viewport.getOffsetToReveal(box, 0).offset;
    final screen = position.viewportDimension;
    final first = math.max(0, ((top - screen) / _extent).floor() ~/ _page * _page);
    final end = math.max(0, (((top + 2 * screen) / _extent).ceil() + _page - 1) ~/ _page * _page);
    return (first, end);
  }

  @override
  Widget build(BuildContext context) {
    final style = _DiffRow.style;
    final extent = MediaQuery.textScalerOf(context).scale(style.fontSize!) * style.height!;
    if (extent != _extent || _generation != t.Fonts.generation) {
      _rows.clear();
      _extent = extent;
      _generation = t.Fonts.generation;
    }
    final count = widget.lines.length;
    final position = _position;
    var first = 0, end = count;
    if (position != null && _end < 0) {
      final screen = position.hasViewportDimension ? position.viewportDimension : MediaQuery.sizeOf(context).height;
      end = math.min(count, (3 * screen / extent).ceil());
      _scheduleSync();
    } else if (position != null) {
      first = math.min(_first, count);
      end = math.min(_end, count);
    }
    return SizedBox(
      height: count * extent,
      child: Stack(children: <Widget>[for (var i = first; i < end; i++) _rows[i] ??= _row(i, extent)]),
    );
  }

  Widget _row(int i, double extent) {
    final l = widget.lines[i];
    final path = widget.path;
    final lineNo = l.newNo ?? l.oldNo;
    final locate = widget.onLocate;
    return Positioned(
      key: ValueKey<int>(i),
      top: i * extent,
      left: 0,
      right: 0,
      height: extent,
      child: _DiffRow(line: l, pinned: widget.pinnedHover == i, onTap: path == null || lineNo == null ? null : () => locate(path, lineNo)),
    );
  }
}

class _DiffRow extends StatefulWidget {
  const _DiffRow({required this.line, this.onTap, this.pinned = false});

  final DiffLine line;
  final VoidCallback? onTap;

  /// gallery：预先呈现悬浮态。
  final bool pinned;

  /// 行字：mono 12.5 · line-height 1.7（画板 21），行高就是这一行字的行框高。
  static TextStyle get style => t.TextStyles.mono.copyWith(height: t.LineHeights.diffRow);

  @override
  State<_DiffRow> createState() => _DiffRowState();
}

class _DiffRowState extends State<_DiffRow> {
  late bool _hover = widget.pinned;

  /// 行号列宽：两位行号 + 间距，取 s24。
  static const double _gutter = t.Spacing.s24;

  @override
  Widget build(BuildContext context) {
    final l = widget.line;
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
    final style = _DiffRow.style;
    final number = style.copyWith(color: t.Neutral.placeholder);
    final ink = style.copyWith(color: fg);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = widget.pinned),
      child: GestureDetector(
        onTap: widget.onTap,
        // 悬浮提示浮在行上（画板 21：绝对定位、不占行宽），行高因此不随悬浮变。
        child: Stack(
          clipBehavior: Clip.none,
          fit: StackFit.expand,
          children: <Widget>[
            Container(
              color: bg,
              padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12),
              child: Row(
                children: <Widget>[
                  SizedBox(width: _gutter, child: Text('${l.oldNo ?? ''}', style: number, textAlign: TextAlign.right)),
                  const SizedBox(width: t.Spacing.s8),
                  SizedBox(width: _gutter, child: Text('${l.newNo ?? ''}', style: number, textAlign: TextAlign.right)),
                  const SizedBox(width: t.Spacing.s12),
                  Text(sign, style: ink),
                  const SizedBox(width: t.Spacing.s8),
                  Expanded(child: Text(l.text, style: ink, maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
            if (_hover)
              Positioned(
                top: 0,
                bottom: 0,
                right: t.Spacing.s8,
                child: Center(
                  child: Popover(
                    padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s8),
                    child: Text('在文件面板中定位', style: t.TextStyles.meta),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
