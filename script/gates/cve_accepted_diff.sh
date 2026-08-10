#!/usr/bin/env bash
set -euo pipefail

# Gate helper — T-34. Compares the CVEs a scan REPORTED against the CVEs this project has
# ACCEPTED, and decides.
#
#   cve_accepted_diff.sh <accepted-file> <found-ids-file>
#
# `<accepted-file>` is one record per line, `#` comments and blank lines ignored:
#
#     CVE-2026-19155 | 2026-09-09 | why this is accepted, in a sentence
#
# `<found-ids-file>` is one CVE id per line — in the workflow, `jq` over Trivy's JSON
# report, already filtered to fixable HIGH/CRITICAL.
#
# --- WHY THIS IS A FILE AND NOT TWENTY LINES INSIDE THE WORKFLOW ---------------------
#
# `.github/workflows/gotenberg-cve.yml` runs it twice: once on the real scan, and once —
# via `cve_accepted_diff_selftest.sh` — on synthetic inputs that each trip exactly one arm.
# Those two have to be THE SAME CODE or the self-test proves something about a copy. That
# is the difference between "the gate can fail" and "a thing shaped like the gate can
# fail", and this project's last three reviews found the second one three times.
#
# The self-test's own case count is not repeated here, because it changes whenever a case
# is added and a number in a comment does not. `cve_accepted_diff_selftest.sh` prints it.
#
# --- THE FOUR WAYS IT SAYS NO --------------------------------------------------------
#
#   1. a found id nobody accepted       — a new vulnerability in the pinned image
#   2. an accepted id past its date     — an acceptance nobody re-examined
#   3. an accepted id nothing reports   — a stale exemption; delete it
#   4. a record that is malformed       — no advisory id, no REAL date, no reason, or an
#                                          expiry further out than MAX_ACCEPTANCE_DAYS
#
# (3) exists because an exemption list only stays honest if entries LEAVE it. (4) exists
# because an acceptance whose expiry cannot arrive is an acceptance that never expires,
# and this repository already has a rule about tokens that never expire. Both halves of
# that were shipped broken once: `9999-99-99` and `2099-12-31` each passed as live
# acceptances until an independent review demonstrated it.
#
# Exit 0 when every finding is accepted and every acceptance is live, dated and bounded;
# 1 when it says no; 2 on a usage error, a missing input, or a platform it cannot trust.
# Rejections print `cve_accepted_diff: FAIL — …`, the same shape as every other gate in
# this directory, so the output reads the same in Actions and on a laptop.

usage() {
  echo "usage: $(basename "$0") <accepted-file> <found-ids-file>" >&2
  echo "       $(basename "$0") --validate-only <accepted-file>" >&2
  exit 2
}

# `--validate-only` CHECKS THE RECORDS AND SKIPS THE COMPARISON, because the two halves
# of this gate need very different things to run. The comparison needs a Trivy report,
# which needs docker, an image pull and a vulnerability database — nightly work. The
# record validation needs nothing, and the thing it catches is time-based: an acceptance
# whose valid-through date has passed. Without this mode that expiry would only ever be
# noticed by the nightly job, and every pull request would stay green over a security
# exemption nobody had re-examined. So `ci.yml`'s `gates` job runs this half on every PR.
#
# `--expiry-advisory` DOWNGRADES ONE ARM, AND ONLY WHERE IT IS NOT THE DETECTOR.
#
# Both reviewers escalated the same thing: every acceptance in the shipped allowlist is
# dated the same day, and `ci.yml` runs on `push: branches: ['**']`, so on 2026-09-10
# every branch in the repository is red because of somebody else's Chromium CVE. The
# cheapest unblock on that morning is a one-character date bump with no re-examination —
# which is precisely the "gate becomes furniture" outcome the expiry exists to prevent,
# arriving through a door the expiry opened. CLAUDE.md §5 names this shape directly: a
# check read against a real clock "goes red for the wrong reason, and gets switched off
# within a week".
#
# This is NOT §7's forbidden "make a gate advisory to reach green". The expiry stays HARD
# in both places where it is the detector and where the person who sees it can act:
#   * the nightly scan, which is what notices the date passing at all; and
#   * any pull request touching the allowlist, the compose pin or this gate — which is
#     every pull request that could be moving a date.
# What is downgraded is only the third copy, on unrelated branches, where the expiry is
# not detecting anything the other two miss and can only block work that cannot fix it.
# Record well-formedness — a malformed or unbounded record — stays hard everywhere.
VALIDATE_ONLY=0
EXPIRY_MODE=hard
while [ "$#" -gt 0 ] && case "${1:-}" in --*) true ;; *) false ;; esac; do
  case "$1" in
    --validate-only)   VALIDATE_ONLY=1 ;;
    --expiry-advisory) EXPIRY_MODE=advisory ;;
    *) echo "cve_accepted_diff: FAIL — unknown option: $1" >&2; usage ;;
  esac
  shift
