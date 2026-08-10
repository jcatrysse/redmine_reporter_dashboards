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
check "every finding accepted, acceptance live" 0 "OK — 1 accepted, 0 unaccepted, 0 stale"

# --- comments, blank lines and indentation are ignored, not treated as records --------
{ echo '# a comment'; echo ''; echo '   '; \
  echo '  CVE-2026-19155 | 2026-09-09 | indented records parse'; } > "$ACC"
printf 'CVE-2026-19155\n' > "$FOUND"
check "comments and blank lines ignored" 0 "OK — 1 accepted"

# --- 1. a finding nobody accepted ----------------------------------------------------
printf 'CVE-2026-19155 | 2026-09-09 | accepted\n' > "$ACC"
printf 'CVE-2026-19155\nCVE-2030-00001\n'         > "$FOUND"
check "a new, unaccepted finding" 1 "NEW fixable HIGH/CRITICAL"

# --- 2. an acceptance past its date --------------------------------------------------
# Found list EMPTY, so the unaccepted arm cannot be what fires.
printf 'CVE-2026-19155 | 2026-08-09 | accepted yesterday, and only through yesterday\n' > "$ACC"
printf '#scan targets=4 report=synthetic\n' > "$FOUND"
check "an acceptance that expired yesterday" 1 "was accepted only through 2026-08-09"

# THE BOUNDARY, AND ONE PAST IT. `valid-through` means what it says: the last day it
# holds is the date on the record. Both sides of that edge are tested because "at the
# limit and one past it" is the rule, and an off-by-one here silently extends or revokes
# every exemption in the list by a day.
printf 'CVE-2026-19155 | 2026-08-10 | valid through today\n' > "$ACC"
printf 'CVE-2026-19155\n' > "$FOUND"
check "an acceptance valid through today" 0 "OK — 1 accepted"

# --- 3. an acceptance nothing reports any more ---------------------------------------
printf 'CVE-2026-19155 | 2026-09-09 | accepted\n' > "$ACC"
printf '#scan targets=4 report=synthetic\n' > "$FOUND"
check "a stale acceptance" 1 "STALE entries; this scan does not report them"

# --- 4. malformed records ------------------------------------------------------------
printf 'CVE-2026-19155 | soon | accepted\n' > "$ACC"
printf '#scan targets=4 report=synthetic\n' > "$FOUND"
check "an expiry that is not a date" 1 "no valid-through date"

printf 'CVE-2026-19155 | 2026-09-09 |\n' > "$ACC"
printf '#scan targets=4 report=synthetic\n' > "$FOUND"
check "an exemption with no reason" 1 "carries no reason"

# THE ID GRAMMAR IS ALMOST NOTHING, ON PURPOSE. A stricter one refused ids Trivy really
# emits (`pyup.io-38834`, `RHSA-2021:1234`), which made the gate unsatisfiable: findable
# and unacceptable at once. What it must still refuse is a token that could never have
# come off the found list.
printf ' | 2026-09-09 | an empty id\n' > "$ACC"
printf '#scan targets=4 report=synthetic\n' > "$FOUND"
check "an empty id" 1 "is not usable as an advisory id"

printf 'CVE-2026 -19155 | 2026-09-09 | a space inside the id\n' > "$ACC"
printf '#scan targets=4 report=synthetic\n' > "$FOUND"
check "whitespace inside an id" 1 "is not usable as an advisory id"

# FINDABLE MUST IMPLY ACCEPTABLE. These are the ids the previous grammar rejected, and
# each one made the gate refuse the exact remedy it had just demanded.
for weird in 'pyup.io-38834' 'RHSA-2021:1234' 'openSUSE-SU-2021:0001' 'TEMP-0000000-A0F5D5'; do
  printf '%s | 2026-09-09 | an id shape a scanner really emits\n' "$weird" > "$ACC"
  printf '#scan targets=4 report=synthetic\n%s\n' "$weird" > "$FOUND"
  check "a findable id is acceptable: $weird" 0 "OK — 1 accepted"
done

# A MISTYPED ID IS REPORTED BY THE STALE ARM, which is a better message than a grammar
# complaint because it names the real problem: this entry covers nothing.
printf 'CVE-2026-19156 | 2026-09-09 | one digit wrong\n' > "$ACC"
printf '#scan targets=4 report=synthetic\nCVE-2026-19155\n' > "$FOUND"
check "a mistyped id surfaces as stale, not as bad grammar" 1 "mistyped and covers nothing"

