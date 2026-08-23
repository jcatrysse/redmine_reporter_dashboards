# frozen_string_literal: true
#
# T-03, the measured half: the performance baseline artefact.
#
# OPT-IN. It seeds 100 000 issues and executes several hundred aggregations, which has
# no business in the ordinary adapter run, so nothing here happens without RRD_BENCH=1.
# The three criteria that ARE assertions live in performance_invariants_spec.rb and run
# every time.
#
#   # measure and report against the committed baseline
#   RRD_BENCH=1 RRD_REFERENCE_DATE=2025-12-29 \
#     RRD_ADAPTER_URL=postgres://redmine:redmine@localhost/redmine_adapter_test \
#     bundle exec rspec -I plugins/redmine_reporter_dashboards/spec \
#                          plugins/redmine_reporter_dashboards/spec/adapter/performance_baseline_spec.rb
#
#   # ...and overwrite it
#   RRD_BENCH=1 RRD_BENCH_WRITE=1 RRD_REFERENCE_DATE=2025-12-29 ... same command
#
# WHAT THIS FILE DOES NOT DO, and will not be made to do: assert a timing. There is no
# committed tolerance — `functional-spec.md` §R7 says the tolerance is a curator
# decision and labels the numeric target as a `[GAP]` — so a red/green verdict on a
# millisecond figure would be a number this project invented, on a runner whose CPU it
# does not control. The drift report below is printed and labelled ADVISORY. Turning it
# into a gate is a curator decision plus a tolerance, in that order.

require_relative 'adapter_helper'
require_relative '../golden/performance'
require_relative '../golden/performance_cases'

# The measurement itself, memoised at module level so every example reads ONE run.
# Examples must not each re-measure: 621 aggregations is minutes, and two examples
# disagreeing because they timed different runs is exactly the kind of flake that gets
# a performance suite switched off.
module RrdBenchRun
  PERF  = RrdGolden::Performance
  CASES = RrdGolden::PerformanceCases

  class << self
    def cells
      @cells ||= measure_all
    end

    def provenance
      @provenance ||= PERF.build_provenance(
        adapter:        RrdAdapterHarness.adapter_name,
        server_version: server_version,
        cpu_model:      PERF.cpu_model,
        cpu_count:      PERF.cpu_count
      )
    end

    def server_version
      ActiveRecord::Base.connection.select_value(
        RrdAdapterHarness.postgresql? ? 'SHOW server_version' : 'SELECT VERSION()'
      ).to_s
    end

    def measure_all
      CASES.aggregation_cells.map do |cell|
        measure(cell['workload'], cell['issues'])
      end
    end

    def measure(workload, issues)
      # Discarded runs first, and their result is what the shape fields are read off:
      # the last kept run would do just as well, but reading them here makes it
      # explicit that the kept samples are timings and nothing else.
      shape = nil
      PERF::DISCARDED_RUNS.times { shape = invoke(workload, issues) }

      # Outside the timed runs: subscribing to sql.active_record costs something, and
      # it would be paid by the measurement rather than by the workload.
      queries = RrdAdapterHarness.count_queries { invoke(workload, issues) }.length

      samples = Array.new(PERF.runs) do
        started = monotonic_ms
        invoke(workload, issues)
        monotonic_ms - started
      end

      {
        'cell'        => CASES.cell_id(workload.id, issues),
        'medium'      => CASES::AGGREGATION,
        'template'    => workload.template,
        'workload'    => workload.id,
        'entry'       => workload.entry,
        'actor'       => workload.actor,
        'args'        => workload.args,
        'issues'      => issues,
        'result_size' => PERF.result_size(shape),
        'queries'     => queries,
        'discarded'   => PERF::DISCARDED_RUNS
      }.merge(PERF.statistics(samples))
    end

    def invoke(workload, issues)
      args = workload.args.each_with_object({}) { |(key, value), out| out[key.to_sym] = value }
      RrdAdapterHarness.as_actor(workload.actor) do
        SqlAggregation::QueryAggregator.public_send(
          workload.entry, RrdAdapterHarness.bench_scope(issues), **args
        )
      end
    end

    # Monotonic and unaffected by the frozen fixture clock, which Time.now is not:
    # travel_to stubs Time.now, so a wall-clock timing under the corpus pin would
    # measure zero for everything.
    def monotonic_ms
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
    end

    # Cell-by-cell against the committed artefact. ADVISORY — see the file header.
    def drift_report
      return ['no committed baseline to compare against'] unless PERF.exist?

      committed = PERF.cells.to_h { |cell| [cell['cell'], cell] }
      cells.map do |cell|
        was = committed[cell['cell']]
        next "#{cell['cell']}: new cell, no committed figure" if was.nil?

        ratio = was['p95_ms'].to_f.positive? ? (cell['p95_ms'] / was['p95_ms'].to_f) : nil
        format('%-52s p95 %9.3f -> %9.3f ms  %s', cell['cell'], was['p95_ms'], cell['p95_ms'],
               ratio ? format('x%.2f', ratio) : 'n/a')
      end
    end
  end
