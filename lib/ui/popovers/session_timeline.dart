// 画板 43 · 会话时间线弹层：按轮列「用户 query 首行（编号 01 / 02…）+ 该轮最终回答首行（A）」，
// 点一行转录区跳到那一条。数据是 `lib/projection/timeline.dart` 从 `SessionStore.entries` 纯派生出来的。
//
// 容器与画板 40 / 41 / 42 的弹层同一套（`Popover` + 封顶滚动 + 标题行钉在滚动区之外，见 menu.dart 的
// `MenuPopover`），但行里多一列导轨与节点，所以行不复用 `MenuRow`、另画一份；「高亮移出视口自动露出」
// 复用 menu.dart 的 `RevealWhenSelected`。

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../projection/timeline.dart';
import '../../theme/tokens.dart' as t;
import '../shell/shell_common.dart';
import '../transcript/card_chrome.dart';
import 'menu.dart';

/// 弹层里的一行：某一轮的编号行（用户）或它的 `A` 行（该轮最终回答）。
class TimelineRow {
  const TimelineRow({required this.turn, required this.isUser});

  final TimelineTurn turn;
  final bool isUser;

  /// 点这一行要跳到的转录条目。
  String get entryId => isUser ? turn.entryId : (turn.answerEntryId ?? turn.entryId);

  String get text => isUser ? turn.query : (turn.answer ?? '');

  /// 标签列的文案：用户行是两位编号（满 100 轮自然变三位），`A` 行固定一个字母。
  String get label => isUser ? turn.n.toString().padLeft(2, '0') : 'A';
}

/// 把轮摊成行：每轮先编号行，有回答再跟一条 `A` 行。
List<TimelineRow> timelineRows(List<TimelineTurn> turns) => <TimelineRow>[
      for (final turn in turns) ...<TimelineRow>[
        TimelineRow(turn: turn, isUser: true),
        if (turn.answer != null) TimelineRow(turn: turn, isUser: false),
      ],
    ];

class SessionTimelinePopover extends StatefulWidget {
  const SessionTimelinePopover({
    super.key,
    required this.turns,
    this.onJump,
    this.maxHeight,
    this.initialSelection = -1,
    this.forceHoverIndex = -1,
    this.scrollToBottomOnOpen = true,
  });

  final List<TimelineTurn> turns;

  /// 点一行、或高亮行按 Enter。关弹层与滚转录都由调用方做（画板 43：两件事都是 0ms）。
  final ValueChanged<TimelineRow>? onJump;

  /// 高度上限；null = 按当帧窗口高 × [t.Timeline.maxHeightFactor]（画板对照页给定值，免得依赖测试窗口大小）。
  final double? maxHeight;

  /// 画板对照页用的初始高亮。真实弹层**打开那一下没有高亮**（与画板 42 同口径）。
  final int initialSelection;

  /// 画板对照页用的强制悬浮行（画板 43 C 组的「悬浮容器 6%」样张）；-1 = 没有。
  final int forceHoverIndex;

  /// 打开时滚到底部，最新一轮在视口内（画板 43）。画板对照页关掉，样张才停在第一行。
  final bool scrollToBottomOnOpen;

  @override
  State<SessionTimelinePopover> createState() => _SessionTimelinePopoverState();
}

class _SessionTimelinePopoverState extends State<SessionTimelinePopover> {
  final ScrollController _scroll = ScrollController();

  /// 弹层开着时键盘焦点归它。
  ///
  /// **不能像 `EscapeDismissible` 那样走 `HardwareKeyboard` 的全局处理器**：那条路**挡不住焦点链** ——
  /// `KeyEventManager` 先跑全部全局处理器，随后**无条件**再把同一下按键发给焦点链，两个结果只是或起来
  /// 回给平台（flutter/lib/src/services/hardware_keyboard.dart 的 `handleRawKeyMessage`）。于是弹层开着时
  /// 那一下 Enter 照样落到输入框的 `Focus` 上被当成「发送」，把没写完的草稿发出去（发布前审查 P2，2026-09-20；
  /// 审查给的「Enter 也返回 true」按这个分发顺序是修不掉的）。方向键同理，会连带移动输入框里的光标。
  /// Esc 仍由 `EscapeDismissible` 的全局处理器管，它不与输入框争这个键。
  final FocusNode _focus = FocusNode(debugLabel: 'session-timeline');

