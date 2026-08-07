# frozen_string_literal: true

# T-22 — the snapshot store.
#
# --- READ THIS BEFORE CHANGING A COLUMN: THE SPEC NAMES THIS TABLE AND NO COLUMN OF IT ---
#
# `technical-spec.md:1203` marks it "**required** — it is the snapshot store the share
# links serve from (§7b.1), no longer optional", and `:1213-1217` adds the policy: "do not
# persist by default … Persistence is opt-in with a mandatory TTL and a purge task."
# That is the entire specification. No document in `docs/plan/` states a single column,
# and `functional-spec.md:348` says out loud that "**No retention model has an owner yet**".
#
# So every column below is DERIVED from a stated requirement, and each names the
# requirement it comes from. That is the honest form of a table nobody specified — but it
# is still a derivation, and §7 rule 6 means a consumer that needs a different column
# cannot add one in a later migration. This is the single most likely thing in T-22 that
# T-28 (share links) or T-30 (failure reports) will want changed, and the PR says so.
#
# The bytes themselves are NOT in this table. `attachment_id` points at Redmine's own
# `Attachment`, whose storage, permissions and cleanup are already solved and already
# audited; duplicating a blob store inside a plugin is a support burden with no upside.
# The column is nullable because T-30 owns the write path and may resolve it differently
# — nothing in T-22 creates a row.
class CreateReporterDashboardsDocuments < ActiveRecord::Migration[6.1]
  def change
    create_table :reporter_dashboards_documents do |t|
      t.integer  :template_id
      t.integer  :project_id
      # Which scheduled occurrence produced it, when one did. NULL for an ad-hoc export.
      t.integer  :schedule_run_id

      t.integer  :created_by_id
      # FR-47: "shared output is **labelled with the identity it was rendered as**", and
      # FR-45: that identity is "explicit, stored and auditable". A snapshot served to a
      # share-link holder makes no visibility decision at request time
      # (technical-spec.md:1330-1332), so the identity it was rendered as is the only
      # record of whose numbers these are.
      t.integer  :rendered_as_user_id

      # FR-58's correlation id — the string a user quotes in a bug report.
      t.string   :correlation_id
      # FR-27: "the resolved engine, its version and the render duration are logged once at
      # boot and **stamped into every produced document**". Stamped into the PDF metadata by
      # the render layer; stored here so the stamp is queryable without opening the file.
      t.string   :engine
      t.string   :engine_version
      t.integer  :render_duration_ms

      t.string   :content_type
      # bigint for the same reason as `bytes_total` in 005.
      t.bigint   :byte_size
      t.integer  :page_count
      # SHA-256 hex of the bytes. Lets `import:verify`-style comparison and any
      # "is this the same document" question be answered without re-reading the blob.
      t.string   :digest

      t.integer  :attachment_id

      # MANDATORY, and NOT NULL is how "mandatory" is said in a schema.
      # `technical-spec.md:1215`: "Persistence is opt-in with a **mandatory TTL** and a
      # purge task. That converts an unmanaged indefinite store into 'off by default,
      # bounded when on'." A nullable expiry is exactly the unmanaged indefinite store.
      t.datetime :expires_at, null: false
      # Set by the purge task. Distinct from destroying the row, so an audit can still
      # answer "a document existed here and was purged on this date" after the bytes are
      # gone.
      t.datetime :purged_at

      t.timestamps null: false
    end

    # The purge task's own query. Without it the purge scans the whole table.
    add_index :reporter_dashboards_documents, :expires_at,
              name: 'index_rd_documents_on_expires_at'
    add_index :reporter_dashboards_documents, :template_id,
              name: 'index_rd_documents_on_template_id'
    add_index :reporter_dashboards_documents, :schedule_run_id,
              name: 'index_rd_documents_on_schedule_run_id'
    add_index :reporter_dashboards_documents, :correlation_id,
              name: 'index_rd_documents_on_correlation_id'
  end
end