end

if !RrdAdapterHarness.configured?
  RSpec.describe 'T-03 performance baseline' do
    it 'is skipped without a database URL' do
      skip RrdAdapterHarness.skip_reason
    end
  end
elsif !RrdGolden::Performance.run?
  RSpec.describe 'T-03 performance baseline' do
    it 'is skipped unless the benchmark is asked for' do
      skip "set #{RrdGolden::Performance::RUN_ENV}=1 to run the performance benchmark — it seeds " \
           '100 000 issues and executes several hundred aggregations, so it is not part of the ' \
           'ordinary adapter run'
    end
  end
elsif !RrdAdapterHarness.reference_date_pinned?
  RSpec.describe 'T-03 performance baseline' do
    it 'refuses to benchmark against an unpinned fixture' do
      skip 'set RRD_REFERENCE_DATE (see RrdGolden::ReferenceDate) before benchmarking: unpinned, ' \
           'the period windows move with the calendar, so two runs measure different amounts of ' \
           'work and the artefact records a difference that is the date rather than the kernel'
    end
  end
else
  RSpec.describe 'T-03 performance baseline' do
    before(:context) do
      RrdAdapterHarness.seed_bench!(RrdGolden::PerformanceCases::ISSUE_COUNTS.max,
                                   seed: RrdGolden::Performance.seed)
    end

    # One measurement, read by every example below. RSpec runs examples in random
    # order, so this cannot live in whichever example happens to go first.
    before { RrdBenchRun.cells }

    it 'seeded the substrate at every declared size' do
      RrdGolden::PerformanceCases::ISSUE_COUNTS.each do |count|
        expect(RrdAdapterHarness.bench_scope(count).count).to eq(count)
      end
    end

    it 'measured exactly the declared aggregation cells' do
      expected = RrdGolden::PerformanceCases.aggregation_cells.map do |cell|
        RrdGolden::PerformanceCases.cell_id(cell['workload'].id, cell['issues'])
      end

      expect(RrdBenchRun.cells.map { |cell| cell['cell'] }).to eq(expected)
    end

    it 'gave every cell a full set of statistics' do
      RrdBenchRun.cells.each do |cell|
        expect(cell.keys).to include('p50_ms', 'p95_ms', 'max_ms', 'stddev_ms', 'dispersion', 'valid')
        expect(cell['p95_ms']).to be >= cell['p50_ms']
        expect(cell['max_ms']).to be >= cell['p95_ms']
      end
    end

    # The dispersion rule, made visible rather than silent. An invalid cell is not a
    # failure — a noisy runner is a fact about the runner — but it must be NAMED, or a
    # reader averages it into a conclusion it cannot support.
    it 'names every cell whose dispersion makes it unusable' do
      invalid = RrdBenchRun.cells.reject { |cell| cell['valid'] }

      warn "\nINVALID CELLS (stddev/p50 > #{RrdGolden::Performance::INVALID_DISPERSION}) — " \
           "their numbers are recorded, not averaged away:\n" +
           invalid.map { |c| "  #{c['cell']}  dispersion #{c['dispersion']}" }.join("\n")
      expect(invalid.length).to be <= RrdBenchRun.cells.length
    end

    it 'reports drift against the committed baseline (ADVISORY, not a gate)' do
      warn "\nADVISORY — non-deterministic, not a correctness guarantee:\n" +
           RrdBenchRun.drift_report.map { |line| "  #{line}" }.join("\n")
    end

    context 'when asked to write the artefact' do
      it 'writes the baseline, or explains why it did not' do
        unless RrdGolden::Performance.write?
          skip "set #{RrdGolden::Performance::WRITE_ENV}=1 to overwrite the committed baseline"
        end

        document = RrdGolden::Performance.save(RrdBenchRun.cells, provenance: RrdBenchRun.provenance)

        expect(document['cells'].length).to eq(RrdGolden::PerformanceCases.aggregation_cells.length)
        # Every declared-but-unmeasurable cell is written down as blocked with the task
        # that owes it. A baseline that simply omitted HTML and PDF would read as
        # coverage it does not have.
        expect(document['blocked'].length).to eq(RrdGolden::PerformanceCases.render_cells.length)
      end
    end
  end
end
