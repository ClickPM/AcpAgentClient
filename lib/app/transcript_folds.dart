// 画板 08 B「回合折叠」的状态：一个全局开关（画板 70「转录」小节，落 `settings.json` 的 `transcript` 段）
// 加每个回合各自的展开态。分组规则本身在 `lib/projection/turn_fold.dart`，这一层只管「折不折」。
//
// **展开态用 [Expando] 按 `TurnEntry` 实例记**，不按 `sessionId + turnId` 记：
// - 回合 id 是每个 store 自己的本地序号（`turn_1`、`turn_2`…），两条会话会撞；
// - 会话重开 / `session/load` 重放会把旧的 [TurnEntry] 整批换掉，按 id 记就会把旧选择套到新回合上，
//   而画板要的正是「重开会话回到默认折叠」；
// - Expando 持弱引用，store 一丢，这里不用任何清理代码就跟着没了。
//
// **已知限制**：`session/load` 的重放不带回轮边界（R6 裁定，docs/design.md § 3），重放出来的历史里
// 没有 [TurnEntry]，所以也不会有摘要行——折叠只对本次会话里真正跑过的回合生效。

import 'package:flutter/foundation.dart';

import '../projection/turn_fold.dart';
import '../projection/wire.dart';
import 'core_bridge.dart';

/// `settings.json` 的 `transcript` 段（Rust 侧 `settings::Transcript`）。
class TranscriptPrefs {
  const TranscriptPrefs({this.collapseFinishedTurns});

  factory TranscriptPrefs.fromJson(JsonMap json) => TranscriptPrefs(
        collapseFinishedTurns: json['collapse_finished_turns'] is bool ? json['collapse_finished_turns'] as bool : null,
      );

  /// null = 没存过，落到 [TranscriptFolds.autoCollapseDefault]。
  final bool? collapseFinishedTurns;

  JsonMap toJson() => <String, dynamic>{'collapse_finished_turns': collapseFinishedTurns};
}

class TranscriptFolds extends ChangeNotifier {
  TranscriptFolds({this.bridge});

  /// 没有桥（gallery / 单测）就只在内存里生效，不落盘。
  final CoreCommands? bridge;

  /// 画板 70：「回合结束后折叠处理过程」**默认开**。默认值只写在这里，Rust 侧不复制一份。
  static const bool autoCollapseDefault = true;

  bool? _stored;

  /// 用户手动切过的回合（true = 折叠，false = 展开）。没记过的按默认值算。
  final Expando<bool> _explicit = Expando<bool>('turn fold');

  bool _disposed = false;

  /// [start] 这一趟读盘的完成信号；改设置前要先等它，免得读盘回来把用户刚点的那一下盖回去。
  Future<void>? _hydration;

  /// 用户已经动过这个开关：之后读盘回来的值一律不再覆盖内存里的选择。
  bool _edited = false;

  /// 读设置成功过没有。没成功过就不落盘（与 `appearance` 同一条教训：别把「读失败 → 缺省」写回去）。
  bool _readSettingsOk = false;

  /// 全局开关的当前值。
  bool get autoCollapse => _stored ?? autoCollapseDefault;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// 启动：读一次盘。失败只是回到默认开，不挡启动。
  Future<void> start() {
    final Future<void> hydration = _hydrate();
    _hydration = hydration;
    return hydration;
  }

  Future<void> _hydrate() async {
    final CoreCommands? bridge = this.bridge;
    if (bridge == null) return;
    bool? loaded;
    try {
      loaded = TranscriptPrefs.fromJson(await bridge.transcriptPrefsGet()).collapseFinishedTurns;
      _readSettingsOk = true;
    } on Object catch (e) {
      debugPrint('transcript: 读设置失败，回默认: $e');
      return;
    }
    // 读盘期间用户已经点过了：他的选择更新，不要拿盘上的旧值盖回去。
    if (_disposed || _edited || loaded == _stored) return;
    _stored = loaded;
    notifyListeners();
  }

  Future<void> _awaitHydration() async {
    final Future<void>? hydration = _hydration;
    if (hydration == null) return;
    try {
      await hydration;
    } on Object {
      // 读盘失败不挡后续操作。
    }
  }

  /// 改全局开关：立即生效 + 落盘。落盘失败不回滚（界面已经变了，下次启动回到旧值即可）。
  Future<void> setAutoCollapse(bool value) async {
    _edited = true;
    if (_stored != value) {
      _stored = value;
      if (!_disposed) notifyListeners();
    }
    await _awaitHydration();
    // 这一笔已经被后来的点击顶掉了就别再发（发布前审查 P2，2026-09-22）：两次点击会并行走到这里，
    // 各自带着**调用当时**捕获的 `value`，先点的那笔若后落地就把用户最后的选择盖回去了。
    // 只发「与当前内存值一致」的那一笔，连点多少下都收敛到最后一下。
    if (_stored != value) return;
    final CoreCommands? bridge = this.bridge;
    if (bridge == null || !_readSettingsOk) return;
    try {
      await bridge.transcriptPrefsSet(TranscriptPrefs(collapseFinishedTurns: value).toJson());
    } on Object catch (e) {
      debugPrint('transcript: 写设置失败: $e');
    }
  }

  // ---------------------------------------------------------------- 每个回合的展开态

  /// 这一轮此刻折不折。运行中的回合永远展开（画板：流式期间必须可见），也不出摘要行——
  /// 摘要行是 `stop_reason` 到达之后才有的东西（见 `lib/ui/transcript/transcript_list.dart`）。
  bool isCollapsed(TurnFold fold) {
    if (fold.turn.isRunning) return false;
    final bool? explicit = _explicit[fold.turn];
    if (explicit != null) return explicit;
    return autoCollapse && fold.autoCollapsible;
  }

  /// 点摘要行：折 ↔ 展，并记住（会话打开期间保持）。
  void toggle(TurnFold fold) {
    _explicit[fold.turn] = !isCollapsed(fold);
    notifyListeners();
  }

  /// 展开某一轮（画板 43 的时间线跳到折叠块里的目标时先调它）。已经展开就什么都不做，不多发一次通知。
  /// 返回真表示这次确实展开了：调用方据此知道布局会变、要等下一帧再量位置。
  bool expand(TurnFold fold) {
    if (!isCollapsed(fold)) return false;
    _explicit[fold.turn] = false;
    notifyListeners();
    return true;
  }
}
