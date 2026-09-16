// 终端面板的接线状态（R4 接线阶段）：每个标签一个本地 shell（`terminal_open`），键盘输入 → `terminal_write`、
// 视口变化 → `terminal_resize`、停止 → `terminal_kill`、关闭 → `terminal_close`；输出从 `acp/terminal_output`（source = local）
// 按 terminalId 分发到各自的 [LocalTerminal]。widget 只拿模型与回调（CLAUDE.md 规则 3）。

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../projection/wire.dart';
import '../theme/tokens.dart' as t;
import '../ui/terminal/local_terminal.dart';
import 'core_bridge.dart';

class LocalTerminals extends ChangeNotifier {
  LocalTerminals({this.bridge});

  final CoreCommands? bridge;
  final List<LocalTerminal> tabs = <LocalTerminal>[];
  String? lastError;
  bool _disposed = false;

  LocalTerminal? byId(String id) {
    for (final tab in tabs) {
      if (tab.id == id) return tab;
    }
    return null;
  }

  /// 标签条上的文案：cwd 的末段（画板 61）。
  static String titleOf(String cwd) => cwd.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).lastOrNull ?? cwd;

  /// 开一个新标签；返回它的 id（失败记 [lastError] 返回 null）。
  Future<String?> open(String cwd, {int? at}) async {
    final b = bridge;
    if (b == null) return null;
    try {
      final r = await b.terminalOpen(cwd, cols: t.Geometry.terminalCols, rows: t.Geometry.terminalRows);
      final id = r['terminalId'] as String? ?? '';
      if (id.isEmpty) throw StateError('terminal_open 没有返回 terminalId');
      final term = LocalTerminal(
        id: id,
        title: titleOf(cwd),
        cwd: r['cwd'] as String? ?? cwd,
        // 键盘输入：进程已退出（或刚被停止、退出事件还在路上）时写不进去是正常的，不算错误。
        onInput: (data) => _write(id, data),
        onResize: (cols, rows) => _resize(id, cols, rows),
      );
      term.addListener(_forward);
      if (at != null && at >= 0 && at <= tabs.length) {
        tabs.insert(at, term);
      } else {
        tabs.add(term);
      }
      _touch();
      return id;
    } catch (e) {
      lastError = describeError(e);
      debugPrint('[terminals] open failed: ${describeError(e)}');
      _touch();
      return null;
    }
  }

  Future<void> _write(String id, String data) async {
    final term = byId(id);
    final b = bridge;
    if (term == null || b == null || !term.running) return;
    try {
      await b.terminalWrite(id, data);
    } catch (e) {
      // 停止方块按下到退出事件到达之间的按键：pty 报「句柄无效」，吞掉即可。
      debugPrint('[terminals] write to $id dropped: ${describeError(e)}');
    }
  }

  void _resize(String id, int cols, int rows) {
    final term = byId(id);
    if (term == null || !term.running) return;
    if (term.cols == cols && term.rows == rows) return;
    term.recordSize(cols, rows);
    _guard(() => bridge!.terminalResize(id, cols: cols, rows: rows));
  }

  /// 画板 61 的停止方块：结束 shell 进程（标签留着，状态行变已退出）。
  Future<void> stop(String id) => _guard(() => bridge!.terminalKill(id));

  /// 关掉标签：核心 kill + 释放；本地丢掉模型。
  Future<void> close(String id) async {
    final term = byId(id);
    if (term == null) return;
    tabs.remove(term);
    term.removeListener(_forward);
    term.dispose();
    _touch();
    await _guard(() => bridge!.terminalClose(id));
  }

  /// 重启：同一个 cwd、同一个位置换一个新 shell；返回新 id。
  Future<String?> restart(String id) async {
    final term = byId(id);
    if (term == null) return null;
    final at = tabs.indexOf(term);
    final cwd = term.cwd;
    await close(id);
    return open(cwd, at: at);
  }

  void clear(String id) => byId(id)?.clear();

  /// `acp/terminal_output`（source = local）：字节进 xterm，退出状态进模型。
  void applyOutput(JsonMap payload) {
    final id = payload['terminalId'];
    if (id is! String) return;
    final term = byId(id);
    if (term == null) return;
    final exit = payload['exitStatus'];
    if (exit is Map) {
      final code = exit['exitCode'];
      term.exit(code: code is num ? code.toInt() : null, sig: exit['signal'] as String?);
      return;
    }
    final b64 = payload['bytes'];
    if (b64 is String) {
      try {
        term.writeBytes(base64Decode(b64));
      } on FormatException {
        // 坏的 base64：丢掉这一块，别掀掉整条流。
      }
    }
  }

  Future<void> _guard(Future<Object?> Function() body) async {
    try {
      await body();
    } catch (e) {
      lastError = describeError(e);
      debugPrint('[terminals] ${describeError(e)}');
      _touch();
    }
  }

  void _forward() => _touch();

  void _touch() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final tab in tabs) {
      tab.removeListener(_forward);
      tab.dispose();
    }
    tabs.clear();
    super.dispose();
  }
}
