# frozen_string_literal: true

# T-22 — the append-only version trail behind FR-21's audit requirement.
#
# `technical-spec.md:1199`: "new, **append-only**: `template_id author_id content
# content_digest created_at`. INV-9 audit + author rollback."
#
# APPEND-ONLY IS EXPRESSED BY THE ABSENCE OF `updated_at`, and that is the point of not
# writing `t.timestamps` here. A row that can be updated is not an audit trail; a schema
# that offers an `updated_at` invites the first person in a hurry to update one. The model
# enforces it as well (`readonly?`), but a column that does not exist cannot be written by
# a console session either.
class CreateReporterDashboardsTemplateVersions < ActiveRecord::Migration[6.1]
  def change
    create_table :reporter_dashboards_template_versions do |t|
      t.integer  :template_id, null: false
      # Nullable on purpose: a version written by an import or a rake task has no human
      # author, and recording a fake one would make the audit trail lie.
      t.integer  :author_id
      # FR-70 again: no migration reads or writes this column.
      t.text     :content
      # SHA-256 hex of `content`. Cheap divergence detection for `import_status`, and the
      # thing a reviewer compares when asking "did this actually change".
      t.string   :content_digest
      t.datetime :created_at, null: false
    end

    # The only two access patterns: "show me this template's history, newest first" and
    # "find the version with this digest".
    add_index :reporter_dashboards_template_versions, [:template_id, :created_at],
              name: 'index_rd_versions_on_template_and_created'
    add_index :reporter_dashboards_template_versions, :content_digest,
              name: 'index_rd_versions_on_content_digest'
  end
end
