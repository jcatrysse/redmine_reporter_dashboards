# frozen_string_literal: true
#
# T-31 `Accept:` clauses 6 and 7 — the OWNED TIME-ENTRY AGGREGATOR, proved by a SECOND
# COMPUTATION rather than by a recorded file, against a real database engine.
#
# --- WHY THERE IS NO GOLDEN CORPUS FOR THIS ---
#
# The aggregation corpus next door exists to answer "has this behaviour MOVED", which is
# what `spec/golden/README.md` says of it in as many words. That question needs a
# previous answer to compare against, and it is the right question for the issue kernel,
# whose numbers are a v0.5.0 artefact under gate G7. This module was written this week. A
# recorded file here would freeze whatever it happened to answer on its first day —
# bugs included — and then report the bug's later removal as a regression.
#
# So every figure below is computed TWICE: once through this module (SQL, `GROUP BY`,
# `SUM`) and once by loading the rows and adding them up in Ruby. Two independent
# computations agreeing is a correctness claim. The Ruby side is written out longhand
# (see RRD_RUBY_KEY) rather than borrowed from `DIMENSIONS`, because an oracle that reads the
# implementation's own table agrees with it by construction.
#
# --- WHY IT LIVES IN spec/adapter/ ---
#
# `SUM` over a `float` column, `COUNT(DISTINCT …)`, a `LEFT OUTER JOIN` next to a
# `GROUP BY`, and `ONLY_FULL_GROUP_BY` are all things PostgreSQL, MySQL 8 and MariaDB 11
# do differently or accept differently. The `adapter` CI job runs this directory against
# all three; a DB-less spec asserting SQL strings could not tell you any engine accepts
# them, let alone that the three agree on the answer.
#
# See spec/adapter/adapter_helper.rb for the fixture (PROJECT_HOURS, HOURS_ENTRIES) and
# for how to run these.

require_relative 'adapter_helper'

if !RrdAdapterHarness.configured?
  RSpec.describe 'TimeEntryAggregator against a real database' do
    it 'is skipped without a database URL' do
      skip RrdAdapterHarness.skip_reason
    end
  end
