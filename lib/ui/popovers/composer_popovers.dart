// 画板 40 · 输入框弹层合集：模型选择器（category model，分组 + 当前项对勾）、思考强度（thought_level）、
// 模式（mode；`current_mode_update` 的回退也走这里）、布尔型会话选项、未知分类的扁平兜底、
// `+` 的上下文加入弹层、用量弹层（复用画板 30 的 ContextPopover）、Follow 提示。
//
// 数据一律来自 `config_option_update` / `session/new` 的 `configOptions`（投影层 ConfigOptionWire）：
// - `category` ∈ mode / model / model_config / thought_level 时进对应下拉，未识别的 category 按扁平列表兜底、顺序照数组；
// - 未识别的 `type` 由投影层整条忽略（画板 40 注）；
// - `configOptions` 是全量替换，`session/set_config_option` 返回整份列表。
//
// 偏离：画板给模型行画了 provider 图标与 `Latest` 徽章，`SessionConfigSelectOption` 只有 value / name / description，
// 没有图标与「最新」字段（规则 2 不自造）。这里图标位用中性占位、`Latest` 徽章省略，已记 rounds/BACKLOG.md。

import 'package:flutter/widgets.dart';

import '../../projection/usage.dart';
import '../../projection/wire.dart';
import '../../theme/tokens.dart' as t;
import '../transcript/card_chrome.dart';
import '../transcript/context_window.dart';
import '../transcript/icons.dart';
import 'menu.dart';

/// `SessionConfigSelectOption`：`{value, name, description?}`。
class ConfigChoice {
  const ConfigChoice({required this.value, required this.name, this.description});

  final String value;
  final String name;
  final String? description;
}

/// 一组可选值：`name == null` 表示扁平（无分组）。
class ConfigGroup {
  const ConfigGroup({this.name, required this.choices});

  final String? name;
  final List<ConfigChoice> choices;
}

/// `SessionConfigSelectOptions` 的两种形状：扁平数组或 `{group, name, options}` 数组。
List<ConfigGroup> configGroups(ConfigOptionWire option) {
  final raw = option.options;
  if (raw.isEmpty) return const <ConfigGroup>[];
  final grouped = raw.first.containsKey('group') && raw.first['options'] is List;
  if (!grouped) return <ConfigGroup>[ConfigGroup(choices: raw.map(_choice).toList(growable: false))];
  return <ConfigGroup>[
    for (final g in raw)
      ConfigGroup(
        name: g['name'] as String?,
        choices: <ConfigChoice>[
          for (final o in (g['options'] as List? ?? const <Object?>[]))
            if (o is Map) _choice(o.cast<String, dynamic>()),
        ],
      ),
  ];
}

ConfigChoice _choice(Map<String, dynamic> json) => ConfigChoice(
      value: json['value'] as String? ?? '',
      name: json['name'] as String? ?? (json['value'] as String? ?? ''),
      description: json['description'] as String?,
    );

/// 当前值对应的 `name`（找不到就原样显示 id）。两种 options 形状的遍历在投影层
/// [ConfigOptionWire.currentOptionName]（画板 08 摘要行的模型名也用它），这里只补一个空串兜底。
String configCurrentName(ConfigOptionWire option) => option.currentOptionName ?? '';

/// select 型下拉（模型 / 思考强度 / 模式 / 未知分类里的某一条）。
/// `searchable` 时顶部出过滤框（画板 40 的模型选择器）；`showLeadingMark` 给模型行的中性图标占位。
class ConfigSelectPopover extends StatelessWidget {
  const ConfigSelectPopover({
    super.key,
    required this.option,
    this.title,
    this.searchController,
    this.searchFocusNode,
    this.searchPlaceholder = 'Select a model...',
    this.query = '',
    this.showLeadingMark = false,
    this.width = t.Geometry.menuWidthWide,
    this.hoveredValue,
    this.onSelect,
    this.onQueryChanged,
  });

  final ConfigOptionWire option;

  /// 无分组时的单个标题行（画板 40 思考强度的 `Change Thinking Effort`，取 `SessionConfigOption.name`）。
  final String? title;
  final TextEditingController? searchController;
  final FocusNode? searchFocusNode;
  final String searchPlaceholder;
  final String query;
  final bool showLeadingMark;
  final double width;

  /// gallery 出悬浮样张用。
  final String? hoveredValue;
  final ValueChanged<String>? onSelect;
  final ValueChanged<String>? onQueryChanged;

  @override
  Widget build(BuildContext context) {
    final current = option.currentValue;
    final groups = configGroups(option);
    final rows = <Widget>[];
    if (searchController != null && searchFocusNode != null) {
      rows.add(MenuSearchField(
        controller: searchController!,
        focusNode: searchFocusNode!,
        placeholder: searchPlaceholder,
        onChanged: onQueryChanged,
      ));
    }
    if (title != null) rows.add(MenuGroupLabel(title!));
    for (final g in groups) {
      final visible = <ConfigChoice>[
        for (final c in g.choices)
          if (query.isEmpty || c.name.toLowerCase().contains(query.toLowerCase())) c,
      ];
      if (visible.isEmpty) continue;
      if (g.name != null) rows.add(MenuGroupLabel(g.name!));
      for (final c in visible) {
        rows.add(MenuRow(
          leading: showLeadingMark ? AcpIcon(AcpIcons.dashedCircle, color: t.Neutral.muted, size: t.IconSizes.toolbar) : null,
          label: c.name,
          selected: c.value == current,
          forceHover: c.value == hoveredValue,
          onTap: onSelect == null ? null : () => onSelect!(c.value),
        ));
      }
    }
    return MenuPopover(width: width, children: rows);
  }
}

