# frozen_string_literal: true

# T-28 — THE ONE TOP-LEVEL CONSTANT THIS PLUGIN DEFINES, AND IT IS FORCED BY CORE'S SCHEMA.
#
# --- WHAT MEASUREMENT PUT IT HERE ---
#
# `Reporting::Snapshot` stores a rendered report as a Redmine `Attachment` CONTAINED BY a
# `RedmineReporterDashboards::Document`, because an uncontained attachment is deleted by
# `rake redmine:attachments:prune` after a day (see that class for the full argument).
# Containing it means core writes the container's class name into
# `attachments.container_type` — and that column is
#
#     t.column "container_type", :string, :limit => 30
#
# (`db/migrate/001_setup.rb:28`, narrowed and re-widened but never past 30 by
# `20120223110929_change_attachments_container_defaults.rb`; still 30 on 6.1, checked
# against the running schema). `RedmineReporterDashboards::Document` is **35 characters**,
# so PostgreSQL answered `PG::StringDataRightTruncation` on the first capture ever attempted
# and MySQL would have TRUNCATED it silently, leaving a container_type that resolves to
# nothing.
#
# --- WHY AN ALIAS AND NOT A SECOND CLASS ---
#
# Rails answers this exact problem with `polymorphic_name` (6.0+): a model may declare the
# string it is stored as, and `Document` declares this one. The other half is the read —
# `Attachment.polymorphic_class_for('RrdReportSnapshot')` is `'RrdReportSnapshot'.constantize`
# — so the name has to resolve to the same class rather than to a copy of it. An alias is
# the whole of that: one class, one table, one set of validations, reachable under a name
# short enough for a column core froze in 2012.
#
# **Do not rename it.** The string is written into `attachments.container_type` of every
# stored snapshot; changing it orphans every attachment already on disk, and there is no
# migration that could find them afterwards.
#
# It carries the `Rrd` prefix rather than a bare noun for the reason `technical-spec.md` §7
# gives for every other name in this plugin: simultaneous installation alongside the base
# plugin is a design goal, and a top-level `ReportSnapshot` is exactly the kind of name two
# report plugins both reach for. (The base plugin is deliberately not spelled here — the
# `zero_reporter` gate reads this file and a mention in prose is indistinguishable from a
# reference to it.)
RrdReportSnapshot = RedmineReporterDashboards::Document
