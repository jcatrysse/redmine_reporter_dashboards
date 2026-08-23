# frozen_string_literal: true

# T-32 — the ad-hoc mail audit, and the two tables FR-61 cannot be built without.
#
# --- WHY A TABLE AT ALL, WHEN §7's LIST DOES NOT NAME ONE ---
#
# `technical-spec.md` §7's table list was written before T-32 and stops at
# `reporter_dashboards_documents`. §7b.5 and FR-61 nonetheless require two things that are
# *state*, not behaviour:
#
#   "Every send is **audited**: who, when, which template, which issues, which recipients —
#    visible to admins."
#   "Rate-limited per user."
#
# Neither is expressible without somewhere to put a row, and the section says why it
# matters in its own words: *"today nothing records what left the building. Now there is a
# log you can answer questions from."* So the columns are DERIVED here from stated
# requirements and recorded for the curator, which is the precedent §7 itself sets for
# `reporter_dashboards_documents` ("Columns approved by the curator 2026-08-07, having been
# derived in T-22 from stated requirements rather than specified here"). See §Findings S-19.
#
# --- THE RATE LIMIT READS THIS TABLE, AND THAT IS WHY THE ROW IS WRITTEN FIRST ---
#
# The alternative was a counter column somewhere. It would have been a second source of
# truth for a question this table already answers, and HANDOVER §1 has the entry about a
# diagnostic built on a column the happy path does not write. Here the happy path writes
# every row, so the limit counts ATTEMPTS rather than successes — which is the difference
# between a limit and a suggestion, because a failing render is still a render somebody
# made this worker do.
#
# The row is therefore claimed BEFORE the render, exactly as T-25's runner claims an
# occurrence before delivering it, and finished afterwards. A crash between the two leaves
# a `running` row, which is honest: something was started and nobody knows how it ended.
#
# --- WHY THE RECIPIENTS ARE A SECOND TABLE AND NOT A TEXT COLUMN ---
#
# `recipients_raw` is one of the names `spec/migrations/schema_contract_spec.rb` forbids
# across every table this plugin creates, and it is forbidden for a good reason rather than
# a naming one: a blob of addresses is unqueryable, so "has anything ever gone to
# example.com" becomes a LIKE over free text. A row per recipient is addressable, which is
# the same argument §7 makes for `reporter_dashboards_schedule_recipients` gaining an `id`.
#
# --- `address` IS NULLABLE AND IS THE ONE ADDRESS COLUMN IN THIS SCHEMA ---
#
# It is also the only one that will ever be permitted, and the schema contract spec was
# TIGHTENED rather than loosened to say so: `address` is now forbidden in every table but
# this one, so the next task that wants an address column argues with a red example.
#
# The distinction that makes it safe is the direction of the data flow. The columns §7
# refuses (`to`/`cc`/`bcc`/`from` on a schedule) are **delivery inputs**: a stored string a
# later run reads and mails to. This one is a **record of a decision already taken** —
# written after `Reporting::MailPolicy` has accepted the address against the admin setting
# and the domain allowlist, and read by nothing that sends. `spec/reporting/
# adhoc_delivery_spec.rb` asserts the delivery never names this model at all.
#
# Without it the audit cannot answer the only question an external address makes anyone ask,
# which is *where did it go* — and an audit that records that a report left the building
# without recording where is not an audit.
class CreateReporterDashboardsMailSends < ActiveRecord::Migration[6.1]
  def change
    create_table :reporter_dashboards_mail_sends do |t|
      # WHO and WHEN. `author_id` is the requester, never the render identity: an ad-hoc
      # send renders as the person who asked for it and there is no second identity to
      # store (FR-61's "issues resolve through the requester's visible scope").
      t.integer  :author_id,  null: false
      t.integer  :project_id, null: false

      # WHICH TEMPLATE — both as a reference and as the name it had at the time.
      #
      # The reference goes null when the template is deleted (`nullify`, in the model), and
      # an audit row whose only answer to "which template" is a dangling integer answers
      # nothing. A renamed template has the same problem more quietly. `template_name` is
      # therefore a copy taken at send time, which is what an auditor is actually asking
      # about — and `source` is copied for the same reason, because a template can be
      # switched from issues to time entries afterwards and the row would then misdescribe
      # what was sent.
      t.integer  :template_id
      t.string   :template_name
      t.string   :source

      # WHICH ISSUES. Nullable, because naming a set is optional — the common send is "this
      # template over the project", and `query_id` is the other way of narrowing it.
      #
      # A text column of ids rather than a join table, deliberately: these are the ids the
      # REQUEST named, kept verbatim so the audit records what was asked for. They are not
      # a relation to traverse, nothing reads them back, and a join table would invite a
      # reader to believe they still describe live rows.
      t.text     :issue_ids
      t.integer  :query_id
      t.string   :query_type

      # WHAT HAPPENED. Same vocabulary as `reporter_dashboards_schedule_runs`, so an
      # operator reading both surfaces meets one set of words.
      t.string   :status,      null: false
      t.text     :error
      t.string   :correlation_id
      t.integer  :recipients_count
      t.integer  :external_count
      t.integer  :document_count
      t.integer  :bytes_total
      t.integer  :duration_ms
      t.datetime :finished_at

      # NOT `t.timestamps`. There is no `updated_at` here for the same reason
      # `ScheduleRun` has none: `created_at` and `finished_at` already say when the send was
      # asked for and when it ended, and a third timestamp invites a reader to trust the
      # wrong one. `created_at` is `null: false` because the rate limit counts on it.
      t.datetime :created_at, null: false
    end

    # THE RATE LIMIT'S INDEX, and §7 rule 6 is why it is here rather than in a later
    # migration: a limit is only as strong as the index it counts on, and an index added
    # later is an index a partially-migrated install does not have.
    add_index :reporter_dashboards_mail_sends, [:author_id, :created_at],
              name: 'index_rd_mail_sends_on_author_and_created'
    add_index :reporter_dashboards_mail_sends, :project_id,
              name: 'index_rd_mail_sends_on_project_id'
    add_index :reporter_dashboards_mail_sends, :template_id,
              name: 'index_rd_mail_sends_on_template_id'

    create_table :reporter_dashboards_mail_send_recipients do |t|
      t.integer  :mail_send_id, null: false
      # EXACTLY ONE OF THESE TWO IS SET, enforced in the model rather than by the database:
      # a CHECK constraint is not portable across the three engines this plugin runs on,
      # and expressing it as one would be a fourth dialect to keep in step.
      t.integer  :user_id
      t.string   :address
      t.datetime :created_at, null: false
    end

    add_index :reporter_dashboards_mail_send_recipients, :mail_send_id,
              name: 'index_rd_mail_recipients_on_send_id'
    # NOT UNIQUE, and the contrast with `index_rd_recipients_ids` is deliberate. That one
    # refuses the same person twice on a SCHEDULE, because a duplicate there means the same
    # person is mailed twice every week. This is a log: if a requester somehow addressed the
    # same person twice in one send, the honest record is two rows saying so.
    add_index :reporter_dashboards_mail_send_recipients, :user_id,
              name: 'index_rd_mail_recipients_on_user_id'
  end
end
