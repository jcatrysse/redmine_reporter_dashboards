#!/usr/bin/env bash
#
# EVERY GATE, AT THE CONFIGURATION A RELEASE IS JUDGED BY, IN ONE COMMAND.
#
# --- WHY THIS FILE EXISTS ---
#
# An independent review's R-08. Most gates here take a MODE, and most of them default to
# `warn`, because the default is tuned for the person editing the file rather than for the
# person cutting the release. The consequence is a PASS-shaped result that is not a pass:
#
#     $ ./script/gates/vendor_integrity.sh
#     vendor_integrity: a shipped file loads a library over the network:
#     examples/sample_report_template.liquid:82: … cdnjs.cloudflare.com …
#     vendor_integrity: mode=warn  vendored files=2  cdn references=2
#     $ echo $?
#     0
#
# That is a gate reporting two policy violations and exiting zero, and it is exactly how the
# two CDN examples survived as long as they did. The individual scripts stay
# developer-friendly; this one is the release verdict, and it is the only thing that should
# ever be quoted as "the gates are green".
#
# --- WHERE THIS DELIBERATELY DIFFERS FROM `ci.yml`'s `gates` JOB ---
#
# In exactly one place, and it is a difference of purpose rather than a drift:
#
#   `cve_accepted_diff.sh` runs WITHOUT `--expiry-advisory` here. `ci.yml` runs on
#   `push: branches: ['**']`, so a hard expiry there means every branch in the repository
#   goes red on the morning a third party's Chromium acceptance ages out — and the cheapest
#   unblock is a one-character date bump nobody re-examines, which is the "gate becomes
#   furniture" outcome the expiry exists to prevent. A RELEASE is the one moment when an
#   acceptance that nobody has re-examined must stop the build. So it is advisory there and
#   hard here, and both places say so.
#
# Everything else is set to the same value `ci.yml` sets, INCLUDING the modes that are not
# strict. `zero_reporter` and `compat_size` are ratchets over debt the project has decided
# to hold visibly rather than pretend away; forcing them strict here would make this script
# something nobody runs, which is the failure mode it was written against.
#
# --- WHAT STOPS THIS SCRIPT GOING STALE ---
#
# A wrapper that forgets a gate is worse than no wrapper, because its summary reads as
# coverage. So the last thing it does is check itself: every `script/gates/*.sh` is either
# run above, a `*_selftest.sh` (run as part of its gate), named in `HELPERS` because another
# gate calls it, or named in `COVERED_ELSEWHERE` with the CI job that owns it. A new gate
# that is added and not wired in fails this script rather than being silently absent from it.
#
# --- USAGE ---
#
#   ./script/gates/release.sh                  run everything, report, exit non-zero on any
#                                              failure. It does NOT stop at the first one —
#                                              a release wants the whole list.
#   ./script/gates/release.sh --coverage-only   run ONLY the self-check above. This is what
#                                              `ci.yml` calls: the individual gates stay
#                                              individual steps there, so a failure names
#                                              itself in the Actions UI, and this one cheap
#                                              step is what stops the two lists drifting.

set -uo pipefail

COVERAGE_ONLY=0
case "${1:-}" in
  --coverage-only) COVERAGE_ONLY=1 ;;
  '') ;;
  *) echo "release: unknown option '$1' (expected --coverage-only or nothing)" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

GATES_DIR='script/gates'

# Gates that are real gates but belong to another CI job, with the reason. `release.sh`
# installs no gems and clones no Redmine, so it cannot run these; naming them here is what
# keeps the summary honest about its own scope.
declare -A COVERED_ELSEWHERE=(
  [drop_reference_parity.sh]='the `rspec` job — it loads the Liquid gem to read the tag registry'
)

# Not gates at all: scripts under `script/gates/` that another gate calls. Listed rather than
# pattern-matched, because "anything with `helper` in the name is not a gate" is the kind of
# rule that quietly excuses a real gate one rename later.
declare -A HELPERS=(
  [cve_findings_from_trivy.sh]='the extractor `cve_accepted_diff.sh` and the nightly scan both call'
)

PASSED=()
FAILED=()

run_gate() {
  local name="$1"
  shift

  [ "$COVERAGE_ONLY" -eq 1 ] && return 0

  printf '\n\033[1m── %s ─────────────────────────────────────────────\033[0m\n' "$name"
  if "$@"; then
    PASSED+=("$name")
  else
    FAILED+=("$name")
  fi
}

if [ "$COVERAGE_ONLY" -eq 1 ]; then
  echo "release: --coverage-only — checking that this script accounts for every gate, running none."
else
  echo "release gates — $(git rev-parse --short HEAD 2>/dev/null || echo 'no git') in $ROOT"
fi

# --- the gates, in `ci.yml`'s order so the two can be read side by side -----------------

run_gate no_secrets "$GATES_DIR/no_secrets.sh"

# Warn, as in CI: the reporter integration still exists and a handful of files legitimately
# name it. What is enforced either way is the ratchet — an unlisted reference fails.
ZERO_REPORTER_MODE=warn run_gate zero_reporter "$GATES_DIR/zero_reporter.sh"

