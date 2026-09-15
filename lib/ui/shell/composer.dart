// 画板 01 / 02 / 03 / 42 · 输入框：占位文案、`+`（画板 40 的上下文加入弹层）、Follow、用量圆环（画板 30）、
// 模型 / 思考强度 / 模式三个下拉（`config_option_update` 按 category 分配，画板 40）、发送 / 停止（`session/cancel`）。
// 上方可叠 Awaiting 停靠条（画板 26）与 `@` / `/` 内联菜单（画板 42）。
// 无已安装 agent 时（画板 01 状态 2 注）：三个下拉与用量圆环都不渲染，发送为禁用态。

import 'package:flutter/widgets.dart';

import '../../projection/usage.dart';
import '../../theme/tokens.dart' as t;
import '../transcript/card_chrome.dart';
import '../transcript/context_window.dart';
import '../transcript/icons.dart';
import 'shell_common.dart';

class Composer extends StatelessWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.placeholder,
    this.enabled = true,
    this.running = false,
    this.usage,
    this.model,
    this.thoughtLevel,
    this.mode,
    this.docks = const <Widget>[],
    this.inlineMenu,
    this.onChanged,
    this.onPlus,
    this.onFollow,
    this.onUsage,
    this.onModel,
    this.onThoughtLevel,
    this.onMode,
    this.onSend,
    this.onStop,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String placeholder;

  /// 有已连接的 agent 且有会话：否则输入与发送都禁用（画板 01 状态 2）。
  final bool enabled;

  /// 回合进行中：发送位换成停止方块。
  final bool running;
  final UsageState? usage;

  /// 三个下拉的当前值文案；`null` = 没有对应 category 的 configOption，该下拉不渲染。
  final String? model;
  final String? thoughtLevel;
  final String? mode;

  /// 输入框上方的停靠条，自上而下依次排：画板 29 的折叠计划条、画板 26 的 Awaiting 条。
  final List<Widget> docks;

  /// 画板 42 的 `@` / `/` 菜单。
  final Widget? inlineMenu;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onPlus;
  final VoidCallback? onFollow;
  final VoidCallback? onUsage;
  final VoidCallback? onModel;
  final VoidCallback? onThoughtLevel;
  final VoidCallback? onMode;
  final VoidCallback? onSend;
  final VoidCallback? onStop;

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
                Align(alignment: Alignment.centerLeft, child: inlineMenu!),
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
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: t.Controls.input + t.Spacing.s8),
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
            const SizedBox(height: t.Spacing.s4),
            _actions(),
          ],
        ),
      );

  Widget _actions() => Row(
        children: <Widget>[
          IconButtonGhost(
            icon: AcpIcons.plus,
            size: t.Controls.compact,
            color: enabled ? t.Neutral.muted : t.Neutral.border,
            onTap: enabled ? onPlus : null,
          ),
          if (enabled) ...<Widget>[
            const SizedBox(width: t.Spacing.s4),
            IconButtonGhost(icon: AcpIcons.target, size: t.Controls.compact, onTap: onFollow),
          ],
          if (usage != null) ...<Widget>[
            const SizedBox(width: t.Spacing.s4),
            Padding(
              padding: t.Controls.padCompact,
              child: UsageIndicator(usage: usage, onTap: onUsage),
            ),
          ],
          const Spacer(),
          if (model != null) ComposerDropdown(label: model!, onTap: onModel, maxWidth: t.Geometry.composerModelMaxWidth),
          if (thoughtLevel != null) ComposerDropdown(label: thoughtLevel!, onTap: onThoughtLevel),
          if (mode != null) ComposerDropdown(label: mode!, onTap: onMode),
          const SizedBox(width: t.Spacing.s4),
          if (running) _StopButton(onTap: onStop) else _SendButton(enabled: enabled, onTap: onSend),
        ],
      );
}

/// 输入框右下的下拉芯片（模型 / 思考强度 / 模式）。
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
          decoration: const BoxDecoration(color: t.Semantic.error, borderRadius: t.Radii.chip),
        ),
      ),
    );
  }
}
