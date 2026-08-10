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
# `.github/workflows/gotenberg-cve.yml` runs it twice: once on the real scan, and once on
# six synthetic inputs that each trip exactly one arm. Those two have to be THE SAME CODE
# or the self-test proves something about a copy. That is the difference between "the gate
# can fail" and "a thing shaped like the gate can fail", and this project's last three
# reviews found the second one three times.
#
# --- THE FOUR WAYS IT SAYS NO --------------------------------------------------------
#
#   1. a found id nobody accepted       — a new vulnerability in the pinned image
#   2. an accepted id past its date     — an acceptance nobody re-examined
#   3. an accepted id nothing reports   — a stale exemption; delete it
#   4. a record that is malformed       — no CVE id, no valid date, or no reason
#
# (3) exists because an exemption list only stays honest if entries LEAVE it. (4) exists
# because an acceptance whose expiry does not parse is an acceptance that never expires,
# and this repository already has a rule about tokens that never expire.
#
# Exit 0 when every finding is accepted and every acceptance is live and dated; 1 otherwise.
# Every rejection prints a `::error::` line naming the id and the reason, so a red run in
# Actions annotates itself and a red run on a laptop still reads.

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
VALIDATE_ONLY=0
if [ "${1:-}" = "--validate-only" ]; then
  VALIDATE_ONLY=1
  shift
  [ "$#" -eq 1 ] || usage
  ACCEPTED_FILE="$1"
  FOUND_FILE=""
else
  [ "$#" -eq 2 ] || usage
  ACCEPTED_FILE="$1"
  FOUND_FILE="$2"
fi

for f in "$ACCEPTED_FILE" ${FOUND_FILE:+"$FOUND_FILE"}; do
  # A MISSING INPUT IS AN ERROR, NOT AN EMPTY SET. `comm` against a file that is not
  # there would otherwise make "the scan produced nothing" and "the scan did not run"
  # the same green.
  [ -f "$f" ] || { echo "::error::$(basename "$0"): no such file: $f" >&2; exit 2; }
done

TODAY="${CVE_GATE_TODAY:-$(date -u +%F)}"   # overridable so the expiry arm is testable
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

bad=0

# --- parse and validate the accepted list ------------------------------------------
: > "$WORK/accepted-ids"
while IFS= read -r raw || [ -n "$raw" ]; do
  line="${raw#"${raw%%[![:space:]]*}"}"          # strip leading whitespace
  case "$line" in ''|'#'*) continue ;; esac

  id="$(printf '%s' "$line"  | cut -d'|' -f1 | tr -d '[:space:]')"
  exp="$(printf '%s' "$line" | cut -d'|' -f2 | tr -d '[:space:]')"
  why="$(printf '%s' "$line" | cut -d'|' -f3-)"

  # NOT `^CVE-`, AND THE REASON IS A DEFECT THIS GATE HAD UNTIL MUTATION TESTING FOUND
  # IT. Trivy's `VulnerabilityID` is not always a CVE: Go and npm advisories with no CVE
  # assigned arrive as `GHSA-…`, and Debian's unfixed-but-tracked entries as `TEMP-…`.
  # A gate that recognised only `CVE-` would have DROPPED those from both sides of the
  # comparison and reported green with an unaccepted finding sitting in the image — the
  # one failure this whole job exists to prevent.
  #
  # So the shape is "an uppercase advisory prefix, then something", which admits every
  # scheme a scanner might emit without enumerating them (an enumeration would go stale
  # and reject the very id somebody is trying to accept, leaving them stuck red). It
  # still rejects the realistic typo: a lowercase word, or a bare number.
  if ! printf '%s' "$id" | grep -qE '^[A-Z][A-Z0-9]{1,15}-[A-Za-z0-9.-]+$'; then
    echo "::error::accepted list: '$id' is not an advisory id — record: $line"
    bad=1; continue
  fi
  if ! printf '%s' "$exp" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    echo "::error::accepted list: $id has no valid-through date (got '$exp')."
    echo "::error::  An acceptance without an expiry never gets re-examined. Use YYYY-MM-DD."
    bad=1; continue
  fi
  if [ -z "$(printf '%s' "$why" | tr -d '[:space:]')" ]; then
    echo "::error::accepted list: $id carries no reason. Every exemption carries one."
    bad=1; continue
  fi
  if [ "$TODAY" \> "$exp" ]; then
    echo "::error::accepted list: $id was accepted only through $exp, and today is $TODAY."
    echo "::error::  Re-examine it: has upstream rebuilt? is the reason below still true?"
    echo "::error::  reason on file:$why"
    bad=1; continue
  fi
  printf '%s\n' "$id" >> "$WORK/accepted-ids"
done < "$ACCEPTED_FILE"

sort -u -o "$WORK/accepted-ids" "$WORK/accepted-ids"

if [ "$VALIDATE_ONLY" -eq 1 ]; then
  [ "$bad" -eq 0 ] || exit 1
  echo "$(wc -l < "$WORK/accepted-ids" | tr -d ' ') acceptance(s), all well-formed and current as of $TODAY"
  exit 0
fi

# The found list is normalised the same way the accepted ids were, so a duplicate id, a
# CRLF line ending or a trailing space cannot turn into a phantom "unaccepted finding".
# Blank lines go; NOTHING ELSE DOES. An id this gate does not recognise is left in, so it
# lands in the comparison and turns the run red — dropping it would be the silent-green
# failure described above, one filter further along.
tr -d '\r' < "$FOUND_FILE" | sed 's/[[:space:]]//g' | grep -v '^$' | sort -u \
  > "$WORK/found-ids" || : > "$WORK/found-ids"

echo "accepted: $(tr '\n' ' ' < "$WORK/accepted-ids")"
echo "found:    $(tr '\n' ' ' < "$WORK/found-ids")"

# --- 1. findings nobody accepted ----------------------------------------------------
comm -13 "$WORK/accepted-ids" "$WORK/found-ids" > "$WORK/new-ids"
if [ -s "$WORK/new-ids" ]; then
  echo "::error::NEW fixable HIGH/CRITICAL findings in the pinned image:"
  while IFS= read -r id; do echo "::error::  $id"; done < "$WORK/new-ids"
  bad=1
fi

# --- 3. acceptances that no longer match anything -----------------------------------
comm -23 "$WORK/accepted-ids" "$WORK/found-ids" > "$WORK/stale-ids"
if [ -s "$WORK/stale-ids" ]; then
  echo "::error::STALE entries in the accepted list — the scan no longer reports them."
  echo "::error::  Delete them. An exemption that exempts nothing still reads as though it means something."
  while IFS= read -r id; do echo "::error::  $id"; done < "$WORK/stale-ids"
  bad=1
fi

[ "$bad" -eq 0 ] || exit 1
echo "$(wc -l < "$WORK/accepted-ids" | tr -d ' ') accepted, 0 unaccepted, 0 stale"