else
  # `unless defined?` because query_aggregator_execution_spec.rb claims the same name and
  # rspec loads every file in this directory before running any of it — either file may be
  # the one that gets there first, and running this one alone must still work.
  H = RrdAdapterHarness unless defined?(H)

  # A stand-in for `Liquid::Diagnostics`, which this process does not load. The aggregator's
  # port is duck-typed on `#degrade` precisely so the aggregation layer need not name the
  # Liquid layer (`script/gates/layer_purity.sh`), and a double is what proves it is a port
  # rather than a hard reference with a `respond_to?` in front of it.
  class RrdFakeDiagnostics
    attr_reader :records

    def initialize
      @records = []
    end

    def degrade(code, detail: nil, **data)
      @records << { code: code, detail: detail.to_s, data: data }
    end

    def codes
      @records.map { |record| record[:code] }
    end
  end

  # THE ORACLE'S OWN DIMENSION TABLE, written out rather than derived from
  # `described_class::DIMENSIONS`. Each entry answers "which key does THIS row belong
  # to", in Ruby, off the loaded record — the `issues.` ones by following the
  # association, which is the independent path to the same fact the LEFT OUTER JOIN
  # reaches in SQL. A spec that iterated the implementation's table would agree with a
  # renamed column, a wrong join and a swapped pair of dimensions.
  RRD_RUBY_KEY = {
    'activity' => ->(e) { e.activity_id },
    'user' => ->(e) { e.user_id },
    'project' => ->(e) { e.project_id },
    'issue' => ->(e) { e.issue_id },
    'tracker' => ->(e) { e.issue&.tracker_id },
    'status' => ->(e) { e.issue&.status_id },
    'priority' => ->(e) { e.issue&.priority_id },
    'author' => ->(e) { e.issue&.author_id },
    'assignee' => ->(e) { e.issue&.assigned_to_id },
    'version' => ->(e) { e.issue&.fixed_version_id },
    'category' => ->(e) { e.issue&.category_id }
  }.freeze

  RSpec.describe RedmineReporterDashboards::Aggregation::TimeEntryAggregator do
    let(:actor) { :manager }
    let(:scope) { H.hours_scope(actor) }

    # The rows the report is over, loaded once. `to_a` and not `pluck`: the oracle reads
    # attributes and follows `issue`, which is the whole point of computing it the other
    # way round.
    def rows(for_actor = actor)
      H.hours_scope(for_actor).to_a
    end

    # The Ruby half. Rounded to two places for the reason `number` is: `0.1 + 0.2` is
    # 0.30000000000000004 in Ruby AND in every engine's float arithmetic, and the two
    # need not agree on the last bit. An oracle comparing raw floats would be red or
    # green by luck.
    def ruby_hours(entries, dimension)
      entries.group_by(&RRD_RUBY_KEY.fetch(dimension))
             .transform_values { |group| group.sum(&:hours).to_f.round(2) }
             .transform_keys { |key| key&.to_s }
    end

    def ruby_counts(entries, dimension)
      entries.group_by(&RRD_RUBY_KEY.fetch(dimension))
             .transform_values { |group| group.map(&:id).uniq.size }
             .transform_keys { |key| key&.to_s }
    end

    # The module's half, reduced to `{key => figure}` so the comparison is about NUMBERS
    # and never about labels. `value` carries the id as a string and nil for the empty
    # bucket, which is exactly what `ruby_hours` keys by.
    def figures(result)
      result['buckets'].each_with_object({}) { |b, out| out[b['value']] = b['count'] }
    end

    def breakdown(**options)
      described_class.breakdown(scope, **options)
    end

    # ----------------------------------------------------------------
    # The fixture is what we think it is. Without this, an empty fixture would make
    # every agreement below vacuously true — two ways of computing nothing agree.
    # ----------------------------------------------------------------

    describe 'the fixture' do
      it 'gives the actor rows to aggregate' do
        expect(rows.size).to eq(H::HOURS_ENTRIES.size)
      end

      it 'hides the archived project\'s hours, so visibility is doing work' do
        expect(::TimeEntry.where(project_id: H::PROJECT_ARCHIVED).sum(:hours)).to eq(40.0)
        expect(rows.map(&:project_id).uniq).to eq([H::PROJECT_HOURS])
      end

      it 'has a row with no activity and a row with no issue, so both empty buckets exist' do
        expect(rows.count { |e| e.activity_id.nil? }).to eq(1)
        expect(rows.count { |e| e.issue_id.nil? }).to eq(1)
      end

      # THE ROUNDING GUARD NEEDS AN UNREPRESENTABLE BUCKET, or deleting `number`'s
      # `.round(2)` is a mutation nothing can see — measured, and it was: the first fixture
      # put the 4.0 row in the same activity bucket, and 0.1 + 0.2 + 4.0 is exact.
      it 'has a bucket whose float sum is not exactly representable' do
        raw = rows.select { |e| e.activity_id == H::ACTIVITY_DESIGN }.map(&:hours)

        expect(raw.sort).to eq([0.1, 0.2])
        expect(raw.sum).not_to eq(0.3)
        expect(raw.sum.round(2)).to eq(0.3)
      end

      it 'has at least two buckets on every dimension the oracle knows' do
        RRD_RUBY_KEY.each_key do |dimension|
          next if dimension == 'project' # one project by construction — see hours_scope

          expect(ruby_hours(rows, dimension).size).to be >= 2, "#{dimension} has one bucket"
        end
      end
    end

    # ----------------------------------------------------------------
    # THE ORACLE. Every dimension, both measures, computed twice.
    # ----------------------------------------------------------------

    describe 'hours per bucket' do
      RRD_RUBY_KEY.each_key do |dimension|
        it "agrees with a Ruby sum, grouped by #{dimension}" do
          result = breakdown(group_by: dimension)

          expect(result).not_to be_nil, "the module refused group_by: #{dimension}"
          expect(figures(result)).to eq(ruby_hours(rows, dimension))
        end
      end
    end

    describe 'entry counts per bucket' do
      RRD_RUBY_KEY.each_key do |dimension|
        it "agrees with a Ruby count, grouped by #{dimension}" do
          result = breakdown(group_by: dimension, measure: 'count')

          expect(figures(result)).to eq(ruby_counts(rows, dimension))
        end
      end
    end

    describe 'the scalar total' do
      it 'agrees with a Ruby sum of every visible row' do
        expected = rows.sum(&:hours).to_f.round(2)

        expect(breakdown(group_by: 'activity')['total']).to eq(expected)
      end

      it 'agrees with a Ruby count of every visible row for the count measure' do
        result = breakdown(group_by: 'activity', measure: 'count')

        expect(result['total']).to eq(rows.size)
      end

      # THE CAP MUST NOT SHRINK IT. Folding the tail into `(other)` preserves the sum, and
      # reading the scalar from the scope is independent of the axis entirely — either way
      # this must hold, which is why it is asserted rather than assumed.
      it 'counts the folded tail too, so a capped axis still totals everything' do
        result = breakdown(group_by: 'activity', limit: 1)

        expect(result['total']).to eq(rows.sum(&:hours).to_f.round(2))
      end
    end

    # ----------------------------------------------------------------
    # FR-48 / G6: the statement count is FIXED. It does not scale with the number of
    # buckets, and it is not the same for both measures — which is the observable that
    # makes `total`'s two branches distinguishable at all. See `total`'s own comment: the
    # scalar and the bucket sum are provably EQUAL here, so an example comparing figures
    # can never tell them apart, and a mutation swapping them stayed green until this.
    # ----------------------------------------------------------------

    describe 'the statement count' do
      def statements(**options)
        relation = scope # outside the counter: the first `let` evaluation runs User.find
        H.count_queries { described_class.breakdown(relation, **options) }
      end

      # grouped read + one label lookup + the scalar total.
      it 'costs three statements for an hours breakdown' do
        expect(statements(group_by: 'activity').length).to eq(3)
      end

      # grouped read + one label lookup. NO scalar — a counted axis is totalled from the
      # buckets, exactly as `QueryAggregator.result_total` does it.
      it 'costs two for a count breakdown, because the total needs no statement' do
        expect(statements(group_by: 'activity', measure: 'count').length).to eq(2)
      end

      # ONE LABEL LOOKUP, NEVER ONE PER BUCKET. `issue` has three buckets and `project` has
      # one, and both cost the same — which is what FR-48 actually forbids.
      it 'does not grow with the number of buckets' do
        expect(statements(group_by: 'issue').length)
          .to eq(statements(group_by: 'project').length)
      end
    end

    # ----------------------------------------------------------------
    # INV-1: the ACTOR decides, and a different actor gets a different answer.
    # ----------------------------------------------------------------

    describe 'visibility' do
      # The discriminating actor. The manager and the developer are both entitled in
      # PROJECT_HOURS and therefore see the same rows — which is honest and is also why
      # they cannot demonstrate this. The reporter holds no time-entry role here at all.
      it 'answers an unentitled actor with nothing rather than with somebody else\'s hours' do
        result = described_class.breakdown(H.hours_scope(:reporter), group_by: 'activity')

        expect(rows(:reporter)).to be_empty
        expect(result['buckets']).to eq([])
        expect(result['total']).to eq(0)
      end

      # The 40 archived hours are the largest single figure in the fixture, so a scope
      # that lost its visibility condition would show up in EVERY assertion above — but
      # only as a wrong number. Named here so the reason is greppable.
      it 'never surfaces the archived project\'s hours in any bucket or in the total' do
        result = breakdown(group_by: 'project')

        expect(result['buckets'].map { |b| b['value'] }).to eq([H::PROJECT_HOURS.to_s])
        expect(result['total']).to eq(rows.sum(&:hours).to_f.round(2))
        expect(result['total']).to be < 40.0
      end
    end

    # ----------------------------------------------------------------
    # The issues join is asked about, not assumed.
    # ----------------------------------------------------------------

    describe 'a scope with no issues join' do
      let(:unjoined) { H.hours_scope(actor, joined: false) }

      it 'still answers every own-table dimension' do
        %w[activity user project issue].each do |dimension|
          result = described_class.breakdown(unjoined, group_by: dimension)

          expect(result).not_to be_nil, "refused own-table dimension #{dimension}"
          expect(figures(result)).to eq(ruby_hours(rows, dimension))
        end
      end

      # REFUSED, not answered with SQL that binds to nothing — and the refusal reaches
      # the author. An engine would either error or, worse, resolve `issues.tracker_id`
      # against some other join.
      it 'refuses every issue-table dimension, visibly' do
        %w[tracker status priority author assignee version category].each do |dimension|
          diagnostics = RrdFakeDiagnostics.new
          result = described_class.breakdown(unjoined, group_by: dimension,
                                                       diagnostics: diagnostics)

          expect(result).to be_nil, "answered issue dimension #{dimension} without the join"
          expect(diagnostics.codes).to eq([:aggregation_dimension_unavailable])
        end
      end

      # AND IT REFUSES WITHOUT ASKING THE DATABASE, which is the only thing that separates
      # the GUARD from the `rescue ActiveRecord::StatementInvalid` behind it. MUTATION-TESTED
      # and this example is the reason it exists: with `applicable?` forced to `true` — and
      # again with `joined_to_issues?` forced to `true` — every assertion above still passed,
      # because PostgreSQL raised on `issues.tracker_id`, the rescue swallowed it and the
      # answer was nil either way. Two guards, both provably dead, in a green run.
      #
      # The difference is real and not stylistic. A rescue that turns a malformed statement
      # into nil depends on the engine raising: a scope that happens to carry an unrelated
      # `issues` reference, or an engine that resolves the column against another join, gets
      # a NUMBER out of the same code path. Zero queries is the observable that says the
      # refusal was a decision.
      it 'refuses before issuing any statement at all, which the rescue behind it cannot' do
        # RESOLVED OUTSIDE THE COUNTER. `unjoined` is a `let`, and its first evaluation runs
        # `User.find` to build the actor — one query, counted, and the example failed on its
        # own fixture setup rather than on the subject.
        relation = unjoined

        %w[tracker status priority author assignee version category].each do |dimension|
          queries = H.count_queries do
            described_class.breakdown(relation, group_by: dimension)
          end

          expect(queries).to eq([]), "#{dimension} reached the database: #{queries.inspect}"
        end
      end
    end

    # ----------------------------------------------------------------
    # Defect D-1: MariaDB truncates a RETURNED COLUMN LABEL at 256 characters, so a
    # grouped `.sum`/`.average`/`.count` — which keys its Hash by the group expression's
    # own text — loses every key past that. `Accept:` clause 5 is that this module never
    # reads a grouped aggregate that way, and `spec/aggregation/time_entry_aggregator_
    # source_spec.rb` asserts it of the source. THIS example asserts the positional read
    # is CORRECT at a length where the label read cannot be, on every engine.
    # ----------------------------------------------------------------

    describe 'a group expression longer than 256 characters' do
      # Equal to `time_entries.activity_id` by construction and ~390 characters long.
      # `COALESCE` rather than a comment or a cast because all three engines accept it,
      # its type is the column's, and nothing about it is adapter-specific.
      let(:long_expression) { "COALESCE(time_entries.activity_id#{', NULL' * 60})" }

      it 'is actually past the limit, or this example proves nothing' do
        expect(long_expression.length).to be > 256
      end

      it 'reads its keys correctly when they are read BY POSITION' do
        plucked = scope.unscope(:order)
                       .group(::Arel.sql(long_expression))
                       .pluck(::Arel.sql(long_expression),
                              ::Arel.sql('SUM(time_entries.hours)'))
                       .each_with_object({}) { |(key, value), out| out[key&.to_s] = value.to_f.round(2) }

        expect(plucked).to eq(ruby_hours(rows, 'activity'))
      end

      # AND THE LABEL READ IS WHERE THE DEFECT LIVES — MEASURED HERE, not quoted from the
      # handover. On MariaDB 10.11 this run produced:
      #
      #   [D-1] Mysql2 label-keyed grouped .sum over a 394-char expression: DIVERGES ([nil])
      #
      # Three buckets collapsed into ONE nil key and the figure came back 3.75 against a real
      # 8.8 — the last group's hours, wearing the total's name. That is the defect entire, and
      # it is why `Accept:` clause 5 is a rule about how the read is SPELLED rather than a
      # warning in a comment.
      #
      # THE ASSERTION IS SCOPED TO THE ENGINE IT WAS MEASURED ON. Asserting divergence
      # everywhere would be asserting a bug this run never saw on PostgreSQL (where the
      # message says `agrees`), and asserting agreement everywhere is what the defect refutes.
      # On the other engines the measurement is REPORTED and nothing is claimed — INV-7's rule
      # applied to a defect rather than to a version. A MariaDB that one day fixed this goes
      # red here, which is the right way to find out.
      it 'records what the label read does on this engine, and pins it where it is known' do
        keyed = scope.unscope(:order).group(::Arel.sql(long_expression))
                     .sum(::Arel.sql('time_entries.hours'))
        agrees = keyed.transform_keys { |key| key&.to_s }
                      .transform_values { |value| value.to_f.round(2) } == ruby_hours(rows, 'activity')

        RSpec.configuration.reporter.message(
          "[D-1] #{H.adapter_name} label-keyed grouped .sum over a " \
          "#{long_expression.length}-char expression: #{agrees ? 'agrees' : 'DIVERGES'} " \
          "(keys #{keyed.keys.inspect}, total #{keyed.values.sum.to_f.round(2)} " \
          "against a real #{rows.sum(&:hours).to_f.round(2)})"
        )

        if H.mariadb?
          expect(agrees).to be(false),
                            'MariaDB no longer truncates the returned column label — D-1 may ' \
                            'be fixed upstream. Re-measure before relaxing anything that ' \
                            'depends on it, starting with QueryAggregator#raw_measure.'
        end
      end
    end

    # ----------------------------------------------------------------
    # `COUNT(DISTINCT time_entries.id)` — and the LIMIT it does not cover.
    # ----------------------------------------------------------------
    #
    # MUTATION-TESTED, AND IT SURVIVED FIRST: dropping the `DISTINCT` left the whole suite
    # green, because nothing in the fixture's joins duplicates a row. So the example that
    # earns its place is one over a scope that DOES — and it exposes something the DISTINCT
    # cannot fix, recorded here rather than left to be discovered.
    describe 'a scope whose joins duplicate rows' do
      # Three roles in the fixture and `1=1`, so every time entry comes back three times.
      # Blunt on purpose: what matters is that the duplication is exact and knowable, not
      # that it resembles a particular Redmine filter.
      let(:tripled) { scope.joins('INNER JOIN roles rrd_dup ON 1=1') }

      it 'triples the rows, or this example proves nothing' do
        expect(::Role.count).to eq(3)
        expect(tripled.count).to eq(rows.size * 3)
      end

      # THE COUNT MEASURE IS RIGHT ANYWAY, which is what `DISTINCT time_entries.id` buys.
      it 'still counts each entry once' do
        result = described_class.breakdown(tripled, group_by: 'activity', measure: 'count')

        expect(figures(result)).to eq(ruby_counts(rows, 'activity'))
      end

      # AND THE HOURS MEASURE IS NOT, WHICH IS A DOCUMENTED LIMIT RATHER THAN A SURPRISE.
      # `SUM` has no `DISTINCT` that helps: `SUM(DISTINCT hours)` would collapse two
      # genuinely separate entries that logged the same number of hours, which is worse. The
      # correct fix is a derived table, and that is a design change beyond this task's
      # `Accept:` list — reported, not absorbed (CLAUDE.md §11.5).
      #
      # Asserted as the CURRENT behaviour so it is visible in the suite and moves the day
      # somebody fixes it, rather than sitting in a comment nobody runs. Every scope the two
      # callers actually build reaches this module through `TimeEntryQuery#base_scope`, whose
      # joins are `belongs_to` and whose custom-field filters are subqueries — none of them
      # duplicates a row.
      it 'over-counts HOURS on such a scope, and no DISTINCT can fix a SUM' do
        result = described_class.breakdown(tripled, group_by: 'activity')
        expected = ruby_hours(rows, 'activity').transform_values { |v| (v * 3).round(2) }

        expect(figures(result)).to eq(expected)
      end
    end

    # ----------------------------------------------------------------
    # The engines have to accept the SQL, not merely answer it.
    # ----------------------------------------------------------------

    describe 'ONLY_FULL_GROUP_BY' do
      it 'is accepted under the strictest GROUP BY mode a production server can be set to' do
        H.with_only_full_group_by do
          RRD_RUBY_KEY.each_key do |dimension|
            result = breakdown(group_by: dimension)
            expect(figures(result)).to eq(ruby_hours(rows, dimension)), dimension
          end
        end
      end
    end

    # ----------------------------------------------------------------
    # The cap, AT the limit and ONE PAST it (CLAUDE.md §3, phase 3).
    # ----------------------------------------------------------------

    describe 'the axis cap' do
      let(:keys) { ruby_hours(rows, 'activity').size }

      it 'has three activity buckets, so at-the-limit and one-past are distinguishable' do
        expect(keys).to eq(3)
      end

      it 'folds nothing AT the limit' do
        result = breakdown(group_by: 'activity', limit: keys)

        expect(result['truncated']).to be(false)
        expect(result['buckets'].size).to eq(keys)
        expect(figures(result)).to eq(ruby_hours(rows, 'activity'))
      end

      it 'folds nothing one INSIDE the limit either' do
        result = breakdown(group_by: 'activity', limit: keys + 1)

        expect(result['truncated']).to be(false)
        expect(result['buckets'].size).to eq(keys)
      end

      # ONE PAST IT: the tail is folded into a single bucket whose figure is the Ruby sum
      # of exactly the buckets that were dropped, and `truncated` SAYS SO (INV-4).
      it 'folds the tail one PAST the limit and says it did' do
        result = breakdown(group_by: 'activity', limit: keys - 1)
        expected = ruby_hours(rows, 'activity').values.sort.reverse

        expect(result['truncated']).to be(true)
        expect(result['buckets'].size).to eq(keys)
        expect(result['buckets'].last['label']).to eq(described_class::DEFAULT_OTHER_LABEL)
        expect(result['buckets'].last['count']).to eq(expected.last)
      end

      it 'folds everything but one at limit 1' do
        result = breakdown(group_by: 'activity', limit: 1)
        expected = ruby_hours(rows, 'activity').values.sort.reverse

        expect(result['buckets'].size).to eq(2)
        expect(result['buckets'].first['count']).to eq(expected.first)
        expect(result['buckets'].last['count']).to eq(expected.drop(1).sum.round(2))
      end
    end

    # ----------------------------------------------------------------
    # Labels and the shared vocabulary (FR-60).
    # ----------------------------------------------------------------

    describe 'labels' do
      def labels(result)
        result['buckets'].map { |b| b['label'] }
      end

      it 'names the activities, and never one nothing was logged against' do
        result = breakdown(group_by: 'activity')

        expect(labels(result)).to include('Design', 'Development')
        expect(labels(result)).not_to include('Unused')
      end

      # `Principal#name`, NOT the login. Redmine's `users` table has no `name` column, so
      # a `pluck(:id, :name)` fell back to `:login` and put `alice` on the axis where the
      # rest of Redmine shows `Alice Adams`.
      it 'names users the way the rest of Redmine names them' do
        result = breakdown(group_by: 'user')

        expect(labels(result)).to include('Alice Adams', 'Bob Brown')
        expect(labels(result)).not_to include('alice')
        expect(labels(result)).not_to include('bob')
      end

      it 'labels an issue bucket with its id and its subject' do
        result = breakdown(group_by: 'issue')

        expect(labels(result)).to include("##{H::HOURS_ISSUE_BUG}: billable bug")
      end

      it 'labels the empty bucket, and lets a caller rename it' do
        expect(labels(breakdown(group_by: 'activity'))).to include(described_class::EMPTY_LABEL)
        expect(labels(breakdown(group_by: 'activity', empty_label: 'unclassified')))
          .to include('unclassified')
      end
    end

    describe 'the result vocabulary' do
      # THE KEYS ARE THE ISSUE KERNEL'S, compared against a REAL call rather than
      # against a list copied out of it — FR-60 is that a template written for one source
      # reads the other, and a copied list agrees with a kernel that has moved on.
      it 'has exactly the keys the issue kernel\'s dimension_breakdown answers' do
        issue_result = H.as_actor(:manager) do
          SqlAggregation::QueryAggregator.dimension_breakdown(
            H.base_scope.where(project_id: H::PROJECT_MAIN), group_by: 'status'
          )
        end

        expect(breakdown(group_by: 'activity').keys.sort).to eq(issue_result.keys.sort)
      end

      it 'has the issue kernel\'s bucket keys too' do
        issue_result = H.as_actor(:manager) do
          SqlAggregation::QueryAggregator.dimension_breakdown(
            H.base_scope.where(project_id: H::PROJECT_MAIN), group_by: 'status'
          )
        end

        expect(breakdown(group_by: 'activity')['buckets'].first.keys.sort)
          .to eq(issue_result['buckets'].first.keys.sort)
      end

      it 'names the measure and its field, so a reader can tell hours from a row count' do
        expect(breakdown(group_by: 'activity').values_at('measure', 'measure_field'))
          .to eq(%w[hours hours])
        expect(breakdown(group_by: 'activity', measure: 'count')
                 .values_at('measure', 'measure_field')).to eq(['count', nil])
      end

      it 'carries a drill-through filter naming the dimension\'s own field' do
        bucket = breakdown(group_by: 'activity')['buckets']
                 .find { |b| b['value'] == H::ACTIVITY_DESIGN.to_s }

        expect(bucket['filter']).to eq('field' => 'activity_id', 'operator' => '=',
                                       'values' => [H::ACTIVITY_DESIGN.to_s])
      end

      it 'filters the empty bucket with the none operator rather than an empty value list' do
        bucket = breakdown(group_by: 'activity')['buckets'].find { |b| b['value'].nil? }

        expect(bucket['filter']).to eq('field' => 'activity_id', 'operator' => '!*',
                                       'values' => [])
      end
    end

    describe 'sorting' do
      it 'orders by figure descending by default' do
        result = breakdown(group_by: 'activity')

        expect(result['buckets'].map { |b| b['count'] })
          .to eq(ruby_hours(rows, 'activity').values.sort.reverse)
      end

      it 'orders by key when asked for a label sort' do
        result = breakdown(group_by: 'activity', sort: 'label')

        # `sort_by(&:to_s)` and NOT `map(&:to_s).sort`: the empty bucket's key stays nil all
        # the way to `bucket['value']`, and mapping it to "" first would assert a value the
        # module must not produce — a drill-through filter needs nil to mean "unset".
        expect(result['buckets'].map { |b| b['value'] })
          .to eq(ruby_hours(rows, 'activity').keys.sort_by(&:to_s))
      end
    end

    describe 'refusals' do
      it 'refuses an unknown dimension visibly and answers nil' do
        diagnostics = RrdFakeDiagnostics.new

        expect(breakdown(group_by: 'activty', diagnostics: diagnostics)).to be_nil
        expect(diagnostics.codes).to eq([:aggregation_dimension_unknown])
      end

      it 'refuses an unknown measure visibly and answers nil' do
        diagnostics = RrdFakeDiagnostics.new

        expect(breakdown(group_by: 'activity', measure: 'median',
                         diagnostics: diagnostics)).to be_nil
        expect(diagnostics.codes).to eq([:aggregation_measure_unknown])
      end

      it 'says WHICH argument it refused, so the author can fix it' do
        diagnostics = RrdFakeDiagnostics.new
        breakdown(group_by: 'activty', diagnostics: diagnostics)

        expect(diagnostics.records.first[:data]).to include(group_by: 'activty')
        expect(diagnostics.records.first[:detail]).to include('activty')
      end
    end
  end
end
