# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)
require 'rake'
require 'stringio'

# T-37 — `rake reporter_dashboards:lint_templates`, THE OTHER HALF OF FR-71'S PARITY.
#
# `technical-spec.md` §9b.1 describes the editor's panel as *"fed by the same linter that
# runs in `rake reporter_dashboards:lint_templates`"*. That sentence named a task that had
# never been written, so the parity it promised had nothing to be parallel to. This file is
# the task's wiring — and the wiring is exactly what no spec can reach: a typo in the
# namespace, a require pointing at a path that moved, or a task that raises on the way in
# all produce a fully green rspec run and a task that does not exist.
#
# `LintReport` itself is covered DB-lessly by `spec/lint_report_spec.rb`, and the equality
# of ITS finding list with the editor's is asserted in
# `test/functional/reporter_dashboards_lint_panel_test.rb`. Between the three files there
# is no gap where a second linter could live.
#
# --- MINITEST TRAP (HANDOVER §1) ---
#
# Test methods defined after a `private` section are silently not run. The `private` here is
# at the very bottom and holds only `capture_task`.
class ReporterDashboardsLintRakeTest < ActiveSupport::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  TASK = 'reporter_dashboards:lint_templates'
  RAKE_FILE = File.expand_path('../../lib/tasks/reporter_dashboards.rake', __dir__)

  Template = RedmineReporterDashboards::Template

  # `SystemExit` is what `exit 1` raises inside an in-process Rake invocation, so the exit
  # code is an assertable value rather than something only a shell can see.
  def setup
    @previous = Rake.application
    @previous_metadata = Rake::TaskManager.record_task_metadata
    Rake.application = Rake::Application.new
    # Descriptions are DISCARDED unless this is on: rake records them only when it is about
    # to show them (`rake -T`), so a `desc` assertion against an in-process load reads nil
    # however correct the task file is.
    Rake::TaskManager.record_task_metadata = true
    Rake::Task.define_task(:environment)
    load RAKE_FILE

    @project = Project.find(1)
    @author = User.find_by!(login: 'jsmith')
    ENV.delete('RRD_PROJECT')
  end

  def teardown
    Rake.application = @previous
    Rake::TaskManager.record_task_metadata = @previous_metadata
    ENV.delete('RRD_PROJECT')
  end

  def create_template(attributes = {})
    Template.create!({ project: @project, author: @author, name: 'Report',
                       content: '<p>clean</p>', source: 'issues',
                       output: 'combined' }.merge(attributes))
  end

  def test_the_task_is_defined_under_the_name_the_spec_uses
    # §9b.1 spells it this way and the editor's panel prints it, so a rename is a
    # documentation change and a locale change as well as a code one.
    assert Rake::Task.task_defined?(TASK), "#{TASK} is not defined by #{RAKE_FILE}"
  end

  def test_the_task_describes_itself_for_rake_dash_t
    description = Rake::Task[TASK].comment

    assert_not_nil description, 'the task has no desc, so it is invisible in `rake -T`'
    assert_match(/lint/i, description)
    assert_match(/writes nothing/i, description)
    assert_match(/exit 1/i, description, 'the description does not say what the exit code means')
  end

  def test_a_clean_installation_reports_clean_and_exits_zero
    create_template(content: '<h1>{{ project.name }}</h1>')

    output = capture_task

    assert_match(/template lint/, output)
    assert_match(/0 error\(s\)/, output)
    assert_match(/every template is clean/, output)
  end

  # THE POSITION IS IN THE OUTPUT, and it is the same spelling the panel prints —
  # `Finding#position`. A report that printed the line while the panel printed line and
  # column would be two vocabularies for one position.
  def test_a_template_with_an_error_is_reported_with_its_position_and_rule
    create_template(name: 'Broken', content: "<p>ok</p>\n<script>  xAxes: []</script>")

    error = assert_raises(SystemExit) { capture_task }

    assert_equal 1, error.status, 'a template with an ERROR must make the task exit 1'
    assert_match(/ERROR/, @output)
    assert_match(/2:11/, @output, 'the finding lost its line:column')
    assert_match(/chartjs2\.scales_axes/, @output)
    assert_match(/Broken/, @output)
  end

  # WARNINGS DO NOT FAIL THE TASK. A non-zero exit that is always non-zero is one nobody
  # reads — the same argument T-25 records for a draft schedule.
  def test_a_template_with_only_a_warning_still_exits_zero
    create_template(content: '<script>beginAtZero: true</script>')

    output = capture_task

    assert_match(/1 warning\(s\)/, output)
    assert_match(/0 error\(s\)/, output)
  end

  # BOTH TEMPLATES CARRY A FINDING, so both would be NAMED in the detail section. A
  # filtering test whose excluded template was clean anyway proves nothing — it is the same
  # vacuous shape the review of T-29 found in a permission fixture.
  def test_rrd_project_limits_the_run_to_one_project
    create_template(name: 'InOne', content: '<p>[page]</p>')
    other = Project.find(2)
    other.enable_module!(:reporter_dashboards_reports)
    Template.create!(project: other, author: @author, name: 'InTwo', content: '<p>[page]</p>',
                     source: 'issues', output: 'combined')

    ENV['RRD_PROJECT'] = other.identifier
    assert_raises(SystemExit) { capture_task }

    assert_match(/1 template\(s\) examined/, @output)
    assert_match(/InTwo/, @output)
    assert_no_match(/InOne/, @output)
  end

  # EXIT 2 FOR A BAD ARGUMENT, which is `export:bundle`'s code for the same thing: a script
  # has to be able to tell "you typed the wrong project" from "a template has an error".
  # It must also NOT fall back to linting everything, which is why the fixture template
  # carries an error: a silent fallback would exit 1 here rather than 2.
  def test_an_unknown_project_exits_two_rather_than_linting_everything
    create_template(content: '<p>[page]</p>')
    ENV['RRD_PROJECT'] = 'no-such-project'

    error = assert_raises(SystemExit) { capture_task }

    assert_equal 2, error.status
    assert_no_match(/template lint/, @output.to_s)
  end

  def test_the_task_writes_nothing_to_the_database
    create_template(content: '<p>[page]</p>')
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
      payload = ActiveSupport::Notifications::Event.new(*args).payload
      next if payload[:cached]
      next if %w[SCHEMA TRANSACTION].include?(payload[:name].to_s)

      statements << payload[:sql].to_s
    end

    assert_raises(SystemExit) { capture_task }

    offenders = statements.reject { |sql| sql.match?(/\A\s*(?:SELECT|SHOW|BEGIN|COMMIT|ROLLBACK)\b/i) }
    assert_equal [], offenders,
                 "a linter must write nothing. Not a read:\n#{offenders.join("\n")}"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  # A TEMPLATE'S BODY IS NEVER PRINTED, only bounded excerpts of the lines that carry a
  # finding. The task runs with a shell, so this is not a privilege boundary — it is that a
  # terminal full of somebody's report template is unreadable and gets pasted into tickets.
  def test_the_task_prints_bounded_excerpts_rather_than_the_body
    secret = "<p>[page]</p>\n<p>#{'S' * 400}</p>"
    create_template(content: secret)

    assert_raises(SystemExit) { capture_task }

    assert_not_include 'S' * 200, @output
  end

  private

  # Rake prints to stdout; the assertions need the text, and a suite that dumps forty lines
  # of report per example is unreadable. `@output` is kept as well as returned so that a
  # test asserting on a task that EXITED can still read what it printed.
  def capture_task
    previous = $stdout
    buffer = StringIO.new
    $stdout = buffer
    Rake::Task[TASK].reenable
    Rake::Task[TASK].invoke
    @output = buffer.string
  ensure
    @output = buffer.string
    $stdout = previous
  end
end
