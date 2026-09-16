// 桥的 Dart 端薄封装：加载 cdylib、订阅六条事件流、把 JSON 字符串解成 Map 交给投影层。
// 这是前端唯一碰 lib/bridge/ 生成物的地方；投影层与 widget 只消费解码后的 JSON（docs/design.md § 3）。
// 核心抛出的 `BridgeError {code, message}` 在这里翻成 [CoreCommandError]，组合根按 `code` 分流（`auth_required` → 认证页，
// `node_missing` → 受管 Node 提示），不 import 生成物。

import 'dart:async';
import 'dart:convert';

import '../bridge/api.dart' as api;
import '../bridge/frb_generated.dart';
import '../projection/wire.dart';

/// 六条事件流的名字（与 docs/design.md § 3 一致）。
enum CoreEvent {
  sessionUpdate('acp/session_update'),
  clientRequest('acp/client_request'),
  agentState('acp/agent_state'),
  terminalOutput('acp/terminal_output'),
  traffic('acp/traffic'),
  registryProgress('registry/progress');

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

/// 核心命令失败：`code` 是 `CoreError::code()` 的稳定短码（`auth_required` / `node_missing` / `cancelled` / `registry` / …）。
class CoreCommandError implements Exception {
  const CoreCommandError(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// 记进 `lastError` 的一行文案：核心错误带上短码，其余照 `toString()`。
String describeError(Object e) => e is CoreCommandError ? '${e.code}: ${e.message}' : e.toString();

/// 组合根用到的核心接口（事件订阅 + 命令面）。抽出来是为了让 `lib/app/` 的接线能在
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
  Future<JsonMap> terminalAuthRun(String agentId, String methodId, String cwd);
  Future<JsonMap> terminalWrite(String terminalId, String data);
  Future<JsonMap> terminalClose(String terminalId);
  Future<JsonMap> agentSettingsGet();
  Future<JsonMap> agentSettingsSet(String agentId, JsonMap server);
  Future<JsonMap> agentSettingsRemove(String agentId);
  Future<JsonMap> agentSettingsImportZed();
  Future<JsonMap> registryList();
  Future<JsonMap> registryRefresh({bool force});
  Future<JsonMap> registryInstall(String agentId);
  Future<JsonMap> registryCancelInstall(String agentId);
  Future<JsonMap> registryRemove(String agentId);
  Future<JsonMap> nodeStatus();
  Future<JsonMap> nodeDownload();
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
  Future<JsonMap> terminalResize(String terminalId, {required int cols, required int rows});
  Future<JsonMap> terminalKill(String terminalId);
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

  /// 全部事件（六条流合一，按到达顺序）。
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
      api.registryProgressStream().listen((s) => _push(CoreEvent.registryProgress, s)),
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

  /// `core_init(data_dir)` → `{dataDir, coreVersion, logPath}`。
  @override
  Future<JsonMap> init(String dataDir) async {
    subscribe();
    return _run(() => api.coreInit(dataDir: dataDir));
  }

  /// `ping(echo)` → `{pong, sequence, coreVersion}`。
  Future<JsonMap> ping(String echo) => _run(() => api.ping(echo: echo));

  int get droppedEventCount => api.droppedEventCount().toInt();

  // ---- 命令（docs/design.md § 3。入参与返回都是 JSON 字符串，这里只做 decode）

  @override
  Future<JsonMap> agentConnect(String agentId, {String? cwd}) => _run(() => api.agentConnect(agentId: agentId, cwd: cwd));

  @override
  Future<JsonMap> agentDisconnect(String agentId) => _run(() => api.agentDisconnect(agentId: agentId));

  @override
  Future<JsonMap> sessionNew(String agentId, String cwd) => _run(() => api.sessionNew(agentId: agentId, cwd: cwd));

  @override
  Future<JsonMap> sessionPrompt(String agentId, String sessionId, List<Object?> prompt) =>
      _run(() => api.sessionPrompt(agentId: agentId, sessionId: sessionId, prompt: jsonEncode(prompt)));

  @override
  Future<JsonMap> sessionCancel(String agentId, String sessionId) => _run(() => api.sessionCancel(agentId: agentId, sessionId: sessionId));

  @override
  Future<JsonMap> sessionSetConfigOption(String agentId, String sessionId, String configId, JsonMap value) =>
      _run(() => api.sessionSetConfigOption(agentId: agentId, sessionId: sessionId, configId: configId, value: jsonEncode(value)));

  @override
  Future<JsonMap> sessionSetMode(String agentId, String sessionId, String modeId) =>
      _run(() => api.sessionSetMode(agentId: agentId, sessionId: sessionId, modeId: modeId));

  @override
  Future<JsonMap> acpRespond(String agentId, String requestId, JsonMap response) =>
      _run(() => api.acpRespond(agentId: agentId, requestId: requestId, response: jsonEncode(response)));

  @override
  Future<JsonMap> authenticate(String agentId, String methodId) => _run(() => api.authenticate(agentId: agentId, methodId: methodId));

  @override
  Future<JsonMap> terminalAuthRun(String agentId, String methodId, String cwd) =>
      _run(() => api.terminalAuthRun(agentId: agentId, methodId: methodId, cwd: cwd));

  @override
  Future<JsonMap> terminalWrite(String terminalId, String data) => _run(() => api.terminalWrite(terminalId: terminalId, data: data));

  @override
  Future<JsonMap> terminalClose(String terminalId) => _run(() => api.terminalClose(terminalId: terminalId));

  @override
  Future<JsonMap> agentSettingsGet() => _run(api.agentSettingsGet);

  @override
  Future<JsonMap> agentSettingsSet(String agentId, JsonMap server) =>
      _run(() => api.agentSettingsSet(agentId: agentId, server: jsonEncode(server)));

  @override
  Future<JsonMap> agentSettingsRemove(String agentId) => _run(() => api.agentSettingsRemove(agentId: agentId));

  @override
  Future<JsonMap> agentSettingsImportZed() => _run(api.agentSettingsImportZed);

  @override
  Future<JsonMap> registryList() => _run(api.registryList);

  @override
  Future<JsonMap> registryRefresh({bool force = false}) => _run(() => api.registryRefresh(force: force));

  @override
  Future<JsonMap> registryInstall(String agentId) => _run(() => api.registryInstall(agentId: agentId));

  @override
  Future<JsonMap> registryCancelInstall(String agentId) => _run(() => api.registryCancelInstall(agentId: agentId));

  @override
  Future<JsonMap> registryRemove(String agentId) => _run(() => api.registryRemove(agentId: agentId));

  @override
  Future<JsonMap> nodeStatus() => _run(api.nodeStatus);

  @override
  Future<JsonMap> nodeDownload() => _run(api.nodeDownload);

  @override
  Future<JsonMap> fsListDir(String root, String path) => _run(() => api.fsListDir(root: root, path: path));

  @override
  Future<JsonMap> fsSearch(String root, String query, {int limit = 10}) => _run(() => api.fsSearch(root: root, query: query, limit: limit));

  @override
  Future<JsonMap> gitBranches(String cwd) => _run(() => api.gitBranches(cwd: cwd));

  @override
  Future<JsonMap> gitSwitch(String cwd, String branch) => _run(() => api.gitSwitch(cwd: cwd, branch: branch));

  @override
  Future<JsonMap> gitCreateBranch(String cwd, String branch) => _run(() => api.gitCreateBranch(cwd: cwd, branch: branch));

  @override
  Future<JsonMap> gitDiff(String cwd, {String? base}) => _run(() => api.gitDiff(cwd: cwd, base: base));

  @override
  Future<JsonMap> workspaceRecent() => _run(api.workspaceRecent);

  @override
  Future<JsonMap> workspaceOpen(String path) => _run(() => api.workspaceOpen(path: path));

  @override
  Future<JsonMap> sessionIndexList() => _run(api.sessionIndexList);

  @override
  Future<JsonMap> sessionIndexUpsert(JsonMap entry) => _run(() => api.sessionIndexUpsert(entry: jsonEncode(entry)));

  @override
  Future<JsonMap> sessionIndexRemove(String agentId, String sessionId) =>
      _run(() => api.sessionIndexRemove(agentId: agentId, sessionId: sessionId));

  @override
  Future<JsonMap> uiStateGet() => _run(api.uiStateGet);

  @override
  Future<JsonMap> uiStateSet(JsonMap patch) => _run(() => api.uiStateSet(patch: jsonEncode(patch)));

  // ---- R4：文件面板 / 终端 / 退出收尾

  @override
  Future<JsonMap> fsRead(String root, String path) => _run(() => api.fsRead(root: root, path: path));

  @override
  Stream<JsonMap> fsWatch(String root) => api.fsWatch(root: root).map(_decodeObject);

  @override
  Future<JsonMap> fsUnwatch(String root) => _run(() => api.fsUnwatch(root: root));

  @override
  Future<JsonMap> gitStatus(String cwd) => _run(() => api.gitStatus(cwd: cwd));

  @override
  Future<JsonMap> terminalOpen(String cwd, {required int cols, required int rows}) =>
      _run(() => api.terminalOpen(cwd: cwd, cols: cols, rows: rows));

  @override
  Future<JsonMap> terminalResize(String terminalId, {required int cols, required int rows}) =>
      _run(() => api.terminalResize(terminalId: terminalId, cols: cols, rows: rows));

  @override
  Future<JsonMap> terminalKill(String terminalId) => _run(() => api.terminalKill(terminalId: terminalId));

  @override
  Future<JsonMap> coreShutdown() => _run(api.coreShutdown);

  /// 跑一条命令：解码 JSON；核心的 `BridgeError` 翻成 [CoreCommandError]（组合根按 `code` 分流，不碰生成物）。
  Future<JsonMap> _run(Future<String> Function() call) async {
    final String raw;
    try {
      raw = await call();
    } on api.BridgeError catch (e) {
      throw CoreCommandError(e.code, e.message);
    }
    return _decodeObject(raw);
  }

  /// 流命令的每一条（`fs_watch`）与 `_run` 共用的解码。
  static JsonMap _decodeObject(String raw) {
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
