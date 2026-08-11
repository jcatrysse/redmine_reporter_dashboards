#!/usr/bin/env bash
# The preflight EXIT-CODE CONTRACT, exercised against real services — §Findings E-27
# row 11. `PreflightCommand` documents three codes (0 verified, 1 failed, 2 nothing
# verified) and they are what a deploy step reads; until this script, no CI run had
# ever read one off a real process. Four cases, each a code the documentation promises:
#
#   0  a named engine against the AUTHENTICATED service            (verified)
#   1  the same engine against the OPEN service, credential set    (a check failed)
#   2  a typo'd engine id                                          (nothing verified)
#   2  a selection that names nothing (`,`) — E-27 row 8's fix     (nothing verified)
#
# Needs: RRD_GOTENBERG_URL (authenticated), RRD_GOTENBERG_OPEN_URL (no auth), and
# RRD_GOTENBERG_USERNAME / RRD_GOTENBERG_PASSWORD — the same variables the conformance
# corpus takes. Deliberately NOT `set -e`: non-zero exits are the subject here, and a
# script that dies on the exit code it exists to read would report nothing.
set -u

cd "$(dirname "$0")/.."

# Exit 3, not 1: "the environment is not set up" and "a case violated the contract"
# must be distinguishable by exit code alone in a local run. CI fails on either.
for var in RRD_GOTENBERG_URL RRD_GOTENBERG_OPEN_URL RRD_GOTENBERG_USERNAME RRD_GOTENBERG_PASSWORD; do
  if [ -z "${!var:-}" ]; then
    echo "FAIL: $var is not set; this contract needs the render-smoke services" >&2
    exit 3
  fi
done

failures=0

# expect_exit <expected-code> <label> <must-contain> [VAR=value ...]
# Runs the standalone driver with the given environment overrides and compares the
# real process exit status — not a return value — against the contract. AND the output
# must carry the sentence that names the intended cause: an adversarial QA pass
# demonstrated the credential arm passing with the open service DEAD ("nothing
# answered" is also exit 1) and passing on a crashed driver (also exit 1). An exit
# code alone cannot tell the finding this script exists to prove from any other
# failure, so each case pins the cause as well as the code.
expect_exit() {
  local expected="$1" label="$2" must_contain="$3"
  shift 3
  local output actual verdict
  output="$(env "$@" ruby script/render_preflight_standalone.rb 2>&1)"
  actual=$?
  verdict=ok
  [ "$actual" -eq "$expected" ] || verdict=FAIL
  if [ -n "$must_contain" ] && ! printf '%s' "$output" | grep -qF "$must_contain"; then
    verdict=FAIL
  fi
  if [ "$verdict" = ok ]; then
    echo "ok   $label -> exit $actual, cause as intended"
  else
    echo "FAIL $label -> exit $actual (expected $expected, output must name: $must_contain)"
    echo "$output" | sed 's/^/     | /'
    failures=$((failures + 1))
  fi
}

expect_exit 0 "gotenberg against the authenticated service" \
  "render preflight: gotenberg" \
  RRD_ENGINE=gotenberg \
  RRD_GOTENBERG_URL="$RRD_GOTENBERG_URL" \
  RRD_GOTENBERG_USERNAME="$RRD_GOTENBERG_USERNAME" \
  RRD_GOTENBERG_PASSWORD="$RRD_GOTENBERG_PASSWORD"

# The credential check must FAIL the run — a credential is configured and the open
# instance answers without it. The pinned sentence is what makes this arm the proof:
# a dead open service and a crashed driver are BOTH exit 1 as well, and both were
# measured satisfying a bare exit-code assertion.
expect_exit 1 "gotenberg against the open service, credential configured" \
  "WITHOUT the configured credential" \
  RRD_ENGINE=gotenberg \
  RRD_GOTENBERG_URL="$RRD_GOTENBERG_OPEN_URL" \
  RRD_GOTENBERG_USERNAME="$RRD_GOTENBERG_USERNAME" \
  RRD_GOTENBERG_PASSWORD="$RRD_GOTENBERG_PASSWORD"

expect_exit 2 "a typo'd engine id" \
  "gotenbrg" \
  RRD_ENGINE=gotenbrg \
  RRD_GOTENBERG_URL="$RRD_GOTENBERG_URL" \
  RRD_GOTENBERG_USERNAME="$RRD_GOTENBERG_USERNAME" \
  RRD_GOTENBERG_PASSWORD="$RRD_GOTENBERG_PASSWORD"

# E-27 row 8: given-but-unparseable used to mean "the default set", silently.
expect_exit 2 "a selection that names nothing (',')" \
  "names no render engine" \
  RRD_ENGINE=',' \
  RRD_GOTENBERG_URL="$RRD_GOTENBERG_URL" \
  RRD_GOTENBERG_USERNAME="$RRD_GOTENBERG_USERNAME" \
  RRD_GOTENBERG_PASSWORD="$RRD_GOTENBERG_PASSWORD"

if [ "$failures" -ne 0 ]; then
  echo "$failures case(s) violated the exit-code contract"
  exit 1
fi
echo "the exit-code contract holds: 0, 1, 2 and 2, each read off a real process"
