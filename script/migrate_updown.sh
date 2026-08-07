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

# NOTHING IS COPIED INTO THE REDMINE CHECKOUT, and the first version did.
#
# It wrote `redmine/.rrd_schema_snapshot.rb` and removed it in an EXIT trap. `rails runner`
# takes an absolute path, so the copy bought nothing — and it cost a real failure: two runs
# sharing one Redmine checkout share that one filename, so whichever finishes first deletes
# the file the other is still using, and the second reports "the file could not be found".
# Reproduced by two concurrent runs during review. A developer running this twice, or a CI
# matrix with two cells against one checkout, hits the same thing.
SNAPSHOT_SCRIPT="$ROOT/script/schema_snapshot.rb"

# ===========================================================================
# EXIT CODES ARE THREE-VALUED, and the third one is the point
#
#   0  every arm passed
#   1  a REVERSIBILITY FAILURE — the schema did not come back
#   2  the script could not run: no checkout, no database, a rake that would not start,
#      a snapshot that came back empty. NOTHING was verified.
#
# Collapsing 2 into 1 is the failure this repository keeps naming: a gate that reports a
# verdict it did not compute. HANDOVER §1 puts it as "treat a search's exit status as
# three-valued", and this is the same rule one layer up.
# ===========================================================================
INFRASTRUCTURE_FAILURE=0

infrastructure() {
  INFRASTRUCTURE_FAILURE=1
  echo >&2
  echo "ERROR: $1" >&2
  echo "       Nothing was verified. Gate G11 is UNKNOWN, not failed." >&2
}

# `rails runner` rather than `rake`: no task to register, and the exit status is the
# script's own. An EMPTY snapshot is treated as a failure rather than as a schema with no
# tables — a Redmine that booted far enough to run the script but not far enough to see a
# database would otherwise produce two identical empty snapshots and a green run.
snapshot() {
  ( cd "$REDMINE_DIR" && bundle exec rails runner "$SNAPSHOT_SCRIPT" "$1" \
      >"$WORK/snapshot.log" 2>&1 ) || {
    infrastructure "rails runner could not take a schema snapshot. Output:
$(sed 's/^/    /' "$WORK/snapshot.log")"
    return 1
  }

  if [ ! -s "$1" ]; then
    infrastructure "the schema snapshot came back EMPTY. A snapshot with no tables in it
       compares equal to any other empty snapshot, so this must never be treated as data."
    return 1
  fi
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

# Runs Ruby inside the Redmine environment and prints its stdout. stderr is NOT discarded:
# the safety refusal below is written to stderr by `abort`, and an earlier version swallowed
# it — so a refusal looked exactly like a silent success.
in_app() {
  ( cd "$REDMINE_DIR" && bundle exec rails runner "$1" )
}

# THE SAFETY CHECK RUNS ONCE, FOR THE WHOLE SCRIPT, not beside the one destructive call.
#
# Every arm here migrates a database up and down repeatedly, and the `fresh` arm drops
# `reporter_project_tabs` outright. Guarding only the drop protected the least of it: an
# operator who pointed this at production would still have had their reporting schema
# migrated to VERSION=0 before the guard was ever reached. Same rule as
# `spec/adapter/adapter_helper.rb:198-207`, applied to the whole run.
assert_test_database() {
  local answer
  answer="$(in_app '
    name = ActiveRecord::Base.connection_db_config.database.to_s
    puts(name.include?("test") ? "ok #{name}" : "refuse #{name}")
  ' 2>"$WORK/dbcheck.log")" || {
    infrastructure "could not ask Redmine which database it is connected to. Output:
$(sed 's/^/    /' "$WORK/dbcheck.log")"
    return 1
  }

  case "$answer" in
    ok\ *) echo "migrate_updown: database=${answer#ok }" ;;
    *)
      infrastructure "REFUSING to run against database '${answer#refuse }'.
       This script migrates a database to VERSION=0 and drops reporter_project_tabs.
       It only runs where the database name contains \"test\"."
      return 1
      ;;
  esac
}

drop_tabs_table() {
  in_app 'ActiveRecord::Base.connection.drop_table(:reporter_project_tabs, if_exists: true)' \
    >"$WORK/drop.log" 2>&1 || {
    infrastructure "could not drop reporter_project_tabs to reach a pre-install state. Output:
$(sed 's/^/    /' "$WORK/drop.log")"
    return 1
  }
}

