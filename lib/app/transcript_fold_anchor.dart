// 画板 08 B「滚动锚点」：折叠 / 展开之后，视口里**该回合的结论保持原位**，不跳顶也不跳底。
//
// 有两条触发路径，第 1 轮实现只顾了第一条（复审 high，2026-09-22）：
//   ① 点摘要行（手动折 / 展）；
//   ② `stop_reason` 到达那一帧的**自动折叠** —— 它是 `isCollapsed` 翻面之后由重建自然发生的，
//      不经过任何点击回调。人没贴在列表底部时（例如翻上去重读刚流出来的结论），折叠块整段消失，
//      视口内容当场往前跳一整段折叠高度。
// 两条路都有一次「转录重建之前」的机会量旧布局：前者是点击回调，后者是 store 的通知回调。
// 所以统一成 [toggle] / [beforeRebuild] → 重建 → 帧后校正这一条。
//
// 锚点取**折叠块之后第一个此刻量得到的行**：按顺序是本轮剩下的条目（多数情况就是最终助手文本），
// 最后是回合页脚（画板写的锚就是页脚）。只认一个固定的行不行 —— 人停在很长的结论中间时页脚在
// 视口之外、没建出来；人停在页脚上时结论的顶又在视口之外。位置按 [transcriptRowKey] /
// [turnFooterKey] 的 GlobalKey 量，所以只有工作台里那一份转录（`trackRows` 开着）会校正。
//
// **折叠块很高时锚点会被挪出已建窗口、帧后量不到**（`ListView` 默认 cacheExtent 只有 250）。
// 那时不放弃：先按滚动范围的收缩量粗调一次 —— 相邻两帧同一份估算的差值，再夹回合法区间，
// 落点不会出内容之外（`transcript_jump.dart` 文件头记的那次白屏是拿估算做**乘法**，不是取差值）——
// 下一帧页脚多半就回到已建窗口里，再精调一次。两帧之内收敛。

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/widgets.dart';

import '../projection/entries.dart';
import '../projection/turn_fold.dart';
import '../ui/transcript/transcript_list.dart';
import 'transcript_folds.dart';

class TranscriptFoldAnchor {
  TranscriptFoldAnchor({required this.controller, required this.entries, required this.folds});

  final ScrollController controller;

  /// 当前会话的转录条目（换会话时供给方自然给出新的一份）。
  final List<TranscriptEntry> Function() entries;
  final TranscriptFolds folds;

  /// 上一帧折着的轮。用来认出「这一帧有轮自己折 / 展了」（路径 ②）。
  Set<String> _collapsed = const <String>{};

  /// 这一次要盯的锚：那一行的 GlobalKey、它在视口里的 y、以及当时的 `maxScrollExtent`。
  GlobalObjectKey<State<StatefulWidget>>? _anchor;
  double _anchorTop = 0;
  double _maxExtent = 0;

  /// 帧后校正已经排上了（同一帧里点两下不排两次）。
  bool _scheduled = false;

  /// 小于这个位移就不动（浮点噪声，跳一下反而多一帧）。
  static const double _epsilon = 0.5;

  /// 路径 ①：点摘要行。**由它代调 [TranscriptFolds.toggle]** —— 量旧布局必须在翻面之前。
  void toggle(TurnFold fold) {
    _arm(fold.turn);
    folds.toggle(fold);
    _collapsed = _collapsedNow();
  }

  /// 路径 ②：转录重建之前（store 通知）。这一刻 store 已经收轮、`isCollapsed` 已经翻面，
  /// 而屏幕上还是旧布局 —— 正好量。
  void beforeRebuild() {
    final Set<String> now = _collapsedNow();
    if (setEquals(now, _collapsed)) return;
    final Set<String> changed = now.difference(_collapsed).union(_collapsed.difference(now));
    _collapsed = now;
    // 一帧里只可能有一轮自己折 / 展（收轮的是最后那一轮）；真撞上多条就盯最靠后的那一轮，
    // 它离视口最近。
    TurnEntry? target;
    for (final e in entries()) {
      if (e is TurnEntry && changed.contains(e.id)) target = e;
    }
    if (target != null) _arm(target);
  }

