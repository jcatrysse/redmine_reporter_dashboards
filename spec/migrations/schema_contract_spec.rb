# frozen_string_literal: true

# T-22 — the schema the migrations describe, asserted against `technical-spec.md` §7.
#
# Every example here is a sentence from §7 or from an FR, turned into a check. That is
# deliberate: §7's table list is prose, and CLAUDE.md §Phase 2 names "specified as
# mechanical, implemented as a comment" as a review failure. Four of the requirements are
# security decisions rather than conveniences — recipients being `user_id` only, the
# scheduler's unique index, the append-only version trail, the mandatory document TTL — and
# a security decision that only a comment defends is one a later task removes without
# noticing.
#
# The schema is read by EXECUTING the migration DSL against a recorder, in a subprocess.
# `spec/migrations/schema_recorder.rb` says why it is a subprocess (§Findings E-7, one
# dependency over) and why it executes rather than parses.
#
# This runs with no Rails, no ActiveRecord and no database, so it runs everywhere. What it
# cannot see is whether the database AGREES — `script/migrate_updown.sh` is where the same
# table list is checked against a live engine.

require 'json'
require 'open3'

require_relative '../spec_helper'

RSpec.describe 'the migration schema contract (technical-spec.md §7)' do
  # A method rather than a constant. A constant assigned inside an `RSpec.describe` block
  # lands on `Object`, not on the example group — see the long note in
  # `reversibility_spec.rb`, where that cost two of T-16's examples in the full run.
  def self.plugin_root
    File.expand_path('../..', __dir__)
  end

  def plugin_root
    self.class.plugin_root
  end

  # One subprocess for the whole file.
  def self.recorded_schema
    @recorded_schema ||= begin
      recorder = File.join(plugin_root, 'spec', 'migrations', 'schema_recorder.rb')
      migrations = File.join(plugin_root, 'db', 'migrate')
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, recorder, migrations)

      unless status.success?
        raise "schema_recorder.rb failed (#{status.exitstatus}); NOTHING was checked:\n#{stderr}"
      end

      JSON.parse(stdout)
    end
  end

  let(:schema)  { self.class.recorded_schema }
  let(:tables)  { schema['tables'] }
  let(:indexes) { schema['indexes'] }

  def columns_of(table)
    tables.fetch(table).fetch('columns')
  end

  def column(table, name)
    columns_of(table).find { |c| c['name'] == name }
  end

  def column_names(table)
    columns_of(table).map { |c| c['name'] }
  end

  def index_named(name)
    indexes.find { |i| i['name'] == name }
  end

  # ---------------------------------------------------------------------------
  # The recorder itself — same reasoning as the AST reader's meta-test. A recorder that
  # silently records nothing makes every example below pass.
  # ---------------------------------------------------------------------------
  describe 'the recorder itself' do
    it 'read every migration and produced a non-trivial schema' do
      expect(schema['migrations'].size).to be >= 7
      expect(tables.size).to be >= 8
      expect(indexes.size).to be >= 15
    end

    it 'expands t.timestamps into two columns' do
      expect(column_names('reporter_dashboards_templates')).to include('created_at', 'updated_at')
    end

    it 'records the implicit primary key, and its absence' do
      expect(tables['reporter_dashboards_schedule_recipients']['id']).to be(true)
      expect(tables['reporter_dashboards_templates_roles']['id']).to be(false)
    end
  end

  # ---------------------------------------------------------------------------
  # §7's table list
  # ---------------------------------------------------------------------------
  describe 'the tables' do
    # The six §7 marks "new", plus the visibility join table 002 creates with them, plus
    # the one §7 marks "exists". Listed rather than derived: a migration silently not
    # running should be a failure, not a shorter list.
    def expected_tables
      %w[
        reporter_project_tabs
        reporter_dashboards_templates
        reporter_dashboards_templates_roles
        reporter_dashboards_template_versions
        reporter_dashboards_schedules
        reporter_dashboards_schedule_runs
        reporter_dashboards_schedule_recipients
        reporter_dashboards_documents
      ]
    end

    it 'is exactly the set §7 names' do
      expect(tables.keys.sort).to eq(expected_tables.sort)
    end

    it 'prefixes every new table with reporter_dashboards_, so both plugins can be installed at once' do
      # `technical-spec.md:1266-1270`: "Namespaced classes + new tables mean both plugins
      # can be installed simultaneously … Decisive." The base plugin's tables are
      # `report_templates`, `report_schedules` and `report_schedules_users`
      # (`lib/redmine_reporter_dashboards/import/survey.rb:45-47`); a collision would make
      # the A/B comparison this whole design rests on impossible.
      reporter_tables = %w[report_templates report_schedules report_schedules_users]

      expect(tables.keys & reporter_tables).to eq([])
      (tables.keys - ['reporter_project_tabs']).each do |name|
        expect(name).to start_with('reporter_dashboards_')
      end
    end
  end

  # ---------------------------------------------------------------------------
  # FR-39 / §7's "the unique index is the whole scheduler fix"
  # ---------------------------------------------------------------------------
  describe 'the at-most-once constraint (FR-39)' do
    it 'puts a UNIQUE index on [schedule_id, occurrence_date]' do
      index = index_named('index_rd_runs_on_schedule_and_occurrence')

      expect(index).not_to be_nil
      expect(index['table']).to eq('reporter_dashboards_schedule_runs')
      expect(index['columns']).to eq(%w[schedule_id occurrence_date])
      expect(index['unique']).to be(true),
                                 'FR-39 puts the guarantee on the database, "not only by ' \
                                 'application logic". A non-unique index enforces nothing.'
    end

    it 'creates it in the SAME migration as its table (§7 rule 6)' do
      # "an index added in a later migration is an index a partially-migrated install does
      # not have, and the scheduler's at-most-once guarantee is only as strong as that
      # index." The recorder replays migrations in order, so an index for a table that has
      # not been created yet would be visible as exactly that.
      runs_migration = schema['migrations'].find { |m| m['file'].include?('schedule_runs') }

      expect(runs_migration).not_to be_nil
      source = File.read(File.join(plugin_root, 'db', 'migrate', runs_migration['file']),
                         encoding: 'UTF-8')
      expect(source).to include('create_table :reporter_dashboards_schedule_runs')
      expect(source).to include('index_rd_runs_on_schedule_and_occurrence')
    end

    it 'stores the occurrence as a date, not a datetime' do
      # A datetime would make the unique index useless: two runs a second apart would be
      # two different occurrences.
      expect(column('reporter_dashboards_schedule_runs', 'occurrence_date')['type']).to eq('date')
    end
  end

  # ---------------------------------------------------------------------------
  # §7: "Reporter stores these dates as datetime while every comparison is date-based"
  # ---------------------------------------------------------------------------
  describe 'schedule dates (the defect §7 names)' do
    %w[start_date end_date last_run_on next_run_on].each do |name|
      it "stores #{name} as a date" do
        expect(column('reporter_dashboards_schedules', name)['type']).to eq('date')
      end
    end

    it 'still uses datetime where an instant really is meant' do
      # The rule is "a date where the comparison is by date", not "never a datetime". If
      # this flipped to `date` the run log would lose the ability to say how long ago an
      # attempt was.
      expect(column('reporter_dashboards_schedules', 'last_attempted_at')['type']).to eq('datetime')
    end
  end

  # ---------------------------------------------------------------------------
  # §7: "user_id only — no free-text to/cc/bcc/from … A security-motivated schema decision"
  # ---------------------------------------------------------------------------
  describe 'recipients (the exfiltration-and-spoofing-relay finding)' do
    def forbidden_mail_columns
      %w[to cc bcc from to_address from_address sender recipients_raw]
    end

    it 'carries user_id and nothing that could hold an address' do
      expect(column_names('reporter_dashboards_schedule_recipients'))
        .to contain_exactly('id', 'schedule_id', 'user_id', 'created_at')
    end

    it 'has no free-text address column in ANY table this plugin creates' do
      # Asserted across the whole schema rather than one table, because the next place
      # somebody would add one is the schedule itself, or the document. §7b.5 keeps the
      # capability of mailing an external address — through an admin setting and a domain
      # allowlist (FR-61), which is a policy about the installation, never a string typed
      # into a per-project form.
      offenders = tables.flat_map do |table, definition|
        definition['columns']
          .map { |c| c['name'] }
          .select { |name| forbidden_mail_columns.include?(name) }
          .map { |name| "#{table}.#{name}" }
      end

      expect(offenders).to eq([])
    end

    it 'gains an id, unlike the join row §7 criticises' do
      # "replaces `report_schedules_users` (which is `id: false`, so a join row is
      # unaddressable). Gains `id`".
      expect(tables['reporter_dashboards_schedule_recipients']['id']).to be(true)
    end

    it 'refuses the same person twice by index, not only by validation' do
      index = index_named('index_rd_recipients_ids')

      expect(index['unique']).to be(true)
      expect(index['columns']).to eq(%w[schedule_id user_id])
    end
  end

  # ---------------------------------------------------------------------------
  # §7 rule 6 and T-40's visibility column
  # ---------------------------------------------------------------------------
  describe 'the templates table' do
    it 'carries lock_version, created with the table (§7 rule 6)' do
      lock = column('reporter_dashboards_templates', 'lock_version')

      expect(lock).not_to be_nil
      expect(lock['type']).to eq('integer')
      expect(lock['null']).to be(false)
      expect(lock['default']).to eq('0')
    end

    it 'carries visibility as an integer defaulting to private (T-40, §4.1)' do
      # Redmine's own values, `app/models/query.rb:259-261`: PRIVATE 0, ROLES 1, PUBLIC 2.
      # `manage_public_reporter_dashboards_templates` governs nothing without this column,
      # and §7 rule 6 forbids adding it in a later migration than its table.
      visibility = column('reporter_dashboards_templates', 'visibility')

      expect(visibility['type']).to eq('integer')
      expect(visibility['default']).to eq('0')
      expect(visibility['null']).to be(false)
    end

    it 'ships the roles join table visibility = ROLES needs' do
      # Not in §7's list. Shipping the column without the table would ship a value an
      # administrator can select and the code can never honour, and rule 6 forbids adding
      # the table later.
      expect(column_names('reporter_dashboards_templates_roles')).to contain_exactly('template_id', 'role_id')

      index = index_named('index_rd_templates_roles_ids')
      expect(index['unique']).to be(true)
    end

    it 'carries the two axes reporter conflated into one `type`' do
      # `implementation-plan.md:1979`: "template types by `source` field (T-31), not a
      # subclass tree". A column literally named `type` is Rails' STI discriminator, which
      # is the subclass tree four documents forbid — so there is deliberately not one.
      expect(column('reporter_dashboards_templates', 'source')['type']).to eq('string')
      expect(column('reporter_dashboards_templates', 'output')['type']).to eq('string')
      expect(column_names('reporter_dashboards_templates')).not_to include('type')
    end

    it 'carries the import provenance T-24 needs, with idempotency on the index' do
      expect(column_names('reporter_dashboards_templates')).to include('source_template_id', 'source_digest')
      expect(index_named('index_rd_templates_on_source_template_id')['unique']).to be(true)
    end
  end

  # ---------------------------------------------------------------------------
  # §7: "append-only"
  # ---------------------------------------------------------------------------
  describe 'the template version trail (FR-21)' do
    it 'has created_at and NO updated_at' do
      # The absence is the mechanism. A row that can be updated is not an audit trail, and
      # a schema offering an `updated_at` invites the first person in a hurry to write one.
      names = column_names('reporter_dashboards_template_versions')

      expect(names).to include('created_at')
      expect(names).not_to include('updated_at')
    end

    it 'records a digest of the content it stores' do
      expect(column_names('reporter_dashboards_template_versions')).to include('content', 'content_digest')
    end
  end

  # ---------------------------------------------------------------------------
  # §7: "opt-in with a mandatory TTL and a purge task"
  # ---------------------------------------------------------------------------
  describe 'the document store' do
    it 'makes expires_at NOT NULL, because that is how "mandatory" is said in a schema' do
      expires = column('reporter_dashboards_documents', 'expires_at')

      expect(expires['type']).to eq('datetime')
      expect(expires['null']).to be(false),
                                 '§7: "Persistence is opt-in with a mandatory TTL … That converts ' \
                                 'an unmanaged indefinite store into off-by-default, bounded-when-on." ' \
                                 'A nullable expiry IS the unmanaged indefinite store.'
    end

    it 'indexes the column the purge task scans' do
      expect(index_named('index_rd_documents_on_expires_at')).not_to be_nil
    end

    it 'records the identity the content was rendered as (FR-45, FR-47)' do
      expect(column_names('reporter_dashboards_documents')).to include('rendered_as_user_id')
    end

    it 'records the engine stamp FR-27 requires' do
      expect(column_names('reporter_dashboards_documents'))
        .to include('engine', 'engine_version', 'render_duration_ms', 'correlation_id')
    end
  end

  # ---------------------------------------------------------------------------
  # The defect the first real migration run found
  # ---------------------------------------------------------------------------
  describe 'index names' do
    it 'keeps every index name inside the tighter engine limit' do
      # PostgreSQL truncates identifiers at 63 characters and MySQL at 64. The derived name
      # for `[:project_id, :visibility]` on `reporter_dashboards_templates` is 64, so the
      # first run of migration 002 aborted on PostgreSQL — and would have SUCCEEDED on
      # MySQL. A plugin that installs on one engine and refuses on another, decided by the
      # length of a column name.
      too_long = indexes.select { |i| i['name'].length > 62 }
                        .map { |i| "#{i['name']} (#{i['name'].length})" }

      expect(too_long).to eq([])
    end

    it 'names every index on a new table explicitly rather than relying on the derivation' do
      derived = indexes.reject { |i| i['explicit_name'] }
                       .reject { |i| i['table'] == 'reporter_project_tabs' }
                       .map { |i| "#{i['table']}: #{i['name']}" }

      expect(derived).to eq([]),
                         'A derived name is a length nobody chose. reporter_project_tabs is ' \
                         'excluded because migration 001 predates this rule and its derived ' \
                         'name is 52 characters — changing it would rename an index on every ' \
                         'installed database for no benefit.'
    end
  end
end
