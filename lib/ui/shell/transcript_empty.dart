// 画板 01 · 转录区的两个空态：状态 1「有 agent 的新会话」（标题取线程头同一份标题）与
// 状态 2「首次启动、尚无已安装 agent」（主按钮切到右栏 Agents 标签，R5 前是空面板占位）。

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../theme/tokens.dart' as t;
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';
import 'motion.dart';
import 'shell_common.dart';

/// 状态 1：新会话。
class NewThreadEmpty extends StatelessWidget {
  const NewThreadEmpty({super.key, required this.title, this.transitionEpoch, this.svg});

  final String title;

  /// 当前 agent 的 `icon.svg`（与侧栏 / 线程头的 [AgentMark] 同一份数据，见 `agentIconSvgOf`）。
  /// 非空就整块铺那张 logo、不再套占位的边框；没有 / 解析不了才退回占位菱形。
  /// 画板 01 状态 1 画的是占位菱形，与画板 41「agent 图标位是单色占位，实现里换各 agent 自己的 logo」
  /// 同一口径 —— 所有者裁定 2026-09-18 这里也换成真 logo（设计稿注记待补）。
  final String? svg;

  /// 画板 05 A 组的错开规则：落到这个空态时，三层按 `motion.stagger` 40ms 自上而下递增
  /// （图标 0ms、标题 40ms、提示行 80ms），**代替**转录区那一下整体入场。
  /// null = 不做入场（gallery 里的静态画板对照）。
  final Object? transitionEpoch;

  @override
  Widget build(BuildContext context) {
    return _Centered(
      stagger: transitionEpoch,
      children: <Widget>[
        _mark(),
        Text(title, style: t.TextStyles.display, textAlign: TextAlign.center),
        Text.rich(
          TextSpan(
            style: t.TextStyles.body.copyWith(color: t.Neutral.muted),
            children: <InlineSpan>[
              const TextSpan(text: '在下面输入第一条消息开始会话；'),
              _codeSpan('@'),
              const TextSpan(text: ' 引用上下文，'),
              _codeSpan('/'),
              const TextSpan(text: ' 调命令。'),
            ],
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  /// 外框尺寸两态一致（同 [AgentMark]），有没有 logo 都不会让这一列的高度跳。
  Widget _mark() {
    final icon = svg;
    if (icon == null || icon.isEmpty) return _placeholder();
    return SvgPicture.string(
      icon,
      width: t.Controls.input,
      height: t.Controls.input,
      errorBuilder: (_, _, _) => _placeholder(),
    );
  }

  Widget _placeholder() => Container(
        width: t.Controls.input,
        height: t.Controls.input,
        decoration: BoxDecoration(
          border: Border.all(color: t.Borders.base, width: t.Borders.width),
          borderRadius: t.Radii.card,
        ),
        alignment: Alignment.center,
        child: Transform.rotate(
          angle: _quarterTurn,
          child: Container(width: t.Spacing.s12, height: t.Spacing.s12, color: t.Neutral.placeholder),
        ),
      );

  static const double _quarterTurn = 0.7853981633974483;

  static InlineSpan _codeSpan(String text) => WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Container(
          decoration: const BoxDecoration(color: t.Neutral.surface, borderRadius: t.Radii.chip),
          padding: t.Spacing.chip,
          child: Text(text, style: t.TextStyles.mono),
        ),
      );
}

/// 状态 2：尚无已安装 agent。
class NoAgentEmpty extends StatelessWidget {
  const NoAgentEmpty({super.key, this.onOpenAgents});

  final VoidCallback? onOpenAgents;

  @override
  Widget build(BuildContext context) {
    return _Centered(
      children: <Widget>[
        const DashedBox(
          size: t.Controls.input,
          child: AcpIcon(AcpIcons.layers, color: t.Neutral.placeholder, size: t.IconSizes.base),
        ),
        const Text('还没有已安装的 agent', style: t.TextStyles.display, textAlign: TextAlign.center),
        Text('先在 Agents 面板安装一个 ACP agent，再回来开始会话。',
            style: t.TextStyles.body.copyWith(color: t.Neutral.muted), textAlign: TextAlign.center),
        AcpButton(
          label: '打开 Agents 面板',
          kind: ButtonKind.primary,
          icon: AcpIcons.layers,
          onTap: onOpenAgents,
        ),
      ],
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.children, this.stagger});

  final List<Widget> children;

  /// 非空时逐层错开入场（画板 05 A 组）；每变一次重播一次。
  final Object? stagger;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: t.Geometry.emptyStateMaxWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            for (var i = 0; i < children.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(height: t.Spacing.s12),
              _layer(i, children[i]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _layer(int i, Widget child) {
    final epoch = stagger;
    if (epoch == null) return child;
    // 「成组错开 ≤ 3」（画板 00）：第 4 层起跟第 3 层同时进，不继续往后拖。
    return MotionEnter(epoch: epoch, delay: t.Motion.stagger * (i < 2 ? i : 2), child: child);
  }
}
