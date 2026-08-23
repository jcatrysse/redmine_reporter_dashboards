# frozen_string_literal: true

require_relative '../spec_helper'
require_relative 'corpus_cases'

# The corpus itself needs a database. Its COVERAGE does not — and coverage is the
# half that rots quietly: a matrix can go on passing while the thing it was built to
# cover has quietly left it. So the shape of the matrix is asserted here, in the
# DB-less run that executes on every supported Redmine, against the acceptance list
# in implementation-plan.md T-01.
RSpec.describe RrdGolden::CorpusCases do
  subject(:cases) { described_class.all }

  describe 'the case list itself' do
    it 'has unique ids' do
      expect(cases.map(&:id).tally.select { |_, n| n > 1 }).to eq({})
    end

    it 'names a known entry point, scope, actor and normalisation for every case' do
      # .all validates on construction; this asserts the validation is reachable
      # rather than trusting that it ran.
      expect { described_class.all }.not_to raise_error
      expect(cases).to all(have_attributes(entry: a_kind_of(String), scope: a_kind_of(String),
                                           actor: a_kind_of(String)))
    end

    it 'carries no clock-relative argument' do
      # A fixture relative to Time.now is a forbidden construct (CLAUDE.md §5) and
      # this is the file where one would be most tempting to write.
      serialised = cases.map { |kase| kase.args.inspect }.join(' ')

      expect(serialised).not_to match(/Time\.now|Date\.today|Time\.zone\.(now|today)/)
    end

    it 'is ordered deterministically, so the corpus file has a stable record order' do
      expect(described_class.all.map(&:id)).to eq(described_class.all.map(&:id))
      expect(described_class.digest).to eq(described_class.digest)
    end
  end

  # T-01: "Covers: .aggregate, .breakdown (legacy), .dimension_breakdown,
  # .completeness, .flags, .version_rollup".
  describe 'the six aggregator entry points' do
    it 'covers every one of them' do
      expect(cases.map(&:entry).uniq.sort).to eq(described_class::ENTRY_POINTS.sort)
    end

    described_class::ENTRY_POINTS.each do |entry|
      it "has more than one case for .#{entry}" do
        expect(described_class.for_entry(entry).length).to be > 1
      end
    end

    it 'exercises every period of .aggregate' do
      periods = described_class.for_entry('aggregate').map { |kase| kase.args['period'] }.uniq

      expect(periods).to include('day', 'week', 'month', 'year')
    end

    it 'exercises all seven core fields of the legacy .breakdown' do
      fields = described_class.for_entry('breakdown').map { |kase| kase.args['group_by'] }

      expect(fields).to include('status', 'priority', 'tracker', 'assignee', 'author',
                                'category', 'version')
    end

    it 'exercises the whole argument surface of .dimension_breakdown' do
      keys = described_class.for_entry('dimension_breakdown').flat_map { |kase| kase.args.keys }.uniq

      expect(keys).to include('group_by', 'split_by', 'sort', 'limit', 'measure', 'of',
                              'user_label', 'age_buckets', 'age_field', 'date_field',
                              'period', 'periods', 'empty_label', 'other_label')
    end
  end

  # T-01: "cap boundaries at 200 / 24 / 12 / 5 000". Each one AT the boundary and one
  # PAST it, because a cap that is only tested at the boundary is a cap nobody has
  # watched refuse anything.
  describe 'the four cap boundaries' do
    def case_ids_matching(prefix)
      described_class.ids.select { |id| id.start_with?(prefix) }
    end

    it 'tests the 200-key cap at the boundary and past it' do
      expect(case_ids_matching('cap/keys')).to include('cap/keys.wide.at', 'cap/keys.wide.past',
                                                       'cap/keys.at_cap_scope')
    end

    it 'tests the 24-age-bucket cap at the boundary and past it' do
      expect(case_ids_matching('cap/age')).to include('cap/age.at', 'cap/age.past')
      expect(described_class::AGE_BOUNDS_AT_CAP.length).to eq(described_class::CAP_AGE_BUCKETS)
      expect(described_class::AGE_BOUNDS_PAST_CAP.length).to eq(described_class::CAP_AGE_BUCKETS + 1)
    end

    it 'tests the 24-period cap at the boundary and past it' do
      expect(case_ids_matching('cap/periods')).to include('cap/periods.month.at',
                                                          'cap/periods.month.past')
    end

    it 'tests the 12-completeness-field cap at the boundary and past it' do
      at_cap   = cases.find { |kase| kase.id == 'completeness/main.at_cap' }
      past_cap = cases.find { |kase| kase.id == 'completeness/main.past_cap' }

      expect(at_cap.args['fields'].length).to eq(described_class::CAP_COMPLETENESS_FIELDS)
      expect(past_cap.args['fields'].length).to eq(described_class::CAP_COMPLETENESS_FIELDS + 1)
      expect(at_cap.args['fields'].uniq.length).to eq(at_cap.args['fields'].length)
    end

    it 'tests the 5 000-cell crosstab boundary at the boundary and past it' do
      expect(case_ids_matching('cap/cells')).to include('cap/cells.at', 'cap/cells.past')
    end

    # The drill-cell cap lives in the Liquid tag, which needs Liquid and a render
    # context — neither of which the corpus job has. Read from the source rather than
    # loaded, so the literal in this file cannot drift away from the implementation
    # without something failing. The other three caps are asserted against the
    # aggregator's own constants by the corpus verifier, where it is loaded.
    it 'agrees with the drill-cell cap the Liquid tag declares' do
      # encoding: named, not inherited. Ruby's default external encoding follows the
      # environment's locale, and a container with no LANG set reads UTF-8 source as
      # US-ASCII — which turns the first em-dash in that file into
      # "invalid byte sequence" rather than into a comment.
      source = File.read(File.expand_path('../../lib/sql_aggregation/liquid_aggregate_tag.rb',
                                          __dir__), encoding: 'UTF-8')

      expect(source).to match(/MAX_DRILL_CELLS\s*=\s*5_000/)
      expect(described_class::CAP_DRILL_CELLS).to eq(5_000)
    end
  end

  # T-01: "≥3 actors with different roles including one role-restricted custom field —
  # absent from the fixture today, and the thing that makes INV-1/INV-2 testable at
  # value level".
  describe 'the actors' do
    it 'has at least three' do
      expect(described_class::ACTORS.length).to be >= 3
    end

    it 'uses every one of them' do
      expect(cases.map(&:actor).uniq.sort).to eq(described_class::ACTORS.sort)
    end

    it 'asks the same question of every actor at least once per actor-dependent surface' do
      %w[dimension/main.cf_salary measure/reported.sum_spent_hours
         completeness/main.cf_salary rollup/main.cost_salary].each do |prefix|
        actors = cases.select { |kase| kase.id.start_with?(prefix) }.map(&:actor).uniq

        expect(actors.sort).to eq(described_class::ACTORS.sort), "#{prefix} is not asked of every actor"
      end
    end

    # Spelled out rather than detected: the args of a rollup case name the field as an
    # Integer in cost_field_ids and a dimension case names it as the string "cf_15",
    # so a clever scan over both would be the thing most likely to quietly match
    # nothing.
    it 'covers the role-restricted custom field on every entry point that can see one' do
      expect(described_class.ids).to include('dimension/main.cf_salary.manager',
                                             'measure/main.sum_cf_salary.manager',
                                             'completeness/main.cf_salary.manager',
                                             'rollup/main.cost_salary.manager')
    end

    it 'points those cases at the role-restricted field and not at another one' do
      salary = "cf_#{described_class::CF_SALARY}"

      expect(cases.find { |k| k.id == 'dimension/main.cf_salary.manager' }.args['group_by']).to eq(salary)
      expect(cases.find { |k| k.id == 'measure/main.sum_cf_salary.manager' }.args['of']).to eq(salary)
      expect(cases.find { |k| k.id == 'completeness/main.cf_salary.manager' }.args['fields'])
        .to eq([salary])
      expect(cases.find { |k| k.id == 'rollup/main.cost_salary.manager' }.args['cost_field_ids'])
        .to eq([described_class::CF_SALARY])
    end

    # The other half of INV-1: an entry point with no actor-dependent surface must be
    # recorded under several actors too, or the corpus only proves visibility where it
    # is already known to apply.
    it 'records the actor-invariant entry points under every actor as well' do
      %w[aggregate flags].each do |entry|
        actors = described_class.for_entry(entry).map(&:actor).uniq

        expect(actors.sort).to eq(described_class::ACTORS.sort)
      end
    end
  end

  describe 'the scopes' do
    it 'uses every declared scope' do
      expect(cases.map(&:scope).uniq.sort).to eq(described_class::SCOPES.sort)
    end

    # The empty state is what a dashboard renders on its first day, and it is where a
    # divide-by-zero or a nil percentile shows up.
    it 'asks every entry point about an empty scope' do
      empty = cases.select { |kase| kase.scope == 'empty' }.map(&:entry).uniq

      expect(empty.sort).to eq(described_class::ENTRY_POINTS.sort)
    end
  end

  describe 'the two normalisations' do
    it 'normalises exactly the entry points whose output order the kernel leaves open' do
      normalised = cases.reject { |kase| kase.normalise == :none }.map(&:entry).uniq.sort

      expect(normalised).to eq(%w[breakdown version_rollup])
    end

    it 'normalises every case of those two, so one is never left comparing a raw order' do
      %w[breakdown version_rollup].each do |entry|
        expect(described_class.for_entry(entry).map(&:normalise).uniq.length).to eq(1)
      end
    end

    it 'leaves every other case recorded exactly as returned' do
      others = cases.reject { |kase| %w[breakdown version_rollup].include?(kase.entry) }

      expect(others.map(&:normalise).uniq).to eq([:none])
    end
  end
end
