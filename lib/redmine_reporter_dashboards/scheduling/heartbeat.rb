# frozen_string_literal: true

require_relative 'occurrences'

module RedmineReporterDashboards
  module Scheduling
    # FR-44's second half: "diagnostics warn when it has never run."
    #
    # --- THE FAILURE THIS EXISTS FOR ---
    #
    # A scheduler that needs an external invocation has one failure mode nothing else
    # catches: the cron entry was never added, or was lost in a migration, or the container
    # that ran it stopped being deployed. Every part of the plugin then works perfectly and
    # no report is ever sent. There is no error, no failed run row, no red anything — the
    # schedules simply sit there looking configured. An operator discovers it when somebody
    # asks where last quarter's report went.
    #
    # --- IT DERIVES, RATHER THAN KEEPING A HEARTBEAT ROW ---
    #
    # The obvious implementation is a stored timestamp the runner touches every tick. Two
    # reasons not to: it is state whose only purpose is to observe other state, and the
    # place to put it would be the plugin's settings hash — one row holding a serialized
    # Hash, so every tick would read-modify-write the same row an administrator edits in a
    # form. That is S-7's lost update, reintroduced for a diagnostic.
    #
    # Everything needed is already written. `last_attempted_at` says a tick reached a
    # schedule; `next_run_on` says when one should next reach it. What the derivation
    # cannot do is tell "no tick has run" apart from "no tick had anything to do", so it
    # does not try to: it answers the question an operator actually has, which is **is
    # there work that should have happened and no evidence that it did**.
    module Heartbeat
      # A schedule more than this many days past its `next_run_on` is overdue rather than
      # merely late. One day of slack absorbs a timezone difference between the schedule
      # and the server, and a cron that runs at 23:55 against a schedule whose local day
      # has already turned over.
      OVERDUE_GRACE_DAYS = 1

      Status = Struct.new(:enabled_count, :last_attempt_at, :never_run, :overdue,
                          keyword_init: true) do
        def never_run?
          never_run ? true : false
        end

        def overdue?
          !overdue.empty?
        end

        # True when there is something an operator should look at. Deliberately NOT the
        # same as "no tick has ever run": an installation with no schedules at all is not
        # misconfigured, it is empty, and a diagnostic that cries wolf there is one that
        # gets switched off before the day it matters.
        def warning?
          never_run? || overdue?
        end
      end

      class << self
        # `today:` is required, for the same reason it is required everywhere else in this
        # namespace: the caller reads the clock once (CLAUDE.md §6).
        def status(today:, scope: nil)
          scope ||= ::RedmineReporterDashboards::Schedule.where(enabled: true)
          runnable = scope.where.not(repeat: nil).where.not(start_date: nil)

          Status.new(enabled_count: scope.count,
                     last_attempt_at: scope.maximum(:last_attempted_at),
                     never_run: never_run?(runnable, today),
                     overdue: overdue_ids(runnable, today))
        end

        # Human lines, in the order an operator wants them. English, and deliberately not
        # localised: this reaches a terminal through a rake task, and a rake task's output
        # follows the server's language rather than a user's. The UI half of FR-44 renders
        # the same `Status` through the locale files.
        def warnings(status)
          lines = []
          if status.never_run?
            lines << 'No scheduled report has ever been attempted, and at least one ' \
                     'schedule is already due. The scheduler needs a periodic external ' \
                     'invocation — see the README — and it looks like nothing is calling ' \
                     'it.'
          end
          if status.overdue?
            lines << "#{status.overdue.length} schedule(s) are past the day they should " \
                     "next have run: #{status.overdue.join(', ')}. Either the periodic " \
                     'invocation stopped, or those schedules are failing — check ' \
                     '`last_status` and `last_error`.'
          end
          lines
        end

        private

        # NOT simply "nothing has a `last_attempted_at`". That is also true of a brand-new
        # installation whose first schedule starts next Monday, and warning there would be
        # noise on day one. The claim is narrower and therefore worth reading: something was
        # DUE, and nothing was ever attempted.
        def never_run?(runnable, today)
          return false if runnable.where.not(last_attempted_at: nil).exists?

          runnable.where(start_date: ..today).exists?
        end

        # `next_run_on` is the runner's own forecast, refreshed on every tick that considers
        # the schedule — so a stale one in the past is evidence that no tick has considered
        # it since. The grace day is why this is not simply `< today`.
        def overdue_ids(runnable, today)
          return [] unless ::RedmineReporterDashboards::Schedule.next_run_on_supported?

          runnable.where(next_run_on: ...(today - OVERDUE_GRACE_DAYS))
                  .order(:id).pluck(:id)
        end
      end
    end
  end
end
