// 画板 51 · Registry 条目状态（同一条目 widget 也是画板 50 列表里的行）：未安装 / 安装中 npx 三步 / 安装中 binary
// 三步 + 进度条 / 已安装 / 需要认证 / 安装失败（可重试、看日志）/ uvx 暂不支持 / custom 条目 / 缺 Node 时的受管 Node 提示卡。
// 数据源 lib/projection/registry.dart（registry.json 条目 + 本地安装 / 认证状态）。安装与认证状态是本地态，不是协议内容；
// 名字 / 版本 / 描述来自 registry.json，不写死任何 agent（规则 2）。样式只取 tokens（规则 3）。

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../projection/registry.dart';
import '../../theme/tokens.dart' as t;
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
          ? const _Diamond()
          : SvgPicture.string(icon, width: t.IconSizes.base, height: t.IconSizes.base, errorBuilder: (_, _, _) => const _Diamond()),
    );
  }
}

class _Diamond extends StatelessWidget {
  const _Diamond();

  @override
  Widget build(BuildContext context) => Transform.rotate(
        angle: _quarterTurn,
        child: Container(width: t.Geometry.agentIconDot, height: t.Geometry.agentIconDot, color: t.Neutral.placeholder),
      );

  /// 45°（画板的 `transform:rotate(45deg)`）。
  static const double _quarterTurn = 0.7853981633974483;
}

/// 条目的动作回调（都可空：gallery 里是只读样张）。
class RegistryEntryActions {
  const RegistryEntryActions({
    this.onInstall,
    this.onCancel,
    this.onRemove,
    this.onLogin,
    this.onRetry,
    this.onViewLog,
    this.onOpenRepository,
  });

  final VoidCallback? onInstall;
  final VoidCallback? onCancel;
  final VoidCallback? onRemove;
  final VoidCallback? onLogin;
  final VoidCallback? onRetry;
  final VoidCallback? onViewLog;
  final VoidCallback? onOpenRepository;
}

/// 条目正文 + 状态相关的附加区（安装步骤 / 进度条 / 失败日志 / custom 的 cmd · args · env）。
/// [padding] 是正文的内边距（画板 50 的行是 12 / 16，画板 51 的卡是 12）；附加区左右沿用它、上 0 下同它。
class RegistryEntryBody extends StatelessWidget {
  const RegistryEntryBody(
    this.entry, {
    super.key,
    this.actions = const RegistryEntryActions(),
    this.padding = const EdgeInsets.all(t.Spacing.s12),
    this.showMeta = true,
    this.showLog = true,
  });

  final RegistryEntryData entry;
  final RegistryEntryActions actions;
  final EdgeInsets padding;

  /// 画板 50 的行带 `ID: …` 与源码仓库链接；画板 51 的状态卡不带。
  final bool showMeta;

