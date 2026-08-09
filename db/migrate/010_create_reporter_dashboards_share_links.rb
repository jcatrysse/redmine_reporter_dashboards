# frozen_string_literal: true

# T-28 — share links, and the two tables §7b.1 names explicitly.
#
# --- WHAT THIS REPLACES, AND WHY THE SHAPE IS THE FIX ---
#
# `technical-spec.md` §7b.1: the base plugin's share token is
# `Digest::MD5.hexdigest("Object#1…ReportTemplate#3:#{secret_key_base}")` — no expiry, no
# revocation short of rotating the application secret, and *"the real defect — the token
# BYPASSES THE VISIBILITY CHECK ENTIRELY rather than authorising a specific thing."*
#
# Every column below is one clause of that indictment answered in the schema rather than in
# code, because a rule the schema does not carry is a rule the next `update_all` breaks:
#
#   token_digest   NOT NULL + unique. The TOKEN IS NEVER STORED. A database dump yields no
#                  working link, which is a test in this task and not a hope.
#   expires_at     NOT NULL. §7b.1 says "**mandatory**"; a nullable expiry is precisely the
#                  unexpiring token being replaced, and `reporter_dashboards_documents`
#                  already set this precedent for the same reason (migration 007).
#   revoked_at     nullable — an event that has usually not happened.
#   max_uses       nullable, meaning "no limit"; `use_count` NOT NULL DEFAULT 0 so the
#                  comparison never has a NULL on either side.
#   render_as_user_id
#                  "the identity the content was rendered as, STORED EXPLICITLY". T-25's
#                  review found what an implicit render identity costs, and §7b.1 asks for
#                  it by name.
#
# --- WHY `scope_kind` IS A STRING AND NOT AN `enum` ---
#
# The same reason `Template#visibility` is (see `template.rb`): `enum` has changed signature
# three times inside this plugin's support span and the base plugin is broken on Redmine 7.0
# for exactly that. Core uses constants plus `validates :inclusion`, and so does this.
#
# --- WHY THE ACCESS LOG IS A SECOND TABLE ---
#
# FR-53 wants "every share-link access recorded (timestamp, address, agent)". A counter on
# the link cannot answer "who reached it and when", and `use_count` is deliberately NOT that
# log — it is the number the `max_uses` comparison reads, kept on the row so the check is
# one read rather than an aggregate. The two disagree only if something writes one without
# the other, which is why the model writes both in one transaction.
class CreateReporterDashboardsShareLinks < ActiveRecord::Migration[6.1]
  def change
    create_table :reporter_dashboards_share_links do |t|
      t.integer  :template_id, null: false
      t.integer  :project_id

      # ONLY THE DIGEST. SHA-256 hex of the token, which is 64 characters — the column is
      # sized by `MAX_STRING` in the model rather than here, following every other string
      # column in this schema.
      t.string   :token_digest, null: false

      # `snapshot` | `query` | `issue_ids` — §7b.1's three, closed in the model.
      t.string   :scope_kind, null: false
      # The query id or the issue id list that `query`/`issue_ids` point at. Text rather
      # than a column per kind: the payload's shape depends on the kind, and three mostly
      # NULL columns would be a schema that lies about what is required.
      t.text     :scope_payload

      # `snapshot`'s frozen artefact. NULL for the other two kinds.
      t.integer  :rendered_document_id
      # The identity the content was rendered as. NOT a foreign key to the requester: a
      # link outlives the request that made it, and FR-45's whole point is that the two are
      # different questions.
      t.integer  :render_as_user_id

      t.integer  :created_by_id
      t.string   :purpose

      # MANDATORY. See the header.
      t.datetime :expires_at, null: false
      t.integer  :max_uses
      t.integer  :use_count, null: false, default: 0
      t.datetime :revoked_at
      t.datetime :last_used_at

      # FR-62 / §7b.6: a PUBLIC link is reachable without a Redmine account, is off by
      # default, and is a second decision on top of sharing — which is why it is a column
      # here and a separate permission in `permissions.rb`, not a `scope_kind`.
      t.boolean  :public_link, null: false, default: false

      t.timestamps null: false
    end

    # THE LOOKUP INDEX, AND IT IS UNIQUE. Two links with one digest would mean two answers
    # to "what does this token authorise", and the resolver takes the first — which is the
    # shape of defect that is invisible until it matters.
    add_index :reporter_dashboards_share_links, :token_digest,
              unique: true, name: 'index_rd_share_links_on_token_digest'
    # "Every active link for this template", which is the owner's list and the
    # revoke-all query.
    add_index :reporter_dashboards_share_links, [:template_id, :revoked_at],
              name: 'index_rd_share_links_on_template_and_revoked'
    add_index :reporter_dashboards_share_links, :expires_at,
              name: 'index_rd_share_links_on_expires_at'

    create_table :reporter_dashboards_share_link_accesses do |t|
      t.integer  :share_link_id, null: false
      # §7b.1: "one row per access: timestamp, IP, user agent".
      #
      # NAMED `ip_address` AND NOT `address`, which is not a stylistic choice.
      # `spec/migrations/schema_contract_spec.rb` permits exactly ONE column called
      # `address` in this schema — the ad-hoc mail audit's — because §Findings S-19
      # settled that an address column is a delivery INPUT and a second one is how a
      # mail relay grows. That guard is about EMAIL addresses and this column holds an
      # IP, so the right answer is the precise name rather than a wider guard. §7b.1
      # says "IP" in as many words.
      #
      # `ip_address` and `user_agent` are NULLABLE on purpose. A request behind a proxy that
      # strips them still happened, and a log that refused to record it would lose the
      # access rather than the field — which is the opposite of what an audit is for.
      t.string   :ip_address
      t.string   :user_agent
      # What the request was answered with, so the log distinguishes "somebody opened it"
      # from "somebody tried an expired link". A refusal is the row most worth having.
      t.string   :outcome, null: false

      # `created_at` ONLY — the same append-only shape as
      # `reporter_dashboards_template_versions` (migration 003), and for the same reason:
      # a row that can be updated is not an audit trail, and a column that does not exist
      # cannot be written by a console session either.
      t.datetime :created_at, null: false
    end

    add_index :reporter_dashboards_share_link_accesses, [:share_link_id, :created_at],
              name: 'index_rd_share_accesses_on_link_and_created'
  end
end
