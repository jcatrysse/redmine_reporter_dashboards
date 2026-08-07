# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-25 — the rake entry point and FR-44's "has this ever actually run?" diagnostic.
#
# The rake file itself is glue and has no test, deliberately: everything it could get wrong
# is in `RunCommand` and `Heartbeat`, which are ordinary classes. What the rake task owns is
# ONE line — the clock read — and this file asserts that it is the only one on the path.
class ReporterDashboardsScheduleCommandTest < ActiveSupport::TestCase
  fixtures :projects, :users

  Template = RedmineReporterDashboards::Template
  Schedule = RedmineReporterDashboards::Schedule
  ScheduleRun = RedmineReporterDashboards::ScheduleRun
  RunCommand = RedmineReporterDashboards::Scheduling::RunCommand
  Heartbeat = RedmineReporterDashboards::Scheduling::Heartbeat
  Delivered = RedmineReporterDashboards::Scheduling::Runner::Delivered

  NOW = Time.utc(2026, 3, 10, 20, 0, 0)
  TODAY = Date.new(2026, 3, 10)

  class StubDelivery
    def initialize(&behaviour)
      @behaviour = behaviour
    end

    def call(schedule:, occurrence_date:, actor:, run:)
      return @behaviour.call(schedule) if @behaviour

      Delivered.new(recipients_count: 1, document_count: 1, bytes_total: 10)
    end
  end

  def setup
    @project = Project.find(1)
    @author = User.find(2)
    @template = Template.create!(project: @project, author_id: @author.id, name: 'Weekly')
    @out = StringIO.new
  end

  def build_schedule(attributes = {})
    Schedule.create!({ project: @project, template_id: @template.id,
                       author_id: @author.id, repeat: 'daily',
                       start_date: Date.new(2026, 1, 1) }.merge(attributes))
  end

  def run_command(**options)
    RunCommand.new(now: NOW, out: @out, delivery: StubDelivery.new, **options).call
  end

  # --- the exit code is the interface --------------------------------------------------

  def test_a_clean_tick_exits_zero
    build_schedule

    assert_equal 0, run_command
    assert_match(/1 schedule\(s\) considered/, @out.string)
  end

  def test_a_failing_schedule_exits_one
    # FR-41: "one failing schedule does not prevent later schedules from delivering; the
    # run exits non-zero." This is the second half, which is the half cron reads.
    build_schedule

    code = RunCommand.new(now: NOW, out: @out,
                          delivery: StubDelivery.new { raise IOError, 'the relay is down' })
                     .call

    assert_equal 1, code
  end

  def test_the_failure_line_names_the_schedule_the_day_and_the_correlation_id
    # The three things needed to find the run row and the log line (FR-58). A cron mail
    # that says only "1 failed" sends an operator to grep for they-know-not-what.
    schedule = build_schedule

    RunCommand.new(now: NOW, out: @out,
                   delivery: StubDelivery.new { raise IOError, 'the relay is down' }).call

    assert_match(/schedule #{schedule.id}/, @out.string)
    assert_match(/2026-03-10/, @out.string)
    assert_match(/the relay is down/, @out.string)
    correlation_id = ScheduleRun.find_by(schedule_id: schedule.id).correlation_id
    assert_includes @out.string, correlation_id
  end

  def test_a_draft_schedule_does_not_make_the_tick_exit_non_zero
    # An exit code that is always non-zero is one nobody reads.
    build_schedule(repeat: nil)

    assert_equal 0, run_command
    assert_match(/1 incomplete/, @out.string)
  end

  # --- narrowing to one schedule ---------------------------------------------------------

  def test_a_single_schedule_can_be_run_by_id
    build_schedule
    wanted = build_schedule

    run_command(schedule_id: wanted.id)

    assert_match(/1 schedule\(s\) considered/, @out.string)
    assert_equal 1, ScheduleRun.where(schedule_id: wanted.id).count
    assert_equal 0, ScheduleRun.where.not(schedule_id: wanted.id).count
  end

  def test_running_one_schedule_by_id_still_respects_the_off_switch
    # The rake task takes an id from the environment, so this is the path an operator uses
    # by hand — and the one where "but I disabled that" has to keep being true.
    disabled = build_schedule(enabled: false)

    run_command(schedule_id: disabled.id)

    assert_equal 0, ScheduleRun.count
    assert_match(/0 schedule\(s\) considered/, @out.string)
  end

  def test_catch_up_is_off_unless_asked_for
    build_schedule(last_run_on: Date.new(2026, 3, 1))

    run_command

    assert_equal [TODAY], ScheduleRun.order(:occurrence_date).pluck(:occurrence_date)
  end

  def test_catch_up_can_be_asked_for
    build_schedule(last_run_on: Date.new(2026, 3, 5))

    run_command(catch_up: true)

    assert_equal 5, ScheduleRun.count
  end

  # --- FR-44: the operator contract -------------------------------------------------------

  def test_the_scheduler_reads_the_clock_in_exactly_one_place
    # The whole namespace takes `today:`/`now:` as an argument, so the clock enters the
    # system once — in the rake file. If a second read appears, a tick can straddle
    # midnight and disagree with itself about which day it is claiming.
    root = File.expand_path('../../lib/redmine_reporter_dashboards', __dir__)
    sources = Dir[File.join(root, 'scheduling', '*.rb')] +
              [File.join(root, 'reporting', 'scheduled_delivery.rb')]

    sources.each do |path|
      code = File.read(path, encoding: 'UTF-8').lines
                 .reject { |line| line.strip.start_with?('#') }.join
      assert_no_match(/Time\.now|Time\.zone\.now|Date\.today|Date\.current|Time\.current/,
                      code, "#{File.basename(path)} reads a clock of its own")
    end

    rake = File.read(File.expand_path('../../lib/tasks/reporter_dashboards.rake', __dir__),
                     encoding: 'UTF-8')
    assert_equal 2, rake.scan(/Time\.zone\.now/).length,
                 'one read for the tick and one for the status task; a third means a ' \
                 'decision about what day it is moved out of a testable class'
  end

  def test_a_fresh_installation_with_no_schedules_warns_about_nothing
    # A diagnostic that cries wolf on day one is one that is switched off before the day it
    # matters.
    status = Heartbeat.status(today: TODAY)

    assert_equal 0, status.enabled_count
    assert_not status.warning?
    assert_empty Heartbeat.warnings(status)
  end

  def test_a_schedule_that_is_due_and_has_never_been_attempted_warns
    # THE FAILURE FR-44 EXISTS FOR: the cron entry was never added, so everything works and
    # nothing is ever sent. No error, no failed run, no red anything.
    build_schedule(start_date: Date.new(2026, 1, 1))

    status = Heartbeat.status(today: TODAY)

    assert status.never_run?
    assert status.warning?
    assert_match(/has ever been attempted/, Heartbeat.warnings(status).join)
  end

  def test_a_schedule_that_only_starts_next_month_does_not_warn
    # Nothing was due, so nothing missing is evidence of nothing. This is the distinction
    # between "no tick has run" and "no tick had anything to do", and it is why the check
    # is not simply `last_attempted_at IS NULL`.
    build_schedule(start_date: Date.new(2026, 4, 1))

    status = Heartbeat.status(today: TODAY)

    assert_not status.never_run?
    assert_not status.warning?
  end

  def test_a_tick_clears_the_never_run_warning
    build_schedule

    run_command
    status = Heartbeat.status(today: TODAY)

    assert_not status.never_run?
    assert_equal NOW.to_i, status.last_attempt_at.to_i
  end

  def test_a_schedule_whose_forecast_has_passed_is_reported_overdue
    # `next_run_on` is refreshed on every tick that considers the schedule, so one left in
    # the past is evidence that no tick has considered it since.
    schedule = build_schedule
    schedule.update_columns(last_attempted_at: Time.utc(2026, 1, 1),
                            next_run_on: Date.new(2026, 2, 1))

    status = Heartbeat.status(today: TODAY)

    assert_equal [schedule.id], status.overdue
    assert status.warning?
    assert_match(/past the day they should next have run/, Heartbeat.warnings(status).join)
  end

  def test_yesterdays_forecast_is_within_the_grace_day
    # At the limit and one past it. One day of slack absorbs a schedule whose local day has
    # already turned over, and a cron that runs at 23:55.
    schedule = build_schedule
    schedule.update_columns(last_attempted_at: NOW, next_run_on: TODAY - 1)
    assert_empty Heartbeat.status(today: TODAY).overdue

    schedule.update_columns(next_run_on: TODAY - 2)
    assert_equal [schedule.id], Heartbeat.status(today: TODAY).overdue
  end

  def test_a_draft_schedule_is_never_reported_overdue
    # It has no repeat rule, so it has no day it should have run on. Reporting it would be
    # a warning nobody can clear except by finishing a schedule they may have parked
    # deliberately.
    schedule = build_schedule(repeat: nil)
    schedule.update_columns(next_run_on: Date.new(2026, 1, 1))

    assert_empty Heartbeat.status(today: TODAY).overdue
  end

  def test_a_hand_run_tick_still_reports_that_the_scheduler_was_not_being_invoked
    # THE CASE THE WARNING IS ACTUALLY READ IN, and the one that fixed the ordering.
    #
    # An operator runs this by hand precisely because no reports are arriving. The tick
    # then sets `last_attempted_at` AND refreshes `next_run_on` — both of the signals
    # `Heartbeat` derives from — so a status taken afterwards says all is well and the
    # question they came with goes unanswered. This example failed against that ordering,
    # which is why `RunCommand` now reads the heartbeat before the tick and prints it after.
    schedule = build_schedule
    schedule.update_columns(next_run_on: Date.new(2026, 2, 1))

    run_command

    assert_match(/past the day they should next have run/, @out.string)
    assert_nil schedule.reload.next_run_on.then { |d| d < TODAY ? d : nil },
               'and the tick did repair the forecast it just reported on'
  end
end
