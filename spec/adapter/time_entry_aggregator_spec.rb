# frozen_string_literal: true
#
# T-31 `Accept:` clauses 6 and 7 — the OWNED TIME-ENTRY AGGREGATOR, proved by a SECOND
# COMPUTATION rather than by a recorded file, against a real database engine.
#
# --- WHY THERE IS NO GOLDEN CORPUS FOR THIS ---
#
# The aggregation corpus next door exists to answer "has this behaviour MOVED", which is
# what `spec/golden/README.md` says of it in as many words. That question needs a previous
# answer to compare against, and it is the right question for the issue kernel, whose
# numbers are a v0.5.0 artefact under gate G7. This module was written this week. A recorded
# file here would freeze whatever it happened to answer on its first day — bugs included —
# and then report the bug's later removal as a regression.
#
# So every figure below is computed TWICE: once through this module (SQL, `GROUP BY`, `SUM`)
# and once by loading the rows and adding them up in Ruby. Two independent computations
# agreeing is a correctness claim. The Ruby side is written out longhand (see RRD_RUBY_KEY)
# rather than borrowed from `DIMENSIONS`, because an oracle that reads the implementation's
# own table agrees with it by construction — planting six wrong `sql:` values is how that
# was checked rather than asserted.
#
# --- WHAT THE ORACLE ALONE CANNOT SEE, AND WHERE THAT LIVES INSTEAD ---
#
# An independent review of the first version found six defects while every figure still
# agreed: no axis ceiling, ties ordered by engine row order, `sort: label` sorting by raw
# id, the cap swallowing `(none)` into `(other)`, `(other)` carrying no `values`, and — the
# blocker — the `issue` dimension printing the subject of an issue the actor may not see.
# Value agreement was never going to catch those. So the boundary and ordering cases are in
# `spec/aggregation/time_entry_aggregator_source_spec.rb`, where a double controls the rows
# exactly; the drill-through filter NAMES are checked against a real `TimeEntryQuery` in
# `test/unit/reporter_dashboards_time_entry_aggregator_test.rb`, which is the only place one
# exists; and what stays here is everything that needs a real engine.
#
# --- WHY IT LIVES IN spec/adapter/ ---
#
# `SUM` over a `float` column, `COUNT(DISTINCT …)`, `COALESCE` in a `GROUP BY`, a
# `LEFT OUTER JOIN` next to it, and `ONLY_FULL_GROUP_BY` are all things PostgreSQL, MySQL 8
# and MariaDB 11 do differently or accept differently. The `adapter` CI job runs this
# directory against all three.
#
# See spec/adapter/adapter_helper.rb for the fixture (PROJECT_HOURS, HOURS_ENTRIES).

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

  # The activity roll-up, computed the other way round: one lookup per id rather than a
  # `COALESCE` inside the `GROUP BY`. Deliberately NOT reading the module's
  # `ACTIVITY_EXPRESSION`.
  module RrdTimeEntryOracle
    module_function

    def rolled_up_activity(activity_id)
      return nil if activity_id.nil?

      ::TimeEntryActivity.find_by(id: activity_id)&.parent_id || activity_id
    end
  end

  # THE ORACLE'S OWN DIMENSION TABLE, written out rather than derived from
  # `described_class::DIMENSIONS`. Each lambda answers "which key does THIS row belong to",
  # in Ruby. It takes the entry and its VISIBLE issue — resolved by the caller through
  # `Issue.visible(actor)` — because that is the independent path to the same fact core's
  # `left_join_issue` reaches by putting `Issue.visible_condition` in its ON clause.
  #
  # The first version followed `e.issue` unscoped, which encoded the NO-visibility semantics
  # and would have agreed with a leak on the issue dimensions too. An independent review
  # caught it in the harness comment before it caught it in the code.
  RRD_RUBY_KEY = {
    'activity' => ->(e, _issue) { RrdTimeEntryOracle.rolled_up_activity(e.activity_id) },
    'user' => ->(e, _issue) { e.user_id },
    'project' => ->(e, _issue) { e.project_id },
    'issue' => ->(e, _issue) { e.issue_id },
    'tracker' => ->(_e, issue) { issue&.tracker_id },
    'status' => ->(_e, issue) { issue&.status_id },
    'version' => ->(_e, issue) { issue&.fixed_version_id },
    'category' => ->(_e, issue) { issue&.category_id }
  }.freeze

  RSpec.describe RedmineReporterDashboards::Aggregation::TimeEntryAggregator do
    let(:actor_name) { :manager }
    let(:actor) { H.actor(actor_name) }
    let(:scope) { H.hours_scope(actor_name) }

    # The rows the report is over. `to_a` and not `pluck`: the oracle reads attributes and
    # follows `issue`, which is the whole point of computing it the other way round.
    def rows(for_actor = actor_name)
      H.hours_scope(for_actor).to_a
    end

    # Which issue ids this actor may actually see — one query, and the oracle's own reading
    # of the rule the SQL applies inside the join.
    def visible_issue_ids(for_actor = actor_name)
      @visible_issue_ids ||= {}
      @visible_issue_ids[for_actor] ||= ::Issue.visible(H.actor(for_actor)).pluck(:id)
    end

    def issue_of(entry, for_actor = actor_name)
      return nil if entry.issue_id.nil?
      return nil unless visible_issue_ids(for_actor).include?(entry.issue_id)

      entry.issue
    end

    def ruby_keyed(entries, dimension, for_actor = actor_name)
      reader = RRD_RUBY_KEY.fetch(dimension)
      entries.group_by { |entry| reader.call(entry, issue_of(entry, for_actor)) }
    end

    # The Ruby half. Rounded to two places for the reason `number` is: `0.1 + 0.2` is
    # 0.30000000000000004 in Ruby AND in every engine's float arithmetic, and the two need
    # not agree on the last bit. An oracle comparing raw floats would be red or green by luck.
    def ruby_hours(entries, dimension, for_actor = actor_name)
      ruby_keyed(entries, dimension, for_actor)
        .transform_values { |group| group.sum(&:hours).to_f.round(2) }
        .transform_keys { |key| key&.to_s }
    end

    def ruby_counts(entries, dimension, for_actor = actor_name)
      ruby_keyed(entries, dimension, for_actor)
        .transform_values { |group| group.map(&:id).uniq.size }
        .transform_keys { |key| key&.to_s }
    end

    # The module's half, reduced to `{key => figure}` so the comparison is about NUMBERS and
    # never about labels. `(other)` is excluded by its `values` key — it is the only bucket
    # that carries one — because it and `(none)` both have `value: nil` and would collide.
    def figures(result)
      result['buckets'].reject { |b| b.key?('values') }
                       .each_with_object({}) { |b, out| out[b['value']] = b['count'] }
    end

    def labels(result)
      result['buckets'].map { |b| b['label'] }
    end

    def breakdown(**options)
      described_class.breakdown(scope, **{ actor: actor }.merge(options))
    end

    # ----------------------------------------------------------------
    # The fixture is what we think it is. Without this, an empty fixture would make every
    # agreement below vacuously true — two ways of computing nothing agree.
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
      # `.round(2)` is a mutation nothing can see. MEASURED TWICE: a bucket of 0.1 + 0.2 + 4.0
      # is exact, and so is 0.1 + 0.2 + 0.5 — the nearest double to `0.8` IS
      # 0.80000000000000004441. Only `0.1 + 0.2` against `0.3` diverges, so the fixture keeps
      # those two rows alone in ACTIVITY_ANALYSIS, and this example fails if they stop being
      # alone.
      it 'has an activity bucket whose float sum is not exactly representable' do
        raw = rows.select { |e| RrdTimeEntryOracle.rolled_up_activity(e.activity_id) == H::ACTIVITY_ANALYSIS }
                  .map(&:hours)

        expect(raw.sort).to eq([0.1, 0.2])
        expect(raw.sum).not_to eq(0.3)
        expect(raw.sum.round(2)).to eq(0.3)
      end

      # THE OVERRIDE IS PRESENT AND IS A CHILD, or the roll-up examples prove nothing.
      it 'has an activity overridden by a project, carrying its parent\'s name' do
        parent = ::TimeEntryActivity.find(H::ACTIVITY_DESIGN)
        child  = ::TimeEntryActivity.find(H::ACTIVITY_DESIGN_LOCAL)

        expect(child.parent_id).to eq(parent.id)
        expect(child.name).to eq(parent.name)
        expect(rows.count { |e| e.activity_id == child.id }).to eq(1)
      end

      # THE DISCLOSURE FIXTURE. The entry is visible; its issue is not.
      it 'has a visible entry pointing at an issue no actor may see' do
        entry = rows.find { |e| e.issue_id == H::HOURS_ISSUE_HIDDEN }

        expect(entry).not_to be_nil
        expect(visible_issue_ids).not_to include(H::HOURS_ISSUE_HIDDEN)
        expect(::Issue.find(H::HOURS_ISSUE_HIDDEN).subject).to eq('CONFIDENTIAL ACQUISITION')
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

    # ----------------------------------------------------------------
    # The activity roll-up (an independent review's finding 6).
    # ----------------------------------------------------------------

    describe 'a project-overridden activity' do
      # ONE BUCKET, not two identically-labelled ones — `time_report.rb:125`.
      it 'rolls the project-local child up to its parent, as core does' do
        result = breakdown(group_by: 'activity')

        expect(labels(result).count('Design')).to eq(1)
        expect(result['buckets'].map { |b| b['value'] })
          .not_to include(H::ACTIVITY_DESIGN_LOCAL.to_s)
      end

      it 'puts the child\'s hours in the parent\'s bucket rather than losing them' do
        result = breakdown(group_by: 'activity')
        design = result['buckets'].find { |b| b['value'] == H::ACTIVITY_DESIGN.to_s }
        expected = rows.select { |e| [H::ACTIVITY_DESIGN, H::ACTIVITY_DESIGN_LOCAL].include?(e.activity_id) }
                       .sum(&:hours).to_f.round(2)

        expect(design['count']).to eq(expected)
      end
    end

    # ----------------------------------------------------------------
    # INV-1 / G5: the ACTOR decides, and the `issue` label is the one that had to be told.
    # ----------------------------------------------------------------

    describe 'visibility' do
      # THE BLOCKER AN INDEPENDENT REVIEW MEASURED. `time_entries.issue_id` is a column on
      # the entry, so it survives the visibility condition core puts in `left_join_issue` —
      # and the first version read the subject off an unscoped `Issue.where(id: ids)`. The
      # actor's own hours report printed the private issue's subject, and on the scheduled
      # path that output is mailed to other people. Redmine prints `"##{id}"`
      # (`timelog_helper.rb:80-85`, `application_helper.rb:307`); so does this.
      it 'labels an invisible issue with its id and never with its subject' do
        result = breakdown(group_by: 'issue')
        bucket = result['buckets'].find { |b| b['value'] == H::HOURS_ISSUE_HIDDEN.to_s }

        expect(bucket).not_to be_nil, 'the hours vanished instead of being attributed'
        expect(bucket['label']).to eq("##{H::HOURS_ISSUE_HIDDEN}")
        expect(labels(result).join(' ')).not_to include('CONFIDENTIAL')
      end

      # AND THE VISIBLE ONES ARE STILL NAMED, or the fix is just "print no labels".
      it 'still labels the issues the actor may see' do
        expect(labels(breakdown(group_by: 'issue')))
          .to include("##{H::HOURS_ISSUE_BUG}: billable bug")
      end

      # FAIL CLOSED WITH NO ACTOR. A caller that forgot to pass one must not get unscoped
      # labels; it gets ids (INV-1/INV-3).
      it 'withholds every issue label when there is no actor' do
        result = described_class.breakdown(scope, group_by: 'issue')

        expect(labels(result)).to include("##{H::HOURS_ISSUE_BUG}")
        expect(labels(result).join(' ')).not_to include('billable bug')
      end

      # The discriminating actor. The manager and the developer are both entitled in
      # PROJECT_HOURS and therefore see the same rows — which is honest and is also why they
      # cannot demonstrate this. The reporter holds no time-entry role here at all.
      it 'answers an unentitled actor with nothing rather than with somebody else\'s hours' do
        result = described_class.breakdown(H.hours_scope(:reporter), group_by: 'activity',
                                                                    actor: H.actor(:reporter))

        expect(rows(:reporter)).to be_empty
        expect(result['buckets']).to eq([])
        expect(result['total']).to eq(0)
      end

      it 'never surfaces the archived project\'s hours in any bucket or in the total' do
        result = breakdown(group_by: 'project')

        expect(result['buckets'].map { |b| b['value'] }).to eq([H::PROJECT_HOURS.to_s])
        expect(result['total']).to eq(rows.sum(&:hours).to_f.round(2))
        expect(result['total']).to be < 40.0
      end

      # AND THE ISSUE-ATTRIBUTE DIMENSIONS FAIL CLOSED BY INHERITANCE, because core puts the
      # condition in the join. The invisible issue's hours land in `(none)`, which is what
      # Redmine's own spent-time report does — asserted so the harness's join cannot quietly
      # lose the condition again (an independent review found it missing there first).
      it 'puts an invisible issue\'s hours in the (none) bucket of every issue dimension' do
        %w[tracker status version category].each do |dimension|
          result = breakdown(group_by: dimension)
          none = result['buckets'].find { |b| b['label'] == described_class::EMPTY_LABEL }

          expect(none).not_to be_nil, "#{dimension} has no (none) bucket"
          expect(none['count']).to eq(ruby_hours(rows, dimension)[nil]), dimension
        end
      end
    end

    # ----------------------------------------------------------------
    # The scalar total.
    # ----------------------------------------------------------------

    describe 'the scalar total' do
      it 'agrees with a Ruby sum of every visible row' do
        expect(breakdown(group_by: 'activity')['total'])
          .to eq(rows.sum(&:hours).to_f.round(2))
      end

      it 'agrees with a Ruby count of every visible row for the count measure' do
        expect(breakdown(group_by: 'activity', measure: 'count')['total']).to eq(rows.size)
      end

      it 'counts the folded tail too, so a capped axis still totals everything' do
        result = breakdown(group_by: 'activity', limit: 1)

        expect(result['total']).to eq(rows.sum(&:hours).to_f.round(2))
      end
    end

    # ----------------------------------------------------------------
    # FR-48 / G6: the statement count is FIXED, and it is what makes `total`'s two branches
    # distinguishable at all — see `total`'s own comment.
    # ----------------------------------------------------------------

    describe 'the statement count' do
      def statements(**options)
        relation = scope # outside the counter: the first `let` evaluation runs User.find
        who = actor
        H.count_queries { described_class.breakdown(relation, actor: who, **options) }
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

      # The `issue` dimension costs ONE MORE, and the extra statement is the visibility check
      # itself — `Issue.visible(actor)` around the label lookup, which is the disclosure fix.
      # Named rather than hidden inside a range, so a change in it is a change somebody reads.
      it 'costs one more for the issue dimension, which is the visibility check' do
        expect(statements(group_by: 'issue').length)
          .to eq(statements(group_by: 'project').length + 1)
      end

      # ONE LABEL LOOKUP, NEVER ONE PER BUCKET. Compared against ITSELF at two bucket counts
      # rather than against another dimension: the count must not depend on how many buckets
      # came back, which is what FR-48 forbids, and comparing two different dimensions would
      # confuse that with the visibility check above.
      it 'does not grow with the number of buckets' do
        expect(statements(group_by: 'activity', limit: 1).length)
          .to eq(statements(group_by: 'activity').length)
        expect(statements(group_by: 'issue', limit: 1).length)
          .to eq(statements(group_by: 'issue').length)
      end
    end

    # ----------------------------------------------------------------
    # The issues join is asked about, not assumed.
    # ----------------------------------------------------------------

    describe 'a scope with no issues join' do
      let(:unjoined) { H.hours_scope(actor_name, joined: false) }

      it 'still answers every own-table dimension' do
        %w[activity user project issue].each do |dimension|
          result = described_class.breakdown(unjoined, group_by: dimension, actor: actor)

          expect(result).not_to be_nil, "refused own-table dimension #{dimension}"
          expect(figures(result)).to eq(ruby_hours(rows, dimension))
        end
      end

      it 'refuses every issue-table dimension, visibly' do
        %w[tracker status version category].each do |dimension|
          diagnostics = RrdFakeDiagnostics.new
          result = described_class.breakdown(unjoined, group_by: dimension, actor: actor,
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
      it 'refuses before issuing any statement at all, which the rescue behind it cannot' do
        relation = unjoined
        who = actor

        %w[tracker status version category].each do |dimension|
          queries = H.count_queries do
            described_class.breakdown(relation, group_by: dimension, actor: who)
          end

          expect(queries).to eq([]), "#{dimension} reached the database: #{queries.inspect}"
        end
      end
    end

    # ----------------------------------------------------------------
    # Defect D-1: MariaDB truncates a RETURNED COLUMN LABEL at 256 characters, so a grouped
    # `.sum`/`.average`/`.count` — which keys its Hash by the group expression's own text —
    # loses every key past that. `Accept:` clause 5 is that this module never reads a grouped
    # aggregate that way, and `spec/aggregation/time_entry_aggregator_source_spec.rb` asserts
    # it of the source. THIS asserts the positional read is CORRECT at a length where the
    # label read is not, on every engine.
    # ----------------------------------------------------------------

    describe 'a group expression longer than 256 characters' do
      # Equal to `time_entries.activity_id` by construction and ~390 characters long.
      # `COALESCE` rather than a comment or a cast because all three engines accept it, its
      # type is the column's, and nothing about it is adapter-specific.
      let(:long_expression) { "COALESCE(time_entries.activity_id#{', NULL' * 60})" }

      # NOT rolled up, deliberately: this is about the READ, so it groups on the raw column
      # and compares against the raw column.
      let(:raw_activity_hours) do
        rows.group_by(&:activity_id)
            .transform_values { |group| group.sum(&:hours).to_f.round(2) }
            .transform_keys { |key| key&.to_s }
      end

      it 'is actually past the limit, or this example proves nothing' do
        expect(long_expression.length).to be > 256
      end

      it 'reads its keys correctly when they are read BY POSITION' do
        plucked = scope.unscope(:order)
                       .group(::Arel.sql(long_expression))
                       .pluck(::Arel.sql(long_expression),
                              ::Arel.sql('SUM(time_entries.hours)'))
                       .each_with_object({}) { |(key, value), out| out[key&.to_s] = value.to_f.round(2) }

        expect(plucked).to eq(raw_activity_hours)
      end

      # AND THE LABEL READ IS WHERE THE DEFECT LIVES — MEASURED HERE, not quoted from the
      # handover. On MariaDB 10.11:
      #
      #   [D-1] Mysql2 label-keyed grouped .sum over a 394-char expression: DIVERGES ([nil])
      #
      # Buckets collapsed into ONE nil key and the figure was the last group's hours wearing
      # the total's name. That is the defect entire, and it is why `Accept:` clause 5 is a
      # rule about how the read is SPELLED rather than a warning in a comment.
      #
      # THE ASSERTION IS SCOPED TO THE ENGINE IT WAS MEASURED ON. Asserting divergence
      # everywhere would be asserting a bug this run never saw on PostgreSQL (where the
      # message says `agrees`), and asserting agreement everywhere is what the defect refutes.
      # HANDOVER §1 records `MySQL 8.0 does NOT do this`, so only the MariaDB branch is
      # pinned — INV-7's rule applied to a defect rather than to a version. A MariaDB that
      # one day fixed this goes red here, which is the right way to find out.
      it 'records what the label read does on this engine, and pins it where it is known' do
        keyed = scope.unscope(:order).group(::Arel.sql(long_expression))
                     .sum(::Arel.sql('time_entries.hours'))
        agrees = keyed.transform_keys { |key| key&.to_s }
                      .transform_values { |value| value.to_f.round(2) } == raw_activity_hours

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
    # `COUNT(DISTINCT time_entries.id)` — and the LIMIT it does not cover (§Findings S-16).
    # ----------------------------------------------------------------

    describe 'a scope whose joins duplicate rows' do
      # `1=1` against the roles table, so every time entry comes back once per role. Blunt on
      # purpose: what matters is that the duplication is exact and knowable, not that it
      # resembles a particular Redmine filter.
      let(:factor) { ::Role.count }
      let(:multiplied) { scope.joins('INNER JOIN roles rrd_dup ON 1=1') }

      it 'multiplies the rows, or this example proves nothing' do
        expect(factor).to be > 1
        expect(multiplied.count).to eq(rows.size * factor)
      end

      it 'still counts each entry once' do
        result = described_class.breakdown(multiplied, group_by: 'activity', measure: 'count',
                                                      actor: actor)

        expect(figures(result)).to eq(ruby_counts(rows, 'activity'))
      end

      # AND THE HOURS MEASURE IS NOT, WHICH IS A DOCUMENTED LIMIT RATHER THAN A SURPRISE.
      # `SUM` has no `DISTINCT` that helps: `SUM(DISTINCT hours)` would collapse two
      # genuinely separate entries that logged the same number of hours, which is worse. The
      # correct fix is a derived table, and that is a design change beyond this task's
      # `Accept:` list — reported, not absorbed (CLAUDE.md §11.5, §Findings S-16).
      #
      # Asserted as the CURRENT behaviour so it is visible in the suite and moves the day
      # somebody fixes it. Every scope the two callers build reaches this module through
      # `TimeEntryQuery#base_scope`, whose joins are `belongs_to` and whose custom-field
      # filters are subqueries — none of them duplicates a row.
      it 'over-counts HOURS on such a scope, and no DISTINCT can fix a SUM' do
        result = described_class.breakdown(multiplied, group_by: 'activity', actor: actor)
        expected = ruby_hours(rows, 'activity')
                   .transform_values { |value| (value * factor).round(2) }

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
    # Labels and the shared vocabulary (FR-60).
    # ----------------------------------------------------------------

    describe 'labels' do
      it 'names the activities, and never one nothing was logged against' do
        result = breakdown(group_by: 'activity')

        expect(labels(result)).to include('Design', 'Development', 'Analysis')
        expect(labels(result)).not_to include('Unused')
      end

      # `Principal#name`, NOT the login. Redmine's `users` table has no `name` column, so a
      # `pluck(:id, :name)` fell back to `:login` and put `alice` on the axis where the rest
      # of Redmine — and the issue kernel, `query_aggregator.rb:1822` — shows `Alice Adams`.
      it 'names users the way the rest of Redmine names them' do
        result = breakdown(group_by: 'user')

        expect(labels(result)).to include('Alice Adams', 'Bob Brown')
        expect(labels(result)).not_to include('alice')
        expect(labels(result)).not_to include('bob')
      end

      it 'labels an issue bucket with its id and its subject' do
        expect(labels(breakdown(group_by: 'issue')))
          .to include("##{H::HOURS_ISSUE_BUG}: billable bug")
      end

      it 'labels the empty bucket, and lets a caller rename it' do
        expect(labels(breakdown(group_by: 'activity'))).to include(described_class::EMPTY_LABEL)
        expect(labels(breakdown(group_by: 'activity', empty_label: 'unclassified')))
          .to include('unclassified')
      end
    end

    describe 'sorting' do
      it 'orders by figure descending by default' do
        result = breakdown(group_by: 'activity')

        expect(result['buckets'].reject { |b| b['value'].nil? }.map { |b| b['count'] })
          .to eq(ruby_hours(rows, 'activity').reject { |key, _| key.nil? }.values.sort.reverse)
      end

      # `sort: label` SORTS BY THE LABEL, and the fixture can now tell that apart from a sort
      # by raw id: `Analysis` has the HIGHEST activity id and the SMALLEST figure, so a label
      # sort disagrees with both alternatives at once. The first version sorted by the raw id
      # and its own example was named "orders by key when asked for a label sort".
      it 'orders by the label, not by the raw key, when asked for a label sort' do
        result = breakdown(group_by: 'activity', sort: 'label')
        named = result['buckets'].reject { |b| b['value'].nil? }

        expect(named.map { |b| b['label'] }).to eq(%w[Analysis Design Development])
        expect(named.map { |b| b['value'] })
          .to eq([H::ACTIVITY_ANALYSIS, H::ACTIVITY_DESIGN, H::ACTIVITY_DEVELOPMENT].map(&:to_s))
      end

      # BOTH SYNTHETIC BUCKETS STAY LAST, whatever `sort` says — `build_axis`'s rule
      # (`query_aggregator.rb:1695-1698`). `(none)` sorts before every label alphabetically,
      # so a label sort that included it would put it first.
      it 'keeps the (none) bucket last under a label sort' do
        result = breakdown(group_by: 'activity', sort: 'label')

        expect(result['buckets'].last['label']).to eq(described_class::EMPTY_LABEL)
      end

      # AN UNSUPPORTED SORT IS A DEGRADATION, NOT A SHRUG. `position` is one of the kernel's
      # three modes and is deliberately not implemented here; the first version fell through
      # for it and for `sort: banana` alike, with nothing logged and nothing on the page.
      it 'degrades visibly on a sort it does not support, and still answers' do
        diagnostics = RrdFakeDiagnostics.new
        result = breakdown(group_by: 'activity', sort: 'position', diagnostics: diagnostics)

        expect(diagnostics.codes).to eq([:aggregation_sort_unsupported])
        expect(figures(result)).to eq(ruby_hours(rows, 'activity'))
      end
    end

    describe 'the result vocabulary' do
      # THE KEYS ARE THE ISSUE KERNEL'S, compared against a REAL call rather than against a
      # list copied out of it — FR-60 is that a template written for one source reads the
      # other, and a copied list agrees with a kernel that has moved on.
      def issue_result
        H.as_actor(:manager) do
          SqlAggregation::QueryAggregator.dimension_breakdown(
            H.base_scope.where(project_id: H::PROJECT_MAIN), group_by: 'status'
          )
        end
      end

      it 'has exactly the keys the issue kernel\'s dimension_breakdown answers' do
        expect(breakdown(group_by: 'activity').keys.sort).to eq(issue_result.keys.sort)
      end

      it 'has the issue kernel\'s bucket keys too' do
        expect(breakdown(group_by: 'activity')['buckets'].first.keys.sort)
          .to eq(issue_result['buckets'].first.keys.sort)
      end

      it 'names the measure and its field, so a reader can tell hours from a row count' do
        expect(breakdown(group_by: 'activity').values_at('measure', 'measure_field'))
          .to eq(%w[hours hours])
        expect(breakdown(group_by: 'activity', measure: 'count')
                 .values_at('measure', 'measure_field')).to eq(['count', nil])
      end

      # `field_name` IS NIL, because that is what `core_dimension` leaves it
      # (`query_aggregator.rb:1793-1815`): in this vocabulary it is a CUSTOM FIELD's human
      # name, not a column and not a filter. The first version put the filter name here.
      it 'leaves field_name nil, as the kernel does for a core column' do
        expect(breakdown(group_by: 'activity')['field_name']).to be_nil
        expect(issue_result['field_name']).to be_nil
      end

      it 'carries a drill-through filter naming the dimension\'s own filter' do
        bucket = breakdown(group_by: 'activity')['buckets']
                 .find { |b| b['value'] == H::ACTIVITY_DESIGN.to_s }

        expect(bucket['filter']).to eq('field' => 'activity_id', 'operator' => '=',
                                       'values' => [H::ACTIVITY_DESIGN.to_s])
      end

      # `issue.tracker_id` and NOT `tracker_id`: the latter is an `IssueQuery` filter name.
      # `test/unit/reporter_dashboards_time_entry_aggregator_test.rb` checks all of them
      # against a real `TimeEntryQuery#available_filters`, which does not exist in this
      # process.
      it 'prefixes an issue attribute\'s filter, because that is what TimeEntryQuery calls it' do
        bucket = breakdown(group_by: 'tracker')['buckets'].find { |b| b['value'] }

        expect(bucket['filter']['field']).to eq('issue.tracker_id')
      end

      # `!*` with `['']`, matching `query_aggregator.rb:1563` — Redmine's own none filter
      # carries the empty string rather than an empty list.
      it 'filters the empty bucket with the none operator' do
        bucket = breakdown(group_by: 'activity')['buckets']
                 .find { |b| b['label'] == described_class::EMPTY_LABEL }

        expect(bucket['filter']).to eq('field' => 'activity_id', 'operator' => '!*',
                                       'values' => [''])
      end

      # A DIMENSION WITH NO FILTER SAYS SO. `TimeEntryQuery` has no `project_id` filter — it
      # bounds the project through the page — so a payload naming one would point nowhere.
      it 'emits no filter at all for a dimension TimeEntryQuery cannot express' do
        result = breakdown(group_by: 'project')

        expect(result['buckets'].map { |b| b['filter'] }).to eq([nil])
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