# A DATE-SHAPED STRING THAT IS NOT A DAY. Both of these satisfy `[0-9]{4}-[0-9]{2}-[0-9]{2}`
# and NEITHER CAN EVER ARRIVE, so either is an acceptance that never expires — the exact
# defect this gate exists to make impossible, and it shipped: an independent review passed
# `9999-99-99 | reason` as a live acceptance at every clock it tried. The previous case for
# this arm used `| soon |`, which discriminates "looks like a date" from "is a string" and
# says nothing about "is a real day", so it passed for the wrong reason.
printf 'CVE-2026-19155 | 2026-13-45 | month 13, day 45\n' > "$ACC"
printf '#scan targets=4 report=synthetic\n' > "$FOUND"
check "a date-shaped string with an impossible month and day" 1 "no valid-through date"

printf 'CVE-2026-19155 | 9999-99-99 | the never-expiring exemption\n' > "$ACC"
printf '#scan targets=4 report=synthetic\n' > "$FOUND"
check "9999-99-99, which no clock ever reaches" 1 "no valid-through date"

# AND THE ONE THAT IS A REAL DAY BUT NOT CANONICAL. `2026-8-10` fails the shape check
# before `date` ever sees it; this asserts the record is REPORTED rather than silently
# normalised into something the file does not say.
printf 'CVE-2026-19155 | 2026-8-10 | not zero-padded\n' > "$ACC"
printf '#scan targets=4 report=synthetic\n' > "$FOUND"
check "a date that is not zero-padded" 1 "no valid-through date"

# --- 5. an expiry so far out that it is a permanent exemption -------------------------
# `2099-12-31 | reason` is well-formed, in the future, and never re-examined. Requiring an
# expiry to be PRESENT does not bound it; requiring it to be NEAR does.
printf 'CVE-2026-19155 | 2099-12-31 | forever, in effect\n' > "$ACC"
printf '#scan targets=4 report=synthetic\n' > "$FOUND"
check "an expiry far enough away to be permanent" 1 "and the limit is 90"

# AT THE LIMIT AND ONE PAST IT — 90 days from the injected clock of 2026-08-10 is
# 2026-11-08, and 91 is 2026-11-09.
printf 'CVE-2026-19155 | 2026-11-08 | exactly 90 days out\n' > "$ACC"
printf 'CVE-2026-19155\n' > "$FOUND"
check "an acceptance exactly at the 90-day limit" 0 "OK — 1 accepted"

printf 'CVE-2026-19155 | 2026-11-09 | 91 days out\n' > "$ACC"
printf '#scan targets=4 report=synthetic\n' > "$FOUND"
check "an acceptance one day past the limit" 1 "is accepted for 91 days"

# --- the injected clock is validated and announced ------------------------------------
# An unvalidated clock override on a security gate is a way to disable every expiry
# leaving no trace. Garbage must be refused, and a run using one must never be mistakable
# for a real run.
printf 'CVE-2026-19155 | 2026-09-09 | accepted\n' > "$ACC"
printf '#scan targets=4 report=synthetic\n' > "$FOUND"
rc=0; out="$(CVE_GATE_TODAY=lunchtime bash "$GATE" --validate-only "$ACC" 2>&1)" || rc=$?
cases=$((cases + 1))
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF "is not a date"; then
  echo "ok    a garbage CVE_GATE_TODAY is refused (exit 2)"
else
  echo "FAIL  a garbage CVE_GATE_TODAY should exit 2: got $rc"
  echo "$out" | sed 's/^/        | /'
  fail=1
fi

rc=0; out="$(CVE_GATE_TODAY=2026-08-10 bash "$GATE" --validate-only "$ACC" 2>&1)" || rc=$?
cases=$((cases + 1))
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF "INJECTED clock"; then
  echo "ok    an injected clock announces itself (exit 0)"
else
  echo "FAIL  an injected clock must say so on stderr: got $rc"
  echo "$out" | sed 's/^/        | /'
  fail=1
fi

