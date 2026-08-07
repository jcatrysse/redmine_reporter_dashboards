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
    # **Finding S-4, settled by T-23.** The specs called the third value "project"; core
    # calls it PUBLIC and labels it *"to any users"* (`config/locales/en.yml:1076`). The
    # integer and the semantics were always core's — only the prose differed — and the
    # prose is now corrected in both documents. The labels this plugin shows are core's
    # own three keys (`label_visibility_private` / `_roles` / `_public`), so an
    # administrator reads the identical words on the template form and on the saved-query
    # form, already translated in every locale Redmine ships.
    VISIBILITY_PRIVATE = 0
    VISIBILITY_ROLES   = 1
    VISIBILITY_PUBLIC  = 2
    VISIBILITIES = [VISIBILITY_PRIVATE, VISIBILITY_ROLES, VISIBILITY_PUBLIC].freeze

    # The permission that lets somebody see a template at all. Named once: it is used by
    # the scope, by `#visible?`, and by `Project.allowed_to_condition`, and three
    # spellings of one permission name is three chances to guard nothing.
    VIEW_PERMISSION = :view_reporter_dashboards_reports

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
    # NULLIFY, not destroy, and the difference is deliberate. A stored document is a frozen
    # SNAPSHOT — bytes that were already produced and may already have been shared (§7b.1).
    # Destroying it with the template would revoke a link somebody holds, silently, as a side
    # effect of an unrelated edit; leaving `template_id` dangling would point at a row that no
    # longer exists. Nullifying keeps the document and forgets which template made it, which
    # is what actually happened. Its own `expires_at` still bounds it, so nothing becomes
    # immortal by being orphaned.
    has_many :documents,
             class_name: 'RedmineReporterDashboards::Document',
             foreign_key: 'template_id',
             dependent: :nullify,
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

    # LENGTHS ARE VALIDATED ON EVERY STRING COLUMN, and that is a cross-engine requirement
    # rather than politeness. `t.string` is `character varying` with NO limit on PostgreSQL
    # and `varchar(255)` on MySQL and MariaDB, so an over-long value VALIDATES AND SAVES on
    # one engine and raises `ActiveRecord::ValueTooLong` on the other — a form that works in
    # development and 500s in production, decided by the database somebody chose.
    MAX_STRING = 255

    validates :name, presence: true, length: { maximum: MAX_STRING }
    validates :engine_hint, :source_digest, length: { maximum: MAX_STRING }, allow_nil: true
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

    # Mirrors `Query`'s `after_save` (`app/models/query.rb:280-284`) — and then closes a hole
    # in it, deliberately.
    #
    # Core clears the role list only when `saved_change_to_visibility?`. That misses CREATE:
    # `Template.create!(visibility: VISIBILITY_PRIVATE, roles: [r])` never marks `visibility`
    # dirty, because 0 is the column default — so the join row is written and survives. It is
    # inert while the template is private, and it goes LIVE the moment somebody switches the
    # template to ROLES, granting a role nobody chose in that edit. The review of T-36
    # demonstrated it.
    #
    # So the condition is "the visibility is not ROLES and there are roles", which subsumes
    # core's case. The extra cost is one `EXISTS` on a save that changed nothing else, and
    # the divergence is written down here rather than left for a reader to notice.
    after_save :clear_roles_unless_visible_to_roles

    def visibility_private?
      visibility == VISIBILITY_PRIVATE
    end

    def visibility_roles?
      visibility == VISIBILITY_ROLES
    end

    def visibility_public?
      visibility == VISIBILITY_PUBLIC
    end

    # ------------------------------------------------------------------------------
    # VISIBILITY — T-23. Core's shape, deliberately, down to the SQL.
    #
    # --- WHY THE ACTOR IS A REQUIRED ARGUMENT AND NOT `User.current` ---
    #
    # `Query.visible(*args)` defaults to `User.current` (`app/models/query.rb:384`) and
    # this one refuses to. INV-1 is the invariant this project loses most easily, and a
    # default argument is exactly how: a caller that forgets gets a plausible answer for
    # whoever happens to be logged in, which in a scheduled run at 06:00 is the Anonymous
    # user and in a preview is the author. A missing argument here is an ArgumentError at
    # the call site instead.
    #
    # --- WHY THE SQL IS COPIED RATHER THAN IMPROVED ---
    #
    # HANDOVER §1 records that MySQL 8 evaluates `projects.<col> IN (SELECT …)` inside a
    # LEFT JOIN's ON clause as TRUE (finding E-1) — an entitlement check written that way
    # passes for everyone, on that engine only. The rule that came out of it is: copy
    # Redmine's shape rather than inventing an equivalent one.
    #
    # This is `Query.visible`'s body (`redmine/app/models/query.rb:377`) with the view
    # permission and the join table substituted, and **one deliberate divergence in the
    # admin arm**, argued where it happens. The first version of this comment claimed
    # "and nothing else" while the roles arm was in fact two clauses short of core's —
    # a false statement about a security-bearing query is worse than no comment, because
    # it is what the next reader checks instead of the SQL. If you change this method,
    # re-diff it against core and re-write this paragraph.
    #
    # **NOT COVERED BY ANY MySQL OR MariaDB RUN** — finding S-9's shape exactly. This is
    # hand-written SQL with an EXISTS subquery and it executes only in the `minitest` job,
    # which is PostgreSQL only. Recorded rather than implied.
    def self.visible(user)
      raise ArgumentError, 'Template.visible needs an actor (INV-1)' if user.nil?

      base = Project.allowed_to_condition(user, VIEW_PERMISSION)
      scope = joins("LEFT OUTER JOIN #{Project.table_name} ON " \
                    "#{table_name}.project_id = #{Project.table_name}.id")
              .where("#{table_name}.project_id IS NULL OR (#{base})")

      if user.admin?
        # THE ONE PLACE THIS DELIBERATELY DIVERGES FROM `Query.visible`, and the
        # divergence was found by a test rather than chosen in the abstract.
        #
        # Core's admin arm is `visibility <> PRIVATE OR user_id = ?`, so an administrator's
        # query LIST hides other people's private queries while `Query#visible?` answers
        # `true if user.admin?` for the same row. The two disagree, and core can afford it
        # because a saved query is cheap to reach another way.
        #
        # Here they must not, because `#editable_by?` also answers `true` for an
        # administrator: with core's arm an admin could edit and DELETE a template that
        # their own index does not list and whose page 404s. A list that hides rows the
        # same person may destroy is a worse surprise than a longer list, so an
        # administrator sees every template in the project — which is what the predicate,
        # the editability rule and Redmine's own "admin bypasses permissions" all already
        # say.
        scope
      elsif user.memberships.any?
        # ALL FOUR LINES OF CORE'S EXISTS SUBQUERY, and the two that were missing were a
        # cross-project leak. The independent review of T-23 found it, and it is worth
        # writing down because the shape is so plausible:
        #
        #   the `projects` join       an ARCHIVED project's roles stop counting
        #   `templates.project_id
        #    = m.project_id`          the membership that satisfies the role must be a
        #                             membership OF THIS TEMPLATE'S PROJECT
        #
        # Without the second line, a user who is a Manager in an unrelated project B and
        # merely a Reporter in project A satisfied a ROLES-visible template in A that
        # named Manager — the `EXISTS` matched through their membership in B. `#visible?`
        # asks `roles_for_project(project)` and correctly said no, so the index listed a
        # template whose page then 404'd: a disclosure AND the scope/predicate divergence
        # the matrix test exists to prevent.
        scope.where(
          "#{table_name}.visibility = ?" \
          " OR (#{table_name}.visibility = ? AND EXISTS (SELECT 1" \
          " FROM reporter_dashboards_templates_roles tr" \
          " INNER JOIN #{MemberRole.table_name} mr ON mr.role_id = tr.role_id" \
          " INNER JOIN #{Member.table_name} m ON m.id = mr.member_id AND m.user_id = ?" \
          " INNER JOIN #{Project.table_name} p ON p.id = m.project_id AND p.status <> ?" \
          " WHERE tr.template_id = #{table_name}.id" \
          " AND (#{table_name}.project_id IS NULL" \
          " OR #{table_name}.project_id = m.project_id)))" \
          " OR #{table_name}.author_id = ?",
          VISIBILITY_PUBLIC, VISIBILITY_ROLES, user.id, Project::STATUS_ARCHIVED, user.id
        )
      elsif user.logged?
        scope.where("#{table_name}.visibility = ? OR #{table_name}.author_id = ?",
                    VISIBILITY_PUBLIC, user.id)
      else
        # ANONYMOUS HAS NO `author_id` TO MATCH, and writing one would be a hole rather
        # than a shortcut: `User.anonymous.id` is a real row id, so a template authored
        # by the anonymous user — which nothing can create, but a database restore or a
        # user deletion could produce — would become visible to every unauthenticated
        # visitor. Public only.
        scope.where("#{table_name}.visibility = ?", VISIBILITY_PUBLIC)
      end
    end

    # The per-record answer. Not derived from the scope, and the duplication is core's
    # too (`Query#visible?`, `app/models/query.rb:412`): a scope answers "which rows may
    # this actor see" in SQL and this answers "may this actor see THIS row" in Ruby, and
    # a controller holding one record must not have to run a query to find out.
    #
    # A test asserts the two agree over a fixed matrix of actors and templates, because
    # two implementations of one rule is exactly the shape that drifts.
    def visible?(user)
      return false if user.nil?
      return true if user.admin?
      return false unless project.nil? || user.allowed_to?(VIEW_PERMISSION, project)

      case visibility
      when VISIBILITY_PUBLIC
        true
      when VISIBILITY_ROLES
        # `user.roles_for_project` answers the built-in Non-member / Anonymous role for a
        # non-member, so this is not "any role" — it is the roles this user actually holds
        # here, intersected with the ones the author named.
        project ? user.roles_for_project(project).intersect?(roles) : false
      else
        # `authored_by?` AND NOT `author_id == user.id`, because the second one matches
        # for the ANONYMOUS user. `User.anonymous` is a real row with a real id, so a
        # template whose `author_id` happens to be it — nothing can create one, but a
        # database restore or a user deletion can produce one — would become visible to
        # every unauthenticated visitor. The scope's anonymous arm never matched on
        # authorship; this one did, and the two disagreeing is what the agreement matrix
        # caught.
        authored_by?(user)
      end
    end

    # --- EDITING: TWO PERMISSIONS, AND THE SECOND ONE IS THE INTERESTING ONE ---
    #
    # `edit_reporter_dashboards_templates` edits anything in the project.
    # `edit_own_reporter_dashboards_templates` edits what you authored, and "own" is
    # `author_id`, never "a template you can see" or "a private template". A template
    # somebody else authored and made public is emphatically not yours to rewrite —
    # rewriting it changes code that runs server-side under everyone else's report.
    #
    # `authored_by?` is separate from the permission test so the functional suite can
    # assert the case that looks right until it is tried: a holder of `edit_own_…`
    # against a template with a different author.
    def authored_by?(user)
      !user.nil? && user.logged? && author_id == user.id
    end

    def editable_by?(user)
      return false if user.nil?
      return true if user.admin?
      # A template with no project is admin-only by construction: Redmine has no role
      # grant outside a project, so there is nothing to check a permission against
      # (technical-spec.md §4.1, "Deliberately not permissions").
      return false if project.nil?

      return true if user.allowed_to?(:edit_reporter_dashboards_templates, project)

      authored_by?(user) &&
        user.allowed_to?(:edit_own_reporter_dashboards_templates, project)
    end

    # Deleting is the same grant as editing — §4.1's rows say "Edit **and delete**" for
    # both. An alias would hide that this is a decision; a method saying so does not.
    def deletable_by?(user)
      editable_by?(user)
    end

    # Whether this actor may give the template a visibility wider than themselves. The
    # same question `manage_public_queries` answers for a saved query, and the reason the
    # column exists at all (§4.1, row 9).
    def visibility_editable_by?(user)
      return false if user.nil?
      return true if user.admin?
      return false if project.nil?

      user.allowed_to?(:manage_public_reporter_dashboards_templates, project)
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

    def clear_roles_unless_visible_to_roles
      return if visibility == VISIBILITY_ROLES
      return if roles.empty?

      roles.clear
    end
  end
end
