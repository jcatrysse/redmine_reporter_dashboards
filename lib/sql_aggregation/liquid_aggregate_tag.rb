# frozen_string_literal: true

require_relative 'scope_resolution'

module SqlAggregation
  # Liquid tag: {% sql_aggregate ... %}   (legacy alias: {% geo_aggregate ... %})
  #
  # Runs server-side SQL aggregation and assigns results to a Liquid variable.
  # Replaces expensive {% for issue in issues %} loops in report templates.
  #
  # Usage (primary — uses the issues drop already in context):
  #   {% sql_aggregate from: issues, period: month, periods: 6,
  #      closed_statuses: "Closed;Rejected", assign_to: stats %}
  #
  # Usage (after reporter plugin fix exposes query_id):
  #   {% sql_aggregate query_id: query_id, period: week, periods: 13,
  #      closed_statuses: "Closed;Rejected", assign_to: stats %}
  #
  # Usage (custom field breakdown, crosstab, age histogram, KPI tiles):
  #   {% sql_aggregate from: issues, group_by: cf_92, sort: count, limit: 10,
  #      assign_to: by_department %}
  #   {% sql_aggregate from: issues, group_by: cf_92, split_by: cf_86, assign_to: matrix %}
  #   {% sql_aggregate from: issues, group_by: period, split_by: cf_86,
  #      period: month, periods: 12, assign_to: per_month %}
  #   {% sql_aggregate from: issues, group_by: age, age_buckets: "30;60;90;180", assign_to: ages %}
  #   {% sql_aggregate from: issues, group_by: flags, closed_statuses: "Closed;Rejected", assign_to: kpi %}
  #
  # --- Dimensions (group_by / split_by) ---
  #
  #   status | priority | tracker | assignee | author | category | version
  #   cf_<id>   issue custom field by numeric id (cf_92)
  #   period    date bucket    — period / periods / date_field
  #   age       age bucket     — age_buckets / age_field
  #   flags     scalar counters — group_by only, never split_by
  #
  # --- Parameters ---
  #
  #   assign_to       — result variable name                     (default: stats)
  #   from            — Liquid var holding the issues drop       (default: issues)
  #   query_id        — IssueQuery id to aggregate instead
  #   group_by        — dimension; switches to breakdown mode
  #   split_by        — second dimension; requires group_by, produces a crosstab
  #   period          — day | week | month | year                (default: month)
  #   periods         — number of periods back  (default 30/13/6/3, capped 90/52/24/10)
  #   months          — backward-compatible alias for periods when period is month
  #   date_field      — created | closed: which timestamp `period` buckets on (default: created)
  #   closed_statuses — semicolon/comma-separated status names (else the is_closed flag)
  #   sort            — count (desc) | label (asc, natural) | position  (default: count)
  #   limit           — keep the top N rows, remainder collapses into `other_label` (default: 0 = all)
  #   other_label     — label of the collapsed row                (default: Other)
  #   empty_label     — label of the no-value row (default: (none); Unassigned for assignee)
  #   age_buckets     — ascending day boundaries                 (default: 30;60;90;180)
  #   age_field       — created | updated | due                  (default: created)
  #   user_label      — name | login for the assignee/author dimensions (default: name)
  #
  # sort / limit / other_label are IGNORED for `period` and `age`: those axes are
  # always in chronological / ascending order and include their empty buckets.
  #
  # --- Result keys ---
  #
  #   Time series (no group_by): labels, created, closed, open_now, total, period, periods
  #   Breakdown:                 buckets [{label, count}], total, group_by,
  #                              dimension, field_name, multi_value, truncated
  #   Crosstab (split_by):       + series, rows [{label, total, counts, cells}],
  #                              matrix, columns, split_by, series_field_name
  #   flags:                     flags {...} plus the same counters at top level
  #
  # A `group_by` over the seven core fields with none of the new parameters runs
  # the original .breakdown code path unchanged, so templates written before the
  # dimension API keep their exact keys, ordering and labels.
  #
  # On any error the tag assigns an empty-safe hash and logs to Rails.logger
  # so the rest of the template renders without crashing.

  class LiquidAggregateTag < Liquid::Tag
    include SqlAggregation::ScopeResolution

    # Matches: key: "quoted" | key: 'quoted' | key: bare_value
    PARAM_RE = /(\w+)\s*:\s*(?:"([^"]*)"|'([^']*)'|([^\s,]+))/

    # Parameters that only exist in dimension mode. When none of them is used and
    # group_by names one of the seven core fields, the legacy .breakdown path runs
    # untouched — that is what keeps existing templates byte-identical.
    DIMENSION_PARAMS = %w[split_by sort limit other_label empty_label
                          age_buckets age_field date_field user_label].freeze

    # group_by values that only the dimension path understands.
    DIMENSION_GROUP_RE = /\A(?:cf_\d+|period|age|flags)\z/i

    def initialize(tag_name, markup, tokens)
      super
      @raw_params = parse_markup(markup)
    end

    def render(context)
      # Resolve assign_to first so the rescue block always has the correct name,
      # even if resolve_scope raises before we reach the assignment below.
      assign_to = str_param(@raw_params['assign_to'], context, default: 'stats')
      t0        = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      scope     = resolve_scope(context)

      if scope.nil?
        Rails.logger.warn('[sql_aggregate] could not resolve an AR scope — skipping aggregation')
        context.scopes.last[assign_to] = empty_result
        return ''
      end

      Rails.logger.info("[sql_aggregate] scope resolved via #{scope_class_label(scope)} in #{elapsed_ms(t0)}ms")
      t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      result = if @raw_params.key?('group_by') || @raw_params.key?('split_by')
        breakdown_result(scope, context)
      else
        time_series_result(scope, context)
      end

      if result.nil?
        context.scopes.last[assign_to] = empty_result
        return ''
      end

      Rails.logger.info("[sql_aggregate] SQL aggregation done in #{elapsed_ms(t1)}ms " \
                        "(total #{elapsed_ms(t0)}ms) #{mode_label(context)}")
      context.scopes.last[assign_to] = result
      ''
    rescue => e
      Rails.logger.error("[sql_aggregate] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      context.scopes.last[assign_to] = empty_result
      ''
    end

    private

    # Scope resolution (resolve_scope, scope_from_registers, scope_from_query_id,
    # scope_from_drop, ar_scope?) lives in SqlAggregation::ScopeResolution, shared
    # with {% version_rollup %}.

    # ------------------------------------------------------------------
    # Modes — each returns a result Hash, or nil for "assign the empty result"
    # ------------------------------------------------------------------

    def time_series_result(scope, context)
      period      = str_param(@raw_params['period'], context, default: 'month')
      raw_periods = @raw_params['periods'] || (@raw_params['months'] if period == 'month')

      SqlAggregation::QueryAggregator.aggregate(
        scope,
        period:          period,
        periods:         int_param(raw_periods, context, default: nil),
        closed_statuses: closed_statuses(context)
      )
    end

    def breakdown_result(scope, context)
      unless @raw_params.key?('group_by')
        Rails.logger.warn('[sql_aggregate] split_by needs a group_by — skipping aggregation')
        return nil
      end

      group_by = str_param(@raw_params['group_by'], context, default: 'status')
      split_by = @raw_params.key?('split_by') ? str_param(@raw_params['split_by'], context) : ''

      if split_by.casecmp('flags').zero?
        Rails.logger.warn('[sql_aggregate] flags is not a valid split_by — skipping aggregation')
        return nil
      end

      return SqlAggregation::QueryAggregator.breakdown(scope, group_by: group_by) if legacy_breakdown?(group_by)

      if group_by.casecmp('flags').zero?
        return SqlAggregation::QueryAggregator.flags(scope, closed_statuses: closed_statuses(context))
      end

      period      = str_param(@raw_params['period'], context, default: 'month')
      raw_periods = @raw_params['periods'] || (@raw_params['months'] if period == 'month')

      SqlAggregation::QueryAggregator.dimension_breakdown(
        scope,
        group_by:    group_by,
        split_by:    (split_by.empty? ? nil : split_by),
        sort:        str_param(@raw_params['sort'], context, default: 'count'),
        limit:       int_param(@raw_params['limit'], context, default: 0),
        other_label: str_param(@raw_params['other_label'], context, default: 'Other'),
        empty_label: (@raw_params.key?('empty_label') ? str_param(@raw_params['empty_label'], context) : nil),
        user_label:  str_param(@raw_params['user_label'], context, default: 'name'),
        period:      period,
        periods:     int_param(raw_periods, context, default: nil),
        date_field:  str_param(@raw_params['date_field'], context, default: 'created'),
        age_buckets: list_param(@raw_params['age_buckets'], context),
        age_field:   str_param(@raw_params['age_field'], context, default: 'created')
      )
    end

    # The original seven-core-field breakdown, unchanged, whenever the template
    # uses none of the dimension parameters and no dimension-only group_by.
    def legacy_breakdown?(group_by)
      return false if group_by.match?(DIMENSION_GROUP_RE)

      DIMENSION_PARAMS.none? { |param| @raw_params.key?(param) }
    end

    # ------------------------------------------------------------------
    # Parameter helpers
    # ------------------------------------------------------------------

    def parse_markup(markup)
      params = {}
      markup.to_s.scan(PARAM_RE) do |key, dq, sq, bare|
        params[key.strip] = dq || sq || bare || ''
      end
      params
    end

    def str_param(value, context, default: '')
      return default if value.nil? || value.empty?

      resolved = context[value]
      resolved.nil? ? value : resolved.to_s
    end

    def int_param(value, context, default: 0)
      return default if value.nil? || value.empty?

      # Skip context lookup for plain numeric literals — avoids accidentally
      # resolving a context key named e.g. "6" to an unrelated variable.
      resolved = value.match?(/\A\d+\z/) ? value : (context[value] || value)
      n = resolved.to_i
      n.zero? ? default : n
    end

    # Semicolon/comma-separated list, like closed_statuses. nil when absent, so
    # the aggregator applies its own default instead of warning about an empty list.
    def list_param(value, context)
      raw = str_param(value, context)
      return nil if raw.empty?

      raw.split(/[;,]/).map(&:strip).reject(&:empty?)
    end

    def closed_statuses(context)
      str_param(@raw_params['closed_statuses'], context).split(/[;,]/).map(&:strip).reject(&:empty?)
    end

    # Appended to the timing line so a template author can see which dimensions
    # the tag actually resolved.
    def mode_label(context)
      unless @raw_params.key?('group_by') || @raw_params.key?('split_by')
        return "[period=#{str_param(@raw_params['period'], context, default: 'month')}]"
      end

      label  = "[group_by=#{str_param(@raw_params['group_by'], context, default: 'status')}"
      split  = @raw_params.key?('split_by') ? str_param(@raw_params['split_by'], context) : ''
      label += " split_by=#{split}" unless split.empty?
      "#{label}]"
    end

    def elapsed_ms(t0)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
    end

    def scope_class_label(scope)
      scope.class.name.split('::').last(2).join('::')
    rescue StandardError
      scope.class.to_s
    end

    # Every key any mode can produce, empty/zero/false, so a template that reads
    # res.rows or res.series after a failed aggregation renders instead of blowing up.
    def empty_result
      {
        'labels'            => [],
        'created'           => [],
        'closed'            => [],
        'open_now'          => 0,
        'total'             => 0,
        'period'            => nil,
        'periods'           => 0,
        'buckets'           => [],
        'group_by'          => nil,
        'split_by'          => nil,
        'dimension'         => nil,
        'field_name'        => nil,
        'series_field_name' => nil,
        'multi_value'       => false,
        'truncated'         => false,
        'series'            => [],
        'rows'              => [],
        'matrix'            => [],
        'columns'           => [],
        'flags'             => {}
      }
    end
  end
end
