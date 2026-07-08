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
  # assign_to — name of the Liquid variable that holds the result (default: stats)
  # period   — day | week | month | year  (default: month)
  # periods  — number of periods back     (default: 30/13/6/3 for day/week/month/year)
  # months   — backward-compatible alias for periods when period is month
  # group_by — status | priority | tracker | assignee | author | category | version
  #            When present, switches to breakdown mode (buckets instead of time-series)
  #
  # Time-series result keys: labels, created, closed, open_now, total, period, periods
  # Breakdown result keys:   buckets [{label, count}], total, group_by
  #
  # closed_statuses — semicolon- or comma-separated status names.
  #                   Omit to use Redmine's built-in is_closed flag.
  #
  # On any error the tag assigns an empty-safe hash and logs to Rails.logger
  # so the rest of the template renders without crashing.

  class LiquidAggregateTag < Liquid::Tag
    include SqlAggregation::ScopeResolution

    # Matches: key: "quoted" | key: 'quoted' | key: bare_value
    PARAM_RE = /(\w+)\s*:\s*(?:"([^"]*)"|'([^']*)'|([^\s,]+))/

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

      result = if @raw_params.key?('group_by')
        group_by = str_param(@raw_params['group_by'], context, default: 'status')
        SqlAggregation::QueryAggregator.breakdown(scope, group_by: group_by)
      else
        period      = str_param(@raw_params['period'], context, default: 'month')
        raw_periods = @raw_params['periods'] || (@raw_params['months'] if period == 'month')
        periods     = int_param(raw_periods, context, default: nil)
        statuses    = str_param(@raw_params['closed_statuses'], context).split(/[;,]/).map(&:strip).reject(&:empty?)
        SqlAggregation::QueryAggregator.aggregate(
          scope,
          period:          period,
          periods:         periods,
          closed_statuses: statuses
        )
      end

      Rails.logger.info("[sql_aggregate] SQL aggregation done in #{elapsed_ms(t1)}ms (total #{elapsed_ms(t0)}ms)")
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

    def elapsed_ms(t0)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
    end

    def scope_class_label(scope)
      scope.class.name.split('::').last(2).join('::')
    rescue StandardError
      scope.class.to_s
    end

    def empty_result
      {
        'labels'   => [],
        'created'  => [],
        'closed'   => [],
        'open_now' => 0,
        'total'    => 0,
        'period'   => nil,
        'periods'  => 0,
        'buckets'  => [],
        'group_by' => nil
      }
    end
  end
end
