// 大 diff 卡（BACKLOG「流式渲染性能」）的回归：
// ① `lineDiff` 线性实现与原先「逐条模拟派发」的实现逐行一致（随机输入对照，下面 [_referenceLineDiff] 是原实现原样）；
// ② 展开体按固定行高只建视口附近的行：滚动、以及卡被上面的条目挪了位置（没有滚动事件、只有父级重建）之后，
//    看得见的行都要建出来；
// ③ 父级每帧重建时 diff 不重算、行不重建（行 widget 实例原样复用），而「定位」回调用的是最新那一个；
// ④ 悬浮提示浮在行上、不撑高行。

import 'dart:math' as math;

import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/transcript/diff_card.dart';
import 'package:diffutil_dart/diffutil.dart' as du;
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 原先的实现：按「活行」下标现扫 + `List.insert` 逐条模拟派发（平方级），拿来当对照。
List<DiffLine> _referenceLineDiff(String? oldText, String newText) {
  List<String> lines(String s) {
    final l = s.split('\n');
    if (l.isNotEmpty && l.last.isEmpty) l.removeLast();
    return l;
  }

  final oldLines = oldText == null ? const <String>[] : lines(oldText);
  final newLines = lines(newText);
  final result = du.calculateListDiff<String>(oldLines, newLines, detectMoves: false);
  final work = <DiffLine>[for (final l in oldLines) DiffLine(DiffKind.equal, l)];
  int indexOfLive(int position) {
    var live = 0;
    for (var i = 0; i < work.length; i++) {
      if (work[i].kind == DiffKind.delete) continue;
      if (live == position) return i;
      live++;
    }
    return work.length;
  }

  for (final u in result.getUpdatesWithData()) {
    switch (u) {
      case du.DataInsert<String>(:final position, :final data):
        work.insert(indexOfLive(position), DiffLine(DiffKind.insert, data));
      case du.DataRemove<String>(:final position, :final data):
        work[indexOfLive(position)] = DiffLine(DiffKind.delete, data);
      case du.DataChange<String>(:final position, :final oldData, :final newData):
        final i = indexOfLive(position);
        work[i] = DiffLine(DiffKind.delete, oldData);
        work.insert(i + 1, DiffLine(DiffKind.insert, newData));
      case du.DataMove<String>():
        break;
    }
  }
  var o = 1, n = 1;
  return <DiffLine>[
    for (final l in work)
      switch (l.kind) {
        DiffKind.equal => DiffLine(l.kind, l.text, oldNo: o++, newNo: n++),
        DiffKind.delete => DiffLine(l.kind, l.text, oldNo: o++),
        DiffKind.insert => DiffLine(l.kind, l.text, newNo: n++),
      },
  ];
}

String _dump(List<DiffLine> lines) => lines.map((l) => '${l.kind.name}|${l.oldNo}|${l.newNo}|${l.text}').join('\n');

ToolCallEntry _entry() => ToolCallEntry(id: 'tc-1', at: DateTime(2026, 9, 24), toolCallId: 'tc-1', title: 'Edit');

ToolCallContentWire _diff(String? oldText, String newText, {String path = 'D:/w/big.dart'}) =>
    ToolCallContentWire(<String, dynamic>{'type': 'diff', 'path': path, 'oldText': ?oldText, 'newText': newText});

String _numbered(int count) => <String>[for (var i = 0; i < count; i++) 'line $i'].join('\n');

/// 画板 21 的行高（与实现同一个口径：字号 × line-height，测试环境的 textScaler 是 1）。
double get _rowExtent => t.TextStyles.mono.fontSize! * t.LineHeights.diffRow;

Finder _rows() => find.byWidgetPredicate((w) => w.runtimeType.toString() == '_DiffRow');

