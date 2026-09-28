// 画板 44 · SendQueueDock widget 单测（验收 4）：计数标题、折叠/展开、全部清空、每行三个动作与 Send Now 键位提示。

import 'package:acp_agent_client/app/send_queue.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/ui/shell/send_queue_dock.dart';
import 'package:acp_agent_client/ui/transcript/card_chrome.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(800, 600)),
        child: Align(alignment: Alignment.topCenter, child: child),
      ),
    );

void main() {
  testWidgets('空队列不渲染任何内容', (tester) async {
    final q = SendQueue();
    await tester.pumpWidget(_host(SendQueueDock(queue: q)));
    expect(find.byType(SizedBox), findsOneWidget);
    expect(find.textContaining('条排队消息'), findsNothing);
  });

  testWidgets('折叠态与展开态切换、每行三个动作与全部清空回调', (tester) async {
    final q = SendQueue();
    final e1 = q.enqueue(<JsonMap>[
      <String, dynamic>{'type': 'text', 'text': '第一条排队消息'},
      <String, dynamic>{'type': 'resource_link', 'uri': 'lib/app/send_queue.dart', 'name': 'send_queue.dart'},
    ]);
    final e2 = q.enqueue(<JsonMap>[
      <String, dynamic>{'type': 'text', 'text': '第二条排队消息'},
    ]);

    int? sentNowId;
    int? editedId;
    int? removedId;
    bool cleared = false;

    await tester.pumpWidget(_host(
      SendQueueDock(
        queue: q,
        onSendNow: (id) => sentNowId = id,
        onEdit: (id) => editedId = id,
        onRemove: (id) => removedId = id,
        onClearAll: () => cleared = true,
      ),
    ));
    await tester.pump();

    // 默认折叠态
    expect(find.text('2 条排队消息'), findsOneWidget);
    expect(find.text('展开'), findsOneWidget);
    expect(find.text('全部清空'), findsOneWidget);

    // 点展开
    await tester.tap(find.text('展开'));
    await tester.pump();

    expect(q.isExpanded, isTrue);
    expect(find.text('#1'), findsOneWidget);
    expect(find.text('#2'), findsOneWidget);
    expect(find.text('第一条排队消息'), findsOneWidget);
    expect(find.text('send_queue.dart'), findsOneWidget);
    expect(find.text('第二条排队消息'), findsOneWidget);
    expect(find.text('Send Now'), findsNWidgets(2));
    expect(find.text('⏎'), findsNWidgets(2));

    // 点第一行的 Send Now
    await tester.tap(find.text('Send Now').first);
    await tester.pump();
    expect(sentNowId, e1.id);

    // 点第一行的编辑图标与删除图标（每行 2 个 IconButtonGhost：pencil, trash）
    final iconBtns = find.byType(IconButtonGhost);
    expect(iconBtns, findsNWidgets(4));
    await tester.tap(iconBtns.at(0)); // 第 1 行编辑
    await tester.pump();
    expect(editedId, e1.id);

    await tester.tap(iconBtns.at(3)); // 第 2 行删除
    await tester.pump();
    expect(removedId, e2.id);

    // 点全部清空
    await tester.tap(find.text('全部清空'));
    await tester.pump();
    expect(cleared, isTrue);

    // 点收起
    await tester.tap(find.text('收起'));
    await tester.pump();
    expect(q.isExpanded, isFalse);
  });

  testWidgets('Paused 态与 AbsorbingCancel 态提示与恢复按钮', (tester) async {
    final q = SendQueue()
      ..enqueue(<JsonMap>[
        <String, dynamic>{'type': 'text', 'text': 'msg 1'},
      ])
      ..enqueue(<JsonMap>[
        <String, dynamic>{'type': 'text', 'text': 'msg 2'},
      ])
      ..pause();

    bool resumed = false;
    await tester.pumpWidget(_host(
      SendQueueDock(
        queue: q,
        onResume: () => resumed = true,
      ),
    ));
    await tester.pump();

    expect(find.text('队列已暂停 · 2 条排队消息'), findsOneWidget);
    expect(find.text('恢复出队'), findsOneWidget);
    await tester.tap(find.text('恢复出队'));
    await tester.pump();
    expect(resumed, isTrue);

    // 转入 AbsorbingCancel 态
    q.sendNow(q.firstId!, isGenerating: true);
    await tester.pump();
    expect(find.text('正在打断当前回合并发送...'), findsOneWidget);
  });
}