done

if [ "$VALIDATE_ONLY" -eq 1 ]; then
  [ "$#" -eq 1 ] || usage
  ACCEPTED_FILE="$1"
  FOUND_FILE=""
else
  [ "$EXPIRY_MODE" = hard ] || {
    echo "cve_accepted_diff: FAIL — --expiry-advisory is only meaningful with" >&2
    echo "  --validate-only. The nightly comparison is where the expiry is the detector," >&2
    echo "  and downgrading it there would leave nothing enforcing it at all." >&2
    exit 2
  }
  [ "$#" -eq 2 ] || usage
  ACCEPTED_FILE="$1"
  FOUND_FILE="$2"
fi

for f in "$ACCEPTED_FILE" ${FOUND_FILE:+"$FOUND_FILE"}; do
  # A MISSING INPUT IS AN ERROR, NOT AN EMPTY SET. `comm` against a file that is not
  # there would otherwise make "the scan produced nothing" and "the scan did not run"
  # the same green.
  # `-r`, NOT `-f`: a process substitution (`gate acc <(jq …)`) is a pipe, not a regular
  # file, and rejecting it as "no such file" ruled out the most natural way to invoke
  # this by hand while telling the operator something untrue about why.
  [ -r "$f" ] || { echo "cve_accepted_diff: FAIL — cannot read: $f" >&2; exit 2; }
done

# --- the clock ------------------------------------------------------------------------
#
# THE OVERRIDE IS VALIDATED AND ANNOUNCED, because an unvalidated clock injected into a
# security gate is a way to switch off every expiry with no trace. It exists so the
# expiry arms are testable at all — the alternative is a fixture relative to `Date.today`,
# which CLAUDE.md §6 forbids for reasons this repository has already been bitten by — but
# a run using one must never be mistakable for a real run.

# `date -u -d` IS REQUIRED, AND ITS ABSENCE IS A FAILURE RATHER THAN A DEGRADATION.
# Validating a calendar date needs real date arithmetic: `2026-13-45` and `9999-99-99`
# both satisfy `[0-9]{4}-[0-9]{2}-[0-9]{2}` and neither is a day. An independent review
# demonstrated exactly that — `9999-99-99 | reason` passed as a live acceptance and would
# never have expired, which is the never-expiring exemption this gate was written to make
# impossible. Falling back to a looser check on a platform without GNU date would put
# that hole back on precisely the machine nobody is watching, so the gate stops instead.
date -u -d 2026-01-02 +%F >/dev/null 2>&1 || {
  echo "cve_accepted_diff: FAIL — this platform's \`date\` cannot parse \`-d <date>\`," >&2
  echo "  so a valid-through date cannot be checked for being a real day. GNU coreutils" >&2
  echo "  is required. Refusing to run rather than accepting dates it cannot verify." >&2
  exit 2
}

