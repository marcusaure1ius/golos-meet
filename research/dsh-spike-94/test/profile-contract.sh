#!/bin/sh
# Profile-contract test of the golos dsh profile (issue #119): the composed
# tree (bundles + spike overlay) must expose ONLY the golos-qa tools to the
# model. Boots nothing: the launcher composes the tree and prints it, and
# test/profile-contract.mjs asserts the row states.
#
#   1. every built-in tool-providing host row is disabled: true;
#   2. every shipped agent preset is overridden to infrastructure-only plugins;
#   3. the golos-qa plugin row is present.
set -eu
cd "$(dirname "$0")/.."

DSH_HOME="$PWD/.dsh-home"
export DSH_HOME

# First run: create the golos profile from the shipped web template (no boot),
# the same first-run step run-web.sh performs.
if [ ! -f "$DSH_HOME/profiles/golos/cordis.yml" ]; then
  npx --no-install @deepseek-ai/dsh golos --from-default-profile web --dump-config >/dev/null
fi

npx --no-install @deepseek-ai/dsh golos --patch ./dsh-patch.yml --dump-config \
  | node test/profile-contract.mjs
