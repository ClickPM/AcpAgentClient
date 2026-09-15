// ACP 线上消息的薄封装（所有者裁定 2026-09-15：手写，不做构建期生成；docs/design.md § 2）。
// 只做字段访问与判别，不做校验；合规性由 Rust 侧用 rust-sdk 类型反序列化 test/fixtures/ 的测试兜底。
// 覆盖面 = docs/acp-projection.md：15 个 session/update 变体（§ 2）、ContentBlock 5 种（§ 2.1）、
// ToolCallContent 3 种（§ 2.2）、permission 与 elicitation 请求形状（§ 3）。
// 纯 Dart，不依赖 widget；未知值一律落到 `unknown`，不抛异常。

typedef JsonMap = Map<String, dynamic>;

JsonMap? _asMap(Object? v) => v is Map ? v.cast<String, dynamic>() : null;

List<JsonMap> _asMapList(Object? v) {
  if (v is! List) return const <JsonMap>[];
  return <JsonMap>[
    for (final item in v)
      if (item is Map) item.cast<String, dynamic>(),
  ];
}

String? _asString(Object? v) => v is String ? v : null;

num? _asNum(Object? v) => v is num ? v : null;

/// 我们编译出的 15 个 `session/update` 变体；表外的一律 [unknown]（§ 8.1：Rust 侧整条反序列化失败）。
enum SessionUpdateKind {
  userMessageChunk('user_message_chunk'),
  agentMessageChunk('agent_message_chunk'),
  agentThoughtChunk('agent_thought_chunk'),
  toolCall('tool_call'),
  toolCallUpdate('tool_call_update'),
  plan('plan'),
  availableCommandsUpdate('available_commands_update'),
  currentModeUpdate('current_mode_update'),
  configOptionUpdate('config_option_update'),
  sessionInfoUpdate('session_info_update'),
  usageUpdate('usage_update'),
  planUpdate('plan_update'),
  planRemoved('plan_removed'),
  compactionUpdate('compaction_update'),
  compactionSummaryChunk('compaction_summary_chunk'),
  unknown('');

  const SessionUpdateKind(this.wire);

  /// 线上 `sessionUpdate` 判别值。
  final String wire;

  static SessionUpdateKind parse(String? wire) {
    for (final k in values) {
      if (k != unknown && k.wire == wire) return k;
    }
    return unknown;
  }

  /// 三种内容 chunk（`ContentChunk` 载荷）。
  bool get isContentChunk => this == userMessageChunk || this == agentMessageChunk || this == agentThoughtChunk;
}

/// `SessionNotification = { sessionId, update, _meta? }`。
class SessionNotificationWire {
  const SessionNotificationWire(this.json);

  final JsonMap json;

  String? get sessionId => _asString(json['sessionId']);
  JsonMap? get meta => _asMap(json['_meta']);
  SessionUpdateWire get update => SessionUpdateWire(_asMap(json['update']) ?? const <String, dynamic>{});
}

/// `update` 对象：按 [kind] 取对应字段。所有 getter 都是无副作用的字段访问。
class SessionUpdateWire {
  const SessionUpdateWire(this.json);

  final JsonMap json;

  SessionUpdateKind get kind => SessionUpdateKind.parse(_asString(json['sessionUpdate']));
  String? get rawKind => _asString(json['sessionUpdate']);
  JsonMap? get meta => _asMap(json['_meta']);

  // ---- ContentChunk（user_message_chunk / agent_message_chunk / agent_thought_chunk）与 compaction_summary_chunk
  ContentBlockWire? get content {
    final c = _asMap(json['content']);
    return c == null ? null : ContentBlockWire(c);
  }

  String? get messageId => _asString(json['messageId']);

  // ---- tool_call / tool_call_update（同一形状，update 只有 toolCallId 必填）
  ToolCallWire get toolCall => ToolCallWire(json);

