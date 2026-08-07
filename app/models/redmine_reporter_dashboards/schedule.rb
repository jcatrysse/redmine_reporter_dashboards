# frozen_string_literal: true

module RedmineReporterDashboards
  # A recurring report.
  #
  # T-22 owns the table and the shape; **T-25 owns the runner**, and nothing here decides
  # when a schedule is due. The one thing this class does assert is the type contract the
  # base plugin got wrong: `technical-spec.md:1200` — "Reporter stores these dates as
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

    validates :template_id, presence: true
    validates :author_id, presence: true
    validates :last_status, inclusion: { in: STATUSES }, allow_nil: true
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
