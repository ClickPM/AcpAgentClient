// 画板 43 的时间线跳转：把转录滚到指定行，落点是「目标块顶边对齐转录区顶部内边距」，不做滚动动画。
// 画板 08 B 的折叠锚点也用它（`transcript_fold_anchor.dart`）：锚点行被折 / 展推出已建窗口、量不到时，
// 按同一套步进把它找回来，落点换成它原来在视口里的 y（[start] 的 `topInset`）。
//
// 惰性列表（`ListView.builder`）里目标行多半还没建出来 —— 没建出来的行没有 RenderObject，拿不到真实位置。
// 这里**不按 `maxScrollExtent` 估位**：那个值对没建出来的那截是按已建行的平均外推的
// （`SliverMultiBoxAdaptorElement._extrapolateMaxScrollOffset`），会随着建出来的那批行换一批而剧烈变动。
// 拿它做 `max * index / count` 的乘法会发散 —— 2026-09-22 复现（40 轮、内容重量压在开头几轮、跳第 20 轮）：
// 第二帧 `maxScrollExtent` 从 27292 爆到 230347，落点 109414 远在真实内容末端之外，sliver 的 `paintExtent`
// 归零 = 整片白屏，下一帧被拉回来又跳出去，肉眼就是高频白屏闪烁，帧数耗尽后停在越界位置。
//
// 改成**单向步进**：锚在「这一帧真正布好局的首 / 末行」上（`RenderSliverMultiBoxAdaptor` 的
// `firstChild` / `lastChild`；被 keep-alive 缓存起来的行已经被 `remove` 出子链表，不会混进来），
// 用它们量出来的真实几何一屏一屏朝目标挪，直到目标自己被建出来再精确落位。两条性质保证不复发：
//   · 落点永远不超过锚行的底边 —— 全是量到的内容，`pixels` 越不过真实内容末端，所以不会白屏；
//   · 方向由「目标在已建区间的哪一侧」定死、每帧至少推进一个 cacheExtent，所以单调收敛、不来回震荡。

import 'dart:math' as math;

import 'package:flutter/rendering.dart' show RenderAbstractViewport, RenderSliverMultiBoxAdaptor, ScrollDirection;
import 'package:flutter/widgets.dart';

import '../theme/tokens.dart' as t;
import '../ui/transcript/transcript_list.dart';

/// 一次「跳到某一行」的驱动器：每帧推进一步，直到落位或放弃。
/// 同一时刻只跳一行（[start] 会顶掉上一次未完成的跳转）。
class TranscriptJump {
  TranscriptJump({required this.controller, required this.rows});

  final ScrollController controller;

  /// 每帧重新取一次行列表：跳的过程中流式还在长内容，行序会变，按 id 重新定位才不会跳错。
  final List<TranscriptRow> Function() rows;

  /// 正在跳向的行 id（[transcriptRowId]）；null = 没在跳。
  String? _target;

  /// 落位时目标行顶边到视口顶边的距离：画板 43 的跳转是转录区顶部内边距，折叠锚点给的是那一行原来的 y。
  double _inset = t.Spacing.s16;

  /// 这一次跳已经步进了几帧 / 落位之后又校正了几帧。
  int _steps = 0;
  int _settles = 0;
  bool _scheduled = false;

  /// 步进的帧数上限。每帧至少推进一个 cacheExtent、通常是一整屏，300 帧够翻几百屏；
  /// 纯粹是防死循环的兜底，正常会话远用不到。
  static const int _maxSteps = 300;

  /// 落位之后最多再校正几帧：前插行会触发 `scrollOffsetCorrection`，第一跳可能差一点。
  static const int _maxSettles = 3;

  bool get isJumping => _target != null;

  /// 开始跳向 [rowId]（条目行就是条目 id，见 [transcriptRowId]）。目标已经在视口附近时当帧就位，不必等下一帧。
  /// [topInset]：落位时目标行顶边到视口顶边的距离。
  void start(String rowId, {double topInset = t.Spacing.s16}) {
    _target = rowId;
    _inset = topInset;
    _steps = 0;
    _settles = 0;
    _step();
    _schedule();
  }

  /// 停掉正在进行的跳转（换会话、组件销毁、用户拖着滚动条 / 惯性滚动还没停）。
  void cancel() => _target = null;

