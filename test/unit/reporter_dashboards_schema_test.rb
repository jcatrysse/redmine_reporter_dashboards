# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-22 / T-36 — the LIVE schema, and the properties only a real database can answer.
#
# `spec/migrations/schema_contract_spec.rb` asserts what the migrations describe;
# `script/migrate_updown.sh` asserts that the rollback restores the database. This file
# sits between them and asks the question neither does: does the schema that was actually
# installed match what §7 asked for, on whichever engine this run is using?
#
# It matters because the three engines disagree. An index name over 63 characters aborts
# the migration on PostgreSQL and succeeds on MySQL; a unique index over a nullable column
# behaves the same on all three but nothing says so until it is tried; and `date` versus
# `datetime` is the specific defect §7 says the base plugin has.
class ReporterDashboardsSchemaTest < ActiveSupport::TestCase
  CONNECTION = -> { ActiveRecord::Base.connection }

  # The six §7 marks "new", plus the visibility join table.
  NEW_TABLES = %w[
    reporter_dashboards_templates
    reporter_dashboards_templates_roles
    reporter_dashboards_template_versions
    reporter_dashboards_schedules
    reporter_dashboards_schedule_runs
    reporter_dashboards_schedule_recipients
    reporter_dashboards_documents
  ].freeze

  def test_every_table_section_7_names_exists_in_the_database
    missing = NEW_TABLES.reject { |t| CONNECTION.call.table_exists?(t) }

    assert_equal [], missing
  end

  def test_the_pre_existing_dashboards_table_is_still_there_and_untouched
    # FR-69's second clause, asked of the installed database rather than of the migration.
    assert CONNECTION.call.table_exists?('reporter_project_tabs')
    assert_equal %w[created_at description id layout position project_id settings title updated_at],
                 CONNECTION.call.columns('reporter_project_tabs').map(&:name).sort
  end

  def test_no_new_table_collides_with_a_base_plugin_table
    # `technical-spec.md:1266-1270` — simultaneous installation is the whole argument for
    # copy-not-adopt, and it fails the moment one table name is shared.
    reporter_tables = %w[report_templates report_schedules report_schedules_users]

    assert_equal [], NEW_TABLES & reporter_tables
  end

  def test_every_index_name_fits_the_tightest_identifier_limit
    # PostgreSQL 63, MySQL 64. The first run of migration 002 produced a 64-character
    # DERIVED name and aborted on PostgreSQL — a plugin that installs on one engine and
    # refuses on another, decided by the length of a column name.
    too_long = NEW_TABLES.flat_map { |t| CONNECTION.call.indexes(t) }
                         .map(&:name)
                         .select { |name| name.length > 62 }

    assert_equal [], too_long
  end

  def test_the_occurrence_index_exists_and_is_unique
    index = CONNECTION.call.indexes('reporter_dashboards_schedule_runs')
                      .find { |i| i.name == 'index_rd_runs_on_schedule_and_occurrence' }

    assert_not_nil index, 'FR-39 depends on this index existing'
    assert index.unique, 'a non-unique index enforces nothing'
    assert_equal %w[schedule_id occurrence_date], index.columns
  end

  def test_the_visibility_join_table_has_no_primary_key
    # Follows core's `queries_roles`. Asserted because the choice is deliberate and differs
    # from the recipients table one migration over, which §7 requires to have an id.
    assert_nil CONNECTION.call.primary_key('reporter_dashboards_templates_roles')
    assert_equal 'id', CONNECTION.call.primary_key('reporter_dashboards_schedule_recipients')
  end

  def test_the_schedule_date_columns_are_dates_in_the_database
    columns = CONNECTION.call.columns('reporter_dashboards_schedules').index_by(&:name)

    %w[start_date end_date last_run_on next_run_on].each do |name|
      assert_equal :date, columns.fetch(name).type, "#{name} should be a date, not a datetime"
    end
  end

  def test_the_mandatory_document_expiry_is_not_null_in_the_database
    expires = CONNECTION.call.columns('reporter_dashboards_documents').find { |c| c.name == 'expires_at' }

    assert_not_nil expires
    assert_not expires.null, 'a nullable expiry is the unmanaged indefinite store §7 forbids'
  end

  def test_the_plugins_migration_bookkeeping_is_recorded_where_redmine_actually_records_it
    # FR-69 and CLAUDE.md G11 both say `plugin_schema_info`. That table exists on NO
    # supported Redmine — the only occurrence of the name in 5.1-stable and 6.1-stable is
    # `lib/tasks/redmine.rake:88`, where it appears in a list of names to EXCLUDE. The real
    # marker is a `schema_migrations` row of the form `<n>-<plugin_id>`
    # (`lib/redmine/plugin.rb:553-555`).
    #
    # This test exists so the documentation defect cannot be quietly forgotten: if a future
    # Redmine reintroduced `plugin_schema_info`, this goes red and somebody re-reads FR-69.
    assert_not CONNECTION.call.table_exists?('plugin_schema_info'),
               'plugin_schema_info exists after all — FR-69 and G11 may be right and this ' \
               'plugin\'s migrate-updown job is asserting against the wrong mechanism'

    # Deliberately NOT asserting that a `1-redmine_reporter_dashboards` row is present.
    # MEASURED: it is not, in this suite. `db:test:prepare` reloads the schema and calls
    # `assume_migrated_upto_version` over `ActiveRecord::Migrator.migrations_paths`, which
    # does not include a plugin's `db/migrate` — so plugin rows are dropped and never
    # restored, while the TABLES survive because they are in the dump. An assertion here
    # would be testing the test harness.
    #
    # The presence and later absence of that row is asserted where the migration state is
    # actually under control: `script/migrate_updown.sh`, which runs a real
    # `rake redmine:plugins:migrate` in both directions and fails if any plugin row
    # survives `VERSION=0`.
    versions = CONNECTION.call.select_values(
      "SELECT version FROM #{CONNECTION.call.quote_table_name('schema_migrations')}"
    )
    plugin_rows = versions.select { |v| v.to_s.match?(/\A\d+-\w+\z/) }

    plugin_rows.each do |row|
      assert_match(/\A\d+-[a-z0-9_]+\z/, row,
                   'Redmine records a plugin migration as "<version>-<plugin_id>" ' \
                   '(lib/redmine/plugin.rb:553-555); a row in another shape means the ' \
                   'mechanism moved and FR-69 needs re-reading')
    end
  end

  def test_no_migration_in_this_plugin_reads_or_writes_a_row
    # §7 rule 3 / FR-70, asserted over the shipped files rather than over the reader's own
    # fixtures, so it holds for whatever is actually in db/migrate at release time. The
    # full rule set lives in `script/gates/migration_reversibility.rb`; this is the
    # full-application half saying the same thing where a booted Redmine can see it.
    reader = File.expand_path('../../script/gates/migration_reversibility', __dir__)
    require reader

    migrations = File.expand_path('../../db/migrate', __dir__)
    allowlist = MigrationReversibility.load_allowlist(
      File.expand_path('../../script/gates/migration_reversibility.allowlist', __dir__)
    )
    findings = MigrationReversibility.scan([migrations], allowlist: allowlist)

    assert_equal [], findings.map(&:to_s)
  end
end
