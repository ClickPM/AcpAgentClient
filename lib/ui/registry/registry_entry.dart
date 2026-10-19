// 画板 51 · Registry 条目状态（同一条目 widget 也是画板 50 列表里的行）：未安装 / 安装中 npx 三步 / 安装中 binary
// 三步 + 进度条 / 已安装 / 需要认证 / 安装失败（可重试、看日志）/ uvx 暂不支持 / custom 条目 / 缺 Node 时的受管 Node 提示卡；
// 画板 53 的升级四态（有新版本 / 升级中 / 升级失败 / 已升级 · 待重载）也在这个 widget 里。
// 数据源 lib/projection/registry.dart（registry.json 条目 + 本地安装 / 认证状态）。安装与认证状态是本地态，不是协议内容；
// 名字 / 版本 / 描述来自 registry.json，不写死任何 agent（规则 2）。样式只取 tokens（规则 3）。

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../projection/process_snapshot.dart';
import '../../projection/registry.dart';
import '../../theme/tokens.dart' as t;
import '../format.dart';
import '../shell/popover_anchor.dart';
import '../shell/shell_common.dart';
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';

/// agent 图标框（画板 50 / 51 / 70）：28 见方的框，里面是缓存的 `icon.svg`；没有时是 10 见方的菱形占位。
class AgentIconBox extends StatelessWidget {
  const AgentIconBox({super.key, this.svg});

  final String? svg;

  @override
  Widget build(BuildContext context) {
    final icon = svg;
    return Container(
      width: t.Geometry.agentIconBox,
      height: t.Geometry.agentIconBox,
      decoration: BoxDecoration(
        border: Border.all(color: t.Borders.base, width: t.Borders.width),
        borderRadius: t.Radii.control,
      ),
      alignment: Alignment.center,
      child: icon == null || icon.isEmpty
          ? _Diamond()
          : SvgPicture.string(
              icon,
              width: t.IconSizes.base,
              height: t.IconSizes.base,
              theme: t.SvgTint.mark,
              errorBuilder: (_, _, _) => _Diamond(),
            ),
    );
  }
}

/// 构造函数不带 `const`：build 里现取颜色 token，换主题要重建（理由见 card_chrome.dart 的 Chevron）。
class _Diamond extends StatelessWidget {
  // ignore: prefer_const_constructors_in_immutables
  _Diamond();

  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: _quarterTurn,
    child: Container(
      width: t.Geometry.agentIconDot,
      height: t.Geometry.agentIconDot,
      color: t.Neutral.placeholder,
    ),
  );

  /// 45°（画板的 `transform:rotate(45deg)`）。
  static const double _quarterTurn = 0.7853981633974483;
}

/// 条目的动作回调（都可空：gallery 里是只读样张）。
class RegistryEntryActions {
  const RegistryEntryActions({
    this.onInstall,
    this.onUpdate,
    this.onCancel,
    this.onRemove,
    this.onLogin,
    this.onRetry,
    this.onViewLog,
    this.onOpenRepository,
    this.onStop,
    this.onToggleProcesses,
    this.stopAnchor,
  });

  final VoidCallback? onInstall;

  /// 画板 53 的 Update（有新版本时）。
  final VoidCallback? onUpdate;
  final VoidCallback? onCancel;
  final VoidCallback? onRemove;
  final VoidCallback? onLogin;
  final VoidCallback? onRetry;
  final VoidCallback? onViewLog;
  final VoidCallback? onOpenRepository;

  /// 画板 54 的 Stop（结束该 agent 的整棵进程树）与运行行展开/收起进程树。
  final VoidCallback? onStop;
  final VoidCallback? onToggleProcesses;
  final PopoverHandle? stopAnchor;
}

/// 条目正文 + 状态相关的附加区（安装步骤 / 进度条 / 失败日志 / custom 的 cmd · args · env / 运行行与进程树）。
/// [padding] 是正文的内边距（画板 50 的行是 12 / 16，画板 51 的卡是 12）；附加区左右沿用它、上 0 下同它。
class _RegistryEntryBody extends StatelessWidget {
  const _RegistryEntryBody(
    this.entry, {
    this.actions = const RegistryEntryActions(),
    this.runtime,
    this.padding = const EdgeInsets.all(t.Spacing.s12),
    this.showMeta = true,
    this.showLog = true,
  });

