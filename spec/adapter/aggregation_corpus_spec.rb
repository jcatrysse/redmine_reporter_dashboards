# frozen_string_literal: true
#
# THE GOLDEN AGGREGATION CORPUS — the differential oracle for gate G7.
#
# Every case in RrdGolden::CorpusCases is re-run against a real database and compared
# with the committed record, byte for byte after canonicalisation. A difference is a
# difference in the numbers the aggregation kernel produces, which is the one thing
# the whole decoupling sequence is not allowed to change.
#
#   generate   RRD_REFERENCE_DATE=2025-12-29 RRD_CORPUS_WRITE=1 \
#              RRD_ADAPTER_URL=postgres://... bundle exec rspec \
#                -I plugins/redmine_reporter_dashboards/spec \
#                   plugins/redmine_reporter_dashboards/spec/adapter/aggregation_corpus_spec.rb
#
#   verify     the same without RRD_CORPUS_WRITE. This is what the `corpus` CI job
#              runs, on all three engines.
#
# Unpinned it SKIPS with a reason: the corpus is generated against one pinned date, so
# comparing it against a run whose fixture is relative to today would fail daily for
# the wrong reason. That skip is why the `corpus` job asserts a zero pending count —
# a skipped oracle looks exactly like a passing one.

require_relative 'adapter_helper'
require_relative '../golden/corpus'
require_relative '../golden/corpus_cases'
require_relative '../golden/adapter_overlay'

if !RrdAdapterHarness.configured?
  RSpec.describe 'the golden aggregation corpus' do
    it 'is skipped without a database URL' do
      skip RrdAdapterHarness.skip_reason
    end
  end
elsif !RrdAdapterHarness.reference_date_pinned?
  RSpec.describe 'the golden aggregation corpus' do
    it 'is skipped without a pinned reference date' do
      skip "the corpus is an oracle: set #{RrdGolden::ReferenceDate::ENV_VAR}=" \
           "#{RrdGolden::ReferenceDate::DEFAULT} to verify it. The `corpus` CI job does, and " \
           'refuses a run in which these examples were pending.'
    end
  end
