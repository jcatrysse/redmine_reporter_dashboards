#!/usr/bin/env bash
set -euo pipefail

# Gate — FR-72's drop reference, in BOTH directions (T-37).
#
# The questions and the reasons are in `drop_reference_parity.rb`, which is Ruby because the
# answer cannot be grepped: "what can a template reach" is `Liquid::Drop.invokable_methods`
# asked of a loaded class, and a regexp over `def` lines would miss inheritance, miss
# `attr_reader`, and count a private method as surface.
#
# `spec/liquid/drop_reference_spec.rb` drives the same module DB-lessly, so the gate and the
# suite can never disagree about what parity means. What the spec cannot reach is this
# wrapper: a reader that fails to LOAD prints nothing and exits non-zero, and a wrapper that
# read that as "no findings" would report OK about a check that did not run. That is T-38's
# own lesson (its new gate reported OK for four arms while its comment-stripper was
# crashing), so the status is read three-valued below and 2 is a hard failure.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
READER="$ROOT/script/gates/drop_reference_parity.rb"

cd "$ROOT"

if ! command -v ruby >/dev/null 2>&1; then
  echo "ERROR: no ruby on PATH; the drop surface is read from loaded classes and this gate" >&2
  echo "       must not report a result it did not compute." >&2
  exit 2
fi

if [ ! -f "$READER" ]; then
  echo "ERROR: $READER is missing — nothing was checked." >&2
  exit 2
fi

# An absent subject is NOT a pass, the rule every gate here follows.
if [ ! -d "$ROOT/lib/redmine_reporter_dashboards/liquid/drops" ]; then
  echo "ERROR: liquid/drops does not exist — nothing was checked." >&2
  exit 2
fi

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

# `bundle exec` when there is a bundle, plain ruby otherwise: the reader needs the Liquid
# gem, and on a developer machine the plugin's own Gemfile is not always the active one. It
# reports exit 2 with a named reason when the gem is unreachable either way, which is why
# this can afford to try the cheaper form.
set +e
if [ -n "${BUNDLE_GEMFILE:-}" ] && command -v bundle >/dev/null 2>&1; then
  bundle exec ruby "$READER" >"$OUT" 2>&1
else
  ruby "$READER" >"$OUT" 2>&1
fi
status=$?
set -e

if [ "$status" -gt 1 ]; then
  echo "ERROR: the drop-reference reader exited $status — it did not run to completion, so no" >&2
  echo "       conclusion about FR-72 is available. Output:" >&2
  sed 's/^/    /' "$OUT" >&2
  exit 2
fi

if [ "$status" -eq 1 ]; then
  echo >&2
  echo "FAIL: the drop reference and the drop layer disagree:" >&2
  sed 's/^/    /' "$OUT" >&2
  echo >&2
  echo "FR-72: every documented accessor must exist at runtime and every runtime accessor" >&2
  echo "must be documented. Add the accessor to DropReference::DECLARED with a type (and" >&2
  echo "\`batch: true\` if reading it in a loop costs no query), then run" >&2
  echo "\`rake reporter_dashboards:drop_reference\` and commit docs/drop-reference.md in the" >&2
  echo "SAME change. A reference that is regenerated later is a reference that was wrong in" >&2
  echo "between." >&2
  exit 1
fi

cat "$OUT"
exit 0
