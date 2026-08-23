#!/usr/bin/env bash
set -euo pipefail

# Gate — T-17 (technical-spec.md §4). ONE parse entry point, and no global filters.
#
# --- WHY THIS IS A GATE AND NOT A CONVENTION ---
#
# Every property the execution policy provides is a property of the CALL SITE:
#
#   resource limits   handed to the Liquid::Context, per render
#   the deadline      bound into that context's registers
#   :strict           passed to parse
#   rethrow_errors    the fourth positional argument to Context.new
#
# A second `Liquid::Template.parse` somewhere convenient has NONE of them. Not because
# anyone decided against them — because those are Liquid's defaults, and the second call
# site did not know it was supposed to argue with them. In particular it writes its
# errors INTO THE DOCUMENT, which is the defect `TemplateRenderer` exists to close and
# the one this repository has already shipped once.
#
# So: `Template.parse` may appear only under `liquid/`. Everywhere else is a finding.
#
# --- AND WHY `register_filter` IS HERE TOO ---
#
# §4: "Never `Template.register_filter`. Construct the `Liquid::Context` and call
# `context.add_filters([...])`." A registered filter is GLOBAL to the process, which
# this plugin shares with Redmine and every other plugin. A filter registered for a
# report is then available inside every template anyone else renders, and removing it
# later breaks templates that came to depend on it. Tag registration on Liquid 4 is
# irreducibly global and is accepted as such; filters are not, so they are not.
#
# Mode:
#   SINGLE_PARSE_MODE=warn    (default) a violation fails; this gate has no exemptions
#   SINGLE_PARSE_MODE=strict  identical today, reserved for a future exemption list

MODE="${SINGLE_PARSE_MODE:-warn}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BASE='lib/redmine_reporter_dashboards'
OWNED_LIQUID="$BASE/liquid"

# Whole-line comments are stripped before matching, for the reason layer_purity.sh and
# compat_size.sh already do it: this file's own header names the construct it forbids,
# and a gate that punishes writing down its rationale teaches people to delete the
# rationale. A trailing comment on a line of code still counts — that line is code.
#
# Exit status is three-valued: 0 = matches, 1 = no matches, anything else = the search
# itself failed and this gate knows nothing, which must be loud. `|| true` here would
# make "clean" and "did not run" the same answer.
# --- THE FILE SET, AND WHY IT IS NOT JUST `*.rb` (2026-08-14) --------------------
#
# It WAS `-name '*.rb'`, and that left **55 files under app/ and lib/ invisible to this
# gate**: every `.erb` view and every `.rake` task. Nothing exploited it — the widening
# found zero new hits — but the hole was found while decision #1 was leaning on this gate
# as the mechanical half of "there is exactly one parse site in this repository", and a
# guarantee is worth what its enforcement covers. An `.erb` partial or a rake formatter can
# call `Liquid::Template.parse` exactly as easily as a `.rb`, and a rake task is the most
# likely place somebody would reach for a second parser ("just render this template to
# stdout").
#
# `.yml` is deliberately NOT included: `config/capabilities.yml` and friends are data, the
# gate does not scan `config/` at all, and a YAML file cannot call a method.
#
# AND THE COUNT IS PRINTED, which is `HANDOVER.md` §1's rule for any gate whose subject is a
# file set: "a gate certifying INV-9 having read no files" is how `no_html_safe.sh` shipped
# with four holes. There is a FLOOR too — below it the gate exits 2 rather than reporting a
# clean run, because `find` answering nothing looks exactly like nothing to find.
GATE_FILE_FLOOR=100

# `|| true` ON THE `find`, AND THE FLOOR BELOW IT WOULD OTHERWISE BE UNREACHABLE — measured,
# on the first attempt to negative-test it. With `set -euo pipefail` and a bare `find app lib`,
# a tree missing those directories makes `find` exit 1, `pipefail` propagates it to the
# `FILE_COUNT=$(...)` assignment, and `set -e` kills the script THERE: **exit 1 with not one
# line of output**, which is `HANDOVER.md`'s "a check that could not run looks exactly like a
# check that passed" in its worst form — the gate reporting nothing and a caller reading it as
# an ordinary violation. The `|| true` is safe here precisely BECAUSE the floor exists: a
# swallowed `find` failure cannot hide, it lands as a count below the floor and exits 2.
gate_files() {
  find app lib \( -name '*.rb' -o -name '*.rake' -o -name '*.erb' \) -type f 2>/dev/null || true
}

FILE_COUNT="$(gate_files | wc -l | tr -d ' ')"
if [ "$FILE_COUNT" -lt "$GATE_FILE_FLOOR" ]; then
  echo "single_parse: FAIL — only $FILE_COUNT files to scan, below the floor of" >&2
  echo "              $GATE_FILE_FLOOR. This gate knows nothing; it did not run over the" >&2
  echo "              tree it certifies. Check the working directory." >&2
  exit 2
fi

search() {
  local pattern="$1" file rc out=''
  while IFS= read -r file; do
    if hits="$(sed 's/^[[:space:]]*#.*$//' "$file" | grep -nE "$pattern")"; then
      out="$out$(echo "$hits" | sed "s|^|$file:|")
"
    else
      rc=$?
      if [ "$rc" -gt 1 ]; then
        echo "single_parse: FAIL — the search itself failed (exit $rc) on $file" >&2
        exit 2
      fi
    fi
  done < <(gate_files | sort)
  printf '%s' "$out"
}

STATUS=0

# ---- 1. Template.parse outside the owned Liquid layer ---------------------------
PARSE_HITS="$(search 'Template\.parse' | sed '/^$/d' || true)"
OUTSIDE="$(echo "$PARSE_HITS" | sed '/^$/d' | grep -v "^$OWNED_LIQUID/" || true)"

if [ -n "$(echo "$OUTSIDE" | sed '/^$/d')" ]; then
  echo "single_parse: FAIL — a template is parsed outside $OWNED_LIQUID/:"
  echo "$OUTSIDE" | sed '/^$/d' | sed 's/^/    /'
  echo
  echo "    Every limit the execution policy applies is a property of the call site:"
  echo "    resource limits, the cooperative deadline, :strict error mode, and"
  echo "    rethrow_errors — without which Liquid writes its errors INTO the document."
  echo "    Route it through Liquid::TemplateRenderer instead."
  STATUS=1
else
  echo "single_parse: OK — Template.parse appears only under $OWNED_LIQUID/"
fi

# ---- 2. register_filter anywhere -------------------------------------------------
FILTER_HITS="$(search 'register_filter' | sed '/^$/d' || true)"

if [ -n "$(echo "$FILTER_HITS" | sed '/^$/d')" ]; then
  echo "single_parse: FAIL — a filter is registered globally:"
  echo "$FILTER_HITS" | sed '/^$/d' | sed 's/^/    /'
  echo
  echo "    Template.register_filter is process-global, and this process is shared with"
  echo "    Redmine and every other plugin. Use context.add_filters([...]), which scopes"
  echo "    the filter to one render — TemplateRenderer takes a filters: argument."
  STATUS=1
else
  echo "single_parse: OK — no globally registered filters"
fi

PARSE_COUNT="$(echo "$PARSE_HITS" | sed '/^$/d' | wc -l | tr -d ' ')"
echo "single_parse: mode=$MODE  parse site(s)=$PARSE_COUNT  all under $OWNED_LIQUID/" \
     "  files scanned=$FILE_COUNT (.rb/.rake/.erb under app/ lib/)"

exit "$STATUS"
