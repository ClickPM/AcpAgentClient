// 画板 11 · 用户消息气泡：默认 / 点击聚焦 / 悬浮出 Edit · Copy · Restore / 编辑中（改文本 → Regenerate 截断后续并重起一轮）。
// `@` 提及芯片 = prompt 里的 resource_link / resource 块（等宽 12.5 · accent 文字 · accent.soft 底 · 圆角 3），可点落右栏文件面板。
// Restore / Regenerate = 本地截断其后投影块 + 同会话重发（所有者裁定 2026-09-15，agent 侧上下文不回退是已知限制）。

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../projection/entries.dart';
import '../../projection/wire.dart';
import '../../theme/tokens.dart' as t;
import 'card_chrome.dart';
import 'icons.dart';

enum UserMessageState { normal, focused, hovered, editing }

class UserMessage extends StatefulWidget {
  const UserMessage(
    this.entry, {
    super.key,
    this.initialState = UserMessageState.normal,
    this.focused = false,
    this.onOpenMention,
    this.onRestore,
    this.onRegenerate,
    this.showChipsDemo = false,
  });

  final MessageEntry entry;
  final UserMessageState initialState;

  /// 外部给的聚焦态（画板 43：时间线跳过来的落点）。与本地点击聚焦是**或**的关系，
  /// 清除由外部负责——转录区里再点一下别处就撤（见 `workbench_screen.dart` 的 `_focusedEntryId`）。
  final bool focused;
  final void Function(String uri)? onOpenMention;
  final VoidCallback? onRestore;

  /// 编辑后的新文本 → 本地截断 + 同会话重发。
  final void Function(String text)? onRegenerate;

  /// gallery：只渲染气泡，不用。
  final bool showChipsDemo;

  @override
  State<UserMessage> createState() => _UserMessageState();
}

class _UserMessageState extends State<UserMessage> {
  late UserMessageState _state = widget.initialState;
  late final TextEditingController _controller = TextEditingController(text: plainText(widget.entry));
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _editing => _state == UserMessageState.editing;

  /// 编辑框里的纯文本：text 块原样，提及块写成 `@name`（重发时 R3 再把 `@name` 还原成 resource_link）。
  /// `image` / `audio` 块不进编辑框、也不随重发带回：编辑历史消息只改文字、原图不保留，是产品取舍不是缺陷
  /// （所有者裁定 2026-09-23，与 Claude Code 的做法一致；见 rounds/BACKLOG-CLOSED.md）。
  static String plainText(MessageEntry e) {
    final b = StringBuffer();
    for (final block in e.blocks) {
      switch (block.type) {
        case ContentBlockType.text:
          b.write(block.text ?? '');
        case ContentBlockType.resourceLink:
          b.write('@${block.name ?? block.title ?? block.uri ?? ''}');
        case ContentBlockType.resource:
          b.write('@${_display(block.resource?.uri)}');
        default:
          break;
      }
    }
    return b.toString();
  }

  void _set(UserMessageState s) => setState(() => _state = s);

  Future<void> _copy() => Clipboard.setData(ClipboardData(text: widget.entry.text));

