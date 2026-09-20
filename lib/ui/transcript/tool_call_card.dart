// 画板 18 / 19 / 20 · 标准工具调用卡：折叠行（kind 图标 + 标题 + 副标题 + 状态图标 + 折叠箭头）、展开（Raw Input: / Output: /
// 底部收起条）、路径悬浮出「Go to File」、状态 pending / in_progress / completed / failed（Output 底色 error.soft）/
// 本地 cancelled（中性徽章 + 「Error: tool call aborted」）。未知 kind 落 other；先到的 update 凭空建卡与正常卡无差异。
// 有 diff / terminal 内容或子代理标记的工具调用由 transcript_list.dart 分发到 21 / 22 / 24。

import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';

import '../../projection/entries.dart';
import '../../projection/wire.dart';
import '../../theme/tokens.dart' as t;
import 'card_chrome.dart';
import 'content_blocks.dart';
import 'icons.dart';

/// kind → 画板 18 的图标（edit / delete / move / think / switch_mode 复用同一行结构，只换图标）。
String kindIcon(ToolKind kind) => switch (kind) {
      ToolKind.read => AcpIcons.file,
      ToolKind.edit => AcpIcons.pencil,
      ToolKind.delete => AcpIcons.trash,
      ToolKind.move => AcpIcons.cornerDownRight,
      ToolKind.search => AcpIcons.search,
      ToolKind.execute => AcpIcons.terminal,
      ToolKind.think => AcpIcons.lightbulb,
      ToolKind.fetch => AcpIcons.globe,
      ToolKind.switchMode => AcpIcons.rotateCcw,
      ToolKind.other => AcpIcons.layers,
    };

/// 路径相对化：去掉会话 cwd 前缀，Windows 上用反斜杠（画板 18 / 21 的写法）。
String displayPath(String? path, {String? cwd}) {
  if (path == null || path.isEmpty) return '';
  var p = path;
  if (p.startsWith('file:///')) p = Uri.parse(p).toFilePath(windows: Platform.isWindows);
  p = p.replaceAll(r'\', '/');
  if (cwd != null && cwd.isNotEmpty) {
    final c = cwd.replaceAll(r'\', '/').replaceAll(RegExp(r'/+$'), '');
    if (p.startsWith('$c/')) p = p.substring(c.length + 1);
  }
  return Platform.isWindows ? p.replaceAll('/', r'\') : p;
}

JsonMap? _rawInputMap(ToolCallEntry e) => e.rawInput is Map ? (e.rawInput as Map).cast<String, dynamic>() : null;

/// 头行副标题：优先 locations[0]（带 rawInput 的 offset / limit 行范围）；execute 类优先 cwd；其余按常见键取第一个字符串值。
String toolSubtitle(ToolCallEntry e, {String? cwd}) {
  final raw = _rawInputMap(e);
  if (e.locations.isNotEmpty) {
    final path = displayPath(e.locations.first.path, cwd: cwd);
    final offset = raw?['offset'];
    final limit = raw?['limit'];
    if (offset is num && limit is num) return '$path (lines ${offset.toInt()}-${offset.toInt() + limit.toInt() - 1})';
    final line = e.locations.first.line;
    return line == null ? path : '$path:${line.toInt()}';
  }
  if (raw == null) return '';
  if (e.kind == ToolKind.execute && raw['cwd'] is String) return displayPath(raw['cwd'] as String);
  for (final k in const <String>['command', 'path', 'pattern', 'url', 'query', 'cwd', 'from', 'key', 'mode', 'description']) {
    final v = raw[k];
    if (v is String && v.isNotEmpty) return k == 'path' ? displayPath(v, cwd: cwd) : v;
  }
  return '';
}

/// execute 类卡展开体第一块：命令本身。
String? toolCommand(ToolCallEntry e) {
  final raw = _rawInputMap(e);
  final c = raw?['command'];
  return c is String ? c : null;
}

/// 状态图标（14）：completed ✓ success · pending 虚线圆 · in_progress spinner · failed ✕ error · cancelled 徽章。
class ToolStatusIcon extends StatelessWidget {
  const ToolStatusIcon(this.status, {super.key});

  final ToolDisplayStatus status;

  @override
  Widget build(BuildContext context) => switch (status) {
        ToolDisplayStatus.completed => const AcpIcon(AcpIcons.checkCircle, color: t.Semantic.success, size: t.IconSizes.toolbar),
        ToolDisplayStatus.pending => const AcpIcon(AcpIcons.dashedCircle, color: t.Neutral.placeholder, size: t.IconSizes.toolbar),
        ToolDisplayStatus.inProgress => const Spinner(),
        ToolDisplayStatus.failed => const AcpIcon(AcpIcons.x, color: t.Semantic.error, size: t.IconSizes.toolbar),
        ToolDisplayStatus.cancelled => const ToneChip('Canceled', tone: ChipTone.neutral),
      };
}

/// 副标题位置的路径芯片：悬浮出 6% 底 + 「Go to File」提示（落右栏文件面板，R4 接 onGoToFile）。
class PathChip extends StatefulWidget {
  const PathChip(this.text, {super.key, this.onGoToFile, this.hoveredInitially = false, this.onHoverChanged});

  final String text;
  final VoidCallback? onGoToFile;
  final bool hoveredInitially;
  final ValueChanged<bool>? onHoverChanged;

  @override
  State<PathChip> createState() => _PathChipState();
}

class _PathChipState extends State<PathChip> {
  late bool _hover = widget.hoveredInitially;

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      decoration: BoxDecoration(color: _hover ? t.Overlays.hover : null, borderRadius: t.Radii.chip),
      padding: _hover ? t.Spacing.chip : EdgeInsets.zero,
      child: Text(widget.text, style: CardText.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    return MouseRegion(
      cursor: widget.onGoToFile == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _hover = true);
        widget.onHoverChanged?.call(true);
      },
      onExit: (_) {
        setState(() => _hover = widget.hoveredInitially);
        widget.onHoverChanged?.call(widget.hoveredInitially);
      },
      child: GestureDetector(
        onTap: widget.onGoToFile,
        child: _hover
            ? Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  chip,
                  Positioned(
                    top: t.Controls.compact,
                    left: 0,
                    child: Popover(
                      padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s8, vertical: t.Spacing.s4),
                      child: Text('Go to File', style: t.TextStyles.meta),
                    ),
                  ),
                ],
              )
            : chip,
      ),
    );
  }
}

