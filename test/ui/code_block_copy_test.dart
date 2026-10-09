import 'dart:async';

import 'package:acp_agent_client/ui/transcript/card_chrome.dart';
import 'package:acp_agent_client/ui/transcript/code_block.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpCode(WidgetTester tester) => tester.pumpWidget(
  const Directionality(
    textDirection: TextDirection.ltr,
    child: CodeBlock(code: 'print("hello");', language: 'dart'),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );

  testWidgets('Copy 写入原文，Copied 停留 1.8 秒再恢复', (tester) async {
    String? copied;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    await pumpCode(tester);
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(copied, 'print("hello");');
    expect(find.text('Copied'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.text('Copied'), findsOneWidget, reason: '120ms 是过渡，不是反馈停留');
    await tester.pump(const Duration(milliseconds: 799));
    expect(find.text('Copied'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Copied'), findsNothing);
  });

  testWidgets('连续发起的复制完成后，从最后一次成功重新计时', (tester) async {
    final writes = <Completer<Object?>>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) {
      final gate = Completer<Object?>();
      writes.add(gate);
      return gate.future;
    });
    await pumpCode(tester);
    final copy = tester.widget<AcpButton>(find.byType(AcpButton)).onTap!;
    // 两次点击发生在 Clipboard 返回前；此时 Copy 按钮仍在。
    copy();
    copy();
    await tester.pump();
    expect(writes, hasLength(2));
    writes[0].complete(null);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    writes[1].complete(null);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Copied'), findsOneWidget, reason: '第一笔的旧计时器不能清掉第二笔反馈');
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.text('Copy'), findsOneWidget);
  });

  testWidgets('卸载代码块撤销反馈计时器', (tester) async {
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
    await pumpCode(tester);
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(find.text('Copied'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    // 不推进时钟；testWidgets 在结束时会断言没有残留 Timer。
    expect(tester.takeException(), isNull);
  });

  testWidgets('剪贴板返回前卸载，不再创建反馈计时器', (tester) async {
    final write = Completer<Object?>();
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) => write.future,
    );
    await pumpCode(tester);
    await tester.tap(find.text('Copy'));
    await tester.pumpWidget(const SizedBox.shrink());
    write.complete(null);
    await tester.pump();
    // 不推进时钟；剪贴板晚到不能留下反馈 Timer。
    expect(tester.takeException(), isNull);
  });
}
