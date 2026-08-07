#!/usr/bin/env bash
set -euo pipefail

# T-36 — the real up -> VERSION=0 -> up cycle. Gate G11.
#
# `technical-spec.md` §7 rule 4: "The down path is tested, not asserted. New CI job
# `migrate-updown`, one per Rails branch: migrate up from empty -> assert the full schema ->
# migrate `VERSION=0` -> assert the schema is byte-comparable to the pre-install dump ->
# migrate up again -> assert idempotent. A plugin that cannot be uninstalled cleanly cannot
# honestly be recommended for a trial install, and a trial install is the whole A/B
# argument."
#
# This script is the implementation. `.github/workflows/ci.yml`'s `migrate-updown` job runs
# exactly this and nothing else, so a developer can reproduce a red cell with one command
# instead of reading YAML.
#
#     cd <plugin>            # a Redmine checkout must already exist at ./redmine
#     ./.codex/redmine_clone.sh 6.1-stable && ./.codex/test_setup.sh
#     ./script/migrate_updown.sh
#
# ===========================================================================
# THE TWO ARMS, AND WHY THERE ARE TWO
# ===========================================================================
#
# FR-69 reads: "Migrating to `VERSION=0` leaves no plugin table, index or
# `plugin_schema_info` row, AND does not drop the pre-existing `reporter_project_tabs`."
#
# Taken literally over ALL of this plugin's tables those clauses cannot both hold, because
# `db/migrate/001` is this plugin's own migration and it is what creates
# `reporter_project_tabs` on a fresh install. The reading this script implements — argued
# in full in the pull request, and the only one under which both clauses are true — is
# that "no plugin table" quantifies over the tables the reporting work ADDS, which is
# exactly the six rows `technical-spec.md` §7 marks **new**; `reporter_project_tabs` is the
# one row it marks **exists**, and rule 2 says the same thing in words: it "**pre-exists
# this work**".
#
# So the requirement is tested as two arms rather than blurred into one:
#
#   preseeded  The literal FR-69 / G11 assertion. The baseline is taken with
#              `reporter_project_tabs` already created BY ITS OWN MIGRATION (plugin at
#              VERSION=1) — which is what "in the state its own migration created" means.
#              After up -> VERSION=0 the schema must be IDENTICAL to that baseline, and no
#              plugin row may remain in `schema_migrations`.
#
#   fresh      What a fresh install actually leaves behind, stated rather than hidden. The
#              baseline is a database with no plugin table at all. After up -> VERSION=0 the
#              ONLY permitted difference is `reporter_project_tabs` and its index — the
#              residue FR-69 clause 2 deliberately protects, because 001's down is a no-op
#              so that a rollback can never destroy somebody's dashboards. Anything else
#              left behind fails the arm.
#
# The second arm is the one that would have caught a naive `drop_table` in 001, and the
# first is the one that catches a new migration forgetting its own down.
#
# ===========================================================================
# `plugin_schema_info` DOES NOT EXIST, AND THAT IS MEASURED
# ===========================================================================
#
# FR-69, `technical-spec.md` §7 rules 2 and 4, `implementation-plan.md` T-36 and CLAUDE.md
# gate G11 all name a table called `plugin_schema_info`. On 5.1-stable and 6.1-stable the
# only occurrence of that name anywhere in Redmine is `lib/tasks/redmine.rake:88`, where it
# appears in a list of table names to EXCLUDE — nothing writes it. The bookkeeping is a
# `schema_migrations` row of the form `<n>-<plugin_id>`
# (`lib/redmine/plugin.rb:553-555`, identical on 5.1, 6.0, 6.1 and 7.0).
#
# A check written literally against FR-69 would therefore assert on a table that never
# exists and pass while checking nothing — this repository's own favourite failure mode. So
# the requirement's INTENT ("no bookkeeping row left behind") is asserted against the
# mechanism that exists, and the documentation defect is reported rather than quietly
# worked around.

MODE_ARMS="${RRD_UPDOWN_ARMS:-preseeded fresh}"
PLUGIN_NAME="${PLUGIN_NAME:-redmine_reporter_dashboards}"
REDMINE_DIR="${REDMINE_DIR:-redmine}"
RAILS_ENV="${RAILS_ENV:-test}"
export RAILS_ENV

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ ! -d "$REDMINE_DIR" ]; then
  echo "ERROR: no Redmine checkout at '$REDMINE_DIR'. Run ./.codex/redmine_clone.sh <branch>" >&2
  echo "       and ./.codex/test_setup.sh first. This gate cannot be evaluated without one," >&2
  echo "       and must not report a result it did not compute." >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SNAPSHOT_SRC="$ROOT/script/schema_snapshot.rb"
SNAPSHOT_DST="$REDMINE_DIR/.rrd_schema_snapshot.rb"
cp "$SNAPSHOT_SRC" "$SNAPSHOT_DST"
trap 'rm -rf "$WORK"; rm -f "$ROOT/$SNAPSHOT_DST"' EXIT

