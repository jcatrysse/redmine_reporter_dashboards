# frozen_string_literal: true

module RedmineReporterDashboards
  # A report template — the owned replacement for the base plugin's `ReportTemplate`.
  #
  # --- WHY THIS CLASS IS NAMESPACED, AND WHY THAT IS THE POINT OF T-22 ---
  #
  # `technical-spec.md:1266-1270`: "Both plugins define `Report`, `ReportTemplate`,
  # `ReportSchedule` at **top level**, so there is no 'install alongside and compare' path
  # today. Namespaced classes + new tables mean **both plugins can be installed
  # simultaneously**, which turns the riskiest single event in the project from a leap of
  # faith into a comparison. Decisive."
  #
  # So the namespace is load-bearing, not tidiness. `spec/migrations/schema_contract_spec.rb`
  # asserts that no model this plugin ships takes a top-level constant.
  #
  # --- WHY `self.table_name` IS SET BY HAND ---
  #
  # Rails would derive `redmine_reporter_dashboards_templates` from the namespaced class.
  # The table is `reporter_dashboards_templates`, because that is the name §7 gives it and
  # because the prefix an operator sees in `\dt` should match the plugin's own tables
  # (`reporter_project_tabs`) rather than its Ruby module.
  #
  # --- WHY THERE IS NO `enum` ANYWHERE IN THIS PLUGIN'S MODELS ---
  #
  # `enum` has changed signature three times inside this support span, and the base plugin
  # is broken on Redmine 7.0 for exactly that reason: `test/test_helper.rb` records that
  # merely REFERENCING reporter's `ReportTemplate` raises on Rails 8.1, because Rails 8.0
  # made `enum`'s first argument positional. Redmine core does not use `enum` for
  # `Query#visibility` either — it uses constants plus `validates :inclusion`
  # (`app/models/query.rb:259-274`). Copying core costs nothing, needs no `compat/enum.rb`
  # shim, and cannot break the same way.
  class Template < RedmineReporterDashboards::Compat.base_record
    include Redmine::I18n

    self.table_name = 'reporter_dashboards_templates'

    # Redmine's own three values and integers, from `app/models/query.rb:259-261`, so an
    # administrator meets ONE concept rather than two (technical-spec.md:617-618).
    #
    # NOTE for whoever writes the labels in T-23: the specs call the third value
    # "project", Redmine calls it PUBLIC and labels it "to any users"
    # (`config/locales/en.yml:1076`). The integer and the semantics are core's; only the
    # spec's prose differs, and the PR reports that.
    VISIBILITY_PRIVATE = 0
    VISIBILITY_ROLES   = 1
    VISIBILITY_PUBLIC  = 2
    VISIBILITIES = [VISIBILITY_PRIVATE, VISIBILITY_ROLES, VISIBILITY_PUBLIC].freeze

    # The two axes reporter's single `type` conflated — see migration 002's comment.
    SOURCES     = %w[issues time_entries].freeze
    OUTPUTS     = %w[per_record combined].freeze
    ORIENTATIONS = %w[portrait landscape].freeze
    PAGE_SIZES   = %w[A4 A3 A5 Letter Legal Tabloid].freeze

    # "top,right,bottom,left" in millimetres. Anchored, and each field bounded to three
    # digits: a page is not 4 000 mm wide, and an unbounded number here reaches the render
    # engine's own argument parser.
    MARGINS_FORMAT = /\A\d{1,3},\d{1,3},\d{1,3},\d{1,3}\z/

    belongs_to :project, optional: true
    belongs_to :author, class_name: 'User', optional: true

    has_many :versions,
             -> { order(created_at: :desc, id: :desc) },
             class_name: 'RedmineReporterDashboards::TemplateVersion',
             foreign_key: 'template_id',
             dependent: :delete_all,
             inverse_of: :template
    has_many :schedules,
             class_name: 'RedmineReporterDashboards::Schedule',
             foreign_key: 'template_id',
             dependent: :destroy,
             inverse_of: :template

    # The same shape as Redmine's `Query` (`app/models/query.rb:265`), including the
    # join-table name being stated rather than derived — Rails would derive
    # `reporter_dashboards_templates_roles` correctly here, but the derivation depends on
    # alphabetical ordering of two class names and would silently change if either were
    # renamed.
    has_and_belongs_to_many :roles,
                            join_table: 'reporter_dashboards_templates_roles',
                            foreign_key: 'template_id',
                            association_foreign_key: 'role_id'

    validates :name, presence: true, length: { maximum: 255 }
    validates :author_id, presence: true
    validates :visibility, inclusion: { in: VISIBILITIES }
    validates :source, inclusion: { in: SOURCES }
    validates :output, inclusion: { in: OUTPUTS }
    validates :orientation, inclusion: { in: ORIENTATIONS }
    validates :page_size, inclusion: { in: PAGE_SIZES }
    validates :margins, format: { with: MARGINS_FORMAT }, allow_blank: true
    # Redmine's own rule for a roles-visible query (`app/models/query.rb:276-278`): a
    # visibility of ROLES with no roles named is not "visible to nobody", it is a form
    # somebody filled in wrong. The message is assembled from the two core keys core
    # itself uses, so it is already translated in all nine locales and reads identically
    # to the one an administrator sees on the saved-query form.
    validate :roles_present_when_visible_to_roles

    # Mirrors `Query`'s `after_save` (`app/models/query.rb:280-284`) exactly, including its
    # narrowness: the roles are cleared only when the visibility actually CHANGED away from
    # ROLES. Clearing on every save would be a second concept for an administrator to
    # learn, and this plugin's whole argument for reusing core's three values is that there
    # is only one.
    after_save :clear_roles_when_visibility_changed_away_from_roles

    def visibility_private?
      visibility == VISIBILITY_PRIVATE
    end

    def visibility_roles?
      visibility == VISIBILITY_ROLES
    end

    def visibility_public?
      visibility == VISIBILITY_PUBLIC
    end

    # Whether the running database actually has the column. §7 rule 5: a user who rolls
    # the PLUGIN back one minor version while keeping the schema — or forward without
    # migrating — must not crash. Asked through `Compat` so the answer is in one place and
    # `compat_size.sh` can see it.
    def self.engine_hint_supported?
      RedmineReporterDashboards::Compat.column_present?(table_name, :engine_hint)
    end

    # Reads nil rather than raising when the column is absent. This is the whole point of
    # rule 5: "cheap, and it converts a support incident into a degraded feature".
    def engine_hint_or_nil
      self.class.engine_hint_supported? ? self[:engine_hint] : nil
    end

    private

    def roles_present_when_visible_to_roles
      return unless visibility == VISIBILITY_ROLES
      return if roles.present?

      errors.add(:base, "#{l(:label_role_plural)} #{l('activerecord.errors.messages.blank')}")
    end

    def clear_roles_when_visibility_changed_away_from_roles
      return unless saved_change_to_visibility?
      return if visibility == VISIBILITY_ROLES

      roles.clear
    end
  end
end
