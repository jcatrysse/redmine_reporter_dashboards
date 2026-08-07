# frozen_string_literal: true

# T-22 — the report template table, and the join table its `visibility` column needs.
#
# --- WHY [6.1] AND NOT SOMETHING NEWER ---
#
# `technical-spec.md:1471` says it in as many words: "New migrations target
# `ActiveRecord::Migration[6.1]`." It is not a style preference, it is the only value that
# parses on every Rails in the support span. MEASURED, on this machine:
#
#   Rails 6.1.7.10  activerecord-6.1.7.10/lib/active_record/migration/compatibility.rb:16
#                   `V6_1 = Current` — 6.1 is the newest constant that exists
#   Rails 7.2.3.2   Compatibility.constants -> V4_2 … V7_2
#   Rails 8.1.3.1   Compatibility.constants -> V4_2 … V8_1
#
# So [6.1] resolves on all three; [7.2] raises `ArgumentError: Unknown migration version`
# on Redmine 5.1 before a single statement runs.
#
# --- WHY TWO TABLES IN ONE MIGRATION ---
#
# `visibility` and the roles it can name are one feature. §7 rule 6 forbids adding an index
# in a later migration than its table because "an index added later is an index a
# half-migrated install does not have"; the same argument applies to a join table without
# which one of the column's three values cannot be honoured at all. See the `visibility`
# comment below.
class CreateReporterDashboardsTemplates < ActiveRecord::Migration[6.1]
  def change
    create_table :reporter_dashboards_templates do |t|
      # NULL is meaningful and deliberate: a template with no project is
      # installation-wide, and `technical-spec.md:663` records that Redmine has no role
      # grant outside a project, so `project_id IS NULL` is admin-only by construction.
      t.integer :project_id
      # NOT NULL because `edit_own_reporter_dashboards_templates` (technical-spec.md §4.1)
      # is answered from this column. A template whose author is unknown is a template
      # nobody can be said to own, and the permission would fail open or closed by accident.
      t.integer :author_id, null: false

      t.string  :name, null: false
      t.text    :description
      # The Liquid source. FR-70: no schema migration may read or write this column, which
      # is why the importer is a rake task (T-24) and never a migration.
      t.text    :content

      # --- source / output: the two axes reporter's single `type` conflated ---
      #
      # §7's table cell still says "STI `type`". Four other places say the opposite and say
      # it more recently — `implementation-plan.md:1979` ("template types by `source` field
      # (T-31), **not a subclass tree**"), `technical-spec.md:1392` ("Do not reproduce the
      # branch. Make the data source a field"), FR-60, and `[OQ-H]`, which is CLOSED with
      # "as a `source` field, not a branch". A column literally named `type` is Rails' STI
      # discriminator whether or not anyone wants it to be, so writing one would build the
      # subclass tree those four forbid.
      #
      # They are two axes, not one, and reporter's three type values collapsed them:
      #   IssueReportTemplate      -> source: issues,       output: per_record
      #   IssueListReportTemplate  -> source: issues,       output: combined
      #   TimeEntriesReportTemplate-> source: time_entries, output: combined
      # FR-36 ("one document per issue, and one document for a set") is the `output` axis;
      # FR-60 ("reporting over time entries … through a `source` field") is the `source`
      # axis. One three-valued column cannot express "a per-record report over time
      # entries", which is why there are two.
      #
      # Strings, not integers and not `enum`. See the model for why `enum` is avoided.
      t.string  :source, null: false, default: 'issues'
      t.string  :output, null: false, default: 'combined'

      # --- visibility: T-40's column, landing in T-22 as §7 rule 6 requires ---
      #
      # `manage_public_reporter_dashboards_templates` governs nothing without it
      # (technical-spec.md:613-618), and rule 6 forbids adding it in a later migration than
      # its table — so it is here rather than in T-23.
      #
      # Integer with Redmine's own values, from `app/models/query.rb:259-261`:
      #   0 VISIBILITY_PRIVATE   1 VISIBILITY_ROLES   2 VISIBILITY_PUBLIC
      # Core's own column is `add_column :queries, :visibility, :integer, default: 0`
      # (20130710182539_add_queries_visibility.rb:3) and carries no NOT NULL. This one does:
      # a NULL visibility is not one of the three answers, and a permission check that has
      # to guess is the failure this column exists to prevent.
      t.integer :visibility, null: false, default: 0

      t.string  :orientation, null: false, default: 'portrait'
      t.string  :page_size,   null: false, default: 'A4'
      # Millimetres, "top,right,bottom,left" — a plain string rather than a serialised
      # Hash. NOTHING in this schema uses `serialize`, deliberately: CLAUDE.md §5's entry
      # records that a non-YAML coder is silently discarded on Rails 6.1, and Rails 7.1's
      # safe-YAML default changes what a stored Hash round-trips to. A four-number string
      # has none of that surface and reads the same on every Rails in the span.
      t.string  :margins

      # One of §7 rule 5's three forward-compatibility columns, guarded by
      # `RedmineReporterDashboards::Compat.column_present?`.
      t.string  :engine_hint
      t.boolean :enabled, null: false, default: true

      # T-24's import provenance. `technical-spec.md:1275`: "the importer records
      # `source_template_id` + `source_digest`, and `rake reporter_dashboards:import_status`
      # reports divergence" — drift becomes visible instead of silent.
      t.integer :source_template_id
      t.string  :source_digest

      # §7 rule 6: created with the table, never added later.
      t.integer :lock_version, null: false, default: 0

      t.timestamps null: false
    end

    # EVERY index in this plugin is named explicitly, and the reason is a defect this
    # migration hit on its first real run: Rails' derived name for
    # `[:project_id, :visibility]` is
    # `index_reporter_dashboards_templates_on_project_id_and_visibility` — 64 characters
    # against PostgreSQL's 63-character identifier limit, so `rake redmine:plugins:migrate`
    # aborted mid-table. MySQL's limit is 64, so the same migration would have SUCCEEDED
    # there: a plugin that installs on one engine and refuses on another, decided by the
    # length of a column name. `index_rd_` is short enough that no index in this schema is
    # within twenty characters of either limit.
    add_index :reporter_dashboards_templates, [:project_id, :name],
              name: 'index_rd_templates_on_project_and_name'
    add_index :reporter_dashboards_templates, :author_id,
              name: 'index_rd_templates_on_author_id'
    add_index :reporter_dashboards_templates, [:project_id, :visibility],
              name: 'index_rd_templates_on_project_and_visibility'

    # UNIQUE, and it is T-24's idempotency made structural rather than hoped for — the
    # same move as the scheduler's `[schedule_id, occurrence_date]`. "import:run …
    # idempotent, stamping source id and digest" (implementation-plan.md:1993) means a
    # second run must find the existing row rather than make a second one.
    #
    # Multiple NULLs are permitted by every engine this plugin runs on (PostgreSQL's
    # default NULLS DISTINCT, InnoDB on both MySQL and MariaDB), so hand-authored
    # templates — which are the normal case and all carry NULL here — are unaffected.
    add_index :reporter_dashboards_templates, :source_template_id, unique: true,
              name: 'index_rd_templates_on_source_template_id'

    # --- the join table `visibility = VISIBILITY_ROLES` cannot work without ---
    #
    # §7's table list does not mention it. That is an omission rather than a decision:
    # Redmine's own `Query` has `has_and_belongs_to_many :roles` (query.rb:265) and
    # validates that the role list is non-blank when visibility is ROLES (query.rb:277),
    # so shipping the column without the table would ship a value an administrator can
    # select and the code can never honour. Rule 6 forbids adding it later.
    #
    # `id: false` follows core's `queries_roles`
    # (20130602092539_create_queries_roles.rb:3-7). §7 rejects `id: false` for
    # `report_schedules_users`, and for a reason that does not reach here: a RECIPIENT row
    # is a thing you want to address, revoke and audit. A visibility pair carries nothing
    # beyond the pair itself.
    create_table :reporter_dashboards_templates_roles, id: false do |t|
      t.integer :template_id, null: false
      t.integer :role_id,     null: false
    end

    add_index :reporter_dashboards_templates_roles, [:template_id, :role_id],
              unique: true, name: 'index_rd_templates_roles_ids'
  end
end
