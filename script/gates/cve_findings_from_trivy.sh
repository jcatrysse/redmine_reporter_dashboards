#!/usr/bin/env bash
set -euo pipefail

# Gate helper — T-34. Turns a Trivy JSON report into the list of advisory ids the gate
# compares against `gotenberg_accepted_cves.allowlist`.
#
#   cve_findings_from_trivy.sh <report.json>
#
# One id per line on stdout. Exit 0 when the report was usable — INCLUDING when it names
# no vulnerabilities at all. Exit 1 when it was not, with a message saying so.
#
# --- WHY THIS IS A FILE AND NOT A `jq` LINE IN THE WORKFLOW --------------------------
#
# It was a jq line in the workflow, and an independent review broke it in one command.
# The defect this whole change exists to prevent is a filter that quietly drops findings
# the gate has not accepted: `cve_accepted_diff.sh` used to narrow both sides of its
# comparison to `^CVE-`, which would have hidden every `GHSA-…` and `TEMP-…` id Trivy
# emits. That was found by mutation testing and fixed — and then the SAME mutation,
# applied one step upstream to the jq expression, produced a green gate with an
# unaccepted advisory in the image while the self-test still reported every case passing.
#
# The extraction is therefore code, in a file, driven by the self-test over a committed
# sample report — the same argument `cve_accepted_diff.sh` makes about itself. A boundary
# of "proved reachable" that stops one step short of the glue is a boundary drawn in the
# wrong place.
#
# --- NO FILTERING, DELIBERATELY ------------------------------------------------------
#
# Trivy is asked for `--severity HIGH,CRITICAL --ignore-unfixed` at the point of
# invocation, so everything in the report is already something somebody could act on.
# This script narrows NOTHING further. An id in a shape nobody anticipated reaches the
# comparison and turns the run red, which is the safe direction: a human then reads it
# and either accepts it with a reason or moves the pin.

usage() { echo "usage: $(basename "$0") <trivy-report.json>" >&2; exit 2; }

[ "$#" -eq 1 ] || usage
REPORT="$1"

[ -f "$REPORT" ] || {
  echo "cve_findings_from_trivy: FAIL — cannot read: $REPORT" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || {
  echo "cve_findings_from_trivy: FAIL — jq is not installed, so NOTHING WAS READ." >&2
  echo "  This is not a verdict about the image." >&2
  exit 1
}

# A REPORT THAT IS NOT JSON IS UNMEASURED, NOT CLEAN. Trivy writing a truncated file, or
# the step before this one failing in a way that left an empty one, must not arrive as
# "no findings".
if ! jq -e . "$REPORT" >/dev/null 2>&1; then
  echo "cve_findings_from_trivy: FAIL — $REPORT is not valid JSON, so NOTHING WAS READ." >&2
  echo "  This is not a verdict about the image." >&2
  exit 1
fi

# NOR IS A REPORT WITH NO TARGETS. The scanned image has a Debian layer, a jar and two Go
# binaries; a report whose `Results` is absent or empty scanned nothing, and "no findings"
# from it would be the most dangerous green in this repository.
#
# Note what this does NOT claim: a report WITH targets and zero vulnerabilities is a
# legitimate clean result and exits 0 with no output. The distinguishable failure is "the
# scanner did not look", not "the scanner found nothing".
targets="$(jq '[.Results[]?] | length' "$REPORT")"
if [ "${targets:-0}" -lt 1 ]; then
  echo "cve_findings_from_trivy: FAIL — $REPORT names no scan targets. NOTHING WAS SCANNED." >&2
  echo "  This is not a verdict about the image." >&2
  exit 1
fi

# PROVENANCE FIRST, AND IT IS NOT DECORATION. Without it an EMPTY found list means two
# opposite things — "the image is clean" and "nothing was scanned" — and the gate has to
# guess. Adversarial QA walked the whole chain: a scan that yields no ids makes every
# acceptance look stale, the gate prints "Delete them", a human does exactly that, and
# from then on the job is permanently GREEN over an image nobody is scanning. The
# allowlist is *designed* to shrink to zero, so that end state is the one the design aims
# at rather than an edge case.
#
# So a clean result is stated, never inferred from silence, and `cve_accepted_diff.sh`
# refuses a found list that does not carry this line.
echo "#scan targets=$targets report=$(basename "$REPORT")"

# `?` on both traversals so a target with no `Vulnerabilities` key, or a null one — both
# of which Trivy really does emit for a clean target — contribute nothing instead of
# aborting the whole extraction.
jq -r '[.Results[]?.Vulnerabilities[]?.VulnerabilityID] | unique[]' "$REPORT"

echo "cve_findings_from_trivy: read $targets target(s) from $REPORT" >&2
