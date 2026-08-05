# frozen_string_literal: true

module RrdGolden
  # THE QUESTIONS the golden corpus answers, as data.
  #
  # One entry per (entry point, scope, actor, arguments) tuple. The generator runs
  # them in this order and the verifier re-runs the same list, so the corpus is a
  # differential over a *declared* matrix rather than over whatever the last person
  # happened to add. Everything here is deliberately inert — no database, no
  # ActiveRecord, not even the aggregator — so the coverage of the matrix can be
  # asserted in the DB-less spec run on every supported Redmine
  # (corpus_cases_spec.rb), while the numbers need a real engine.
  #
  # --- What the matrix has to cover, and why each is here ---
  #
  #   six entry points   .aggregate, .breakdown (legacy), .dimension_breakdown,
  #                      .completeness, .flags, .version_rollup — the whole public
  #                      surface of the kernel that T-07/T-08 re-seam
  #   four caps          200 dimension keys / 24 age buckets / 12 completeness
  #                      fields / 5 000 crosstab cells, each AT the boundary and one
  #                      PAST it (CLAUDE.md §3, phase 3)
  #   four actors        three distinct roles, including one ROLE-RESTRICTED custom
  #                      field, so INV-1 and INV-2 are testable at value level: the
  #                      same call under a different actor is refused, or answers
  #                      differently
  #   the empty scope    what every entry point says about nothing at all — the
  #                      empty state a dashboard actually renders on day one
  #
  # --- Ordering ---
  #
  # `normalise` names the cases whose OUTPUT ORDER the kernel does not define. Two
  # exist, and both are findings rather than choices (see the note on each): the
  # corpus records them sorted, because freezing an undefined order would make the
  # oracle fail on whichever row order the engine felt like returning. Everything
  # else is recorded exactly as returned — `buckets`, `labels`, `rows` and `series`
  # are ordering contracts and sorting them would hide the regression the corpus
  # exists to catch.
  module CorpusCases
    Case = Struct.new(:id, :entry, :scope, :actor, :args, :normalise, keyword_init: true) do
      def normalise
        self[:normalise] || :none
      end
    end

    ENTRY_POINTS = %w[aggregate breakdown dimension_breakdown completeness flags
                      version_rollup].freeze

    # Resolved by the generator against the harness fixture, never here.
    SCOPES = %w[main reported sweep wide wide_at_cap closed_only empty].freeze

    ACTORS = %w[manager developer reporter auditor].freeze

    NORMALISATIONS = %i[none sort_buckets sort_version_rows].freeze

    # The caps, as literals. They are asserted against the aggregator's own constants
    # by the verifier, so raising a cap without regenerating the corpus fails here
    # rather than silently widening what is frozen.
    CAP_DIMENSION_KEYS      = 200
    CAP_AGE_BUCKETS         = 24
    CAP_COMPLETENESS_FIELDS = 12
    CAP_DRILL_CELLS         = 5_000

    # Custom field ids, mirroring the harness. Duplicated as literals for the same
    # reason the caps are: this file must load without the harness.
    CF_DEPARTMENT = 10
    CF_POINTS     = 11
    CF_COST       = 12
    CF_HIDDEN     = 13
    CF_CLIENT     = 14
    CF_SALARY     = 15
    CF_WIDE       = 16

    # The eight core completeness fields, in the order COMPLETENESS_CORE_FIELDS
    # declares them.
    CORE_COMPLETENESS = %w[assigned_to_id category_id fixed_version_id parent_id
                           due_date start_date estimated_hours description].freeze

    # 24 ascending bounds -> 25 buckets, which is the cap exactly. The 25th bound is
    # dropped by MAX_AGE_BUCKETS, so the "one past" case must produce the SAME
    # result as this one — and the verifier asserts that rather than merely
    # recording it.
    AGE_BOUNDS_AT_CAP   = (1..CAP_AGE_BUCKETS).to_a.freeze
    AGE_BOUNDS_PAST_CAP = (1..(CAP_AGE_BUCKETS + 1)).to_a.freeze

    class << self
      def all
        @all ||= begin
          cases = aggregate_cases + breakdown_cases + dimension_cases + measure_cases +
                  cap_cases + completeness_cases + flags_cases + version_rollup_cases
          validate!(cases)
          cases.freeze
        end
      end

      def ids
        all.map(&:id)
      end

      def for_entry(entry)
        all.select { |kase| kase.entry == entry.to_s }
      end

      # The identity of the QUESTION LIST, recorded in the manifest. A case list that
      # has moved on from the committed answers is caught by comparing this, instead
      # of by a reader noticing that a case id in the diff has no record.
      def digest
        require_relative 'corpus_canonicaliser'
        CorpusCanonicaliser.digest(all.map { |kase| declaration(kase) })
      end

      # What goes into the corpus record alongside the result: everything needed to
      # re-run the case by hand from the failure message.
      def declaration(kase)
        { 'case' => kase.id, 'entry' => kase.entry, 'scope' => kase.scope,
          'actor' => kase.actor, 'args' => kase.args, 'normalise' => kase.normalise.to_s }
      end

      private

      def build(id, entry, scope, actor, args = {}, normalise: :none)
        Case.new(id: id, entry: entry, scope: scope, actor: actor, args: args,
                 normalise: normalise)
      end

      def validate!(cases)
        duplicates = cases.map(&:id).tally.select { |_, n| n > 1 }.keys
        raise "duplicate corpus case ids: #{duplicates.sort.inspect}" unless duplicates.empty?

        cases.each do |kase|
          raise "#{kase.id}: unknown entry point #{kase.entry}" unless ENTRY_POINTS.include?(kase.entry)
          raise "#{kase.id}: unknown scope #{kase.scope}" unless SCOPES.include?(kase.scope)
          raise "#{kase.id}: unknown actor #{kase.actor}" unless ACTORS.include?(kase.actor)
          raise "#{kase.id}: unknown normalisation" unless NORMALISATIONS.include?(kase.normalise)
        end
      end

      # ----------------------------------------------------------------
      # .aggregate — the time series
      # ----------------------------------------------------------------
      #
      # The period sweep runs over the 400-day fixture, which spans three ISO years
      # from the pinned reference date, so the TO_CHAR / DATE_FORMAT divergence is
      # exercised by every one of these rather than only on the days of the year a
      # relative fixture would wander into it.
      def aggregate_cases
        periods = { 'day' => [30, 90, 91], 'week' => [13, 52, 53],
                    'month' => [6, 24, 25], 'year' => [3, 10, 11] }

        cases = periods.flat_map do |period, counts|
          [build("aggregate/sweep.#{period}.default", 'aggregate', 'sweep', 'manager',
                 { 'period' => period })] +
            counts.map do |n|
              build("aggregate/sweep.#{period}.#{n}", 'aggregate', 'sweep', 'manager',
                    { 'period' => period, 'periods' => n })
            end
        end

        # closed_statuses: by name, by two names, by a name that does not exist (the
        # fall-back-to-is_closed path), and the default empty list.
        cases += [
          build('aggregate/main.month.default', 'aggregate', 'main', 'manager', { 'period' => 'month' }),
          build('aggregate/main.day60.closed_named', 'aggregate', 'main', 'manager',
                { 'period' => 'day', 'periods' => 60, 'closed_statuses' => ['Closed'] }),
          build('aggregate/main.day60.closed_two', 'aggregate', 'main', 'manager',
                { 'period' => 'day', 'periods' => 60, 'closed_statuses' => %w[Closed Rejected] }),
          build('aggregate/main.day60.closed_unknown', 'aggregate', 'main', 'manager',
                { 'period' => 'day', 'periods' => 60, 'closed_statuses' => ['No Such Status'] }),
          # The chunking boundary: OPEN_AT_END_CHUNK is 30, so 90 periods is three
          # statements whose parts have to line up.
          build('aggregate/main.day90.chunked', 'aggregate', 'main', 'manager',
                { 'period' => 'day', 'periods' => 90 }),
          build('aggregate/empty.month', 'aggregate', 'empty', 'manager', { 'period' => 'month' })
        ]

        # .aggregate reads no custom field and no time entry, so it must be
        # actor-INVARIANT. Recorded under two actors and asserted equal: an oracle
        # that only proves visibility where it applies cannot notice a new leak.
        cases + ACTORS.map do |actor|
          build("aggregate/main.month.actor_#{actor}", 'aggregate', 'main', actor,
                { 'period' => 'month' })
        end
      end

      # ----------------------------------------------------------------
      # .breakdown — the legacy entry point, all seven core fields
      # ----------------------------------------------------------------
      #
      # normalise: :sort_buckets on every case. FINDING, not a preference:
      # .breakdown sorts its buckets with `sort_by { -count }`, which is neither
      # stable nor total, over a Hash whose order comes from an unordered GROUP BY.
      # Two engines — or two runs — may legitimately return equal-count buckets in a
      # different order. The kernel is frozen byte-for-byte by gate G7, so this
      # cannot be fixed here; the corpus therefore records the buckets in a total
      # order ([-count, label]) which still fails if the COUNT order regresses.
      def breakdown_cases
        fields = %w[status priority tracker assignee author category version]

        cases = fields.map do |field|
          build("breakdown/main.#{field}", 'breakdown', 'main', 'manager',
                { 'group_by' => field }, normalise: :sort_buckets)
        end

        cases + [
          build('breakdown/reported.status', 'breakdown', 'reported', 'manager',
                { 'group_by' => 'status' }, normalise: :sort_buckets),
          build('breakdown/wide.assignee', 'breakdown', 'wide', 'manager',
                { 'group_by' => 'assignee' }, normalise: :sort_buckets),
          build('breakdown/empty.status', 'breakdown', 'empty', 'manager',
                { 'group_by' => 'status' }, normalise: :sort_buckets),
          # Not a breakdown field: the documented empty-and-safe answer, not nil.
          build('breakdown/main.unknown_field', 'breakdown', 'main', 'manager',
                { 'group_by' => 'nonsense' }, normalise: :sort_buckets)
        ]
      end

      # ----------------------------------------------------------------
      # .dimension_breakdown — dimensions, labels, sorts, limits, crosstabs
      # ----------------------------------------------------------------
      def dimension_cases
        core_dimension_cases + label_and_sort_cases + custom_field_cases +
          period_and_age_cases + crosstab_cases + refusal_cases
      end

      def core_dimension_cases
        %w[status priority tracker assignee author category version].map do |field|
          build("dimension/main.#{field}", 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => field })
        end
      end

      def label_and_sort_cases
        [
          build('dimension/main.assignee.login', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'assignee', 'user_label' => 'login' }),
          build('dimension/main.assignee.empty_label', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'assignee', 'empty_label' => 'Nobody' }),
          build('dimension/main.priority.sort_count', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'priority', 'sort' => 'count' }),
          build('dimension/main.priority.sort_label', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'priority', 'sort' => 'label' }),
          # No order_map on a core dimension, so `position` degrades to label order.
          # Frozen because the degradation is the behaviour, not a bug to discover.
          build('dimension/main.priority.sort_position', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'priority', 'sort' => 'position' }),
          build('dimension/main.priority.sort_unknown', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'priority', 'sort' => 'sideways' }),
          # cf_DEPARTMENT has possible_values, so `position` is a real order here.
          build('dimension/main.cf_department.sort_position', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => "cf_#{CF_DEPARTMENT}", 'sort' => 'position' }),
          build('dimension/main.priority.limit1', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'priority', 'sort' => 'label', 'limit' => 1 }),
          build('dimension/main.priority.limit1.other_label', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'priority', 'sort' => 'label', 'limit' => 1,
                  'other_label' => 'The rest' }),
          build('dimension/main.priority.limit2', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'priority', 'sort' => 'label', 'limit' => 2 }),
          build('dimension/empty.status', 'dimension_breakdown', 'empty', 'manager',
                { 'group_by' => 'status' })
        ]
      end

      # The role-restricted field is the point of this block. cf_SALARY is
      # `visible: false` restricted to ROLE_MANAGER, and the four actors sit in the
      # four positions that matter:
      #
      #   manager    holds the role in MAIN -> values visible
      #   auditor    holds the role, but in WIDE -> field resolves, values HIDDEN,
      #              and the issues still count (INV-2: the join must not filter)
      #   developer  holds no entitled role -> the dimension is REFUSED (nil)
      #   reporter   ditto, from a different role
      def custom_field_cases
        cases = [
          build('dimension/main.cf_department', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => "cf_#{CF_DEPARTMENT}" }),
          build('dimension/main.cf_points', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => "cf_#{CF_POINTS}" }),
          build('dimension/reported.cf_cost', 'dimension_breakdown', 'reported', 'manager',
                { 'group_by' => "cf_#{CF_COST}" }),
          build('dimension/main.cf_department.empty_label', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => "cf_#{CF_DEPARTMENT}", 'empty_label' => 'Not set' })
        ]

        cases += ACTORS.flat_map do |actor|
          [build("dimension/main.cf_salary.#{actor}", 'dimension_breakdown', 'main', actor,
                 { 'group_by' => "cf_#{CF_SALARY}" }),
           build("dimension/wide.cf_salary.#{actor}", 'dimension_breakdown', 'wide', actor,
                 { 'group_by' => "cf_#{CF_SALARY}" })]
        end

        # A project-restricted field is NOT actor-restricted: recorded under two
        # actors so the difference between the two mechanisms is frozen too.
        cases + ACTORS.map do |actor|
          build("dimension/reported.cf_cost.#{actor}", 'dimension_breakdown', 'reported', actor,
                { 'group_by' => "cf_#{CF_COST}" })
        end
      end

      def period_and_age_cases
        cases = %w[day week month year].map do |period|
          build("dimension/sweep.period.#{period}", 'dimension_breakdown', 'sweep', 'manager',
                { 'group_by' => 'period', 'period' => period, 'periods' => 7 })
        end

        cases += [
          build('dimension/main.period.closed_field', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'period', 'period' => 'day', 'periods' => 60,
                  'date_field' => 'closed' }),
          build('dimension/main.period.unknown_field', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'period', 'period' => 'day', 'periods' => 7,
                  'date_field' => 'sideways' })
        ]

        cases + %w[created updated due].map do |field|
          build("dimension/main.age.#{field}", 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'age', 'age_field' => field, 'age_buckets' => [30, 60, 90] })
        end
      end

      def crosstab_cases
        [
          build('dimension/main.status_x_tracker', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'status', 'split_by' => 'tracker' }),
          build('dimension/main.cf_department_x_status', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => "cf_#{CF_DEPARTMENT}", 'split_by' => 'status' }),
          build('dimension/sweep.period_x_tracker', 'dimension_breakdown', 'sweep', 'manager',
                { 'group_by' => 'period', 'period' => 'day', 'periods' => 5,
                  'split_by' => 'tracker' }),
          build('dimension/main.age_x_status', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'age', 'age_buckets' => [30, 90], 'split_by' => 'status' }),
          build('dimension/main.status_x_tracker.limit1', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'status', 'split_by' => 'tracker', 'sort' => 'count',
                  'limit' => 1 }),
          build('dimension/wide.cf_wide_x_tracker.limit3', 'dimension_breakdown', 'wide', 'manager',
                { 'group_by' => "cf_#{CF_WIDE}", 'split_by' => 'tracker', 'sort' => 'label',
                  'limit' => 3 })
        ]
      end

      # Each of these must be nil — a refusal, not an empty chart. Frozen because a
      # refusal that quietly becomes an empty result is the failure mode INV-3 is
      # about: the viewer cannot tell "you may not see this" from "there is nothing".
      def refusal_cases
        [
          build('dimension/main.cf_hidden', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => "cf_#{CF_HIDDEN}" }),
          build('dimension/main.cf_client', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => "cf_#{CF_CLIENT}" }),
          build('dimension/main.cf_absent', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'cf_9999' }),
          build('dimension/main.unknown_dimension', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'nonsense' }),
          build('dimension/main.flags_as_dimension', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'flags' }),
          build('dimension/main.split_unknown', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'status', 'split_by' => 'nonsense' }),
          build('dimension/main.avg_spent_hours', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'status', 'measure' => 'avg', 'of' => 'spent_hours' }),
          build('dimension/main.unknown_measure', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'status', 'measure' => 'sideways', 'of' => 'estimated_hours' }),
          build('dimension/main.sum_without_of', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'status', 'measure' => 'sum' })
        ]
      end

      # ----------------------------------------------------------------
      # Measures — the numeric CAST and the two visibility-aware joins
      # ----------------------------------------------------------------
      def measure_cases
        cases = [
          build('measure/main.sum_estimated', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'status', 'measure' => 'sum', 'of' => 'estimated_hours' }),
          build('measure/main.avg_estimated', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'tracker', 'measure' => 'avg', 'of' => 'estimated_hours' }),
          build('measure/main.sum_done_ratio', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'status', 'measure' => 'sum', 'of' => 'done_ratio' }),
          build('measure/main.avg_done_ratio', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'status', 'measure' => 'avg', 'of' => 'done_ratio' }),
          build('measure/main.distinct_assignee', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'tracker', 'measure' => 'distinct', 'of' => 'assignee' }),
          build('measure/main.distinct_issue', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'tracker', 'measure' => 'distinct', 'of' => 'issue' }),
          build('measure/main.sum_cf_points', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'tracker', 'measure' => 'sum', 'of' => "cf_#{CF_POINTS}" }),
          build('measure/main.avg_cf_points', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'tracker', 'measure' => 'avg', 'of' => "cf_#{CF_POINTS}" }),
          # A non-additive measure over a COLLAPSED bucket: the Other bucket gets its
          # own aggregate, and the crosstab row is recounted rather than added up.
          build('measure/main.avg_estimated.collapsed', 'dimension_breakdown', 'main', 'manager',
                { 'group_by' => 'priority', 'sort' => 'label', 'limit' => 1,
                  'measure' => 'avg', 'of' => 'estimated_hours' }),
          build('measure/main.distinct_assignee.collapsed_crosstab', 'dimension_breakdown', 'main',
                'manager',
                { 'group_by' => 'status', 'split_by' => 'tracker', 'sort' => 'count',
                  'limit' => 1, 'measure' => 'distinct', 'of' => 'assignee' })
        ]

        # spent_hours and cf_SALARY are the two actor-dependent measures. Both under
        # every actor: this is the value-level INV-1 evidence.
        cases += ACTORS.flat_map do |actor|
          [build("measure/reported.sum_spent_hours.#{actor}", 'dimension_breakdown', 'reported',
                 actor,
                 { 'group_by' => 'status', 'measure' => 'sum', 'of' => 'spent_hours' }),
           build("measure/main.sum_cf_salary.#{actor}", 'dimension_breakdown', 'main', actor,
                 { 'group_by' => 'tracker', 'measure' => 'sum', 'of' => "cf_#{CF_SALARY}" }),
           build("measure/wide.sum_cf_salary.#{actor}", 'dimension_breakdown', 'wide', actor,
                 { 'group_by' => 'tracker', 'measure' => 'sum', 'of' => "cf_#{CF_SALARY}" })]
        end

        cases + [
          build('measure/empty.sum_estimated', 'dimension_breakdown', 'empty', 'manager',
                { 'group_by' => 'status', 'measure' => 'sum', 'of' => 'estimated_hours' }),
          build('measure/empty.avg_estimated', 'dimension_breakdown', 'empty', 'manager',
                { 'group_by' => 'status', 'measure' => 'avg', 'of' => 'estimated_hours' })
        ]
      end

      # ----------------------------------------------------------------
      # The caps — each AT the boundary and one PAST it
      # ----------------------------------------------------------------
      #
      # Three of the four caps CLAMP rather than refuse, which means the "one past"
      # case must return exactly what the "at" case returns. That equality is
      # asserted by the verifier, not just recorded: a cap that stops clamping would
      # otherwise show up as two records that both changed, which reads like a
      # fixture problem rather than like a broken limit.
      def cap_cases
        [
          # 200 dimension keys. `wide` holds 260 distinct values.
          build('cap/keys.wide.limit0', 'dimension_breakdown', 'wide', 'manager',
                { 'group_by' => "cf_#{CF_WIDE}", 'sort' => 'label', 'limit' => 0 }),
          build('cap/keys.wide.below', 'dimension_breakdown', 'wide', 'manager',
                { 'group_by' => "cf_#{CF_WIDE}", 'sort' => 'label',
                  'limit' => CAP_DIMENSION_KEYS - 1 }),
          build('cap/keys.wide.at', 'dimension_breakdown', 'wide', 'manager',
                { 'group_by' => "cf_#{CF_WIDE}", 'sort' => 'label',
                  'limit' => CAP_DIMENSION_KEYS }),
          build('cap/keys.wide.past', 'dimension_breakdown', 'wide', 'manager',
                { 'group_by' => "cf_#{CF_WIDE}", 'sort' => 'label',
                  'limit' => CAP_DIMENSION_KEYS + 1 }),
          # Exactly 200 distinct values in scope: the axis lands ON the cap with no
          # Other bucket at all, which is the boundary the other four approach.
          build('cap/keys.at_cap_scope', 'dimension_breakdown', 'wide_at_cap', 'manager',
                { 'group_by' => "cf_#{CF_WIDE}", 'sort' => 'label',
                  'limit' => CAP_DIMENSION_KEYS }),

          # 24 age buckets. 24 bounds -> 25 buckets; the 25th bound is dropped.
          build('cap/age.at', 'dimension_breakdown', 'wide', 'manager',
                { 'group_by' => 'age', 'age_buckets' => AGE_BOUNDS_AT_CAP }),
          build('cap/age.past', 'dimension_breakdown', 'wide', 'manager',
                { 'group_by' => 'age', 'age_buckets' => AGE_BOUNDS_PAST_CAP }),

          # 24 periods for period: month — sanitize_periods clamps the 25th.
          build('cap/periods.month.at', 'aggregate', 'sweep', 'manager',
                { 'period' => 'month', 'periods' => 24 }),
          build('cap/periods.month.past', 'aggregate', 'sweep', 'manager',
                { 'period' => 'month', 'periods' => 25 }),

          # 5 000 crosstab cells. 200 rows x 25 day-periods is the cap exactly;
          # 201 rows (200 keys + Other) x 25 is one row past it. The cap itself
          # (MAX_DRILL_CELLS) lives in the Liquid tag, not in the kernel — what is
          # frozen here is the GRID that feeds it, which is what a re-seam can change.
          #
          # The series is `period`, not `age`, and that is deliberate: 25 age buckets
          # would need 24 boundaries, and a 24-boundary age CASE is the one shape the
          # MySQL family gets wrong today (see spec/golden/adapter_overlay.rb). A cell
          # -count boundary built on a broken dimension would measure the defect
          # rather than the cap.
          build('cap/cells.at', 'dimension_breakdown', 'wide_at_cap', 'manager',
                { 'group_by' => "cf_#{CF_WIDE}", 'sort' => 'label',
                  'limit' => CAP_DIMENSION_KEYS, 'split_by' => 'period',
                  'period' => 'day', 'periods' => 25 }),
          build('cap/cells.past', 'dimension_breakdown', 'wide', 'manager',
                { 'group_by' => "cf_#{CF_WIDE}", 'sort' => 'label', 'limit' => 0,
                  'split_by' => 'period', 'period' => 'day', 'periods' => 25 })
        ]
      end

      # ----------------------------------------------------------------
      # .completeness — the 12-field cap REFUSES rather than clamps
      # ----------------------------------------------------------------
      def completeness_cases
        at_cap   = CORE_COMPLETENESS + ["cf_#{CF_DEPARTMENT}", "cf_#{CF_POINTS}",
                                        "cf_#{CF_COST}", "cf_#{CF_SALARY}"]
        past_cap = at_cap + ["cf_#{CF_WIDE}"]

        cases = [
          build('completeness/main.one', 'completeness', 'main', 'manager',
                { 'fields' => ['due_date'] }),
          build('completeness/main.five', 'completeness', 'main', 'manager',
                { 'fields' => ['due_date', 'assignee', 'description', "cf_#{CF_DEPARTMENT}",
                               "cf_#{CF_POINTS}"] }),
          build('completeness/main.aliases', 'completeness', 'main', 'manager',
                { 'fields' => %w[assignee category version parent due start estimated] }),
          build('completeness/main.at_cap', 'completeness', 'main', 'manager',
                { 'fields' => at_cap }),
          build('completeness/main.past_cap', 'completeness', 'main', 'manager',
                { 'fields' => past_cap }),
          build('completeness/main.order_preserved', 'completeness', 'main', 'manager',
                { 'fields' => %w[description due_date] }),
          build('completeness/reported.restricted_cf', 'completeness', 'reported', 'manager',
                { 'fields' => ["cf_#{CF_COST}", "cf_#{CF_DEPARTMENT}"] }),
          build('completeness/main.hidden_cf', 'completeness', 'main', 'manager',
                { 'fields' => ["cf_#{CF_HIDDEN}"] }),
          build('completeness/main.no_fields', 'completeness', 'main', 'manager',
                { 'fields' => [] }),
          build('completeness/main.unknown_field', 'completeness', 'main', 'manager',
                { 'fields' => ['sideways'] }),
          build('completeness/empty.three', 'completeness', 'empty', 'manager',
                { 'fields' => %w[due_date assignee description] })
        ]

        # The role-restricted field again, twice per actor, because .completeness has
        # TWO refusal behaviours and the difference between them is worth freezing:
        #
        #   alone          every field refused -> nil, the honest "you may not see
        #                  this" answer
        #   with a field   the refused field is DROPPED and the rest is reported, so
        #                  an unentitled viewer gets a chart that is silently one
        #                  bucket short. Pre-existing, documented here rather than
        #                  changed: the kernel is frozen byte for byte by G7.
        cases + ACTORS.flat_map do |actor|
          [build("completeness/main.cf_salary.#{actor}", 'completeness', 'main', actor,
                 { 'fields' => ["cf_#{CF_SALARY}"] }),
           build("completeness/main.cf_salary_and_due.#{actor}", 'completeness', 'main', actor,
                 { 'fields' => ["cf_#{CF_SALARY}", 'due_date'] })]
        end
      end

      # ----------------------------------------------------------------
      # .flags — the scalars, MIN/MAX and the portable percentile
      # ----------------------------------------------------------------
      def flags_cases
        [
          build('flags/main.default', 'flags', 'main', 'manager', {}),
          build('flags/main.closed_named', 'flags', 'main', 'manager',
                { 'closed_statuses' => ['Closed'] }),
          build('flags/main.closed_two', 'flags', 'main', 'manager',
                { 'closed_statuses' => %w[Closed Rejected] }),
          build('flags/main.closed_unknown', 'flags', 'main', 'manager',
                { 'closed_statuses' => ['No Such Status'] }),
          build('flags/reported.default', 'flags', 'reported', 'manager', {}),
          build('flags/wide.default', 'flags', 'wide', 'manager', {}),
          # Nothing open: both percentiles are nil, which is not the same answer as 0.
          build('flags/closed_only.default', 'flags', 'closed_only', 'manager', {}),
          build('flags/empty.default', 'flags', 'empty', 'manager', {})
        ] + ACTORS.map do |actor|
          # Actor-invariant, like .aggregate, and asserted to be.
          build("flags/main.actor_#{actor}", 'flags', 'main', actor, {})
        end
      end

      # ----------------------------------------------------------------
      # .version_rollup
      # ----------------------------------------------------------------
      #
      # normalise: :sort_version_rows on every case. FINDING, like .breakdown's: the
      # rows come out in `totals.keys` order, and `totals` is an unordered GROUP BY,
      # so the row order is whatever the engine returns. Recorded sorted by
      # version_id (nil last) so a value regression is still caught while an engine's
      # row order cannot make the corpus fail.
      def version_rollup_cases
        cases = [
          build('rollup/main.no_cost', 'version_rollup', 'main', 'manager', {},
                normalise: :sort_version_rows),
          build('rollup/main.cost', 'version_rollup', 'main', 'manager',
                { 'cost_field_ids' => [CF_COST] }, normalise: :sort_version_rows),
          build('rollup/main.cost_two', 'version_rollup', 'main', 'manager',
                { 'cost_field_ids' => [CF_COST, CF_SALARY] }, normalise: :sort_version_rows),
          build('rollup/main.cost_hidden', 'version_rollup', 'main', 'manager',
                { 'cost_field_ids' => [CF_HIDDEN] }, normalise: :sort_version_rows),
          build('rollup/main.cost_absent', 'version_rollup', 'main', 'manager',
                { 'cost_field_ids' => [9999] }, normalise: :sort_version_rows),
          build('rollup/main.closed_named', 'version_rollup', 'main', 'manager',
                { 'closed_statuses' => ['Closed'], 'cost_field_ids' => [CF_COST] },
                normalise: :sort_version_rows),
          build('rollup/main.closed_unknown', 'version_rollup', 'main', 'manager',
                { 'closed_statuses' => ['No Such Status'] }, normalise: :sort_version_rows),
          # The archived project rolls up under a nil version, and its 40 spent hours
          # are invisible: the nil row is a real row, not a placeholder.
          build('rollup/reported.default', 'version_rollup', 'reported', 'manager', {},
                normalise: :sort_version_rows),
          build('rollup/empty.default', 'version_rollup', 'empty', 'manager', {},
                normalise: :sort_version_rows)
        ]

        cases + ACTORS.map do |actor|
          build("rollup/main.cost_salary.#{actor}", 'version_rollup', 'main', actor,
                { 'cost_field_ids' => [CF_SALARY] }, normalise: :sort_version_rows)
        end
      end
    end
  end
end
