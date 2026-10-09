import 'package:acp_agent_client/app/workbench_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> lifecycle(WidgetTester tester, AppLifecycleState state) async {
  tester.binding.handleAppLifecycleStateChanged(state);
  // 只排空微任务，不 pump 帧；最小化后不会收到 vsync。
  await tester.idle();
}

void main() {
  testWidgets('最小化排空已经挂在帧上的队列，后台新消息不等帧，还原恢复按帧', (tester) async {
    await lifecycle(tester, AppLifecycleState.resumed);
    final c = WorkbenchController(source: DataSource.fixtures);
    addTearDown(c.dispose);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    final applied = <int>[];
    c.batcher.enqueue(() => applied.add(0));
    await tester.idle();
    expect(applied, isEmpty, reason: '前台应按帧合并');
    await lifecycle(tester, AppLifecycleState.hidden);
    expect(applied, <int>[0]);
    expect(c.batcher.pendingCount, 0);
    for (var i = 1; i <= 100; i++) {
      c.batcher.enqueue(() => applied.add(i));
      await tester.idle();
      expect(c.batcher.pendingCount, 0);
    }
    expect(applied, List<int>.generate(101, (i) => i));
    await lifecycle(tester, AppLifecycleState.resumed);
    c.batcher.enqueue(() => applied.add(101));
    await tester.idle();
    expect(c.batcher.pendingCount, 1);
    await tester.pump();
    expect(applied, List<int>.generate(102, (i) => i));
    expect(c.batcher.pendingCount, 0);
  });

  testWidgets('后台切换不绕过重放 hold/release；dispose 取消挂起帧', (tester) async {
    await lifecycle(tester, AppLifecycleState.resumed);
    final c = WorkbenchController(source: DataSource.fixtures);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    var applied = 0;
    c.batcher.enqueue(() => applied++);
    c.batcher.hold();
    await lifecycle(tester, AppLifecycleState.hidden);
    expect(applied, 0);
    c.batcher.release();
    expect(applied, 1);
    await lifecycle(tester, AppLifecycleState.resumed);
    c.batcher.enqueue(() => applied++);
    c.dispose();
    await tester.pump();
    expect(applied, 1, reason: '已释放的组合根不能继续应用队列');
  });
}
