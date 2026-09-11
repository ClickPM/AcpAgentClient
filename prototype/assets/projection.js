/* ACP 投影状态机。
 *
 * 刻意不碰 DOM：吃线上 JSON，吐状态。这一份是原型里唯一有参考价值的部分 ——
 * R0/R1 往 Rust + React 搬的时候搬的是这里的规则，不是这里的代码。
 *
 * 规则出处全部标在注释里，对应 docs/acp-projection.md 的小节号。
 */
(function (global) {
  'use strict';

  /* 我们编译得出来的 15 个变体（稳定 11 + sdk unstable 伞打开的 4）。
   * 不在这张表里的一律丢弃 —— 对应 §8.1：Rust 侧 SessionUpdate 没有 catch-all，
   * 整条通知反序列化失败，sdk 只记日志、连接不断、用户无感。 */
  var KNOWN_UPDATES = {
    user_message_chunk: '稳定',
    agent_message_chunk: '稳定',
    agent_thought_chunk: '稳定',
    tool_call: '稳定',
    tool_call_update: '稳定',
    plan: '稳定',
    available_commands_update: '稳定',
    current_mode_update: '稳定',
    config_option_update: '稳定',
    session_info_update: '稳定',
    usage_update: '稳定',
    plan_update: 'unstable · 需声明 plan',
    plan_removed: 'unstable · 需声明 plan',
    compaction_update: 'unstable · 需声明 session.compaction',
    compaction_summary_chunk: 'unstable · 需声明 session.compaction'
  };

  /* ToolKind 在 Rust 侧带 #[serde(other)]，未知值安全回落 other。 */
  var TOOL_KINDS = ['read', 'edit', 'delete', 'move', 'search', 'execute', 'think', 'fetch', 'switch_mode', 'other'];
  /* ToolCallStatus 没有 catch-all，未知值会让整条通知反序列化失败。 */
  var TOOL_STATUSES = ['pending', 'in_progress', 'completed', 'failed'];
  var TOOL_CONTENT_TYPES = ['content', 'diff', 'terminal'];
  var STABLE_PLAN_ID = '__stable__';

  function createState() {
    return {
      agent: null,
      clientCapabilities: null,
      session: { id: null, cwd: null, title: null, updatedAt: null },
      modes: null,
      configOptions: [],
      commands: [],
      usage: null,
      turnUsage: null,
      entries: [],
      seq: 0,
      toolCalls: {},        // toolCallId -> entry
      plans: {},            // planId -> entry
      compactions: {},      // compactionId -> entry
      terminals: {},        // terminalId -> {output, truncated, exitStatus, released}
      pending: { permission: null, elicitation: null },
      envCalls: [],         // fs/* 与 terminal/* 的调用流水，只进侧栏不进转录
      dropped: [],
      seen: {},             // sessionUpdate -> 次数
      turn: 0,
      stopReason: null
    };
  }

  function nextId(state, prefix) {
    state.seq += 1;
    return prefix + '_' + state.seq;
  }

  function push(state, entry) {
    entry.id = nextId(state, entry.kind);
    entry.at = Date.now();
    state.entries.push(entry);
    return entry;
  }

  function drop(state, reason, raw) {
    var rec = { reason: reason, raw: raw, at: Date.now() };
    state.dropped.push(rec);
    return { kind: 'dropped', reason: reason };
  }

  /* ---------- 内容块 ---------- */

  /* §8.3 VecSkipError：集合里某一项解析不了就丢那一项，其余保留。 */
  function sanitizeToolContent(list) {
    var kept = [], skipped = 0;
    (list || []).forEach(function (item) {
      if (item && TOOL_CONTENT_TYPES.indexOf(item.type) !== -1) kept.push(item);
      else skipped += 1;
    });
    return { items: kept, skipped: skipped };
  }

  /* ---------- 消息与思考：分组规则是客户端自己定的（§7.2） ---------- */

  function sameMessage(a, b) {
    if (!a && !b) return true;      // 都没有 messageId：按角色连续合并
    return !!a && !!b && a === b;   // 有 id：id 相同才是同一条
  }

  function appendChunk(state, kind, role, u) {
    var last = state.entries[state.entries.length - 1];
    var mid = u.messageId || null;
    if (last && last.kind === kind && last.role === role && sameMessage(last.messageId, mid)) {
      last.blocks.push(u.content);
      return last;
    }
    return push(state, { kind: kind, role: role, messageId: mid, blocks: [u.content] });
  }

  /* ---------- 工具调用：合并语义见 §2.2，集合是替换不是追加 ---------- */

  function newToolCall(state, id, title) {
    var entry = push(state, {
      kind: 'tool_call',
      call: {
        toolCallId: id,
        title: title || '(未命名工具调用)',
        name: null,
        kind: 'other',
        status: 'pending',
        content: [],
        locations: [],
        rawInput: null,
        rawOutput: null
      },
      localStatus: null,   // §7.1 协议里没有 cancelled，这是客户端本地态
      skipped: 0,
      kindFellBack: false,
      createdFromUpdate: false
    });
    state.toolCalls[id] = entry;
    return entry;
  }

  function mergeToolCall(entry, fields) {
    var call = entry.call;
    if (fields.title !== undefined) call.title = fields.title;
    if (fields.name !== undefined) call.name = fields.name;
    if (fields.kind !== undefined) {
      if (TOOL_KINDS.indexOf(fields.kind) === -1) { call.kind = 'other'; entry.kindFellBack = fields.kind; }
      else call.kind = fields.kind;
    }
    if (fields.status !== undefined) call.status = fields.status;
    if (fields.content !== undefined) {
      var r = sanitizeToolContent(fields.content);
      call.content = r.items;            // 替换，不是追加
      entry.skipped += r.skipped;
    }
    if (fields.locations !== undefined) call.locations = fields.locations; // 同上
    if (fields.rawInput !== undefined) call.rawInput = fields.rawInput;
    if (fields.rawOutput !== undefined) call.rawOutput = fields.rawOutput;
  }

  /* ---------- 计划 ---------- */

  function upsertPlan(state, planId, patch) {
    var entry = state.plans[planId];
    if (!entry) {
      entry = push(state, {
        kind: 'plan', planId: planId, unstable: planId !== STABLE_PLAN_ID,
        type: 'items', entries: [], uri: null, markdown: null, removed: false
      });
      state.plans[planId] = entry;
    }
    Object.keys(patch).forEach(function (k) { entry[k] = patch[k]; });
    return entry;
  }

  /* ---------- 压缩 ---------- */

  function upsertCompaction(state, id, patch) {
    var entry = state.compactions[id];
    if (!entry) {
      entry = push(state, { kind: 'compaction', compactionId: id, status: 'in_progress', summary: [], error: null });
      state.compactions[id] = entry;
    }
    Object.keys(patch).forEach(function (k) { entry[k] = patch[k]; });
    return entry;
  }

  /* ---------- session/update 的总入口 ---------- */

  function applyUpdate(state, notification, raw) {
    var u = notification.update;
    if (!u || typeof u.sessionUpdate !== 'string') return drop(state, 'update 缺少 sessionUpdate 判别式', raw);

    var tag = u.sessionUpdate;
    if (!KNOWN_UPDATES[tag]) {
      return drop(state, '未知的 sessionUpdate: ' + tag + ' —— 我们编译不出这个变体，整条通知被丢弃', raw);
    }

    // 未知 ToolCallStatus 会让整条通知在 Rust 侧反序列化失败，这里照同样口径处理。
    if ((tag === 'tool_call' || tag === 'tool_call_update') &&
        u.status !== undefined && TOOL_STATUSES.indexOf(u.status) === -1) {
      return drop(state, '未知的 ToolCallStatus: ' + u.status + ' —— ToolCallStatus 没有 catch-all，整条通知丢弃', raw);
    }

    state.seen[tag] = (state.seen[tag] || 0) + 1;

    switch (tag) {
      case 'user_message_chunk':
        return { kind: 'entry', entry: appendChunk(state, 'message', 'user', u) };
      case 'agent_message_chunk':
        return { kind: 'entry', entry: appendChunk(state, 'message', 'agent', u) };
      case 'agent_thought_chunk':
        return { kind: 'entry', entry: appendChunk(state, 'thought', 'agent', u) };

      case 'tool_call': {
        var e = state.toolCalls[u.toolCallId] || newToolCall(state, u.toolCallId, u.title);
        mergeToolCall(e, u);
        return { kind: 'entry', entry: e };
      }
      case 'tool_call_update': {
        var t = state.toolCalls[u.toolCallId];
        if (!t) {                      // §7.4 update 可以先于 tool_call 到，凭空建卡
          t = newToolCall(state, u.toolCallId, u.title);
          t.createdFromUpdate = true;
        }
        mergeToolCall(t, u);
        return { kind: 'entry', entry: t };
      }

      case 'plan':                     // 稳定变体：整份替换，没有 id
        return { kind: 'entry', entry: upsertPlan(state, STABLE_PLAN_ID, { type: 'items', entries: u.entries || [] }) };
      case 'plan_update': {
        var p = u.plan || {};
        var patch = { type: p.type || 'items' };
        if (p.type === 'file') patch.uri = p.uri;
        else if (p.type === 'markdown') patch.markdown = p.content;
        else patch.entries = p.entries || [];
        return { kind: 'entry', entry: upsertPlan(state, p.planId, patch) };
      }
      case 'plan_removed':
        // 真实客户端直接移除这张卡；原型留着并打标，方便看见这条更新确实生效了。
        return { kind: 'entry', entry: upsertPlan(state, u.planId, { removed: true }) };

      case 'compaction_update': {
        var patchC = { status: u.status };
        if (u.summary !== undefined) patchC.summary = u.summary || [];  // 全量替换
        if (u.error !== undefined) patchC.error = u.error;
        return { kind: 'entry', entry: upsertCompaction(state, u.compactionId, patchC) };
      }
      case 'compaction_summary_chunk': {
        var c = upsertCompaction(state, u.compactionId, {});
        c.summary.push(u.content);
        return { kind: 'entry', entry: c };
      }

      case 'available_commands_update':
        state.commands = u.availableCommands || [];    // 全量替换
        return { kind: 'state' };
      case 'current_mode_update':
        if (state.modes) state.modes.currentModeId = u.currentModeId;
        return { kind: 'state' };
      case 'config_option_update':
        state.configOptions = u.configOptions || [];   // 全量替换
        return { kind: 'state' };
      case 'session_info_update':
        if (u.title !== undefined) state.session.title = u.title;        // null = 清空
        if (u.updatedAt !== undefined) state.session.updatedAt = u.updatedAt;
        return { kind: 'state' };
      case 'usage_update':
        state.usage = { used: u.used, size: u.size, cost: u.cost || null };
        return { kind: 'state' };
    }
    return drop(state, '落到了不该落的分支: ' + tag, raw);
  }

  /* ---------- agent -> client 的请求 ---------- */

  function applyClientRequest(state, msg) {
    var p = msg.params || {};
    switch (msg.method) {
      case 'session/request_permission': {
        var entry = push(state, {
          kind: 'permission',
          requestId: msg.id,
          toolCallId: (p.toolCall || {}).toolCallId || null,
          options: p.options || [],
          status: 'pending',
          chosen: null
        });
        state.pending.permission = entry;
        return { kind: 'entry', entry: entry, blocking: true };
      }
      case 'elicitation/create': {
        var el = push(state, {
          kind: 'elicitation',
          requestId: msg.id,
          mode: p.mode,
          // §3.2 作用域二选一：会话内，或挂在某个 requestId 上（此时没有 sessionId）
          scope: p.sessionId ? { type: 'session', sessionId: p.sessionId, toolCallId: p.toolCallId || null }
                             : { type: 'request', requestId: p.requestId },
          schema: p.requestedSchema || null,
          url: p.url || null,
          elicitationId: p.elicitationId || null,
          status: 'pending',
          values: null
        });
        state.pending.elicitation = el;
        return { kind: 'entry', entry: el, blocking: true };
      }
      case 'fs/read_text_file':
      case 'fs/write_text_file':
        state.envCalls.push({ method: msg.method, path: p.path, at: Date.now() });
        return { kind: 'env' };
      case 'terminal/create':
        state.envCalls.push({ method: msg.method, path: p.command + ' ' + (p.args || []).join(' '), at: Date.now() });
        return { kind: 'env', pendingTerminal: p };
      case 'terminal/output':
      case 'terminal/wait_for_exit':
      case 'terminal/kill':
      case 'terminal/release':
        state.envCalls.push({ method: msg.method, path: p.terminalId, at: Date.now() });
        if (msg.method === 'terminal/release') {
          var term = state.terminals[p.terminalId];
          // §4 释放之后输出必须继续留在工具卡上，所以只打标不清空。
          if (term) term.released = true;
        }
        return { kind: 'env' };
    }
    return { kind: 'env' };
  }

  /* ---------- 终端：输出不是协议消息（design.md 的 acp/terminal_output） ---------- */

  function ensureTerminal(state, id, byteLimit) {
    if (!state.terminals[id]) {
      state.terminals[id] = { id: id, output: '', truncated: false, exitStatus: null, released: false, byteLimit: byteLimit || 65536 };
    }
    return state.terminals[id];
  }

  function appendTerminalOutput(state, id, chunk) {
    var t = ensureTerminal(state, id);
    t.output += chunk;
    if (t.output.length > t.byteLimit) {
      // §4 截断必须落在字符边界上，JS 的字符串切片天然满足。
      t.output = t.output.slice(t.output.length - t.byteLimit);
      t.truncated = true;
    }
    return t;
  }

  /* ---------- 回合边界：协议不给，客户端自己切（§7.7） ---------- */

  function startTurn(state, promptBlocks) {
    state.turn += 1;
    state.stopReason = null;
    state.turnUsage = null;
    return push(state, { kind: 'turn', n: state.turn, prompt: promptBlocks || [], stopReason: null, usage: null });
  }

  function endTurn(state, result) {
    state.stopReason = result.stopReason || null;
    state.turnUsage = result.usage || null;
    for (var i = state.entries.length - 1; i >= 0; i--) {
      if (state.entries[i].kind === 'turn') {
        state.entries[i].stopReason = state.stopReason;
        state.entries[i].usage = state.turnUsage;
        break;
      }
    }
  }

  /* ---------- 取消：协议没有 cancelled 工具状态，全靠本地态（§7.1） ---------- */

  function cancelTurn(state) {
    var touched = 0;
    state.entries.forEach(function (e) {
      if (e.kind === 'tool_call' && !e.localStatus &&
          (e.call.status === 'pending' || e.call.status === 'in_progress')) {
        e.localStatus = 'cancelled';
        touched += 1;
      }
    });
    // 规范硬要求：发出 session/cancel 后，挂起的权限请求 MUST 以 cancelled 回应。
    var answered = null;
    if (state.pending.permission) {
      state.pending.permission.status = 'cancelled';
      answered = state.pending.permission.requestId;
      state.pending.permission = null;
    }
    state.stopReason = 'cancelled';
    return { toolCalls: touched, permissionRequestId: answered };
  }

  function answerPermission(state, option) {
    var entry = state.pending.permission;
    if (!entry) return null;
    entry.status = 'answered';
    entry.chosen = option;
    state.pending.permission = null;
    return { jsonrpc: '2.0', id: entry.requestId, result: { outcome: { outcome: 'selected', optionId: option.optionId } } };
  }

  function answerElicitation(state, action, content) {
    var entry = state.pending.elicitation;
    if (!entry) return null;
    entry.status = action;
    entry.values = content || null;
    state.pending.elicitation = null;
    var result = action === 'accept' ? { action: 'accept', content: content || {} } : { action: action };
    return { jsonrpc: '2.0', id: entry.requestId, result: result };
  }

  /* ---------- 连接级 ---------- */

  function applyInitializeResult(state, result) {
    state.agent = {
      name: (result.agentInfo || {}).name || '(未报名字)',
      title: (result.agentInfo || {}).title || null,
      version: (result.agentInfo || {}).version || '?',
      protocolVersion: result.protocolVersion,
      capabilities: result.agentCapabilities || {},
      authMethods: result.authMethods || []
    };
  }

  function applyNewSessionResult(state, result) {
    state.session.id = result.sessionId;
    if (result.modes) state.modes = result.modes;
    if (result.configOptions) state.configOptions = result.configOptions;
  }

  global.AcpProjection = {
    KNOWN_UPDATES: KNOWN_UPDATES,
    STABLE_PLAN_ID: STABLE_PLAN_ID,
    createState: createState,
    applyUpdate: applyUpdate,
    applyClientRequest: applyClientRequest,
    applyInitializeResult: applyInitializeResult,
    applyNewSessionResult: applyNewSessionResult,
    ensureTerminal: ensureTerminal,
    appendTerminalOutput: appendTerminalOutput,
    startTurn: startTurn,
    endTurn: endTurn,
    cancelTurn: cancelTurn,
    answerPermission: answerPermission,
    answerElicitation: answerElicitation
  };
})(window);
