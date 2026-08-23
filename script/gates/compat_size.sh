#!/usr/bin/env bash
set -euo pipefail

# Gate — T-09 / mechanism E4 (technical-spec.md §1.2).
#
# Two jobs, and only one of them is a pass/fail:
#
#   1. HARD: `Rails::VERSION` and `Redmine::VERSION` appear ONLY under compat.
#      CLAUDE.md §4: "Version divergence lives in compat/ — one module, one method per
#      divergence, a comment naming the versions. Never a scattered `if Rails::VERSION`."
#      A scattered version test is how a compatibility shim stops being a shim: it is
#      invisible, so nobody deletes it when the version it guards goes out of support.
#
#   2. SOFT: print the compat LOC. E4 asks for the number on every PR, in those words —
#      "compatibility debt as a visible number is the only real defence against the
#      'temporary adapter ossifies' fate ADR-004 names". A number nobody sees is the
#      fate; a number in every PR is the defence.
#
# --- Why printing rather than a budget, stated so the next reader does not "fix" it ---
#
# CLAUDE.md §4 says "There is a committed LOC budget on that directory and a gate that
# enforces it." There is NOT, and there never was: no number is committed anywhere in
# docs/plan/, and technical-spec E4 — the actual specification — says PRINT, not cap.
# T-09's Accept line agrees with the spec ("the compat/ LOC is printed on every PR").
#
# So this gate implements the spec, and the discrepancy is reported to the curator
# rather than resolved here by inventing a number. Picking the cap IS the decision:
# too high and it is decoration, too low and the next legitimate divergence gets
# refused by a threshold nobody argued for. See implementation-plan.md §Findings F-4.
#
# Set COMPAT_LOC_BUDGET to turn the number into a ratchet once one is agreed.

MODE="${COMPAT_SIZE_MODE:-warn}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# compat is a FILE today, not a directory, and that is deliberate — Zeitwerk requires a
# path under a plugin's lib/ to match the constant it defines, so `compat/base_record.rb`
# must define Compat::BaseRecord. Both spellings are counted so the gate keeps working
# on the day it becomes a directory.
COMPAT_PATHS=()
[ -f 'lib/redmine_reporter_dashboards/compat.rb' ] && COMPAT_PATHS+=('lib/redmine_reporter_dashboards/compat.rb')
[ -d 'lib/redmine_reporter_dashboards/compat' ]    && COMPAT_PATHS+=('lib/redmine_reporter_dashboards/compat')

if [ "${#COMPAT_PATHS[@]}" -eq 0 ]; then
  echo "compat_size: no compat file or directory found."
  echo "             That is a legitimate state — no version divergence is owned yet —"
  echo "             but it is said out loud, because a gate over nothing reads exactly"
  echo "             like a gate that passed."
  COMPAT_FILES=''
else
  COMPAT_FILES="$(find "${COMPAT_PATHS[@]}" -name '*.rb' -type f | sort)"
fi

# The version constants, and where they may appear. `app/` and `lib/` only: a spec or a
# test may legitimately assert on a version to decide what it is allowed to expect.
PATTERN='Rails::VERSION|Redmine::VERSION'
SEARCH_PATHS=(app lib)

# Whole-line comments are stripped before matching, and that is not leniency: the very
# first run of this gate failed on the comment that explains WHY the check moved into
# Compat. A gate that punishes writing down its own reason teaches people to delete the
# reason, so it would have made the codebase worse in exactly the dimension it exists to
# protect. A trailing comment on a line of code still counts — that line is code.
matches() {
  local file
  for file in $(find "${SEARCH_PATHS[@]}" -name '*.rb' -type f 2>/dev/null | sort); do
    if sed 's/^[[:space:]]*#.*$//' "$file" | grep -qE "$PATTERN"; then
      echo "$file"
    fi
  done
}

FOUND="$(matches | sort -u | sed '/^$/d')"
ALLOWED="$(printf '%s\n' "$COMPAT_FILES" | sed '/^$/d' | sort -u)"
OUTSIDE="$(comm -23 <(echo "$FOUND") <(echo "$ALLOWED") | sed '/^$/d')"

# Total lines, and code lines with blanks and whole-line comments removed. Both are
# printed: the first is what the file costs to read, the second what it costs to own.
if [ -n "$COMPAT_FILES" ]; then
  TOTAL="$(echo "$COMPAT_FILES" | xargs cat | wc -l | tr -d ' ')"
  CODE="$(echo "$COMPAT_FILES" | xargs cat | grep -vcE '^\s*(#|$)' || true)"
  COUNT="$(echo "$COMPAT_FILES" | wc -l | tr -d ' ')"
else
  TOTAL=0; CODE=0; COUNT=0
fi

echo "compat_size: mode=$MODE  files=$COUNT  lines=$TOTAL  code lines=$CODE"
if [ -n "$COMPAT_FILES" ]; then
  echo "$COMPAT_FILES" | sed 's/^/    /'
fi

STATUS=0

if [ -n "$OUTSIDE" ]; then
  echo
  echo "FAIL: a version test outside compat —"
  echo "$OUTSIDE" | sed 's/^/    /'
  echo
  echo "Move it into RedmineReporterDashboards::Compat as one named method with a"
  echo "comment naming the versions it spans, and call that. A version check written"
  echo "where it is needed is invisible: it survives the release that made it"
  echo "unnecessary, which is exactly how a temporary adapter ossifies (ADR-004)."
  STATUS=1
fi

if [ -n "${COMPAT_LOC_BUDGET:-}" ]; then
  if [ "$CODE" -gt "$COMPAT_LOC_BUDGET" ]; then
    echo
    echo "FAIL: compat is $CODE code lines, past the committed budget of $COMPAT_LOC_BUDGET."
    echo "Raising the budget is a curator decision and belongs in the same PR as the"
    echo "divergence that needs it, with the reason."
    STATUS=1
  else
    echo "compat_size: $CODE/$COMPAT_LOC_BUDGET code lines against the committed budget."
  fi
else
  echo "compat_size: no COMPAT_LOC_BUDGET set — the number is REPORTED, not enforced."
  echo "             That is what technical-spec E4 asks for. See §Findings F-4 for the"
  echo "             open question about whether it should become a cap."
fi

if [ "$STATUS" -eq 0 ] && [ -z "$OUTSIDE" ]; then
  echo "compat_size: OK — every version test lives in compat."
fi

exit "$STATUS"