  final RegistryEntryData entry;
  final RegistryEntryActions actions;
  final AgentEntryRuntime? runtime;
  final EdgeInsets padding;

  /// 画板 50 的行带 `ID: …` 与源码仓库链接；画板 51 的状态卡不带。
  final bool showMeta;

  /// 失败态是否展开日志块（画板 51 展开；点「查看日志」切换）。
  final bool showLog;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final run = runtime;
    final progress = e.progress;
    final below = EdgeInsets.only(
      left: padding.left,
      right: padding.right,
      bottom: padding.bottom,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding: padding,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              AgentIconBox(svg: e.iconSvg),
              const SizedBox(width: t.Spacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _titleRow(e, run),
                    if (_description(e) != null &&
                        !(run?.isStopping ?? false)) ...<Widget>[
                      const SizedBox(height: t.Spacing.s4),
                      Text(
                        _description(e)!,
                        style: t.TextStyles.secondary.copyWith(
                          height: t.LineHeights.body,
                        ),
                      ),
                    ],
                    // 画板 53「已升级 · 待重载」：运行中的连接还是旧版。
                    if (e.reloadPending != null &&
                        e.installed &&
                        !e.isInstalling &&
                        !e.isFailed &&
                        !(run?.isStopping ?? false)) ...<Widget>[
                      const SizedBox(height: t.Spacing.s4),
                      Text(_reloadNote(e), style: _noteStyle),
                    ],
                    if (showMeta &&
                        !e.isCustom &&
                        !(run?.isStopping ?? false)) ...<Widget>[
                      const SizedBox(height: t.Spacing.s4),
                      _metaRow(e),
                    ],
                    if (run != null && run.isConnecting) ...<Widget>[
                      const SizedBox(height: t.Spacing.s4),
                      _connectingRow(),
                    ] else if (run != null && run.isStopping) ...<Widget>[
                      const SizedBox(height: t.Spacing.s4),
                      _stoppingRows(),
                    ] else if (run != null && run.isRunning) ...<Widget>[
                      const SizedBox(height: t.Spacing.s4),
                      _runningRow(run),
                      if (run.canExpand && run.expanded)
                        _ProcessTreeTable(
                          rows: run.rows,
                          metricLabel: run.metric.label,
                        ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: t.Spacing.s12),
              _action(e, run),
            ],
          ),
        ),
        if (e.isInstalling && progress != null)
          InstallSteps(
            progress,
            padding: e.isUpgrading && progress.kind != 'binary'
                ? below.copyWith(bottom: t.Spacing.s8)
                : below,
          ),
        if (e.isInstalling && progress != null && progress.kind == 'binary')
          _InstallProgressBar(
            progress,
            padding: e.isUpgrading
                ? below.copyWith(bottom: t.Spacing.s8)
                : below,
          ),
        // 画板 53「升级中」：步骤下面一行说明旧版本还在用。
        if (e.isUpgrading && progress != null)
          Padding(
            padding: below,
            child: Text(_upgradingNote(e, progress), style: _noteStyle),
          ),
        if (e.isFailed && showLog && (e.failure ?? '').isNotEmpty)
          Padding(
            padding: e.isUpgradeFailed
                ? below.copyWith(bottom: t.Spacing.s8)
                : below,
            child: MonoBlock(
              text: e.failure,
              background: t.Semantic.errorSoft,
              style: CardText.codeError,
            ),
          ),
        // 画板 53「升级失败」：错误块下面一行说明旧版本不受影响（日志收起时也在）。
        if (e.isUpgradeFailed)
          Padding(
            padding: below,
            child: Text(
              '升级到 v${e.upgradeTarget} 失败，仍在使用 v${e.displayVersion}。',
              style: _noteStyle,
            ),
          ),
        if (e.isCustom && e.custom != null)
          Padding(padding: below, child: _CustomCommandLines(e.custom!)),
      ],
    );
  }

  /// 画板 53 的说明行（muted 之下一档的次要字）。
  TextStyle get _noteStyle => t.TextStyles.secondary.copyWith(
    color: t.Neutral.placeholder,
    height: t.LineHeights.body,
  );

  /// npx 握手通过才切换；binary 没有握手，解压完成即切换（DIVERGENCE：画板 53 注写的是同一行「握手通过」）。
  static String _upgradingNote(RegistryEntryData e, InstallProgress p) =>
      'v${e.displayVersion} 仍可正常使用；新版本${p.kind == 'binary' ? '解压完成' : '握手通过'}后才切换。';

  static String _reloadNote(RegistryEntryData e) {
    final running = e.reloadPending!.isEmpty ? '旧版本' : ' v${e.reloadPending} ';
    return '已升级到 v${e.displayVersion}。正在运行的$running连接不受影响，在会话头 Reload Agent 或重开应用后生效。';
  }

  /// 名字 · 版本 · 徽章（画板 51 的八种状态、画板 53 的升级四态、画板 54 的运行中芯片）。
  Widget _titleRow(RegistryEntryData e, AgentEntryRuntime? run) {
    final chips = <Widget>[];
    if (e.isCustom) {
      chips.add(ToneChip('custom', tone: ChipTone.neutral));
    } else if (e.isUpgrading) {
      // 画板 53「升级中」只有这一个芯片。
      chips.add(ToneChip('upgrading', tone: ChipTone.accent));
    } else if (e.isInstalling) {
      chips.add(ToneChip('installing', tone: ChipTone.accent));
    } else if (e.isFailed && !e.isUpgradeFailed) {
      chips.add(ToneChip('failed', tone: ChipTone.error));
    } else if (e.kind == DistributionKind.uvx) {
      chips.add(ToneChip('uvx', tone: ChipTone.warning));
    } else if (!e.installed && e.kind != DistributionKind.none) {
      chips.add(ToneChip(e.kind.wire, tone: ChipTone.neutral));
    }
    if (!e.isUpgrading) {
      if (e.installed) chips.add(ToneChip('已安装', tone: ChipTone.success));
      if (e.loggedIn) chips.add(ToneChip('已登录', tone: ChipTone.success));
      if (e.needsAuth) chips.add(ToneChip('需要认证', tone: ChipTone.warning));
      if (run != null && run.isRunning) chips.add(_RunningChip());
      // 画板 53：升级失败的 failed 排在已安装 / 已登录之后（首装失败的排最前，画板 51）。
      if (e.isUpgradeFailed) {
        chips.add(ToneChip('failed', tone: ChipTone.error));
      } else if (e.hasUpdate) {
        chips.add(ToneChip('可升级', tone: ChipTone.accent));
      }
    }
    final version = e.displayVersion;
    return Wrap(
      spacing: t.Spacing.s8,
      runSpacing: t.Spacing.s4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text(e.name, style: CardText.strong),
        // 有新版本 / 升级中写「旧 → 新」，新版本号用强调色（画板 50 / 53）；升级失败只写装着的那一版。
        if ((e.hasUpdate || e.isUpgrading) && !e.isUpgradeFailed)
          Text.rich(
            TextSpan(
              text: 'v$version → ',
              children: <InlineSpan>[
                TextSpan(
                  text: 'v${e.upgradeTarget}',
                  style: t.TextStyles.monoMeta.copyWith(color: t.Accent.text),
                ),
              ],
            ),
            style: t.TextStyles.monoMeta.copyWith(color: t.Neutral.muted),
            softWrap: false,
          )
        else if (version.isNotEmpty)
          Text(
            'v$version',
            style: t.TextStyles.monoMeta.copyWith(color: t.Neutral.muted),
          ),
        ...chips,
      ],
    );
  }

  /// 描述：需要认证时换成协议事实（`session/new` 回了 `-32000`）；uvx 换成「暂不支持」的说明；安装中 / custom 不出描述。
  String? _description(RegistryEntryData e) {
    if (e.isCustom || e.isInstalling) return null;
    if (e.isFailed) return null;
    if (e.needsAuth) return 'session/new 返回 -32000，需要先完成认证。';
    if (e.kind == DistributionKind.uvx) {
      return 'registry 条目声明的安装方式是 uvx，本版本暂不支持，可改用自定义命令接入。';
    }
    if (e.kind == DistributionKind.none || !e.supported) {
      return 'registry 条目没有本平台可用的分发方式，可改用自定义命令接入。';
    }
    return e.description.isEmpty ? null : e.description;
  }

  /// `ID: …` + 源码仓库链接（画板 50）。
  Widget _metaRow(RegistryEntryData e) {
    final repo = e.repository ?? e.website;
    return Row(
      children: <Widget>[
        Text('ID: ${e.id}', style: t.TextStyles.monoMeta),
        if (repo != null) ...<Widget>[
          const SizedBox(width: t.Spacing.s12),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: actions.onOpenRepository,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  AcpIcon(
                    AcpIcons.gitBranch,
                    color: t.Neutral.placeholder,
                    size: t.IconSizes.toolbar,
                  ),
                  const SizedBox(width: t.Spacing.s4),
                  Text(
                    e.repository != null ? '源码仓库' : '网站',
                    style: t.TextStyles.monoMeta,
                  ),
                  const SizedBox(width: t.Spacing.s4),
                  AcpIcon(
                    AcpIcons.externalLink,
                    color: t.Neutral.placeholder,
                    size: t.IconSizes.toolbar,
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 画板 54 A 段连接中：`spinner + 连接中…`。
  Widget _connectingRow() => Padding(
    padding: t.Resource.runRowMargin,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Spinner(size: t.Resource.iconSize),
        const SizedBox(width: t.Resource.gap),
        Text(
          '连接中…',
          style: t.TextStyles.monoMeta.copyWith(color: t.Neutral.muted),
        ),
      ],
    ),
  );

  /// 画板 54 B3 停止中：`spinner + 正在停止…` + 下方小字。
  Widget _stoppingRows() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Spinner(size: t.Resource.iconSize),
          const SizedBox(width: t.Resource.gap),
          Text(
            '正在停止…',
            style: t.TextStyles.monoMeta.copyWith(color: t.Neutral.muted),
          ),
        ],
      ),
      const SizedBox(height: t.Spacing.s4),
      Text('先请 agent 自行退出，3 秒后仍在就结束整棵进程树', style: t.TextStyles.meta),
    ],
  );

  /// 画板 54 A 段运行行：`PID · 进程数 · 约内存 · 已运行时长 · 会话数`；采样不可用时只留 `PID <pid>` 且不可展开。
  Widget _runningRow(AgentEntryRuntime run) {
    final pid = run.effectivePid;
    if (!run.hasSample) {
      return Padding(
        padding: t.Resource.runRowMargin,
        child: Text(
          'PID ${pid ?? '—'}',
          style: t.TextStyles.monoMeta.copyWith(color: t.Neutral.muted),
        ),
      );
    }
    final muted = t.TextStyles.monoMeta.copyWith(color: t.Neutral.muted);
    final dot = Text('·', style: t.TextStyles.monoMeta);
    final uptime = run.uptimeText;
    final content = Padding(
      padding: t.Resource.runRowMargin,
      child: Wrap(
        spacing: t.Resource.gap,
        runSpacing: t.Spacing.s4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          AcpIcon(
            run.expanded ? AcpIcons.chevronDown : AcpIcons.chevronRight,
            size: t.Resource.iconSize,
            color: t.Neutral.muted,
          ),
          Text('PID ${pid ?? '—'}', style: muted),
          dot,
          Text('${run.processCount} 个进程', style: muted),
          dot,
          Text(
            '约 ${formatBytes(run.bytes)}',
            style: t.TextStyles.monoMeta.copyWith(color: t.Neutral.strong),
          ),
          if (uptime != null) ...<Widget>[dot, Text(uptime, style: muted)],
          dot,
          Text(run.sessionLabel, style: muted),
        ],
      ),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: actions.onToggleProcesses,
        child: content,
      ),
    );
  }

  /// 右侧动作：按状态八选一（画板 54：运行中在左边加 Stop；停止中只留置灰的 Stop；升级中 / 升级失败时保留升级操作与 Stop）。
  Widget _action(RegistryEntryData e, AgentEntryRuntime? run) {
    final stop = run != null && (run.isRunning || run.isStopping)
        ? StopAgentButton(
            onTap: run.isRunning ? actions.onStop : null,
            enabled: !run.isStopping,
            forceHover: run.stopHovered,
            anchor: actions.stopAnchor,
          )
        : null;
    if (e.isInstalling) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (stop != null) ...<Widget>[
            stop,
            const SizedBox(width: t.Resource.gap),
          ],
          Spinner(),
          const SizedBox(width: t.Spacing.s8),
          AcpButton(label: '取消', onTap: actions.onCancel),
        ],
      );
    }
    if (e.isFailed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (stop != null) ...<Widget>[
            stop,
            const SizedBox(width: t.Resource.gap),
          ],
          AcpButton(
            label: '重试',
            kind: ButtonKind.primary,
            onTap: actions.onRetry,
          ),
          const SizedBox(width: t.Spacing.s4),
          AcpButton(label: '查看日志', onTap: actions.onViewLog),
        ],
      );
    }
    if (run != null && run.isStopping) return stop!;
    final trailing = <Widget>[
      if (!e.builtin)
        if (e.isCustom)
          RemoveButton(onTap: actions.onRemove)
        else if (e.needsAuth)
          AcpButton(
            label: '登录',
            kind: ButtonKind.primary,
            icon: AcpIcons.lock,
            onTap: actions.onLogin,
          )
        else if (e.hasUpdate) ...<Widget>[
          AcpButton(
            label: 'Update',
            kind: ButtonKind.primary,
            icon: AcpIcons.download,
            onTap: actions.onUpdate,
          ),
          RemoveButton(onTap: actions.onRemove),
        ] else if (e.installed)
          RemoveButton(onTap: actions.onRemove)
        else if (e.isUnsupported)
          const AcpButton(
            label: '暂不支持',
            kind: ButtonKind.primary,
            enabled: false,
          )
        else
          AcpButton(
            label: 'Install',
            kind: ButtonKind.primary,
            icon: AcpIcons.download,
            onTap: actions.onInstall,
          ),
    ];
    final items = <Widget>[if (stop != null) stop, ...trailing];
    if (items.isEmpty) return const SizedBox.shrink();
    if (items.length == 1) return items.first;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var i = 0; i < items.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: t.Resource.gap),
          items[i],
        ],
      ],
    );
  }
}

