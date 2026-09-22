// 画板 50 · Agents 面板（ACP Registry）：右栏 Agents 标签的正文。标题 + Learn More、搜索、All / Installed / Not Installed
// 计数、条目列表（行 widget 在 registry_entry.dart）、缺 Node 时的受管 Node 提示卡（画板 51）。
// 数据源 lib/projection/registry.dart；registry.json 给 name / version / desc / id / repo，安装状态是本地态。样式只取 tokens。

import 'package:flutter/widgets.dart';

import '../../projection/registry.dart';
import '../../theme/tokens.dart' as t;
import '../shell/shell_common.dart';
import '../transcript/icons.dart';
import 'registry_entry.dart';

/// 官方 registry 的说明页（画板 50 的 Learn More）。
const String registryLearnMoreUrl = 'https://agentclientprotocol.com/registry';

class RegistryPanel extends StatelessWidget {
  const RegistryPanel({
    super.key,
    required this.entries,
    required this.searchController,
    required this.searchFocusNode,
    this.query = '',
    this.filter = RegistryFilter.all,
    this.installedCount = 0,
    this.notInstalledCount = 0,
    this.node = const NodeStatus(),
    this.nodeProgress,
    this.fetchError,
    this.fetching = false,
    this.showLogFor = const <String>{},
    this.onSearchChanged,
    this.onFilter,
    this.onLearnMore,
    this.onDownloadNode,
    this.actionsFor,
  });

  /// 过滤 + 搜索之后要显示的条目。
  final List<RegistryEntryData> entries;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final String query;
  final RegistryFilter filter;

  /// 三个计数（All = 两者之和）。
  final int installedCount;
  final int notInstalledCount;
  final NodeStatus node;
  final InstallProgress? nodeProgress;
  final String? fetchError;
  final bool fetching;

  /// 失败态展开了日志块的条目（画板 51「查看日志」切换）。
  final Set<String> showLogFor;
  final ValueChanged<String>? onSearchChanged;
  final ValueChanged<RegistryFilter>? onFilter;
  final VoidCallback? onLearnMore;
  final VoidCallback? onDownloadNode;
  final RegistryEntryActions Function(RegistryEntryData entry)? actionsFor;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: t.Surface.canvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _header(),
          Expanded(child: _list()),
        ],
      ),
    );
  }

  Widget _header() => Container(
        padding: const EdgeInsets.only(left: t.Spacing.s16, right: t.Spacing.s16, top: t.Spacing.s16, bottom: t.Spacing.s12),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: <Widget>[
                Text('ACP Registry', style: t.TextStyles.title),
                const SizedBox(width: t.Spacing.s8),
                Expanded(child: Text('Agent Client Protocol 插件市场', style: t.TextStyles.secondary, maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (fetching) ...<Widget>[Spinner(), const SizedBox(width: t.Spacing.s8)],
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: onLearnMore,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text('Learn More', style: t.TextStyles.secondary.copyWith(color: t.Accent.text)),
                        const SizedBox(width: t.Spacing.s4),
                        AcpIcon(AcpIcons.externalLink, color: t.Accent.text, size: t.IconSizes.toolbar),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: t.Spacing.s12),
            Row(
              children: <Widget>[
                Expanded(child: _search()),
                const SizedBox(width: t.Spacing.s12),
                _filterChip('All', installedCount + notInstalledCount, RegistryFilter.all),
                const SizedBox(width: t.Spacing.s4),
                _filterChip('Installed', installedCount, RegistryFilter.installed),
                const SizedBox(width: t.Spacing.s4),
                _filterChip('Not Installed', notInstalledCount, RegistryFilter.notInstalled),
              ],
            ),
            if (fetchError != null) ...<Widget>[
              const SizedBox(height: t.Spacing.s8),
              Row(
                children: <Widget>[
                  AcpIcon(AcpIcons.alertTriangle, color: t.Semantic.warning, size: t.IconSizes.toolbar),
                  const SizedBox(width: t.Spacing.s4),
                  Expanded(
                    child: Text(
                      'registry 拉取失败，显示的是本地缓存：$fetchError',
                      style: t.TextStyles.secondary.copyWith(color: t.Semantic.warning),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      );

  /// 搜索框（h28 · panel 底 · subtle 边框 · radius 4）。
  Widget _search() => Container(
        height: t.Controls.standard,
        decoration: BoxDecoration(
          color: t.Neutral.panel,
          border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
          borderRadius: t.Radii.control,
        ),
        padding: t.Controls.padStandard,
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: searchController,
          builder: (context, value, _) => Row(
            children: <Widget>[
              AcpIcon(AcpIcons.search, color: value.text.isEmpty ? t.Neutral.placeholder : t.Neutral.muted, size: t.IconSizes.toolbar),
              const SizedBox(width: t.Spacing.s8),
              Expanded(
                child: AcpTextField(
                  controller: searchController,
                  focusNode: searchFocusNode,
                  style: t.TextStyles.secondary.copyWith(color: t.Neutral.text, height: t.LineHeights.control),
                  placeholder: 'Search agents...',
                  placeholderStyle: t.TextStyles.secondary.copyWith(color: t.Neutral.placeholder, height: t.LineHeights.control),
                  onChanged: onSearchChanged,
                ),
              ),
            ],
          ),
        ),
      );

  Widget _filterChip(String label, int count, RegistryFilter value) {
    final selected = filter == value;
    return Hoverable(
      onTap: onFilter == null ? null : () => onFilter!(value),
      builder: (context, hovered) => Container(
        height: t.Controls.compact,
        padding: t.Controls.padCompact,
        decoration: BoxDecoration(
          color: selected ? t.Overlays.selected : (hovered ? t.Overlays.hover : null),
          borderRadius: t.Radii.control,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(label, style: t.TextStyles.secondary.copyWith(color: selected ? t.Accent.text : t.Neutral.muted, height: t.LineHeights.control)),
            const SizedBox(width: t.Spacing.s4),
            Text('$count', style: t.TextStyles.monoMeta.copyWith(color: selected ? t.Accent.text : t.Neutral.placeholder)),
          ],
        ),
      ),
    );
  }

  Widget _list() {
    final showNode = !node.usable;
    if (entries.isEmpty && !showNode) {
      return Center(
        child: Text(
          query.isNotEmpty ? '没有匹配的 agent' : (fetchError != null ? 'registry 没有缓存，联网后重试' : '暂无 agent'),
          style: t.TextStyles.secondary.copyWith(color: t.Neutral.placeholder),
        ),
      );
    }
    return ListView.builder(
      itemCount: entries.length + (showNode ? 1 : 0),
      itemBuilder: (context, i) {
        if (showNode) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s16, vertical: t.Spacing.s12),
              child: ManagedNodePrompt(progress: nodeProgress, onDownload: onDownloadNode, minVersion: node.minVersion.split('.').first),
            );
          }
          i -= 1;
        }
        final e = entries[i];
        return RegistryEntryRow(e, actions: actionsFor?.call(e) ?? const RegistryEntryActions(), showLog: showLogFor.contains(e.id));
      },
    );
  }
}
