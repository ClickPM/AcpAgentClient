// 画板 54 B1 / B2 · 停止 agent 确认弹层（R10）：
// 锚在条目右侧 Stop 按钮下方（右对齐），宽 Geometry.menuWidth（280），样式与画板 41 的 DeleteSessionConfirm 一致。
//   - B1：有会话挂在该 agent 上（但无回合在跑、无会话在等你处理）→ 按钮「停止」
//   - B2：有回合在跑，或有会话在等你处理（画板 09 口径）→ 加 warning 色块说明后果，按钮「仍然停止」
//   - B3：无会话时不弹此确认，直接进入停止中态。

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import '../format.dart';
import '../popovers/menu.dart';
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';

/// 停止确认弹层的数据快照（供状态层单测与组件渲染共用）。
class StopConfirmData {
  const StopConfirmData({
    required this.agentId,
    required this.agentName,
    required this.sessionCount,
    this.runningSessions = 0,
    this.awaitingSessions = 0,
    this.awaitingVerb = '授权',
    this.processCount,
    this.bytes,
  });

  final String agentId;
  final String agentName;
  final int sessionCount;
  final int runningSessions;
  final int awaitingSessions;
  final String awaitingVerb;
  final int? processCount;
  final int? bytes;

  /// 是否处于 B2 态（有回合在跑或有会话在等你处理）。
  bool get hasActiveWork => runningSessions > 0 || awaitingSessions > 0;
}

class StopAgentConfirm extends StatelessWidget {
  // ignore: prefer_const_constructors_in_immutables
  StopAgentConfirm({
    super.key,
    required this.agentName,
    required this.sessionCount,
    this.runningSessions = 0,
    this.awaitingSessions = 0,
    this.awaitingVerb = '授权',
    this.processCount,
    this.bytes,
    this.width = t.Geometry.menuWidth,
    this.onCancel,
    this.onConfirm,
  });

  factory StopAgentConfirm.fromData(
    StopConfirmData data, {
    Key? key,
    double width = t.Geometry.menuWidth,
    VoidCallback? onCancel,
    VoidCallback? onConfirm,
  }) => StopAgentConfirm(
    key: key,
    agentName: data.agentName,
    sessionCount: data.sessionCount,
    runningSessions: data.runningSessions,
    awaitingSessions: data.awaitingSessions,
    awaitingVerb: data.awaitingVerb,
    processCount: data.processCount,
    bytes: data.bytes,
    width: width,
    onCancel: onCancel,
    onConfirm: onConfirm,
  );

  final String agentName;
  final int sessionCount;
  final int runningSessions;
  final int awaitingSessions;
  final String awaitingVerb;
  final int? processCount;
  final int? bytes;
  final double width;
  final VoidCallback? onCancel;
  final VoidCallback? onConfirm;

  bool get hasActiveWork => runningSessions > 0 || awaitingSessions > 0;

  static String buildWarningText({
    required int runningSessions,
    required int awaitingSessions,
    String awaitingVerb = '授权',
  }) {
    final parts = <String>[
      if (runningSessions > 0) '$runningSessions 个会话正在运行回合',
      if (awaitingSessions > 0) '$awaitingSessions 个会话在等你$awaitingVerb',
    ];
    return '${parts.join('，')}。停止会中断回合，未回答的请求作废，排队的消息清空。';
  }

  static String buildBodyText({
    required int sessionCount,
    int? processCount,
    int? bytes,
  }) {
    final procPart = processCount != null && bytes != null
        ? '结束它的全部 $processCount 个进程（约 ${formatBytes(bytes)}）。'
        : '结束它的全部进程。';
    return '$procPart挂在它上面的 $sessionCount 个会话会断开，转录保留；再次打开会话时重新连接并载回。';
  }

  @override
  Widget build(BuildContext context) {
    return MenuPopover(
      width: width,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(t.Spacing.s8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('停止 $agentName？', style: CardText.strong),
              if (hasActiveWork) ...<Widget>[
                const SizedBox(height: t.Resource.confirmGap),
                Container(
                  padding: t.Resource.warningPadding,
                  decoration: BoxDecoration(
                    color: t.Semantic.warningSoft,
                    borderRadius: t.Radii.control,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Padding(
                        padding: t.Resource.warningIconPadding,
                        child: AcpIcon(
                          AcpIcons.alertTriangle,
                          size: t.Resource.iconSize,
                          strokeWidth: t.Badge.iconStroke,
                          color: t.Semantic.warning,
                        ),
                      ),
                      const SizedBox(width: t.Resource.gap),
                      Expanded(
                        child: Text(
                          buildWarningText(
                            runningSessions: runningSessions,
                            awaitingSessions: awaitingSessions,
                            awaitingVerb: awaitingVerb,
                          ),
                          style: t.TextStyles.secondary.copyWith(
                            color: t.Semantic.warning,
                            height: t.LineHeights.body,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: t.Resource.confirmGap),
              Text(
                buildBodyText(
                  sessionCount: sessionCount,
                  processCount: processCount,
                  bytes: bytes,
                ),
                style: t.TextStyles.secondary.copyWith(
                  height: t.LineHeights.body,
                ),
              ),
              const SizedBox(height: t.Resource.confirmGap),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  AcpButton(label: '取消', onTap: onCancel),
                  const SizedBox(width: t.Resource.gap),
                  AcpButton(
                    label: hasActiveWork ? '仍然停止' : '停止',
                    labelColor: t.Semantic.error,
                    onTap: onConfirm,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
