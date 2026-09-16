#!/usr/bin/env bash
set -uo pipefail

# The negative test for `no_html_safe.sh` — T-27.
#
# This repository's rule, written in `layer_purity.sh` and repeated in `ci.yml`:
# **a gate nobody has watched fail is not yet a gate.** Every arm below plants the
# violation the gate exists to catch, or the construct it must NOT flag, and asserts the
# outcome. `chrome_no_design_tokens_selftest.sh` and `cve_accepted_diff_selftest.sh` are
# the same shape and run ahead of their gate in CI.
#
# The first version of `no_html_safe.sh` was negative-tested interactively and shipped
# without this file. An independent review then found FOUR holes that an interactive test
# had not thought to plant — `raw` without parentheses, `<%==`, a crashing search, and a
# missing search path — which is precisely the argument for committing the test rather
# than performing it once. Arms 6-9 are those four.
#
# It works on a COPY of the tree under a temporary root, so it can add and remove files
# without touching the working tree. HANDOVER §1: a harness that mutates the real tree
# eventually leaves a mutation in it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/script/gates/no_html_safe.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A minimal but REALISTIC tree: the gate has a floor on how many files it scanned, so a
# two-file fixture would fail for the wrong reason. Copy the real app/ and lib/.
mkdir -p "$TMP/script/gates"
cp -r "$ROOT/app" "$ROOT/lib" "$TMP/"
cp "$GATE" "$TMP/script/gates/"
cp "$ROOT/script/gates/no_html_safe.allowlist" "$TMP/script/gates/" 2>/dev/null || \
  : > "$TMP/script/gates/no_html_safe.allowlist"

PROBE_RB="$TMP/lib/rrd_selftest_probe.rb"
PROBE_ERB="$TMP/app/views/rrd_selftest_probe.html.erb"

failures=0

# Runs the gate against the temporary tree and compares its exit status.
# The status is captured on its OWN line — HANDOVER §1 records a sweep that read
# `basename`'s exit code instead of the command's and reported a failing gate as rc=0.
expect() {
  local label="$1" want="$2" out rc
  out="$(cd "$TMP" && bash script/gates/no_html_safe.sh 2>&1)"
  rc=$?
  if [ "$rc" -eq "$want" ]; then
    echo "  ok   $label (rc=$rc)"
  else
    echo "  FAIL $label — expected rc=$want, got rc=$rc" >&2
    echo "$out" | sed 's/^/       /' >&2
    failures=$((failures + 1))
  fi
  rm -f "$PROBE_RB" "$PROBE_ERB"
}

echo "no_html_safe_selftest:"

# --- 0. THE CLEAN TREE PASSES. Without this arm every other arm could be passing
# --- because the gate always fails.
expect "a clean tree passes" 0

# --- 1. The violation itself.
printf 'module P\n  def probe(v)\n    v.html_safe\n  end\nend\n' > "$PROBE_RB"
expect "html_safe on a value fails" 1

# --- 2. Prose is not code. This repo's comment density makes this the common case.
printf 'module P\n  # never call v.html_safe here\n  def probe(v)\n    v\n  end\nend\n' > "$PROBE_RB"
expect "a comment mentioning html_safe passes" 0

# --- 3. Rails' empty-buffer idiom is not the defect INV-9 names.
printf "module P\n  def probe\n    ''.html_safe\n  end\nend\n" > "$PROBE_RB"
expect "the empty-buffer idiom passes" 0

# --- 4. AND THE EXEMPTION MUST NOT LAUNDER THE REST OF ITS LINE. The first version
# --- dropped the whole matching line, so this PASSED while the comment promised it
# --- would not.
printf "module P\n  def probe(v)\n    ''.html_safe << v.html_safe\n  end\nend\n" > "$PROBE_RB"
expect "an exempt call does not launder a real one on the same line" 1

# --- 5. ERB is scanned, not just Ruby.
printf '<%%= @v.html_safe %%>\n' > "$PROBE_ERB"
expect "html_safe inside an .erb fails" 1

# --- 6. `raw` WITHOUT PARENTHESES, IN AN ERB OUTPUT TAG — the idiomatic Rails form and
# --- the place the helper is actually used. Missed by the first version of the gate.
printf '<%%= raw @v %%>\n' > "$PROBE_ERB"
expect "bare raw inside an ERB output tag fails" 1

# --- 6b. THE KNOWN GAP, ASSERTED RATHER THAN HIDDEN.
#
# A bare `raw v` in a `.rb` file is NOT flagged, deliberately. Distinguishing that call
# from the assignment `raw = v` is not something grep can do, and the pattern that tried
# (`\braw[[:space:](]`) matched a local variable in `query_aggregator.rb` and reported 20
# real files. There are zero bare `raw` calls in the plugin's Ruby today.
#
# This arm exists so the gap is a RECORDED PROPERTY with a test that goes red if somebody
# widens the pattern — at which point they should delete this arm and keep the widening,
# having first checked the false-positive count. A limitation nobody wrote down is a
# limitation the next reader mistakes for coverage.
printf 'module P\n  def probe(v)\n    raw v\n  end\nend\n' > "$PROBE_RB"
expect "a bare raw call in Ruby is a KNOWN GAP and passes" 0

