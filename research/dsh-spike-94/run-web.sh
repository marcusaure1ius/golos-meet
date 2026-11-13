#!/bin/sh
# Golos Meet dsh spike launcher (issue #94).
#
# Boots the "golos" dsh profile (a copy of the shipped web profile) with the
# spike overlay ./dsh-patch.yml: the golos-qa plugin (search_meetings,
# summarize_meeting) and the OpenRouter DeepSeek V4.1 Flash default model.
#
# The OpenRouter key is pulled from the QA Keychain item into the process
# environment of dsh only. It is never written to a file, a log, or this script.
set -eu
cd "$(dirname "$0")"

DSH_HOME="$PWD/.dsh-home"
export DSH_HOME

if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  OPENROUTER_API_KEY="$(security find-generic-password \
    -w -s golos-meet.qa.b2c0b2c1c6e2413cba82e061cdb9cd97 -a openrouter-api-key)"
  export OPENROUTER_API_KEY
fi

# First run: create the golos profile from the shipped web template.
if [ ! -f "$DSH_HOME/profiles/golos/cordis.yml" ]; then
  npx --no-install @deepseek-ai/dsh golos --from-default-profile web --dump-config >/dev/null
fi

exec npx --no-install @deepseek-ai/dsh golos \
  --patch ./dsh-patch.yml \
  --host 127.0.0.1 --port 3080 --no-open "$@"
