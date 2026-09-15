// 画板 42 · 输入框内联菜单：`@` 提及（文件 / 文件夹 / 最近，经 `fs_search` 按名过滤）与 `/` 命令
// （`available_commands_update` 的全量列表，单组渲染——所有者裁定 2026-09-15，`AvailableCommand` 没有分组与来源字段）。
// `input` 目前只有 unstructured：`hint` 即参数提示，命令名后的整段文本原样作参数。
// `@` 能塞什么由 `promptCapabilities.{image, audio, embeddedContext}` 决定，缺能力时对应分组不出现（画板 42 注）。

import 'package:flutter/widgets.dart';

import '../../projection/wire.dart';
import '../../theme/tokens.dart' as t;
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';
import 'menu.dart';

/// `@` 菜单的一条：文件 / 目录 / 最近用过的文件。
class MentionItem {
  const MentionItem({required this.path, required this.name, required this.parent, this.isDirectory = false});

  /// 绝对路径（选中后作为 `resource_link` 的 uri）。
  final String path;

  /// 显示名（文件名或 `目录/`）。
  final String name;

  /// 所在目录（画板上行尾的 mono 文字）。
  final String parent;
  final bool isDirectory;
}

class MentionMenu extends StatelessWidget {
  const MentionMenu({
    super.key,
    this.files = const <MentionItem>[],
    this.directories = const <MentionItem>[],
    this.recent = const <MentionItem>[],
    this.selectedIndex = 0,
    this.width = t.Geometry.menuWidthInline,
    this.onPick,
  });

  final List<MentionItem> files;
  final List<MentionItem> directories;
  final List<MentionItem> recent;

  /// 键盘高亮项（跨三组的全局下标）。
  final int selectedIndex;
  final double width;
  final ValueChanged<MentionItem>? onPick;

  /// 三组拼起来的顺序（键盘上下键与 selectedIndex 用）。
  List<MentionItem> get items => <MentionItem>[...files, ...directories, ...recent];

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    var i = 0;
    void group(String label, List<MentionItem> list) {
      if (list.isEmpty) return;
      rows.add(MenuGroupLabel(label));
      for (final item in list) {
        final selected = i == selectedIndex;
        rows.add(MenuRow(
          icon: item.isDirectory ? AcpIcons.folder : AcpIcons.file,
          label: item.name,
          labelStyle: selected ? CardText.secondary.copyWith(color: t.Accent.text) : CardText.secondary.copyWith(color: t.Neutral.text),
          secondary: item.parent,
          secondaryStyle: t.TextStyles.monoMeta,
          selected: selected,
          trailing: const SizedBox.shrink(),
          onTap: onPick == null ? null : () => onPick!(item),
        ));
        i++;
      }
    }

    group('Files', files);
    group('Directories', directories);
    group('Recent', recent);
    return MenuPopover(width: width, children: rows);
  }
}

class SlashCommandMenu extends StatelessWidget {
  const SlashCommandMenu({
    super.key,
    required this.commands,
    this.selectedIndex = 0,
    this.width = t.Geometry.menuWidthInline,
    this.onPick,
  });

  final List<AvailableCommandWire> commands;
  final int selectedIndex;
  final double width;
  final ValueChanged<AvailableCommandWire>? onPick;

  @override
  Widget build(BuildContext context) {
    return MenuPopover(
      width: width,
      children: <Widget>[
        const MenuGroupLabel('Commands'),
        for (var i = 0; i < commands.length; i++) _row(commands[i], i == selectedIndex),
      ],
    );
  }

  Widget _row(AvailableCommandWire c, bool selected) {
    final hint = c.inputHint;
    return _CommandRow(
      name: '/${c.name ?? ''}',
      description: c.description ?? '',
      hint: hint,
      selected: selected,
      onTap: onPick == null ? null : () => onPick!(c),
    );
  }
}

/// `/` 菜单一行：命令名（mono）+ 描述 + 参数提示。
class _CommandRow extends StatelessWidget {
  const _CommandRow({required this.name, required this.description, this.hint, this.selected = false, this.onTap});

  final String name;
  final String description;
  final String? hint;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return MenuRow(
      icon: AcpIcons.command,
      label: name,
      labelStyle: t.TextStyles.mono.copyWith(color: selected ? t.Accent.text : t.Neutral.text),
      secondary: description,
      secondaryStyle: CardText.secondary,
      selected: selected,
      trailing: hint == null || hint!.isEmpty
          ? const SizedBox.shrink()
          : Text('<$hint>', style: t.TextStyles.monoMeta),
      onTap: onTap,
    );
  }
}
