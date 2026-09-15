// gallery 的数据源：把 test/fixtures/*.jsonl 回放进投影层（ROUNDS.md § 0 第 3 条「三处共用」）。
// 时钟按每行的 delay 推进，思考耗时 / 轮耗时按 fixtures 的节奏走。同步 IO：flutter test 的 zone 是 FakeAsync。

import 'dart:io';

import '../projection/entries.dart';
import '../projection/fixture_line.dart';
import '../projection/fixture_replay.dart';
import '../projection/session_store.dart';

/// 由 fixtures 的 delay 推进的假时钟。
class ReplayClock {
  ReplayClock([DateTime? start]) : now = start ?? DateTime.utc(2026, 9, 15, 12);

  DateTime now;

  void advance(int ms) => now = DateTime.fromMillisecondsSinceEpoch(now.millisecondsSinceEpoch + ms, isUtc: true);
}

class FixtureReplay {
  FixtureReplay._(this.sessions, this.replayer, this.clock);

  final Sessions sessions;
  final FixtureReplayer replayer;
  final ReplayClock clock;

  static const String sessionId = 'sess_9f3c21a7';
  static const String agentId = 'fixture-agent';

  static Directory fixturesDir = Directory('test/fixtures');

  static List<FixtureLine> load(String file) {
    final f = File('${fixturesDir.path}/$file.jsonl');
    return FixtureLine.parseAll(f.readAsStringSync());
  }

  /// 回放若干文件；`upTo` = 最后一个文件只喂到第 N 行（不含），用来停在某个中间态；`untilTag` = 喂到该 tag 行为止（含）。
  static FixtureReplay replay(List<String> files, {int? upTo, String? untilTag, bool autoAnswer = false}) {
    final clock = ReplayClock();
    final sessions = Sessions(clock: () => clock.now);
    final replayer = FixtureReplayer(sessions, agentId: agentId, autoAnswer: autoAnswer)..onDelay = clock.advance;
    final r = FixtureReplay._(sessions, replayer, clock);
    for (var i = 0; i < files.length; i++) {
      final lines = load(files[i]);
      final last = i == files.length - 1;
      for (var n = 0; n < lines.length; n++) {
        if (last && upTo != null && n >= upTo) return r;
        replayer.feed(lines[n]);
        if (last && untilTag != null && lines[n].tag == untilTag) return r;
      }
    }
    return r;
  }

  SessionStore get session => sessions.session(sessionId, agentId: agentId);

  List<TranscriptEntry> get entries => session.entries;

  T first<T extends TranscriptEntry>() => entries.whereType<T>().first;
  T last<T extends TranscriptEntry>() => entries.whereType<T>().last;
  Iterable<T> all<T extends TranscriptEntry>() => entries.whereType<T>();
  ToolCallEntry tool(String id) => session.toolCalls[id]!;
}