# `rails runner` rather than `rake`: no task to register, and the exit status is the
# script's own.
snapshot() {
  ( cd "$REDMINE_DIR" && bundle exec rails runner .rrd_schema_snapshot.rb "$1" >/dev/null )
}

migrate() {
  local version_arg=()
  [ "$#" -gt 0 ] && version_arg=("VERSION=$1")
  ( cd "$REDMINE_DIR" && bundle exec rake "redmine:plugins:migrate" \
      "NAME=$PLUGIN_NAME" "${version_arg[@]}" >"$WORK/migrate.log" 2>&1 ) || {
    echo "FAIL: rake redmine:plugins:migrate ${version_arg[*]-} exited non-zero. Full output:" >&2
    sed 's/^/    /' "$WORK/migrate.log" >&2
    return 1
  }
}

# Runs Ruby inside the Redmine environment and prints its stdout. Used only for the two
# fixture operations the arms need, so that they go through ActiveRecord and work on
# PostgreSQL, MySQL and MariaDB alike.
in_app() {
  ( cd "$REDMINE_DIR" && bundle exec rails runner "$1" 2>/dev/null )
}

# The `fresh` arm has to reach a genuinely pre-install database, and the only object left
# after VERSION=0 is `reporter_project_tabs`. Dropping it is a FIXTURE operation, and it
# destroys dashboards — so it refuses any database whose name does not say "test", the same
# guard `spec/adapter/adapter_helper.rb:198-207` uses for the same reason.
drop_tabs_table() {
  in_app '
    name = ActiveRecord::Base.connection_db_config.database.to_s
    unless name.include?("test")
      abort("REFUSING to drop reporter_project_tabs in database #{name.inspect}: " \
            "migrate_updown.sh only runs against a database whose name contains \"test\".")
    end
    ActiveRecord::Base.connection.drop_table(:reporter_project_tabs, if_exists: true)
    puts "dropped"
  '
}

# The six tables `technical-spec.md` §7 marks "new", plus the visibility join table 002
# creates alongside them. Listed here rather than derived, so that a migration silently not
# running is a failure rather than a shorter list.
EXPECTED_NEW_TABLES=(
  reporter_dashboards_templates
  reporter_dashboards_templates_roles
  reporter_dashboards_template_versions
  reporter_dashboards_schedules
  reporter_dashboards_schedule_runs
  reporter_dashboards_schedule_recipients
  reporter_dashboards_documents
)

# FR-39's constraint, and the recipient uniqueness that mirrors it. Asserted by NAME and by
# the `unique=true` flag, because an index that exists but is not unique enforces nothing
# and looks identical in a table listing.
EXPECTED_UNIQUE_INDEXES=(
  "INDEX reporter_dashboards_schedule_runs.index_rd_runs_on_schedule_and_occurrence unique=true columns=schedule_id,occurrence_date"
  "INDEX reporter_dashboards_schedule_recipients.index_rd_recipients_ids unique=true columns=schedule_id,user_id"
  "INDEX reporter_dashboards_templates_roles.index_rd_templates_roles_ids unique=true columns=template_id,role_id"
  "INDEX reporter_dashboards_templates.index_rd_templates_on_source_template_id unique=true columns=source_template_id"
)

STATUS=0

report_arm_failure() {
  STATUS=1
  echo >&2
  echo "FAIL: arm '$1' — $2" >&2
}

run_arm() {
  local arm="$1"
  echo
  echo "migrate_updown: --- arm '$arm' ---"

  # ---------------------------------------------------------------- baseline
  migrate 0 || { report_arm_failure "$arm" "could not reach VERSION=0 before the run"; return; }

  case "$arm" in
    preseeded)
      # "in the state ITS OWN MIGRATION created" — so 001 creates it, not a hand-written
      # CREATE TABLE that would drift from it.
      migrate 1 || { report_arm_failure "$arm" "could not migrate to VERSION=1"; return; }
      ;;
    fresh)
      drop_tabs_table >/dev/null || {
        report_arm_failure "$arm" "could not drop reporter_project_tabs to reach a pre-install state"
        return
      }
      ;;
    *)
      report_arm_failure "$arm" "unknown arm (expected 'preseeded' or 'fresh')"
      return
      ;;
  esac

  snapshot "$WORK/a.txt"

  # ---------------------------------------------------------------- up
  migrate || { report_arm_failure "$arm" "migrating up failed"; return; }
  snapshot "$WORK/b.txt"

  local missing=()
  local table
  for table in "${EXPECTED_NEW_TABLES[@]}"; do
    grep -qx "TABLE $table" "$WORK/b.txt" || missing+=("$table")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    report_arm_failure "$arm" "migrating up did not create: ${missing[*]}"
    return
  fi

  local index
  for index in "${EXPECTED_UNIQUE_INDEXES[@]}"; do
    grep -qx "$index" "$WORK/b.txt" || {
      report_arm_failure "$arm" "expected unique index missing or not unique after up:
    $index
  A unique index that is merely present is not a constraint. FR-39 puts the scheduler's
  at-most-once guarantee on the database, so this line failing means the guarantee is gone."
      return
    }
  done

  # -------------------------------------------------- up again is idempotent
  migrate || { report_arm_failure "$arm" "a second 'migrate' (idempotency) failed"; return; }
  snapshot "$WORK/b2.txt"
  if ! diff -u "$WORK/b.txt" "$WORK/b2.txt" >"$WORK/idem.diff"; then
    report_arm_failure "$arm" "migrating up twice changed the schema — it is not idempotent:"
    sed 's/^/    /' "$WORK/idem.diff" >&2
    return
  fi

  # ---------------------------------------------------------------- down
  migrate 0 || { report_arm_failure "$arm" "migrating down to VERSION=0 failed"; return; }
  snapshot "$WORK/c.txt"

  # FR-69's bookkeeping clause, asserted against the mechanism that exists.
  if grep -q '^PLUGINMIGRATION ' "$WORK/c.txt"; then
    report_arm_failure "$arm" "VERSION=0 left plugin rows in schema_migrations:
