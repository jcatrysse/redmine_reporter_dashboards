# frozen_string_literal: true
#
# T-03, the falsifiable half. `functional-spec.md` §R7 splits the performance
# requirement in two, and this file is the part that needs no target:
#
#   * query count independent of issue count (FR-48)
#   * zero issue-object instantiation for an aggregate-only workload
#   * bounded output regardless of input
#
# All three are asserted HARD, on every engine, on every adapter run — not behind
# RRD_BENCH. A timing is noise around a mean and belongs in an artefact
# (performance_baseline_spec.rb); these three are yes-or-no questions about the SQL the
# kernel emits, and the reason T-03 has to precede T-07/T-08 is that a regression in
# any of them is a defect rather than a slowdown someone argues about.
#
# The substrate is 10 000 bench issues (RrdAdapterHarness.seed_bench!), sliced at 100
# and 10 000 — two orders of magnitude, which is what makes "independent of issue
# count" a real question. `technical-spec.md` §3.4 asks for 10 vs 10 000; 100 is used
# as the small end so every dimension still has rows in it there, so the ratio is
# larger than the one asked for rather than smaller.

require_relative 'adapter_helper'
require_relative '../golden/performance'
require_relative '../golden/performance_cases'

# The run's instrumentation, at top level rather than inside the example group: RSpec
# class_evals a describe block, so a constant defined in one lands on an anonymous
# class and reads as a constant definition in a block to every linter.
module RrdPerfInvariants
  CASES = RrdGolden::PerformanceCases
  SMALL = CASES::INVARIANT_COUNTS.min
  LARGE = CASES::INVARIANT_COUNTS.max

  class << self
    # The instrumentation itself lives on the harness, so this spec and the benchmark
    # share one definition of "a query" (see RrdAdapterHarness#count_queries).
    def queries(&block)
      RrdAdapterHarness.count_queries(&block)
    end

    def instantiations(class_name, &block)
      RrdAdapterHarness.count_instantiations(class_name, &block)
    end

    # The aggregator called exactly as a caller would, with keyword arguments and an
    # explicit actor (INV-1) — the same shape CorpusGenerator#invoke uses, for the
    # same reason: what is measured has to be the public surface T-07 and T-08 re-seam.
    def invoke(workload, count)
      args = workload.args.each_with_object({}) { |(key, value), out| out[key.to_sym] = value }
      RrdAdapterHarness.as_actor(workload.actor) do
        SqlAggregation::QueryAggregator.public_send(
          workload.entry, RrdAdapterHarness.bench_scope(count), **args
        )
      end
    end

    # Executed once and discarded. The first call to a workload pays for the adapter's
    # prepared statement and the closed-status lookup; counting a warm run against a
    # cold one would report a difference in warmth as a difference in the workload.
    def warm(workload, count)
      invoke(workload, count)
      nil
    end
  end
end

if !RrdAdapterHarness.configured?
  RSpec.describe 'R7 absolute performance criteria' do
    it 'is skipped without a database URL' do
      skip RrdAdapterHarness.skip_reason
    end
  end
