// 画板 34 · agent 状态与错误：acp/agent_state（spawned / initialized / auth_required / exited）、未知变体丢弃告警、JSON-RPC 错误码。
// 数据源 lib/projection/agent_state.dart（AgentConnection）。agent 名字来自 initialize 的 agentInfo / 进程名，不写死（规则 2）。
// R3 接线：认证入口按 authMethods 的 type（agent → authenticate；terminal → 内置终端）、重启 agent、打开流量面板。

import 'package:flutter/widgets.dart';

import '../../projection/agent_state.dart';
import '../../theme/tokens.dart' as t;
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';

class AgentStateBar extends StatefulWidget {
  const AgentStateBar(
    this.connection, {
    super.key,
    this.initiallyExpanded = false,
    this.onAuthenticate,
    this.onRestart,
    this.onOpenTraffic,
  });

  final AgentConnection connection;
  final bool initiallyExpanded;
  final void Function(String methodId)? onAuthenticate;
  final VoidCallback? onRestart;
  final VoidCallback? onOpenTraffic;

  @override
  State<AgentStateBar> createState() => _AgentStateBarState();
}

class _AgentStateBarState extends State<AgentStateBar> {
  late bool _expanded = widget.initiallyExpanded;

  String get _name {
    final c = widget.connection;
    return c.agentName ?? c.program ?? c.agentId;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.connection;
    return switch (c.state) {
      AgentLifecycle.spawned => _row(
          icon: const AcpIcon(AcpIcons.dot, color: t.Neutral.placeholder, size: t.IconSizes.toolbar),
          title: '$_name 进程已启动',
          meta: '${c.pid == null ? '' : 'pid ${c.pid} · '}spawned',
        ),
      AgentLifecycle.initialized => _row(
          icon: const AcpIcon(AcpIcons.checkCircle, color: t.Semantic.success, size: t.IconSizes.toolbar),
          title: '$_name${c.agentVersion == null ? '' : ' v${c.agentVersion}'} 已初始化',
          meta: 'protocolVersion ${c.protocolVersion ?? '?'} · ${c.capabilityNames.join(' / ')}',
        ),
      AgentLifecycle.authRequired => _card(<Widget>[
          _row(
            icon: const AcpIcon(AcpIcons.lock, color: t.Semantic.warning, size: t.IconSizes.toolbar),
            title: '需要认证才能新建会话',
            meta: 'JSON-RPC -32000 · session/new',
            bare: true,
          ),
          Container(
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
            padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
            child: Row(
              children: <Widget>[
                for (final m in c.authMethods) ...<Widget>[
                  if (m['type'] == 'agent')
                    AcpButton(label: '用 ${m['name'] ?? m['id']} 登录', kind: ButtonKind.primary, onTap: () => widget.onAuthenticate?.call(m['id'] as String? ?? ''))
                  else
                    AcpButton(label: '在内置终端认证', onTap: () => widget.onAuthenticate?.call(m['id'] as String? ?? '')),
                  const SizedBox(width: t.Spacing.s8),
                ],
                Flexible(
                  child: Text(
                    'authMethods: ${c.authMethods.map((m) => '${m['id']}（${m['type']} 型）').join(' / ')}',
                    style: t.TextStyles.monoMeta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ]),
      AgentLifecycle.exited => _card(<Widget>[
          _row(
            icon: const AcpIcon(AcpIcons.slashCircle, color: t.Semantic.error, size: t.IconSizes.toolbar),
            title: '$_name 已退出',
            meta: 'exitCode ${c.exitCode ?? '—'} · signal ${c.signal ?? 'none'}',
            trailing: Chevron(expanded: _expanded),
            onTap: () => setState(() => _expanded = !_expanded),
            bare: true,
          ),
          if (_expanded)
            CardBody(
              padding: const EdgeInsets.all(t.Spacing.s12),
              children: <Widget>[
                const SectionLabel('stderr 尾巴（最后 5 行）'),
                MonoBlock(text: _tail(c)),
                Row(
                  children: <Widget>[
                    AcpButton(label: '重启 agent', kind: ButtonKind.primary, onTap: widget.onRestart),
                    const SizedBox(width: t.Spacing.s8),
                    AcpButton(label: '在流量面板查看原始行', onTap: widget.onOpenTraffic),
                  ],
                ),
              ],
            ),
        ]),
      AgentLifecycle.authenticating => _row(
          icon: const Spinner(),
          title: '正在认证${c.authenticatingLabel == null ? '' : '：${c.authenticatingLabel}'}',
          meta: 'methodId ${c.authenticatingMethodId ?? '?'}${c.authenticatingTerminalId == null ? '' : ' · terminalId ${c.authenticatingTerminalId}'}',
        ),
      AgentLifecycle.coreReady => _row(
          icon: const AcpIcon(AcpIcons.dot, color: t.Neutral.placeholder, size: t.IconSizes.toolbar),
          title: '核心已就绪',
          meta: 'core_ready',
        ),
      AgentLifecycle.none || AgentLifecycle.unknown => _row(
          icon: const AcpIcon(AcpIcons.dashedCircle, color: t.Neutral.placeholder, size: t.IconSizes.toolbar),
          title: _name,
          meta: c.rawState ?? '',
        ),
    };
  }

  static String _tail(AgentConnection c) {
    final tail = c.stderrTail;
    if (tail != null && tail.isNotEmpty) {
      final lines = tail.split('\n');
      return lines.length <= AgentStateStore.stderrKeep ? tail : lines.sublist(lines.length - AgentStateStore.stderrKeep).join('\n');
    }
    return c.stderrLines.join('\n');
  }

  Widget _card(List<Widget> children) => TranscriptCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children),
      );

  Widget _row({required Widget icon, required String title, required String meta, Widget? trailing, VoidCallback? onTap, bool bare = false}) {
    final row = SizedBox(
      height: t.Controls.input + t.Spacing.s8,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12),
        child: Row(
          children: <Widget>[
            icon,
            const SizedBox(width: t.Spacing.s8),
            Text(title, style: CardText.headerTitle),
            const SizedBox(width: t.Spacing.s8),
            Expanded(child: Text(meta, style: t.TextStyles.monoMeta, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ?trailing,
          ],
        ),
      ),
    );
    final body = onTap == null ? row : GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: row);
    return bare ? body : TranscriptCard(child: body);
  }
}

/// 未知会话更新已丢弃（告警）：核心侧计数 + acp/agent_state 上抛；原文落 acp/traffic。
class DroppedUpdatesBar extends StatelessWidget {
  const DroppedUpdatesBar({super.key, required this.count, this.onOpenTraffic});

  final int count;
  final VoidCallback? onOpenTraffic;

  @override
  Widget build(BuildContext context) {
    return TranscriptCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            height: t.Controls.input + t.Spacing.s8,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12),
              child: Row(
                children: <Widget>[
                  const AcpIcon(AcpIcons.alertTriangle, color: t.Semantic.warning, size: t.IconSizes.toolbar),
                  const SizedBox(width: t.Spacing.s8),
                  Text('$count 条未知会话更新已丢弃', style: CardText.headerTitle),
                  const SizedBox(width: t.Spacing.s8),
                  Expanded(child: Text('sessionUpdate 反序列化失败 · 原文见 ACP 流量调试', style: t.TextStyles.monoMeta, maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
          ),
          Container(
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
            padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
            child: Row(children: <Widget>[AcpButton(label: '打开流量面板', onTap: onOpenTraffic)]),
          ),
        ],
      ),
    );
  }
}