  // ---- plan（稳定：整份替换）
  List<PlanEntryWire> get planEntries => _asMapList(json['entries']).map(PlanEntryWire.new).toList(growable: false);

  // ---- plan_update（unstable）
  PlanUpdateWire? get planUpdate {
    final p = _asMap(json['plan']);
    return p == null ? null : PlanUpdateWire(p);
  }

  // ---- plan_removed（unstable）
  String? get planId => _asString(json['planId']);

  // ---- available_commands_update（全量列表）
  List<AvailableCommandWire> get availableCommands =>
      _asMapList(json['availableCommands']).map(AvailableCommandWire.new).toList(growable: false);

  // ---- current_mode_update
  String? get currentModeId => _asString(json['currentModeId']);

  // ---- config_option_update（全量替换）
  List<ConfigOptionWire> get configOptions =>
      _asMapList(json['configOptions']).map(ConfigOptionWire.new).toList(growable: false);

  // ---- session_info_update（部分更新：键存在且为 null = 清空）
  bool get hasTitle => json.containsKey('title');
  String? get title => _asString(json['title']);
  bool get hasUpdatedAt => json.containsKey('updatedAt');
  String? get updatedAt => _asString(json['updatedAt']);

  // ---- usage_update（会话级上下文窗口）
  num? get used => _asNum(json['used']);
  num? get size => _asNum(json['size']);
  UsageCostWire? get cost {
    final c = _asMap(json['cost']);
    return c == null ? null : UsageCostWire(c);
  }

  // ---- compaction_update / compaction_summary_chunk（unstable）
  String? get compactionId => _asString(json['compactionId']);
  String? get compactionStatus => _asString(json['status']);
  String? get compactionSummary => _asString(json['summary']);
  String? get compactionError => _asString(json['error']);
}

/// `ContentBlock` 5 种（§ 2.1）：text / image / audio / resource_link / resource；输出方向没有能力门，全部要能呈现。
enum ContentBlockType {
  text('text'),
  image('image'),
  audio('audio'),
  resourceLink('resource_link'),
  resource('resource'),
  unknown('');

  const ContentBlockType(this.wire);

  final String wire;

  static ContentBlockType parse(String? wire) {
    for (final t in values) {
      if (t != unknown && t.wire == wire) return t;
    }
    return unknown;
  }
}

class ContentBlockWire {
  const ContentBlockWire(this.json);

  final JsonMap json;

  ContentBlockType get type => ContentBlockType.parse(_asString(json['type']));
  String? get rawType => _asString(json['type']);

  /// text
  String? get text => _asString(json['text']);

  /// image / audio：base64 数据与 mimeType；image 另有可选 uri。
  String? get data => _asString(json['data']);
  String? get mimeType => _asString(json['mimeType']);
  String? get uri => _asString(json['uri']);

  /// resource_link
  String? get name => _asString(json['name']);
  String? get title => _asString(json['title']);
  String? get description => _asString(json['description']);
  num? get size => _asNum(json['size']);

  /// resource（内嵌资源：text 或 blob 二选一）
  EmbeddedResourceWire? get resource {
    final r = _asMap(json['resource']);
    return r == null ? null : EmbeddedResourceWire(r);
  }

  JsonMap? get annotations => _asMap(json['annotations']);
  JsonMap? get meta => _asMap(json['_meta']);
}

class EmbeddedResourceWire {
  const EmbeddedResourceWire(this.json);

  final JsonMap json;

  String? get uri => _asString(json['uri']);
  String? get mimeType => _asString(json['mimeType']);
  String? get text => _asString(json['text']);
  String? get blob => _asString(json['blob']);
  bool get isText => json.containsKey('text');
  bool get isBlob => json.containsKey('blob');
}

/// `ToolCall` / `ToolCallUpdate`（§ 2.2）。`kind` 未知落 other（Rust 侧 `#[serde(other)]`），`status` 未知保留原文。
class ToolCallWire {
  const ToolCallWire(this.json);

