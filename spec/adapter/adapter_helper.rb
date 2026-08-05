# frozen_string_literal: true
#
# Harness for the ADAPTER EXECUTION specs.
#
# Everything else under spec/ is a pure unit spec: it stubs ActiveRecord away and
# asserts on the SQL *strings* the aggregator builds. That proves the intent, but it
# cannot prove that PostgreSQL and MySQL/MariaDB actually accept those strings and
# answer the same numbers — and the aggregator has real per-adapter branches:
#
#   date_format_sql   TO_CHAR(x, 'IYYY"-W"IW')  vs  DATE_FORMAT(x, '%x-W%v')
#   numeric_cast      CAST(x AS numeric)        vs  CAST(x AS DECIMAL(20,4))
#   count_case        COUNT(DISTINCT CASE WHEN ... THEN issues.id END)
#   percentile_age    ORDER BY ... OFFSET n LIMIT 1   (no percentile_cont)
#   the joins         LEFT OUTER JOIN custom_values / time_entries with a
#                     visibility subquery in the ON clause, next to a GROUP BY
#
# So these specs create a small real schema — the columns of Redmine's tables that
# the aggregator names, under the same table names, because the generated SQL says
# `issues.`, `custom_values.`, `time_entries.` and `projects.` literally — seed a
# deterministic fixture, and run the aggregator against it for real.
#
# NOT a substitute for the minitest functional tests: Redmine's own models,
# visibility rules and permissions are stubbed here with the smallest thing that has
# the same SQL SHAPE (a subquery over members/member_roles for a role-restricted
# custom field, a projects-referencing condition for time entry visibility). What is
# under test is the aggregator's SQL against a real database engine, not Redmine's
# authorization.
#
# --- Actors ---
#
# The fixture has FOUR actors holding three roles (see ACTORS), and both entitlement
# checks read the actor rather than ignoring it. That is what makes INV-1 and INV-2
# testable at VALUE level: the same call with a different actor returns different
# numbers, or is refused. What is deliberately NOT here is Issue.visible — the
# viewer's issue scope is Redmine's own SQL, so it is frozen by the scope fixture in
# test/unit/golden_scope_fixture_test.rb, where a real IssueQuery exists.
#
# --- Running them ---
#
#   RRD_ADAPTER_URL=postgres://redmine:redmine@localhost/redmine_adapter_test \
#     bundle exec rspec -I plugins/redmine_reporter_dashboards/spec \
#                          plugins/redmine_reporter_dashboards/spec/adapter
#
#   RRD_ADAPTER_URL=mysql2://root@localhost/redmine_adapter_test  bundle exec rspec ...
#
# Without RRD_ADAPTER_URL the specs skip with that message, so the DB-less suite
# stays runnable anywhere. They are deliberately run as their OWN rspec invocation:
# they load the real ActiveRecord, while spec/sql_aggregation/* define a stub
# ActiveRecord::Base when none exists, and one process should not have to be
# correct under both. .codex/test_plugin.sh and the CI workflow keep them apart.
#
# The target database is DROPPED AND RECREATED table by table, so the URL must name
# a database whose name contains "test". That guard is the only thing between a
# careless RRD_ADAPTER_URL and someone's development data.

require 'logger' # concurrent-ruby >= 1.3.5 no longer requires this; ActiveSupport needs Logger defined
require 'active_support'
require 'active_support/time'
require 'active_support/testing/time_helpers'
require 'uri'
require_relative '../spec_helper'
require_relative '../golden/reference_date'
require_relative '../golden/adapter_overlay'

Time.zone ||= 'UTC'

unless defined?(Rails)
  module Rails
    def self.logger
      @logger ||= Logger.new(File::NULL)
    end
  end
end

