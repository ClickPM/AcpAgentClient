// 画板 01 · 转录区的两个空态：状态 1「有 agent 的新会话」（标题取线程头同一份标题）与
// 状态 2「首次启动、尚无已安装 agent」（主按钮切到右栏 Agents 标签，R5 前是空面板占位）。

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';
import 'shell_common.dart';

/// 状态 1：新会话。
class NewThreadEmpty extends StatelessWidget {
  const NewThreadEmpty({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return _Centered(
      children: <Widget>[
        Container(
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
        ),
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
  const _Centered({required this.children});

  final List<Widget> children;

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
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}
