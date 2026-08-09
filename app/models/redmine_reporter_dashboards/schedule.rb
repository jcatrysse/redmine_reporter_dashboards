# frozen_string_literal: true

module RedmineReporterDashboards
  # A recurring report.
  #
  # T-22 owns the table and the shape; **T-25 owns the runner**, and nothing here decides
  # when a schedule is due. The one thing this class does assert is the type contract the
  # base plugin got wrong: `technical-spec.md` — "Reporter stores these dates as
  # `datetime` while every comparison is date-based — fixed."
  class Schedule < RedmineReporterDashboards::Compat.base_record
    self.table_name = 'reporter_dashboards_schedules'

    # The four columns that are `date` rather than `datetime`, listed so
    # `spec/migrations/schema_contract_spec.rb` can assert the column types against a name
    # this class states rather than against a list the spec repeats.
    DATE_COLUMNS = %w[start_date end_date last_run_on next_run_on].freeze

    # `last_status` is a small closed vocabulary. Not `enum` — see `Template` for why this
    # plugin uses constants plus inclusion everywhere.
    STATUS_SUCCESS = 'success'
    STATUS_FAILED  = 'failed'
    STATUS_SKIPPED = 'skipped'
    STATUSES = [STATUS_SUCCESS, STATUS_FAILED, STATUS_SKIPPED].freeze

    # T-25's repeat vocabulary, DEFINED IN ONE PLACE and re-exported here.
    #
    # T-22 left `repeat` unvalidated on purpose — "nothing here decides when a schedule is
    # due" — and `Scheduling::Occurrences` is what decides it. The constant lives there,
    # with the arithmetic that consumes it, so the validation below and the enumerator can
    # never come to disagree about what "quarterly" is. A model that accepted a fifth value
    # the enumerator does not implement would produce a schedule that is valid, saved,
    # enabled, and silently never due.
    REPEATS = RedmineReporterDashboards::Scheduling::Occurrences::REPEATS

    # Who the report is rendered as. The POLICY; `render_as_user_id` carries the identity
    # it resolved to, which is what FR-45 means by "explicit, stored and auditable".
    RENDER_AS_AUTHOR = 'author'
    RENDER_AS_USER   = 'user'
    RENDER_AS = [RENDER_AS_AUTHOR, RENDER_AS_USER].freeze

    belongs_to :project, optional: true
    belongs_to :template,
               class_name: 'RedmineReporterDashboards::Template',
               foreign_key: 'template_id',
               inverse_of: :schedules
    belongs_to :author, class_name: 'User', optional: true
    belongs_to :render_as_user, class_name: 'User', optional: true

    has_many :runs,
             -> { order(occurrence_date: :desc, id: :desc) },
             class_name: 'RedmineReporterDashboards::ScheduleRun',
             foreign_key: 'schedule_id',
             dependent: :delete_all,
             inverse_of: :schedule
    has_many :recipients,
             class_name: 'RedmineReporterDashboards::ScheduleRecipient',
             foreign_key: 'schedule_id',
             dependent: :delete_all,
             inverse_of: :schedule
    has_many :recipient_users, through: :recipients, source: :user

    # See `Template::MAX_STRING` for why every string column is length-validated: `t.string`
    # is unlimited on PostgreSQL and varchar(255) on MySQL/MariaDB, so without this an
    # over-long e-mail subject saves on one engine and raises `ValueTooLong` on another.
    MAX_STRING = 255

    validates :template_id, presence: true
    validates :author_id, presence: true
    validates :email_subject, :repeat, :query_type, :render_as, :timezone, :last_status,
              length: { maximum: MAX_STRING }, allow_nil: true
    validates :last_status, inclusion: { in: STATUSES }, allow_nil: true
    # `allow_nil` because the column is nullable and a half-built schedule is a legitimate
    # draft; a NAMED rule that this plugin cannot enumerate is not.
    validates :repeat, inclusion: { in: REPEATS }, allow_nil: true
    validates :render_as, inclusion: { in: RENDER_AS }, allow_nil: true
    validates :consecutive_failures,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :end_date_not_before_start_date
    # The identity has to exist when the policy says a specific user. Without this the
    # runner falls back to something, and "something" is how a report gets rendered as the
    # wrong person (FR-45).
    validate :render_as_user_present_when_policy_names_one

    # §7 rule 5's two schedule columns. Same reasoning as `Template.engine_hint_supported?`.
    def self.next_run_on_supported?
      RedmineReporterDashboards::Compat.column_present?(table_name, :next_run_on)
    end

    def self.consecutive_failures_supported?
      RedmineReporterDashboards::Compat.column_present?(table_name, :consecutive_failures)
    end

    # WHOSE NUMBERS A REPORT FROM THIS SCHEDULE HOLDS. FR-45: "the render identity of a
    # scheduled report is explicit, stored and auditable, **and a test send uses the same
    # identity as the real run**."
    #
    # It lives on the model rather than in the runner because of that last clause. The
    # runner asks it at 06:00 and the controller asks it when somebody presses "Send a test"
    # — and if those were two implementations they would answer differently the first time
    # anybody touched one, which is precisely the promise FR-45 makes. One method, two
    # callers, no way for them to disagree.
    #
    # EVERY ARM THAT CANNOT ANSWER RAISES, and none falls back. The three fallbacks a reader
    # might expect are each a way of mailing the wrong report:
    #
    #   User.current   — nobody, in a rake task. Whatever the last request left behind.
    #   User.anonymous — renders an EMPTY report that looks like a successful one. Nothing
    #                    raises, an e-mail goes out, and it contains no issues.
    #   the author,    — silently ignores the policy this row stores, which IS the audit
    #   regardless       trail FR-45 asks for.
    #
    # The POLICY is a closed set for the same reason `repeat` is: a value the column accepts
    # and this code does not implement must not produce a schedule that is valid, saved,
    # enabled and silently rendered as somebody else. `validates … inclusion:` does not close
    # it, because `update_columns` and `update_all` bypass validation and this plugin uses
    # both.
    #
    # A LOCKED user is refused too. A departed employee's schedule that keeps mailing their
    # view of the data is the same leak as a share link nobody revoked.
    class IdentityUnavailable < StandardError; end

    def render_identity
      user = case render_as
             when nil, RENDER_AS_AUTHOR then author
             when RENDER_AS_USER then render_as_user
             else
               raise IdentityUnavailable,
                     "schedule #{id} names render policy #{render_as.inspect}, which this " \
                     "version of the plugin cannot honour. Accepted: #{RENDER_AS.join(', ')}"
             end

      if user.nil?
        raise IdentityUnavailable,
              "schedule #{id} names no user to render as (render_as=#{render_as.inspect}); " \
              'the render identity has to be stored, not guessed at delivery time'
      end

      unless user.logged? && user.active?
        raise IdentityUnavailable,
              "schedule #{id} renders as user #{user.id}, which is not an active account; " \
              'a locked or anonymous identity produces a report that looks successful and ' \
              "holds nobody's data"
      end

      user
    end

    def next_run_on_or_nil
      self.class.next_run_on_supported? ? self[:next_run_on] : nil
    end

    # Zero rather than nil when the column is absent: every caller of this treats it as a
    # counter, and a nil would turn an operator warning into a NoMethodError.
    def consecutive_failures_or_zero
      self.class.consecutive_failures_supported? ? self[:consecutive_failures].to_i : 0
    end

    private

    def end_date_not_before_start_date
      return if start_date.blank? || end_date.blank?
      return if end_date >= start_date

      errors.add(:end_date, :greater_than_or_equal_to, count: start_date)
    end

    def render_as_user_present_when_policy_names_one
      return unless render_as == RENDER_AS_USER
      return if render_as_user_id.present?

      errors.add(:render_as_user_id, :blank)
    end
  end
end
