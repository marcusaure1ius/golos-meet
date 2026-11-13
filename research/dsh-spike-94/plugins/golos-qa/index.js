/**
 * golos-qa — dsh plugin over the Golos Meet QA archive (issue #94).
 *
 * Two model-facing tools:
 *  - search_meetings: FTS5 query over the QA knowledge.sqlite
 *    (table knowledge_fts), returns quotes + timecodes + source meeting ids.
 *  - summarize_meeting: reads meetings/<id>/transcript.json and returns a
 *    compressed summary via the OpenRouter chat API (DeepSeek V4.1 Flash).
 *
 * The OpenRouter key arrives only through the process environment
 * (OPENROUTER_API_KEY); this file never reads, stores, or logs it.
 * The archive path can be overridden with GOLOS_QA_ARCHIVE.
 */

import { DatabaseSync } from 'node:sqlite'
import { readFile } from 'node:fs/promises'
import path from 'node:path'
import os from 'node:os'

export const name = 'golos-qa'
export const inject = ['tools']

const ARCHIVE = process.env.GOLOS_QA_ARCHIVE
  ?? path.join(os.homedir(), 'Library', 'Application Support',
    'golos-meet-qa-b2c0b2c1c6e2413cba82e061cdb9cd97')

// Test hook for the local mock; production default is OpenRouter.
const OPENROUTER_BASE_URL = process.env.GOLOS_OPENROUTER_BASE_URL ?? 'https://openrouter.ai/api/v1'
const OPENROUTER_MODEL = process.env.GOLOS_SPIKE_MODEL ?? 'deepseek/deepseek-v4.1-flash'

const MIN_QUOTE_CHARS = 5 // issue #93 P3: drop empty-segment noise
const DEFAULT_LIMIT = 8
const MAX_LIMIT = 25

let cachedDb
function openArchiveDb() {
  if (cachedDb !== undefined) return cachedDb
  const file = path.join(ARCHIVE, 'knowledge.sqlite')
  cachedDb = new DatabaseSync(file, { readOnly: true })
  return cachedDb
}

/**
 * Split free text into quoted-prefix FTS5 tokens ("word*"). Long Russian words
 * lose trailing inflection endings (vowels and soft sign) so the prefix covers
 * the word family: «прайсингу» → «прайсинг» matches прайсинг/прайсинга;
 * «договорились» → «договорил» matches договорились/договорили.
 */
