// 画板 70 · 设置：agent 配置（registry 型只读展开；custom 型行内编辑 cmd / args / env）、从 Zed 导入、Node 运行时、
// 数据目录与日志路径的打开 / 复制。只做这四块，没有外观设置（BACKLOG）。走 agent_settings_get / set / remove 与
// agent_settings_import_zed（接线阶段）。数据源 lib/projection/registry.dart 里已安装的条目。样式只取 tokens。

import 'package:flutter/widgets.dart';

import '../../projection/registry.dart';
import '../../theme/tokens.dart' as t;
import '../registry/registry_entry.dart';
import '../shell/shell_common.dart';
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';

/// custom 型行内编辑的三个输入（cmd / args / env；args 空格分隔，env 是 `K=V` 空格分隔）。
class CustomEditFields {
  const CustomEditFields({required this.command, required this.args, required this.env, required this.focus});

  final TextEditingController command;
  final TextEditingController args;
  final TextEditingController env;
  final FocusNode focus;
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.agents,
    required this.dataDir,
    this.logPath,
    this.zedSettingsPath,
    this.zedImportResult,
    this.node = const NodeStatus(),
    this.nodeProgress,
    this.expandedId,
    this.editingId,
    this.editFields,
    this.onEdit,
    this.onCollapse,
    this.onSave,
    this.onRemove,
    this.onImportZed,
    this.onDownloadNode,
    this.onOpenPath,
    this.onCopyPath,
  });

  /// 已安装的条目（registry 型 + custom 型）。
  final List<RegistryEntryData> agents;
  final String dataDir;
  final String? logPath;
  final String? zedSettingsPath;

  /// 上次导入的结果文案（「已导入 2 条，跳过同名 3 条」）。
  final String? zedImportResult;
  final NodeStatus node;
  final InstallProgress? nodeProgress;

  /// registry 型点「编辑」后只读展开的那一条。
  final String? expandedId;

  /// custom 型正在行内编辑的那一条（[editFields] 一并给）。
  final String? editingId;
  final CustomEditFields? editFields;
  final ValueChanged<String>? onEdit;
  final VoidCallback? onCollapse;
  final ValueChanged<String>? onSave;
  final ValueChanged<String>? onRemove;
  final VoidCallback? onImportZed;
  final VoidCallback? onDownloadNode;
  final ValueChanged<String>? onOpenPath;
  final ValueChanged<String>? onCopyPath;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: t.Surface.canvas,
      padding: const EdgeInsets.only(left: t.Spacing.s24, right: t.Spacing.s24, top: t.Spacing.s24),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: t.Geometry.settingsContentWidth),
          child: ListView(
            children: <Widget>[
              _title(),
              const SizedBox(height: t.Spacing.s16),
              _section('agent 配置', note: 'registry 型只读；custom 型可编辑 cmd / args / env', child: _agentsCard()),
              const SizedBox(height: t.Spacing.s16),
              _section('从 Zed 导入', child: _zedCard()),
              const SizedBox(height: t.Spacing.s16),
              _section('Node 运行时', child: _nodeCard()),
              const SizedBox(height: t.Spacing.s16),
              _section('数据目录与日志', child: _pathsCard()),
              const SizedBox(height: t.Spacing.s24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _title() => Container(
        padding: const EdgeInsets.only(bottom: t.Spacing.s8),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            const Text('设置', style: t.TextStyles.display),
            const SizedBox(width: t.Spacing.s8),
            Expanded(child: Text('agent 配置 · 从 Zed 导入 · Node 运行时 · 数据目录', style: t.TextStyles.secondary.copyWith(color: t.Neutral.placeholder))),
          ],
        ),
      );

  Widget _section(String title, {String? note, required Widget child}) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Text(title, style: CardText.strong),
              if (note != null) ...<Widget>[const SizedBox(width: t.Spacing.s8), Expanded(child: Text(note, style: t.TextStyles.meta))],
            ],
          ),
          const SizedBox(height: t.Spacing.s8),
          child,
        ],
      );

  // ---------------------------------------------------------------- agent 配置

  Widget _agentsCard() => TranscriptCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (agents.isEmpty)
              Padding(
                padding: const EdgeInsets.all(t.Spacing.s12),
                child: Text('还没有已安装或手填的 agent；到 Agents 面板安装，或从 Zed 导入。', style: t.TextStyles.secondary),
              ),
            for (var i = 0; i < agents.length; i++) ...<Widget>[
              if (agents[i].id == editingId && editFields != null)
                CustomEditBlock(agent: agents[i], fields: editFields!, onCancel: onCollapse, onSave: onSave == null ? null : () => onSave!(agents[i].id))
              else ...<Widget>[
                _agentRow(agents[i], last: i == agents.length - 1 && agents[i].id != expandedId),
                if (agents[i].id == expandedId) LaunchReadOnlyBlock(agent: agents[i], onCollapse: onCollapse),
              ],
            ],
          ],
        ),
      );

  Widget _agentRow(RegistryEntryData a, {required bool last}) {
    final chips = <Widget>[
      ToneChip(a.isCustom ? 'custom' : 'registry', tone: ChipTone.neutral),
      if (!a.isCustom && (a.installedVersion ?? a.version).isNotEmpty)
        Text('v${a.installedVersion ?? a.version}', style: t.TextStyles.monoMeta.copyWith(color: t.Neutral.muted)),
      if (a.loggedIn) const ToneChip('已登录', tone: ChipTone.success),
      if (a.needsAuth) const ToneChip('需要认证', tone: ChipTone.warning),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
      decoration: last ? null : const BoxDecoration(border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
      child: Row(
        children: <Widget>[
          AgentIconBox(svg: a.iconSvg),
          const SizedBox(width: t.Spacing.s12),
          Expanded(
            child: Wrap(
              spacing: t.Spacing.s8,
              runSpacing: t.Spacing.s4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Text(a.isCustom ? a.id : a.name, style: t.TextStyles.body.copyWith(color: t.Neutral.strong, height: t.LineHeights.control)),
                ...chips,
              ],
            ),
          ),
          const SizedBox(width: t.Spacing.s8),
          // 内置 agent（R7 的 sidecar）随包分发：既不可编辑也不可删（docs/design.md § 8）——
          // 它的 command / args 是按可执行文件位置合成的，存进 settings.json 换台机器就过期。
          // 两个按钮都置灰，不改布局。
          AcpButton(label: '编辑', onTap: onEdit == null || a.builtin ? null : () => onEdit!(a.id)),
          const SizedBox(width: t.Spacing.s4),
          RemoveButton(onTap: onRemove == null || a.builtin ? null : () => onRemove!(a.id)),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 从 Zed 导入

  Widget _zedCard() => TranscriptCard(
        child: SettingsRow(
          label: 'Zed settings.json',
          value: zedSettingsPath ?? '—',
          note: zedImportResult ?? '读取 agent_servers 段，导入为 custom 型配置；不覆盖同名项。',
          trailing: <Widget>[
            AcpButton(label: '从 Zed 导入', kind: ButtonKind.primary, icon: AcpIcons.download, enabled: zedSettingsPath != null, onTap: onImportZed),
          ],
        ),
      );

  // ---------------------------------------------------------------- Node 运行时

  Widget _nodeCard() {
    final system = node.system;
    final managed = node.managed;
    final p = nodeProgress;
    final downloading = p != null && p.isRunning;
    return TranscriptCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SettingsRow(
            label: '系统 Node',
            leading: system != null
                ? const AcpIcon(AcpIcons.checkCircle, color: t.Semantic.success, size: t.IconSizes.toolbar)
                : const AcpIcon(AcpIcons.slashCircle, color: t.Semantic.warning, size: t.IconSizes.toolbar),
            value: system != null ? '${system.version} · ${system.path}' : (node.systemError ?? '未检测到 Node ≥ ${node.minVersion.split('.').first}'),
            muted: system == null,
            bottomBorder: true,
          ),
          SettingsRow(
            label: '受管 Node',
            leading: managed != null ? const AcpIcon(AcpIcons.checkCircle, color: t.Semantic.success, size: t.IconSizes.toolbar) : null,
            value: managed != null
                ? '${managed.version} · ${managed.path}'
                : downloading
                    ? '${InstallSteps.labelOf(p, p.step)}${p.fraction == null ? '' : ' · ${(p.fraction! * 100).round()}%'}'
                    : (p != null && p.isFailed ? '下载失败 · ${p.error ?? ''}' : '未下载 · 供 npx 型 agent 使用，不改系统环境'),
            muted: managed == null,
            trailing: <Widget>[
              if (downloading)
                const Spinner()
              else if (managed == null)
                AcpButton(label: p != null && p.isFailed ? '重试' : '下载受管 Node', icon: AcpIcons.download, onTap: onDownloadNode),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 数据目录与日志

  Widget _pathsCard() => TranscriptCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SettingsRow(label: '数据目录', value: dataDir, trailing: _pathActions(dataDir), bottomBorder: true),
            SettingsRow(label: '日志路径', value: logPath ?? '（还没有日志文件）', muted: logPath == null, trailing: logPath == null ? const <Widget>[] : _pathActions(logPath!)),
          ],
        ),
      );

  List<Widget> _pathActions(String path) => <Widget>[
        AcpButton(label: '打开', icon: AcpIcons.folder, onTap: onOpenPath == null ? null : () => onOpenPath!(path)),
        const SizedBox(width: t.Spacing.s4),
        AcpButton(label: '复制', icon: AcpIcons.copy, onTap: onCopyPath == null ? null : () => onCopyPath!(path)),
      ];
}

/// 设置行：`[标签 160][值（mono 12）+ 注][尾部控件]`，10 / 12 内边距（就近取 s8 / s12）。
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.label,
    required this.value,
    this.note,
    this.leading,
    this.trailing = const <Widget>[],
    this.muted = false,
    this.bottomBorder = false,
  });

  final String label;
  final String value;
  final String? note;
  final Widget? leading;
  final List<Widget> trailing;
  final bool muted;
  final bool bottomBorder;

  @override
  Widget build(BuildContext context) {
    final valueStyle = t.TextStyles.monoMeta.copyWith(fontSize: t.TextStyles.secondary.fontSize, color: muted ? t.Neutral.muted : t.Neutral.text);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
      decoration: bottomBorder ? const BoxDecoration(border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width))) : null,
      child: Row(
        children: <Widget>[
          SizedBox(width: t.Geometry.settingsLabelWidth, child: Text(label, style: t.TextStyles.secondary)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    if (leading != null) ...<Widget>[leading!, const SizedBox(width: t.Spacing.s4)],
                    Flexible(child: Text(value, style: valueStyle, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ],
                ),
                if (note != null) ...<Widget>[const SizedBox(height: t.Spacing.s4), Text(note!, style: t.TextStyles.meta)],
              ],
            ),
          ),
          if (trailing.isNotEmpty) const SizedBox(width: t.Spacing.s12),
          ...trailing,
        ],
      ),
    );
  }
}

