// 画板 25 · 权限授权卡：session/request_permission · options[].kind = allow_once / allow_always / reject_once / reject_always。
// 头行 = kind 图标 + 标题 + 路径（accent 链接）；「View Raw Input」折叠 / 展开（请求里的 ToolCallUpdate 原样 JSON）；
// 底部 = Allow（主按钮 + Alt-Shift-A）· Deny（Alt-Shift-X）· 范围下拉（Ctrl-Alt-A，列出全部选项与 kind）。
// 请求里可能只有 toolCallId，标题与 kind 从已累积的 tool call 取；回应只有 selected / cancelled。

import 'package:flutter/widgets.dart';

import '../../projection/entries.dart';
import '../../projection/wire.dart';
import '../../theme/tokens.dart' as t;
import 'card_chrome.dart';
import 'icons.dart';
import 'tool_call_card.dart';

class PermissionCard extends StatefulWidget {
  const PermissionCard(
    this.entry, {
    super.key,
    this.toolCall,
    this.cwd,
    this.rawExpandedInitially = false,
    this.scopeOpenInitially = false,
    this.onAnswer,
    this.onOpenPath,
  });

  final PermissionEntry entry;

  /// 已累积的 tool call（请求可能只带 toolCallId）。
  final ToolCallEntry? toolCall;
  final String? cwd;
  final bool rawExpandedInitially;
  final bool scopeOpenInitially;
  final void Function(String optionId)? onAnswer;
  final void Function(String path)? onOpenPath;