  /// 打开前握着焦点的那个节点（多半是输入框）：关掉时还回去，免得用户得再点一下才能接着打字。
  FocusNode? _restoreFocusTo;
  late List<TimelineRow> _rows = timelineRows(widget.turns);
  late int _selected = widget.initialSelection;

  @override
  void initState() {
    super.initState();
    _restoreFocusTo = FocusManager.instance.primaryFocus;
    // 显式抢焦点，不靠 `autofocus`：`OverlayPortal` **不给** overlay 子树另开 `FocusScope`（overlay child
    // 与锚点同属一个域），而 `_Autofocus.applyIfValid` 要求 `scope.focusedChild == null` 才兑现
    //（flutter/lib/src/widgets/focus_manager.dart）—— 这个域里输入框已经是 focusedChild，autofocus 于是被
    // 直接丢弃，输入框照样握着键盘（实测；复审订正了「自成焦点域」那个说法）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
    if (widget.scrollToBottomOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  @override
  void didUpdateWidget(SessionTimelinePopover oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 弹层开着时转录还在长（后台那一轮跑完、或 agent 正在回字）：行重算，高亮跟着它指的那一行走。
    if (!identical(oldWidget.turns, widget.turns)) {
      final current = _selected >= 0 && _selected < _rows.length ? _rows[_selected] : null;
      _rows = timelineRows(widget.turns);
      _selected = current == null
          ? -1
          : _rows.indexWhere((r) => r.isUser == current.isUser && r.turn.n == current.turn.n);
    }
  }

  @override
  void dispose() {
    final restore = _restoreFocusTo;
    _focus.dispose();
    _scroll.dispose();
    // 焦点还回去要等这一帧收完：这会儿 `_focus` 刚被拆掉，焦点管理器还在重新挑主焦点。
    if (restore != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (restore.context != null) restore.requestFocus();
      });
    }
    super.dispose();
  }

