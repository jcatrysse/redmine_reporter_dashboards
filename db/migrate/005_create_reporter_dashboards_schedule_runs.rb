# frozen_string_literal: true

# T-22 — the run log, and the one database constraint the whole plan names.
#
# --- THE UNIQUE INDEX IS THE SCHEDULER FIX, NOT AN OPTIMISATION ---
#
# `technical-spec.md:1205-1211`: "The runner **claims the occurrence first** by inserting
# the run row; a duplicate insert is caught and skipped." FR-39 states it as a requirement
# on the schema rather than on the code: "A schedule occurrence delivers **at most once**,
# enforced by a **database constraint**, not only by application logic."
#
# So `[schedule_id, occurrence_date]` is UNIQUE, and it is created here with the table
# because §7 rule 6 says so and gives the reason: "an index added in a later migration is
# an index a partially-migrated install does not have, and the scheduler's at-most-once
# guarantee is only as strong as that index."
class CreateReporterDashboardsScheduleRuns < ActiveRecord::Migration[6.1]
  def change
    create_table :reporter_dashboards_schedule_runs do |t|
      t.integer  :schedule_id, null: false
      # `date`, not `datetime`, and for the same reason as the schedule's own dates: an
      # occurrence is a day. A datetime here would make the unique index useless, because
      # two runs a second apart would be two different occurrences.
      t.date     :occurrence_date, null: false

      t.datetime :started_at
      t.datetime :finished_at
      t.string   :status
      t.text     :error
      t.integer  :duration_ms

      t.integer  :recipients_count
      t.integer  :document_count
      # bigint: a run may attach several documents and `integer` tops out at 2 GB, which is
      # a limit nobody would think to test until an install hit it.
      t.bigint   :bytes_total

      # FR-58's correlation id, so a log line, a failure notice and this row can be joined
      # up by a human reading a bug report.
      t.string   :correlation_id
    end

    add_index :reporter_dashboards_schedule_runs, [:schedule_id, :occurrence_date],
              unique: true, name: 'index_rd_runs_on_schedule_and_occurrence'
    add_index :reporter_dashboards_schedule_runs, :correlation_id,
              name: 'index_rd_runs_on_correlation_id'
  end
end
