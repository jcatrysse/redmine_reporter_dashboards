# frozen_string_literal: true
#
# The DB-less half of T-03: the arithmetic, the matrix, and the committed artefact's
# own consistency. Runs on every supported Redmine in the ordinary spec job, exactly as
# corpus_cases_spec.rb does — the numbers need a database, but "is the baseline internally
# honest" does not, and that is the question that actually goes stale.

require_relative '../spec_helper'
require_relative 'performance'
require_relative 'performance_cases'
require_relative 'corpus_cases'

RSpec.describe RrdGolden::Performance do
  # ----------------------------------------------------------------
  # Percentiles: nearest-rank, no interpolation
  # ----------------------------------------------------------------

  describe '.percentile' do
    let(:twenty) { (1..20).to_a }

    it 'takes the nearest rank rather than interpolating' do
      # ceil(0.95 * 20) = 19 -> the 19th sample. Every reported figure is a sample
      # that actually occurred, which an interpolated percentile cannot promise.
      expect(described_class.percentile(twenty, 0.95)).to eq(19)
      expect(described_class.percentile(twenty, 0.5)).to eq(10)
      expect(described_class.percentile(twenty, 1.0)).to eq(20)
    end

    it 'sorts before ranking, so sample order cannot change the answer' do
      expect(described_class.percentile(twenty.shuffle, 0.95)).to eq(19)
    end

    it 'is the only sample when there is one' do
      expect(described_class.percentile([7.5], 0.95)).to eq(7.5)
    end

    it 'refuses an empty sample set rather than returning nil' do
      expect { described_class.percentile([], 0.5) }.to raise_error(ArgumentError, /no samples/)
    end

    it 'refuses a fraction outside (0, 1]' do
      expect { described_class.percentile(twenty, 0) }.to raise_error(ArgumentError, /\(0, 1\]/)
      expect { described_class.percentile(twenty, 1.5) }.to raise_error(ArgumentError, /\(0, 1\]/)
    end
  end

  describe '.stddev' do
    it 'is the SAMPLE standard deviation, dividing by n-1' do
      # [2, 4, 4, 4, 5, 5, 7, 9]: population sd 2.0, sample sd sqrt(32/7).
      expect(described_class.stddev([2, 4, 4, 4, 5, 5, 7, 9])).to be_within(1e-9).of(Math.sqrt(32.0 / 7))
    end

    it 'is zero for one sample, where n-1 would divide by zero' do
      expect(described_class.stddev([4.2])).to eq(0.0)
    end

    it 'is zero when every sample is identical' do
      expect(described_class.stddev([3.0] * 20)).to eq(0.0)
    end
  end

  # ----------------------------------------------------------------
  # The invalid-cell rule — AT the limit and one past it
  # ----------------------------------------------------------------

  describe '.statistics' do
    # Two samples with a chosen ratio: p50 of [a, b] is a (nearest rank, ceil(1) = 1),
    # and the sample sd of two values is |b - a| / sqrt(2).
    def pair_with_dispersion(target)
      a = 100.0
      b = a + (target * a * Math.sqrt(2))
      [a, b]
    end

    it 'is valid AT the dispersion limit' do
      stats = described_class.statistics(pair_with_dispersion(described_class::INVALID_DISPERSION))

      expect(stats['dispersion']).to be_within(1e-6).of(described_class::INVALID_DISPERSION)
      expect(stats['valid']).to be(true)
    end

    it 'is invalid one step past the dispersion limit' do
      stats = described_class.statistics(pair_with_dispersion(described_class::INVALID_DISPERSION + 0.01))

      expect(stats['valid']).to be(false)
    end

    it 'reads validity off the raw ratio, not the rounded one' do
      # 0.3504 rounds to 0.35 at microsecond precision. If the comparison ran on the
      # rounded figure this cell would be reported valid on the strength of the
      # rounding.
      stats = described_class.statistics(pair_with_dispersion(0.3504))

      expect(stats['dispersion']).to eq(0.35)
      expect(stats['valid']).to be(false)
    end

    it 'keeps an invalid cell\'s numbers rather than dropping or smoothing them' do
      samples = pair_with_dispersion(2.0)
      stats   = described_class.statistics(samples)

      expect(stats['valid']).to be(false)
      expect(stats['p50_ms']).to eq(described_class.round_us(samples.min))
      expect(stats['max_ms']).to eq(described_class.round_us(samples.max))
      expect(stats['runs']).to eq(2)
    end

    it 'reports a zero p50 as invalid with no dispersion figure' do
      stats = described_class.statistics([0.0, 0.0])

      expect(stats['dispersion']).to be_nil
      expect(stats['valid']).to be(false)
    end

    it 'orders min <= p50 <= p95 <= max for any sample set' do
      stats = described_class.statistics([9.0, 1.0, 5.0, 3.0, 7.0])

      expect(stats['min_ms']).to be <= stats['p50_ms']
      expect(stats['p50_ms']).to be <= stats['p95_ms']
      expect(stats['p95_ms']).to be <= stats['max_ms']
    end

    it 'refuses an empty sample set' do
      expect { described_class.statistics([]) }.to raise_error(ArgumentError, /no samples/)
    end
  end

  # ----------------------------------------------------------------
  # The write guard
  # ----------------------------------------------------------------

  describe '.save' do
    let(:thin_cell) do
      { 'cell' => 'aggregation/breakdown.status@1000', 'runs' => 3, 'p50_ms' => 1.0 }
    end

    it 'refuses to write an artefact whose cells were measured too few times' do
      before_bytes = File.exist?(described_class::BASELINE) ? File.binread(described_class::BASELINE) : nil

      expect { described_class.save([thin_cell], provenance: {}) }
        .to raise_error(described_class::TooFewRuns, /fewer than #{described_class::WARM_RUNS}/)

      # The refusal has to happen BEFORE the write, or the guard only reports damage.
      after_bytes = File.exist?(described_class::BASELINE) ? File.binread(described_class::BASELINE) : nil
      expect(after_bytes).to eq(before_bytes)
    end

    it 'names the offending cell, so the message is actionable' do
      expect { described_class.save([thin_cell], provenance: {}) }
        .to raise_error(described_class::TooFewRuns, /breakdown\.status@1000/)
    end
  end

  # Real environment variables, set and restored, rather than a stub on ENV.fetch:
  # everything in this process reads ENV, and a partial double on it would fail the
  # next unrelated lookup.
  describe 'environment handling' do
    around do |example|
      saved = ENV.to_hash.slice(described_class::SEED_ENV, described_class::IMAGE_DIGEST_ENV,
                                described_class::RUNS_ENV)
      example.run
    ensure
      [described_class::SEED_ENV, described_class::IMAGE_DIGEST_ENV,
       described_class::RUNS_ENV].each { |key| ENV.delete(key) }
      saved.each { |key, value| ENV[key] = value }
    end

    it 'falls back to the recorded default seed when the seed variable is absent' do
      ENV.delete(described_class::SEED_ENV)

      expect(described_class.seed).to eq(described_class::DEFAULT_SEED)
    end

    it 'falls back to the default rather than to zero when the seed is not a number' do
      ENV[described_class::SEED_ENV] = 'yesterday'

      expect(described_class.seed).to eq(described_class::DEFAULT_SEED)
    end

    it 'uses a given numeric seed' do
      ENV[described_class::SEED_ENV] = '4242'

      expect(described_class.seed).to eq(4242)
    end

    it 'reports no runner image digest rather than inventing one' do
      ENV[described_class::IMAGE_DIGEST_ENV] = '   '

      expect(described_class.image_digest).to be_nil
    end

    it 'records the runner image digest when the runner supplies one' do
      ENV[described_class::IMAGE_DIGEST_ENV] = 'sha256:abc123'

      expect(described_class.image_digest).to eq('sha256:abc123')
    end

    it 'defaults the run count to the required number of warm runs' do
      ENV.delete(described_class::RUNS_ENV)

      expect(described_class.runs).to eq(described_class::WARM_RUNS)
    end

    it 'accepts a smaller run count for shaking the harness out' do
      ENV[described_class::RUNS_ENV] = '3'

      expect(described_class.runs).to eq(3)
    end

    it 'refuses a zero run count, which would produce statistics over nothing' do
      ENV[described_class::RUNS_ENV] = '0'

      expect(described_class.runs).to eq(described_class::WARM_RUNS)
    end
  end

  # ----------------------------------------------------------------
  # The committed artefact
  # ----------------------------------------------------------------

  describe 'the committed baseline' do
    it 'is committed' do
      expect(described_class.exist?).to be(true), described_class.missing_message
    end

    it 'carries the provenance a later reader needs' do
      expect(described_class.provenance.keys).to include(
        'baseline_commit', 'reference_date', 'time_zone', 'measured_at', 'seed', 'runs',
        'discarded_runs', 'percentile_method', 'stddev_method', 'clock',
        'invalid_dispersion_above', 'adapter', 'server_version', 'ruby', 'rails',
        'cpu_model', 'cpu_count', 'runner_image_digest', 'workloads'
      )
    end

    it 'was measured over at least the required number of warm runs' do
      expect(described_class.provenance['runs']).to be >= described_class::WARM_RUNS
      described_class.cells.each do |cell|
        expect(cell['runs']).to be >= described_class::WARM_RUNS, "#{cell['cell']} has #{cell['runs']} runs"
      end
    end

    it 'names the reference date and zone the fixture was pinned to' do
      expect(described_class.provenance['reference_date']).to match(/\A\d{4}-\d{2}-\d{2}\z/)
      expect(described_class.provenance['time_zone']).to eq('UTC')
    end

    it 'was measured against the byte-identity baseline commit' do
      expect(described_class.provenance['baseline_commit']).to eq(RrdGolden::Baseline::COMMIT)
    end

    # The same guard the corpus manifest carries for its case list. A widened matrix
    # with an unchanged artefact is a baseline describing a different set of questions
    # than the one someone will compare against.
    it 'was measured against the committed workload matrix' do
      expect(described_class.provenance['workloads']).to eq(RrdGolden::PerformanceCases.digest),
                                                        'the workload matrix changed without the ' \
                                                        'baseline being re-measured — see ' \
                                                        'spec/golden/README.md'
    end

    it 'holds exactly one cell per declared (workload, issue count)' do
      expected = RrdGolden::PerformanceCases.aggregation_cells.map do |cell|
        RrdGolden::PerformanceCases.cell_id(cell['workload'].id, cell['issues'])
      end

      expect(described_class.cells.map { |cell| cell['cell'] }).to eq(expected)
    end

    it 'records the fixture seed it was generated from' do
      expect(described_class.provenance['seed']).to be_a(Integer)
    end

    # The pause point, made mechanical. HTML and PDF are declared axes that cannot be
    # measured from this repository, and the artefact says so rather than omitting them
    # — INV-7's rule applied to performance: an unmeasured configuration is unmeasured,
    # not fast.
    it 'declares every unmeasurable render cell as blocked, with the task that owes it' do
      blocked = described_class.blocked

      expect(blocked.length).to eq(RrdGolden::PerformanceCases.render_cells.length)
      expect(blocked.map { |cell| cell['medium'] }.uniq.sort).to eq(%w[html pdf])
      blocked.each do |cell|
        expect(cell['reason']).to be_a(String)
        expect(cell['reason']).not_to be_empty
        expect(cell['owed_by']).to match(/\AT-\d\d\z/)
      end
    end

    it 'measures no cell in a medium it also declares blocked' do
      measured = described_class.cells.map { |cell| cell['medium'] }.uniq

      expect(measured).to eq([RrdGolden::PerformanceCases::AGGREGATION])
    end
  end
end

RSpec.describe RrdGolden::PerformanceCases do
  it 'has a unique id per workload' do
    ids = described_class.all.map(&:id)

    expect(ids.uniq.length).to eq(ids.length)
  end

  it 'names only entry points the kernel actually exposes' do
    expect(described_class.all.map(&:entry).uniq - RrdGolden::CorpusCases::ENTRY_POINTS).to eq([])
  end

  it 'assigns every workload to a declared template' do
    expect(described_class.all.map(&:template).uniq - described_class::TEMPLATES).to eq([])
  end

  it 'leaves no declared template without a workload' do
    described_class::TEMPLATES.each do |template|
      expect(described_class.for_template(template)).not_to be_empty, "#{template} has no workload"
    end
  end

  # The reason the third "template" exists at all. If the two reference templates ever
  # grow to cover the whole surface this can go; until then the baseline has to say out
  # loud that it is measuring more than the Accept list's axis, not less.
  it 'covers all six entry points the re-seam touches, which the reference templates do not' do
    reference = described_class.all.reject { |w| w.template == 'production-shapes' }

    expect(reference.map(&:entry).uniq.sort).to eq(%w[breakdown version_rollup])
    expect(described_class.all.map(&:entry).uniq.sort).to eq(RrdGolden::CorpusCases::ENTRY_POINTS.sort)
  end

  it 'says where every workload came from' do
    described_class.all.each do |workload|
      expect(workload.source).to be_a(String), "#{workload.id} has no source"
      expect(workload.source.length).to be > 20, "#{workload.id}'s source says nothing"
    end
  end

  it 'writes the production age boundaries the way the real templates write them' do
    aging = described_class.find('dimension.age.string_bounds')

    # A STRING, not an Array. T-02's survey found every real template spelling it this
    # way, and it is the spelling that triggers defect D-1 on MariaDB.
    expect(aging.args['age_buckets']).to eq('30;60;90;180')
  end

  # A new workload with no budget entry would pass the query-count spec by accident —
  # `QUERY_BUDGET.fetch` would raise there, but only on a machine with a database. This
  # catches it in the DB-less run instead.
  it 'gives every workload a measured query budget' do
    expect(described_class.all.map(&:id) - described_class::QUERY_BUDGET.keys).to eq([])
  end

  it 'has no query budget for a workload that no longer exists' do
    expect(described_class::QUERY_BUDGET.keys - described_class.all.map(&:id)).to eq([])
  end

  it 'declares the size of the answer every workload is supposed to give back' do
    expect(described_class.all.map(&:id).sort).to eq(described_class::EXPECTED_RESULT_SIZE.keys.sort)
  end

  it 'bounds only workloads that have a cap to be bounded by' do
    described_class::CAPPED_BOUNDS.each_key do |id|
      expect { described_class.find(id) }.not_to raise_error
    end
  end

  it 'measures three issue counts, two orders of magnitude apart' do
    expect(described_class::ISSUE_COUNTS).to eq([1_000, 10_000, 100_000])
    expect(described_class::ISSUE_COUNTS).to eq(described_class::ISSUE_COUNTS.sort)
  end

  it 'checks the absolute criteria across at least two orders of magnitude' do
    small, large = described_class::INVARIANT_COUNTS

    expect(large / small).to be >= 100
  end

  it 'declares both render media blocked, each naming the task that owes it' do
    expect(described_class::BLOCKED_MEDIA.keys.sort).to eq([described_class::HTML, described_class::PDF])
    described_class::BLOCKED_MEDIA.each_value do |entry|
      expect(entry['owed_by']).to eq('T-10')
    end
  end

  it 'enumerates one render cell per (reference template, issue count, medium)' do
    # production-shapes has no template file, so it has no render cell — only the two
    # real reference templates do.
    expect(described_class.render_cells.length).to eq(2 * described_class::ISSUE_COUNTS.length * 2)
  end

  it 'digests the matrix over the fields a measurement depends on' do
    expect(described_class.digest).to match(/\A[0-9a-f]{64}\z/)
    expect(described_class.digest).to eq(described_class.digest)
  end
end
