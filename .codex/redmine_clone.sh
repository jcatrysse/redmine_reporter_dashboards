#!/usr/bin/env bash
set -euo pipefail

REDMINE_VERSION="${1:-5.1-stable}"   # 5.1-stable, 6.0-stable, 6.1-stable
REDMINE_DIR="${REDMINE_DIR:-redmine}"
REDMINE_REPO_URL="https://github.com/redmine/redmine.git"

if ! git ls-remote --heads "$REDMINE_REPO_URL" "$REDMINE_VERSION" | grep -q "$REDMINE_VERSION"; then
  echo "ERROR: Redmine branch '$REDMINE_VERSION' not found on $REDMINE_REPO_URL" >&2
  exit 1
fi

if [ ! -d "$REDMINE_DIR/.git" ]; then
  git clone --depth 1 --branch "$REDMINE_VERSION" "$REDMINE_REPO_URL" "$REDMINE_DIR"
else
  (
    cd "$REDMINE_DIR"
    git fetch --depth 1 origin "$REDMINE_VERSION:refs/remotes/origin/$REDMINE_VERSION"

    # test_setup.sh appends a test-only gem to Redmine's OWN Gemfile, so after one
    # setup run this checkout is dirty and a plain `git checkout -B` refuses to switch
    # branches. That failure is quiet in the worst way: the tree stays on the previous
    # Redmine version while every step afterwards reports its results as though it had
    # moved — a suite that says "Redmine 7.0" while running 6.1.
    #
    # The modification is this tooling's own and test_setup.sh re-applies it, so it is
    # discarded deliberately, and said out loud rather than forced silently.
    if ! git diff --quiet; then
      echo "NOTE: discarding local modifications in $REDMINE_DIR before switching to $REDMINE_VERSION:" >&2
      git diff --name-only | sed 's/^/        /' >&2
    fi

    git checkout -f -B "$REDMINE_VERSION" "origin/$REDMINE_VERSION"

    actual="$(git rev-parse --abbrev-ref HEAD)"
    if [ "$actual" != "$REDMINE_VERSION" ]; then
      echo "ERROR: expected to be on $REDMINE_VERSION but HEAD is $actual." >&2
      exit 1
    fi
  )
fi

PLUGIN_NAME="$(basename "$(pwd)")"
mkdir -p "$REDMINE_DIR/plugins/$PLUGIN_NAME"
rsync -a --delete --exclude "$REDMINE_DIR/" --exclude .git/ ./ "$REDMINE_DIR/plugins/$PLUGIN_NAME/"

# redmine_reporter_dashboards depends on the redmine_reporter plugin: its init.rb
# raises if reporter is absent and the functional tests boot the full app. When a
# sibling redmine_reporter checkout is available (the local / codex layout), copy
# it in so the dependency is satisfied. In CI provide it via REPORTER_PLUGIN_PATH.
REPORTER_PLUGIN_PATH="${REPORTER_PLUGIN_PATH:-../redmine_reporter}"
if [ -d "$REPORTER_PLUGIN_PATH" ]; then
  mkdir -p "$REDMINE_DIR/plugins/redmine_reporter"
  rsync -a --delete --exclude "$REDMINE_DIR/" --exclude .git/ "$REPORTER_PLUGIN_PATH/" "$REDMINE_DIR/plugins/redmine_reporter/"
else
  echo "WARNING: redmine_reporter dependency not found at '$REPORTER_PLUGIN_PATH'." >&2
  echo "         The geo rspec specs will still run, but the minitest functional tests" >&2
  echo "         will fail to boot. Set REPORTER_PLUGIN_PATH to a redmine_reporter checkout." >&2
fi
