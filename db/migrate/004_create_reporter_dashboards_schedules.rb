# frozen_string_literal: true

# T-22 — schedules, with the run state that makes a failure visible.
#
# --- THE DEFECT THIS TABLE FIXES, IN ITS COLUMN TYPES ---
#
# `technical-spec.md`: "Reporter stores these dates as `datetime` while every
# comparison is date-based — fixed." So `start_date`, `end_date`, `last_run_on` and
# `next_run_on` are `date`. A `datetime` compared by date is a bug that only shows up
# either side of midnight in a timezone nobody tested, and the column type is the only
# place it can be fixed once.
class CreateReporterDashboardsSchedules < ActiveRecord::Migration[6.1]
  def change
    create_table :reporter_dashboards_schedules do |t|
      t.integer :project_id
      t.integer :template_id, null: false
      # The schedule owner. `technical-spec.md`: "the schedule owner gets a failure
      # notice carrying the correlation id" — there has to be a column saying who that is.
      t.integer :author_id, null: false

      # The saved query a schedule renders through. `query_type` carries the class name so
      # a `TimeEntryQuery` schedule is expressible (T-31); it is a string rather than a
      # Rails polymorphic pair because the id column is named in §7 and the pair is not.
      t.integer :query_id
      t.string  :query_type

      t.string  :repeat
      t.date    :start_date
      t.date    :end_date

      t.string  :email_subject
      t.text    :email_template

      # --- render identity: TWO columns, because FR-45 asks for a stored identity ---
      #
      # §7 names one column, `render_as`. FR-45 requires the render identity to be
      # "explicit, **stored** and auditable, and a test send uses the **same** identity as
      # the real run". A policy string alone cannot store *which user*, so the policy and
      # the identity are separate: `render_as` is the policy ("author", "user", …) and
      # `render_as_user_id` is the identity it resolved to. Rule 6 means the second column
      # cannot arrive in a later migration, so it arrives here or never.
      t.string  :render_as
      t.integer :render_as_user_id

      t.string  :timezone
      t.boolean :enabled, null: false, default: true

      # --- run state (technical-spec.md) ---
      t.date     :last_run_on
      t.datetime :last_attempted_at
      t.string   :last_status
      t.text     :last_error
      t.integer  :last_duration_ms
      # NOT NULL with a default, because the operator-visible warning
      # (technical-spec.md) counts on this being a number rather than sometimes NULL.
      t.integer  :consecutive_failures, null: false, default: 0
      # One of §7 rule 5's three forward-compatibility columns.
      t.date     :next_run_on

      t.timestamps null: false
    end

    add_index :reporter_dashboards_schedules, :template_id,
              name: 'index_rd_schedules_on_template_id'
    add_index :reporter_dashboards_schedules, :project_id,
              name: 'index_rd_schedules_on_project_id'
    # --- THIS COMMENT SAID SOMETHING FALSE UNTIL T-25 WAS BUILT AND MEASURED ---
    #
    # It read: "The runner's own query: 'which enabled schedules are due?'. Without it the
    # scheduler scans every schedule on every tick, which is the shape FR-48 exists to
    # forbid." T-25's runner does not read `next_run_on` at all, and it does scan — the
    # emitted statement is `WHERE enabled = $1 ORDER BY id`.
    #
    # AND THAT IS DELIBERATE, not an omission. Due-ness is a question about the schedule's
    # OWN local date (`Scheduling::Runner#today_for`), so a SQL prefilter on `next_run_on`
    # would be wrong by a day for any schedule more than a few hours from the server's
    # zone — it would silently skip exactly the schedules the `timezone` column exists for.
    # FR-48 is a bound on query count against ISSUE count, and this is one query against
    # the schedule count, which no installation has a lot of.
    #
    # The index still belongs here rather than in a later migration: §7 rule 6 forbids
    # adding it later, so it exists now or never, and the schedule list UI and any future
    # prefilter (a coarse `next_run_on <= today + 1`, narrowed in Ruby) both want it.
    add_index :reporter_dashboards_schedules, [:enabled, :next_run_on],
              name: 'index_rd_schedules_on_enabled_and_next_run'
  end
end
