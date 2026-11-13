/**
 * Minimal OpenAI-compatible *streaming* chat-completions mock for the dsh
 * spike e2e test (issue #94). pi-ai consumes SSE, so the mock streams:
 *   1. first call  -> one assistant turn asking for the search_meetings tool;
 *   2. second call -> final text once a tool result is in the messages.
 *
 * The test asserts that dsh sent the spike's tools in the request and that the
 * executed tool result (real archive quotes + timecodes) reached the model.
 * No external API and no real key involved.
 *
 * Usage: node test/mock-llm.mjs [port]   (default 8301)
 */

import http from 'node:http'

const port = Number(process.argv[2] ?? 8301)

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
    console.log(`[mock] model=${payload.model ?? '?'} tools=${requestedTools.length} spike-tools=${hasSpikes}`)

    const messages = payload.messages ?? []
    const toolMessage = messages.find((message) => message.role === 'tool')

    if (toolMessage !== undefined) {
      const text = typeof toolMessage?.content === 'string'
        ? toolMessage.content
        : JSON.stringify(toolMessage?.content ?? '')
      console.log(`[mock] tool result seen by model: ${text.slice(0, 400)}`)
      const expectSummary = process.env.MOCK_TOOL === 'summarize_meeting'
      const valid = expectSummary
        ? text.includes('MOCK-SUMMARY-OK') && text.includes('реплик')
        : text.includes('2026-') && text.includes('прайсинг')
      const answer = valid
        ? (expectSummary
          ? 'MOCK-E2E-OK: summarize_meeting вернул сводку встречи.'
          : 'MOCK-E2E-OK: в ноябре обсуждали прайсинг; таймкоды и цитаты — в tool-результате.')
        : 'MOCK-E2E-FAIL: tool result did not contain expected archive data.'
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
    const toolCall = process.env.MOCK_TOOL === 'summarize_meeting'
      ? { name: 'summarize_meeting', arguments: JSON.stringify({ meetingId: '2026-11-13_15-04-05' }) }
      : { name: 'search_meetings', arguments: JSON.stringify({ query: 'прайсинг за ноябрь', since: '2026-11-01', until: '2026-11-30' }) }
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
