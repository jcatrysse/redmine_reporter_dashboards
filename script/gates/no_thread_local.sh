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

# --- TWO REPAIRS, BOTH ASKED FOR BY HANDOVER §1, MADE THE FIRST TIME THIS WAS TOUCHED
#
# 1. WHOLE-LINE COMMENTS ARE STRIPPED, as `layer_purity.sh` and `compat_size.sh` already
#    do. The first version failed on this file's own successor — a comment in the
#    wkhtmltopdf adapter explaining WHY it uses `IO.select` rather than a thread per
#    stream. A gate that punishes writing down its own rationale teaches people to
#    delete the rationale, so it damages the codebase in exactly the dimension it exists
#    to protect. A trailing comment on a line of code still counts; that line is code.
#
# 2. `|| true` IS GONE. It cannot tell "no matches" from "the search crashed", and one
#    of those is a lie — the same defect that made `layer_purity.sh` report every layer
#    clean while checking nothing. A search's exit status is three-valued here:
#    0 = matches, 1 = no matches, anything else = the tool failed and this gate knows
#    nothing, which must be loud.
matches() {
  local file rc
  while IFS= read -r file; do
    # `if` rather than a bare assignment: under `set -e` a failing simple command ends
    # the script, and "grep found nothing" is a failing command with exit 1. Putting the
    # search in a condition is what lets the three-valued check below run at all.
    if sed 's/^[[:space:]]*#.*$//' "$file" | grep -qE "$PATTERN"; then
      echo "$file"
    else
      rc=$?
      if [ "$rc" -gt 1 ]; then
        echo "no_thread_local: FAIL — the search itself failed (exit $rc) on $file" >&2
        exit 2
      fi
    fi
  done < <(find "${SEARCH_PATHS[@]}" -name '*.rb' -type f 2>/dev/null | sort)
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