/// 画板 54 的 `运行中` 芯片（success 色 + 6px 绿点）。
class _RunningChip extends StatelessWidget {
  // ignore: prefer_const_constructors_in_immutables
  _RunningChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: t.Spacing.chip,
      decoration: BoxDecoration(
        color: t.Semantic.successSoft,
        borderRadius: t.Radii.chip,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: t.UnreadDot.size,
            height: t.UnreadDot.size,
            decoration: BoxDecoration(
              color: t.Semantic.success,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: t.Spacing.s4),
          Text(
            '运行中',
            style: t.TextStyles.monoMeta.copyWith(color: t.Semantic.success),
          ),
        ],
      ),
    );
  }
}

/// 画板 54 的 Stop 按钮：ghost 中性按钮 + 10px 红色圆角停止方块（与红色的 Remove 区分）。
class StopAgentButton extends StatelessWidget {
  // ignore: prefer_const_constructors_in_immutables
  StopAgentButton({
    super.key,
    this.onTap,
    this.enabled = true,
    this.forceHover = false,
    this.anchor,
  });

  final VoidCallback? onTap;
  final bool enabled;
  final bool forceHover;
  final PopoverHandle? anchor;

  @override
  Widget build(BuildContext context) {
    final button = Hoverable(
      onTap: enabled ? onTap : null,
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      forceHover: enabled && forceHover,
      builder: (context, hovered) => Container(
        height: t.Controls.standard,
        padding: t.Controls.padInput,
        decoration: BoxDecoration(
          color: enabled && hovered ? t.Overlays.hover : null,
          borderRadius: t.Radii.control,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: t.Resource.stopSquare,
              height: t.Resource.stopSquare,
              decoration: BoxDecoration(
                color: t.Semantic.error,
                borderRadius: t.Radii.chip,
              ),
            ),
            const SizedBox(width: t.Resource.gap),
            Text(
              'Stop',
              style: CardText.button.copyWith(color: t.Neutral.text),
            ),
          ],
        ),
      ),
    );
    final wrapped = enabled
        ? button
        : Opacity(opacity: t.Opacities.pending, child: button);
    return PopoverAnchor(handle: anchor, child: wrapped);
  }
}

