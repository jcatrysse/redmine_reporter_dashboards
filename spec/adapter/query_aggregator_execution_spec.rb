# frozen_string_literal: true
#
# Adapter EXECUTION specs: the aggregator's SQL run against a real PostgreSQL or
# MySQL/MariaDB server. See spec/adapter/adapter_helper.rb for what is real, what is
# stubbed and how to run these.

require_relative 'adapter_helper'

if !RrdAdapterHarness.configured?
  RSpec.describe 'SqlAggregation::QueryAggregator against a real database' do
    it 'is skipped without a database URL' do
      skip RrdAdapterHarness.skip_reason
    end
  end
else
  H = RrdAdapterHarness

  RSpec.describe SqlAggregation::QueryAggregator do
    # main     — the four hand-built issues, every scalar assertion is read off them
    # reported — main plus the archived project, so the visibility conditions have
    #            something to hide without the calendar sweep drowning the numbers
    # sweep    — one issue per day for 400 days, for the period bucketing only
    let(:main)     { H.base_scope.where(project_id: H::PROJECT_MAIN) }
    let(:reported) { H.base_scope.where(project_id: [H::PROJECT_MAIN, H::PROJECT_ARCHIVED]) }
    let(:sweep)    { H.base_scope.where(project_id: H::PROJECT_SWEEP) }

    # ----------------------------------------------------------------
    # The adapter is what we think it is
    # ----------------------------------------------------------------

    describe 'adapter detection' do
      it 'recognises the connected server as PostgreSQL or MySQL/MariaDB' do
        family = described_class.send(:adapter_family)
        expect(family).to eq(H.postgresql? ? :postgresql : :mysql)
      end
    end

    # ----------------------------------------------------------------
    # Period bucketing: the database's TO_CHAR / DATE_FORMAT must agree with the
    # Ruby labels for EVERY bucket, on whatever day the suite happens to run.
    # ----------------------------------------------------------------

    describe '.aggregate period bucketing' do
      # One issue per day for 400 days, so the ISO-week turn of the year and the
      # month/year boundaries are inside the fixture no matter the current date —
      # which a hand-picked fixture date only manages on the days it was written for.
      { 'day' => 30, 'week' => 52, 'month' => 24, 'year' => 10 }.each do |period, periods|
        it "buckets #{period} exactly as Ruby labels it" do
          result   = described_class.aggregate(sweep, period: period, periods: periods)
          labels   = result['labels']
          counts   = labels.zip(result['created']).to_h
          expected = H.sweep_dates.group_by { |d| H.ruby_label(d, period) }
                      .transform_values(&:size)

          expect(labels.length).to eq(periods)
          labels.each do |label|
            expect(counts[label]).to eq(expected.fetch(label, 0)),
                                     "#{period} bucket #{label}: database said #{counts[label]}, " \
                                     "Ruby expected #{expected.fetch(label, 0)}"
          end
        end
      end

      it 'counts every seeded issue in total and open_now' do
        result = described_class.aggregate(sweep, period: 'month', periods: 24)
        expect(result['total']).to eq(H::SWEEP_DAYS)
        expect(result['open_now']).to eq(H::SWEEP_DAYS)
      end

      it 'window and labels agree: the created series accounts for the whole window' do
        result = described_class.aggregate(sweep, period: 'day', periods: 30)
        # 30 consecutive days, one issue each.
        expect(result['created']).to eq([1] * 30)
      end
    end

    # ----------------------------------------------------------------
    # open_at_end: COUNT(DISTINCT CASE WHEN ...) with bound timestamps
    # ----------------------------------------------------------------

    describe '.aggregate open_at_end' do
      subject(:result) { described_class.aggregate(main, period: 'day', periods: 60) }

      # Fixture: issues 1..4 in the main project. 1 open (100d), 2 closed 40d ago,
      # 3 REOPENED (closed_on 40d ago but an open status), 4 created 5d ago.
      it 'reports the backlog height at the end of each day' do
        series = result['open_at_end']

        # Oldest bucket (today-59): 1, 2 and 3 exist and none is closed yet.
        expect(series.first).to eq(3)
        # today-30, i.e. after issue 2's closing: 2 has dropped out, 3 has not.
        expect(series[29]).to eq(2)
        # Today: 4 has appeared, 2 is still closed.
        expect(series.last).to eq(3)
      end

      it 'agrees with open_now on the last bucket' do
        expect(result['open_at_end'].last).to eq(result['open_now'])
      end

      it 'puts the reopened issue in the closed series only when its status is closed' do
        # Issue 2 closed 40 days ago; issue 3 carries the same closed_on with an open
        # status and must NOT appear.
        expect(result['closed'][19]).to eq(1)
        expect(result['closed'].sum).to eq(1)
        expect(result['created'].sum).to eq(1) # only issue 4 was created inside the window
      end

      it 'treats every issue as open when no status is closed' do
        result = described_class.aggregate(main, period: 'day', periods: 60,
                                                 closed_statuses: ['No Such Status'])
        expect(result['open_at_end'].last).to eq(4)
        expect(result['open_now']).to eq(4)
        expect(result['closed'].sum).to eq(0)
      end

      it 'chunks a window wider than OPEN_AT_END_CHUNK into several statements' do
        # 90 > OPEN_AT_END_CHUNK (30): the SELECT is split, and the parts must line up.
        series = described_class.aggregate(main, period: 'day', periods: 90)['open_at_end']
        expect(series.length).to eq(90)
        expect(series.last).to eq(3)
        expect(series.first).to eq(3)
      end
    end

    # ----------------------------------------------------------------
    # flags: scalars, MIN/MAX and the portable percentile
    # ----------------------------------------------------------------

    describe '.flags' do
      subject(:flags) { described_class.flags(main) }

      it 'counts the fixture correctly' do
        expect(flags.slice('total', 'open', 'closed', 'assigned', 'unassigned',
                           'with_due_date', 'without_due_date', 'overdue', 'no_estimate'))
          .to eq('total' => 4, 'open' => 3, 'closed' => 1, 'assigned' => 3, 'unassigned' => 1,
                 'with_due_date' => 3, 'without_due_date' => 1, 'overdue' => 1,
                 'no_estimate' => 1)
      end

      it 'reads the open-age extremes off MIN/MAX' do
        expect(flags['oldest_open_days']).to eq(100)
        expect(flags['newest_open_days']).to eq(5)
      end

      # Open ages ascending: 5, 100, 100. Lower percentile, so both land on 100.
      it 'reads the percentiles with OFFSET/LIMIT rather than percentile_cont' do
        expect(flags['median_open_days']).to eq(100)
        expect(flags['p90_open_days']).to eq(100)
      end

      it 'returns nil percentiles when nothing is open' do
        closed_only = main.where(status_id: H::STATUS_CLOSED)
        flags = described_class.flags(closed_only)
        expect(flags['median_open_days']).to be_nil
        expect(flags['p90_open_days']).to be_nil
      end
    end

    # ----------------------------------------------------------------
    # Dimensions
    # ----------------------------------------------------------------

    describe '.dimension_breakdown' do
      def buckets_for(result)
        result['buckets'].each_with_object({}) { |b, out| out[b['label']] = b['count'] }
      end

      it 'groups on a core column and names the ids' do
        result = described_class.dimension_breakdown(main, group_by: 'status')
        expect(buckets_for(result)).to eq('New' => 2, 'In Progress' => 1, 'Closed' => 1)
        expect(result['total']).to eq(4)
      end

      it 'groups on the assignee, showing display names and the Unassigned bucket' do
        result = described_class.dimension_breakdown(main, group_by: 'assignee')
        expect(buckets_for(result)).to eq('Alice Adams' => 2, 'Bob Brown' => 1, 'Unassigned' => 1)
      end

      it 'groups on a custom field through the aliased LEFT OUTER JOIN' do
        result = described_class.dimension_breakdown(main, group_by: "cf_#{H::CF_DEPARTMENT}")
        # Issue 4 holds an empty string; NULLIF folds it into the no-value bucket.
        expect(buckets_for(result)).to eq('Sales' => 2, 'Ops' => 1, '(none)' => 1)
        expect(result['field_name']).to eq('Department')
      end

      # The visibility subquery is in the ON clause, so an unentitled value becomes
      # NULL rather than dropping its issue.
      it 'hides the values of a project-restricted custom field without losing issues' do
        result = described_class.dimension_breakdown(reported, group_by: "cf_#{H::CF_COST}")
        # Issue 5 holds 999.99 in the archived project: its VALUE is hidden, but the
        # issue still counts — it lands in the no-value bucket with 3 and 4.
        expect(buckets_for(result)).to eq('100.5' => 1, '200.25' => 1, '(none)' => 3)
        expect(result['buckets'].sum { |b| b['count'] }).to eq(5)
      end

      it 'refuses a custom field the viewer may not see, and a non-issue one' do
        expect(described_class.dimension_breakdown(main, group_by: "cf_#{H::CF_HIDDEN}")).to be_nil
        expect(described_class.dimension_breakdown(main, group_by: "cf_#{H::CF_CLIENT}")).to be_nil
      end

      it 'buckets ages with a CASE over bound timestamps' do
        result = described_class.dimension_breakdown(main, group_by: 'age',
                                                           age_buckets: [30, 60, 90])
        expect(buckets_for(result)).to eq('0-30' => 1, '31-60' => 0, '61-90' => 0, '>90' => 3)
      end

      it 'buckets ages on a date column, where NULL lands in the empty bucket' do
        result = described_class.dimension_breakdown(main, group_by: 'age', age_field: 'due',
                                                           age_buckets: [30])
        # due dates: today-10 and today-20 are within 30 days; today+30 is negative
        # age so it is also >= the boundary; issue 4 has none.
        expect(buckets_for(result)['(none)']).to eq(1)
        expect(result['buckets'].sum { |b| b['count'] }).to eq(4)
      end

      it 'groups on a period dimension with fixed keys' do
        result = described_class.dimension_breakdown(sweep, group_by: 'period',
                                                            period: 'day', periods: 7)
        expect(result['buckets'].length).to eq(7)
        expect(result['buckets'].map { |b| b['count'] }).to eq([1] * 7)
      end

      it 'pivots a crosstab in one GROUP BY over both dimensions' do
        result = described_class.dimension_breakdown(main, group_by: 'status',
                                                           split_by: 'tracker')
        cells = result['rows'].each_with_object({}) { |row, out| out[row['label']] = row['cells'] }

        expect(result['series']).to eq(%w[Bug Feature])
        expect(cells['New']).to eq('Bug' => 1, 'Feature' => 1)
        expect(cells['In Progress']).to eq('Bug' => 0, 'Feature' => 1)
        expect(cells['Closed']).to eq('Bug' => 1, 'Feature' => 0)
        expect(result['total']).to eq(4)
      end
    end

    # ----------------------------------------------------------------
    # DEFECT D-1 — the age dimension past the MySQL column-label limit
    #
    # Found on 2026-08-05 by the golden corpus (T-01), on MariaDB 10.11.
    #
    # The age dimension groups on a generated CASE. ActiveRecord reads the group key
    # back out of the result row BY THE EXPRESSION'S OWN TEXT, and the MySQL family
    # truncates a returned column label at 256 characters: measured with this shape,
    # 261 characters still works and 262 does not. Past it the lookup misses, every
    # group key comes back nil, and the entire result collapses into the "(none)"
    # bucket with a total taken from whichever group the server returned last.
    #
    # FOUR boundaries cross the limit, and DEFAULT_AGE_BUCKETS is [30, 60, 90, 180].
    # So the DEFAULT age dimension is broken on MySQL and MariaDB, in production,
    # today. Every existing example above uses three boundaries or fewer, which is the
    # only reason CI has been green.
    #
    # Asserted on BOTH engines rather than skipped on one: the MySQL branch pins the
    # defect so that fixing it fails here — which is the notification the fixer wants.
    # The fix belongs to whichever task may touch the kernel; gate G7 freezes it byte
    # for byte until then.
    # ----------------------------------------------------------------

    describe 'the age dimension with the DEFAULT boundaries (defect D-1)' do
      subject(:buckets) { described_class.dimension_breakdown(main, group_by: 'age')['buckets'] }

      it 'buckets by age on PostgreSQL and collapses into (none) on the MySQL family' do
        labelled = buckets.map { |bucket| [bucket['label'], bucket['count']] }

        if H.mysql?
          # And note the total: 3, not 4. The collapse does not merely mislabel the
          # buckets — the count it keeps is whichever group the server returned last,
          # so an issue disappears from the chart altogether.
          expect(labelled).to eq([['0-30', 0], ['31-60', 0], ['61-90', 0], ['91-180', 0],
                                  ['>180', 0], ['(none)', 3]]),
                              "DEFECT D-1 has changed shape (got #{labelled.inspect}) — re-measure " \
                              'before editing this expectation'
          expect(described_class.dimension_breakdown(main, group_by: 'age')['total']).to eq(3)
        else
          expect(labelled).to eq([['0-30', 1], ['31-60', 0], ['61-90', 0], ['91-180', 3],
                                  ['>180', 0]])
          expect(described_class.dimension_breakdown(main, group_by: 'age')['total']).to eq(4)
        end
      end

      # The boundary of the defect, so its cause is a measured fact and not a comment:
      # three boundaries stay under the limit and are correct everywhere.
      it 'is correct at three boundaries on every engine' do
        result = described_class.dimension_breakdown(main, group_by: 'age',
                                                           age_buckets: [30, 60, 90])

        expect(result['buckets'].map { |b| [b['label'], b['count']] })
          .to eq([['0-30', 1], ['31-60', 0], ['61-90', 0], ['>90', 3]])
      end
    end

    # ----------------------------------------------------------------
    # Per-actor visibility — the harness's four actors, at value level
    #
    # INV-1 says the actor is explicit; INV-2 says a value the actor may not see is
    # hidden without losing the issue. Both are asserted here at the level the
    # aggregator actually decides them, and frozen for every entry point by the
    # golden corpus.
    # ----------------------------------------------------------------

    describe 'the role-restricted custom field' do
      def salary_dimension(actor)
        H.as_actor(actor) do
          described_class.dimension_breakdown(main, group_by: "cf_#{H::CF_SALARY}")
        end
      end

      it 'answers with its values for an actor entitled in the issues\' project' do
        expect(salary_dimension(:manager)['buckets'].map { |b| [b['label'], b['count']] })
          .to eq([['1000.5', 1], ['2000.25', 1], ['(none)', 2]])
      end

      it 'is refused outright to actors holding no entitled role anywhere' do
        expect(salary_dimension(:developer)).to be_nil
        expect(salary_dimension(:reporter)).to be_nil
      end

      # The INV-2 case: the field resolves, the values do not, and the issues stay.
      it 'hides the values but keeps the issues for an actor entitled elsewhere' do
        expect(salary_dimension(:auditor)['buckets'].map { |b| [b['label'], b['count']] })
          .to eq([['(none)', 4]])
      end

      it 'shows that same actor the values in the project where the role is held' do
        result = H.as_actor(:auditor) do
          described_class.dimension_breakdown(H.base_scope.where(project_id: H::PROJECT_WIDE),
                                              group_by: "cf_#{H::CF_SALARY}", sort: 'label')
        end

        expect(result['buckets'].map { |b| b['label'] }).to eq(['10.25', '20.25', '30.25',
                                                                '40.25', '(none)'])
      end

      it 'restores User.current afterwards, so one case cannot move the next one' do
        before_actor = ::User.current
        H.as_actor(:reporter) { described_class.flags(main) }

        expect(::User.current).to eq(before_actor)
      end
    end

    describe 'visible spent time' do
      def spent_total(actor)
        H.as_actor(actor) do
          described_class.dimension_breakdown(reported, group_by: 'status',
                                                        measure: 'sum', of: 'spent_hours')['total']
        end
      end

      it 'is summed where the actor holds an entitled role' do
        expect(spent_total(:manager)).to eq(7.0)
        expect(spent_total(:developer)).to eq(7.0)
      end

      it 'is zero where no entitled role is held at all' do
        expect(spent_total(:reporter)).to eq(0.0)
      end

      it 'is zero where the entitled role is held in another project' do
        expect(spent_total(:auditor)).to eq(0.0)
      end
    end

    # ----------------------------------------------------------------
    # Measures — the numeric CAST and the two visibility-aware joins
    # ----------------------------------------------------------------

    describe '.dimension_breakdown with a measure' do
      def buckets_for(result)
        result['buckets'].each_with_object({}) { |b, out| out[b['label']] = b['count'] }
      end

      it 'sums a core numeric column' do
        result = described_class.dimension_breakdown(main, group_by: 'status',
                                                           measure: 'sum', of: 'estimated_hours')
        expect(buckets_for(result)).to eq('New' => 10.0, 'In Progress' => 0.0, 'Closed' => 4.0)
        expect(result['total']).to eq(14.0)
        expect(result['measure']).to eq('sum')
      end

      it 'averages a core numeric column, ignoring the rows that have none' do
        result = described_class.dimension_breakdown(main, group_by: 'tracker',
                                                           measure: 'avg', of: 'estimated_hours')
        expect(buckets_for(result)).to eq('Bug' => 6.0, 'Feature' => 2.0)
      end

      it 'counts distinct references, where NULL is not a value' do
        result = described_class.dimension_breakdown(main, group_by: 'tracker',
                                                           measure: 'distinct', of: 'assignee')
        expect(buckets_for(result)).to eq('Bug' => 2, 'Feature' => 1)
      end

      # NULLIF before CAST: the empty string on issue 3 must become NULL, not abort
      # the statement on PostgreSQL.
      it 'sums a numeric custom field through the per-adapter CAST' do
        result = described_class.dimension_breakdown(main, group_by: 'tracker',
                                                           measure: 'sum', of: "cf_#{H::CF_POINTS}")
        expect(buckets_for(result)).to eq('Bug' => 8.0, 'Feature' => 0.0)
      end

      it 'averages a numeric custom field' do
        result = described_class.dimension_breakdown(main, group_by: 'tracker',
                                                           measure: 'avg', of: "cf_#{H::CF_POINTS}")
        expect(buckets_for(result)).to eq('Bug' => 4.0, 'Feature' => 0.0)
      end

      # The condition sits in the ON clause, so a bucket with no visible time reports
      # zero instead of vanishing — and the archived project's 40 hours never count.
      it 'sums spent hours only where the viewer may see them, keeping empty buckets' do
        result = described_class.dimension_breakdown(reported, group_by: 'status',
                                                               measure: 'sum', of: 'spent_hours')
        expect(buckets_for(result)).to eq('New' => 5.0, 'In Progress' => 0.0, 'Closed' => 2.0)
        expect(result['total']).to eq(7.0)
      end

      it 'refuses avg on spent_hours' do
        expect(described_class.dimension_breakdown(main, group_by: 'status',
                                                         measure: 'avg', of: 'spent_hours')).to be_nil
      end

      # An average cannot be added up from its parts, so a bucket that collapses two
      # raw keys gets its own aggregate — one extra statement, built from
      # dimension_keys_condition's IN () list.
      it 'recomputes a collapsed Other bucket for a non-additive measure' do
        result = described_class.dimension_breakdown(main, group_by: 'priority',
                                                           sort: 'label', limit: 1,
                                                           measure: 'avg', of: 'estimated_hours')
        buckets = result['buckets'].each_with_object({}) { |b, out| out[b['label']] = b['count'] }

        # Label order: High, Low, Normal — so Other collapses Low and Normal, whose
        # estimates are issue 4 (none) and issues 1 and 2 (8.0 and 4.0).
        expect(result['buckets'].map { |b| b['label'] }).to eq(%w[High Other])
        expect(buckets['High']).to eq(2.0)
        expect(buckets['Other']).to eq(6.0)
        # Stringified, because they go into an issue-list URL.
        expect(result['buckets'].last['values']).to eq(%w[1 2])
        expect(result['truncated']).to be true
      end

      # The collapsed row's CELLS are re-aggregated too, not just its total: adding
      # distinct counts across the series would double-count an assignee who appears
      # in two of them, which is exactly this fixture.
      it 'recounts collapsed crosstab rows for a non-additive measure' do
        result = described_class.dimension_breakdown(main, group_by: 'status', split_by: 'tracker',
                                                          sort: 'count', limit: 1,
                                                          measure: 'distinct', of: 'assignee')
        expect(result['rows'].map { |r| r['label'] }).to eq(%w[Closed Other])

        other = result['rows'].last
        expect(other['cells']).to eq('Bug' => 1, 'Feature' => 1)
        # Alice is the only assignee behind both cells, so the row is 1, not 2.
        expect(other['total']).to eq(1)
      end
    end

    # ----------------------------------------------------------------
    # completeness
    # ----------------------------------------------------------------

    describe '.completeness' do
      it 'counts filled and empty per field in one statement' do
        result = described_class.completeness(
          main, fields: ['due_date', 'assignee', 'description', "cf_#{H::CF_DEPARTMENT}",
                         "cf_#{H::CF_POINTS}"]
        )
        filled = result['buckets'].each_with_object({}) { |b, out| out[b['label']] = b['count'] }

        expect(result['total']).to eq(4)
        expect(filled).to eq('Due date' => 3, 'Assignee' => 3, 'Description' => 2,
                             'Department' => 3, 'Points' => 2)
        expect(result['buckets'].map { |b| b['empty'] }).to eq([1, 1, 2, 1, 2])
        expect(result['buckets'].map { |b| b['pct'] }).to eq([75, 75, 50, 75, 50])
      end

      it 'keeps the bucket order of the fields: list' do
        result = described_class.completeness(main, fields: %w[description due_date])
        expect(result['buckets'].map { |b| b['label'] }).to eq(['Description', 'Due date'])
      end

      # One shared custom_values join, each field's own visibility clause in its CASE.
      it 'reports a project-restricted custom field as empty where it may not be seen' do
        result = described_class.completeness(reported, fields: ["cf_#{H::CF_COST}",
                                                                "cf_#{H::CF_DEPARTMENT}"])
        expect(result['total']).to eq(5)
        expect(result['buckets'].map { |b| b['count'] }).to eq([2, 4])
      end

      it 'refuses a field the viewer may not see' do
        expect(described_class.completeness(main, fields: ["cf_#{H::CF_HIDDEN}"])).to be_nil
      end
    end

    # ----------------------------------------------------------------
    # version_rollup
    # ----------------------------------------------------------------

    describe '.version_rollup' do
      subject(:rows) do
        described_class.version_rollup(main, cost_field_ids: [H::CF_COST])
          .each_with_object({}) { |row, out| out[row['version_id']] = row }
      end

      it 'rolls up counts, sums and date extremes per version' do
        expect(rows.keys.sort).to eq([1, 2])
        expect(rows[1].slice('total', 'open', 'closed', 'open_done_sum', 'overdue_open',
                             'unassigned_open', 'no_estimate'))
          .to eq('total' => 2, 'open' => 1, 'closed' => 1, 'open_done_sum' => 30,
                 'overdue_open' => 1, 'unassigned_open' => 0, 'no_estimate' => 0)
        expect(rows[2].slice('total', 'open', 'closed', 'open_done_sum', 'overdue_open',
                             'unassigned_open', 'no_estimate'))
          .to eq('total' => 2, 'open' => 2, 'closed' => 0, 'open_done_sum' => 10,
                 'overdue_open' => 0, 'unassigned_open' => 1, 'no_estimate' => 1)
      end

      it 'sums estimates and the visible spent hours' do
        expect(rows[1]['est_hours']).to eq(12.0)
        expect(rows[2]['est_hours']).to eq(2.0)
        expect(rows[1]['spent_hours']).to eq(7.0)
        expect(rows[2]['spent_hours']).to eq(0.0)
      end

      it 'reads the date extremes' do
        expect(rows[1]['start_date']).to eq(H.today - 100)
        expect(rows[1]['due_date']).to eq(H.today - 10)
        expect(rows[2]['due_date']).to eq(H.today + 30)
      end

      it 'sums a cost custom field through the aliased INNER join' do
        expect(rows[1]['cost']).to eq(H::CF_COST.to_s => 300.75)
        expect(rows[2]['cost']).to eq({})
      end

      it 'skips a cost field the viewer may not see' do
        rows = described_class.version_rollup(main, cost_field_ids: [H::CF_HIDDEN])
        expect(rows.map { |row| row['cost'] }.uniq).to eq([{}])
      end

      it 'leaves the archived project out of the visible spent hours' do
        rollup = described_class.version_rollup(reported)
        # Issue 5 has no target version, so it rolls up under nil — and its 40 hours
        # are in an archived project, hence invisible.
        nil_row = rollup.find { |row| row['version_id'].nil? }
        expect(nil_row['total']).to eq(1)
        expect(nil_row['spent_hours']).to eq(0.0)
      end
    end

    # ----------------------------------------------------------------
    # ONLY_FULL_GROUP_BY — the strictest thing a production MySQL can be set to
    # ----------------------------------------------------------------

    describe 'under ONLY_FULL_GROUP_BY' do
      before do
        skip 'MySQL/MariaDB only' unless H.mysql?
      end

      it 'buckets periods, whose group expression is a plain function' do
        H.with_only_full_group_by do
          result = described_class.aggregate(sweep, period: 'week', periods: 8)
          expect(result['labels'].length).to eq(8)
          expect(result['created'].sum).to be_positive
        end
      end

      it 'groups on a core column' do
        H.with_only_full_group_by do
          expect(described_class.dimension_breakdown(main, group_by: 'status')['total']).to eq(4)
        end
      end

      # This is the regression: the cf dimension used to group on NULLIF(value, ''),
      # which MariaDB's matcher rejects, taking out every cf_<id> dashboard block on a
      # server with ONLY_FULL_GROUP_BY turned on.
      it 'groups on a custom field' do
        H.with_only_full_group_by do
          result = described_class.dimension_breakdown(main, group_by: "cf_#{H::CF_DEPARTMENT}")
          expect(result['buckets'].map { |b| b['label'] }).to eq(['Sales', 'Ops', '(none)'])
        end
      end

      it 'groups on a custom field crossed with a core column' do
        H.with_only_full_group_by do
          expect(described_class.dimension_breakdown(main, group_by: "cf_#{H::CF_DEPARTMENT}",
                                                           split_by: 'tracker')['total']).to eq(4)
        end
      end

      it 'applies a measure over the visibility-aware joins' do
        H.with_only_full_group_by do
          expect(described_class.dimension_breakdown(main, group_by: 'status', measure: 'sum',
                                                           of: 'spent_hours')['total']).to eq(7.0)
          expect(described_class.dimension_breakdown(main, group_by: 'status', measure: 'avg',
                                                           of: "cf_#{H::CF_POINTS}")['total']).to eq(4.0)
        end
      end

      it 'runs completeness, version_rollup and flags' do
        H.with_only_full_group_by do
          expect(described_class.completeness(main, fields: %w[due_date description])['total'])
            .to eq(4)
          expect(described_class.version_rollup(main, cost_field_ids: [H::CF_COST]).length).to eq(2)
          expect(described_class.flags(main)['total']).to eq(4)
        end
      end

      # The age dimension is the one whose group expression is unavoidably a CASE.
      # MySQL 8 matches an identical select-list expression against the GROUP BY and
      # accepts it; MariaDB's matcher does not recognise CASE-family items and rejects
      # the statement. Asserted where it holds, skipped with the reason where it does
      # not, rather than pinned to whichever engine happens to run.
      it 'groups on the age CASE — on MySQL, but not on MariaDB' do
        skip 'MariaDB with ONLY_FULL_GROUP_BY rejects a CASE in the GROUP BY — see the ' \
             'database support section in the README' if H.mariadb?

        H.with_only_full_group_by do
          result = described_class.dimension_breakdown(main, group_by: 'age',
                                                             age_buckets: [30, 60])
          expect(result['buckets'].map { |b| [b['label'], b['count']] })
            .to eq([['0-30', 1], ['31-60', 0], ['>60', 3]])
        end
      end
    end
  end
end