/// 转录的形状：一个竖向 ListView，上面一条高度可变的条目，下面是 diff 卡；[above] 一变整个列表重建（同转录听 store）。
/// [diff] 与 [onLocate] 每次重建都现造（转录里 wire 对象与 `(p, l) => onGoToFile!(p, l)` 都是每次 build 新建的）。
Future<void> _pumpList(
  WidgetTester tester, {
  required ValueNotifier<double> above,
  required ScrollController controller,
  required ToolCallContentWire Function() diff,
  void Function(String path, int line) Function()? onLocate,
}) {
  return tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(800, 600)),
        child: ListenableBuilder(
          listenable: above,
          builder: (_, _) => ListView(
            controller: controller,
            children: <Widget>[
              SizedBox(height: above.value),
              DiffCard(_entry(), diff: diff(), initiallyExpanded: true, onLocate: onLocate?.call()),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('lineDiff', () {
    test('与逐条模拟派发的原实现一致（随机输入）', () {
      final rng = math.Random(7);
      const alphabet = <String>['a', 'b', 'c', 'd', '', '  x', 'e'];
      String randomText(int n) => <String>[for (var i = 0; i < n; i++) alphabet[rng.nextInt(alphabet.length)]].join('\n');
      for (var round = 0; round < 2000; round++) {
        final oldLines = randomText(rng.nextInt(30)).split('\n');
        // 一半在旧文件上随机增删改（像真实的编辑），一半完全随机。
        final String newText;
        if (round.isEven) {
          final edited = List<String>.of(oldLines);
          for (var k = rng.nextInt(6); k > 0; k--) {
            final at = edited.isEmpty ? 0 : rng.nextInt(edited.length);
            switch (rng.nextInt(3)) {
              case 0:
                edited.insert(at, alphabet[rng.nextInt(alphabet.length)]);
              case 1:
                if (edited.isNotEmpty) edited.removeAt(at);
              default:
                if (edited.isNotEmpty) edited[at] = '${edited[at]}!';
            }
          }
          newText = edited.join('\n');
        } else {
          newText = randomText(rng.nextInt(30));
        }
        final oldText = round % 7 == 0 ? null : oldLines.join('\n');
        final suffix = rng.nextBool() ? '\n' : '';
        expect(_dump(lineDiff(oldText, '$newText$suffix')), _dump(_referenceLineDiff(oldText, '$newText$suffix')), reason: 'old=$oldText\nnew=$newText');
      }
    });

    test('新文件全是新增行；同一处先删后增', () {
      expect(_dump(lineDiff(null, 'a\nb\n')), 'insert|null|1|a\ninsert|null|2|b');
      expect(_dump(lineDiff('a\nb\nc', 'a\nx\ny\nc')), 'equal|1|1|a\ndelete|2|null|b\ninsert|null|2|x\ninsert|null|3|y\nequal|3|4|c');
    });

    test('三千行的文件改一大段：删 / 增各 1000 行', () {
      final big = <String>[for (var i = 0; i < 3000; i++) 'line $i'];
      final edited = List<String>.of(big);
      for (var i = 1000; i < 2000; i++) {
        edited[i] = 'changed $i';
      }
      final lines = lineDiff(big.join('\n'), edited.join('\n'));
      expect(lines.where((l) => l.kind == DiffKind.delete).length, 1000);
      expect(lines.where((l) => l.kind == DiffKind.insert).length, 1000);
    });
  });

  group('DiffCard 展开体', () {
    testWidgets('只建视口附近的行；滚到中间，中间的行建出来', (WidgetTester tester) async {
      final above = ValueNotifier<double>(0);
      final controller = ScrollController();
      addTearDown(above.dispose);
      addTearDown(controller.dispose);
      final diff = _diff(null, _numbered(2000));
      await _pumpList(tester, above: above, controller: controller, diff: () => diff);
      await tester.pump();

      expect(find.text('line 0'), findsOneWidget);
      expect(find.text('line 1999'), findsNothing);
      expect(_rows().evaluate().length, lessThan(200), reason: '两千行全建了 = 没有惰性');
      // 本体高度 = 行数 × 固定行高（没建的行也占着位置，滚动条与后面的条目位置才对）。
      expect(controller.position.maxScrollExtent, greaterThan(2000 * _rowExtent - 600));

      controller.jumpTo(1000 * _rowExtent);
      await tester.pump();
      expect(find.text('line 1010'), findsOneWidget);
      expect(find.text('line 0'), findsNothing);
    });

    testWidgets('卡被上面的条目挪了位置（没有滚动事件）之后，看得见的行补建出来', (WidgetTester tester) async {
      // 上面是一条很高的条目，只露出底部 200px；diff 卡从视口 200px 处开始，看得见的是开头几行。
      final above = ValueNotifier<double>(5000);
      final controller = ScrollController();
      addTearDown(above.dispose);
      addTearDown(controller.dispose);
      final diff = _diff(null, _numbered(2000));
      await _pumpList(tester, above: above, controller: controller, diff: () => diff);
      await tester.pump();
      controller.jumpTo(4800);
      await tester.pump();
      await tester.pump();
      expect(find.text('line 0'), findsOneWidget);

      // 那一条收起（高度归零）：卡整体上移 5000，滚动位置没动，视口里换成了两百多行之后的那些。
      above.value = 0;
      await tester.pump();
      await tester.pump();
      expect(controller.offset, 4800);
      expect(find.text('line 230'), findsOneWidget, reason: '父级重建后没补算窗口，这一屏是空的');
    });

    testWidgets('父级重建：diff 不重算、行不重建，定位回调用最新的那一个', (WidgetTester tester) async {
      final above = ValueNotifier<double>(0);
      final controller = ScrollController();
      addTearDown(above.dispose);
      addTearDown(controller.dispose);
      final calls = <String>[];
      var generation = 0;
      // 每次重建都新造一个 wire 对象与一个回调闭包（转录里就是这样）；闭包记下造它时的代数，调到旧闭包就能看出来。
      await _pumpList(
        tester,
        above: above,
        controller: controller,
        diff: () => _diff('a\nb\nc', 'a\nx\nc'),
        onLocate: () {
          final g = generation;
          return (p, l) => calls.add('$g:$p:$l');
        },
      );
      await tester.pump();
      final firstRow = tester.widget(_rows().first);

      generation = 1;
      above.value = 0.5; // 触发整列重建
      await tester.pump();
      await tester.pump();
      expect(identical(tester.widget(_rows().first), firstRow), isTrue, reason: '行 widget 换了新实例 = diff 重算或行缓存失效');

      await tester.tap(find.text('x'));
      expect(calls, <String>['1:D:/w/big.dart:2']);
    });

    testWidgets('新文本变了才重算：计数与行跟着变', (WidgetTester tester) async {
      final above = ValueNotifier<double>(0);
      final controller = ScrollController();
      addTearDown(above.dispose);
      addTearDown(controller.dispose);
      var newText = 'a\nb';
      await _pumpList(tester, above: above, controller: controller, diff: () => _diff('a', newText));
      await tester.pump();
      expect(find.text('+1'), findsOneWidget);
      expect(find.text('b'), findsOneWidget);

      newText = 'a\nb\nc\nd';
      above.value = 1;
      await tester.pump();
      await tester.pump();
      expect(find.text('+3'), findsOneWidget);
      expect(find.text('d'), findsOneWidget);
    });

    testWidgets('悬浮提示浮在行上，不撑高行', (WidgetTester tester) async {
      final above = ValueNotifier<double>(0);
      final controller = ScrollController();
      addTearDown(above.dispose);
      addTearDown(controller.dispose);
      await _pumpList(tester, above: above, controller: controller, diff: () => _diff('a\nb', 'a\nc'));
      await tester.pump();
      final before = tester.getSize(find.byType(DiffCard));
      final rowHeight = tester.getSize(_rows().first).height;
      expect(rowHeight, closeTo(_rowExtent, 0.01));

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer();
      await mouse.moveTo(tester.getCenter(find.text('c')));
      await tester.pump();
      expect(find.text('在文件面板中定位'), findsOneWidget);
      expect(tester.getSize(find.byType(DiffCard)), before);
    });

    testWidgets('外面没有竖向滚动时全建', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(800, 3000)),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 800, child: DiffCard(_entry(), diff: _diff(null, _numbered(100)), initiallyExpanded: true)),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(_rows(), findsNWidgets(100));
    });
  });
}