else
  RSpec.describe 'R7 absolute performance criteria' do
    run   = RrdPerfInvariants
    cases = RrdPerfInvariants::CASES
    small = RrdPerfInvariants::SMALL
    large = RrdPerfInvariants::LARGE

    before(:context) do
      # Idempotent and monotonic: if the benchmark already seeded 100 000 in this
      # process this is a no-op, and if it seeds later it re-seeds with the same rows
      # for the first 10 000. Neither spec can observe whether the other ran first.
      RrdAdapterHarness.seed_bench!(RrdPerfInvariants::LARGE, seed: RrdGolden::Performance.seed)
    end

    it 'seeded the substrate at both sizes' do
      expect(RrdAdapterHarness.bench_scope(small).count).to eq(small)
      expect(RrdAdapterHarness.bench_scope(large).count).to eq(large)
    end

    it 'declares the same custom field ids as the harness fixture' do
      expect(cases::CF_DEPARTMENT).to eq(RrdAdapterHarness::CF_DEPARTMENT)
      expect(cases::CF_POINTS).to eq(RrdAdapterHarness::CF_POINTS)
      expect(cases::CF_WIDE).to eq(RrdAdapterHarness::CF_WIDE)
    end

    # ----------------------------------------------------------------
    # 1. Query count independent of issue count (FR-48)
    # ----------------------------------------------------------------

    describe 'query count' do
      cases.all.each do |workload|
        it "#{workload.id} issues the same number of queries at #{small} and #{large} issues" do
          run.warm(workload, small)
          run.warm(workload, large)

          at_small = run.queries { run.invoke(workload, small) }
          at_large = run.queries { run.invoke(workload, large) }

          expect(at_large.length).to eq(at_small.length),
                                     lambda {
                                       "#{workload.id}: #{at_small.length} queries at #{small} " \
                                         "issues, #{at_large.length} at #{large}. Query count must " \
                                         "not scale with issue count (FR-48).\n\nat #{small}:\n" \
                                         "#{at_small.join("\n")}\n\nat #{large}:\n#{at_large.join("\n")}"
                                     }
        end
      end

      # The per-workload ratchet. See PerformanceCases::QUERY_BUDGET for why the
      # numbers are measured rather than chosen, and why one global ceiling was the
      # wrong control.
      it 'stays within the measured per-workload query budget' do
        counts = cases.all.to_h do |workload|
          run.warm(workload, large)
          [workload.id, run.queries { run.invoke(workload, large) }.length]
        end

        over = counts.select { |id, n| n > cases::QUERY_BUDGET.fetch(id) }
        expect(over).to eq({}),
                        "over budget: #{over.map { |id, n| "#{id} #{n} > #{cases::QUERY_BUDGET[id]}" }
                                            .join(', ')} (all workloads: #{counts.inspect})"
      end
    end

    # ----------------------------------------------------------------
    # 2. Zero issue-object instantiation
    # ----------------------------------------------------------------

    describe 'issue instantiation' do
      cases.all.each do |workload|
        it "#{workload.id} instantiates no Issue objects over #{large} issues" do
          run.warm(workload, large)

          instantiated = run.instantiations('Issue') { run.invoke(workload, large) }

          expect(instantiated).to eq(0),
                                  "#{workload.id} instantiated #{instantiated} Issue object(s). An " \
                                  'aggregate-only workload must answer from SQL — one object per row ' \
                                  'is the cost R7 exists to keep out (functional-spec.md §R7).'
        end
      end
    end

    # ----------------------------------------------------------------
    # The measurement measures what it says it measures
    # ----------------------------------------------------------------
    #
    # Not one of R7's three criteria, and here because the baseline is worthless
    # without it. A workload that answers a smaller question than it declares gets
    # faster and reads as an improvement: `completeness.seven` originally asked for two
    # field names the kernel does not accept, so it warned, dropped them, and measured
    # a five-field panel under a seven-field name for a whole generation of the
    # artefact. Every entry point here logs-and-degrades on an unusable argument rather
    # than raising, which is right for a template author and silent for a benchmark.

    describe 'result size' do
      cases::EXPECTED_RESULT_SIZE.each do |workload_id, expected|
        it "#{workload_id} answers a question of the declared size (#{expected})" do
          result = run.invoke(cases.find(workload_id), large)

          expect(RrdGolden::Performance.result_size(result)).to eq(expected),
                                                               "#{workload_id} gave back " \
                                                               "#{RrdGolden::Performance.result_size(result).inspect} " \
                                                               "of an expected #{expected}. Either the " \
                                                               'fixture changed or an argument is being ' \
                                                               'dropped with a log line — check the ' \
                                                               'warnings from QueryAggregator.'
        end
      end
    end

    # ----------------------------------------------------------------
    # 3. Bounded output regardless of input
    # ----------------------------------------------------------------

    describe 'bounded output' do
      cases::CAPPED_BOUNDS.each do |workload_id, bound|
        it "#{workload_id} returns at most #{bound} buckets over #{large} issues" do
          buckets = run.invoke(cases.find(workload_id), large)['buckets']

          expect(buckets).to be_an(Array)
          expect(buckets.length).to be <= bound,
                                    "#{workload_id} returned #{buckets.length} buckets, more than " \
                                    "the #{bound} its cap allows"
        end
      end

      # The one that would actually break if the cap were removed: cf_WIDE has one
      # distinct value per issue, so an uncapped group_by returns 10 000 rows here and
      # 100 000 in the benchmark. The bucket count must not move between the sizes.
      it "the pareto axis returns the same bucket count at #{small} and #{large} issues" do
        workload = cases.find('dimension.cf_pareto.top12')

        at_small = run.invoke(workload, small)['buckets'].length
        at_large = run.invoke(workload, large)['buckets'].length

        expect(at_large).to eq(at_small),
                            "the capped axis returned #{at_small} buckets over #{small} issues and " \
                            "#{at_large} over #{large}: the output is following the input"
      end

      # And a bounded output must still account for everything it collapsed, or the
      # cap has turned into silent data loss rather than a bound.
      it 'the collapsed pareto total still equals the issue count' do
        result = run.invoke(cases.find('dimension.cf_pareto.top12'), large)

        expect(result['total']).to eq(large)
        expect(result['buckets'].sum { |bucket| bucket['count'] }).to eq(large)
      end
    end
  end
end