# STRICT here, warn in CI, and this is not the documented difference above — it is a
# measurement. CI's comment says the legacy glue still needs per-thread state; measured on
# this tree the gate reports `referencing files=0  exempt=0`, so strict and warn are the
# same verdict and strict is the one that stays true. If this ever fails, the glue came
# back and a release is the right place to find out.
NO_THREAD_LOCAL_MODE=strict run_gate no_thread_local "$GATES_DIR/no_thread_local.sh"

LAYER_PURITY_MODE=strict run_gate layer_purity "$GATES_DIR/layer_purity.sh"

# No budget, as in CI. §Findings F-4 is the open question about whether the compat LOC
# should become a cap; until it is answered, this prints the number rather than capping it.
run_gate compat_size "$GATES_DIR/compat_size.sh"

# THE HOLE THIS SCRIPT WAS WRITTEN FOR. `vendor_integrity.sh` was not run by any CI job at
# all — it existed, it was correct, and nothing called it. Strict, because a shipped file
# that fetches a library over the network contradicts the bundled/no-egress asset default
# the plugin ships with, and §6 rejects CDN-with-SRI: integrity proves the bytes and does
# nothing about the egress.
VENDOR_INTEGRITY_MODE=strict run_gate vendor_integrity "$GATES_DIR/vendor_integrity.sh"

run_gate chrome_no_design_tokens bash -c \
  "$GATES_DIR/chrome_no_design_tokens_selftest.sh && $GATES_DIR/chrome_no_design_tokens.sh"

run_gate no_html_safe bash -c \
  "$GATES_DIR/no_html_safe_selftest.sh && $GATES_DIR/no_html_safe.sh"

run_gate single_parse "$GATES_DIR/single_parse.sh"

run_gate migration_reversibility "$GATES_DIR/migration_reversibility.sh"

# WITHOUT `--expiry-advisory`. See the header: this is the one deliberate difference from
# `ci.yml`, and it is the whole reason a release wrapper is not just a shorter way to type
# the CI job.
run_gate gotenberg_accepted_cves bash -c \
  "$GATES_DIR/cve_accepted_diff_selftest.sh && \
   $GATES_DIR/cve_accepted_diff.sh --validate-only $GATES_DIR/gotenberg_accepted_cves.allowlist"

# --- the self-check ---------------------------------------------------------------------

printf '\n\033[1m── coverage ───────────────────────────────────────\033[0m\n'

unwired=()
for path in "$GATES_DIR"/*.sh; do
  name="$(basename "$path")"

  case "$name" in
    release.sh|*_selftest.sh) continue ;;
  esac

  if [ -n "${HELPERS[$name]:-}" ]; then
    echo "release: $name — not a gate: ${HELPERS[$name]}"
    continue
  fi

  if [ -n "${COVERED_ELSEWHERE[$name]:-}" ]; then
    echo "release: $name — not run here: ${COVERED_ELSEWHERE[$name]}"
    continue
  fi

  # `run_gate <name>` where <name> is the basename without `.sh`, or the script path itself
  # appearing in a command line above. Both spellings are used, so both are searched.
  if ! grep -qE "(run_gate|GATES_DIR/)${name%.sh}(\.sh|[[:space:]])" "${BASH_SOURCE[0]}"; then
    unwired+=("$name")
  fi
done

if [ "${#unwired[@]}" -gt 0 ]; then
  echo "release: FAIL — gate(s) exist that this script neither runs nor accounts for:" >&2
  printf '  %s\n' "${unwired[@]}" >&2
  echo "  Add it above, or add it to COVERED_ELSEWHERE with the CI job that owns it." >&2
  echo "  A release wrapper that silently skips a gate is worse than no wrapper." >&2
  FAILED+=('release-coverage')
else
  echo "release: every gate under $GATES_DIR/ is run here or accounted for."
fi

# --- the verdict ------------------------------------------------------------------------

# THE ONE SENTENCE THIS SCRIPT MUST NEVER GET WRONG. `--coverage-only` ran no gate, so it
# must not print the line that says every gate passed — that is the PASS-shaped result the
# whole file was written against, and it would be this script telling the lie.
if [ "$COVERAGE_ONLY" -eq 1 ]; then
  if [ "${#FAILED[@]}" -gt 0 ]; then
    echo
    echo 'release: coverage check FAILED. No gate was run.'
    exit 1
  fi

  echo
  echo 'release: coverage check passed. NO GATE WAS RUN — this says nothing about the code.'
  exit 0
fi

printf '\n\033[1m── verdict ────────────────────────────────────────\033[0m\n'
printf 'passed: %d\n' "${#PASSED[@]}"

if [ "${#FAILED[@]}" -gt 0 ]; then
  printf 'FAILED: %d\n' "${#FAILED[@]}"
  printf '  %s\n' "${FAILED[@]}"
  echo
  echo 'release: NOT RELEASABLE on the gates above.'
  exit 1
fi

echo
echo 'release: every gate passes at its release configuration.'
