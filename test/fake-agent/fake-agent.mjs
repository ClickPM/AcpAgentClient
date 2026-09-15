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
          authMethods: [{ type: 'terminal', id: 'fake-setup', name: 'Configure fake API key', description: 'runs --setup', args: ['--setup'] }],
        })
        break
      case 'session/new': {
        const authed = process.env.FAKE_AGENT_AUTHED === '1' || existsSync(join(msg.params.cwd, MARKER))
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
    update(sessionId, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'Let me edit the file.' } })
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
