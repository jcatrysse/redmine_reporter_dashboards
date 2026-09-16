#!/usr/bin/env bash
set -euo pipefail

# Gate — T-43, §Findings M-4. The rule and the reasons are in
# `erb_comment_integrity.rb`, which is Ruby because the check runs ERB's own two-state
# machine over the file — template text, inside a tag — and STATE is not something grep can
# see: M-4's opener was on line 1 and its offending delimiter on line 29.
#
# This wrapper exists for one reason and it is T-38's lesson: a reader that fails to LOAD
# prints nothing and exits non-zero, and a wrapper that read that as "no findings" would
# report OK about a check that never ran. So the status is read three-valued and 2 is a
# hard failure, exactly as `drop_reference_parity.sh` does it.
#
# `erb_comment_integrity_selftest.sh` drives both arms by planting real violations, because
# a gate with no negative test is a gate nobody has seen say no.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
READER="$ROOT/script/gates/erb_comment_integrity.rb"
SEARCH="${ERB_COMMENT_SEARCH_PATH:-app/views}"

cd "$ROOT"

if ! command -v ruby >/dev/null 2>&1; then
  echo "ERROR: no ruby on PATH; this gate must not report a result it did not compute." >&2
  exit 2
fi

if [ ! -f "$READER" ]; then
  echo "ERROR: $READER is missing — nothing was checked." >&2
  exit 2
fi

set +e
ruby "$READER" "$ROOT" "$SEARCH"
STATUS=$?
set -e

case "$STATUS" in
  0) exit 0 ;;
  1) exit 1 ;;
  *)
    echo "erb_comment_integrity: COULD NOT CHECK (reader exited $STATUS)" >&2
    exit 2
    ;;
esac
