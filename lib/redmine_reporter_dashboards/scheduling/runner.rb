# frozen_string_literal: true

require 'securerandom'

require_relative 'occurrences'

module RedmineReporterDashboards
  module Scheduling
    # T-25 — WHAT HAPPENS ON A TICK.
    #
    # `Occurrences` answers *which days are owed*. This answers *what to do about them*,
    # and it is the half where every one of the base plugin's scheduler findings lives:
    # running twice sends twice, a missed day is unknowable, and the first failing
    # template aborts the rest.
    #
    # --- THE FOUR GUARANTEES, AND WHERE EACH ONE IS ---
    #
    #   FR-39  at most once      `ScheduleRun.claim` — a UNIQUE INSERT, not a check.
    #                            `nil` means somebody else holds this occurrence.
    #   FR-40  bounded catch-up  `Occurrences.due(catch_up:)`, and a plain tick asks for
    #                            today only.
    #   FR-41  no embargo        a per-schedule rescue, a guarded rescue around the
    #                            recording of that rescue, and a summary carrying the
    #                            exit code the rake task honours.
    #   FR-42  once per          the render happens ONCE, behind one `delivery.call`, and
    #          occurrence        this class never iterates recipients at all. There is no
    #                            loop here that a recipient list could get into.
    #
    # --- WHY DELIVERY IS A PORT AND NOT A METHOD ---
    #
    # `delivery:` is REQUIRED and has no default. Everything above is a decision about
    # *bookkeeping* — claim, rescue, run state, exit code — and none of it needs to know
    # what a report is. Keeping the render and the mail behind one call means each of the
    # branches this class owns can be driven without a browser, an SMTP server or a
    # template that renders, which is the only way the interesting ones (a raise mid-run,
    # a duplicate claim, an identity that has been locked) get tested at all.
    #
    # It is also the seam T-25's remaining half plugs into. NOTHING DELIVERS YET; when
    # something does, it implements `#call(schedule:, occurrence_date:, actor:, run:)`
    # and answers a `Delivered` — or raises, which is handled identically.
    #
    # --- WHAT THIS CLASS DELIBERATELY DOES NOT DO ---
    #
    # It does not read the clock. `now:` is required, for the same reason `Occurrences`
    # takes `today:` and `RenderContext` takes an actor: a scheduler is the one component
    # where reaching for `Time.now` feels reasonable, and a single one here would make
    # every test of it a fixture relative to the day it runs (CLAUDE.md §6).
    class Runner
      # WHAT A DELIVERY ANSWERS. One shape whether it worked or not, so the bookkeeping
      # below has a single path — the same reason `ReportRun::Outcome` is one struct.
      #
      # The counts are what `reporter_dashboards_schedule_runs` stores, and they come from
      # the deliverer rather than being counted here because this class never sees a
      # document or a recipient.
      # `reported` — the deliverer has ALREADY told the schedule's owner about this failure.
      # Without it the runner's own notice fires as well and one broken render produces two
      # mails, which is how a diagnostic becomes something people filter.
      Delivered = Struct.new(:recipients_count, :document_count, :bytes_total,
                             :correlation_id, :error, :reported, keyword_init: true) do
        def ok?
          error.nil?
        end

        def reported?
          reported ? true : false
        end
      end

      # One thing that went wrong, kept so the caller can print it and exit non-zero.
      # `occurrence_date` is nil when the schedule failed before any occurrence was
      # reached — an unknown repeat rule, say — which is a different failure from a
      # delivery that broke, and a summary that could not tell them apart would send an
      # operator to the wrong place.
      Failure = Struct.new(:schedule_id, :occurrence_date, :correlation_id, :message,
                           keyword_init: true)

      # FR-41's second half: "the run exits non-zero". The rake task reads `exit_code`;
      # nothing decides that twice.
      #
      # `incomplete` is NOT counted as a failure — see `#incomplete_reason`.
      Summary = Struct.new(:considered, :claimed, :skipped, :incomplete, :succeeded,
                           :failed, :failures, keyword_init: true) do
        def ok?
          failed.zero?
        end

        def exit_code
          ok? ? 0 : 1
        end

        def to_s
          "#{considered} schedule(s) considered, #{incomplete} incomplete, " \
            "#{claimed} occurrence(s) claimed, #{skipped} already claimed, " \
            "#{succeeded} delivered, #{failed} failed"
        end
      end

      # `reporter_dashboards_schedules.last_error` and `…_runs.error` are `t.text`, which
      # is 64 KiB on MySQL and unbounded on PostgreSQL. A backtrace from a deep render
      # failure clears 64 KiB without trying, and the failure mode is the worst available:
      # the runner records a failure, and the act of recording it raises
      # `ActiveRecord::ValueTooLong`, so the schedule is left saying `running` on one
      # engine and `failed` on the other. Bounded here, once, for both columns.
      MAX_ERROR = 8_000

      attr_reader :now, :delivery, :catch_up, :max_catchup_days, :logger

      # now               a Time. Read once by the caller — see the class comment.
      # delivery          the port. Required; there is no default and no fallback.
      # schedules         an ActiveRecord relation, or nil for "every enabled schedule".
      #                   Injected so the rake task can run one schedule by id without
      #                   this class growing a second entry point.
      # catch_up          FR-40. False is a plain tick and answers today only.
      def initialize(now:, delivery:, schedules: nil, catch_up: false,
                     max_catchup_days: Occurrences::DEFAULT_MAX_CATCHUP_DAYS, logger: nil,
                     notify: nil)
        raise ArgumentError, 'a scheduler run needs a clock reading (now:)' if now.nil?
        raise ArgumentError, 'a scheduler run needs a delivery port' if delivery.nil?

        @now = now
        @delivery = delivery
        @schedules = schedules
        @catch_up = catch_up ? true : false
        @max_catchup_days = Integer(max_catchup_days)
        @logger = logger
        # THE SECOND HALF OF FR-43, and the first version did not have it.
        #
        # `notify` is told about a failure the DELIVERY never saw. Three of them exist and
        # the most likely one in production is the first: a render identity that has been
        # locked (an employee left), a policy this version cannot honour, and a repeat rule
        # it cannot interpret. All three raise before `delivery.call`, so the owner notice
        # that lives behind the port could never be sent — while the README told the reader
        # they would get one. Measured by an independent review: `MAILS SENT = 0`.
        #
        # Optional, because `Runner`'s own examples drive it with a bare delivery double and
        # a required second port would make every one of them about wiring. Production
        # always passes one: `RunCommand` hands it the same `ScheduledDelivery`.
        @notify = notify
        @today = {}
      end

      def call
        summary = Summary.new(considered: 0, claimed: 0, skipped: 0, incomplete: 0,
                              succeeded: 0, failed: 0, failures: [])

        schedules.each do |schedule|
          summary.considered += 1
          run_schedule(schedule, summary)
        end

        info_line("[scheduler] #{summary}")
        summary
      end

      private

      # `enabled` IS APPLIED TO THE INJECTED RELATION TOO, and the first version of this
      # method did not do that.
      #
      # It read `(@schedules || Schedule.where(enabled: true))`, which makes the off switch
      # the ALTERNATIVE to the injection rather than a constraint on it — so the rake task
      # the parameter exists for ("run one schedule by id") would mail a report for a
      # schedule an administrator had switched off, and FR-45's test send would inherit the
      # same bypass. Measured by the independent review: `considered=1 delivered=1`.
      # `test_a_disabled_schedule_is_not_considered` gave false confidence because it only
      # ever exercised the default branch.
      #
      # If a deliberate force-run is ever wanted it belongs in an argument that says so.
      #
      # `order(:id)` so two runs over the same data visit schedules in the same order. A
      # relation with no order is a relation whose failure ordering changes between
      # PostgreSQL and MySQL, and an operator reading two logs side by side should not have
      # to wonder whether that means anything.
      # `preload` FOR THE IDENTITY, because `render_identity` reads one of the two on every
      # schedule and a lazy `belongs_to` is a query apiece. Measured before adding it: a
      # tick over N schedules issued `4N + 1` statements, of which N were
      # `SELECT users … WHERE id = $1`. It is a small N and FR-48 is about ISSUE count, but
      # a per-row query in the one loop that grows with an installation's size is the same
      # defect one level up, and it costs a word to remove.
      def schedules
        (@schedules || ::RedmineReporterDashboards::Schedule.all)
          .where(enabled: true)
          .preload(:author, :render_as_user)
          .order(:id)
      end

      # FR-41, outer half. This rescue catches what happens BEFORE any occurrence is
      # claimed — a stored repeat rule this version cannot interpret, a database error
      # enumerating one — because a raise here would end the whole tick and every schedule
      # after this one would silently not deliver.
      #
      # `StandardError` and not `Exception`: an Interrupt or a NoMemoryError must still
      # stop the process (CLAUDE.md §5). And this is not a swallowed error — it is logged
      # with its class and backtrace, recorded on the schedule, counted, and it makes the
      # task exit 1.
      def run_schedule(schedule, summary)
        reason = incomplete_reason(schedule)
        return skip_incomplete(schedule, reason, summary) if reason

        # `@current` NAMES THE OCCURRENCE THE RESCUE BELONGS TO.
        #
        # Without it a raise on the SUCCESS path — `finish_run` or the state write blowing
        # up after the mail has gone — is recorded with `occurrence_date: nil` and
        # `correlation_id: nil`, which are exactly the two fields `Failure`'s comment says
        # exist so an operator is not sent to the wrong place. Measured by the independent
        # review: the run row said `success`, the summary said failed, and the failure named
        # no day.
        @current = nil
        occurrences_for(schedule).each do |date|
          run_occurrence(schedule, date, summary)
        end
        refresh_next_run_on(schedule)
      rescue StandardError => e
        record_failure(summary, schedule, @current&.first, @current&.last, e)
        record_failure_state(schedule, describe(e))
        notify_owner(schedule, @current&.first, @current&.last, describe(e))
      ensure
        @current = nil
      end

      # A DRAFT IS NOT A FAILURE, and this distinction is what keeps the exit code useful.
      #
      # `repeat` and `start_date` are both nullable and both validated `allow_nil`, because
      # T-22 decided a half-built schedule is a legitimate row. Enabled and half-built is a
      # misconfiguration an operator should see — but counting it as a FAILURE would make
      # the cron entry exit non-zero on every tick for ever, and a non-zero exit that is
      # always non-zero is one nobody reads. That is the same decay CLAUDE.md §7 describes
      # for a gate made advisory to get to green.
      #
      # So it is recorded, visibly, using the status vocabulary T-22 already defined for
      # exactly this and nothing else has used since: `skipped`.
      #
      # An unknown-but-present repeat rule is the OTHER case and is a real failure — the
      # row asks for something this plugin cannot do, rather than not asking yet.
      def incomplete_reason(schedule)
        return 'it names no repeat rule' if schedule.repeat.to_s.strip.empty?
        return 'it has no start date' if schedule.start_date.nil?

        nil
      end

      def skip_incomplete(schedule, reason, summary)
        summary.incomplete += 1
        message = "this schedule is enabled but not finished: #{reason}"
        info_line("[scheduler] schedule #{schedule.id} skipped — #{message}")

        write_schedule_state(
          schedule,
          last_attempted_at: now,
          last_status: ::RedmineReporterDashboards::Schedule::STATUS_SKIPPED,
          last_error: message,
          # A draft has no next run, and a stale date left in the column would say it has.
          next_run_on: nil
        )
      end

      def occurrences_for(schedule)
        Occurrences.due(repeat: schedule.repeat,
                        start_date: schedule.start_date,
                        end_date: schedule.end_date,
                        last_run_on: schedule.last_run_on,
                        today: today_for(schedule),
                        catch_up: catch_up,
                        max_catchup_days: max_catchup_days)
      end

      # WHICH DAY IT IS *FOR THIS SCHEDULE*.
      #
      # `reporter_dashboards_schedules.timezone` exists and this is the one place it can
      # mean anything: a daily schedule owned by a team in Sydney fires on Sydney's Tuesday,
      # not on the server's. Without this the column is decoration, and a report titled
      # "Monday" arrives covering Sunday for everyone more than a few hours from UTC.
      #
      # An unparseable zone DEGRADES to the server's date with a log line rather than
      # raising. The alternative is a schedule that stops delivering because somebody typed
      # `Europe/Brussel`, and the day it picks is at worst the one it would have picked
      # before the column was filled in. Memoised per schedule so the warning is one line
      # rather than one per question asked about the same row.
      def today_for(schedule)
        @today.fetch(schedule.id) { @today[schedule.id] = resolve_today(schedule) }
      end

      def resolve_today(schedule)
        name = schedule.timezone.to_s.strip
        return now.to_date if name.empty?

        zone = ::ActiveSupport::TimeZone[name]
        if zone.nil?
          warn_line("[scheduler] schedule #{schedule.id} names timezone #{name.inspect}, " \
                    'which this Rails does not know; using the server date')
          return now.to_date
        end

        now.in_time_zone(zone).to_date
      end

      # ONE OCCURRENCE: claim, deliver, record. In that order, and the order is the
      # guarantee — the claim is an INSERT against a unique index, so two runners that
      # overlap produce one delivery and one skip rather than two e-mails.
      def run_occurrence(schedule, date, summary)
        return if regressed?(schedule, date, summary)

        run = claim(schedule, date)

        if run.nil?
          # NOT A FAILURE. The index did its job, which is the entire point of FR-39.
          # It is counted and logged because a tick that skipped everything and a tick that
          # had nothing to do look identical otherwise.
          summary.skipped += 1
          info_line("[scheduler] schedule #{schedule.id} occurrence #{date} is already " \
                    'claimed; skipping')
          return
        end

        summary.claimed += 1
        @current = [date, run.correlation_id]
        deliver_claimed(schedule, date, run, summary)
      end

      # TIME CAN GO BACKWARDS, AND THE UNIQUE INDEX CANNOT SEE IT.
      #
      # `occurrence_date` is the schedule's LOCAL date, so it moves when the local date
      # moves — and the local date can move backwards for reasons that have nothing to do
      # with a duplicate run: an administrator retimezones a schedule westward, NTP steps
      # the clock back across local midnight, a VM is restored from a snapshot. Each of
      # those produces a DIFFERENT `occurrence_date` for the same wall-clock day, which the
      # index has no way to refuse, so recipients get two reports within the hour and
      # `last_run_on` regresses — which also drops the catch-up floor.
      #
      # Measured by the independent review: one schedule retimezoned Auckland → Los_Angeles
      # between two ticks an hour apart produced run rows for both 10 and 11 March, and
      # `last_run_on` went from the 11th back to the 10th.
      #
      # A date at or before `last_run_on` is therefore refused. Nothing legitimate is lost:
      # `catchup_floor` already starts at `last_run_on + 1`, so a genuine catch-up never
      # produces one, and a plain tick only can when the clock has moved. It is counted as
      # a skip and logged as the regression it is, rather than passed to the index in the
      # hope that the dates happen to collide.
      def regressed?(schedule, date, summary)
        last = schedule.last_run_on
        return false if last.nil? || date > last

        summary.skipped += 1
        warn_line("[scheduler] schedule #{schedule.id} produced occurrence #{date}, which " \
                  "is not after its last run (#{last}). The schedule's local date has " \
                  'moved backwards — a timezone edit, or a clock step. Skipping rather ' \
                  'than delivering a second report for the same day under a different date')
        true
      end

      def claim(schedule, date)
        ::RedmineReporterDashboards::ScheduleRun.claim(
          schedule, date,
          started_at: now,
          status: ::RedmineReporterDashboards::ScheduleRun::STATUS_RUNNING,
          correlation_id: SecureRandom.uuid
        )
      end

      # FR-41, inner half — and the reason it is separate from the outer one is the
      # CLAIMED ROW.
      #
      # Once `claim` has returned a row, that occurrence is spoken for: the unique index
      # will refuse it on every later tick. A raise that escaped from here would leave the
      # row at `running` for ever — an occurrence that can never be retried and never says
      # why — so this rescue is not politeness, it is what keeps the at-most-once guarantee
      # from turning into never-at-all.
      #
      # And the run STAYS CLAIMED on failure, on purpose. The delivery may have mailed some
      # recipients before it broke; re-running it would mail them twice, which is the exact
      # defect FR-39 exists to prevent. Recovery is explicit — an operator sees the failed
      # run and its correlation id, and decides.
      def deliver_claimed(schedule, date, run, summary)
        started = monotonic_ms

        result = begin
          actor = render_identity(schedule)
          delivered!(delivery.call(schedule: schedule, occurrence_date: date,
                                   actor: actor, run: run))
        rescue StandardError => e
          Delivered.new(error: describe(e), correlation_id: run.correlation_id)
        end

        duration = elapsed(started)
        if result.ok?
          succeed(schedule, date, run, result, duration, summary)
        else
          fail_occurrence(schedule, date, run, result, duration, summary)
        end
      end

      # A PORT THAT ANSWERS THE WRONG THING IS A FAILURE, not a success.
      #
      # The tempting version of this is `return if value.nil?` and carry on, which records
      # a delivery that did not happen as one that did — the worst outcome available here,
      # because it also advances `last_run_on` and so removes the day from the catch-up
      # window. Raising inside the `begin` above turns a broken deliverer into an ordinary
      # recorded failure with the class name in it.
      def delivered!(value)
        return value if value.is_a?(Delivered)

        raise TypeError,
              "the delivery port answered #{value.class} rather than a " \
              "#{Delivered.name}; a scheduled run is only recorded as delivered when " \
              'the deliverer says so'
      end

      def succeed(schedule, date, run, result, duration, summary)
        finish_run(run, ::RedmineReporterDashboards::ScheduleRun::STATUS_SUCCESS, result,
                   duration)
        write_schedule_state(schedule, success_state(schedule, date, duration))
        summary.succeeded += 1
      end

      def fail_occurrence(schedule, date, run, result, duration, summary)
        finish_run(run, ::RedmineReporterDashboards::ScheduleRun::STATUS_FAILED, result,
                   duration)
        write_schedule_state(schedule, failure_state(schedule, result.error, duration))
        record_failure(summary, schedule, date, run.correlation_id, result.error)
        # Only for what the delivery did NOT report on. A `Delivered` carrying an error
        # came from the deliverer, which has already told the owner; notifying again here
        # would send two mails for one failure.
        notify_owner(schedule, date, run.correlation_id, result.error) unless
          result.reported?
      end

      # FR-43 for the failures the delivery never saw. Guarded for the same reason
      # `record_failure_state` is: this runs inside a rescue clause on one path, and a raise
      # there escapes the clause and embargoes every later schedule.
      def notify_owner(schedule, date, correlation_id, message)
        return if @notify.nil?

        @notify.notify_failure(schedule: schedule, occurrence_date: date,
                               correlation_id: correlation_id, message: message)
      rescue StandardError => e
        warn_line("[scheduler] schedule #{schedule.id} failed AND its owner could not be " \
                  "notified: #{describe(e)}")
      end

      # --- run state -------------------------------------------------------------------
      #
      # S-7, CLOSED by the curator on 2026-08-07, put its obligation on this task in one
      # sentence: **"T-25 inherits the obligation: write run state with `update_columns`
      # (or an equivalent that does not carry the whole row), so the runner and the form
      # cannot overwrite each other's columns."**
      #
      # `reporter_dashboards_schedules` is the only table in the schema with two writers —
      # an administrator editing the form while this runs — and it deliberately has NO
      # `lock_version`, because a runner that raised `StaleObjectError` whenever somebody
      # had the form open would record failures that are not failures.
      #
      # `update_columns` is what makes that safe: it issues an UPDATE naming exactly these
      # columns, so an administrator who disables a schedule mid-tick STAYS disabled. A
      # `save` here would write back every attribute this object loaded, including the
      # `enabled: true` it read a second before the human changed it — silently
      # re-enabling a schedule somebody just switched off, which is the lost update S-7
      # describes.
      #
      # It also skips validations and callbacks, and that is wanted rather than tolerated:
      # a schedule that has become invalid since it was saved — its template was deleted,
      # say — must still be able to record WHY it failed.

      def success_state(schedule, date, duration)
        {
          # PLAIN `date`, AND THE SECOND GUARD THAT WAS HERE HAS BEEN REMOVED.
          #
          # It read `[date, schedule.last_run_on].compact.max`, as belt to `#regressed?`'s
          # braces. Mutation-testing showed it is not belt but dead weight: `#regressed?`
          # returns before the claim for every `date <= last_run_on`, and `update_columns`
          # updates the in-memory attribute, so within a catch-up each occurrence sees the
          # previous one's value. `max` is therefore unreachable — reverting it to `date`
          # left the whole file green. Two mechanisms for one property, one of them
          # provably never running, is the second way of doing something CLAUDE.md §6
          # forbids, and the unreachable one is the one that would rot.
          last_run_on: date,
          last_attempted_at: now,
          last_status: ::RedmineReporterDashboards::Schedule::STATUS_SUCCESS,
          last_error: nil,
          last_duration_ms: duration,
          consecutive_failures: 0,
          next_run_on: next_run_on(schedule)
        }
      end

      # `last_run_on` IS NOT ADVANCED BY A FAILURE, and that is a decision rather than an
      # omission. It is the catch-up floor, so advancing it would move a day that did not
      # deliver out of the window — FR-40's "a missed occurrence is visible" turned into
      # its opposite by a column claiming a failed day ran.
      #
      # The cost is that a persistently failing schedule re-enumerates the same days on
      # every catch-up tick and has each claim refused. That is bounded by
      # `max_catchup_days`, costs one failed INSERT apiece, and each refusal logs the
      # schedule and the date — which is the diagnostic an operator wants anyway.
      def failure_state(schedule, message, duration)
        {
          last_attempted_at: now,
          last_status: ::RedmineReporterDashboards::Schedule::STATUS_FAILED,
          last_error: bounded(message),
          last_duration_ms: duration,
          consecutive_failures: schedule.consecutive_failures_or_zero + 1,
          next_run_on: next_run_on(schedule)
        }
      end

      # §7 RULE 5, WHICH IS WHY THIS IS NOT JUST `schedule.update_columns(columns)`.
      #
      # `next_run_on` and `consecutive_failures` are two of the three columns the rule
      # names: an install one minor version behind on schema does not have them. MEASURED,
      # by dropping the column in a throwaway transaction and trying the write:
      #
      #   ActiveModel::MissingAttributeError: can't write unknown attribute `next_run_on`
      #
      # On such an install the runner would fail every schedule AND fail to record any of
      # it — a plugin rollback that stops all scheduled reporting, which is exactly the
      # support incident rule 5 exists to convert into a degraded feature.
      #
      # `Schedule` already owns both questions (`next_run_on_supported?`,
      # `consecutive_failures_supported?`), so this asks them rather than asking the schema
      # a third way.
      def write_schedule_state(schedule, columns)
        columns = columns.dup
        columns.delete(:next_run_on) unless
          ::RedmineReporterDashboards::Schedule.next_run_on_supported?
        columns.delete(:consecutive_failures) unless
          ::RedmineReporterDashboards::Schedule.consecutive_failures_supported?

        schedule.update_columns(columns)
      end

      # THE LAST LINE OF DEFENCE, and it exists because the obvious version of the outer
      # rescue is not actually safe.
      #
      # `rescue => e; record_failure; write_schedule_state` re-raises out of the RESCUE
      # BODY if the write itself fails — the row was deleted mid-tick, the connection went
      # away — and an exception raised inside a rescue clause is not caught by that same
      # clause. FR-41 would then be violated by the code written to satisfy it: every
      # schedule after this one silently does not deliver.
      #
      # So the write is guarded, and the guard LOGS rather than swallowing. "Failed, and
      # the failure could not be recorded" is a different and worse fact than "failed", and
      # an operator has to be able to see it.
      def record_failure_state(schedule, message)
        write_schedule_state(schedule, failure_state(schedule, message, nil))
      rescue StandardError => e
        warn_line("[scheduler] schedule #{schedule.id} failed AND its run state could " \
                  "not be recorded: #{describe(e)}")
      end

      # A SCHEDULE WITH NO OCCURRENCE TODAY STILL NEEDS ITS `next_run_on` TO BE TRUE.
      #
      # Every other write in this class happens because an occurrence did. A schedule that
      # is not due today — or whose `end_date` has passed — reached none of them, so its
      # `next_run_on` was whatever the last successful run left there: an ENDED schedule
      # kept a past date for ever, which is the opposite of what `Occurrences#next_occurrence`
      # says a caller does with its nil. Found by the independent review, with the probe.
      #
      # Written only when it actually changes, so an idle tick over a hundred schedules
      # issues no UPDATEs rather than a hundred. And `last_attempted_at` is deliberately NOT
      # touched here: nothing was attempted, and a column that says otherwise would make an
      # ended schedule look like it runs daily.
      def refresh_next_run_on(schedule)
        return unless ::RedmineReporterDashboards::Schedule.next_run_on_supported?

        wanted = next_run_on(schedule)
        return if wanted == schedule[:next_run_on]

        schedule.update_columns(next_run_on: wanted)
      end

      def next_run_on(schedule)
        Occurrences.next_occurrence(after: today_for(schedule),
                                    repeat: schedule.repeat,
                                    start_date: schedule.start_date,
                                    end_date: schedule.end_date)
      rescue Occurrences::UnknownRepeat
        # The repeat rule is the reason this schedule is failing in the first place. A
        # second raise from the bookkeeping would replace a recorded failure with an
        # unrecorded one.
        nil
      end

      # `finished_at` IS DERIVED FROM THE MONOTONIC MEASUREMENT, not from a second clock
      # reading — which keeps `now:` the only clock input while still recording elapsed
      # time. The first version wrote `finished_at: now`, so every run row said it started
      # and finished at the same instant, and an eight-occurrence catch-up spanning forty
      # minutes stamped all sixteen timestamps identically. Migration 005 removed
      # `created_at`/`updated_at` on the grounds that "a duplicate pair of timestamps
      # invites a reader to trust the wrong one" — and the runner was writing exactly one.
      def finish_run(run, status, result, duration)
        run.update_columns(
          finished_at: now + (duration / 1000.0),
          status: status,
          duration_ms: duration,
          error: bounded(result.error),
          recipients_count: result.recipients_count,
          document_count: result.document_count,
          bytes_total: result.bytes_total
        )
      end

      # --- render identity (FR-45) -----------------------------------------------------

      # ONE IMPLEMENTATION, ON THE MODEL. This used to be forty lines here, and FR-45's
      # "a test send uses the SAME identity as the real run" is exactly the promise a second
      # copy breaks — the controller's Send-a-test button asks the same question, and two
      # implementations answer differently the first time anybody edits one.
      def render_identity(schedule)
        schedule.render_identity
      end

      # --- bookkeeping -------------------------------------------------------------------

      def record_failure(summary, schedule, date, correlation_id, error)
        message = error.is_a?(::StandardError) ? describe(error) : error.to_s
        summary.failed += 1
        summary.failures << Failure.new(schedule_id: schedule.id, occurrence_date: date,
                                        correlation_id: correlation_id, message: message)

        # The class and the message on the operator's line, the backtrace behind it. FR-58
        # asks that the id in the notice be the id in the log, so the correlation id is on
        # both — and says so explicitly when there is none, because a blank there would
        # read as a missing id rather than as a failure that never reached a run row.
        warn_line("[scheduler] schedule #{schedule.id}" \
                  "#{date ? " occurrence #{date}" : ''} failed " \
                  "[#{correlation_id || 'no run row'}]: #{message}")
        warn_line(error.backtrace.join("\n")) if error.is_a?(::StandardError) && error.backtrace
      end

      # The class name is half the diagnostic. `undefined method 'each' for nil` with no
      # class in front of it has sent more than one person looking in the wrong file.
      #
      # EXCEPT FOR `Schedule::IdentityUnavailable`, which is a UX pass's finding rather than
      # a reviewer's. `last_error` is a column an administrator reads on a schedule row, and
      # a sixty-character fully-qualified class name in front of it says less than the
      # sentence after it. The prefix earns its place for a FOREIGN exception, where the
      # class is the only clue about which layer broke, and earns nothing for one the model
      # raised with a sentence already in it. (The class used to live on this file; T-25's
      # UI moved it to `Schedule`, so a test send and a 06:00 run cannot disagree.)
      def describe(error)
        return error.to_s unless error.is_a?(::StandardError)
        return error.message if
          error.is_a?(::RedmineReporterDashboards::Schedule::IdentityUnavailable)

        "#{error.class}: #{error.message}"
      end

      def bounded(message)
        return nil if message.nil?

        text = message.to_s
        return text if text.length <= MAX_ERROR

        "#{text[0, MAX_ERROR]}… (truncated at #{MAX_ERROR} characters)"
      end

      def elapsed(started)
        (monotonic_ms - started).round
      end

      def monotonic_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
      end

      # A LOGGER THAT RAISES MUST NOT STOP THE SCHEDULER, and this is the one place in the
      # plugin where CLAUDE.md §5's ban on a swallowed error is deliberately not applied.
      # The argument, because a rule set aside without one is a rule nobody keeps:
      #
      # §5 forbids `rescue nil` because it hides a failure FROM SOMEBODY. Here the failure
      # IS the reporting channel — `Errno::EPIPE` on a closed log pipe, `ENOSPC` on a full
      # log volume — so there is nobody left to hide it from, and the two candidate
      # behaviours are "the disk filled and one line was lost" against "the disk filled and
      # every scheduled report in the installation stopped being delivered".
      #
      # It is not a theoretical hazard. The independent review measured it: with a logger
      # whose `warn` raised, the raise escaped `#call` from inside the outer rescue body —
      # an exception raised in a rescue clause is not caught by that clause — and the second
      # schedule never ran. `record_failure_state`'s own guard did not help, because it
      # covers only the second of the two statements in that body, and its own rescue logs
      # too. Six call sites, one choke point: fixing it here fixes all of them.
      #
      # Narrow on purpose. `StandardError` leaves Interrupt and NoMemoryError alone, and the
      # runner's own bookkeeping — the counters, the summary, the database writes — is
      # outside this and still raises where it should.
      def info_line(line)
        logger.info(line) if logger.respond_to?(:info)
      rescue StandardError
        nil
      end

      def warn_line(line)
        logger.warn(line) if logger.respond_to?(:warn)
      rescue StandardError
        nil
      end
    end
  end
end