# `date -u -d X +%F` round-trips only a real day: it rejects month 13 and day 45, and it
# normalises nothing back to a string that was not already canonical (`2026-8-10` becomes
# `2026-08-10`, so it fails the equality and the record is reported).
#
# THE SHAPE CHECK IS A PRE-FILTER, NOT A SECOND GUARD, and that is worth saying because it
# looks like one. Mutation testing left both `M05` (delete the shape check) and `Mh`
# (remove its end anchor) alive, and they are EQUIVALENT MUTANTS rather than a coverage
# gap — established by construction, not by reading: `date -u -d X +%F` always emits
# `YYYY-MM-DD`, so requiring the output to equal the input already forces that shape, and
# 36 hand-built candidates (`tomorrow`, `@1735689600`, `2026/08/10`, `2026-08-10-extra`,
# `9999-99-99`, `2026-02-30`, `99999-08-10`, the empty string …) were run through all
# three variants with ZERO differing verdicts. What the line buys is that `date` is not
# handed arbitrary prose, and that a reader sees the intended format stated. Deleting it
# would change nothing; adding a test for it would be a test of nothing.
is_a_date() {
  local candidate="$1" parsed
  printf '%s' "$candidate" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || return 1
  parsed="$(date -u -d "$candidate" +%F 2>/dev/null)" || return 1
  [ "$parsed" = "$candidate" ]
}

days_between() {  # days_between <from> <to>, both already known to be real dates
  local from to
  from="$(date -u -d "$1" +%s)"
  to="$(date -u -d "$2" +%s)"
  echo $(( (to - from) / 86400 ))
}

if [ -n "${CVE_GATE_TODAY:-}" ]; then
  is_a_date "$CVE_GATE_TODAY" || {
    echo "cve_accepted_diff: FAIL — CVE_GATE_TODAY='$CVE_GATE_TODAY' is not a date (YYYY-MM-DD)." >&2
    exit 2
  }
  TODAY="$CVE_GATE_TODAY"
  echo "cve_accepted_diff: NOTE — running against an INJECTED clock of $TODAY, not today." >&2
else
  TODAY="$(date -u +%F)"
fi

# THE LONGEST AN ACCEPTANCE MAY RUN. An expiry the gate merely requires to be PRESENT is
# satisfied by `2099-12-31`, which is a permanent exemption wearing a date — the same
# review found that too. The window is what makes "accepted for a bounded time" a property
# of the gate rather than of whoever last read the file.
#
# 90 days, not 30: the allowlist recommends 30 for these entries, and the gate should
# refuse the indefensible rather than enforce a house style. A quarter is the longest any
# fixable HIGH should sit unexamined.
MAX_ACCEPTANCE_DAYS="${CVE_GATE_MAX_DAYS:-90}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# G6 SAYS NO UNBOUNDED OUTPUT, and a gate is not exempt from it. A found list of a hundred
# thousand ids — a scanner misconfiguration rather than a hundred thousand real
# vulnerabilities — printed one error line each and buried every other message in the job
# log. The count is what matters; twenty examples is what is useful.
print_capped() {
  local file="$1" n
  n="$(wc -l < "$file" | tr -d ' ')"
  head -20 "$file" | while IFS= read -r id; do echo "    $id"; done
  [ "$n" -le 20 ] || echo "    … and $((n - 20)) more ($n in total)"
}

bad=0

