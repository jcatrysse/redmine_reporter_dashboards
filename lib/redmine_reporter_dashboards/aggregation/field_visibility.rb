# frozen_string_literal: true

module RedmineReporterDashboards
  module Aggregation
    # redmine_issue_field_visibility ("ifv") for the aggregation tags. Curator decision
    # 2026-11-25, `docs/DECISIONS-2026-11-25.md`: "Ook de teltags afschermen".
    #
    # ifv hides core issue fields per role and project. The issue drop honours it since
    # ef7ac49; this module makes `{% sql_aggregate %}` (and `{% geo_aggregate %}`) and
    # `{% version_rollup %}` honour it as well, for the render actor and never the ambient
    # user (INV-1). The rule per project in scope, for a field ifv hides from the actor there:
    #
    #   grouping by it       every issue of that project lands in ONE hidden bucket, with no
    #                        drill filter on that axis (kernel hunk `field-visibility`)
    #   measuring it         those issues read NULL, so the value is the visible projects'
    #                        only; the result names the field in `hidden_fields`
    #   flags/completeness   the counters that read it are recomputed over the visible
    #                        projects only, lose their drill filter, and are named in
    #                        `hidden_fields`
    #   filtering on it      the report query's issues in those projects are left out,
    #                        and the author is told (degradation `aggregation_hidden_filter`)
    #   version_rollup       issues of a project that hides any field the rollup reads are
    #                        left out, and the author is told
    #   spent time by        entries of a project that hides version or category are left out
    #   version/category     when grouping by it, and the author is told
    #
    # Without ifv, and for an admin, `hidden_projects` answers {} WITHOUT a query. For any
    # other actor it costs, per tag, one DISTINCT project_id pluck, one Project query and
    # ifv's role lookup per project (memoised on the render's Batch, shared with the drop);
    # that grows with the number of PROJECTS in scope, never with the number of issues. When
    # it answers {} every caller runs exactly the code it ran before: the output is
    # byte-identical, only those statements are added.
    #
    # Set-based throughout. Nothing here loops over issues.
    module FieldVisibility
      # RedmineIssueFieldVisibility::HIDEABLE_CORE_FIELDS on Redmine 7 (Tracker::CORE_FIELDS
      # less done_ratio and parent_issue_id). Anything else ifv answers is ignored here.
      HIDEABLE_FIELDS = %w[assigned_to_id category_id description due_date estimated_hours
                           fixed_version_id priority_id start_date].freeze

      # Query filter name => the hideable field it reads. `issue.` is stripped first, which
      # covers TimeEntryQuery's issue filters.
      FILTER_FIELDS = {
        'assigned_to_id' => 'assigned_to_id', 'member_of_group' => 'assigned_to_id',
        'assigned_to_role' => 'assigned_to_id', 'category_id' => 'category_id',
        'fixed_version_id' => 'fixed_version_id', 'priority_id' => 'priority_id',
        'start_date' => 'start_date', 'due_date' => 'due_date',
        'estimated_hours' => 'estimated_hours', 'estimated_remaining_hours' => 'estimated_hours',
        'total_estimated_hours' => 'estimated_hours', 'description' => 'description',
        # "Search" matches the description text.
        'any_searchable' => 'description'
      }.freeze

      # `assigned_to.cf_5`, `fixed_version.due_date`, `fixed_version.status`, ...
      FILTER_PREFIXES = { 'assigned_to.' => 'assigned_to_id',
                          'fixed_version.' => 'fixed_version_id' }.freeze

      # The legacy `.breakdown` group_by names that read a hideable field.
      BREAKDOWN_FIELDS = { 'assignee' => 'assigned_to_id', 'priority' => 'priority_id',
                           'category' => 'category_id', 'version' => 'fixed_version_id' }.freeze

      # `.flags` counters, and the funnel stage, each hideable field feeds.
      FLAG_KEYS = { 'assigned_to_id' => %w[assigned unassigned],
                    'due_date' => %w[with_due_date without_due_date overdue],
                    'estimated_hours' => %w[no_estimate] }.freeze
      FLAG_STAGES = { 'assigned_to_id' => 'assigned', 'due_date' => 'with_due_date' }.freeze

      # Every hideable field `QueryAggregator.version_rollup` reads.
      ROLLUP_FIELDS = %w[fixed_version_id assigned_to_id estimated_hours due_date start_date].freeze

      # The spent-time dimensions that read an issue field ifv can hide.
      TIME_ENTRY_DIMENSIONS = { 'version' => 'fixed_version_id', 'category' => 'category_id' }.freeze

      module_function

      # { field => [project ids] } for each hideable field the actor may not see in at least
      # one project of `scope`. {} without ifv, without an actor or Batch, and for an admin,
      # in which case no query runs.
      def hidden_projects(scope, render_context, project_column: 'issues.project_id')
        return {} unless ::RedmineReporterDashboards::Liquid::Batch.field_visibility_rule?

        # FAIL CLOSED (INV-3): with the rule installed, a render that cannot say whose
        # visibility applies must not count as "nothing hidden". The tags rescue this into
        # their empty result.
        actor = render_context&.actor
        batch = render_context&.batch
        raise ArgumentError, 'field visibility needs the render actor and its Batch' if actor.nil? || batch.nil?

        # ifv answers [] for an admin itself; asking first saves the pluck.
        return {} if actor.respond_to?(:admin?) && actor.admin?

        ids = scope.unscope(:order).distinct.pluck(Arel.sql(project_column)).compact
        return {} if ids.empty?

        hidden = {}
        ::Project.where(id: ids).order(:id).each do |project|
          (Array(batch.hidden_core_fields(project)) & HIDEABLE_FIELDS).each do |field|
            (hidden[field] ||= []) << project.id
          end
        end
        hidden
      end

      # The bucket label, from the render's locale. Core's `label_hidden` wording.
      def label
        ::I18n.t(:label_reporter_aggregation_hidden, default: 'Hidden')
      end

      # The hideable fields the query filters on, in filter order.
      def filtered_fields(query)
        filters = query.respond_to?(:filters) ? query.filters : nil
        return [] unless filters.respond_to?(:keys)

        filters.keys.filter_map { |name| filter_field(name) }.uniq
      end

      def filter_field(name)
        name = name.to_s.delete_prefix('issue.')
        FILTER_FIELDS[name] || FILTER_PREFIXES.find { |prefix, _| name.start_with?(prefix) }&.last
      end

      # The projects in which any of `fields` is hidden, sorted.
      def projects_hiding(hidden, fields)
        Array(fields).flat_map { |field| Array(hidden[field]) }.uniq.sort
      end

      def without_projects(scope, project_ids, project_column: 'issues.project_id')
        return scope if project_ids.empty?

        scope.where.not(project_column => project_ids)
      end

      # THE FILTER RULE. A query condition on a field the actor cannot see in a project
      # would let a count answer "how many issues there are assigned to X" for that project,
      # so the issues of those projects are left out and the author is told how many
      # projects that was. Answers [scope, hidden map of what remains].
      def apply_filter_rule(scope, query, hidden, diagnostics, tag:, project_column: 'issues.project_id',
                            records: 'issues')
        fields   = filtered_fields(query) & hidden.keys
        excluded = projects_hiding(hidden, fields)
        return [scope, hidden] if excluded.empty?

        degrade(diagnostics, :aggregation_hidden_filter,
                "the report query filters on #{fields.join(', ')}, which is hidden from this " \
                "actor in #{excluded.length} project(s); their #{records} are left out",
                tag: tag, fields: fields.join(', '), projects: excluded.length)
        remaining = hidden.transform_values { |ids| ids - excluded }.reject { |_, ids| ids.empty? }
        [without_projects(scope, excluded, project_column: project_column), remaining]
      end

      # `{% version_rollup %}`: per target version, so a hidden bucket has no row to live in.
      def apply_rollup_rule(scope, hidden, diagnostics)
        fields   = ROLLUP_FIELDS & hidden.keys
        excluded = projects_hiding(hidden, fields)
        return scope if excluded.empty?

        degrade(diagnostics, :aggregation_hidden_rollup,
                "#{fields.join(', ')} is hidden from this actor in #{excluded.length} " \
                'project(s); their issues are left out of the version rollup',
                fields: fields.join(', '), projects: excluded.length)
        without_projects(scope, excluded)
      end

      # Spent time grouped by an issue field the actor cannot see in some projects: those
      # projects' entries are left out rather than shown under their real version/category.
      def apply_time_entry_rule(scope, group_by, hidden, diagnostics)
        field    = TIME_ENTRY_DIMENSIONS[group_by.to_s.strip.downcase]
        excluded = field ? projects_hiding(hidden, [field]) : []
        return scope if excluded.empty?

        degrade(diagnostics, :aggregation_hidden_group,
                "#{field} is hidden from this actor in #{excluded.length} project(s); their " \
                'time entries are left out of this grouping',
                fields: field, projects: excluded.length)
        without_projects(scope, excluded, project_column: 'time_entries.project_id')
      end

      # The legacy `.breakdown` cannot carry a hidden bucket; true sends the tag down the
      # dimension path instead (with `user_label: login`, the legacy label text).
      def breakdown_hidden?(group_by, hidden)
        field = BREAKDOWN_FIELDS[group_by.to_s]
        !field.nil? && hidden.key?(field)
      end

      # `.flags`: the counters that read a hidden field are recomputed over the projects
      # where the actor can see it. One extra `.flags` call per distinct set of hiding
      # projects (one in practice), never per issue.
      def apply_to_flags(result, scope, hidden, &)
        fields = FLAG_KEYS.keys & hidden.keys
        return result if fields.empty? || !result.is_a?(Hash)

        by_set = fields.group_by { |field| hidden[field] }
        by_set.each do |project_ids, set_fields|
          visible = yield(without_projects(scope, project_ids))
          set_fields.each do |field|
            FLAG_KEYS[field].each do |key|
              result[key] = visible[key]
              result['flags'][key] = visible[key] if result['flags'].is_a?(Hash)
            end
            stage = Array(result['stages']).find { |entry| entry['key'] == FLAG_STAGES[field] }
            next if stage.nil?

            stage['count']  = visible[stage['key']]
            stage['filter'] = nil
            # no URL at all: a nil filter alone means "the report query unchanged"
            stage['hidden'] = true
          end
        end
        result['hidden_fields'] = fields
        result
      end

      # `.completeness`: a hidden field's bucket is recomputed over the projects where the
      # actor can see it (so its `total` and `pct` are of those issues), and loses both
      # drill filters.
      def apply_to_completeness(result, scope, hidden, &)
        return result unless result.is_a?(Hash)

        fields = Array(result['fields']) & hidden.keys
        return result if fields.empty?

        fields.group_by { |field| hidden[field] }.each do |project_ids, set_fields|
          visible = yield(without_projects(scope, project_ids), set_fields)
          next unless visible.is_a?(Hash)

          Array(visible['buckets']).each do |bucket|
            index = result['buckets'].index { |entry| entry['value'] == bucket['value'] }
            next if index.nil?

            result['buckets'][index] = bucket.merge('filter' => nil, 'empty_filter' => nil)
          end
        end
        result['hidden_fields'] = fields
        result
      end

      # The hidden bucket's group key (-1, or the kernel's text marker) is not a value a
      # template should see: `value` reads nil and `values` (an Other row) leaves it out.
      def scrub_sentinels(result)
        return result unless result.is_a?(Hash) && result.key?('hidden_fields')

        keys = [SqlAggregation::QueryAggregator::HIDDEN_ID_KEY.to_s,
                SqlAggregation::QueryAggregator::HIDDEN_TEXT_KEY]
        %w[buckets rows series_entries].each do |name|
          Array(result[name]).each do |entry|
            next unless entry.is_a?(Hash)

            entry['value'] = nil if keys.include?(entry['value'])
            entry['values'] -= keys if entry['values'].is_a?(Array)
          end
        end
        result
      end

      def degrade(diagnostics, code, message, **data)
        Rails.logger.warn("[field_visibility] #{message}")
        diagnostics&.degrade(code, detail: message, **data)
      end
    end
  end
end
