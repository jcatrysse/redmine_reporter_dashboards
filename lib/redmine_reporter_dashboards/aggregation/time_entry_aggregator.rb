# frozen_string_literal: true

module RedmineReporterDashboards
  module Aggregation
    # T-31 — the OWNED aggregator for time entries. A sibling of
    # `aggregation/query_aggregator.rb`, never an edit to it.
    #
    # --- WHY A SECOND MODULE RATHER THAN A SECOND G7 HUNK ---
    #
    # Curator decision, 2026-08-08, closing §Findings **S-13**. The issue kernel counts
    # `DISTINCT issues.id` by construction — that is the constant `DISTINCT_ISSUES` — and
    # gate **G7** holds that file byte-identical to its `v0.5.0` blob plus exactly ONE
    # declared hunk. Generalising the counted unit there would be a second exception in the
    # file this plan freezes hardest, and it would move the oracle 176 corpus values are
    # measured against.
    #
    # The objection to two implementations is answered by what they actually share. A
    # time-entry report wants DIFFERENT SQL — `SUM(hours)` grouped by activity, user or an
    # issue attribute — so the reusable part was never the query builder. What is shared is
    # the RESULT VOCABULARY: the bucket shape, the `filter` payload a drill-through link is
    # built from, the `(none)` bucket, the cap and its `truncated` flag. Those are reproduced
    # here deliberately and asserted against the issue kernel's own keys, so a template
    # written for one reads the other.
    #
    # --- EVERY GROUPED AGGREGATE IS READ POSITIONALLY, AND THAT IS A CORRECTNESS RULE ---
    #
    # This is `Accept:` clause 5 and the single most important thing in the file. Defect
    # **D-1** — MariaDB truncating a returned column label at 256 characters — was fixed for
    # the COUNT path only: `QueryAggregator.grouped_counts` does
    # `relation.pluck(*group_values, Arel.sql("COUNT(…)"))` and reads the row BY POSITION,
    # while `raw_measure` still calls `relation.sum(Arel.sql(expression))` on a grouped
    # relation — and ActiveRecord keys that Hash by the group expression's own TEXT. Past 256
    # characters every key comes back NULL, the buckets collapse into one and the total is
    # taken from whichever group the server returned last.
    #
    # `SUM(hours)` grouped by a dimension is this module's entire purpose, so it walks
    # straight into the one defect class this project has documented as open and ungated —
    # the handover says of it, in as many words, *"no gate in this project can catch it"*. So
    # there is no `.sum`, `.average` or `.count` on a grouped relation anywhere below;
    # `measure_rows` is the only read, it plucks, and a spec asserts this file's own source
    # contains none of the three.
    #
    # --- HOW CORRECTNESS IS ESTABLISHED: A SECOND COMPUTATION, NOT A SNAPSHOT ---
    #
    # `Accept:` clause 6. `spec/adapter/time_entry_aggregator_spec.rb` computes every figure
    # twice — once through this module's SQL and once by loading the rows and adding them up
    # in Ruby — and runs the comparison on PostgreSQL, MySQL 8 and MariaDB 11. Two
    # independent computations agreeing is a correctness claim; a recorded file would only be
    # a did-it-change claim, and for brand-new code it would freeze whatever this happened to
    # answer on its first day. No golden corpus is added, deliberately.
    module TimeEntryAggregator
      # `DISTINCT issues.id` is the issue kernel's unit. This module's is a time entry, and
      # naming it as a constant is what makes the difference greppable rather than implied.
      DISTINCT_ENTRIES = 'DISTINCT time_entries.id'
      HOURS_EXPRESSION = 'time_entries.hours'

      EMPTY_LABEL = '(none)'
      DEFAULT_OTHER_LABEL = '(other)'

      # THE DIMENSIONS, and which table each one needs.
      #
      # `own` means the column is on `time_entries` and needs no join. `issue` means it is on
      # `issues`, which a time-entry scope reaches only because `TimeEntryQuery#base_scope`
      # calls `.left_join_issue` — so those are declared as needing it and `applicable?`
      # answers honestly for a scope that does not have it, rather than emitting SQL that
      # binds to nothing.
      #
      # `activity` and `user` are the two the issue kernel does not have at all, and they are
      # the two a time report is usually about.
      # `label:` NAMES A READER METHOD, NOT A COLUMN, and that distinction is a defect the
      # first version shipped. It plucked `:name` and fell back to `:login` when the table had
      # no `name` column — and Redmine's `users` table has none, so every hours-by-user axis
      # was labelled `jsmith` instead of `John Smith`. `Principal#name` is a METHOD honouring
      # `Setting.user_format`, so the labels are read off loaded records. Still ONE query
      # (FR-48); see `labels_for`.
      DIMENSIONS = {
        'activity' => { sql: 'time_entries.activity_id', on: :own, field: 'activity_id',
                        model: 'TimeEntryActivity', label: :name },
        'user' => { sql: 'time_entries.user_id', on: :own, field: 'user_id',
                    model: 'User', label: :name },
        'project' => { sql: 'time_entries.project_id', on: :own, field: 'project_id',
                       model: 'Project', label: :name },
        # `prefix_id` because an issue's subject is not unique and an axis of bare subjects is
        # an axis a reader cannot act on — `#42: Fix the importer` is what Redmine shows and
        # what a drill-through lands on.
        'issue' => { sql: 'time_entries.issue_id', on: :own, field: 'issue_id',
                     model: 'Issue', label: :subject, prefix_id: true },
        'tracker' => { sql: 'issues.tracker_id', on: :issue, field: 'tracker_id',
                       model: 'Tracker', label: :name },
        'status' => { sql: 'issues.status_id', on: :issue, field: 'status_id',
                      model: 'IssueStatus', label: :name },
        'priority' => { sql: 'issues.priority_id', on: :issue, field: 'priority_id',
                        model: 'IssuePriority', label: :name },
        'author' => { sql: 'issues.author_id', on: :issue, field: 'author_id',
                      model: 'User', label: :name },
        'assignee' => { sql: 'issues.assigned_to_id', on: :issue, field: 'assigned_to_id',
                        model: 'User', label: :name },
        'version' => { sql: 'issues.fixed_version_id', on: :issue, field: 'fixed_version_id',
                       model: 'Version', label: :name },
        'category' => { sql: 'issues.category_id', on: :issue, field: 'category_id',
                        model: 'IssueCategory', label: :name }
      }.freeze

      # A KNOWN LIMIT, recorded rather than discovered later. `COUNT(DISTINCT …)` is right over
      # a scope whose joins duplicate rows; `SUM` is NOT, and there is no `DISTINCT` that
      # helps — `SUM(DISTINCT hours)` would collapse two genuinely separate entries that
      # logged the same number of hours, which is worse than the over-count. The correct fix
      # is a derived table, which is a design change beyond T-31.
      #
      # It does not bite on either caller: every scope reaching this module comes from
      # `ReportScope`, i.e. `TimeEntry.visible` or `TimeEntryQuery#base_scope`, whose joins are
      # `belongs_to` (one row each) and whose custom-field filters are `IN (SELECT …)`
      # subqueries. `spec/adapter/time_entry_aggregator_spec.rb` asserts BOTH halves over a
      # deliberately tripling join, so the day somebody adds a `has_many` join the suite says
      # which measure moved.
      MEASURES = {
        'hours' => { kind: :sum, sql: "SUM(#{HOURS_EXPRESSION})" },
        'count' => { kind: :count, sql: "COUNT(#{DISTINCT_ENTRIES})" }
      }.freeze

      DEFAULT_MEASURE = 'hours'

      # The axis cap. Same shape and the same default as the issue kernel's, because a
      # template author who has learned one has learned both.
      DEFAULT_LIMIT = 0

      module_function

      # The one entry point. Answers the issue kernel's `single_result` shape, or nil for an
      # argument it cannot use — LOGGING AND DEGRADING rather than raising, which is what
      # every aggregator entry point in this plugin does (HANDOVER §1) and what a template
      # author needs from one.
      #
      # `diagnostics:` IS A PORT AND IT IS THE DIFFERENCE BETWEEN INV-4 HELD AND CLAIMED. The
      # first version only wrote to `logger`, so an author who typed `group_by: activty` got
      # `TOTAL=[0]` on the page and the reason in a server log they cannot read. That is
      # exactly the finding an independent review raised against increment 1's refusal, one
      # layer down. Duck-typed on `#degrade` — this module must not name the Liquid layer's
      # class, and does not need to.
      def breakdown(scope, group_by:, measure: DEFAULT_MEASURE, sort: 'count',
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

        rows = measure_rows(scope, dimension, measure_spec)
        if rows.nil?
          return refuse(logger, diagnostics, :aggregation_dimension_unavailable,
                        "group_by: #{group_by} needs the issues join, which this scope has not got",
                        group_by: group_by.to_s)
        end

        assemble(rows, dimension, measure_spec, group_by: group_by, sort: sort, limit: limit,
                                                other_label: other_label,
                                                empty_label: empty_label || EMPTY_LABEL,
                                                scope: scope)
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
        scope.unscope(:order)
             .group(::Arel.sql(expression))
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
      def joined_to_issues?(scope)
        scope.to_sql.match?(/join\s+"?issues"?/i)
      rescue StandardError
        false
      end

      # --- the shared vocabulary ----------------------------------------------------------

      # The keys are `QueryAggregator.single_result`'s keys, deliberately. A template that
      # loops `stats.buckets` and prints `bucket.label` and `bucket.count` works over either
      # source, which is the whole of what "one aggregation vocabulary" (FR-60) buys — and
      # `count` holds the MEASURE, hours included, exactly as it does for the issue kernel's
      # `measure: sum`.
      def assemble(rows, dimension, measure_spec, group_by:, sort:, limit:, other_label:,
                   empty_label:, scope:)
        pairs = rows.map { |key, value| [key, number(value, measure_spec)] }
        labels = labels_for(dimension, pairs.map(&:first))

        ordered = order(pairs, sort)
        kept, folded = cap(ordered, limit)

        buckets = kept.map do |key, value|
          bucket(key, value, labels, dimension, empty_label)
        end
        buckets << { 'label' => other_label, 'count' => folded, 'value' => nil,
                     'filter' => nil } if folded

        { 'buckets' => buckets,
          'total' => total(scope, measure_spec, buckets),
          'group_by' => group_by.to_s,
          'dimension' => group_by.to_s,
          'field_name' => dimension[:field],
          'measure' => measure_spec[:kind] == :count ? 'count' : 'hours',
          'measure_field' => measure_spec[:kind] == :count ? nil : 'hours',
          'multi_value' => false,
          'truncated' => !folded.nil? }
      end

      # A bucket, with the drill-through `filter` payload in the same shape the issue kernel
      # emits — `field`, `operator`, `values` — so `DrillThrough` needs no second branch.
      def bucket(key, value, labels, dimension, empty_label)
        { 'label' => key.nil? ? empty_label : (labels[key] || key.to_s),
          'count' => value,
          'value' => key.nil? ? nil : key.to_s,
          'filter' => key.nil? ? { 'field' => dimension[:field], 'operator' => '!*',
                                   'values' => [] }
                               : { 'field' => dimension[:field], 'operator' => '=',
                                   'values' => [key.to_s] } }
      end

      # ONE QUERY FOR ALL THE LABELS, never one per bucket — FR-48 forbids a query count that
      # scales with the answer's size, and a label lookup per row is the classic way to break
      # it. A dimension with no model, or a model this Redmine does not define, labels itself
      # with the raw key rather than raising.
      #
      # RECORDS, NOT `pluck` — see `DIMENSIONS`. The label is a READER, and `Principal#name`
      # is a method over `firstname`/`lastname` honouring `Setting.user_format`, so plucking a
      # `name` COLUMN put logins on every hours-by-user axis. Still one query; the row count
      # is the bucket count, which the cap already bounds.
      def labels_for(dimension, keys)
        ids = keys.compact
        return {} if ids.empty? || dimension[:model].nil?

        model = resolve_model(dimension[:model])
        return {} if model.nil?

        model.where(id: ids).map { |record| [record.id, record_label(record, dimension)] }.to_h
      rescue ::ActiveRecord::StatementInvalid, ::NameError
        {}
      end

      # `respond_to?` guarded because the reader is core's: a Redmine that renamed `subject`
      # must degrade to an id rather than to a 500.
      def record_label(record, dimension)
        reader = dimension[:label] || :name
        text = record.respond_to?(reader) ? record.public_send(reader).to_s.strip : ''

        if dimension[:prefix_id]
          text.empty? ? "##{record.id}" : "##{record.id}: #{text}"
        else
          text.empty? ? record.id.to_s : text
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

      # THE SAME SPLIT `QueryAggregator.result_total` MAKES, and matching it is the point:
      # a counted axis is totalled from the buckets, a measured one is read from the scope.
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
      def total(scope, measure_spec, buckets)
        return buckets.sum { |bucket| bucket['count'] } if measure_spec[:kind] == :count

        value = scope.unscope(:order).pluck(::Arel.sql(measure_spec[:sql])).first
        number(value, measure_spec)
      rescue ::ActiveRecord::StatementInvalid
        0
      end

      # `count` descending is the default because that is what the issue kernel's `sort`
      # default means; `label` is the other spelling a template may ask for. An unknown value
      # falls back to `count` rather than raising, matching the kernel's `sanitize_sort`.
      def order(pairs, sort)
        case sort.to_s
        when 'label' then pairs.sort_by { |key, _| key.to_s }
        when 'value' then pairs.sort_by { |_, value| -value }
        else pairs.sort_by { |_, value| -value }
        end
      end

      # The cap folds the tail into one bucket and SAYS SO through `truncated`, rather than
      # dropping it — INV-4, and the same behaviour the issue kernel's `build_axis` has.
      # `limit` of 0 means no cap, which is its default there too.
      def cap(ordered, limit)
        return [ordered, nil] if limit.to_i <= 0 || ordered.length <= limit.to_i

        kept = ordered.first(limit.to_i)
        folded = ordered.drop(limit.to_i).sum { |_, value| value }
        [kept, folded.is_a?(Float) ? folded.round(2) : folded]
      end

      # Both halves of a refusal, in one place so neither can be forgotten: the server log for
      # whoever is on call, and the degradation the template author reads on the page (INV-4).
      # Answers nil, which is what `breakdown` returns and what the tag turns into the empty
      # result.
      def refuse(logger, diagnostics, code, message, **data)
        logger.warn("[time_entry_aggregation] #{message}") if logger.respond_to?(:warn)
        diagnostics.degrade(code, detail: message, **data) if diagnostics.respond_to?(:degrade)
        nil
      end
    end
  end
end
