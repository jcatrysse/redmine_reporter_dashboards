# frozen_string_literal: true

require 'date'

module RedmineReporterDashboards
  # T-25's date arithmetic, and nothing else.
  #
  # `scheduling/` names neither the Liquid layer nor the render layer — it is upstream of
  # both, in the same sense `charts/` and `assets/` are (findings F-13/F-13b). This file
  # in particular names no layer at all: it takes five values and answers a list of dates.
  module Scheduling
    # WHICH DAYS A SCHEDULE OWES A REPORT.
    #
    # --- WHY THIS IS A PURE FUNCTION AND NOT A METHOD ON `Schedule` ---
    #
    # FR-39's at-most-once guarantee is a database constraint and FR-40's "a missed
    # occurrence is visible and explicitly recoverable" is a policy, but the question
    # underneath both — *given a repeat rule, a start date and the day of the last run,
    # which dates are owed?* — is arithmetic. Arithmetic with a table in front of it is
    # arithmetic nobody can test at the boundaries, and the boundaries are where this is
    # wrong: the 31st of a month that has 30 days, the 29th of February, a schedule that
    # has not run for a year.
    #
    # So it takes dates and answers dates. `spec/scheduling/occurrences_spec.rb` drives
    # every rule across a leap year without a database, a Redmine or a clock.
    #
    # --- `today:` IS REQUIRED, AND THAT IS THE SAME DECISION AS `RenderContext`'s ACTOR ---
    #
    # There is no `Date.today` in this file. CLAUDE.md §6 forbids a fixture relative to the
    # current date because "the corpus changes daily, goes red for the wrong reason, and
    # gets switched off within a week" — and a scheduler is the one component where that
    # temptation is strongest, because its whole subject is what day it is. The caller
    # reads the clock, once, and passes the answer in.
    module Occurrences
      # The five rules the base plugin offered (`report_schedule.rb`, recorded in
      # `docs/plan/reference/source-inventory.md:101`). A closed set: an unknown repeat is
      # an ERROR rather than "never due", because a schedule that silently never fires is
      # the failure mode an operator cannot see. T-22 deliberately left `repeat`
      # unvalidated — "nothing here decides when a schedule is due" — so this is where the
      # vocabulary is defined and `Schedule` will validate against it.
      DAILY     = 'daily'
      WEEKLY    = 'weekly'
      MONTHLY   = 'monthly'
      QUARTERLY = 'quarterly'
      YEARLY    = 'yearly'
      REPEATS = [DAILY, WEEKLY, MONTHLY, QUARTERLY, YEARLY].freeze

      # `technical-spec.md:1214`: "a schedule dormant for a year must not emit 365
      # e-mails". Seven days is a week of missed runs — enough to cover a long weekend of
      # downtime, short enough that nobody's inbox receives a year of history because a
      # cron entry was restored.
      DEFAULT_MAX_CATCHUP_DAYS = 7

      # How far `next_occurrence` will look before answering "no".
      #
      # THE SUFFICIENT VALUE IS 365, and this is 397 for headroom rather than because 397
      # is needed — said plainly because an earlier version of this comment claimed 366 was
      # the bound and that trimming the constant would "silently lose leap years", and both
      # halves were wrong. The gap from `after + 1` to the next occurrence is at most 365
      # days for every rule here: a yearly schedule started on 29 February clamps to the
      # 28th, which is 364 days after 1 March.
      #
      # What the constant is actually for is TERMINATION, not reach. A search that ends is
      # the difference between an empty answer and a rake task that never returns because
      # somebody stored a rule whose `end_date` is in the past. `occurrences_spec.rb` pins
      # the value, so trimming it is a decision somebody takes rather than one that passes.
      DEFAULT_HORIZON_DAYS = 397

      class UnknownRepeat < ArgumentError; end

      class << self
        # Is `date` a day this rule fires on, counting from `start_date`?
        #
        # Phase is taken from `start_date` rather than from the calendar: a weekly schedule
        # started on a Tuesday fires on Tuesdays, not on Mondays, and a monthly one started
        # on the 15th fires on the 15th. That is what an author means by "weekly" and it is
        # what makes `start_date` a setting rather than a formality.
        def due_on?(date, repeat:, start_date:, end_date: nil)
          date = to_date(date)
          start_date = to_date(start_date)
          end_date = end_date && to_date(end_date)

          return false if start_date.nil? || date < start_date
          return false if end_date && date > end_date

          matches?(date, repeat, start_date)
        end

        # THE DATES A RUN OWES, most recent last.
        #
        # `catch_up: false` — the default and what a cron entry gets — answers **at most
        # today**, because FR-40 says "a normal run does not silently backfill". A machine
        # that was off for three days should not, on being switched on, mail three reports
        # to everybody without anyone asking.
        #
        # `catch_up: true` is the explicit recovery FR-40's other half requires, bounded by
        # `max_catchup_days` counted back from `today`. Note what the bound is measured
        # against: the WINDOW, not the number of occurrences. A daily schedule dormant for a
        # year yields seven dates; so does a daily schedule dormant for eight days.
        def due(repeat:, start_date:, today:, end_date: nil, last_run_on: nil,
                catch_up: false, max_catchup_days: DEFAULT_MAX_CATCHUP_DAYS)
          today = to_date(today)
          validate_repeat!(repeat)

          window_start = catch_up ? catchup_floor(today, last_run_on, max_catchup_days) : today

          (window_start..today).select do |date|
            due_on?(date, repeat: repeat, start_date: start_date, end_date: end_date)
          end
        end

        # What a run SKIPPED because the catch-up bound cut it off — the visible half of
        # FR-40. An operator who sees "3 occurrences were missed and are outside the
        # 7-day window" can decide to run them; one who sees nothing cannot.
        #
        # Bounded itself, at `limit`: a schedule dormant for a decade must not turn a
        # diagnostic into 3 650 dates. The count is what matters, and the caller is told
        # when the list was cut.
        def missed_beyond_catchup(repeat:, start_date:, today:, end_date: nil,
                                  last_run_on: nil,
                                  max_catchup_days: DEFAULT_MAX_CATCHUP_DAYS, limit: 50)
          today = to_date(today)
          last_run_on = last_run_on && to_date(last_run_on)
          validate_repeat!(repeat)

          floor = catchup_floor(today, last_run_on, max_catchup_days)
          # Nothing is BEYOND the window when the window already reaches the last run.
          first = last_run_on ? last_run_on + 1 : to_date(start_date)
          return [] if first.nil? || first >= floor

          dates = (first..(floor - 1)).select do |date|
            due_on?(date, repeat: repeat, start_date: start_date, end_date: end_date)
          end

          dates.first(limit)
        end

        # THE NEXT DATE THIS RULE FIRES ON, strictly after `after` — or nil.
        #
        # This is the only forward-looking question in the module, and it exists for one
        # column: `next_run_on`. §7 rule 5 lists it as a forward-compatibility column and
        # `technical-spec.md`'s index `[:enabled, :next_run_on]` is "the runner's own
        # query" — an operator looking at a schedule list wants to know when the next one
        # is without running the enumerator in their head.
        #
        # --- WHY A BOUNDED SCAN AND NOT A FORMULA ---
        #
        # A formula would have to reproduce `month_aligned?`'s clamping in reverse, and the
        # reverse of a clamp is not a function: 28 February is the 1-month step from both
        # 31 January and 28 January, so "which step-count lands here" has no single answer.
        # Stepping forward asks the SAME predicate the runner will ask on the day, so the
        # two can never disagree — which is the property that matters, because a
        # `next_run_on` that says Tuesday while `due_on?` says Wednesday is a lie in the UI
        # that no test of either half alone would catch.
        #
        # Nil means "not within the horizon", which covers a schedule whose `end_date` has
        # passed and one whose `start_date` is years out. A caller writes the nil straight
        # into the column: "no next run" is exactly what an ended schedule should show.
        def next_occurrence(after:, repeat:, start_date:, end_date: nil,
                            horizon_days: DEFAULT_HORIZON_DAYS)
          after = to_date(after)
          start_date = to_date(start_date)
          validate_repeat!(repeat)
          return nil if start_date.nil?

          # From the day after `after`, or from the start date when that is still ahead —
          # so a schedule beginning in 2030 is found rather than scanned past.
          first = [after + 1, start_date].max
          last = first + Integer(horizon_days)
          return nil if end_date && to_date(end_date) < first

          (first..last).find do |date|
            due_on?(date, repeat: repeat, start_date: start_date, end_date: end_date)
          end
        end

        private

        # The earliest date a catch-up run may reach. Two bounds, and the LATER one wins:
        # the configured window, and the day after the last successful run — there is
        # nothing to catch up from before that, and re-emitting it would be the duplicate
        # the unique index exists to refuse.
        def catchup_floor(today, last_run_on, max_catchup_days)
          window = today - Integer(max_catchup_days)
          last_run_on = last_run_on && to_date(last_run_on)
          return window if last_run_on.nil?

          [window, last_run_on + 1].max
        end

        def matches?(date, repeat, start_date)
          case repeat.to_s
          when DAILY     then true
          when WEEKLY    then ((date - start_date).to_i % 7).zero?
          when MONTHLY   then month_aligned?(date, start_date, 1)
          when QUARTERLY then month_aligned?(date, start_date, 3)
          when YEARLY    then month_aligned?(date, start_date, 12)
          else raise UnknownRepeat, unknown_message(repeat)
          end
        end

        # THE CLAMPING CASE, which is the whole reason this is not `date.day ==
        # start_date.day`.
        #
        # A monthly schedule started on the 31st has no 31st in February, April, June,
        # September or November. Skipping those months is one answer and it is the wrong
        # one: "monthly" that fires seven times a year is a bug an author discovers in
        # August. `>>` is Ruby's own month arithmetic and it already clamps — `Date.new(2026,
        # 1, 31) >> 1` is 28 February 2026 — so the rule is "this date is the nth month-step
        # from the start", asked by stepping rather than by comparing day numbers.
        #
        # The same arithmetic answers 29 February yearly: `Date.new(2024, 2, 29) >> 12` is
        # 28 February 2025, so a leap-day schedule fires on the 28th in common years rather
        # than falling silent for three years at a time.
        def month_aligned?(date, start_date, step_months)
          months = ((date.year - start_date.year) * 12) + (date.month - start_date.month)
          return false unless months >= 0 && (months % step_months).zero?

          (start_date >> months) == date
        end

        def validate_repeat!(repeat)
          return if REPEATS.include?(repeat.to_s)

          raise UnknownRepeat, unknown_message(repeat)
        end

        def unknown_message(repeat)
          "#{repeat.inspect} is not a repeat rule this plugin knows. " \
            "Accepted: #{REPEATS.join(', ')}"
        end

        # A Date arrives as itself; a Time or a TimeWithZone answers its own `to_date` in
        # ITS OWN zone; everything else is refused. §7 made these columns `date` rather
        # than `datetime` because the base plugin stored timestamps and compared them as
        # dates, and accepting a String here would put that ambiguity back one layer up —
        # `'2026-03-10'` has no zone, so whose 10 March is it?
        #
        # --- REFUSED BY CLASS, AND THE FIRST VERSION WAS REFUSED BY `respond_to?` ---
        #
        # `raise unless value.respond_to?(:to_date)` reads like a guard and is not one:
        # **ActiveSupport gives `String` a `#to_date`**, so in any booted Redmine — which
        # is every production caller — a String satisfied it and was parsed. The example
        # that says otherwise PASSED IN ISOLATION, where ActiveSupport is not loaded, and
        # failed only in the full DB-less run. Same shape as HANDOVER §1's constant trap:
        # a check whose subject is supplied by another file's require.
        #
        # So the accepted set is named by class. `DateTime < Date`, and
        # `ActiveSupport::TimeWithZone` is not a `Time` — it answers `acts_like_time?`,
        # which is the only portable way to recognise one without naming ActiveSupport
        # from a module that does not otherwise need it.
        def to_date(value)
          return nil if value.nil?
          return value if value.instance_of?(::Date)

          unless value.is_a?(::Date) || value.is_a?(::Time) ||
                 (value.respond_to?(:acts_like_time?) && value.acts_like_time?)
            raise ArgumentError, "#{value.class} is not a date"
          end

          value.to_date
        end
      end
    end
  end
end
