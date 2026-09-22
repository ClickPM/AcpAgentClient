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
import 'package:acp_agent_client/ui/transcript/transcript_list.dart';
import 'package:acp_agent_client/ui/transcript/turn_fold_row.dart';
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

/// 只看渲染、不点的那几张：给一个一次性的折叠态控制器，点击回调照常接上。
Widget _list(SessionStore store) {
  final folds = TranscriptFolds();
  return TranscriptList(store, folds: folds, onToggleFold: folds.toggle);
}

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

    testWidgets('有失败项时首行末尾追加「N 项失败」，且不自动折叠', (tester) async {
      final s = newStore();
      startTurn(s, '跑一下');
      toolCall(s, 'tc-1');
      toolCall(s, 'tc-2', status: 'failed');
      agent(s, '出错了。');
      s.endTurn(stopReason: 'end_turn');

      await pump(tester, _list(s));
      expect(find.text('1 项失败'), findsOneWidget);
      expect(find.byType(ToolCallCard), findsNWidgets(2), reason: '含失败的回合保持展开');
    });

    testWidgets('可及性：button + expanded，整行可点', (tester) async {
      final folds = TranscriptFolds();
      await pump(tester, TranscriptList(sample(), folds: folds, onToggleFold: folds.toggle));
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
