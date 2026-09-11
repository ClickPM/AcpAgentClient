/* 回放器与渲染。样式与交互都不作数，只为把 projection.js 的状态看清楚。 */
(function (global) {
  'use strict';

  var P = global.AcpProjection;
  var FIXTURE = global.ACP_FIXTURE;

  var state = P.createState();
  var traffic = [];
  var cursor = 0;
  var timer = null;
  var speed = 1;
  var waiting = null;      // 'permission' | 'elicitation' | null
  var finished = false;
  var pendingTerminalReq = null;

  var $ = function (id) { return document.getElementById(id); };

  /* ---------------- 工具 ---------------- */

  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  var SECRET_RE = /^(authorization|api[-_]?key|apikey|token|secret|password|bearer|.*_token|.*_key)$/i;

  /* CLAUDE.md 规则 8：流量面板对密钥类字段打码。 */
  function redact(value) {
    if (Array.isArray(value)) return value.map(redact);
    if (value && typeof value === 'object') {
      var out = {};
      Object.keys(value).forEach(function (k) {
        var v = value[k];
        if (SECRET_RE.test(k) && typeof v === 'string') out[k] = '***';
        else if (k === 'name' && typeof v === 'string' && SECRET_RE.test(v) && typeof value.value === 'string') out[k] = v;
        else out[k] = redact(v);
      });
      // { name: "Authorization", value: "..." } 这种成对形状要按 name 判断 value
      if (typeof out.name === 'string' && SECRET_RE.test(out.name) && typeof out.value === 'string') out.value = '***';
      return out;
    }
    return value;
  }

  function json(v) { return JSON.stringify(redact(v), null, 2); }

  /* 极简行级 diff，够看即可 */
  function lineDiff(oldText, newText) {
    var a = (oldText == null ? '' : oldText).split('\n');
    var b = (newText == null ? '' : newText).split('\n');
    var m = [], i, j;
    for (i = 0; i <= a.length; i++) { m[i] = []; for (j = 0; j <= b.length; j++) m[i][j] = 0; }
    for (i = a.length - 1; i >= 0; i--) {
      for (j = b.length - 1; j >= 0; j--) {
        m[i][j] = a[i] === b[j] ? m[i + 1][j + 1] + 1 : Math.max(m[i + 1][j], m[i][j + 1]);
      }
    }
    var rows = []; i = 0; j = 0;
    while (i < a.length && j < b.length) {
      if (a[i] === b[j]) { rows.push(['ctx', a[i]]); i++; j++; }
      else if (m[i + 1][j] >= m[i][j + 1]) { rows.push(['del', a[i]]); i++; }
      else { rows.push(['add', b[j]]); j++; }
    }
    while (i < a.length) { rows.push(['del', a[i++]]); }
    while (j < b.length) { rows.push(['add', b[j++]]); }
    return rows;
  }

  /* ---------------- 流量面板 ---------------- */

  function addTraffic(rec) {
    traffic.push(rec);
    if (traffic.length > 400) traffic.shift();
  }

  function renderTraffic() {
    var html = traffic.map(function (r, idx) {
      var cls = 'tr-' + r.dir + (r.dropped ? ' tr-dropped' : '');
      var arrow = r.dir === 'out' ? '→' : r.dir === 'in' ? '←' : r.dir === 'stderr' ? '!' : '·';
      var kindLabel = r.dir === 'out' ? '发出' : r.dir === 'in' ? '收到' : r.dir === 'stderr' ? 'stderr' : 'local';
      return '' +
        '<details class="traffic-row ' + cls + '">' +
          '<summary>' +
            '<span class="tr-arrow">' + arrow + '</span>' +
            '<span class="tr-method">' + esc(r.tag) + '</span>' +
            (r.id !== undefined && r.id !== null ? '<span class="tr-id">#' + esc(r.id) + '</span>' : '') +
            '<span class="tr-dir">' + kindLabel + '</span>' +
            (r.dropped ? '<span class="tr-badge danger">丢弃</span>' : '') +
          '</summary>' +
          (r.note ? '<p class="tr-note">' + esc(r.note) + '</p>' : '') +
          (r.dropped ? '<p class="tr-note danger">' + esc(r.dropped) + '</p>' : '') +
          '<pre>' + esc(r.body) + '</pre>' +
        '</details>';
    }).join('');
    var el = $('traffic');
    var atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 60;
    el.innerHTML = html;
    if (atBottom) el.scrollTop = el.scrollHeight;
    $('traffic-count').textContent = traffic.length;
  }

  /* ---------------- 内容块 ---------------- */

  function renderBlock(b) {
    if (!b || !b.type) return '';
    switch (b.type) {
      case 'text':
        return '<div class="blk-text">' + esc(b.text) + '</div>';
      case 'image':
        return '<figure class="blk-media"><img alt="image content block" src="data:' + esc(b.mimeType) + ';base64,' + esc(b.data) + '">' +
               '<figcaption>image · ' + esc(b.mimeType) + (b.uri ? ' · ' + esc(b.uri) : '') + '</figcaption></figure>';
      case 'audio':
        return '<div class="blk-file"><span class="blk-file-kind">audio</span>' +
               '<span class="blk-file-name">' + esc(b.mimeType) + '</span>' +
               '<span class="blk-file-meta">base64 ' + esc(b.data ? b.data.length : 0) + ' 字节 · 原型不解码</span></div>';
      case 'resource_link':
        return '<div class="blk-file"><span class="blk-file-kind">link</span>' +
               '<span class="blk-file-name">' + esc(b.title || b.name) + '</span>' +
               '<span class="blk-file-meta">' + esc(b.uri) + (b.size ? ' · ' + esc(b.size) + ' 字节' : '') + '</span></div>';
      case 'resource': {
        var r = b.resource || {};
        var body = r.text !== undefined ? r.text : '(blob，' + (r.blob ? r.blob.length : 0) + ' 字节 base64)';
        return '<details class="blk-resource"><summary><span class="blk-file-kind">resource</span>' +
               esc(r.uri) + (r.mimeType ? ' · ' + esc(r.mimeType) : '') + '</summary><pre>' + esc(body) + '</pre></details>';
      }
      default:
        return '<div class="blk-unknown">未知内容块类型：' + esc(b.type) + '</div>';
    }
  }

  function renderBlocks(list) { return (list || []).map(renderBlock).join(''); }

  /* ---------------- 转录条目 ---------------- */

  var STATUS_LABEL = { pending: '等待中', in_progress: '进行中', completed: '完成', failed: '失败', cancelled: '已取消' };

  function renderToolContent(item) {
    if (item.type === 'content') return '<div class="tc-content">' + renderBlock(item.content) + '</div>';
    if (item.type === 'diff') {
      var rows = lineDiff(item.oldText, item.newText).map(function (r) {
        var sign = r[0] === 'add' ? '+' : r[0] === 'del' ? '-' : ' ';
        return '<div class="diff-line diff-' + r[0] + '"><span class="diff-sign">' + sign + '</span>' + esc(r[1]) + '</div>';
      }).join('');
      return '<div class="tc-diff"><header>' + esc(item.path) + (item.oldText == null ? ' · 新文件' : '') + '</header>' + rows + '</div>';
    }
    if (item.type === 'terminal') {
      var t = state.terminals[item.terminalId];
      if (!t) return '<div class="tc-term"><header>终端 ' + esc(item.terminalId) + '（尚未创建）</header></div>';
      var badges = '';
      if (t.truncated) badges += '<span class="pill warn">已截断</span>';
      if (t.exitStatus) badges += '<span class="pill ' + (t.exitStatus.exitCode === 0 ? 'ok' : 'danger') + '">退出码 ' + esc(t.exitStatus.exitCode) + '</span>';
      if (t.released) badges += '<span class="pill">已释放 · 输出保留</span>';
      return '<div class="tc-term"><header>终端 ' + esc(item.terminalId) + badges + '</header>' +
             '<pre class="term-out">' + esc(t.output) + '</pre></div>';
    }
    return '';
  }

  function renderToolCall(e) {
    var c = e.call;
    var status = e.localStatus || c.status;
    var tags = '';
    if (e.createdFromUpdate) tags += '<span class="pill info" title="此前没有 tool_call，凭一条 update 建的卡">凭空建卡</span>';
    if (e.kindFellBack) tags += '<span class="pill warn" title="未知 ToolKind 回落到 other">kind=' + esc(e.kindFellBack) + ' → other</span>';
    if (e.skipped) tags += '<span class="pill warn" title="content 里有解析不了的项，只丢那一项">跳过 ' + e.skipped + ' 项</span>';
    if (e.localStatus) tags += '<span class="pill danger" title="协议里没有 cancelled 工具状态，这是客户端本地态">本地态</span>';

    var locs = (c.locations || []).map(function (l) {
      return '<code class="loc">' + esc(l.path) + (l.line ? ':' + l.line : '') + '</code>';
    }).join('');

    var raw = '';
    if (c.rawInput || c.rawOutput) {
      raw = '<details class="tc-raw"><summary>rawInput / rawOutput</summary><pre>' +
            esc(JSON.stringify({ rawInput: c.rawInput, rawOutput: c.rawOutput }, null, 2)) + '</pre></details>';
    }

    return '<article class="entry tool ' + status + '">' +
      '<header class="tool-head">' +
        '<span class="kind-pill k-' + esc(c.kind) + '">' + esc(c.kind) + '</span>' +
        '<span class="tool-title">' + esc(c.title) + '</span>' +
        '<span class="status-pill s-' + status + '">' + (STATUS_LABEL[status] || status) + '</span>' +
      '</header>' +
      (tags ? '<div class="tool-tags">' + tags + '</div>' : '') +
      (locs ? '<div class="tool-locs">' + locs + '</div>' : '') +
      (c.content || []).map(renderToolContent).join('') +
      raw +
      '<footer class="tool-foot"><code>' + esc(c.toolCallId) + '</code></footer>' +
    '</article>';
  }

  function renderPlan(e) {
    var head = e.planId === P.STABLE_PLAN_ID
      ? '计划 <span class="pill">稳定 plan · 整份替换</span>'
      : '计划 <code>' + esc(e.planId) + '</code> <span class="pill info">plan_update · unstable</span>';
    if (e.removed) head += '<span class="pill danger">已移除</span>';
    var body;
    if (e.type === 'file') body = '<div class="blk-file"><span class="blk-file-kind">file</span><span class="blk-file-name">' + esc(e.uri) + '</span></div>';
    else if (e.type === 'markdown') body = '<pre class="plan-md">' + esc(e.markdown) + '</pre>';
    else body = '<ol class="plan-list">' + (e.entries || []).map(function (p) {
      return '<li class="pe pe-' + esc(p.status) + '"><span class="pe-dot"></span>' +
             '<span class="pe-text">' + esc(p.content) + '</span>' +
             '<span class="pe-prio p-' + esc(p.priority) + '">' + esc(p.priority) + '</span></li>';
    }).join('') + '</ol>';
    return '<article class="entry plan' + (e.removed ? ' removed' : '') + '"><header>' + head + '</header>' + body + '</article>';
  }

  function renderCompaction(e) {
    return '<article class="entry compaction"><header>上下文压缩 <code>' + esc(e.compactionId) + '</code>' +
      '<span class="pill info">unstable · 需声明 session.compaction</span>' +
      '<span class="status-pill s-' + esc(e.status === 'completed' ? 'completed' : e.status === 'failed' ? 'failed' : 'in_progress') + '">' + esc(e.status) + '</span>' +
      '</header>' +
      (e.error ? '<p class="danger">' + esc(e.error) + '</p>' : '') +
      '<div class="compaction-summary">' + (e.summary.length ? renderBlocks(e.summary) : '<span class="muted">保留摘要流式写入中…</span>') + '</div>' +
    '</article>';
  }

  function renderPermission(e) {
    var body;
    if (e.status === 'pending') {
      body = '<div class="perm-options">' + e.options.map(function (o, i) {
        return '<button class="perm-btn k-' + esc(o.kind) + '" data-perm="' + i + '">' + esc(o.name) +
               '<span class="perm-kind">' + esc(o.kind) + '</span></button>';
      }).join('') + '</div><p class="muted">流会停在这里，直到你选一个 —— 这就是 ACP 的阻塞语义。</p>';
    } else if (e.status === 'cancelled') {
      body = '<p class="danger">本轮已取消，按规范以 <code>{"outcome":"cancelled"}</code> 回应。</p>';
    } else {
      body = '<p>已选择 <strong>' + esc(e.chosen.name) + '</strong>（<code>' + esc(e.chosen.optionId) + '</code>）</p>';
    }
    return '<article class="entry permission"><header>权限请求' +
      (e.toolCallId ? ' <code>' + esc(e.toolCallId) + '</code>' : '') +
      '<span class="pill">session/request_permission</span></header>' + body + '</article>';
  }

  function renderElicitationField(key, schema, required) {
    var label = '<label class="fld"><span class="fld-name">' + esc(schema.title || key) +
      (required ? ' <em class="req">必填</em>' : '') + '</span>' +
      (schema.description ? '<span class="fld-desc">' + esc(schema.description) + '</span>' : '');
    var input;
    if (schema.type === 'string' && (schema.oneOf || schema.enum)) {
      var opts = schema.oneOf
        ? schema.oneOf.map(function (o) { return '<option value="' + esc(o.const) + '">' + esc(o.title) + '</option>'; })
        : schema.enum.map(function (v) { return '<option value="' + esc(v) + '">' + esc(v) + '</option>'; });
      input = '<select data-fld="' + esc(key) + '" data-type="string">' + opts.join('') + '</select>';
    } else if (schema.type === 'string') {
      input = '<input type="text" data-fld="' + esc(key) + '" data-type="string"' +
              (schema.maxLength ? ' maxlength="' + schema.maxLength + '"' : '') +
              (schema.default ? ' value="' + esc(schema.default) + '"' : '') + '>';
    } else if (schema.type === 'number' || schema.type === 'integer') {
      input = '<input type="number" data-fld="' + esc(key) + '" data-type="' + schema.type + '"' +
              (schema.minimum !== undefined ? ' min="' + schema.minimum + '"' : '') +
              (schema.maximum !== undefined ? ' max="' + schema.maximum + '"' : '') +
              (schema.default !== undefined ? ' value="' + schema.default + '"' : '') + '>';
    } else if (schema.type === 'boolean') {
      input = '<input type="checkbox" data-fld="' + esc(key) + '" data-type="boolean"' + (schema.default ? ' checked' : '') + '>';
    } else if (schema.type === 'array') {
      var items = (schema.items && (schema.items.oneOf || schema.items.enum)) || [];
      input = '<div class="multi">' + items.map(function (it) {
        var v = it.const || it, t = it.title || it;
        return '<label><input type="checkbox" data-multi="' + esc(key) + '" value="' + esc(v) + '"> ' + esc(t) + '</label>';
      }).join('') + '</div>';
    } else {
      // §3.2 未知 type 的属性：客户端应忽略该字段
      return '<div class="fld ignored">忽略未知属性 <code>' + esc(key) + '</code>（type=' + esc(schema.type) + '）</div>';
    }
    return label + input + '</label>';
  }

  function renderElicitation(e) {
    var scope = e.scope.type === 'session'
      ? '会话内' + (e.scope.toolCallId ? ' · 挂在 ' + esc(e.scope.toolCallId) : '')
      : '请求内（没有 sessionId）';
    var body;
    if (e.status !== 'pending') {
      body = '<p>' + (e.status === 'accept'
        ? '已提交：<code>' + esc(JSON.stringify(e.values)) + '</code>'
        : '用户选择了 <strong>' + esc(e.status) + '</strong>') + '</p>';
    } else if (e.mode === 'url') {
      body = '<p>打开系统浏览器：<code>' + esc(e.url) + '</code></p>' +
             '<button class="btn" data-elicit="accept">已完成</button>';
    } else {
      var s = e.schema || {}, req = s.required || [];
      body = '<div class="elicit-form">' +
        (s.description ? '<p class="fld-desc">' + esc(s.description) + '</p>' : '') +
        Object.keys(s.properties || {}).map(function (k) {
          return renderElicitationField(k, s.properties[k], req.indexOf(k) !== -1);
        }).join('') +
        '<div class="elicit-actions">' +
          '<button class="btn primary" data-elicit="accept">提交</button>' +
          '<button class="btn" data-elicit="decline">拒绝</button>' +
          '<button class="btn" data-elicit="cancel">取消</button>' +
        '</div></div>';
    }
    return '<article class="entry elicitation"><header>' + esc(s0(e)) + '<span class="pill">' + esc(scope) + '</span></header>' + body + '</article>';
  }
  function s0(e) { return 'elicitation · ' + (e.mode === 'url' ? 'URL 模式' : '表单模式'); }

  function renderTurn(e) {
    var tail = '';
    if (e.stopReason) {
      var cls = e.stopReason === 'end_turn' ? 'ok' : e.stopReason === 'cancelled' ? 'danger' : 'warn';
      tail = '<span class="pill ' + cls + '">stopReason: ' + esc(e.stopReason) + '</span>';
      if (e.usage) {
        tail += '<span class="pill" title="unstable_end_turn_token_usage：在 PromptResponse 上，不是 session/update">' +
          '回合用量 ' + esc(e.usage.totalTokens) + ' tok（入 ' + esc(e.usage.inputTokens) +
          ' / 出 ' + esc(e.usage.outputTokens) + (e.usage.thoughtTokens ? ' / 思考 ' + esc(e.usage.thoughtTokens) : '') + '）</span>';
      }
    }
    return '<div class="turn-divider"><span class="turn-n">第 ' + e.n + ' 轮</span>' + tail +
      '<span class="turn-note">轮边界是客户端自己切的，协议里没有</span></div>';
  }

  function renderEntry(e) {
    switch (e.kind) {
      case 'message':
        return '<article class="entry msg ' + e.role + '">' +
          '<header>' + (e.role === 'user' ? '用户' : 'Agent') +
          (e.messageId ? '<code class="mid">' + esc(e.messageId) + '</code>' : '<span class="pill warn">无 messageId · 按角色合并</span>') +
          '</header><div class="msg-body">' + renderBlocks(e.blocks) + '</div></article>';
      case 'thought':
        return '<details class="entry thought" open><summary>思考 ' +
          (e.messageId ? '<code class="mid">' + esc(e.messageId) + '</code>' : '') +
          '<span class="pill">折叠单元由客户端定</span></summary>' +
          '<div class="msg-body">' + renderBlocks(e.blocks) + '</div></details>';
      case 'tool_call': return renderToolCall(e);
      case 'plan': return renderPlan(e);
      case 'compaction': return renderCompaction(e);
      case 'permission': return renderPermission(e);
      case 'elicitation': return renderElicitation(e);
      case 'turn': return renderTurn(e);
    }
    return '';
  }

  function renderTranscript() {
    var el = $('transcript');
    var atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 120;
    el.innerHTML = state.entries.map(renderEntry).join('') ||
      '<p class="empty">按「播放」开始回放一段合成的 ACP 会话。</p>';
    if (atBottom) el.scrollTop = el.scrollHeight;
  }

  /* ---------------- 侧栏 ---------------- */

  function renderSidebar() {
    // agent 与能力
    var a = state.agent;
    $('agent-name').textContent = a ? (a.title || a.name) : '未连接';
    $('agent-sub').textContent = a ? (a.name + ' · v' + a.version + ' · 协议 v' + a.protocolVersion) : '等待 initialize';
    var caps = [];
    if (a) {
      var ac = a.capabilities || {};
      if (ac.loadSession) caps.push('loadSession');
      var sc = ac.sessionCapabilities || {};
      ['list', 'delete', 'resume', 'close', 'additionalDirectories'].forEach(function (k) { if (sc[k]) caps.push('session.' + k); });
      var pc = ac.promptCapabilities || {};
      ['image', 'audio', 'embeddedContext'].forEach(function (k) { if (pc[k]) caps.push('prompt.' + k); });
      var mc = ac.mcpCapabilities || {};
      ['http', 'sse'].forEach(function (k) { if (mc[k]) caps.push('mcp.' + k); });
      (a.authMethods || []).forEach(function (m) { caps.push('auth:' + m.type + '/' + m.id); });
    }
    $('agent-caps').innerHTML = caps.map(function (c) { return '<span class="chip">' + esc(c) + '</span>'; }).join('') ||
      '<span class="muted">—</span>';

    // 会话
    $('session-title').textContent = state.session.title || '(未命名会话)';
    $('session-meta').innerHTML = state.session.id
      ? '<code>' + esc(state.session.id) + '</code>' + (state.session.updatedAt ? ' · ' + esc(state.session.updatedAt) : '')
      : '<span class="muted">尚未建立</span>';

    // 配置选项（规范：有 configOptions 就忽略 modes）
    var cfgHtml = state.configOptions.map(function (o) {
      var head = '<div class="cfg-head"><span class="cfg-name">' + esc(o.name) + '</span>' +
        (o.category ? '<span class="chip tiny">' + esc(o.category) + '</span>' : '') + '</div>';
      if (o.type === 'boolean') {
        return '<div class="cfg">' + head + '<label class="switch"><input type="checkbox" data-cfg="' + esc(o.id) + '" data-cfgtype="boolean"' +
          (o.currentValue ? ' checked' : '') + '><span>' + (o.currentValue ? '开' : '关') + '</span></label></div>';
      }
      if (o.type === 'select') {
        var flat = [];
        (o.options || []).forEach(function (x) {
          if (x.group) (x.options || []).forEach(function (y) { flat.push({ v: y.value, n: x.name + ' / ' + y.name }); });
          else flat.push({ v: x.value, n: x.name });
        });
        return '<div class="cfg">' + head + '<select data-cfg="' + esc(o.id) + '" data-cfgtype="select">' +
          flat.map(function (f) {
            return '<option value="' + esc(f.v) + '"' + (f.v === o.currentValue ? ' selected' : '') + '>' + esc(f.n) + '</option>';
          }).join('') + '</select></div>';
      }
      return '<div class="cfg muted">忽略未识别的 type：' + esc(o.type) + '</div>';
    }).join('');
    $('config-options').innerHTML = cfgHtml || '<span class="muted">—</span>';
    $('modes-note').innerHTML = state.modes
      ? (state.configOptions.length
        ? '<span class="pill warn">agent 同时给了 modes（current=' + esc(state.modes.currentModeId) + '），规范要求忽略它</span>'
        : '<span class="pill">仅有 modes：current=' + esc(state.modes.currentModeId) + '</span>')
      : '';

    // 用量
    if (state.usage) {
      var pct = Math.min(100, Math.round(state.usage.used / state.usage.size * 100));
      $('usage').innerHTML = '<div class="bar"><i style="width:' + pct + '%"></i></div>' +
        '<div class="usage-nums">' + state.usage.used.toLocaleString() + ' / ' + state.usage.size.toLocaleString() +
        ' tok（' + pct + '%）' + (state.usage.cost ? ' · ' + state.usage.cost.amount + ' ' + state.usage.cost.currency : '') + '</div>';
    } else {
      $('usage').innerHTML = '<span class="muted">—</span>';
    }

    // 斜杠命令
    $('commands').innerHTML = state.commands.map(function (c) {
      return '<div class="cmd"><code>/' + esc(c.name) + '</code><span>' + esc(c.description) + '</span>' +
        (c.input ? '<em class="hint">' + esc(c.input.hint) + '</em>' : '') + '</div>';
    }).join('') || '<span class="muted">—</span>';

    // 变体覆盖
    $('coverage').innerHTML = Object.keys(P.KNOWN_UPDATES).map(function (k) {
      var n = state.seen[k] || 0;
      return '<div class="cov ' + (n ? 'hit' : '') + '"><code>' + esc(k) + '</code>' +
        '<span class="cov-n">' + (n || '—') + '</span></div>';
    }).join('');

    // 丢弃
    $('dropped-count').textContent = state.dropped.length;
    $('dropped').innerHTML = state.dropped.map(function (d) {
      return '<div class="drop-item">' + esc(d.reason) + '</div>';
    }).join('') || '<span class="muted">暂无</span>';

    // 环境调用
    $('env-calls').innerHTML = state.envCalls.slice(-8).reverse().map(function (c) {
      return '<div class="env"><code>' + esc(c.method) + '</code><span>' + esc(c.path) + '</span></div>';
    }).join('') || '<span class="muted">—</span>';

    $('stop-reason').textContent = state.stopReason || '—';
  }

  function render() { renderTranscript(); renderSidebar(); renderTraffic(); }

  /* ---------------- 回放 ---------------- */

  function trafficFromStep(step, extra) {
    var rec = {
      dir: step.dir,
      tag: step.tag || (step.kind === 'terminal_output' ? 'terminal 输出（非协议）' :
                        step.kind === 'terminal_exit' ? 'terminal 退出（非协议）' : 'stderr'),
      id: step.msg ? step.msg.id : null,
      note: step.note || null,
      body: step.msg ? json(step.msg.params !== undefined ? step.msg.params
             : step.msg.result !== undefined ? step.msg.result : step.msg)
             : json(step.chunk !== undefined ? { terminalId: step.terminalId, chunk: step.chunk }
                    : step.exitStatus !== undefined ? { terminalId: step.terminalId, exitStatus: step.exitStatus }
                    : { line: step.line })
    };
    if (extra) Object.keys(extra).forEach(function (k) { rec[k] = extra[k]; });
    addTraffic(rec);
    return rec;
  }

  function applyStep(step) {
    if (step.turn === 'start') P.startTurn(state, step.msg.params.prompt);

    if (step.dir === 'local') {
      if (step.kind === 'terminal_output') P.appendTerminalOutput(state, step.terminalId, step.chunk);
      else if (step.kind === 'terminal_exit') {
        var t = P.ensureTerminal(state, step.terminalId);
        t.exitStatus = step.exitStatus;
      }
      trafficFromStep(step);
      return;
    }
    if (step.dir === 'stderr') { trafficFromStep(step); return; }

    var msg = step.msg;

    if (step.dir === 'out') {
      // 客户端发出去的：terminal/create 的响应要把终端建起来
      if (pendingTerminalReq && msg.result && msg.result.terminalId) {
        P.ensureTerminal(state, msg.result.terminalId, pendingTerminalReq.outputByteLimit);
        pendingTerminalReq = null;
      }
      trafficFromStep(step);
      return;
    }

    // dir === 'in'
    if (msg.method === 'session/update') {
      var res = P.applyUpdate(state, msg.params, msg);
      trafficFromStep(step, res.kind === 'dropped' ? { dropped: res.reason } : null);
      return;
    }
    if (msg.method) {
      var r = P.applyClientRequest(state, msg);
      if (r.pendingTerminal) pendingTerminalReq = r.pendingTerminal;
      trafficFromStep(step);
      if (r.blocking) {
        waiting = state.pending.permission ? 'permission' : 'elicitation';
        pause();
      }
      return;
    }
    // 是一条响应
    if (msg.result) {
      if (msg.id === 0) P.applyInitializeResult(state, msg.result);
      else if (msg.id === 1) P.applyNewSessionResult(state, msg.result);
      else if (step.turn === 'end') P.endTurn(state, msg.result);
      trafficFromStep(step);
    }
  }

  function tick() {
    if (cursor >= FIXTURE.steps.length) { finish(); return; }
    var step = FIXTURE.steps[cursor++];
    applyStep(step);
    render();
    updateControls();
    if (waiting) return;
    schedule();
  }

  function schedule() {
    if (cursor >= FIXTURE.steps.length) { finish(); return; }
    var next = FIXTURE.steps[cursor];
    timer = setTimeout(tick, Math.max(16, next.delay / speed));
  }

  function finish() {
    timer = null; finished = true; updateControls();
  }

  function play() {
    if (finished || waiting || timer) return;
    schedule();
    updateControls();
  }
  function pause() {
    if (timer) { clearTimeout(timer); timer = null; }
    updateControls();
  }
  function stepOnce() {
    if (waiting || finished) return;
    pause(); tick();
  }
  function reset() {
    pause();
    state = P.createState(); traffic = []; cursor = 0; waiting = null; finished = false; pendingTerminalReq = null;
    render(); updateControls();
  }

  function updateControls() {
    $('btn-play').disabled = !!timer || finished || !!waiting;
    $('btn-pause').disabled = !timer;
    $('btn-step').disabled = finished || !!waiting;
    $('btn-cancel').disabled = finished || !state.session.id;
    var status = finished ? '回放结束' :
      waiting === 'permission' ? '等你回应权限请求' :
      waiting === 'elicitation' ? '等你填 elicitation 表单' :
      timer ? '回放中' : '已暂停';
    $('play-status').textContent = status;
    $('play-status').className = 'status ' + (waiting ? 'waiting' : timer ? 'running' : '');
    $('progress').textContent = cursor + ' / ' + FIXTURE.steps.length;
  }

  /* ---------------- 交互 ---------------- */

  document.addEventListener('click', function (ev) {
    var permBtn = ev.target.closest('[data-perm]');
    if (permBtn) {
      var entry = state.pending.permission;
      if (!entry) return;
      var opt = entry.options[parseInt(permBtn.getAttribute('data-perm'), 10)];
      var response = P.answerPermission(state, opt);
      addTraffic({ dir: 'out', tag: 'session/request_permission', id: response.id, body: json(response.result), note: '用户的选择' });
      waiting = null; render(); updateControls(); play();
      return;
    }

    var elBtn = ev.target.closest('[data-elicit]');
    if (elBtn) {
      var action = elBtn.getAttribute('data-elicit');
      var content = null;
      if (action === 'accept') {
        content = {};
        document.querySelectorAll('[data-fld]').forEach(function (f) {
          var type = f.getAttribute('data-type'), key = f.getAttribute('data-fld');
          if (type === 'boolean') content[key] = f.checked;
          else if (type === 'number' || type === 'integer') content[key] = Number(f.value);
          else content[key] = f.value;
        });
        var multi = {};
        document.querySelectorAll('[data-multi]').forEach(function (f) {
          var key = f.getAttribute('data-multi');
          if (!multi[key]) multi[key] = [];
          if (f.checked) multi[key].push(f.value);
        });
        Object.keys(multi).forEach(function (k) { content[k] = multi[k]; });
      }
      var resp = P.answerElicitation(state, action, content);
      addTraffic({ dir: 'out', tag: 'elicitation/create', id: resp.id, body: json(resp.result), note: '用户的回应' });
      waiting = null; render(); updateControls(); play();
      return;
    }
  });

  document.addEventListener('change', function (ev) {
    var cfg = ev.target.closest('[data-cfg]');
    if (!cfg) return;
    var id = cfg.getAttribute('data-cfg');
    var isBool = cfg.getAttribute('data-cfgtype') === 'boolean';
    var value = isBool ? cfg.checked : cfg.value;
    state.configOptions.forEach(function (o) { if (o.id === id) o.currentValue = value; });
    var req = {
      jsonrpc: '2.0', id: 900 + Math.floor(Math.random() * 99), method: 'session/set_config_option',
      params: isBool ? { sessionId: state.session.id, id: id, type: 'boolean', value: value }
                     : { sessionId: state.session.id, id: id, value: value }
    };
    addTraffic({ dir: 'out', tag: 'session/set_config_option', id: req.id, body: json(req.params), note: '前端改配置 → 核心发命令（原型只做本地乐观更新）' });
    render();
  });

  $('btn-play').addEventListener('click', play);
  $('btn-pause').addEventListener('click', pause);
  $('btn-step').addEventListener('click', stepOnce);
  $('btn-reset').addEventListener('click', reset);
  $('btn-cancel').addEventListener('click', function () {
    var r = P.cancelTurn(state);
    addTraffic({ dir: 'out', tag: 'session/cancel', body: json({ sessionId: state.session.id }), note: '客户端主动取消本轮' });
    if (r.permissionRequestId !== null && r.permissionRequestId !== undefined) {
      addTraffic({
        dir: 'out', tag: 'session/request_permission', id: r.permissionRequestId,
        body: json({ outcome: { outcome: 'cancelled' } }),
        note: '规范硬要求：取消后挂起的权限请求 MUST 以 cancelled 回应'
      });
      waiting = null;
    }
    render(); updateControls();
  });
  $('speed').addEventListener('change', function (e) {
    speed = Number(e.target.value);
    if (timer) { pause(); play(); }
  });

  render();
  updateControls();
})(window);
