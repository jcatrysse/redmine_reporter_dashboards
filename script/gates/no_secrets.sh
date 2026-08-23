#!/usr/bin/env bash
set -euo pipefail

# Gate G1 — the fork-PR promise, kept mechanically.
#
# The workflow used to check out a PRIVATE plugin with secrets.REPORTER_REPO_TOKEN
# before running the functional tests. A secret is not readable from a fork pull
# request, so the full suite could never run on an outside contribution: it was
# skipped, and a skipped suite looks like a passing one.
#
# The dependency is gone and the secret with it. This gate is what stops it coming
# back, because the way it comes back is not malice — it is one convenient step added
# during an unrelated change, six months from now, by someone who never read this
# file. GITHUB_TOKEN is the single exception: GitHub provides it to every run,
# including a fork's, so it costs nothing.
#
# Not a test. A green suite says nothing about this.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOWS="$ROOT/.github/workflows"

cd "$ROOT"

if [ ! -d "$WORKFLOWS" ]; then
  echo "no_secrets: no .github/workflows directory — nothing to check."
  exit 0
fi

# A secret is only READ through a `${{ … }}` expression, so that is what is matched —
# not the bare text "secrets.". Two false positives taught this: the header comment in
# ci.yml that records which secret was removed, and this script's own filename, which
# contains the literal "secrets.sh". A gate that cries wolf gets switched off, so the
# match is the actual usage and comment lines are skipped.
findings="$(
  ruby -e '
    require "find"
    root = ARGV[0]
    out = []
    Find.find(root) do |path|
      next unless File.file?(path) && path =~ /\.ya?ml\z/

      File.readlines(path, encoding: "UTF-8").each_with_index do |line, i|
        next if line.lstrip.start_with?("#")

        line.scan(/\$\{\{[^}]*\}\}/) do |expr|
          expr.scan(/secrets\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)|secrets\s*\[\s*.([A-Za-z_][A-Za-z0-9_]*).\s*\]/) do |dot, brack|
            out << "#{path}:#{i + 1}:secrets.#{dot || brack}"
          end
        end
      end
    end
    puts out
  ' "$WORKFLOWS" 2>/dev/null || true
)"

offending="$(echo "$findings" | grep -v 'secrets\.GITHUB_TOKEN$' | sed '/^$/d' || true)"

total="$(echo "$findings" | sed '/^$/d' | wc -l | tr -d ' ')"
echo "no_secrets: $total secret reference(s) in $WORKFLOWS"

if [ -n "$offending" ]; then
  echo >&2
  echo "FAIL: a workflow references a secret other than GITHUB_TOKEN:" >&2
  echo "$offending" | sed 's/^/    /' >&2
  echo >&2
  echo "A secret is unreadable from a fork pull request, so any job that needs one" >&2
  echo "cannot run on an outside contribution — it is skipped, and a skipped job reads" >&2
  echo "exactly like a passing one. That is the failure this gate exists to prevent." >&2
  echo >&2
  echo "If a private dependency really is needed again, that is a decision to take" >&2
  echo "deliberately: it costs the project the ability to accept tested contributions." >&2
  exit 1
fi

echo "no_secrets: OK — nothing but GITHUB_TOKEN, so every job can run on a fork pull request."
