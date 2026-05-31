# frozen_string_literal: true

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

    # ------------------------------------------------------------------
    # Scope resolution: prefer explicit query_id, then registers, then drop
    # ------------------------------------------------------------------

    def resolve_scope(context)
      if @raw_params.key?('query_id')
        return scope_from_query_id(@raw_params['query_id'], context)
      end

      # Registers-based resolution avoids building a massive WHERE IN from a
      # loaded Array when Reporter has passed the IssueQuery (or controller)
      # via context.registers.
      scope = scope_from_registers(context)
      return scope if scope

      from_key = @raw_params['from'] || 'issues'
      scope_from_drop(context[from_key])
    end

    # Try to obtain an AR::Relation from context.registers without touching
    # the issues drop (which may hold a loaded Array in production).
    #
    # Priority:
    #   1. :sql_issue_query — set by reporter_render_patch.rb once activated
    #   2. :container       — Reporter stores the source object here; when it IS
    #                         an IssueQuery, base_scope is available directly
    #   3. :controller      — standard Redmine pattern; controller has @query
    def scope_from_registers(context)
      registers = context.registers rescue {}
      return nil if registers.nil? || registers.empty?

      if (query = registers[:sql_issue_query])
        scope = query.base_scope rescue nil
        return scope if ar_scope?(scope)
      end

      # :container — Reporter stores the liquidize argument here.
      # ReporterListPatch replaces the loaded Array with query.base_scope,
      # so after patching the container IS the AR scope.
      if (container = registers[:container])
        return container if ar_scope?(container)
        if container.respond_to?(:base_scope)
          scope = container.base_scope rescue nil
          return scope if ar_scope?(scope)
        end
        query = container.instance_variable_get(:@query) rescue nil
        if query&.respond_to?(:base_scope)
          scope = query.base_scope rescue nil
          return scope if ar_scope?(scope)
        end
      end

      if (controller = registers[:controller])
        query = controller.instance_variable_get(:@query) rescue nil
        if query&.respond_to?(:base_scope)
          scope = query.base_scope rescue nil
          return scope if ar_scope?(scope)
        end
      end

      nil
    end

    def scope_from_query_id(param, context)
      qid = (context[param] || param).to_i
      return nil if qid.zero?

      query = IssueQuery.find_by(id: qid)
      return nil unless query

      query.base_scope
    rescue => e
      Rails.logger.warn("[sql_aggregate] query_id lookup failed: #{e.message}")
      nil
    end

    def scope_from_drop(drop)
      return nil unless drop

      # Check all ivars for an IssueQuery or scope stored alongside @issues.
      # reporter_render_patch.rb sets @sql_base_scope on the drop when
      # Reporter is patched at the IssuesDrop level.
      drop.instance_variables.each do |ivar|
        next if ivar == :@issues
        val = drop.instance_variable_get(ivar) rescue nil
        return val if ar_scope?(val)
        if val.respond_to?(:base_scope)
          scope = val.base_scope rescue nil
          return scope if ar_scope?(scope)
        end
      end

      # Primary: IssuesDrop stores the collection in @issues.
      # Reporter passes a loaded Array (not an AR::Relation), so reconstruct
      # a scope from the issue IDs when the value is not already an AR scope.
      if drop.instance_variable_defined?(:@issues)
        candidate = drop.instance_variable_get(:@issues)
        return candidate if ar_scope?(candidate)

        if candidate.is_a?(Array)
          ids = candidate.filter_map { |obj| obj.id if obj.respond_to?(:id) }
          return ids.any? ? Issue.where(id: ids) : Issue.none
        end
      end

      # Fallback: some drops expose the scope via a public method
      %i[scope issues_scope base_scope].each do |m|
        next unless drop.respond_to?(m)

        candidate = drop.public_send(m)
        return candidate if ar_scope?(candidate)
      end

      # Last resort: drop is itself an AR scope (unlikely but safe to check)
      return drop if ar_scope?(drop)

      nil
    end

    def ar_scope?(obj)
      obj.respond_to?(:where) && obj.respond_to?(:group) && obj.respond_to?(:count)
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
