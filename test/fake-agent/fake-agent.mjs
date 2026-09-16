#!/usr/bin/env node
// 离线验收用的假 agent（R1）：零依赖 Node 脚本，走 ACP v1 stdio，把 test/fixtures/ 的场景按请求回放。
// 只给 rust/tools/acp-smoke 与手工验收用，不是产品的一部分；行为：
//   initialize            → agentInfo + terminal 型 authMethod（args ["--setup"]）
//   session/new           → cwd 下没有 .fake-agent-authed（且 FAKE_AGENT_AUTHED 未设）时回 -32000，否则回 sessionId + configOptions
//   session/prompt        → agent_message_chunk、一条 notice（我们编译不出的变体）、tool_call、request_permission（等回应）、
//                           plan、config_option_update、elicitation form（等回应）、elicitation url + elicitation/complete、
//                           tool_call_update completed、usage_update；最后 PromptResponse end_turn + usage
//   session/cancel        → 当前回合以 cancelled 收尾（挂起的权限请求由客户端回 cancelled）
//   --setup               → stderr 打印 "Enter fake API key: "，从 stdin 读一行，写 <cwd>/.fake-agent-authed，退出 0
//   --crash-after <ms>    → 启动后 N 毫秒往 stderr 写一行并以退出码 3 退出（验 exited 事件）
//   --crash-on-prompt     → 收到 session/prompt 时往 stderr 写一行并以退出码 3 退出（回合中途死掉）
//   --hang-on-prompt      → 收到 session/prompt 后永不回应（给外部 taskkill 留时间）
//   --stderr-noise        → 每次 prompt 往 stderr 写一行（验 traffic 的 stderr 路）
//   --fs                  → （R4）回合开头先 fs/write_text_file 写 <cwd>/fake-agent.txt、再 fs/read_text_file 读第 2 行，
//                           结果写进最后那条 agent_message_chunk
//   --terminal            → （R4）回合里跑一条前台命令：terminal/create（echo）→ 工具卡嵌 terminal → wait_for_exit →
//                           output → release → 工具卡 completed（release 后输出仍留在卡上）
//   --terminal-bg         → （R4）另起一条后台长命令（ping / sleep 30）嵌进工具卡并 wait_for_exit：等客户端用停止方块 kill，
//                           退出后工具卡 failed
//   --sessions            → （R6）会话持久化：会话与整段历史落 <cwd>/.fake-agent-sessions.json，
//                           打开 session/list（cwd 过滤 + 每页一条的 cursor 分页）、session/load（重放完整历史再返回）、
//                           session/resume（不重放）、session/close、session/delete；sessionId 随机生成
//   --caps a,b,c          → （R6）声明哪些 sessionCapabilities（默认 list,resume,close,delete；`--caps ""` 一个都不声明）
//   --modes-only          → （R6）session/new / load 只给 modes 不给 configOptions（modes 回退路径），
//                           set_mode 成功后补一条 current_mode_update
//   --sessions            → （R6）会话持久化：会话与整段历史落 <cwd>/.fake-agent-sessions.json，
//                           打开 session/list（cwd 过滤 + 每页一条的 cursor 分页）、session/load（重放完整历史再返回）、
//                           session/resume（不重放）、session/close、session/delete；sessionId 随机生成
//   --caps a,b,c          → （R6）声明哪些 sessionCapabilities（默认 list,resume,close,delete；给空串就一个都不声明）
//   --modes-only          → （R6）session/new / load 只给 modes 不给 configOptions（modes 回退路径），
//                           set_mode 成功后补一条 current_mode_update
// 密钥字段只放明显的假值（规则 8 的脱敏验收看 traffic 里是否变成 ***）。

import { createInterface } from 'node:readline'
import { existsSync, readFileSync, writeFileSync, renameSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import { join } from 'node:path'

const argv = process.argv.slice(2)
const flag = (name) => argv.includes(name)
const value = (name) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : undefined }
const MARKER = '.fake-agent-authed'

