/**
 * Profile-contract assertions for the composed golos dsh profile (issue #119).
 *
 * Reads `dsh golos --patch ./dsh-patch.yml --dump-config` output on stdin and
 * asserts the spike's "no built-in tools" contract:
 *   1. every built-in tool-providing host row is disabled: true;
 *   2. every shipped agent preset is overridden to infrastructure-only plugins
 *      (time context + compaction) — no dsh-tool-*, no skills, no persona;
 *   3. the golos-qa plugin row is present.
 *
 * The dump is the launcher's own text rendering of the composed Cordis entry
 * tree (top-level `- id:` rows, nested config indented below them, layer
 * markers as `# == …` comment lines between rows). The parser below keeps to
 * that shape on purpose: the dsh package does not ship a machine-readable
 * composition API, and a full YAML dependency for one test is not warranted.
 *
 * Usage (see test/profile-contract.sh):
 *   dsh golos --patch ./dsh-patch.yml --dump-config | node test/profile-contract.mjs
 */

import { stdin } from 'node:process'

const dump = await new Promise((resolve, reject) => {
  let text = ''
  stdin.setEncoding('utf8')
  stdin.on('data', (chunk) => { text += chunk })
  stdin.on('end', () => resolve(text))
  stdin.on('error', reject)
})

/** Parse top-level `- id:` rows; each row's body is its indented lines. */
function parseRows(text) {
  const rows = new Map()
  let current = null
  for (const line of text.split('\n')) {
    const top = line.match(/^- id: (\S+)/)
    if (top) {
      current = top[1]
      rows.set(current, [])
      continue
    }
    if (current === null) continue
    if (line === '' || line.startsWith('#')) continue // layer marker between rows
    if (/^\s/.test(line)) rows.get(current).push(line)
    else current = null // non-indented, non-row text: stop attaching
  }
  return rows
}

const rows = parseRows(dump)

let failures = 0
function check(ok, label) {
  console.log(`${ok ? 'PASS' : 'FAIL'}: ${label}`)
  if (!ok) failures += 1
}

// 1. Built-in tool rows must be disabled at the host plane. This is the same
// disable list dsh-patch.yml carries (and the web bundle applies for web);
// test/dsh-patch.mock.yml mirrors it for the headless profile.
const requiredDisabled = [
  'tool-plugin-manager',
  'tool-bash',
  'tool-pwsh',
  'tool-jobs',
  'tool-fs',
  'tool-fs-search',
  'skill-filesystem',
  'tool-skill',
  'command-goal',
  'tool-goal',
  'plan-mode',
  'tool-subagent-control',
  'tool-subagent',
  'tool-subagent-fork',
  'workflow-ptc',
  'tool-workflow',
  'tool-todo',
  'tool-web',
  'tool-working-directory',
  'mcp-resources',
]
for (const id of requiredDisabled) {
  const body = rows.get(id)?.join('\n')
  check(body !== undefined && body.includes('disabled: true'),
    `host row ${id} disabled: true`)
}

// 2. Every shipped preset is overridden to infrastructure-only plugins.
const allowedPresetPlugins = new Set([
  '@deepseek-ai/dsh-time-context',
  '@deepseek-ai/dsh-compaction-basic',
  '@deepseek-ai/dsh-command-compact',
  '@deepseek-ai/dsh-compaction-tool-result-pruner',
  'cordis:group', // the nested compaction group marker
])
const forbiddenPluginPattern = /dsh-(tool-|skill-filesystem|persona|plan-mode|plugin-manager|agent-instructions)/
for (const preset of ['preset-standard', 'preset-ptc', 'preset-minimal', 'preset-cordis']) {
  const body = rows.get(preset)?.join('\n') ?? ''
  const names = [...body.matchAll(/name:\s*'?([\w:@/.-]+)'?/g)].map((m) => m[1])
  const mounted = names.filter((n) => n !== '@deepseek-ai/dsh-agent-preset')
  const onlyAllowed = mounted.every((n) => allowedPresetPlugins.has(n))
  const noneForbidden = mounted.every((n) => !forbiddenPluginPattern.test(n))
  check(mounted.length > 0 && onlyAllowed && noneForbidden,
    `${preset} mounts only infrastructure plugins (got: ${mounted.join(', ') || 'none'})`)
}

// 3. The golos-qa plugin is registered.
check(rows.has('golos-qa'), 'golos-qa plugin row present')

// 4. No other top-level row still looks like a live built-in tool provider.
// `tools` (the registry) and `tool-executor-native` (the executor that
// dispatches the golos tools) must stay mounted; `tool-result-pruner` is the
// compaction backend (no model tool), and `tool-executor-ptc` stays disabled
// by dsh-base itself.
const requiredLive = new Set(['tools', 'tool-executor-native', 'tool-result-pruner'])
const liveToolish = [...rows.entries()]
  .filter(([id]) => /^tool-|^skill-filesystem$|^workflow-|^plan-mode$|^mcp-resources$/.test(id))
  .filter(([id, body]) => !requiredLive.has(id) && !body.join('\n').includes('disabled: true'))
  .map(([id]) => id)
check(liveToolish.length === 0, `no other live tool-like rows (got: ${liveToolish.join(', ') || 'none'})`)

if (failures > 0) {
  console.log(`profile-contract: ${failures} assertion(s) failed`)
  process.exit(1)
}
console.log('profile-contract: OK')
