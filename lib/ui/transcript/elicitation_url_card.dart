// 画板 28 · 链接跳转交互卡：elicitation/create · mode "url"（elicitationId + url）→ elicitation/complete。
// 默认 Waiting for input → 已打开浏览器 Waiting for completion... → 完成 Completed（由 agent 的 elicitation/complete 收尾）。
// 无会话阶段（requestScope）也可能收到本卡，落画板 52（R5）。打开浏览器由 url_launcher 接（R3 / R5），这里只回调。

import 'package:flutter/widgets.dart';

import '../../projection/entries.dart';
import '../../theme/tokens.dart' as t;
import 'card_chrome.dart';
import 'icons.dart';

class ElicitationUrlCard extends StatelessWidget {
  const ElicitationUrlCard(this.entry, {super.key, this.agentName, this.onOpen, this.onCancel});

  final ElicitationEntry entry;
  final String? agentName;
  final VoidCallback? onOpen;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final who = agentName ?? e.agentId ?? 'agent';
    final completed = e.status == PendingStatus.completed;
    final opened = e.opened && !completed;
    final Widget status = completed
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const AcpIcon(AcpIcons.check, color: t.Semantic.success, size: t.IconSizes.toolbar),
              const SizedBox(width: t.Spacing.s4),
              Text('Completed', style: CardText.secondary.copyWith(color: t.Semantic.success)),
            ],
          )
        : opened
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Spinner(),
                  const SizedBox(width: t.Spacing.s4),
                  Text('Waiting for completion...', style: CardText.secondary),
                ],
              )
            : Text('Waiting for input', style: CardText.secondary);
    return TranscriptCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CardHeader(
            leading: const AcpIcon(AcpIcons.info, color: t.Accent.base),
            title: 'Sign in requested by $who',
            titleStyle: CardText.cardTitle,
            trailing: <Widget>[status],
            height: t.Controls.input + t.Spacing.s8,
          ),
          CardBody(
            padding: const EdgeInsets.all(t.Spacing.s12),
            children: <Widget>[
              if (e.wire.message != null) Text(e.wire.message!, style: t.TextStyles.body),
              MonoBlock(text: e.wire.url ?? '', style: CardText.subtitle, softWrap: false),
              Row(
                children: <Widget>[
                  AcpButton(label: 'Open in browser', kind: ButtonKind.primary, icon: AcpIcons.externalLink, enabled: !completed, onTap: onOpen),
                  const SizedBox(width: t.Spacing.s8),
                  if (completed)
                    Text('已收到 elicitation/complete，登录完成', style: t.TextStyles.body.copyWith(color: t.Semantic.success))
                  else if (opened)
                    AcpButton(label: 'Cancel', onTap: onCancel),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
