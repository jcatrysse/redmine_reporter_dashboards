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
  #   Returns: labels, created, closed, open_at_end, open_now, total, period, periods
  #
  #   open_at_end is the backlog height: issues that existed and were not yet closed
  #   at the end of each period. One conditional aggregate per period, chunked.
  #   closed_on records only the last closing and survives a reopen, so a reopened
  #   issue counts as open for everything before that last closing; and the points
  #   carry no drill-through URL.
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
  #   measure / of    — what a bucket VALUE is, when it is not a row count:
  #                     count (default) | distinct | sum | avg over an `of:` field.
  #                     A non-additive measure makes `total` its own aggregate
  #                     rather than the sum of the buckets.
  #
  #   One dimension  → buckets, total, group_by, dimension, field_name,
  #                    measure, measure_field, multi_value, truncated
  #   Two dimensions → additionally series, rows, matrix, columns, split_by,
  #                    series_field_name, series_entries
  #                    (a dense rows x series crosstab)
  #
  #   Every bucket, row and series entry additionally carries the raw stored
  #   value and the issue-list filter that isolates it, so {% sql_aggregate %}
  #   can turn a chart element into a drill-through URL:
  #
  #     'value'  => '415'                 # raw value, nil for the empty bucket
  #     'values' => ['580', '581']        # only on a collapsed Other row
  #     'filter' => { 'field' => 'cf_92', 'operator' => '=', 'values' => ['415'] }
  #
  #   'filter' is nil whenever the bucket cannot be expressed as an issue-list
  #   filter; labels and counts are unaffected.
  #
  #
  #   Returns nil (after logging a warning) when a dimension cannot be resolved,
  #   so the caller can assign its empty-safe result instead of raising.
  #
  # --- Completeness (.completeness) ---
  #
  #   fields — up to 12 core fields and/or cf_<id> names
  #
  #   One bucket per field: label, count (FILLED), empty, total, pct, value, and the
  #   is-set / is-not-set filters. One statement, and one custom_values join for all
  #   the custom fields. Bucket order follows `fields:`; sort and limit do not apply.
  #   The numbers are what the VIEWER may see: a role-restricted field counts as
  #   empty for a user who cannot see it.
  #
  # --- Governance flags (.flags) ---
  #
  #   One row of scalar counters for KPI tiles: total, open, closed, assigned,
  #   unassigned, with_due_date, without_due_date, overdue, no_estimate,
  #   oldest_open_days, newest_open_days, median_open_days, p90_open_days — plus
  #   `stages`, the funnel projection of four of them with the issue-list filter
  #   that isolates each stage.
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

    # How many conditional aggregates go into one statement. `period: day` allows 90
    # periods, which is more than is comfortable in a single SELECT on either
    # adapter; three statements for the widest window is a fair trade.
    OPEN_AT_END_CHUNK = 30

    # Hard cap on the number of rows / series returned, independent of `limit`.
    # Protects a dashboard from someone grouping on a free-text custom field.
    MAX_DIMENSION_KEYS = 200

    PERIOD_DATE_COLUMNS = { 'created' => 'issues.created_on', 'closed' => 'issues.closed_on' }.freeze
    AGE_DATE_COLUMNS    = { 'created' => 'issues.created_on', 'updated' => 'issues.updated_on',
                            'due'     => 'issues.due_date' }.freeze

    # The IssueQuery filter name behind each date column, for drill-through.
    PERIOD_FILTER_FIELDS = { 'created' => 'created_on', 'closed' => 'closed_on' }.freeze
    AGE_FILTER_FIELDS    = { 'created' => 'created_on', 'updated' => 'updated_on',
                             'due'     => 'due_date' }.freeze

    # Funnel projection of the flags counters. `total` has no filter: the report
    # query unchanged IS the first stage. `status_id` with the operator `c`
    # (closed) is used instead of an id list so the stage stays correct whatever
    # Redmine considers closed — see the caveat about an explicit
    # closed_statuses: in the README.
    FLAG_STAGES = [
      { key: 'total',         label: 'Registered',   field: nil,               operator: nil },
      { key: 'assigned',      label: 'Has assignee', field: 'assigned_to_id',  operator: '*' },
      { key: 'with_due_date', label: 'Has due date', field: 'due_date',        operator: '*' },
      { key: 'closed',        label: 'Closed',       field: 'status_id',       operator: 'c' }
    ].freeze

    # ------------------------------------------------------------------
    # Measures — what a bucket VALUE is, when it is not a row count
    # ------------------------------------------------------------------

    MEASURE_KINDS = %w[count distinct sum avg].freeze

    # `count` and `sum` are additive, so a collapsed bucket is the sum of its parts.
    # `distinct` and `avg` are not: they need their own aggregate.
    ADDITIVE_MEASURES = %i[count sum].freeze

    # Core reference columns usable with measure: distinct. Anything countable is
    # allowed here; the numeric measures live in MEASURE_NUMERIC_COLUMNS.
    MEASURE_REFERENCES = {
      'author'   => 'issues.author_id',      'assignee' => 'issues.assigned_to_id',
      'tracker'  => 'issues.tracker_id',     'status'   => 'issues.status_id',
      'priority' => 'issues.priority_id',    'category' => 'issues.category_id',
      'version'  => 'issues.fixed_version_id', 'project' => 'issues.project_id',
      'issue'    => 'issues.id'
    }.freeze

    MEASURE_NUMERIC_COLUMNS = { 'estimated_hours' => 'issues.estimated_hours',
                                'done_ratio'      => 'issues.done_ratio' }.freeze

    # Custom field formats whose values can be summed or averaged.
    NUMERIC_CF_FORMATS = %w[int float].freeze

    # kind         — :count | :distinct | :sum | :avg
    # field        — the `of:` name, echoed back as measure_field
    # expression   — SQL the aggregate is applied to (nil for a plain issue count)
    # join         — optional raw join fragment
    # project_join — true when the join fragment references the projects table
    Measure = Struct.new(:kind, :field, :expression, :join, :project_join, keyword_init: true)

    # ------------------------------------------------------------------
    # Completeness — how much of each field is actually filled in
    # ------------------------------------------------------------------

    # Every named field becomes one conditional aggregate, so the statement grows
    # with the list. Twelve is already a wide chart.
    MAX_COMPLETENESS_FIELDS = 12

    # Core fields worth asking about, i.e. the nullable ones. `text` fields are
    # empty when they are NULL *or* blank, like a custom value.
    COMPLETENESS_CORE_FIELDS = {
      'assigned_to_id'   => { label: 'Assignee',       text: false },
      'category_id'      => { label: 'Category',       text: false },
      'fixed_version_id' => { label: 'Target version', text: false },
      'parent_id'        => { label: 'Parent task',    text: false },
      'due_date'         => { label: 'Due date',       text: false },
      'start_date'       => { label: 'Start date',     text: false },
      'estimated_hours'  => { label: 'Estimated time', text: false },
      'description'      => { label: 'Description',    text: true }
    }.freeze

    # The dimension-style names are accepted too, so `fields:` reads the same way
    # `group_by:` does.
    COMPLETENESS_ALIASES = {
      'assignee' => 'assigned_to_id', 'category'  => 'category_id',
      'version'  => 'fixed_version_id', 'parent'  => 'parent_id',
      'due'      => 'due_date',       'start'     => 'start_date',
      'estimated' => 'estimated_hours', 'estimated_time' => 'estimated_hours'
    }.freeze

    # One field to report on: `condition` is the SQL that makes it count as filled,
    # `filter_field` the IssueQuery filter name behind it.
    CompletenessField = Struct.new(:key, :label, :filter_field, :condition, :custom_field_id,
                                  keyword_init: true)

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
    #   filter_field — IssueQuery filter name for drill-through ('cf_92',
    #                  'status_id', 'created_on'); nil when the dimension cannot
    #                  be expressed as an issue-list filter at all
    #   filter_for   — ->(raw_keys) { {'field','operator','values'} | nil }, given
    #                  one raw key for a normal bucket and every collapsed raw key
    #                  for the Other bucket
    Dimension = Struct.new(:name, :sql, :join, :project_join, :scope_filter, :label_map,
                           :fallback_label, :order_map, :fixed_keys, :field_name, :multi_value,
                           :empty_label, :filter_field, :filter_for, keyword_init: true)

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
        'labels'      => labels,
        'created'     => labels.map { |l| created_raw[l] || 0 },
        'closed'      => labels.map { |l| closed_raw[l]  || 0 },
        'open_at_end' => open_at_end(base, labels, period, closed_ids),
        'open_now'    => open_count,
        'total'       => total,
        'period'      => period.to_s,
        'periods'     => periods
      }
    end

    # ------------------------------------------------------------------
    # Issues open at the end of each period
    # ------------------------------------------------------------------

    # The backlog height, aligned with `labels`. A template could only approximate
    # this by running a cumulative sum of created - closed in JavaScript, which is
    # wrong for every issue that already existed when the window opened.
    #
    # One conditional aggregate per period in a single statement, so the number of
    # round trips does not grow with the window. `period: day` allows 90 buckets,
    # which is more than is comfortable in one SELECT, so the aggregates are
    # chunked.
    #
    # LIMITATION: `closed_on` records only the LAST closing, and Redmine PRESERVES it
    # when an issue is reopened (Issue#update_closed_on: "the closed_on attribute
    # stores the time of the last closing and is preserved when the issue is
    # reopened" — it has no clearing branch). There is therefore no record of when an
    # issue was closed the first time, so an issue closed in March, reopened in April
    # and closed again in June counts as open for everything before June.
    #
    # Because closed_on survives a reopen, the CURRENT status is what decides whether
    # we treat an issue as closed at all — see open_at_expression, where that term is
    # load-bearing rather than belt-and-braces. Getting the real history right means
    # reading journals: far more expensive, and out of scope. Documented next to the
    # key in the README.
    def self.open_at_end(base, labels, period, closed_ids)
      ends = labels.map { |label| period_end_bound(label, period) }
      return labels.map { 0 } if ends.any?(&:nil?)

      values = []
      ends.each_slice(OPEN_AT_END_CHUNK) do |slice|
        values.concat(aggregate_row(base, slice.map { |at| open_at_expression(at, closed_ids) }))
      end
      values.map { |value| value.to_i }
    rescue UnsupportedAdapterError
      raise
    rescue StandardError => e
      Rails.logger.warn("[sql_aggregation] open_at_end could not be computed: #{e.class}: #{e.message}")
      labels.map { 0 }
    end
    private_class_method :open_at_end

    # "Existed before `bound`, and was not closed yet." `bound` is the EXCLUSIVE end
    # of the period — midnight starting the next one — so there is no 23:59:59 gap
    # to lose a row in.
    #
    # The status term is NOT redundant. `closed_on` is preserved when an issue is
    # reopened, so on its own it would report a currently-open issue as closed for
    # every period after the closing it once had — and disagree with `open_now` about
    # today. Requiring the current status to be a closed one is what makes a reopened
    # issue count as open.
    #
    # It also makes this mirror the `closed` series: both honour closed_statuses, so a
    # chart drawing them together cannot disagree with itself about what "closed"
    # means. With no closed status at all every issue counts as open, exactly as
    # `open_now` does.
    def self.open_at_expression(bound, closed_ids)
      if closed_ids.empty?
        return ActiveRecord::Base.sanitize_sql_array([count_case('issues.created_on < ?'), bound])
      end

      ActiveRecord::Base.sanitize_sql_array(
        [count_case('issues.created_on < ? AND NOT (issues.closed_on IS NOT NULL ' \
                    'AND issues.closed_on < ? AND issues.status_id IN (?))'),
         bound, bound, closed_ids]
      )
    end
    private_class_method :open_at_expression

    def self.count_case(condition)
      "COUNT(DISTINCT CASE WHEN #{condition} THEN issues.id END)"
    end
    private_class_method :count_case

    # One row of scalar aggregates. pluck, not select().take: no Issue object is
    # instantiated, which is the rule everywhere else in this class.
    #
    # The relation must carry no ORDER BY: PostgreSQL rejects an ordered select whose
    # ORDER BY columns are not in the aggregate. Every caller passes a base that has
    # been through unscope(:order) — keep it that way.
    def self.aggregate_row(base, expressions)
      return [] if expressions.empty?

      row = base.pluck(*expressions.map { |sql| Arel.sql(sql) })
      # pluck answers [v] for one expression and [[v1, v2, ...]] for several.
      expressions.length == 1 ? Array(row) : Array(row.first)
    end
    private_class_method :aggregate_row

    # Exclusive end of the period a label names: midnight starting the day after its
    # last one, on the same clock as the rest of the class. Reuses the label parser
    # the drill-through filters use, so the counts cannot drift from the axis.
    def self.period_end_bound(label, period)
      _from, to = period_bucket_range(label, period)
      return nil if to.nil?

      beginning_of_day(to + 1)
    end
    private_class_method :period_end_bound

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
                                 date_field: 'created', age_buckets: nil, age_field: 'created',
                                 measure: 'count', of: nil)
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

      measure_spec = resolve_measure(measure, of)
      return nil if measure_spec.nil?

      base = apply_dimension(scope.unscope(:order), group_dim)
      base = apply_dimension(base, split_dim) if split_dim
      base = apply_measure(base, measure_spec)

      if split_dim
        crosstab_result(base, group_dim, split_dim, sort: sort, limit: limit,
                                                    other_label: other_label,
                                                    group_by: group_by, split_by: split_by,
                                                    measure: measure_spec)
      else
        single_result(base, group_dim, sort: sort, limit: limit, other_label: other_label,
                                       group_by: group_by, measure: measure_spec)
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
      overdue   = open_scope.where('issues.due_date < ?', current_date).count(DISTINCT_ISSUES)
      no_est    = base.where(estimated_hours: nil).count(DISTINCT_ISSUES)
      oldest    = open_scope.minimum(:created_on)
      newest    = open_scope.maximum(:created_on)
      open_now  = total - closed

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
        'newest_open_days'  => days_since(newest),
        'median_open_days'  => percentile_age(open_scope, open_now, 1, 2),
        'p90_open_days'     => percentile_age(open_scope, open_now, 9, 10)
      }

      # Exposed twice on purpose: {{ f.total }} and {{ f.flags.total }} both work.
      values.merge(
        'flags'     => values,
        'buckets'   => [],
        'stages'    => flag_stages(values),
        'group_by'  => 'flags',
        'dimension' => 'flags'
      )
    end

    # Age percentile of the open issues.
    #
    # Deliberately NOT percentile_cont: that is PostgreSQL only. Ordering by
    # created_on and reading one row at an offset is portable, uses the index the
    # column already has, and costs one query per percentile.
    #
    # NEWEST first, so the rows come back in ascending AGE and the offset is the
    # ordinary percentile index. Oldest-first would put p90 at the young end, which
    # is the opposite of what a "90% of open issues are younger than this" number
    # means.
    #
    # This is the LOWER percentile, not the interpolated one: with an even number of
    # open issues the median is the younger of the two middle ages rather than their
    # average. For issue ages that is a distinction without a difference, and it buys
    # MySQL support.
    #
    # The offset counts ROWS. A scope carrying a fanning join (a multi-valued custom
    # field in the report query's own sort or group) can therefore shift the
    # percentile by a place or two — noted in the README.
    def self.percentile_age(open_scope, open_count, numerator, denominator)
      return nil unless open_count.to_i.positive?

      offset = ((open_count - 1) * numerator) / denominator
      at     = open_scope.reorder(created_on: :desc).offset(offset).limit(1).pick(:created_on)
      days_since(at)
    rescue StandardError => e
      Rails.logger.warn("[sql_aggregation] percentile age could not be read: #{e.class}: #{e.message}")
      nil
    end
    private_class_method :percentile_age

    # Funnel stages with the issue-list filter that isolates each of them, so a
    # funnel widget does not have to hardcode the counter-to-filter mapping.
    # `total` carries no filter: the report query unchanged IS that stage, which
    # is a valid drill-down rather than a missing one.
    def self.flag_stages(values)
      FLAG_STAGES.map do |stage|
        filter =
          if stage[:field]
            { 'field' => stage[:field], 'operator' => stage[:operator], 'values' => [''] }
          end
        { 'key' => stage[:key], 'label' => stage[:label],
          'count' => values[stage[:key]], 'filter' => filter }
      end
    end
    private_class_method :flag_stages

    # ------------------------------------------------------------------
    # Completeness
    # ------------------------------------------------------------------

    # One bucket per named field: how many issues have it filled in, how many do
    # not, and the percentage. This is the widget that makes every other one
    # trustworthy — a Department chart means nothing if Department is 22% filled.
    #
    # `count` is the FILLED count, so an existing bar chart works unchanged.
    #
    # One statement: one conditional aggregate per field, and ONE custom_values join
    # for all the custom fields rather than one per field. Bucket order follows
    # `fields:`; sort and limit do not apply, like period and age.
    #
    # Returns nil — after logging — when the list is unusable, so the caller assigns
    # its empty-safe result.
    def self.completeness(scope, fields:)
      entries = resolve_completeness_fields(fields)
      return nil if entries.nil?

      base   = apply_completeness_joins(scope.unscope(:order), entries)
      total  = base.count(DISTINCT_ISSUES)
      filled = aggregate_row(base, entries.map { |entry| count_case(entry.condition) })

      buckets = entries.each_with_index.map do |entry, index|
        completeness_bucket(entry, filled[index].to_i, total)
      end

      {
        'buckets'     => buckets,
        'total'       => total,
        'group_by'    => 'completeness',
        'dimension'   => 'completeness',
        'fields'      => entries.map(&:key),
        'field_name'  => nil,
        'measure'     => 'count',
        'multi_value' => false,
        'truncated'   => false
      }
    rescue UnsupportedAdapterError
      raise
    rescue StandardError => e
      Rails.logger.warn("[sql_aggregation] completeness failed: #{e.class}: #{e.message}")
      nil
    end

    def self.completeness_bucket(entry, filled, total)
      {
        'label'        => entry.label,
        'count'        => filled,
        'empty'        => total - filled,
        'total'        => total,
        'pct'          => total.positive? ? ((filled * 100.0) / total).round : 0,
        'value'        => entry.key,
        'filter'       => { 'field' => entry.filter_field, 'operator' => '*',  'values' => [''] },
        'empty_filter' => { 'field' => entry.filter_field, 'operator' => '!*', 'values' => [''] }
      }
    end
    private_class_method :completeness_bucket

    def self.resolve_completeness_fields(fields)
      names = Array(fields).map { |name| name.to_s.strip }.reject(&:empty?).uniq
      if names.empty?
        Rails.logger.warn('[sql_aggregation] group_by: completeness needs a fields: list, e.g. ' \
                          'fields: "cf_94;assigned_to_id;due_date"')
        return nil
      end

      if names.length > MAX_COMPLETENESS_FIELDS
        Rails.logger.warn("[sql_aggregation] completeness accepts at most #{MAX_COMPLETENESS_FIELDS} " \
                          "fields, #{names.length} given — refusing rather than building an " \
                          'unreadable chart')
        return nil
      end

      entries = names.filter_map { |name| completeness_field(name) }
      return entries if entries.any?

      Rails.logger.warn("[sql_aggregation] none of the completeness fields #{names.inspect} " \
                        'could be resolved')
      nil
    end
    private_class_method :resolve_completeness_fields

    def self.completeness_field(name)
      if (match = CF_DIMENSION_RE.match(name))
        return completeness_custom_field(name, match[1].to_i)
      end

      key = COMPLETENESS_ALIASES.fetch(name.downcase, name.downcase)
      cfg = COMPLETENESS_CORE_FIELDS[key]
      if cfg.nil?
        Rails.logger.warn("[sql_aggregation] #{name.inspect} is not a completeness field — expected " \
                          "cf_<id> or one of #{COMPLETENESS_CORE_FIELDS.keys.join(', ')}")
        return nil
      end

      column    = "issues.#{key}"
      condition = "#{column} IS NOT NULL"
      condition += " AND #{column} <> ''" if cfg[:text]
      CompletenessField.new(key: key, label: cfg[:label], filter_field: key, condition: condition)
    end
    private_class_method :completeness_field

    # Same resolution and the same visibility condition as the cf_<id> dimension: a
    # field the viewer may not see must not be reported as empty for them, and a
    # non-issue custom field is refused the same way.
    def self.completeness_custom_field(name, field_id)
      custom_field = find_issue_custom_field(field_id)
      if custom_field.nil?
        Rails.logger.warn("[sql_aggregation] custom field ##{field_id} does not exist " \
                          'or is not an issue custom field')
        return nil
      end

      alias_name = 'rrd_cv_c'
      condition  = "#{alias_name}.custom_field_id = #{field_id}" \
                   " AND (#{visibility_condition(custom_field)})" \
                   " AND #{alias_name}.value IS NOT NULL AND #{alias_name}.value <> ''"

      CompletenessField.new(key: "cf_#{field_id}", label: custom_field.name.to_s,
                            filter_field: "cf_#{field_id}", condition: condition,
                            custom_field_id: field_id)
    end
    private_class_method :completeness_custom_field

    # ONE join for every custom field in the list. Each field's own visibility
    # condition lives in its CASE instead, because they differ per field.
    def self.apply_completeness_joins(base, entries)
      ids = entries.map(&:custom_field_id).compact.uniq
      return base if ids.empty?

      alias_name = 'rrd_cv_c'
      base.joins(:project).joins(
        "LEFT OUTER JOIN #{CustomValue.table_name} #{alias_name}" \
        " ON #{alias_name}.customized_type = 'Issue'" \
        " AND #{alias_name}.customized_id = issues.id" \
        " AND #{alias_name}.custom_field_id IN (#{ids.join(',')})"
      )
    end
    private_class_method :apply_completeness_joins

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
      elsif %w[flags completeness].include?(pseudo)
        Rails.logger.warn("[sql_aggregation] #{pseudo} is only valid as group_by, not as a dimension")
        nil
      else
        Rails.logger.warn("[sql_aggregation] unknown dimension #{key.inspect} — " \
                          'expected a core field, cf_<id>, period or age')
        nil
      end
    end

    # ------------------------------------------------------------------
    # Measure resolution
    # ------------------------------------------------------------------

    # Returns a Measure, or nil after logging — an unusable measure is refused like
    # an unusable dimension, so the caller assigns its empty-safe result rather than
    # charting a number nobody can explain.
    def self.resolve_measure(measure, of, suffix: 'm')
      kind = measure.to_s.strip.downcase
      kind = 'count' if kind.empty?

      unless MEASURE_KINDS.include?(kind)
        Rails.logger.warn("[sql_aggregation] unknown measure #{measure.inspect} — " \
                          "expected one of #{MEASURE_KINDS.join(', ')}")
        return nil
      end

      field = of.to_s.strip
      if kind == 'count'
        unless field.empty?
          Rails.logger.warn("[sql_aggregation] of: #{field.inspect} is ignored by measure: count — " \
                            'use measure: distinct to count distinct values')
        end
        return Measure.new(kind: :count)
      end

      if field.empty?
        Rails.logger.warn("[sql_aggregation] measure: #{kind} needs an of: field")
        return nil
      end

      numeric = %w[sum avg].include?(kind)
      if (match = CF_DIMENSION_RE.match(field))
        custom_field_measure(kind.to_sym, field, match[1].to_i, numeric: numeric, suffix: suffix)
      elsif (column = MEASURE_NUMERIC_COLUMNS[field])
        Measure.new(kind: kind.to_sym, field: field, expression: column)
      elsif field == 'spent_hours'
        spent_hours_measure(kind.to_sym, field)
      elsif (column = MEASURE_REFERENCES[field])
        return Measure.new(kind: kind.to_sym, field: field, expression: column) unless numeric

        Rails.logger.warn("[sql_aggregation] of: #{field} is a reference, not a number — " \
                          "measure: #{kind} needs a numeric field")
        nil
      else
        Rails.logger.warn("[sql_aggregation] unknown of: #{field.inspect} — expected a core field, " \
                          'cf_<id>, estimated_hours or spent_hours')
        nil
      end
    end

    # SUM over the issue's time entries. A LEFT OUTER join on purpose: with an inner
    # one a bucket whose issues logged no time would vanish from the axis instead of
    # reporting zero.
    #
    # avg is refused: AVG(time_entries.hours) is the average SIZE OF A TIME ENTRY,
    # not the average spent per issue, and quietly charting the first as the second
    # is worse than saying no.
    def self.spent_hours_measure(kind, field)
      if kind == :avg
        Rails.logger.warn('[sql_aggregation] measure: avg is not supported for spent_hours — it would ' \
                          'average time entries, not issues; use measure: sum, or avg on ' \
                          'estimated_hours')
        return nil
      end

      Measure.new(kind: kind, field: field, expression: 'time_entries.hours',
                  join: time_entries_join, project_join: true)
    end
    private_class_method :spent_hours_measure

    # Redmine NEVER sums spent time without TimeEntry.visible_condition: the issue
    # list column subselect, IssueQuery#total_for_spent_hours and
    # Issue.load_visible_spent_hours all apply it, because :view_time_entries is
    # granted per project and a role can be limited to its own entries. Summing a raw
    # join would report hours the viewer may not see.
    #
    # The condition sits in the ON clause rather than a WHERE, so this stays a LEFT
    # OUTER join and a bucket whose issues have no visible entries reports zero
    # instead of dropping off the axis.
    #
    # NOT aliased, unlike the custom-value joins: TimeEntry.visible_condition spells
    # out `time_entries.user_id` for a role limited to its own entries, so the real
    # table name has to be in scope. Redmine's own joins(:time_entries) does the same.
    def self.time_entries_join
      'LEFT OUTER JOIN time_entries ON time_entries.issue_id = issues.id' \
        " AND (#{time_entry_visibility_condition})"
    end
    private_class_method :time_entries_join

    # Fails CLOSED, like visibility_condition: an authorization clause we cannot
    # build must not silently disappear.
    def self.time_entry_visibility_condition
      return '1=0' unless defined?(TimeEntry) && TimeEntry.respond_to?(:visible_condition)

      condition = TimeEntry.visible_condition(User.current).to_s.strip
      condition.empty? ? '1=0' : condition
    rescue StandardError => e
      Rails.logger.warn('[sql_aggregation] could not build the time entry visibility condition: ' \
                        "#{e.class}: #{e.message} — reporting no spent time")
      '1=0'
    end
    private_class_method :time_entry_visibility_condition

    def self.custom_field_measure(kind, name, field_id, numeric:, suffix:)
      custom_field = find_issue_custom_field(field_id)
      if custom_field.nil?
        Rails.logger.warn("[sql_aggregation] custom field ##{field_id} does not exist " \
                          'or is not an issue custom field')
        return nil
      end

      if numeric && !numeric_custom_field?(custom_field)
        Rails.logger.warn("[sql_aggregation] #{name} is not a numeric custom field — " \
                          "measure: #{kind} needs one of #{NUMERIC_CF_FORMATS.join(', ')}")
        return nil
      end

      raw = "rrd_cv_#{suffix}.value"
      Measure.new(
        kind: kind,
        field: name,
        expression: numeric ? numeric_cast("NULLIF(#{raw}, '')") : "NULLIF(#{raw}, '')",
        join: custom_value_join(custom_field, field_id, suffix),
        project_join: true
      )
    end
    private_class_method :custom_field_measure

    def self.numeric_custom_field?(custom_field)
      custom_field.respond_to?(:field_format) &&
        NUMERIC_CF_FORMATS.include?(custom_field.field_format.to_s)
    rescue StandardError
      false
    end
    private_class_method :numeric_custom_field?

    # The cast comes AFTER the NULLIF so an empty string never reaches it. A value
    # that is not a number in a numeric-format field still yields NULL rather than
    # aborting the statement on PostgreSQL — documented in the README.
    def self.numeric_cast(expression)
      if postgresql?
        "CAST(#{expression} AS numeric)"
      else
        "CAST(#{expression} AS DECIMAL(20,4))"
      end
    end
    private_class_method :numeric_cast

    # ------------------------------------------------------------------
    # Applying a measure
    # ------------------------------------------------------------------

    def self.apply_measure(base, measure)
      return base if measure.nil? || measure.join.nil?

      base = base.joins(:project) if measure.project_join
      base.joins(measure.join)
    end
    private_class_method :apply_measure

    def self.additive_measure?(measure)
      measure.nil? || ADDITIVE_MEASURES.include?(measure.kind)
    end
    private_class_method :additive_measure?

    # One scalar. Used for `total` and for a collapsed bucket of a non-additive
    # measure, which cannot be added up from its parts.
    def self.measure_scalar(relation, measure)
      measure_number(raw_measure(relation, measure), measure)
    end
    private_class_method :measure_scalar

    # {group value => measure}, the grouped counterpart.
    def self.measure_groups(relation, measure)
      return grouped_counts(relation) if measure.nil? || measure.kind == :count

      raw = raw_measure(relation, measure)
      return {} unless raw.is_a?(Hash)

      raw.each_with_object({}) { |(key, value), out| out[key] = measure_number(value, measure) }
    end
    private_class_method :measure_groups

    # The counted axis, read back BY POSITION — defect D-1's fix.
    #
    # ActiveRecord's grouped `.count` derives a result-column ALIAS from the group
    # expression's own text (execute_grouped_calculation -> ColumnAliasTracker#
    # column_alias_for -> table_alias_for, which slices at table_alias_length) and then
    # looks each key up by that alias. MariaDB truncates a returned column label at 256
    # characters — measured with the age CASE, 261 works and 262 does not — so the two
    # ends asked and answered with different names, EVERY key came back nil, the whole
    # axis collapsed into the empty bucket, and the total was taken from whichever group
    # the server returned last. Four age boundaries cross it and DEFAULT_AGE_BUCKETS is
    # four, so that was the default on MariaDB, in production.
    #
    # Shortening the expression is not the fix and was measured not to be: on PostgreSQL
    # the alias is ALREADY truncated (limit 63) and the answer is correct, because AR
    # asks for the same truncated name it sent. The defect is the two ends DISAGREEING,
    # so a shorter CASE only moves the cliff. `SELECT <expr>, COUNT(...) GROUP BY <expr>`
    # read positionally carries no alias for anything to disagree about.
    #
    # It is the same statement and the same GROUP BY — this changes how the result is
    # READ, not how much work the server does. Query count is unchanged. Reading it any
    # other way (one conditional aggregate per bucket) was tried and is dramatically
    # slower on MariaDB, which is the engine the defect is on.
    #
    # `group_values` is what was passed to `.group`, so the key shape matches `.count`'s
    # exactly: one group expression gives a bare key, several give an Array key.
    def self.grouped_counts(relation)
      expressions = relation.group_values
      return {} if expressions.empty?

      rows = relation.pluck(*expressions, Arel.sql("COUNT(#{DISTINCT_ISSUES})"))
      rows.each_with_object({}) do |row, out|
        *key, count = row
        out[expressions.length == 1 ? key.first : key] = count.to_i
      end
    end
    private_class_method :grouped_counts

    def self.raw_measure(relation, measure)
      case measure&.kind
      when nil, :count then relation.count(DISTINCT_ISSUES)
      when :distinct   then relation.count("DISTINCT #{measure.expression}")
      when :sum        then relation.sum(Arel.sql(measure.expression))
      when :avg        then relation.average(Arel.sql(measure.expression))
      end
    end
    private_class_method :raw_measure

    # Integers for the counting measures, Floats for the numeric ones — rounded in
    # Ruby, not in SQL, so PostgreSQL and MySQL cannot disagree about the last digit.
    def self.measure_number(value, measure)
      case measure&.kind
      when :sum then value.to_f
      when :avg then value.nil? ? 0.0 : value.to_f.round(2)
      else value.to_i
      end
    end
    private_class_method :measure_number

    # SQL for "the dimension value is one of these raw keys", so a collapsed bucket
    # can be aggregated on its own. NULL is spelled out separately: it is never IN.
    def self.dimension_keys_condition(dim, raws)
      expression = dim.sql.is_a?(Symbol) ? "issues.#{dim.sql}" : dim.sql.to_s
      present    = raws.reject(&:nil?)
      parts      = []
      parts << "#{expression} IS NULL" if raws.any?(&:nil?)
      if present.any?
        parts << ActiveRecord::Base.sanitize_sql_array(["#{expression} IN (?)", present])
      end
      return nil if parts.empty?

      "(#{parts.join(' OR ')})"
    end
    private_class_method :dimension_keys_condition

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
      overdue_by    = open_scope.where('issues.due_date < ?', current_date).group(:fixed_version_id).count
      unassigned_by = open_scope.where(assigned_to_id: nil).group(:fixed_version_id).count
      noest_by      = base.where(estimated_hours: nil).group(:fixed_version_id).count
      est_by        = base.group(:fixed_version_id).sum(:estimated_hours)
      start_by      = base.group(:fixed_version_id).minimum(:start_date)
      due_by        = base.group(:fixed_version_id).maximum(:due_date)
      # joins(:project) so the time entry visibility clause has the projects table to
      # read; AR de-duplicates it when the scope already carries one.
      spent_by      = base.joins(:project).joins(:time_entries)
                          .where(time_entry_visibility_condition)
                          .group(:fixed_version_id).sum('time_entries.hours')

      # Cost custom fields: mirror Redmine's Numeric#total_for_scope
      # (lib/redmine/field_format.rb) — join custom_values, skip empty strings so
      # the numeric CAST is safe on both PostgreSQL and MySQL — plus a GROUP BY.
      #
      # The field is resolved rather than trusted as a bare id, so a restricted field
      # is refused (find_issue_custom_field checks CustomField.visible) and the join
      # carries the same per-project visibility clause the dimension join does. An
      # aliased INNER join, not the :custom_values association: the alias keeps several
      # cost fields in one rollup apart, and INNER keeps the historical shape where a
      # version with no value is simply absent from the hash.
      cost_by = {} # "field_id" => { version_id => BigDecimal }
      Array(cost_field_ids).map { |id| id.to_i }.reject(&:zero?).uniq.each_with_index do |fid, index|
        custom_field = find_issue_custom_field(fid)
        if custom_field.nil?
          Rails.logger.warn("[sql_aggregation] cost field ##{fid} is not a usable issue custom " \
                            'field for this user — skipping it')
          next
        end

        alias_name = "rrd_cv_cost#{index}"
        cost_by[fid.to_s] = base.joins(:project)
          .joins(cost_value_join(custom_field, fid, alias_name))
          .group(:fixed_version_id)
          .sum("CAST(#{alias_name}.value AS decimal(30,3))")
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
      today = current_date # memoised once; avoids a midnight-crossing skew across iterations
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

    # ONE clock for every date this class computes.
    #
    # Time.zone, not Date.today: `n.months.ago` and friends are Time.zone-based,
    # and Rails stores and compares timestamps in UTC — which is what the DB's own
    # TO_CHAR / DATE_FORMAT bucketing sees. Date.today follows the server's system
    # timezone instead, so on a host that is not UTC it disagreed with both, and
    # the WHERE window could start a day (or a month) away from the oldest label:
    # the oldest bucket then reported zero, or an unlabelled period leaked in.
    #
    # Note that Redmine never sets Time.zone per request (it stays at the Rails
    # default) and applies its own date FILTERS in User.current.time_zone, so a
    # drill-down range and a chart bucket can still disagree by a day for a viewer
    # in another timezone. That is documented, and is a different clock from this one.
    def self.current_date
      Time.zone ? Time.zone.today : Date.today
    end
    private_class_method :current_date

    # Start of the OLDEST bucket build_labels produces, so the WHERE window and
    # the label axis cover exactly the same span. n-1, not n: build_labels counts
    # the current period as the first of the n. A wider window used to be
    # harmless for .aggregate — it maps counts onto the labels and drops the rest
    # — but the period dimension reports what it is given, and a stray bucket
    # outside the axis is not something a template can chart.
    #
    # Derived from current_date, the same value build_labels starts from, so the
    # two cannot drift apart whatever the host's timezone is.
    def self.period_from(n, period)
      back  = [n.to_i - 1, 0].max
      today = current_date
      start = case period.to_s
              when 'day'   then today - back
              when 'week'  then (today - (back * 7)).beginning_of_week
              when 'month' then (today << back).beginning_of_month
              when 'year'  then (today << (back * 12)).beginning_of_year
              else              (today << back).beginning_of_month
              end
      beginning_of_day(start)
    end
    private_class_method :period_from

    # Date -> Time at 00:00 on the same clock as current_date.
    def self.beginning_of_day(date)
      return date.to_time unless Time.zone

      Time.zone.local(date.year, date.month, date.day)
    end
    private_class_method :beginning_of_day

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

    def self.single_result(base, dim, sort:, limit:, other_label:, group_by:, measure: nil)
      totals = measure_groups(base.group(dim.sql), measure)
      axis   = build_axis(dim, totals, sort: sort, limit: limit, other_label: other_label)
      values = fold_values(base, dim, axis, totals, measure)

      buckets = axis.keys.map do |key|
        describe_bucket({ 'label' => axis.labels[key], 'count' => values[key] }, dim, axis, key)
      end

      {
        'buckets'       => buckets,
        'total'         => result_total(base, buckets, measure),
        'group_by'      => group_by.to_s,
        'dimension'     => dim.name,
        'field_name'    => dim.field_name,
        'measure'       => measure_name(measure),
        'measure_field' => measure&.field,
        'multi_value'   => dim.multi_value ? true : false,
        'truncated'     => axis.truncated
      }
    end
    private_class_method :single_result

    # Raw group values folded onto display keys. An additive measure adds its parts;
    # a distinct count or an average cannot be added, so a bucket that collapses
    # several raw values (Other, or a no-value bucket holding both NULL and a
    # whitespace string) gets its own aggregate — one extra query per such bucket,
    # of which there are at most two.
    def self.fold_values(base, dim, axis, totals, measure)
      groups = {}
      axis.key_map.each { |raw, display| (groups[display] ||= []) << raw }

      # zero, not nil: a fixed-keys axis (period, age) lists every bucket in the
      # window, including the ones the GROUP BY never returned.
      zero   = measure_number(nil, measure)
      values = Hash.new(zero)
      groups.each do |display, raws|
        values[display] =
          if raws.length == 1
            totals.fetch(raws.first, zero)
          elsif additive_measure?(measure)
            raws.sum { |raw| totals.fetch(raw, zero) }
          else
            collapsed_measure(base, dim, raws, measure) || totals.fetch(raws.first, zero)
          end
      end
      values
    end
    private_class_method :fold_values

    def self.collapsed_measure(base, dim, raws, measure)
      condition = dimension_keys_condition(dim, raws)
      return nil if condition.nil?

      measure_scalar(base.where(condition), measure)
    rescue StandardError => e
      Rails.logger.warn("[sql_aggregation] could not aggregate the collapsed bucket for " \
                        "#{dim.name}: #{e.class}: #{e.message}")
      nil
    end
    private_class_method :collapsed_measure

    # A plain count keeps the historical meaning — the sum of the buckets, which for
    # a multi-valued custom field deliberately exceeds the issue count. Every other
    # measure gets its own aggregate over the whole scope, because a distinct count
    # does not add up and an average certainly does not.
    def self.result_total(base, buckets, measure)
      return buckets.sum { |bucket| bucket['count'] } if measure.nil? || measure.kind == :count

      measure_scalar(base, measure)
    end
    private_class_method :result_total

    def self.measure_name(measure)
      (measure&.kind || :count).to_s
    end
    private_class_method :measure_name

    # One GROUP BY over both dimensions, pivoted in Ruby into a dense matrix.
    # `limit` applies to the rows only — the series axis is bounded by the hard
    # cap alone, so a row limit never silently drops a chart series.
    def self.crosstab_result(base, group_dim, split_dim, sort:, limit:, other_label:,
                             group_by:, split_by:, measure: nil)
      pairs = measure_groups(base.group(group_dim.sql, split_dim.sql), measure)

      # Per-axis totals: summing the cells is only valid for an additive measure, so
      # the others get their own grouped aggregate — two queries, not one per cell.
      if additive_measure?(measure)
        row_totals    = Hash.new(0)
        series_totals = Hash.new(0)
        pairs.each do |(row_raw, series_raw), value|
          row_totals[row_raw]       += value
          series_totals[series_raw] += value
        end
      else
        row_totals    = measure_groups(base.group(group_dim.sql), measure)
        series_totals = measure_groups(base.group(split_dim.sql), measure)
      end

      row_axis    = build_axis(group_dim, row_totals, sort: sort, limit: limit,
                                                      other_label: other_label)
      series_axis = build_axis(split_dim, series_totals, sort: sort, limit: 0,
                                                         other_label: other_label)

      zero = measure_number(nil, measure)
      grid = {}
      pairs.each do |(row_raw, series_raw), value|
        row_key    = row_axis.key_map.fetch(row_raw, row_raw)
        series_key = series_axis.key_map.fetch(series_raw, series_raw)
        (grid[row_key] ||= Hash.new(zero))[series_key] += value
      end
      # A collapsed row's cells cannot be added up for a non-additive measure, so
      # that row is re-aggregated across the series axis. One query per collapsed
      # row, of which there are at most two.
      recount_collapsed_rows(base, group_dim, split_dim, row_axis, series_axis, grid, measure)

      series = series_axis.keys.map { |key| series_axis.labels[key] }

      # `series` stays an Array of label Strings — every existing template feeds
      # it straight to Chart.js. The per-series raw value and filter live in a
      # parallel `series_entries` Array instead of replacing it.
      series_entries = series_axis.keys.map do |key|
        describe_bucket({ 'label' => series_axis.labels[key] }, split_dim, series_axis, key)
      end

      rows = row_axis.keys.map do |row_key|
        row_grid = grid[row_key] || {}
        counts   = series_axis.keys.map { |key| row_grid.fetch(key, zero) }
        cells    = {}
        series.each_with_index { |label, i| cells[label] = counts[i] }
        total = additive_measure?(measure) ? counts.sum
                                          : row_totals_for(row_axis, row_totals, row_key, measure)
        row = { 'label'  => row_axis.labels[row_key], 'total' => total,
                'counts' => counts,                   'cells' => cells }
        describe_bucket(row, group_dim, row_axis, row_key)
      end

      {
        'series'            => series,
        'series_entries'    => series_entries,
        'rows'              => rows,
        'matrix'            => rows.map { |r| r['counts'] },
        'columns'           => crosstab_columns(rows, series_axis, series_totals, measure),
        'buckets'           => rows.map do |r|
          bucket = { 'label' => r['label'], 'count' => r['total'], 'value' => r['value'] }
          bucket['values'] = r['values'] if r.key?('values')
          bucket['filter'] = r['filter']
          bucket
        end,
        'total'             => crosstab_total(base, rows, measure),
        'group_by'          => group_by.to_s,
        'split_by'          => split_by.to_s,
        'dimension'         => group_dim.name,
        'field_name'        => group_dim.field_name,
        'series_field_name' => split_dim.field_name,
        'measure'           => measure_name(measure),
        'measure_field'     => measure&.field,
        'multi_value'       => (group_dim.multi_value || split_dim.multi_value) ? true : false,
        'truncated'         => (row_axis.truncated || series_axis.truncated)
      }
    end
    private_class_method :crosstab_result

    # Folds the raw per-axis totals onto one display key.
    def self.row_totals_for(axis, totals, display_key, measure)
      zero = measure_number(nil, measure)
      raws = axis.key_map.each_with_object([]) { |(raw, display), out| out << raw if display == display_key }
      return zero if raws.empty?
      return totals.fetch(raws.first, zero) if raws.length == 1
      return raws.sum { |raw| totals.fetch(raw, zero) } if additive_measure?(measure)

      # Several raw values behind one display key and a measure that does not add up:
      # the axis total was aggregated per raw value, so the largest of them is the
      # closest honest answer — never their sum, which would overstate it.
      raws.map { |raw| totals.fetch(raw, zero) }.max
    end
    private_class_method :row_totals_for

    def self.crosstab_total(base, rows, measure)
      return rows.sum { |row| row['total'] } if additive_measure?(measure)

      measure_scalar(base, measure)
    end
    private_class_method :crosstab_total

    def self.crosstab_columns(rows, series_axis, series_totals, measure)
      return series_axis.keys.each_index.map { |i| rows.sum { |r| r['counts'][i] } } if additive_measure?(measure)

      series_axis.keys.map { |key| row_totals_for(series_axis, series_totals, key, measure) }
    end
    private_class_method :crosstab_columns

    def self.recount_collapsed_rows(base, group_dim, split_dim, row_axis, series_axis, grid, measure)
      return if additive_measure?(measure)

      collapsed = {}
      row_axis.key_map.each { |raw, display| (collapsed[display] ||= []) << raw }
      collapsed.each do |display, raws|
        next if raws.length < 2

        condition = dimension_keys_condition(group_dim, raws)
        next if condition.nil?

        cells = measure_groups(base.where(condition).group(split_dim.sql), measure)
        row   = Hash.new(measure_number(nil, measure))
        cells.each { |series_raw, value| row[series_axis.key_map.fetch(series_raw, series_raw)] = value }
        grid[display] = row
      end
    rescue StandardError => e
      Rails.logger.warn("[sql_aggregation] could not re-aggregate a collapsed crosstab row: " \
                        "#{e.class}: #{e.message}")
    end
    private_class_method :recount_collapsed_rows

    # ------------------------------------------------------------------
    # Drill-through descriptors
    # ------------------------------------------------------------------

    # Adds the raw value and the issue-list filter to one bucket / row / series
    # entry, leaving `label` (and `count`) exactly as they were. Every added key
    # is present even when it is nil, except `values`, which only a collapsed
    # Other row carries.
    def self.describe_bucket(entry, dim, axis, key)
      entry['value']  = raw_value(key)
      entry['values'] = collapsed_values(axis, key) if key == OTHER_KEY
      entry['filter'] = bucket_filter(dim, axis, key)
      entry
    end
    private_class_method :describe_bucket

    # Neither synthetic bucket has a single stored value: Other spans several
    # (see `values`) and the empty bucket is precisely the absence of one.
    def self.raw_value(key)
      return nil if key == OTHER_KEY || key == EMPTY_KEY

      key.to_s
    end
    private_class_method :raw_value

    # Insertion order of key_map is ordered-then-dropped-then-blank, and the
    # dropped keys were sorted, so this list is deterministic.
    def self.collapsed_values(axis, key)
      collapsed_keys(axis, key).map(&:to_s)
    end
    private_class_method :collapsed_values

    def self.collapsed_keys(axis, key)
      axis.key_map.each_with_object([]) { |(raw, display), keys| keys << raw if display == key }
    end
    private_class_method :collapsed_keys

    def self.bucket_filter(dim, axis, key)
      return nil if dim.nil? || dim.filter_field.nil?

      # "none" is Redmine's !* operator, and it expects exactly one blank value.
      return none_filter(dim.filter_field) if key == EMPTY_KEY
      return nil if dim.filter_for.nil?

      raws = key == OTHER_KEY ? collapsed_keys(axis, key) : [key]
      filter = dim.filter_for.call(raws)
      filter.is_a?(Hash) ? filter : nil
    rescue StandardError => e
      Rails.logger.warn("[sql_aggregation] could not build the drill-through filter for " \
                        "#{dim.name} #{key.inspect}: #{e.class}: #{e.message}")
      nil
    end
    private_class_method :bucket_filter

    def self.none_filter(field)
      { 'field' => field, 'operator' => '!*', 'values' => [''] }
    end
    private_class_method :none_filter

    # Equality over one or more raw values — one bucket, or every value an Other
    # row collapsed (the drill-down is then their union, as the issue list ORs
    # the values of a single filter).
    def self.equality_filter(field, raws)
      values = Array(raws).map { |raw| raw.to_s.strip }.reject(&:empty?).uniq
      return nil if values.empty?

      { 'field' => field, 'operator' => '=', 'values' => values }
    end
    private_class_method :equality_filter

    # Absolute date range. Either end may be nil, which Redmine expresses with
    # >= / <= instead of the two-sided ><.
    def self.date_range_filter(field, from, to)
      return nil if from.nil? && to.nil?

      if from && to
        { 'field' => field, 'operator' => '><', 'values' => [iso_date(from), iso_date(to)] }
      elsif from
        { 'field' => field, 'operator' => '>=', 'values' => [iso_date(from)] }
      else
        { 'field' => field, 'operator' => '<=', 'values' => [iso_date(to)] }
      end
    end
    private_class_method :date_range_filter

    # The format Redmine's own date filters use, and the only one Query's filter
    # validation accepts (%Y-%m-%d, optionally with a time it never needs here).
    def self.iso_date(date)
      date.strftime('%Y-%m-%d')
    end
    private_class_method :iso_date

    # A date bucket spans one contiguous range, so a set of collapsed keys can
    # only be expressed when it is a single bucket. period and age use
    # fixed_keys, which never collapse into Other, so this is a guard rather than
    # a limitation.
    def self.period_bucket_filter(field, type, raws)
      return nil unless raws.length == 1

      from, to = period_bucket_range(raws.first, type)
      return nil if from.nil?

      date_range_filter(field, from, to)
    end
    private_class_method :period_bucket_filter

    # Inverse of build_labels: "2026-05-30" | "2026-W22" | "2026-05" | "2026".
    # Returns [first day, last day] of the bucket, or nil for a key that is not a
    # label of this period type.
    def self.period_bucket_range(key, type)
      text = key.to_s
      case type.to_s
      when 'day'
        return nil unless (match = /\A(\d{4})-(\d{2})-(\d{2})\z/.match(text))

        day = Date.new(match[1].to_i, match[2].to_i, match[3].to_i)
        [day, day]
      when 'week'
        return nil unless (match = /\A(\d{4})-W(\d{2})\z/.match(text))

        # cwyear/cweek, matching MySQL %x-%v and PostgreSQL IYYY-IW.
        monday = Date.commercial(match[1].to_i, match[2].to_i, 1)
        [monday, monday + 6]
      when 'year'
        return nil unless (match = /\A(\d{4})\z/.match(text))

        [Date.new(match[1].to_i, 1, 1), Date.new(match[1].to_i, 12, 31)]
      else
        return nil unless (match = /\A(\d{4})-(\d{2})\z/.match(text))

        first = Date.new(match[1].to_i, match[2].to_i, 1)
        [first, first.next_month - 1]
      end
    rescue StandardError
      nil
    end
    private_class_method :period_bucket_range

    # The age CASE is a chain of `column >= today - boundary` tests evaluated
    # newest-first, so bucket i covers exactly the ages its label names:
    #
    #   "0-30"  -> column >= today-30                  (>=, open upper end)
    #   "31-60" -> today-60 <= column <= today-31       (><)
    #   ">180"  -> column <= today-181                  (<=, open lower end)
    #
    # `today` is the one captured when the dimension was built, so the URL and
    # the SQL agree even across midnight. The SQL compares timestamps and the
    # filter compares dates, so an issue created on a boundary day earlier than
    # the current time of day can land in the neighbouring bucket.
    def self.age_bucket_filter(field, labels, bounds, today, raws)
      return nil unless raws.length == 1

      index = labels.index(raws.first.to_s)
      return nil if index.nil?

      from = index < bounds.length ? today - bounds[index] : nil
      to   = index.zero? ? nil : today - bounds[index - 1] - 1

      date_range_filter(field, from, to)
    end
    private_class_method :age_bucket_filter

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
        empty_label: empty_label.nil? ? cfg[:null_label] : empty_label.to_s,
        # The grouping column IS the IssueQuery filter name for all seven core
        # fields (status_id, priority_id, tracker_id, assigned_to_id, author_id,
        # category_id, fixed_version_id).
        filter_field: cfg[:field].to_s,
        filter_for: ->(raws) { equality_filter(cfg[:field].to_s, raws) }
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

      Dimension.new(
        name: name,
        # The BARE column, not NULLIF(column, ''): custom_value_join already keeps
        # the empty-string rows out of the join, so an issue whose only value is ''
        # arrives as NULL here exactly as it did before — and the GROUP BY is now a
        # plain column reference. See custom_value_join for why that matters.
        sql: Arel.sql("rrd_cv_#{suffix}.value"),
        join: custom_value_join(custom_field, field_id, suffix),
        project_join: true,
        label_map: ->(raws) { custom_field_labels(custom_field, raws) },
        order_map: ->(raws) { custom_field_positions(custom_field, raws) },
        field_name: custom_field.name.to_s,
        multi_value: custom_field.respond_to?(:multiple?) && custom_field.multiple? ? true : false,
        empty_label: empty_label.nil? ? DEFAULT_EMPTY_LABEL : empty_label.to_s,
        # Redmine names a custom field filter cf_<id> (Query#add_custom_field_filter).
        # Whether it actually IS available — is_filter, and enabled for the
        # project and tracker — is checked when the URL is built, not here.
        filter_field: "cf_#{field_id}",
        filter_for: ->(raws) { equality_filter("cf_#{field_id}", raws) }
      )
    end
    private_class_method :custom_field_dimension

    # One LEFT OUTER JOIN of custom_values for one custom field, under a private
    # alias. Shared by the cf dimension (rrd_cv_g / rrd_cv_s) and the cf measure
    # (rrd_cv_m), so all three cannot collide even in one statement.
    #
    # NOT cf_<id>: that alias is what Redmine's own IssueQuery uses when a query
    # sorts or groups on a custom field (lib/redmine/field_format.rb#join_alias),
    # and the incoming scope may already carry it.
    #
    # The visibility clause mirrors Redmine's own join: a custom field can be
    # restricted to roles, and without it a viewer who may not see the field would
    # still get its values as chart labels. Like core, a viewer who is not entitled
    # sees the values as NULL — they land in the empty bucket.
    #
    # `value <> ''` is in the ON clause rather than a NULLIF around the group
    # expression, which is where it used to be. Same result — a row with an empty
    # value does not join, so the LEFT OUTER JOIN yields NULL and the issue lands in
    # the no-value bucket — but the dimension now groups on a BARE COLUMN.
    #
    # That is not cosmetic. MariaDB's ONLY_FULL_GROUP_BY (MySQL 8 has it on by
    # default, and Rails appends to the server's sql_mode rather than replacing it)
    # matches a select-list expression against the GROUP BY list, and its matcher
    # does not recognise CASE-family items — NULLIF is one — as equal to themselves.
    # `SELECT NULLIF(v,'') ... GROUP BY NULLIF(v,'')` is therefore rejected outright
    # with "'value' isn't in GROUP BY", which took out every cf_<id> dashboard block
    # on such a server. A plain column matches, and can use an index besides.
    #
    # NOTE for multi-valued fields: an issue holding both 'Sales' and '' used to
    # appear under 'Sales' AND in the no-value bucket. It now appears only under
    # 'Sales', which is what the axis should have said all along.
    def self.custom_value_join(custom_field, field_id, suffix)
      alias_name = "rrd_cv_#{suffix}"
      "LEFT OUTER JOIN #{CustomValue.table_name} #{alias_name}" \
        " ON #{alias_name}.customized_type = 'Issue'" \
        " AND #{alias_name}.customized_id = issues.id" \
        " AND #{alias_name}.custom_field_id = #{field_id}" \
        " AND #{alias_name}.value <> ''" \
        " AND (#{visibility_condition(custom_field)})"
    end
    private_class_method :custom_value_join

    # INNER, and with the blank filter in the ON clause: only rows that actually carry
    # a value take part in the SUM, and a version without one stays out of the result
    # exactly as it did before this join was aliased and made visibility-aware.
    def self.cost_value_join(custom_field, field_id, alias_name)
      "INNER JOIN #{CustomValue.table_name} #{alias_name}" \
        " ON #{alias_name}.customized_type = 'Issue'" \
        " AND #{alias_name}.customized_id = issues.id" \
        " AND #{alias_name}.custom_field_id = #{field_id}" \
        " AND #{alias_name}.value <> ''" \
        " AND (#{visibility_condition(custom_field)})"
    end
    private_class_method :cost_value_join

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
      return nil unless custom_field_visible?(custom_field)

      custom_field
    rescue StandardError => e
      Rails.logger.warn("[sql_aggregation] custom field ##{field_id} lookup failed: #{e.class}: #{e.message}")
      nil
    end
    private_class_method :find_issue_custom_field

    # A role-restricted custom field is not offered to a viewer who is not entitled to
    # it: Query#add_custom_fields_filters builds its filters from `scope.visible`, so
    # the field does not appear in that user's filter list at all. The VALUES were
    # already protected by visibility_condition, but the field's NAME was not — and a
    # dimension exposes it as `field_name`, a completeness bucket as its label.
    #
    # It also removes an inconsistency with drill-through: an unentitled viewer never
    # got a URL for such a field, because Redmine leaves it out of available_filters.
    # Refusing to name what we already refuse to link is the consistent posture.
    #
    # CustomField.visible is Redmine's own predicate — one indexed EXISTS — rather
    # than a reimplementation of the roles join. Fails CLOSED, like
    # visibility_condition: a gate we cannot evaluate must not simply open.
    def self.custom_field_visible?(custom_field)
      return true unless defined?(CustomField) && CustomField.respond_to?(:visible)

      return true if CustomField.visible(User.current).exists?(id: custom_field.id)

      Rails.logger.warn("[sql_aggregation] custom field ##{custom_field.id} is restricted to roles " \
                        'the current user does not have — refusing it as a dimension, measure or ' \
                        'completeness field')
      false
    rescue StandardError => e
      Rails.logger.warn("[sql_aggregation] could not check the visibility of custom field " \
                        "##{custom_field.id}: #{e.class}: #{e.message} — refusing it")
      false
    end
    private_class_method :custom_field_visible?

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
      filter_field = PERIOD_FILTER_FIELDS[field]

      Dimension.new(
        name: name,
        sql: Arel.sql(date_format_sql(column, cfg)),
        scope_filter: ->(scope) { scope.where("#{column} >= ?", period_from(count, type)) },
        fixed_keys: build_labels(count, type),
        empty_label: empty_label.nil? ? DEFAULT_EMPTY_LABEL : empty_label.to_s,
        filter_field: filter_field,
        filter_for: ->(raws) { period_bucket_filter(filter_field, type, raws) }
      )
    end
    private_class_method :period_dimension

    # Portable on PostgreSQL and MySQL: no DATEDIFF, no CURRENT_DATE arithmetic.
    # The boundaries are computed in Ruby and bound as parameters; the SQL is a
    # plain CASE over >= comparisons. A NULL date (age_field: due) yields NULL and
    # lands in the empty bucket, not in the oldest one.
    #
    # KNOWN LIMITATION — MariaDB with ONLY_FULL_GROUP_BY.
    # This is the one dimension whose group expression is unavoidably a CASE, and
    # MariaDB's ONLY_FULL_GROUP_BY matcher does not recognise a CASE in the select
    # list as equal to the same CASE in the GROUP BY, so it rejects the statement
    # ("'created_on' isn't in GROUP BY"). PostgreSQL and MySQL 8 both accept it;
    # MariaDB only rejects it when a DBA has turned ONLY_FULL_GROUP_BY on, which is
    # not its default. The tag rescues and renders the empty result with the error in
    # the log, so a dashboard degrades rather than 500s. Removing the CASE means
    # grouping on a join or a select alias instead — see the note in the README's
    # database support section. Every other dimension groups on a bare column or a
    # plain function, both of which MariaDB matches.
    def self.age_dimension(name, age_buckets:, age_field:, empty_label:)
      bounds = normalize_age_buckets(age_buckets)

      field = age_field.to_s
      unless AGE_DATE_COLUMNS.key?(field)
        Rails.logger.warn("[sql_aggregation] unknown age_field #{age_field.inspect} — falling back to created") unless field.empty?
        field = 'created'
      end
      column = AGE_DATE_COLUMNS[field]
      labels = age_bucket_labels(bounds)
      today  = current_date

      fragments = ["CASE WHEN #{column} IS NULL THEN NULL"]
      binds     = []
      bounds.each_with_index do |days, index|
        fragments << "WHEN #{column} >= ? THEN ?"
        binds << (field == 'due' ? today - days : days.days.ago) << labels[index]
      end
      fragments << 'ELSE ? END'
      binds << labels.last

      filter_field = AGE_FILTER_FIELDS[field]

      Dimension.new(
        name: name,
        sql: Arel.sql(ActiveRecord::Base.sanitize_sql_array([fragments.join(' '), *binds])),
        fixed_keys: labels,
        empty_label: empty_label.nil? ? DEFAULT_EMPTY_LABEL : empty_label.to_s,
        filter_field: filter_field,
        filter_for: ->(raws) { age_bucket_filter(filter_field, labels, bounds, today, raws) }
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

      (current_date - timestamp.to_date).to_i
    rescue StandardError
      nil
    end
    private_class_method :days_since
  end
end
