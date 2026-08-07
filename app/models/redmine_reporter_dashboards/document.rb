# frozen_string_literal: true

module RedmineReporterDashboards
  # A rendered report, kept.
  #
  # T-22 creates the table and this class; **nothing in T-22 writes a row**. Persistence is
  # opt-in (`technical-spec.md:1213-1217`) and the write path belongs to T-28 (share-link
  # snapshots) and T-30 (failure reports). What is enforced here is the one policy the spec
  # does state: a **mandatory** expiry.
  #
  # `expires_at` is NOT NULL in the schema and validated here as well. The pair is
  # deliberate — the column stops a console session or a future migration creating an
  # immortal row, the validation gives a caller a message instead of a
  # `NotNullViolation`. "Off by default, bounded when on" is only true if the bound cannot
  # be omitted.
  class Document < RedmineReporterDashboards::Compat.base_record
    self.table_name = 'reporter_dashboards_documents'

    belongs_to :template,
               class_name: 'RedmineReporterDashboards::Template',
               foreign_key: 'template_id',
               optional: true
    belongs_to :project, optional: true
    belongs_to :schedule_run,
               class_name: 'RedmineReporterDashboards::ScheduleRun',
               foreign_key: 'schedule_run_id',
               optional: true
    belongs_to :created_by, class_name: 'User', optional: true
    # FR-47: shared output is labelled with the identity it was rendered as. A snapshot
    # makes no visibility decision when it is served, so this column is the only record of
    # whose numbers the document contains.
    belongs_to :rendered_as_user, class_name: 'User', optional: true

    validates :expires_at, presence: true

    # Expired but not yet purged. The purge task's scope, named here so the task and any
    # diagnostic agree on the definition rather than each writing their own `where`.
    scope :expired, ->(now = Time.zone.now) { where(purged_at: nil).where(arel_table[:expires_at].lteq(now)) }
    scope :live,    ->(now = Time.zone.now) { where(purged_at: nil).where(arel_table[:expires_at].gt(now)) }

    def expired?(now = Time.zone.now)
      expires_at.present? && expires_at <= now
    end

    def purged?
      purged_at.present?
    end
  end
end
