#!/usr/bin/env bash
set -euo pipefail

REDMINE_DIR="${REDMINE_DIR:-redmine}"
PLUGIN_NAME="$(basename "$(pwd)")"
MISE_BIN="${MISE_BIN:-mise}"
REPORTER_PLUGIN_NAME="${REPORTER_PLUGIN_NAME:-redmine_reporter}"
# redmine:plugins:test boots Rails through db:test:prepare, which loads the
# default (development) environment unless told otherwise -- and test_setup.sh
# installs gems `without development`, so that environment cannot even load.
export RAILS_ENV="${RAILS_ENV:-test}"

reporter_required() {
  case "${REQUIRE_REPORTER_PLUGIN:-}" in
    1|true|TRUE|yes|YES) return 0 ;;
    0|false|FALSE|no|NO) return 1 ;;
  esac

  [ "${CI:-}" = "true" ]
}

detect_ruby_version() {
  local version=""

  if [ -f ".ruby-version" ]; then
    version="$(tr -d '\n' < .ruby-version)"
  elif [ -f "Gemfile" ]; then
    local ruby_line=""
    ruby_line="$(grep -E "^[[:space:]]*ruby " Gemfile | head -n 1 || true)"

    version="$(echo "$ruby_line" | sed -E -n "s/.*ruby[[:space:]]*['\\\"]([0-9]+\\.[0-9]+(\\.[0-9]+)?)[\"'].*$/\\1/p")"
    if [ -z "$version" ]; then
      version="$(echo "$ruby_line" | sed -E -n "s/.*~>[[:space:]]*([0-9]+\\.[0-9]+(\\.[0-9]+)?).*/\\1/p")"
    fi
    if [ -z "$version" ]; then
      local upper=""
      upper="$(echo "$ruby_line" | sed -E -n "s/.*<[[:space:]]*([0-9]+\\.[0-9]+(\\.[0-9]+)?).*/\\1/p")"
      if [ -n "$upper" ]; then
        local major="${upper%%.*}"
        local minor="${upper#*.}"
        minor="${minor%%.*}"
        if [ "$minor" -gt 0 ]; then
          minor=$((minor - 1))
        fi
        version="${major}.${minor}"
      fi
    fi
  fi

  echo "$version"
}

cd "$REDMINE_DIR"
mkdir -p tmp/test-results

RUBY_VERSION="$(detect_ruby_version)"
PLUGIN_DIR="plugins/$PLUGIN_NAME"
SPEC_DIR="$PLUGIN_DIR/spec"
TEST_DIR="$PLUGIN_DIR/test"

run_command() {
  if [ -n "$RUBY_VERSION" ]; then
    if command -v "$MISE_BIN" >/dev/null 2>&1; then
      "$MISE_BIN" exec "ruby@$RUBY_VERSION" -- "$@"
    else
      echo "mise is required to run tests with Ruby $RUBY_VERSION. Please run ./.codex/test_setup.sh first." >&2
      exit 1
    fi
  else
    if ! command -v bundle >/dev/null 2>&1; then
      echo "Bundler is not available. Please run ./.codex/test_setup.sh first." >&2
      exit 1
    fi
    "$@"
  fi
}

ran_tests=false

# spec/adapter runs the aggregator's SQL against a real PostgreSQL or MySQL/MariaDB
# server. It loads the REAL ActiveRecord, while spec/sql_aggregation defines a stub
# ActiveRecord::Base when none exists, so the two get their own processes: excluded
# from the run below, then run on their own when a database URL is available.
# test_setup.sh writes one to redmine/.rrd_adapter_url; RRD_ADAPTER_URL wins.
if [ -z "${RRD_ADAPTER_URL:-}" ] && [ -f .rrd_adapter_url ]; then
  RRD_ADAPTER_URL="$(sed -n 's/^RRD_ADAPTER_URL=//p' .rrd_adapter_url)"
fi

if [ -d "$SPEC_DIR" ]; then
  # The specs `require 'spec_helper'`, which resolves against the load path. rspec
  # runs from the Redmine root, so the plugin's spec/ must be put on it explicitly.
  run_command bundle exec rspec -I "$SPEC_DIR" "$SPEC_DIR" --format progress \
    --exclude-pattern 'adapter/**/*_spec.rb'
  ran_tests=true

  if [ -d "$SPEC_DIR/adapter" ]; then
    if [ -n "${RRD_ADAPTER_URL:-}" ]; then
      echo "Running the adapter execution specs against $RRD_ADAPTER_URL" >&2
      RRD_ADAPTER_URL="$RRD_ADAPTER_URL" \
        run_command bundle exec rspec -I "$SPEC_DIR" "$SPEC_DIR/adapter" --format progress
    else
      echo "WARNING: skipping the adapter execution specs — no RRD_ADAPTER_URL." >&2
      echo "         Run ./.codex/test_setup.sh (optionally with RRD_DB=mysql or mariadb)," >&2
      echo "         or set RRD_ADAPTER_URL to a database whose name contains 'test'." >&2
    fi
  fi
fi

if [ -d "$TEST_DIR" ]; then
  if [ -d "plugins/$REPORTER_PLUGIN_NAME" ]; then
    run_command bundle exec rake redmine:plugins:test NAME="$PLUGIN_NAME"
    ran_tests=true
  elif reporter_required; then
    echo "ERROR: $REPORTER_PLUGIN_NAME dependency not found; full plugin tests cannot boot Redmine." >&2
    echo "       Provide REPORTER_PLUGIN_PATH before redmine_clone.sh, or set REQUIRE_REPORTER_PLUGIN=0 to run standalone specs only." >&2
    exit 1
  else
    echo "WARNING: skipping minitest plugin tests because $REPORTER_PLUGIN_NAME is not installed." >&2
    echo "         Standalone RSpec specs were run; set REQUIRE_REPORTER_PLUGIN=1 to enforce full tests." >&2
  fi
fi

if [ "$ran_tests" = false ]; then
  echo "No spec/ or test/ directory found for $PLUGIN_NAME." >&2
  exit 1
fi
