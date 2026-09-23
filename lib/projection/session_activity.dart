// 画板 06 A / 08 C / 09 · 会话活动的派生：哪些会话在跑、哪些在等你处理，以及按工作区的计数。
//
// 「等你处理」= 该会话至少有一条挂起的 permission / elicitation（画板 09）；它与「运行中」互斥——
// 等你的会话不扫掠、不计入在跑数，挂起的全部了结而回合还没结束就回到运行中。
// requestScope 的 elicitation（认证阶段，无会话，落画板 52）不算。
//
// 只读 [Sessions]（回合与挂起队列），每次现算、不记状态：只有内存里有投影的会话才可能在跑或在等，
// 另记一份就多一处要对齐的状态。纯 Dart。

import 'entries.dart';
import 'session_store.dart';

class SessionActivity {
  /// [workspaceKey] 把会话的 cwd 归成工作区键（调用方给 `WorkspaceState.normalizeCwd`：
  /// 同一目录的两种写法不能被判成两个工作区；那条规则只该有一份，这里不再抄）。
  factory SessionActivity(Sessions sessions, {required String Function(String cwd) workspaceKey}) {
    final awaiting = sessions.pending.firstBySession();
    final running = <String>{
      for (final s in sessions.all)
        if (s.isRunning && !awaiting.containsKey(s.sessionId)) s.sessionId,
    };
    Map<String, int> byWorkspace(Iterable<String> ids) {
      final out = <String, int>{};
      for (final id in ids) {
        final String? cwd = sessions.maybe(id)?.cwd;
        if (cwd == null || cwd.isEmpty) continue;
        final key = workspaceKey(cwd);
        out[key] = (out[key] ?? 0) + 1;
      }
      return out;
    }

    return SessionActivity._(awaiting, running, byWorkspace(running), byWorkspace(awaiting.keys));
  }

  SessionActivity._(this.awaiting, this.running, this.runningByWorkspace, this.awaitingByWorkspace);

  /// 画板 09：等你处理的会话 → 它最早到的那一项（[PermissionEntry] 或 [ElicitationEntry]，侧栏标记按它定种类）。
  final Map<String, TranscriptEntry> awaiting;

  /// 画板 06 A：有在途 prompt、且不在 [awaiting] 里的会话（出扫掠亮点线）。
  final Set<String> running;

  /// 画板 08 C / 09 B：按工作区键分组的会话数。没记 cwd 的会话归不到某一行，只进 [runningTotal] / [awaitingTotal]。
  final Map<String, int> runningByWorkspace;
  final Map<String, int> awaitingByWorkspace;

  /// 触发钮上的合计：所有工作区（含当前），**没记 cwd 的也算**——它确实在跑 / 在等，
  /// 漏掉它就不再是「别处还有多少」的真数。
  int get runningTotal => running.length;
  int get awaitingTotal => awaiting.length;

  /// 有在跑或等你会话的工作区个数（触发钮 tooltip 的最后一段）。
  int get workspaceCount => <String>{...runningByWorkspace.keys, ...awaitingByWorkspace.keys}.length;
}
