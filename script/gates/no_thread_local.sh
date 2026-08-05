#!/usr/bin/env bash
set -euo pipefail

# Gate — T-07. No ambient per-thread state outside the legacy glue.
#
# `Thread.current` is how the plugin used to get an IssueQuery from reporter's renderer
# into a Liquid tag: reporter's `liquidize()` takes no registers argument that can be
# extended from outside, so the query was parked in a thread-local for the duration of
# a render. It works, and it is guarded by an `ensure` — but it is ambient state on a
# reused request thread, which is the shape of the worst bug this plugin could have:
# one user's filters bleeding into another user's report.
#
# The owned path carries the actor, the scope and the query in a RenderContext, which
# is an argument. So the construct now has exactly one legitimate home — the glue that
# exists only because reporter is installed, and which is deleted at 1.0 — and this
# gate is what keeps it there. T-07's acceptance list asks for it in those words:
# "a gate asserts `Thread.current` is absent from `lib/`/`app/` outside `glue/legacy/`".
#
# Mode:
#   NO_THREAD_LOCAL_MODE=warn    (default) a reference outside the exempt paths fails;
#                                an exempt path that no longer needs the exemption warns
#   NO_THREAD_LOCAL_MODE=strict  ANY reference fails. What 1.0 must pass, because at 1.0
#                                glue/legacy/ does not exist.
#
# Deliberately also catches Thread#[]= on an explicit thread and Fiber-local storage:
# swapping `Thread.current[:k]` for `Thread.current.thread_variable_set` would satisfy a
# grep for the first form while changing nothing about the problem.

MODE="${NO_THREAD_LOCAL_MODE:-warn}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATTERN='Thread\.current|thread_variable_set|thread_variable_get|Thread\.new|Fiber\[|Fiber\.\['
SEARCH_PATHS=(app lib)

# The only files allowed to carry it, each with the reason. This list may only SHRINK.
EXEMPT=(
  # Owns the thread-local that gets reporter's IssueQuery into a Liquid tag. Reporter's
  # liquidize() takes no registers argument to extend, so there is no other channel.
  # Deleted with glue/legacy/ at 1.0; replaced by Liquid::RenderContext.
  "lib/redmine_reporter_dashboards/glue/legacy/reporter_list_patch.rb"
  # Reads the key the patch above sets. Frozen by the scope fixture oracle.
  "lib/redmine_reporter_dashboards/glue/legacy/scope_resolution.rb"
)

cd "$ROOT"

matches() {
  if command -v rg >/dev/null 2>&1; then
    rg -l "$PATTERN" "${SEARCH_PATHS[@]}" 2>/dev/null || true
  else
    grep -rlE "$PATTERN" "${SEARCH_PATHS[@]}" 2>/dev/null || true
  fi
}

FOUND="$(matches | sort -u)"
ALLOWED="$(printf '%s\n' "${EXEMPT[@]}" | sort -u)"

UNLISTED="$(comm -23 <(echo "$FOUND") <(echo "$ALLOWED") | sed '/^$/d')"
STALE="$(comm -13 <(echo "$FOUND") <(echo "$ALLOWED") | sed '/^$/d')"

FOUND_COUNT="$(echo "$FOUND" | sed '/^$/d' | wc -l | tr -d ' ')"
echo "no_thread_local: mode=$MODE  referencing files=$FOUND_COUNT  exempt=${#EXEMPT[@]}"

STATUS=0

if [ "$MODE" = "strict" ] && [ -n "$FOUND" ]; then
  echo
  echo "FAIL (strict): per-thread state must not exist at 1.0, and these files carry it:"
  echo "$FOUND" | sed 's/^/    /'
  exit 1
fi

if [ -n "$UNLISTED" ]; then
  echo
  echo "FAIL: per-thread state outside the legacy glue:"
  echo "$UNLISTED" | sed 's/^/    /'
  echo
  echo "The owned path carries the actor, the scope and the query in a"
  echo "Liquid::RenderContext, which is an argument rather than ambient state. If a new"
  echo "reference is genuinely unavoidable, it belongs in glue/legacy/ with the reason —"
  echo "and that is a decision to take in review, not a line to add to this file."
  STATUS=1
fi

if [ -n "$STALE" ]; then
  echo
  echo "WARN: these files are exempt but no longer reference per-thread state."
  echo "      Remove them from the list — the exemption is meant to shrink."
  echo "$STALE" | sed 's/^/    /'
fi

if [ "$STATUS" -eq 0 ] && [ -z "$STALE" ]; then
  echo "no_thread_local: OK — per-thread state exists only in glue/legacy/, and every exemption is used."
fi

exit "$STATUS"
