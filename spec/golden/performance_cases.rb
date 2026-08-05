# frozen_string_literal: true

module RrdGolden
  # THE MATRIX the performance baseline measures, as data.
  #
  # T-03 exists to convert R7 from unfalsifiable to relative: "fast, efficient,
  # good-looking" carries no number, so `functional-spec.md` §R7 replaces it with a
  # baseline measured *before* the aggregator is touched, plus three absolute criteria
  # that need no target at all. This file is the axis declaration for the first half.
  #
  # Inert on purpose — no ActiveRecord, no aggregator, no database — so the shape of
  # the matrix and the arithmetic over it can be asserted in the DB-less spec run on
  # every supported Redmine (performance_spec.rb), exactly as corpus_cases.rb is.
  #
  # --- The axes ---
  #
  #   medium       AGGREGATION | HTML | PDF. Only the first is measurable in this
  #                repository today; see BLOCKED_MEDIA and Performance.blocked_cells.
  #   template     the two reference templates, plus PRODUCTION_SHAPES — see below.
  #   issue count  1 000 / 10 000 / 100 000, taken as id-range slices of one seeded
  #                substrate so the three counts are the same data at three sizes and
  #                not three different fixtures.
  #
  # --- Why there is a third "template" ---
  #
  # The Accept list says "per reference template", and the two reference templates
  # between them reach exactly two of the kernel's six entry points: `sql_aggregate
  # group_by: status` (which the tag routes to `.breakdown`) and `version_rollup`.
  # T-07 and T-08 re-seam all six. A baseline over two of them would go stale the
  # moment the re-seam touched the other four, and there would be no way back to it —
  # that is the whole reason this task must precede the aggregator changing.
  #
  # PRODUCTION_SHAPES is therefore a deliberate WIDENING of the declared axis, and it
  # is labelled as one rather than folded in silently: its workloads are the shapes
  # T-02's survey found in the 26 real templates (10 period charts, 3 flag funnels, 2
  # completeness panels, custom-field pareto, aging with `age_buckets: "30;60;90;180"`,
  # status x period heatmaps). Every workload names the survey line it comes from.
  module PerformanceCases
    # Custom field ids, as spelled by the adapter harness fixture. Repeated here
    # rather than required, because this file must stay inert (see the header) — and
    # the verifier asserts the two agree.
    CF_DEPARTMENT = 10
    CF_POINTS     = 11
    CF_WIDE       = 16

    AGGREGATION = 'aggregation'
    HTML        = 'html'
    PDF         = 'pdf'

    MEDIA = [AGGREGATION, HTML, PDF].freeze

    # HTML and PDF cannot be measured from this repository, and that is a fact about
    # the tree rather than a decision:
    #
    #   * the only Liquid renderer today is redmine_reporter's, which is a separate
    #     private plugin — T-05 made it optional, T-10..T-15 build the owned render
    #     path, and until then there is nothing here to time;
    #   * there is no PDF engine available to this session, and the curator has said
    #     a running Gotenberg is not something they can provide.
    #
    # So these cells are recorded as BLOCKED in the artefact, with the task that owes
    # them. An unmeasured cell that is written down as unmeasured is a pause point; an
    # unmeasured cell that is simply absent is a baseline quietly claiming coverage it
    # does not have (INV-7 applied to performance rather than to versions).
    BLOCKED_MEDIA = {
      HTML => { 'reason' => 'no Liquid renderer in this plugin yet — the only one today is ' \
                            "redmine_reporter's, which is a separate private plugin",
                'owed_by' => 'T-10' },
      PDF  => { 'reason' => 'no PDF engine reachable from this session (no Gotenberg, no ' \
                            'headless Chromium render path yet)',
                'owed_by' => 'T-10' }
    }.freeze

    # Id-range slices of one substrate. 100 000 is the largest because it is the
    # largest number the Accept list names; nothing here extrapolates past it.
    ISSUE_COUNTS = [1_000, 10_000, 100_000].freeze

    # The counts the ABSOLUTE criteria are checked at. Two orders of magnitude apart,
    # which is what makes "query count independent of issue count" a real question:
    # a count that scaled with rows could not be within 0 of itself across 100x.
    # `technical-spec.md` §3.4 asks for 10 vs 10 000; 100 is used as the small end so
    # every dimension of the fixture still has rows in it at the small size, and the
    # ratio is larger than the one asked for, not smaller.
    INVARIANT_COUNTS = [100, 10_000].freeze

    TEMPLATES = %w[sample-report version-status production-shapes].freeze

    Workload = Struct.new(:id, :template, :entry, :actor, :args, :source, keyword_init: true)

    def self.build(id, template, entry, args, source, actor: 'manager')
      Workload.new(id: id, template: template, entry: entry, actor: actor,
                   args: args, source: source)
    end

    WORKLOADS = [
      # --- reference template 1: docs/plan/reference/example-template-sample-report.liquid
      build('breakdown.status', 'sample-report', 'breakdown',
            { 'group_by' => 'status' },
            'example-template-sample-report.liquid:37 — {% sql_aggregate from: issues, ' \
            'group_by: status %}, which liquid_aggregate_tag routes to .breakdown'),

      # --- reference template 2: docs/plan/reference/example-template-version-status.liquid
      build('version_rollup.costs', 'version-status', 'version_rollup',
            { 'closed_statuses' => %w[Closed Rejected], 'cost_field_ids' => [CF_POINTS] },
            'example-template-version-status.liquid:168 — {% version_rollup from: issues, ' \
            'closed_statuses: ..., cost_fields: ... %}'),

      # --- the four entry points the reference templates never reach, at the shapes
      #     T-02's production survey found. See the header for why these are here.
      build('aggregate.month.12', 'production-shapes', 'aggregate',
            { 'period' => 'month', 'periods' => 12, 'closed_statuses' => %w[Closed Rejected] },
            'T-02 survey: 10 of 26 production templates group_by period; the flow chart is ' \
            'the single most common shape in the corpus of real templates'),

      build('flags.funnel', 'production-shapes', 'flags',
            { 'closed_statuses' => %w[Closed Rejected] },
            'T-02 survey: 3 production templates use group_by: flags'),

      # Seven fields that all RESOLVE. The first version of this workload asked for
      # `assigned_to` and `done_ratio`, neither of which is a completeness field
      # (`assignee` is the alias; done_ratio is not offered at all), so the kernel
      # warned and dropped them and the cell measured a five-field completeness under a
      # seven-field name. EXPECTED_RESULT_SIZE now catches that class of mistake
      # mechanically — a measurement of less work than the declaration claims is worse
      # than no measurement.
      build('completeness.seven', 'production-shapes', 'completeness',
            { 'fields' => ['assignee', 'due_date', 'start_date', 'estimated_hours',
                           'description', 'parent', "cf_#{CF_DEPARTMENT}"] },
            'T-02 survey: 2 production templates use group_by: completeness. Seven fields, ' \
            'one of them a custom field, so the per-field join path is in the measurement'),

      build('dimension.cf_pareto.top12', 'production-shapes', 'dimension_breakdown',
            { 'group_by' => "cf_#{CF_WIDE}", 'sort' => 'count', 'limit' => 12 },
            'T-02 survey: cf_92 / cf_94 / cf_99 pareto charts. cf_WIDE has one distinct ' \
            'value per issue here, so this is also the OTHER-collapse path at 100 000 keys'),

      build('dimension.age.string_bounds', 'production-shapes', 'dimension_breakdown',
            { 'group_by' => 'age', 'age_buckets' => '30;60;90;180' },
            'T-02 survey: every aging template writes age_buckets as the STRING ' \
            '"30;60;90;180" — the same spelling, and the same four boundaries, that ' \
            'trigger defect D-1 on MariaDB'),

      build('dimension.status_x_period', 'production-shapes', 'dimension_breakdown',
            { 'group_by' => 'status', 'split_by' => 'period', 'period' => 'month',
              'periods' => 12 },
            'T-02 survey: the status x period heatmap. The crosstab path, which issues ' \
            'the most queries of any workload here'),

      build('measure.assignee.spent_hours', 'production-shapes', 'dimension_breakdown',
            { 'group_by' => 'assignee', 'measure' => 'sum', 'of' => 'spent_hours' },
            'the time_entries join with TimeEntry.visible_condition in its ON clause — ' \
            'the one workload whose SQL carries a visibility subquery, and the shape ' \
            'MySQL 8 was measured mis-evaluating (see adapter_helper.rb)')
    ].freeze

    # The number of queries each workload may issue, MEASURED rather than guessed.
    #
    # The equality assertion in performance_invariants_spec.rb — same count at 100 and
    # at 10 000 issues — is necessary but not sufficient on its own: a workload issuing
    # one query per BUCKET would still be equal at both sizes whenever the bucket count
    # did not move. So the absolute figure is pinned too, per workload, as a RATCHET:
    # `<=`, so a kernel that gets tighter passes and a kernel that adds a query fails
    # with the workload named.
    #
    # These are the figures measured on PostgreSQL 16 against this fixture, and the
    # baseline artefact carries the same figure per cell so a later reader can see what
    # was true when. A first attempt at this control was ONE global ceiling of 12, and
    # it was wrong on its first run: version_rollup issues 18. Two orders of magnitude
    # of issues later it still issues 18 — it is 11 grouped aggregates, the closed-status
    # lookup, the cost-field resolution and one grouped sum per cost field, none of
    # which scale with rows or with versions — so the finding was that the ceiling was
    # a guess, not that the kernel had an N+1. A number that comes from a measurement
    # says which of those two it is; a number that comes from intuition does not.
    QUERY_BUDGET = {
      'breakdown.status'             => 3,
      'version_rollup.costs'         => 18,
      'aggregate.month.12'           => 7,
      'flags.funnel'                 => 12,
      'completeness.seven'           => 6,
      'dimension.cf_pareto.top12'    => 5,
      'dimension.age.string_bounds'  => 2,
      'dimension.status_x_period'    => 3,
      'measure.assignee.spent_hours' => 5
    }.freeze

    # How much each workload GIVES BACK, measured against the bench fixture at 10 000
    # issues. Pinned for one reason: a timing is only comparable if the amount of work
    # behind it is. A workload that quietly started answering a smaller question would
    # get faster and look like an improvement — which is exactly what happened to the
    # first draft of `completeness.seven` (see its note above), and it took reading the
    # artefact to notice. This turns "the same question" into an assertion.
    #
    # The figure is the shape's own natural size, not the hash's key count — see
    # Performance.result_size: labels for a period series, stages for the flag funnel,
    # buckets for a dimension or a completeness panel, rows for a rollup.
    EXPECTED_RESULT_SIZE = {
      'breakdown.status'             => 4,  # four statuses in the fixture
      'version_rollup.costs'         => 9,  # eight bench versions plus the no-version row
      'aggregate.month.12'           => 12, # one label per requested period
      'flags.funnel'                 => 4,  # FLAG_STAGES; note flags returns buckets: [] by design
      'completeness.seven'           => 7,  # one bucket per RESOLVED field
      'dimension.cf_pareto.top12'    => 13, # limit 12 plus the collapsed Other
      'dimension.age.string_bounds'  => 5,  # four boundaries -> five age ranges
      'dimension.status_x_period'    => 4,  # one crosstab row per status
      'measure.assignee.spent_hours' => 3   # two assignees plus the unassigned bucket
    }.freeze

    # The workloads whose output is bounded by something OTHER than the fixture's own
    # cardinality, with that bound. "Bounded output regardless of input" is only
    # falsifiable here: `breakdown.status` returns four buckets because the fixture has
    # four statuses, and no cap is being tested by that.
    #
    #   cf_pareto  `limit: 12` against 100 000 DISTINCT values — the one workload that
    #              would return one row per issue if the cap came off
    #   age        the bucket set is derived from the four boundaries, not from the
    #              data, so it cannot follow the input at all
    CAPPED_BOUNDS = {
      'dimension.cf_pareto.top12'   => 13,
      'dimension.age.string_bounds' => 5
    }.freeze

    class << self
      def all
        WORKLOADS
      end

      def for_template(template)
        WORKLOADS.select { |w| w.template == template }
      end

      def find(id)
        WORKLOADS.find { |w| w.id == id } ||
          raise(ArgumentError, "no performance workload named #{id.inspect}")
      end

      # One cell per (workload, issue count) at AGGREGATION. The HTML and PDF media
      # are per TEMPLATE, not per workload — a rendered document is one timing, not
      # one per tag in it — so they are enumerated separately.
      def aggregation_cells
        WORKLOADS.flat_map do |workload|
          ISSUE_COUNTS.map { |count| { 'workload' => workload, 'issues' => count } }
        end
      end

      def render_cells
        BLOCKED_MEDIA.keys.flat_map do |medium|
          TEMPLATES.reject { |t| t == 'production-shapes' }.flat_map do |template|
            ISSUE_COUNTS.map { |count| { 'template' => template, 'issues' => count, 'medium' => medium } }
          end
        end
      end

      def cell_id(workload_id, issues, medium = AGGREGATION)
        "#{medium}/#{workload_id}@#{issues}"
      end

      def render_cell_id(template, issues, medium)
        "#{medium}/#{template}@#{issues}"
      end

      # Everything about the matrix a reader can check without a database: which
      # workloads exist and what they ask for. Digested into the artefact so a matrix
      # change without a re-measurement is visible (the corpus does the same with its
      # case list).
      def digest_payload
        WORKLOADS.map do |w|
          { 'id' => w.id, 'template' => w.template, 'entry' => w.entry, 'actor' => w.actor,
            'args' => w.args }
        end
      end

      def digest
        require 'digest'
        require 'json'
        Digest::SHA256.hexdigest(JSON.generate(digest_payload))
      end
    end
  end
end