  void _schedule() {
    if (_target == null || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      _step();
      _schedule();
    });
  }

  /// 推进一帧：目标已经建出来就精确落位，没建出来就朝它挪一屏。
  void _step() {
    if (_target == null) return;
    if (!controller.hasClients) return cancel();
    final list = rows();
    final index = list.indexWhere((r) => transcriptRowId(r) == _target);
    if (index < 0) return cancel(); // 目标被 Restore 截断掉了 / 被折进折叠块里了
    final p = controller.position;
    // 拖着滚动条 / 触屏惯性还没停：让他先滑完，别跟他抢（与 workbench_screen 的跟随底部同一条规矩）。
    // 这条拦不住滚轮：`pointerScroll` 每个事件末尾就 `goBallistic(0)` → idle，滚轮滚完当帧即回 idle，
    // 跳转下一帧照常推进 —— 一次跳转只有几帧，滚轮打不断它是可接受的（审查 P3，2026-09-22）。
    if (p.userScrollDirection != ScrollDirection.idle) return cancel();
    final sliver = _sliver(p);
    final first = sliver?.firstChild;
    final last = sliver?.lastChild;
    if (sliver == null || first == null || last == null) return cancel();

    final double want;
    if (index < sliver.indexOf(first)) {
      // 目标在上面：把已建的第一行推到视口底，它上面那一屏这一帧就会被建出来。
      if (!_advance()) return;
      want = _revealOffset(first) - p.viewportDimension;
    } else if (index > sliver.indexOf(last)) {
      // 目标在下面：把已建的最后一行推到视口顶；那一行一屏装不下时改推它的底边，两者取大 ——
      // 既保证每帧有推进，落点又仍在这一行量到的范围里（越不过真实内容末端，所以不会白屏）。
      if (!_advance()) return;
      final top = _revealOffset(last);
      want = math.max(top, top + last.size.height - p.viewportDimension);
    } else {
      // 目标就在布好局的那一段里：按它自己的真实位置落位。
      final box = _rowBox(list[index]);
      if (box == null) return cancel();
      // `getOffsetToReveal(…, 0)` 给的是「目标顶边贴视口顶边」的偏移，再减去要留的距离：
      // 画板 43 是转录区顶部内边距，目标上方就正好留出那 16；锚点给的是那一行原来的 y。
      want = _revealOffset(box) - _inset;
      if (++_settles > _maxSettles) return cancel();
    }

    final to = want.clamp(p.minScrollExtent, p.maxScrollExtent);
    if ((to - p.pixels).abs() <= 0.5) return cancel(); // 已经在位 / 推不动了
    controller.jumpTo(to);
  }

  /// 记一帧步进；超过上限就收手，停在当前位置而不是继续空转。
  /// 两个计数器都**不互相清零**：清零的话「步进 → 落位 → 又被挤出已建区间 → 再步进」这种
  /// 拉锯就没有总预算了，理论上能一直转下去。各自单调，整次跳转就必然有头。
  bool _advance() {
    if (++_steps <= _maxSteps) return true;
    cancel();
    return false;
  }

  /// [box] 顶边贴视口顶边时的滚动偏移。
  double _revealOffset(RenderBox box) => RenderAbstractViewport.of(box).getOffsetToReveal(box, 0).offset;

  /// 已经建出来并布好局的那一行的 RenderBox；没建出来 = null。摘要行没有可量的键，不会成为目标。
  RenderBox? _rowBox(TranscriptRow row) {
    final GlobalObjectKey<State<StatefulWidget>>? key = switch (row) {
      EntryRow(:final entry) => transcriptRowKey(entry),
      TurnEndRow(:final turn) => turnFooterKey(turn),
      TurnFoldSummaryRow() => null,
    };
    final box = key?.currentContext?.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize ? box : null;
  }

  /// 转录列表底层那个惰性 sliver。只拿它的 `firstChild` / `lastChild` 当锚：那两行一定是这一帧
  /// 真正布好局的（keep-alive 缓存起来的行已被 `remove` 出子链表），位置是量出来的、不是估出来的。
  RenderSliverMultiBoxAdaptor? _sliver(ScrollPosition p) {
    final root = p.context.storageContext.findRenderObject();
    if (root == null) return null;
    RenderSliverMultiBoxAdaptor? found;
    void visit(RenderObject node) {
      if (found != null) return;
      if (node is RenderSliverMultiBoxAdaptor) {
        found = node;
        return;
      }
      node.visitChildren(visit);
    }

    visit(root);
    return found;
  }
}
