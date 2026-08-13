#!/usr/bin/env bash
set -uo pipefail

# Gate — T-27 / INV-9. `technical-spec.md` §4: *"No `html_safe` anywhere."*
#
# --- WHAT THIS IS FOR ---
#
# A report template is written by a user and executed on the server, so every byte a
# template produces is untrusted input that ends up in a page an administrator reads.
# `html_safe`, `raw` and ERB's `<%==` are the ways to tell Rails to stop escaping it.
# INV-9 says the answer is: don't — the frame's opaque-origin sandbox and its CSP are
# what make template output safe to display, not a decision to trust it.
#
# Until this file existed the property was a matter of comments. Three of them
# (`report_frame.rb`, `report_document.rb`, `templates_helper.rb`) said so in as many
# words and CITED THIS GATE BY NAME while it did not exist — which a review correctly
# called out as reading like coverage that is not there. This is that gate.
#
# --- THE `Accept:` LINE, AND THE DEVIATION FROM IT, DECLARED ---
#
# `implementation-plan.md` T-27 and `technical-spec.md` §4 say: *"allows `html_safe|raw(`
# in ≤2 files"* — ONE pattern with ONE budget of two files. This implements something
# STRICTER, and CLAUDE.md §11.3 says a deviation is reported rather than absorbed:
#
#   * `html_safe` on a value is allowed in ZERO files, not two. Nothing in the plugin
#     does it, so a budget of two would be two free passes nobody has asked for.
#   * `raw`/`<%==` keeps the budget of two, spent through the allowlist.
#
# The spec's own budget is therefore never exceeded — this refuses a subset of what it
# refuses. Recorded in `technical-spec.md` §4 in the same change, per G9.
#
# --- WHY COMMENT LINES ARE STRIPPED, AND WHY THAT IS NOT A HOLE ---
#
# This repository's comment density makes prose ABOUT `html_safe` far more common than
# calls to it: a bare grep reports thirteen files, eleven of them explaining why they do
# not do it. A gate whose normal output is eleven false positives is a gate people learn
# to skip past — HANDOVER §1 records the same lesson from a lint that found `<script>` in
# prose and reported 72 findings in a template that had none.
#
# It is not a hole because a stripped line is a line Ruby does not execute. Only a line
# whose FIRST non-whitespace character is `#` is stripped, so `#` inside a string literal
# still counts.
#
# Run it from anywhere:  ./script/gates/no_html_safe.sh
# Its negative test:     ./script/gates/no_html_safe_selftest.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALLOWLIST="${NO_HTML_SAFE_ALLOWLIST:-$ROOT/script/gates/no_html_safe.allowlist}"
SEARCH_PATHS=(app lib)
MAX_RAW_FILES=2

cd "$ROOT" || exit 2

# --- THE PATTERNS -------------------------------------------------------------------
#
# `raw` WITHOUT PARENTHESES IS THE IDIOMATIC RAILS FORM and the first version of this
# gate missed it, along with `<%==` — Erubi's raw-output shorthand, which is exactly
# `<%= raw … %>`. A gate for INV-9 that misses `<%== template_output %>` in an `.erb` is
# not enforcing INV-9. Found by an independent review, not by the first negative test,
# because that test only ever planted the two forms the author had thought of.
#
# --- AND THE OVER-CORRECTION, WHICH THE SELF-TEST CAUGHT IMMEDIATELY ---------------
#
# The fix was first written `\braw[[:space:](]`, to catch `raw v`. That matches **`raw =
# "rrd_cv_#{suffix}.value"`** — an ordinary local variable — and reported 20 real files,
# `query_aggregator.rb` among them. A gate whose normal output is twenty false positives
# is worse than the hole it closed.
#
# Distinguishing a bare call `raw v` from an assignment `raw = v` is not something grep
# can do. So the pattern matches where the helper is ACTUALLY used to emit markup:
# parenthesised anywhere, and both bare forms inside an ERB output tag. A bare `raw v` in
# a `.rb` helper is the one form still missed; it is vanishingly rare in this codebase
# (zero occurrences), and buying it costs twenty false positives.
HTML_SAFE_PATTERN='\.html_safe'
RAW_PATTERN='(\braw\(|<%==|<%=[[:space:]]*raw[[:space:]])'

# --- THE EXEMPTION, BY SHAPE AND BY OCCURRENCE --------------------------------------
#
# `''.html_safe` and `"".html_safe` mark the EMPTY STRING. That is Rails' documented way
# to start an `ActiveSupport::SafeBuffer` you then `<<` escaped content onto, and it
# cannot launder anything: the safe thing is a zero-length string, and every `<<` after
# it escapes its argument.
#
# IT IS DELETED FROM THE LINE, NOT USED TO DROP THE LINE. The first version filtered
# matching lines out with `grep -v`, so `buf = ''.html_safe << user_input.html_safe`
# PASSED — the exemption laundered the rest of its own line, while the comment promised
# the opposite. Removing just the exempt occurrences leaves any other `.html_safe` on
# that line exposed.
EMPTY_BUFFER="(''|\"\")\.html_safe"

