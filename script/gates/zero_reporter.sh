#!/usr/bin/env bash
set -euo pipefail

# Gate G8 — layer purity, reporter half.
#
# Reports every file under app/, lib/, db/, config/ and init.rb that names
# redmine_reporter, Redmineup or up_acts_as_list, and compares that set against the
# committed allowlist.
#
# WARN mode by default, because the integration still exists: reporter is optional,
# not gone, so a handful of files legitimately name it and each says why in
# zero_reporter.allowlist. What the gate enforces is the RATCHET — a file that is not
# on the list is a failure, and a file on the list that no longer needs to be there is
# reported so the list shrinks instead of ossifying. At 1.0 the list should be empty.
#
# Mode:
#   ZERO_REPORTER_MODE=warn    (default) new references fail; a stale allowlist entry warns
#   ZERO_REPORTER_MODE=strict  ANY reference fails, allowlist or not. What 1.0 must pass.
#
# The negative lookahead is load-bearing. A plain grep for "redmine_reporter" matches
# this plugin's own name several hundred times, which is why an earlier version of this
# check was abandoned as unusable noise.

MODE="${ZERO_REPORTER_MODE:-warn}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALLOWLIST="$ROOT/script/gates/zero_reporter.allowlist"
PATTERN='redmineup|Redmineup|up_acts_as_list|redmine_reporter(?!_dashboards)'
SEARCH_PATHS=(app lib db config init.rb)

cd "$ROOT"

if ! command -v rg >/dev/null 2>&1; then
  # grep -P for the lookahead. GNU grep has it; BSD grep does not, so say which tool
  # is missing rather than reporting a clean run that never happened.
  if ! echo 'x' | grep -qP 'x' 2>/dev/null; then
    echo "ERROR: neither ripgrep nor grep -P is available; the negative lookahead cannot be" >&2
    echo "       evaluated and this gate must not report a result it did not compute." >&2
    exit 2
  fi
fi

matches() {
  if command -v rg >/dev/null 2>&1; then
    rg --pcre2 -l "$PATTERN" "${SEARCH_PATHS[@]}" 2>/dev/null || true
  else
    grep -rlP "$PATTERN" "${SEARCH_PATHS[@]}" 2>/dev/null || true
  fi
}

# First whitespace-separated field of each non-comment, non-blank line.
allowed_paths() {
  [ -f "$ALLOWLIST" ] || return 0
  sed -E 's/#.*$//' "$ALLOWLIST" | awk 'NF { print $1 }'
}

FOUND="$(matches | sort -u)"
ALLOWED="$(allowed_paths | sort -u)"

UNLISTED="$(comm -23 <(echo "$FOUND") <(echo "$ALLOWED") | sed '/^$/d')"
STALE="$(comm -13 <(echo "$FOUND") <(echo "$ALLOWED") | sed '/^$/d')"

found_count="$(echo "$FOUND" | sed '/^$/d' | wc -l | tr -d ' ')"
allowed_count="$(echo "$ALLOWED" | sed '/^$/d' | wc -l | tr -d ' ')"

echo "zero_reporter: mode=$MODE  referencing files=$found_count  allowlist entries=$allowed_count"

status=0

if [ -n "$UNLISTED" ]; then
  echo >&2
  echo "FAIL: these files reference the base plugin or the vendor gem and are not on the allowlist:" >&2
  echo "$UNLISTED" | sed 's/^/    /' >&2
  echo >&2
  echo "Either remove the reference, or add the file to $ALLOWLIST with the reason it" >&2
  echo "has to stay. The allowlist is a record of accepted debt, not a mute button." >&2
  status=1
fi

# A ratchet needs to be able to tighten: an entry whose file no longer matches is an
# opportunity to shrink the list, and left alone it turns the allowlist into folklore.
if [ -n "$STALE" ]; then
  echo >&2
  echo "NOTE: these allowlist entries no longer match anything and should be deleted:" >&2
  echo "$STALE" | sed 's/^/    /' >&2
fi

if [ "$MODE" = 'strict' ] && [ "$found_count" != '0' ]; then
  echo >&2
  echo "FAIL (strict): $found_count file(s) still reference the base plugin or the vendor gem." >&2
  echo "$FOUND" | sed 's/^/    /' >&2
  status=1
fi

if [ "$status" = '0' ] && [ -z "$STALE" ]; then
  echo "zero_reporter: OK — every reference is accounted for, and no entry is stale."
fi

exit "$status"
