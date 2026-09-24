// 画板 08 B「滚动锚点」：折叠 / 展开之后，视口里**该回合的结论保持原位**，不跳顶也不跳底。
//
// 有三条触发路径。第 1 轮实现只顾了第一条（复审 high，2026-09-22），第 2 轮补了第二条，第三条是复审 P2（同日）：
//   ① 点摘要行（手动折 / 展）；
//   ② `stop_reason` 到达那一帧的**自动折叠** —— 它是 `isCollapsed` 翻面之后由重建自然发生的，
//      不经过任何点击回调。人没贴在列表底部时（例如翻上去重读刚流出来的结论），折叠块整段消失，
//      视口内容当场往前跳一整段折叠高度；
//   ③ 画板 70 的全局开关（`TranscriptFolds.setAutoCollapse`；设置页与转录同屏，一下让所有已结束回合同时折 / 展）
//      与画板 43 跳转前的 `expand` —— 它们只通知 `TranscriptFolds`，既不走点击回调也不经过 store。
// 三条路都有一次「转录重建之前」的机会量旧布局：① 是点击回调，② 是 store 的通知回调，③ 是 `TranscriptFolds`
// 的通知回调（通知到达时 `isCollapsed` 已经翻面而屏幕还是旧布局，与 ② 同一个时机）。所以统一成
// [toggle] / [beforeRebuild] → 重建 → 帧后校正这一条；③ 由这里自己订阅 `TranscriptFolds`，组合根只需接 ②。
//
// 锚点取**折叠块之后第一个此刻量得到的行**：按顺序是本轮剩下的条目（多数情况就是最终助手文本），
// 最后是回合页脚（画板写的锚就是页脚）。只认一个固定的行不行 —— 人停在很长的结论中间时页脚在
// 视口之外、没建出来；人停在页脚上时结论的顶又在视口之外。位置按 [transcriptRowKey] /
// [turnFooterKey] 的 GlobalKey 量，所以只有工作台里那一份转录（`trackRows` 开着）会校正。
// 一帧里多轮同时变（全局开关）时从后往前找第一个量得到的那一轮：靠后的那轮离视口最近，它的锚点之上的
// 变化全被这一个锚点带住，它之下的变化本来就不挪视口。
//
// **重建之后锚点行离开了已建窗口、量不到时**（折叠块高过窗口时展开、或全局开关一下展开几十行），
// 不拿 `maxScrollExtent` 估——第 2 轮整改一度按它的变化量粗调一把，第 3 轮审查指出那是错的，已删：
//   · 列表已经建到最后一行时，Flutter 在同一帧的 layout 里已经把 `pixels` 夹进新的
//     `maxScrollExtent`，等于替我们补了一部分；再按 extent 差值减一次就是重复补偿，
//     人离底部 d、折叠高度 H 且 d < H 时会多推 H − d；
//   · 还没建到最后一行时 `maxScrollExtent` 是按已建行平均高度外推的，折叠会换掉这批已建行，
//     外推值可能不降反升（`transcript_jump.dart` 文件头记过一次 27292 → 230347），
//     差值为正就把人直接夹到列表底部。
// 而是交给画板 43 那套 [TranscriptJump] 一屏一屏把锚点行找回来，落点是它原来在视口里的 y（复审 P2，
// 2026-09-22，同时收掉了此前记在 rounds/BACKLOG.md 的「锚点量不到时不校正」残余）。

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/widgets.dart';

import '../projection/entries.dart';
import '../projection/turn_fold.dart';
import '../ui/transcript/transcript_list.dart';
import 'transcript_folds.dart';
import 'transcript_jump.dart';

class TranscriptFoldAnchor {
  TranscriptFoldAnchor({required this.controller, required this.entries, required this.folds}) {
    // 快照按此刻的状态打底：列表第一帧就按它建，之后只认「变化」。不打底的话全局开关第一次翻面
    // （例如从默认全折到全展）会被当成「没变」，整条路不校正。
    _collapsed = _collapsedNow();
    // 路径 ③：全局开关与时间线跳转前的 `expand` 只通知 `TranscriptFolds`。
    folds.addListener(beforeRebuild);
  }

  final ScrollController controller;

  /// 当前会话的转录条目（换会话时供给方自然给出新的一份）。
  final List<TranscriptEntry> Function() entries;
  final TranscriptFolds folds;

