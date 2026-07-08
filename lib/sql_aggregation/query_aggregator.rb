# frozen_string_literal: true

module SqlAggregation
  # Runs pure-SQL COUNT(*) GROUP BY aggregations on an ActiveRecord scope.
  # No Issue objects are instantiated — the scope is used only for SQL generation.
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
  # --- Breakdown mode (.breakdown) ---
  #
  #   group_by — 'status' | 'priority' | 'tracker' | 'assignee' |
  #              'author' | 'category' | 'version'
  #
  #   Returns: buckets [{label, count}] sorted desc, total, group_by
  class QueryAggregator
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
        .count

      # Guard against empty closed_ids: WHERE status_id IN () / NOT IN () produces
      # 1=0 / 1=1 which is technically correct but makes intent opaque.
      if closed_ids.empty?
        closed_raw = {}
        open_count = base.count
      else
        closed_raw = base
          .where(status_id: closed_ids)
          .where('issues.closed_on IS NOT NULL')
          .where('issues.closed_on >= ?', from)
          .group(date_format_sql('issues.closed_on', cfg))
          .count
        open_count = base.where.not(status_id: closed_ids).count
      end

      total = base.count

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
      id_counts = base.group(cfg[:field]).count        # {1=>42, nil=>5, 3=>18}
      ids       = id_counts.keys.compact
      names     = ids.any? ? cfg[:lookup].call(ids) : {}

      buckets = id_counts.map do |id, count|
        label = id.nil? ? cfg[:null_label] : (names[id] || "#{group_by.capitalize} ##{id}")
        { 'label' => label.to_s, 'count' => count }
      end.sort_by { |b| -b['count'] }

      { 'buckets' => buckets, 'total' => buckets.sum { |b| b['count'] }, 'group_by' => group_by.to_s }
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

    def self.period_from(n, period)
      case period.to_s
      when 'day'   then n.days.ago.beginning_of_day
      when 'week'  then n.weeks.ago.beginning_of_week
      when 'month' then n.months.ago.beginning_of_month
      when 'year'  then n.years.ago.beginning_of_year
      else              n.months.ago.beginning_of_month
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

    def self.postgresql?
      @postgresql ||= ActiveRecord::Base.connection.adapter_name =~ /postgresql/i ? true : false
    rescue StandardError
      false
    end
    private_class_method :postgresql?

    def self.date_format_sql(column, cfg)
      if postgresql?
        "TO_CHAR(#{column}, '#{cfg[:pg_format]}')"
      else
        "DATE_FORMAT(#{column}, '#{cfg[:sql_format]}')"
      end
    end
    private_class_method :date_format_sql
  end
end
