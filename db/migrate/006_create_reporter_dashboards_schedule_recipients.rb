# frozen_string_literal: true

# T-22 — recipients, and the columns this table deliberately does not have.
#
# --- `user_id` ONLY. THIS IS A SECURITY DECISION, NOT A SIMPLIFICATION ---
#
# `technical-spec.md:1202`: "replaces `report_schedules_users` … Gains `id`; **`user_id`
# only** — no free-text `to`/`cc`/`bcc`/`from`, which is the exfiltration-and-spoofing-relay
# finding. A security-motivated schema decision."
#
# The base plugin's ad-hoc mail path takes free-text `to`/`cc`/`bcc` **and `from`**
# (`technical-spec.md:1405-1407`), which is a report over any issue in the instance, mailed
# anywhere, with a forged sender. Removing the columns is what makes that unbuildable
# rather than merely discouraged: §7b.5's redesign resolves recipients as Redmine users
# server-side and puts `From` under server control, and there is nowhere in this schema to
# store anything else.
#
# `spec/migrations/schema_contract_spec.rb` asserts by name that none of the four columns
# exists in ANY table this plugin creates, so a later task adding one back has to argue
# with a failing test rather than with a comment.
#
# --- WHY IT GAINS AN `id` WHERE THE VISIBILITY JOIN TABLE DOES NOT ---
#
# §7's objection to `report_schedules_users` is that it is `id: false`, "so a join row is
# unaddressable". A recipient row is a thing an operator wants to address: remove this one
# person, audit when they were added. That is not true of a visibility pair
# (see 002), which is why the two join tables differ on purpose.
class CreateReporterDashboardsScheduleRecipients < ActiveRecord::Migration[6.1]
  def change
    create_table :reporter_dashboards_schedule_recipients do |t|
      t.integer  :schedule_id, null: false
      t.integer  :user_id,     null: false
      t.datetime :created_at,  null: false
    end

    # UNIQUE: one row per person per schedule. Without it a double-submitted form mails
    # the same person twice, which reads to the recipient as the scheduler misfiring —
    # the very complaint FR-39's index exists to answer, one table over.
    add_index :reporter_dashboards_schedule_recipients, [:schedule_id, :user_id],
              unique: true, name: 'index_rd_recipients_ids'
    add_index :reporter_dashboards_schedule_recipients, :user_id,
              name: 'index_rd_recipients_on_user_id'
  end
end
