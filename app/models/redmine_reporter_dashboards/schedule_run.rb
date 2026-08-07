# frozen_string_literal: true

module RedmineReporterDashboards
  # One occurrence of one schedule.
  #
  # --- THE CLAIM, AND WHY IT IS AN INSERT RATHER THAN A CHECK ---
  #
  # `technical-spec.md:1205-1207`: "The runner **claims the occurrence first** by inserting
  # the run row; a duplicate insert is caught and skipped." FR-39 puts the guarantee on the
  # database rather than on the code: "**enforced by a database constraint, not only by
  # application logic**."
  #
  # `claim` below is that insert. It is here rather than in T-25's runner because the
  # guarantee belongs to the schema, and a second runner (a test send, a catch-up task, a
  # cron that overlapped itself) must go through the same door. What T-25 owns is when to
  # call it and what to do with `nil`.
  #
  # Note what it does NOT do: it never asks "does a run exist for this date?" first. Two
  # processes both asking get two `false`s and both proceed — the check-then-act race is
  # exactly the defect the unique index removes, and reintroducing it in Ruby would undo
  # the fix while looking careful.
  class ScheduleRun < RedmineReporterDashboards::Compat.base_record
    self.table_name = 'reporter_dashboards_schedule_runs'

    # No `updated_at`/`created_at` on this table: `started_at` and `finished_at` say more,
    # and a duplicate pair of timestamps invites a reader to trust the wrong one.
    self.record_timestamps = false

    STATUS_RUNNING = 'running'
    STATUS_SUCCESS = 'success'
    STATUS_FAILED  = 'failed'
    STATUS_SKIPPED = 'skipped'
    STATUSES = [STATUS_RUNNING, STATUS_SUCCESS, STATUS_FAILED, STATUS_SKIPPED].freeze

    belongs_to :schedule,
               class_name: 'RedmineReporterDashboards::Schedule',
               foreign_key: 'schedule_id',
               inverse_of: :runs

    validates :schedule_id, presence: true
    validates :occurrence_date, presence: true
    validates :status, inclusion: { in: STATUSES }, allow_nil: true

    # Claims `occurrence_date` for `schedule`, returning the new row — or `nil` when
    # another process already holds it.
    #
    # --- WHY `requires_new: true`, WHICH IS THE WHOLE CORRECTNESS OF THIS METHOD ---
    #
    # MEASURED, and the first version of this method was wrong: on PostgreSQL a statement
    # that raises inside a transaction puts that transaction into a failed state, and every
    # later statement in it raises `PG::InFailedSqlTransaction` — including the ones the
    # caller wanted to run after being told "somebody else has this occurrence".
    #
    # Without the savepoint the smoke run died on the NEXT line after a duplicate claim,
    # which in T-25's runner would mean "a schedule that was already claimed takes the
    # whole catch-up pass down with it" — a per-schedule rescue (technical-spec.md:1209)
    # that cannot actually continue. `requires_new: true` issues a SAVEPOINT when there is
    # already a transaction, so the duplicate rolls back exactly the failed INSERT.
    #
    # --- WHY ONLY `RecordNotUnique` IS RESCUED ---
    #
    # It is the ANSWER, not an error: the index did its job. Anything else — a dead
    # connection, a missing column, a NOT NULL violation — propagates, because a runner
    # that read "the database is broken" as "already claimed" would silently stop sending
    # every report in the installation and report success. CLAUDE.md §5 forbids
    # `rescue Exception` and `rescue nil` for exactly this shape of reason.
    #
    # And note what is NOT here: no `exists?` check before the insert. Two processes both
    # asking get two `false`s and both proceed — the check-then-act race is the defect the
    # unique index removes, and reintroducing it in Ruby would undo the fix while looking
    # careful.
    def self.claim(schedule, occurrence_date, attributes = {})
      schedule_id = schedule.respond_to?(:id) ? schedule.id : schedule

      transaction(requires_new: true) do
        create!(attributes.merge(schedule_id: schedule_id, occurrence_date: occurrence_date))
      end
    rescue ::ActiveRecord::RecordNotUnique
      nil
    end
  end
end
