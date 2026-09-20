// 画板 01 / 02 / 03 / 42 · 输入框：占位文案、`+`（画板 40 的上下文加入弹层）、Follow、用量圆环（画板 30）、
// 会话配置格（`configOptions` 与 modes 回退平铺，画板 40）、发送 / 停止（`session/cancel`）。
// 上方可叠 Awaiting 停靠条（画板 26）与 `@` / `/` 内联菜单（画板 42）。
// 输入行之上还有待发图片的芯片条（composer_attachments.dart，所有者 2026-09-18 直接要求，设计稿外的增补）。
// 无已安装 agent 时（画板 01 状态 2 注）：配置格与用量圆环都不渲染，发送为禁用态。

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../projection/usage.dart';
import '../../projection/wire.dart';
import '../../theme/tokens.dart' as t;
import '../popovers/menu.dart';
import '../transcript/card_chrome.dart';
import '../transcript/context_window.dart';
import '../transcript/icons.dart';
import 'composer_attachments.dart';
import 'popover_anchor.dart';
import 'shell_common.dart';
import 'tooltip.dart';

class Composer extends StatelessWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.placeholder,
    this.enabled = true,
    this.running = false,
    this.usage,
    this.options = const <ComposerOption>[],
    this.docks = const <Widget>[],
    this.attachments = const <ContentBlockWire>[],
    this.onRemoveAttachment,
    this.onPaste,
    this.inlineMenu,
    this.onInlineMenuMove,
    this.onInlineMenuPick,
    this.onInlineMenuDismiss,
    this.onChanged,
    this.onPlus,
    this.onFollow,
    this.followOn = false,
    this.onUsage,
    this.onSend,
    this.onStop,
    this.plusAnchor,
    this.followAnchor,
    this.usageAnchor,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String placeholder;

  /// 有已连接的 agent 且有会话：否则输入与发送都禁用（画板 01 状态 2）。
  final bool enabled;

  /// 回合进行中：发送位换成停止方块。
  final bool running;
  final UsageState? usage;

  /// 输入框右下的会话配置格，从左到右照给的顺序排（档序归组合根定，见 workbench_controller.dart）：
  /// select 型是下拉芯片，boolean 型是就地开关（画板 40）。空列表 = 没连上 agent 或 agent 不发 configOptions。
  final List<ComposerOption> options;

  /// 输入框上方的停靠条，自上而下依次排：画板 29 的折叠计划条、画板 26 的 Awaiting 条。
  final List<Widget> docks;

  /// 待随下一条 prompt 发出的图片块（`+` 的 Image 与 Ctrl+V 粘贴）：输入框顶部的芯片条，悬浮出预览。
  final List<ContentBlockWire> attachments;
  final ValueChanged<ContentBlockWire>? onRemoveAttachment;

  /// Ctrl/Cmd+V：剪贴板里是图片时加成附件块。文本粘贴仍归 `EditableText` 自己（见 [_onKeyEvent]）。
  final VoidCallback? onPaste;

  /// 画板 42 的 `@` / `/` 菜单。
  final Widget? inlineMenu;

  /// 菜单开着时的键盘操作（都由组合根实现）：上下键移动高亮（`-1` / `+1`）、Enter 选中、Esc 关掉。
  final ValueChanged<int>? onInlineMenuMove;
  final VoidCallback? onInlineMenuPick;
  final VoidCallback? onInlineMenuDismiss;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onPlus;
  final VoidCallback? onFollow;

  /// Follow 开关（客户端本地态，画板 40 的提示）：开着时图标走 accent。
  final bool followOn;
  final VoidCallback? onUsage;
  final VoidCallback? onSend;
  final VoidCallback? onStop;

  /// 画板 40 里固定那三个弹层的锚点（配置格各自的锚点在 [ComposerOption.anchor]；gallery 里为 null）。
  final PopoverHandle? plusAnchor;
  final PopoverHandle? followAnchor;
  final PopoverHandle? usageAnchor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: t.Spacing.s16, right: t.Spacing.s16, bottom: t.Spacing.s16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: t.Geometry.contentMaxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (inlineMenu != null) ...<Widget>[
                // Esc 走全局处理器而不是下面那个 `Focus`：鼠标在别处点过之后焦点就不在输入框里了，
                // 键事件再也不经过输入框的焦点链（所有者手测 2026-09-18）。
                Align(
                  alignment: Alignment.centerLeft,
                  child: EscapeDismissible(onDismiss: onInlineMenuDismiss, child: inlineMenu!),
                ),
                const SizedBox(height: t.Spacing.s8),
              ],
              for (final dock in docks) ...<Widget>[dock, const SizedBox(height: t.Spacing.s8)],
              _box(),
            ],
          ),
        ),
      ),
    );
  }

  /// Enter 发送、Shift+Enter 换行（所有者裁定 2026-09-17）。`Focus` 在 `EditableText` 之上，
  /// 拦下来（`handled`）引擎就不会再把这一下翻成换行字符，上下键也不会再落到 `DefaultTextEditingShortcuts`
  /// 去挪光标。
  /// 中文 IME 组合窗开着时（`composing` 有效）一律放行：那一下 Enter 是给候选词上屏用的，上下键是翻候选页的。
  ///
  /// `@` / `/` 菜单开着时（画板 42）这两个键归菜单：上下键移动高亮（按住连发，所以 repeat 也收）、
  /// Enter 把高亮项填进输入框（不发送）。菜单关着时一切照旧——上下键仍是多行文本里的换行移动。
  /// Esc 不在这里：它归菜单自己的 [EscapeDismissible]，焦点不在输入框时也得管用。
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (controller.value.composing.isValid) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (inlineMenu != null) {
      if (key == LogicalKeyboardKey.arrowDown) {
        onInlineMenuMove?.call(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        onInlineMenuMove?.call(-1);
        return KeyEventResult.handled;
      }
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // Ctrl/Cmd+V：顺带看一眼剪贴板里有没有图（截图 / 图片文件），有就加成附件块。
    // 一律 `ignored`：这一下是不是文本粘贴要读完剪贴板才知道，而按键回调必须同步返回，
    // 所以文本粘贴照旧交给 `EditableText`，`onPaste` 那边先看剪贴板里是不是文本、是就什么都不做。
    // Shift / Alt 一起按的不算：Ctrl+Shift+V（「粘贴为纯文本」的习惯键）Flutter 自己不认，
    // 不排掉的话它也会拉一次 powershell 读剪贴板、剪贴板里有位图时还静默多出一枚芯片。
    if (key == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed) &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !HardwareKeyboard.instance.isAltPressed) {
      if (enabled) onPaste?.call();
      return KeyEventResult.ignored;
    }
    if (key != LogicalKeyboardKey.enter && key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    if (inlineMenu != null) {
      onInlineMenuPick?.call();
      return KeyEventResult.handled;
    }
    // 禁用态与回合进行中都不发（发送位此时是停止方块），但也不落回换行：Enter 的含义保持唯一。
    if (enabled && !running) onSend?.call();
    return KeyEventResult.handled;
  }

  Widget _box() => Container(
        decoration: BoxDecoration(
          color: t.Neutral.panel,
          border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
          borderRadius: t.Radii.card,
        ),
        padding: const EdgeInsets.fromLTRB(t.Spacing.s12, t.Spacing.s12, t.Spacing.s12, t.Spacing.s8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (attachments.isNotEmpty) ...<Widget>[
              ComposerAttachments(blocks: attachments, onRemove: onRemoveAttachment),
              const SizedBox(height: t.Spacing.s8),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: t.Controls.input + t.Spacing.s8),
              child: Focus(
                canRequestFocus: false,
                onKeyEvent: _onKeyEvent,
                child: AcpTextField(
                  controller: controller,
                  focusNode: focusNode,
                  style: t.TextStyles.body,
                  placeholder: placeholder,
                  placeholderStyle: t.TextStyles.body.copyWith(color: t.Neutral.placeholder),
                  maxLines: null,
                  minLines: null,
                  onChanged: onChanged,
                ),
              ),
            ),
            const SizedBox(height: t.Spacing.s4),
            _actions(),
          ],
        ),
      );

  Widget _actions() => Row(
        children: <Widget>[
          AcpTooltip(
            message: 'Add context',
            child: PopoverAnchor(
              handle: plusAnchor,
              child: IconButtonGhost(
                icon: AcpIcons.plus,
                size: t.Controls.compact,
                color: enabled ? t.Neutral.muted : t.Neutral.border,
                onTap: enabled ? onPlus : null,
              ),
            ),
          ),
          if (enabled) ...<Widget>[
            const SizedBox(width: t.Spacing.s4),
            AcpTooltip(
              message: 'Follow agent',
              child: PopoverAnchor(
                handle: followAnchor,
                child: IconButtonGhost(
                  icon: AcpIcons.target,
                  size: t.Controls.compact,
                  color: followOn ? t.Accent.text : t.Neutral.muted,
                  onTap: onFollow,
                ),
              ),
            ),
          ],
          if (usage != null) ...<Widget>[
            const SizedBox(width: t.Spacing.s4),
            PopoverAnchor(
              handle: usageAnchor,
              child: Padding(
                padding: t.Controls.padCompact,
                child: UsageIndicator(usage: usage, onTap: onUsage),
              ),
            ),
          ],
          const Spacer(),
          for (final o in options)
            if (o.on == null)
              PopoverAnchor(
                handle: o.anchor,
                child: ComposerDropdown(label: o.label, onTap: o.onTap, maxWidth: o.maxWidth),
              )
            else
              ComposerToggle(label: o.label, on: o.on!, onTap: o.onToggle),
          const SizedBox(width: t.Spacing.s4),
          if (running) _StopButton(onTap: onStop) else _SendButton(enabled: enabled, onTap: onSend),
        ],
      );
}

