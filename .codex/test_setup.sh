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

# Which engine to set up. The plugin supports PostgreSQL and MySQL/MariaDB, and the
# aggregator has real per-adapter SQL branches, so both sides are worth having
# locally. RRD_DB=postgresql (default) | mysql | mariadb.
#
# Two databases are created either way: redmine_test for the functional tests, and
# redmine_adapter_test for spec/adapter, which recreates its own tables and must
# therefore never share a database with anything else.
RRD_DB="${RRD_DB:-postgresql}"

# System deps (Ubuntu/Debian)
sudo apt-get update
sudo apt-get install -y build-essential nodejs

setup_postgresql() {
  sudo apt-get install -y libpq-dev postgresql postgresql-contrib
  sudo service postgresql start

  # Create user/db (idempotent-ish)
  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='redmine'" | grep -q 1; then
    sudo -u postgres psql -c "ALTER ROLE redmine WITH LOGIN CREATEDB SUPERUSER PASSWORD 'redmine';"
  else
    sudo -u postgres psql -c "CREATE ROLE redmine WITH LOGIN CREATEDB SUPERUSER PASSWORD 'redmine';"
  fi
  for db in redmine_test redmine_adapter_test; do
    sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1 \
      || sudo -u postgres createdb -O redmine "$db"
  done

  cat > "$REDMINE_DIR/config/database.yml" <<'EOF'
test:
  adapter: postgresql
  database: redmine_test
  host: localhost
  username: redmine
  password: redmine
  encoding: unicode
EOF

  echo 'RRD_ADAPTER_URL=postgres://redmine:redmine@localhost/redmine_adapter_test' \
    > "$REDMINE_DIR/.rrd_adapter_url"
}

# MySQL and MariaDB share everything but the package and service name; the Debian
# packages conflict, so only one of the two can be installed at a time.
setup_mysql_family() {
  local flavour="$1" service

  sudo apt-get install -y default-libmysqlclient-dev
  if [ "$flavour" = 'mariadb' ]; then
    sudo apt-get install -y mariadb-server mariadb-client
    service=mariadb
  else
    sudo apt-get install -y mysql-server mysql-client
    service=mysql
  fi
  sudo service "$service" start

  # The root socket login is passwordless on a fresh Debian install of both.
  sudo mysql <<'SQL'
CREATE DATABASE IF NOT EXISTS redmine_test CHARACTER SET utf8mb4;
CREATE DATABASE IF NOT EXISTS redmine_adapter_test CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS 'redmine'@'localhost' IDENTIFIED BY 'redmine';
CREATE USER IF NOT EXISTS 'redmine'@'127.0.0.1' IDENTIFIED BY 'redmine';
GRANT ALL ON redmine_test.* TO 'redmine'@'localhost';
GRANT ALL ON redmine_test.* TO 'redmine'@'127.0.0.1';
GRANT ALL ON redmine_adapter_test.* TO 'redmine'@'localhost';
GRANT ALL ON redmine_adapter_test.* TO 'redmine'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

  cat > "$REDMINE_DIR/config/database.yml" <<'EOF'
test:
  adapter: mysql2
  database: redmine_test
  host: 127.0.0.1
  username: redmine
  password: redmine
  encoding: utf8mb4
EOF

  echo 'RRD_ADAPTER_URL=mysql2://redmine:redmine@127.0.0.1/redmine_adapter_test' \
    > "$REDMINE_DIR/.rrd_adapter_url"
}

case "$RRD_DB" in
  postgresql|postgres|pg) setup_postgresql ;;
  mysql)                  setup_mysql_family mysql ;;
  mariadb)                setup_mysql_family mariadb ;;
  *)
    echo "ERROR: unknown RRD_DB=$RRD_DB — expected postgresql, mysql or mariadb." >&2
    exit 1
    ;;
esac

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