  /// 换会话 / 组件销毁：这次没做完的校正不再算数。
  void cancel() {
    _anchor = null;
    _collapsed = const <String>{};
  }

  Set<String> _collapsedNow() => <String>{
        for (final f in foldsOf(entries()).values)
          if (folds.isCollapsed(f)) f.turn.id,
      };

  /// 记下这一轮的锚点位置并排一次帧后校正。折叠块之后一行都还没建出来的话不记：
  /// 用户此刻看的就是折叠块自己（或它上面的内容），而那一段的位置不受折叠影响，不动就是对的。
  void _arm(TurnEntry turn) {
    if (!controller.hasClients) return;
    for (final key in _candidates(turn)) {
      final double? top = _topOf(key);
      if (top == null) continue;
      _anchor = key;
      _anchorTop = top;
      _maxExtent = controller.position.maxScrollExtent;
      _schedule();
      return;
    }
  }

  /// 折叠块之后可以当锚的行，从近到远：本轮剩下的条目，最后是回合页脚。
  Iterable<GlobalObjectKey<State<StatefulWidget>>> _candidates(TurnEntry turn) sync* {
    final TurnFold? fold = foldsOf(entries())[turn.id];
    final List<TranscriptEntry> all = entries();
    if (fold != null) {
      final int from = all.indexOf(fold.folded.last) + 1;
      if (from > 0) {
        for (var i = from; i < all.length; i++) {
          final TranscriptEntry e = all[i];
          if (e is TurnEntry) break; // 跨到下一轮就不算了
          yield transcriptRowKey(e);
        }
      }
    }
    yield turnFooterKey(turn);
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      _correct(precise: true);
    });
  }

  void _correct({required bool precise}) {
    final GlobalObjectKey<State<StatefulWidget>>? anchor = _anchor;
    if (anchor == null || !controller.hasClients) return;
    final ScrollPosition p = controller.position;
    final double? top = _topOf(anchor);
    if (top != null) {
      _anchor = null;
      _jumpBy(p, top - _anchorTop);
      return;
    }
    if (!precise) {
      // 粗调之后还是量不到（锚点离得太远）：收手，别一直空转。
      _anchor = null;
      return;
    }
    // 锚点被挪出已建窗口了：先按滚动范围的变化量粗调，下一帧再精调。
    // 锚点上方的内容少了 Δ，`maxScrollExtent` 也少 Δ，锚点的 y 同样少 Δ —— 三者同号，所以直接传差值。
    _jumpBy(p, p.maxScrollExtent - _maxExtent);
    _maxExtent = p.maxScrollExtent;
    WidgetsBinding.instance.addPostFrameCallback((_) => _correct(precise: false));
  }

  /// 锚点在视口里往下跑了 `delta`（往上跑就是负的），把 `pixels` 同向加回去，它就停在原地：
  /// y = 内容偏移 − pixels，内容偏移变了 delta，pixels 也加 delta，y 不变。
  /// **一律夹回合法区间**：落点永远在内容之内，任何一帧都不会出现空白视口。
  void _jumpBy(ScrollPosition p, double delta) {
    if (delta.abs() <= _epsilon) return;
    final double next = (p.pixels + delta).clamp(p.minScrollExtent, p.maxScrollExtent);
    if ((next - p.pixels).abs() > _epsilon) controller.jumpTo(next);
  }

  /// 这一行此刻在屏幕坐标系里的顶边；没建出来回 null。
  static double? _topOf(GlobalObjectKey<State<StatefulWidget>> key) {
    final RenderObject? box = key.currentContext?.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize ? box.localToGlobal(Offset.zero).dy : null;
  }
}
