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

  # ------------------------------------------------- DECISION 2: rewrite, non-destructively

  # `RRD_REWRITE=1` TAKES THE SOURCE'S VERSION AND LOSES NOTHING.
  #
  # Before this, the only way to accept the original after editing locally was to DELETE the
  # copy and re-run — data loss offered as a documented step, where §7a had named a
  # `--rewrite` flag. The local content goes into the template's own append-only version
  # history FIRST, so the flag changes which content is CURRENT and never which content
  # still exists.
  def test_rewrite_takes_the_source_and_keeps_the_local_edit_in_the_version_history
    id = seed_source
    run_import
    copy = Template.find_by(source_template_id: id)
    copy.update!(content: '<p>my own edit</p>')
    connection.update("UPDATE report_templates SET content = #{connection.quote('<p>new</p>')} " \
                      "WHERE id = #{id}")

    result = run_import(rewrite: true)

    assert_equal 1, result.count(:updated)
    assert_equal '<p>new</p>', copy.reload.content
    # THE EDIT IS STILL THERE. This is the assertion that makes the flag safe rather than
    # merely convenient.
    assert_includes copy.versions.map(&:content), '<p>my own edit</p>'
  end

  # THE SNAPSHOT COMES FIRST, so a failure to record it cannot leave the edit destroyed.
  # Asserted by ORDER of effect: with the version write raising, the content must not move.
  def test_rewrite_does_not_overwrite_when_the_snapshot_cannot_be_written
    id = seed_source
    run_import
    copy = Template.find_by(source_template_id: id)
    copy.update!(content: '<p>my own edit</p>')
    connection.update("UPDATE report_templates SET content = #{connection.quote('<p>new</p>')} " \
                      "WHERE id = #{id}")

    # A TARGETED, RESTORED PATCH rather than `stub`: the write is
    # `existing.versions.create!`, which goes through the association, so stubbing the
    # class's `.new` would not reach it and `Object#stub` needs `minitest/mock` besides.
    # `create_or_update` is the one method every persistence path funnels through.
    klass = RedmineReporterDashboards::TemplateVersion
    original = klass.instance_method(:create_or_update)
    begin
      klass.send(:define_method, :create_or_update) { |*| raise 'no snapshot' }
      assert_raises(RuntimeError) { run_import(rewrite: true) }
    ensure
      klass.send(:define_method, :create_or_update, original)
    end

    assert_equal '<p>my own edit</p>', copy.reload.content,
                 'the content was overwritten even though the snapshot failed'
  end

  # WITHOUT THE FLAG IT STILL REFUSES, and the note now names the flag rather than telling
  # somebody to delete their work.
  def test_without_rewrite_a_diverged_copy_is_still_left_alone_and_the_note_names_the_flag
    id = seed_source
    run_import
    Template.find_by(source_template_id: id).update!(content: '<p>mine</p>')
    connection.update("UPDATE report_templates SET content = #{connection.quote('<p>new</p>')} " \
                      "WHERE id = #{id}")

    result = run_import

    assert_equal 1, result.count(:diverged)
    assert result.notes.any? { |note| note.include?('RRD_REWRITE') }
    assert_not result.notes.any? { |note| note.match?(/delete/i) },
               'the note must not offer data loss as the remedy'
  end

  # ------------------------------------------------- DECISION 3: a project that is not here

  # A TEMPLATE WHOSE PROJECT WAS NEVER MIGRATED IS SKIPPED, NOT IMPORTED INVISIBLY.
  #
  # `belongs_to :project, optional: true` does no existence check, so this used to import
  # cleanly, report `created`, and produce a row that no surface in this plugin can reach —
  # every one of them is scoped through a project.
  def test_a_template_whose_project_does_not_exist_is_skipped_and_names_it
    assert_not Project.exists?(id: 999_999), 'the fixture must not have this project'
    connection.insert(
      "INSERT INTO report_templates (type, name, project_id, content) VALUES (" \
      "'IssueListReportTemplate', 'Orphan', 999999, '<p>x</p>')"
    )

    result = run_import

    assert_equal 1, result.count(:skipped)
    assert_equal 0, Template.where.not(source_template_id: nil).count
    assert_includes result.outcomes.first.reason, '999999'
    assert result.failed?
  end

  # AN ARCHIVED PROJECT IS DELIBERATELY NOT REFUSED. The row is real and the template
  # becomes reachable again on unarchive; refusing would make a migration depend on the
  # order somebody happens to unarchive things in.
  def test_a_template_in_an_archived_project_is_still_imported
    seed_source(name: 'Archived one')
    @project.update_columns(status: Project::STATUS_ARCHIVED)

    result = run_import

    assert_equal 1, result.count(:created)
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

  # ------------------------------------------------------------ S-29, the dashboards

  # THE DEFECT, REPRODUCED END TO END BEFORE THE FIX IS ASSERTED.
  #
  # Both tables number from 1, so a widget holding the SOURCE's template id usually still
  # resolves here — to an unrelated report of ours, rendered silently. The collision is
  # BUILT rather than hoped for: the source row is inserted with an explicit id equal to
  # one of our existing templates, which is what a real migration looks like and what makes
  # the "before" assertion mean anything.
  def test_a_carried_over_widget_setting_renders_the_wrong_report_until_the_import_fixes_it
    decoy = rrd_owned_template('DECOY — not what was configured')
    source_id = seed_source_with_id(decoy.id, name: 'The real one', content: '<p>RIGHT</p>')
    tab = tab_with_widget(stored_template_id: source_id)
    assert_equal decoy, resolved_template(tab),
                 'precondition: the stale id must resolve to the decoy, or this proves nothing'

    result = run_import

    assert_equal 1, result.widget_changes.count { |c| c.status == :rewritten }
    copy = Template.find_by!(source_template_id: source_id)
    assert_equal copy, resolved_template(tab.reload),
                 'after the import the widget must render the copy of what it named'
    assert_not_equal decoy, resolved_template(tab)
  end

  # A PLAN THAT DOES NOT PREDICT THE RUN IS WORSE THAN NO PLAN — the runner's own words.
  # Both halves: the same changes are reported, and the row is untouched.
  def test_a_dry_run_predicts_the_widget_changes_and_writes_none_of_them
    source_id = seed_source(name: 'The real one')
    tab = tab_with_widget(stored_template_id: source_id)

    touched_before = tab.reload.updated_at
    dry = run_import(dry_run: true)
    tab.reload
    stored_after_dry = stored_template_id(tab)
    # THE ROW, NOT ONLY THE VALUE. On a dry run there is nothing to write into the settings
    # anyway (the copies have no ids yet), so a version of this test that only checked the
    # id passed against a `save!` that fired regardless and moved `updated_at` — an
    # operator's "did the plan change anything?" answered wrongly.
    assert_equal touched_before, tab.updated_at, 'a dry run must not touch the row at all'
    real = run_import

    assert_equal source_id.to_i, stored_after_dry, 'a dry run must not write'
    assert_equal [:rewritten], dry.widget_changes.map(&:status)
    assert_equal dry.widget_changes.map { |c| [c.block, c.from, c.status] },
                 real.widget_changes.map { |c| [c.block, c.from, c.status] }
  end

  # Idempotence rests on the MARKER, not on the arithmetic — a second run must be a no-op
  # even where the numbers would line up again.
  def test_a_second_import_does_not_rewrite_a_widget_twice
    source_id = seed_source(name: 'The real one')
    tab = tab_with_widget(stored_template_id: source_id)

    run_import
    first = stored_template_id(tab.reload)
    second_run = run_import

    assert_equal first, stored_template_id(tab.reload)
    assert_equal 0, second_run.widget_changes.count { |c| c.status == :rewritten }
  end

  # A stored id with no imported counterpart is LEFT ALONE and NAMED. Rewriting it would be
  # inventing a mapping; summarising it away would leave somebody with a widget to re-pick
  # and no way to know which.
  def test_an_unmappable_widget_is_left_alone_and_named_in_the_report
    seed_source(name: 'The real one')
    tab = tab_with_widget(stored_template_id: 999_999)

    touched_before = tab.reload.updated_at
    result = run_import
    tab.reload

    assert_equal 999_999, stored_template_id(tab)
    # `:unknown` changes nothing, so the row must not be written — `updated_at` moving on a
    # tab the run did not change is what makes an operator stop trusting the next report.
    assert_equal touched_before, tab.updated_at
    assert_equal [:unknown], result.widget_changes.map(&:status)
    printed = RedmineReporterDashboards::Import::ImportReport.render(result)
    assert_includes printed, 'COULD NOT BE MAPPED'
    assert_includes printed, 'widget report_by_issues: stored template 999999'
  end

  # Only the two report widgets' settings are this module's business. A `news` widget that
  # happens to hold the same key must not be touched, and neither must the layout.
  #
  # `news` IS IN THE LAYOUT, and that is not decoration: `clear_unused_block_settings`
  # drops the settings of any block the layout does not name, on every save — so a version
  # of this test that only added the settings would pass against a module that rewrote
  # `news` too.
  def test_it_touches_only_the_report_widgets
    source_id = seed_source(name: 'The real one')
    tab = ReporterProjectTab.create!(
      project: @project, title: 'Overview',
      layout: [['report_by_issues'], ['news']],
      settings: { 'report_by_issues' => { report_template_id: source_id },
                  'news' => { report_template_id: source_id } }
    )
    assert_equal source_id.to_i, tab.reload.block_settings('news')[:report_template_id],
                 'precondition: the news setting must survive the layout prune'
    layout_before = tab.layout

    run_import

    tab.reload
    assert_equal source_id.to_i, tab.block_settings('news')[:report_template_id]
    assert_nil tab.block_settings('news')[:report_template_origin]
    assert_equal layout_before, tab.layout
  end

  # A dashboard may hold up to MAX_BLOCK_OCCURS copies of a widget, and every one carries
  # its own stored id. The `__N` instances are the ones a walk over a settings Hash is most
  # likely to miss — and the one the widget lookup itself got wrong once already.
  def test_every_instance_of_a_report_widget_is_rewritten
    issues_id = seed_source(name: 'Issues report')
    hours_id = seed_source(type: 'TimeEntriesReportTemplate', name: 'Hours report')
    blocks = %w[report_by_issues report_by_issues__1 report_by_spent_time]
    stored = { 'report_by_issues' => issues_id, 'report_by_issues__1' => issues_id,
               'report_by_spent_time' => hours_id }
    tab = ReporterProjectTab.create!(
      project: @project, title: 'Overview', layout: blocks.map { |b| [b] },
      settings: blocks.to_h { |b| [b, { report_template_id: stored[b] }] }
    )

    result = run_import

    assert_equal 3, result.widget_changes.count { |c| c.status == :rewritten }
    tab.reload
    blocks.each do |block|
      assert_not_equal stored[block].to_i, tab.block_settings(block)[:report_template_id],
                       "#{block} was left pointing at the source's id"
      assert_equal 'rrd', tab.block_settings(block)[:report_template_origin]
    end
  end

  # THE MARKER IS WHAT MAKES A RE-RUN SAFE, AND ONLY A COLLISION CAN SHOW IT.
  #
  # After a rewrite the widget stores the COPY's id. A second run is a no-op simply because
  # that id is usually not also a source id — which is the probabilistic reasoning S-29 is
  # about, one level in. This builds the case where it IS: a second source row is inserted
  # with an explicit id equal to the copy's. Without the marker the widget is rewritten a
  # second time, to a template nobody named.
  def test_the_marker_stops_a_second_rewrite_when_the_new_id_collides_with_a_source_id
    first_source = seed_source(name: 'The real one')
    tab = tab_with_widget(stored_template_id: first_source)
    run_import
    copy_id = stored_template_id(tab.reload)
    assert_not_equal first_source.to_i, copy_id, 'precondition: the rewrite must have happened'

    # A source row whose id is the id the widget now stores — the collision, built.
    seed_source_with_id(copy_id, name: 'A DIFFERENT source', content: '<p>OTHER</p>')
    second = run_import

    assert_equal copy_id, stored_template_id(tab.reload),
                 'the marker must stop a widget being repointed a second time'
    assert_equal 0, second.widget_changes.count { |c| c.status == :rewritten }
  end

  # A SKIPPED SOURCE HAS NO COPY, so a widget naming it must be reported as unmappable
  # rather than as repointed. Including skipped rows in the mapping makes the report claim
  # a widget was fixed while its stored id is untouched — the report lying about the one
  # thing it exists to say.
  def test_a_skipped_source_is_not_reported_as_a_repointed_widget
    skipped_id = seed_source(type: 'SomethingReporterNeverShipped', name: 'Unknown type')
    tab = tab_with_widget(stored_template_id: skipped_id)

    result = run_import

    assert_equal 1, result.count(:skipped), 'precondition: the source must have been skipped'
    assert_equal [:unknown], result.widget_changes.map(&:status)
    assert_equal skipped_id.to_i, stored_template_id(tab.reload)
  end

  # `WidgetSettings.apply` IS A PUBLIC METHOD AND ITS `dry_run:` IS ITS OWN CONTRACT.
  #
  # Driven directly rather than through `import:run`, because on that path a dry run has no
  # template ids to write anyway — so `unless dry_run` is unobservable there, and a
  # mutation that deleted it survived the whole importer suite. A caller handing this
  # module a REAL mapping with `dry_run: true` is the case the flag exists for, and it is
  # one method call away.
  def test_apply_writes_nothing_on_a_dry_run_even_with_a_real_mapping
    copy = rrd_owned_template('The copy')
    tab = tab_with_widget(stored_template_id: 4242)
    changes = RedmineReporterDashboards::Import::WidgetSettings.apply({ 4242 => copy },
                                                                     dry_run: true)

    assert_equal [:rewritten], changes.map(&:status), 'the plan must still be computed'
    assert_equal 4242, stored_template_id(tab.reload), 'a dry run must not write'
  end

  # A TAB WITH NOTHING TO REWRITE MUST NOT BE SAVED, and the observable is not `updated_at`
  # — Rails issues no UPDATE for an unchanged record, measured: 0 statements. It is
  # `clear_unused_block_settings`, which runs `before_validation` and PRUNES the settings of
  # any block the layout does not name. Saving a tab this run had no business touching would
  # therefore delete somebody else's stored settings as a side effect of an import.
  def test_a_tab_whose_widgets_are_all_unmappable_is_not_saved_at_all
    seed_source(name: 'The real one')
    tab = tab_with_widget(stored_template_id: 999_999)
    # Written around the callbacks on purpose: this is the state a tab reaches when a widget
    # is removed from the layout by an older version, and it is what the prune would eat.
    tab.update_column(:settings, tab.settings.merge('news' => { limit: 7 }))

    run_import

    assert_equal 7, ReporterProjectTab.find(tab.id).settings['news'][:limit],
                 'the import saved a tab it had no change for, and the prune ate the settings'
  end

  private

  def rrd_owned_template(name)
    Template.create!(project: @project, author: @admin, name: name,
                     content: '<p>WRONG</p>', source: 'issues', output: 'combined',
                     visibility: Template::VISIBILITY_PUBLIC)
  end

  # An explicit id, so the collision S-29 is about can be BUILT rather than waited for.
  def seed_source_with_id(id, type: 'IssueListReportTemplate', name: 'Weekly',
                          content: '<p>hi</p>')
    connection.insert(
      'INSERT INTO report_templates (id, type, name, project_id, content) VALUES (' \
      "#{connection.quote(id)}, #{connection.quote(type)}, #{connection.quote(name)}, " \
      "#{connection.quote(@project.id)}, #{connection.quote(content)})"
    )
    id
  end

  def tab_with_widget(stored_template_id:, block: 'report_by_issues')
    ReporterProjectTab.create!(project: @project, title: 'Overview',
                               layout: [[block]],
                               settings: { block => { report_template_id: stored_template_id } })
  end

  def stored_template_id(tab, block: 'report_by_issues')
    settings = tab.block_settings(block)
    settings[:report_template_id] || settings['report_template_id']
  end

  # Resolved the way the WIDGET resolves it, not by a bare find — the claim is about what
  # somebody looking at the dashboard sees.
  def resolved_template(tab, block: 'report_by_issues')
    @project.enable_module!(:reporter_dashboards_reports)
    RedmineReporterDashboards::WidgetReport.template_for(
      project: @project, actor: @admin, source: 'issues',
      template_id: stored_template_id(tab, block: block)
    )
  end
end
