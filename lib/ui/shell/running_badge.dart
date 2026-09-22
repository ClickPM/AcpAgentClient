// 画板 08 C · 在跑会话数徽标：11px 循环箭头 + 数字，accent 文字配 `badge.accent.bg` 底。
// 出现在项目切换钮（全部工作区合计）与切换器每一行（该工作区各自的数）上。
//
// 图标**静态不旋转**（linear 动效在本系统只留给画板 06 的扫掠），数字直切不做过渡，
// 为 0 一律不渲染（调用方用 [RunningBadge.maybe]，不留占位）。

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import '../transcript/icons.dart';

class RunningBadge extends StatelessWidget {
  const RunningBadge(this.count, {super.key});

  final int count;

  /// 为 0 就不渲染（画板：无徽标、无灰底 0、不留占位）。
  static Widget? maybe(int count) => count <= 0 ? null : RunningBadge(count);

  /// 两位数照排、宽度自增；> 99 显示 `99+`。
  static String label(int count) => count > t.Badge.overflowAt ? '${t.Badge.overflowAt}+' : '$count';

  @override
  Widget build(BuildContext context) => Container(
        height: t.Badge.height,
        padding: t.Badge.padding,
        decoration: BoxDecoration(color: t.Badge.accentBg, borderRadius: t.Badge.radius),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AcpIcon(
              AcpIcons.rotateCw,
              color: t.Accent.text,
              size: t.Badge.iconSize,
              strokeWidth: t.Badge.iconStroke,
            ),
            const SizedBox(width: t.Badge.gap),
            Text(
              label(count),
              style: t.TextStyles.monoMeta.copyWith(
                color: t.Accent.text,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      );
}