# NON-CVE ADVISORY IDS ARE FIRST-CLASS. Trivy emits `GHSA-…` for Go and npm advisories
# with no CVE assigned and `TEMP-…` for Debian entries, and a gate that only understood
# `CVE-` would drop them from BOTH sides and report green with an unaccepted finding in
# the image. That defect was in this gate until mutation M12 exposed it.
printf 'GHSA-abcd-efgh-ijkl | 2026-09-09 | a Go advisory with no CVE assigned\n' > "$ACC"
printf 'GHSA-abcd-efgh-ijkl\n' > "$FOUND"
check "a GHSA id is accepted like any other" 0 "OK — 1 accepted"

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
check "CRLF, blank lines and trailing spaces in the found list" 0 "OK — 1 accepted"

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
validate_only "--validate-only accepts a live, well-formed record" 0 "accepted=1"

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

# =====================================================================================
# THE EXTRACTION HALF — cve_findings_from_trivy.sh
# =====================================================================================
#
# WHY THIS IS HERE AND NOT LEFT TO THE WORKFLOW. It was a `jq` line in
# `gotenberg-cve.yml`, untested, and an independent review broke it in one command: apply
# the SAME `^CVE-` narrowing that mutation testing had just caught inside the gate, one
# step upstream in the jq, and the job goes green with an unaccepted advisory in the image
# while this self-test still reports every case passing. A boundary of "proved reachable"
# that stops short of the glue is drawn in the wrong place.
EXTRACT="$HERE/cve_findings_from_trivy.sh"
FIXTURE="$HERE/fixtures/trivy-report.sample.json"
[ -f "$EXTRACT" ] || { echo "self-test: $EXTRACT is missing"; exit 2; }
[ -f "$FIXTURE" ] || { echo "self-test: $FIXTURE is missing"; exit 2; }

# THE EXACT SET, not a count and not a subset. `GHSA-4wf9-vq2p-2xrm` is in the fixture for
# exactly one reason: it is what disappears if anybody narrows extraction to `^CVE-`.
rc=0; out="$(bash "$EXTRACT" "$FIXTURE" 2>/dev/null)" || rc=$?
cases=$((cases + 1))
provenance="$(printf '%s\n' "$out" | head -1)"
ids="$(printf '%s\n' "$out" | tail -n +2)"
want="CVE-2026-19155
CVE-2026-46602
CVE-2026-46604
CVE-2026-56852
GHSA-4wf9-vq2p-2xrm"
if [ "$rc" -eq 0 ] && [ "$ids" = "$want" ]; then
  echo "ok    the real report yields exactly its five advisories, GHSA included (exit 0)"
else
  echo "FAIL  extraction from the sample report is wrong (exit $rc). Got:"
  printf '%s\n' "$out" | sed 's/^/        | /'
  fail=1
fi

# PROVENANCE IS STATED, NEVER IMPLIED. Without this line an empty found list means both
# "clean image" and "nothing was scanned", and the gate cannot tell them apart.
cases=$((cases + 1))
if printf '%s' "$provenance" | grep -qE '^#scan targets=4 '; then
  echo "ok    the extraction states its provenance on the first line"
else
  echo "FAIL  first line should be '#scan targets=4 …', got: $provenance"
  fail=1
fi

# The two chromium rows carry ONE id between them; a report that yields it twice would
# make the comparison's `sort -u` the only thing saving it.
cases=$((cases + 1))
if [ "$(printf '%s\n' "$ids" | grep -c '^CVE-2026-19155$')" -eq 1 ]; then
  echo "ok    two packages sharing one advisory yield one id"
else
  echo "FAIL  CVE-2026-19155 should appear exactly once"
  fail=1
fi

# TARGETS WITH NOTHING IN THEM MUST CONTRIBUTE NOTHING, NOT ABORT. The fixture has one
# target with `Vulnerabilities: null` and one with no such key at all, both of which Trivy
# really writes. A traversal without `?` fails on them, and a failed extraction that is
# not noticed produces an EMPTY found list — which is a green gate.
cases=$((cases + 1))
if [ "$rc" -eq 0 ]; then
  echo "ok    a null and an absent Vulnerabilities key are survived, not fatal"
else
  echo "FAIL  extraction aborted on a clean target (exit $rc)"
  fail=1
fi

# --- an unusable report is UNMEASURED, never clean ------------------------------------
extract_rejects() { # extract_rejects <name> <file> <expected-exit> <substring>
  local name="$1" f="$2" want_rc="$3" want_msg="$4" rc=0 out
  cases=$((cases + 1))
  out="$(bash "$EXTRACT" "$f" 2>&1)" || rc=$?
  if [ "$rc" -eq "$want_rc" ] && printf '%s' "$out" | grep -qF -- "$want_msg"; then
    echo "ok    $name (exit $rc)"
  else
    echo "FAIL  $name: expected exit $want_rc and '$want_msg', got exit $rc"
    printf '%s\n' "$out" | sed 's/^/        | /'
    fail=1
  fi
}