module RrdAdapterHarness
  ENV_VAR = 'RRD_ADAPTER_URL'

  # Status ids are referenced from the specs, so they are named rather than magic.
  STATUS_NEW         = 1
  STATUS_IN_PROGRESS = 2
  STATUS_CLOSED      = 5
  STATUS_REJECTED    = 6

  PROJECT_MAIN     = 1 # active
  PROJECT_ARCHIVED = 2 # status 9 — excluded by both stubbed visibility conditions
  PROJECT_SWEEP    = 3 # active; holds the one-issue-per-day calendar sweep
  PROJECT_WIDE     = 4 # active; holds the cap-boundary fixture (see seed_wide!)

  CF_DEPARTMENT = 10 # list,  visible everywhere
  CF_POINTS     = 11 # int,   visible everywhere
  CF_COST       = 12 # float, restricted to PROJECT_MAIN
  CF_HIDDEN     = 13 # list,  not in CustomField.visible -> refused outright
  CF_CLIENT     = 14 # ProjectCustomField -> refused as a non-issue custom field
  CF_SALARY     = 15 # float, restricted to ROLE_MANAGER — the ROLE-restricted field
  CF_WIDE       = 16 # list,  visible everywhere; one distinct value per wide issue

  # Roles. Which permissions each carries is expressed by the two lists below rather
  # than by a permissions column: the stubs need the SQL shape of an entitlement
  # check, not Redmine's permission model.
  ROLE_MANAGER   = 1
  ROLE_DEVELOPER = 2
  ROLE_REPORTER  = 3

  # The roles that may see time entries, i.e. Redmine's :view_time_entries.
  TIME_ENTRY_ROLE_IDS = [ROLE_MANAGER, ROLE_DEVELOPER].freeze

  # Actors, by the name the corpus refers to them by. Four, with three distinct
  # roles, because three actors are only enough to tell "entitled" from "not
  # entitled" — and the interesting case is two actors holding the SAME role in
  # DIFFERENT projects, which is what separates "the field is refused" from "the
  # field resolves but its values are hidden here".
  #
  #   manager    ROLE_MANAGER   in MAIN, SWEEP, WIDE — sees everything
  #   developer  ROLE_DEVELOPER in MAIN, WIDE        — time entries yes, CF_SALARY no
  #   reporter   ROLE_REPORTER  in WIDE              — neither
  #   auditor    ROLE_MANAGER   in WIDE              — CF_SALARY resolves, but its
  #                                                    values are hidden on MAIN
  ACTORS = { manager: 1, developer: 2, reporter: 3, auditor: 4 }.freeze

  SWEEP_DAYS = 400

  # The zone the fixture and the corpus are pinned in. See #freeze_to_reference_date!
  # for why it is set rather than inherited.
  CORPUS_TIME_ZONE = 'UTC'

  # The cap-boundary fixture. 250 > MAX_DIMENSION_KEYS (200) so the 200-key cap is
  # crossed, and 250 = 10 × 25 so the created_on spread divides evenly over
  # WIDE_SPREAD_DAYS — no bucket is short, which would make a cap case's numbers
  # depend on an arithmetic accident.
  #
  # 25 days, not 26, so a `period: day, periods: 25` split covers the whole fixture:
  # that is the crosstab the 5 000-cell case is built from, and a 26th day outside the
  # window would silently drop ten rows out of the grid.
  WIDE_ISSUES      = 250
  WIDE_ID_BASE     = 2_000
  WIDE_SPREAD_DAYS = 25

  WIDE_STATUS_CYCLE   = [STATUS_NEW, STATUS_IN_PROGRESS, STATUS_CLOSED, STATUS_REJECTED].freeze
  WIDE_ASSIGNEE_CYCLE = [ACTORS[:manager], ACTORS[:developer], nil].freeze

  # Exactly MAX_DIMENSION_KEYS distinct CF_WIDE values, with no blank bucket — the
  # scope that lands an axis ON the cap rather than one past it.
  WIDE_AT_CAP = 200

  class << self
    def url
      ENV[ENV_VAR].to_s
    end

    def configured?
      !url.empty?
    end

    def skip_reason
      "set #{ENV_VAR} to a PostgreSQL or MySQL/MariaDB URL naming a *test* database " \
        "(e.g. #{ENV_VAR}=postgres://redmine:redmine@localhost/redmine_adapter_test) " \
        'to run the adapter execution specs'
    end

    def database_name
      URI.parse(url).path.to_s.sub(%r{\A/}, '')
    rescue URI::InvalidURIError
      ''
    end

    # The whole schema is recreated with force: true, so refuse anything that does
    # not announce itself as a test database.
    def connect!
      unless database_name.include?('test')
        raise "#{ENV_VAR} names the database #{database_name.inspect}; refusing to recreate " \
              'its tables. Point it at a database whose name contains "test".'
      end

      ActiveRecord::Base.establish_connection(url)
      ActiveRecord::Base.connection.execute('SELECT 1')
      adapter_name
    end

    def adapter_name
      ActiveRecord::Base.connection.adapter_name.to_s
    end

    def postgresql?
      adapter_name.match?(/postgres/i)
    end

    def mysql?
      adapter_name.match?(/mysql|maria|trilogy/i)
    end

    # The mysql2 adapter reports "Mysql2" for MariaDB too, so the server version is
    # the only way to tell them apart — and they differ in how strict
    # ONLY_FULL_GROUP_BY is, which one example turns on.
    def mariadb?
      mysql? && ActiveRecord::Base.connection.select_value('SELECT VERSION()').to_s.match?(/mariadb/i)
    end

    # QueryAggregator memoises the adapter family on the class; a spec process that
    # connects after something already asked would otherwise keep :unknown.
    def reset_adapter_memo!
      SqlAggregation::QueryAggregator.instance_variable_set(:@adapter_family, nil)
    end

    def load_schema!
      c = ActiveRecord::Base.connection

      c.create_table(:projects, force: true) do |t|
        t.string  :name
        t.integer :status, null: false, default: 1
      end

      c.create_table(:issue_statuses, force: true) do |t|
        t.string  :name
        t.boolean :is_closed, null: false, default: false
      end

      c.create_table(:trackers, force: true) { |t| t.string :name }
      c.create_table(:issue_categories, force: true) do |t|
        t.string  :name
        t.integer :project_id
      end

      c.create_table(:enumerations, force: true) do |t|
        t.string :name
        t.string :type
      end

      c.create_table(:users, force: true) do |t|
        t.string :login, :firstname, :lastname
      end

      # Roles and memberships. Redmine's own tables and columns, because both
      # stubbed entitlement checks below produce a subquery over them — the same
      # shape IssueCustomField#visibility_by_project_condition and
      # TimeEntry.visible_condition produce in the real application.
      c.create_table(:roles, force: true) { |t| t.string :name }

      c.create_table(:members, force: true) do |t|
        t.integer :user_id, :project_id
      end

      c.create_table(:member_roles, force: true) do |t|
        t.integer :member_id, :role_id
      end

      c.create_table(:versions, force: true) do |t|
        t.integer :project_id
        t.string  :name
        t.date    :effective_date
      end

      c.create_table(:issues, force: true) do |t|
        t.integer  :project_id, :tracker_id, :status_id, :priority_id, :category_id,
                   :fixed_version_id, :author_id, :assigned_to_id
        t.integer  :parent_id, :done_ratio
        t.string   :subject
        t.text     :description
        t.float    :estimated_hours
        t.date     :start_date, :due_date
        t.datetime :created_on, :updated_on, :closed_on
      end

      c.create_table(:custom_fields, force: true) do |t|
        t.string  :type, :name, :field_format
        t.integer :position
        t.boolean :visible,  null: false, default: true
        t.boolean :multiple, null: false, default: false
        t.text    :possible_values
        # Not a Redmine column. Stands in for the projects subquery that
        # IssueCustomField#visibility_by_project_condition produces for a
        # PROJECT-restricted field: nil means "everyone", an id means "only there".
        # Independent of the actor, so it is the wrong tool for INV-1.
        t.integer :visibility_project_id
        # Also not a Redmine column, and this one IS actor-dependent: the role a
        # viewer must hold — in the project the issue belongs to — for the field's
        # values to be visible at all. Redmine spells this as `visible: false` plus
        # rows in custom_fields_roles; one column carries the same fact here.
        t.integer :visibility_role_id
      end

      c.create_table(:custom_values, force: true) do |t|
        t.string  :customized_type
        t.integer :customized_id, :custom_field_id
        t.text    :value
      end

      c.create_table(:time_entries, force: true) do |t|
        t.integer :project_id, :issue_id, :user_id
        t.float   :hours
        t.date    :spent_on
      end
    end

    MODEL_NAMES = %i[Project IssueStatus Tracker IssueCategory Version IssuePriority User
                     Role Member MemberRole
                     TimeEntry CustomValue CustomField IssueCustomField ProjectCustomField
                     Issue].freeze

    # These are TOP-LEVEL constants, because that is how the aggregator names them.
    # If one is already taken the specs must fail rather than silently redefine
    # somebody else's class — a booted Redmine is the obvious case, and there these
    # specs have no business running at all.
    def define_models!
      return if defined?(::Issue) && ::Issue.respond_to?(:rrd_adapter_harness_model?)

      taken = MODEL_NAMES.select { |name| Object.const_defined?(name, false) }
      unless taken.empty?
        raise "#{taken.join(', ')} already defined — the adapter execution specs define their own " \
              'models under those names and must run in their own process (bundle exec rspec ' \
              'spec/adapter), not inside a booted Redmine.'
      end

      # rubocop:disable Lint/ConstantDefinitionInBlock
      Object.const_set(:Project, Class.new(ActiveRecord::Base))
      Object.const_set(:IssueStatus, Class.new(ActiveRecord::Base))
      Object.const_set(:Tracker, Class.new(ActiveRecord::Base))
      Object.const_set(:IssueCategory, Class.new(ActiveRecord::Base))
      Object.const_set(:Version, Class.new(ActiveRecord::Base))

      Object.const_set(:IssuePriority, Class.new(ActiveRecord::Base) do
        self.table_name = 'enumerations'
      end)

      Object.const_set(:User, Class.new(ActiveRecord::Base) do
        def name
          "#{firstname} #{lastname}".strip
        end

        class << self
          attr_writer :current

          def current
            @current ||= order(:id).first
          end
        end
      end)

      Object.const_set(:Role, Class.new(ActiveRecord::Base))
      Object.const_set(:Member, Class.new(ActiveRecord::Base))
      Object.const_set(:MemberRole, Class.new(ActiveRecord::Base))

      # Redmine applies TimeEntry.visible_condition to every sum of spent time; the
      # stand-in has the same shape (it names `projects`, so the aggregator's
      # joins(:project) is load-bearing) without reimplementing permissions.
      #
      # It is ACTOR-DEPENDENT, which the earlier flat `projects.status = 1` was not:
      # spent time is visible in the projects where the viewer holds a role that may
      # see it, and nowhere else. Without that, every "same call, different actor"
      # case in the corpus would return the same numbers and INV-1 would be frozen
      # as untested rather than as held. nil user → 1=0, fail closed.
      Object.const_set(:TimeEntry, Class.new(ActiveRecord::Base) do
        def self.visible_condition(user)
          return '1=0' if user.nil?

          "projects.status = 1 AND #{RrdAdapterHarness.entitled_projects_sql(
            user, RrdAdapterHarness::TIME_ENTRY_ROLE_IDS, 'projects.id'
          )}"
        end
      end)

      Object.const_set(:CustomValue, Class.new(ActiveRecord::Base))

      Object.const_set(:CustomField, Class.new(ActiveRecord::Base) do
        # Redmine: a field with `visible: true` is offered to everyone; one with
        # `visible: false` is offered only to viewers holding one of its roles,
        # anywhere. A field that is neither is offered to nobody — which is what
        # CF_HIDDEN is, and it must stay refused for every actor.
        def self.visible(user)
          role_ids = RrdAdapterHarness.role_ids_for(user)
          return where(visible: true) if role_ids.empty?

          where(visible: true).or(where(visibility_role_id: role_ids))
        end

        # Defaults to User.current exactly as Redmine's does, because the aggregator
        # calls it with no argument (query_aggregator.rb#visibility_condition).
        def visibility_by_project_condition(user = ::User.current)
          return '1=0' if user.nil?

          if visibility_role_id
            return RrdAdapterHarness.entitled_projects_subquery_sql(user, [visibility_role_id.to_i])
          end

          return '1=1' if visibility_project_id.nil?

          "issues.project_id IN (SELECT rrd_vp.id FROM projects rrd_vp " \
            "WHERE rrd_vp.id = #{visibility_project_id.to_i})"
        end
      end)

      Object.const_set(:IssueCustomField, Class.new(::CustomField))
      Object.const_set(:ProjectCustomField, Class.new(::CustomField))

      Object.const_set(:Issue, Class.new(ActiveRecord::Base) do
        belongs_to :project, optional: true
        belongs_to :status, class_name: 'IssueStatus', optional: true
        has_many :time_entries, dependent: nil

        # The marker define_models! recognises, so a second call is a no-op rather
        # than a "already defined" failure against its own classes.
        def self.rrd_adapter_harness_model?
          true
        end
      end)
      # rubocop:enable Lint/ConstantDefinitionInBlock
    end

    # ------------------------------------------------------------------
    # Actors
    # ------------------------------------------------------------------

    # "the projects where this viewer holds one of these roles", as a SQL fragment
    # over Redmine's own membership tables.
    #
    # A LITERAL ID LIST, because that is what Redmine emits: Project.allowed_to_condition
    # resolves the projects in Ruby and interpolates
    # `projects.id IN (1,2,3)` — see app/models/project.rb, the statement_by_role loop.
    # It is also the only form that is CORRECT on MySQL 8.
    #
    # This method used to emit `#{column} IN (SELECT … FROM members …)` instead, and the
    # first real CI run caught it: on MySQL 8.0.46 a subquery inside a LEFT OUTER JOIN's
    # ON clause that references a SEPARATELY JOINED table (`projects`) is silently
    # evaluated as TRUE, so an actor with no entitled role summed 7.0 visible hours
    # instead of 0.0. Measured, bisected:
    #
    #   projects.id       IN (subquery)  in a LEFT JOIN ON clause  -> ignored on MySQL 8
    #   issues.project_id IN (subquery)  in a LEFT JOIN ON clause  -> correct
    #   projects.id       IN (1,2,3)     in a LEFT JOIN ON clause  -> correct
    #   all three                                                  -> correct on PostgreSQL
    #                                                                 and on MariaDB
    #
    # THE PRODUCTION PATHS ARE NOT AFFECTED, and that is worth stating precisely rather
    # than assuming: `TimeEntry.visible_condition` reaches `projects` but emits literal
    # id lists, and `IssueCustomField#visibility_by_project_condition` does emit a
    # subquery but keys it on `#{customized_class.table_name}.project_id`, i.e.
    # `issues.project_id` — the shape MySQL gets right. Verified against 6.1-stable's
    # custom_field.rb:262 and issue_custom_field.rb:35. So this was a fidelity defect in
    # the harness: it invented a shape Redmine never produces, and MySQL then made the
    # harness lie about visibility.
    #
    # No separate "MySQL mis-evaluates this" assertion is needed to keep the shape out:
    # the per-actor spent-time examples below fail on MySQL the moment it comes back,
    # which is the mechanical control rather than a comment asking politely.
    def entitled_projects_sql(user, role_ids, column)
      ids = Array(role_ids).map(&:to_i).reject(&:zero?)
      return '1=0' if user.nil? || ids.empty?

      project_ids = ::Member.where(user_id: user.id)
                            .where(id: ::MemberRole.where(role_id: ids).select(:member_id))
                            .distinct.pluck(:project_id).compact.sort
      return '1=0' if project_ids.empty?

      "#{column} IN (#{project_ids.join(',')})"
    end

    # The custom-field half, and it is deliberately a DIFFERENT shape from the one
    # above: a SUBQUERY keyed on `issues.project_id`, because that is what
    # CustomField#visibility_by_project_condition emits
    # (`project_key ||= "#{customized_class.table_name}.project_id"`, custom_field.rb:262
    # on 6.1-stable). The two stubs are not two spellings of one fact — they mirror two
    # different conditions Redmine really produces, and the difference is load-bearing:
    # this shape is evaluated correctly by every supported engine, the `projects`-keyed
    # subquery is not (see above).
    def entitled_projects_subquery_sql(user, role_ids)
      ids = Array(role_ids).map(&:to_i).reject(&:zero?)
      return '1=0' if user.nil? || ids.empty?

      "issues.project_id IN (SELECT DISTINCT rrd_m.project_id FROM members rrd_m " \
        "INNER JOIN member_roles rrd_mr ON rrd_mr.member_id = rrd_m.id " \
        "WHERE rrd_m.user_id = #{user.id.to_i} AND rrd_mr.role_id IN (#{ids.join(',')}))"
    end

    # PostgreSQL / MySQL / MariaDB, as the overlay keys its exceptions.
    #
    # MariaDB is its own family and the adapter NAME cannot tell you so — mysql2 reports
    # "Mysql2" for both — so the question is asked of the server version, once, here.
    # Defect D-1 is MariaDB's and not MySQL's, which is exactly why this exists.
    # ONE mapper, not two: AdapterOverlay.family_for owns the name -> family rule and
    # is exercised in the DB-less spec; all this adds is the answer to the question the
    # name cannot carry, read from the live server.
    def overlay_family
      RrdGolden::AdapterOverlay.family_for(adapter_name, mariadb: mysql? && mariadb?)
    end

    # Every role the user holds anywhere, sorted so the generated SQL of a scope
    # built from it does not depend on row order.
    def role_ids_for(user)
      return [] if user.nil?

      ::MemberRole.where(member_id: ::Member.where(user_id: user.id).select(:id))
                  .distinct.pluck(:role_id).compact.sort
    end

    def actor(name)
      id = ACTORS.fetch(name.to_sym) do
        raise ArgumentError, "unknown actor #{name.inspect} — known: #{ACTORS.keys.join(', ')}"
      end
      ::User.find(id)
    end

    # INV-1 says the actor is explicit, and the aggregator reads User.current. Every
    # corpus case therefore names its actor and runs inside this, which restores what
    # it found: a leaked User.current would silently change the next case's numbers.
    def as_actor(name)
      previous = ::User.current
      ::User.current = actor(name)
      yield
    ensure
      ::User.current = previous
    end

    # The scope every spec starts from: the shape IssueQuery#base_scope has, minus
    # Issue.visible (whose SQL is Redmine's, not ours).
    def base_scope
      ::Issue.joins(:status, :project)
    end

    # The whole fixture hangs off this one date, which is what makes it pinnable at
    # all: set RRD_REFERENCE_DATE and every issue, time entry, version and sweep day
    # moves with it coherently. Unset, the fixture stays relative to today, which is
    # what the adapter execution specs want (see RrdGolden::ReferenceDate).
    def today
      RrdGolden::ReferenceDate.date || Time.zone.today
    end

    def reference_date_pinned?
      RrdGolden::ReferenceDate.pinned?
    end

    # Pinning the fixture is not enough on its own, and the first pinned run proved
    # it: every period count came back 0. The aggregator derives its windows from the
    # clock — query_aggregator.rb:1135 is the single clock read, and :2099 records
    # that the SQL deliberately carries no CURRENT_DATE arithmetic — so moving the
    # fixture into the past without moving the clock just empties every window. The
    # pin therefore freezes time as well, and the two stay one fact rather than two
    # that can drift apart.
    #
    # Because the aggregator's only clock read is Ruby-side, freezing Ruby is
    # sufficient: there is no database clock to keep in step.
    #
    # Frozen at the LAST SECOND of the reference day, so `today` is the reference
    # date while every midday-anchored at(n) row — at(0) included — is strictly in
    # the past. Unpinned, at(0) sits at midday against a real `now` that may fall
    # either side of it, so freezing removes a boundary ambiguity rather than adding
    # one.
    # UTC is SET here, not inherited. `Time.zone ||= 'UTC'` at the top of this file
    # only wins when nothing set a zone first, so a corpus generated in a process
    # whose zone came from somewhere else would be pinned to a different instant and
    # bucket its own fixture differently — green locally, red in CI, for a reason
    # nothing in the diff would show. The constant is on the MODULE (see the top of
    # this file) rather than here: inside `class << self` it would land on the
    # singleton class, where RrdAdapterHarness::CORPUS_TIME_ZONE cannot reach it —
    # and the corpus's provenance check compares against it by name.
    def freeze_to_reference_date!
      date = RrdGolden::ReferenceDate.date
      return false unless date

      Time.zone = CORPUS_TIME_ZONE
      time_travel.travel_to(Time.zone.local(date.year, date.month, date.day, 23, 59, 59))
      true
    end

    def unfreeze_time!
      time_travel.travel_back
    end

    # ActiveSupport's time helpers are written as a test-framework mixin, but the
    # fixture is seeded in before(:suite), outside any example — so they are driven
    # from one dedicated object instead of being mixed into every example group.
    def time_travel
      @time_travel ||= Object.new.extend(ActiveSupport::Testing::TimeHelpers)
    end

    # Midday UTC, so no fixture sits on a day boundary the database could round the
    # other way from Ruby.
    def at(days_ago)
      Time.zone.local(today.year, today.month, today.day, 12, 0, 0) - (days_ago * 86_400)
    end

    def seed!
      truncate_all!

      ::Project.insert_all!([
        { id: PROJECT_MAIN,     name: 'Main',     status: 1 },
        { id: PROJECT_ARCHIVED, name: 'Archived', status: 9 },
        { id: PROJECT_SWEEP,    name: 'Sweep',    status: 1 },
        { id: PROJECT_WIDE,     name: 'Wide',     status: 1 }
      ])

      ::IssueStatus.insert_all!([
        { id: STATUS_NEW,         name: 'New',         is_closed: false },
        { id: STATUS_IN_PROGRESS, name: 'In Progress', is_closed: false },
        { id: STATUS_CLOSED,      name: 'Closed',      is_closed: true },
        { id: STATUS_REJECTED,    name: 'Rejected',    is_closed: true }
      ])

      ::Tracker.insert_all!([{ id: 1, name: 'Bug' }, { id: 2, name: 'Feature' }])
      ::IssueCategory.insert_all!([{ id: 1, name: 'Backend', project_id: PROJECT_MAIN }])
      ::IssuePriority.insert_all!([
        { id: 1, name: 'Low',    type: 'IssuePriority' },
        { id: 2, name: 'Normal', type: 'IssuePriority' },
        { id: 3, name: 'High',   type: 'IssuePriority' }
      ])
      ::User.insert_all!([
        { id: ACTORS[:manager],   login: 'alice', firstname: 'Alice', lastname: 'Adams' },
        { id: ACTORS[:developer], login: 'bob',   firstname: 'Bob',   lastname: 'Brown' },
        { id: ACTORS[:reporter],  login: 'carol', firstname: 'Carol', lastname: 'Clark' },
        { id: ACTORS[:auditor],   login: 'dave',  firstname: 'Dave',  lastname: 'Doyle' }
      ])
      seed_memberships!
      ::Version.insert_all!([
        { id: 1, project_id: PROJECT_MAIN, name: 'v1.0', effective_date: today + 30 },
        { id: 2, project_id: PROJECT_MAIN, name: 'v2.0', effective_date: today + 90 }
      ])

      # insert_all! requires every row to carry the same keys, so the columns that
      # only some fields use are spelled out as nil rather than left off.
      ::CustomField.insert_all!([
        { id: CF_DEPARTMENT, type: 'IssueCustomField', name: 'Department', field_format: 'list',
          position: 1, visible: true, multiple: false, possible_values: "Sales\nOps",
          visibility_project_id: nil, visibility_role_id: nil },
        { id: CF_POINTS, type: 'IssueCustomField', name: 'Points', field_format: 'int',
          position: 2, visible: true, multiple: false, possible_values: nil,
          visibility_project_id: nil, visibility_role_id: nil },
        { id: CF_COST, type: 'IssueCustomField', name: 'Cost', field_format: 'float',
          position: 3, visible: true, multiple: false, possible_values: nil,
          visibility_project_id: PROJECT_MAIN, visibility_role_id: nil },
        { id: CF_HIDDEN, type: 'IssueCustomField', name: 'Hidden', field_format: 'list',
          position: 4, visible: false, multiple: false, possible_values: "Yes\nNo",
          visibility_project_id: nil, visibility_role_id: nil },
        { id: CF_CLIENT, type: 'ProjectCustomField', name: 'Client', field_format: 'string',
          position: 5, visible: true, multiple: false, possible_values: nil,
          visibility_project_id: nil, visibility_role_id: nil },
        { id: CF_SALARY, type: 'IssueCustomField', name: 'Salary', field_format: 'float',
          position: 6, visible: false, multiple: false, possible_values: nil,
          visibility_project_id: nil, visibility_role_id: ROLE_MANAGER },
        { id: CF_WIDE, type: 'IssueCustomField', name: 'Work package', field_format: 'list',
          position: 7, visible: true, multiple: false, possible_values: nil,
          visibility_project_id: nil, visibility_role_id: nil }
      ])

      seed_main_project!
      seed_archived_project!
      seed_sweep!
      seed_wide!
    end

    # Three roles, four actors, six memberships. Written out one row at a time
    # instead of generated: which actor is entitled where is the whole point of the
    # fixture, and a loop would make it something the reader has to execute in their
    # head.
    def seed_memberships!
      ::Role.insert_all!([
        { id: ROLE_MANAGER,   name: 'Manager' },
        { id: ROLE_DEVELOPER, name: 'Developer' },
        { id: ROLE_REPORTER,  name: 'Reporter' }
      ])

      memberships = [
        [1, ACTORS[:manager],   PROJECT_MAIN,  ROLE_MANAGER],
        [2, ACTORS[:manager],   PROJECT_SWEEP, ROLE_MANAGER],
        [3, ACTORS[:manager],   PROJECT_WIDE,  ROLE_MANAGER],
        [4, ACTORS[:developer], PROJECT_MAIN,  ROLE_DEVELOPER],
        [5, ACTORS[:developer], PROJECT_WIDE,  ROLE_DEVELOPER],
        [6, ACTORS[:reporter],  PROJECT_WIDE,  ROLE_REPORTER],
        # The same role as the manager, held somewhere else: CF_SALARY resolves for
        # this actor, and its values are still hidden on every MAIN issue.
        [7, ACTORS[:auditor],   PROJECT_WIDE,  ROLE_MANAGER]
      ]

      ::Member.insert_all!(memberships.map { |id, uid, pid, _rid| { id: id, user_id: uid, project_id: pid } })
      ::MemberRole.insert_all!(memberships.map.with_index(1) do |(mid, _uid, _pid, rid), id|
        { id: id, member_id: mid, role_id: rid }
      end)
    end

    # Four issues with exactly known ages, closings and assignments — the fixture
    # every scalar assertion is read off.
    #
    #   1  open,   created 100d ago, assignee alice, est 8.0,  due 10d ago (overdue)
    #   2  closed, created 100d ago, closed 40d ago, assignee bob, est 4.0
    #   3  open,   created 100d ago, closed_on 40d ago BUT status New — a REOPENED
    #      issue, the case that makes open_at_end's status term load-bearing
    #   4  open,   created 5d ago, no assignee, no estimate, no due date
    #
    # `description` covers the one completeness field with a text branch
    # (IS NOT NULL *AND* <> ''): filled on 1 and 4, empty string on 2, NULL on 3.
    def seed_main_project!
      ::Issue.insert_all!([
        { id: 1, project_id: PROJECT_MAIN, tracker_id: 1, status_id: STATUS_NEW, priority_id: 2,
          category_id: 1, fixed_version_id: 1, author_id: 1, assigned_to_id: 1, parent_id: nil,
          done_ratio: 30, subject: 'open old overdue', description: 'has text',
          estimated_hours: 8.0, start_date: today - 100,
          due_date: today - 10, created_on: at(100), updated_on: at(2), closed_on: nil },
        { id: 2, project_id: PROJECT_MAIN, tracker_id: 1, status_id: STATUS_CLOSED, priority_id: 2,
          category_id: 1, fixed_version_id: 1, author_id: 1, assigned_to_id: 2, parent_id: nil,
          done_ratio: 100, subject: 'closed', description: '',
          estimated_hours: 4.0, start_date: today - 100,
          due_date: today - 20, created_on: at(100), updated_on: at(40), closed_on: at(40) },
        { id: 3, project_id: PROJECT_MAIN, tracker_id: 2, status_id: STATUS_NEW, priority_id: 3,
          category_id: nil, fixed_version_id: 2, author_id: 2, assigned_to_id: 1, parent_id: nil,
          done_ratio: 10, subject: 'reopened', description: nil,
          estimated_hours: 2.0, start_date: today - 100,
          due_date: today + 30, created_on: at(100), updated_on: at(1), closed_on: at(40) },
        { id: 4, project_id: PROJECT_MAIN, tracker_id: 2, status_id: STATUS_IN_PROGRESS,
          priority_id: 1, category_id: nil, fixed_version_id: 2, author_id: 1,
          assigned_to_id: nil, parent_id: 1, done_ratio: 0, subject: 'new',
          description: 'also text', estimated_hours: nil,
          start_date: today - 5, due_date: nil, created_on: at(5), updated_on: at(0),
          closed_on: nil }
      ])

      ::CustomValue.insert_all!([
        { customized_type: 'Issue', customized_id: 1, custom_field_id: CF_DEPARTMENT, value: 'Sales' },
        { customized_type: 'Issue', customized_id: 2, custom_field_id: CF_DEPARTMENT, value: 'Ops' },
        { customized_type: 'Issue', customized_id: 3, custom_field_id: CF_DEPARTMENT, value: 'Sales' },
        { customized_type: 'Issue', customized_id: 4, custom_field_id: CF_DEPARTMENT, value: '' },
        { customized_type: 'Issue', customized_id: 1, custom_field_id: CF_POINTS, value: '5' },
        { customized_type: 'Issue', customized_id: 2, custom_field_id: CF_POINTS, value: '3' },
        { customized_type: 'Issue', customized_id: 3, custom_field_id: CF_POINTS, value: '' },
        { customized_type: 'Issue', customized_id: 1, custom_field_id: CF_COST, value: '100.5' },
        { customized_type: 'Issue', customized_id: 2, custom_field_id: CF_COST, value: '200.25' },
        { customized_type: 'Issue', customized_id: 1, custom_field_id: CF_HIDDEN, value: 'nope' },
        # The role-restricted field. Visible to the manager (ROLE_MANAGER in MAIN),
        # hidden from the auditor (ROLE_MANAGER, but only in WIDE), and refused
        # outright to the developer and the reporter, who hold no entitled role at
        # all. Issue 3's empty string stays out of the join either way.
        { customized_type: 'Issue', customized_id: 1, custom_field_id: CF_SALARY, value: '1000.5' },
        { customized_type: 'Issue', customized_id: 2, custom_field_id: CF_SALARY, value: '2000.25' },
        { customized_type: 'Issue', customized_id: 3, custom_field_id: CF_SALARY, value: '' }
      ])

      # 3.5 + 1.5 visible hours on issue 1, 2.0 on issue 2, none on 3 and 4.
      ::TimeEntry.insert_all!([
        { project_id: PROJECT_MAIN, issue_id: 1, user_id: 1, hours: 3.5, spent_on: today - 3 },
        { project_id: PROJECT_MAIN, issue_id: 1, user_id: 2, hours: 1.5, spent_on: today - 2 },
        { project_id: PROJECT_MAIN, issue_id: 2, user_id: 1, hours: 2.0, spent_on: today - 50 }
      ])
    end

    # One open issue in the archived project, with a value for the restricted custom
    # field and a time entry. Both must be invisible through the visibility
    # conditions while the ISSUE itself still counts — the LEFT OUTER joins must not
    # turn into filters.
    def seed_archived_project!
      ::Issue.insert_all!([
        { id: 5, project_id: PROJECT_ARCHIVED, tracker_id: 1, status_id: STATUS_NEW,
          priority_id: 2, category_id: nil, fixed_version_id: nil, author_id: 1,
          assigned_to_id: 2, parent_id: nil, done_ratio: 0, subject: 'archived',
          description: nil, estimated_hours: 16.0,
          start_date: today - 50, due_date: nil, created_on: at(50), updated_on: at(50),
          closed_on: nil }
      ])

      ::CustomValue.insert_all!([
        { customized_type: 'Issue', customized_id: 5, custom_field_id: CF_COST, value: '999.99' },
        { customized_type: 'Issue', customized_id: 5, custom_field_id: CF_DEPARTMENT, value: 'Ops' }
      ])

      ::TimeEntry.insert_all!([
        { project_id: PROJECT_ARCHIVED, issue_id: 5, user_id: 1, hours: 40.0, spent_on: today - 10 }
      ])
    end

    # One open issue per day for SWEEP_DAYS days. Its only job is to make the
    # database's own day/week/month/year bucketing collide with Ruby's labels for
    # whatever today happens to be — including the ISO-week turn of the year, which
    # a fixed fixture date would only exercise on the days it was written for.
    def seed_sweep!
      rows = (0...SWEEP_DAYS).map do |i|
        { id: 1_000 + i, project_id: PROJECT_SWEEP, tracker_id: 1, status_id: STATUS_NEW,
          priority_id: 2, author_id: 1, done_ratio: 0, subject: "sweep #{i}",
          start_date: today - i, created_on: at(i), updated_on: at(i) }
      end
      ::Issue.insert_all!(rows)
    end

    # The cap-boundary fixture: WIDE_ISSUES issues carrying one DISTINCT custom field
    # value each, so MAX_DIMENSION_KEYS (200) is genuinely crossed rather than
    # approached, and spread over WIDE_SPREAD_DAYS days so a period or age split has
    # something in every bucket.
    #
    # In its own project, deliberately. Every existing assertion is read off the four
    # hand-built MAIN issues, and 260 more issues in that scope would rewrite all of
    # them — which is how a fixture extension turns into a spec rewrite.
    #
    # Everything varies by index arithmetic, never by rand: two runs must produce the
    # same bytes (CLAUDE.md §6).
    def seed_wide!
      issues = (0...WIDE_ISSUES).map do |i|
        day = i % WIDE_SPREAD_DAYS
        { id: WIDE_ID_BASE + i, project_id: PROJECT_WIDE, tracker_id: (i % 2) + 1,
          status_id: WIDE_STATUS_CYCLE[i % WIDE_STATUS_CYCLE.length],
          priority_id: (i % 3) + 1, category_id: nil, fixed_version_id: nil,
          author_id: ACTORS[:manager], assigned_to_id: WIDE_ASSIGNEE_CYCLE[i % 3],
          parent_id: nil, done_ratio: (i % 5) * 25, subject: "wide #{i}",
          description: i.even? ? "described #{i}" : nil,
          estimated_hours: (i % 4).zero? ? nil : ((i % 4) * 1.5),
          start_date: today - day, due_date: i.even? ? today - (i % 13) : nil,
          created_on: at(day), updated_on: at(day), closed_on: nil }
      end
      ::Issue.insert_all!(issues)

      # One distinct value per issue — 260 of them, zero-padded so `sort: label` has a
      # total order that does not depend on natural-sort tie-breaking.
      values = (0...WIDE_ISSUES).map do |i|
        { customized_type: 'Issue', customized_id: WIDE_ID_BASE + i,
          custom_field_id: CF_WIDE, value: format('w%03d', i) }
      end
      # A handful of role-restricted values here too: WIDE is where the auditor holds
      # ROLE_MANAGER, so this is the same field being VISIBLE to the actor it is
      # hidden from on MAIN.
      values += (0...4).map do |i|
        { customized_type: 'Issue', customized_id: WIDE_ID_BASE + i,
          custom_field_id: CF_SALARY, value: format('%d.25', (i + 1) * 10) }
      end
      ::CustomValue.insert_all!(values)
    end

    def truncate_all!
      %w[issues custom_values time_entries projects issue_statuses trackers
         issue_categories enumerations users versions custom_fields
         roles members member_roles].each do |table|
        ActiveRecord::Base.connection.delete("DELETE FROM #{table}")
      end
    end

    def sweep_dates
      (0...SWEEP_DAYS).map { |i| today - i }
    end

    # The Ruby side of the bucketing contract, written out here rather than borrowed
    # from QueryAggregator: a spec that called the same helper the implementation
    # calls would agree with it by construction.
    def ruby_label(date, period)
      case period
      when 'day'   then date.strftime('%Y-%m-%d')
      when 'week'  then "#{date.cwyear}-W#{date.cweek.to_s.rjust(2, '0')}"
      when 'month' then date.strftime('%Y-%m')
      when 'year'  then date.strftime('%Y')
      end
    end

    # MySQL/MariaDB only. Runs the block with the strictest GROUP BY mode a
    # production server can be configured with, which is what actually rejects a
    # selected expression that is not in the GROUP BY.
    def with_only_full_group_by
      return yield unless mysql?

      c = ActiveRecord::Base.connection
      previous = c.select_value('SELECT @@SESSION.sql_mode').to_s
      modes = previous.split(',').reject(&:empty?)
      c.execute("SET SESSION sql_mode = '#{(modes | %w[ONLY_FULL_GROUP_BY]).join(',')}'")
      begin
        yield
      ensure
        c.execute("SET SESSION sql_mode = '#{previous}'")
      end
    end
  end
end

if RrdAdapterHarness.configured?
  require 'active_record'
  require_relative '../../lib/sql_aggregation/query_aggregator'

  RSpec.configure do |config|
    config.before(:suite) do
      # Before seed!, so the fixture's timestamps and the aggregator's windows are
      # read off the same clock. A no-op when RRD_REFERENCE_DATE is unset.
      RrdAdapterHarness.freeze_to_reference_date!
      RrdAdapterHarness.connect!
      RrdAdapterHarness.reset_adapter_memo!
      RrdAdapterHarness.define_models!
      RrdAdapterHarness.load_schema!
      RrdAdapterHarness.seed!
    end

    config.after(:suite) { RrdAdapterHarness.unfreeze_time! }
  end
end
