require File.expand_path('../test_helper', __dir__)
require 'rake'
require 'stringio'

# The wiring, and only the wiring.
#
# `Import::Survey` and `Import::PlanReport` are covered by rspec — the survey against a
# real engine, the formatter DB-less. What neither can reach is the four lines in
# `lib/tasks/reporter_dashboards.rake`: a typo in the namespace, a require pointing at a
# path that moved, or a task that raises on the way in. All three produce a fully green
# rspec run and a rake task that does not exist, which is exactly the class of failure
# this project keeps finding late.
#
# So this loads the real .rake file into its own Rake application and invokes the task
# against the test database — which has no reporter tables, so it exercises the "reporter
# was never installed" path end to end, including the exit-0 promise on T-02's Accept
# list.
class ImportPlanRakeTest < ActiveSupport::TestCase
  TASK = 'reporter_dashboards:import:plan'.freeze
  RAKE_FILE = File.expand_path('../../lib/tasks/reporter_dashboards.rake', __dir__).freeze

  def setup
    # Its own Rake application, so this test neither depends on Redmine's task list
    # having been loaded nor leaves a task behind in it.
    @previous = Rake.application
    @previous_metadata = Rake::TaskManager.record_task_metadata
    Rake.application = Rake::Application.new
    # Descriptions are DISCARDED unless this is on: rake only records them when it is
    # about to show them (`rake -T`), so a `desc` assertion against an in-process load
    # reads nil however correct the task file is. Measured, after the first version of
    # this test failed for exactly that reason.
    Rake::TaskManager.record_task_metadata = true
    # :environment is already true here — the test suite booted it — so it is stubbed
    # as a no-op rather than re-running Rails initialisation inside a test.
    Rake::Task.define_task(:environment)
    load RAKE_FILE
  end

  def teardown
    Rake.application = @previous
    Rake::TaskManager.record_task_metadata = @previous_metadata
  end

  def test_the_task_is_defined_under_the_documented_name
    # technical-spec.md §7a and the README both spell it this way. A rename would be a
    # documentation change, so it is asserted rather than assumed.
    assert Rake::Task.task_defined?(TASK), "#{TASK} is not defined by #{RAKE_FILE}"
  end

  def test_the_task_describes_itself_for_rake_dash_t
    description = Rake::Task[TASK].comment

    assert_not_nil description, 'the task has no desc, so it is invisible in `rake -T`'
    assert_match(/read-only|writes nothing/i, description,
                 'the description does not say the task is read-only, which is its main property')
  end

  def test_the_task_runs_and_prints_a_report
    output = capture_task

    assert_match(/import:plan/, output)
    assert_match(/Nothing was written/, output)
    assert_match(/reporter's tables/, output)
  end

  def test_the_task_reports_the_absent_case_without_raising
    # The Redmine test database has no reporter tables, which is the migration-day
    # starting point and the case an operator hits first.
    output = capture_task

    assert_match(/ABSENT/, output)
    assert_match(/not evidence that the/, output,
                 'an empty survey must not read as a clean bill of health')
  end

  def test_the_task_always_reports_what_it_could_not_answer
    # The section that must survive every early return: the fourth R-15 query lives in
    # the request log, and a report that omitted it would imply completeness.
    output = capture_task

    assert_match(/could NOT answer/, output)
    assert_match(/R-15 query 4/, output)
    assert_match(/issue_mails/, output)
  end

  def test_the_task_writes_nothing_to_the_database
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
      payload = ActiveSupport::Notifications::Event.new(*args).payload
      next if payload[:cached]
      next if %w[SCHEMA TRANSACTION].include?(payload[:name].to_s)

      statements << payload[:sql].to_s
    end

    capture_task

    offenders = statements.reject { |sql| sql.match?(/\A\s*(?:SELECT|SHOW|BEGIN|COMMIT|ROLLBACK)\b/i) }
    assert_equal [], offenders,
                 "import:plan must write nothing (INV-6). Not a read:\n#{offenders.join("\n")}"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  private

  # Rake tasks print to stdout; the assertions need the text, and a test suite that
  # dumps 40 lines of report per example is unreadable.
  def capture_task
    previous = $stdout
    $stdout = StringIO.new
    Rake::Task[TASK].reenable
    Rake::Task[TASK].invoke
    $stdout.string
  ensure
    $stdout = previous
  end
end
