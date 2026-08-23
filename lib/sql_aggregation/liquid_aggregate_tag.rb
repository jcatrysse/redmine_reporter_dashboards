# frozen_string_literal: true

require_relative '../redmine_reporter_dashboards/liquid/execution_policy'
require_relative '../redmine_reporter_dashboards/liquid/scope_binding'
require_relative '../redmine_reporter_dashboards/liquid/tag_params'
require_relative '../redmine_reporter_dashboards/aggregation/drill_through'

module SqlAggregation
  # Liquid tag: {% sql_aggregate ... %}   (legacy alias: {% geo_aggregate ... %})
  #
  # Runs server-side SQL aggregation and assigns the result to a Liquid variable, instead of
  # a {% for issue in issues %} loop. The parameter surface is documented for the people who
  # write templates in `docs/template-authoring.md`; what follows is the behaviour a
  # maintainer needs and the doc does not carry.
  #
  # --- MODE SWITCHING ---
  #
  #   no group_by                 time series
  #   group_by                    breakdown
  #   group_by + split_by         crosstab
  #   group_by: flags             scalar counters; never valid as split_by
  #   group_by: completeness      filled/empty per field; never valid as split_by
  #
  # A `group_by` over one of the seven core fields with none of the newer parameters runs
  # the original `.breakdown` path unchanged, so templates written before the dimension API
  # keep their exact keys, ordering and labels.
  #
  # `sort` / `limit` / `other_label` are IGNORED for `period` and `age`: those axes are
  # always chronological or ascending and include their empty buckets.
  #
  # --- RESULT KEYS ---
  #
  #   time series  labels, created, closed, open_now, total, period, periods
  #   breakdown    buckets [{label, count, value, filter}], total, group_by, dimension,
  #                field_name, multi_value, truncated
  #   crosstab     + series, series_entries, rows [{label, total, counts, cells, value,
  #                filter}], matrix, columns, split_by, series_field_name
  #   flags        flags {...}, the same counters at top level, and
  #                stages [{key, label, count, filter}]
  #   completeness buckets [{label, count, empty, total, pct, value, filter, empty_filter}]
  #                in the order `fields:` names them, plus fields and total
  #
  # --- DRILL-THROUGH ---
  #
  # `drill: true` adds drill_available, drill_degraded, base_url, a `url` on every bucket,
  # row, series entry and stage, and `cell_urls` (+ cell_urls_truncated) for a crosstab.
  #
  # It IMPLIES the dimension path, because only that path knows the raw stored value behind
  # a label — so for a core field the labels become the dimension ones (display name for
  # users) rather than the legacy ones; `user_label: login` keeps the old text.
  #
  # Nothing is emitted when no IssueQuery can be resolved: `drill_available` is false and
  # there are no URLs at all, because a dimension-only URL would silently show issues from
  # outside the report scope.
  #
  # On any error the tag assigns an empty-safe hash and logs to Rails.logger
  # so the rest of the template renders without crashing.

  class LiquidAggregateTag < Liquid::Tag
    # T-07: two resolution sources, both starting from Issue.visible. The six-source
    # archaeology this replaced lived in Glue::Legacy::ScopeResolution and was DELETED by
    # S-30 (2026-08-13). Since curator decision #1 (2026-08-14) a render arriving with no
    # RenderContext resolves NOTHING AT ALL — `query_id:` included, because resolving it
    # needed an ambient actor and that read is gone with the host-render path it served. The
    # tag assigns the empty result and logs, as it already did for an unresolvable scope.
    include RedmineReporterDashboards::Liquid::ScopeBinding

    # Markup parsing and the quoted-means-literal rule live in one place for all four
    # tags — see `RedmineReporterDashboards::Liquid::TagParams`, which carries the
    # decision and the upgrade note.
    TagParams = RedmineReporterDashboards::Liquid::TagParams

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
      @raw_params = TagParams.parse(markup)
    end

    def render(context)
      # THE COOPERATIVE DEADLINE (T-17). One line, at the top of `render`, because a
      # resource limit bounds WORK UNITS and this tag's cost is TIME: a
      # sql_aggregate tag running a ninety-second query costs exactly one render-score
      # point, and no resource limit will ever notice it.
      #
      # STALE UNTIL S-30 CORRECTED IT: this used to say "a no-op today on every existing
      # install: these tags still run inside the host plugin's renderer". `TemplateRenderer`
      # has been the renderer for every report this plugin produces since T-23, and it
      # binds a budget. The sentence survives as a note on the OTHER case — a template
      # rendered by the host plugin binds no budget, and `Budget.from` answers a null
      # object rather than nil precisely so this call site is safe there. When
      # `TemplateRenderer` is the one rendering, this same
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

      # A TIME-ENTRY SCOPE GOES TO THE TIME-ENTRY AGGREGATOR — T-31 increment 2. This kernel
      # counts `DISTINCT issues.id`, so answering a time-entry scope with it is §Findings
      # S-13: issue counts under time-entry labels. Increment 1 refused here because there was
      # nowhere correct to send it; now there is, and what remains refused is a source with no
      # aggregator at all — see `time_entry_result`.
      #
      # `{% version_rollup %}` still REFUSES rather than dispatching, through
      # `ScopeBinding.issue_kernel_permitted?`, which is why that method still exists with one
      # caller: a per-target-version rollup over time entries is a different report nobody has
      # specified.
      source = RedmineReporterDashboards::Liquid::ScopeBinding.report_source(context)
      if source != :issues
        result = time_entry_result(scope, context, source)
        context.scopes.last[assign_to] = result || empty_result
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

    # THE OWNED TIME-ENTRY PATH. One dispatch, and everything about how a time entry is
    # aggregated lives in `Aggregation::TimeEntryAggregator` — including the positional
    # grouped read that D-1's still-open `SUM` hazard requires. This method's whole job is to
    # translate the tag's markup into that module's arguments and to refuse a source it has
    # no aggregator for.
    #
    # `group_by` IS REQUIRED HERE, unlike the issue path's time series. There is no
    # time-entry equivalent of `aggregate`'s created/closed flow — a time entry is not opened
    # and closed — so a tag with no dimension has nothing to ask for, and answering the empty
    # result says that more honestly than inventing a series.
    def time_entry_result(scope, context, source)
      render_context = RedmineReporterDashboards::Liquid::RenderContext.from(context)
      diagnostics    = render_context&.diagnostics
      aggregator     = RedmineReporterDashboards::Aggregation::TimeEntryAggregator

      unless source == :time_entries
        degrade_here(diagnostics, :aggregation_source_unsupported,
                     "no aggregator for a #{source} scope",
                     source: source.to_s, tag: 'sql_aggregate')
        return nil
      end

      group_by = str_param(@raw_params['group_by'], context)
      if group_by.strip.empty?
        degrade_here(diagnostics, :aggregation_group_by_required,
                     'a time-entry aggregation needs group_by',
                     source: source.to_s)
        return nil
      end

      report_unsupported_params(diagnostics, context)

      aggregator.breakdown(
        scope,
        group_by: group_by,
        # EXPLICIT, NEVER `User.current` (INV-1). The aggregator needs it for exactly one
        # thing — scoping the `issue` dimension's labels by visibility — and a nil actor makes
        # it withhold those labels rather than read them unscoped.
        actor: render_context&.actor,
        measure: str_param(@raw_params['measure'], context, default: aggregator::DEFAULT_MEASURE),
        sort: str_param(@raw_params['sort'], context, default: aggregator::DEFAULT_SORT),
        limit: int_param(@raw_params['limit'], context, default: aggregator::DEFAULT_LIMIT),
        other_label: str_param(@raw_params['other_label'], context,
                               default: aggregator::DEFAULT_OTHER_LABEL),
        empty_label: str_param(@raw_params['empty_label'], context, default: nil),
        logger: Rails.logger,
        # THE AUTHOR SEES THE REFUSAL TOO. A mistyped `group_by` used to answer the empty
        # result with the reason only in the server log — the same finding an independent
        # review raised against increment 1, one layer down (INV-4).
        diagnostics: diagnostics
      )
    end

    # Parameters the issue path understands and the time-entry path does not. **They used to
    # be dropped in silence**, which an independent review measured end to end: a template
    # asking for a crosstab got a single axis, `drill: true` produced no `bucket.url` at all,
    # and nothing on the page said either — while the README promised drill-through. HANDOVER
    # §1's rule is that every aggregator entry point LOGS AND DEGRADES on an argument it
    # cannot use, and these are arguments it cannot use.
    #
    # Named individually rather than as "anything not in the supported list", because a typo
    # is a different finding from an unsupported feature and the message has to say which.
    TIME_ENTRY_UNSUPPORTED_PARAMS = {
      'split_by' => 'a crosstab over two dimensions',
      'period' => 'period bucketing',
      'periods' => 'period bucketing',
      'months' => 'period bucketing',
      'drill' => 'drill-through URLs',
      'age_buckets' => 'age bucketing',
      'age_field' => 'age bucketing',
      'date_field' => 'date-field selection',
      'user_label' => 'the user-label switch',
      'of' => 'a measured custom field',
      'fields' => 'the completeness field list',
      'closed_statuses' => 'the closed-status list'
    }.freeze

    def report_unsupported_params(diagnostics, _context)
      present = TIME_ENTRY_UNSUPPORTED_PARAMS.keys.select { |key| @raw_params.key?(key) }
      return if present.empty?

      wanted = present.map { |key| TIME_ENTRY_UNSUPPORTED_PARAMS[key] }.uniq
      degrade_here(diagnostics, :aggregation_params_unsupported,
                   "#{present.join(', ')} #{present.one? ? 'is' : 'are'} not supported over " \
                   "time entries (#{wanted.join('; ')}); the aggregation ran without " \
                   "#{present.one? ? 'it' : 'them'}",
                   params: present.join(','))
    end

    # Both halves, in one place: the log line for whoever is on call and the degradation the
    # template author reads on the page.
    def degrade_here(diagnostics, code, message, **data)
      Rails.logger.warn("[sql_aggregate] #{message}")
      diagnostics&.degrade(code, detail: message, **data)
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

    # QUOTED MEANS LITERAL, BARE MEANS A VARIABLE — decided once, in `TagParams`,
    # which carries the reasoning and the upgrade note.
    def str_param(value, context, default: '')
      TagParams.resolve(value, context, default: default)
    end

    def int_param(value, context, default: 0)
      return default if value.nil? || value.empty?

      # Skip context lookup for plain numeric literals — avoids accidentally
      # resolving a context key named e.g. "6" to an unrelated variable. A QUOTED
      # value is a literal for the same reason every other quoted value is: `limit: "6"`
      # asks for six, never for whatever a variable named `6` holds.
      resolved =
        if TagParams.quoted?(value) || value.match?(/\A\d+\z/)
          value.to_s
        else
          context[value.to_s] || value.to_s
        end
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
