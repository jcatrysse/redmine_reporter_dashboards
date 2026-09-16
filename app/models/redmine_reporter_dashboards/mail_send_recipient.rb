# frozen_string_literal: true

module RedmineReporterDashboards
  # T-32 — one addressee of one ad-hoc send, recorded after the fact.
  #
  # --- THIS IS A RECORD, NOT A DESTINATION ---
  #
  # `technical-spec.md` §7 removes `to`/`cc`/`bcc`/`from` from the schedule tables because
  # they were **delivery inputs**: a stored string that a later run reads and mails to,
  # which is "a report over any issue in the instance, mailed anywhere, with a forged
  # sender". Nothing reads these rows and sends anything — `Reporting::AdhocDelivery` takes
  # its recipient list as an argument and never names this class, and a spec asserts that
  # rather than trusting this comment.
  #
  # `address` is populated only for an address `Reporting::MailPolicy` has already accepted
  # against the administrator's setting and domain allowlist. For a Redmine user the column
  # stays null and `user_id` carries it, so the common case stores no address at all and
  # the audit still resolves one through the user record.
  class MailSendRecipient < RedmineReporterDashboards::Compat.base_record
    self.table_name = 'reporter_dashboards_mail_send_recipients'

    # `created_at` only, written on create. No `updated_at` column exists: a log line is
    # not edited.
    self.record_timestamps = false

    belongs_to :mail_send,
               class_name: 'RedmineReporterDashboards::MailSend',
               foreign_key: 'mail_send_id',
               inverse_of: :recipients

    validates :mail_send_id, presence: true

    # EXACTLY ONE, and both directions are checked. The database cannot say this portably
    # across PostgreSQL, MySQL and MariaDB without a fourth dialect to keep in step, so it
    # is said here — and it is said as two rules rather than one, because "neither" and
    # "both" are different mistakes and a reader of the error should be told which they
    # made. A row with neither identifies nobody; a row with both is two claims about one
    # addressee and there is no rule for which wins.
    validate :exactly_one_identity

    # What an audit page prints. `user` is resolved lazily and through Redmine's own model
    # rather than stored, so a renamed or deleted account reads correctly rather than
    # showing a name from last year.
    def user
      return nil if user_id.nil?

      @user ||= ::User.find_by(id: user_id)
    end

    def external?
      address.present?
    end

    # The address as an auditor reads it: the stored one for an external recipient, the
    # account's own for a Redmine user, and a plain statement when the account is gone.
    # Never nil, because this lands in a table cell.
    def display_address
      return address if external?
      return user.mail if user&.mail.present?

      nil
    end

    private

    def exactly_one_identity
      if user_id.blank? && address.blank?
        errors.add(:base, 'a recipient row identifies either a Redmine user or an address')
      elsif user_id.present? && address.present?
        errors.add(:base, 'a recipient row identifies a Redmine user or an address, not both')
      end
    end
  end
end