  /// 失败态是否展开日志块（画板 51 展开；点「查看日志」切换）。
  final bool showLog;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final progress = e.progress;
    final below = EdgeInsets.only(left: padding.left, right: padding.right, bottom: padding.bottom);
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
                    _titleRow(e),
                    if (_description(e) != null) ...<Widget>[
                      const SizedBox(height: t.Spacing.s4),
                      Text(_description(e)!, style: t.TextStyles.secondary.copyWith(height: t.LineHeights.body)),
                    ],
                    if (showMeta && !e.isCustom) ...<Widget>[
                      const SizedBox(height: t.Spacing.s4),
                      _metaRow(e),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: t.Spacing.s12),
              _action(e),
            ],
          ),
        ),
        if (e.isInstalling && progress != null) InstallSteps(progress, padding: below),
        if (e.isInstalling && progress != null && progress.kind == 'binary') InstallProgressBar(progress, padding: below),
        if (e.isFailed && showLog && (e.failure ?? '').isNotEmpty)
          Padding(padding: below, child: MonoBlock(text: e.failure, background: t.Semantic.errorSoft, style: CardText.codeError)),
        if (e.isCustom && e.custom != null) Padding(padding: below, child: CustomCommandLines(e.custom!)),
      ],
    );
  }

  /// 名字 · 版本 · 徽章（画板 51 的八种状态各自的徽章组合）。
  Widget _titleRow(RegistryEntryData e) {
    final chips = <Widget>[];
    if (e.isCustom) {
      chips.add(const ToneChip('custom', tone: ChipTone.neutral));
    } else if (e.isInstalling) {
      chips.add(const ToneChip('installing', tone: ChipTone.accent));
    } else if (e.isFailed) {
      chips.add(const ToneChip('failed', tone: ChipTone.error));
    } else if (e.kind == DistributionKind.uvx) {
      chips.add(const ToneChip('uvx', tone: ChipTone.warning));
    } else if (!e.installed && e.kind != DistributionKind.none) {
      chips.add(ToneChip(e.kind.wire, tone: ChipTone.neutral));
    }
    if (e.installed) chips.add(const ToneChip('已安装', tone: ChipTone.success));
    if (e.loggedIn) chips.add(const ToneChip('已登录', tone: ChipTone.success));
    if (e.needsAuth) chips.add(const ToneChip('需要认证', tone: ChipTone.warning));
    return Wrap(
      spacing: t.Spacing.s8,
      runSpacing: t.Spacing.s4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text(e.name, style: CardText.strong),
        if (e.version.isNotEmpty) Text('v${e.version}', style: t.TextStyles.monoMeta.copyWith(color: t.Neutral.muted)),
        ...chips,
      ],
    );
  }

  /// 描述：需要认证时换成协议事实（`session/new` 回了 `-32000`）；uvx 换成「暂不支持」的说明；安装中 / custom 不出描述。
  String? _description(RegistryEntryData e) {
    if (e.isCustom || e.isInstalling) return null;
    if (e.isFailed) return null;
    if (e.needsAuth) return 'session/new 返回 -32000，需要先完成认证。';
    if (e.kind == DistributionKind.uvx) return 'registry 条目声明的安装方式是 uvx，本版本暂不支持，可改用自定义命令接入。';
    if (e.kind == DistributionKind.none || !e.supported) return 'registry 条目没有本平台可用的分发方式，可改用自定义命令接入。';
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
                  const AcpIcon(AcpIcons.gitBranch, color: t.Neutral.placeholder, size: t.IconSizes.toolbar),
                  const SizedBox(width: t.Spacing.s4),
                  Text(e.repository != null ? '源码仓库' : '网站', style: t.TextStyles.monoMeta),
                  const SizedBox(width: t.Spacing.s4),
                  const AcpIcon(AcpIcons.externalLink, color: t.Neutral.placeholder, size: t.IconSizes.toolbar),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 右侧动作：按状态八选一。
  Widget _action(RegistryEntryData e) {
    if (e.isInstalling) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[const Spinner(), const SizedBox(width: t.Spacing.s8), AcpButton(label: '取消', onTap: actions.onCancel)],
      );
    }
    if (e.isFailed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AcpButton(label: '重试', kind: ButtonKind.primary, onTap: actions.onRetry),
          const SizedBox(width: t.Spacing.s4),
          AcpButton(label: '查看日志', onTap: actions.onViewLog),
        ],
      );
    }
    // 内置 agent（R7 的 sidecar）不可删，按钮置灰。
    if (e.isCustom) return RemoveButton(onTap: e.builtin ? null : actions.onRemove);
    if (e.needsAuth) return AcpButton(label: '登录', kind: ButtonKind.primary, icon: AcpIcons.lock, onTap: actions.onLogin);
    if (e.installed) return RemoveButton(onTap: actions.onRemove);
    if (e.isUnsupported) return const AcpButton(label: '暂不支持', kind: ButtonKind.primary, enabled: false);
    return AcpButton(label: 'Install', kind: ButtonKind.primary, icon: AcpIcons.download, onTap: actions.onInstall);
  }
}

/// Remove（ghost，error 色，垃圾桶图标；画板 50 / 51 / 70）。
class RemoveButton extends StatelessWidget {
  const RemoveButton({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) =>
      AcpButton(label: 'Remove', icon: AcpIcons.trash, iconColor: t.Semantic.error, labelColor: t.Semantic.error, onTap: onTap);
}

/// 画板 51 的状态卡（卡片容器 + 12 内边距的条目正文）。
class RegistryEntryCard extends StatelessWidget {
  const RegistryEntryCard(this.entry, {super.key, this.actions = const RegistryEntryActions(), this.showLog = true});

  final RegistryEntryData entry;
  final RegistryEntryActions actions;
  final bool showLog;

  @override
  Widget build(BuildContext context) => TranscriptCard(
        child: RegistryEntryBody(entry, actions: actions, showMeta: false, showLog: showLog),
      );
}

/// 画板 50 列表里的一行（12 / 16 内边距 + 底边框）。
class RegistryEntryRow extends StatelessWidget {
  const RegistryEntryRow(this.entry, {super.key, this.actions = const RegistryEntryActions(), this.showLog = true});

  final RegistryEntryData entry;
  final RegistryEntryActions actions;
  final bool showLog;

  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
        child: RegistryEntryBody(
          entry,
          actions: actions,
          padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s16, vertical: t.Spacing.s12),
          showLog: showLog,
        ),
      );
}

/// 安装步骤清单（画板 51：npx 三步 / binary 三步 / 受管 Node 两步）：当前步 spinner、已完成对勾、未到的虚线圆、失败的斜杠圆。
class InstallSteps extends StatelessWidget {
  const InstallSteps(this.progress, {super.key, this.padding = const EdgeInsets.all(t.Spacing.s12)});

  final InstallProgress progress;
  final EdgeInsets padding;