printf 'this is not json' > "$WORK/bad.json"
extract_rejects "a report that is not JSON" "$WORK/bad.json" 1 "NOTHING WAS READ"

printf '' > "$WORK/empty.json"
extract_rejects "an empty report file" "$WORK/empty.json" 1 "NOTHING WAS READ"

printf '{"SchemaVersion":2,"Results":[]}' > "$WORK/notargets.json"
extract_rejects "a report with no scan targets" "$WORK/notargets.json" 1 "NOTHING WAS SCANNED"

printf '{"SchemaVersion":2}' > "$WORK/noresults.json"
extract_rejects "a report with no Results key at all" "$WORK/noresults.json" 1 "NOTHING WAS SCANNED"

extract_rejects "a report file that is not there" "$WORK/absent.json" 2 "cannot read"

# AND THE CASE THAT MUST *NOT* BE REJECTED: a real scan of a clean image. Targets present,
# no vulnerabilities. This is the one green the gate has to keep believing, and conflating
# it with "the scanner did not run" would make a clean image unreportable.
printf '{"SchemaVersion":2,"Results":[{"Target":"x","Vulnerabilities":[]}]}' > "$WORK/clean.json"
rc=0; out="$(bash "$EXTRACT" "$WORK/clean.json" 2>/dev/null)" || rc=$?
cases=$((cases + 1))
if [ "$rc" -eq 0 ] \
   && [ "$(printf '%s\n' "$out" | grep -vc '^#')" -eq 0 ] \
   && printf '%s' "$out" | grep -q '^#scan targets=1'; then
  echo "ok    a clean scan yields provenance and no ids, not silence (exit 0)"
else
  echo "FAIL  a clean scan should exit 0 with provenance and no ids: exit $rc, output '$out'"
  fail=1
fi

# AND THE GATE MUST ACCEPT THAT — a clean scan is the one green it has to keep believing.
printf '#scan targets=1 report=clean.json\n' > "$FOUND"
printf '# nothing accepted, because nothing was found\n' > "$ACC"
check "a clean scan against an empty allowlist" 0 "OK — 0 accepted, 0 unaccepted, 0 stale"

# WHEREAS AN EMPTY FILE WITH NO PROVENANCE IS UNMEASURED. This is the chain adversarial
# QA walked: a broken scan makes every acceptance look stale, the gate says "delete
# them", somebody does, and the job is green for ever over an image nobody scans.
: > "$FOUND"
printf '# nothing accepted\n' > "$ACC"
check "an empty found list with no provenance" 1 "carries no scan provenance"

: > "$FOUND"
printf 'CVE-2026-19155 | 2026-09-09 | accepted\n' > "$ACC"
check "an empty found list does not read as 'all stale'" 1 "carries no scan provenance"

# --- --expiry-advisory: downgraded in one place, and ONLY there -----------------------
printf 'CVE-2026-19155 | 2026-08-09 | expired yesterday\n' > "$ACC"
rc=0; out="$(CVE_GATE_TODAY=2026-08-10 bash "$GATE" --validate-only --expiry-advisory "$ACC" 2>&1)" || rc=$?
cases=$((cases + 1))
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF 'WARNING'; then
  echo "ok    --expiry-advisory warns instead of failing on an expired record (exit 0)"
else
  echo "FAIL  --expiry-advisory should warn and exit 0: got $rc"
  echo "$out" | sed 's/^/        | /'
  fail=1
fi

# WELL-FORMEDNESS STAYS HARD EVEN THERE. Advisory applies to the EXPIRY arm only; a
# malformed or unbounded record is a mistake in the file, not a clock running out, and
# nothing is gained by letting it through anywhere.
printf 'CVE-2026-19155 | 9999-99-99 | still refused\n' > "$ACC"
rc=0; out="$(CVE_GATE_TODAY=2026-08-10 bash "$GATE" --validate-only --expiry-advisory "$ACC" 2>&1)" || rc=$?
cases=$((cases + 1))
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF 'no valid-through date'; then
  echo "ok    --expiry-advisory does not soften record validation (exit 1)"
