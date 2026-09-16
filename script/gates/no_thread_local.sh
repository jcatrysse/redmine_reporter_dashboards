#!/usr/bin/env bash
set -euo pipefail

# Gate — T-07, and since S-30 (2026-08-13) an ABSOLUTE one: no ambient per-thread
# state under app/ or lib/, with no exemptions at all.
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
# gate is what keeps it there. T-07's acceptance list asked for "a gate asserts
# `Thread.current` is absent from `lib/`/`app/` outside `glue/legacy/`" — and S-30
# deleted `glue/legacy/`, so the "outside" clause has no subject and the rule is: nowhere.
#
# Mode:
#   NO_THREAD_LOCAL_MODE=warn    (default) a reference outside the exempt paths fails;
#                                an exempt path that no longer needs the exemption warns
#   NO_THREAD_LOCAL_MODE=strict  ANY reference fails. With EXEMPT empty the two modes
#                                answer identically; strict is kept because the difference
#                                returns the moment somebody adds an entry.
#
# Deliberately also catches Thread#[]= on an explicit thread and Fiber-local storage:
# swapping `Thread.current[:k]` for `Thread.current.thread_variable_set` would satisfy a
# grep for the first form while changing nothing about the problem.

MODE="${NO_THREAD_LOCAL_MODE:-warn}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATTERN='Thread\.current|thread_variable_set|thread_variable_get|Thread\.new|Fiber\[|Fiber\.\['
SEARCH_PATHS=(app lib)

# The only files allowed to carry it, each with the reason. This list may only SHRINK.
# S-30, 2026-08-13: THIS LIST IS EMPTY, and that is the end state the comment above it
# has been promising since it was written. Both entries were `glue/legacy/` —
# `reporter_list_patch.rb`, which parked the host plugin's IssueQuery in a thread-local
# because its `liquidize()` took no registers argument to extend, and
# `scope_resolution.rb`, which read that key. Both are deleted; `Liquid::RenderContext`
# carries the query as a field, which is what a register is for.
#
# An empty list means the gate now asserts something absolute: NO per-thread state
# anywhere under app/ or lib/. Keep it that way — a render is a request, a request is a
# thread, and state parked on the thread is the shape that serves the first viewer's
# scope to the second.
EXEMPT=()

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
  done < <(scanned_files)
}

# EVERY SEARCH PATH MUST EXIST, AND THE SET MUST HAVE A FLOOR.
#
# S-30 emptied EXEMPT, and an independent review measured what that cost: this gate's
# ONLY protection against scanning nothing had been the stale-exemption arm, which
# WARNed when a listed file went missing. With an empty list a scan of zero files
# printed a clean OK — `find … 2>/dev/null` swallows "No such file or directory", so
# running it from the wrong root certified the tree having read none of it. That is
# HANDOVER §1's most-repeated failure, and emptying the list is what exposed it.
#
# Two checks replace the accidental canary, and the PASS line prints what it scanned so
# "it read nothing" is visible rather than inferred.
scanned_files() {
  find "${SEARCH_PATHS[@]}" -name '*.rb' -type f | sort
}

for path in "${SEARCH_PATHS[@]}"; do
  if [ ! -d "$path" ]; then
    echo "no_thread_local: FAIL — search path '$path' does not exist, so this gate would" >&2
    echo "                 report a clean tree having read nothing. Run it from the root." >&2
    exit 2
  fi
done

SCANNED="$(scanned_files | wc -l | tr -d ' ')"
if [ "$SCANNED" -lt 100 ]; then
  echo "no_thread_local: FAIL — only $SCANNED file(s) scanned under ${SEARCH_PATHS[*]}." >&2
  echo "                 The plugin has hundreds; a set this small means the search is" >&2
  echo "                 broken, not that the tree is clean." >&2
  exit 2
fi

FOUND="$(matches | sort -u)"
# `${EXEMPT[@]+...}` AND NOT A BARE `"${EXEMPT[@]}"`. S-30 emptied this array, and
# expanding an EMPTY array under `set -u` is an unbound-variable error on bash before
# 4.4 — which is the bash a macOS developer has (3.2). Measured fine on this container's
# 5.2, and that is exactly the kind of "works here" that ships a gate nobody else can
# run. The `+` form expands to nothing at all when the array is empty.
ALLOWED="$(printf '%s\n' ${EXEMPT[@]+"${EXEMPT[@]}"} | sort -u)"

UNLISTED="$(comm -23 <(echo "$FOUND") <(echo "$ALLOWED") | sed '/^$/d')"
STALE="$(comm -13 <(echo "$FOUND") <(echo "$ALLOWED") | sed '/^$/d')"

FOUND_COUNT="$(echo "$FOUND" | sed '/^$/d' | wc -l | tr -d ' ')"
echo "no_thread_local: mode=$MODE  scanned=$SCANNED  referencing files=$FOUND_COUNT  exempt=${#EXEMPT[@]}"

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
  echo "reference is genuinely unavoidable there is nowhere left to put it — glue/legacy/"
  echo "is deleted — so it is a decision to take in review, not a line to add to this file."
  STATUS=1
fi

if [ -n "$STALE" ]; then
  echo
  echo "WARN: these files are exempt but no longer reference per-thread state."
  echo "      Remove them from the list — the exemption is meant to shrink."
  echo "$STALE" | sed 's/^/    /'
fi

if [ "$STATUS" -eq 0 ] && [ -z "$STALE" ]; then
  echo "no_thread_local: OK — $SCANNED files scanned, no per-thread state under app/ or lib/."
fi

exit "$STATUS"