/// custom 型的行内编辑块（画板 70）：panel 底，标题行（id + custom 芯片 + 收起），cmd / args / env 三行输入，取消 / 保存。
class CustomEditBlock extends StatelessWidget {
  const CustomEditBlock({super.key, required this.agent, required this.fields, this.onCancel, this.onSave});

  final RegistryEntryData agent;
  final CustomEditFields fields;
  final VoidCallback? onCancel;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: t.Neutral.panel,
      padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _EditHeader(id: agent.id, kind: 'custom', onCollapse: onCancel),
          const SizedBox(height: t.Spacing.s8),
          _field('cmd', fields.command, focusNode: fields.focus, autofocus: true),
          const SizedBox(height: t.Spacing.s8),
          _field('args', fields.args),
          const SizedBox(height: t.Spacing.s8),
          _field('env', fields.env),
          const SizedBox(height: t.Spacing.s8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              AcpButton(label: '取消', onTap: onCancel),
              const SizedBox(width: t.Spacing.s4),
              AcpButton(label: '保存', kind: ButtonKind.primary, onTap: onSave),
            ],
          ),
        ],
      ),
    );
  }

  Widget _field(String label, TextEditingController controller, {FocusNode? focusNode, bool autofocus = false}) => Row(
        children: <Widget>[
          SizedBox(width: t.Geometry.settingsFieldLabelWidth, child: Text(label, style: t.TextStyles.secondary)),
          Expanded(
            child: Container(
              height: t.Controls.standard,
              decoration: BoxDecoration(
                color: t.Neutral.panel,
                border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
                borderRadius: t.Radii.control,
              ),
              padding: t.Controls.padStandard,
              alignment: Alignment.centerLeft,
              child: AcpTextField(
                controller: controller,
                focusNode: focusNode ?? FocusNode(),
                autofocus: autofocus,
                style: t.TextStyles.mono.copyWith(height: t.LineHeights.control),
              ),
            ),
          ),
        ],
      );
}