class ToolCallCard extends StatefulWidget {
  const ToolCallCard(this.entry, {super.key, this.cwd, this.initiallyExpanded = false, this.onGoToFile, this.pathHoveredInitially = false});

  final ToolCallEntry entry;
  final String? cwd;
  final bool initiallyExpanded;
  final void Function(String path, int? line)? onGoToFile;
  final bool pathHoveredInitially;

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  late bool _expanded = widget.initiallyExpanded;
  late bool _pathHover = widget.pathHoveredInitially;

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final status = e.displayStatus;
    final cancelled = status == ToolDisplayStatus.cancelled;
    final subtitle = toolSubtitle(e, cwd: widget.cwd);
    final loc = e.locations.isEmpty ? null : e.locations.first;
    final goTo = widget.onGoToFile;
    return TranscriptCard(
      // 路径提示要画到卡片之外，悬浮时不裁剪。
      clip: _pathHover ? Clip.none : Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CardHeader(
            leading: AcpIcon(kindIcon(e.kind), color: t.Neutral.muted),
            title: e.title,
            subtitleWidget: subtitle.isEmpty
                ? null
                : PathChip(
                    subtitle,
                    hoveredInitially: widget.pathHoveredInitially,
                    onHoverChanged: (h) => setState(() => _pathHover = h),
                    onGoToFile: loc?.path == null || goTo == null ? null : () => goTo(loc!.path!, loc.line?.toInt()),
                  ),
            trailing: <Widget>[ToolStatusIcon(status), Chevron(expanded: _expanded)],
            onTap: _toggle,
          ),
          if (_expanded) ...<Widget>[
            CardBody(children: cancelled ? _cancelledBody(e) : _body(e, status)),
            CollapseBar(onTap: _toggle),
          ],
        ],
      ),
    );
  }

  List<Widget> _body(ToolCallEntry e, ToolDisplayStatus status) {
    final command = toolCommand(e);
    final failed = status == ToolDisplayStatus.failed;
    final textOut = <String>[];
    final otherOut = <Widget>[];
    for (final c in e.content) {
      final b = c.content;
      if (b == null) continue;
      if (b.type == ContentBlockType.text) {
        textOut.add(b.text ?? '');
      } else {
        otherOut.add(ContentBlockView(b));
      }
    }
    final raw = e.rawOutput;
    if (textOut.isEmpty && raw != null) textOut.add(JsonHighlight.pretty(raw));
    final hasOutput = textOut.isNotEmpty || otherOut.isNotEmpty;
    return <Widget>[
      if (command != null && e.kind == ToolKind.execute) MonoBlock(text: command),
      if (e.rawInput != null) ...<Widget>[
        const SectionLabel('Raw Input:'),
        MonoBlock(span: JsonHighlight.span(e.rawInput)),
      ],
      if (hasOutput) ...<Widget>[
        const SectionLabel('Output:'),
        if (textOut.isNotEmpty)
          MonoBlock(
            text: textOut.join('\n'),
            background: failed ? t.Semantic.errorSoft : t.Neutral.panel,
            style: failed ? CardText.codeError : CardText.code,
          ),
        ...otherOut,
      ],
    ];
  }

  List<Widget> _cancelledBody(ToolCallEntry e) {
    final command = toolCommand(e);
    return <Widget>[
      if (command != null) MonoBlock(text: command) else if (e.rawInput != null) MonoBlock(span: JsonHighlight.span(e.rawInput)),
      const SectionLabel('Output:'),
      const MonoBlock(text: 'Error: tool call aborted'),
    ];
  }
}

/// 画板 18 底部的 kind 图标一览（gallery 用）。
class KindIconRow extends StatelessWidget {
  const KindIconRow({super.key, this.kinds = const <ToolKind>[ToolKind.read, ToolKind.search, ToolKind.execute, ToolKind.fetch, ToolKind.other]});

  final List<ToolKind> kinds;

  @override
  Widget build(BuildContext context) {
    return TranscriptCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: t.Spacing.s16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: <Widget>[
            for (final k in kinds)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: t.Controls.input,
                    height: t.Controls.input,
                    decoration: BoxDecoration(border: Border.all(color: t.Borders.subtle, width: t.Borders.width), borderRadius: t.Radii.control),
                    alignment: Alignment.center,
                    child: AcpIcon(kindIcon(k), color: t.Neutral.muted),
                  ),
                  const SizedBox(height: t.Spacing.s8),
                  Text(k.wire, style: t.TextStyles.monoMeta),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