function queryWords(rawQuery) {
  return String(rawQuery)
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter((word) => word.length >= 4)
    .map((word) => {
      let stem = word.replace(/"/g, '')
      if (stem.length >= 7) {
        while (stem.length >= 6 && /[аяоеиуьюы]$/.test(stem)) stem = stem.slice(0, -1)
      }
      return `"${stem}*"`
    })
}

function formatTimecode(seconds) {
  const total = Math.max(0, Math.floor(seconds))
  const minutes = Math.floor(total / 60)
  const rest = total % 60
  return `${String(minutes).padStart(2, '0')}:${String(rest).padStart(2, '0')}`
}

async function meetingTitle(meetingId) {
  try {
    const raw = await readFile(path.join(ARCHIVE, 'meetings', meetingId, 'meta.json'), 'utf8')
    const meta = JSON.parse(raw)
    return typeof meta.title === 'string' && meta.title.trim() !== '' ? meta.title : null
  } catch {
    return null
  }
}

export const search_meetings = {
  name: 'search_meetings',
  description:
    'Полнотекстовый поиск (FTS5) по расшифровкам встреч QA-архива Golos Meet. ' +
    'Возвращает цитаты с таймкодами (мм:сс от начала записи) и id встречи-источника. ' +
    'Используй для ответов «о чём договорились…», «что говорили про…». ' +
    'Параметры: query — текст запроса обычными словами; since/until — фильтр по дате встречи (YYYY-MM-DD); ' +
    'limit — сколько цитат вернуть (по умолчанию 8).',
  parameters: {
    type: 'object',
    properties: {
      query: { type: 'string', description: 'Поисковый запрос, обычными словами (русский/английский).' },
      since: { type: 'string', description: 'Включительно, дата встречи YYYY-MM-DD.' },
      until: { type: 'string', description: 'Включительно, дата встречи YYYY-MM-DD.' },
      limit: { type: 'number', description: 'Максимум цитат (8 по умолчанию, до 25).' },
    },
    required: ['query'],
    additionalProperties: false,
  },
  output: {
    schema: {
      type: 'object',
      properties: {
        query: { type: 'string' },
        totalFound: { type: 'number' },
        matches: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              meetingId: { type: 'string' },
              meetingTitle: { type: 'string' },
              timecode: { type: 'string' },
              startSeconds: { type: 'number' },
              endSeconds: { type: 'number' },
              quote: { type: 'string' },
            },
            required: ['meetingId', 'timecode', 'startSeconds', 'endSeconds', 'quote'],
          },
        },
      },
      required: ['query', 'totalFound', 'matches'],
    },
    render(_args, value) {
      if (!value.matches || value.matches.length === 0) {
        return [{ type: 'text', text: `По запросу «${value.query}» совпадений не найдено.` }]
      }
      const lines = value.matches.map((match, index) => {
        const title = match.meetingTitle ? ` (${match.meetingTitle})` : ''
        return `${index + 1}. [${match.timecode}] ${match.meetingId}${title}: «${match.quote}»`
      })
      return [{
        type: 'text',
        text: `Найдено ${value.totalFound} совпадений; показаны ${value.matches.length}:\n${lines.join('\n')}`,
      }]
    },
  },
  timeoutMs: 30000,
  async execute(args, exec) {
    if (typeof args.query !== 'string' || args.query.trim() === '') {
      throw new Error('search_meetings: query must be a non-empty string')
    }
    const words = queryWords(args.query)
    if (words.length === 0) {
      return { query: args.query, totalFound: 0, matches: [] }
    }
    const limit = Math.min(Math.max(Number.isFinite(args.limit) ? Math.trunc(args.limit) : DEFAULT_LIMIT, 1), MAX_LIMIT)

    const dateOr = (value, fallback) =>
      typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value) ? value : fallback
    const conditions = [
      'source_key LIKE \'meeting:%\'',
      'length(trim(c.text)) >= ?',
      `source_key >= 'meeting:${dateOr(args.since, '0000-00-00')}'`,
      `source_key <= 'meeting:${dateOr(args.until, '9999-99-99')}~'`,
    ]
    const sql =
      'SELECT c.rowid, c.source_key, c.location, c.text, bm25(knowledge_fts) AS rank ' +
      'FROM knowledge_fts f JOIN embedding_chunks c ON c.rowid = f.rowid ' +
      `WHERE knowledge_fts MATCH ? AND ${conditions.join(' AND ')} ` +
      'ORDER BY rank LIMIT ?'

    const db = openArchiveDb()
    const surplus = limit + 40 // fetch a surplus, interleave meetings, then cut
    const runQuery = (ftsQuery) => db.prepare(sql).all(ftsQuery, MIN_QUOTE_CHARS, surplus)

    // Pass 1: all words together (precision). Pass 2: any word (recall), used
    // only when the precise pass is thin; common-word noise ("Договорились.")
    // then sinks below the AND hits.
    const stems = queryWords(args.query).map((word) => word.slice(1, -2)) // strip quotes and trailing *
    const matchedWords = (text) => {
      const lower = text.toLowerCase()
      return stems.reduce((count, stem) => count + (lower.includes(stem) ? 1 : 0), 0)
    }
    const andRows = runQuery(words.join(' AND '))
    exec.signal.throwIfAborted()
    const seen = new Set(andRows.map((row) => row.rowid))
    let orRows = []
    if (andRows.length < limit) {
      orRows = runQuery(words.join(' OR ')).filter((row) => !seen.has(row.rowid))
      exec.signal.throwIfAborted()
      // bm25 alone boosts short generic replies ("Договорились."); rows that
      // match more of the query words carry the actual topic, so they first.
      orRows.sort((a, b) => (matchedWords(b.text) - matchedWords(a.text)) || (a.rank - b.rank))
    }
    const totalFound = andRows.length + orRows.length

    const byMeeting = new Map()
    for (const row of [...andRows, ...orRows]) {
      const meetingId = row.source_key.slice('meeting:'.length)
      if (!byMeeting.has(meetingId)) byMeeting.set(meetingId, [])
      if (byMeeting.get(meetingId).length >= 3) continue // cap quotes per meeting
      let startSeconds = 0
      let endSeconds = 0
      try {
        const location = JSON.parse(row.location)
        startSeconds = Number(location.startSeconds) || 0
        endSeconds = Number(location.endSeconds) || startSeconds
      } catch { /* keep zeros */ }
      byMeeting.get(meetingId).push({
        meetingId,
        timecode: formatTimecode(startSeconds),
        startSeconds,
        endSeconds,
        quote: row.text.trim(),
      })
    }

    const matches = []
    for (const [meetingId, quotes] of byMeeting) {
      const title = await meetingTitle(meetingId)
      for (const quote of quotes) {
        if (title !== null) quote.meetingTitle = title
        matches.push(quote)
        if (matches.length >= limit) break
      }
      if (matches.length >= limit) break
    }
    return { query: args.query, totalFound, matches }
  },
}

