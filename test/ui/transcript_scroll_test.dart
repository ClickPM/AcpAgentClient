// R2 验收 4：1,000 个块的转录滚动粗测（ListView.builder + 按帧合并 session/update）。计时类测试，单独跑：
//   flutter test test/ui/transcript_scroll_test.dart
// 结果落 build/scroll-report.json（gitignored）并 debugPrint；flutter test 是 debug、无 GPU，数字只作相对参考（记任务卡）。

import 'dart:convert';
import 'dart:io';

import 'package:acp_agent_client/projection/batcher.dart';
import 'package:acp_agent_client/projection/session_store.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/ui/transcript/transcript_list.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../gallery_harness.dart';

const String sid = 'sess_scroll';

/// 1,000 个块：用户消息 / 助手 Markdown / 思考 / 工具卡（含 diff 与终端）/ 计划 / 压缩 轮换，每 20 块一轮。
List<JsonMap> synthUpdates(int n) {
  final out = <JsonMap>[];
  for (var i = 0; i < n; i++) {
    switch (i % 8) {
      case 0:
        out.add(<String, dynamic>{'sessionUpdate': 'user_message_chunk', 'messageId': 'u$i', 'content': <String, dynamic>{'type': 'text', 'text': '第 $i 块：给 validate.ps1 加一项校验，先读一遍现有脚本。'}});
      case 1:
        out.add(<String, dynamic>{'sessionUpdate': 'agent_thought_chunk', 'messageId': 't$i', 'content': <String, dynamic>{'type': 'text', 'text': '先确认现有检查项，再决定插在编译之前还是之后（第 $i 块）。'}});
      case 2:
      case 3:
        out.add(<String, dynamic>{
          'sessionUpdate': 'agent_message_chunk',
          'messageId': 'a$i',
          'content': <String, dynamic>{
            'type': 'text',
            'text': '## 第 $i 块\n\n把检查拆成三层，任一层命中即 `exit 1`：\n\n1. 扫描面 `lib/**/*.dart`\n2. 禁止模式 `Color(0x…)`\n3. 白名单只有 `tokens.dart`\n\n```dart\nfinal x = $i; // block\n```\n',
          },
        });
      case 4:
        out.add(<String, dynamic>{'sessionUpdate': 'tool_call', 'toolCallId': 'call_$i', 'title': 'Read file', 'kind': 'read', 'status': 'completed', 'rawInput': <String, dynamic>{'path': 'docs/file_$i.md'}, 'locations': <JsonMap>[<String, dynamic>{'path': 'D:/x/docs/file_$i.md', 'line': i}]});
      case 5:
        out.add(<String, dynamic>{
          'sessionUpdate': 'tool_call',
          'toolCallId': 'edit_$i',
          'title': 'Edit file',
          'kind': 'edit',
          'status': 'completed',
          'content': <JsonMap>[
            <String, dynamic>{'type': 'diff', 'path': 'D:/x/lib/f_$i.dart', 'oldText': 'a\nb\nc\n', 'newText': 'a\nB\nc\nd\n'},
          ],
        });
      case 6:
        out.add(<String, dynamic>{'sessionUpdate': 'tool_call', 'toolCallId': 'exec_$i', 'title': 'Run Command', 'kind': 'execute', 'status': 'completed', 'rawInput': <String, dynamic>{'command': 'echo $i'}});
      case 7:
        // 稳定 plan 是整份替换（只会有一张卡），这里用带 planId 的 plan_update 让每块都是独立的卡。
        out.add(<String, dynamic>{
          'sessionUpdate': 'plan_update',
          'plan': <String, dynamic>{
            'type': 'items',
            'planId': 'plan_$i',
            'entries': <JsonMap>[
              <String, dynamic>{'content': '步骤 1', 'priority': 'high', 'status': 'completed'},
              <String, dynamic>{'content': '步骤 2（第 $i 块）', 'priority': 'medium', 'status': 'in_progress'},
            ],
          },
        });
    }
  }
  return out;
}

void main() {
  testWidgets('1,000 blocks: batched apply notifies once; scrolling through stays smooth', (tester) async {
    const width = 800.0;
    const height = 900.0;
    tester.view.physicalSize = const Size(width, height);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await loadGalleryFonts();
      await precacheIcons();
    });

    final sessions = Sessions();
    final store = sessions.session(sid);
    store.cwd = 'D:/x';
    store.startTurn(const <ContentBlockWire>[]);
    var notifications = 0;
    store.addListener(() => notifications++);

    // 按帧合并：1,000 条 update 排队，一次 flush 只通知一次。
    final flushes = <void Function()>[];
    final batcher = UpdateBatcher(sessions, scheduler: flushes.add);
    final apply = Stopwatch()..start();
    for (final u in synthUpdates(1000)) {
      batcher.enqueue(() => store.applyUpdateJson(u));
    }
    for (final f in flushes) {
      f();
    }
    apply.stop();
    expect(notifications, 1);
    expect(store.entries.length, greaterThanOrEqualTo(1000));

    final controller = ScrollController();
    final firstFrame = Stopwatch()..start();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(width, height)),
          child: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(builder: (_) => TranscriptList(store, controller: controller)),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    firstFrame.stop();
    expect(tester.takeException(), isNull);

    // 逐屏跳到底再跳回来，记每帧耗时。
    final frames = <double>[];
    final max = controller.position.maxScrollExtent;
    var offset = 0.0;
    while (offset < max) {
      offset = (offset + height).clamp(0, max);
      final sw = Stopwatch()..start();
      controller.jumpTo(offset);
      await tester.pump();
      sw.stop();
      frames.add(sw.elapsedMicroseconds / 1000);
      if (offset >= max) break;
    }
    // 平滑滚动一段（每帧 40px，60 帧）。
    controller.jumpTo(0);
    await tester.pump();
    for (var i = 0; i < 60; i++) {
      final sw = Stopwatch()..start();
      controller.jumpTo(controller.offset + 40);
      await tester.pump();
      sw.stop();
      frames.add(sw.elapsedMicroseconds / 1000);
    }
    expect(tester.takeException(), isNull);

    final sorted = List<double>.of(frames)..sort();
    double pct(double p) => sorted[((sorted.length - 1) * p).round()];
    final report = <String, dynamic>{
      'blocks': store.entries.length,
      'applyMs': apply.elapsedMicroseconds / 1000,
      'firstFrameMs': firstFrame.elapsedMicroseconds / 1000,
      'maxScrollExtent': max,
      'frames': frames.length,
      'p50Ms': pct(0.5),
      'p95Ms': pct(0.95),
      'maxMs': sorted.last,
      'mode': 'flutter test (debug, no GPU)',
    };
    Directory('build').createSync(recursive: true);
    File('build/scroll-report.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    debugPrint('[scroll] $report');
    controller.dispose();
  });
}
