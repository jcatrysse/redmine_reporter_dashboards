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
      def resolve(query_class, model, actor, project, query_id, on_missing_query)
        query = find_query(query_class, actor, query_id, on_missing_query)
        return [within(query.base_scope, project_subtree_ids(project)), query] if query

        [within(model.visible(actor), project ? [project.id] : nil), nil]
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

      def project_subtree_ids(project)
        return nil if project.nil?

        ids = [project.id]
        if project.respond_to?(:descendants)
          ids += project.descendants.where.not(status: ::Project::STATUS_ARCHIVED).ids
        end
        ids
      end
    end
  end
end
