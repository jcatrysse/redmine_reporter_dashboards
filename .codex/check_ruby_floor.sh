#!/usr/bin/env bash
#
# The plugin declares `requires_redmine version_or_higher: '5.1'`, and Redmine 5.1
# runs on Ruby 2.7 (its Gemfile says `ruby '>= 2.7.0', '< 3.3.0'`). So the plugin's
# own code has to parse and run under 2.7 — including the specs, which are what a
# packager runs first.
#
# `ruby -c` under 2.7 would be the honest check, but the GitHub-hosted images no
# longer carry a 2.7 build, and installing one just for a syntax pass costs more than
# it is worth. This greps for the constructs that actually bit during development
# instead. Every pattern below is here because it was written by accident at least
# once. Full-line comments are excluded, so prose about a construct is not a finding.
#
# Run it from the plugin root:  ./.codex/check_ruby_floor.sh

set -uo pipefail

DIRS=(lib app spec test config db)
status=0

ruby_files() {
  local existing=()
  for dir in "${DIRS[@]}"; do
    [ -d "$dir" ] && existing+=("$dir")
  done
  [ ${#existing[@]} -eq 0 ] && return 0
  find "${existing[@]}" -name '*.rb' -type f -print0
}

# Drops grep hits whose matched line is a full-line comment. The hit format is
# file:line:content, so the first two fields are removed before testing.
strip_comment_lines() {
  awk '{ rest = $0; sub(/^[^:]*:[0-9]+:/, "", rest); if (rest !~ /^[[:space:]]*#/) print }'
}

check() {
  local label="$1" pattern="$2" hits
  hits="$(ruby_files | xargs -0 grep -nP -- "$pattern" 2>/dev/null | strip_comment_lines || true)"
  if [ -n "$hits" ]; then
    echo "ERROR: $label" >&2
    echo "$hits" | sed 's/^/  /' >&2
    status=1
  fi
}

# Endless method definitions (Ruby 3.0+): `def foo = expr`, `def self.foo(x) = expr`.
# The `=` has to terminate the argument list, so a default argument value
# (`def foo(a = 1)`) must not match — hence the optional parenthesised group.
check 'endless method definition — needs Ruby 3.0, the floor is 2.7' \
      '^\s*def\s+[A-Za-z_][\w.]*[!?]?(\([^)]*\))?\s*=(?!=|~)'

# Hash#except is Ruby 3.0 core. ActiveSupport backports it, so this only bites where
# ActiveSupport is absent — which is exactly how the pure-unit specs run.
check 'Hash#except — Ruby 3.0 core, and ActiveSupport is not loaded in the unit specs' \
      '\.except\('

# Hash literal value omission `{x:, y:}` — Ruby 3.1.
check 'hash literal value omission — needs Ruby 3.1, the floor is 2.7' \
      '\{\s*[a-z_]\w*:\s*(,|\})'

# Core APIs with no 2.7 equivalent.
check 'API newer than Ruby 2.7' \
      '\b(Data\.define)\b|\.intersect\?\('

if [ "$status" -eq 0 ]; then
  echo 'Ruby 2.7 syntax floor: OK'
fi

exit "$status"