  @override
  State<PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<PermissionCard> {
  late bool _raw = widget.rawExpandedInitially;
  late bool _scopeOpen = widget.scopeOpenInitially;
  String? _scopeId;

  List<PermissionOptionWire> get _options => widget.entry.options;

  PermissionOptionWire? _byKind(String kind) {
    for (final o in _options) {
      if (o.kind == kind) return o;
    }
    return null;
  }

  /// 当前范围：用户选过的；否则第一个 allow_once；否则第一个 allow_*。
  PermissionOptionWire? get _scope {
    if (_scopeId != null) {
      for (final o in _options) {
        if (o.optionId == _scopeId) return o;
      }
    }
    return _byKind('allow_once') ?? _byKind('allow_always');
  }

  PermissionOptionWire? get _deny => _byKind('reject_once') ?? _byKind('reject_always');

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final tc = widget.toolCall;
    final patch = e.toolCallPatch;
    final kind = ToolKind.tryParse(patch.kind) ?? tc?.kind ?? ToolKind.other;
    final title = patch.title ?? tc?.title ?? '(未命名工具调用)';
    final rawPath = _pathOf(patch) ?? (tc == null ? null : _pathOfEntry(tc));
    final path = rawPath == null ? null : displayPath(rawPath, cwd: widget.cwd);
    final scope = _scope;
    final deny = _deny;
    final answered = e.status != PendingStatus.pending;
    return TranscriptCard(
      // 范围下拉画在卡片之外，展开时不裁剪。
      clip: _scopeOpen ? Clip.none : Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CardHeader(
            leading: AcpIcon(kindIcon(kind), color: t.Neutral.muted),
            title: title,
            subtitleWidget: path == null
                ? null
                : GestureDetector(
                    onTap: () => widget.onOpenPath?.call(rawPath!),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Text(path, style: CardText.link.copyWith(height: t.LineHeights.control), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _raw = !_raw),
            child: Container(
              height: t.Controls.standard,
              padding: t.Controls.padInput,
              decoration: const BoxDecoration(border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
              child: Row(
                children: <Widget>[
                  Text('View Raw Input', style: CardText.secondary),
                  const SizedBox(width: t.Spacing.s4),
                  Chevron(expanded: _raw),
                ],
              ),
            ),
          ),
          if (_raw)
            Padding(
              padding: const EdgeInsets.only(left: t.Spacing.s12, right: t.Spacing.s12, bottom: t.Spacing.s8),
              child: MonoBlock(span: JsonHighlight.span(patch.json)),
            ),
          Container(
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
            padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
            child: Row(
              children: <Widget>[
                AcpButton(
                  label: 'Allow',
                  kind: ButtonKind.primary,
                  icon: AcpIcons.check,
                  kbd: 'Alt-Shift-A',
                  enabled: !answered && scope?.optionId != null,
                  onTap: scope?.optionId == null ? null : () => widget.onAnswer?.call(scope!.optionId!),
                ),
                const SizedBox(width: t.Spacing.s8),
                AcpButton(
                  label: 'Deny',
                  icon: AcpIcons.x,
                  iconColor: t.Semantic.error,
                  labelColor: t.Semantic.error,
                  kbd: 'Alt-Shift-X',
                  enabled: !answered && deny?.optionId != null,
                  onTap: deny?.optionId == null ? null : () => widget.onAnswer?.call(deny!.optionId!),
                ),
                const Spacer(),
                if (answered)
                  Text(_answeredLabel(e), style: CardText.secondary)
                else
                  Stack(
                    clipBehavior: Clip.none,
                    children: <Widget>[
                      AcpButton(
                        label: scope?.name ?? '—',
                        kbd: 'Ctrl-Alt-A',
                        trailing: Chevron(expanded: _scopeOpen),
                        onTap: () => setState(() => _scopeOpen = !_scopeOpen),
                      ),
                      if (_scopeOpen)
                        Positioned(
                          top: t.Controls.standard + t.Spacing.s4,
                          right: 0,
                          child: _ScopeMenu(
                            options: _options,
                            selectedId: scope?.optionId,
                            onPick: (o) => setState(() {
                              _scopeId = o.optionId;
                              _scopeOpen = false;
                            }),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _answeredLabel(PermissionEntry e) => switch (e.status) {
        PendingStatus.answered => '已选择 ${e.chosenOptionId}',
        PendingStatus.cancelled => '已随 session/cancel 取消',
        PendingStatus.withdrawn => 'agent 已撤回',
        _ => '',
      };

  static String? _pathOf(ToolCallWire w) {
    if (w.locations.isNotEmpty) return w.locations.first.path;
    final raw = w.rawInput;
    if (raw is Map && raw['path'] is String) return raw['path'] as String;
    return null;
  }

  static String? _pathOfEntry(ToolCallEntry e) {
    if (e.locations.isNotEmpty) return e.locations.first.path;
    final raw = e.rawInput;
    if (raw is Map && raw['path'] is String) return raw['path'] as String;
    return null;
  }
}

/// 范围下拉：每项 = 名称 + kind（mono meta）；选中项 surface 底 + accent 对勾。
class _ScopeMenu extends StatelessWidget {
  const _ScopeMenu({required this.options, required this.selectedId, required this.onPick});

  final List<PermissionOptionWire> options;
  final String? selectedId;
  final void Function(PermissionOptionWire o) onPick;

  /// 菜单宽度（几何，不是样式）：按画板 25 的下拉宽度。
  static const double _width = 330;

  @override
  Widget build(BuildContext context) {
    return Popover(
      padding: const EdgeInsets.all(t.Spacing.s4),
      child: SizedBox(
        width: _width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final o in options)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onPick(o),
                child: Container(
                  height: t.Controls.standard,
                  padding: t.Controls.padStandard,
                  decoration: BoxDecoration(color: o.optionId == selectedId ? t.Neutral.surface : null, borderRadius: t.Radii.chip),
                  child: Row(
                    children: <Widget>[
                      Expanded(child: Text(o.name ?? o.optionId ?? '', style: CardText.button, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      Text(o.kind ?? '', style: t.TextStyles.monoMeta),
                      if (o.optionId == selectedId) ...<Widget>[
                        const SizedBox(width: t.Spacing.s8),
                        const AcpIcon(AcpIcons.check, color: t.Accent.base, size: t.IconSizes.toolbar),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
