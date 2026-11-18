/**
 * Minimal OpenAI-compatible *streaming* chat-completions mock for the dsh
 * spike e2e test (issue #94). pi-ai consumes SSE, so the mock streams:
 *   1. first call  -> one assistant turn asking for a tool (MOCK_TOOL decides
 *                     which: search_meetings, summarize_meeting on an allowed
 *                     meeting, or summarize_meeting on a policy-unmapped
 *                     meeting to verify the egress-gate denial, issue #94);
 *   2. second call -> final text once a tool result is in the messages.
 *
 * The test asserts that dsh sent the spike's tools in the request, that the
 * executed tool result (real archive quotes/timecodes, or the honest
 * egress-gate denial) reached the model, and that the profile's Russian
 * language instruction is part of the system prompt (issue #103).
 * No external API and no real key involved.
 *
 * Usage: MOCK_TOOL=search_meetings node test/mock-llm.mjs [port]  (default 8301)
 */

import http from 'node:http'

const port = Number(process.argv[2] ?? 8301)
const mockTool = process.env.MOCK_TOOL ?? 'search_meetings'

function sseChunks(response, writeChunk, finishReason, finalContent) {
  response.writeHead(200, {
    'content-type': 'text/event-stream',
    'cache-control': 'no-cache',
    connection: 'keep-alive',
  })
  const frame = (delta, finish) => JSON.stringify({
    id: 'mock', object: 'chat.completion.chunk', created: 0, model: 'mock',
    choices: [{ index: 0, delta, finish_reason: finish ?? null }],
  })
  response.write(`data: ${frame({ role: 'assistant' })}\n\n`)
  writeChunk(response)
  response.write(`data: ${frame({}, finishReason)}\n\n`)
  response.write('data: [DONE]\n\n')
  response.end()
}

const server = http.createServer((request, response) => {
  let body = ''
  request.on('data', (chunk) => { body += chunk })
  request.on('end', () => {
    if (!request.url.includes('/chat/completions')) {
      response.writeHead(404).end('{"error":{"message":"not found"}}')
      return
    }
    let payload
    try { payload = JSON.parse(body) } catch { payload = {} }
    const agentRequest = Array.isArray(payload.tools) && payload.tools.length > 0
    if (!agentRequest) {
      // Direct REST call from the summarize_meeting tool: answer with a fixed
      // summary the tool passes through to the agent conversation.
      console.log('[mock] plugin summarize REST call -> fixed summary')
      response.writeHead(200, { 'content-type': 'application/json' })
      response.end(JSON.stringify({
        id: 'mock-rest', object: 'chat.completion', created: 0, model: payload.model ?? 'mock',
        choices: [{ index: 0, finish_reason: 'stop', message: { role: 'assistant', content: 'MOCK-SUMMARY-OK: встреча была про прайсинг и ноябрьские договорённости.' } }],
        usage: { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 },
      }))
      return
    }
    const requestedTools = (payload.tools ?? []).map((tool) => tool?.function?.name).filter(Boolean)
    const hasSpikes = requestedTools.includes('search_meetings') && requestedTools.includes('summarize_meeting')
    // Issue #119: the model-visible catalog must contain ONLY the golos-qa
    // tools — any built-in harness tool here is a contract violation (it gave
    // the agent filesystem/terminal reach and triggered TCC prompts).
    const nonGolosTools = requestedTools.filter((name) => name !== 'search_meetings' && name !== 'summarize_meeting')
    console.log(`[mock] model=${payload.model ?? '?'} tools=${requestedTools.length} spike-tools=${hasSpikes} non-golos-tools=${nonGolosTools.length ? nonGolosTools.join(',') : 'none'}`)

    const messages = payload.messages ?? []
    const toolMessage = messages.find((message) => message.role === 'tool')

    if (toolMessage !== undefined) {
      const text = typeof toolMessage?.content === 'string'
        ? toolMessage.content
        : JSON.stringify(toolMessage?.content ?? '')
      console.log(`[mock] tool result seen by model: ${text.slice(0, 300)}`)
      // Issue #103: the profile's Russian "start with content" instruction
      // must be part of what the model sees (system prompt in the request).
      const systemText = messages
        .filter((message) => message.role === 'system')
        .map((message) => (typeof message.content === 'string' ? message.content : JSON.stringify(message.content)))
        .join('\n')
      const hasLanguageInstruction = systemText.includes('Отвечай только на русском языке')
      console.log(`[mock] system prompt has golos language instruction: ${hasLanguageInstruction}`)
      let valid
      let answer
      if (mockTool === 'summarize_denied') {
        // The egress gate must deny without any model call: the honest denial
        // text in the tool result is the proof (a summary would mean the
        // plugin called the mock's REST endpoint for a forbidden meeting).
        valid = text.includes('запрещена политикой проекта')
        answer = valid
          ? 'MOCK-E2E-OK: summarize_meeting вернул честный отказ по политике проекта.'
          : 'MOCK-E2E-FAIL: egress gate did not deny the unmapped meeting.'
      } else if (mockTool === 'summarize_meeting') {
        valid = text.includes('MOCK-SUMMARY-OK') && text.includes('реплик')
        answer = valid
          ? 'MOCK-E2E-OK: summarize_meeting вернул сводку встречи.'
          : 'MOCK-E2E-FAIL: tool result did not contain the expected summary.'
      } else {
        valid = text.includes('2026-') && text.includes('прайсинг')
        answer = valid
          ? 'MOCK-E2E-OK: в ноябре обсуждали прайсинг; таймкоды и цитаты — в tool-результате.'
          : 'MOCK-E2E-FAIL: tool result did not contain expected archive data.'
      }
      if (!hasLanguageInstruction) valid = false
      if (nonGolosTools.length > 0) valid = false
      console.log(`[mock] verdict: ${valid ? 'OK' : 'FAIL'}`)
      sseChunks(
        response,
        (res) => res.write(`data: ${JSON.stringify({
          id: 'mock', object: 'chat.completion.chunk', created: 0, model: 'mock',
          choices: [{ index: 0, delta: { content: answer }, finish_reason: null }],
        })}\n\n`),
        'stop',
      )
      return
    }
    const forcedArguments = mockTool === 'summarize_denied'
      ? { meetingId: '2026-11-02_14-01-54' } // real meeting, no project mapping -> gate must deny
      : mockTool === 'summarize_meeting'
        ? { meetingId: '2026-11-13_15-04-05' } // mapped to the allowSelectedContext project
        : { query: 'прайсинг за ноябрь', since: '2026-11-01', until: '2026-11-30' }
    const toolCall = {
      name: mockTool === 'summarize_denied' ? 'summarize_meeting' : mockTool,
      arguments: JSON.stringify(forcedArguments),
    }
    sseChunks(
      response,
      (res) => res.write(`data: ${JSON.stringify({
        id: 'mock', object: 'chat.completion.chunk', created: 0, model: 'mock',
        choices: [{
          index: 0, delta: {
            tool_calls: [{
              index: 0, id: 'call-mock-1', type: 'function',
              function: toolCall,
            }],
          }, finish_reason: null,
        }],
      })}\n\n`),
      'tool_calls',
    )
  })
})

server.listen(port, '127.0.0.1', () => console.log(`[mock] listening on http://127.0.0.1:${port}/v1`))
