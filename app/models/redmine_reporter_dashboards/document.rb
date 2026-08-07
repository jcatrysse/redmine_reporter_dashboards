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

    # `technical-spec.md:1215`: "Persistence is opt-in with a **mandatory TTL** and a purge
    # task. That converts an unmanaged indefinite store into 'off by default, **bounded when
    # on**'." Presence alone delivers the first half and not the second: `expires_at =
    # 9999-12-31` satisfies a presence check, reports `expired?` false for ever, and the
    # purge task never collects it — an immortal row wearing a TTL. Bounded is the word the
    # spec uses, so there is a bound.
    #
    # A year, because the capability this store exists for is a share link (§7b.1), whose own
    # default expiry is proposed at 30 days — so a year is two orders of magnitude of slack
    # for a snapshot, and still a number a purge task will actually reach.
    MAX_RETENTION = 366 * 24 * 60 * 60

    validates :expires_at, presence: true
    validate :expiry_within_the_retention_bound

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

    private

    # Measured from `created_at` on a persisted row and from now on a new one, so that
    # re-saving an old document does not fail for having been created a long time ago.
    def expiry_within_the_retention_bound
      return if expires_at.blank?

      origin = created_at || Time.zone.now
      return if expires_at <= origin + MAX_RETENTION

      errors.add(:expires_at, :less_than_or_equal_to, count: origin + MAX_RETENTION)
    end
  end
end
