#!/usr/bin/env bash
set -euo pipefail

# Self-test for `cve_accepted_diff.sh` — T-34.
#
# THE GATE MUST BE ABLE TO SAY NO, AND THIS PROVES IT RATHER THAN ASSERTING IT.
#
# `cve_accepted_diff.sh` is a list of accepted CVEs compared against a list of found ones,
# and the whole class of defect it invites is the one this project's reviews keep finding:
# a check that runs, prints something reassuring, and cannot go red. An accepted-findings
# list is an especially easy place to build one, because the failure it is guarding
# against — a NEW vulnerability in an image nobody controls — does not exist on the day
# you write it, so nothing disproves a gate that never fires.
#
# So each of the gate's refusals gets a case here, and each case is constructed so that
# ONLY THAT ARM can fire: the expiry cases run against an EMPTY found-list, so a non-zero
# exit cannot be coming from the unaccepted-finding arm instead. Exit codes are not enough
# on their own — every refusal exits 1 — so every case also matches the text of the
# message, which is what tells the arms apart.
#
# `CVE_GATE_TODAY` is why the expiry arms are testable at all: without an injectable
# clock the only ways to test an expiry are to wait for it or to write a fixture relative
# to `Date.today`, and CLAUDE.md §6 forbids the second for the reason this repository has
# already been bitten by it.
#
# Run it directly; it needs nothing but the gate script beside it.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/cve_accepted_diff.sh"
[ -f "$GATE" ] || { echo "self-test: $GATE is missing"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ACC="$WORK/accepted"
FOUND="$WORK/found"

fail=0
cases=0

# check <name> <expected-exit> <expected-message-substring|-> ; reads $ACC and $FOUND
check() {
  local name="$1" want_rc="$2" want_msg="$3" rc=0 out
  cases=$((cases + 1))
  out="$(CVE_GATE_TODAY=2026-08-10 bash "$GATE" "$ACC" "$FOUND" 2>&1)" || rc=$?

  if [ "$rc" -ne "$want_rc" ]; then
    echo "FAIL  $name: expected exit $want_rc, got $rc"
    echo "$out" | sed 's/^/        | /'
    fail=1
    return
  fi
  if [ "$want_msg" != "-" ] && ! printf '%s' "$out" | grep -qF -- "$want_msg"; then
    echo "FAIL  $name: exit $rc was right, but the message did not mention: $want_msg"
    echo "$out" | sed 's/^/        | /'
    fail=1
    return
  fi
  echo "ok    $name (exit $rc)"
}

# --- the control. If this one is not green, nothing below means anything. -------------
printf 'CVE-2026-19155 | 2026-09-09 | accepted, with a reason\n' > "$ACC"
printf 'CVE-2026-19155\n'                                        > "$FOUND"
check "every finding accepted, acceptance live" 0 "1 accepted, 0 unaccepted, 0 stale"

# --- comments, blank lines and indentation are ignored, not treated as records --------
{ echo '# a comment'; echo ''; echo '   '; \
  echo '  CVE-2026-19155 | 2026-09-09 | indented records parse'; } > "$ACC"
printf 'CVE-2026-19155\n' > "$FOUND"
check "comments and blank lines ignored" 0 "1 accepted"

# --- 1. a finding nobody accepted ----------------------------------------------------
printf 'CVE-2026-19155 | 2026-09-09 | accepted\n' > "$ACC"
printf 'CVE-2026-19155\nCVE-2030-00001\n'         > "$FOUND"
check "a new, unaccepted finding" 1 "NEW fixable HIGH/CRITICAL"

# --- 2. an acceptance past its date --------------------------------------------------
# Found list EMPTY, so the unaccepted arm cannot be what fires.
printf 'CVE-2026-19155 | 2026-08-09 | accepted yesterday, and only through yesterday\n' > "$ACC"
: > "$FOUND"
check "an acceptance that expired yesterday" 1 "was accepted only through 2026-08-09"

# THE BOUNDARY, AND ONE PAST IT. `valid-through` means what it says: the last day it
# holds is the date on the record. Both sides of that edge are tested because "at the
# limit and one past it" is the rule, and an off-by-one here silently extends or revokes
# every exemption in the list by a day.
printf 'CVE-2026-19155 | 2026-08-10 | valid through today\n' > "$ACC"
printf 'CVE-2026-19155\n' > "$FOUND"
check "an acceptance valid through today" 0 "1 accepted"

# --- 3. an acceptance nothing reports any more ---------------------------------------
printf 'CVE-2026-19155 | 2026-09-09 | accepted\n' > "$ACC"
: > "$FOUND"
check "a stale acceptance" 1 "STALE entries"

# --- 4. malformed records ------------------------------------------------------------
printf 'CVE-2026-19155 | soon | accepted\n' > "$ACC"
: > "$FOUND"
check "an expiry that is not a date" 1 "no valid-through date"

printf 'CVE-2026-19155 | 2026-09-09 |\n' > "$ACC"
: > "$FOUND"
check "an exemption with no reason" 1 "carries no reason"

printf 'not-a-cve | 2026-09-09 | accepted\n' > "$ACC"
: > "$FOUND"
check "an id with no advisory prefix" 1 "is not an advisory id"

# NON-CVE ADVISORY IDS ARE FIRST-CLASS. Trivy emits `GHSA-…` for Go and npm advisories
# with no CVE assigned and `TEMP-…` for Debian entries, and a gate that only understood
# `CVE-` would drop them from BOTH sides and report green with an unaccepted finding in
# the image. That defect was in this gate until mutation M12 exposed it.
printf 'GHSA-abcd-efgh-ijkl | 2026-09-09 | a Go advisory with no CVE assigned\n' > "$ACC"
printf 'GHSA-abcd-efgh-ijkl\n' > "$FOUND"
check "a GHSA id is accepted like any other" 0 "1 accepted"

printf 'CVE-2026-19155 | 2026-09-09 | accepted\n' > "$ACC"
printf 'CVE-2026-19155\nGHSA-abcd-efgh-ijkl\n'    > "$FOUND"
check "an unaccepted GHSA finding is still a finding" 1 "GHSA-abcd-efgh-ijkl"

# --- a rejected record must not also join the accepted set ---------------------------
# M11: dropping the `continue` after the expiry error leaves the expired id in the
# accepted set. The verdict does not change — it is red either way — but the report
# does, and it reports the OPPOSITE of the truth: the entry is simultaneously announced
# as expired and counted as a live acceptance, which is how it would come to be treated
# as covering a finding nobody has accepted.
printf 'CVE-2026-19155 | 2026-08-09 | expired yesterday\n' > "$ACC"
printf 'CVE-2026-19155\n' > "$FOUND"
rc=0; out="$(CVE_GATE_TODAY=2026-08-10 bash "$GATE" "$ACC" "$FOUND" 2>&1)" || rc=$?
cases=$((cases + 1))
if [ "$rc" -eq 1 ] \
   && printf '%s' "$out" | grep -qF 'was accepted only through' \
   && printf '%s' "$out" | grep -qF 'NEW fixable HIGH/CRITICAL'; then
  echo "ok    an expired record does not silently cover its finding (exit 1)"
else
  echo "FAIL  an expired record should be reported expired AND its finding unaccepted"
  echo "$out" | sed 's/^/        | /'
  fail=1
fi

# --- the found list is normalised, not taken literally --------------------------------
# M12: a CRLF checkout, a trailing space or a blank line must not manufacture an
# unaccepted finding. This is the arm that turns a cosmetic difference in whoever
# produced the list into a red build for no reason — and a gate that cries wolf is a
# gate somebody turns off.
printf 'CVE-2026-19155 | 2026-09-09 | accepted\n' > "$ACC"
printf 'CVE-2026-19155 \r\n\r\nCVE-2026-19155\n'  > "$FOUND"
check "CRLF, blank lines and trailing spaces in the found list" 0 "1 accepted"

# --- --validate-only: the half that runs on every pull request ------------------------
# It must check the records and NOT the comparison — an expired acceptance has to fail it
# (that is the whole reason it exists) while a perfectly ordinary "the scan reports things
# this file accepts" must not, since no scan has run.
validate_only() { # validate_only <name> <expected-exit> <expected-substring|->
  local name="$1" want_rc="$2" want_msg="$3" rc=0 out
  cases=$((cases + 1))
  out="$(CVE_GATE_TODAY=2026-08-10 bash "$GATE" --validate-only "$ACC" 2>&1)" || rc=$?
  if [ "$rc" -ne "$want_rc" ] \
     || { [ "$want_msg" != "-" ] && ! printf '%s' "$out" | grep -qF -- "$want_msg"; }; then
    echo "FAIL  $name: expected exit $want_rc and '$want_msg', got exit $rc"
    echo "$out" | sed 's/^/        | /'
    fail=1
    return
  fi
  echo "ok    $name (exit $rc)"
}

printf 'CVE-2026-19155 | 2026-09-09 | accepted\n' > "$ACC"
validate_only "--validate-only accepts a live, well-formed record" 0 "1 acceptance(s)"

printf 'CVE-2026-19155 | 2026-08-09 | expired yesterday\n' > "$ACC"
validate_only "--validate-only fails on an expired acceptance" 1 "was accepted only through"

printf 'CVE-2026-19155 | whenever | accepted\n' > "$ACC"
validate_only "--validate-only fails on a malformed date" 1 "no valid-through date"

# AND IT MUST NOT SMUGGLE THE COMPARISON IN. If `--validate-only` also ran the set
# difference it would report every acceptance as stale — nothing was scanned — and the
# gates job would be red on every pull request for a reason that is not true.
printf 'CVE-2026-19155 | 2026-09-09 | accepted\n' > "$ACC"
rc=0; out="$(CVE_GATE_TODAY=2026-08-10 bash "$GATE" --validate-only "$ACC" 2>&1)" || rc=$?
cases=$((cases + 1))
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qF 'STALE'; then
  echo "ok    --validate-only does not run the comparison (exit 0)"
else
  echo "FAIL  --validate-only ran the comparison: exit $rc"
  echo "$out" | sed 's/^/        | /'
  fail=1
fi

# --- a missing input is an error, not an empty set -----------------------------------
# Both files exist in every case above, so this is the one arm that has to be reached by
# naming a file that is not there. It matters because `comm` against a missing file would
# otherwise let "the scan did not run" arrive as "the scan found nothing".
rc=0
out="$(bash "$GATE" "$WORK/absent" "$FOUND" 2>&1)" || rc=$?
cases=$((cases + 1))
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF 'no such file'; then
  echo "ok    a missing input file (exit 2)"
else
  echo "FAIL  a missing input file: expected exit 2 and 'no such file', got exit $rc"
  echo "$out" | sed 's/^/        | /'
  fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "cve_accepted_diff self-test: $cases cases, all as specified"
else
  echo "cve_accepted_diff self-test: FAILED"
fi
exit "$fail"
