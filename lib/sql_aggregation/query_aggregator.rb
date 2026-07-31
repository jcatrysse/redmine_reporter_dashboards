# frozen_string_literal: true

module SqlAggregation
  # Runs pure-SQL COUNT(DISTINCT issues.id) GROUP BY aggregations on an
  # ActiveRecord scope. No Issue objects are instantiated — the scope is used
  # only for SQL generation. Requires PostgreSQL or MySQL/MariaDB.
  #
  # --- Time-series mode (.aggregate / .monthly_flow) ---
  #
  #   period  — 'day' | 'week' | 'month' | 'year'  (default: 'month')
  #   periods — number of buckets back               (default: 30/13/6/3)
  #
  #   day   → "2026-05-30"   (max 90,  default 30)
  #   week  → "2026-W22"     (max 52,  default 13, ISO 8601 zero-padded)
  #   month → "2026-05"      (max 24,  default 6)
  #   year  → "2026"         (max 10,  default 3)
  #
  #   Returns: labels, created, closed, open_now, total, period, periods
  #
  # --- Breakdown mode (.breakdown) — LEGACY ---
  #
  #   group_by — 'status' | 'priority' | 'tracker' | 'assignee' |
  #              'author' | 'category' | 'version'
  #
  #   Returns: buckets [{label, count}] sorted desc, total, group_by
  #
  #   Labels users by login. Keys, ordering and label text are kept identical for
  #   templates written before the dimension API below; new code should use
  #   .dimension_breakdown instead.
  #
  # --- Dimension mode (.dimension_breakdown) ---
  #
  #   group_by / split_by — any DIMENSION:
  #
  #     status | priority | tracker | assignee | author | category | version
  #                     — the seven core fields (same labels, display name for users)
  #     cf_<id>         — issue custom field by numeric id, e.g. cf_92
  #     period          — date bucket (period / periods / date_field)
  #     age             — age bucket  (age_buckets / age_field)
  #
  #   One dimension  → buckets, total, group_by, dimension, field_name,
  #                    multi_value, truncated
  #   Two dimensions → additionally series, rows, matrix, columns, split_by,
  #                    series_field_name  (a dense rows x series crosstab)
  #
  #
  #   Returns nil (after logging a warning) when a dimension cannot be resolved,
  #   so the caller can assign its empty-safe result instead of raising.
  #
  # --- Governance flags (.flags) ---
  #
  #   One row of scalar counters for KPI tiles: total, open, closed, assigned,
  #   unassigned, with_due_date, without_due_date, overdue, no_estimate,
  #   oldest_open_days, newest_open_days.
  class QueryAggregator
    # Raised when the connected database is neither PostgreSQL nor MySQL. The
    # tags rescue it, so a dashboard degrades to an empty result with one clear
    # line in the log instead of a puzzling "no such function: DATE_FORMAT".
    class UnsupportedAdapterError < StandardError; end

    # Every issue count in this file is per ISSUE, not per joined row. The scope
    # handed to us may already carry joins that multiply rows (a custom-field
    # filter, watchers, time entries) and the custom field dimension adds one of
    # its own; a plain COUNT(*) would then report more issues than exist.
    DISTINCT_ISSUES = 'DISTINCT issues.id'

    PERIOD_CONFIG = {
      'day'   => { max: 90,  default: 30, sql_format: '%Y-%m-%d', pg_format: 'YYYY-MM-DD'  },
      'week'  => { max: 52,  default: 13, sql_format: '%x-W%v',   pg_format: 'IYYY"-W"IW' },
      'month' => { max: 24,  default: 6,  sql_format: '%Y-%m',    pg_format: 'YYYY-MM'     },
      'year'  => { max: 10,  default: 3,  sql_format: '%Y',       pg_format: 'YYYY'        }
    }.freeze

    # Lambdas resolved at call time so constants need not exist at load time.
    BREAKDOWN_CONFIG = {
      'status'   => { field: :status_id,        null_label: 'None',
                      lookup: ->(ids) { IssueStatus.where(id: ids).pluck(:id, :name).to_h } },
      'priority' => { field: :priority_id,      null_label: 'None',
                      lookup: ->(ids) { IssuePriority.where(id: ids).pluck(:id, :name).to_h } },
      'tracker'  => { field: :tracker_id,       null_label: 'None',
                      lookup: ->(ids) { Tracker.where(id: ids).pluck(:id, :name).to_h } },
      'assignee' => { field: :assigned_to_id,   null_label: 'Unassigned',
                      lookup: ->(ids) { User.where(id: ids).pluck(:id, :login).to_h } },
      'author'   => { field: :author_id,        null_label: 'None',
                      lookup: ->(ids) { User.where(id: ids).pluck(:id, :login).to_h } },
      'category' => { field: :category_id,      null_label: 'None',
                      lookup: ->(ids) { IssueCategory.where(id: ids).pluck(:id, :name).to_h } },
      'version'  => { field: :fixed_version_id, null_label: 'None',
                      lookup: ->(ids) { Version.where(id: ids).pluck(:id, :name).to_h } }
    }.freeze

    # ------------------------------------------------------------------
    # Dimension mode configuration
    # ------------------------------------------------------------------

    CF_DIMENSION_RE     = /\Acf_(\d+)\z/i
    DEFAULT_EMPTY_LABEL = '(none)'
    DEFAULT_OTHER_LABEL = 'Other'
    DEFAULT_AGE_BUCKETS = [30, 60, 90, 180].freeze
    SORT_MODES          = %w[count label position].freeze

    # Every boundary adds a WHEN branch to the generated CASE, so the list is
    # capped like PERIOD_CONFIG caps `periods`.
    MAX_AGE_BUCKETS = 24

    # Hard cap on the number of rows / series returned, independent of `limit`.
    # Protects a dashboard from someone grouping on a free-text custom field.
    MAX_DIMENSION_KEYS = 200

    PERIOD_DATE_COLUMNS = { 'created' => 'issues.created_on', 'closed' => 'issues.closed_on' }.freeze
    AGE_DATE_COLUMNS    = { 'created' => 'issues.created_on', 'updated' => 'issues.updated_on',
                            'due'     => 'issues.due_date' }.freeze

    # Sentinels for the two synthetic buckets. Symbols cannot collide with a raw
    # SQL group value (always String, Integer or nil).
    OTHER_KEY = :__rrd_other__
    EMPTY_KEY = :__rrd_empty__

    # How to group, and how to turn the raw group values into labels.
    #   sql          — group expression (Symbol for a core column, Arel.sql otherwise)
    #   join         — optional raw LEFT OUTER JOIN fragment
    #   scope_filter — optional ->(scope) { scope.where(...) }
    #   label_map    — ->(raw_keys) { {raw => label} }, ONE batch lookup, never raises
    #   fallback_label — ->(raw) { label } for keys the map misses (a failed lookup
    #                    must not degrade "Assignee #10" into a bare "10")
    #   order_map    — ->(raw_keys) { {raw => Integer} } for sort: position (may be nil)
    #   fixed_keys   — every expected raw key, in display order (period, age)
    #   project_join — true when the join fragment references the projects table
    Dimension = Struct.new(:name, :sql, :join, :project_join, :scope_filter, :label_map,
                           :fallback_label, :order_map, :fixed_keys, :field_name, :multi_value,
                           :empty_label, keyword_init: true)

    # Result of ordering one axis: display keys, their labels, raw => display key.
    Axis = Struct.new(:keys, :labels, :key_map, :truncated, keyword_init: true)

    # ------------------------------------------------------------------
    # Time-series aggregation
    # ------------------------------------------------------------------

    # scope            — AR relation (e.g. from IssuesDrop or IssueQuery#base_scope)
    # period           — 'day', 'week', 'month', 'year'  (default: 'month')
    # periods          — number of periods back           (default: per period type)
    # closed_statuses  — Array of status *names*; falls back to is_closed flag when empty
    def self.aggregate(scope, period: 'month', periods: nil, closed_statuses: [])
      cfg     = PERIOD_CONFIG.fetch(period.to_s, PERIOD_CONFIG['month'])
      periods = sanitize_periods(periods, cfg)
      from    = period_from(periods, period)

      closed_ids = resolve_closed_ids(closed_statuses)
      labels     = build_labels(periods, period)

      base = scope.unscope(:order)

      created_raw = base
        .where('issues.created_on >= ?', from)
        .group(date_format_sql('issues.created_on', cfg))
        .count(DISTINCT_ISSUES)

      # Guard against empty closed_ids: WHERE status_id IN () / NOT IN () produces
      # 1=0 / 1=1 which is technically correct but makes intent opaque.
      if closed_ids.empty?
        closed_raw = {}
        open_count = base.count(DISTINCT_ISSUES)
      else
        closed_raw = base
          .where(status_id: closed_ids)
          .where('issues.closed_on IS NOT NULL')
          .where('issues.closed_on >= ?', from)
          .group(date_format_sql('issues.closed_on', cfg))
          .count(DISTINCT_ISSUES)
        open_count = base.where.not(status_id: closed_ids).count(DISTINCT_ISSUES)
      end

      total = base.count(DISTINCT_ISSUES)

      {
        'labels'   => labels,
        'created'  => labels.map { |l| created_raw[l] || 0 },
        'closed'   => labels.map { |l| closed_raw[l]  || 0 },
        'open_now' => open_count,
        'total'    => total,
        'period'   => period.to_s,
        'periods'  => periods
      }
    end

    # Backward-compatible alias.
    def self.monthly_flow(scope, months: 6, closed_statuses: [])
      aggregate(scope, period: 'month', periods: months, closed_statuses: closed_statuses)
    end

    # ------------------------------------------------------------------
    # Categorical breakdown
    # ------------------------------------------------------------------

    # group_by — one of the keys in BREAKDOWN_CONFIG
    #
    # Returns:
    #   buckets  — [{label, count}, ...] sorted by count descending
    #   total    — sum of all counts
    #   group_by — echoed back for template use
    def self.breakdown(scope, group_by:)
      cfg = BREAKDOWN_CONFIG[group_by.to_s]
      return { 'buckets' => [], 'total' => 0, 'group_by' => group_by.to_s } unless cfg

      base      = scope.unscope(:order)
      id_counts = base.group(cfg[:field]).count(DISTINCT_ISSUES)  # {1=>42, nil=>5, 3=>18}
      ids       = id_counts.keys.compact
      names     = ids.any? ? cfg[:lookup].call(ids) : {}

      buckets = id_counts.map do |id, count|
        label = id.nil? ? cfg[:null_label] : (names[id] || "#{group_by.capitalize} ##{id}")
        { 'label' => label.to_s, 'count' => count }
      end.sort_by { |b| -b['count'] }

      { 'buckets' => buckets, 'total' => buckets.sum { |b| b['count'] }, 'group_by' => group_by.to_s }
    end

    # ------------------------------------------------------------------
    # Dimension breakdown / crosstab
    # ------------------------------------------------------------------

    # group_by    — any dimension (core field, cf_<id>, period, age)
    # split_by    — optional second dimension; produces a rows x series crosstab
    # sort        — 'count' (desc) | 'label' (asc, natural) | 'position'
    # limit       — keep the top N rows, remainder collapses into `other_label`
    #               (0 = no limit; ignored for the period and age dimensions)
    # empty_label — label of the null/blank bucket (defaults per dimension)
    # user_label  — 'name' (display name) | 'login' for the assignee/author dims
    #
    # Returns nil — after logging a warning — when a dimension is invalid.
    def self.dimension_breakdown(scope, group_by:, split_by: nil, sort: 'count', limit: 0,
                                 other_label: DEFAULT_OTHER_LABEL, empty_label: nil,
                                 user_label: 'name', period: 'month', periods: nil,
                                 date_field: 'created', age_buckets: nil, age_field: 'created')
      sort = sanitize_sort(sort)
      opts = { empty_label: empty_label, user_label: user_label, period: period,
               periods: periods, date_field: date_field, age_buckets: age_buckets,
               age_field: age_field }

      group_dim = resolve_dimension(group_by, suffix: 'g', **opts)
      return nil if group_dim.nil?

      split_dim = nil
      unless split_by.nil? || split_by.to_s.strip.empty?
        split_dim = resolve_dimension(split_by, suffix: 's', **opts)
        return nil if split_dim.nil?
      end

      base = apply_dimension(scope.unscope(:order), group_dim)
      base = apply_dimension(base, split_dim) if split_dim

      if split_dim
        crosstab_result(base, group_dim, split_dim, sort: sort, limit: limit,
                                                    other_label: other_label,
                                                    group_by: group_by, split_by: split_by)
      else
        single_result(base, group_dim, sort: sort, limit: limit,
                                       other_label: other_label, group_by: group_by)
      end
    end

    # ------------------------------------------------------------------
    # Governance flags — one row of scalars for KPI tiles / funnels
    # ------------------------------------------------------------------
    #
    # closed_statuses — Array of status NAMES; falls back to is_closed when empty.
    # Each scalar is one small indexed aggregate; nothing is loaded into Ruby
    # except the two MIN/MAX timestamps used for the *_open_days values.
    def self.flags(scope, closed_statuses: [])
      base       = scope.unscope(:order)
      closed_ids = resolve_closed_ids(closed_statuses)

      total = base.count(DISTINCT_ISSUES)

      if closed_ids.empty?
        closed     = 0
        open_scope = base
      else
        closed     = base.where(status_id: closed_ids).count(DISTINCT_ISSUES)
        open_scope = base.where.not(status_id: closed_ids)
      end

      assigned  = base.where.not(assigned_to_id: nil).count(DISTINCT_ISSUES)
      with_due  = base.where.not(due_date: nil).count(DISTINCT_ISSUES)
      overdue   = open_scope.where('issues.due_date < ?', Date.today).count(DISTINCT_ISSUES)
      no_est    = base.where(estimated_hours: nil).count(DISTINCT_ISSUES)
      oldest    = open_scope.minimum(:created_on)
      newest    = open_scope.maximum(:created_on)

      values = {
        'total'             => total,
        'open'              => total - closed,
        'closed'            => closed,
        'assigned'          => assigned,
        'unassigned'        => total - assigned,
        'with_due_date'     => with_due,
        'without_due_date'  => total - with_due,
        'overdue'           => overdue,
        'no_estimate'       => no_est,
        'oldest_open_days'  => days_since(oldest),
        'newest_open_days'  => days_since(newest)
      }

      # Exposed twice on purpose: {{ f.total }} and {{ f.flags.total }} both work.
      values.merge(
        'flags'     => values,
        'buckets'   => [],
        'group_by'  => 'flags',
        'dimension' => 'flags'
      )
    end

    # ------------------------------------------------------------------
    # Dimension resolution
    # ------------------------------------------------------------------

    # suffix — 'g' for the group_by axis, 's' for split_by; keeps the two
    #          custom_values join aliases apart.
    def self.resolve_dimension(name, suffix:, empty_label: nil, user_label: 'name',
                               period: 'month', periods: nil, date_field: 'created',
                               age_buckets: nil, age_field: 'created')
      key = name.to_s.strip
      # Core field names stay case-sensitive (that is how .breakdown reads them);
      # the dimensions this file adds accept any case, like the tag's dispatcher.
      pseudo = key.downcase

      if (cfg = BREAKDOWN_CONFIG[key])
        core_dimension(key, cfg, empty_label: empty_label, user_label: user_label)
      elsif (match = CF_DIMENSION_RE.match(key))
        custom_field_dimension(key, match[1].to_i, suffix: suffix, empty_label: empty_label)
      elsif pseudo == 'period'
        period_dimension(key, period: period, periods: periods,
                              date_field: date_field, empty_label: empty_label)
      elsif pseudo == 'age'
        age_dimension(key, age_buckets: age_buckets, age_field: age_field, empty_label: empty_label)
      elsif pseudo == 'flags'
        Rails.logger.warn('[sql_aggregation] flags is only valid as group_by, not as a dimension')
        nil
      else
        Rails.logger.warn("[sql_aggregation] unknown dimension #{key.inspect} — " \
                          'expected a core field, cf_<id>, period or age')
        nil
      end
    end

    # ------------------------------------------------------------------
    # Per-version rollup — one row per fixed_version, all in SQL
    # ------------------------------------------------------------------
    #
    # Replaces an O(versions x issues) Liquid loop with a handful of grouped SQL
    # queries (each a single indexed GROUP BY over the scope). Returns an Array
    # of per-version Hashes with STRING keys (Liquid dot-access friendly), one per
    # fixed_version_id present in the scope (a nil version_id = issues with no
    # target version):
    #
    #   version_id       — Integer or nil
    #   total            — issue count
    #   open / closed    — counts (closed via closed_statuses, else is_closed flag)
    #   open_done_sum    — SUM(done_ratio) over OPEN issues (for % complete)
    #   overdue_open     — open issues past due
    #   unassigned_open  — open issues with no assignee
    #   no_estimate      — issues with a NULL estimated_hours
    #   est_hours        — SUM(estimated_hours)
    #   spent_hours      — SUM(time_entries.hours) of the version's own issues
    #   start_date       — MIN(start_date)  (Date or nil)
    #   due_date         — MAX(due_date)    (Date or nil)
    #   cost             — { "<field_id>" => Float } summed per numeric custom field
    #
    # closed_statuses — Array of status NAMES; falls back to is_closed when empty.
    # cost_field_ids  — Array of numeric custom field ids to SUM per version.
    def self.version_rollup(scope, closed_statuses: [], cost_field_ids: [])
      base       = scope.unscope(:order)
      closed_ids = resolve_closed_ids(closed_statuses)

      totals = base.group(:fixed_version_id).count
      return [] if totals.empty?

      open_scope    = closed_ids.empty? ? base : base.where.not(status_id: closed_ids)
      closed_by     = closed_ids.empty? ? {} : base.where(status_id: closed_ids).group(:fixed_version_id).count
      open_by       = open_scope.group(:fixed_version_id).count
      done_by       = open_scope.group(:fixed_version_id).sum(:done_ratio)
      overdue_by    = open_scope.where('issues.due_date < ?', Date.today).group(:fixed_version_id).count
      unassigned_by = open_scope.where(assigned_to_id: nil).group(:fixed_version_id).count
      noest_by      = base.where(estimated_hours: nil).group(:fixed_version_id).count
      est_by        = base.group(:fixed_version_id).sum(:estimated_hours)
      start_by      = base.group(:fixed_version_id).minimum(:start_date)
      due_by        = base.group(:fixed_version_id).maximum(:due_date)
      spent_by      = base.joins(:time_entries).group(:fixed_version_id).sum('time_entries.hours')

      # Cost custom fields: mirror Redmine's Numeric#total_for_scope
      # (lib/redmine/field_format.rb) — join custom_values, skip empty strings so
      # the numeric CAST is safe on both PostgreSQL and MySQL — plus a GROUP BY.
      cost_by = {} # "field_id" => { version_id => BigDecimal }
      Array(cost_field_ids).map { |id| id.to_i }.reject(&:zero?).uniq.each do |fid|
        cost_by[fid.to_s] = base.joins(:custom_values)
          .where(custom_values: { custom_field_id: fid })
          .where.not(custom_values: { value: '' })
          .group(:fixed_version_id)
          .sum("CAST(#{CustomValue.table_name}.value AS decimal(30,3))")
      end

      totals.keys.map do |vid|
        cost = {}
        cost_by.each { |fid, by_version| (v = by_version[vid]) && cost[fid] = v.to_f }
        {
          'version_id'      => vid,
          'total'           => totals[vid]        || 0,
          'open'            => open_by[vid]       || 0,
          'closed'          => closed_by[vid]     || 0,
          'open_done_sum'   => (done_by[vid]      || 0).to_i,
          'overdue_open'    => overdue_by[vid]    || 0,
          'unassigned_open' => unassigned_by[vid] || 0,
          'no_estimate'     => noest_by[vid]      || 0,
          'est_hours'       => (est_by[vid]       || 0).to_f,
          'spent_hours'     => (spent_by[vid]     || 0).to_f,
          'start_date'      => start_by[vid],
          'due_date'        => due_by[vid],
          'cost'            => cost
        }
      end
    end

    # ------------------------------------------------------------------
    # Label generation — one label per period, oldest first
    # ------------------------------------------------------------------

    def self.build_labels(n, period)
      today = Date.today   # memoised once; avoids a midnight-crossing skew across iterations
      case period.to_s
      when 'day'
        (0...n).map { |i| (today - i).strftime('%Y-%m-%d') }.reverse
      when 'week'
        # cwyear: ISO year — differs from calendar year in the last/first week of January.
        # MySQL %x and PostgreSQL IYYY both match cwyear; do NOT replace with .year here.
        (0...n).map do |i|
          d = today - (i * 7)
          "#{d.cwyear}-W#{d.cweek.to_s.rjust(2, '0')}"
        end.reverse
      when 'month'
        (0...n).map { |i| (today << i).strftime('%Y-%m') }.reverse
      when 'year'
        (0...n).map { |i| (today << (i * 12)).strftime('%Y') }.reverse
      else
        (0...n).map { |i| (today << i).strftime('%Y-%m') }.reverse
      end
    end

    # ------------------------------------------------------------------
    # Private helpers
    # ------------------------------------------------------------------

    # Start of the OLDEST bucket build_labels produces, so the WHERE window and
    # the label axis cover exactly the same span. n-1, not n: build_labels counts
    # the current period as the first of the n. A wider window used to be
    # harmless for .aggregate — it maps counts onto the labels and drops the rest
    # — but the period dimension reports what it is given, and a stray bucket
    # outside the axis is not something a template can chart.
    def self.period_from(n, period)
      back = [n.to_i - 1, 0].max
      case period.to_s
      when 'day'   then back.days.ago.beginning_of_day
      when 'week'  then back.weeks.ago.beginning_of_week
      when 'month' then back.months.ago.beginning_of_month
      when 'year'  then back.years.ago.beginning_of_year
      else              back.months.ago.beginning_of_month
      end
    end
    private_class_method :period_from

    def self.sanitize_periods(value, cfg)
      n = value.to_i
      n = cfg[:default] unless n.positive?
      [n, cfg[:max]].min
    end
    private_class_method :sanitize_periods

    def self.resolve_closed_ids(names)
      names = Array(names).map(&:strip).reject(&:empty?)
      if names.any?
        ids = IssueStatus.where(name: names).pluck(:id)
        if ids.empty?
          Rails.logger.warn("[sql_aggregation] closed_statuses #{names.inspect} matched no IssueStatus records — treating all issues as open")
        end
        ids
      else
        IssueStatus.where(is_closed: true).pluck(:id)
      end
    end
    private_class_method :resolve_closed_ids

    # :postgresql | :mysql | :unknown. :unknown means the adapter name could not
    # be read at all (no connection) — that is not the same as "some other
    # database", and must not be turned into a hard failure.
    def self.adapter_family
      @adapter_family ||=
        begin
          name = ActiveRecord::Base.connection.adapter_name.to_s
          if name.match?(/postgres|postgis/i)
            :postgresql
          elsif name.match?(/mysql|maria|trilogy/i)
            :mysql
          else
            Rails.logger.warn("[sql_aggregation] database adapter #{name.inspect} is not supported " \
                              '— only PostgreSQL and MySQL/MariaDB are')
            :unsupported
          end
        rescue StandardError
          :unknown
        end
    end
    private_class_method :adapter_family

    def self.postgresql?
      adapter_family == :postgresql
    end
    private_class_method :postgresql?

    # Fail fast and legibly on an adapter whose date formatting we do not speak,
    # rather than emitting MySQL syntax and letting the database complain.
    def self.date_format_sql(column, cfg)
      case adapter_family
      when :postgresql
        "TO_CHAR(#{column}, '#{cfg[:pg_format]}')"
      when :unsupported
        raise UnsupportedAdapterError,
              'period aggregation needs PostgreSQL or MySQL/MariaDB date formatting'
      else
        "DATE_FORMAT(#{column}, '#{cfg[:sql_format]}')"
      end
    end
    private_class_method :date_format_sql

    # ------------------------------------------------------------------
    # Dimension helpers — grouping and result assembly
    # ------------------------------------------------------------------

    # The association join comes FIRST on purpose. ActiveRecord renders
    # association joins before raw string joins, so `projects` is already in the
    # FROM clause by the time the custom-values ON clause references it —
    # IssueCustomField#visibility_by_project_condition always embeds
    # Issue.visible_condition, which reads projects.status and enabled_modules.
    # IssueQuery#base_scope (Issue.visible.joins(:status, :project)) carries that
    # join already and ActiveRecord de-duplicates identical association joins, so
    # this only adds a join to the scopes that lack one — e.g. the
    # Issue.where(id: ids) that ScopeResolution rebuilds from a loaded Array.
    # issues.project_id is NOT NULL, so the INNER JOIN never drops a row.
    def self.apply_dimension(base, dim)
      base = base.joins(:project) if dim.project_join
      base = base.joins(dim.join) if dim.join
      base = dim.scope_filter.call(base) if dim.scope_filter
      base
    end
    private_class_method :apply_dimension

    def self.single_result(base, dim, sort:, limit:, other_label:, group_by:)
      totals = base.group(dim.sql).count(DISTINCT_ISSUES)
      axis   = build_axis(dim, totals, sort: sort, limit: limit, other_label: other_label)

      counts = Hash.new(0)
      totals.each { |raw, count| counts[axis.key_map.fetch(raw, raw)] += count.to_i }

      buckets = axis.keys.map { |key| { 'label' => axis.labels[key], 'count' => counts[key] } }

      {
        'buckets'     => buckets,
        'total'       => buckets.sum { |b| b['count'] },
        'group_by'    => group_by.to_s,
        'dimension'   => dim.name,
        'field_name'  => dim.field_name,
        'multi_value' => dim.multi_value ? true : false,
        'truncated'   => axis.truncated
      }
    end
    private_class_method :single_result

    # One GROUP BY over both dimensions, pivoted in Ruby into a dense matrix.
    # `limit` applies to the rows only — the series axis is bounded by the hard
    # cap alone, so a row limit never silently drops a chart series.
    def self.crosstab_result(base, group_dim, split_dim, sort:, limit:, other_label:,
                             group_by:, split_by:)
      pairs = base.group(group_dim.sql, split_dim.sql).count(DISTINCT_ISSUES)

      row_totals    = Hash.new(0)
      series_totals = Hash.new(0)
      pairs.each do |(row_raw, series_raw), count|
        row_totals[row_raw]       += count.to_i
        series_totals[series_raw] += count.to_i
      end

      row_axis    = build_axis(group_dim, row_totals, sort: sort, limit: limit,
                                                      other_label: other_label)
      series_axis = build_axis(split_dim, series_totals, sort: sort, limit: 0,
                                                         other_label: other_label)

      grid = {}
      pairs.each do |(row_raw, series_raw), count|
        row_key    = row_axis.key_map.fetch(row_raw, row_raw)
        series_key = series_axis.key_map.fetch(series_raw, series_raw)
        (grid[row_key] ||= Hash.new(0))[series_key] += count.to_i
      end

      series = series_axis.keys.map { |key| series_axis.labels[key] }

      rows = row_axis.keys.map do |row_key|
        row_grid = grid[row_key] || {}
        counts   = series_axis.keys.map { |key| row_grid[key] || 0 }
        cells    = {}
        series.each_with_index { |label, i| cells[label] = counts[i] }
        { 'label'  => row_axis.labels[row_key], 'total' => counts.sum,
          'counts' => counts,                   'cells' => cells }
      end

      {
        'series'            => series,
        'rows'              => rows,
        'matrix'            => rows.map { |r| r['counts'] },
        'columns'           => series.each_index.map { |i| rows.sum { |r| r['counts'][i] } },
        'buckets'           => rows.map { |r| { 'label' => r['label'], 'count' => r['total'] } },
        'total'             => rows.sum { |r| r['total'] },
        'group_by'          => group_by.to_s,
        'split_by'          => split_by.to_s,
        'dimension'         => group_dim.name,
        'field_name'        => group_dim.field_name,
        'series_field_name' => split_dim.field_name,
        'multi_value'       => (group_dim.multi_value || split_dim.multi_value) ? true : false,
        'truncated'         => (row_axis.truncated || series_axis.truncated)
      }
    end
    private_class_method :crosstab_result

    # Orders one axis and decides which raw keys collapse into Other / the empty
    # bucket. Both special buckets always sit at the end, whatever `sort` says.
    def self.build_axis(dim, totals, sort:, limit:, other_label:)
      blank, present = totals.keys.partition { |key| blank_key?(key) }
      labels         = safe_label_map(dim, present)

      if dim.fixed_keys
        # period / age: fixed chronological or ascending order, no sort, no limit.
        ordered = dim.fixed_keys.dup
        ordered += sort_keys(present - ordered, totals, labels, dim, 'label')
        dropped = []
      else
        ordered = sort_keys(present, totals, labels, dim, sort)
        cap     = limit.to_i.positive? ? [limit.to_i, MAX_DIMENSION_KEYS].min : MAX_DIMENSION_KEYS
        dropped = ordered.drop(cap)
        ordered = ordered.first(cap)
      end

      key_map = {}
      ordered.each { |key| key_map[key] = key }
      dropped.each { |key| key_map[key] = OTHER_KEY }
      blank.each   { |key| key_map[key] = EMPTY_KEY }

      # NOTE: .empty?, not .any? — the blank bucket's only member is usually nil,
      # and [nil].any? is false.
      display = ordered.dup
      display << OTHER_KEY unless dropped.empty?
      display << EMPTY_KEY unless blank.empty?

      label_of = {}
      ordered.each { |key| label_of[key] = labels[key] || fallback_label(dim, key) }
      label_of[OTHER_KEY] = other_label.to_s
      label_of[EMPTY_KEY] = dim.empty_label.to_s

      Axis.new(keys: display, labels: label_of, key_map: key_map, truncated: !dropped.empty?)
    end
    private_class_method :build_axis

    # Every comparison ends in the raw key so the order is total — two labels
    # with the same count must not depend on Hash or adapter ordering.
    def self.sort_keys(keys, totals, labels, dim, sort)
      return [] if keys.empty?

      case sort
      when 'label'
        keys.sort_by { |key| [natural_key(labels[key] || key.to_s), key.to_s] }
      when 'position'
        positions = safe_order_map(dim, keys)
        keys.sort_by do |key|
          position = positions[key]
          [position ? 0 : 1, position.to_i, natural_key(labels[key] || key.to_s), key.to_s]
        end
      else
        keys.sort_by { |key| [-totals[key].to_i, natural_key(labels[key] || key.to_s), key.to_s] }
      end
    end
    private_class_method :sort_keys

    # "Phase 2" before "Phase 10", and case-insensitive, without a locale-dependent
    # collation. Each token is a [kind, number, text] triple so the tuples always
    # compare element-for-element; numeric tokens sort before text ones.
    def self.natural_key(label)
      label.to_s.downcase.scan(/\d+|\D+/).map do |token|
        token.match?(/\A\d/) ? [0, token.to_i, ''] : [1, 0, token]
      end
    end
    private_class_method :natural_key

    def self.blank_key?(key)
      key.nil? || key.to_s.strip.empty?
    end
    private_class_method :blank_key?

    def self.safe_label_map(dim, keys)
      return {} if keys.empty? || dim.label_map.nil?

      map = dim.label_map.call(keys)
      map.is_a?(Hash) ? map : {}
    rescue StandardError => e
      Rails.logger.warn("[sql_aggregation] label lookup failed for #{dim.name}: #{e.class}: #{e.message}")
      {}
    end
    private_class_method :safe_label_map

    def self.fallback_label(dim, key)
      return key.to_s if dim.fallback_label.nil?

      dim.fallback_label.call(key).to_s
    rescue StandardError
      key.to_s
    end
    private_class_method :fallback_label

    def self.safe_order_map(dim, keys)
      return {} if keys.empty? || dim.order_map.nil?

      map = dim.order_map.call(keys)
      map.is_a?(Hash) ? map : {}
    rescue StandardError => e
      Rails.logger.warn("[sql_aggregation] position lookup failed for #{dim.name}: #{e.class}: #{e.message}")
      {}
    end
    private_class_method :safe_order_map

    def self.sanitize_sort(value)
      sort = value.to_s.strip.downcase
      return sort if SORT_MODES.include?(sort)

      unless sort.empty?
        Rails.logger.warn("[sql_aggregation] unknown sort #{value.inspect} — falling back to count")
      end
      'count'
    end
    private_class_method :sanitize_sort

    # ------------------------------------------------------------------
    # Dimension builders
    # ------------------------------------------------------------------

    def self.core_dimension(name, cfg, empty_label:, user_label:)
      user_field = %i[assigned_to_id author_id].include?(cfg[:field])
      by_name    = user_field && user_label.to_s != 'login'

      Dimension.new(
        name: name,
        # Symbol, not raw SQL: ActiveRecord qualifies it with the issues table and
        # casts the group keys to the column type on every adapter.
        sql: cfg[:field],
        label_map: lambda { |raw_ids|
          ids = raw_ids.compact
          next {} if ids.empty?

          names = by_name ? user_display_names(ids) : cfg[:lookup].call(ids)
          # A blank name is left out so it falls through to fallback_label.
          names.each_with_object({}) do |(id, label), map|
            map[id] = label.to_s unless label.to_s.strip.empty?
          end
        },
        # Same "Status #7" text .breakdown produces for an id with no record.
        fallback_label: ->(id) { "#{name.capitalize} ##{id}" },
        empty_label: empty_label.nil? ? cfg[:null_label] : empty_label.to_s
      )
    end
    private_class_method :core_dimension

    # Display name ("Jane Doe"), not the login — a chart axis is read by humans.
    # One query, only for the distinct ids actually present.
    def self.user_display_names(ids)
      User.where(id: ids).to_a.each_with_object({}) { |user, map| map[user.id] = user.name.to_s }
    end
    private_class_method :user_display_names

    def self.custom_field_dimension(name, field_id, suffix:, empty_label:)
      unless field_id.positive?
        Rails.logger.warn("[sql_aggregation] #{name} is not a usable custom field id")
        return nil
      end

      custom_field = find_issue_custom_field(field_id)
      if custom_field.nil?
        Rails.logger.warn("[sql_aggregation] custom field ##{field_id} does not exist " \
                          'or is not an issue custom field')
        return nil
      end

      # NOT cf_<id>: that alias is what Redmine's own IssueQuery uses when a query
      # sorts or groups on a custom field (lib/redmine/field_format.rb#join_alias),
      # and the incoming scope may already carry it.
      #
      # The visibility clause mirrors Redmine's own join: a custom field can be
      # restricted to roles, and without it a viewer who may not see the field
      # would still get its values as chart labels. Like core, a viewer who is
      # not entitled sees the values as NULL — they land in the empty bucket.
      table = CustomValue.table_name
      join  = "LEFT OUTER JOIN #{table} rrd_cv_#{suffix}" \
              " ON rrd_cv_#{suffix}.customized_type = 'Issue'" \
              " AND rrd_cv_#{suffix}.customized_id = issues.id" \
              " AND rrd_cv_#{suffix}.custom_field_id = #{field_id}" \
              " AND (#{visibility_condition(custom_field)})"

      Dimension.new(
        name: name,
        # NULLIF collapses '' and NULL into one "no value" bucket.
        sql: Arel.sql("NULLIF(rrd_cv_#{suffix}.value, '')"),
        join: join,
        project_join: true,
        label_map: ->(raws) { custom_field_labels(custom_field, raws) },
        order_map: ->(raws) { custom_field_positions(custom_field, raws) },
        field_name: custom_field.name.to_s,
        multi_value: custom_field.respond_to?(:multiple?) && custom_field.multiple? ? true : false,
        empty_label: empty_label.nil? ? DEFAULT_EMPTY_LABEL : empty_label.to_s
      )
    end
    private_class_method :custom_field_dimension

    # Redmine's CustomField#visibility_by_project_condition: "1=1" for a field
    # everyone may see, "1=0" for anonymous, otherwise a subquery limiting the
    # values to projects where the viewer has an entitled role. Fails CLOSED —
    # an authorization clause we cannot build must not silently disappear.
    def self.visibility_condition(custom_field)
      return '1=1' unless custom_field.respond_to?(:visibility_by_project_condition)

      condition = custom_field.visibility_by_project_condition.to_s.strip
      condition.empty? ? '1=1' : condition
    rescue StandardError => e
      Rails.logger.warn("[sql_aggregation] could not build the visibility condition for custom " \
                        "field ##{custom_field.id}: #{e.class}: #{e.message} — hiding its values")
      '1=0'
    end
    private_class_method :visibility_condition

    # An issue custom field is identified by its STI class. CustomField has no
    # `customized_type` column and no such method: that name exists only on
    # custom_values, and in the REST API representation
    # (custom_fields/index.api.rsb renders field.class.customized_class.name
    # .underscore, so "issue" in lowercase).
    def self.find_issue_custom_field(field_id)
      custom_field = CustomField.find_by(id: field_id)
      return nil if custom_field.nil?
      return nil unless issue_custom_field?(custom_field)

      custom_field
    rescue StandardError => e
      Rails.logger.warn("[sql_aggregation] custom field ##{field_id} lookup failed: #{e.class}: #{e.message}")
      nil
    end
    private_class_method :find_issue_custom_field

    # Three checks, so this holds under Redmine (constant loaded), under a bare
    # RSpec run (constant stubbed away) and for plugin subclasses.
    def self.issue_custom_field?(custom_field)
      return true if defined?(IssueCustomField) && custom_field.is_a?(IssueCustomField)
      return true if custom_field.respond_to?(:type) && custom_field.type.to_s == 'IssueCustomField'
      return false unless custom_field.class.respond_to?(:customized_class)

      custom_field.class.customized_class.to_s == 'Issue'
    end
    private_class_method :issue_custom_field?

    # Label resolution, in order: the field's own format, then the enumeration
    # table (enumeration / depending_enumeration store the enumeration id in
    # custom_values.value), then the raw value.
    #
    # For enumeration-backed formats the two first steps are swapped, because
    # they answer identically and the batched one costs a single query:
    # Redmine::FieldFormat::RecordList#cast_single_value runs
    # `target_class.find_by_id(value)` — one round trip PER DISTINCT VALUE. That
    # order is NOT safe for other formats: a `list` field whose options happen to
    # be "1", "2", "3" must be named by its own format, not by unrelated
    # CustomFieldEnumeration rows with those ids.
    def self.custom_field_labels(custom_field, raws)
      values = raws.compact.reject { |raw| raw.to_s.strip.empty? }.uniq
      return {} if values.empty?

      batched = enumeration_backed?(custom_field)
      labels  = batched ? enumeration_labels(values) : {}

      unresolved(values, labels).each do |raw|
        label = cast_custom_value_label(custom_field, raw)
        labels[raw] = label if label
      end

      # Only when the batch has not already run, so a dimension never issues two.
      labels.merge!(enumeration_labels(unresolved(values, labels))) unless batched

      values.each { |raw| labels[raw] ||= raw.to_s }
      labels
    end
    private_class_method :custom_field_labels

    # True for 'enumeration' and for plugin formats built on it, such as the
    # 'depending_enumeration' format used by Client / Business Entity /
    # Lesson Category.
    def self.enumeration_backed?(custom_field)
      format = custom_field.respond_to?(:format) ? custom_field.format : nil
      if defined?(CustomFieldEnumeration) && format.respond_to?(:target_class)
        return true if format.target_class == CustomFieldEnumeration
      end

      custom_field.respond_to?(:field_format) &&
        custom_field.field_format.to_s.include?('enumeration')
    rescue StandardError
      false
    end
    private_class_method :enumeration_backed?

    def self.unresolved(values, labels)
      values.reject { |raw| labels.key?(raw) }
    end
    private_class_method :unresolved

    # One batched query for every value that looks like an enumeration id.
    def self.enumeration_labels(raws)
      ids = raws.select { |raw| raw.to_s.match?(/\A\d+\z/) }
      return {} if ids.empty?

      names = custom_field_enumeration_names(ids)
      ids.each_with_object({}) do |raw, map|
        name = names[raw.to_s]
        map[raw] = name unless name.nil? || name.empty?
      end
    end
    private_class_method :enumeration_labels

    def self.cast_custom_value_label(custom_field, raw)
      format = custom_field.respond_to?(:format) ? custom_field.format : nil
      return nil unless format.respond_to?(:cast_value)

      value = format.cast_value(custom_field, raw)
      return nil if value.nil?

      label = value.respond_to?(:name) ? value.name.to_s : value.to_s
      label.strip.empty? ? nil : label
    rescue StandardError => e
      # Deliberately quiet: a format that cannot cast one value falls through to
      # the enumeration lookup and then to the raw value.
      Rails.logger.debug("[sql_aggregation] cast_value failed for #{raw.inspect}: #{e.class}")
      nil
    end
    private_class_method :cast_custom_value_label

    def self.custom_field_enumeration_names(ids)
      return {} unless defined?(CustomFieldEnumeration)

      CustomFieldEnumeration.where(id: ids.map(&:to_i)).pluck(:id, :name)
                            .each_with_object({}) { |(id, name), map| map[id.to_s] = name.to_s }
    rescue StandardError => e
      Rails.logger.warn("[sql_aggregation] enumeration lookup failed: #{e.class}: #{e.message}")
      {}
    end
    private_class_method :custom_field_enumeration_names

    # sort: position — the field's own value order: CustomFieldEnumeration#position
    # for enumeration formats, otherwise the index in possible_values. Values with
    # no known position are left out of the map and sort after the known ones.
    def self.custom_field_positions(custom_field, raws)
      positions = {}

      enum_ids = raws.select { |raw| raw.to_s.match?(/\A\d+\z/) }
      if enum_ids.any? && defined?(CustomFieldEnumeration)
        CustomFieldEnumeration.where(id: enum_ids.map(&:to_i)).pluck(:id, :position)
                              .each { |id, position| positions[id.to_s] = position.to_i }
      end

      values = custom_field.respond_to?(:possible_values) ? Array(custom_field.possible_values) : []
      values.each_with_index { |value, index| positions[value.to_s] ||= index }

      raws.each_with_object({}) do |raw, map|
        position = positions[raw.to_s]
        map[raw] = position unless position.nil?
      end
    rescue StandardError => e
      Rails.logger.warn("[sql_aggregation] position lookup failed: #{e.class}: #{e.message}")
      {}
    end
    private_class_method :custom_field_positions

    def self.period_dimension(name, period:, periods:, date_field:, empty_label:)
      type = period.to_s
      unless PERIOD_CONFIG.key?(type)
        Rails.logger.warn("[sql_aggregation] unknown period #{period.inspect} — falling back to month") unless type.empty?
        type = 'month'
      end
      cfg = PERIOD_CONFIG[type]

      field = date_field.to_s
      unless PERIOD_DATE_COLUMNS.key?(field)
        Rails.logger.warn("[sql_aggregation] unknown date_field #{date_field.inspect} — falling back to created") unless field.empty?
        field = 'created'
      end
      column = PERIOD_DATE_COLUMNS[field]

      count = sanitize_periods(periods, cfg)

      Dimension.new(
        name: name,
        sql: Arel.sql(date_format_sql(column, cfg)),
        scope_filter: ->(scope) { scope.where("#{column} >= ?", period_from(count, type)) },
        fixed_keys: build_labels(count, type),
        empty_label: empty_label.nil? ? DEFAULT_EMPTY_LABEL : empty_label.to_s
      )
    end
    private_class_method :period_dimension

    # Portable on PostgreSQL and MySQL: no DATEDIFF, no CURRENT_DATE arithmetic.
    # The boundaries are computed in Ruby and bound as parameters; the SQL is a
    # plain CASE over >= comparisons. A NULL date (age_field: due) yields NULL and
    # lands in the empty bucket, not in the oldest one.
    def self.age_dimension(name, age_buckets:, age_field:, empty_label:)
      bounds = normalize_age_buckets(age_buckets)

      field = age_field.to_s
      unless AGE_DATE_COLUMNS.key?(field)
        Rails.logger.warn("[sql_aggregation] unknown age_field #{age_field.inspect} — falling back to created") unless field.empty?
        field = 'created'
      end
      column = AGE_DATE_COLUMNS[field]
      labels = age_bucket_labels(bounds)
      today  = Date.today

      fragments = ["CASE WHEN #{column} IS NULL THEN NULL"]
      binds     = []
      bounds.each_with_index do |days, index|
        fragments << "WHEN #{column} >= ? THEN ?"
        binds << (field == 'due' ? today - days : days.days.ago) << labels[index]
      end
      fragments << 'ELSE ? END'
      binds << labels.last

      Dimension.new(
        name: name,
        sql: Arel.sql(ActiveRecord::Base.sanitize_sql_array([fragments.join(' '), *binds])),
        fixed_keys: labels,
        empty_label: empty_label.nil? ? DEFAULT_EMPTY_LABEL : empty_label.to_s
      )
    end
    private_class_method :age_dimension

    def self.normalize_age_buckets(value)
      list = case value
             when nil   then []
             when Array then value
             else value.to_s.split(/[;,]/)
             end

      bounds = list.map { |entry| entry.to_s.strip.to_i }.select(&:positive?).uniq.sort
      if bounds.length > MAX_AGE_BUCKETS
        Rails.logger.warn("[sql_aggregation] age_buckets has #{bounds.length} boundaries — " \
                          "keeping the first #{MAX_AGE_BUCKETS}")
        bounds = bounds.first(MAX_AGE_BUCKETS)
      end
      return bounds unless bounds.empty?

      unless list.empty?
        Rails.logger.warn("[sql_aggregation] age_buckets #{value.inspect} has no positive day " \
                          "boundary — falling back to #{DEFAULT_AGE_BUCKETS.inspect}")
      end
      DEFAULT_AGE_BUCKETS.dup
    end
    private_class_method :normalize_age_buckets

    # [30, 60, 90, 180] => ["0-30", "31-60", "61-90", "91-180", ">180"]
    def self.age_bucket_labels(bounds)
      labels   = []
      previous = 0
      bounds.each do |boundary|
        labels << (previous.zero? ? "0-#{boundary}" : "#{previous + 1}-#{boundary}")
        previous = boundary
      end
      labels << ">#{previous}"
      labels
    end
    private_class_method :age_bucket_labels

    def self.days_since(timestamp)
      return nil if timestamp.nil?

      (Date.today - timestamp.to_date).to_i
    rescue StandardError
      nil
    end
    private_class_method :days_since
  end
end