  /// 锚点行被推出已建窗口时的找回器（见文件头）。行列表与 `TranscriptList` 同一口径。
  late final TranscriptJump _jump = TranscriptJump(controller: controller, rows: _rows);

  /// 上一帧折着的轮。用来认出「这一帧有轮自己折 / 展了」（路径 ② / ③）。
  Set<String> _collapsed = const <String>{};

  /// 这一次要盯的锚：那一行的 GlobalKey、它的行 id（[transcriptRowId]）与它在视口里的 y。
  GlobalObjectKey<State<StatefulWidget>>? _anchor;
  String _anchorRowId = '';
  double _anchorTop = 0;

  /// 帧后校正已经排上了（同一帧里点两下不排两次）。
  bool _scheduled = false;

  /// 小于这个位移就不动（浮点噪声，跳一下反而多一帧）。
  static const double _epsilon = 0.5;

  /// 路径 ①：点摘要行。**由它代调 [TranscriptFolds.toggle]** —— 量旧布局必须在翻面之前。
  /// 先按点的那一轮定锚（[_collapsed] 快照万一过期，随后的通知也不会认错轮），翻面的通知再走一遍
  /// [beforeRebuild] 只是把快照同步掉：这一帧已经有锚就不再换。
  void toggle(TurnFold fold) {
    _arm(fold);
    folds.toggle(fold);
  }

  /// 路径 ② / ③：转录重建之前（store 或 `TranscriptFolds` 的通知）。这一刻 `isCollapsed` 已经翻面，
  /// 而屏幕上还是旧布局 —— 正好量。
  ///
  /// [arm] 为假时只同步快照、不定锚：组合根在视口贴着底部时这么调（iteration-15）。那时跟随会把视口留在底部，
  /// 结论本来就在最下面；这里再把结论钉回原位，收轮新出的回合页脚就被挤到视口外，离底部的那一截还会把跟随关掉，
  /// 之后再进来的内容都长在视口下面。
  void beforeRebuild({bool arm = true}) {
    final Set<String> now = _collapsedNow();
    if (setEquals(now, _collapsed)) return;
    final Set<String> changed = now.difference(_collapsed).union(_collapsed.difference(now));
    _collapsed = now;
    if (!arm) return;
    // 从后往前：收轮折叠的是最后那一轮；全局开关一下全变时，靠后的那轮离视口最近。
    // 量不到就再往前找一轮，直到有一轮的锚点此刻在已建窗口里。
    final List<TurnFold> turns = <TurnFold>[
      for (final f in foldsOf(entries()).values)
        if (changed.contains(f.id)) f,
    ];
    for (final TurnFold fold in turns.reversed) {
      if (_arm(fold)) return;
    }
  }

  /// 换会话 / 时间线自己要跳：这次没做完的校正不再算数，快照按此刻的状态重打（列表下一帧就按它建）。
  void cancel() {
    _anchor = null;
    _jump.cancel();
    _collapsed = _collapsedNow();
  }

  /// 组件销毁：退订并作废（不再碰 [entries]，供给方可能已经在销毁）。
  void dispose() {
    folds.removeListener(beforeRebuild);
    _anchor = null;
    _jump.cancel();
  }

  List<TranscriptRow> _rows() {
    final List<TranscriptEntry> all = entries();
    return buildRows(all, folds: foldsOf(all), collapsed: folds.isCollapsed);
  }

  Set<String> _collapsedNow() => <String>{
        for (final f in foldsOf(entries()).values)
          if (folds.isCollapsed(f)) f.id,
      };

  /// 记下这一轮的锚点位置并排一次帧后校正；返回这一轮有没有量到锚。这一帧已经定过锚就不再换
  /// （先定的那个更靠前于变化，位移都能带住）。折叠块之后一行都还没建出来的话不记：
  /// 用户此刻看的就是折叠块自己（或它上面的内容），而那一段的位置不受折叠影响，不动就是对的。
  bool _arm(TurnFold fold) {
    if (!controller.hasClients) return false;
    if (_anchor != null) return true;
    for (final (key, rowId) in _candidates(fold)) {
      final double? top = _topOf(key);
      if (top == null) continue;
      _anchor = key;
      _anchorRowId = rowId;
      _anchorTop = top;
      _schedule();
      return true;
    }
    return false;
  }