else
  echo "FAIL  --expiry-advisory must still reject a malformed record: got $rc"
  echo "$out" | sed 's/^/        | /'
  fail=1
fi

printf 'CVE-2026-19155 | 2099-12-31 | still refused\n' > "$ACC"
rc=0; out="$(CVE_GATE_TODAY=2026-08-10 bash "$GATE" --validate-only --expiry-advisory "$ACC" 2>&1)" || rc=$?
cases=$((cases + 1))
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF 'the limit is 90'; then
  echo "ok    --expiry-advisory does not soften the acceptance window (exit 1)"
else
  echo "FAIL  --expiry-advisory must still bound the window: got $rc"
  echo "$out" | sed 's/^/        | /'
  fail=1
fi

# AND IT IS REFUSED WHERE IT WOULD LEAVE NOTHING ENFORCING THE EXPIRY. The nightly
# comparison is the detector; an advisory expiry there is an expiry nowhere.
printf 'CVE-2026-19155 | 2026-09-09 | accepted\n' > "$ACC"
printf '#scan targets=4 report=synthetic\nCVE-2026-19155\n' > "$FOUND"
rc=0; out="$(CVE_GATE_TODAY=2026-08-10 bash "$GATE" --expiry-advisory "$ACC" "$FOUND" 2>&1)" || rc=$?
cases=$((cases + 1))
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF 'only meaningful with'; then
  echo "ok    --expiry-advisory is refused on the comparison (exit 2)"
else
  echo "FAIL  --expiry-advisory should be refused without --validate-only: got $rc"
  echo "$out" | sed 's/^/        | /'
  fail=1
fi

rc=0; out="$(bash "$GATE" --nonsense "$ACC" 2>&1)" || rc=$?
cases=$((cases + 1))
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF 'unknown option'; then
  echo "ok    an unknown option is refused (exit 2)"
else
  echo "FAIL  an unknown option should exit 2: got $rc"
  fail=1
fi

# --- mutants that survived an adversarial QA pass, now covered ------------------------
# Mb: the existence check applied to the ACCEPTED file only. The self-test named a missing
# accepted file and never a missing FOUND one, so deleting half the check was invisible.
printf 'CVE-2026-19155 | 2026-09-09 | accepted\n' > "$ACC"
rc=0; out="$(CVE_GATE_TODAY=2026-08-10 bash "$GATE" "$ACC" "$WORK/no-such-found" 2>&1)" || rc=$?
cases=$((cases + 1))
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF 'cannot read'; then
  echo "ok    a missing FOUND file is exit 2, not an empty set (exit 2)"
else
  echo "FAIL  a missing found file must exit 2: got $rc"
  echo "$out" | sed 's/^/        | /'
  fail=1
fi

# Mj: dropping `|| [ -n "$raw" ]` silently loses the LAST record of a file with no final
# newline — which is what a hand-edited allowlist often is.
printf 'CVE-2026-19155 | 2026-09-09 | first\nCVE-2026-46602 | 2026-09-09 | last, no newline' > "$ACC"
printf '#scan targets=4 report=synthetic\nCVE-2026-19155\nCVE-2026-46602\n' > "$FOUND"
check "a file with no trailing newline keeps its last record" 0 "OK — 2 accepted"

# Md: de-duplication of the accepted ids. Without it a repeated entry makes `comm` see an
# unsorted-looking input and the counts stop meaning anything.
printf 'CVE-2026-19155 | 2026-09-09 | once\nCVE-2026-19155 | 2026-09-09 | and again\n' > "$ACC"
printf '#scan targets=4 report=synthetic\nCVE-2026-19155\n' > "$FOUND"
check "a duplicated acceptance counts once" 0 "OK — 1 accepted, 0 unaccepted, 0 stale"

# --- a missing input is an error, not an empty set -----------------------------------
# Both files exist in every case above, so this is the one arm that has to be reached by
# naming a file that is not there. It matters because `comm` against a missing file would
# otherwise let "the scan did not run" arrive as "the scan found nothing".
rc=0
out="$(bash "$GATE" "$WORK/absent" "$FOUND" 2>&1)" || rc=$?
cases=$((cases + 1))
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF 'cannot read'; then
  echo "ok    a missing input file (exit 2)"
else
  echo "FAIL  a missing input file: expected exit 2 and 'cannot read', got exit $rc"
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
