#!/usr/bin/env bash
set -uo pipefail

# Gate — T-27 / INV-9. `technical-spec.md` §4: *"No `html_safe` anywhere."*
#
# --- WHAT THIS IS FOR ---
#
# A report template is written by a user and executed on the server, so every byte a
# template produces is untrusted input that ends up in a page an administrator reads.
# `html_safe` and `raw()` are the two ways to tell Rails to stop escaping it. INV-9 says
# the answer is: don't — the frame's opaque-origin sandbox and its CSP are what make
# template output safe to display, not a decision to trust it.
#
# Until this file existed the property was a matter of comments. Three of them
# (`report_frame.rb:29`, `report_document.rb:34`, `templates_helper.rb:173`) said so in as
# many words and CITED THIS GATE BY NAME while it did not exist — which a review correctly
# called out as reading like coverage that is not there. This is that gate.
#
# --- THE `Accept:` LINE, PRECISELY ---
#
# *"`no_html_safe` gate allows `raw(` in ≤2 files."* So the cap is TWO, it is enforced
# rather than described, and the allowlist below is what spends it. It is at ZERO today:
# nothing in the plugin calls `raw(` at all, and the only real `html_safe` calls are
# `''.html_safe` — Rails' idiom for STARTING a safe buffer, which marks the empty string
# and never author content. Those are exempted by shape, not by filename, and the reason
# is argued where the exemption is written.
#
# --- WHY COMMENT LINES ARE STRIPPED, AND WHY THAT IS NOT A HOLE ---
#
# This repository's comment density makes prose ABOUT `html_safe` far more common than
# calls to it: a bare grep reports thirteen files, eleven of them explaining why they do
# not do it. A gate whose normal output is eleven false positives is a gate people learn
# to skip past — HANDOVER §1 records the same lesson from a lint that found `<script>` in
# prose and reported 72 findings in a template that had none.
#
# It is not a hole because a stripped line is a line Ruby does not execute. `#` inside a
# string literal is not stripped: only a line whose first non-whitespace character is `#`.
#
# Run it from anywhere:  ./script/gates/no_html_safe.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALLOWLIST="$ROOT/script/gates/no_html_safe.allowlist"
SEARCH_PATHS=(app lib)
MAX_RAW_FILES=2

cd "$ROOT" || exit 2

# --- THE EXEMPTION, BY SHAPE ------------------------------------------------------
#
# `''.html_safe` and `"".html_safe` mark the EMPTY STRING. That is Rails' documented way
# to start an `ActiveSupport::SafeBuffer` you then `<<` escaped content onto, and it
# cannot launder anything: the safe thing is a zero-length string, and every `<<` after it
# escapes its argument. `reporter_project_pages_helper.rb` builds its control markup that
# way, which is the correct idiom and not the defect INV-9 names.
#
# Written as a pattern rather than as a filename so the exemption does not become "this
# file may do anything". A `foo.html_safe` in that same file still fails.
EMPTY_BUFFER="(''|\"\")\.html_safe"

# Strip full-line comments, then find the pattern. Exit status is THREE-VALUED and the
# third value is loud: 0 = matches, 1 = no matches, anything else = the search itself
# failed and this gate knows nothing. `layer_purity.sh` learned this the hard way — a
# `|| true` there swallowed a crashing search and reported every layer clean while a
# planted violation went undetected.
search() {
  local pattern="$1" file stripped rc out=''
  while IFS= read -r file; do
    stripped="$(sed 's/^[[:space:]]*#.*$//' "$file" | grep -nE "$pattern")"
    rc=$?
    if [ "$rc" -gt 1 ]; then
      echo "no_html_safe: FAIL — the search itself failed (exit $rc) on $file" >&2
      exit 2
    fi
    if [ -n "$stripped" ]; then
      out="$out$(echo "$stripped" | sed "s|^|$file:|")
"
    fi
  # THE PARENTHESES ARE LOAD-BEARING. `-name '*.rb' -o -name '*.erb' -type f` binds as
  # `(-name '*.rb') OR (-name '*.erb' AND -type f)`, so `-type f` constrains only the
  # second branch and a DIRECTORY named `*.rb` would be handed to `sed`. Written without
  # them in the first draft and caught by this gate's own negative test.
  done < <(find "${SEARCH_PATHS[@]}" -type f \( -name '*.rb' -o -name '*.erb' \) 2>/dev/null | sort)
  printf '%s' "$out"
}

# First whitespace-separated field of each non-comment, non-blank line — the same format
# `zero_reporter.allowlist` uses, so a reader learns one shape.
allowed_paths() {
  [ -f "$ALLOWLIST" ] || return 0
  sed -E 's/#.*$//' "$ALLOWLIST" | awk 'NF { print $1 }'
}

status=0

# --- 1. `html_safe`, excluding the empty-buffer idiom -------------------------------
html_safe_hits="$(search '\.html_safe' | grep -vE "$EMPTY_BUFFER")"

if [ -n "$html_safe_hits" ]; then
  echo "FAIL: html_safe is called on a value (INV-9; technical-spec.md §4 — 'No html_safe anywhere')" >&2
  echo "$html_safe_hits" | sed 's/^/    /' >&2
  echo "" >&2
  echo "  A report template is user-written code executed on the server, so its output is" >&2
  echo "  untrusted. What makes it safe to display is the opaque-origin sandbox and the CSP" >&2
  echo "  in ReportFrame, never a decision to stop escaping. Escape it, or put the value in" >&2
  echo "  a <script type=\"application/json\"> data block (FR-19)." >&2
  status=1
fi

# --- 2. `raw(`, capped at two files ------------------------------------------------
raw_hits="$(search '\braw\(')"
raw_files="$(echo "$raw_hits" | awk -F: 'NF { print $1 }' | sort -u | sed '/^$/d')"
raw_count="$(echo "$raw_files" | sed '/^$/d' | wc -l | tr -d ' ')"

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
  echo "FAIL: raw() is called in a file that is not on the allowlist" >&2
  echo "$unallowed" | sed '/^$/d' | sed 's/^/    /' >&2
  echo "  Add it to script/gates/no_html_safe.allowlist WITH A REASON, in review — the" >&2
  echo "  allowlist is a decision, not a way to make this gate green. Cap: $MAX_RAW_FILES files." >&2
  status=1
fi

if [ "$raw_count" -gt "$MAX_RAW_FILES" ]; then
  echo "FAIL: raw() appears in $raw_count files; T-27's Accept: caps it at $MAX_RAW_FILES" >&2
  status=1
fi

# --- 3. THE ALLOWLIST MUST NOT BE STALE ---------------------------------------------
#
# An entry that permits nothing today is what silently permits something tomorrow.
# `zero_reporter.sh` enforces the same rule for the same reason.
while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  if ! echo "$raw_files" | grep -qxF "$entry"; then
    echo "FAIL: $entry is on the allowlist but calls no raw() — delete the entry" >&2
    status=1
  fi
done <<< "$allowed"

if [ "$status" -eq 0 ]; then
  echo "no_html_safe: PASS — no html_safe on a value; raw() in $raw_count of at most $MAX_RAW_FILES allowed file(s)"
fi

exit "$status"