# --- 7. `<%==` — Erubi's raw-output shorthand, exactly `<%= raw … %>`, also missed.
printf '<%%== @v %%>\n' > "$PROBE_ERB"
expect "the <%%== shorthand fails" 1

# --- 8. raw( off the allowlist fails; on it, passes.
printf 'module P\n  def probe(v)\n    raw(v)\n  end\nend\n' > "$PROBE_RB"
expect "raw() off the allowlist fails" 1

printf 'module P\n  def probe(v)\n    raw(v)\n  end\nend\n' > "$PROBE_RB"
echo "lib/rrd_selftest_probe.rb	selftest" >> "$TMP/script/gates/no_html_safe.allowlist"
expect "raw() on the allowlist passes" 0

# --- 9. A STALE ENTRY FAILS. An allowlist entry permitting nothing today is what
# --- silently permits something tomorrow.
expect "a stale allowlist entry fails" 1
sed -i '/rrd_selftest_probe/d' "$TMP/script/gates/no_html_safe.allowlist"

# --- 9b. THE CAP, AT IT AND ONE PAST IT ---------------------------------------------
#
# CLAUDE.md Phase 3: "For anything with a limit, test AT the limit and one past it."
# The limit is two files, and an off-by-one here is the difference between enforcing
# T-27's `Accept:` line and enforcing something adjacent to it.
PROBE_A="$TMP/lib/rrd_selftest_cap_a.rb"
PROBE_B="$TMP/lib/rrd_selftest_cap_b.rb"
PROBE_C="$TMP/lib/rrd_selftest_cap_c.rb"
cap_probe() { printf 'module P\n  def probe(v)\n    raw(v)\n  end\nend\n' > "$1"; }

cap_probe "$PROBE_A"
cap_probe "$PROBE_B"
{ echo "lib/rrd_selftest_cap_a.rb	selftest"; echo "lib/rrd_selftest_cap_b.rb	selftest"; } \
  >> "$TMP/script/gates/no_html_safe.allowlist"
out="$(cd "$TMP" && bash script/gates/no_html_safe.sh 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  ok   two allowlisted files is AT the cap and passes (rc=$rc)"
else
  echo "  FAIL two allowlisted files — expected rc=0, got rc=$rc" >&2
  echo "$out" | sed 's/^/       /' >&2
  failures=$((failures + 1))
fi

cap_probe "$PROBE_C"
echo "lib/rrd_selftest_cap_c.rb	selftest" >> "$TMP/script/gates/no_html_safe.allowlist"
out="$(cd "$TMP" && bash script/gates/no_html_safe.sh 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && echo "$out" | grep -q 'the cap is 2'; then
  echo "  ok   three allowlisted files is one PAST the cap and fails (rc=$rc)"
else
  echo "  FAIL three allowlisted files — expected rc=1 naming the cap, got rc=$rc" >&2
  echo "$out" | sed 's/^/       /' >&2
  failures=$((failures + 1))
fi
rm -f "$PROBE_A" "$PROBE_B" "$PROBE_C"
sed -i '/rrd_selftest_cap/d' "$TMP/script/gates/no_html_safe.allowlist"

# --- 10. A SEARCH THAT CRASHES MUST NOT REPORT PASS. The first version called `exit 2`
# --- inside a command substitution, which exited the subshell and let the script go on
# --- to print PASS and exit 0.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 3\n' > "$TMP/bin/grep"
chmod +x "$TMP/bin/grep"
out="$(cd "$TMP" && PATH="$TMP/bin:$PATH" bash script/gates/no_html_safe.sh 2>&1)"
rc=$?
if [ "$rc" -eq 2 ]; then
  echo "  ok   a crashing search exits 2 rather than passing (rc=$rc)"
else
  echo "  FAIL a crashing search — expected rc=2, got rc=$rc" >&2
  echo "$out" | sed 's/^/       /' >&2
  failures=$((failures + 1))
fi
rm -rf "$TMP/bin"

# --- 11. A MISSING SEARCH PATH MUST NOT REPORT PASS. Run from the wrong root, the
# --- first version certified INV-9 having read nothing.
mv "$TMP/app" "$TMP/app-moved"
out="$(cd "$TMP" && bash script/gates/no_html_safe.sh 2>&1)"
rc=$?
if [ "$rc" -eq 2 ]; then
  echo "  ok   a missing search path exits 2 rather than passing (rc=$rc)"
else
  echo "  FAIL a missing search path — expected rc=2, got rc=$rc" >&2
  echo "$out" | sed 's/^/       /' >&2
  failures=$((failures + 1))
fi
mv "$TMP/app-moved" "$TMP/app"

if [ "$failures" -ne 0 ]; then
  echo "no_html_safe_selftest: FAIL — $failures arm(s) did not behave as specified" >&2
  exit 1
fi

echo "no_html_safe_selftest: PASS — every arm behaves as specified"