  static String labelOf(InstallProgress p, String step) => switch (step) {
        'resolve' => '解析 npx 包${p.detail == null ? '' : ' ${p.detail}'}',
        'write_settings' => '写入 settings.json',
        'handshake' => '首次拉起并握手 initialize',
        'download' || 'node_download' => '下载${p.detail == null ? '' : ' ${p.detail}'}',
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
      StepState.active => const Spinner(),
      StepState.done => const AcpIcon(AcpIcons.check, color: t.Semantic.success, size: t.IconSizes.toolbar),
      StepState.failed => const AcpIcon(AcpIcons.slashCircle, color: t.Semantic.error, size: t.IconSizes.toolbar),
      StepState.pending => const AcpIcon(AcpIcons.dashedCircle, color: t.Neutral.placeholder, size: t.IconSizes.toolbar),
    };
    final color = switch (state) {
      StepState.active || StepState.done => t.Neutral.text,
      StepState.failed => t.Semantic.error,
      StepState.pending => t.Neutral.placeholder,
    };
    final bytes = (step == 'download' || step == 'node_download') && p.done != null && p.total != null
        ? '${formatBytes(p.done!)} / ${formatBytes(p.total!)}'
        : null;
    return Row(
      children: <Widget>[
        icon,
        const SizedBox(width: t.Spacing.s8),
        Expanded(child: Text(labelOf(p, step), style: t.TextStyles.secondary.copyWith(color: color), maxLines: 1, overflow: TextOverflow.ellipsis)),
        if (bytes != null && state == StepState.active) Text(bytes, style: t.TextStyles.monoMeta),
      ],
    );
  }
}

/// 下载进度条 + 「62% · 2.1 MB/s · 约 4s」（画板 51 的 binary 安装）。总大小未知时只画不确定态（整条 subtle）。
class InstallProgressBar extends StatelessWidget {
  const InstallProgressBar(this.progress, {super.key, this.padding = const EdgeInsets.all(t.Spacing.s12)});

  final InstallProgress progress;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    final fraction = p.fraction;
    final parts = <String>[
      if (fraction != null) '${(fraction * 100).round()}%',
      if (p.bytesPerSecond != null && p.bytesPerSecond! > 0) '${formatBytes(p.bytesPerSecond!)}/s',
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
                  decoration: BoxDecoration(color: t.Borders.subtle, borderRadius: t.Radii.pill(t.Geometry.installProgressHeight)),
                ),
                if (fraction != null)
                  Container(
                    height: t.Geometry.installProgressHeight,
                    width: constraints.maxWidth * fraction,
                    decoration: BoxDecoration(color: t.Accent.base, borderRadius: t.Radii.pill(t.Geometry.installProgressHeight)),
                  ),
              ],
            ),
          ),
          if (parts.isNotEmpty) ...<Widget>[
            const SizedBox(height: t.Spacing.s4),
            Text(parts.join(' · '), style: t.TextStyles.monoMeta.copyWith(color: t.Neutral.muted)),
          ],
        ],
      ),
    );
  }
}

/// custom 条目下方的 `cmd:` / `args:` / `env:` 三行（画板 51）。
class CustomCommandLines extends StatelessWidget {
  const CustomCommandLines(this.command, {super.key});

  final CustomCommand command;

  @override
  Widget build(BuildContext context) {
    final style = t.TextStyles.monoMeta.copyWith(color: t.Neutral.muted, fontSize: t.TextStyles.secondary.fontSize);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text('cmd: ${command.command}', style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: t.Spacing.s4),
        Text('args: ${command.argsText}', style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: t.Spacing.s4),
        Text('env: ${command.envText}', style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
      ],
    );
  }
}

/// 缺 Node 时的受管 Node 提示卡（画板 51 / 50）。下载中换成两步清单与进度。
class ManagedNodePrompt extends StatelessWidget {
  const ManagedNodePrompt({super.key, this.progress, this.onDownload, this.minVersion = '22'});

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
                const AcpIcon(AcpIcons.alertTriangle, color: t.Semantic.warning),
                const SizedBox(width: t.Spacing.s8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text('未检测到 Node ≥ $minVersion', style: t.TextStyles.body.copyWith(color: t.Neutral.strong, height: t.LineHeights.control)),
                      const SizedBox(height: t.Spacing.s4),
                      Text(
                        p != null && p.isFailed
                            ? '受管 Node 下载失败：${p.error ?? ''}'
                            : 'npx 型 agent 需要 Node 运行时。可以下载一份受管 Node 到数据目录，只供本应用使用，不改系统环境。',
                        style: t.TextStyles.secondary.copyWith(height: t.LineHeights.body, color: p != null && p.isFailed ? t.Semantic.error : null),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: t.Spacing.s12),
                if (downloading)
                  const Spinner()
                else
                  AcpButton(label: p != null && p.isFailed ? '重试' : '下载受管 Node', kind: ButtonKind.primary, icon: AcpIcons.download, onTap: onDownload),
              ],
            ),
          ),
          if (downloading) ...<Widget>[
            InstallSteps(p, padding: const EdgeInsets.only(left: t.Spacing.s12, right: t.Spacing.s12, bottom: t.Spacing.s12)),
            InstallProgressBar(p, padding: const EdgeInsets.only(left: t.Spacing.s12, right: t.Spacing.s12, bottom: t.Spacing.s12)),
          ],
        ],
      ),
    );
  }
}
