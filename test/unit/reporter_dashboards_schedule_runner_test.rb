# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# T-25 — the runner, against a real database.
#
# `spec/scheduling/occurrences_spec.rb` proves the arithmetic without a Redmine. NOTHING
# in this file could be proved there, because every claim it makes is about a WRITE: that
# the unique index refuses a second claim, that `update_columns` leaves a column the runner
# did not name alone, that a run row stops saying `running`. A double cannot fail an index.
#
# The delivery is a fake — see `RecordingDelivery` — and that is the design rather than a
# shortcut. `Runner` owns bookkeeping, not rendering: keeping the render behind a port is
# what lets the branches that matter (a raise mid-run, a duplicate claim, an identity that
# was locked last week) be driven at all, none of which a real render would reach.
class ReporterDashboardsScheduleRunnerTest < ActiveSupport::TestCase
  fixtures :projects, :users

  Template = RedmineReporterDashboards::Template
  Schedule = RedmineReporterDashboards::Schedule
  ScheduleRun = RedmineReporterDashboards::ScheduleRun
  ScheduleRecipient = RedmineReporterDashboards::ScheduleRecipient
  Runner = RedmineReporterDashboards::Scheduling::Runner

  # PINNED, never `Date.today` (CLAUDE.md §6). 10 March 2026 is a Tuesday and 11 March is
  # a Wednesday, which is what the timezone example below turns on.
  NOW = Time.utc(2026, 3, 10, 20, 0, 0)
  TODAY = Date.new(2026, 3, 10)

  # The port, recording what it was handed. It answers a `Delivered` because that is the
  # contract; the examples that break the contract do so explicitly.
  class RecordingDelivery
    attr_reader :calls

    def initialize(&behaviour)
      @calls = []
      @behaviour = behaviour
    end

    def call(schedule:, occurrence_date:, actor:, run:)
      @calls << { schedule: schedule, occurrence_date: occurrence_date, actor: actor,
                  run: run }
      return @behaviour.call(schedule, occurrence_date, actor, run) if @behaviour

      Runner::Delivered.new(recipients_count: 3, document_count: 1, bytes_total: 4_096)
    end

    def dates
      @calls.map { |c| c[:occurrence_date] }
    end

    def actors
      @calls.map { |c| c[:actor] }
    end
  end

  # A logger that keeps what it was told, so an example can assert a diagnostic the runner
  # only ever emits to a log — which is the whole of what some guards contribute.
  class RecordingLogger
    attr_reader :infos, :warns

    def initialize(raising: false)
      @infos = []
      @warns = []
      @raising = raising
    end

    def info(line)
      raise Errno::EPIPE, 'the log pipe closed' if @raising

      @infos << line
    end

    def warn(line)
      raise Errno::EPIPE, 'the log pipe closed' if @raising

      @warns << line
    end
  end

  def setup
    @project = Project.find(1)
    @author = User.find(2)
    @template = Template.create!(project: @project, author_id: @author.id, name: 'Weekly')
    @delivery = RecordingDelivery.new
  end

  def build_schedule(attributes = {})
    Schedule.create!({ project: @project, template_id: @template.id,
                       author_id: @author.id, repeat: 'daily',
                       start_date: Date.new(2026, 1, 1) }.merge(attributes))
  end

  def run_now(delivery: @delivery, **options)
    Runner.new(now: NOW, delivery: delivery, **options).call
  end

  # Every statement Rails issued during the block. Used by the S-7 example below, which is
  # about WHICH COLUMNS an UPDATE names — a fact no amount of reading attributes back can
  # establish, because a full-row write and a two-column write leave the same row behind
  # whenever nobody else touched it in between.
  def captured_sql
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      statements << payload[:sql]
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # --- the happy path, and what it writes ------------------------------------------

  def test_a_due_schedule_is_delivered_once_and_recorded
    schedule = build_schedule

    summary = run_now

    assert_equal 1, @delivery.calls.length
    assert_equal [TODAY], @delivery.dates
    assert_equal 1, summary.claimed
    assert_equal 1, summary.succeeded
    assert_equal 0, summary.failed
    assert_equal 0, summary.exit_code

    assert_equal 1, ScheduleRun.where(schedule_id: schedule.id).count
    run = ScheduleRun.find_by(schedule_id: schedule.id)
    assert_equal TODAY, run.occurrence_date
    assert_equal ScheduleRun::STATUS_SUCCESS, run.status
    assert_not_nil run.finished_at
    assert_equal 3, run.recipients_count
    assert_equal 1, run.document_count
    assert_equal 4_096, run.bytes_total
    assert_not_nil run.correlation_id
  end

  def test_success_writes_the_schedules_run_state
    schedule = build_schedule
    schedule.update_columns(consecutive_failures: 4)

    run_now
    schedule.reload

    assert_equal TODAY, schedule.last_run_on
    assert_equal Schedule::STATUS_SUCCESS, schedule.last_status
    assert_nil schedule.last_error
    assert_equal 0, schedule.consecutive_failures, 'a success clears the failure streak'
    assert_equal Date.new(2026, 3, 11), schedule.next_run_on
    assert_not_nil schedule.last_attempted_at
  end

  def test_a_schedule_that_is_not_due_today_delivers_nothing
    build_schedule(repeat: 'weekly', start_date: Date.new(2026, 3, 4)) # Wednesdays

    summary = run_now

    assert_empty @delivery.calls
    assert_equal 0, summary.claimed
    assert_equal 0, ScheduleRun.count
  end

  def test_a_disabled_schedule_is_not_considered
    build_schedule(enabled: false)

    summary = run_now

    assert_equal 0, summary.considered
    assert_empty @delivery.calls
  end

  # --- FR-39: at most once, enforced by the index ------------------------------------

  def test_an_occurrence_already_claimed_is_skipped_and_not_delivered
    schedule = build_schedule
    ScheduleRun.claim(schedule, TODAY, status: ScheduleRun::STATUS_SUCCESS)

    summary = run_now

    assert_empty @delivery.calls, 'a claimed occurrence must not be rendered again'
    assert_equal 1, summary.skipped
    assert_equal 0, summary.claimed
    assert_equal 0, summary.failed, 'the index doing its job is not a failure'
    assert_equal 0, summary.exit_code
  end

  def test_two_runners_over_the_same_tick_deliver_once
    # The concurrency this guards is two cron entries overlapping. Sequential here, which
    # is enough: the second runner's claim goes to the same unique index the second
    # process's would, and `ScheduleRun.claim` is the only door either can use.
    build_schedule

    first = RecordingDelivery.new
    second = RecordingDelivery.new
    run_now(delivery: first)
    run_now(delivery: second)

    assert_equal 1, first.calls.length
    assert_empty second.calls
    assert_equal 1, ScheduleRun.count
  end

  # --- FR-41: one failure does not embargo the rest -----------------------------------

  def test_a_raising_delivery_is_recorded_and_the_next_schedule_still_delivers
    broken = build_schedule
    healthy = build_schedule

    delivery = RecordingDelivery.new do |schedule, _date, _actor, _run|
      raise IOError, 'the printer is on fire' if schedule.id == broken.id

      Runner::Delivered.new(recipients_count: 1, document_count: 1, bytes_total: 10)
    end

    summary = run_now(delivery: delivery)

    assert_equal 2, summary.considered
    assert_equal 1, summary.failed
    assert_equal 1, summary.succeeded
    assert_equal 1, summary.exit_code, 'FR-41: the run exits non-zero'

    assert_equal 1, summary.failures.length
    failure = summary.failures.first
    assert_equal broken.id, failure.schedule_id
    assert_equal TODAY, failure.occurrence_date
    assert_includes failure.message, 'IOError'
    assert_includes failure.message, 'the printer is on fire'

    assert_equal ScheduleRun::STATUS_SUCCESS,
                 ScheduleRun.find_by(schedule_id: healthy.id).status
  end

  def test_a_failed_run_row_stops_saying_running
    # The failure this guards is a rescue that records the summary and forgets the row: an
    # occurrence stuck at `running` can never be retried, because the unique index will
    # refuse every later claim, and it never says why.
    schedule = build_schedule
    delivery = RecordingDelivery.new { raise 'boom' }

    run_now(delivery: delivery)

    assert_equal 1, ScheduleRun.where(schedule_id: schedule.id).count
    run = ScheduleRun.find_by(schedule_id: schedule.id)
    assert_equal ScheduleRun::STATUS_FAILED, run.status
    assert_not_nil run.finished_at
    assert_includes run.error, 'boom'
    assert_not_nil run.correlation_id
  end

  def test_a_failure_increments_the_streak_and_does_not_advance_last_run_on
    # `last_run_on` is the catch-up floor. Advancing it on a failure would move a day that
    # did not deliver out of the window — FR-40's "a missed occurrence is visible" turned
    # into its opposite.
    schedule = build_schedule(last_run_on: Date.new(2026, 3, 1))
    schedule.update_columns(consecutive_failures: 2)
    delivery = RecordingDelivery.new { raise 'boom' }

    run_now(delivery: delivery)
    schedule.reload

    assert_equal Date.new(2026, 3, 1), schedule.last_run_on
    assert_equal Schedule::STATUS_FAILED, schedule.last_status
    assert_equal 3, schedule.consecutive_failures
    assert_includes schedule.last_error, 'boom'
  end

  def test_a_failure_whose_own_recording_fails_still_does_not_embargo_the_rest
    # THE VERSION OF THE OUTER RESCUE THAT LOOKS RIGHT AND IS NOT.
    #
    #   rescue => e
    #     record_failure(...)
    #     write_schedule_state(...)   # <- raises: the row went away, the connection died
    #
    # An exception raised inside a rescue clause is NOT caught by that clause, so it leaves
    # `#call` entirely and every schedule after this one silently does not deliver — FR-41
    # violated by the code written to satisfy it.
    #
    # Both schedules here fail in the outer rescue (an uninterpretable repeat rule) and the
    # recording of both failures is broken. Without the guard the first raise escapes and
    # `considered` stops at 1.
    first = build_schedule
    second = build_schedule
    [first, second].each { |s| s.update_columns(repeat: 'fortnightly') }
    Schedule.any_instance.stubs(:update_columns)
            .raises(ActiveRecord::StatementInvalid, 'the connection went away')

    summary = nil
    assert_nothing_raised { summary = run_now }

    assert_equal 2, summary.considered, 'the second schedule was still reached'
    assert_equal 2, summary.failed
    assert_equal 1, summary.exit_code
  end

  def test_a_logger_that_raises_does_not_stop_the_tick
    # MEASURED BY THE INDEPENDENT REVIEW, and it escaped `#call` outright. `record_failure`
    # runs FIRST in the outer rescue body and does I/O — two log lines, one of them a whole
    # backtrace — and a raise there is a raise inside a rescue clause, which that clause
    # does not catch. `record_failure_state`'s guard did not help: it covers only the second
    # statement, and its own rescue logs too.
    #
    # `Errno::EPIPE` is the realistic shape: a closed log pipe or a full log volume, on the
    # one component in the plugin that runs unattended.
    first = build_schedule
    second = build_schedule
    [first, second].each { |s| s.update_columns(repeat: 'fortnightly') }

    summary = nil
    assert_nothing_raised { summary = run_now(logger: RecordingLogger.new(raising: true)) }

    assert_equal 2, summary.considered, 'the second schedule was still reached'
    assert_equal 2, summary.failed
  end

  def test_a_logger_that_raises_does_not_stop_a_healthy_delivery_either
    # The same hole on the success path, where the log line is `info` rather than `warn`.
    build_schedule

    summary = nil
    assert_nothing_raised { summary = run_now(logger: RecordingLogger.new(raising: true)) }

    assert_equal 1, summary.succeeded
    assert_equal 1, @delivery.calls.length
  end

  def test_a_failure_after_a_successful_delivery_names_the_occurrence_it_belongs_to
    # The report went out. Something in the bookkeeping after it then broke, so the outer
    # rescue records the failure — and it must not record it as belonging to no day and no
    # run, which are the two fields `Failure` carries so an operator is not sent to the
    # wrong place. Found by the independent review.
    schedule = build_schedule
    ScheduleRun.any_instance.stubs(:update_columns)
               .raises(ActiveRecord::StatementInvalid, 'the connection went away')

    summary = run_now

    assert_equal 1, @delivery.calls.length, 'precondition: the delivery did happen'
    assert_equal 1, summary.failed
    failure = summary.failures.first
    assert_equal schedule.id, failure.schedule_id
    assert_equal TODAY, failure.occurrence_date, 'the failure names the day it belongs to'
    assert_not_nil failure.correlation_id, 'and the run it belongs to'
  end

  def test_a_delivery_that_answers_an_error_is_a_failure_without_raising
    schedule = build_schedule
    delivery = RecordingDelivery.new do
      Runner::Delivered.new(error: 'no render engine is registered', recipients_count: 0)
    end

    summary = run_now(delivery: delivery)

    assert_equal 1, summary.failed
    assert_equal ScheduleRun::STATUS_FAILED,
                 ScheduleRun.find_by(schedule_id: schedule.id).status
    assert_includes schedule.reload.last_error, 'no render engine'
  end

  def test_a_delivery_that_answers_nothing_is_a_failure_and_not_a_success
    # The tempting reading of a nil is "there was nothing to do". Recording it as a
    # success would also advance `last_run_on`, removing the day from the catch-up window
    # — a report that never rendered, marked delivered, and now unrecoverable.
    schedule = build_schedule
    delivery = RecordingDelivery.new { nil }

    summary = run_now(delivery: delivery)

    assert_equal 1, summary.failed
    assert_equal 0, summary.succeeded
    assert_nil schedule.reload.last_run_on
    assert_includes schedule.last_error, 'TypeError'
  end

  # --- FR-42: once per occurrence, not once per recipient -----------------------------

  def test_three_recipients_produce_one_render
    schedule = build_schedule
    [2, 3, 4].each { |id| ScheduleRecipient.create!(schedule_id: schedule.id, user_id: id) }

    run_now

    assert_equal 3, schedule.recipients.count
    assert_equal 1, @delivery.calls.length, 'FR-42: one render per occurrence'
  end

  # --- FR-40: catch-up is explicit and bounded ----------------------------------------

  def test_a_plain_tick_does_not_backfill
    build_schedule(last_run_on: Date.new(2026, 3, 1))

    run_now

    assert_equal [TODAY], @delivery.dates
  end

  def test_catch_up_delivers_the_missed_days_bounded_by_the_window
    build_schedule(last_run_on: Date.new(2025, 3, 1))

    summary = run_now(catch_up: true)

    assert_equal 8, @delivery.dates.length, 'the seven-day window, inclusive of today'
    assert_equal Date.new(2026, 3, 3), @delivery.dates.first
    assert_equal TODAY, @delivery.dates.last
    assert_equal 8, summary.claimed
    assert_equal 8, ScheduleRun.count
  end

  def test_catch_up_advances_last_run_on_to_the_final_occurrence
    schedule = build_schedule(last_run_on: Date.new(2026, 3, 7))

    run_now(catch_up: true)

    assert_equal TODAY, schedule.reload.last_run_on
  end

  # --- FR-45: the render identity -----------------------------------------------------

  def test_the_default_identity_is_the_schedule_author
    build_schedule

    run_now

    assert_equal [@author], @delivery.actors
  end

  def test_a_schedule_naming_a_user_renders_as_that_user
    other = User.find(3)
    build_schedule(render_as: Schedule::RENDER_AS_USER, render_as_user_id: other.id)

    run_now

    assert_equal [other], @delivery.actors
  end

  def test_a_render_policy_this_version_does_not_know_is_refused_rather_than_defaulted
    # THE BLOCKER THE INDEPENDENT REVIEW FOUND. The first version was `if render_as ==
    # 'user' … else author end`, so any other value — an unknown policy, a case variant, a
    # value written by a later plugin version — rendered as the AUTHOR and reported success.
    # That is the third fallback the method's own comment says it refuses, committed eleven
    # lines below the comment.
    #
    # `validates … inclusion:` does not close it: `update_columns` and `update_all` bypass
    # validation and this plugin uses both. §7 rule 5 makes it routine rather than exotic —
    # roll the plugin back one minor while keeping the data, and every schedule carrying a
    # newer policy reverts to mailing the author's view.
    other = User.find(3)
    schedule = build_schedule(render_as: Schedule::RENDER_AS_USER, render_as_user_id: other.id)
    schedule.update_columns(render_as: 'recipient')

    summary = run_now

    assert_empty @delivery.calls, 'it must not render as anybody'
    assert_equal 1, summary.failed
    assert_equal 1, summary.exit_code
    assert_includes schedule.reload.last_error, 'recipient'
    assert_includes schedule.last_error, 'cannot honour'
  end

  def test_a_case_variant_of_the_render_policy_is_refused_too
    # `'User'` is not `'user'`. The old code sent it down the author branch silently, which
    # is the worst available answer: the schedule stores an identity and a report goes out
    # as somebody else.
    other = User.find(3)
    schedule = build_schedule(render_as: Schedule::RENDER_AS_USER, render_as_user_id: other.id)
    schedule.update_columns(render_as: 'User')

    summary = run_now

    assert_empty @delivery.calls
    assert_equal 1, summary.failed
  end

  def test_an_explicit_author_policy_still_renders_as_the_author
    # The closed set has to keep the two legitimate arms working, and `nil` is one of them:
    # the column is nullable and an unfinished schedule means "the author".
    build_schedule(render_as: Schedule::RENDER_AS_AUTHOR)

    run_now

    assert_equal [@author], @delivery.actors
  end

  def test_a_locked_render_identity_is_refused_rather_than_rendered
    # A departed employee's schedule that keeps mailing their view of the data is the same
    # leak as a share link nobody revoked. Fixture user 5 is locked.
    locked = User.find(5)
    assert_not locked.active?, 'fixture precondition: user 5 is locked'
    schedule = build_schedule(render_as: Schedule::RENDER_AS_USER,
                              render_as_user_id: locked.id)

    summary = run_now

    assert_empty @delivery.calls
    assert_equal 1, summary.failed
    # NO CLASS NAME PREFIX on the runner's own errors — a UX finding, not a review one.
    # `last_error` is a column an administrator reads on a schedule row, and sixty
    # characters of a fully-qualified `…::IdentityUnavailable:` say less than the sentence
    # after it. A FOREIGN exception keeps its class (see the `IOError` example above),
    # because there the class is the only clue about what broke.
    assert_includes schedule.reload.last_error, 'not an active account'
    assert_not_includes schedule.last_error, 'IdentityUnavailable'
  end

  def test_an_identity_that_no_longer_exists_is_refused
    # `author_id` is NOT NULL and presence-validated, so this state arrives one way only:
    # the user row was deleted after the schedule was saved.
    schedule = build_schedule
    schedule.update_columns(author_id: 999_999)

    summary = run_now

    assert_empty @delivery.calls
    assert_equal 1, summary.failed
    assert_includes schedule.reload.last_error, 'names no user to render as'
  end

  def test_an_anonymous_identity_is_refused_rather_than_rendering_an_empty_report
    # The report an anonymous identity renders contains nothing, is mailed, and is recorded
    # as a success — so this has to be refused rather than rendered.
    #
    # WHICH CLAUSE CATCHES IT, MEASURED. `AnonymousUser` sets `valid_statuses =
    # [STATUS_ANONYMOUS]`, so `active?` is already false and the `logged?` half of the
    # guard is NOT load-bearing here — deleting it leaves this example green. It stays
    # anyway, and this comment says why rather than implying it does work it does not:
    # `active?` catches this case through Redmine's choice of status constant, which is an
    # implementation detail of another project, while `logged?` states the actual rule.
    # Redundancy with a reason, not a second guard.
    schedule = build_schedule
    schedule.update_columns(author_id: User.anonymous.id)

    summary = run_now

    assert_empty @delivery.calls
    assert_equal 1, summary.failed
    assert_includes schedule.reload.last_error, 'not an active account'
  end

  # --- FR-43 for the failures the delivery never sees ---------------------------------

  # The runner's second port. `ScheduledDelivery` implements both; here it only records.
  class RecordingNotifier
    attr_reader :calls

    def initialize
      @calls = []
    end

    def notify_failure(schedule:, occurrence_date:, correlation_id:, message:)
      @calls << { schedule: schedule, occurrence_date: occurrence_date,
                  correlation_id: correlation_id, message: message }
    end
  end

  def test_a_locked_render_identity_notifies_the_owner
    # THE MOST LIKELY SCHEDULED-REPORT FAILURE IN PRODUCTION: an employee leaves and their
    # account is locked. It raises inside the runner BEFORE `delivery.call`, so the owner
    # notice that lives behind the delivery port could never be sent — while the README told
    # the reader they would get one. Found by an independent review, measured at 0 mails.
    schedule = build_schedule(render_as: Schedule::RENDER_AS_USER, render_as_user_id: 5)
    notifier = RecordingNotifier.new

    run_now(notify: notifier)

    assert_equal 1, notifier.calls.length
    assert_equal schedule.id, notifier.calls.first[:schedule].id
    assert_equal TODAY, notifier.calls.first[:occurrence_date]
    assert_includes notifier.calls.first[:message], 'not an active account'
    assert_not_nil notifier.calls.first[:correlation_id]
  end

  def test_an_uninterpretable_repeat_rule_notifies_the_owner_too
    schedule = build_schedule
    schedule.update_columns(repeat: 'fortnightly')
    notifier = RecordingNotifier.new

    run_now(notify: notifier)

    # THE OUTER RESCUE'S notice, and the only example that reaches it. A locked identity
    # raises INSIDE `deliver_claimed`'s begin, so it travels the `fail_occurrence` path;
    # only a schedule that breaks before any occurrence is claimed exercises this one.
    # Measured: deleting `notify_owner` from the outer rescue left the locked-identity
    # example green.
    assert_equal 1, notifier.calls.length
    assert_nil notifier.calls.first[:occurrence_date], 'it failed before reaching a day'
    assert_includes notifier.calls.first[:message], 'UnknownRepeat'
  end

  def test_a_failure_the_delivery_already_reported_is_not_notified_twice
    # `ScheduledDelivery` mails the owner itself and says so with `reported: true`. Without
    # that flag one broken render produces two identical mails, which is how a diagnostic
    # becomes something people filter.
    build_schedule
    notifier = RecordingNotifier.new
    delivery = RecordingDelivery.new do
      Runner::Delivered.new(error: 'the engine is missing', reported: true)
    end

    summary = run_now(delivery: delivery, notify: notifier)

    assert_equal 1, summary.failed
    assert_empty notifier.calls
  end

  def test_a_failure_the_delivery_did_not_report_is_notified
    build_schedule
    notifier = RecordingNotifier.new
    delivery = RecordingDelivery.new { raise IOError, 'the printer is on fire' }

    run_now(delivery: delivery, notify: notifier)

    assert_equal 1, notifier.calls.length
  end

  def test_a_notifier_that_raises_does_not_embargo_the_rest
    # Same rule as everything else in the rescue path: this runs inside a rescue clause on
    # one of the two paths, and a raise there escapes the clause.
    build_schedule
    build_schedule
    exploding = Object.new
    exploding.define_singleton_method(:notify_failure) { |**| raise IOError, 'no mail' }
    delivery = RecordingDelivery.new { raise 'boom' }

    summary = nil
    assert_nothing_raised { summary = run_now(delivery: delivery, notify: exploding) }

    assert_equal 2, summary.considered
    assert_equal 2, summary.failed
  end

  def test_the_notify_port_is_optional
    # `Runner`'s own examples drive it without one; a required second port would make every
    # one of them about wiring.
    build_schedule
    delivery = RecordingDelivery.new { raise 'boom' }

    assert_nothing_raised { run_now(delivery: delivery) }
  end

  # --- S-7: the runner and the form must not overwrite each other ---------------------

  def test_the_run_state_update_names_only_the_run_state_columns
    # S-7, closed by the curator: no `lock_version` on schedules, and **T-25 inherits the
    # obligation** to write run state "with `update_columns` (or an equivalent that does
    # not carry the whole row)".
    #
    # THIS IS THE ONLY EXAMPLE THAT CAN ACTUALLY CHECK THAT, and the behavioural one below
    # is not — measured, not assumed. Rails' partial writes mean `assign_attributes` +
    # `save` also emits an UPDATE naming only the changed columns, so a full-row write and
    # a two-column write leave an IDENTICAL row behind whenever nobody edited it in
    # between. The mutation test that swapped `update_columns` for `save` passed every
    # other example in this file.
    #
    # So the claim is made about the STATEMENT. `updated_at` is the tell: `update_columns`
    # does not touch it and every `save`-shaped write does.
    build_schedule

    statements = captured_sql { run_now }
    updates = statements.select do |sql|
      sql =~ /\AUPDATE/i && sql.include?('reporter_dashboards_schedules')
    end

    assert_equal 1, updates.length, 'one write, at the end of the occurrence'
    %w[enabled updated_at email_subject template_id].each do |column|
      assert_not_includes updates.first, column,
                          "the run-state write must not carry #{column}"
    end
    assert_includes updates.first, 'last_status'
  end

  def test_the_runner_does_not_undo_an_administrators_edit
    # The behavioural companion to the example above: an administrator disables the
    # schedule while the delivery is in flight, and the run state is still recorded without
    # re-enabling it. This is the OUTCOME S-7 is about; the statement-level example is what
    # proves the mechanism that guarantees it.
    schedule = build_schedule
    delivery = RecordingDelivery.new do |s, _date, _actor, _run|
      Schedule.where(id: s.id).update_all(enabled: false, email_subject: 'edited by a human')
      Runner::Delivered.new(recipients_count: 1, document_count: 1, bytes_total: 1)
    end

    run_now(delivery: delivery)
    schedule.reload

    assert_not schedule.enabled, 'the administrator disabled it; the runner must not undo that'
    assert_equal 'edited by a human', schedule.email_subject
    assert_equal Schedule::STATUS_SUCCESS, schedule.last_status, 'and the run state is still written'
  end

  def test_run_state_is_written_even_when_the_schedule_can_no_longer_be_saved
    # A NEGATIVE `consecutive_failures` — a counter corrupted by a hand-edited database or
    # an older version — fails `numericality: { greater_than_or_equal_to: 0 }`, and it stays
    # invalid after the runner's own write, because the runner only ever adds one to it.
    #
    # PICKING THE COLUMN TOOK TWO TRIES AND BOTH FAILURES ARE THE SAME MISTAKE. `last_status`
    # was first: the runner OVERWRITES it, so an `update!` assigns a valid value before
    # validating and the record saves — the mutation test passed. Then `render_as`, which the
    # closed set added later now refuses outright, so the example stopped reaching its own
    # subject. The invalid state has to be one the code under test neither writes clean nor
    # interprets.
    #
    # `update_columns` skips validations, and that is wanted rather than tolerated: a
    # schedule that cannot be SAVED must still be able to record WHY it failed. An `update!`
    # here would raise inside the failure path, so the one row an operator goes to look at
    # would be the one row that never gets written.
    schedule = build_schedule
    schedule.update_columns(consecutive_failures: -5)
    assert_not schedule.reload.valid?, 'precondition: the schedule can no longer be saved'
    delivery = RecordingDelivery.new { raise 'the template is gone' }

    summary = run_now(delivery: delivery)

    assert_equal 1, summary.failed
    assert_equal Schedule::STATUS_FAILED, schedule.reload.last_status
    assert_includes schedule.last_error, 'the template is gone'
  end

  # --- §7 rule 5: a schema one minor behind ------------------------------------------

  # RULE 5, AND WHY THESE TWO EXAMPLES ASSERT ON THE STATEMENT RATHER THAN ON THE ROW.
  #
  # §7 rule 5: "a user who rolls the plugin back one minor version while keeping the schema
  # must not crash". `next_run_on` and `consecutive_failures` are two of the three columns
  # it names, and the direction that actually breaks is the opposite one — new code against
  # an old schema, where naming an absent column in `update_columns` raises. MEASURED, by
  # dropping the column in a throwaway transaction and trying it:
  #
  #   ActiveModel::MissingAttributeError: can't write unknown attribute `next_run_on`
  #
  # On such an install the runner would fail every schedule AND record none of it — a
  # plugin rollback that stops all scheduled reporting.
  #
  # It cannot be reproduced here, and two ways of trying were measured and rejected.
  # Narrowing the SELECT does not do it (the type is still known, so the write succeeds),
  # and actually dropping the column would be DDL inside the test transaction — which
  # PostgreSQL rolls back and MySQL does not, so it would leave the schema wrecked for
  # every test after it on one of the two engines this plugin supports.
  #
  # So the claim is made where the guard actually acts: the emitted UPDATE must not NAME a
  # column the schema does not have. Same technique as the S-7 example above, and the same
  # reason — it is the mechanism, not a downstream consequence of it.
  def pretend_the_columns_are_absent
    Schedule.stubs(:next_run_on_supported?).returns(false)
    Schedule.stubs(:consecutive_failures_supported?).returns(false)
  end

  def schedule_update_from(statements)
    updates = statements.select do |sql|
      sql =~ /\AUPDATE/i && sql.include?('reporter_dashboards_schedules')
    end
    assert_equal 1, updates.length
    updates.first
  end

  def test_the_run_state_update_omits_the_forward_compatibility_columns_when_absent
    pretend_the_columns_are_absent
    schedule = build_schedule

    summary = nil
    statement = schedule_update_from(captured_sql { summary = run_now })

    assert_not_includes statement, 'next_run_on'
    assert_not_includes statement, 'consecutive_failures'
    assert_includes statement, 'last_run_on', 'the columns that DO exist are still written'
    assert_equal 1, summary.succeeded
    assert_equal Schedule::STATUS_SUCCESS, schedule.reload.last_status
  end

  def test_a_failure_is_still_recorded_when_the_forward_compatibility_columns_are_absent
    # The arm that matters more: on such an install a failure must still reach
    # `last_error`. `failure_state` also READS `consecutive_failures` to increment it, which
    # is why `Schedule#consecutive_failures_or_zero` exists rather than a bare attribute.
    pretend_the_columns_are_absent
    schedule = build_schedule
    delivery = RecordingDelivery.new { raise 'boom' }

    summary = nil
    statement = schedule_update_from(captured_sql { summary = run_now(delivery: delivery) })

    assert_not_includes statement, 'next_run_on'
    assert_not_includes statement, 'consecutive_failures'
    assert_equal 1, summary.failed
    assert_equal Schedule::STATUS_FAILED, schedule.reload.last_status
    assert_includes schedule.last_error, 'boom'
  end

  # --- an incomplete schedule is visible, and is not a permanent red ------------------

  def test_an_enabled_schedule_with_no_repeat_rule_is_recorded_as_skipped
    # A non-zero exit that is always non-zero is one nobody reads. A draft is recorded
    # using the `skipped` status T-22 defined and nothing had used, and the tick still
    # exits 0.
    schedule = build_schedule(repeat: nil)

    summary = run_now

    assert_empty @delivery.calls
    assert_equal 1, summary.incomplete
    assert_equal 0, summary.failed
    assert_equal 0, summary.exit_code
    assert_equal Schedule::STATUS_SKIPPED, schedule.reload.last_status
    assert_includes schedule.last_error, 'names no repeat rule'
  end

  def test_an_enabled_schedule_with_no_start_date_is_recorded_as_skipped
    schedule = build_schedule(start_date: nil)

    summary = run_now

    assert_equal 1, summary.incomplete
    assert_equal 0, summary.exit_code
    assert_includes schedule.reload.last_error, 'no start date'
  end

  def test_a_stored_repeat_rule_this_version_cannot_interpret_is_a_failure
    # Different from a draft: the row ASKS for something rather than not asking yet. It
    # arrives from an older plugin version or a hand-edited database, and a schedule that
    # silently never fires is the failure an operator cannot see.
    schedule = build_schedule
    schedule.update_columns(repeat: 'fortnightly')

    summary = run_now

    assert_equal 1, summary.failed
    assert_equal 1, summary.exit_code
    assert_equal 1, summary.failures.length
    assert_nil summary.failures.first.occurrence_date, 'it failed before reaching a day'
    assert_includes schedule.reload.last_error, 'UnknownRepeat'
  end

  # --- the schedule's own timezone ----------------------------------------------------

  def test_the_day_is_the_schedules_own_day_and_not_the_servers
    # 2026-03-10 20:00 UTC is already Wednesday the 11th in Auckland. A Wednesday schedule
    # therefore fires; on the server's Tuesday it would not. Without this the `timezone`
    # column is decoration.
    build_schedule(repeat: 'weekly', start_date: Date.new(2026, 3, 4), timezone: 'Auckland')

    run_now

    assert_equal [Date.new(2026, 3, 11)], @delivery.dates
  end

  def test_an_unknown_timezone_degrades_to_the_server_date_rather_than_failing
    # A schedule that stops delivering because somebody typed `Europe/Brussel` is worse
    # than one that picks the day it would have picked before the column was filled in.
    #
    # THE WARNING IS THE ASSERTION, and the first version of this example did not make it.
    # It checked only the date and the failure count — both of which hold with the entire
    # `if zone.nil?` block deleted, because `Time#in_time_zone(nil)` already returns self.
    # The degradation is Rails' behaviour; the guard's only contribution is telling
    # somebody. Found by the independent review as the fourth vacuous example in this file.
    logger = RecordingLogger.new
    build_schedule(timezone: 'Europe/Brussel')

    summary = run_now(logger: logger)

    assert_equal [TODAY], @delivery.dates
    assert_equal 0, summary.failed
    assert_match(/names timezone "Europe\/Brussel"/, logger.warns.join("\n"))
  end

  def test_the_unknown_timezone_warning_is_said_once_per_schedule_and_not_once_per_question
    # `today_for` is asked several times per schedule — enumerating, and again for
    # `next_run_on` — and once per occurrence-worth of bookkeeping on top. Without the
    # memoisation an eight-day catch-up buries the operator's log in the same line.
    logger = RecordingLogger.new
    build_schedule(timezone: 'Europe/Brussel', last_run_on: Date.new(2026, 3, 1))

    run_now(logger: logger, catch_up: true)

    assert_equal 8, @delivery.dates.length, 'precondition: this really is a catch-up tick'
    assert_equal 1, logger.warns.count { |line| line.include?('Europe/Brussel') }
  end

  # --- bounded error text --------------------------------------------------------------

  def test_a_very_long_error_is_truncated_before_it_reaches_a_text_column
    # `t.text` is 64 KiB on MySQL and unbounded on PostgreSQL. An unbounded backtrace makes
    # the act of recording a failure raise `ValueTooLong` on one engine and not the other —
    # so the schedule is left saying `running` on exactly one of the two.
    schedule = build_schedule
    delivery = RecordingDelivery.new { raise('x' * 50_000) }

    run_now(delivery: delivery)

    assert_operator schedule.reload.last_error.length, :<=, Runner::MAX_ERROR + 60
    assert_includes schedule.last_error, 'truncated'
    assert_operator ScheduleRun.find_by(schedule_id: schedule.id).error.length,
                    :<=, Runner::MAX_ERROR + 60
  end

  # --- the constructor's two refusals ---------------------------------------------------

  def test_a_runner_without_a_clock_is_refused
    # There is no `Time.now` in the runner, for the same reason there is none in
    # `Occurrences`: a scheduler is where reaching for the current date feels most
    # reasonable, and one call would make every example above relative to the day it runs.
    error = assert_raises(ArgumentError) { Runner.new(now: nil, delivery: @delivery) }
    assert_includes error.message, 'clock reading'
  end

  def test_a_runner_without_a_delivery_port_is_refused
    error = assert_raises(ArgumentError) { Runner.new(now: NOW, delivery: nil) }
    assert_includes error.message, 'delivery port'
  end

  def test_the_runner_reads_no_clock_of_its_own
    # The mechanical half. A single `Time.now` here would defeat every pinned date above
    # without failing a single one of them today.
    source = File.read(
      File.expand_path('../../lib/redmine_reporter_dashboards/scheduling/runner.rb',
                       __dir__), encoding: 'UTF-8'
    )
    code = source.lines.reject { |line| line.strip.start_with?('#') }.join

    # `CLOCK_REALTIME` and `DateTime.now` are in the list because the first version of this
    # regex missed them, and `Process.clock_gettime` sits two methods from the wall-clock
    # spelling — HANDOVER §1 names that exact pair as the read this project uses elsewhere.
    # `CLOCK_MONOTONIC` is deliberately absent: it measures a DURATION and cannot tell you
    # what day it is, which is the only thing this rule is about.
    refute_match(/Time\.now|Time\.at|Time\.current|Time\.zone\.now|
                  Date\.today|Date\.current|DateTime\.now|CLOCK_REALTIME/x, code)
  end

  # --- a scoped run ----------------------------------------------------------------------

  def test_a_caller_may_narrow_the_schedules_considered
    build_schedule
    wanted = build_schedule

    summary = run_now(schedules: Schedule.where(id: wanted.id))

    assert_equal 1, summary.considered
    assert_equal [wanted.id], @delivery.calls.map { |c| c[:schedule].id }
  end

  def test_narrowing_does_not_reach_a_disabled_schedule
    # The off switch has to hold for the caller the parameter exists for. The first version
    # made `enabled` the ALTERNATIVE to the injected relation rather than a constraint on
    # it, so a rake task running one schedule by id would mail a report for one an
    # administrator had switched off — and FR-45's test send would inherit the same bypass.
    # `test_a_disabled_schedule_is_not_considered` above gave false confidence: it only ever
    # exercised the default branch. Found by the independent review, with the probe.
    disabled = build_schedule(enabled: false)

    summary = run_now(schedules: Schedule.where(id: disabled.id))

    assert_equal 0, summary.considered
    assert_empty @delivery.calls
  end

  # --- the clock can move backwards, and the index cannot see it ------------------------

  def test_a_local_date_that_moved_backwards_does_not_deliver_a_second_report
    # `occurrence_date` is the schedule's LOCAL date, so a westward timezone edit, an NTP
    # step back across local midnight or a snapshot restore produces a DIFFERENT
    # `occurrence_date` for the same wall-clock day — which the unique index has no way to
    # refuse. Measured by the independent review: Auckland → Los_Angeles between two ticks
    # an hour apart gave run rows for both the 10th and the 11th, and `last_run_on` went
    # backwards from the 11th to the 10th.
    schedule = build_schedule(timezone: 'Auckland')
    run_now
    assert_equal [Date.new(2026, 3, 11)], @delivery.dates
    assert_equal Date.new(2026, 3, 11), schedule.reload.last_run_on

    schedule.update_columns(timezone: 'America/Los_Angeles')
    second = RecordingDelivery.new
    summary = run_now(delivery: second)

    assert_empty second.calls, 'the same day must not be delivered under an earlier date'
    assert_equal 1, summary.skipped
    assert_equal 0, summary.failed, 'a clock that moved is not a broken schedule'
    assert_equal 1, ScheduleRun.where(schedule_id: schedule.id).count
    assert_equal Date.new(2026, 3, 11), schedule.reload.last_run_on,
                 'last_run_on is the catch-up floor and must never walk backwards'
  end

  # --- next_run_on stays true for a schedule with nothing to do today -------------------

  def test_an_ended_schedule_stops_advertising_a_next_run
    # Every other write in this class happens because an occurrence did, so a schedule with
    # NO occurrence today reached none of them and kept whatever `next_run_on` the last
    # successful run left behind — for ever. Found by the independent review.
    schedule = build_schedule(end_date: Date.new(2026, 3, 5))
    schedule.update_columns(next_run_on: Date.new(2026, 3, 5))

    summary = run_now

    assert_empty @delivery.calls
    assert_equal 1, summary.considered
    assert_nil schedule.reload.next_run_on, 'an ended schedule has no next run'
    assert_nil schedule.last_attempted_at, 'and nothing was attempted, so nothing says so'
  end

  def test_a_schedule_not_due_today_still_learns_when_it_next_is
    build_schedule(repeat: 'weekly', start_date: Date.new(2026, 3, 4)) # Wednesdays

    run_now

    assert_equal Date.new(2026, 3, 11), Schedule.order(:id).last.next_run_on
  end

  def test_an_idle_tick_writes_nothing_it_does_not_have_to
    # The refresh is written only when the value CHANGES, so a hundred idle schedules cost
    # a hundred reads and no writes. Without that, every tick rewrites every row.
    schedule = build_schedule(repeat: 'weekly', start_date: Date.new(2026, 3, 4))
    run_now

    statements = captured_sql { run_now(delivery: RecordingDelivery.new) }
    updates = statements.select do |sql|
      sql =~ /\AUPDATE/i && sql.include?('reporter_dashboards_schedules')
    end

    assert_equal Date.new(2026, 3, 11), schedule.reload.next_run_on
    assert_empty updates, 'nothing changed, so nothing is written'
  end

  # --- the run row's timestamps ---------------------------------------------------------

  def test_a_run_row_does_not_claim_it_started_and_finished_at_the_same_instant
    # Migration 005 dropped `created_at`/`updated_at` because "a duplicate pair of
    # timestamps invites a reader to trust the wrong one" — and the first version of the
    # runner wrote exactly one, stamping `started_at` and `finished_at` from the tick's
    # single clock reading. `finished_at` is derived from the monotonic measurement instead,
    # so `now:` stays the only clock input.
    schedule = build_schedule
    delivery = RecordingDelivery.new do
      sleep 0.02
      Runner::Delivered.new(recipients_count: 1, document_count: 1, bytes_total: 1)
    end

    run_now(delivery: delivery)

    run = ScheduleRun.find_by(schedule_id: schedule.id)
    assert_operator run.finished_at, :>, run.started_at
    assert_operator run.duration_ms, :>=, 20
  end

  # --- G6: the tick's cost is linear in the schedule count ------------------------------

  def test_the_query_count_per_schedule_is_constant
    # G6 in the one form that applies to a scheduler. FR-48 bounds queries against ISSUE
    # count, which this class never sees — but a per-schedule cost that is itself a function
    # of the schedule count (a schema question asked per row, an association loaded in a
    # loop) is the same defect one level up, and it is invisible until an installation has
    # a hundred schedules.
    # WARM THE CONNECTION FIRST, and this line is why the example is trustworthy rather
    # than flaky. PostgreSQL's adapter issues catalogue lookups (`SHOW search_path`, a
    # `pg_attribute` query per table) the FIRST time a process touches a table, so a cold
    # measurement carries four statements a warm one does not. The example passed when the
    # file ran alone and failed inside the full suite, which is CLAUDE.md §3's
    # passes-locally-fails-in-CI shape exactly — here caused by test ORDER rather than by
    # the code under test.
    count_queries_for_schedules(1)

    one = count_queries_for_schedules(1)
    two = count_queries_for_schedules(2)
    four = count_queries_for_schedules(4)

    per_schedule = two - one
    assert_operator per_schedule, :>, 0, 'precondition: each schedule costs something'
    assert_operator per_schedule, :<=, 3,
                    'a tick costs an INSERT and two UPDATEs per schedule. This was <= 4 ' \
                    'when the preload that removed the fourth was added in the same diff, ' \
                    'so it could not detect the regression it was written for: measured ' \
                    'with the preload 3, without it 4, both green'
    assert_equal one + (3 * per_schedule), four,
                 "queries are not linear in the schedule count: 1 -> #{one}, " \
                 "2 -> #{two}, 4 -> #{four}"
  end

  def count_queries_for_schedules(count)
    Schedule.delete_all
    ScheduleRun.delete_all
    count.times { build_schedule }
    delivery = RecordingDelivery.new

    statements = captured_sql { Runner.new(now: NOW, delivery: delivery).call }
    assert_equal count, delivery.calls.length, 'precondition: every schedule delivered'
    statements.reject { |sql| sql.start_with?('SAVEPOINT', 'RELEASE SAVEPOINT', 'ROLLBACK') }
              .length
  end
end
