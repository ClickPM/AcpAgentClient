// 画板 08 B · 回合折叠的呈现与交互：摘要行两态 / 单行退化 / 失败数 / 可及性、
// 折叠态把折叠块整批拿掉、`stop_reason` 到达才出摘要行、展开态在会话生命周期内记住、
// 以及折叠 / 展开后回合页脚在视口里的位置不变（画板「滚动锚点」）。

import 'package:acp_agent_client/app/transcript_fold_anchor.dart';
import 'package:acp_agent_client/app/transcript_folds.dart';
import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/projection/session_store.dart';
import 'package:acp_agent_client/projection/turn_fold.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/ui/transcript/assistant_text.dart';
import 'package:acp_agent_client/ui/transcript/thinking_block.dart';
import 'package:acp_agent_client/ui/transcript/tool_call_card.dart';
import 'package:acp_agent_client/ui/transcript/turn_state.dart';
import 'package:acp_agent_client/ui/transcript/user_message.dart';
import 'package:acp_agent_client/ui/transcript/transcript_list.dart';
import 'package:acp_agent_client/ui/transcript/turn_fold_row.dart';
import 'package:flutter/gestures.dart' show Drag, DragStartDetails, DragUpdateDetails;
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../gallery_harness.dart';

SessionStore newStore() {
  var t = DateTime.utc(2026, 9, 22, 12);
  return SessionStore(
    sessionId: 'sess_fold_ui',
    clock: () {
      t = t.add(const Duration(milliseconds: 100));
      return t;
    },
  );
}

void agent(SessionStore s, String text) => s.applyUpdateJson(<String, dynamic>{
      'sessionUpdate': 'agent_message_chunk',
      'content': <String, dynamic>{'type': 'text', 'text': text},
    });

void thought(SessionStore s, String text) => s.applyUpdateJson(<String, dynamic>{
      'sessionUpdate': 'agent_thought_chunk',
      'content': <String, dynamic>{'type': 'text', 'text': text},
    });

void toolCall(SessionStore s, String id, {String status = 'completed'}) => s.applyUpdateJson(<String, dynamic>{
      'sessionUpdate': 'tool_call',
      'toolCallId': id,
      'title': 'Read file',
      'status': status,
    });

TurnEntry startTurn(SessionStore s, String prompt) =>
    s.startTurn(<ContentBlockWire>[ContentBlockWire(<String, dynamic>{'type': 'text', 'text': prompt})]);

/// 一轮：思考 1 + 工具调用 2 + 最终文本 1。
SessionStore sample({String? model, String stop = 'end_turn', bool end = true}) {
  final s = newStore();
  if (model != null) {
    s.applyUpdateJson(<String, dynamic>{
      'sessionUpdate': 'config_option_update',
      'configOptions': <Object>[
        <String, dynamic>{
          'id': 'model',
          'category': 'model',
          'type': 'select',
          'currentValue': 'm',
          'options': <Object>[
            <String, dynamic>{'value': 'm', 'name': model},
          ],
        },
      ],
    });
  }
  startTurn(s, '开始做第二阶段');
  thought(s, '先复核最新提交');
  toolCall(s, 'tc-1');
  toolCall(s, 'tc-2');
  agent(s, '第二阶段已全部开发完毕。');
  if (end) s.endTurn(stopReason: stop);
  return s;
}

/// 不接滚动校正的那几张：**故意不传 `onToggleFold`**，顺带守住「有 folds 就点得动」这条退路
/// （复审 P2，2026-09-22：gallery 的画板 08 样张就是这么用的）。
Widget _list(SessionStore store) => TranscriptList(store, folds: TranscriptFolds());