export const summarize_meeting = {
  name: 'summarize_meeting',
  description:
    'Сжатая сводка одной встречи QA-архива Golos Meet по её id (формат YYYY-MM-DD_HH-MM-SS). ' +
    'Читает полный транскрипт и сжимает его моделью (DeepSeek V4.1 Flash через OpenRouter): ' +
    'о чём говорили, ключевые договорённости и решения. search_meetings возвращает нужные meetingId.',
  parameters: {
    type: 'object',
    properties: {
      meetingId: { type: 'string', description: 'id встречи, например 2026-11-10_14-01-40.' },
      focus: { type: 'string', description: 'Необязательный фокус сводки, например «прайсинг».' },
    },
    required: ['meetingId'],
    additionalProperties: false,
  },
  output: {
    schema: {
      type: 'object',
      properties: {
        meetingId: { type: 'string' },
        segments: { type: 'number' },
        summary: { type: 'string' },
      },
      required: ['meetingId', 'segments', 'summary'],
    },
    render(_args, value) {
      return [{ type: 'text', text: `Сводка встречи ${value.meetingId} (${value.segments} реплик):\n\n${value.summary}` }]
    },
  },
  timeoutMs: 180000,
  async execute(args, exec) {
    if (typeof args.meetingId !== 'string' || !/^[\w-]+$/.test(args.meetingId)) {
      throw new Error('summarize_meeting: meetingId must be a folder id like 2026-11-10_14-01-40')
    }
    const apiKey = process.env.OPENROUTER_API_KEY
    if (typeof apiKey !== 'string' || apiKey === '') {
      throw new Error('summarize_meeting: OPENROUTER_API_KEY is not set in the dsh process environment')
    }
    const file = path.join(ARCHIVE, 'meetings', args.meetingId, 'transcript.json')
    let transcript
    try {
      transcript = JSON.parse(await readFile(file, 'utf8'))
    } catch (error) {
      throw new Error(`summarize_meeting: cannot read transcript for ${args.meetingId}: ${String(error)}`)
    }
    const segments = Array.isArray(transcript.segments) ? transcript.segments : []
    if (segments.length === 0) {
      throw new Error(`summarize_meeting: transcript for ${args.meetingId} has no segments`)
    }
    const speakerLabel = (speaker) => (speaker === 'me' ? 'Я' : 'Участник')
    const MAX_CHARS = 60000
    let text = ''
    let used = 0
    for (const segment of segments) {
      const line = `[${formatTimecode(Number(segment.start) || 0)}] ${speakerLabel(segment.speaker)}: ${String(segment.text).trim()}\n`
      if (text.length + line.length > MAX_CHARS) break
      text += line
      used += 1
    }
    const focus = typeof args.focus === 'string' && args.focus.trim() !== ''
      ? ` Особое внимание — теме: ${args.focus.trim()}.`
      : ''
    const systemPrompt =
      'Ты — ассистент по встречам Golos Meet. Сжми транскрипт встречи в сводку на русском: ' +
      '1) тема встречи одним предложением; 2) ключевые договорённости и решения списком (без повторов); ' +
      '3) важные цифры, сроки и ответственных. Не выдумывай: всё, что не прозвучало, не упоминай. ' +
      'Отвечай готовым текстом без markdown-разметки заголовков уровня #.'
    const userPrompt = `Транскрипт встречи ${args.meetingId}:\n\n${text}\nСделай сводку.${focus}`

    const response = await fetch(`${OPENROUTER_BASE_URL}/chat/completions`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${apiKey}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        model: OPENROUTER_MODEL,
        messages: [
          { role: 'system', content: systemPrompt },
          { role: 'user', content: userPrompt },
        ],
        max_tokens: 2000,
        temperature: 0.2,
      }),
      signal: exec.signal,
    })
    if (!response.ok) {
      const body = await response.text().catch(() => '')
      throw new Error(`summarize_meeting: OpenRouter API error ${response.status}: ${body.slice(0, 300)}`)
    }
    const payload = await response.json()
    const summary = payload?.choices?.[0]?.message?.content
    if (typeof summary !== 'string' || summary === '') {
      throw new Error('summarize_meeting: OpenRouter returned an empty completion')
    }
    return { meetingId: args.meetingId, segments: used, summary: summary.trim() }
  },
}

export function apply(ctx) {
  ctx.tools.register(search_meetings)
  ctx.tools.register(summarize_meeting)
}
