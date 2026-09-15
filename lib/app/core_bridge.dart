// 桥的 Dart 端薄封装：加载 cdylib、订阅五条事件流、把 JSON 字符串解成 Map 交给投影层。
// 这是前端唯一碰 lib/bridge/ 生成物的地方；投影层与 widget 只消费解码后的 JSON（docs/design.md § 3）。

import 'dart:async';
import 'dart:convert';

import '../bridge/api.dart' as api;
import '../bridge/frb_generated.dart';
import '../projection/wire.dart';

/// 五条事件流的名字（与 docs/design.md § 3 一致）。
enum CoreEvent {
  sessionUpdate('acp/session_update'),
  clientRequest('acp/client_request'),
  agentState('acp/agent_state'),
  terminalOutput('acp/terminal_output'),
  traffic('acp/traffic');

  const CoreEvent(this.name);

  final String name;
}

/// 一条到达的事件：通道 + 解码后的 payload（解不开的 payload 原样放在 [raw]，[json] 为空）。
class CoreEventRecord {
  const CoreEventRecord(this.channel, this.raw, this.json);

  final CoreEvent channel;
  final String raw;
  final JsonMap? json;
}

class CoreBridge {
  CoreBridge._();

  static CoreBridge? _instance;

  /// 加载 cdylib（进程内一次）。
  static Future<CoreBridge> load() async {
    if (_instance != null) return _instance!;
    await RustLib.init();
    return _instance = CoreBridge._();
  }

  final StreamController<CoreEventRecord> _events = StreamController<CoreEventRecord>.broadcast();
  final List<StreamSubscription<String>> _subscriptions = <StreamSubscription<String>>[];
  bool _subscribed = false;

  /// 全部事件（五条流合一，按到达顺序）。
  Stream<CoreEventRecord> get events => _events.stream;

  Stream<CoreEventRecord> on(CoreEvent channel) => events.where((e) => e.channel == channel);

  /// 先订阅再 init：核心在 init 时就会推 `core_ready`。
  void subscribe() {
    if (_subscribed) return;
    _subscribed = true;
    _subscriptions.addAll(<StreamSubscription<String>>[
      api.sessionUpdateStream().listen((s) => _push(CoreEvent.sessionUpdate, s)),
      api.clientRequestStream().listen((s) => _push(CoreEvent.clientRequest, s)),
      api.agentStateStream().listen((s) => _push(CoreEvent.agentState, s)),
      api.terminalOutputStream().listen((s) => _push(CoreEvent.terminalOutput, s)),
      api.trafficStream().listen((s) => _push(CoreEvent.traffic, s)),
    ]);
  }

  void _push(CoreEvent channel, String raw) {
    JsonMap? json;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) json = decoded.cast<String, dynamic>();
    } on FormatException {
      json = null;
    }
    _events.add(CoreEventRecord(channel, raw, json));
  }

  /// `core_init(data_dir)` → `{dataDir, coreVersion}`。
  Future<JsonMap> init(String dataDir) async {
    subscribe();
    final raw = await api.coreInit(dataDir: dataDir);
    return _decode(raw);
  }

  /// `ping(echo)` → `{pong, sequence, coreVersion}`。
  Future<JsonMap> ping(String echo) async => _decode(await api.ping(echo: echo));

  int get droppedEventCount => api.droppedEventCount().toInt();

  JsonMap _decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw FormatException('core returned non-object JSON', raw);
  }

  Future<void> dispose() async {
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    _subscribed = false;
    await _events.close();
  }
}