# ===========================================================================
# THE BASELINE HAS TO BE PROVEN CLEAN, OR THE WHOLE TEST IS A TAUTOLOGY
#
# This is the sharpest thing the review of T-36 found, and it made the gate worthless on
# every run after the first. The arms take their baseline AFTER `migrate VERSION=0` — so a
# migration whose `down` leaves its table behind leaves it behind in the BASELINE too, and
# the final comparison then finds the two snapshots identical and reports success. On a
# fresh database the defect is caught; on a re-run of the same database it is not, and CI
# re-uses databases.
#
# So the state after `VERSION=0` is asserted rather than assumed: no table this plugin's
# reporting schema adds may exist. A leftover is reported as what it is — a previous run's
# down-migration that did not complete — rather than being quietly adopted as the baseline.
# ===========================================================================
assert_no_plugin_tables() {
  local snapshot_file="$1" context="$2" leftovers
  leftovers="$(awk '$1 == "TABLE" && $2 ~ /^reporter_dashboards_/ { print $2 }' "$snapshot_file")"

  [ -z "$leftovers" ] && return 0

  echo >&2
  echo "FAIL: after VERSION=0 ($context) these tables still exist:" >&2
  echo "$leftovers" | sed 's/^/    /' >&2
  echo >&2
  echo "A down-migration did not remove its own table. If this is left over from an earlier" >&2
  echo "failed run rather than from the migrations as they stand, drop them by hand and run" >&2
  echo "again — but do not skip this: adopting them as the baseline is what would make every" >&2
  echo "later comparison pass by comparing the damage with itself." >&2
  return 1
}

# The table a snapshot line is about. `TABLE x`, `COLUMN x.col …` and `INDEX x.name …` all
# name it in field 2, so one rule reads all three.
#
# An earlier version filtered the residue with `grep -v reporter_project_tabs`, a SUBSTRING
# match over the whole line — so a future table called `reporter_project_tabs_archive`, or
# any column or index whose NAME merely contained that string, would have been accepted as
# permitted residue. Compare the table name exactly.
snapshot_line_table() {
  awk '{ split($2, parts, "."); print parts[1] }'
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

  # The baseline is PROVEN clean rather than assumed. See the long note on
  # assert_no_plugin_tables: without this, a broken down-migration poisons the baseline on
  # every run after the first and the final comparison passes by comparing the damage with
  # itself.
  snapshot "$WORK/zero.txt" || return
  assert_no_plugin_tables "$WORK/zero.txt" "before arm '$arm'" || { STATUS=1; return; }

  case "$arm" in
    preseeded)
      # "in the state ITS OWN MIGRATION created" — so 001 creates it, not a hand-written
      # CREATE TABLE that would drift from it.
      migrate 1 || { report_arm_failure "$arm" "could not migrate to VERSION=1"; return; }
      ;;
    fresh)
      drop_tabs_table || return
      ;;
    *)
      report_arm_failure "$arm" "unknown arm (expected 'preseeded' or 'fresh')"
      return
      ;;
  esac

  snapshot "$WORK/a.txt" || return

  # ---------------------------------------------------------------- up
  migrate || { report_arm_failure "$arm" "migrating up failed"; return; }
  snapshot "$WORK/b.txt" || return

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

  # ---------------------------------------------------------------- down
  migrate 0 || { report_arm_failure "$arm" "migrating down to VERSION=0 failed"; return; }
  snapshot "$WORK/c.txt" || return

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
      echo "migrate_updown: arm 'preseeded' — post-rollback schema identical to pre-install,"
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

      # Every remaining line must be ABOUT reporter_project_tabs — matched on the table
      # name in field 2, never as a substring of the whole line. Anything else is a table,
      # column or index a down-migration forgot.
      local stray
      stray="$(paste -d' ' <(snapshot_line_table <"$WORK/added.txt") "$WORK/added.txt" \
                 | awk '$1 != "reporter_project_tabs" { $1 = ""; sub(/^ /, ""); print }')"
      if [ -n "$stray" ]; then
        report_arm_failure "$arm" "VERSION=0 left objects behind that are not reporter_project_tabs:
