# frozen_string_literal: true

module RedmineReporterDashboards
  # A rendered report, kept.
  #
  # T-22 created the table and this class and **wrote no row**. Persistence is opt-in
  # (`technical-spec.md:1220-1223`), and the write path is **T-28's, and it now exists**:
  # `Reporting::Snapshot` renders a report once as a named identity and freezes it here, so
  # that a share link serves bytes rather than making a visibility decision at request time
  # (FR-52). T-30's failure documents are still not persisted through this class.
  #
  # Read `Reporting::Snapshot` before changing anything about `attachment` below: TWO
  # measurements against core shape it, and neither is guessable from this file.
  #
  # Line numbers in this comment were REPOINTED in T-28 — the T-22 originals
  # (`:1203`, `:1213-1217`, `:1215`) had drifted onto §7b.4's scheduling paragraphs and
  # cited text that says nothing about persistence.
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

    # T-28 — THE BYTES, AND THE LINK IS DELIBERATELY WRITTEN IN BOTH DIRECTIONS.
    #
    # `attachment_id` is migration 007's own pointer and §7 rule 6 means it cannot be
    # replaced by a different column later, so it stays the pointer. What it does NOT do is
    # keep the row alive: `Attachment.prune` destroys every attachment with no CONTAINER
    # after a day (`app/models/attachment.rb:375`, run by `rake redmine:attachments:prune`),
    # and it does not look at who points at it. So the attachment is also contained BY this
    # document, which is what takes it out of that WHERE clause. See `Reporting::Snapshot`
    # for the measurement.
    belongs_to :attachment, class_name: '::Attachment', optional: true
    # The same row, reached from the container side, so `dependent: :destroy` has somewhere
    # to hang: destroying a document must take its bytes and its file off the disk with it.
    has_one :stored_attachment, class_name: '::Attachment', as: :container,
                                dependent: :destroy, inverse_of: false

    # `technical-spec.md:1222-1223`: "Persistence is opt-in with a **mandatory TTL** and a purge
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

    # T-28 — WHAT CORE STORES IN `attachments.container_type` FOR A CONTAINED SNAPSHOT, and
    # it is a measurement rather than a preference: that column is `varchar(30)` and this
    # class's name is 35 characters. `app/models/rrd_report_snapshot.rb` holds the full
    # argument and the constant this resolves back to — read it before changing this string,
    # because every snapshot already on disk is found by it.
    def self.polymorphic_name
      'RrdReportSnapshot'
    end

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

    # T-28 — CORE'S THREE QUESTIONS ABOUT A CONTAINED ATTACHMENT, AND ALL THREE ANSWER NO.
    #
    # `Attachment#visible?` is `container && container.attachments_visible?(user)`
    # (`app/models/attachment.rb:198`), and `editable?`/`deletable?` are the same shape.
    # Containing the attachment is what saves it from the prune — it also makes it reachable
    # at `/attachments/:id/:filename`, which is a URL with no share link in it and therefore
    # a way round every control in FR-51.
    #
    # A snapshot is served by ONE endpoint, which is the share link's, and it authorises the
    # bytes rather than the reader. So core is told plainly that nobody may see, change or
    # delete this attachment through core — an undefined method here would have been a 500
    # from `AttachmentsController` instead, which is a refusal by accident.
    #
    # THE ARGUMENT IS NOT `false` PER USER: it is false for every user including an
    # administrator, because the question core is asking is *"may this person download it at
    # this URL"* and the answer is that this URL is not how it is downloaded.
    def attachments_visible?(_user = nil)
      false
    end

    def attachments_editable?(_user = nil)
      false
    end

    def attachments_deletable?(_user = nil)
      false
    end

    # The stored bytes, or nil when there are none — a purged document, or a row from before
    # anything wrote one. `readable?` is core's own check that the file is actually on disk,
    # and skipping it turns a missing file into an `Errno::ENOENT` from a controller.
    def bytes
      return nil if purged?
      return nil if attachment.nil? || !attachment.readable?

      ::File.binread(attachment.diskfile)
    end

    private

    # Measured from `created_at` on a persisted row and from now on a new one, so that
    # re-saving an old document does not fail for having been created a long time ago.
    def expiry_within_the_retention_bound
      return if expires_at.blank?

      origin = created_at || Time.zone.now
      return if expires_at <= origin + MAX_RETENTION

      # `.to_date`, so the message reads "… 2027-08-08" rather than
      # "… 2027-08-08 14:08:29 UTC". The bound is a retention policy measured in days; a
      # seconds-precision timestamp in a form error is noise a reader has to look past, and
      # it is the one part of this message Rails interpolates verbatim in every locale.
      errors.add(:expires_at, :less_than_or_equal_to, count: (origin + MAX_RETENTION).to_date)
    end
  end
end
