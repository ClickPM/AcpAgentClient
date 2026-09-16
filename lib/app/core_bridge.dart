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

/// 桥抛出的错误的可读文案：`BridgeError` 的 `toString` 只有类名，报告与 lastError 要看 `code: message`。
String describeError(Object e) => e is api.BridgeError ? '${e.code}: ${e.message}' : e.toString();

/// 一条到达的事件：通道 + 解码后的 payload（解不开的 payload 原样放在 [raw]，[json] 为空）。
class CoreEventRecord {
  const CoreEventRecord(this.channel, this.raw, this.json);

  final CoreEvent channel;
  final String raw;
  final JsonMap? json;
}

/// 组合根用到的核心接口（事件订阅 + R3 的命令面）。抽出来是为了让 `lib/app/` 的接线能在
/// `flutter test` 里用假实现驱动（cdylib 在 flutter_tester 里加载不了），真实实现只有 [CoreBridge]。
abstract interface class CoreCommands {
  Stream<CoreEventRecord> on(CoreEvent channel);

  Future<JsonMap> init(String dataDir);

  Future<JsonMap> agentConnect(String agentId, {String? cwd});
  Future<JsonMap> agentDisconnect(String agentId);
  Future<JsonMap> sessionNew(String agentId, String cwd);
  Future<JsonMap> sessionPrompt(String agentId, String sessionId, List<Object?> prompt);
  Future<JsonMap> sessionCancel(String agentId, String sessionId);
  Future<JsonMap> sessionSetConfigOption(String agentId, String sessionId, String configId, JsonMap value);
  Future<JsonMap> sessionSetMode(String agentId, String sessionId, String modeId);
  Future<JsonMap> acpRespond(String agentId, String requestId, JsonMap response);
  Future<JsonMap> authenticate(String agentId, String methodId);
  Future<JsonMap> agentSettingsGet();
  Future<JsonMap> fsListDir(String root, String path);
  Future<JsonMap> fsSearch(String root, String query, {int limit});
  Future<JsonMap> gitBranches(String cwd);
  Future<JsonMap> gitSwitch(String cwd, String branch);
  Future<JsonMap> gitCreateBranch(String cwd, String branch);
  Future<JsonMap> gitDiff(String cwd, {String? base});
  Future<JsonMap> workspaceRecent();
  Future<JsonMap> workspaceOpen(String path);
  Future<JsonMap> sessionIndexList();
  Future<JsonMap> sessionIndexUpsert(JsonMap entry);
  Future<JsonMap> sessionIndexRemove(String agentId, String sessionId);
  Future<JsonMap> uiStateGet();
  Future<JsonMap> uiStateSet(JsonMap patch);

  // ---- R4：文件面板、目录监视、git 徽章、本地 shell 与终端控制、退出收尾
  Future<JsonMap> fsRead(String root, String path);

  /// 流命令：每批变化一条 `{root, dirs, git}`；取消订阅即停。
  Stream<JsonMap> fsWatch(String root);
  Future<JsonMap> fsUnwatch(String root);
  Future<JsonMap> gitStatus(String cwd);
  Future<JsonMap> terminalOpen(String cwd, {required int cols, required int rows});
  Future<JsonMap> terminalWrite(String terminalId, String data);
  Future<JsonMap> terminalResize(String terminalId, {required int cols, required int rows});
  Future<JsonMap> terminalKill(String terminalId);
  Future<JsonMap> terminalClose(String terminalId);
  Future<JsonMap> coreShutdown();
}

class CoreBridge implements CoreCommands {
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

  @override
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
  @override
  Future<JsonMap> init(String dataDir) async {
    subscribe();
    final raw = await api.coreInit(dataDir: dataDir);
    return _decode(raw);
  }

  /// `ping(echo)` → `{pong, sequence, coreVersion}`。
  Future<JsonMap> ping(String echo) async => _decode(await api.ping(echo: echo));

  int get droppedEventCount => api.droppedEventCount().toInt();

  // ---- 命令（docs/design.md § 3；R3 用到的那些。入参与返回都是 JSON 字符串，这里只做 decode）

  @override
  Future<JsonMap> agentConnect(String agentId, {String? cwd}) async =>
      _decode(await api.agentConnect(agentId: agentId, cwd: cwd));

  @override
  Future<JsonMap> agentDisconnect(String agentId) async => _decode(await api.agentDisconnect(agentId: agentId));

  @override
  Future<JsonMap> sessionNew(String agentId, String cwd) async => _decode(await api.sessionNew(agentId: agentId, cwd: cwd));

