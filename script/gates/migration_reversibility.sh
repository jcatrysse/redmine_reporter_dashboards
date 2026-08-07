#!/usr/bin/env bash
set -euo pipefail

# Gate G11 (static half) — §7's reversibility RULES, checked without a database.
#
# The other half of G11 is `script/migrate_updown.sh`, which runs a real up -> VERSION=0 ->
# up cycle and needs a Redmine checkout and a database engine. This half needs neither, so
# it runs in the `gates` job alongside the other seven and on any developer machine.
#
# The two halves answer different questions and neither replaces the other. This one asks
# "is this migration written in a form whose reverse is DECLARED?"; the other asks "does
# the reverse actually restore the database?" A migration can pass this and fail that (a
# perfectly-formed `change` that Rails inverts into a statement the engine rejects), and it
# can pass that and fail this (001, whose down works by accident of a runtime query — which
# is why it is on the allowlist WITH the measurement, rather than simply passing).
#
# The rules themselves live in `migration_reversibility.rb`, which is Ruby because the
# questions §7 asks need a parser rather than a grep — a regexp cannot tell `def down` from
# the word "down" in a comment explaining why there isn't one, and this repository's
# migrations are full of exactly that sentence. `spec/migrations/reversibility_spec.rb`
# drives the same file, so the gate and the suite can never disagree about what the rules
# are.
#
# Mode:
#   MIGRATION_REVERSIBILITY_MODE=strict  (default) any finding fails
#   MIGRATION_REVERSIBILITY_MODE=warn    findings are reported, exit 0
#
# STRICT BY DEFAULT, unlike every other gate here, and that is deliberate: the others ratchet
# down a pre-existing violation that predates the plan, and this one has no backlog to work
# through. §7's rules are being introduced in the same release as the migrations they govern,
# so there is nothing to be lenient about. `warn` exists only so a bisect can see the
# findings without the script exiting first.

MODE="${MIGRATION_REVERSIBILITY_MODE:-strict}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
READER="$ROOT/script/gates/migration_reversibility.rb"
ALLOWLIST="$ROOT/script/gates/migration_reversibility.allowlist"
MIGRATIONS="$ROOT/db/migrate"

cd "$ROOT"

if ! command -v ruby >/dev/null 2>&1; then
  echo "ERROR: no ruby on PATH; the reversibility rules are parsed rather than grepped and" >&2
  echo "       this gate must not report a result it did not compute." >&2
  exit 2
fi

# An absent subject is reported on its own line and is NOT a pass — the same rule
# layer_purity.sh and vendor_integrity.sh follow. A gate that silently checks nothing is
# indistinguishable from a gate that found nothing.
if [ ! -d "$MIGRATIONS" ]; then
  echo "ERROR: no migration directory at db/migrate — nothing was checked." >&2
  exit 2
fi

migration_count="$(find "$MIGRATIONS" -maxdepth 1 -name '[0-9]*_*.rb' | wc -l | tr -d ' ')"
if [ "$migration_count" -eq 0 ]; then
  echo "ERROR: db/migrate contains no migrations — nothing was checked." >&2
  exit 2
fi

exemption_count=0
if [ -f "$ALLOWLIST" ]; then
  exemption_count="$(sed -E 's/#.*$//' "$ALLOWLIST" | awk 'NF { print }' | wc -l | tr -d ' ')"
fi

FINDINGS="$(mktemp)"
trap 'rm -f "$FINDINGS"' EXIT

# Three-valued, as HANDOVER §1 requires of every search inside a gate: 0 = clean,
# 1 = findings, anything else = the reader itself failed and this gate knows nothing.
set +e
ruby "$READER" "$MIGRATIONS" >"$FINDINGS" 2>&1
reader_status=$?
set -e

if [ "$reader_status" -gt 1 ]; then
  echo "ERROR: the reversibility reader exited $reader_status — it did not run to completion," >&2
  echo "       so no conclusion about db/migrate is available. Output:" >&2
  sed 's/^/    /' "$FINDINGS" >&2
  exit 2
fi

finding_count="$(awk 'NF' "$FINDINGS" | wc -l | tr -d ' ')"

echo "migration_reversibility: mode=$MODE  migrations=$migration_count  findings=$finding_count  exemptions=$exemption_count"

if [ "$finding_count" -gt 0 ]; then
  echo >&2
  echo "FAIL: technical-spec.md §7's reversibility rules are broken by:" >&2
  sed 's/^/    /' "$FINDINGS" >&2
  echo >&2
  echo "Each finding names the rule it breaks. If one of them is genuinely right for a" >&2
  echo "migration, add a line to script/gates/migration_reversibility.allowlist WITH the" >&2
  echo "reason — the loader refuses an exemption that has none — and argue for it in the" >&2
  echo "pull request. That list should shrink; it must never grow silently." >&2

  [ "$MODE" = 'strict' ] && exit 1
  echo "migration_reversibility: WARN mode — reported and not enforced." >&2
  exit 0
fi

echo "migration_reversibility: OK — every migration declares its reverse."
exit 0
