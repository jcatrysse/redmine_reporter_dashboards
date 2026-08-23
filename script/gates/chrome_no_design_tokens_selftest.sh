#!/usr/bin/env bash
set -euo pipefail

# The self-test for `chrome_no_design_tokens.sh` — T-38.
#
# --- WHY A GATE NEEDS ONE OF THESE, IN THIS REPOSITORY IN PARTICULAR -------------------
#
# `layer_purity.sh` shipped a version that reported every layer clean while checking
# nothing, and was caught only because somebody planted the violation before trusting it.
# `cve_accepted_diff.sh` has carried a committed self-test ever since, for the same reason.
# This file is that convention applied to the newest gate — and it is not ceremony: the
# FIRST version of the gate it tests reported `OK` on four of its arms while its
# comment-stripper was crashing, because a failing pipe and a clean file are the same empty
# string, and a SECOND version passed while examining almost nothing, because the strip was
# greedy across the joined file and deleted every rule between the first and the last
# comment. Both are here as cases.
#
# --- IT RUNS THE GATE AGAINST A THROWAWAY TREE, NOT AGAINST THE REPOSITORY -------------
#
# The gate derives its root from its own path, so a copy of it in `/tmp/x/script/gates/`
# scans `/tmp/x/assets/stylesheets/`. That is what lets this file plant violations without
# ever touching the real stylesheet — a self-test that edited the subject it protects would
# be one bad `trap` away from being the defect.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/script/gates/chrome_no_design_tokens.sh"
[ -x "$GATE" ] || { echo "selftest: FAIL — $GATE is not executable"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/script/gates" "$WORK/assets/stylesheets"
cp "$GATE" "$WORK/script/gates/"

PASSED=0
FAILED=0

# `expect` is "fails" or "passes" — what the gate must do about this stylesheet.
check() {
  local expect="$1" label="$2" css="$3"
  printf '%s' "$css" > "$WORK/assets/stylesheets/probe.css"

  local rc=0
  ( cd "$WORK" && ./script/gates/chrome_no_design_tokens.sh >/dev/null 2>&1 ) || rc=$?

  local got
  if [ "$rc" -eq 0 ]; then got=passes; else got=fails; fi

  if [ "$got" = "$expect" ]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    echo "selftest: FAIL — expected the gate to $expect on '$label', it $got (exit $rc)"
  fi
}

# A layout-only stylesheet, which is what chrome is allowed to be. Everything below either
# adds one forbidden declaration to this or is a near-miss that must NOT be a finding.
CLEAN='.a { display: flex; gap: 16px; margin-top: 4px; }
.b { width: 100%; min-height: 40em; resize: vertical; }
.c { text-decoration: none; float: right; vertical-align: middle; }
'

check passes 'layout only'                        "$CLEAN"

# ---- arm 1: colour, in every spelling ------------------------------------------------
check fails  'hex colour'                         "$CLEAN.d { color: #abc; }"
check fails  '8-digit hex'                        "$CLEAN.d { outline-color: #aabbccdd; }"
check fails  'rgb()'                              "$CLEAN.d { background: rgb(1, 2, 3); }"
check fails  'rgba()'                             "$CLEAN.d { background: rgba(1, 2, 3, .5); }"
check fails  'hsl()'                              "$CLEAN.d { background: hsl(1 2% 3%); }"
check fails  'oklch()'                            "$CLEAN.d { background: oklch(0.7 0.1 200); }"
check fails  'color-mix()'                        "$CLEAN.d { background: color-mix(in srgb, red, blue); }"
check fails  'a named colour in a property'       "$CLEAN.d { background: red; }"

# ---- arm 2: the properties that decide the look --------------------------------------
check fails  'color'                              "$CLEAN.d { color: currentColor; }"
check fails  'background shorthand'               "$CLEAN.d { background: none; }"
check fails  'border shorthand with no colour'    "$CLEAN.d { border: 1px solid; }"
check fails  'border-bottom'                      "$CLEAN.d { border-bottom: 1px dashed; }"
check fails  'box-shadow'                         "$CLEAN.d { box-shadow: 0 0 1px; }"
check fails  'fill'                               "$CLEAN.d { fill: none; }"
check fails  'font-family'                        "$CLEAN.d { font-family: serif; }"
check fails  'font-size'                          "$CLEAN.d { font-size: 11px; }"
check fails  'font-weight'                        "$CLEAN.d { font-weight: bold; }"
check fails  'line-height'                        "$CLEAN.d { line-height: 1; }"
check fails  'font shorthand'                     "$CLEAN.d { font: 12px/1 serif; }"

# ---- arm 3: a custom property DECLARATION -------------------------------------------
check fails  'custom property'                    "$CLEAN:root { --rrd-gap: 4px; }"

# ---- arm 4: a bundled typeface -------------------------------------------------------
check fails  '@font-face'                         "$CLEAN@font-face { src: local(x); }"

check fails  'a vendor-prefixed colour property'  "$CLEAN.d { -webkit-text-fill-color: currentColor; }"
check fails  'a vendor-prefixed font property'    "$CLEAN.d { -moz-font-feature-settings: normal; }"

# ---- the near-misses. Each of these is text that MENTIONS a forbidden construct or
# ---- merely contains its letters, and none of them is a finding. §Findings E-14's
# ---- lesson: a scanner that cannot tell code from prose is confidently wrong.
check passes 'a comment naming a colour'          "$CLEAN/* color: #abc is forbidden here */"
check passes 'a multi-line comment naming one'    "$CLEAN/* the rule
   forbids color: #abc and font-size
   and says why */"
check passes 'a class name containing border'     "$CLEAN.rrd-border-box { margin: 0; }"
check passes 'a class name containing background'  "$CLEAN.background-thing { display: flex; }"
check passes 'a var() READ of Redmine own token'  "$CLEAN.d { padding: var(--oc-gap); }"

# ---- THE TWO FAILURES THE GATE ITSELF HAS HAD -----------------------------------------
#
# 1. MID-FILE. The greedy sed strip deleted everything between the first `/*` and the last
#    `*/`, so a violation between two comments was invisible while one appended at the END
#    was caught. Every arm above appends; this one does not.
check fails  'a violation BETWEEN two comments' "/* first comment */
.d { color: #123456; }
/* last comment */
$CLEAN"

# 2. A CRASHED READER. `strip_comments` reads the file as UTF-8 and `gsub`es it, so a byte
#    that is not valid UTF-8 raises — which is the SAME class of failure the gate met for
#    real on its first run, where a container with no `LANG` made Ruby read every file as
#    US-ASCII and raise on an em dash. Driven with a real invalid byte rather than by
#    patching the gate, because what has to be proven is that the gate STOPS, and the
#    version this replaced detected the condition and exited 0 anyway: its guard lived
#    inside the function the arms call through `$( … )`, and an `exit` in a command
#    substitution exits a subshell.
printf '.ok { display: flex; }\n' > "$WORK/assets/stylesheets/probe.css"
printf '\xff\xfe .broken { display: flex; }\n' > "$WORK/assets/stylesheets/not-utf8.css"
rc=0
( cd "$WORK" && ./script/gates/chrome_no_design_tokens.sh >/dev/null 2>&1 ) || rc=$?
if [ "$rc" -eq 0 ]; then
  FAILED=$((FAILED + 1))
  echo 'selftest: FAIL — the gate passed on a file its reader could not read. A reader that'
  echo '                 did not read is not a clean file.'
else
  PASSED=$((PASSED + 1))
fi
rm -f "$WORK/assets/stylesheets/not-utf8.css"

# 3. A STYLESHEET THAT SURVIVES THE STRIP AS NOTHING. Either it is all comments or the strip
#    swallowed the rules, and the gate cannot tell those apart — so it stops on both. An
#    all-comment stylesheet is the reachable half, and it is the honest place to fail: a file
#    with no rule in it is either pointless or evidence that the reader is broken, and both
#    want somebody to look.
printf '/* a comment and nothing else at all */\n' > "$WORK/assets/stylesheets/probe.css"
rc=0
( cd "$WORK" && ./script/gates/chrome_no_design_tokens.sh >/dev/null 2>&1 ) || rc=$?
if [ "$rc" -eq 0 ]; then
  FAILED=$((FAILED + 1))
  echo 'selftest: FAIL — the gate passed on a stylesheet that strips to nothing, so it'
  echo '                 examined no rule and said so to nobody.'
else
  PASSED=$((PASSED + 1))
fi

# 4. AN ABSENT SUBJECT. A grep over a directory that has been renamed finds nothing and
#    exits 0, which is indistinguishable from a directory that is clean.
rm -f "$WORK/assets/stylesheets/probe.css"
rc=0
( cd "$WORK" && ./script/gates/chrome_no_design_tokens.sh >/dev/null 2>&1 ) || rc=$?
if [ "$rc" -eq 0 ]; then
  FAILED=$((FAILED + 1))
  echo 'selftest: FAIL — the gate passed with NO stylesheet to read. "clean" and "did not run"'
  echo '                 are the two states a gate exists to distinguish.'
else
  PASSED=$((PASSED + 1))
fi

echo "chrome_no_design_tokens_selftest: $PASSED case(s) passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