  @override
  Future<JsonMap> sessionPrompt(String agentId, String sessionId, List<Object?> prompt) async =>
      _decode(await api.sessionPrompt(agentId: agentId, sessionId: sessionId, prompt: jsonEncode(prompt)));

  @override
  Future<JsonMap> sessionCancel(String agentId, String sessionId) async =>
      _decode(await api.sessionCancel(agentId: agentId, sessionId: sessionId));

  @override
  Future<JsonMap> sessionSetConfigOption(String agentId, String sessionId, String configId, JsonMap value) async => _decode(
        await api.sessionSetConfigOption(agentId: agentId, sessionId: sessionId, configId: configId, value: jsonEncode(value)),
      );

  @override
  Future<JsonMap> sessionSetMode(String agentId, String sessionId, String modeId) async =>
      _decode(await api.sessionSetMode(agentId: agentId, sessionId: sessionId, modeId: modeId));

  @override
  Future<JsonMap> acpRespond(String agentId, String requestId, JsonMap response) async =>
      _decode(await api.acpRespond(agentId: agentId, requestId: requestId, response: jsonEncode(response)));

  @override
  Future<JsonMap> authenticate(String agentId, String methodId) async =>
      _decode(await api.authenticate(agentId: agentId, methodId: methodId));

  @override
  Future<JsonMap> agentSettingsGet() async => _decode(await api.agentSettingsGet());

  @override
  Future<JsonMap> fsListDir(String root, String path) async => _decode(await api.fsListDir(root: root, path: path));

  @override
  Future<JsonMap> fsSearch(String root, String query, {int limit = 10}) async =>
      _decode(await api.fsSearch(root: root, query: query, limit: limit));

  @override
  Future<JsonMap> gitBranches(String cwd) async => _decode(await api.gitBranches(cwd: cwd));

  @override
  Future<JsonMap> gitSwitch(String cwd, String branch) async => _decode(await api.gitSwitch(cwd: cwd, branch: branch));

  @override
  Future<JsonMap> gitCreateBranch(String cwd, String branch) async =>
      _decode(await api.gitCreateBranch(cwd: cwd, branch: branch));

  @override
  Future<JsonMap> gitDiff(String cwd, {String? base}) async => _decode(await api.gitDiff(cwd: cwd, base: base));

  @override
  Future<JsonMap> workspaceRecent() async => _decode(await api.workspaceRecent());

  @override
  Future<JsonMap> workspaceOpen(String path) async => _decode(await api.workspaceOpen(path: path));

  @override
  Future<JsonMap> sessionIndexList() async => _decode(await api.sessionIndexList());

  @override
  Future<JsonMap> sessionIndexUpsert(JsonMap entry) async => _decode(await api.sessionIndexUpsert(entry: jsonEncode(entry)));

  @override
  Future<JsonMap> sessionIndexRemove(String agentId, String sessionId) async =>
      _decode(await api.sessionIndexRemove(agentId: agentId, sessionId: sessionId));

  @override
  Future<JsonMap> uiStateGet() async => _decode(await api.uiStateGet());

  @override
  Future<JsonMap> uiStateSet(JsonMap patch) async => _decode(await api.uiStateSet(patch: jsonEncode(patch)));

  // ---- R4

  @override
  Future<JsonMap> fsRead(String root, String path) async => _decode(await api.fsRead(root: root, path: path));

  @override
  Stream<JsonMap> fsWatch(String root) => api.fsWatch(root: root).map(_decode);

  @override
  Future<JsonMap> fsUnwatch(String root) async => _decode(await api.fsUnwatch(root: root));

  @override
  Future<JsonMap> gitStatus(String cwd) async => _decode(await api.gitStatus(cwd: cwd));

  @override
  Future<JsonMap> terminalOpen(String cwd, {required int cols, required int rows}) async =>
      _decode(await api.terminalOpen(cwd: cwd, cols: cols, rows: rows));

  @override
  Future<JsonMap> terminalWrite(String terminalId, String data) async =>
      _decode(await api.terminalWrite(terminalId: terminalId, data: data));

  @override
  Future<JsonMap> terminalResize(String terminalId, {required int cols, required int rows}) async =>
      _decode(await api.terminalResize(terminalId: terminalId, cols: cols, rows: rows));

  @override
  Future<JsonMap> terminalKill(String terminalId) async => _decode(await api.terminalKill(terminalId: terminalId));

  @override
  Future<JsonMap> terminalClose(String terminalId) async => _decode(await api.terminalClose(terminalId: terminalId));

  @override
  Future<JsonMap> coreShutdown() async => _decode(await api.coreShutdown());

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