if (flag('--setup')) {
  process.stderr.write('fake-agent setup\nEnter fake API key: ')
  const rl = createInterface({ input: process.stdin })
  rl.once('line', (line) => {
    const cwd = process.cwd()
    writeFileSync(join(cwd, MARKER), `FAKE-KEY-FOR-REDACTION-TEST:${line.length}\n`)
    process.stderr.write(`\nsaved (${line.length} chars) to ${join(cwd, MARKER)}\n`)
    rl.close()
    process.exit(0)
  })
} else {
  serve()
}

function serve() {
  const crashAfter = value('--crash-after')
  if (crashAfter !== undefined) {
    setTimeout(() => {
      process.stderr.write('fake-agent: simulated crash (exit 3)\n')
      process.exit(3)
    }, Number(crashAfter))
  }
  const send = (msg) => process.stdout.write(JSON.stringify(msg) + '\n')
  let nextId = 100
  const pending = new Map() // id → { resolve }
  const request = (method, params) => new Promise((resolve) => {
    const id = nextId++
    pending.set(id, { resolve })
    send({ jsonrpc: '2.0', id, method, params })
  })
  const notify = (method, params) => send({ jsonrpc: '2.0', method, params })
  const turns = new Map() // sessionId → { cancelled }
  let authedInProcess = false // R5：agent 型认证成功后本进程内放行 session/new

  // ---- R6 会话持久化（--sessions）：整段历史落盘，重开后 session/load 能重放回来。
  const persist = flag('--sessions')
  const modesOnly = flag('--modes-only')
  const capsArg = value('--caps')
  const caps = (capsArg === undefined ? 'list,resume,close,delete' : capsArg).split(',').map((s) => s.trim()).filter(Boolean)
  const storePath = (cwd) => join(cwd, '.fake-agent-sessions.json')
  const readStore = (cwd) => {
    try { return JSON.parse(readFileSync(storePath(cwd), 'utf8')) } catch { return {} }
  }
  const writeStore = (cwd, data) => {
    // 临时文件 + rename（CLAUDE.md 规则 7 的写法，夹具也照做）。
    const tmp = storePath(cwd) + '.tmp'
    writeFileSync(tmp, JSON.stringify(data, null, 2))
    renameSync(tmp, storePath(cwd))
  }
  const sessionCwd = new Map() // sessionId → cwd（本进程内建过 / 载过的会话）
  const recordUpdate = (sessionId, u) => {
    if (!persist) return
    const cwd = sessionCwd.get(sessionId)
    if (cwd === undefined) return
    const data = readStore(cwd)
    const entry = data[sessionId]
    if (entry === undefined) return
    entry.history.push(u)
    entry.updatedAt = new Date().toISOString()
    if (u.sessionUpdate === 'user_message_chunk' && entry.title === null) {
      entry.title = String(u.content?.text ?? '').slice(0, 40)
    }
    writeStore(cwd, data)
  }
  const update = (sessionId, u) => { recordUpdate(sessionId, u); notify('session/update', { sessionId, update: u }) }

  // session/new / load / resume 共用的会话配置（--modes-only 只给 modes，走 modes 回退路径）。
  const modeState = (current) => ({ currentModeId: current, availableModes: [{ id: 'ask', name: 'Ask' }, { id: 'code', name: 'Code' }] })
  const configOptionsFor = (current) => [
    { id: 'mode', name: 'Mode', category: 'mode', type: 'select', currentValue: current, options: [{ value: 'ask', name: 'Ask' }, { value: 'code', name: 'Code' }] },
    { id: 'auto_approve_reads', name: 'Auto approve reads', type: 'boolean', currentValue: false },
  ]
  const sessionConfig = (current) => modesOnly
    ? { modes: modeState(current) }
    : { modes: modeState(current), configOptions: configOptionsFor(current) }

  const rl = createInterface({ input: process.stdin })
  rl.on('line', (line) => {
    if (!line.trim()) return
    let msg
    try { msg = JSON.parse(line) } catch { return }
    if (msg.id !== undefined && msg.method === undefined) {
      const p = pending.get(msg.id)
      if (p) { pending.delete(msg.id); p.resolve(msg.result ?? { error: msg.error }) }
      return
    }
    const reply = (result) => send({ jsonrpc: '2.0', id: msg.id, result })
    const fail = (code, message) => send({ jsonrpc: '2.0', id: msg.id, error: { code, message } })
    switch (msg.method) {
      case 'initialize':
        reply({
          protocolVersion: 1,
          agentInfo: { name: 'fake-agent', title: 'Fake Agent', version: '0.0.1' },
          agentCapabilities: {
            loadSession: persist,
            promptCapabilities: { image: false, embeddedContext: false },
            ...(persist && caps.length > 0 ? { sessionCapabilities: Object.fromEntries(caps.map((k) => [k, {}])) } : {}),
          },
          authMethods: [
            { type: 'terminal', id: 'fake-setup', name: 'Configure fake API key', description: 'runs --setup', args: ['--setup'] },
            // R5：agent 型方法，authenticate 时发一条 requestScope 的 URL elicitation（照 codex-acp 的 device code 路径：
            // requestId = 在途 authenticate 的 JSON-RPC id，是数字），客户端 accept 后 elicitation/complete 收尾，本进程内记为已认证。
            { id: 'fake-url', name: 'Sign in with fake browser', description: 'URL elicitation (requestScope)' },
          ],
        })
        break
      case 'authenticate': {
        if (msg.params?.methodId !== 'fake-url') { fail(-32602, `unknown auth method ${msg.params?.methodId}`); break }
        request('elicitation/create', { mode: 'url', requestId: msg.id, message: 'Open the fake login page and come back', elicitationId: 'el_auth_1', url: 'https://example.invalid/fake-login' })
          .then((response) => {
            if (response?.action === 'accept') {
              notify('elicitation/complete', { elicitationId: 'el_auth_1' })
              authedInProcess = true
              reply({})
            } else {
              fail(-32000, `login ${response?.action ?? 'cancelled'}`)
            }
          })
        break
      }
      case 'session/new': {
        const authed = authedInProcess || process.env.FAKE_AGENT_AUTHED === '1' || existsSync(join(msg.params.cwd, MARKER))
        if (!authed) { fail(-32000, 'FAKE_API_KEY is not configured. Run --setup.'); break }
        const cwd = msg.params.cwd
        let sessionId = 'sess_fake_1'
        if (persist) {
          sessionId = 'sess_' + randomUUID()
          const data = readStore(cwd)
          data[sessionId] = { cwd, title: null, updatedAt: new Date().toISOString(), closed: false, history: [] }
          writeStore(cwd, data)
          sessionCwd.set(sessionId, cwd)
        }
        reply({ sessionId, ...sessionConfig('ask') })
        // 斜杠命令（画板 42）：走 update() 入库，session/load 重放后 `/` 菜单还在。
        update(sessionId, {
          sessionUpdate: 'available_commands_update',
          availableCommands: [
            { name: 'review', description: '审一遍改动' },
            { name: 'compact', description: '压缩上下文' },
          ],
        })
        break
      }
      // ---- R6 会话生命周期。没开 --sessions 时这五条一律 -32601（能力也没声明，客户端本来就不该发）。
      case 'session/list': {
        if (!persist) { fail(-32601, 'session/list needs --sessions'); break }
        const cwd = msg.params?.cwd ?? process.cwd()
        const data = readStore(cwd)
        const ids = Object.keys(data)
          .filter((id) => msg.params?.cwd === undefined || msg.params.cwd === null || data[id].cwd === msg.params.cwd)
          .sort()
        // 每页一条：客户端必须按 nextCursor 取完才看得到全部。
        const from = msg.params?.cursor === undefined || msg.params.cursor === null ? 0 : Number(msg.params.cursor)
        if (!Number.isInteger(from) || from < 0 || from > ids.length) { fail(-32602, 'bad cursor ' + msg.params?.cursor); break }
        const page = ids.slice(from, from + 1)
        const next = from + 1 < ids.length ? String(from + 1) : undefined
        reply({
          sessions: page.map((id) => ({ sessionId: id, cwd: data[id].cwd, title: data[id].title ?? undefined, updatedAt: data[id].updatedAt })),
          ...(next === undefined ? {} : { nextCursor: next }),
        })
        break
      }
      case 'session/load': {
        if (!persist) { fail(-32601, 'session/load needs --sessions'); break }
        const cwd = msg.params.cwd
        const data = readStore(cwd)
        const entry = data[msg.params.sessionId]
        if (entry === undefined) { fail(-32602, 'no such session ' + msg.params.sessionId); break }
        sessionCwd.set(msg.params.sessionId, cwd)
        entry.closed = false
        writeStore(cwd, data)
        // 规范：整段历史 MUST 用 session/update 重放完再返回（重放本身不再入库，所以绕开 update()）。
        for (const u of entry.history) notify('session/update', { sessionId: msg.params.sessionId, update: u })
        reply(sessionConfig('ask'))
        break
      }
      case 'session/resume': {
        if (!persist) { fail(-32601, 'session/resume needs --sessions'); break }
        const cwd = msg.params.cwd
        const data = readStore(cwd)
        const entry = data[msg.params.sessionId]
        if (entry === undefined) { fail(-32602, 'no such session ' + msg.params.sessionId); break }
        sessionCwd.set(msg.params.sessionId, cwd)
        entry.closed = false
        writeStore(cwd, data)
        reply({}) // MUST NOT 重放
        break
      }
      case 'session/close': {
        if (!persist) { fail(-32601, 'session/close needs --sessions'); break }
        const cwd = sessionCwd.get(msg.params.sessionId)
        if (cwd === undefined) { fail(-32602, 'no such session ' + msg.params.sessionId); break }
        const t = turns.get(msg.params.sessionId)
        if (t) t.cancelled = true
        const data = readStore(cwd)
        if (data[msg.params.sessionId] !== undefined) { data[msg.params.sessionId].closed = true; writeStore(cwd, data) }
        sessionCwd.delete(msg.params.sessionId)
        reply({})
        break
      }
      case 'session/delete': {
        if (!persist) { fail(-32601, 'session/delete needs --sessions'); break }
        const cwd = sessionCwd.get(msg.params.sessionId) ?? process.cwd()
        const data = readStore(cwd)
        if (data[msg.params.sessionId] === undefined) { fail(-32602, 'no such session ' + msg.params.sessionId); break }
        delete data[msg.params.sessionId]
        writeStore(cwd, data)
        sessionCwd.delete(msg.params.sessionId)
        reply({})
        break
      }
      case 'session/prompt':
        if (flag('--crash-on-prompt')) { process.stderr.write('fake-agent: crash on prompt (exit 3)' + String.fromCharCode(10)); process.exit(3) }
        if (flag('--hang-on-prompt')) { process.stderr.write('fake-agent: hanging on prompt' + String.fromCharCode(10)); break }
        runTurn(msg).catch((e) => fail(-32603, String(e)))
        break
      case 'session/cancel': {
        const t = turns.get(msg.params.sessionId)
        if (t) t.cancelled = true
        break
      }
      case 'session/set_mode':
        reply({})
        // R6 modes 回退：客户端发起的切换成功即生效；这里再补一条 agent 侧通知（Zed / dsh 都这么干）。
        if (modesOnly) update(msg.params.sessionId, { sessionUpdate: 'current_mode_update', currentModeId: msg.params.modeId })
        break
      case 'session/set_config_option':
        reply({ configOptions: [{ id: 'mode', name: 'Mode', category: 'mode', type: 'select', currentValue: msg.params.value, options: [{ value: 'ask', name: 'Ask' }, { value: 'code', name: 'Code' }] }] })
        break
      default:
        if (msg.id !== undefined) fail(-32601, `method not found: ${msg.method}`)
    }
  })
  rl.on('close', () => process.exit(0))

  async function runTurn(msg) {
    const sessionId = msg.params.sessionId
    const turn = { cancelled: false }
    turns.set(sessionId, turn)
    const reply = (result) => send({ jsonrpc: '2.0', id: msg.id, result })
    if (flag('--stderr-noise')) process.stderr.write('[fake-agent] turn started; token=FAKE-TOKEN-FOR-REDACTION-TEST\n')
    const cwd = msg.params?.cwd ?? process.cwd()
    let fsNote = ''
    if (flag('--fs')) {
      const path = join(cwd, 'fake-agent.txt')
      update(sessionId, { sessionUpdate: 'tool_call', toolCallId: 'call_fs_write', title: 'Write fake-agent.txt', kind: 'edit', status: 'in_progress', locations: [{ path }] })
      const w = await request('fs/write_text_file', { sessionId, path, content: '第一行\n第二行\n第三行\n' })
      update(sessionId, { sessionUpdate: 'tool_call_update', toolCallId: 'call_fs_write', status: w?.error ? 'failed' : 'completed',
        content: [{ type: 'diff', path, oldText: null, newText: '第一行\n第二行\n第三行\n' }] })
      update(sessionId, { sessionUpdate: 'tool_call', toolCallId: 'call_fs_read', title: 'Read fake-agent.txt', kind: 'read', status: 'in_progress', locations: [{ path, line: 2 }], rawInput: { path, offset: 2, limit: 1 } })
      const r = await request('fs/read_text_file', { sessionId, path, line: 2, limit: 1 })
      update(sessionId, { sessionUpdate: 'tool_call_update', toolCallId: 'call_fs_read', status: r?.error ? 'failed' : 'completed',
        content: [{ type: 'content', content: { type: 'text', text: r?.content ?? JSON.stringify(r) } }] })
      fsNote = ` fs=${JSON.stringify({ write: w, read: r })}`
    }
    if (flag('--terminal')) {
      update(sessionId, { sessionUpdate: 'tool_call', toolCallId: 'call_term_fg', title: 'echo fake-terminal-ok', kind: 'execute', status: 'pending', rawInput: { command: 'echo fake-terminal-ok', cwd } })
      const created = await request('terminal/create', { sessionId, command: 'echo', args: ['fake-terminal-ok'], cwd, outputByteLimit: 65536 })
      const terminalId = created?.terminalId
      update(sessionId, { sessionUpdate: 'tool_call_update', toolCallId: 'call_term_fg', status: 'in_progress', content: [{ type: 'terminal', terminalId }] })
      const exit = await request('terminal/wait_for_exit', { sessionId, terminalId })
      const out = await request('terminal/output', { sessionId, terminalId })
      await request('terminal/release', { sessionId, terminalId })
      update(sessionId, { sessionUpdate: 'tool_call_update', toolCallId: 'call_term_fg', status: exit?.exitCode === 0 ? 'completed' : 'failed' })
      fsNote += ` terminal=${JSON.stringify({ exit, truncated: out?.truncated, sawOutput: typeof out?.output === 'string' && out.output.includes('fake-terminal-ok') })}`
    }
    if (flag('--terminal-bg')) {
      const [command, args] = process.platform === 'win32'
        ? ['cmd', ['/c', 'echo background started && ping -n 60 127.0.0.1 > nul']]
        : ['sh', ['-c', 'echo background started; sleep 60']]
      update(sessionId, { sessionUpdate: 'tool_call', toolCallId: 'call_term_bg', title: 'background job', kind: 'execute', status: 'pending', rawInput: { command: `${command} ${args.join(' ')}`, cwd } })
      const created = await request('terminal/create', { sessionId, command, args, cwd })
      const terminalId = created?.terminalId
      update(sessionId, { sessionUpdate: 'tool_call_update', toolCallId: 'call_term_bg', status: 'in_progress', content: [{ type: 'terminal', terminalId }] })
      const exit = await request('terminal/wait_for_exit', { sessionId, terminalId })
      const out = await request('terminal/output', { sessionId, terminalId })
      await request('terminal/release', { sessionId, terminalId })
      update(sessionId, { sessionUpdate: 'tool_call_update', toolCallId: 'call_term_bg', status: exit?.exitCode === 0 ? 'completed' : 'failed' })
      fsNote += ` background=${JSON.stringify({ exit, sawOutput: typeof out?.output === 'string' && out.output.includes('background started') })}`
    }
    update(sessionId, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'Let me edit the file.' + fsNote } })
    update(sessionId, { sessionUpdate: 'notice', severity: 'warning', title: 'model degraded', description: 'fallback model in use' })
    update(sessionId, { sessionUpdate: 'tool_call', toolCallId: 'call_edit_1', title: 'edit README', kind: 'edit', status: 'pending' })
    const permission = await request('session/request_permission', {
      sessionId,
      toolCall: { toolCallId: 'call_edit_1' },
      options: [
        { optionId: 'allow-once', name: 'Allow once', kind: 'allow_once' },
        { optionId: 'reject-once', name: 'Reject', kind: 'reject_once' },
      ],
    })
    if (turn.cancelled || permission?.outcome?.outcome === 'cancelled') {
      reply({ stopReason: 'cancelled' })
      return
    }
    if (permission?.outcome?.outcome === 'selected' && permission.outcome.optionId === 'reject-once') {
      update(sessionId, { sessionUpdate: 'tool_call_update', toolCallId: 'call_edit_1', status: 'failed' })
      reply({ stopReason: 'end_turn', usage: { totalTokens: 12, inputTokens: 10, outputTokens: 2 } })
      return
    }
    update(sessionId, { sessionUpdate: 'tool_call_update', toolCallId: 'call_edit_1', status: 'in_progress' })
    update(sessionId, { sessionUpdate: 'plan', entries: [{ content: 'edit README', priority: 'high', status: 'in_progress' }] })
    // --modes-only 的 agent 一辈子不发 configOptions（R6 的 modes 回退路径就是这种 agent），
    // 回合里也不能破例，否则模式下拉会中途从 modes 切成 configOptions。
    if (!modesOnly) {
      update(sessionId, { sessionUpdate: 'config_option_update', configOptions: [
        { id: 'mode', name: 'Mode', category: 'mode', type: 'select', currentValue: 'code', options: [{ value: 'ask', name: 'Ask' }, { value: 'code', name: 'Code' }] },
        { id: 'auto_approve_reads', name: 'Auto approve reads', type: 'boolean', currentValue: true },
      ] })
    }
    const form = await request('elicitation/create', {
      mode: 'form', sessionId, message: 'Commit after editing?',
      requestedSchema: { type: 'object', properties: { commit: { type: 'boolean', title: 'Commit', default: true }, note: { type: 'string', title: 'Note', maxLength: 40 } }, required: ['commit'] },
    })
    if (turn.cancelled) { reply({ stopReason: 'cancelled' }); return }
    const url = await request('elicitation/create', { mode: 'url', requestId: 'req_login_1', message: 'Open the login page', elicitationId: 'el_url_1', url: 'https://example.invalid/login' })
    notify('elicitation/complete', { elicitationId: 'el_url_1', requestId: 'req_login_1' })
    update(sessionId, { sessionUpdate: 'tool_call_update', toolCallId: 'call_edit_1', status: 'completed',
      content: [{ type: 'diff', path: join(msg.params?.cwd ?? process.cwd(), 'README.md'), oldText: 'a\n', newText: 'b\n' }] })
    update(sessionId, { sessionUpdate: 'usage_update', used: 1200, size: 128000 })
    update(sessionId, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: `Done (form=${JSON.stringify(form)}, url=${JSON.stringify(url)}).` } })
    reply({ stopReason: turn.cancelled ? 'cancelled' : 'end_turn', usage: { totalTokens: 42, inputTokens: 30, outputTokens: 12 } })
  }
}
