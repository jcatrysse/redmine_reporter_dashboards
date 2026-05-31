#!/usr/bin/env bash
set -euo pipefail

REDMINE_DIR="${REDMINE_DIR:-redmine}"
RAILS_ENV=test
MISE_BIN="${MISE_BIN:-mise}"
REPORTER_PLUGIN_NAME="${REPORTER_PLUGIN_NAME:-redmine_reporter}"

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

# System deps (Ubuntu/Debian)
sudo apt-get update
sudo apt-get install -y build-essential libpq-dev nodejs postgresql postgresql-contrib

# Start postgres
sudo service postgresql start

# Create user/db (idempotent-ish)
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='redmine'" | grep -q 1; then
  sudo -u postgres psql -c "ALTER ROLE redmine WITH LOGIN CREATEDB SUPERUSER PASSWORD 'redmine';"
else
  sudo -u postgres psql -c "CREATE ROLE redmine WITH LOGIN CREATEDB SUPERUSER PASSWORD 'redmine';"
fi
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='redmine_test'" | grep -q 1 || sudo -u postgres createdb -O redmine redmine_test

cat > "$REDMINE_DIR/config/database.yml" <<'EOF'
test:
  adapter: postgresql
  database: redmine_test
  host: localhost
  username: redmine
  password: redmine
  encoding: unicode
EOF

cd "$REDMINE_DIR"

RUBY_VERSION="$(detect_ruby_version)"
if [ -n "$RUBY_VERSION" ]; then
  if command -v "$MISE_BIN" >/dev/null 2>&1; then
    "$MISE_BIN" install "ruby@$RUBY_VERSION"
    "$MISE_BIN" use -g "ruby@$RUBY_VERSION"
  else
    echo "mise is required to install Ruby $RUBY_VERSION. Please install mise or set PATH to a compatible ruby." >&2
    exit 1
  fi
fi

if ! grep -q "rails-controller-testing" Gemfile; then
  cat <<'EOF' >> Gemfile

group :test do
  gem 'rails-controller-testing'
end
EOF
fi

bundle config set without 'development'
bundle config set path 'vendor/bundle'

run_command() {
  if command -v "$MISE_BIN" >/dev/null 2>&1 && [ -n "${RUBY_VERSION:-}" ]; then
    "$MISE_BIN" exec "ruby@$RUBY_VERSION" -- "$@"
  else
    "$@"
  fi
}

run_command bundle install

if [ ! -d "plugins/$REPORTER_PLUGIN_NAME" ]; then
  echo "WARNING: $REPORTER_PLUGIN_NAME dependency not found at 'plugins/$REPORTER_PLUGIN_NAME'." >&2
  if reporter_required; then
    echo "ERROR: full Redmine setup requires $REPORTER_PLUGIN_NAME. Provide REPORTER_PLUGIN_PATH before redmine_clone.sh or set REQUIRE_REPORTER_PLUGIN=0 to run standalone specs only." >&2
    exit 1
  fi
  echo "Skipping Redmine database setup because $REPORTER_PLUGIN_NAME is missing." >&2
  echo "Standalone specs can still run with ./.codex/test_plugin.sh; minitest will be skipped." >&2
  exit 0
fi

run_command bundle exec rake db:drop db:create db:migrate RAILS_ENV=test
run_command bundle exec rake redmine:plugins:migrate RAILS_ENV=test
