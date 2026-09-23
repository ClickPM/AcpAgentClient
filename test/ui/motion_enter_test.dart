// 画板 05 的入场件 MotionEnter（BACKLOG P5「motion 的两个潜伏项」，iteration-04）：
// ① 同一元素被复用而 duration / delay 变了，下一次播放要按新参数走，不能冻在首次 build 的那一套上；
// ② delay 与 duration 都是零时 `delay / (delay + duration)` 是 NaN，中途切到这一档不能让 Interval 的断言炸。

import 'package:acp_agent_client/ui/shell/motion.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({required Object? epoch, Duration delay = Duration.zero, required Duration duration}) => Directionality(
  textDirection: TextDirection.ltr,
  child: MotionEnter(epoch: epoch, delay: delay, duration: duration, child: const SizedBox.shrink()),
);

double _opacity(WidgetTester tester) => tester.widget<Opacity>(find.byType(Opacity)).opacity;

void main() {
  testWidgets('复用同一元素、时长变长：重播按新时长走', (tester) async {
    await tester.pumpWidget(_host(epoch: 0, duration: const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(_opacity(tester), 1);

    // 同一位置、同一类型：元素被复用，走 didUpdateWidget。
    await tester.pumpWidget(_host(epoch: 1, duration: const Duration(milliseconds: 1000)));
    await tester.pump(const Duration(milliseconds: 150));
    // 按旧的 100ms 早就播完了；按新的 1000ms 才走了一小段。
    expect(_opacity(tester), lessThan(1));
    await tester.pumpAndSettle();
    expect(_opacity(tester), 1);
  });

  testWidgets('复用同一元素、延迟变长：重播按新延迟错开', (tester) async {
    await tester.pumpWidget(_host(epoch: 0, duration: const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      _host(epoch: 1, delay: const Duration(milliseconds: 300), duration: const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    // 还在 300ms 的延迟里：一点都不该显出来。
    expect(_opacity(tester), 0);
    await tester.pumpAndSettle();
    expect(_opacity(tester), 1);
  });

  testWidgets('delay 与 duration 都是零：挂上、重播、播到一半切过来都不炸', (tester) async {
    await tester.pumpWidget(_host(epoch: 0, duration: Duration.zero));
    await tester.pump();
    expect(_opacity(tester), 1);

    await tester.pumpWidget(_host(epoch: 1, duration: Duration.zero));
    await tester.pump();
    expect(_opacity(tester), 1);

    // 播到一半把两者都切成零：正在跑的那段按新曲线取值，Interval 的起点不能是 NaN。
    await tester.pumpWidget(_host(epoch: 2, duration: const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(_host(epoch: 2, duration: Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(_opacity(tester), 1);
  });
}
