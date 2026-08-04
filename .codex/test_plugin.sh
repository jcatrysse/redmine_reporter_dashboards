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

# detect_ruby_version and friends. Shared with the other .codex script rather than
# duplicated: the version it derives has to agree with ci.yml, and two copies of
# that reasoning drift.
# shellcheck source=.codex/ruby_version.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ruby_version.sh"

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
  # The full-app tests used to be SKIPPED when redmine_reporter was absent, because
  # the plugin could not boot without it. It can now, and the standalone
  # configuration is the one most worth running: a suite that only ever runs WITH
  # reporter present cannot notice the dependency coming back.
  #
  # So absence no longer skips anything. REQUIRE_REPORTER_PLUGIN now means only
  # "fail if the reporter-present configuration was asked for and is not there",
  # which is what CI uses to tell a missing checkout from a deliberate standalone run.
  if [ ! -d "plugins/$REPORTER_PLUGIN_NAME" ] && reporter_required; then
    echo "ERROR: REQUIRE_REPORTER_PLUGIN asks for the reporter-present configuration, but" >&2
    echo "       plugins/$REPORTER_PLUGIN_NAME is not installed. Provide REPORTER_PLUGIN_PATH" >&2
    echo "       before redmine_clone.sh, or set REQUIRE_REPORTER_PLUGIN=0 to run standalone." >&2
    exit 1
  fi

  if [ -d "plugins/$REPORTER_PLUGIN_NAME" ]; then
    echo "Running the full-app tests WITH $REPORTER_PLUGIN_NAME present." >&2
  else
    echo "Running the full-app tests STANDALONE — no $REPORTER_PLUGIN_NAME, no redmineup gem." >&2
  fi

  run_command bundle exec rake redmine:plugins:test NAME="$PLUGIN_NAME"
  ran_tests=true
fi

if [ "$ran_tests" = false ]; then
  echo "No spec/ or test/ directory found for $PLUGIN_NAME." >&2
  exit 1
fi
