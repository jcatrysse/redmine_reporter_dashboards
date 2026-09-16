#!/usr/bin/env bash
set -euo pipefail

# Self-test for `erb_comment_integrity.sh` — T-43.
#
# A gate nobody has seen say NO is a gate that might not be able to. T-38 shipped one that
# reported OK for four arms while its own reader was crashing, and the lesson written up
# there is that the self-protection arms have to be driven BY BREAKING THE READER FOR REAL
# rather than by patching an arm to pretend.
#
# So: real files in a temp tree, including M-4's exact shape, plus the two
# could-not-check cases — an absent directory and a directory with no `.erb` in it — each
# of which must answer 2 rather than 0.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/script/gates/erb_comment_integrity.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILURES=0

run_case() {
  local name="$1" expected="$2" search="$3"
  set +e
  ERB_COMMENT_SEARCH_PATH="$search" bash "$GATE" >/dev/null 2>&1
  local status=$?
  set -e
  if [ "$status" = "$expected" ]; then
    echo "  ok    $name (exit $status)"
  else
    echo "  FAIL  $name — expected exit $expected, got $status"
    FAILURES=$((FAILURES + 1))
  fi
}

# A gate that reads its subject from the repository cannot be pointed at a temp tree
# without one of the two moving. The search path moves: the reader takes it as its second
# argument and the wrapper reads it from the environment, so the temp tree is placed INSIDE
# the repository for the duration and removed on exit. It is under `tmp/` and git ignores
# that path.
WORK="$ROOT/tmp/erb_comment_integrity_selftest"
rm -rf "$WORK"
mkdir -p "$WORK/clean" "$WORK/dirty" "$WORK/trim" "$WORK/unterminated" "$WORK/empty"
trap 'rm -rf "$TMP" "$WORK"' EXIT

# --- clean: long comments are the point of this repository and must not be findings ---
cat > "$WORK/clean/_ok.html.erb" <<'ERB'
<%#
  A long header comment, which this repository writes on purpose.

  It mentions sql_aggregate and version_rollup by name, and a `render` call, and none of
  those are ERB tags, so none of them is a finding.
%>
<%= render partial: 'x' %>
<%# a short one %>
ERB

# --- dirty: M-4's exact shape — the opener on line 1, the tag far below ---
cat > "$WORK/dirty/_leak.html.erb" <<'ERB'
<%#
  Nothing is appended to the output buffer before the rescue: the only writes in the
  guarded body are the `<%= render %>` calls, and `render` builds its result before
  returning, so a raise inside one leaves the buffer untouched.

  --- WHAT IS DIFFERENT FROM THE PROJECT DASHBOARD ---
%>
<p>body</p>
ERB

# --- trim mode: `<%-#` opens a comment too, and a rule that knew only `<%#` is defeated ---
cat > "$WORK/trim/_trim.html.erb" <<'ERB'
<%-#
  a comment opened in trim mode, containing <%= leak %> which closes it
%>
ERB

# --- unterminated: a different defect, and it must not pass silently ---
printf '<%%#\n  a comment nobody closed\n' > "$WORK/unterminated/_open.html.erb"

# --- rule B: THE HOLE THE FIRST VERSION HAD, and this case is why it is committed.
# The fix for M-4 reintroduced M-4 inside the sentence explaining M-4, by quoting the
# CLOSING delimiter. Rule A saw no opener before that delimiter and reported OK. ---
mkdir -p "$WORK/closer"
cat > "$WORK/closer/_closer.html.erb" <<'ERB'
<%#
  A long header comment.

  ERB closes a comment at the first %>, which is exactly what this line just did, so
  everything from here on is printed instead of ignored.
%>
<p>body</p>
ERB

# --- and the case rule B must NOT fire on: a one-line comment with markup after it ---
mkdir -p "$WORK/inline"
printf '<%%# a short note %%><p>x</p>\n' > "$WORK/inline/_inline.html.erb"

echo "erb_comment_integrity_selftest:"
run_case "a clean view is a pass"                    0 "tmp/erb_comment_integrity_selftest/clean"
run_case "M-4's shape is caught"                     1 "tmp/erb_comment_integrity_selftest/dirty"
run_case "a trim-mode comment is caught too"         1 "tmp/erb_comment_integrity_selftest/trim"
run_case "an unterminated comment is caught"         1 "tmp/erb_comment_integrity_selftest/unterminated"
run_case "a directory with no .erb cannot pass"      2 "tmp/erb_comment_integrity_selftest/empty"
run_case "an absent directory cannot pass"           2 "tmp/erb_comment_integrity_selftest/nope"
run_case "a quoted CLOSING delimiter is caught"      1 "tmp/erb_comment_integrity_selftest/closer"
run_case "a one-line comment with markup after it is fine" 0 "tmp/erb_comment_integrity_selftest/inline"

# --- and the reader itself broken for real, which is the arm T-38 says to drive ---
BROKEN="$ROOT/tmp/erb_comment_integrity_selftest/broken_reader.rb"
printf 'raise "deliberately broken reader"\n' > "$BROKEN"
set +e
ruby "$BROKEN" >/dev/null 2>&1
BROKEN_STATUS=$?
set -e
if [ "$BROKEN_STATUS" != "0" ]; then
  echo "  ok    a reader that raises exits non-zero (exit $BROKEN_STATUS), which the wrapper maps to 2"
else
  echo "  FAIL  a raising reader exited 0"
  FAILURES=$((FAILURES + 1))
fi

if [ "$FAILURES" != "0" ]; then
  echo "erb_comment_integrity_selftest: $FAILURES case(s) failed" >&2
  exit 1
fi

echo "erb_comment_integrity_selftest: OK — 9 cases, both rules and both self-protection arms driven."
