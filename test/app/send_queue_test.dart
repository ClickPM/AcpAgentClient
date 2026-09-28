// Round send-queue — 发送队列纯状态机单测（对齐 Zed message_queue.rs，验收 1）。

import 'package:acp_agent_client/app/send_queue.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SendQueue State Machine', () {
    test('初始状态：空队列，状态为 autoProcess，不可 fast-track', () {
      final q = SendQueue();
      expect(q.isEmpty, isTrue);
      expect(q.length, 0);
      expect(q.processingState, ProcessingState.autoProcess);
      expect(q.canFastTrack, isFalse);
      expect(q.first, isNull);
    });

    test('FIFO 出队：入队两项，onTurnStopped 依次自动弹出', () {
      final q = SendQueue();
      final e1 = q.enqueue(<JsonMap>[<String, dynamic>{'type': 'text', 'text': 'first'}]);
      final e2 = q.enqueue(<JsonMap>[<String, dynamic>{'type': 'text', 'text': 'second'}]);
      expect(q.length, 2);
      expect(q.firstId, e1.id);
      expect(q.canFastTrack, isTrue);

      final popped1 = q.onTurnStopped();
      expect(popped1?.id, e1.id);
      expect(popped1?.plainText, 'first');
      expect(q.length, 1);

      final popped2 = q.onTurnStopped();
      expect(popped2?.id, e2.id);
      expect(popped2?.plainText, 'second');
      expect(q.length, 0);
      expect(q.canFastTrack, isFalse);

      final popped3 = q.onTurnStopped();
      expect(popped3, isNull);
    });

    test('编辑队首保护：isEditingFront 为 true 时不自动出队', () {
      final q = SendQueue();
      q.enqueue(<JsonMap>[<String, dynamic>{'type': 'text', 'text': 'item'}]);
      expect(q.onTurnStopped(isEditingFront: true), isNull);
      expect(q.length, 1);
    });

    test('手动停止 / 报错 → Paused 保护；再入队 / resume 恢复', () {
      final q = SendQueue();
      q.enqueue(<JsonMap>[<String, dynamic>{'type': 'text', 'text': 'item 1'}]);
      q.pause();
      expect(q.isPaused, isTrue);
      expect(q.onTurnStopped(), isNull);
      expect(q.length, 1);

      // resume 恢复
      q.resume();
      expect(q.processingState, ProcessingState.autoProcess);
      expect(q.onTurnStopped()?.plainText, 'item 1');
      expect(q.isEmpty, isTrue);

      // 再次暂停后，入队操作视为积极交互，自动恢复为 autoProcess
      q.enqueue(<JsonMap>[<String, dynamic>{'type': 'text', 'text': 'item 2'}]);
      q.pause();
      expect(q.isPaused, isTrue);
      q.enqueue(<JsonMap>[<String, dynamic>{'type': 'text', 'text': 'item 3'}]);
      expect(q.processingState, ProcessingState.autoProcess);
    });

    test('Send Now 在回合进行中 → AbsorbingCancel，吞掉那次 Stopped 不双发', () {
      final q = SendQueue();
      final e1 = q.enqueue(<JsonMap>[<String, dynamic>{'type': 'text', 'text': 'm1'}]);
      final e2 = q.enqueue(<JsonMap>[<String, dynamic>{'type': 'text', 'text': 'm2'}]);

      // 对 m2 触发 Send Now（在途）
      final sent = q.sendNow(e2.id, isGenerating: true);
      expect(sent?.id, e2.id);
      expect(q.processingState, ProcessingState.absorbingCancel);
      expect(q.isAbsorbingCancel, isTrue);
      expect(q.length, 1); // 只剩 m1

      // 吞掉当前正在执行的回合被 cancel 时的 Stopped 事件
      final absorbed = q.onTurnStopped();
      expect(absorbed, isNull);
      // 恢复为 autoProcess，未双发 m1
      expect(q.processingState, ProcessingState.autoProcess);
      expect(q.length, 1);

      // 后续回合结束时正常弹出 m1
      final next = q.onTurnStopped();
      expect(next?.id, e1.id);
    });

    test('fast-track 插队：生成中转入 AbsorbingCancel；空闲时不进 AbsorbingCancel', () {
      final q = SendQueue();
      final e1 = q.enqueue(<JsonMap>[<String, dynamic>{'type': 'text', 'text': 'm1'}]);

      // 空闲时触发 fastTrack
      final ft1 = q.tryFastTrack(isGenerating: false);
      expect(ft1?.id, e1.id);
      expect(q.processingState, ProcessingState.autoProcess);
      expect(q.canFastTrack, isFalse);

      // 生成中触发 fastTrack
      final e2 = q.enqueue(<JsonMap>[<String, dynamic>{'type': 'text', 'text': 'm2'}]);
      final ft2 = q.tryFastTrack(isGenerating: true);
      expect(ft2?.id, e2.id);
      expect(q.processingState, ProcessingState.absorbingCancel);
      // Stopped 事件被吞掉
      expect(q.onTurnStopped(), isNull);
      expect(q.processingState, ProcessingState.autoProcess);
    });

    test('popBack 用于空框按 ↑ 回退队尾编辑', () {
      final q = SendQueue();
      q.enqueue(<JsonMap>[<String, dynamic>{'type': 'text', 'text': 'first'}]);
      final e2 = q.enqueue(<JsonMap>[<String, dynamic>{'type': 'text', 'text': 'second'}]);
      expect(q.length, 2);

      final popped = q.popBack();
      expect(popped?.id, e2.id);
      expect(popped?.plainText, 'second');
      expect(q.length, 1);

      q.popBack();
      expect(q.popBack(), isNull);
      expect(q.isEmpty, isTrue);
    });

    test('remove 与 clear 正确移除项与更新 canFastTrack', () {
      final q = SendQueue();
      final e1 = q.enqueue(<JsonMap>[<String, dynamic>{'type': 'text', 'text': '1'}]);
      final e2 = q.enqueue(<JsonMap>[<String, dynamic>{'type': 'text', 'text': '2'}]);
      expect(q.remove(999), isNull);
      expect(q.remove(e1.id)?.id, e1.id);
      expect(q.length, 1);
      expect(q.firstId, e2.id);

      q.clear();
      expect(q.isEmpty, isTrue);
      expect(q.canFastTrack, isFalse);
    });
  });
}