/// 布尔型会话选项（需声明 `session.configOptions.boolean`）。
class BooleanOptionsPopover extends StatelessWidget {
  const BooleanOptionsPopover({
    super.key,
    required this.options,
    this.title = 'Session options · boolean',
    this.width = t.Geometry.menuWidthWide,
    this.onToggle,
  });

  final List<ConfigOptionWire> options;
  final String title;
  final double width;

  /// `session/set_config_option`：`{"type":"boolean","value":<新值>}`。
  final void Function(String configId, bool value)? onToggle;

  @override
  Widget build(BuildContext context) {
    return MenuPopover(
      width: width,
      children: <Widget>[
        MenuGroupLabel(title),
        for (final o in options)
          MenuRow(
            label: o.name ?? o.id ?? '',
            trailing: MenuToggle(
              on: o.currentValue == true,
              onTap: onToggle == null ? null : () => onToggle!(o.id ?? '', o.currentValue != true),
            ),
            onTap: onToggle == null ? null : () => onToggle!(o.id ?? '', o.currentValue != true),
          ),
      ],
    );
  }
}

/// 未识别 category 的兜底：扁平列表，顺序照数组；每行右侧是当前值 + 展开箭头（点开各自的 select 弹层）。
class UnknownCategoryPopover extends StatelessWidget {
  const UnknownCategoryPopover({
    super.key,
    required this.options,
    this.title = '未知分类（category 不在 mode / model / model_config / thought_level）',
    this.note = '未识别的 category 按扁平列表兜底渲染，顺序照数组；未识别的 type 整条忽略',
    this.width = t.Geometry.menuWidthWide,
    this.onOpen,
  });

  final List<ConfigOptionWire> options;
  final String title;
  final String note;
  final double width;
  final ValueChanged<String>? onOpen;

  @override
  Widget build(BuildContext context) {
    return MenuPopover(
      width: width,
      children: <Widget>[
        MenuGroupLabel(title),
        for (final o in options)
          MenuRow(
            label: o.name ?? o.id ?? '',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(configCurrentName(o), style: t.TextStyles.monoMeta.copyWith(color: t.Neutral.muted)),
                const SizedBox(width: t.Spacing.s4),
                Chevron(expanded: false),
              ],
            ),
            onTap: onOpen == null ? null : () => onOpen!(o.id ?? ''),
          ),
        const MenuDivider(),
        MenuNote(note),
      ],
    );
  }
}

/// `+` 的上下文加入弹层（画板 40，裁定后只剩四项）：
/// Files & Directories → 输入框里插 `@`、弹画板 42 的 `@` 菜单 → `resource_link`；Sessions → 本地转录文本作 embedded resource；
/// Image → `image` 块（受 `promptCapabilities.image` 门）；Branch Diff → `git diff` 输出作 embedded resource。
class PlusPopover extends StatelessWidget {
  const PlusPopover({
    super.key,
    this.imageEnabled = true,
    this.width = t.Geometry.menuWidthNarrow,
    this.onFiles,
    this.onSessions,
    this.onImage,
    this.onBranchDiff,
  });

  /// `promptCapabilities.image`；无能力时该行不渲染。
  final bool imageEnabled;
  final double width;
  final VoidCallback? onFiles;
  final VoidCallback? onSessions;
  final VoidCallback? onImage;
  final VoidCallback? onBranchDiff;

  @override
  Widget build(BuildContext context) {
    return MenuPopover(
      width: width,
      children: <Widget>[
        MenuRow(icon: AcpIcons.file, label: 'Files & Directories', onTap: onFiles),
        MenuRow(icon: AcpIcons.messageSquare, label: 'Sessions', onTap: onSessions),
        if (imageEnabled) MenuRow(icon: AcpIcons.image, label: 'Image', onTap: onImage),
        MenuRow(icon: AcpIcons.gitBranch, label: 'Branch Diff', onTap: onBranchDiff),
      ],
    );
  }
}

/// 用量弹层（画板 30 / 40）：直接复用画板 30 的 ContextPopover，Rules 计数由组合根从项目根的规则文件得出。
class UsagePopover extends StatelessWidget {
  const UsagePopover({super.key, required this.usage, this.rulesCount = 0, this.onOpenRules});

  final UsageState? usage;
  final int rulesCount;
  final VoidCallback? onOpenRules;

  @override
  Widget build(BuildContext context) => ContextPopover(usage: usage, rulesCount: rulesCount, onOpenRules: onOpenRules);
}

/// Follow 提示（画板 40）：agent 名来自 `initialize` 的 `agentInfo`，不写死（规则 2）。
class FollowTip extends StatelessWidget {
  const FollowTip({super.key, required this.agentName, this.width = t.Geometry.menuWidth});

  final String agentName;
  final double width;

  @override
  Widget build(BuildContext context) {
    return MenuPopover(
      width: width,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s8, vertical: t.Spacing.s4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('Follow $agentName', style: CardText.secondary.copyWith(
                fontWeight: t.Weights.medium,
                fontVariations: t.Weights.mediumVariation,
                color: t.Neutral.strong,
              )),
              const SizedBox(height: t.Spacing.s4),
              Text("Track the agent's location as it reads and edits files.",
                  style: t.TextStyles.secondary.copyWith(height: t.LineHeights.body)),
            ],
          ),
        ),
      ],
    );
  }
}
