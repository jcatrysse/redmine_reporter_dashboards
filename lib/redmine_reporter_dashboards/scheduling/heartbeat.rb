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
    # --- WHICH COLUMN IS THE EVIDENCE, AND THE FIRST VERSION PICKED THE WRONG ONE ---
    #
    # It asked `last_attempted_at IS NULL`, which is not "no tick has run": the runner
    # writes that column only when it CLAIMS an occurrence, and `refresh_next_run_on`
    # deliberately does not touch it because nothing was attempted. So on a perfectly
    # healthy install whose only schedule is monthly, every daily tick printed *"it looks
    # like nothing is calling it"* for up to thirty days, and `schedules:status` exited 1
    # the whole time. An independent review measured it. A diagnostic that is red on a
    # correct installation is one somebody switches off before the day it matters, which is
    # the decay this module's own comment claimed to avoid.
    #
    # `next_run_on` is the right column, because the runner refreshes it on every tick that
    # CONSIDERS a schedule — delivering or not. A runnable, currently-active schedule with
    # no forecast is therefore one no tick has ever looked at. Three conditions, and each
    # of them removes a false positive that was measured rather than imagined:
    #
    #   started and not ended  — an ENDED schedule correctly has no forecast, for ever, so
    #                            without this it warns permanently no matter how often the
    #                            scheduler runs.
    #   nothing attempted      — belt to the above; a schedule that has delivered has
    #                            plainly been reached.
    #   an occurrence exists   — a schedule whose `end_date` arrives before its next
    #                            occurrence has no forecast because there is none to have,
    #                            not because nothing ran. Asked in Ruby, over the handful
    #                            of rows the first two conditions leave.
    module Heartbeat
      # A schedule more than this many days past its `next_run_on` is overdue rather than
      # merely late. One day of slack absorbs a timezone difference between the schedule
      # and the server, and a cron that runs at 23:55 against a schedule whose local day
      # has already turned over.
      OVERDUE_GRACE_DAYS = 1

      # How many candidate rows `never_run?` will ask `Occurrences` about. The SQL narrows
      # to "active, unforecast, never attempted", which on a working install is empty and
      # on a broken one is every schedule — and the answer is the same after ten as after
      # ten thousand, so the scan is bounded rather than complete.
      NEVER_RUN_SAMPLE = 25

      Status = Struct.new(:enabled_count, :last_attempt_at, :never_run, :overdue,
                          :undetermined, keyword_init: true) do
        def never_run?
          never_run ? true : false
        end

        def overdue?
          !overdue.empty?
        end

        # §7 RULE 5's THIRD STATE. An install one minor version behind on schema has no
        # `next_run_on`, so the question cannot be answered — and answering `false` would
        # be the silent green this whole module exists to prevent. Reported as its own
        # thing, which is what CLAUDE.md §7's "a gate you could not check is UNVERIFIED,
        # never PASS" asks of a diagnostic too.
        def undetermined?
          undetermined ? true : false
        end

        # True when there is something an operator should look at. Deliberately NOT the
        # same as "no tick has ever run": an installation with no schedules at all is not
        # misconfigured, it is empty.
        def warning?
          never_run? || overdue? || undetermined?
        end
      end

      class << self
        # `today:` is required, for the same reason it is required everywhere else in this
        # namespace: the caller reads the clock once (CLAUDE.md §6).
        def status(today:, scope: nil)
          scope ||= ::RedmineReporterDashboards::Schedule.where(enabled: true)
          runnable = scope.where.not(repeat: nil)
          forecastable = ::RedmineReporterDashboards::Schedule.next_run_on_supported?

          Status.new(enabled_count: scope.count,
                     last_attempt_at: scope.maximum(:last_attempted_at),
                     never_run: forecastable && never_run?(runnable, today),
                     overdue: forecastable ? overdue_ids(runnable, today) : [],
                     undetermined: !forecastable)
        end

        # Human lines, in the order an operator wants them. English, and deliberately not
        # localised: this reaches a terminal through a rake task, and a rake task's output
        # follows the server's language rather than a user's. The UI half of FR-44 renders
        # the same `Status` through the locale files.
        def warnings(status)
          lines = []
          if status.undetermined?
            lines << 'This database has no `next_run_on` column, so whether the scheduler ' \
                     'is being invoked cannot be determined. That is a schema one version ' \
                     'behind the code — run the plugin migrations.'
          end
          if status.never_run?
            lines << 'At least one schedule is active and has never been reached by a ' \
                     'run. The scheduler needs a periodic external invocation — see the ' \
                     'README — and it looks like nothing is calling it.'
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

        # See the class comment for why this is three conditions rather than one.
        def never_run?(runnable, today)
          candidates = runnable.where(next_run_on: nil, last_attempted_at: nil)
                               .where(start_date: ..today)
                               .where(end_date: nil).or(
                                 runnable.where(next_run_on: nil, last_attempted_at: nil)
                                         .where(start_date: ..today)
                                         .where(end_date: today..)
                               )
                               .order(:id).limit(NEVER_RUN_SAMPLE)

          candidates.any? { |schedule| forecastable?(schedule, today) }
        end

        # Would a tick have written a forecast for this row? If not, the empty column is
        # the correct answer rather than evidence of anything.
        def forecastable?(schedule, today)
          !Occurrences.next_occurrence(after: today,
                                       repeat: schedule.repeat,
                                       start_date: schedule.start_date,
                                       end_date: schedule.end_date).nil?
        rescue Occurrences::UnknownRepeat
          # A rule this version cannot interpret is a failure the runner reports every
          # tick, loudly, on the schedule itself. It is not evidence that nothing ran.
          false
        end

        # `next_run_on` is the runner's own forecast, refreshed on every tick that considers
        # the schedule — so a stale one in the past is evidence that no tick has considered
        # it since. The grace day is why this is not simply `< today`.
        def overdue_ids(runnable, today)
          runnable.where(next_run_on: ...(today - OVERDUE_GRACE_DAYS)).order(:id).pluck(:id)
        end
      end
    end
  end
end