  final JsonMap json;

  String? get toolCallId => _asString(json['toolCallId']);
  String? get title => _asString(json['title']);
  String? get name => _asString(json['name']);
  bool get hasKind => json.containsKey('kind');
  String? get kind => _asString(json['kind']);
  bool get hasStatus => json.containsKey('status');
  String? get status => _asString(json['status']);
  bool get hasContent => json.containsKey('content');
  List<ToolCallContentWire> get content => _asMapList(json['content']).map(ToolCallContentWire.new).toList(growable: false);
  bool get hasLocations => json.containsKey('locations');
  List<ToolCallLocationWire> get locations =>
      _asMapList(json['locations']).map(ToolCallLocationWire.new).toList(growable: false);
  Object? get rawInput => json['rawInput'];
  Object? get rawOutput => json['rawOutput'];
  JsonMap? get meta => _asMap(json['_meta']);

  static const List<String> knownKinds = <String>[
    'read', 'edit', 'delete', 'move', 'search', 'execute', 'think', 'fetch', 'switch_mode', 'other',
  ];
  static const List<String> knownStatuses = <String>['pending', 'in_progress', 'completed', 'failed'];
}

/// `ToolCallContent` 3 种：content / diff / terminal；未知项跳过（§ 8.3）。
enum ToolCallContentType {
  content('content'),
  diff('diff'),
  terminal('terminal'),
  unknown('');

  const ToolCallContentType(this.wire);

  final String wire;

  static ToolCallContentType parse(String? wire) {
    for (final t in values) {
      if (t != unknown && t.wire == wire) return t;
    }
    return unknown;
  }
}

class ToolCallContentWire {
  const ToolCallContentWire(this.json);

  final JsonMap json;

  ToolCallContentType get type => ToolCallContentType.parse(_asString(json['type']));
  String? get rawType => _asString(json['type']);

  /// content
  ContentBlockWire? get content {
    final c = _asMap(json['content']);
    return c == null ? null : ContentBlockWire(c);
  }

  /// diff
  String? get path => _asString(json['path']);
  String? get oldText => _asString(json['oldText']);
  String? get newText => _asString(json['newText']);

  /// terminal
  String? get terminalId => _asString(json['terminalId']);
}

class ToolCallLocationWire {
  const ToolCallLocationWire(this.json);

  final JsonMap json;

  String? get path => _asString(json['path']);
  num? get line => _asNum(json['line']);
}

/// 稳定 `plan` 的条目。
class PlanEntryWire {
  const PlanEntryWire(this.json);

  final JsonMap json;

  String? get content => _asString(json['content']);
  String? get priority => _asString(json['priority']);
  String? get status => _asString(json['status']);
}

/// unstable `plan_update.plan`：items / file / markdown 三种载荷，都带 planId。
class PlanUpdateWire {
  const PlanUpdateWire(this.json);

  final JsonMap json;

  String? get type => _asString(json['type']);
  String? get planId => _asString(json['planId']);
  List<PlanEntryWire> get entries => _asMapList(json['entries']).map(PlanEntryWire.new).toList(growable: false);
  String? get uri => _asString(json['uri']);

  /// markdown 载荷的正文字段在 schema 里叫 `content`（`PlanMarkdown { planId, content }`），不是 `markdown`。
  String? get markdown => _asString(json['content']);
}

class AvailableCommandWire {
  const AvailableCommandWire(this.json);

  final JsonMap json;

  String? get name => _asString(json['name']);
  String? get description => _asString(json['description']);

  /// `input.hint`（目前只有 unstructured 一种）。
  String? get inputHint => _asString(_asMap(json['input'])?['hint']);
}

/// `SessionConfigOption`：select（扁平或分组 options）/ boolean；未知 type 由投影层整条忽略。
class ConfigOptionWire {
  const ConfigOptionWire(this.json);

  final JsonMap json;