/// 输入框右下的一格会话配置（画板 40）：`on == null` 是 select 下拉芯片，否则是 boolean 就地开关。
/// 一条 `configOption` 一格、不按 category 合并，未识别的 category 也照样有格（ACP v1 session-config-options：
/// 「Clients MUST handle missing or unknown categories gracefully」）。
class ComposerOption {
  const ComposerOption({
    required this.label,
    this.anchor,
    this.onTap,
    this.on,
    this.onToggle,
    this.maxWidth,
  });

  /// select 型是当前值的展示名，boolean 型是这条选项自己的名字（开关本身表达值）。
  final String label;

  /// select 型的弹层锚点（gallery 里为 null）。
  final PopoverHandle? anchor;
  final VoidCallback? onTap;

  /// boolean 型的当前值；`null` 表示这是 select 型。
  final bool? on;
  final VoidCallback? onToggle;

  /// 太长的当前值要截断的那格（模型名），其余不限宽。
  final double? maxWidth;
}

/// 输入框右下的下拉芯片（会话配置里的 select 型）。
class ComposerDropdown extends StatelessWidget {
  const ComposerDropdown({super.key, required this.label, this.onTap, this.maxWidth});

  final String label;
  final VoidCallback? onTap;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: t.Spacing.s4),
      child: Hoverable(
        onTap: onTap,
        builder: (context, hovered) => Container(
          height: t.Controls.compact,
          padding: t.Controls.padCompact,
          decoration: BoxDecoration(color: hovered ? t.Overlays.hover : null, borderRadius: t.Radii.control),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth ?? double.infinity),
                child: Text(label, style: CardText.secondary.copyWith(color: t.Neutral.text), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: t.Spacing.s4),
              const Chevron(expanded: false),
            ],
          ),
        ),
      ),
    );
  }
}

