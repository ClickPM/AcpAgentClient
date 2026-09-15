// 用量（docs/acp-projection.md § 2.5）：`usage_update` 是会话级上下文窗口（used / size / cost?），不是每轮增量；
// 回合级用量在 PromptResponse.usage 上，落在 TurnEntry（entries.dart）。纯 Dart。

import 'wire.dart';

class UsageState {
  const UsageState({required this.used, required this.size, this.costAmount, this.costCurrency});

  factory UsageState.fromUpdate(SessionUpdateWire u) => UsageState(
        used: u.used ?? 0,
        size: u.size ?? 0,
        costAmount: u.cost?.amount,
        costCurrency: u.cost?.currency,
      );

  final num used;
  final num size;
  final num? costAmount;
  final String? costCurrency;

  bool get hasCost => costAmount != null;

  /// 0–1 的占比；size 为 0 时为 0。
  double get fraction => size <= 0 ? 0 : (used / size).clamp(0, 1).toDouble();

  /// 百分比整数（画板 30：1% / 78%）。
  int get percent => (fraction * 100).round();

  JsonMap toJson() => <String, dynamic>{'used': used, 'size': size, 'costAmount': costAmount, 'costCurrency': costCurrency};

  /// 10k / 1M 这类缩写（画板 30「1% · 10k / 1M」）。
  static String compact(num n) {
    if (n >= 1000000) return '${_trim(n / 1000000)}M';
    if (n >= 1000) return '${_trim(n / 1000)}k';
    return n.toString();
  }

  static String _trim(double v) {
    final s = v.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }
}