  /// 折叠块之后可以当锚的行，从近到远：本轮剩下的条目，最后是回合页脚。每项是「量位置的键 + 行 id」。
  Iterable<(GlobalObjectKey<State<StatefulWidget>>, String)> _candidates(TurnFold fold) sync* {
    final List<TranscriptEntry> all = entries();
    final int from = all.indexOf(fold.folded.last) + 1;
    if (from > 0) {
      for (var i = from; i < all.length; i++) {
        final TranscriptEntry e = all[i];
        if (e is TurnEntry) {
          // 轮边界自己不出行（`buildRows` 跳过它），当不了锚。
          // **实时轮**（`fold.turn != null`）到此为止：下面那句 yield 会把回合页脚给出来，它离得更近。
          // **重放回来的历史轮**没有轮边界、也就没有页脚兜底，跳过这一条继续往后找：折叠块之后
          // 变化点之下的任何一行位移都一样带得住，`_arm` 取第一个此刻量得到的即可（复审 P2 两轮，
          // 2026-09-22：先是这一轮收在工具调用上时一条候选都没有，后是只给一条、而那一条恰好
          // 已经滚出 ListView 缓存时仍然落空）。
          if (fold.turn != null) break;
          continue;
        }
        // 折叠块之后**这一轮剩下的条目**；历史轮再往后还有下一轮的条目（同上）。
        // 顶层用户消息在这里不当分界：实时轮按 `TurnEntry` 切轮，agent 发来一条对不上的
        // `user_message_chunk` 时投影层会在折叠块之后另起一条顶层用户消息，那不是新一轮，
        // 按它停下会把本轮结论整段掐出候选（复审 P2，2026-09-22）。
        yield (transcriptRowKey(e), transcriptRowId(EntryRow(e)));
      }
    }
    final TurnEntry? turn = fold.turn;
    if (turn != null) yield (turnFooterKey(turn), transcriptRowId(TurnEndRow(turn)));
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      _correct();
    });
  }

  void _correct() {
    final GlobalObjectKey<State<StatefulWidget>>? anchor = _anchor;
    _anchor = null;
    if (anchor == null || !controller.hasClients) return;
    final double? top = _topOf(anchor);
    if (top != null) {
      _jumpBy(controller.position, top - _anchorTop);
      return;
    }
    // 量不到：锚点行被推出了已建窗口。一屏一屏找回来，落点仍是它原来在视口里的 y（见文件头）。
    final double? viewportTop = _viewportTop();
    if (viewportTop == null) return;
    _jump.start(_anchorRowId, topInset: _anchorTop - viewportTop);
  }

  /// 锚点在视口里往下跑了 `delta`（往上跑就是负的），把 `pixels` 同向加回去，它就停在原地：
  /// y = 内容偏移 − pixels，内容偏移变了 delta，pixels 也加 delta，y 不变。
  /// **一律夹回合法区间**：落点永远在内容之内，任何一帧都不会出现空白视口。
  void _jumpBy(ScrollPosition p, double delta) {
    if (delta.abs() <= _epsilon) return;
    // 用户正在拖 / 触控板正在滑：`jumpTo` 会 goIdle 把这次滚动掐断，让他先滑完
    // （与 `workbench_screen._followToBottom`、`TranscriptJump._step` 同一条规矩）。
    if (p.userScrollDirection != ScrollDirection.idle) return;
    final double next = (p.pixels + delta).clamp(p.minScrollExtent, p.maxScrollExtent);
    if ((next - p.pixels).abs() > _epsilon) controller.jumpTo(next);
  }

  /// 转录视口顶边在屏幕坐标系里的 y（与 [_topOf] 同一坐标系，两者相减就是行在视口里的 y）。
  double? _viewportTop() {
    final RenderObject? box = controller.position.context.storageContext.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize ? box.localToGlobal(Offset.zero).dy : null;
  }

  /// 这一行此刻在屏幕坐标系里的顶边；没建出来回 null。
  static double? _topOf(GlobalObjectKey<State<StatefulWidget>> key) {
    final RenderObject? box = key.currentContext?.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize ? box.localToGlobal(Offset.zero).dy : null;
  }
}
