// 画板 25 · 权限授权卡：session/request_permission · options[].kind = allow_once / allow_always / reject_once / reject_always。
// 头行 = kind 图标 + 标题 + 路径（accent 链接）；「View Raw Input」折叠 / 展开（请求里的 ToolCallUpdate 原样 JSON）；
// 底部 = Allow（主按钮）· Deny · 范围下拉（列出全部选项与 kind）。
// 画板上三个按钮各标了一个快捷键（Alt-Shift-A / Alt-Shift-X / Ctrl-Alt-A），但快捷键从没接过按键处理；
// 2026-09-18 所有者裁定去掉这三个装饰标签（设计稿补注记见 rounds/BACKLOG.md）。
// 范围下拉走 [PopoverAnchor] 浮在 Overlay 上：之前画在卡片自己的 Stack 里，转录列表里下一张卡绘制顺序更晚，会把菜单压住。
// 请求里可能只有 toolCallId，标题与 kind 从已累积的 tool call 取；回应只有 selected / cancelled。

import 'package:flutter/widgets.dart';

import '../../projection/entries.dart';
import '../../projection/wire.dart';
import '../../theme/tokens.dart' as t;
import '../shell/popover_anchor.dart';
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

  /// 一挂上就把范围下拉打开（画板对照的静态样张用；需要 Overlay 祖先）。
  final bool scopeOpenInitially;
  final void Function(String optionId)? onAnswer;
  final void Function(String path)? onOpenPath;

  @override
  State<PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<PermissionCard> {
  late bool _raw = widget.rawExpandedInitially;

  /// 范围下拉的锚点句柄（放 State 里，别每帧新建）；`_scopeOpen` 只管 chevron 的朝向，
  /// 点外 / Esc 关掉时由 `onDismiss` 同步回来。
  final PopoverHandle _scopeMenu = PopoverHandle();
  bool _scopeOpen = false;
  String? _scopeId;

  List<PermissionOptionWire> get _options => widget.entry.options;

  @override
  void initState() {
    super.initState();
    if (widget.scopeOpenInitially) {
      // 锚点的 OverlayPortal 要先挂上才能显示，推到首帧之后。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openScope();
      });
    }
  }

  @override
  void dispose() {
    _scopeMenu.dispose();
    super.dispose();
  }

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

  void _openScope() {
    _scopeMenu.show(
      // OverlayPortal 每帧重建 overlay child，builder 直接读当前状态。
      (_) => _PermissionScopeMenu(options: _options, selectedId: _scope?.optionId, onPick: _pickScope),
      targetAnchor: Alignment.bottomRight,
      followerAnchor: Alignment.topRight,
      onDismiss: () {
        if (mounted) setState(() => _scopeOpen = false);
      },
    );
    setState(() => _scopeOpen = true);
  }

  void _toggleScope() {
    if (_scopeOpen) {
      _scopeMenu.hide();
      setState(() => _scopeOpen = false);
    } else {
      _openScope();
    }
  }

  void _pickScope(PermissionOptionWire o) {
    _scopeMenu.hide();
    setState(() {
      _scopeId = o.optionId;
      _scopeOpen = false;
    });
  }

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
              decoration: BoxDecoration(border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
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
            decoration: BoxDecoration(border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
            padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
            child: Row(
              children: <Widget>[
                AcpButton(
                  label: 'Allow',
                  kind: ButtonKind.primary,
                  icon: AcpIcons.check,
                  enabled: !answered && scope?.optionId != null,
                  onTap: scope?.optionId == null ? null : () => widget.onAnswer?.call(scope!.optionId!),
                ),
                const SizedBox(width: t.Spacing.s8),
                AcpButton(
                  label: 'Deny',
                  icon: AcpIcons.x,
                  iconColor: t.Semantic.error,
                  labelColor: t.Semantic.error,
                  enabled: !answered && deny?.optionId != null,
                  onTap: deny?.optionId == null ? null : () => widget.onAnswer?.call(deny!.optionId!),
                ),
                const Spacer(),
                if (answered)
                  Text(_answeredLabel(e), style: CardText.secondary)
                else
                  PopoverAnchor(
                    handle: _scopeMenu,
                    child: AcpButton(
                      label: scope?.name ?? '—',
                      trailing: Chevron(expanded: _scopeOpen),
                      onTap: _toggleScope,
                    ),
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
        PendingStatus.withdrawn => 'agent 已不再等待',
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
/// 由 [PermissionCard] 挂到 Overlay 上。
class _PermissionScopeMenu extends StatelessWidget {
  const _PermissionScopeMenu({required this.options, required this.selectedId, required this.onPick});

  final List<PermissionOptionWire> options;
  final String? selectedId;
  final void Function(PermissionOptionWire o) onPick;

  /// 菜单宽度（几何，不是样式）：按画板 25 的下拉宽度。

  @override
  Widget build(BuildContext context) {
    return Popover(
      padding: const EdgeInsets.all(t.Spacing.s4),
      child: SizedBox(
        width: t.Geometry.permissionMenuWidth,
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
                        AcpIcon(AcpIcons.check, color: t.Accent.base, size: t.IconSizes.toolbar),
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