# --- parse and validate the accepted list ------------------------------------------
: > "$WORK/accepted-ids"
while IFS= read -r raw || [ -n "$raw" ]; do
  line="${raw#"${raw%%[![:space:]]*}"}"          # strip leading whitespace
  case "$line" in ''|'#'*) continue ;; esac

  # TRIMMED AT THE ENDS, NOT SQUEEZED THROUGHOUT. `tr -d '[:space:]'` deleted interior
  # whitespace too, so `CVE-2026 -19155` silently became a different, perfectly valid id
  # and was accepted for a vulnerability nobody had looked at. Trimming leaves the
  # interior space in place, where the comparison sees an id matching nothing and the
  # stale arm reports it.
  id="$(printf '%s' "$line"  | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  exp="$(printf '%s' "$line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  why="$(printf '%s' "$line" | cut -d'|' -f3-)"

  # THE ID GRAMMAR IS DELIBERATELY ALMOST NOTHING, and the previous, stricter one was a
  # defect rather than a safeguard.
  #
  # It matched `^[A-Z][A-Z0-9]{1,15}-…`, chosen to admit `GHSA-…` and `TEMP-…` alongside
  # `CVE-…` after mutation testing showed a `^CVE-`-only gate would silently drop them.
  # But the FOUND side is not validated at all, and adversarial QA found ids Trivy really
  # emits that this side refuses: `pyup.io-38834` (python-safety-db), `RHSA-2021:1234`,
  # `openSUSE-SU-2021:0001`. Each is findable and UNACCEPTABLE — the gate goes red, the
  # operator adds it to the list exactly as instructed, and the gate goes red again for a
  # second reason. A refusal no action can satisfy is INV-4, which is the very thing this
  # whole change was written to remove.
  #
  # So the rule is only "a token that could have come off the found list": non-empty, no
  # whitespace, no `|`. The typo protection the strict grammar seemed to buy was never
  # real — a mistyped id matches nothing and the STALE arm reports it, which is a better
  # message than a grammar complaint because it names the actual problem.
  case "$id" in
    ''|*[[:space:]]*|*'|'*)
      echo "cve_accepted_diff: FAIL — '$id' is not usable as an advisory id."
      echo "  It must be a single token: not empty, no spaces, no '|'. Record: $line"
      bad=1; continue
      ;;
  esac
  # A REAL DAY, not a string that looks like one. `2026-13-45` and `9999-99-99` both match
  # the YYYY-MM-DD shape and neither can ever arrive, so either would be an acceptance
  # that never expires.
  if ! is_a_date "$exp"; then
    echo "cve_accepted_diff: FAIL — $id has no valid-through date (got '$exp')."
    echo "  It must be a real day in YYYY-MM-DD. An acceptance whose date can never"
    echo "  arrive is an acceptance that never gets re-examined."
    bad=1; continue
  fi
  if [ -z "$(printf '%s' "$why" | tr -d '[:space:]')" ]; then
    echo "cve_accepted_diff: FAIL — $id carries no reason. Every exemption carries one."
    bad=1; continue
  fi
  if [ "$TODAY" \> "$exp" ]; then
    if [ "$EXPIRY_MODE" = advisory ]; then
      echo "cve_accepted_diff: WARNING — $id was accepted only through $exp, and today is $TODAY."
      echo "  The nightly scan fails on this, and so does any pull request touching the"
      echo "  allowlist. It is a warning HERE so an expiry cannot block branches that"
      echo "  cannot fix it — see the note on --expiry-advisory in this script."
      continue
    fi
    echo "cve_accepted_diff: FAIL — $id was accepted only through $exp, and today is $TODAY."
    echo "  Re-examine it: has upstream rebuilt? is the reason below still true?"
    echo "  reason on file:$why"
    bad=1; continue
  fi
  window="$(days_between "$TODAY" "$exp")"
  if [ "$window" -gt "$MAX_ACCEPTANCE_DAYS" ]; then
    echo "cve_accepted_diff: FAIL — $id is accepted for $window days (through $exp)," \
         "and the limit is $MAX_ACCEPTANCE_DAYS."
    echo "  An expiry far enough away is a permanent exemption wearing a date. Shorten it;"
    echo "  if the finding is still unfixable when it arrives, move it again, deliberately."
    bad=1; continue
  fi
  printf '%s\n' "$id" >> "$WORK/accepted-ids"
done < "$ACCEPTED_FILE"

sort -u -o "$WORK/accepted-ids" "$WORK/accepted-ids"

if [ "$VALIDATE_ONLY" -eq 1 ]; then
  [ "$bad" -eq 0 ] || exit 1
  echo "cve_accepted_diff: accepted=$(wc -l < "$WORK/accepted-ids" | tr -d ' ')"
  echo "cve_accepted_diff: OK — all acceptances well-formed as of $TODAY" \
       "(expiry: $EXPIRY_MODE)"
  exit 0
fi

