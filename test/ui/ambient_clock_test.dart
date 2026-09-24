// iteration-14 · 常驻动画（spinner、侧栏扫掠线）走共用低频时钟 AmbientClock（lib/ui/shell/motion.dart）：
// 屏上挂着它们时没有逐帧 ticker（Windows 上每一帧都是整窗重画），前台 ≈ 15 跳/秒、失焦 4 跳/秒、最小化停表；
// 没有订阅者时定时器不存在；TickerMode 关掉的子树、reduced-motion 下的扫掠线都不订阅。

import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/shell/motion.dart';
import 'package:acp_agent_client/ui/shell/sidebar.dart';
import 'package:acp_agent_client/ui/transcript/icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final AmbientClock _clock = AmbientClock.instance;

Widget _host(Widget child) => Directionality(textDirection: TextDirection.ltr, child: Center(child: child));

/// [span] 这段假时间里时钟跳了几次（临时挂一个订阅者数；它和屏上的订阅者共用同一个定时器）。
Future<int> _ticks(WidgetTester tester, Duration span) async {
  var n = 0;
  void count() => n++;
  _clock.addListener(count);
  await tester.pump(span);
  _clock.removeListener(count);
  return n;
}

void main() {
  const second = Duration(seconds: 1);
  final int focused = second.inMicroseconds ~/ t.Motion.ambientInterval.inMicroseconds;
  final int inactive = second.inMicroseconds ~/ t.Motion.ambientIntervalInactive.inMicroseconds;

  testWidgets('spinner 不挂逐帧 ticker，按 ambientInterval 跳，转角随时间走', (tester) async {
    await tester.pumpWidget(_host(Spinner()));
    expect(tester.binding.transientCallbackCount, 0, reason: '没有 Ticker 在逐帧请求');
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(_clock.interval, t.Motion.ambientInterval);

    final RotationTransition rotation = tester.widget(find.byType(RotationTransition));
    final double before = rotation.turns.value;
    expect(await _ticks(tester, second), focused);
    await tester.pump(t.Geometry.spinnerPeriod ~/ 4);
    expect(rotation.turns.value, isNot(before), reason: '同一个相位对象，值按帧时间戳现算');

    await tester.pumpWidget(_host(const SizedBox()));
    expect(_clock.interval, isNull, reason: '没有订阅者：定时器不存在');
  });

  testWidgets('多只 spinner 共用一个时钟：跳数不随只数变', (tester) async {
    await tester.pumpWidget(_host(Row(mainAxisSize: MainAxisSize.min, children: <Widget>[Spinner(), Spinner(), Spinner()])));
    expect(tester.binding.transientCallbackCount, 0);
    expect(await _ticks(tester, second), focused);
  });

  testWidgets('窗口状态分档：失焦 4 跳/秒、hidden 停表、回前台复原', (tester) async {
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    await tester.pumpWidget(_host(Spinner()));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(_clock.interval, t.Motion.ambientIntervalInactive);
    expect(await _ticks(tester, second), inactive);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(_clock.interval, isNull, reason: '最小化：框架本来就停帧，定时器也停');
    expect(await _ticks(tester, second), 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(_clock.interval, t.Motion.ambientInterval);
    expect(await _ticks(tester, second), focused);
  });

  testWidgets('TickerMode 关掉的子树里 spinner 不订阅', (tester) async {
    await tester.pumpWidget(_host(TickerMode(enabled: false, child: Spinner())));
    expect(_clock.interval, isNull);

    await tester.pumpWidget(_host(TickerMode(enabled: true, child: Spinner())));
    expect(_clock.interval, t.Motion.ambientInterval);
  });

  group('侧栏运行中的扫掠线', () {
    Widget row({bool reduceMotion = false}) => MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
              child: Center(
                child: SizedBox(
                  width: 280,
                  child: SidebarSessionRow(
                    SidebarSession(id: 's', title: '跑着的会话', updatedAt: DateTime(2026, 9, 24), messageCount: 3),
                    now: DateTime(2026, 9, 24),
                    running: true,
                  ),
                ),
              ),
            ),
          ),
        );

    testWidgets('走同一个时钟，不挂逐帧 ticker', (tester) async {
      await tester.pumpWidget(row());
      expect(tester.binding.transientCallbackCount, 0);
      expect(_clock.interval, t.Motion.ambientInterval);
      expect(await _ticks(tester, second), focused);
    });

    testWidgets('reduced-motion 下是静态线，不订阅', (tester) async {
      await tester.pumpWidget(row(reduceMotion: true));
      expect(_clock.interval, isNull);
    });
  });
}
