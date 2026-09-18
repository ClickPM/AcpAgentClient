// 画板 31 · 回合态与结束：运行中（线程头 spinner + 发送位替换为停止方块）与五种 stopReason 的结束行
// （end_turn success / max_tokens · max_turn_requests warning / refusal error / cancelled 中性；徽章文字即协议枚举原值）。
// 轮的边界是客户端自己切的（TurnEntry）；回合级 usage 来自 PromptResponse，cost 来自会话级 usage_update。
// 第六种是画板外的失败态（2026-09-18）：`session/prompt` 回 JSON-RPC error 时协议没有 stopReason，
// 结束行改显「失败」徽章 + `TurnEntry.error` 的原文，画板 31 补这一态的事记在 rounds/BACKLOG.md。

import 'package:flutter/widgets.dart';

import '../../projection/entries.dart';
import '../../projection/usage.dart';
import '../../theme/tokens.dart' as t;
import 'card_chrome.dart';
import 'icons.dart';
import 'terminal_card.dart';

String formatTokens(num? n) {
  if (n == null) return '';
  final s = n.round().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

String formatSeconds(Duration? d) => d == null ? '' : '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';

/// 线程头（运行中）：菱形图标 + 标题 + spinner。
class ThreadHeaderRunning extends StatelessWidget {
  const ThreadHeaderRunning({super.key, required this.title, this.running = true, this.note});

  final String title;
  final bool running;

  /// 画板 31 右侧的说明文字（gallery 用）。
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: t.Controls.input + t.Spacing.s8,
      decoration: BoxDecoration(
        color: t.Surface.canvas,
        borderRadius: t.Radii.card,
        border: Border.all(color: t.Borders.subtle, width: t.Borders.width),
      ),
      padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12),
      child: Row(
        children: <Widget>[
          const AcpIcon(AcpIcons.diamond, color: t.Accent.base),
          const SizedBox(width: t.Spacing.s8),
          Text(title, style: CardText.headerTitle),
          if (running) ...<Widget>[const SizedBox(width: t.Spacing.s8), const Spinner()],
          const Spacer(),
          if (note != null) Text(note!, style: CardText.secondary),
        ],
      ),
    );
  }
}

/// 输入框（运行中）：+ · 模型 / 模式下拉 · 停止方块（gallery 用；R3 的 composer 接投影层后替换）。
class ComposerRunning extends StatelessWidget {
  const ComposerRunning({super.key, this.thoughtLevel = 'High', this.mode = 'Write', this.onStop});

  final String thoughtLevel;
  final String mode;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: t.Controls.input + t.Spacing.s16,
      decoration: const BoxDecoration(color: t.Neutral.panel, borderRadius: t.Radii.card),
      padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s16),
      child: Row(
        children: <Widget>[
          const AcpIcon(AcpIcons.plus, color: t.Neutral.placeholder),
          const Spacer(),
          AcpButton(label: thoughtLevel, trailing: const Chevron(expanded: false)),
          const SizedBox(width: t.Spacing.s4),
          AcpButton(label: mode, trailing: const Chevron(expanded: false)),
          const SizedBox(width: t.Spacing.s8),
          StopSquareButton(onTap: onStop),
        ],
      ),
    );
  }
}

/// 回合结束行：[stopReason 徽章] 说明 · tokens（in / out）· cost · 耗时。
class TurnEndLine extends StatelessWidget {
  const TurnEndLine(this.turn, {super.key, this.usage});

  final TurnEntry turn;

  /// 会话级 usage（cost 从这里来）。
  final UsageState? usage;

  static ChipTone toneOf(String? reason) => switch (reason) {
        'end_turn' => ChipTone.success,
        'max_tokens' || 'max_turn_requests' => ChipTone.warning,
        'refusal' => ChipTone.error,
        _ => ChipTone.neutral,
      };

  static String describe(String? reason) => switch (reason) {
        'end_turn' => '',
        'max_tokens' => '达到模型上限，回答被截断',
        'max_turn_requests' => '达到单轮请求次数上限，已停止继续调用工具',
        'refusal' => 'agent 拒绝继续本轮',
        'cancelled' => '用户发出 session/cancel · 未完成的工具卡转本地 cancelled',
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    final reason = turn.stopReason;
    // 失败收轮：`session/prompt` 回了 JSON-RPC error（或连接断了），协议没给 stopReason。
    // 画板 31 只画了五种协议结束值，这一态是画板外的；不另起一张卡，就在这条结束行上把徽章换成
    // 「失败」、把原因写进说明位（转录里的文字还不能选中，所以允许折行，别让原因被 ellipsis 吃掉）。
    final failed = reason == null && turn.error != null;
    final u = turn.usage;
    final parts = <String>[];
    if (failed) parts.add(turn.error!);
    final d = describe(reason);
    if (d.isNotEmpty) parts.add(d);
    if (u?.total != null) {
      final io = u!.input != null || u.output != null ? '（in ${formatTokens(u.input)} / out ${formatTokens(u.output)}）' : '';
      parts.add('${formatTokens(u.total)} tokens$io');
    }
    if (reason == 'end_turn' && usage != null && usage!.hasCost) parts.add('\$${usage!.costAmount}');
    final elapsed = formatSeconds(turn.elapsed);
    if (elapsed.isNotEmpty) parts.add(elapsed);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: t.Controls.standard),
      child: Row(
        crossAxisAlignment: failed ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: <Widget>[
          Padding(
            padding: failed ? const EdgeInsets.only(top: t.Spacing.s8) : EdgeInsets.zero,
            child: ToneChip(failed ? '失败' : (reason ?? '?'), tone: failed ? ChipTone.error : toneOf(reason)),
          ),
          const SizedBox(width: t.Spacing.s8),
          Expanded(
            child: Padding(
              padding: failed ? const EdgeInsets.symmetric(vertical: t.Spacing.s8) : EdgeInsets.zero,
              child: Text(
                parts.join(' · '),
                style: CardText.headerTitle.copyWith(color: failed ? t.Semantic.error : t.Neutral.muted),
                maxLines: failed ? 3 : 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
