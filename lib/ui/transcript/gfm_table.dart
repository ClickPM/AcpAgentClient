// 画板 14 · GFM 表格：列对齐（左 / 居中 / 右）、表头 surface、斑马行 panel / popover、数字列 tabular-nums、超宽横向滚动。
// 输入是 package:markdown 的 <table> 元素（markdown_body.dart 调过来），单元格内联由调用方渲染成 InlineSpan。

import 'package:flutter/widgets.dart';
import 'package:markdown/markdown.dart' as md;

import '../../theme/tokens.dart' as t;
import 'card_chrome.dart';

typedef InlineBuilder = InlineSpan Function(List<md.Node>? nodes, TextStyle base);

/// 表格最小宽度（画板 14：表格撑满 752 的内容宽；窄列时横向滚动）。窄于内容宽时以内容宽为准。
class GfmTable extends StatelessWidget {
  const GfmTable({super.key, required this.element, required this.inline});

  final md.Element element;
  final InlineBuilder inline;

  static TextAlign _align(md.Element cell) {
    final a = (cell.attributes['align'] ?? cell.attributes['style'] ?? '').toLowerCase();
    if (a.contains('center')) return TextAlign.center;
    if (a.contains('right')) return TextAlign.right;
    return TextAlign.left;
  }

  // getter 而非 static final：理由同 [CardText]，static final 会把 family 冻在首次访问那一刻。
  static TextStyle get _head => CardText.strong;
  static TextStyle get _cell => t.TextStyles.body;

  /// 数字列开 tabular-nums：整列单元格都像数字（含单位后缀）时。
  static final RegExp _numeric = RegExp(r'^[\d.,]+\s*[a-zA-Z%]*$');

  @override
  Widget build(BuildContext context) {
    final rows = <TableRow>[];
    var stripe = false;
    List<TextAlign>? aligns;
    final bodyRows = <List<md.Element>>[];
    for (final section in element.children?.whereType<md.Element>() ?? const <md.Element>[]) {
      final isHead = section.tag == 'thead';
      for (final tr in section.children?.whereType<md.Element>() ?? const <md.Element>[]) {
        final cells = tr.children?.whereType<md.Element>().toList() ?? const <md.Element>[];
        aligns ??= cells.map(_align).toList();
        if (!isHead) bodyRows.add(cells);
        rows.add(
          TableRow(
            decoration: BoxDecoration(color: isHead ? t.Neutral.surface : (stripe ? t.Neutral.panel : t.Surface.popover)),
            children: <Widget>[
              for (var i = 0; i < cells.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
                  child: Text.rich(
                    inline(cells[i].children, isHead ? _head : _cellStyle(bodyRows, i)),
                    style: isHead ? _head : _cellStyle(bodyRows, i),
                    textAlign: i < (aligns.length) ? aligns[i] : TextAlign.left,
                  ),
                ),
            ],
          ),
        );
        if (!isHead) stripe = !stripe;
      }
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth.isFinite ? constraints.maxWidth : 0),
            child: ClipRRect(
              borderRadius: t.Radii.card,
              child: Container(
                decoration: BoxDecoration(border: Border.all(color: t.Borders.subtle, width: t.Borders.width), borderRadius: t.Radii.card),
                child: Table(
                  defaultColumnWidth: const IntrinsicColumnWidth(),
                  border: TableBorder(horizontalInside: BorderSide(color: t.Borders.subtle, width: t.Borders.width)),
                  children: rows,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static TextStyle _cellStyle(List<List<md.Element>> bodyRows, int col) {
    if (bodyRows.isEmpty) return _cell;
    final allNumeric = bodyRows.every((r) => col < r.length && _numeric.hasMatch(r[col].textContent.trim()));
    return allNumeric ? _cell.copyWith(fontFeatures: const <FontFeature>[FontFeature.tabularFigures()]) : _cell;
  }
}
