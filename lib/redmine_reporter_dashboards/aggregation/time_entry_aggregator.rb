# frozen_string_literal: true

module RedmineReporterDashboards
  module Aggregation
    # The aggregator for time entries. A sibling of `aggregation/query_aggregator.rb`,
    # never an edit to it.
    #
    # WHY A SECOND MODULE. The issue kernel counts `DISTINCT issues.id` by construction, and
    # G7 holds that file to its v0.5.0 code. Generalising the counted unit there would move
    # the oracle 176 corpus values are measured against. What the two would have shared was
    # never the query builder — a time-entry report wants `SUM(hours)` grouped by activity,
    # user or an issue attribute — it is the RESULT VOCABULARY: the bucket shape, the
    # `filter` payload a drill-through is built from, `(none)` and `(other)`, the cap and its
    # `truncated` flag. Every rule below that says "as the kernel does" cites the kernel line
    # it copies, and the specs compare against `TimeEntryQuery#available_filters` and against
    # a real `dimension_breakdown` call.
    #
    # THE DIMENSION SET IS CORE'S. `redmine/lib/redmine/helpers/time_report.rb`'s
    # `load_available_criteria` is the authority, and these are its eight. `priority`,
    # `author` and `assignee` are excluded because none has a `TimeEntryQuery` filter to
    # drill into — and `author` is the dangerous one, since `author_id` IS a time-entry
    # filter and means WHO RECORDED THE ENTRY, not the issue's author, so its payload would
    # resolve to a plausible, wrong row set. Adding a dimension means answering "which filter
    # does its drill-through use" first.
    #
    # EVERY GROUPED AGGREGATE IS READ POSITIONALLY, AND THAT IS A CORRECTNESS RULE. MariaDB
    # truncates a returned column label at 256 characters, and ActiveRecord keys a grouped
    # `.sum`/`.average`/`.count` by the group expression's own text — past the limit every
    # key comes back NULL, the buckets collapse into one, and the total is taken from
    # whichever group the server returned last. `SUM(hours)` grouped by a dimension is this
    # module's entire purpose, so there is no `.sum`, `.average` or `.count` on a grouped
    # relation anywhere below: `measure_rows` is the only read, it plucks, and a spec asserts
    # this file's source contains none of the three.
    #
    # CORRECTNESS IS A SECOND COMPUTATION, NOT A SNAPSHOT.
    # `spec/adapter/time_entry_aggregator_spec.rb` computes every figure twice — once through
    # this SQL and once by loading the rows and adding them up in Ruby — on PostgreSQL,
    # MySQL 8 and MariaDB 11. Two independent computations agreeing is a correctness claim; a
    # recorded file would only be a did-it-change claim, and for new code it would freeze
    # whatever this answered on its first day. No golden corpus here, deliberately.
    module TimeEntryAggregator
      # `DISTINCT issues.id` is the issue kernel's unit. This module's is a time entry, and
      # naming it as a constant is what makes the difference greppable rather than implied.
      DISTINCT_ENTRIES = 'DISTINCT time_entries.id'
      HOURS_EXPRESSION = 'time_entries.hours'

      EMPTY_LABEL = '(none)'
      DEFAULT_OTHER_LABEL = '(other)'

      # THE ACTIVITY DIMENSION NEEDS A JOIN, AND THE REASON IS A WRONG NUMBER. A project may
      # OVERRIDE a time-entry activity, which creates a CHILD enumeration with its own id;
      # entries logged before the override keep the parent id and entries logged after get the
      # child. Grouping on the bare `time_entries.activity_id` therefore produces TWO buckets
      # carrying the SAME label, and a per-activity figure that disagrees with the spent-time
      # report Redmine itself ships. Measured by an independent review:
      #
      #     hours by activity: [["Design", 155.25, "9"], ["Design", 9.0, "17"]]
      #
      # Core rolls the child up to its parent — `time_report.rb:125`,
      # `COALESCE(#{TimeEntryActivity.table_name}.parent_id, …id)` — and so does this. The
      # alias is this plugin's own so it cannot collide with a join the caller's scope
      # already carries, and it is a LEFT join because an entry may have no activity at all.
      ACTIVITY_ALIAS = 'rrd_activity'
      ACTIVITY_JOIN = "LEFT OUTER JOIN enumerations #{ACTIVITY_ALIAS} " \
                      "ON #{ACTIVITY_ALIAS}.id = time_entries.activity_id"
      ACTIVITY_EXPRESSION = "COALESCE(#{ACTIVITY_ALIAS}.parent_id, #{ACTIVITY_ALIAS}.id)"

      # `label:` NAMES A READER METHOD, NOT A COLUMN, and that distinction is a defect the
      # first version shipped. It plucked `:name` and fell back to `:login` when the table had
      # no `name` column — and Redmine's `users` table has none, so every hours-by-user axis
      # was labelled `jsmith` instead of `John Smith`. `Principal#name` is a METHOD honouring
      # `Setting.user_format`, and the kernel reads it the same way
      # (`query_aggregator.rb:1822`, `user_display_names`). So the labels are read off loaded
      # records. Still ONE query, and now only for the buckets that survive the cap.
      #
      # `field:` IS A `TimeEntryQuery` FILTER NAME OR IT IS NIL. Not a column name — the
      # first version put `tracker_id` here, which is an `IssueQuery` filter and not a
      # time-entry one, so six of eleven drill-throughs pointed at filters that do not exist.
      # `nil` means "this dimension has no drill-through", which is honest and is what
      # `project` gets: `TimeEntryQuery` bounds the project through the page, not a filter.
      # A spec asserts every non-nil value is in `TimeEntryQuery#available_filters`.
      #
      # `visibility_scoped:` on `issue` because `time_entries.issue_id` is a column on the
      # ENTRY, so it survives the visibility condition core puts in `left_join_issue` — see
      # `labels_for`, where the leak that produced this flag is written up.
      DIMENSIONS = {
        'activity' => { sql: ACTIVITY_EXPRESSION, on: :own, joins: ACTIVITY_JOIN,
                        field: 'activity_id', model: 'TimeEntryActivity', label: :name },
        'user' => { sql: 'time_entries.user_id', on: :own, field: 'user_id',
                    model: 'User', label: :name },
        'project' => { sql: 'time_entries.project_id', on: :own, field: nil,
                       model: 'Project', label: :name },
        'issue' => { sql: 'time_entries.issue_id', on: :own, field: 'issue_id',
                     model: 'Issue', label: :subject, prefix_id: true,
                     visibility_scoped: true },
        'tracker' => { sql: 'issues.tracker_id', on: :issue, field: 'issue.tracker_id',
                       model: 'Tracker', label: :name },
        'status' => { sql: 'issues.status_id', on: :issue, field: 'issue.status_id',
                      model: 'IssueStatus', label: :name },
        'version' => { sql: 'issues.fixed_version_id', on: :issue,
                       field: 'issue.fixed_version_id', model: 'Version', label: :name },
        'category' => { sql: 'issues.category_id', on: :issue, field: 'issue.category_id',
                        model: 'IssueCategory', label: :name }
      }.freeze

      # A KNOWN LIMIT, recorded rather than discovered later — §Findings **S-16**.
      # `COUNT(DISTINCT …)` is right over a scope whose joins duplicate rows; `SUM` is NOT,
      # and there is no `DISTINCT` that helps — `SUM(DISTINCT hours)` would collapse two
      # genuinely separate entries that logged the same number of hours, which is worse than
      # the over-count. The correct fix is a derived table, a design change beyond T-31.
      #
      # It does not bite on either caller: every scope reaching this module comes from
      # `ReportScope`, i.e. `TimeEntry.visible` or `TimeEntryQuery#base_scope`, whose joins
      # are `belongs_to` (one row each) and whose custom-field filters are `IN (SELECT …)`
      # subqueries. `spec/adapter/time_entry_aggregator_spec.rb` asserts BOTH halves over a
      # deliberately tripling join, so the day somebody adds a `has_many` join the suite says
      # which measure moved.
      MEASURES = {
        'hours' => { kind: :sum, sql: "SUM(#{HOURS_EXPRESSION})" },
        'count' => { kind: :count, sql: "COUNT(#{DISTINCT_ENTRIES})" }
      }.freeze

      DEFAULT_MEASURE = 'hours'

      # `count` and `label`, which are two of the kernel's three
      # (`query_aggregator.rb:1774`, `SORT_MODES = %w[count label position]`). **`position`
      # is deliberately NOT supported and is deliberately not silent:** it needs an
      # enumeration order per dimension, only two of these eight have one, and an argument a
      # module cannot honour is a degradation rather than a shrug (HANDOVER §1, "every
      # aggregator entry point LOGS AND DEGRADES"). The first version fell through `else` for
      # `position` AND for `sort: banana` alike, with no log and nothing on the page.
      SORT_MODES = %w[count label].freeze
      DEFAULT_SORT = 'count'

      # `0` MEANS "THE AUTHOR SET NO LIMIT", NOT "NO LIMIT". The first version returned every
      # bucket in that case and its comment claimed the kernel does the same; measured, it
      # does the opposite — `query_aggregator.rb:1684`,
      # `cap = limit.positive? ? [limit, MAX_DIMENSION_KEYS].min : MAX_DIMENSION_KEYS`, with
      # `MAX_DIMENSION_KEYS = 200`. Without the ceiling, `{% sql_aggregate group_by: issue %}`
      # on a real instance emitted one bucket per issue with `truncated: false`, so nothing
      # admitted it: 50 000 buckets, measured, in 0.09 s. That is G6's unbounded output and
      # FR-48, in the one place a template author cannot see it coming.
      MAX_KEYS = 200
      DEFAULT_LIMIT = 0

      module_function

      # The one entry point. Answers the issue kernel's `single_result` shape, or nil for an
      # argument it cannot use — LOGGING AND DEGRADING rather than raising, which is what
      # every aggregator entry point in this plugin does (HANDOVER §1) and what a template
      # author needs from one.
      #
      # `actor:` IS EXPLICIT AND IS NOT OPTIONAL IN EFFECT. It exists only to scope the issue
      # dimension's labels, and a nil actor is answered by labelling every bucket `#<id>` —
      # fail closed (INV-1/INV-3), never by falling back to `User.current`.
      #
      # `diagnostics:` IS A PORT AND IT IS THE DIFFERENCE BETWEEN INV-4 HELD AND CLAIMED. The
      # first version only wrote to `logger`, so an author who typed `group_by: activty` got
      # `TOTAL=[0]` on the page and the reason in a server log they cannot read. That is
      # exactly the finding an independent review raised against increment 1's refusal, one
      # layer down. Duck-typed on `#degrade` — this module must not name the Liquid layer's
      # class, and does not need to.
      def breakdown(scope, group_by:, actor: nil, measure: DEFAULT_MEASURE, sort: DEFAULT_SORT,
                    limit: DEFAULT_LIMIT, other_label: DEFAULT_OTHER_LABEL,
                    empty_label: nil, logger: nil, diagnostics: nil)
        dimension = DIMENSIONS[group_by.to_s]
        if dimension.nil?
          return refuse(logger, diagnostics, :aggregation_dimension_unknown,
                        "group_by: #{group_by.inspect} is not a time-entry dimension",
                        group_by: group_by.to_s)
        end

        measure_spec = MEASURES[measure.to_s]
        if measure_spec.nil?
          return refuse(logger, diagnostics, :aggregation_measure_unknown,
                        "measure: #{measure.inspect} is not a time-entry measure",
                        measure: measure.to_s)
        end

        sort_mode = resolve_sort(sort, logger, diagnostics)

        rows = measure_rows(scope, dimension, measure_spec)
        if rows.nil?
          return refuse(logger, diagnostics, :aggregation_dimension_unavailable,
                        "group_by: #{group_by} needs the issues join, which this scope has not got",
                        group_by: group_by.to_s)
        end

        assemble(rows, dimension, measure_spec, group_by: group_by, sort: sort_mode,
                                                limit: limit, other_label: other_label,
                                                empty_label: empty_label || EMPTY_LABEL,
                                                scope: scope, actor: actor, logger: logger,
                                                diagnostics: diagnostics)
      end

      # An unsupported `sort` is a DEGRADATION and not a refusal: the figures are still
      # right, only their order is not what was asked for, so the report is worth having with
      # a note attached rather than withheld.
      def resolve_sort(sort, logger, diagnostics)
        mode = sort.to_s
        return mode if SORT_MODES.include?(mode)

        note(logger, diagnostics, :aggregation_sort_unsupported,
             "sort: #{sort.inspect} is not supported over time entries; ordered by " \
             "#{DEFAULT_SORT} instead (supported: #{SORT_MODES.join(', ')})",
             sort: mode)
        DEFAULT_SORT
      end

      # THE ONLY READ, AND IT PLUCKS. See the file comment: `.sum`/`.average`/`.count` on a
      # grouped relation key their Hash by the group expression's TEXT, which MariaDB
      # truncates at 256 characters — so this reads `[key, value]` by POSITION, exactly as
      # `QueryAggregator.grouped_counts` does for counts.
      #
      # `unscope(:order)` because an ORDER BY on a column that is not in the GROUP BY is an
      # error on some engines and meaningless on all of them.
      def measure_rows(scope, dimension, measure_spec)
        return nil unless applicable?(scope, dimension)

        expression = dimension[:sql]
        relation = scope.unscope(:order)
        relation = relation.joins(dimension[:joins]) if dimension[:joins]
        relation.group(::Arel.sql(expression))
                .pluck(::Arel.sql(expression), ::Arel.sql(measure_spec[:sql]))
      rescue ::ActiveRecord::StatementInvalid
        nil
      end

      # Whether the scope can see the table this dimension's column lives on. A time-entry
      # scope built from `TimeEntry.visible` alone has no `issues` join; one built from
      # `TimeEntryQuery#base_scope` does, because that calls `.left_join_issue`. Asking is
      # what stops the module emitting SQL for a column nothing binds.
      def applicable?(scope, dimension)
        return true if dimension[:on] == :own

        joined_to_issues?(scope)
      end

      # Read off the relation's own SQL rather than its join list: `left_join_issue` is a
      # scope on `TimeEntry`, `joins(:issue)` is an association join and a caller may have
      # written either, and both end up in the statement. One question, one place to ask it.
      #
      # A RELATION THAT CANNOT ANSWER IS TREATED AS NOT JOINED — fail closed, and a spec
      # drives it, because a review's mutation flipped this `false` to `true` and the whole
      # suite stayed green. A guard whose fail-open direction nothing tests is not a guard.
      def joined_to_issues?(scope)
        scope.to_sql.match?(/join\s+"?issues"?/i)
      rescue StandardError
        false
      end

      # --- the shared vocabulary ----------------------------------------------------------

      # The keys are `QueryAggregator.single_result`'s keys, deliberately, and the ORDER the
      # buckets come out in is `build_axis`'s (`query_aggregator.rb:1670-1704`): the present
      # keys, then `(other)` if anything was folded, then `(none)` if anything was blank —
      # **both synthetic buckets last, whatever `sort` says**.
      #
      # THE BLANK KEYS ARE PARTITIONED OUT BEFORE THE CAP, and the first version did not do
      # that. Measured by an independent review: `limit: 2` over four buckets folded `Zebra`
      # AND `(none)` into `(other)`, so unclassified hours were reported as "some other
      # activity" — a different statement, and one the README explicitly denied.
      #
      # `count` HOLDS THE MEASURE, hours included, exactly as it does for the issue kernel's
      # `measure: sum`. That is what "one aggregation vocabulary" (FR-60) buys: a template
      # that loops `stats.buckets` and prints `bucket.label` and `bucket.count` reads either
      # source.
      def assemble(rows, dimension, measure_spec, group_by:, sort:, limit:, other_label:,
                   empty_label:, scope:, actor:, logger:, diagnostics:)
        pairs = rows.map { |key, value| [key, number(value, measure_spec)] }
        blank, present = pairs.partition { |key, _| blank_key?(key) }

        kept, dropped = split(order_by_figure(present), limit)
        labels = labels_for(dimension, kept.map(&:first), actor, logger)
        kept = order_by_label(kept, labels, dimension) if sort == 'label'

        buckets = kept.map { |key, value| bucket(key, value, labels, dimension) }
        buckets << other_bucket(dropped, other_label, dimension) unless dropped.empty?
        buckets << empty_bucket(blank, empty_label, dimension) unless blank.empty?

        if dropped.any?
          note(logger, diagnostics, :aggregation_axis_truncated,
               "group_by: #{group_by} produced #{present.length} values; " \
               "#{kept.length} are shown and #{dropped.length} were folded into " \
               "#{other_label}",
               group_by: group_by.to_s, kept: kept.length, folded: dropped.length)
        end

        { 'buckets' => buckets,
          'total' => total(scope, measure_spec, buckets),
          'group_by' => group_by.to_s,
          'dimension' => group_by.to_s,
          # nil, because `core_dimension` leaves it nil (`query_aggregator.rb:1793-1815`):
          # in that vocabulary `field_name` is a CUSTOM FIELD's human name, not a column and
          # not a filter. The first version put the filter name here, which made the same
          # fact live in two places and neither of them the one a drill-through reads.
          'field_name' => nil,
          'measure' => measure_spec[:kind] == :count ? 'count' : 'hours',
          'measure_field' => measure_spec[:kind] == :count ? nil : 'hours',
          'multi_value' => false,
          'truncated' => !dropped.empty? }
      end

      # THE ORDER IS TOTAL, and that is a determinism rule rather than a nicety (CLAUDE.md
      # §6). `sort_by` is not stable, so ties fell back to whatever row order the engine
      # returned — and with a cap that changes WHICH buckets exist, not merely their order.
      # Measured by an independent review over five buckets of 1.0 hours each: PostgreSQL row
      # order `[10 … 50]` kept `["10", "20"]` at `limit: 2` and the reverse order kept
      # `["50", "40"]`. Equal hours are the normal case in a timesheet — everybody logs 8.0.
      #
      # The tie-break is the raw key, which needs no labels, which is what lets the label
      # lookup happen AFTER the cap. The kernel breaks ties on the label first
      # (`query_aggregator.rb:1723`) because it already holds every label; buying the same
      # nicety here would cost a query over every distinct key in the table.
      def order_by_figure(pairs)
        pairs.sort_by { |key, value| [-value, key.to_s] }
      end

      # `sort: label` SORTS BY THE LABEL. The first version sorted by the raw id and its
      # example was named "orders by key when asked for a label sort", so the spec enshrined
      # the defect: activity ids 20/21 and users Alice/Bob happened to be in alphabetical
      # order, and the fixture could not tell the two apart.
      #
      # `natural_key` mirrors `query_aggregator.rb:1731` — "Phase 2" before "Phase 10",
      # case-insensitively, without a locale-dependent collation. It is reimplemented rather
      # than called because the kernel's is a private class method inside a byte-frozen file
      # (G7); the specs assert the two agree on the cases that matter.
      def order_by_label(pairs, labels, dimension)
        pairs.sort_by do |key, _|
          [natural_key(labels[key] || fallback_label(key, dimension)), key.to_s]
        end
      end

      def natural_key(label)
        label.to_s.downcase.scan(/\d+|\D+/).map do |token|
          token.match?(/\A\d/) ? [0, token.to_i, ''] : [1, 0, token]
        end
      end

      # nil AND a blank string, because `blank_key?` is the kernel's predicate
      # (`query_aggregator.rb:1738`) and an engine that returns `''` for a NULL group key
      # must land in the same bucket as one that returns nil.
      def blank_key?(key)
        key.nil? || key.to_s.strip.empty?
      end

      # The ceiling, and `limit` can only tighten it — never widen it past `MAX_KEYS`.
      # Copied from `query_aggregator.rb:1684`.
      def split(ordered, limit)
        ceiling = limit.to_i.positive? ? [limit.to_i, MAX_KEYS].min : MAX_KEYS
        [ordered.first(ceiling), ordered.drop(ceiling)]
      end

      # A bucket, with the drill-through `filter` payload in the same shape the issue kernel
      # emits — `field`, `operator`, `values` — so `DrillThrough` needs no second branch.
      def bucket(key, value, labels, dimension)
        { 'label' => labels[key] || fallback_label(key, dimension),
          'count' => value,
          'value' => key.to_s,
          'filter' => equality_filter(dimension, [key.to_s]) }
      end

      # `(other)` CARRIES `values`, because the kernel's does (`query_aggregator.rb:1518`)
      # and because without it the bucket is indistinguishable from `(none)` — both have
      # `value: nil` — and its drill-through cannot be built at all. The list is the keys it
      # folded, in the order they were folded, so it is deterministic; `split` bounds it.
      def other_bucket(dropped, other_label, dimension)
        values = dropped.map { |key, _| key.to_s }
        { 'label' => other_label.to_s,
          'count' => round_like(dropped.sum { |_, value| value }),
          'value' => nil,
          'values' => values,
          'filter' => equality_filter(dimension, values) }
      end

      # `(none)` folds every blank key — nil and `''` alike — into one bucket and filters
      # for the ABSENCE of a value. `'values' => ['']` and not `[]`, matching
      # `query_aggregator.rb:1563`: Redmine's own `!*` filter carries the empty string.
      def empty_bucket(blank, empty_label, dimension)
        { 'label' => empty_label.to_s,
          'count' => round_like(blank.sum { |_, value| value }),
          'value' => nil,
          'filter' => none_filter(dimension) }
      end

      def equality_filter(dimension, values)
        return nil if dimension[:field].nil?

        { 'field' => dimension[:field], 'operator' => '=', 'values' => values }
      end

      def none_filter(dimension)
        return nil if dimension[:field].nil?

        { 'field' => dimension[:field], 'operator' => '!*', 'values' => [''] }
      end

      # The kernel's own fallback text for an id with no record — `"Status #7"`,
      # `query_aggregator.rb:1809` — and `"#42"` for an issue, which is what
      # `timelog_helper.rb:80-85` prints for an issue the viewer may not see.
      def fallback_label(key, dimension)
        dimension[:prefix_id] ? "##{key}" : "#{dimension[:model].to_s.capitalize} ##{key}"
      end

      # ONE QUERY FOR ALL THE LABELS, never one per bucket — FR-48 forbids a query count that
      # scales with the answer's size — and only for the buckets that SURVIVED the cap, which
      # the first version did not manage: it labelled every raw key and then trimmed, so a
      # 50 000-value axis instantiated 50 000 records to print 200 of them.
      #
      # A dimension with no model, or a model this Redmine does not define, labels itself
      # with `fallback_label` rather than raising.
      #
      # --- THE VISIBILITY SCOPE, WHICH IS A DISCLOSURE FIX AND NOT A REFINEMENT ---
      #
      # `time_entries.issue_id` is a column on the ENTRY, so the `issue` dimension's keys
      # survive the `Issue.visible_condition` core puts inside `left_join_issue`
      # (`redmine/app/models/time_entry.rb:64-70`). The first version then read the label from
      # an unscoped `Issue.where(id: ids)`. Measured by an independent review: an actor who
      # could see the time entry and NOT the private issue read
      # `"#15: ACQUISITION OF ACME CORP"` off their own hours report — and on the scheduled
      # path that output is mailed to other people.
      #
      # Redmine refuses this in two places, `timelog_helper.rb:80-85` and
      # `application_helper.rb:307`, both by falling back to `"##{id}"`. So does this. A nil
      # actor, or a model that cannot answer `visible`, gets NO labels at all rather than
      # unscoped ones — fail closed (INV-1/INV-3), and the bucket still prints `#42` so the
      # figure is not lost.
      def labels_for(dimension, keys, actor, logger = nil)
        ids = keys.compact
        return {} if ids.empty? || dimension[:model].nil?

        model = resolve_model(dimension[:model])
        return {} if model.nil?

        relation = visible_to(model.where(id: ids), dimension, actor, logger)
        return {} if relation.nil?

        relation.map { |record| [record.id, record_label(record, dimension)] }.to_h
      rescue ::ActiveRecord::StatementInvalid, ::NameError => e
        warn_line(logger, "label lookup failed for #{dimension[:model]}: #{e.class}: #{e.message}")
        {}
      end

      # nil means "do not label these at all", which is the fail-closed answer.
      def visible_to(relation, dimension, actor, logger)
        return relation unless dimension[:visibility_scoped]

        if actor.nil?
          warn_line(logger, "no actor, so #{dimension[:model]} labels are withheld")
          return nil
        end
        return relation.visible(actor) if relation.respond_to?(:visible)

        warn_line(logger, "#{dimension[:model]} cannot answer .visible, so labels are withheld")
        nil
      end

      # `respond_to?` guarded because the reader is core's: a Redmine that renamed `subject`
      # must degrade to an id rather than to a 500.
      def record_label(record, dimension)
        reader = dimension[:label] || :name
        text = record.respond_to?(reader) ? record.public_send(reader).to_s.strip : ''

        if dimension[:prefix_id]
          text.empty? ? "##{record.id}" : "##{record.id}: #{text}"
        else
          text.empty? ? "#{dimension[:model].to_s.capitalize} ##{record.id}" : text
        end
      end

      # `Object.const_get` on a CLOSED list of names from `DIMENSIONS`, never on anything a
      # template or a column can influence. CLAUDE.md §5 forbids `constantize` over file or
      # user content; this is neither — the names are literals in this file — and the rescue
      # exists because a Redmine that renamed one must degrade to an unlabelled bucket rather
      # than a 500.
      def resolve_model(name)
        ::Object.const_get(name)
      rescue ::NameError
        nil
      end

      # A SUM COMES BACK AS A STRING ON SOME ADAPTERS, and as a BigDecimal on others. Hours
      # are a decimal in Redmine's schema, so the answer is rounded to two places rather than
      # left as whatever the adapter handed over — an axis whose labels differ by engine is
      # the same class of defect as one whose numbers do.
      def number(value, measure_spec)
        return value.to_i if measure_spec[:kind] == :count

        value.to_f.round(2)
      end

      def round_like(value)
        value.is_a?(Float) ? value.round(2) : value
      end

      # THE SAME SPLIT `QueryAggregator.result_total` MAKES (`query_aggregator.rb:1360-1364`),
      # and matching it is the point: a counted axis is totalled from the buckets, a measured
      # one is read from the scope.
      #
      # MUTATION-TESTED, AND THIS IS THE FINDING. The first version always read the scalar,
      # and replacing it with `buckets.sum` left the whole suite green — because the fold
      # preserves the sum and every dimension here is single-valued, so the two computations
      # are provably EQUAL and no example could ever tell them apart. An equivalent mutant is
      # not a missing test; it is a query nobody needed. So the count path no longer issues
      # it (FR-48: one less statement per counted breakdown), the measured path keeps it
      # because it is the robust reading if a dimension ever folds rows differently, and the
      # difference is now visible where it is real — as a QUERY COUNT, asserted in
      # `spec/adapter/time_entry_aggregator_spec.rb`.
      #
      # ROUNDING MEANS THE TWO CAN DIFFER BY A CENT-HOUR: three buckets of 0.005 each round
      # to 0.01, 0.01, 0.01 while the scalar rounds once to 0.02. Structurally impossible on
      # the issue path, which counts integers, and inherent to any report that prints a total
      # and its parts at two decimal places — Redmine's own spent-time report included. Named
      # here so a reader who spots it knows it is arithmetic and not a lost row.
      def total(scope, measure_spec, buckets)
        return buckets.sum { |bucket| bucket['count'] } if measure_spec[:kind] == :count

        value = scope.unscope(:order).pluck(::Arel.sql(measure_spec[:sql])).first
        number(value, measure_spec)
      rescue ::ActiveRecord::StatementInvalid
        0
      end

      # Both halves of a refusal, in one place so neither can be forgotten: the server log for
      # whoever is on call, and the degradation the template author reads on the page (INV-4).
      # Answers nil, which is what `breakdown` returns and what the tag turns into the empty
      # result. A spec asserts BOTH halves — the log line's absence was a surviving mutation.
      def refuse(logger, diagnostics, code, message, **data)
        note(logger, diagnostics, code, message, **data)
        nil
      end

      # A degradation that is NOT a refusal: the figures stand, something about them is less
      # than was asked for, and the reader is told. Same two halves.
      def note(logger, diagnostics, code, message, **data)
        warn_line(logger, message)
        diagnostics.degrade(code, detail: message, **data) if diagnostics.respond_to?(:degrade)
        true
      end

      def warn_line(logger, message)
        logger.warn("[time_entry_aggregation] #{message}") if logger.respond_to?(:warn)
      end
    end
  end
end