# Strip full-line comments and the exempt occurrences, then match. The status is
# THREE-VALUED and the third value is loud: 0 = matches, 1 = none, anything else = the
# search itself failed and this gate knows nothing.
#
# IT `return`s AND DOES NOT `exit`. The first version called `exit 2` here — and
# `search` is only ever called inside `$( … )`, so that exited the SUBSHELL and the
# script carried on to print PASS and exit 0. A crashing search reported success.
# `ci.yml` documents this exact trap forty lines from where this gate is registered, and
# the first version reproduced it anyway. The caller now checks the status on its own
# line.
search() {
  local pattern="$1" file stripped rc out=''
  while IFS= read -r file; do
    # `sed -E`, NOT bare `sed`. In BRE the `(`, `|` and `?` in `EMPTY_BUFFER` are
    # LITERALS, so the exemption silently matched nothing and every `''.html_safe` in
    # `reporter_project_pages_helper.rb` was reported as a violation. Caught by arm 3 of
    # the self-test on its first run — the interactive test it replaced had used a
    # different sed invocation and never saw this.
    stripped="$(sed -E -e 's/^[[:space:]]*#.*$//' -e "s/$EMPTY_BUFFER//g" "$file" \
                | grep -nE "$pattern")"
    rc=$?
    if [ "$rc" -gt 1 ]; then
      echo "no_html_safe: the search itself failed (exit $rc) on $file" >&2
      return 2
    fi
    if [ -n "$stripped" ]; then
      out="$out$(echo "$stripped" | sed "s|^|$file:|")
"
    fi
  done < <(scanned_files)
  printf '%s' "$out"
  return 0
}

# EVERY SEARCH PATH MUST EXIST. `find` on a missing directory writes to stderr and finds
# nothing, so `2>/dev/null` turned "run from the wrong root" into a clean PASS — a gate
# certifying INV-9 having read no files at all. This repository's single most-repeated
# failure is a check that could not run looking exactly like a check that passed.
for path in "${SEARCH_PATHS[@]}"; do
  if [ ! -d "$path" ]; then
    echo "no_html_safe: FAIL — search path '$path' does not exist, so this gate would" >&2
    echo "              certify INV-9 having read nothing. Run it from the plugin root." >&2
    exit 2
  fi
done

scanned_files() {
  find "${SEARCH_PATHS[@]}" -type f \( -name '*.rb' -o -name '*.erb' \) | sort
}

# AND THE FILE SET NEEDS A FLOOR. A glob that matches nothing must never be a pass —
# HANDOVER §1, where a source-level spec asserted a list was EMPTY and an empty glob
# satisfied it on all four Redmine branches.
SCANNED="$(scanned_files | wc -l | tr -d ' ')"
if [ "$SCANNED" -lt 50 ]; then
  echo "no_html_safe: FAIL — only $SCANNED file(s) scanned under ${SEARCH_PATHS[*]}." >&2
  echo "              The plugin has hundreds; a set this small means the search is" >&2
  echo "              broken, not that the tree is clean." >&2
  exit 2
fi

# First whitespace-separated field of each non-comment, non-blank line — the same format
# `zero_reporter.allowlist` uses, so a reader learns one shape.
allowed_paths() {
  [ -f "$ALLOWLIST" ] || return 0
  sed -E 's/#.*$//' "$ALLOWLIST" | awk 'NF { print $1 }'
}

status=0

# --- 1. `html_safe` on a value ------------------------------------------------------
html_safe_hits="$(search "$HTML_SAFE_PATTERN")"
rc=$?
[ "$rc" -gt 1 ] && exit 2

if [ -n "$html_safe_hits" ]; then
  echo "FAIL: html_safe is called on a value (INV-9; technical-spec.md §4)" >&2
  echo "$html_safe_hits" | sed 's/^/    /' >&2
  echo "" >&2
  echo "  A report template is user-written code executed on the server, so its output is" >&2
  echo "  untrusted. What makes it safe to display is the opaque-origin sandbox and the CSP" >&2
  echo "  in ReportFrame, never a decision to stop escaping. Escape it, or put the value in" >&2
  echo "  a <script type=\"application/json\"> data block (FR-19)." >&2
  status=1
fi

# --- 2. `raw` / `<%==`, capped at two files -----------------------------------------
raw_hits="$(search "$RAW_PATTERN")"
rc=$?
[ "$rc" -gt 1 ] && exit 2

raw_files="$(echo "$raw_hits" | awk -F: 'NF { print $1 }' | sort -u | sed '/^$/d')"
raw_count="$(echo "$raw_files" | sed '/^$/d' | grep -c . || true)"

allowed="$(allowed_paths)"
unallowed=''
while IFS= read -r file; do
  [ -z "$file" ] && continue
  if ! echo "$allowed" | grep -qxF "$file"; then
    unallowed="$unallowed$file
"
  fi
done <<< "$raw_files"

if [ -n "$(echo "$unallowed" | sed '/^$/d')" ]; then
  echo "FAIL: raw()/<%== is used in a file that is not on the allowlist" >&2
  echo "$unallowed" | sed '/^$/d' | sed 's/^/    /' >&2
  echo "  Add it to the allowlist WITH A REASON, in review — the allowlist is a decision," >&2
  echo "  not a way to make this gate green. Cap: $MAX_RAW_FILES files." >&2
  status=1
fi

if [ "$raw_count" -gt "$MAX_RAW_FILES" ]; then
  echo "FAIL: raw()/<%== appears in $raw_count files; the cap is $MAX_RAW_FILES" >&2
  status=1
fi

# --- 3. THE ALLOWLIST MUST NOT BE STALE ---------------------------------------------
#
# An entry that permits nothing today is what silently permits something tomorrow.
# `zero_reporter.sh` enforces the same rule for the same reason.
while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  if ! echo "$raw_files" | grep -qxF "$entry"; then
    echo "FAIL: $entry is on the allowlist but uses no raw()/<%== — delete the entry" >&2
    status=1
  fi
done <<< "$allowed"

if [ "$status" -eq 0 ]; then
  echo "no_html_safe: PASS — $SCANNED files scanned; no html_safe on a value; " \
       "raw()/<%== in $raw_count of at most $MAX_RAW_FILES allowed file(s)"
fi

exit "$status"
