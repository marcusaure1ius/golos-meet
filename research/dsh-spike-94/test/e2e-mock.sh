#!/bin/sh
# End-to-end test of the golos-qa dsh plugin without any real LLM API or key
# (issue #94). A local OpenAI-compatible mock (test/mock-llm.mjs) plays the
# model; dsh runs headless with the spike overlay pointed at the mock and must:
#   1. register search_meetings + summarize_meeting,
#   2. execute search_meetings and pass real archive quotes/timecodes back,
#   3. execute summarize_meeting, whose tool calls the mock LLM REST endpoint
#      the same way it calls OpenRouter, and pass the summary back.
set -eu
cd "$(dirname "$0")/.."

PORT=8301
DSH_HOME="$PWD/.dsh-home"
export DSH_HOME
GOLOS_OPENROUTER_BASE_URL="http://127.0.0.1:$PORT/v1"
export GOLOS_OPENROUTER_BASE_URL

node test/mock-llm.mjs "$PORT" &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null' EXIT
sleep 1

run_case() {
  MOCK_TOOL="$1" OPENROUTER_API_KEY=mock-key npx --no-install @deepseek-ai/dsh headless \
    --patch ./test/dsh-patch.mock.yml "О чём договорились по прайсингу за ноябрь?" 2>/dev/null
}

FAIL=0
OUT1=$(run_case search_meetings)
echo "--- search_meetings: $OUT1"
case "$OUT1" in *MOCK-E2E-OK*) echo "PASS: search_meetings" ;; *) echo "FAIL: search_meetings"; FAIL=1 ;; esac

OUT2=$(run_case summarize_meeting)
echo "--- summarize_meeting: $OUT2"
case "$OUT2" in *MOCK-E2E-OK*) echo "PASS: summarize_meeting" ;; *) echo "FAIL: summarize_meeting"; FAIL=1 ;; esac

exit "$FAIL"