void main() {
  Future<void> pump(WidgetTester tester, Widget child, {Size size = const Size(900, 1400)}) async {
    await tester.runAsync(() async {
      await loadGalleryFonts();
      await precacheIcons();
    });
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(size: size),
          // `TranscriptList` 里的 SelectableRegion 要一个 Overlay 祖先。
          child: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (_) => Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(width: size.width, height: size.height, child: child),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('摘要行', () {
    testWidgets('两行态：第二行是回合开始时的模型名', (tester) async {
      final s = sample(model: 'Gemini 3.8 Flash High (CLIProxy)');
      await pump(tester, _list(s));
      expect(find.text('处理详情'), findsOneWidget);
      expect(find.text('3 条消息 · 2 次工具调用'), findsOneWidget);
      expect(find.text('Gemini 3.8 Flash High (CLIProxy)'), findsOneWidget);
    });

    testWidgets('没有模型信息就退化成单行，不留空的第二行', (tester) async {
      await pump(tester, _list(sample()));
      expect(find.text('处理详情'), findsOneWidget);
      expect(find.text('3 条消息 · 2 次工具调用'), findsOneWidget);
      // 单行态里除了首行没有别的文本节点挂在摘要行下。
      final row = find.byType(TurnFoldRow);
      expect(find.descendant(of: row, matching: find.byType(Text)), findsNWidgets(2), reason: '「处理详情」+ 计数');
    });

    testWidgets('有失败项时首行末尾追加「N 项失败」，回合正常收轮则照常折叠', (tester) async {
      final s = newStore();
      startTurn(s, '跑一下');
      toolCall(s, 'tc-1');
      toolCall(s, 'tc-2', status: 'failed');
      agent(s, '出错了。');
      s.endTurn(stopReason: 'end_turn');

      await pump(tester, _list(s));
      expect(find.text('1 项失败'), findsOneWidget, reason: '折起来了也要看得见失败数（所有者裁定 2026-09-22）');
      expect(find.byType(ToolCallCard), findsNothing, reason: '跑到了结论，过程收进摘要行');
      expect(find.text('出错了。'), findsOneWidget, reason: '最终助手文本不参与折叠');
    });

    testWidgets('被取消的回合保持展开（摘要行在，但过程不收起）', (tester) async {
      final s = newStore();
      startTurn(s, '跑一下');
      toolCall(s, 'tc-1');
      s.endTurn(stopReason: 'cancelled');

      await pump(tester, _list(s));
      expect(find.byType(TurnFoldRow), findsOneWidget);
      expect(find.byType(ToolCallCard), findsOneWidget, reason: '没走到结束值，过程就是现场');
    });

    testWidgets('可及性：button + expanded，整行可点', (tester) async {
      await pump(tester, _list(sample()));
      final handle = tester.ensureSemantics();

      expect(
        tester.getSemantics(find.byType(TurnFoldRow)),
        matchesSemantics(isButton: true, hasExpandedState: true, isExpanded: false, hasTapAction: true, label: '处理详情，3 条消息 · 2 次工具调用'),
      );

      // 点首行文字（不是 chevron）也能展开。
      await tester.tap(find.text('处理详情'));
      await tester.pumpAndSettle();
      expect(find.byType(ThinkingBlock), findsOneWidget);
      handle.dispose();
    });
  });

  group('折叠时机', () {
    testWidgets('运行中不出摘要行、过程全可见；stop_reason 到达后收起', (tester) async {
      final s = sample(end: false);
      final folds = TranscriptFolds();
      await pump(tester, TranscriptList(s, folds: folds, onToggleFold: folds.toggle));
      expect(find.byType(TurnFoldRow), findsNothing);
      expect(find.byType(ToolCallCard), findsNWidgets(2));

      s.endTurn(stopReason: 'end_turn');
      await tester.pumpAndSettle();
      expect(find.byType(TurnFoldRow), findsOneWidget);
      expect(find.byType(ToolCallCard), findsNothing);
      expect(find.byType(ThinkingBlock), findsNothing);
      expect(find.text('第二阶段已全部开发完毕。'), findsOneWidget, reason: '最终助手文本不参与折叠');
    });

    testWidgets('全局开关关掉后回合结束不自动折叠，摘要行仍在（可手动折）', (tester) async {
      final folds = TranscriptFolds();
      await folds.setAutoCollapse(false);
      await pump(tester, TranscriptList(sample(), folds: folds, onToggleFold: folds.toggle));
      expect(find.byType(TurnFoldRow), findsOneWidget);
      expect(find.byType(ToolCallCard), findsNWidgets(2));

      await tester.tap(find.byType(TurnFoldRow));
      await tester.pumpAndSettle();
      expect(find.byType(ToolCallCard), findsNothing);
    });

    testWidgets('session/load 重放回来的历史照样折：摘要行在、过程收起、退化成单行、没有回合页脚', (tester) async {
      final s = newStore();
      s.resetForReplay();
      s.applyUpdateJson(<String, dynamic>{
        'sessionUpdate': 'user_message_chunk',
        'content': <String, dynamic>{'type': 'text', 'text': '历史一问'},
      });
      thought(s, '历史里的思考');
      toolCall(s, 'tc-old');
      agent(s, '历史一答');

      final folds = TranscriptFolds();
      await pump(tester, TranscriptList(s, folds: folds, onToggleFold: folds.toggle));
      expect(find.byType(TurnFoldRow), findsOneWidget);
      expect(find.byType(ToolCallCard), findsNothing);
      expect(find.byType(ThinkingBlock), findsNothing);
      expect(find.text('2 条消息 · 1 次工具调用'), findsOneWidget);
      expect(find.text('历史一答'), findsOneWidget, reason: '最终 agent 文本不参与折叠');
      expect(find.byType(TurnEndLine), findsNothing, reason: '重放没有轮边界，也就没有回合页脚');

      // 点一下照样展得开。
      await tester.tap(find.byType(TurnFoldRow));
      await tester.pumpAndSettle();
      expect(find.byType(ToolCallCard), findsOneWidget);
    });

    testWidgets('手动展开之后，后续通知不会把它重新折回去', (tester) async {
      final s = sample();
      final folds = TranscriptFolds();
      await pump(tester, TranscriptList(s, folds: folds, onToggleFold: folds.toggle));
      await tester.tap(find.byType(TurnFoldRow));
      await tester.pumpAndSettle();
      expect(find.byType(ToolCallCard), findsNWidgets(2));

      // 同一条会话后面又来了一轮：上一轮的展开态要保持。
      startTurn(s, '再来一轮');
      toolCall(s, 'tc-3');
      agent(s, '好了。');
      s.endTurn(stopReason: 'end_turn');
      await tester.pumpAndSettle();
      expect(find.byType(ToolCallCard), findsNWidgets(2), reason: '第一轮仍展开（2 张），第二轮折起来');
    });
  });

  group('滚动锚点', () {
    /// 折叠块前面压足内容，让列表真的要滚动（否则 maxScrollExtent = 0，怎么折都不会动）。
    SessionStore tall() {
      final s = newStore();
      startTurn(s, '第一轮：占位');
      agent(s, List<String>.filled(40, '很长的一段结论文本。').join());
      s.endTurn(stopReason: 'end_turn');
      startTurn(s, '第二轮');
      thought(s, '先复核最新提交');
      for (var i = 0; i < 6; i++) {
        toolCall(s, 'tc-$i');
      }
      agent(s, '这就是结论。');
      s.endTurn(stopReason: 'end_turn');
      return s;
    }

    testWidgets('折叠 / 展开后该回合的结论文本在视口里的位置不变', (tester) async {
      final s = tall();
      final folds = TranscriptFolds();
      await folds.setAutoCollapse(false); // 先全展开，再手动折，能量到「折叠那一下」
      final ScrollController controller = ScrollController();
      final anchor = TranscriptFoldAnchor(controller: controller, entries: () => s.entries, folds: folds);
      await pump(
        tester,
        TranscriptList(s, folds: folds, controller: controller, trackRows: true, onToggleFold: anchor.toggle),
        size: const Size(800, 400),
      );
      // 滚到底（惰性列表的 maxScrollExtent 是估的，推一次可能还差一截，连推几次到真正的底）。
      for (var i = 0; i < 5; i++) {
        controller.jumpTo(controller.position.maxScrollExtent);
        await tester.pumpAndSettle();
      }

      // 按 widget 找而不是 find.text：助手正文走 Markdown 渲染，落地是 RichText，`find.text` 默认不认它。
      final Finder conclusion = find.byWidgetPredicate((w) => w is AssistantText && w.entry.text == '这就是结论。');
      final double before = tester.getTopLeft(conclusion).dy;
      expect(controller.position.maxScrollExtent, greaterThan(0), reason: '这个用例必须真的能滚');

      await tester.tap(find.byType(TurnFoldRow));
      await tester.pumpAndSettle();
      expect(find.byType(ToolCallCard), findsNothing, reason: '确实折起来了');
      expect(tester.getTopLeft(conclusion).dy, closeTo(before, 0.5));

      // 再展开回去，同样不动。
      await tester.tap(find.byType(TurnFoldRow));
      await tester.pumpAndSettle();
      expect(find.byType(ToolCallCard), findsNWidgets(6), reason: '又展开了');
      expect(tester.getTopLeft(conclusion).dy, closeTo(before, 0.5));
    });

    testWidgets('自动折叠（stop_reason 到达）同样校正：人翻在结论上，视口不跳', (tester) async {
      // 复审 high（2026-09-22）：自动折叠不经过任何点击回调，第 1 轮实现整条没校正。
      // 人没贴在列表底部（翻上去重读刚流出来的结论）时，折叠块整段消失，视口当场往前跳一整段折叠高度。
      final s = newStore();
      startTurn(s, '第一轮：占位');
      agent(s, List<String>.filled(40, '很长的一段结论文本。').join());
      s.endTurn(stopReason: 'end_turn');
      startTurn(s, '第二轮');
      thought(s, '先复核最新提交');
      for (var i = 0; i < 6; i++) {
        toolCall(s, 'tc-$i');
      }
      // 结论要够长，人才能停在它中间（不贴底，否则被 maxScrollExtent 夹住就看不出跳没跳）。
      agent(s, '这就是结论。${List<String>.filled(200, '后面还有很长一段。').join()}');

      final folds = TranscriptFolds();
      final ScrollController controller = ScrollController();
      final anchor = TranscriptFoldAnchor(controller: controller, entries: () => s.entries, folds: folds);
      await pump(
        tester,
        TranscriptList(s, folds: folds, controller: controller, trackRows: true, onToggleFold: anchor.toggle),
        size: const Size(800, 400),
      );
      for (var i = 0; i < 5; i++) {
        controller.jumpTo(controller.position.maxScrollExtent);
        await tester.pumpAndSettle();
      }
      // 往回翻半屏：人正看着结论中间，不在底部。
      controller.jumpTo(controller.position.pixels - 200);
      await tester.pumpAndSettle();
      final Finder conclusion = find.byWidgetPredicate((w) => w is AssistantText && w.entry.text.startsWith('这就是结论。'));
      final double before = tester.getTopLeft(conclusion).dy;
      expect(controller.position.pixels, lessThan(controller.position.maxScrollExtent - 100), reason: '人不在底部，否则夹一下就看不出跳没跳');

      // 组合根的接线：store 通知里先量旧布局（`workbench_screen._onTranscriptGrew`）。
      s.addListener(anchor.beforeRebuild);
      s.endTurn(stopReason: 'end_turn');
      await tester.pumpAndSettle();

      expect(folds.isCollapsed(foldsOf(s.entries).values.last), isTrue, reason: 'stop_reason 到达即自动折叠');
      expect(tester.getTopLeft(conclusion).dy, closeTo(before, 0.5), reason: '结论停在原地，不跳');
    });

    testWidgets('人正在拖 / 惯性还没停时不校正：不跟用户抢滚动', (tester) async {
      // 复审 P2（2026-09-22）：`jumpTo` 会 goIdle 把正在进行的滚动掐断。
      // 与 `workbench_screen._followToBottom`、`TranscriptJump._step` 同一条规矩。
      // 折叠的那一轮后面还要有内容，否则折完 `pixels` 会被新的 maxScrollExtent 夹一下，
      // 看不出「校正有没有额外再推一次」。
      final s = tall();
      startTurn(s, '第三轮');
      agent(s, List<String>.filled(120, '后面还有很长一段。').join());
      s.endTurn(stopReason: 'end_turn');

      final folds = TranscriptFolds();
      final ScrollController controller = ScrollController();
      final anchor = TranscriptFoldAnchor(controller: controller, entries: () => s.entries, folds: folds);
      await folds.setAutoCollapse(false);
      await pump(
        tester,
        TranscriptList(s, folds: folds, controller: controller, trackRows: true, onToggleFold: anchor.toggle),
        size: const Size(800, 400),
      );
      // 滚到第二轮的结论那一带（不在两端，夹不到）。
      controller.jumpTo(300);
      await tester.pumpAndSettle();

      // 手指按住并拖起来：userScrollDirection 离开 idle。
      // 直接驱动 `ScrollPosition.drag`，不走手势 —— 转录整块包在 `SelectableRegion` 里，
      // 模拟拖拽会被它当成选字。
      final Drag drag = controller.position.drag(DragStartDetails(globalPosition: tester.getCenter(find.byType(TranscriptList))), () {});
      drag.update(DragUpdateDetails(globalPosition: Offset.zero, delta: const Offset(0, 40), primaryDelta: 40));
      await tester.pump();
      expect(controller.position.userScrollDirection, isNot(ScrollDirection.idle), reason: '用例前提：这会儿确实在滚');
      final double dragged = controller.position.pixels;

      // 拖着的时候把这一轮折起来：校正要让路，不许 jumpTo。
      anchor.toggle(foldsOf(s.entries).values.first);
      await tester.pump();
      await tester.pump();
      expect(controller.position.pixels, closeTo(dragged, 0.5), reason: '人在滚，别跟他抢');

      drag.cancel();
      await tester.pumpAndSettle();
    });

    testWidgets('历史轮收在工具调用上、没有页脚可兜底时，锚落到下一轮的用户气泡（审查 P2，2026-09-22）', (tester) async {
      // 重放回来的历史轮没有 `TurnEntry`，也就没有回合页脚。这一轮又**没有最终助手文本**
      // （收在工具调用上），于是「本轮折叠块之后剩下的条目」一条都没有——整改前 `_candidates`
      // 一个候选都给不出来，`_arm` 落空、这一下不再校正，人正看着的下一轮会被整段高度推走。
      final s = newStore();
      s.resetForReplay();
      void historyUser(String text) => s.applyUpdateJson(<String, dynamic>{
            'sessionUpdate': 'user_message_chunk',
            'content': <String, dynamic>{'type': 'text', 'text': text},
          });

      historyUser('历史一问：占位');
      agent(s, List<String>.filled(40, '很长的一段历史回答。').join());
      historyUser('历史二问');
      thought(s, '历史里的思考');
      for (var i = 0; i < 3; i++) {
        toolCall(s, 'tc-$i');
      }
      // 这一轮到此为止：没有最终助手文本，下一条就是下一轮的用户气泡。
      historyUser('历史三问：人正看着这一条');
      agent(s, '历史三答。${List<String>.filled(200, '后面还有很长一段。').join()}');

      final folds = TranscriptFolds();
      await folds.setAutoCollapse(false); // 先全展开，再手动折，能量到「折叠那一下」
      final ScrollController controller = ScrollController();
      final anchor = TranscriptFoldAnchor(controller: controller, entries: () => s.entries, folds: folds);
      await pump(
        tester,
        TranscriptList(s, folds: folds, controller: controller, trackRows: true, onToggleFold: anchor.toggle),
        size: const Size(800, 400),
      );
      for (var i = 0; i < 5; i++) {
        controller.jumpTo(controller.position.maxScrollExtent);
        await tester.pumpAndSettle();
      }
      expect(controller.position.maxScrollExtent, greaterThan(0), reason: '这个用例必须真的能滚');

      // 人停在最后那一轮的用户气泡上（它在要折的那一轮之后，折叠会把它整段推走）。
      final Finder watching = find.byWidgetPredicate(
        (w) => w is UserMessage && w.entry.text.startsWith('历史三问'),
      );
      // 惰性列表：从底往回翻，直到那颗气泡真的建出来，且离底足够远（贴底会被 maxScrollExtent
      // 夹一下，看不出跳没跳）。
      for (var i = 0; i < 20; i++) {
        final ScrollPosition p = controller.position;
        if (watching.evaluate().isNotEmpty && p.pixels < p.maxScrollExtent - 320) break;
        controller.jumpTo(p.pixels - 100);
        await tester.pumpAndSettle();
      }
      expect(watching, findsOneWidget, reason: '用例前提：那颗气泡此刻在已建窗口里');
      expect(
        controller.position.pixels,
        lessThan(controller.position.maxScrollExtent - 320),
        reason: '人不在底部，否则夹一下就看不出跳没跳',
      );
      final double before = tester.getTopLeft(watching).dy;

      // 折的是上面那一轮（人看着的这一屏里它已经出了已建窗口，所以走全局开关这条路径——
      // 点摘要行那条路径这时候根本点不到它）。
      await folds.setAutoCollapse(true);
      await tester.pumpAndSettle();
      expect(find.byType(ToolCallCard), findsNothing, reason: '确实折起来了');
      // 没有锚可用时气泡被整段推出视口、跟着被回收，位置都量不到了——先把这一步报清楚。
      expect(watching, findsOneWidget, reason: '气泡还在已建窗口里（没锚可用时它会被推走）');
      expect(tester.getTopLeft(watching).dy, closeTo(before, 0.5), reason: '气泡停在原地，不被整段推走');
      anchor.dispose();
    });

    testWidgets('历史轮的下一轮第一行已滚出缓存时，锚继续往后找到视口里的正文（复审 P2，2026-09-22）', (tester) async {
      // 同上一条的场景，但人停得更靠后：下一轮的用户气泡已经滚出 ListView 缓存、量不到了，
      // 人正看着的是气泡后面那段很长的正文。候选要是只给「下一轮第一行」那一条就用完了，
      // `_arm` 照样落空，正文被整段折叠高度顶上去。
      final s = newStore();
      s.resetForReplay();
      void historyUser(String text) => s.applyUpdateJson(<String, dynamic>{
            'sessionUpdate': 'user_message_chunk',
            'content': <String, dynamic>{'type': 'text', 'text': text},
          });

      historyUser('历史一问：占位');
      agent(s, List<String>.filled(40, '很长的一段历史回答。').join());
      historyUser('历史二问');
      thought(s, '历史里的思考');
      for (var i = 0; i < 6; i++) {
        toolCall(s, 'tc-$i');
      }
      // 这一轮收在工具调用上：折叠块之后本轮一条都不剩。
      historyUser('历史三问');
      // 正文要够长：人往回翻得比折叠块高之后，气泡仍要落在 ListView 缓存（默认约 250px）之外。
      agent(s, '历史三答。${List<String>.filled(400, '后面还有很长一段。').join()}');

      final folds = TranscriptFolds();
      await folds.setAutoCollapse(false);
      final ScrollController controller = ScrollController();
      final anchor = TranscriptFoldAnchor(controller: controller, entries: () => s.entries, folds: folds);
      await pump(
        tester,
        TranscriptList(s, folds: folds, controller: controller, trackRows: true, onToggleFold: anchor.toggle),
        size: const Size(800, 400),
      );
      for (var i = 0; i < 5; i++) {
        controller.jumpTo(controller.position.maxScrollExtent);
        await tester.pumpAndSettle();
      }
      // 往回翻得比折叠块高，但远不到那颗气泡：人看的是正文尾段。
      controller.jumpTo(controller.position.pixels - 350);
      await tester.pumpAndSettle();

      final Finder bubble = find.byWidgetPredicate(
        (w) => w is UserMessage && w.entry.text.startsWith('历史三问'),
      );
      final Finder body = find.byWidgetPredicate(
        (w) => w is AssistantText && w.entry.text.startsWith('历史三答。'),
      );
      expect(bubble, findsNothing, reason: '用例前提：下一轮第一行已经滚出缓存、量不到');
      expect(body, findsOneWidget, reason: '用例前提：人正看着的正文在视口里');
      expect(find.byType(TurnEndLine), findsNothing, reason: '历史轮没有回合页脚');
      expect(
        controller.position.pixels,
        lessThan(controller.position.maxScrollExtent - 300),
        reason: '人离底得比折叠块还远，否则夹一下就看不出跳没跳',
      );
      final double before = tester.getTopLeft(body).dy;

      await folds.setAutoCollapse(true);
      await tester.pumpAndSettle();
      expect(find.byType(ToolCallCard), findsNothing, reason: '确实折起来了');
      expect(tester.getTopLeft(body).dy, closeTo(before, 0.5), reason: '正文停在原地');
      anchor.dispose();
    });

    testWidgets('实时轮里折叠块之后多出一条对不上的用户消息，结论仍在锚点候选里（复审 P2，2026-09-22）', (tester) async {
      // agent 发来一条与本地回显对不上的 `user_message_chunk` 时，投影层会在折叠块之后另起一条
      // 顶层用户消息——那**不是**新一轮（实时轮按 `TurnEntry` 切）。锚点的跨轮判据要是也把它当
      // 轮边界，本轮结论就被掐出候选，只剩页脚；人停在长结论中间、页脚还没建出来时就没锚可用。
      final s = newStore();
      startTurn(s, '第一轮：占位');
      agent(s, List<String>.filled(40, '很长的一段结论文本。').join());
      s.endTurn(stopReason: 'end_turn');

      startTurn(s, '第二轮');
      thought(s, '先复核最新提交');
      for (var i = 0; i < 6; i++) {
        toolCall(s, 'tc-$i');
      }
      // 对不上的那一条：内容与本地回显不同，投影层在末尾新建一条顶层用户消息。
      s.applyUpdateJson(<String, dynamic>{
        'sessionUpdate': 'user_message_chunk',
        'content': <String, dynamic>{'type': 'text', 'text': '对不上的一条'},
      });
      agent(s, '这就是结论。${List<String>.filled(200, '后面还有很长一段。').join()}');
      s.endTurn(stopReason: 'end_turn');
      expect(
        s.entries.whereType<MessageEntry>().where((m) => m.role == MessageRole.user),
        hasLength(3),
        reason: '用例前提：两轮的回显 + 那条对不上的，都在顶层',
      );

      final folds = TranscriptFolds();
      await folds.setAutoCollapse(false); // 先全展开，再折，能量到「折叠那一下」
      final ScrollController controller = ScrollController();
      final anchor = TranscriptFoldAnchor(controller: controller, entries: () => s.entries, folds: folds);
      await pump(
        tester,
        TranscriptList(s, folds: folds, controller: controller, trackRows: true, onToggleFold: anchor.toggle),
        size: const Size(800, 400),
      );
      for (var i = 0; i < 5; i++) {
        controller.jumpTo(controller.position.maxScrollExtent);
        await tester.pumpAndSettle();
      }
      // 往回翻：人正看着结论中间，页脚在视口之外、没建出来。翻的量要大于折叠块自己的高度，
      // 否则折叠后 pixels 被 maxScrollExtent 夹到底，视口跟着内容一起缩，位移就抵消掉了、看不出跳没跳。
      controller.jumpTo(controller.position.pixels - 350);
      await tester.pumpAndSettle();
      final Finder conclusion = find.byWidgetPredicate(
        (w) => w is AssistantText && w.entry.text.startsWith('这就是结论。'),
      );
      final double before = tester.getTopLeft(conclusion).dy;
      expect(
        controller.position.pixels,
        lessThan(controller.position.maxScrollExtent - 300),
        reason: '人离底得比折叠块还远，否则夹一下就看不出跳没跳',
      );
      expect(find.byType(TurnEndLine), findsNothing, reason: '用例前提：页脚没建出来，否则它自己就能当锚');

      await folds.setAutoCollapse(true);
      await tester.pumpAndSettle();
      expect(find.byType(ToolCallCard), findsNothing, reason: '确实折起来了');
      expect(tester.getTopLeft(conclusion).dy, closeTo(before, 0.5), reason: '结论停在原地');
      anchor.dispose();
    });

    testWidgets('画板 70 的全局开关翻面：长转录里所有回合同时折 / 展，视口里的结论也不跳', (tester) async {
      // 复审 P2（2026-09-22）：设置页与转录同屏，这个开关既不走点击回调也不通知 store，第 1 轮实现这条路没校正，
      // 人正读着长转录时拨一下开关，视口当场跳走所有折叠块高度之和。两半整改：锚点自己订阅 `TranscriptFolds`；
      // 列表按键复用行（`findChildIndexCallback`）——已建窗口之外那几轮的折 / 展不再把眼前的行换成别的条目。
      final s = newStore();
      startTurn(s, '第一轮：占位');
      agent(s, List<String>.filled(40, '很长的一段结论文本。').join());
      s.endTurn(stopReason: 'end_turn');
      // 中间四轮各一大段过程：它们在已建窗口之外，按序号复用的话一翻面就把窗口里的行全换掉。
      for (var n = 2; n <= 5; n++) {
        startTurn(s, '第 $n 轮');
        thought(s, '想一下');
        for (var i = 0; i < 6; i++) {
          toolCall(s, 'tc$n-$i');
        }
        agent(s, '第 $n 轮的结论。');
        s.endTurn(stopReason: 'end_turn');
      }
      startTurn(s, '第六轮：长文本把前面几轮推出已建窗口');
      agent(s, List<String>.filled(60, '很长的一段结论文本。').join());
      s.endTurn(stopReason: 'end_turn');
      startTurn(s, '第七轮');
      toolCall(s, 'tc7-0');
      toolCall(s, 'tc7-1');
      agent(s, '第七轮的结论。');
      s.endTurn(stopReason: 'end_turn');

      final folds = TranscriptFolds(); // 默认开：有过程的五轮此刻都折着
      final ScrollController controller = ScrollController();
      final anchor = TranscriptFoldAnchor(controller: controller, entries: () => s.entries, folds: folds);
      await pump(
        tester,
        TranscriptList(s, folds: folds, controller: controller, trackRows: true, onToggleFold: anchor.toggle),
        size: const Size(800, 400),
      );
      for (var i = 0; i < 8; i++) {
        controller.jumpTo(controller.position.maxScrollExtent);
        await tester.pumpAndSettle();
      }
      expect(find.byType(ToolCallCard), findsNothing, reason: '都自动折着');
      final Finder conclusion = find.byWidgetPredicate((w) => w is AssistantText && w.entry.text == '第七轮的结论。');
      final double before = tester.getTopLeft(conclusion).dy;

      // 关掉全局开关：五轮同时展开，上面多出几十行。
      await folds.setAutoCollapse(false);
      await tester.pumpAndSettle();
      expect(find.byType(ToolCallCard), findsWidgets, reason: '确实展开了');
      expect(tester.getTopLeft(conclusion).dy, closeTo(before, 0.5), reason: '结论停在原地');

      // 再打开：同时折回去，同样不动。
      await folds.setAutoCollapse(true);
      await tester.pumpAndSettle();
      expect(find.byType(ToolCallCard), findsNothing, reason: '又折回去了');
      expect(tester.getTopLeft(conclusion).dy, closeTo(before, 0.5));
      anchor.dispose();
    });
  });

  group('时间线跳转', () {
    test('目标在折叠块里时 expand 返回真并展开那一轮；已经展开时返回假', () {
      final s = sample();
      final folds = TranscriptFolds();
      final TurnFold fold = foldsOf(s.entries).values.single;
      final TranscriptEntry target = fold.folded.first;

      expect(foldContaining(<TurnFold>[fold], target), same(fold));
      expect(folds.isCollapsed(fold), isTrue);
      expect(folds.expand(fold), isTrue);
      expect(folds.isCollapsed(fold), isFalse);
      expect(folds.expand(fold), isFalse, reason: '已经展开就不再通知一次');
    });
  });
}
