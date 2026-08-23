# frozen_string_literal: true

require 'digest'
require 'etc'
require 'json'
require_relative 'baseline'
require_relative 'performance_cases'
require_relative 'reference_date'

module RrdGolden
  # The performance baseline: the statistics, the invalid-cell rule, and the artefact.
  #
  # This is NOT an oracle. The golden corpus (Corpus) freezes numbers that must not
  # move and fails when they do; a timing is noise around a mean and a test that
  # asserted one would be red on a busy runner and switched off within a week. What is
  # written down here is a MEASUREMENT with its provenance, so that when T-07 and T-08
  # re-seam the aggregator someone can say by how much it moved and against what.
  #
  # The three things that ARE falsifiable live next to it and are asserted hard, in
  # spec/adapter/performance_invariants_spec.rb, on every engine on every run:
  # query count independent of issue count, zero Issue instantiation, bounded output
  # (functional-spec.md §R7, "Absolute, needing no target").
  #
  # --- Method, written down because a statistic without its method is a number ---
  #
  #   clock        Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond).
  #                Monotonic, so a clock adjustment mid-run cannot produce a negative
  #                sample, and unaffected by the frozen fixture clock.
  #   warm-up      DISCARDED runs are executed and thrown away before the kept ones.
  #                The first call to a workload pays for the adapter's prepared
  #                statement, the connection's type map and the OS page cache; keeping
  #                it would put the cost of the measurement in the measurement.
  #   percentile   NEAREST-RANK on the sorted kept samples: index = ceil(f * n) - 1.
  #                No interpolation, so every reported value is a sample that actually
  #                occurred. p95 of 20 samples is the 19th.
  #   stddev       SAMPLE standard deviation (n-1). These are 20 draws from a
  #                distribution, not the whole population.
  #   invalid      dispersion = stddev / p50. Above INVALID_DISPERSION the cell is
  #                recorded with valid: false and its numbers are kept as measured.
  #                The Accept list is explicit that such a cell is "reported invalid,
  #                not averaged away": deleting it would leave a gap that reads as
  #                coverage, and smoothing it would launder a number nobody can use.
  module Performance
    DIR      = File.expand_path('performance', __dir__)
    BASELINE = File.join(DIR, 'baseline.json')

    # Opt in to running the benchmark at all — it seeds 100 000 issues and executes
    # several hundred aggregations, which has no place in the normal adapter run.
    RUN_ENV = 'RRD_BENCH'
    # ...and opt in again to overwrite the committed artefact.
    WRITE_ENV = 'RRD_BENCH_WRITE'
    # The fixture seed, recorded in the artefact. Overridable so a curator can show a
    # result is not an artefact of one particular data shape.
    SEED_ENV = 'RRD_BENCH_SEED'
    # The runner image digest, which a process cannot discover about itself. Recorded
    # as nil when absent rather than guessed.
    IMAGE_DIGEST_ENV = 'RRD_BENCH_IMAGE_DIGEST'
    # Fewer runs, for shaking the harness out. Cannot produce a committable artefact —
    # see `save`.
    RUNS_ENV = 'RRD_BENCH_RUNS'

    DEFAULT_SEED = 20_251_229

    WARM_RUNS      = 20
    DISCARDED_RUNS = 3

    INVALID_DISPERSION = 0.35

    class Missing < StandardError; end
    class Corrupt < StandardError; end
    class TooFewRuns < StandardError; end

    class << self
      def run?
        flag?(RUN_ENV)
      end

      def write?
        flag?(WRITE_ENV)
      end

      def flag?(name)
        %w[1 true yes].include?(ENV.fetch(name, '').to_s.strip.downcase)
      end

      def seed
        raw = ENV.fetch(SEED_ENV, '').to_s.strip
        raw.match?(/\A\d+\z/) ? raw.to_i : DEFAULT_SEED
      end

      def runs
        raw = ENV.fetch(RUNS_ENV, '').to_s.strip
        raw.match?(/\A[1-9]\d*\z/) ? raw.to_i : WARM_RUNS
      end

      def image_digest
        raw = ENV.fetch(IMAGE_DIGEST_ENV, '').to_s.strip
        raw.empty? ? nil : raw
      end

      def exist?
        File.exist?(BASELINE)
      end

      # ------------------------------------------------------------------
      # Statistics
      # ------------------------------------------------------------------

      # Nearest-rank, 1-indexed rank mapped to a 0-indexed array. f in (0, 1].
      def percentile(samples, fraction)
        raise ArgumentError, 'no samples' if samples.empty?
        unless fraction.positive? && fraction <= 1
          raise ArgumentError, "fraction must be in (0, 1], got #{fraction.inspect}"
        end

        sorted = samples.sort
        rank   = (fraction * sorted.length).ceil
        sorted[rank - 1]
      end

      # Sample standard deviation. Zero for a single sample: with n = 1 there is no
      # dispersion to report, and (n-1) would divide by zero.
      def stddev(samples)
        return 0.0 if samples.length < 2

        mean = samples.sum.to_f / samples.length
        variance = samples.sum { |x| (x - mean)**2 } / (samples.length - 1)
        Math.sqrt(variance)
      end

      # The statistics block of a cell. Rounded to microseconds: a millisecond timing
      # carries no information past the third decimal and the extra digits only make
      # the artefact harder to read.
      def statistics(samples)
        raise ArgumentError, 'no samples' if samples.empty?

        p50 = percentile(samples, 0.5)
        sd  = stddev(samples)
        # p50 of zero would make the dispersion ratio undefined. With a monotonic
        # float-millisecond clock it takes a workload that did nothing, so it is a
        # harness failure rather than a fast cell — recorded as invalid, with the
        # ratio left nil rather than set to something arithmetic-friendly.
        #
        # The validity test reads the RAW ratio and the record carries the rounded one.
        # The other way round, a cell at 0.3504 would round into range and be reported
        # valid on the strength of the rounding — a small laundering, but laundering.
        ratio = p50.positive? ? (sd / p50) : nil
        valid = !ratio.nil? && ratio <= INVALID_DISPERSION

        {
          'runs'       => samples.length,
          'min_ms'     => round_us(samples.min),
          'p50_ms'     => round_us(p50),
          'p95_ms'     => round_us(percentile(samples, 0.95)),
          'max_ms'     => round_us(samples.max),
          'mean_ms'    => round_us(samples.sum.to_f / samples.length),
          'stddev_ms'  => round_us(sd),
          'dispersion' => ratio.nil? ? nil : round_us(ratio),
          'valid'      => valid
        }
      end

      def round_us(value)
        (value.to_f * 1_000).round / 1_000.0
      end

      # How much a workload gave back — recorded per cell so a later reader can see
      # whether a timing changed because the kernel got slower or because it started
      # answering a differently sized question.
      #
      # Shape-aware, and it has to be: `.flags` returns `'buckets' => []` DELIBERATELY
      # (its shape is `stages`, and the empty array is there so a template that loops
      # over buckets renders nothing rather than raising), and `.aggregate` has no
      # buckets at all. A naive `result['buckets'].length` reports the flag funnel as
      # size 0 and the period series as its hash key count, and both readings are
      # wrong in a way nobody would notice in a table of milliseconds.
      def result_size(result)
        case result
        when nil   then nil
        when Array then result.length                # .version_rollup: one row per version
        when Hash
          if result['labels'].is_a?(Array)      then result['labels'].length # .aggregate
          elsif result['stages'].is_a?(Array)   then result['stages'].length # .flags
          elsif result['buckets'].is_a?(Array)  then result['buckets'].length
          else result.keys.length
          end
        end
      end

      # ------------------------------------------------------------------
      # The artefact
      # ------------------------------------------------------------------

      def records
        raise Missing, missing_message unless exist?

        JSON.parse(File.read(BASELINE, encoding: 'UTF-8'))
      end

      def cells
        Array(records['cells'])
      end

      def blocked
        Array(records['blocked'])
      end

      def provenance
        records.fetch('provenance') { raise Corrupt, 'the baseline artefact has no provenance block' }
      end

      def invalid_cells
        cells.reject { |cell| cell['valid'] }
      end

      # The cells that are declared but not measured, with the task that owes them.
      # Generated from PerformanceCases so a medium cannot quietly stop being blocked.
      def blocked_cells
        PerformanceCases.render_cells.map do |cell|
          medium = cell['medium']
          PerformanceCases::BLOCKED_MEDIA.fetch(medium).merge(
            'cell'     => PerformanceCases.render_cell_id(cell['template'], cell['issues'], medium),
            'medium'   => medium,
            'template' => cell['template'],
            'issues'   => cell['issues']
          )
        end
      end

      # `runs` is checked here rather than left to the reader: RRD_BENCH_RUNS exists so
      # the harness can be shaken out in seconds, and the one thing it must not be able
      # to do is produce a committed artefact whose statistics are drawn from three
      # samples. The Accept list says >= 20 warm runs, so this is that sentence made
      # mechanical.
      def save(cells, provenance:)
        thin = cells.select { |cell| cell['runs'].to_i < WARM_RUNS }
        unless thin.empty?
          raise TooFewRuns,
                "refusing to write the baseline: #{thin.length} cell(s) have fewer than " \
                "#{WARM_RUNS} kept runs (e.g. #{thin.first['cell']} with #{thin.first['runs']}). " \
                "#{RUNS_ENV} is for shaking the harness out, not for producing an artefact."
        end

        Dir.mkdir(DIR) unless Dir.exist?(DIR)
        document = {
          'provenance' => provenance,
          'cells'      => cells,
          'blocked'    => blocked_cells
        }
        File.binwrite(BASELINE, "#{JSON.pretty_generate(document)}\n")
        document
      end

      # Everything a later reader needs to decide whether this baseline answers their
      # question. `measured_at` is read off CLOCK_REALTIME rather than Time.now,
      # because the benchmark runs under the corpus's frozen clock and Time.now there
      # would stamp the artefact with the reference date — a plausible-looking lie
      # about when the measurement happened.
      def build_provenance(adapter:, server_version:, cpu_model:, cpu_count:)
        {
          'baseline_commit'          => Baseline::COMMIT,
          'reference_date'           => ReferenceDate.require!.iso8601,
          'time_zone'                => 'UTC',
          'measured_at'              => Time.at(Process.clock_gettime(Process::CLOCK_REALTIME))
                                            .utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
          'seed'                     => seed,
          'runs'                     => runs,
          'discarded_runs'           => DISCARDED_RUNS,
          'percentile_method'        => 'nearest-rank (no interpolation)',
          'stddev_method'            => 'sample (n-1)',
          'clock'                    => 'Process::CLOCK_MONOTONIC, float_millisecond',
          'invalid_dispersion_above' => INVALID_DISPERSION,
          'adapter'                  => adapter.to_s,
          'server_version'           => server_version.to_s,
          'ruby'                     => RUBY_VERSION,
          'rails'                    => (defined?(::Rails::VERSION::STRING) ? ::Rails::VERSION::STRING : nil),
          'active_record'            => (defined?(::ActiveRecord::VERSION::STRING) ? ::ActiveRecord::VERSION::STRING : nil),
          'cpu_model'                => cpu_model,
          'cpu_count'                => cpu_count,
          'runner_image_digest'      => image_digest,
          'workloads'                => PerformanceCases.digest
        }
      end

      # The CPU the numbers were produced on. /proc/cpuinfo is Linux-only and this is
      # provenance rather than behaviour, so an unreadable one is recorded as nil.
      def cpu_model
        line = File.readlines('/proc/cpuinfo', encoding: 'UTF-8').find { |l| l.start_with?('model name') }
        line&.split(':', 2)&.last&.strip
      rescue SystemCallError
        nil
      end

      def cpu_count
        Etc.nprocessors
      rescue StandardError
        nil
      end

      def missing_message
        "the performance baseline is not committed (expected #{BASELINE}). Generate it " \
          "with #{RUN_ENV}=1 #{WRITE_ENV}=1 and RRD_REFERENCE_DATE set, against a database, " \
          'then commit the file.'
      end
    end
  end
end
