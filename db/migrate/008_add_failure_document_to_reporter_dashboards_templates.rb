# frozen_string_literal: true

# T-30 — FR-59's opt-in.
#
# --- WHY THIS IS A COLUMN AND NOT A SETTING ---
#
# §7b.3 makes the failure document optional "per template/schedule, default off". A plugin
# setting would make it installation-wide, and T-40's `[OQ-F]` decision is the precedent
# against exactly that shape: an install-wide switch over what a report does belongs to
# whoever authors the report, not to whoever installed the plugin.
#
# --- WHY IT IS ON THE TEMPLATE AND NOT ALSO ON THE SCHEDULE ---
#
# Reported rather than decided — see `implementation-plan.md` §Findings **S-11**. §7b.3
# says "per template/schedule"; a schedule renders a template, so the template half covers
# every render, and the schedule half has nowhere to deliver a document to: T-30's own
# acceptance list requires the owner's failure notice to carry **no attachment**, and the
# only other destination is `reporter_dashboards_documents`, whose write path is T-28's.
# A column that nothing reads is worse than an absent one, so this is one column and the
# gap is written down.
#
# --- RULE 6 DOES NOT APPLY AND RULE 5 DOES ---
#
# §7 rule 6 pins `lock_version` and every unique index to their table's own migration.
# This is neither. Rule 5 is the one that applies: a plain column added after 0.6, so the
# model reads it through `Compat.column_present?` and answers `false` when an install has
# the older schema — the failure document is off, which is also its default, so a
# rolled-back install degrades to the behaviour it had before this migration existed.
class AddFailureDocumentToReporterDashboardsTemplates < ActiveRecord::Migration[6.1]
  def change
    add_column :reporter_dashboards_templates, :failure_document, :boolean,
               null: false, default: false
  end
end
