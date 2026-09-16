// 画板 61 · 本地交互 shell 的一个标签（纯 Dart 模型 + xterm 的 Terminal 实例）：id / 标题 / cwd / 起止时间 / 退出状态，
// 键盘输入与尺寸变化经回调交给调用方（接线阶段接 `terminal_write` / `terminal_resize`），字节流经 [writeBytes] 喂进 xterm。
// PTY 在 Rust 侧（`rust/pty`），这里只渲染（docs/design.md § 9）。

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart' as xt;

import '../../theme/tokens.dart' as t;

class LocalTerminal extends ChangeNotifier {
  LocalTerminal({
    required this.id,
    required this.title,
    required this.cwd,
    this.onInput,
    this.onResize,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now() {
    terminal = xt.Terminal(
      maxLines: t.Geometry.terminalScrollbackLines,
      onOutput: (data) => onInput?.call(data),
      onResize: (cols, rows, _, _) => onResize?.call(cols, rows),
    );
    // `StringConversionSink.withCallback` 要等 close 才回调；`fromStringSink` 每块都 write 一次，流式才对。
    _decoder = const Utf8Decoder(allowMalformed: true).startChunkedConversion(
      StringConversionSink.fromStringSink(_TerminalSink(_onDecoded)),
    );
  }

  /// 核心分配的终端 id（`terminal_open` 的返回）。
  final String id;

  /// 标签条上的文案（画板 61 用 cwd 末段）。
  String title;
  final String cwd;

  /// 键盘输入（xterm 的 `onOutput`，含它对 DSR 等探询的应答）。
  void Function(String data)? onInput;

  /// 视口尺寸变化（列 × 行）。
  void Function(int cols, int rows)? onResize;

  late final xt.Terminal terminal;
  late final ByteConversionSink _decoder;

  final DateTime startedAt;
  DateTime? endedAt;
  int? exitCode;
  String? signal;

  bool get running => endedAt == null;
  Duration? get elapsed => endedAt?.difference(startedAt);

  /// 上次 `onResize` 报出的尺寸（重启时沿用）。
  int cols = t.Geometry.terminalCols;
  int rows = t.Geometry.terminalRows;

  /// `acp/terminal_output` 的原始字节：分块解码，跨块的多字节字符不会被切坏（`utf8.decode` 逐块解会把半个汉字变成 U+FFFD）。
  void writeBytes(List<int> bytes) => _decoder.add(bytes);

  void _onDecoded(String text) {
    if (text.isEmpty) return;
    terminal.write(text);
    notifyListeners();
  }

  /// 已解码的文本（gallery / 测试）。
  void write(String text) => _onDecoded(text);

  void exit({int? code, String? sig, DateTime? at}) {
    exitCode = code;
    signal = sig;
    endedAt = at ?? DateTime.now();
    notifyListeners();
  }

  /// 画板 61 的「清屏」：只清本地缓冲与视口，不动子进程。
  void clear() {
    terminal.buffer.clear();
    terminal.buffer.setCursor(0, 0);
    notifyListeners();
  }

  void recordSize(int c, int r) {
    cols = c;
    rows = r;
  }
}

/// 把分块解码出来的字符串直接交给终端。
class _TerminalSink implements StringSink {
  _TerminalSink(this._onText);

  final void Function(String) _onText;

  @override
  void write(Object? object) => _onText('$object');

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) => _onText(objects.join(separator));

  @override
  void writeCharCode(int charCode) => _onText(String.fromCharCode(charCode));

  @override
  void writeln([Object? object = '']) => _onText('$object\n');
}