  /// 弹层开着时**键盘完全归它**：上下键移高亮、Enter 命中，其余的键一概吃掉、什么也不做。
  ///
  /// 「其余的键也吃掉」不是图省事，是这条路径已经漏过两次（发布前审查与复审各一条 P2）：放行的键会沿焦点链
  /// 继续上浮到 `WidgetsApp` 的默认 `Shortcuts`，Tab / Shift+Tab / 左右方向键在那里是
  /// `NextFocusIntent` / `PreviousFocusIntent` / `DirectionalFocusIntent`，会把键盘交回输入框，
  /// 而弹层还开着 —— 之后 Enter 又走输入框的「发送」，把没写完的草稿发出去。逐个枚举要挡的键就是在赌
  /// 没有下一个漏网的，所以这里反过来：只放行 Esc（它由 `EscapeDismissible` 的全局处理器负责关这一层，
  /// 全局处理器本来就跑在焦点链之前，放不放行都拦不住，写成 ignored 只是让这件事在代码里看得见）。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        return KeyEventResult.ignored;
      case LogicalKeyboardKey.arrowDown:
        _move(1);
      case LogicalKeyboardKey.arrowUp:
        _move(-1);
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        if (_selected >= 0 && _selected < _rows.length) widget.onJump?.call(_rows[_selected]);
      default:
        break;
    }
    return KeyEventResult.handled;
  }

  /// 打开那一下没有高亮，所以第一次按下键从第一行起、按上键从最后一行起；之后夹在两端不回绕。
  void _move(int delta) {
    if (_rows.isEmpty) return;
    final next = _selected < 0
        ? (delta > 0 ? 0 : _rows.length - 1)
        : (_selected + delta).clamp(0, _rows.length - 1);
    if (next == _selected) return;
    setState(() => _selected = next);
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = widget.maxHeight ?? MediaQuery.sizeOf(context).height * t.Timeline.maxHeightFactor;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: _popover(maxHeight),
    );
  }

  Widget _popover(double maxHeight) {
    return Popover(
      radius: t.Radii.card,
      padding: const EdgeInsets.all(t.Spacing.s4),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SizedBox(
          width: t.Timeline.width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 标题行钉在滚动区之外（同 `MenuPopover` 里的搜索框）：长列表滚起来时它要一直在。
              MenuGroupLabel('Session timeline · ${widget.turns.length} turns', style: t.TextStyles.labelTabular),
              Flexible(
                child: SingleChildScrollView(
                  controller: _scroll,
                  child: _rows.isEmpty ? const _TimelineEmpty() : _body(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 导轨画在行的下面、只有一条：从第一个节点中心到最后一个节点中心（两端不出头）。
  /// 行高固定，所以「半行高」就正好是首尾节点的中心，不用去量。
  Widget _body() {
    return Stack(
      children: <Widget>[
        const Positioned(
          left: 0,
          width: t.Timeline.railColumn,
          top: t.Controls.standard / 2,
          bottom: t.Controls.standard / 2,
          child: Center(
            child: SizedBox(
              width: t.Timeline.railWidth,
              height: double.infinity,
              child: ColoredBox(color: t.Timeline.rail),
            ),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (var i = 0; i < _rows.length; i++) ...<Widget>[
              // 轮与轮之间空 4（导轨竖线跨过它不断——它画在这整块的背后）。
              if (i > 0 && _rows[i].isUser) const SizedBox(height: t.Timeline.turnGap),
              _row(i),
            ],
          ],
        ),
      ],
    );
  }

  Widget _row(int index) {
    final row = _rows[index];
    final selected = index == _selected;
    return RevealWhenSelected(
      selected: selected,
      child: SizedBox(
        height: t.Controls.standard,
        child: Row(
          children: <Widget>[
            SizedBox(width: t.Timeline.railColumn, child: Center(child: _node(solid: row.isUser))),
            // 悬浮 / 高亮容器只盖标签列与文字列，导轨列不在容器里（画板 43 C 组）。
            Expanded(
              child: Hoverable(
                onTap: widget.onJump == null ? null : () => widget.onJump!(row),
                forceHover: index == widget.forceHoverIndex,
                builder: (context, hovered) => Container(
                  padding: t.Controls.padCompact,
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: selected ? t.Overlays.selected : (hovered ? t.Overlays.hover : null),
                    borderRadius: t.Radii.control,
                  ),
                  child: Row(
                    children: <Widget>[
                      SizedBox(
                        width: t.Timeline.label,
                        child: Text(
                          row.label,
                          style: row.isUser ? t.TextStyles.monoMeta.copyWith(color: t.Neutral.muted) : t.TextStyles.monoMeta,
                        ),
                      ),
                      const SizedBox(width: t.Spacing.s8),
                      Expanded(
                        child: Text(
                          row.text,
                          style: row.isUser ? CardText.cardTitle : CardText.secondary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 节点：用户行实心，`A` 行空心（描边宽同导轨，填的是弹层底色，压在导轨线上才看得出是个圈）。
  Widget _node({required bool solid}) => Container(
        width: t.Timeline.node,
        height: t.Timeline.node,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: solid ? t.Timeline.nodeColor : t.Surface.popover,
          border: solid ? null : Border.all(color: t.Timeline.nodeColor, width: t.Timeline.railWidth),
        ),
      );
}

/// 空态：有会话、还没有任何一轮（画板 43 E 组）。无导轨、无节点，弹层按内容收窄。
class _TimelineEmpty extends StatelessWidget {
  const _TimelineEmpty();

  @override
  Widget build(BuildContext context) => Container(
        height: t.Controls.standard,
        padding: t.Controls.padCompact,
        alignment: Alignment.centerLeft,
        child: Text('No messages in this session yet', style: CardText.secondary.copyWith(color: t.Neutral.placeholder)),
      );
}