/// 输入框右下的开关格（会话配置里的 boolean 型）：标签在左、开关在右，与下拉芯片同排同高
/// （照 Zed 的做法，不再单开一个面板）。
class ComposerToggle extends StatelessWidget {
  const ComposerToggle({super.key, required this.label, required this.on, this.onTap});

  final String label;
  final bool on;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: t.Spacing.s4),
      child: Hoverable(
        onTap: onTap,
        builder: (context, hovered) => Container(
          height: t.Controls.compact,
          padding: t.Controls.padCompact,
          decoration: BoxDecoration(color: hovered ? t.Overlays.hover : null, borderRadius: t.Radii.control),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(label, style: CardText.secondary.copyWith(color: t.Neutral.text), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(width: t.Spacing.s4),
              MenuToggle(on: on, onTap: onTap),
            ],
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.enabled, this.onTap});

  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Hoverable(
      onTap: enabled ? onTap : null,
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      builder: (context, hovered) => Container(
        width: t.Controls.standard,
        height: t.Controls.standard,
        decoration: BoxDecoration(
          color: enabled ? (hovered ? t.Accent.active : t.Accent.base) : t.Neutral.surface,
          borderRadius: t.Radii.control,
        ),
        alignment: Alignment.center,
        child: AcpIcon(AcpIcons.arrowUp, color: enabled ? t.Accent.onAccent : t.Neutral.placeholder),
      ),
    );
  }
}

/// 停止（`session/cancel`）：发送位换成 error 色方块（画板 02）。
class _StopButton extends StatelessWidget {
  const _StopButton({this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Hoverable(
      onTap: onTap,
      builder: (context, hovered) => Container(
        width: t.Controls.standard,
        height: t.Controls.standard,
        decoration: BoxDecoration(color: hovered ? t.Overlays.active : t.Overlays.hover, borderRadius: t.Radii.control),
        alignment: Alignment.center,
        child: Container(
          width: t.Spacing.s12,
          height: t.Spacing.s12,
          decoration: BoxDecoration(color: t.Semantic.error, borderRadius: t.Radii.chip),
        ),
      ),
    );
  }
}
