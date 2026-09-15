// 画板 80 · ACP 流量调试：方向与方法名过滤、丢弃告警行、流量行与原文展开、暂停跟随、复制行、stderr 尾巴区。
// 数据源 lib/projection/traffic.dart（`acp/traffic`）。原始行在核心侧已脱敏（`Authorization` / `api_key` / `token` → `***`，
// 规则 8），本页不再处理也不落盘。未知变体整条丢失时，原始行是唯一可见性来源（acp-projection.md § 8.1 / § 8.4）。

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../projection/traffic.dart';
import '../../theme/tokens.dart' as t;
import '../shell/shell_common.dart';
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';

class TrafficPage extends StatefulWidget {
  const TrafficPage({
    super.key,
    required this.store,
    required this.filterController,
    required this.filterFocusNode,
    this.stderrAgentId,
    this.initiallyExpanded = const <int>{},
  });

  final TrafficStore store;
  final TextEditingController filterController;
  final FocusNode filterFocusNode;

  /// stderr 尾巴区显示哪个 agent（缺省取第一个有 stderr 的）。
  final String? stderrAgentId;

  /// gallery 出展开样张用。
  final Set<int> initiallyExpanded;

  @override
  State<TrafficPage> createState() => _TrafficPageState();
}

class _TrafficPageState extends State<TrafficPage> {
  late final Set<int> _expanded = <int>{...widget.initiallyExpanded};
  final ScrollController _scroll = ScrollController();
  TrafficDirection? _direction;
  String _query = '';
  bool _paused = false;
  bool _stderrExpanded = true;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 「跟随」= 新行到达后滚到底；「暂停跟随」后不再自动滚（画板 80）。
  void _follow() {
    if (_paused || !_scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_paused && _scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final lines = widget.store.filtered(direction: _direction, query: _query);
        _follow();
        return Padding(
          padding: const EdgeInsets.only(left: t.Spacing.s24, right: t.Spacing.s24, top: t.Spacing.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _header(),
              if (widget.store.droppedCount > 0) ...<Widget>[const SizedBox(height: t.Spacing.s12), _droppedBar()],
              const SizedBox(height: t.Spacing.s12),
              Expanded(child: _list(lines)),
              _stderrBox(),
            ],
          ),
        );
      },
    );
  }

  Widget _header() => Container(
        padding: const EdgeInsets.only(bottom: t.Spacing.s12),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
        child: Row(
          children: <Widget>[
            const Text('ACP 流量调试', style: t.TextStyles.title),
            const SizedBox(width: t.Spacing.s12),
            _directionChip('全部', null),
            _directionChip('← 收', TrafficDirection.inbound),
            _directionChip('→ 发', TrafficDirection.outbound),
            const SizedBox(width: t.Spacing.s12),
            _filterField(),
            const Spacer(),
            AcpButton(label: _paused ? '继续跟随' : '暂停跟随', onTap: () => setState(() => _paused = !_paused)),
            const SizedBox(width: t.Spacing.s4),
            AcpButton(label: '复制行', icon: AcpIcons.copy, onTap: _copyVisible),
          ],
        ),
      );

  Widget _directionChip(String label, TrafficDirection? direction) {
    final selected = _direction == direction;
    return Padding(
      padding: const EdgeInsets.only(right: t.Spacing.s4),
      child: Hoverable(
        onTap: () => setState(() => _direction = direction),
        builder: (context, hovered) => Container(
          height: t.Controls.compact,
          padding: t.Controls.padCompact,
          decoration: BoxDecoration(
            color: selected ? t.Overlays.selected : (hovered ? t.Overlays.hover : null),
            borderRadius: t.Radii.control,
          ),
          alignment: Alignment.center,
          child: Text(label, style: CardText.secondary.copyWith(color: selected ? t.Accent.text : t.Neutral.muted)),
        ),
      ),
    );
  }

  Widget _filterField() => Container(
        width: t.Geometry.trafficMethodWidth,
        height: t.Controls.standard,
        decoration: BoxDecoration(
          color: t.Neutral.panel,
          border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
          borderRadius: t.Radii.control,
        ),
        padding: t.Controls.padCompact,
        child: Row(
          children: <Widget>[
            const AcpIcon(AcpIcons.search, color: t.Neutral.placeholder, size: t.IconSizes.toolbar),
            const SizedBox(width: t.Spacing.s8),
            Expanded(
              child: AcpTextField(
                controller: widget.filterController,
                focusNode: widget.filterFocusNode,
                style: CardText.secondary.copyWith(color: t.Neutral.text),
                placeholder: '过滤方法名…',
                placeholderStyle: CardText.secondary.copyWith(color: t.Neutral.placeholder),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          ],
        ),
      );

  Widget _droppedBar() {
    final since = widget.store.firstDroppedAt;
    final sinceText = since == null
        ? ''
        : ' · since ${since.hour.toString().padLeft(2, '0')}:${since.minute.toString().padLeft(2, '0')}:${since.second.toString().padLeft(2, '0')}';
    return Container(
      decoration: BoxDecoration(
        color: t.Semantic.warningSoft,
        border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
        borderRadius: t.Radii.card,
      ),
      padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
      child: Row(
        children: <Widget>[
          const AcpIcon(AcpIcons.alertTriangle, color: t.Semantic.warning, size: t.IconSizes.toolbar),
          const SizedBox(width: t.Spacing.s8),
          Expanded(
            child: Text('${widget.store.droppedCount} 条未知会话更新已丢弃（sessionUpdate 反序列化失败）— 原文见下方高亮行',
                style: CardText.secondary.copyWith(color: t.Neutral.text), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          Text('dropped: ${widget.store.droppedCount}$sinceText', style: t.TextStyles.monoMeta.copyWith(color: t.Neutral.muted)),
        ],
      ),
    );
  }

  Widget _list(List<TrafficLine> lines) => Container(
        decoration: BoxDecoration(
          color: t.Surface.canvas,
          border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
          borderRadius: t.Radii.card,
        ),
        clipBehavior: Clip.hardEdge,
        child: ListView.builder(
          controller: _scroll,
          itemCount: lines.length,
          itemBuilder: (context, i) => TrafficRow(
            line: lines[i],
            expanded: _expanded.contains(lines[i].seq),
            onToggle: () => setState(() {
              if (!_expanded.remove(lines[i].seq)) _expanded.add(lines[i].seq);
            }),
          ),
        ),
      );

  Widget _stderrBox() {
    final agentId = widget.stderrAgentId ?? (widget.store.stderr.isEmpty ? null : widget.store.stderr.keys.first);
    final tail = agentId == null ? const <String>[] : (widget.store.stderr[agentId] ?? const <String>[]);
    if (tail.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: t.Spacing.s12, bottom: t.Spacing.s16),
      decoration: BoxDecoration(
        color: t.Surface.canvas,
        border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
        borderRadius: t.Radii.card,
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Hoverable(
            onTap: () => setState(() => _stderrExpanded = !_stderrExpanded),
            builder: (context, hovered) => Container(
              height: t.Controls.standard,
              color: hovered ? t.Overlays.hover : null,
              padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12),
              child: Row(
                children: <Widget>[
                  Text('stderr 尾巴', style: CardText.secondary.copyWith(
                    fontWeight: t.Weights.medium,
                    fontVariations: t.Weights.mediumVariation,
                    color: t.Neutral.strong,
                  )),
                  const SizedBox(width: t.Spacing.s8),
                  Expanded(child: Text('$agentId · 最后 ${tail.length} 行', style: t.TextStyles.monoMeta)),
                  Chevron(expanded: _stderrExpanded),
                ],
              ),
            ),
          ),
          if (_stderrExpanded)
            Container(
              width: double.infinity,
              decoration: const BoxDecoration(border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
              padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
              child: Text(tail.join('\n'), style: CardText.code.copyWith(color: t.Neutral.muted)),
            ),
        ],
      ),
    );
  }

  void _copyVisible() {
    final lines = widget.store.filtered(direction: _direction, query: _query);
    Clipboard.setData(ClipboardData(text: lines.map((l) => l.raw).join('\n')));
  }
}

/// 一行流量（可展开看原文）。
class TrafficRow extends StatelessWidget {
  const TrafficRow({super.key, required this.line, required this.expanded, this.onToggle});

  final TrafficLine line;
  final bool expanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final arrow = line.direction == TrafficDirection.outbound ? AcpIcons.arrowRight : AcpIcons.arrowLeft;
    final arrowColor = line.direction == TrafficDirection.outbound ? t.Semantic.success : t.Accent.text;
    return Container(
      decoration: BoxDecoration(
        color: line.dropped ? t.Semantic.warningSoft : null,
        border: const Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Hoverable(
            onTap: onToggle,
            builder: (context, hovered) => Container(
              height: t.Controls.standard,
              color: hovered && !line.dropped ? t.Overlays.hover : null,
              padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12),
              child: Row(
                children: <Widget>[
                  AcpIcon(arrow, color: arrowColor, size: t.IconSizes.toolbar),
                  const SizedBox(width: t.Spacing.s8),
                  SizedBox(
                    width: t.Geometry.trafficMethodWidth,
                    child: Text(line.displayMethod, style: t.TextStyles.mono, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: t.Spacing.s8),
                  line.dropped
                      ? Chip(line.label, background: t.Surface.popover, color: t.Semantic.warning)
                      : Chip(line.label, background: t.Neutral.surface, color: t.Neutral.muted),
                  const Spacer(),
                  Text(line.time, style: t.TextStyles.monoMeta.copyWith(color: line.dropped ? t.Neutral.muted : t.Neutral.placeholder)),
                  const SizedBox(width: t.Spacing.s8),
                  Chevron(expanded: expanded),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.only(left: t.Spacing.s12, right: t.Spacing.s12, bottom: t.Spacing.s8),
              child: line.dropped
                  ? Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: t.Surface.popover,
                        border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
                        borderRadius: t.Radii.control,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text.rich(JsonHighlight.span(line.raw)),
                          Text('→ 该变体未编译进 SessionUpdate，整条通知反序列化失败并被丢弃',
                              style: CardText.code.copyWith(color: t.Semantic.warning)),
                        ],
                      ),
                    )
                  : MonoBlock(span: JsonHighlight.span(line.pretty ?? line.raw)),
            ),
        ],
      ),
    );
  }
}