# --- the found list, and the provenance that makes an EMPTY one meaningful ------------
#
# THIS IS THE MOST IMPORTANT DOZEN LINES IN THE GATE, because without them an empty found
# list is simultaneously "the image is clean" and "nothing was scanned", and the gate
# cannot tell. Adversarial QA walked the consequence all the way down:
#
#   a scan yields no ids -> every acceptance looks stale -> the gate prints "Delete them"
#   -> a human does exactly that -> from then on the job is GREEN, for ever, over an image
#   nobody is scanning.
#
# It is not a far-fetched path. The allowlist is DESIGNED to shrink to zero, so the state
# in which the stale arm stops covering for the missing provenance is the state the design
# is aiming at. An unreadable found file reached it too: the old `|| : > found-ids`
# swallowed the read error and substituted the empty set, so a permission problem was
# reported as "the scan no longer reports them. Delete them."
#
# So: no `||` fallback — a read failure aborts under `set -e` — and a found list with no
# ids must SAY a scan happened. `cve_findings_from_trivy.sh` writes that line; a
# hand-written list gets the same treatment as a broken one, which is correct.
# `|| true` IS LOAD-BEARING, AND FOR THE OPPOSITE REASON TO THE ONE IT USUALLY IS. On a
# zero-byte found file `grep -v '^$'` matches nothing, exits 1, and `pipefail` + `set -e`
# abort the script HERE — before the provenance check below can say why. That made the
# most important error message in this gate unreachable for the exact input it exists to
# catch, which is the same defect an independent review found in the workflow's "no
# digest-pinned image" branch. Measured, both times, by running it.
#
# Nothing is being swallowed: an unreadable file was already rejected by the `-r` check,
# and an empty result now falls into the provenance check rather than into `comm`.
tr -d '\r' < "$FOUND_FILE" | sed 's/[[:space:]]//g' | grep -v '^$' | sort -u \
  > "$WORK/found-raw" || true

grep -q '^#scan' "$WORK/found-raw" && HAS_PROVENANCE=1 || HAS_PROVENANCE=0
grep -v '^#' "$WORK/found-raw" > "$WORK/found-ids" || : > "$WORK/found-ids"

if [ ! -s "$WORK/found-ids" ] && [ "$HAS_PROVENANCE" -eq 0 ]; then
  echo "cve_accepted_diff: FAIL — the found list is empty and carries no scan provenance."
  echo "  An empty list means either 'the image is clean' or 'nothing was scanned', and"
  echo "  those must never be the same verdict. Produce it with"
  echo "  cve_findings_from_trivy.sh, which states a clean result rather than implying it."
  echo "  This is NOT a verdict about the image."
  exit 1
fi

echo "accepted: $(tr '\n' ' ' < "$WORK/accepted-ids")"
echo "found:    $(tr '\n' ' ' < "$WORK/found-ids")"

# --- 1. findings nobody accepted ----------------------------------------------------
comm -13 "$WORK/accepted-ids" "$WORK/found-ids" > "$WORK/new-ids"
if [ -s "$WORK/new-ids" ]; then
  echo "cve_accepted_diff: FAIL — NEW fixable HIGH/CRITICAL findings in the pinned image:"
  print_capped "$WORK/new-ids"
  echo "  Accept each with a reason and a valid-through date in the allowlist, or move the pin."
  bad=1
fi

# --- 3. acceptances that no longer match anything -----------------------------------
comm -23 "$WORK/accepted-ids" "$WORK/found-ids" > "$WORK/stale-ids"
if [ -s "$WORK/stale-ids" ]; then
  echo "cve_accepted_diff: FAIL — STALE entries; the scan no longer reports them:"

  print_capped "$WORK/stale-ids"
  echo "  Delete them. An exemption that exempts nothing still reads as though it means something."
  bad=1
fi

[ "$bad" -eq 0 ] || exit 1
echo "cve_accepted_diff: accepted=$(wc -l < "$WORK/accepted-ids" | tr -d ' ')"
echo "cve_accepted_diff: OK — $(wc -l < "$WORK/accepted-ids" | tr -d ' ') accepted, 0 unaccepted, 0 stale"