$(echo "$stray" | sed 's/^/    /')"
        return
      fi

      if ! grep -qx 'TABLE reporter_project_tabs' "$WORK/added.txt"; then
        report_arm_failure "$arm" "reporter_project_tabs did NOT survive VERSION=0.
  That is the mirror of the hazard this plan criticises in the base plugin: a rollback that
  destroys the dashboards a user configured. See FR-69 and technical-spec.md §7 rule 2."
        return
      fi

      echo "migrate_updown: arm 'fresh' — the only residue of VERSION=0 is"
      echo "                reporter_project_tabs and its index, which FR-69 requires to survive:"
      sed 's/^/                  /' "$WORK/added.txt"
      ;;
  esac

  # ------------------------------------------ up again, AFTER the rollback
  #
  # §7 rule 4's order, and it is the order for a reason: "migrate up from empty -> assert
  # the full schema -> migrate VERSION=0 -> assert the schema is byte-comparable to the
  # pre-install dump -> migrate up again -> assert idempotent."
  #
  # The reinstall is the operationally interesting half. A user who rolls back to escape a
  # bad release and then reinstalls must get the same schema they had — and on this plugin
  # that is a real question rather than a formality, because 001 left `reporter_project_tabs`
  # standing and its `unless table_exists?` has to ADOPT it rather than fail.
  migrate || { report_arm_failure "$arm" "reinstalling after the rollback failed"; return; }
  snapshot "$WORK/d.txt" || return

  if ! diff -u "$WORK/b.txt" "$WORK/d.txt" >"$WORK/reinstall.diff"; then
    report_arm_failure "$arm" "reinstalling after a rollback did NOT restore the same schema:"
    sed 's/^/    /' "$WORK/reinstall.diff" >&2
    return
  fi

  # And once more, so "up is idempotent" is asserted rather than assumed.
  migrate || { report_arm_failure "$arm" "a second 'migrate' (idempotency) failed"; return; }
  snapshot "$WORK/d2.txt" || return

  if ! diff -u "$WORK/d.txt" "$WORK/d2.txt" >"$WORK/idem.diff"; then
    report_arm_failure "$arm" "migrating up twice changed the schema — it is not idempotent:"
    sed 's/^/    /' "$WORK/idem.diff" >&2
    return
  fi

  echo "migrate_updown: arm '$arm' OK — rollback restored the pre-install schema, reinstall"
  echo "                restored the full one, and a second migrate changed nothing."
}

echo "migrate_updown: plugin=$PLUGIN_NAME  redmine=$REDMINE_DIR  RAILS_ENV=$RAILS_ENV  arms=$MODE_ARMS"

assert_test_database || {
  echo >&2
  echo "migrate_updown: could not establish a safe database to run against." >&2
  exit 2
}

# EVERY arm runs even if an earlier one failed, and each re-establishes its own baseline
# from VERSION=0 — so arm order carries no information and a first failure cannot mask a
# second. That is CLAUDE.md §6's `fail-fast: false` rule applied inside one script: a run
# that stops at the first red cell cannot tell you whether the others were red too.
for arm in $MODE_ARMS; do
  # `|| true`, and an explicit `if` rather than `[ … ] && break`. TWO `set -e` interactions,
  # both found by watching the script exit 1 where it had to exit 2:
  #
  #   * `run_arm` reports a failure by returning non-zero, and a bare non-zero command in a
  #     loop body terminates the shell — so the second arm never ran and the summary below
  #     never printed.
  #   * `[ cond ] && break` returns 1 when the condition is false, and as the LAST command
  #     of a loop body that terminates the shell too.
  #
  # Both would have shown up only on a failing run, which is the one run whose output has to
  # be trustworthy: the exit code that separates "reversibility failed" from "the script
  # could not run" was being thrown away exactly when it mattered.
  run_arm "$arm" || true

  if [ "$INFRASTRUCTURE_FAILURE" -eq 1 ]; then
    break
  fi
done

if [ "$INFRASTRUCTURE_FAILURE" -eq 1 ]; then
  echo >&2
  echo "migrate_updown: DID NOT RUN TO COMPLETION. Gate G11 is UNVERIFIED — not passed, and" >&2
  echo "                not failed either. Fix the error above and run again." >&2
  exit 2
fi

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
