# frozen_string_literal: true

require_relative '../redmine_reporter_dashboards/liquid/execution_policy'
require_relative '../redmine_reporter_dashboards/liquid/scope_binding'
require_relative '../redmine_reporter_dashboards/aggregation/drill_through'

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
  #   flags        scalar counters  — group_by only, never split_by
  #   completeness filled/empty per field (fields:) — group_by only, never split_by
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
  #   fields          — semicolon/comma-separated field list for group_by: completeness
  #   user_label      — name | login for the assignee/author dimensions (default: name)
  #   measure         — count (default) | distinct | sum | avg
  #   of              — field the measure applies to (author, cf_94, estimated_hours, …)
  #   drill           — true adds drill-through URLs                (default: false)
  #   drill_max_url   — maximum URL length before an element gets no URL (default: 2000)
  #   drill_inherit   — all (default) | filters: what a drill-down URL inherits
  #
  # sort / limit / other_label are IGNORED for `period` and `age`: those axes are
  # always in chronological / ascending order and include their empty buckets.
  #
  # --- Result keys ---
  #
  #   Time series (no group_by): labels, created, closed, open_now, total, period, periods
  #   Breakdown:                 buckets [{label, count, value, filter}], total,
  #                              group_by, dimension, field_name, multi_value, truncated
  #   Crosstab (split_by):       + series, series_entries, rows [{label, total,
  #                              counts, cells, value, filter}], matrix, columns,
  #                              split_by, series_field_name
  #   flags:                     flags {...} plus the same counters at top level,
  #                              and stages [{key, label, count, filter}]
  #   completeness:              buckets [{label, count, empty, total, pct, value,
  #                              filter, empty_filter}] in the order fields: names
  #                              them, plus fields and total (the issue count)
  #
  # --- Drill-through (drill: true) ---
  #
  #   Adds drill_available, drill_degraded, base_url, a `url` on every bucket /
  #   row / series_entries entry / stage, and `cell_urls` (+ cell_urls_truncated)
  #   for a crosstab (rows x series, aligned with `matrix`). Each URL is the Redmine issue list showing the
  #   report's own issues — filters, columns, grouping, totals and sort inherited
  #   — narrowed to that one element.
  #
  #   drill: true implies the dimension path, because only it knows the raw stored
  #   value behind a label. For one of the seven core fields that means the
  #   dimension labels (display name for users) instead of the legacy ones; pass
  #   user_label: login to keep the old text.
  #
  #   Nothing is emitted when no IssueQuery can be resolved: drill_available is
  #   then false and there are no URLs at all, because a dimension-only URL would
  #   silently show issues from outside the report scope.
  #
  # A `group_by` over the seven core fields with none of the new parameters runs
  # the original .breakdown code path unchanged, so templates written before the
  # dimension API keep their exact keys, ordering and labels.
  #
  # On any error the tag assigns an empty-safe hash and logs to Rails.logger
  # so the rest of the template renders without crashing.

  class LiquidAggregateTag < Liquid::Tag
    # T-07: two resolution sources, both starting from Issue.visible. The six-source
    # archaeology this replaced now lives in Glue::Legacy::ScopeResolution and is
    # reached only when no RenderContext is present, i.e. on a reporter install.
    include RedmineReporterDashboards::Liquid::ScopeBinding

    # Matches: key: "quoted" | key: 'quoted' | key: bare_value
    PARAM_RE = /(\w+)\s*:\s*(?:"([^"]*)"|'([^']*)'|([^\s,]+))/

    # Parameters that only exist in dimension mode. When none of them is used and
    # group_by names one of the seven core fields, the legacy .breakdown path runs
    # untouched — that is what keeps existing templates byte-identical.
    DIMENSION_PARAMS = %w[split_by sort limit other_label empty_label
                          age_buckets age_field date_field user_label of].freeze

    # group_by values that only the dimension path understands.
    DIMENSION_GROUP_RE = /\A(?:cf_\d+|period|age|flags|completeness)\z/i

    # Ceiling on rows x series before cell_urls stops building URLs. A crosstab
    # past this point is not a chart any more, and 200x200 URLs would be megabytes
    # of markup. The array stays dense and aligned; the entries are just nil.
    MAX_DRILL_CELLS = 5_000

    def initialize(tag_name, markup, tokens)
      super
      @raw_params = parse_markup(markup)
    end

    def render(context)
      # THE COOPERATIVE DEADLINE (T-17). One line, at the top of `render`, because a
      # resource limit bounds WORK UNITS and this tag's cost is TIME: a
      # sql_aggregate tag running a ninety-second query costs exactly one render-score
      # point, and no resource limit will ever notice it.
      #
      # A no-op today on every existing install: these tags still run inside the host
      # plugin's renderer, which binds no budget, and `Budget.from` answers a null
      # object rather than nil precisely so this call site is safe to add before the
      # owned renderer exists. When `TemplateRenderer` is the one rendering, this same
      # line is what stops a slow template.
      RedmineReporterDashboards::Liquid::Budget.from(context).check!('sql_aggregate')

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

      # THIS KERNEL COUNTS ISSUES, SO IT IS ONLY EVER GIVEN AN ISSUE SCOPE — T-31, and
      # §Findings **S-13** is why the refusal is here rather than a comment somewhere.
      #
      # `QueryAggregator`'s unit of count is `DISTINCT issues.id`. Handed a time-entry
      # relation it does NOT raise: `TimeEntryQuery#base_scope` calls `.left_join_issue`,
      # so every issue column resolves and the tag answers issue counts under time-entry
      # labels — four entries over two issues came back as `2` in every bucket, and
      # `spent_hours` answered nothing at all. A wrong number under a right heading is the
      # one outcome this repository keeps deleting.
      #
      # It refuses LOUDLY and degrades to the empty result rather than raising, which is
      # what every other unusable argument on this path does (HANDOVER §1: "every
      # aggregator entry point LOGS AND DEGRADES"). The owned time-entry aggregator that
      # replaces this branch is T-31's second increment; until it lands, a template asking
      # for it gets nothing and a recorded degradation, never a plausible lie.
      unowned_source = report_source(context)
      if unowned_source != :issues
        Rails.logger.warn("[sql_aggregate] refusing a #{unowned_source} scope: this " \
                          'aggregation kernel counts issues, and answering would report ' \
                          'issue counts under other labels (finding S-13)')
        record_degradation(context, unowned_source)
        context.scopes.last[assign_to] = empty_result
        return ''
      end

      Rails.logger.info("[sql_aggregate] scope resolved via #{scope_class_label(scope)} in #{elapsed_ms(t0)}ms")
      t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Render-time state stays on the stack: Liquid parses a template once and
      # may render the same tag instance again, concurrently and with different
      # assigns, so nothing that depends on `context` may be memoised on self.
      drill     = bool_param(@raw_params['drill'], context)
      breakdown = @raw_params.key?('group_by') || @raw_params.key?('split_by')
      result    = breakdown ? breakdown_result(scope, context, drill) : time_series_result(scope, context)

      if result.nil?
        context.scopes.last[assign_to] = empty_result
        return ''
      end

      drill_label = ''
      if drill
        t2 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        apply_drill(result, context, breakdown)
        # Separate from the aggregation: building the filter list costs one
        # available_filters pass, and a large crosstab a URL per cell.
        drill_label = " drill=#{elapsed_ms(t2)}ms"
      end

      Rails.logger.info("[sql_aggregate] SQL aggregation done in #{elapsed_ms(t1)}ms " \
                        "(total #{elapsed_ms(t0)}ms)#{drill_label} #{mode_label(context)}")
      context.scopes.last[assign_to] = result
      ''
    rescue => e
      Rails.logger.error("[sql_aggregate] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      context.scopes.last[assign_to] = empty_result
      ''
    end

    private

    # WHICH TABLE the resolved scope is over, taken from the render context rather than
    # sniffed off the relation.
    #
    # `RenderContext.from` and NOT `TagContext.for`, deliberately. `TagContext.for` never
    # answers nil — it builds an actor-only fallback — and building one reads
    # `User.current`, so using it here would add an ambient actor read to a code path that
    # does not need an actor at all. INV-1 is about not doing that. Nil is the answer this
    # method wants: no owned render context IS the legacy path, and the legacy path resolves
    # issue scopes and nothing else.
    #
    # Asking the relation instead would raise on every scope double in the specs and fail
    # OPEN on exactly the object it could not identify.
    def report_source(context)
      RedmineReporterDashboards::Liquid::RenderContext.from(context)&.source || :issues
    end

    # Visible rather than silent (INV-4). The degradation reaches the diagnostics panel the
    # same way an unresolved asset or a readiness timeout does. Nothing to record on the
    # legacy path, where there is no diagnostics collector and no owned panel to show one.
    def record_degradation(context, source)
      RedmineReporterDashboards::Liquid::RenderContext.from(context)
        &.diagnostics
        &.degrade(:aggregation_source_unsupported, source: source.to_s)
    end

    # Scope resolution (resolve_scope, resolve_query) lives in
    # RedmineReporterDashboards::Liquid::ScopeBinding, shared with {% version_rollup %}.
    # It has exactly two sources; see that file for why there is no enforce_visibility
    # any more.

    # ------------------------------------------------------------------
    # Modes — each returns a result Hash, or nil for "assign the empty result"
    # ------------------------------------------------------------------

    def time_series_result(scope, context)
      if measured?(context)
        Rails.logger.warn('[sql_aggregate] measure: needs a group_by — the time series always counts ' \
                          'issues; use group_by: period for a measured period chart')
      end
      period      = str_param(@raw_params['period'], context, default: 'month')
      raw_periods = @raw_params['periods'] || (@raw_params['months'] if period == 'month')

      SqlAggregation::QueryAggregator.aggregate(
        scope,
        period:          period,
        periods:         int_param(raw_periods, context, default: nil),
        closed_statuses: closed_statuses(context)
      )
    end

    def breakdown_result(scope, context, drill = false)
      unless @raw_params.key?('group_by')
        Rails.logger.warn('[sql_aggregate] split_by needs a group_by — skipping aggregation')
        return nil
      end

      group_by = str_param(@raw_params['group_by'], context, default: 'status')
      split_by = @raw_params.key?('split_by') ? str_param(@raw_params['split_by'], context) : ''

      if %w[flags completeness].include?(split_by.downcase)
        Rails.logger.warn("[sql_aggregate] #{split_by.downcase} is not a valid split_by — " \
                          'skipping aggregation')
        return nil
      end

      if legacy_breakdown?(group_by, drill, measured?(context))
        return SqlAggregation::QueryAggregator.breakdown(scope, group_by: group_by)
      end

      if group_by.casecmp('completeness').zero?
        if measured?(context)
          Rails.logger.warn('[sql_aggregate] measure: is ignored by group_by: completeness — it ' \
                            'counts issues per field')
        end
        return SqlAggregation::QueryAggregator.completeness(
          scope, fields: list_param(@raw_params['fields'], context)
        )
      end

      if group_by.casecmp('flags').zero?
        if measured?(context)
          Rails.logger.warn('[sql_aggregate] measure: is ignored by group_by: flags — its counters ' \
                            'are fixed')
        end
        statuses = closed_statuses(context)
        if drill && statuses.any?
          # The `closed` funnel stage drills through with status_id=c, i.e.
          # Redmine's is_closed flag, not the names given here. When the two sets
          # differ the stage count and the drill-down count differ with them.
          Rails.logger.warn('[sql_aggregate] drill: true with an explicit closed_statuses ' \
                            "#{statuses.inspect}: the closed stage links to status_id=c (Redmine's " \
                            'is_closed flag), so its count and the linked issue list can differ')
        end
        return SqlAggregation::QueryAggregator.flags(scope, closed_statuses: statuses)
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
        age_field:   str_param(@raw_params['age_field'], context, default: 'created'),
        measure:     measure_param(context),
        of:          str_param(@raw_params['of'], context)
      )
    end

    # `count` when absent, so an existing template keeps the row-count behaviour.
    def measure_param(context)
      str_param(@raw_params['measure'], context, default: 'count')
    end

    # A measure other than count changes what a bucket VALUE means, so it needs the
    # dimension path — the legacy breakdown only knows how to count rows.
    def measured?(context)
      measure_param(context) != 'count'
    end

    # The original seven-core-field breakdown, unchanged, whenever the template
    # uses none of the dimension parameters and no dimension-only group_by.
    #
    # Drill-through needs the raw stored value behind each label, which only the
    # dimension path carries — so `drill: true` leaves the legacy path. A falsy
    # `drill` does NOT, on purpose: switching paths would silently change user
    # labels from login to display name for a template that asked for nothing.
    def legacy_breakdown?(group_by, drill, measured)
      return false if drill || measured
      return false if group_by.match?(DIMENSION_GROUP_RE)

      DIMENSION_PARAMS.none? { |param| @raw_params.key?(param) }
    end

    # ------------------------------------------------------------------
    # Drill-through URLs
    # ------------------------------------------------------------------

    # Mutates `result` in place, adding drill_available and — when an IssueQuery
    # could be resolved — base_url, drill_degraded, one url per bucket / row /
    # series entry / stage, and cell_urls plus cell_urls_truncated for a crosstab.
    # Never raises: a failure here must not cost the template its counts.
    def apply_drill(result, context, breakdown)
      unless breakdown
        # A time series has labels, not buckets: there is no element carrying a
        # raw value to filter on. group_by: period is the drillable equivalent.
        Rails.logger.warn('[sql_aggregate] drill: true is not supported for the time series — ' \
                          'use group_by: period for a drillable period chart')
        result['drill_available'] = false
        return result
      end

      builder = drill_builder(context)
      if builder.nil?
        result['drill_available'] = false
        return result
      end

      result['drill_available'] = true
      result['base_url']        = builder.base_url

      %w[buckets rows series_entries].each do |key|
        entries(result[key]).each do |entry|
          entry['url'] = element_url(builder, entry['filter'])
          # completeness carries a second filter: the actionable one, "not set".
          entry['empty_url'] = element_url(builder, entry['empty_filter']) if entry.key?('empty_filter')
        end
      end
      # `total` has no filter, and that means "the report query unchanged" rather
      # than "not expressible", so it links to the base URL.
      entries(result['stages']).each do |stage|
        stage['url'] = stage['filter'] ? element_url(builder, stage['filter']) : builder.base_url
      end

      if result.key?('series_entries')
        # Two return values, not an ivar: render state on the tag would leak into
        # the next render of the same parsed template.
        grid, truncated = cell_urls(builder, result)
        result['cell_urls']           = grid
        result['cell_urls_truncated'] = truncated
      end
      # True when at least one URL had to drop its inherited columns and totals to
      # fit, so a template can explain why that list is not laid out like the report.
      result['drill_degraded'] = builder.degraded? ? true : false
      result
    rescue => e
      Rails.logger.error("[sql_aggregate] drill-through failed: #{e.class}: #{e.message}")
      result['drill_available'] = false
      result
    end

    def drill_builder(context)
      query = resolve_query(context)
      if query.nil?
        Rails.logger.warn('[sql_aggregate] drill: true but no IssueQuery could be resolved — ' \
                          'no drill-down URLs (counts are unaffected)')
        return nil
      end

      SqlAggregation::DrillThrough.build(
        query,
        max_url_length: int_param(@raw_params['drill_max_url'], context,
                                  default: SqlAggregation::DrillThrough::DEFAULT_MAX_URL_LENGTH),
        inherit: drill_inherit(context)
      )
    end

    # all (default) — filters, columns, grouping, totals and sort order
    # filters      — filters only, for a shorter URL or to land on an ungrouped list
    def drill_inherit(context)
      value = str_param(@raw_params['drill_inherit'], context, default: 'all').strip.downcase
      return :filters_only if value == 'filters'
      return :all if value.empty? || value == 'all'

      Rails.logger.warn("[sql_aggregate] unknown drill_inherit #{value.inspect} — " \
                        'expected all or filters; inheriting everything')
      :all
    end

    def element_url(builder, filter)
      filter ? builder.url_for([filter]) : nil
    end

    # Dense rows x series, aligned with `matrix`: each entry ANDs the row filter and
    # the series filter, and is nil wherever either is missing or the two cannot be
    # combined. Iterates the raw arrays, not the Hash-only ones, so the grid stays
    # aligned with `matrix` even for an entry that carries no filter at all.
    #
    # Returns [grid, truncated]: past the cell cap the grid stays dense and aligned
    # but every entry is nil, which a template cannot tell from "no filter" — hence
    # the flag, exposed as cell_urls_truncated next to the existing `truncated`.
    def cell_urls(builder, result)
      rows   = result['rows'].is_a?(Array) ? result['rows'] : []
      series = result['series_entries'].is_a?(Array) ? result['series_entries'] : []

      if rows.length * series.length > MAX_DRILL_CELLS
        Rails.logger.warn("[sql_aggregate] #{rows.length}x#{series.length} crosstab cells exceed the " \
                          "#{MAX_DRILL_CELLS} drill-through cell cap — cell_urls stays aligned but " \
                          'empty and cell_urls_truncated is set')
        return [rows.map { series.map { nil } }, true]
      end

      grid = rows.map do |row|
        row_filter = filter_of(row)
        series.map do |entry|
          series_filter = filter_of(entry)
          next nil unless row_filter && series_filter

          builder.url_for([row_filter, series_filter])
        end
      end
      [grid, false]
    end

    def filter_of(entry)
      entry.is_a?(Hash) ? entry['filter'] : nil
    end

    def entries(value)
      value.is_a?(Array) ? value.select { |entry| entry.is_a?(Hash) } : []
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

    # Flag parameter. Accepts the literal `drill: true` as well as a Liquid
    # variable holding a real boolean; anything else (including an absent
    # parameter) is false, which is what keeps existing templates untouched.
    def bool_param(value, context)
      %w[1 true yes on].include?(str_param(value, context).strip.downcase)
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
        'labels'              => [],
        'created'             => [],
        'closed'              => [],
        'open_at_end'         => [],
        'open_now'            => 0,
        'total'               => 0,
        'period'              => nil,
        'periods'             => 0,
        'buckets'             => [],
        'group_by'            => nil,
        'split_by'            => nil,
        'dimension'           => nil,
        'field_name'          => nil,
        'series_field_name'   => nil,
        'measure'             => nil,
        'measure_field'       => nil,
        'multi_value'         => false,
        'truncated'           => false,
        'series'              => [],
        'series_entries'      => [],
        'rows'                => [],
        'matrix'              => [],
        'columns'             => [],
        'flags'               => {},
        'median_open_days'    => nil,
        'p90_open_days'       => nil,
        'stages'              => [],
        'fields'              => [],
        'drill_available'     => false,
        'drill_degraded'      => false,
        'base_url'            => nil,
        'cell_urls'           => [],
        'cell_urls_truncated' => false
      }
    end
  end
end
