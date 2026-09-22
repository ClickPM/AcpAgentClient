// 画板 70「转录」小节的全局开关：读盘、落盘，以及与外观同一条教训 ——
// 读盘还没回来 / 读盘失败时不能把内存里的缺省值写回去，把盘上已有的设置抹掉。

import 'dart:async';

import 'package:acp_agent_client/app/transcript_folds.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_core.dart';

void main() {
  test('没存过 -> 默认开', () async {
    final core = FakeCore();
    final folds = TranscriptFolds(bridge: core);
    expect(folds.autoCollapse, isTrue, reason: '画板 70 写的是默认开');
    await folds.start();
    expect(folds.autoCollapse, isTrue);
    expect(core.transcriptPrefs, isEmpty, reason: '只是读一下，不该顺手落盘');
  });

  test('盘上存的是关 -> 读回来生效', () async {
    final core = FakeCore()..transcriptPrefs = <String, dynamic>{'collapse_finished_turns': false};
    final folds = TranscriptFolds(bridge: core);
    var notified = 0;
    folds.addListener(() => notified++);
    await folds.start();
    expect(folds.autoCollapse, isFalse);
    expect(notified, 1);
  });

  test('改开关：立即生效并落盘', () async {
    final core = FakeCore();
    final folds = TranscriptFolds(bridge: core);
    await folds.start();
    await folds.setAutoCollapse(false);
    expect(folds.autoCollapse, isFalse);
    expect(core.transcriptPrefs, <String, dynamic>{'collapse_finished_turns': false});
    await folds.setAutoCollapse(true);
    expect(core.transcriptPrefs, <String, dynamic>{'collapse_finished_turns': true});
  });

  test('读盘还没回来就点了开关：读盘回来不把用户的选择盖掉', () async {
    final core = FakeCore()
      ..transcriptPrefs = <String, dynamic>{'collapse_finished_turns': true}
      ..transcriptPrefsGetGate = Completer<void>();
    final folds = TranscriptFolds(bridge: core);
    final Future<void> started = folds.start();

    // 读盘挂着的时候用户点了「关」。
    final Future<void> edited = folds.setAutoCollapse(false);
    expect(folds.autoCollapse, isFalse, reason: '界面当场就要变');

    core.transcriptPrefsGetGate!.complete();
    await started;
    await edited;
    expect(folds.autoCollapse, isFalse, reason: '盘上的旧值不该盖回用户刚点的那一下');
    expect(core.transcriptPrefs, <String, dynamic>{'collapse_finished_turns': false});
  });

  test('读盘失败：只改内存，绝不落盘（免得把盘上已有的抹掉）', () async {
    // 盘上存的是「开」。读失败时若还照常落盘，这一格就会被写成「关」。
    final core = FakeCore()
      ..transcriptPrefs = <String, dynamic>{'collapse_finished_turns': true}
      ..transcriptPrefsGetFailures = -1; // 一直失败
    final folds = TranscriptFolds(bridge: core);
    await folds.start();
    expect(folds.autoCollapse, isTrue, reason: '读不到就回默认（默认也是开）');

    await folds.setAutoCollapse(false);
    expect(folds.autoCollapse, isFalse, reason: '界面照常变');
    expect(core.transcriptPrefs, <String, dynamic>{'collapse_finished_turns': true},
        reason: '从没读成功过就不许落盘');
  });

  test('没有桥（gallery / 单测）：只在内存里生效', () async {
    final folds = TranscriptFolds();
    await folds.start();
    await folds.setAutoCollapse(false);
    expect(folds.autoCollapse, isFalse);
  });
}
