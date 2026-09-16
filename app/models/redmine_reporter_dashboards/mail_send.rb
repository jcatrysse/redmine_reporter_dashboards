# frozen_string_literal: true

module RedmineReporterDashboards
  # T-32 — one ad-hoc report mail, as an audit row and as the rate limiter's substrate.
  #
  # --- THIS ROW IS CLAIMED BEFORE THE RENDER, NOT WRITTEN AFTER IT ---
  #
  # FR-61 asks for two things that look separate and are one: an audit, and a per-user rate
  # limit. A limit that counted only completed sends would be a limit on SUCCESS, and the
  # expensive half of an ad-hoc send is the render — so a template that fails costs the
  # worker exactly as much as one that works, and a requester who can make it fail could
  # repeat it without bound. `#claim` therefore inserts a `running` row first and
  # `#finish` closes it, which is `ScheduleRun`'s shape for the same reason.
  #
  # It also means a crash between the two leaves a `running` row. That is deliberate and is
  # the honest record: something was started and nothing knows how it ended. It counts
  # against the limit, which is the fail-closed direction.
  class MailSend < RedmineReporterDashboards::Compat.base_record
    self.table_name = 'reporter_dashboards_mail_sends'

    # `created_at` is written by `#claim`; there is no `updated_at` column, so Rails must
    # not try to maintain one. Same decision as `ScheduleRun`, for the same reason.
    self.record_timestamps = false

    STATUS_RUNNING = 'running'
    STATUS_SUCCESS = 'success'
    STATUS_FAILED  = 'failed'
    # NO `skipped`. `ScheduleRun` has one because a draft schedule is a legitimate row that
    # delivers nothing; an ad-hoc send is a person pressing a button, and there is no state
    # in which that is neither a success nor a failure. A vocabulary that carries a value
    # nothing can produce invites a reader to look for it.
    STATUSES = [STATUS_RUNNING, STATUS_SUCCESS, STATUS_FAILED].freeze

    # `optional: true` AND `nullify` ON THE OTHER SIDE. An audit outlives its subject: a
    # template deleted next March must not take the record of what it mailed with it, which
    # is the same argument T-22 made for documents outliving their template.
    belongs_to :template,
               class_name: 'RedmineReporterDashboards::Template',
               foreign_key: 'template_id',
               optional: true,
               inverse_of: :mail_sends

    has_many :recipients,
             class_name: 'RedmineReporterDashboards::MailSendRecipient',
             foreign_key: 'mail_send_id',
             inverse_of: :mail_send,
             dependent: :destroy

    validates :author_id, presence: true
    validates :project_id, presence: true
    validates :status, inclusion: { in: STATUSES }

    # ONE PLACE THAT ANSWERS "how many sends has this person made lately", because the
    # limit and the message that explains the limit must agree. Two callers computing it
    # separately is §Findings S-15's shape, one table over.
    #
    # `since` is passed in rather than read off the clock here: CLAUDE.md §6 forbids a bare
    # `Time.now` in anything a test has to pin, and the caller already has one.
    def self.count_since(author_id, since)
      where(author_id: author_id).where(arel_table[:created_at].gteq(since)).count
    end

    # The claim. Returns the persisted row.
    #
    # No `rescue RecordNotUnique` here and no unique index behind it, unlike
    # `ScheduleRun.claim` — and the difference is the point rather than an omission. A
    # schedule occurrence is a thing that must happen AT MOST ONCE, so its identity is
    # `[schedule_id, occurrence_date]` and a duplicate is an answer. Two people legitimately
    # mailing the same report a minute apart are two sends, and refusing the second would
    # be a defect. What bounds the volume here is the rate limit, which is a different
    # control with a different failure mode.
    def self.claim(attributes)
      create!(attributes.merge(status: STATUS_RUNNING))
    end

    # `update_columns`, and S-7's rule is why: this writes the outcome of a send while a
    # human may be looking at the audit list, and a full-row write would carry back
    # whatever this in-memory object happens to hold for every other column. It also skips
    # validation deliberately — a row that cannot be validated must still be able to record
    # that it failed, which is the case T-25's runner found the hard way.
    def finish(status:, error: nil, recipients_count: nil, external_count: nil,
               document_count: nil, bytes_total: nil, duration_ms: nil, finished_at: nil,
               correlation_id: nil)
      update_columns(
        status: status,
        # BOUNDED. `last_error`'s lesson from T-25: an exception message can carry a whole
        # query, and a text column will take it. Truncated here rather than at every call
        # site, because there is one column and there will be more callers.
        error: error && error.to_s[0, 1000],
        recipients_count: recipients_count,
        external_count: external_count,
        document_count: document_count,
        bytes_total: bytes_total,
        duration_ms: duration_ms,
        correlation_id: correlation_id || self[:correlation_id],
        finished_at: finished_at
      )
    end

    def running?
      status == STATUS_RUNNING
    end

    def succeeded?
      status == STATUS_SUCCESS
    end
  end
end