/// 画板 54 展开态进程树表（进程名 / PID / 专用内存）。
class _ProcessTreeTable extends StatelessWidget {
  const _ProcessTreeTable({required this.rows, required this.metricLabel});

  final List<ProcessTreeRow> rows;
  final String metricLabel;

  @override
  Widget build(BuildContext context) {
    final headerStyle = t.TextStyles.monoMeta;
    final textStyle = t.TextStyles.monoMeta.copyWith(color: t.Neutral.text);
    final pidStyle = t.TextStyles.monoMeta.copyWith(color: t.Neutral.muted);
    return Container(
      margin: t.ProcessTree.margin,
      padding: t.ProcessTree.padding,
      decoration: BoxDecoration(
        color: t.Neutral.panel,
        border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
        borderRadius: t.Radii.control,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: t.ProcessTree.headerBottom,
            child: Row(
              children: <Widget>[
                Expanded(child: Text('进程', style: headerStyle)),
                SizedBox(
                  width: t.ProcessTree.pidWidth,
                  child: Text(
                    'PID',
                    style: headerStyle,
                    textAlign: TextAlign.right,
                  ),
                ),
                SizedBox(
                  width: t.ProcessTree.bytesWidth,
                  child: Text(
                    metricLabel,
                    style: headerStyle,
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
          for (final row in rows)
            Container(
              height: t.ProcessTree.rowHeight,
              padding: t.ProcessTree.rowPadding,
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Padding(
                      padding: t.ProcessTree.indentPadding(row.depth),
                      child: Text.rich(
                        TextSpan(
                          children: <InlineSpan>[
                            if (row.isIndented)
                              TextSpan(text: row.prefix, style: headerStyle),
                            if (row.name.isNotEmpty)
                              TextSpan(text: row.name, style: textStyle),
                            if (row.terminalSuffix != null)
                              TextSpan(
                                text: row.terminalSuffix,
                                style: headerStyle,
                              ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: t.ProcessTree.pidWidth,
                    child: Text(
                      '${row.pid}',
                      style: pidStyle,
                      textAlign: TextAlign.right,
                    ),
                  ),
                  SizedBox(
                    width: t.ProcessTree.bytesWidth,
                    child: Text(
                      formatBytes(row.bytes),
                      style: textStyle,
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Remove（ghost，error 色，垃圾桶图标；画板 50 / 51 / 70）。
class RemoveButton extends StatelessWidget {
  const RemoveButton({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => AcpButton(
    label: 'Remove',
    icon: AcpIcons.trash,
    iconColor: t.Semantic.error,
    labelColor: t.Semantic.error,
    onTap: onTap,
  );
}

/// 画板 51 的状态卡（卡片容器 + 12 内边距的条目正文）。
class RegistryEntryCard extends StatelessWidget {
  const RegistryEntryCard(
    this.entry, {
    super.key,
    this.actions = const RegistryEntryActions(),
    this.runtime,
    this.showLog = true,
  });

  final RegistryEntryData entry;
  final RegistryEntryActions actions;
  final AgentEntryRuntime? runtime;
  final bool showLog;

  @override
  Widget build(BuildContext context) => TranscriptCard(
    child: _RegistryEntryBody(
      entry,
      actions: actions,
      runtime: runtime,
      showMeta: false,
      showLog: showLog,
    ),
  );
}

/// 画板 50 / 54 列表里的一行（12 / 16 内边距 + 底边框）。
class RegistryEntryRow extends StatelessWidget {
  const RegistryEntryRow(
    this.entry, {
    super.key,
    this.actions = const RegistryEntryActions(),
    this.runtime,
    this.showLog = true,
  });

  final RegistryEntryData entry;
  final RegistryEntryActions actions;
  final AgentEntryRuntime? runtime;
  final bool showLog;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      border: Border(
        bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width),
      ),
    ),
    child: _RegistryEntryBody(
      entry,
      actions: actions,
      runtime: runtime,
      padding: const EdgeInsets.symmetric(
        horizontal: t.Spacing.s16,
        vertical: t.Spacing.s12,
      ),
      showLog: showLog,
    ),
  );
}

/// 安装步骤清单（画板 51：npx 三步 / binary 三步 / 受管 Node 两步）：当前步 spinner、已完成对勾、未到的虚线圆、失败的斜杠圆。
class InstallSteps extends StatelessWidget {
  const InstallSteps(
    this.progress, {
    super.key,
    this.padding = const EdgeInsets.all(t.Spacing.s12),
  });

  final InstallProgress progress;
  final EdgeInsets padding;

  static String labelOf(InstallProgress p, String step) => switch (step) {
    'resolve' => '解析 npx 包${p.detail == null ? '' : ' ${p.detail}'}',
    'write_settings' => '写入 settings.json',
    'handshake' => '首次拉起并握手 initialize',
    'download' ||
    'node_download' => '下载${p.detail == null ? '' : ' ${p.detail}'}',
    'verify' => 'sha256 校验',
    'extract' || 'node_extract' => '解压到数据目录',
    _ => step,
  };

  @override
  Widget build(BuildContext context) {
    final p = progress;
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var i = 0; i < p.steps.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: t.Spacing.s4),
            _step(p, p.steps[i]),
          ],
        ],
      ),
    );
  }

  Widget _step(InstallProgress p, String step) {
    final state = p.stateOf(step);
    final Widget icon = switch (state) {
      StepState.active => Spinner(),
      StepState.done => AcpIcon(
        AcpIcons.check,
        color: t.Semantic.success,
        size: t.IconSizes.toolbar,
      ),
      StepState.failed => AcpIcon(
        AcpIcons.slashCircle,
        color: t.Semantic.error,
        size: t.IconSizes.toolbar,
      ),
      StepState.pending => AcpIcon(
        AcpIcons.dashedCircle,
        color: t.Neutral.placeholder,
        size: t.IconSizes.toolbar,
      ),
    };
    final color = switch (state) {
      StepState.active || StepState.done => t.Neutral.text,
      StepState.failed => t.Semantic.error,
      StepState.pending => t.Neutral.placeholder,
    };
    final bytes =
        (step == 'download' || step == 'node_download') &&
            p.done != null &&
            p.total != null
        ? '${formatBytes(p.done!)} / ${formatBytes(p.total!)}'
        : null;
    return Row(
      children: <Widget>[
        icon,
        const SizedBox(width: t.Spacing.s8),
        Expanded(
          child: Text(
            labelOf(p, step),
            style: t.TextStyles.secondary.copyWith(color: color),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (bytes != null && state == StepState.active)
          Text(bytes, style: t.TextStyles.monoMeta),
      ],
    );
  }
}

/// 下载进度条 + 「62% · 2.1 MB/s · 约 4s」（画板 51 的 binary 安装）。总大小未知时只画不确定态（整条 subtle）。
class _InstallProgressBar extends StatelessWidget {
  const _InstallProgressBar(
    this.progress, {
    this.padding = const EdgeInsets.all(t.Spacing.s12),
  });

  final InstallProgress progress;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    final fraction = p.fraction;
    final parts = <String>[
      if (fraction != null) '${(fraction * 100).round()}%',
      if (p.bytesPerSecond != null && p.bytesPerSecond! > 0)
        '${formatBytes(p.bytesPerSecond!)}/s',
      if (p.etaSeconds != null) '约 ${p.etaSeconds!.ceil()}s',
    ];
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          LayoutBuilder(
            builder: (context, constraints) => Stack(
              children: <Widget>[
                Container(
                  height: t.Geometry.installProgressHeight,
                  decoration: BoxDecoration(
                    color: t.Borders.subtle,
                    borderRadius: t.Radii.pill(
                      t.Geometry.installProgressHeight,
                    ),
                  ),
                ),
                if (fraction != null)
                  Container(
                    height: t.Geometry.installProgressHeight,
                    width: constraints.maxWidth * fraction,
                    decoration: BoxDecoration(
                      color: t.Accent.base,
                      borderRadius: t.Radii.pill(
                        t.Geometry.installProgressHeight,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (parts.isNotEmpty) ...<Widget>[
            const SizedBox(height: t.Spacing.s4),
            Text(
              parts.join(' · '),
              style: t.TextStyles.monoMeta.copyWith(color: t.Neutral.muted),
            ),
          ],
        ],
      ),
    );
  }
}

/// custom 条目下方的 `cmd:` / `args:` / `env:` 三行（画板 51）。
class _CustomCommandLines extends StatelessWidget {
  const _CustomCommandLines(this.command);

  final CustomCommand command;

  @override
  Widget build(BuildContext context) {
    final style = t.TextStyles.monoMeta.copyWith(
      color: t.Neutral.muted,
      fontSize: t.TextStyles.secondary.fontSize,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          'cmd: ${command.command}',
          style: style,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: t.Spacing.s4),
        Text(
          'args: ${command.argsText}',
          style: style,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: t.Spacing.s4),
        Text(
          'env: ${command.envText}',
          style: style,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// 缺 Node 时的受管 Node 提示卡（画板 51 / 50）。下载中换成两步清单与进度。
class ManagedNodePrompt extends StatelessWidget {
  const ManagedNodePrompt({
    super.key,
    this.progress,
    this.onDownload,
    this.minVersion = '22',
  });

  final InstallProgress? progress;
  final VoidCallback? onDownload;
  final String minVersion;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    final downloading = p != null && p.isRunning;
    return TranscriptCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(t.Spacing.s12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                AcpIcon(AcpIcons.alertTriangle, color: t.Semantic.warning),
                const SizedBox(width: t.Spacing.s8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        '未检测到 Node ≥ $minVersion',
                        style: t.TextStyles.body.copyWith(
                          color: t.Neutral.strong,
                          height: t.LineHeights.control,
                        ),
                      ),
                      const SizedBox(height: t.Spacing.s4),
                      Text(
                        p != null && p.isFailed
                            ? '受管 Node 下载失败：${p.error ?? ''}'
                            : 'npx 型 agent 需要 Node 运行时。可以下载一份受管 Node 到数据目录，只供本应用使用，不改系统环境。',
                        style: t.TextStyles.secondary.copyWith(
                          height: t.LineHeights.body,
                          color: p != null && p.isFailed
                              ? t.Semantic.error
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: t.Spacing.s12),
                if (downloading)
                  Spinner()
                else
                  AcpButton(
                    label: p != null && p.isFailed ? '重试' : '下载受管 Node',
                    kind: ButtonKind.primary,
                    icon: AcpIcons.download,
                    onTap: onDownload,
                  ),
              ],
            ),
          ),
          if (downloading) ...<Widget>[
            InstallSteps(
              p,
              padding: const EdgeInsets.only(
                left: t.Spacing.s12,
                right: t.Spacing.s12,
                bottom: t.Spacing.s12,
              ),
            ),
            _InstallProgressBar(
              p,
              padding: const EdgeInsets.only(
                left: t.Spacing.s12,
                right: t.Spacing.s12,
                bottom: t.Spacing.s12,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
