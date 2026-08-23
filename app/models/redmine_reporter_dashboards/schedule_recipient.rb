# frozen_string_literal: true

module RedmineReporterDashboards
  # One person who receives one schedule's report.
  #
  # --- A REDMINE USER, AND NOTHING ELSE ---
  #
  # There is no `to`, `cc`, `bcc` or `from` on this table, and there is no accessor for one
  # here. `technical-spec.md` calls that "the exfiltration-and-spoofing-relay finding.
  # A security-motivated schema decision", and §7b.5 describes what the base plugin's
  # free-text version actually permits: a report over any issue in the instance, mailed
  # anywhere, with a forged sender.
  #
  # External addresses are not forbidden by this plugin — §7b.5 keeps the capability — but
  # they arrive through an admin setting plus a domain allowlist (FR-61), which is a policy
  # about the installation. They do not arrive as a string somebody typed into a schedule
  # form, because a schedule form is reachable by anyone holding
  # `manage_reporter_dashboards_schedules` in one project.
  class ScheduleRecipient < RedmineReporterDashboards::Compat.base_record
    self.table_name = 'reporter_dashboards_schedule_recipients'

    # `created_at` only — see the migration.
    self.record_timestamps = false

    belongs_to :schedule,
               class_name: 'RedmineReporterDashboards::Schedule',
               foreign_key: 'schedule_id',
               inverse_of: :recipients
    belongs_to :user

    validates :schedule_id, presence: true
    validates :user_id, presence: true
    # The unique index is the enforcement; this is the readable error. Both are needed:
    # the validation gives a form a message, the index survives two concurrent submissions.
    validates :user_id, uniqueness: { scope: :schedule_id }

    # `before_save`, not `before_validation` — see TemplateVersion for the measurement.
    # `save(validate: false)` skips validation callbacks and would hit the NOT NULL.
    before_save :stamp_created_at

    private

    def stamp_created_at
      self.created_at ||= Time.zone.now
    end
  end
end