/// registry 型「编辑」展开的只读块：拉起参数来自 install.json（registry 型只读，画板 70 注）。
class LaunchReadOnlyBlock extends StatelessWidget {
  const LaunchReadOnlyBlock({super.key, required this.agent, this.onCollapse});

  final RegistryEntryData agent;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    final launch = agent.launch;
    final style = t.TextStyles.mono.copyWith(color: t.Neutral.muted, height: t.LineHeights.control);
    return Container(
      color: t.Neutral.panel,
      padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _EditHeader(id: agent.id, kind: 'registry', onCollapse: onCollapse),
          const SizedBox(height: t.Spacing.s8),
          if (launch == null)
            Text('还没有拉起记录（安装完成后写入 agents/${agent.id}/install.json）。', style: t.TextStyles.secondary)
          else ...<Widget>[
            _line('cmd', launch.command, style),
            const SizedBox(height: t.Spacing.s4),
            _line('args', launch.argsText, style),
            const SizedBox(height: t.Spacing.s4),
            _line('env', launch.envText, style),
          ],
        ],
      ),
    );
  }

  Widget _line(String label, String value, TextStyle style) => Row(
        children: <Widget>[
          SizedBox(width: t.Geometry.settingsFieldLabelWidth, child: Text(label, style: t.TextStyles.secondary)),
          Expanded(child: Text(value, style: style, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
      );
}

class _EditHeader extends StatelessWidget {
  const _EditHeader({required this.id, required this.kind, this.onCollapse});

  final String id;
  final String kind;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) => Row(
        children: <Widget>[
          Text(id, style: t.TextStyles.secondary.copyWith(color: t.Neutral.strong, fontWeight: t.Weights.medium, fontVariations: t.Weights.mediumVariation)),
          const SizedBox(width: t.Spacing.s8),
          ToneChip(kind, tone: ChipTone.neutral),
          const Spacer(),
          IconButtonGhost(icon: AcpIcons.chevronUp, color: t.Neutral.placeholder, size: t.Controls.compact, onTap: onCollapse),
        ],
      );
}
