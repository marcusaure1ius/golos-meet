#!/bin/sh
# End-to-end test of the golos-qa dsh plugin without any real LLM API or key
# (issue #94). A local OpenAI-compatible mock (test/mock-llm.mjs) plays the
# model; dsh runs headless with the spike overlay pointed at the mock and must:
#   1. register search_meetings + summarize_meeting,
#   2. execute search_meetings and pass real archive quotes/timecodes back,
#   3. execute summarize_meeting (egress gate allows: meeting mapped to an
#      allowSelectedContext project), whose tool calls the mock LLM REST
#      endpoint the same way it calls OpenRouter, and pass the summary back,
#   4. execute summarize_meeting for a meeting WITHOUT project mapping and
#      return the honest egress-gate denial without calling the model (#94),
#   5. include the profile's Russian "answer only in Russian, start with the
#      content" system instruction in what the model sees (issue #103),
#   6. see NO tools besides search_meetings/summarize_meeting in the catalog:
#      the mock fails the case if any built-in harness tool reaches the
#      request (issue #119 "no built-in tools" contract).
set -eu
cd "$(dirname "$0")/.."

PORT=8301
DSH_HOME="$PWD/.dsh-home"
export DSH_HOME
GOLOS_OPENROUTER_BASE_URL="http://127.0.0.1:$PORT/v1"
export GOLOS_OPENROUTER_BASE_URL

# The mock reads MOCK_TOOL from its own environment (which tool it forces the
# agent to call), so it restarts per case.
MOCK_PID=""
start_mock() {
  MOCK_TOOL="$1" node test/mock-llm.mjs "$PORT" &
  MOCK_PID=$!
  sleep 1
}
stop_mock() {
  if [ -n "$MOCK_PID" ]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  MOCK_PID=""
  sleep 0.3
}
trap 'stop_mock' EXIT

run_case() {
  OPENROUTER_API_KEY=mock-key npx --no-install @deepseek-ai/dsh headless \
    --patch ./test/dsh-patch.mock.yml "О чём договорились по прайсингу за ноябрь?" 2>/dev/null
}

FAIL=0
check() {
  case "$2" in *MOCK-E2E-OK*) echo "PASS: $1" ;; *) echo "FAIL: $1"; FAIL=1 ;; esac
}

start_mock search_meetings
OUT1=$(run_case)
echo "--- search_meetings: $OUT1"
check search_meetings "$OUT1"
stop_mock

start_mock summarize_meeting
OUT2=$(run_case)
echo "--- summarize_meeting: $OUT2"
check summarize_meeting "$OUT2"
stop_mock

start_mock summarize_denied
OUT3=$(run_case)
echo "--- summarize_denied: $OUT3"
check summarize_denied "$OUT3"
stop_mock

exit "$FAIL"
