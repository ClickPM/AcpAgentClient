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
// 密钥字段只放明显的假值（规则 8 的脱敏验收看 traffic 里是否变成 ***）。

import { createInterface } from 'node:readline'
import { existsSync, writeFileSync } from 'node:fs'
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
  const update = (sessionId, u) => notify('session/update', { sessionId, update: u })
  const turns = new Map() // sessionId → { cancelled }
  let authedInProcess = false // R5：agent 型认证成功后本进程内放行 session/new

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
          agentCapabilities: { loadSession: false, promptCapabilities: { image: false, embeddedContext: false } },
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
        reply({
          sessionId: 'sess_fake_1',
          modes: { currentModeId: 'ask', availableModes: [{ id: 'ask', name: 'Ask' }, { id: 'code', name: 'Code' }] },
          configOptions: [
            { id: 'mode', name: 'Mode', category: 'mode', type: 'select', currentValue: 'ask', options: [{ value: 'ask', name: 'Ask' }, { value: 'code', name: 'Code' }] },
            { id: 'auto_approve_reads', name: 'Auto approve reads', type: 'boolean', currentValue: false },
          ],
        })
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
    update(sessionId, { sessionUpdate: 'config_option_update', configOptions: [
      { id: 'mode', name: 'Mode', category: 'mode', type: 'select', currentValue: 'code', options: [{ value: 'ask', name: 'Ask' }, { value: 'code', name: 'Code' }] },
      { id: 'auto_approve_reads', name: 'Auto approve reads', type: 'boolean', currentValue: true },
    ] })
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
