# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/scheduling/occurrences'

# T-25 — the date arithmetic, at the boundaries where it is wrong.
#
# Every date in this file is a LITERAL. CLAUDE.md §6 forbids a fixture relative to
# `Date.today`, and a scheduler is where that rule is hardest to keep and most necessary:
# a suite whose scheduler tests pass in March and fail on 29 February is a suite somebody
# switches off. `Occurrences` takes `today:` as an argument so the clock never enters.
#
# 2024 is a leap year and 2025 is not, which is why both appear.
RSpec.describe RedmineReporterDashboards::Scheduling::Occurrences do
  def d(iso)
    Date.parse(iso)
  end

  describe 'daily' do
    it 'is due every day from the start date' do
      %w[2026-03-01 2026-03-02 2026-03-03].each do |date|
        expect(described_class.due_on?(d(date), repeat: 'daily', start_date: d('2026-03-01')))
          .to be(true)
      end
    end

    it 'is not due before the start date' do
      expect(described_class.due_on?(d('2026-02-28'), repeat: 'daily',
                                     start_date: d('2026-03-01'))).to be(false)
    end

    it 'is not due after the end date' do
      expect(described_class.due_on?(d('2026-03-05'), repeat: 'daily',
                                     start_date: d('2026-03-01'),
                                     end_date: d('2026-03-04'))).to be(false)
    end
  end

  describe 'weekly' do
    # PHASE COMES FROM THE START DATE, not from the calendar week. An author who starts a
    # schedule on a Tuesday means Tuesdays.
    it 'fires on the start date`s weekday and no other' do
      start = d('2026-03-03') # a Tuesday

      expect(described_class.due_on?(d('2026-03-10'), repeat: 'weekly', start_date: start)).to be(true)
      expect(described_class.due_on?(d('2026-03-17'), repeat: 'weekly', start_date: start)).to be(true)
      expect(described_class.due_on?(d('2026-03-09'), repeat: 'weekly', start_date: start)).to be(false)
      expect(described_class.due_on?(d('2026-03-11'), repeat: 'weekly', start_date: start)).to be(false)
    end
  end

  describe 'monthly, and the clamping that is the whole reason this is not a day-number check' do
    let(:start) { d('2026-01-31') }

    it 'fires on the same day-of-month where the month has one' do
      expect(described_class.due_on?(d('2026-03-31'), repeat: 'monthly', start_date: start)).to be(true)
      expect(described_class.due_on?(d('2026-05-31'), repeat: 'monthly', start_date: start)).to be(true)
    end

    # A "monthly" schedule that fires seven times a year is a defect an author discovers
    # in August. February has no 31st, so the occurrence is the last day it does have.
    it 'CLAMPS to the last day of a short month rather than skipping it' do
      expect(described_class.due_on?(d('2026-02-28'), repeat: 'monthly', start_date: start)).to be(true)
      expect(described_class.due_on?(d('2026-04-30'), repeat: 'monthly', start_date: start)).to be(true)
    end

    it 'does not also fire on the 28th of a month that HAS a 31st' do
      # The clamp must be a consequence of the month being short, not an extra occurrence.
      expect(described_class.due_on?(d('2026-03-28'), repeat: 'monthly', start_date: start)).to be(false)
    end

    it 'clamps to 29 February in a leap year and 28 in a common one' do
      expect(described_class.due_on?(d('2024-02-29'), repeat: 'monthly',
                                     start_date: d('2024-01-31'))).to be(true)
      expect(described_class.due_on?(d('2025-02-28'), repeat: 'monthly',
                                     start_date: d('2025-01-31'))).to be(true)
    end
  end

  describe 'quarterly' do
    let(:start) { d('2026-01-15') }

    it 'fires every third month from the start' do
      expect(described_class.due_on?(d('2026-04-15'), repeat: 'quarterly', start_date: start)).to be(true)
      expect(described_class.due_on?(d('2026-07-15'), repeat: 'quarterly', start_date: start)).to be(true)
      expect(described_class.due_on?(d('2027-01-15'), repeat: 'quarterly', start_date: start)).to be(true)
    end

    it 'does not fire in the months between' do
      expect(described_class.due_on?(d('2026-02-15'), repeat: 'quarterly', start_date: start)).to be(false)
      expect(described_class.due_on?(d('2026-03-15'), repeat: 'quarterly', start_date: start)).to be(false)
    end
  end

  describe 'yearly' do
    it 'fires on the anniversary' do
      expect(described_class.due_on?(d('2027-06-09'), repeat: 'yearly',
                                     start_date: d('2026-06-09'))).to be(true)
    end

    # A leap-day schedule that falls silent for three years at a time is the same defect
    # as the monthly clamp, one scale up.
    it 'clamps a 29 February schedule to the 28th in common years' do
      expect(described_class.due_on?(d('2025-02-28'), repeat: 'yearly',
                                     start_date: d('2024-02-29'))).to be(true)
      expect(described_class.due_on?(d('2028-02-29'), repeat: 'yearly',
                                     start_date: d('2024-02-29'))).to be(true)
    end
  end

  describe '#due — what a plain run owes' do
    # FR-40: "a normal run does not silently backfill". A machine that was off for three
    # days must not, on being switched on, mail three reports to everybody.
    it 'answers TODAY only, even when days were missed' do
      dates = described_class.due(repeat: 'daily', start_date: d('2026-03-01'),
                                  today: d('2026-03-10'), last_run_on: d('2026-03-05'))

      expect(dates).to eq([d('2026-03-10')])
    end

    it 'answers nothing when today is not an occurrence' do
      dates = described_class.due(repeat: 'weekly', start_date: d('2026-03-03'),
                                  today: d('2026-03-04'))

      expect(dates).to be_empty
    end

    it 'answers nothing after the end date' do
      dates = described_class.due(repeat: 'daily', start_date: d('2026-03-01'),
                                  end_date: d('2026-03-04'), today: d('2026-03-05'))

      expect(dates).to be_empty
    end
  end

  describe '#due — catch-up, which is explicit and bounded' do
    it 'includes the missed days back to the day after the last run' do
      dates = described_class.due(repeat: 'daily', start_date: d('2026-03-01'),
                                  today: d('2026-03-10'), last_run_on: d('2026-03-07'),
                                  catch_up: true)

      expect(dates).to eq([d('2026-03-08'), d('2026-03-09'), d('2026-03-10')])
    end

    it 'never re-emits the day that already ran' do
      # The unique index would refuse it anyway; emitting it would turn every catch-up run
      # into a log full of refused claims.
      dates = described_class.due(repeat: 'daily', start_date: d('2026-03-01'),
                                  today: d('2026-03-10'), last_run_on: d('2026-03-09'),
                                  catch_up: true)

      expect(dates).to eq([d('2026-03-10')])
      expect(dates).not_to include(d('2026-03-09'))
    end

    # `technical-spec.md:1214` in one example: "a schedule dormant for a year must not
    # emit 365 e-mails".
    it 'is bounded by the window, not by how long the schedule slept' do
      dates = described_class.due(repeat: 'daily', start_date: d('2025-01-01'),
                                  today: d('2026-03-10'), last_run_on: d('2025-03-10'),
                                  catch_up: true)

      expect(dates.length).to eq(8) # the seven-day window, inclusive of today
      expect(dates.first).to eq(d('2026-03-03'))
      expect(dates.last).to eq(d('2026-03-10'))
    end

    it 'honours a max_catchup_days an operator narrowed' do
      dates = described_class.due(repeat: 'daily', start_date: d('2025-01-01'),
                                  today: d('2026-03-10'), last_run_on: d('2025-03-10'),
                                  catch_up: true, max_catchup_days: 2)

      expect(dates).to eq([d('2026-03-08'), d('2026-03-09'), d('2026-03-10')])
    end

    it 'catches up a schedule that has NEVER run, still bounded' do
      dates = described_class.due(repeat: 'daily', start_date: d('2020-01-01'),
                                  today: d('2026-03-10'), catch_up: true)

      expect(dates.length).to eq(8)
    end
  end

  describe '#missed_beyond_catchup — the visible half of FR-40' do
    it 'names the occurrences the window cut off' do
      missed = described_class.missed_beyond_catchup(
        repeat: 'daily', start_date: d('2026-03-01'), today: d('2026-03-10'),
        last_run_on: d('2026-03-01')
      )

      expect(missed).to eq([d('2026-03-02')])
    end

    it 'is empty when the window already reaches the last run' do
      missed = described_class.missed_beyond_catchup(
        repeat: 'daily', start_date: d('2026-03-01'), today: d('2026-03-10'),
        last_run_on: d('2026-03-08')
      )

      expect(missed).to be_empty
    end

    it 'is bounded, so a decade of dormancy is not a diagnostic of 3 650 dates' do
      missed = described_class.missed_beyond_catchup(
        repeat: 'daily', start_date: d('2016-01-01'), today: d('2026-03-10'),
        last_run_on: d('2016-01-01'), limit: 5
      )

      expect(missed.length).to eq(5)
    end
  end

  describe '#next_occurrence — the only forward-looking question, and `next_run_on`s only source' do
    it 'answers the next day the rule fires on, not today' do
      # Strictly AFTER. A `next_run_on` that keeps pointing at the day just delivered is
      # the shape that makes an operator think the scheduler is stuck.
      nxt = described_class.next_occurrence(after: d('2026-03-10'), repeat: 'daily',
                                            start_date: d('2026-03-01'))

      expect(nxt).to eq(d('2026-03-11'))
    end

    it 'skips forward to the rule`s own phase' do
      nxt = described_class.next_occurrence(after: d('2026-03-10'), repeat: 'weekly',
                                            start_date: d('2026-03-03')) # a Tuesday

      expect(nxt).to eq(d('2026-03-17'))
    end

    # THE PROPERTY THAT MATTERS: it asks `due_on?`, so the two can never disagree. A
    # `next_run_on` saying Tuesday while the runner fires on Wednesday is a lie in the UI
    # that no test of either half alone would catch — so the clamp is asserted through
    # BOTH doors on the same date.
    it 'agrees with due_on? on the clamped month' do
      nxt = described_class.next_occurrence(after: d('2026-01-31'), repeat: 'monthly',
                                            start_date: d('2026-01-31'))

      expect(nxt).to eq(d('2026-02-28'))
      expect(described_class.due_on?(nxt, repeat: 'monthly',
                                     start_date: d('2026-01-31'))).to be(true)
    end

    it 'finds a start date that is still years away rather than scanning past it' do
      nxt = described_class.next_occurrence(after: d('2026-03-10'), repeat: 'yearly',
                                            start_date: d('2030-06-01'))

      expect(nxt).to eq(d('2030-06-01'))
    end

    it 'answers nil for a schedule whose end date has passed' do
      # Which is what an ended schedule should show: no next run, rather than a date it
      # will never reach.
      nxt = described_class.next_occurrence(after: d('2026-03-10'), repeat: 'daily',
                                            start_date: d('2026-01-01'),
                                            end_date: d('2026-03-05'))

      expect(nxt).to be_nil
    end

    it 'answers nil on the last day rather than pointing one day past the end' do
      nxt = described_class.next_occurrence(after: d('2026-03-05'), repeat: 'daily',
                                            start_date: d('2026-01-01'),
                                            end_date: d('2026-03-05'))

      expect(nxt).to be_nil
    end

    it 'clears the widest gap the rules can produce — a leap-day yearly, 364 days' do
      nxt = described_class.next_occurrence(after: d('2024-03-01'), repeat: 'yearly',
                                            start_date: d('2024-02-29'))

      expect(nxt).to eq(d('2025-02-28'))
    end

    it 'pins the horizon, because the example above does not' do
      # THIS EXAMPLE EXISTS BECAUSE THE ONE ABOVE USED TO CLAIM IT. Its comment said it
      # stopped anybody trimming the constant to a round 365 "and silently losing leap
      # years". Measured: at 365 and at 363 the whole file stays green, and 365 is in fact
      # sufficient. So the constant is pinned here on purpose, with the argument in the
      # message rather than in prose nothing checks.
      expect(described_class::DEFAULT_HORIZON_DAYS).to eq(397),
                                                       '365 is the sufficient bound (a leap-day yearly is 364 days out); ' \
                                                       '397 is deliberate headroom. Changing it is a decision — take it here.'
    end

    it 'terminates on a rule that has no next occurrence at all' do
      # The property the "is bounded" title used to promise and never exercised: a rule the
      # scan can never satisfy has to come back, not run to the end of time.
      nxt = described_class.next_occurrence(after: d('2026-03-10'), repeat: 'yearly',
                                            start_date: d('2020-01-01'),
                                            end_date: d('2026-06-01'))

      expect(nxt).to be_nil
    end

    it 'answers nil when the horizon is too short to reach the next occurrence' do
      nxt = described_class.next_occurrence(after: d('2026-03-10'), repeat: 'yearly',
                                            start_date: d('2026-01-01'), horizon_days: 30)

      expect(nxt).to be_nil
    end

    it 'refuses an unknown rule here too' do
      expect do
        described_class.next_occurrence(after: d('2026-03-10'), repeat: 'fortnightly',
                                        start_date: d('2026-03-01'))
      end.to raise_error(described_class::UnknownRepeat)
    end
  end

  describe 'an unknown repeat rule' do
    # A schedule that silently never fires is the failure an operator cannot see. T-22
    # deliberately left `repeat` unvalidated and left the vocabulary to this file, so an
    # unknown value has to be loud HERE or it is loud nowhere.
    it 'raises rather than answering "never due"' do
      expect do
        described_class.due(repeat: 'fortnightly', start_date: d('2026-03-01'),
                            today: d('2026-03-10'))
      end.to raise_error(described_class::UnknownRepeat, /fortnightly/)
    end

    it 'names what it does accept' do
      expect do
        described_class.due(repeat: 'hourly', start_date: d('2026-03-01'),
                            today: d('2026-03-10'))
      end.to raise_error(described_class::UnknownRepeat,
                         /daily, weekly, monthly, quarterly, yearly/)
    end

    it 'refuses one through `due_on?` too, not only through `due`' do
      expect do
        described_class.due_on?(d('2026-03-10'), repeat: 'never', start_date: d('2026-03-01'))
      end.to raise_error(described_class::UnknownRepeat)
    end
  end

  describe 'the clock never enters this module' do
    it 'names no Date.today, Time.now or Date.current anywhere in its source' do
      # The mechanical half of "the caller reads the clock". A scheduler is the one place
      # where reaching for the current date feels reasonable, and a single `Date.today`
      # here would make every example above a fixture relative to the day it runs.
      source = File.read(
        File.expand_path('../../lib/redmine_reporter_dashboards/scheduling/occurrences.rb',
                         __dir__), encoding: 'UTF-8'
      )
      code = source.lines.reject { |line| line.strip.start_with?('#') }.join

      expect(code).not_to match(/Date\.today|Time\.now|Date\.current|Time\.current/)
    end
  end

  describe 'what it accepts as a date' do
    it 'takes a Time and reads its own date' do
      expect(described_class.due_on?(Time.new(2026, 3, 10, 23, 0, 0), repeat: 'daily',
                                     start_date: d('2026-03-01'))).to be(true)
    end

    it 'refuses a String rather than parsing one' do
      # §7 made these columns `date` rather than `datetime` because the base plugin stored
      # timestamps and compared them as dates. Accepting a string here would put the same
      # ambiguity back one layer up.
      expect do
        described_class.due_on?('2026-03-10', repeat: 'daily', start_date: d('2026-03-01'))
      end.to raise_error(ArgumentError, /not a date/)
    end
  end
end