  @override
  Widget build(BuildContext context) {
    if (_editing) return _editor();
    final focused = _state == UserMessageState.focused || widget.focused;
    final hovered = _state == UserMessageState.hovered;
    final bubble = MouseRegion(
      onEnter: (_) => _state == UserMessageState.normal ? _set(UserMessageState.hovered) : null,
      onExit: (_) => _state == UserMessageState.hovered ? _set(UserMessageState.normal) : null,
      child: GestureDetector(
        onTap: () => _set(focused ? UserMessageState.normal : UserMessageState.focused),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: t.Neutral.panel,
            borderRadius: t.Radii.card,
            border: Border.all(color: focused ? t.FocusRing.color : t.Neutral.panel, width: t.FocusRing.width),
          ),
          padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s16, vertical: t.Spacing.s12),
          child: Text.rich(_spans(), style: t.TextStyles.body),
        ),
      ),
    );
    if (!hovered) return bubble;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        bubble,
        Positioned(
          top: -t.Spacing.s16,
          right: t.Spacing.s8,
          child: Popover(
            padding: const EdgeInsets.all(t.Spacing.s4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButtonGhost(icon: AcpIcons.pencil, size: t.Controls.compact, onTap: () => _set(UserMessageState.editing)),
                IconButtonGhost(icon: AcpIcons.copy, size: t.Controls.compact, onTap: _copy),
                IconButtonGhost(icon: AcpIcons.rotateCcw, size: t.Controls.compact, onTap: widget.onRestore),
              ],
            ),
          ),
        ),
      ],
    );
  }

  TextSpan _spans() {
    final children = <InlineSpan>[];
    for (final b in widget.entry.blocks) {
      switch (b.type) {
        case ContentBlockType.text:
          children.add(TextSpan(text: b.text ?? ''));
        case ContentBlockType.resourceLink:
          children.add(_chip(b.name ?? b.title ?? b.uri ?? '', b.uri));
        case ContentBlockType.resource:
          final uri = b.resource?.uri;
          children.add(_chip(_display(uri), uri));
        case ContentBlockType.image:
          // 从文件来的图带 `uri`（`+` 选的 / 剪贴板里复制的文件），芯片就显示文件名；截图没有来源，显示 image。
          final name = _display(b.uri);
          children.add(_chip(name.isEmpty ? 'image' : name, b.uri));
        case ContentBlockType.audio:
          children.add(_chip('audio', null));
        case ContentBlockType.unknown:
          children.add(TextSpan(text: b.rawType ?? ''));
      }
    }
    return TextSpan(children: children);
  }

  static String _display(String? uri) {
    if (uri == null) return '';
    final u = Uri.tryParse(uri);
    final segs = u?.pathSegments ?? const <String>[];
    return segs.isEmpty ? uri : segs.last;
  }

  InlineSpan _chip(String label, String? uri) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: MentionChip(label: '@$label', onTap: uri == null ? null : () => widget.onOpenMention?.call(uri)),
    );
  }

  Widget _editor() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(color: t.Neutral.panel, borderRadius: t.Radii.card),
      padding: const EdgeInsets.all(t.Spacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            decoration: BoxDecoration(
              color: t.Surface.popover,
              borderRadius: t.Radii.control,
              border: Border.all(color: t.FocusRing.color, width: t.FocusRing.width),
            ),
            padding: const EdgeInsets.all(t.Spacing.s12),
            child: EditableText(
              controller: _controller,
              focusNode: _focus,
              style: t.TextStyles.body,
              cursorColor: t.Accent.base,
              backgroundCursorColor: t.Neutral.surface,
              maxLines: null,
              autofocus: true,
            ),
          ),
          const SizedBox(height: t.Spacing.s12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              AcpButton(label: 'Cancel', onTap: () => _set(UserMessageState.normal)),
              const SizedBox(width: t.Spacing.s8),
              AcpButton(
                label: 'Regenerate',
                kind: ButtonKind.primary,
                onTap: () {
                  widget.onRegenerate?.call(_controller.text);
                  _set(UserMessageState.normal);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// `@` 提及芯片：默认 accent.soft 底；悬浮加 6% 深色容器。
class MentionChip extends StatefulWidget {
  const MentionChip({super.key, required this.label, this.onTap, this.hoveredInitially = false});

  final String label;
  final VoidCallback? onTap;
  final bool hoveredInitially;

  @override
  State<MentionChip> createState() => _MentionChipState();
}

class _MentionChipState extends State<MentionChip> {
  late bool _hover = widget.hoveredInitially;

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      decoration: BoxDecoration(color: t.Accent.soft, borderRadius: t.Radii.chip),
      foregroundDecoration: _hover ? BoxDecoration(color: t.Overlays.hover, borderRadius: t.Radii.chip) : null,
      padding: t.Spacing.chip,
      child: Text(widget.label, style: t.TextStyles.mono.copyWith(color: t.Accent.text)),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = widget.hoveredInitially),
      child: GestureDetector(onTap: widget.onTap, child: chip),
    );
  }
}

/// 给 Text.rich 用的可点芯片 recognizer（保留给未来的纯文本芯片）。
TapGestureRecognizer tapRecognizer(VoidCallback onTap) => TapGestureRecognizer()..onTap = onTap;
