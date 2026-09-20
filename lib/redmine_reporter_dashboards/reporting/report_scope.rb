# frozen_string_literal: true

module RedmineReporterDashboards
  module Reporting
    # T-31 — the ONE place that decides which rows a report is about.
    #
    # --- WHY THIS EXISTS, AND IT IS A BLOCKER'S WORTH OF REASON ---
    #
    # It did not, and the two callers disagreed. `TemplatesController` learned to branch on
    # `template.source`; `ScheduledDelivery` did not, and kept building `Issue.visible` for
    # every schedule. An independent review measured the result: a `source: time_entries`
    # template delivered by the scheduler rendered over the ISSUE scope and mailed
    # `COUNT=[7]` — the issue count — where the actor's visible entry count was 3, with
    # `ok=true`, no diagnostic and nobody told. That is §Findings **S-13** exactly, on the
    # one path that has an audience, and it shipped in the commit whose subject was "the
    # wrong-numbers path is closed first".
    #
    # Two callers deciding the same thing separately is what produced it, so there is now
    # one of them. A third caller — an API, T-32's ad-hoc mail — gets both sources for free
    # and cannot get this wrong by omission.
    #
    # --- THE PROJECT CONSTRAINT, AND WHY IT IS APPLIED HERE RATHER THAN TRUSTED ---
    #
    # A saved query is not bounded by the project whose page you opened. MEASURED: a global
    # `TimeEntryQuery` viewed at `/projects/ecookbook/…` returned rows from projects 1 AND 3,
    # and assigning `query.project = project` — core's own idiom — does NOT change that
    # (`base_scope.pluck(:project_id).uniq` was `[1, 3]` before and after). T-23 inherited
    # the looseness on the issue path where it was merely surprising; T-31 makes it wrong,
    # because the S-14 notice makes a claim about the CURRENT project's roles while the
    # figures could come from another one.
    #
    # So the constraint is explicit, and the two paths get DIFFERENT bounds — see `resolve`,
    # which is where the reasoning and the measurement that corrected it live. Each bound is
    # a tightening of what it replaced and neither widens anything.
    #
    # --- ONE DELIBERATE DIFFERENCE BETWEEN THE CALLERS, AND IT IS AN ARGUMENT ---
    #
    # An unresolvable query id is IGNORED interactively and RAISES for a schedule.
    # `ScheduledDelivery`'s own comment is the argument and it is kept: nobody is probing a
    # scheduler, so the disclosure reasoning does not apply — and the fallback there would be
    # much worse, because a schedule configured for "blocked, high priority" would quietly
    # start mailing every row in the project under the same name.
    module ReportScope
      # Raised only when `on_missing_query: :raise`. `ScheduledDelivery` rescues it into a
      # typed failure; the interactive path never asks for it.
      class UnresolvableQuery < StandardError; end

      SOURCES = %w[issues time_entries].freeze

      module_function

      # Answers `[scope, query]`. `scope` is nil for a source this version does not know —
      # never a fallback to issues, which is the whole defect above wearing a smaller hat.
      # `ReportRun` refuses such a template with a typed diagnostic.
      def build(template:, actor:, project: nil, query_id: nil, on_missing_query: :ignore)
        case template.source.to_s
        when 'issues'
          resolve(::IssueQuery, ::Issue, actor, project, query_id, on_missing_query)
        when 'time_entries'
          resolve(::TimeEntryQuery, ::TimeEntry, actor, project, query_id, on_missing_query)
        else
          [nil, nil]
        end
      end

      # `query_class.visible(actor)` and not `find_by` on its own: `base_scope` already starts
      # from the model's `visible` scope, so no rows could leak either way — but an arbitrary
      # id would still let a caller learn that somebody else's private query exists and
      # confirm its filters through the shape of the result. `visible` is also STI-scoped, so
      # an issue template cannot borrow a time-entry query or the reverse.
      # THE TWO PATHS GET DIFFERENT BOUNDS, and the first version got this wrong in a way
      # the suite caught immediately: it applied the SUBTREE bound to both, which WIDENED
      # the default path from "this project" to "this project and its descendants" and moved
      # eleven existing counts. Each bound is a tightening of what it replaced, and neither
      # widens anything:
      #
      #   no query   exactly this project — T-23's behaviour, unchanged
      #   a query    this project's SUBTREE — narrowed from unbounded
      #
      # The asymmetry is the point. The default scope is "the page you are on". A saved query
      # is an explicit authoring choice that may legitimately roll several projects up, so
      # narrowing it to a single id would break that on purpose; the subtree is what Redmine
      # itself means by a project's data (`Query#project_statement` unions the descendants).
      #
      # --- WHERE INV-1 ACTUALLY RESTS ON THE QUERY PATH, SAID OUT LOUD (T-51) ---
      #
      # `actor` is threaded explicitly and the no-query branch below uses it. The QUERY branch
      # does not: `Query#base_scope` calls `Issue.visible` / `TimeEntry.visible` with NO
      # argument, so it reads `User.current`. What holds INV-1 there is `Snapshot#as` and
      # `ScheduledDelivery#as`, which set `User.current` to the actor around the render — not
      # the threading in this file. That is pre-existing and T-51 does not change it; it is
      # written down because a reader of this method would otherwise conclude the opposite,
      # and a comment that implies coverage it does not have is the defect this repository
      # keeps finding in its own prose.
      def resolve(query_class, model, actor, project, query_id, on_missing_query)
        query = find_query(query_class, actor, query_id, on_missing_query)
        relation = query ? query.base_scope : model.visible(actor)

        [within(relation, bound_project_ids(project: project, query: query)), query]
      end

      # WHICH PROJECT IDS THIS RESOLVE WILL APPLY, AS A FUNCTION SOMEBODY ELSE CAN ASK.
      #
      # `resolve` used to inline this branch, and T-52 needed the same answer one layer up:
      # the my-page widget's spent-time notice makes a claim about visibility, and a claim
      # about a DIFFERENT set of projects than the figures cover is §Findings S-14's shape.
      # An independent review measured exactly that — a widget bound to a subtree, a notice
      # asked about the root, and a reader given silence over a figure that had dropped two
      # of three rows in a descendant.
      #
      # So the branch lives once and both callers ask it, rather than the notice keeping a
      # copy that can drift from the bound. `reporter_dashboards_report_scope_test.rb`
      # asserts the two agree on the projects the scope actually returns.
      #
      #   no project   nil              nothing is constrained
      #   a query      the setting's answer — see `project_bound_ids`
      #   no query     exactly this project, and DECISIONS-PENDING #19 is why it is not
      #                the setting's answer here too
      def bound_project_ids(project:, query:)
        return nil if project.nil?

        query ? project_bound_ids(project) : [project.id]
      end

      def find_query(query_class, actor, query_id, on_missing_query)
        return nil if query_id.to_s.strip.empty?

        query = query_class.visible(actor).find_by(id: query_id)
        return query if query

        if on_missing_query == :raise
          raise UnresolvableQuery,
                "this report is built on saved query #{query_id}, which " \
                "#{actor.respond_to?(:login) ? actor.login : actor} cannot see — it was " \
                'deleted, made private, or the permissions changed. Nothing was sent, ' \
                'because the alternative is mailing a different report under the same name'
        end

        # ONE ANSWER FOR "gone" AND "not yours", on the interactive path. Telling them apart
        # is the disclosure `visible` is there to prevent.
        nil
      end

      # Both models name the column `project_id` on their own table, so one clause serves
      # both relations. A nil id list means "no project context" — a template outside a
      # project, which the schema permits — and constrains nothing.
      def within(scope, project_ids)
        return scope if scope.nil? || project_ids.nil?

        scope.where(project_id: project_ids)
      end

      # T-51 — WHICH PROJECTS "THIS PROJECT" MEANS, AND REDMINE ALREADY DECIDED THAT.
      #
      # This answered the subtree unconditionally, which is right on a default installation and
      # wrong on one that switched subprojects off. Measured on Redmine 5.1 with one global
      # `IssueQuery` on project 1's surface (`docs/plan/reference/verification-project-scope.md`):
      #
      #   setting ON    Redmine's own issue list 10 rows `[1,3,5]`   this method 10 `[1,3,5]`
      #   setting OFF   Redmine's own issue list  4 rows `[1]`       this method 10 `[1,3,5]`
      #
      # `Setting.display_subprojects_issues?` is what Redmine's own list consults
      # (`Query#project_statement`, `redmine/app/models/query.rb:965-968`), it ships ON
      # (`config/settings.yml:229`), and an administrator who turns it off is asking for exactly
      # the narrowing the OFF row shows. So the setting decides here too.
      #
      # --- WHY THE SETTING RATHER THAN `project_statement` ITSELF ---
      #
      # Two earlier drafts of this task assigned the project to the query and let
      # `project_statement` answer, which is literally what `QueriesHelper#retrieve_query` does.
      # A red team and an independent review each built it and measured the same consequence:
      # `IssueQuery` offers its `project_id` FILTER only while the query has no project, so
      # assigning one removes that filter from the drill-through query's `available_filters`,
      # the URL still emits it and the receiving list discards it. A figure of 3 linked to a
      # list of 10. Reading one setting keeps the query object untouched and keeps that link
      # exactly as it is.
      #
      # BOTH SOURCES, deliberately. `ReportScope` serves issues and time entries through one
      # `resolve`, and `Query#project_statement` is shared, so Redmine's own spent-time list
      # honours the same issue-named setting. Matching that is the point; `docs/user-guide.md`
      # says so where an administrator reads it.
      #
      # ARCHIVED DESCENDANTS ARE EXCLUDED EITHER WAY, and that is belt and braces rather than
      # the load-bearing part: `Project.allowed_to_condition`, inside `Issue.visible` and
      # `TimeEntry.visible`, already excludes them for everybody including an administrator.
      def project_bound_ids(project)
        return nil if project.nil?

        ids = [project.id]
        return ids unless subprojects_included?
        return ids unless project.respond_to?(:descendants)

        ids + project.descendants.where.not(status: ::Project::STATUS_ARCHIVED).ids
      end

      # `respond_to?` because this module is driven by doubles in the DB-less suite, where
      # `Setting` may not be the real class. An installation always has it; a spec that does
      # not gets the default, which is Redmine's own default.
      def subprojects_included?
        return true unless defined?(::Setting) && ::Setting.respond_to?(:display_subprojects_issues?)

        ::Setting.display_subprojects_issues?
      end
    end
  end
end
