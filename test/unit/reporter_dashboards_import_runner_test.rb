# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-24 — the importer, against REAL reporter-shaped tables.
#
# --- WHY THE FULL APP AND NOT A DOUBLE ---
#
# Every claim T-24's `Accept:` makes is about a database. "Never writes to reporter's
# tables" needs those tables to exist so that a write to them would be observable.
# "Idempotent" means running it twice against a real unique-keyed row set. And the
# four-way outcome turns on `source_digest`, which is a column.
#
# The tables are created here and dropped in teardown, which is the pattern T-02's survey
# already uses: the base plugin is private and is not installed in CI, so the only way to
# exercise the migration path is to build its shape.
class ReporterDashboardsImportRunnerTest < ActiveSupport::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  Runner = RedmineReporterDashboards::Import::Runner
  Template = RedmineReporterDashboards::Template

  def setup
    @admin = User.find(1)
    assert @admin.admin?, 'user 1 must be an administrator'
    @project = Project.find(1)
    create_source_tables
  end

  def teardown
    drop_source_tables
  end

  # ------------------------------------------------------------------ the substrate

  def connection
    ActiveRecord::Base.connection
  end

  # Reporter's shape, as `Import::Survey` documents it. Only the columns the importer
  # reads: this is a stand-in for another plugin's schema, not a copy of it.
  def create_source_tables
    drop_source_tables
    connection.create_table(:report_templates) do |t|
      t.string :type
      t.string :name
      t.integer :project_id
      t.text :content
    end
  end

  def drop_source_tables
    connection.drop_table(:report_templates, if_exists: true)
  end

  def seed_source(type: 'IssueListReportTemplate', name: 'Weekly', content: '<p>hi</p>')
    connection.insert(
      "INSERT INTO report_templates (type, name, project_id, content) VALUES (" \
      "#{connection.quote(type)}, #{connection.quote(name)}, " \
      "#{connection.quote(@project.id)}, #{connection.quote(content)})"
    )
    connection.select_value('SELECT MAX(id) FROM report_templates')
  end

  def run_import(**options)
    Runner.call(actor: @admin, **options)
  end

  # ------------------------------------------------------------------ copy, forward-only

  def test_it_copies_a_template_and_stamps_its_source_and_digest
    source_id = seed_source

    result = run_import

    assert_equal 1, result.count(:created)
    copy = Template.find_by(source_template_id: source_id)
    assert copy, 'no copy was written'
    assert_equal '<p>hi</p>', copy.content
    assert_equal Runner.digest('<p>hi</p>'), copy.source_digest
    assert_equal @admin.id, copy.author_id
    assert_equal @project.id, copy.project_id
    # T-23's rule, applied to the importer: a copy is private to whoever imported it. The
    # source plugin's visibility vocabulary is not ours to translate, and widening is a
    # decision `manage_public_…` governs afterwards.
    assert_equal Template::VISIBILITY_PRIVATE, copy.visibility
  end

  # REPORTER'S THREE TYPES CONFLATE TWO AXES (§Findings S-2), so one input is two outputs.
  # Read through `Exchange::TYPE_MAP` rather than a second copy of the mapping.
  def test_it_maps_each_source_type_onto_source_and_output
    {
      'IssueReportTemplate' => %w[issues per_record],
      'IssueListReportTemplate' => %w[issues combined],
      'TimeEntriesReportTemplate' => %w[time_entries combined]
    }.each do |type, (source, output)|
      id = seed_source(type: type, name: "T-#{type}")

      run_import

      copy = Template.find_by(source_template_id: id)
      assert copy, "#{type} produced no copy"
      assert_equal source, copy.source, type
      assert_equal output, copy.output, type
    end
  end

  # AN UNKNOWN TYPE IS SKIPPED WITH ITS NAME, NOT GUESSED AT. `constantize` on a database
  # column is FR-55's defect with a different input channel.
  def test_an_unknown_type_is_skipped_and_named
    seed_source(type: 'SomeOtherPluginTemplate', name: 'Odd one')

    result = run_import

    assert_equal 1, result.count(:skipped)
    assert_equal 0, Template.where.not(source_template_id: nil).count
    assert result.failed?, 'a skipped template must make the run report failure'
    assert_includes result.outcomes.first.reason, 'SomeOtherPluginTemplate'
  end

  # THE CLAUSE THAT DEFINES THE WHOLE TASK. `technical-spec.md` §7's *Adopt vs copy*: the
  # base plugin's own uninstall drops these tables, so adopting the rows would lose them.
  #
  # Asserted on the STATEMENTS, not on the rows: a row that still looks right proves the
  # importer did not happen to change it, not that it could not.
  # THE PATTERN MATCHES A VERB AND A TABLE, NOT THE START OF THE STRING.
  #
  # The first version anchored at `\A\s*`, and an independent review defeated it with one
  # leading SQL comment: Rails emits `/* controller:… */ UPDATE …` whenever
  # `query_log_tags_enabled` is on, which is an ordinary production setting. A real
  # `connection.execute("/* rails */ UPDATE report_templates SET name = 'PWNED'")` planted
  # inside the runner left this test GREEN while the row-comparison test below — the one
  # the commit message called insufficient — was the only thing that fired.
  #
  # The anchor cannot simply be dropped: `SELECT id, updated_on FROM report_templates`
  # contains "update". Matching VERB + `report_` table is what distinguishes them, and
  # `WRITE_TO_SOURCE` is shared with `#test_status_writes_nothing` so the two cannot drift.
  #
  # HANDOVER §1: "Negative-test a gate before trusting it — plant the violation it exists to
  # catch and watch it fail." This one was not, and that is why it did not work.
  WRITE_TO_SOURCE = /
    \b(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM|DROP\s+TABLE|ALTER\s+TABLE|TRUNCATE(?:\s+TABLE)?)
    \s+(?:ONLY\s+)?[`"\[]?report_
  /xi.freeze

  def writes_to_source(&block)
    offending = []
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      offending << sql if sql.match?(WRITE_TO_SOURCE)
    end

    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &block)
    offending
  end

  def test_it_issues_no_write_against_reporters_tables
    seed_source
    seed_source(name: 'Second')

    assert_equal [], writes_to_source { run_import }
  end

  # THE GATE'S OWN NEGATIVE TEST, committed rather than performed once by hand.
  #
  # Every shape the first version missed, plus the one it caught, driven through the very
  # predicate the test above uses. Without this the pattern is a regexp nobody has watched
  # fail, which is what it was.
  def test_the_no_write_pattern_catches_every_shape_of_write
    caught = [
      "INSERT INTO report_templates (name) VALUES ('x')",
      "insert into report_templates (name) values ('x')",
      "/* rails */ UPDATE report_templates SET name = 'x'",
      "/* app:redmine,controller:foo */\nUPDATE report_templates SET name = 'x'",
      '  DELETE FROM report_templates WHERE id = 1',
      'UPDATE "report_templates" SET "name" = $1',
      'DROP TABLE report_schedules',
      'TRUNCATE TABLE report_schedules_users'
    ]
    caught.each { |sql| assert sql.match?(WRITE_TO_SOURCE), "missed: #{sql}" }

    # And it must not fire on the SELECTs the importer legitimately issues — a pattern that
    # matched those would be an assertion nobody could keep green, which is how a guard
    # gets deleted.
    [
      'SELECT id, updated_on FROM report_templates ORDER BY id',
      'SELECT id, content FROM report_templates LIMIT 5000',
      'UPDATE reporter_dashboards_templates SET content = $1'
    ].each { |sql| assert_not sql.match?(WRITE_TO_SOURCE), "false positive: #{sql}" }
  end

  def test_the_source_rows_are_untouched
    id = seed_source
    before = connection.select_one("SELECT * FROM report_templates WHERE id = #{id}")

    run_import

    assert_equal before, connection.select_one("SELECT * FROM report_templates WHERE id = #{id}")
    assert_equal 1, connection.select_value('SELECT COUNT(*) FROM report_templates').to_i
  end

  # ------------------------------------------------------------------ idempotence

  def test_running_twice_creates_one_copy_and_reports_it_unchanged
    seed_source

    run_import
    second = run_import

    assert_equal 1, Template.where.not(source_template_id: nil).count
    assert_equal 1, second.count(:unchanged)
    assert_equal 0, second.count(:created)
  end

  # A SAFE FAST-FORWARD: the source moved, the copy did not.
  def test_a_changed_source_updates_an_unedited_copy
    id = seed_source
    run_import
    connection.update("UPDATE report_templates SET content = #{connection.quote('<p>new</p>')} " \
                      "WHERE id = #{id}")

    result = run_import

    assert_equal 1, result.count(:updated)
    copy = Template.find_by(source_template_id: id)
    assert_equal '<p>new</p>', copy.content
    assert_equal Runner.digest('<p>new</p>'), copy.source_digest
  end

  # THE OUTCOME THE TASK'S `Accept:` LINE IS ABOUT. An importer that overwrote a locally
  # edited template would destroy somebody's work, once, quietly, on a re-run triggered for
  # an unrelated reason.
  def test_a_locally_edited_copy_is_never_overwritten
    id = seed_source
    run_import
    copy = Template.find_by(source_template_id: id)
    copy.update!(content: '<p>my own edit</p>')
    connection.update("UPDATE report_templates SET content = #{connection.quote('<p>new</p>')} " \
                      "WHERE id = #{id}")

    result = run_import

    assert_equal 1, result.count(:diverged)
    assert_equal 0, result.count(:updated)
    assert_equal '<p>my own edit</p>', copy.reload.content
    assert_not result.failed?, 'divergence is an expected state, not a failed run'
  end

  # ------------------------------------------------------------------ the dry run

  def test_a_dry_run_decides_everything_and_writes_nothing
    seed_source

    result = run_import(dry_run: true)

    assert_equal 1, result.count(:created)
    assert_equal 0, Template.where.not(source_template_id: nil).count
  end

  # ------------------------------------------------------------------ status

  def test_status_reports_each_kind_of_drift
    unchanged_id = seed_source(name: 'Steady')
    stale_id = seed_source(name: 'Moved')
    edited_id = seed_source(name: 'Edited')
    run_import

    connection.update("UPDATE report_templates SET content = #{connection.quote('<p>x</p>')} " \
                      "WHERE id = #{stale_id}")
    Template.find_by(source_template_id: edited_id).update!(content: '<p>mine</p>')

    status = Runner.status

    by_source = status.outcomes.to_h { |o| [o.source_id, o.status] }
    assert_equal :unchanged, by_source[unchanged_id]
    assert_equal :stale, by_source[stale_id]
    assert_equal :diverged, by_source[edited_id]
  end

  # IT STILL ANSWERS AFTER THE BASE PLUGIN IS GONE, which is exactly when somebody asks
  # what state their migration is in. `source_absent` rather than a crash or a false
  # "up to date".
  def test_status_survives_the_source_tables_being_dropped
    seed_source
    run_import
    drop_source_tables

    status = Runner.status

    assert_equal 1, status.count(:source_absent)
    assert status.notes.any? { |note| note.include?('report_templates') }
  end

  def test_status_writes_nothing
    seed_source
    run_import

    assert_equal [], writes_to_source { Runner.status }
  end

  # ------------------------------------------------------------------ absence and bounds

  # THE EXPECTED STATE ON AN INSTALLATION THAT NEVER HAD THE BASE PLUGIN. Not an error.
  def test_a_missing_source_table_is_a_note_and_not_a_crash
    drop_source_tables

    result = run_import

    assert_equal [], result.outcomes
    assert result.notes.any? { |note| note.include?('report_templates') }
    assert_not result.failed?
  end

  def test_only_the_named_projects_are_imported
    mine = seed_source(name: 'Ours')
    connection.insert(
      "INSERT INTO report_templates (type, name, project_id, content) VALUES (" \
      "'IssueListReportTemplate', 'Theirs', 999, '<p>x</p>')"
    )

    result = run_import(project_ids: [@project.id])

    assert_equal 1, result.outcomes.length
    assert_equal mine, result.outcomes.first.source_id
  end

  # THE ONLY VALUE THAT REACHES THE SQL IS CAST TO INTEGER FIRST.
  def test_a_non_numeric_project_filter_raises_rather_than_reaching_the_database
    seed_source

    assert_raises(ArgumentError) { run_import(project_ids: ['1; DROP TABLE report_templates']) }
    assert connection.table_exists?(:report_templates)
  end

  # ------------------------------------------------------------------ the owner

  def test_resolve_actor_accepts_an_admin_by_login_or_id_and_refuses_anybody_else
    assert_equal @admin, Runner.resolve_actor(@admin.login)
    assert_equal @admin, Runner.resolve_actor(@admin.id.to_s)
    assert_nil Runner.resolve_actor('jsmith'), 'a non-administrator must be refused'
    assert_nil Runner.resolve_actor('nobody-with-this-login')
    # `to_i` would turn this into 0 and `find_by(id: 0)` into a confusing nil; the
    # login branch answers honestly instead.
    assert_nil Runner.resolve_actor('0')
  end

  # THE MUTATION THAT SURVIVED THE FIRST FIX. `User.active` vs `User.all` answer the same
  # thing on a fixture set with no locked administrator, so the property had no test on
  # EITHER branch — which is how the two branches came to disagree in the first place.
  #
  # It matters because `author_id` is what `edit_own_…` reads: templates authored by an
  # account that cannot log in are templates whose owner can never edit them.
  def test_resolve_actor_refuses_an_administrator_who_cannot_log_in
    locked = User.create!(login: 'lockedadmin', firstname: 'L', lastname: 'Admin',
                          mail: 'locked@example.com', admin: true,
                          status: User::STATUS_LOCKED)
    registered = User.create!(login: 'regadmin', firstname: 'R', lastname: 'Admin',
                              mail: 'reg@example.com', admin: true,
                              status: User::STATUS_REGISTERED)

    assert_nil Runner.resolve_actor('lockedadmin'), 'a locked administrator was accepted'
    assert_nil Runner.resolve_actor(locked.id.to_s)
    assert_nil Runner.resolve_actor('regadmin'), 'an unactivated administrator was accepted'
    assert_nil Runner.resolve_actor(registered.id.to_s)
    # And the fallback must not pick one either — the two branches now share one scope.
    assert_not_equal locked, Runner.resolve_actor(nil)
    assert Runner.resolve_actor(nil).active?
  end

  def test_resolve_actor_falls_back_to_an_active_administrator
    assert Runner.resolve_actor(nil)&.admin?
  end
end
