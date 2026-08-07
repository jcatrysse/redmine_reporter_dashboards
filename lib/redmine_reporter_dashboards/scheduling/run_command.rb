# frozen_string_literal: true

require_relative 'runner'
require_relative 'heartbeat'
require_relative '../reporting/scheduled_delivery'

module RedmineReporterDashboards
  module Scheduling
    # WHAT `rake reporter_dashboards:schedules:run` ACTUALLY IS.
    #
    # The rake file is four lines of glue, the same shape as `import:plan` and
    # `render:preflight` and for the same reason: the decisions — what the exit code means,
    # what gets printed, which schedules are in scope, when a warning is worth showing — are
    # decisions, and a decision inside a `.rake` file is one no test can reach.
    #
    # --- THE EXIT CODE IS THE INTERFACE ---
    #
    # This runs from cron. Nobody reads its output on a good day, so the exit code is the
    # whole signal and FR-41 says what it must be: non-zero when a schedule failed. Two
    # codes, because a third would need a meaning an operator could act on differently:
    #
    #   0  every schedule the tick considered either delivered or had nothing to do
    #   1  at least one schedule failed — `last_error` on the row says which and why
    #
    # A schedule that is an unfinished DRAFT is not a failure and does not reach 1; see
    # `Runner#incomplete_reason` for why an always-non-zero exit is worse than none.
    class RunCommand
      attr_reader :now, :out

      # now         a Time. Read ONCE, by the caller — the rake task is where the clock
      #             legitimately enters, and it enters in exactly one place.
      # schedule_id run one schedule instead of all of them. Still subject to `enabled`:
      #             `Runner#schedules` applies that to an injected scope too, which is a
      #             defect this project already had and fixed once.
      # delivery    injected only by tests. Production always gets the real one, so there
      #             is no configuration in which the scheduler quietly delivers nothing.
      def initialize(now:, schedule_id: nil, catch_up: false,
                     max_catchup_days: Occurrences::DEFAULT_MAX_CATCHUP_DAYS,
                     delivery: nil, logger: nil, out: $stdout)
        @now = now
        @schedule_id = schedule_id
        @catch_up = catch_up
        @max_catchup_days = max_catchup_days
        @delivery = delivery
        @logger = logger
        @out = out
      end

      # THE HEARTBEAT IS READ BEFORE THE TICK AND PRINTED AFTER IT, and getting that
      # backwards makes the diagnostic useless in the only situation it is read in.
      #
      # An operator runs this by hand precisely because no reports are arriving. The tick
      # then sets `last_attempted_at` and refreshes `next_run_on` — destroying both signals
      # `Heartbeat` derives from — so a status taken afterwards says everything is fine and
      # the one question they came with goes unanswered. Measured: the example that asserts
      # this failed against the obvious ordering.
      def call
        before = Heartbeat.status(today: now.to_date)
        summary = runner.call
        report(summary, before)
        summary.exit_code
      end

      private

      attr_reader :logger

      def runner
        Runner.new(now: now,
                   delivery: @delivery || default_delivery,
                   schedules: scope,
                   catch_up: @catch_up,
                   max_catchup_days: @max_catchup_days,
                   logger: logger)
      end

      def default_delivery
        ::RedmineReporterDashboards::Reporting::ScheduledDelivery.new(logger: logger)
      end

      def scope
        return nil if @schedule_id.nil?

        ::RedmineReporterDashboards::Schedule.where(id: @schedule_id)
      end

      # THE SUMMARY FIRST, THEN THE FAILURES, THEN THE HEARTBEAT.
      #
      # A cron entry's output usually reaches a mailbox only when it is non-empty or
      # non-zero, so this is written to be read by somebody who is already worried. The
      # failures name the schedule, the day and the correlation id — the three things
      # needed to find the run row and the log line (FR-58).
      def report(summary, heartbeat_before)
        line(summary.to_s)

        summary.failures.each do |failure|
          line("  ! schedule #{failure.schedule_id}" \
               "#{failure.occurrence_date ? " (#{failure.occurrence_date})" : ''} " \
               "[#{failure.correlation_id || 'no run row'}] #{failure.message}")
        end

        # FR-44, from the status taken BEFORE the tick — see `#call`.
        Heartbeat.warnings(heartbeat_before).each { |warning| line("  * #{warning}") }
      end

      def line(text)
        out.puts(text) if out.respond_to?(:puts)
      end
    end
  end
end
