/* 合成的 ACP 线上流（wire script）。
 *
 * 每一步是一条真实形状的 JSON-RPC 消息，字段照 schema/v1 写。回放器按 delay 依次投喂给
 * projection.js。dir 的四种取值：
 *   out    客户端 -> agent
 *   in     agent  -> 客户端
 *   local  不是协议消息（终端输出、客户端本地态），对应 design.md 的 acp/terminal_output
 *   stderr agent 的 stderr 尾巴
 * awaits 有值的步骤会让回放停住，等界面上的人回应，回应完再继续。
 */
(function (global) {
  'use strict';

  var SESSION = 'sess_9f3c21a7';
  var CWD = 'D:/variFlight_work/AcpAgentClient';

  // 内容块演示用的小图，btoa 只吃 ASCII，SVG 里不要放中文。
  var DEMO_SVG = [
    '<svg xmlns="http://www.w3.org/2000/svg" width="240" height="120">',
    '<rect width="240" height="120" fill="#1f6feb"/>',
    '<circle cx="60" cy="60" r="34" fill="#7ee787"/>',
    '<rect x="112" y="34" width="104" height="14" rx="7" fill="#ffffff" opacity="0.9"/>',
    '<rect x="112" y="58" width="78" height="14" rx="7" fill="#ffffff" opacity="0.65"/>',
    '<rect x="112" y="82" width="96" height="14" rx="7" fill="#ffffff" opacity="0.4"/>',
    '</svg>'
  ].join('');

  function update(u) {
    return { jsonrpc: '2.0', method: 'session/update', params: { sessionId: SESSION, update: u } };
  }
  function text(t) { return { type: 'text', text: t }; }

  var steps = [
    // ---- 连接与初始化 ------------------------------------------------------
    {
      delay: 0, dir: 'out', tag: 'initialize',
      msg: {
        jsonrpc: '2.0', id: 0, method: 'initialize',
        params: {
          protocolVersion: 1,
          clientInfo: { name: 'AcpAgentClient', version: '0.0.0' },
          clientCapabilities: {
            fs: { readTextFile: true, writeTextFile: true },
            terminal: true,
            auth: { terminal: true },
            session: { configOptions: { boolean: {} }, compaction: {} },
            plan: {},
            elicitation: { form: {}, url: {} },
            _meta: { terminal_output: true, 'terminal-auth': true }
          }
        }
      }
    },
    {
      delay: 260, dir: 'in', tag: 'initialize',
      msg: {
        jsonrpc: '2.0', id: 0,
        result: {
          protocolVersion: 1,
          agentInfo: { name: 'dsh-acp-interactive', title: 'DeepSeek Harness', version: '0.9.2' },
          agentCapabilities: {
            loadSession: true,
            promptCapabilities: { image: true, embeddedContext: true },
            mcpCapabilities: { http: true },
            sessionCapabilities: { list: {}, resume: {}, close: {} }
          },
          authMethods: [
            { type: 'terminal', id: 'dsh-setup', name: '在终端里登录', description: '跑一次 --setup 写入密钥', args: ['--setup'] }
          ]
        }
      }
    },

    // ---- 建会话 ------------------------------------------------------------
    {
      delay: 200, dir: 'out', tag: 'session/new',
      msg: {
        jsonrpc: '2.0', id: 1, method: 'session/new',
        params: {
          cwd: CWD,
          mcpServers: [
            {
              type: 'http', name: 'variflight-bi', url: 'https://mcp.example.internal/bi',
              headers: [{ name: 'Authorization', value: 'Bearer sk-live-8f21c0d4e9' }]
            }
          ]
        }
      }
    },
    {
      delay: 320, dir: 'in', tag: 'session/new',
      msg: {
        jsonrpc: '2.0', id: 1,
        result: {
          sessionId: SESSION,
          modes: {
            currentModeId: 'ask',
            availableModes: [
              { id: 'ask', name: '询问', description: '每次改动前请求许可' },
              { id: 'code', name: '编码', description: '完整工具权限' }
            ]
          },
          configOptions: [
            {
              id: 'mode', name: '会话模式', description: '控制 agent 何时请求许可',
              category: 'mode', type: 'select', currentValue: 'ask',
              options: [
                { value: 'ask', name: '询问', description: '每次改动前请求许可' },
                { value: 'code', name: '编码', description: '完整工具权限' }
              ]
            },
            {
              id: 'model', name: '模型', category: 'model', type: 'select', currentValue: 'ds-v4',
              options: [
                { group: 'DeepSeek', name: 'DeepSeek', options: [
                  { value: 'ds-v4', name: 'DeepSeek V4', description: '默认' },
                  { value: 'ds-r2', name: 'DeepSeek R2', description: '推理更强' }
                ] }
              ]
            },
            {
              id: 'auto_approve_reads', name: '自动批准只读工具',
              description: '读文件与搜索不再逐次询问', type: 'boolean', currentValue: false
            }
          ]
        }
      }
    },
    {
      delay: 160, dir: 'in', tag: 'available_commands_update',
      msg: update({
        sessionUpdate: 'available_commands_update',
        availableCommands: [
          { name: 'review', description: '对当前 diff 做一次缺陷审查', input: { hint: '可选：范围' } },
          { name: 'compact', description: '压缩上下文' },
          { name: 'plan', description: '只出计划不动手' }
        ]
      })
    },

    // ---- 第一轮：发 prompt --------------------------------------------------
    {
      delay: 280, dir: 'out', tag: 'session/prompt', turn: 'start',
      msg: {
        jsonrpc: '2.0', id: 2, method: 'session/prompt',
        params: {
          sessionId: SESSION,
          prompt: [
            text('给 scripts/validate.ps1 加一项：校验前端 TS 类型与 schema 同步。先看一眼现在的脚本。'),
            {
              type: 'resource',
              resource: {
                uri: 'file:///D:/variFlight_work/AcpAgentClient/docs/acp-projection.md',
                mimeType: 'text/markdown',
                text: '# ACP 可投影内容清单\n...（@ 提及带进来的上下文，此处省略）'
              }
            }
          ]
        }
      }
    },
    {
      delay: 220, dir: 'in', tag: 'user_message_chunk',
      msg: update({
        sessionUpdate: 'user_message_chunk',
        messageId: 'msg_u1',
        content: text('给 scripts/validate.ps1 加一项：校验前端 TS 类型与 schema 同步。先看一眼现在的脚本。')
      })
    },

    // ---- 思考 --------------------------------------------------------------
    {
      delay: 300, dir: 'in', tag: 'agent_thought_chunk',
      msg: update({ sessionUpdate: 'agent_thought_chunk', messageId: 'th_1', content: text('先确认 validate.ps1 现在跑了哪些检查，') })
    },
    {
      delay: 180, dir: 'in', tag: 'agent_thought_chunk',
      msg: update({ sessionUpdate: 'agent_thought_chunk', messageId: 'th_1', content: text('再决定把 schema 同步校验插在编译之前还是之后。插在之前更省时间。') })
    },

    // ---- 回答开始 -----------------------------------------------------------
    {
      delay: 260, dir: 'in', tag: 'agent_message_chunk',
      msg: update({ sessionUpdate: 'agent_message_chunk', messageId: 'msg_a1', content: text('我先读一下现在的 ') })
    },
    {
      delay: 120, dir: 'in', tag: 'agent_message_chunk',
      msg: update({ sessionUpdate: 'agent_message_chunk', messageId: 'msg_a1', content: text('`scripts/validate.ps1`，') })
    },
    {
      delay: 120, dir: 'in', tag: 'agent_message_chunk',
      msg: update({ sessionUpdate: 'agent_message_chunk', messageId: 'msg_a1', content: text('然后按下面的计划改。') })
    },

    // ---- 计划（稳定变体：整份替换） -------------------------------------------
    {
      delay: 240, dir: 'in', tag: 'plan',
      msg: update({
        sessionUpdate: 'plan',
        entries: [
          { content: '读 scripts/validate.ps1', priority: 'high', status: 'in_progress' },
          { content: '加一步 schema -> TS 类型同步校验', priority: 'high', status: 'pending' },
          { content: '跑一次确认退出码', priority: 'medium', status: 'pending' }
        ]
      })
    },

    // ---- 工具调用 1：读文件 ---------------------------------------------------
    {
      delay: 220, dir: 'in', tag: 'tool_call',
      msg: update({
        sessionUpdate: 'tool_call',
        toolCallId: 'call_read_1',
        title: '读取 scripts/validate.ps1',
        kind: 'read',
        status: 'pending',
        rawInput: { path: 'D:/variFlight_work/AcpAgentClient/scripts/validate.ps1' }
      })
    },
    {
      delay: 200, dir: 'in', tag: 'tool_call_update',
      msg: update({ sessionUpdate: 'tool_call_update', toolCallId: 'call_read_1', status: 'in_progress' })
    },
    {
      delay: 120, dir: 'in', tag: 'fs/read_text_file',
      msg: {
        jsonrpc: '2.0', id: 5, method: 'fs/read_text_file',
        params: { sessionId: SESSION, path: 'D:/variFlight_work/AcpAgentClient/scripts/validate.ps1' }
      }
    },
    {
      delay: 90, dir: 'out', tag: 'fs/read_text_file',
      msg: { jsonrpc: '2.0', id: 5, result: { content: '#Requires -Version 5.1\nSet-StrictMode -Version Latest\n...' } }
    },
    {
      delay: 220, dir: 'in', tag: 'tool_call_update',
      note: 'content 与 locations 是替换语义，不是追加',
      msg: update({
        sessionUpdate: 'tool_call_update',
        toolCallId: 'call_read_1',
        status: 'completed',
        content: [{ type: 'content', content: text('42 行；现在只做 cargo build / cargo test 两件事，没有 schema 相关校验。') }],
        locations: [{ path: 'D:/variFlight_work/AcpAgentClient/scripts/validate.ps1', line: 18 }]
      })
    },

    // ---- 会话元数据与用量 -------------------------------------------------------
    {
      delay: 140, dir: 'in', tag: 'session_info_update',
      msg: update({ sessionUpdate: 'session_info_update', title: '给 validate.ps1 加 schema 同步校验', updatedAt: '2026-09-11T09:14:22Z' })
    },
    {
      delay: 120, dir: 'in', tag: 'usage_update',
      msg: update({ sessionUpdate: 'usage_update', used: 18240, size: 200000, cost: { amount: 0.012, currency: 'USD' } })
    },

    // ---- plan_update（unstable，靠我们声明 plan 能力才会来） -----------------------
    {
      delay: 220, dir: 'in', tag: 'plan_update',
      note: '要客户端声明 plan 能力才会收到',
      msg: update({
        sessionUpdate: 'plan_update',
        plan: {
          type: 'items',
          planId: 'plan_validate',
          entries: [
            { content: '读 scripts/validate.ps1', priority: 'high', status: 'completed' },
            { content: '加一步 schema -> TS 类型同步校验', priority: 'high', status: 'in_progress' },
            { content: '跑一次确认退出码', priority: 'medium', status: 'pending' }
          ]
        }
      })
    },

    // ---- 工具调用 2：改文件 + 权限请求 ---------------------------------------------
    {
      delay: 240, dir: 'in', tag: 'tool_call',
      msg: update({
        sessionUpdate: 'tool_call',
        toolCallId: 'call_edit_1',
        title: '修改 scripts/validate.ps1',
        kind: 'edit',
        status: 'pending',
        rawInput: { path: 'D:/variFlight_work/AcpAgentClient/scripts/validate.ps1', insertAfterLine: 18 }
      })
    },
    {
      delay: 200, dir: 'in', tag: 'session/request_permission', awaits: 'permission',
      msg: {
        jsonrpc: '2.0', id: 6, method: 'session/request_permission',
        params: {
          sessionId: SESSION,
          toolCall: { toolCallId: 'call_edit_1' },
          options: [
            { optionId: 'allow-once', name: '允许这一次', kind: 'allow_once' },
            { optionId: 'allow-always', name: '总是允许改这个文件', kind: 'allow_always' },
            { optionId: 'reject-once', name: '拒绝', kind: 'reject_once' }
          ]
        }
      }
    },
    {
      delay: 160, dir: 'in', tag: 'tool_call_update',
      msg: update({ sessionUpdate: 'tool_call_update', toolCallId: 'call_edit_1', status: 'in_progress' })
    },
    {
      delay: 120, dir: 'in', tag: 'fs/write_text_file',
      msg: {
        jsonrpc: '2.0', id: 7, method: 'fs/write_text_file',
        params: { sessionId: SESSION, path: 'D:/variFlight_work/AcpAgentClient/scripts/validate.ps1', content: '...' }
      }
    },
    { delay: 90, dir: 'out', tag: 'fs/write_text_file', msg: { jsonrpc: '2.0', id: 7, result: {} } },
    {
      delay: 240, dir: 'in', tag: 'tool_call_update',
      msg: update({
        sessionUpdate: 'tool_call_update',
        toolCallId: 'call_edit_1',
        status: 'completed',
        content: [{
          type: 'diff',
          path: 'D:/variFlight_work/AcpAgentClient/scripts/validate.ps1',
          oldText: 'cargo build --workspace\ncargo test --workspace\n',
          newText: 'node scripts/gen-acp-types.mjs --check\ncargo build --workspace\ncargo test --workspace\n'
        }],
        locations: [{ path: 'D:/variFlight_work/AcpAgentClient/scripts/validate.ps1', line: 19 }]
      })
    },

    // ---- 新的一条消息（messageId 变了 -> 另起气泡） -------------------------------
    {
      delay: 220, dir: 'in', tag: 'agent_message_chunk',
      note: 'messageId 从 msg_a1 变成 msg_a2，客户端据此另起一条消息',
      msg: update({ sessionUpdate: 'agent_message_chunk', messageId: 'msg_a2', content: text('改好了，跑一次看看退出码。') })
    },

    // ---- 工具调用 3：终端 --------------------------------------------------------
    {
      delay: 200, dir: 'in', tag: 'tool_call',
      msg: update({
        sessionUpdate: 'tool_call', toolCallId: 'call_exec_1',
        title: 'powershell -File scripts/validate.ps1', kind: 'execute', status: 'pending'
      })
    },
    {
      delay: 180, dir: 'in', tag: 'terminal/create',
      msg: {
        jsonrpc: '2.0', id: 8, method: 'terminal/create',
        params: {
          sessionId: SESSION, command: 'powershell', args: ['-File', 'scripts/validate.ps1'],
          cwd: CWD, outputByteLimit: 65536,
          env: [{ name: 'ACP_TOKEN', value: 'tok_7d31aa90ff' }]
        }
      }
    },
    { delay: 110, dir: 'out', tag: 'terminal/create', msg: { jsonrpc: '2.0', id: 8, result: { terminalId: 'term_1' } } },
    {
      delay: 140, dir: 'in', tag: 'tool_call_update',
      msg: update({
        sessionUpdate: 'tool_call_update', toolCallId: 'call_exec_1', status: 'in_progress',
        content: [{ type: 'terminal', terminalId: 'term_1' }]
      })
    },
    { delay: 260, dir: 'local', kind: 'terminal_output', terminalId: 'term_1', chunk: '> node scripts/gen-acp-types.mjs --check\n' },
    { delay: 420, dir: 'local', kind: 'terminal_output', terminalId: 'term_1', chunk: 'schema/v1 -> src/acp/types.ts: 同步\n' },
    { delay: 380, dir: 'local', kind: 'terminal_output', terminalId: 'term_1', chunk: '> cargo build --workspace\n    Finished dev [unoptimized] in 3.71s\n' },
    { delay: 340, dir: 'local', kind: 'terminal_output', terminalId: 'term_1', chunk: '> cargo test --workspace\ntest result: ok. 12 passed; 0 failed\n' },
    {
      delay: 120, dir: 'in', tag: 'terminal/wait_for_exit',
      msg: { jsonrpc: '2.0', id: 9, method: 'terminal/wait_for_exit', params: { sessionId: SESSION, terminalId: 'term_1' } }
    },
    { delay: 100, dir: 'local', kind: 'terminal_exit', terminalId: 'term_1', exitStatus: { exitCode: 0, signal: null } },
    { delay: 40, dir: 'out', tag: 'terminal/wait_for_exit', msg: { jsonrpc: '2.0', id: 9, result: { exitCode: 0, signal: null } } },
    {
      delay: 140, dir: 'in', tag: 'terminal/release',
      msg: { jsonrpc: '2.0', id: 10, method: 'terminal/release', params: { sessionId: SESSION, terminalId: 'term_1' } }
    },
    { delay: 60, dir: 'out', tag: 'terminal/release', msg: { jsonrpc: '2.0', id: 10, result: {} } },
    {
      delay: 160, dir: 'in', tag: 'tool_call_update',
      note: '终端已 release，但输出必须继续留在卡上',
      msg: update({ sessionUpdate: 'tool_call_update', toolCallId: 'call_exec_1', status: 'completed' })
    },

    // ---- 丢弃演示 1：notice（我们编译不出） ------------------------------------------
    {
      delay: 220, dir: 'in', tag: 'notice',
      note: '裁定：不改 feature 集，计数 + 告警 + 落 traffic',
      msg: update({ sessionUpdate: 'notice', severity: 'warning', title: '模型已降级到 ds-v4-mini', description: '主模型限流，本轮剩余请求走备用模型。' })
    },

    // ---- elicitation：表单 ------------------------------------------------------
    {
      delay: 240, dir: 'in', tag: 'elicitation/create', awaits: 'elicitation',
      msg: {
        jsonrpc: '2.0', id: 11, method: 'elicitation/create',
        params: {
          mode: 'form',
          sessionId: SESSION,
          toolCallId: 'call_edit_1',
          requestedSchema: {
            type: 'object',
            title: '提交前确认',
            description: '这次改动要不要顺手把校验接进 CI？',
            properties: {
              scope: {
                type: 'string', title: '接入范围', description: '选一个',
                oneOf: [
                  { const: 'local', title: '只在本地 validate.ps1' },
                  { const: 'ci', title: '本地 + CI' }
                ],
                default: 'local'
              },
              note: { type: 'string', title: '备注', description: '会写进任务卡', maxLength: 120 },
              strict: { type: 'boolean', title: '不同步就直接失败', default: true }
            },
            required: ['scope']
          }
        }
      }
    },
    {
      delay: 200, dir: 'in', tag: 'config_option_update',
      note: 'set_config_option 之外，agent 也会主动推全量配置',
      msg: update({
        sessionUpdate: 'config_option_update',
        configOptions: [
          {
            id: 'mode', name: '会话模式', description: '控制 agent 何时请求许可',
            category: 'mode', type: 'select', currentValue: 'code',
            options: [
              { value: 'ask', name: '询问', description: '每次改动前请求许可' },
              { value: 'code', name: '编码', description: '完整工具权限' }
            ]
          },
          {
            id: 'model', name: '模型', category: 'model', type: 'select', currentValue: 'ds-v4',
            options: [
              { group: 'DeepSeek', name: 'DeepSeek', options: [
                { value: 'ds-v4', name: 'DeepSeek V4', description: '默认' },
                { value: 'ds-r2', name: 'DeepSeek R2', description: '推理更强' }
              ] }
            ]
          },
          { id: 'auto_approve_reads', name: '自动批准只读工具', description: '读文件与搜索不再逐次询问', type: 'boolean', currentValue: true },
          { id: 'thinking', name: '思考强度', category: 'thought_level', type: 'select', currentValue: 'medium',
            options: [
              { value: 'low', name: '低' }, { value: 'medium', name: '中' }, { value: 'high', name: '高' }
            ] }
        ]
      })
    },
    {
      delay: 140, dir: 'in', tag: 'current_mode_update',
      note: 'configOptions 已经带了 mode，规范说此时应以 configOptions 为准',
      msg: update({ sessionUpdate: 'current_mode_update', currentModeId: 'code' })
    },

    // ---- 上下文压缩（unstable，靠我们声明 session.compaction 才会来） ------------------
    {
      delay: 260, dir: 'in', tag: 'compaction_update',
      note: '要客户端声明 session.compaction 才会收到',
      msg: update({ sessionUpdate: 'compaction_update', compactionId: 'cmp_1', status: 'in_progress' })
    },
    {
      delay: 300, dir: 'in', tag: 'compaction_summary_chunk',
      msg: update({ sessionUpdate: 'compaction_summary_chunk', compactionId: 'cmp_1', content: text('已读 validate.ps1 并在 cargo build 之前插入 gen-acp-types 校验；') })
    },
    {
      delay: 220, dir: 'in', tag: 'compaction_summary_chunk',
      msg: update({ sessionUpdate: 'compaction_summary_chunk', compactionId: 'cmp_1', content: text('本地跑通，退出码 0。待办：是否接 CI。') })
    },
    {
      delay: 200, dir: 'in', tag: 'compaction_update',
      msg: update({ sessionUpdate: 'compaction_update', compactionId: 'cmp_1', status: 'completed' })
    },
    {
      delay: 120, dir: 'in', tag: 'usage_update',
      msg: update({ sessionUpdate: 'usage_update', used: 6120, size: 200000, cost: { amount: 0.019, currency: 'USD' } })
    },

    // ---- 容错演示：凭空建卡 + 跳过未知集合项 + 未知 kind 回落 --------------------------
    {
      delay: 260, dir: 'in', tag: 'tool_call_update',
      note: 'toolCallId 此前没出现过；content 里混了未知类型；kind 是未知值',
      msg: update({
        sessionUpdate: 'tool_call_update',
        toolCallId: 'call_ghost_1',
        title: '汇总本轮改动',
        kind: 'sculpt',
        status: 'completed',
        content: [
          { type: 'content', content: text('1 个文件改动，+1 行。') },
          { type: 'table', rows: [['scripts/validate.ps1', '+1']] },
          { type: 'content', content: text('没有新增依赖。') }
        ]
      })
    },

    // ---- 丢弃演示 2：假想的未来变体 ----------------------------------------------
    {
      delay: 200, dir: 'in', tag: 'artifact_update',
      note: '假想的未来变体，演示未知 sessionUpdate 的处理',
      msg: update({ sessionUpdate: 'artifact_update', artifactId: 'art_1', title: '改动摘要', mimeType: 'text/html' })
    },

    // ---- 计划移除 ---------------------------------------------------------------
    {
      delay: 180, dir: 'in', tag: 'plan_removed',
      msg: update({ sessionUpdate: 'plan_removed', planId: 'plan_validate' })
    },

    // ---- 收尾消息：五种内容块 ------------------------------------------------------
    {
      delay: 240, dir: 'in', tag: 'agent_message_chunk',
      msg: update({ sessionUpdate: 'agent_message_chunk', messageId: 'msg_a3', content: text('完成。校验已插在 cargo build 之前，本地跑通：') })
    },
    {
      delay: 160, dir: 'in', tag: 'agent_message_chunk',
      msg: update({
        sessionUpdate: 'agent_message_chunk', messageId: 'msg_a3',
        content: { type: 'image', mimeType: 'image/svg+xml', data: global.btoa(DEMO_SVG), uri: 'acp://demo/summary.svg' }
      })
    },
    {
      delay: 160, dir: 'in', tag: 'agent_message_chunk',
      msg: update({
        sessionUpdate: 'agent_message_chunk', messageId: 'msg_a3',
        content: {
          type: 'resource_link', uri: 'file:///D:/variFlight_work/AcpAgentClient/scripts/validate.ps1',
          name: 'validate.ps1', title: '改动后的校验脚本', mimeType: 'text/plain', size: 1841
        }
      })
    },
    {
      delay: 160, dir: 'in', tag: 'agent_message_chunk',
      msg: update({
        sessionUpdate: 'agent_message_chunk', messageId: 'msg_a3',
        content: {
          type: 'resource',
          resource: {
            uri: 'file:///D:/variFlight_work/AcpAgentClient/scripts/gen-acp-types.mjs',
            mimeType: 'text/javascript',
            text: 'import { readFileSync } from "node:fs";\n// 从 schema/v1 生成 TS 类型，--check 只比对不写盘\n'
          }
        }
      })
    },
    {
      delay: 160, dir: 'in', tag: 'agent_message_chunk',
      msg: update({
        sessionUpdate: 'agent_message_chunk', messageId: 'msg_a3',
        content: { type: 'audio', mimeType: 'audio/wav', data: 'UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAAB9AAACABAAZGF0YQAAAAA=' }
      })
    },
    { delay: 200, dir: 'stderr', line: '[dsh] turn finished in 6.2s' },

    // ---- 回合结束 ---------------------------------------------------------------
    {
      delay: 220, dir: 'in', tag: 'session/prompt', turn: 'end',
      note: 'unstable_end_turn_token_usage：回合级用量在 PromptResponse 上，不是 session/update',
      msg: {
        jsonrpc: '2.0', id: 2,
        result: {
          stopReason: 'end_turn',
          usage: { totalTokens: 24380, inputTokens: 18240, outputTokens: 5180, thoughtTokens: 960, cachedReadTokens: 14200 }
        }
      }
    }
  ];

  global.ACP_FIXTURE = { sessionId: SESSION, cwd: CWD, steps: steps };
})(window);
