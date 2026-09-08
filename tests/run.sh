#!/usr/bin/env bash
# tests/run.sh - run every tests/*.test.sh and report the combined result.
#
#   ./tests/run.sh              run everything, report what was skipped
#   ./tests/run.sh --strict     treat any skipped check as a failure
#
# --strict is what CI uses: a suite that skips most of its checks because the
# tools they need are absent must not be able to report success.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TALLY=$(mktemp "${TMPDIR:-/tmp}/dotfiles-test-tally.XXXXXX")
trap 'rm -f "$TALLY"' EXIT
export DOTFILES_TEST_TALLY="$TALLY"

status=0
for suite in "$ROOT"/tests/*.test.sh; do
  printf '# %s\n' "${suite#"$ROOT"/}"
  /bin/bash "$suite" "$@" || status=1
done

passed=0
skipped=0
while read -r p s; do
  passed=$((passed + p))
  skipped=$((skipped + s))
done <"$TALLY"

printf '\n# total: %d ok, %d skipped\n' "$passed" "$skipped"
exit "$status"