$(grep '^PLUGINMIGRATION ' "$WORK/c.txt" | sed 's/^/    /')"
    return
  fi

  # ------------------------------------------------- the arm's own assertion
  case "$arm" in
    preseeded)
      # Identical, apart from the bookkeeping row the baseline legitimately carries and
      # the previous check has already proved is gone.
      grep -v '^PLUGINMIGRATION ' "$WORK/a.txt" >"$WORK/a.cmp"
      grep -v '^PLUGINMIGRATION ' "$WORK/c.txt" >"$WORK/c.cmp"
      if ! diff -u "$WORK/a.cmp" "$WORK/c.cmp" >"$WORK/down.diff"; then
        report_arm_failure "$arm" "the post-rollback schema is NOT the pre-install schema:"
        sed 's/^/    /' "$WORK/down.diff" >&2
        return
      fi
      echo "migrate_updown: arm 'preseeded' OK — post-rollback schema identical to pre-install,"
      echo "                and no plugin row left in schema_migrations."
      ;;
    fresh)
      grep -v '^PLUGINMIGRATION ' "$WORK/a.txt" | sort >"$WORK/a.cmp"
      grep -v '^PLUGINMIGRATION ' "$WORK/c.txt" | sort >"$WORK/c.cmp"

      comm -13 "$WORK/a.cmp" "$WORK/c.cmp" >"$WORK/added.txt"
      comm -23 "$WORK/a.cmp" "$WORK/c.cmp" >"$WORK/removed.txt"

      if [ -s "$WORK/removed.txt" ]; then
        report_arm_failure "$arm" "the rollback REMOVED objects that pre-dated the install:
$(sed 's/^/    /' "$WORK/removed.txt")"
        return
      fi

      # Every remaining line must belong to reporter_project_tabs. Anything else is a
      # table, column or index a down-migration forgot.
      if grep -v 'reporter_project_tabs' "$WORK/added.txt" >"$WORK/stray.txt"; then
        if [ -s "$WORK/stray.txt" ]; then
          report_arm_failure "$arm" "VERSION=0 left objects behind that are not reporter_project_tabs:
$(sed 's/^/    /' "$WORK/stray.txt")"
          return
        fi
      fi

      if ! grep -qx 'TABLE reporter_project_tabs' "$WORK/added.txt"; then
        report_arm_failure "$arm" "reporter_project_tabs did NOT survive VERSION=0.
  That is the mirror of the hazard this plan criticises in the base plugin: a rollback that
  destroys the dashboards a user configured. See FR-69 and technical-spec.md §7 rule 2."
        return
      fi

      echo "migrate_updown: arm 'fresh' OK — the only residue of VERSION=0 is"
      echo "                reporter_project_tabs and its index, which FR-69 requires to survive:"
      sed 's/^/                  /' "$WORK/added.txt"
      ;;
  esac
}

echo "migrate_updown: plugin=$PLUGIN_NAME  redmine=$REDMINE_DIR  RAILS_ENV=$RAILS_ENV  arms=$MODE_ARMS"

for arm in $MODE_ARMS; do
  run_arm "$arm"
done

# Leave the database installed. A developer running this by hand almost always wants to
# keep working, and a CI job that ends with the plugin uninstalled would hide an "up" that
# only works from an already-migrated state.
echo
migrate || STATUS=1

if [ "$STATUS" -eq 0 ]; then
  echo "migrate_updown: OK — every arm passed."
else
  echo >&2
  echo "migrate_updown: FAILED. Gate G11 is not satisfied." >&2
fi

exit "$STATUS"
