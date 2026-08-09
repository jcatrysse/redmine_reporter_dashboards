# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)
require 'rake'
require 'stringio'

# T-29 — the wiring of the bundle tasks (`export:bundle`, `import:plan`, `import:run`)
# and of the migration importer they had to be told apart from. Only the wiring.
#
# `Bundle`, `BundleImport` and `BundleReport` are covered elsewhere — the format DB-less,
# the importer against a real database. What none of those can reach is the rake file
# itself: a typo in a namespace, a require pointing at a path that moved, or a task that
# raises on the way in. All three produce a fully green suite and a rake task that does
# not exist. `ImportPlanRakeTest` exists for exactly this reason and this file follows it.
#
# --- AND IT PINS THE NAMESPACE, WHICH IS A DECISION RATHER THAN A NAME ---
#
# §7b.2 calls these two steps `import:plan` and `import:run`. Both names were already
# taken by T-02 and T-24's migration importer, which reads the BASE PLUGIN's tables — a
# different feature entirely. The collision is recorded as §Findings S-22; the assertions
# below are what stop somebody "fixing" the namespace back into a duplicate later.
class ExchangeRakeTest < ActiveSupport::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  RAKE_FILE = File.expand_path('../../lib/tasks/reporter_dashboards.rake', __dir__).freeze
  Template = RedmineReporterDashboards::Template

  def setup
    @previous = Rake.application
    @previous_metadata = Rake::TaskManager.record_task_metadata
    Rake.application = Rake::Application.new
    # Descriptions are DISCARDED unless this is on — rake records them only when it is
    # about to show them. `ImportPlanRakeTest` learned that by failing on it first.
    Rake::TaskManager.record_task_metadata = true
    Rake::Task.define_task(:environment)
    load RAKE_FILE

    @project = Project.find(1)
    @admin = User.find(1)
    @tmp = File.join(Dir.tmpdir, "rrd-exchange-#{Process.pid}.json")
  end

  def teardown
    Rake.application = @previous
    Rake::TaskManager.record_task_metadata = @previous_metadata
    File.delete(@tmp) if File.exist?(@tmp)
    %w[RRD_FILE RRD_PROJECT RRD_ON_CONFLICT RRD_ACTOR RRD_OUT].each { |k| ENV.delete(k) }
  end

  # ------------------------------------------------------------------ helpers

  # RETURNS THE EXIT STATUS RATHER THAN LETTING IT ESCAPE, and that is not tidiness — it
  # is the difference between a test suite that reports and one that vanishes.
  #
  # `import:plan` and `import:run` end in `exit(...)`, and `exit(0)` raises
  # `SystemExit` exactly as `exit(2)` does. A test that merely invoked the task let that
  # escape, and Minitest does not catch SystemExit: the whole run TERMINATED at the first
  # such test, printing no summary line at all. `rake` answered 1 with no failing test
  # named, which reads as an infrastructure problem rather than a test bug. Measured here
  # before it was understood, and worth knowing for any future rake-task test.
  def invoke(name)
    out = StringIO.new
    previous = $stdout
    $stdout = out
    status = 0
    begin
      Rake::Task[name].reenable
      Rake::Task[name].invoke
    rescue SystemExit => e
      status = e.status
    end
    [out.string, status]
  ensure
    $stdout = previous
  end

  def write_bundle(*templates)
    File.binwrite(@tmp, JSON.generate('format_version' => 1, 'templates' => templates))
    @tmp
  end

  def entry(overrides = {})
    { 'name' => 'From a file', 'content' => '<p>x</p>', 'source' => 'issues',
      'output' => 'combined' }.merge(overrides)
  end

  # ------------------------------------------------------------------ the tasks exist

  def test_the_three_bundle_tasks_are_defined_under_the_names_the_spec_asks_for
    %w[reporter_dashboards:export:bundle reporter_dashboards:import:plan
       reporter_dashboards:import:run].each do |name|
      assert Rake::Task.task_defined?(name), "#{name} is not defined"
      assert_not_nil Rake::Task[name].comment, "#{name} has no description for rake -T"
    end
  end

  # THE TWO IMPORTERS ARE DISTINCT AND EACH IS WHERE THE CURATOR PUT IT (S-22, decided
  # 2026-08-09). `import:*` is the BUNDLE — the spec's names, per §7b.2 — and the one-way
  # migration off the old plugin lives at `migrate_from_reporter:*`.
  #
  # Both halves are asserted because rake will not tell you if they collide: a duplicate
  # definition ENHANCES the task and runs both bodies in order, so `rake -T` would show one
  # task with one description and two behaviours. This test is what stops that.
  def test_the_two_importers_are_distinct_and_each_is_where_the_curator_put_it
    assert Rake::Task.task_defined?('reporter_dashboards:migrate_from_reporter:plan')
    assert Rake::Task.task_defined?('reporter_dashboards:migrate_from_reporter:run')
    assert Rake::Task.task_defined?('reporter_dashboards:migrate_from_reporter:status')

    # The migration importer reads the OLD PLUGIN's tables, and its description says so.
    assert_match(/redmine_reporter/,
                 Rake::Task['reporter_dashboards:migrate_from_reporter:plan'].comment)
    # The bundle importer reads a FILE, and its description names the variable that holds
    # one. If the two ever swapped back, this is the assertion that fails.
    assert_match(/RRD_FILE/, Rake::Task['reporter_dashboards:import:plan'].comment)
  end

  # AND EACH TASK HAS EXACTLY ONE BODY. A collision does not raise; it appends. Asserting
  # the ACTION COUNT is the only way to see it — measured at 2 for a duplicated task.
  def test_no_task_has_been_defined_twice
    %w[reporter_dashboards:import:plan reporter_dashboards:import:run
       reporter_dashboards:export:bundle reporter_dashboards:migrate_from_reporter:plan
       reporter_dashboards:migrate_from_reporter:run].each do |name|
      assert_equal 1, Rake::Task[name].actions.length,
                   "#{name} has more than one body, so two features share the name"
    end
  end

  # ------------------------------------------------------------------ they run

  def test_plan_reads_a_file_writes_nothing_and_says_what_it_would_do
    ENV['RRD_FILE'] = write_bundle(entry)
    ENV['RRD_PROJECT'] = @project.identifier

    output = status = nil
    assert_no_difference 'RedmineReporterDashboards::Template.count' do
      output, status = invoke('reporter_dashboards:import:plan')
    end

    assert_equal 0, status, 'a plan that decided cleanly must exit 0'
    assert_match(/PLAN ONLY — nothing was written/, output)
    assert_match(/From a file/, output)
  end

  def test_apply_imports_the_bundle
    ENV['RRD_FILE'] = write_bundle(entry)
    ENV['RRD_PROJECT'] = @project.identifier

    status = nil
    assert_difference 'RedmineReporterDashboards::Template.count', 1 do
      _output, status = invoke('reporter_dashboards:import:run')
    end

    assert_equal 0, status
    assert Template.exists?(project_id: @project.id, name: 'From a file')
  end

  def test_export_writes_a_bundle_that_apply_can_read_back
    Template.create!(project: @project, author: @admin, name: 'Round trip',
                     content: '<p>r</p>', source: 'issues', output: 'combined')
    ENV['RRD_PROJECT'] = @project.identifier
    ENV['RRD_OUT'] = @tmp

    _output, status = invoke('reporter_dashboards:export:bundle')

    assert_equal 0, status
    written = JSON.parse(File.binread(@tmp))
    assert_equal %w[format_version exported_at plugin_version templates], written.keys
    assert_include 'Round trip', written['templates'].map { |t| t['name'] }
  end

  # ------------------------------------------------------------------ operator mistakes

  # A SENTENCE, NOT A STACK TRACE, and exit 2 rather than 1 — "your arguments were wrong"
  # and "a template failed to import" are different outcomes and a script has to be able
  # to tell them apart. `SystemExit` is what `exit` raises, so the status is assertable.
  def test_a_missing_RRD_FILE_is_refused_with_a_sentence_and_exit_2
    ENV['RRD_PROJECT'] = @project.identifier

    _output, status = invoke('reporter_dashboards:import:plan')

    assert_equal 2, status
  end

  def test_a_file_that_is_not_there_is_refused_with_exit_2
    ENV['RRD_FILE'] = File.join(Dir.tmpdir, 'no-such-bundle-rrd.json')
    ENV['RRD_PROJECT'] = @project.identifier

    _output, status = invoke('reporter_dashboards:import:plan')

    assert_equal 2, status
  end

  def test_a_project_that_does_not_exist_is_refused_with_exit_2
    ENV['RRD_FILE'] = write_bundle(entry)
    ENV['RRD_PROJECT'] = 'no-such-project-identifier'

    _output, status = invoke('reporter_dashboards:import:plan')

    assert_equal 2, status
  end

  # EXIT 1 IS THE OTHER OUTCOME: the bundle was read and a template in it failed. This is
  # the distinction the two codes exist for, so both are asserted rather than only one.
  def test_a_bundle_with_a_failing_template_exits_1
    ENV['RRD_FILE'] = write_bundle(entry('page_size' => 'A9'))
    ENV['RRD_PROJECT'] = @project.identifier

    _output, status = invoke('reporter_dashboards:import:run')

    assert_equal 1, status
  end
end
