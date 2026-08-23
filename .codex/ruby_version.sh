# shellcheck shell=bash
#
# Which Ruby the tests should run on, for the Redmine checkout in $PWD.
#
# detect_ruby_version echoes either a version for `mise install` / `mise exec`, or
# NOTHING — which means "the ruby already on PATH satisfies Redmine's own Gemfile,
# so install nothing and use it".
#
# --- Why this is not three sed expressions any more ---
#
# Redmine states its Ruby requirement in its own Gemfile, and the four supported
# branches state it four different ways:
#
#   5.1-stable   ruby '>= 2.7.0', '< 3.3.0'
#   6.0-stable   ruby '>= 3.0.0', '< 3.4.0'
#   6.1-stable   ruby '>= 3.1.0', '< 3.5.0'
#   7.0-stable   ruby '>= 3.2.0', '< 4.1.0'
#
# The previous implementation derived a version by decrementing the upper bound's
# MINOR — which is only meaningful while both bounds share a major. On 7.0 it
# therefore produced "4.0", a Ruby that does not exist, and setup died with
# "mise is required to install Ruby 4.0". A branch the CI matrix has covered since
# it was added could not be set up locally at all.
#
# So instead of guessing, ask the two authorities:
#
#   1. the ruby on PATH — if it satisfies the Gemfile, there is nothing to install
#   2. mise's own list of real Ruby versions — take the NEWEST that satisfies
#
# which yields 3.2 / 3.3 / 3.4 / 3.4 for the four branches above, matching the
# ruby-version column of .github/workflows/ci.yml rather than diverging from it.

# The quoted constraints on Redmine's `ruby` line, one per line. Non-zero when the
# Gemfile has no such line, which is a legitimate answer, not an error.
gemfile_ruby_requirements() {
  [ -f Gemfile ] || return 1

  local ruby_line
  ruby_line="$(grep -E "^[[:space:]]*ruby[[:space:]]" Gemfile | head -n 1 || true)"
  [ -n "$ruby_line" ] || return 1

  printf '%s\n' "$ruby_line" | grep -oE "['\"][^'\"]+['\"]" | tr -d "\"'"
}

# Gem::Requirement does the comparing, not a shell version sort: it is the same
# resolver bundler will use one step later, so agreeing with it is the point.
path_ruby_satisfies_gemfile() {
  command -v ruby >/dev/null 2>&1 || return 1

  local reqs
  reqs="$(gemfile_ruby_requirements)" || return 1
  [ -n "$reqs" ] || return 1

  printf '%s' "$reqs" | ruby -rrubygems -e '
    reqs = $stdin.read.split("\n").map(&:strip).reject(&:empty?)
    exit 1 if reqs.empty?
    exit Gem::Requirement.new(reqs).satisfied_by?(Gem::Version.new(RUBY_VERSION)) ? 0 : 1
  ' >/dev/null 2>&1
}

newest_mise_ruby_satisfying_gemfile() {
  command -v "${MISE_BIN:-mise}" >/dev/null 2>&1 || return 1

  local reqs candidates
  reqs="$(gemfile_ruby_requirements)" || return 1
  [ -n "$reqs" ] || return 1

  # Plain X.Y.Z only: mise also lists jruby, truffleruby and previews, none of which
  # this suite is claiming to support.
  candidates="$("${MISE_BIN:-mise}" ls-remote ruby 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$')"
  [ -n "$candidates" ] || return 1

  printf '%s\n---\n%s' "$reqs" "$candidates" | ruby -rrubygems -e '
    reqs, versions = $stdin.read.split("\n---\n", 2)
    req = Gem::Requirement.new(reqs.to_s.split("\n").map(&:strip).reject(&:empty?))
    best = versions.to_s.split("\n").map(&:strip).reject(&:empty?).filter_map { |v|
      begin
        Gem::Version.new(v)
      rescue ArgumentError
        nil
      end
    }.select { |v| req.satisfied_by?(v) }.max
    exit 1 unless best
    puts best.segments.first(2).join(".")
  ' 2>/dev/null
}

# X.Y from the `>=` constraint. Used only to make the caller's "mise is required to
# install Ruby X" message name a version that actually exists.
gemfile_ruby_lower_bound() {
  local reqs
  reqs="$(gemfile_ruby_requirements)" || return 1

  printf '%s' "$reqs" | ruby -e '
    lower = $stdin.read.split("\n").map(&:strip).find { |r| r.start_with?(">=") }
    exit 1 unless lower
    m = lower.match(/(\d+)\.(\d+)/)
    exit 1 unless m
    puts "#{m[1]}.#{m[2]}"
  ' 2>/dev/null
}

detect_ruby_version() {
  # An explicit pin outranks everything: it is somebody's stated decision.
  if [ -f ".ruby-version" ]; then
    tr -d '\n' < .ruby-version
    return 0
  fi

  # Empty answer: use the ruby on PATH.
  if path_ruby_satisfies_gemfile; then
    return 0
  fi

  newest_mise_ruby_satisfying_gemfile && return 0

  # No mise to ask and an unsuitable PATH ruby. Emitting nothing here would silently
  # run the suite on a Ruby Redmine does not support, so name the floor Redmine
  # itself states and let the caller refuse.
  gemfile_ruby_lower_bound || true
}
