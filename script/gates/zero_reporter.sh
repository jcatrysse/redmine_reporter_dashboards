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
# on the list is a failure, AND a file on the list that no longer needs to be there is a
# failure too, so the list can only shrink.
#
# Mode:
#   ZERO_REPORTER_MODE=warn    (default) an unlisted file fails; a STALE entry fails
#   ZERO_REPORTER_MODE=strict  any reference outside the `[permanent]` set fails.
#                              What 1.0 must pass.
#
# --- WHY A STALE ENTRY IS A FAILURE AND NOT A NOTE (T-26, 2026-08-08) ---
#
# It was a NOTE, and a note is what a ratchet cannot be made of. The allowlist's own
# header says "this list may only SHRINK"; nothing enforced that, so an entry whose file
# had been cleaned up could sit there indefinitely, and the next person to add a
# reference to that file would find it already permitted. Failing on a stale entry is the
# difference between a record of accepted debt and folklore. It costs one deletion when
# it fires, and the failure message says which line to delete.
#
# --- WHY STRICT IGNORES `[permanent]`, AND WHO DECIDED THAT (T-26, 2026-08-08) ---
#
# Strict used to mean "ANY reference fails, allowlist or not", described as "what 1.0 must
# pass". **It could never pass.** The curator decided on 2026-08-05 that the 1.0 target is
# *empty except the importer* — reading the base plugin's data by name is what the importer
# is FOR, so those references are the opposite of coupling and are not going away. A flag
# that can never be switched on is not a target, it is a comment.
#
# So strict now means what the curator's decision actually implies: **no coupling outside
# the permanently-exempt set**. An allowlist entry whose reason begins `[permanent]` is
# exempt from strict; every other entry is debt that strict refuses. That makes strict
# REACHABLE — after T-30…T-32 own the reporting surface and the integration entries go —
# rather than aspirational.
#
# The exemption is deliberately narrow and deliberately visible: it is written per entry,
# in the file a reviewer reads, not as a path pattern hidden in this script.
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

# The paths whose REASON begins `[permanent]` — the set strict mode exempts. Matched on
# the reason rather than on the path so that the exemption is a stated decision about a
# file, visible in the line a reviewer reads.
permanent_paths() {
  [ -f "$ALLOWLIST" ] || return 0
  sed -E 's/#.*$//' "$ALLOWLIST" | awk 'NF && $2 == "[permanent]" { print $1 }'
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

# A ratchet has to be able to tighten, and only tighten. An entry whose file no longer
# matches is a permission nobody needs any more, and leaving it costs the next person who
# adds a reference to that file: the gate would wave it through.
if [ -n "$STALE" ]; then
  echo >&2
  echo "FAIL: these allowlist entries no longer match anything. Delete them —" >&2
  echo "      the list may only shrink, and an entry that permits nothing today is one" >&2
  echo "      that silently permits something tomorrow:" >&2
  echo "$STALE" | sed 's/^/    /' >&2
  status=1
fi

if [ "$MODE" = 'strict' ]; then
  PERMANENT="$(permanent_paths | sort -u)"
  DEBT="$(comm -23 <(echo "$FOUND") <(echo "$PERMANENT") | sed '/^$/d')"
  debt_count="$(echo "$DEBT" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [ "$debt_count" != '0' ]; then
    echo >&2
    echo "FAIL (strict): $debt_count file(s) reference the base plugin or the vendor gem" >&2
    echo "               outside the permanently-exempt set:" >&2
    echo "$DEBT" | sed 's/^/    /' >&2
    echo >&2
    echo "Strict is the 1.0 target: no coupling except the importer, which reads the base" >&2
    echo "plugin's data by name because that is what it is for. Most of the list above goes" >&2
    echo "when T-30..T-32 own the reporting surface." >&2
    status=1
  fi
fi

if [ "$status" = '0' ]; then
  echo "zero_reporter: OK — every reference is accounted for, and no entry is stale."
fi

exit "$status"