else
  require_relative '../golden/corpus_generator'

  # One pass over the database, shared by every example. Generated lazily so it
  # happens after the harness's before(:suite) has frozen the clock and seeded.
  module RrdCorpusRun
    class << self
      def actual
        @actual ||= RrdGolden::CorpusGenerator.records
                                              .each_with_object({}) { |r, out| out[r['case']] = r }
      end

      # Regenerating and verifying are the same code path with one branch, so a
      # written corpus can never be a shape the verifier would reject.
      def expected
        @expected ||= begin
          if RrdGolden::Corpus.write?
            warn "\n[corpus] RRD_CORPUS_WRITE is set: REGENERATING #{RrdGolden::Corpus::VALUES}"
            RrdGolden::Corpus.save(actual.values, cases_digest: RrdGolden::CorpusCases.digest,
                                                  adapter: RrdAdapterHarness.adapter_name)
          end
          if RrdGolden::Corpus.overlay_write?
            warn "\n[corpus] RRD_CORPUS_OVERLAY_WRITE is set: REGENERATING " \
                 "#{RrdGolden::AdapterOverlay.path_for(family)}"
            RrdGolden::AdapterOverlay.save(family, actual.values)
          end
          RrdGolden::Corpus.by_case
        end
      end

      # Asked of the SERVER, not of the adapter name: mysql2 reports "Mysql2" for
      # MariaDB too, and D-1 is MariaDB's alone.
      def family
        @family ||= RrdAdapterHarness.overlay_family
      end

      # The result the engine actually produced, canonicalised — the same form the
      # file holds, so the comparison is never string-against-structure.
      def actual_result(case_id)
        RrdGolden::CorpusCanonicaliser.canonicalise(actual.fetch(case_id)['result'])
      end

      # What the committed corpus says, with no overlay applied. The exhaustiveness
      # assertion needs this: comparing against the overlaid value would make every
      # declared case agree by construction.
      def committed_result(case_id)
        expected.fetch(case_id) do
          raise "the corpus has no record for case #{case_id.inspect} — the case list has moved " \
                "on from the committed file. Regenerate with #{RrdGolden::Corpus::WRITE_ENV}=1."
        end['result']
      end

      # The committed result, unless this case is one of the overlay's named
      # exceptions on this engine.
      def expected_result(case_id)
        return committed_result(case_id) unless
          RrdGolden::AdapterOverlay.case_ids_for(family).include?(case_id)

        RrdGolden::CorpusCanonicaliser.canonicalise(
          RrdGolden::AdapterOverlay.expected_for(case_id, family)
        )
      end

      # A wall of numbers is not a failure message. This names the first path at
      # which the two structures part company, which is almost always enough to see
      # what changed.
      def first_difference(expected, actual, path = [])
        return nil if expected == actual

        if expected.is_a?(Hash) && actual.is_a?(Hash)
          (expected.keys | actual.keys).each do |key|
            diff = first_difference(expected[key], actual[key], path + [key])
            return diff if diff
          end
        elsif expected.is_a?(Array) && actual.is_a?(Array)
          if expected.length == actual.length
            expected.each_index do |i|
              diff = first_difference(expected[i], actual[i], path + [i])
              return diff if diff
            end
          else
            return { path: path, expected: "#{expected.length} elements",
                     actual: "#{actual.length} elements" }
          end
        end

        { path: path, expected: expected.inspect, actual: actual.inspect }
      end

      def failure_message(kase)
        expected = expected_result(kase.id)
        actual   = actual_result(kase.id)
        diff     = first_difference(expected, actual) || {}
        where    = diff[:path].to_a.empty? ? '(the whole result)' : diff[:path].join(' -> ')

        <<~MESSAGE
          #{kase.id} no longer produces the frozen numbers.

            entry point   SqlAggregation::QueryAggregator.#{kase.entry}
            scope         #{kase.scope}
            actor         #{kase.actor}
            arguments     #{kase.args.inspect}
            engine        #{RrdAdapterHarness.adapter_name} (overlay family: #{family})

            first difference at   #{where}
              expected  #{diff[:expected]}
              actual    #{diff[:actual]}

          If the kernel was meant to change, it was not: gate G7 freezes it byte for byte.
          If the FIXTURE changed, that is the bug — the corpus is generated from it.
          If this is a genuine per-engine difference at 4 decimal places, it belongs in
          spec/golden/adapter_overlay.rb with a written reason and a raised ratchet.
        MESSAGE
      end
    end
  end

  RSpec.describe 'the golden aggregation corpus' do
    # The suite runs in random order, so no example may depend on another having run
    # (CLAUDE.md §6). Touching `expected` here makes every example — not only the
    # ones that compare against it — see a written corpus on a regenerating run.
    before { RrdCorpusRun.expected }

    # ----------------------------------------------------------------
    # Provenance — is this corpus answering the same question we are asking?
    # ----------------------------------------------------------------

    describe 'provenance' do
      subject(:manifest) { RrdGolden::Corpus.manifest }

      it 'was generated against the baseline commit' do
        expect(manifest['baseline_commit']).to eq(RrdGolden::Baseline::COMMIT)
      end

      it 'was generated against the reference date this run is pinned to' do
        expect(manifest['reference_date']).to eq(RrdGolden::ReferenceDate.require!.iso8601)
      end

      # The corpus buckets by day and by ISO week. Generated in another zone, every
      # boundary case would sit on the other side of midnight.
      it 'was generated in the time zone this run uses' do
        expect(manifest['time_zone']).to eq(RrdAdapterHarness::CORPUS_TIME_ZONE)
        expect(Time.zone.name).to eq(RrdAdapterHarness::CORPUS_TIME_ZONE)
      end

      # Hand-editing a record to make a failing case pass is the one attack on a
      # golden corpus that leaves no trace anywhere else.
      it 'has not been edited since it was generated' do
        expect(manifest['digest']).to eq(Digest::SHA256.hexdigest(File.binread(RrdGolden::Corpus::VALUES)))
      end

      # The other direction: the case list is the question, the file is the answer.
      it 'answers the committed case list' do
        expect(manifest['cases']).to eq(RrdGolden::CorpusCases.digest),
                                     'the case matrix has changed but the corpus has not been ' \
                                     "regenerated. Run with #{RrdGolden::Corpus::WRITE_ENV}=1 and " \
                                     'commit both files.'
      end

      it 'holds one record per case and no more' do
        expect(manifest['record_count']).to eq(RrdGolden::CorpusCases.all.length)
        expect(RrdGolden::Corpus.by_case.keys.sort).to eq(RrdGolden::CorpusCases.ids.sort)
      end
    end

    # ----------------------------------------------------------------
    # The caps, as the aggregator declares them
    # ----------------------------------------------------------------

    describe 'the cap constants the matrix is built on' do
      it 'matches MAX_DIMENSION_KEYS' do
        expect(RrdGolden::CorpusCases::CAP_DIMENSION_KEYS)
          .to eq(SqlAggregation::QueryAggregator::MAX_DIMENSION_KEYS)
      end

      it 'matches MAX_AGE_BUCKETS' do
        expect(RrdGolden::CorpusCases::CAP_AGE_BUCKETS)
          .to eq(SqlAggregation::QueryAggregator::MAX_AGE_BUCKETS)
      end

      it 'matches MAX_COMPLETENESS_FIELDS' do
        expect(RrdGolden::CorpusCases::CAP_COMPLETENESS_FIELDS)
          .to eq(SqlAggregation::QueryAggregator::MAX_COMPLETENESS_FIELDS)
      end

      it "matches month's period maximum, which is the same 24" do
        expect(SqlAggregation::QueryAggregator::PERIOD_CONFIG['month'][:max])
          .to eq(RrdGolden::CorpusCases::CAP_AGE_BUCKETS)
      end
    end

    # ----------------------------------------------------------------
    # The corpus itself: one example per case
    # ----------------------------------------------------------------

    describe 'every case still produces the frozen numbers' do
      RrdGolden::CorpusCases.all.each do |kase|
        it kase.id do
          expect(RrdCorpusRun.actual_result(kase.id))
            .to eq(RrdCorpusRun.expected_result(kase.id)), -> { RrdCorpusRun.failure_message(kase) }
        end
      end
    end

    # ----------------------------------------------------------------
    # What the records MEAN — assertions the file alone cannot make
    #
    # A corpus records whatever it was given. These examples say what the recorded
    # numbers have to be RELATED to, so a wrong-but-consistent regeneration is caught
    # as well as a drift.
    # ----------------------------------------------------------------

    def result(case_id)
      RrdCorpusRun.actual.fetch(case_id)['result']
    end

    describe 'the 200-key cap' do
      it 'keeps 200 keys and collapses the rest into one Other bucket' do
        buckets = result('cap/keys.wide.limit0')['buckets']

        expect(buckets.length).to eq(RrdGolden::CorpusCases::CAP_DIMENSION_KEYS + 1)
        expect(buckets.last['label']).to eq('Other')
        expect(result('cap/keys.wide.limit0')['truncated']).to be true
      end

      it 'lands on exactly 200 buckets with no Other when the scope holds exactly 200 keys' do
        at_cap = result('cap/keys.at_cap_scope')

        expect(at_cap['buckets'].length).to eq(RrdGolden::CorpusCases::CAP_DIMENSION_KEYS)
        expect(at_cap['buckets'].map { |b| b['label'] }).not_to include('Other')
        expect(at_cap['truncated']).to be false
      end

      it 'accounts for every issue in scope, Other included' do
        expect(result('cap/keys.wide.limit0')['buckets'].sum { |b| b['count'] })
          .to eq(RrdAdapterHarness::WIDE_ISSUES)
      end

      # The cap CLAMPS: asking for one more than it allows is the same request.
      it 'answers a limit one past the cap identically to the cap' do
        expect(result('cap/keys.wide.past')).to eq(result('cap/keys.wide.at'))
      end

      it 'answers a limit below the cap differently, so the equality above means something' do
        expect(result('cap/keys.wide.below')).not_to eq(result('cap/keys.wide.at'))
      end
    end

    describe 'the 24-age-bucket cap' do
      # Both engines are asserted, neither is skipped, and the MySQL branch asserts
      # the DEFECT rather than the intent — see DEFECT D-1 in
      # spec/golden/adapter_overlay.rb. When D-1 is fixed this example fails, which is
      # exactly the signal wanted: the fix has to come here and delete the branch.
      it 'produces one bucket per bound plus the open-ended one' do
        buckets = result('cap/age.at')['buckets']

        if RrdAdapterHarness.mariadb?
          expect(buckets.length).to eq(RrdGolden::CorpusCases::CAP_AGE_BUCKETS + 2)
          expect(buckets.last['label']).to eq('(none)'),
                                           'DEFECT D-1 has changed shape: MariaDB used to ' \
                                           'collapse a >256-character age CASE into the empty ' \
                                           'bucket. Re-read the overlay entry before touching it.'
          expect(buckets[0..-2].map { |b| b['count'] }.uniq).to eq([0])
        else
          expect(buckets.length).to eq(RrdGolden::CorpusCases::CAP_AGE_BUCKETS + 1)
          expect(buckets.sum { |b| b['count'] }).to eq(RrdAdapterHarness::WIDE_ISSUES)
        end
      end

      # True on both engines: the 25th bound never reaches the SQL, so the statement —
      # correct or not — is the same one.
      it 'drops the 25th bound rather than widening the CASE' do
        expect(result('cap/age.past')).to eq(result('cap/age.at'))
      end

      # The boundary of the defect itself, so the 256-character limit is a measured
      # fact in the suite and not only a sentence in a comment.
      it 'is unaffected at three bounds, on either engine' do
        buckets = result('dimension/main.age.created')['buckets']

        expect(buckets.map { |b| b['label'] }).to eq(['0-30', '31-60', '61-90', '>90'])
        expect(buckets.sum { |b| b['count'] }).to eq(4)
      end
    end

    describe 'the 24-period cap' do
      it 'returns 24 labels' do
        expect(result('cap/periods.month.at')['labels'].length)
          .to eq(RrdGolden::CorpusCases::CAP_AGE_BUCKETS)
      end

      it 'clamps a 25th period rather than growing the window' do
        expect(result('cap/periods.month.past')).to eq(result('cap/periods.month.at'))
      end
    end

    describe 'the 12-completeness-field cap' do
      it 'accepts twelve fields' do
        expect(result('completeness/main.at_cap')['buckets'].length)
          .to eq(RrdGolden::CorpusCases::CAP_COMPLETENESS_FIELDS)
      end

      # This cap REFUSES where the others clamp: thirteen fields is nil, not the
      # first twelve. Frozen because silently dropping the thirteenth would produce a
      # chart that is missing a field nobody asked it to drop.
      it 'refuses thirteen' do
        expect(result('completeness/main.past_cap')).to be_nil
      end
    end

    describe 'the 5 000-cell crosstab boundary' do
      it 'is exactly 5 000 cells at the boundary' do
        rows   = result('cap/cells.at')['rows']
        series = result('cap/cells.at')['series']

        expect(rows.length).to eq(RrdGolden::CorpusCases::CAP_DIMENSION_KEYS)
        expect(series.length).to eq(RrdAdapterHarness::WIDE_SPREAD_DAYS)
        expect(rows.length * series.length).to eq(RrdGolden::CorpusCases::CAP_DRILL_CELLS)
      end

      it 'is one row past the boundary when the keys are truncated' do
        rows   = result('cap/cells.past')['rows']
        series = result('cap/cells.past')['series']

        expect(rows.length).to eq(RrdGolden::CorpusCases::CAP_DIMENSION_KEYS + 1)
        expect(rows.length * series.length).to be > RrdGolden::CorpusCases::CAP_DRILL_CELLS
      end

      it 'fills the grid densely, so a cell count is a cell count' do
        rows   = result('cap/cells.at')['rows']
        series = result('cap/cells.at')['series']

        expect(rows.map { |row| row['cells'].keys.sort }.uniq).to eq([series.sort])
      end
    end

    # ----------------------------------------------------------------
    # INV-1 / INV-2 at value level — the reason the fixture has four actors
    # ----------------------------------------------------------------

    describe 'the role-restricted custom field' do
      it 'is refused outright to an actor holding no entitled role' do
        expect(result('dimension/main.cf_salary.developer')).to be_nil
        expect(result('dimension/main.cf_salary.reporter')).to be_nil
        expect(result('completeness/main.cf_salary.developer')).to be_nil
        expect(result('measure/main.sum_cf_salary.reporter')).to be_nil
      end

      # Not an assertion that this is RIGHT — it is an assertion that it is what
      # happens, so the re-seam cannot change it by accident. A refused field in a
      # LIST is dropped and the remaining fields are reported: the unentitled viewer
      # gets a chart with one bucket fewer and nothing saying so.
      it 'is dropped from a completeness list rather than refusing the whole list' do
        partial = result('completeness/main.cf_salary_and_due.developer')

        expect(partial).not_to be_nil
        expect(partial['buckets'].map { |b| b['label'] }).to eq(['Due date'])
        expect(result('completeness/main.cf_salary_and_due.manager')['buckets'].map { |b| b['label'] })
          .to eq(['Salary', 'Due date'])
      end

      it 'answers with its values for the actor entitled where the issues are' do
        labels = result('dimension/main.cf_salary.manager')['buckets'].map { |b| b['label'] }

        expect(labels).to include('1000.5', '2000.25')
      end

      # The one that matters: the field RESOLVES, the values are hidden, and the
      # issues still count. A join that turned into a filter would lose them.
      it 'hides the values but keeps the issues for an actor entitled elsewhere' do
        auditor = result('dimension/main.cf_salary.auditor')
        manager = result('dimension/main.cf_salary.manager')

        expect(auditor).not_to be_nil
        expect(auditor['buckets'].map { |b| b['label'] }).to eq(['(none)'])
        expect(auditor['buckets'].sum { |b| b['count'] })
          .to eq(manager['buckets'].sum { |b| b['count'] })
      end

      it 'reports zero filled, not an absent bucket, for the actor entitled elsewhere' do
        auditor = result('completeness/main.cf_salary.auditor')
        manager = result('completeness/main.cf_salary.manager')

        expect(auditor['buckets'].map { |b| [b['label'], b['count'], b['empty']] })
          .to eq([['Salary', 0, 4]])
        expect(manager['buckets'].map { |b| [b['label'], b['count']] }).to eq([['Salary', 2]])
      end

      it 'shows the same actor the values in the project where the role IS held' do
        expect(result('dimension/wide.cf_salary.auditor')['buckets'].map { |b| b['label'] })
          .to include('10.25')
      end

      it 'sums to zero rather than to the hidden total' do
        expect(result('measure/main.sum_cf_salary.auditor')['total']).to eq(0.0)
        expect(result('measure/main.sum_cf_salary.manager')['total']).to be > 0.0
      end

      it 'keeps a role-restricted cost field out of a rollup the actor may not see' do
        manager = result('rollup/main.cost_salary.manager')
        auditor = result('rollup/main.cost_salary.auditor')

        expect(manager.map { |row| row['cost'] }.any? { |cost| cost.any? }).to be true
        expect(auditor.map { |row| row['cost'] }.uniq).to eq([{}])
      end
    end

    describe 'visible spent time' do
      it 'differs by actor, and is zero where no entitled role is held' do
        entitled   = result('measure/reported.sum_spent_hours.manager')['total']
        unentitled = result('measure/reported.sum_spent_hours.reporter')['total']

        expect(entitled).to be > 0.0
        expect(unentitled).to eq(0.0)
      end

      it 'is zero for an actor whose entitled role is in another project' do
        expect(result('measure/reported.sum_spent_hours.auditor')['total']).to eq(0.0)
      end
    end

    # The complement of the above: the two entry points with no actor-dependent
    # surface must give every actor the same answer. Without this, a corpus proves
    # visibility only where it is already applied.
    describe 'the actor-invariant entry points' do
      it 'answers .aggregate identically for every actor' do
        answers = RrdGolden::CorpusCases::ACTORS.map { |a| result("aggregate/main.month.actor_#{a}") }

        expect(answers.uniq.length).to eq(1)
      end

      it 'answers .flags identically for every actor' do
        answers = RrdGolden::CorpusCases::ACTORS.map { |a| result("flags/main.actor_#{a}") }

        expect(answers.uniq.length).to eq(1)
      end
    end

    # ----------------------------------------------------------------
    # Reproducibility — a corpus that is not reproducible is not an oracle
    # ----------------------------------------------------------------

    describe 'reproducibility' do
      it 'produces the same bytes when the whole matrix is run a second time' do
        first  = RrdGolden::CorpusCanonicaliser.digest(RrdCorpusRun.actual.values)
        second = RrdGolden::CorpusCanonicaliser.digest(RrdGolden::CorpusGenerator.records)

        expect(second).to eq(first)
      end

      # Overlay cases aside, this engine must rebuild the committed file exactly. On
      # the canonical engine the overlay is empty, so this IS whole-file byte
      # equality; on another engine it is byte equality over everything the overlay
      # does not name. One assertion rather than one per engine, and no skip — a
      # skipped oracle reads exactly like a passing one.
      it 'rebuilds the committed corpus byte for byte, overlay cases aside' do
        overlaid = RrdGolden::AdapterOverlay.case_ids_for(RrdCorpusRun.family)
        mine     = RrdCorpusRun.actual.values.reject { |r| overlaid.include?(r['case']) }
        theirs   = RrdGolden::Corpus.records.reject { |r| overlaid.include?(r['case']) }

        expect(RrdGolden::CorpusCanonicaliser.digest(mine))
          .to eq(RrdGolden::CorpusCanonicaliser.digest(theirs))
      end
    end

    # ----------------------------------------------------------------
    # The overlay is exhaustive
    #
    # THE assertion that makes a per-engine overlay safe. Without it an overlay entry
    # would be a licence: "this case differs, and so may anything else". With it, the
    # set of cases that differ on this engine has to be EXACTLY the set the overlay
    # names — a new divergence fails even though the overlay is "already used", and a
    # fixed divergence fails until its entry is deleted.
    # ----------------------------------------------------------------

    describe 'the per-adapter overlay' do
      let(:differing) do
        RrdGolden::CorpusCases.ids.reject do |id|
          RrdCorpusRun.actual_result(id) == RrdCorpusRun.committed_result(id)
        end
      end

      it 'names exactly the cases that differ from the committed corpus on this engine' do
        expect(differing.sort).to eq(RrdGolden::AdapterOverlay.case_ids_for(RrdCorpusRun.family).sort),
                                 <<~MESSAGE
                                   the cases that differ on #{RrdAdapterHarness.adapter_name} are not the cases the overlay
                                   declares.

                                     differ:  #{differing.sort.inspect}
                                     overlay: #{RrdGolden::AdapterOverlay.case_ids_for(RrdCorpusRun.family).sort.inspect}

                                   A case that differs and is not listed is a divergence nobody has looked at.
                                   A case that is listed and no longer differs means the reason has gone away —
                                   delete the entry and lower RATCHET in the same commit.
                                 MESSAGE
      end

      # What an entry must LOOK like — a reason, a known family, a case that exists, and
      # the ratchet — is asserted in spec/golden/adapter_overlay_spec.rb, which needs no
      # database and therefore runs on every supported Redmine. One home for that rule.
    end
  end
end
