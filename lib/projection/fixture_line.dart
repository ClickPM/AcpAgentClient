// test/fixtures/*.jsonl 的一行（格式见 test/fixtures/README.md）。三处共用：Rust 测试、Dart 投影单测、gallery 回放。
// 纯 Dart。

import 'dart:convert';

import 'wire.dart';

/// 线上行的方向：out = 客户端 → agent；in = agent → 客户端；local = 非协议的本地态；stderr = agent 的 stderr。
enum FixtureDir { out, inbound, local, stderr, unknown }

class FixtureLine {
  const FixtureLine(this.json);

  factory FixtureLine.parse(String line) {
    final decoded = jsonDecode(line);
    return FixtureLine(decoded is Map ? decoded.cast<String, dynamic>() : const <String, dynamic>{});
  }

  /// 逐行解析一个 JSONL 文件的内容，跳过空行。
  static List<FixtureLine> parseAll(String text) => <FixtureLine>[
        for (final raw in const LineSplitter().convert(text))
          if (raw.trim().isNotEmpty) FixtureLine.parse(raw),
      ];

  final JsonMap json;

  FixtureDir get dir => switch (json['dir']) {
        'out' => FixtureDir.out,
        'in' => FixtureDir.inbound,
        'local' => FixtureDir.local,
        'stderr' => FixtureDir.stderr,
        _ => FixtureDir.unknown,
      };

  String? get tag => json['tag'] as String?;
  String? get note => json['note'] as String?;

  /// `expect: reject` = Rust 侧必须反序列化失败的故意行。
  bool get expectReject => json['expect'] == 'reject';

  /// `awaits: permission | elicitation`：回放器在此停住等用户回应。
  String? get awaits => json['awaits'] as String?;

  /// 回放延时（毫秒）。
  int get delayMs => (json['delay'] as num?)?.toInt() ?? 0;

  /// 协议消息（JSON-RPC 对象）；local / stderr 行没有。
  JsonMap? get msg => json['msg'] is Map ? (json['msg'] as Map).cast<String, dynamic>() : null;

  String? get method => msg?['method'] as String?;
  Object? get id => msg?['id'];
  JsonMap? get params => msg?['params'] is Map ? (msg!['params'] as Map).cast<String, dynamic>() : null;
  JsonMap? get result => msg?['result'] is Map ? (msg!['result'] as Map).cast<String, dynamic>() : null;

  bool get isSessionUpdate => method == 'session/update';

  /// `session/update` 行的 SessionNotification。
  SessionNotificationWire? get sessionNotification =>
      isSessionUpdate && params != null ? SessionNotificationWire(params!) : null;

  /// local 行：terminal_output / terminal_exit。
  String? get localKind => json['kind'] as String?;
  String? get terminalId => json['terminalId'] as String?;
  String? get chunk => json['chunk'] as String?;
  JsonMap? get exitStatus => json['exitStatus'] is Map ? (json['exitStatus'] as Map).cast<String, dynamic>() : null;

  /// stderr 行。
  String? get line => json['line'] as String?;
}