  String? get id => _asString(json['id']);
  String? get name => _asString(json['name']);
  String? get description => _asString(json['description']);
  String? get category => _asString(json['category']);
  String? get type => _asString(json['type']);
  Object? get currentValue => json['currentValue'];
  List<JsonMap> get options => _asMapList(json['options']);
}

class UsageCostWire {
  const UsageCostWire(this.json);

  final JsonMap json;

  num? get amount => _asNum(json['amount']);
  String? get currency => _asString(json['currency']);
}

/// `session/request_permission` params（§ 3.1）：`toolCall` 是 ToolCallUpdate，可能只有 toolCallId。
class PermissionRequestWire {
  const PermissionRequestWire(this.json);

  final JsonMap json;

  String? get sessionId => _asString(json['sessionId']);
  ToolCallWire get toolCall => ToolCallWire(_asMap(json['toolCall']) ?? const <String, dynamic>{});
  List<PermissionOptionWire> get options => _asMapList(json['options']).map(PermissionOptionWire.new).toList(growable: false);
}

class PermissionOptionWire {
  const PermissionOptionWire(this.json);

  final JsonMap json;

  String? get optionId => _asString(json['optionId']);
  String? get name => _asString(json['name']);

  /// allow_once / allow_always / reject_once / reject_always。
  String? get kind => _asString(json['kind']);
}

/// `elicitation/create` params（§ 3.2）：mode form / url；作用域 sessionScope（sessionId）或 requestScope（requestId）。
class ElicitationRequestWire {
  const ElicitationRequestWire(this.json);

  final JsonMap json;

  String? get mode => _asString(json['mode']);
  bool get isForm => mode == 'form';
  bool get isUrl => mode == 'url';

  /// 给用户看的一句话（两种模式都必填）。
  String? get message => _asString(json['message']);

  String? get sessionId => _asString(json['sessionId']);
  String? get toolCallId => _asString(json['toolCallId']);
  String? get requestId => _asString(json['requestId']);

  /// requestScope：没有会话（认证 / 配置阶段），落认证页而不是转录。
  bool get isRequestScope => sessionId == null && requestId != null;

  /// form
  JsonMap? get requestedSchema => _asMap(json['requestedSchema']);

  /// url
  String? get elicitationId => _asString(json['elicitationId']);
  String? get url => _asString(json['url']);
}

/// `acp/client_request` 事件的信封：`{agentId, requestId, method, params}`。
class ClientRequestEnvelope {
  const ClientRequestEnvelope(this.json);

  final JsonMap json;

  String? get agentId => _asString(json['agentId']);
  Object? get requestId => json['requestId'];
  String? get method => _asString(json['method']);
  JsonMap get params => _asMap(json['params']) ?? const <String, dynamic>{};

  bool get isPermission => method == 'session/request_permission';
  bool get isElicitation => method == 'elicitation/create';

  PermissionRequestWire get permission => PermissionRequestWire(params);
  ElicitationRequestWire get elicitation => ElicitationRequestWire(params);
}

/// `acp/session_update` 事件的信封：`{agentId, sessionId, update}`，`update` 是 SessionNotification 原样 JSON。
class SessionUpdateEnvelope {
  const SessionUpdateEnvelope(this.json);

  final JsonMap json;

  String? get agentId => _asString(json['agentId']);
  String? get sessionId => _asString(json['sessionId']);
  SessionNotificationWire get notification => SessionNotificationWire(_asMap(json['update']) ?? const <String, dynamic>{});
}

/// `acp/agent_state` 事件：`{agentId, state, ...}`；R0 只有 `core_ready`。
class AgentStateWire {
  const AgentStateWire(this.json);

  final JsonMap json;

  String? get agentId => _asString(json['agentId']);
  String? get state => _asString(json['state']);
  num? get droppedUpdates => _asNum(json['droppedUpdates']);
  String? get stderrTail => _asString(json['stderrTail']);
}
