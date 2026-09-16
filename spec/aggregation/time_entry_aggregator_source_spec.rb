# frozen_string_literal: true
#
# T-31 — the TIME-ENTRY AGGREGATOR's structural rules, asserted without a database.
#
# Its VALUES are proved in `spec/adapter/time_entry_aggregator_spec.rb`, by computing every
# figure twice against a real engine. What is here is everything that agreement cannot see:
# the shape of the read, the axis ceiling, the total order, which bucket the cap may fold,
# and the fail-closed direction of each guard. An independent review of the first version
# found six defects while every figure still agreed, and five guards that were provably dead
# in a green run — so this file exists to make those things observable with the rows under
# the example's own control.
#
# --- CLAUSE 5: THE GROUPED AGGREGATE IS READ BY POSITION ---
#
# Defect **D-1**: MariaDB truncates a RETURNED COLUMN LABEL at 256 characters. ActiveRecord's
# `relation.sum(expr)` / `.average(expr)` / `.count(expr)` on a GROUPED relation key their
# result Hash by the group expression's own TEXT, so past 256 characters every key comes back
# nil, the buckets collapse into one, and the total is taken from whichever group the server
# returned last. `QueryAggregator.grouped_counts` was fixed for COUNT — it plucks and reads
# the row positionally — while `raw_measure` still calls `.sum` on a grouped relation.
#
# `SUM(hours)` grouped by a dimension is `TimeEntryAggregator`'s entire purpose, so it walks
# straight into the one defect class this project has documented as open and UNGATED: the
# handover says of it, in as many words, *"no gate in this project can catch it"*. That is
# what makes a spec the only available control.
#
# --- WHY A SOURCE SCAN *AND* A BEHAVIOURAL DOUBLE ---
#
# The scan catches the construct wherever it is added, including in a method no example
# calls. The double catches a reader that plucks but reads the WRONG position, and an
# accidental `relation.count` with no argument — which the scan can see only as text. Neither
# subsumes the other, and the length case itself is measured against a real engine next door,
# where a 394-character group expression runs on PostgreSQL, MySQL 8 and MariaDB 11.

require 'logger'
require 'active_support'
require 'active_support/time'
require_relative '../spec_helper'

Time.zone ||= 'UTC'

# PER-CONSTANT, and this file is the one that proved why. Its first version guarded on
# `unless defined?(ActiveRecord)` and defined the namespace with only `StatementInvalid` in
# it; on the seeds where it loaded before spec/sql_stats_controller_spec.rb, THAT file's
# identically coarse guard then skipped and `ActiveRecord::RecordNotFound` was never defined.
# One spec broke another through a constant neither of them mentions. All four DB-less files
# that stub this namespace now guard the constant rather than the module.
module ActiveRecord; end unless defined?(ActiveRecord)

unless defined?(ActiveRecord::StatementInvalid)
  module ActiveRecord
    class StatementInvalid < StandardError; end
  end
end

# Per-constant for the same reason, even though both definitions would be identical: the
# lesson is three lines up and an identical hazard shape does not get a pass for being
# harmless today.
module Arel; end unless defined?(Arel)

unless Arel.respond_to?(:sql)
  module Arel
    def self.sql(string)
      string
    end
  end
end

require_relative '../../lib/redmine_reporter_dashboards/aggregation/time_entry_aggregator'

RRD_TEA_SOURCE = File.expand_path(
  '../../lib/redmine_reporter_dashboards/aggregation/time_entry_aggregator.rb', __dir__
).freeze

# The forbidden construct, in one place so the scan and the two examples that prove the scan
# works cannot drift apart. `\.(sum|average|count)` NOT followed by a block:
# `ordered.drop(n).sum { … }` is `Enumerable#sum` over an Array already in memory and is not
# a database read at all, while `relation.sum(expr)` and a bare `relation.count` are. The
# block separates them mechanically, without this spec having to know which receiver is a
# relation.
RRD_GROUPED_CALCULATION = /\.(sum|average|count)\b(?!\s*\{|\s+do\b)/.freeze

# Chainable enough for `measure_rows` and `total`, and DELIBERATELY carrying no `sum`,
# `average` or `count` at all: a module that reached for one gets a NoMethodError here rather
# than a plausible Hash. `pluck` answers by ARITY, because the two reads are different
# questions — two expressions is the grouped read, one is the scalar total.
class RrdRecordingRelation
  attr_reader :calls, :grouped_by, :joined

  def initialize(sql:, rows: [], total: 0.0, raise_on_pluck: false, raise_on_total: false,
                 raise_on_to_sql: false)
    @sql = sql
    @rows = rows
    @total = total
    @raise_on_pluck = raise_on_pluck
    @raise_on_total = raise_on_total
    @raise_on_to_sql = raise_on_to_sql
    @calls = []
    @grouped_by = nil
    @joined = []
  end

  def to_sql
    raise 'this relation cannot render its SQL' if @raise_on_to_sql

    @sql
  end

  def unscope(*args)
    @calls << [:unscope, args]
    self
  end

  def joins(clause)
    @calls << [:joins, clause]
    @joined << clause
    self
  end

  def group(expression)
    @calls << [:group, expression]
    @grouped_by = expression
    self
  end

  def pluck(*expressions)
    @calls << [:pluck, expressions]
    if expressions.length == 1
      raise ::ActiveRecord::StatementInvalid, 'SUM failed' if @raise_on_total

      return [@total]
    end
    raise ::ActiveRecord::StatementInvalid, 'column issues.tracker_id does not exist' if @raise_on_pluck

    @rows
  end

  def names
    @calls.map(&:first)
  end
end

# A `#degrade` recorder. The aggregator's port is duck-typed precisely so the aggregation
# layer need not name the Liquid layer (`script/gates/layer_purity.sh`).
class RrdDegradeRecorder
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

# A logger that only remembers. `refuse`'s log half was a surviving mutation: deleting the
# `logger.warn` left every example green while the comment said "both halves, in one place so
# neither can be forgotten".
class RrdRecordingLogger
  attr_reader :lines

  def initialize
    @lines = []
  end

  def warn(line)
    @lines << line
  end
end

RSpec.describe RedmineReporterDashboards::Aggregation::TimeEntryAggregator do
  let(:joined_sql) do
    'SELECT time_entries.* FROM time_entries ' \
      'LEFT OUTER JOIN issues ON issues.id = time_entries.issue_id'
  end
  let(:unjoined_sql) do
    'SELECT time_entries.* FROM time_entries ' \
      'INNER JOIN projects ON projects.id = time_entries.project_id'
  end

  def relation(rows, sql: joined_sql, **options)
    RrdRecordingRelation.new(sql: sql, rows: rows, **options)
  end

  def figures(result)
    result['buckets'].each_with_object({}) { |b, out| out[b['label']] = b['count'] }
  end

  # An issue dimension needs the join; `user` is the one used wherever the dimension does not
  # matter, because it needs neither a join nor a label lookup this process can serve.
  def breakdown(rows, **options)
    described_class.breakdown(relation(rows), **{ group_by: 'user' }.merge(options))
  end

  describe 'the source' do
    # Comments are stripped first, because the module's own header explains D-1 and has to be
    # able to say `relation.sum(expr)` in prose while the scan stays about code — MEASURED:
    # the first version stripped nothing (`/#.*\z/` cannot cross the trailing newline) and
    # reported three of the module's own explanatory sentences as offences.
    #
    # A WHOLE-LINE comment goes entirely. A trailing one goes only when the line holds no
    # quote, because `"##{record.id}"` is code and cutting at its `#` would blind the scan to
    # everything after it — leniency in the direction of a false PASS is the one direction a
    # control like this must not have.
    let(:code_lines) do
      File.readlines(RRD_TEA_SOURCE).each_with_index.map do |line, index|
        code = if line.match?(/\A\s*#/) then ''
               elsif line.include?('"') || line.include?("'") then line
               else line.sub(/#.*/, '')
               end
        [index + 1, code]
      end
    end

    let(:offences) do
      code_lines.select { |_number, line| line.match?(RRD_GROUPED_CALCULATION) }
    end

    it 'reads no grouped aggregate through ActiveRecord\'s calculation methods' do
      expect(offences.map { |number, line| "#{number}: #{line.strip}" }).to eq([])
    end

    # THE SCAN MUST BE ABLE TO SEE THE THING IT FORBIDS, or a green result means the regex is
    # broken rather than the file clean.
    it 'would catch the construct if it were added' do
      planted = [[1, "        scope.group(expr).sum(Arel.sql('SUM(x)'))\n"]]

      expect(planted.select { |_n, line| line.match?(RRD_GROUPED_CALCULATION) }).to eq(planted)
    end

    it 'permits the in-memory Enumerable form the cap uses' do
      permitted = [[1, "        folded = ordered.drop(limit).sum { |_, value| value }\n"]]

      expect(permitted.select { |_n, line| line.match?(RRD_GROUPED_CALCULATION) }).to eq([])
    end

    it 'groups in exactly one place, so there is one read to keep correct' do
      expect(code_lines.count { |_number, line| line.match?(/\.group\(/) }).to eq(1)
    end

    it 'plucks wherever it groups' do
      expect(code_lines.count { |_number, line| line.match?(/\.pluck\(/) }).to be >= 1
    end
  end

  # --------------------------------------------------------------------------------
  # The read itself.
  # --------------------------------------------------------------------------------

  it 'reads the grouped rows as [key, measure] pairs by position' do
    scope = relation([[20, 3.0], [nil, 1.5]])
    described_class.breakdown(scope, group_by: 'user')

    pluck = scope.calls.find { |name, _| name == :pluck }[1]
    expect(pluck.length).to eq(2)
    expect(pluck.first).to eq('time_entries.user_id')
    expect(pluck.last).to eq('SUM(time_entries.hours)')
  end

  it 'drops the ORDER BY before grouping, which some engines reject and none needs' do
    scope = relation([[20, 3.0]])
    described_class.breakdown(scope, group_by: 'user')

    expect(scope.calls.first).to eq([:unscope, [:order]])
  end

  # THE POSITIONS ARE NOT INTERCHANGEABLE, and a reader that swapped them would still pluck.
  # Distinguishable values, so a swap cannot pass: the key is an id and the measure is not.
  it 'takes the bucket key from the first column and the figure from the second' do
    result = described_class.breakdown(relation([[20, 7.25]]), group_by: 'user')

    expect(result['buckets'].first['value']).to eq('20')
    expect(result['buckets'].first['count']).to eq(7.25)
  end

  it 'groups by the dimension\'s own column and not by the measure' do
    scope = relation([[20, 3.0]])
    described_class.breakdown(scope, group_by: 'user')

    expect(scope.grouped_by).to eq('time_entries.user_id')
  end

  # THE ACTIVITY DIMENSION ADDS ITS OWN JOIN AND ROLLS THE OVERRIDE UP. Its VALUES are
  # asserted against a real engine and a real overridden activity next door; what this asserts
  # is the SQL, because a `COALESCE` over a join nobody added binds to nothing.
  describe 'the activity roll-up' do
    it 'joins the enumerations table under its own alias' do
      scope = relation([[20, 1.0]])
      described_class.breakdown(scope, group_by: 'activity')

      expect(scope.joined).to eq([described_class::ACTIVITY_JOIN])
      expect(scope.joined.first).to include('LEFT OUTER JOIN enumerations rrd_activity')
    end

    # `COALESCE(parent_id, id)` and not the bare column — `time_report.rb:125`.
    it 'groups on the parent id where there is one, as core does' do
      scope = relation([[20, 1.0]])
      described_class.breakdown(scope, group_by: 'activity')

      expect(scope.grouped_by).to eq('COALESCE(rrd_activity.parent_id, rrd_activity.id)')
    end

    it 'adds no join for a dimension that needs none' do
      scope = relation([[20, 1.0]])
      described_class.breakdown(scope, group_by: 'user')

      expect(scope.joined).to eq([])
    end
  end

  # --------------------------------------------------------------------------------
  # `applicable?` IS A DECISION, NOT A RESCUE (mutation-tested, and it survived first).
  # --------------------------------------------------------------------------------
  #
  # Forcing `applicable?` to `true` — and separately forcing `joined_to_issues?` to `true` —
  # left every adapter example green, because PostgreSQL raised on `issues.tracker_id`,
  # `measure_rows`'s rescue swallowed it and the answer was nil either way. Two guards,
  # provably dead, in a green run.
  #
  # HERE THE DOUBLE MAKES THE DIFFERENCE OBSERVABLE WITHOUT AN ENGINE AT ALL: a refusal never
  # calls `group`, while a rescue-shaped non-refusal calls it and then fails.
  describe 'a scope whose SQL carries no issues join' do
    %w[tracker status version category].each do |dimension|
      it "refuses #{dimension} without touching the relation" do
        scope = relation([[1, 1.0]], sql: unjoined_sql)

        expect(described_class.breakdown(scope, group_by: dimension)).to be_nil
        expect(scope.names).not_to include(:group)
        expect(scope.names).not_to include(:pluck)
      end
    end

    it 'still answers the own-table dimensions on that very same scope' do
      %w[activity user project issue].each do |dimension|
        scope = relation([[7, 2.5]], sql: unjoined_sql)

        expect(described_class.breakdown(scope, group_by: dimension)).not_to be_nil, dimension
        expect(scope.names).to include(:group)
      end
    end

    # AND THE JOIN IS RECOGNISED WHEN IT IS THERE, in the spellings a caller may hold:
    # Redmine's raw `left_join_issue` string with its visibility condition, the same quoted,
    # and an association join. Without this the guard could be refusing every issue dimension
    # always and the examples above would all still pass.
    [
      'SELECT time_entries.* FROM time_entries LEFT OUTER JOIN issues ON issues.id = time_entries.issue_id AND (1=1)',
      'SELECT "time_entries".* FROM "time_entries" LEFT OUTER JOIN "issues" ON "issues"."id" = "time_entries"."issue_id"',
      'SELECT time_entries.* FROM time_entries INNER JOIN issues ON issues.id = time_entries.issue_id'
    ].each_with_index do |sql, index|
      it "accepts an issue dimension when the statement holds the join (spelling #{index + 1})" do
        scope = relation([[1, 3.0]], sql: sql)

        expect(described_class.breakdown(scope, group_by: 'tracker')).not_to be_nil
        expect(scope.grouped_by).to eq('issues.tracker_id')
      end
    end

    # FAIL CLOSED WHEN THE RELATION CANNOT ANSWER. A surviving mutation flipped
    # `joined_to_issues?`'s rescue from `false` to `true` and the whole suite stayed green —
    # the fail-OPEN direction of a fail-closed guard, untested. A relation that cannot render
    # its SQL is one this module knows nothing about, so the issue dimensions are refused.
    it 'refuses an issue dimension when it cannot read the statement at all' do
      scope = relation([[1, 1.0]], raise_on_to_sql: true)

      expect(described_class.breakdown(scope, group_by: 'tracker')).to be_nil
      expect(scope.names).not_to include(:group)
    end

    it 'still answers an own-table dimension on that same unreadable relation' do
      scope = relation([[1, 1.0]], raise_on_to_sql: true)

      expect(described_class.breakdown(scope, group_by: 'user')).not_to be_nil
    end
  end

  # --------------------------------------------------------------------------------
  # THE RESCUE IS THE BACKSTOP BEHIND `applicable?`, AND IT MUST REFUSE RATHER THAN ANSWER
  # ZERO (mutation-tested, and it survived first).
  # --------------------------------------------------------------------------------
  #
  # `nil` is a REFUSAL, which `breakdown` turns into a degradation the author reads, while
  # `[]` is "no rows", which produces a complete-looking report with a total of 0 and nothing
  # said. That is INV-4 and INV-5's distinction exactly, on the path taken when a statement
  # does not compile.
  describe 'a statement the engine refuses' do
    it 'refuses the whole breakdown rather than answering an empty one' do
      scope = relation([], raise_on_pluck: true)

      expect(described_class.breakdown(scope, group_by: 'tracker')).to be_nil
    end

    it 'says so, so an author does not read a zero as an answer' do
      recorder = RrdDegradeRecorder.new
      described_class.breakdown(relation([], raise_on_pluck: true), group_by: 'tracker',
                                                                   diagnostics: recorder)

      expect(recorder.codes).to eq([:aggregation_dimension_unavailable])
    end

    # AND A TOTAL THAT WILL NOT COMPUTE IS ZERO RATHER THAN AN EXCEPTION — a surviving
    # mutation deleted this rescue and nothing went red, because nothing reached it.
    it 'answers a zero total rather than raising when the scalar read fails' do
      result = described_class.breakdown(relation([[1, 2.0]], raise_on_total: true),
                                         group_by: 'user')

      expect(result['buckets'].first['count']).to eq(2.0)
      expect(result['total']).to eq(0)
    end
  end

  # --------------------------------------------------------------------------------
  # THE AXIS CEILING. An independent review measured 50 000 buckets with
  # `truncated: false` — G6's unbounded output, in the default configuration.
  # --------------------------------------------------------------------------------

  describe 'the ceiling on how many buckets an axis may have' do
    def rows_for(count, from: 1)
      (from...(from + count)).map { |i| [i, (count - i + from).to_f] }
    end

    it 'matches the issue kernel\'s, which is 200' do
      expect(described_class::MAX_KEYS).to eq(200)
    end

    # AT the ceiling: nothing folded.
    it 'keeps every bucket at exactly MAX_KEYS' do
      result = breakdown(rows_for(described_class::MAX_KEYS))

      expect(result['buckets'].length).to eq(described_class::MAX_KEYS)
      expect(result['truncated']).to be(false)
    end

    # ONE PAST it: folded, and it says so. `limit: 0` is the default every template that does
    # not set one uses, which is exactly why the first version's "0 means no cap" was a defect
    # rather than a curiosity.
    it 'folds the tail one past MAX_KEYS even with no limit asked for' do
      result = breakdown(rows_for(described_class::MAX_KEYS + 1))

      expect(result['buckets'].length).to eq(described_class::MAX_KEYS + 1)
      expect(result['buckets'].last['label']).to eq(described_class::DEFAULT_OTHER_LABEL)
      expect(result['truncated']).to be(true)
    end

    it 'does not let an explicit limit widen the ceiling' do
      result = breakdown(rows_for(described_class::MAX_KEYS + 50),
                         limit: described_class::MAX_KEYS + 40)

      expect(result['buckets'].count { |b| b['value'] }).to eq(described_class::MAX_KEYS)
      expect(result['truncated']).to be(true)
    end

    it 'lets an explicit limit tighten it' do
      result = breakdown(rows_for(10), limit: 3)

      expect(result['buckets'].count { |b| b['value'] }).to eq(3)
      expect(result['truncated']).to be(true)
    end

    # THE FOLDED FIGURE IS THE SUM OF WHAT WAS FOLDED, not zero and not the whole total.
    it 'folds the tail\'s figures into the other bucket' do
      result = breakdown([[1, 5.0], [2, 3.0], [3, 2.0], [4, 1.0]], limit: 2)
      other = result['buckets'].last

      expect(other['label']).to eq(described_class::DEFAULT_OTHER_LABEL)
      expect(other['count']).to eq(3.0)
    end

    # AND IT SAYS SO ON THE PAGE. A truncated axis that only sets a flag nobody prints is
    # INV-4 unmet; the flag AND a degradation.
    it 'degrades visibly when it folds' do
      recorder = RrdDegradeRecorder.new
      breakdown([[1, 5.0], [2, 3.0]], limit: 1, diagnostics: recorder)

      expect(recorder.codes).to eq([:aggregation_axis_truncated])
      expect(recorder.records.first[:data]).to include(folded: 1)
    end

    it 'says nothing when it folds nothing' do
      recorder = RrdDegradeRecorder.new
      breakdown([[1, 5.0], [2, 3.0]], diagnostics: recorder)

      expect(recorder.codes).to eq([])
    end
  end

  # --------------------------------------------------------------------------------
  # THE ORDER IS TOTAL. Equal figures are the normal case in a timesheet — everybody logs
  # 8.0 — and with a cap the tie-break decides WHICH buckets exist, not merely their order.
  # --------------------------------------------------------------------------------

  describe 'ties' do
    let(:tied) { [[10, 1.0], [20, 1.0], [30, 1.0], [40, 1.0], [50, 1.0]] }

    it 'orders identical figures the same way whatever order the engine returned them in' do
      forwards = breakdown(tied)
      backwards = breakdown(tied.reverse)

      expect(forwards['buckets'].map { |b| b['value'] })
        .to eq(backwards['buckets'].map { |b| b['value'] })
    end

    # THE CAP IS WHERE IT STOPS BEING COSMETIC: an independent review measured
    # `["10", "20"]` from one row order and `["50", "40"]` from the other, at `limit: 2`.
    it 'keeps the same buckets under a cap whatever order the engine returned them in' do
      forwards = breakdown(tied, limit: 2)
      backwards = breakdown(tied.reverse, limit: 2)

      expect(forwards['buckets'].map { |b| b['value'] })
        .to eq(backwards['buckets'].map { |b| b['value'] })
      expect(forwards['buckets'].first['value']).to eq('10')
    end
  end

  # --------------------------------------------------------------------------------
  # `sort: label`, and the two synthetic buckets that never take part in a sort.
  # --------------------------------------------------------------------------------

  describe 'sorting' do
    it 'orders by figure descending by default' do
      result = breakdown([[1, 2.0], [2, 9.0], [3, 5.0]])

      expect(result['buckets'].map { |b| b['count'] }).to eq([9.0, 5.0, 2.0])
    end

    # WITH NO MODELS IN THIS PROCESS the labels are `fallback_label`, `"User #7"` — which is
    # still enough to tell a label sort from an id sort, because `natural_key` makes
    # `User #7` come before `User #12` while the ids say the opposite.
    it 'orders by the label and not by the raw key' do
      result = described_class.breakdown(relation([[12, 9.0], [7, 1.0]]), group_by: 'user',
                                                                         sort: 'label')

      expect(result['buckets'].map { |b| b['value'] }).to eq(%w[7 12])
    end

    # `sort_by` and not `<`: Array has `<=>` but no `<`, and the first version of this example
    # asserted with `be <` and failed on the matcher rather than on the subject.
    it 'sorts labels naturally, so Phase 2 comes before Phase 10' do
      expect(['Phase 10', 'Phase 2', 'phase 1'].sort_by { |l| described_class.natural_key(l) })
        .to eq(['phase 1', 'Phase 2', 'Phase 10'])
    end

    it 'compares labels case-insensitively, without a locale-dependent collation' do
      expect(described_class.natural_key('phase 2')).to eq(described_class.natural_key('Phase 2'))
    end

    # BOTH SYNTHETIC BUCKETS LAST, WHATEVER `sort` SAYS — `build_axis`'s rule
    # (`query_aggregator.rb:1695-1698`).
    it 'keeps (other) and (none) at the end under a label sort' do
      result = described_class.breakdown(relation([[12, 9.0], [7, 1.0], [nil, 4.0]]),
                                        group_by: 'user', sort: 'label', limit: 1)

      expect(result['buckets'].map { |b| b['label'] }.last(2))
        .to eq([described_class::DEFAULT_OTHER_LABEL, described_class::EMPTY_LABEL])
    end

    # AN UNSUPPORTED SORT IS A DEGRADATION, NOT A SHRUG. `position` is one of the kernel's
    # three modes and is deliberately not implemented here; the first version fell through for
    # it and for `sort: banana` alike, with nothing logged and nothing on the page.
    %w[position banana].each do |mode|
      it "degrades visibly on sort: #{mode} and still answers" do
        recorder = RrdDegradeRecorder.new
        result = breakdown([[1, 2.0], [2, 9.0]], sort: mode, diagnostics: recorder)

        expect(recorder.codes).to eq([:aggregation_sort_unsupported])
        expect(result['buckets'].map { |b| b['count'] }).to eq([9.0, 2.0])
      end
    end

    it 'says nothing about a sort it does support' do
      recorder = RrdDegradeRecorder.new
      breakdown([[1, 2.0]], sort: 'label', diagnostics: recorder)

      expect(recorder.codes).to eq([])
    end
  end

  # --------------------------------------------------------------------------------
  # `(none)` IS NOT `(other)`. An independent review measured the cap folding unclassified
  # hours into "some other activity", which is a different statement and one the README
  # explicitly denied.
  # --------------------------------------------------------------------------------

  describe 'the empty bucket' do
    let(:with_blank) { [[1, 5.0], [2, 3.0], [3, 2.0], [nil, 0.5]] }

    it 'survives a cap that folds everything else' do
      result = breakdown(with_blank, limit: 1)
      empty = result['buckets'].find { |b| b['label'] == described_class::EMPTY_LABEL }

      expect(empty).not_to be_nil
      expect(empty['count']).to eq(0.5)
    end

    it 'is not counted against the cap, so the cap means named buckets' do
      result = breakdown(with_blank, limit: 3)

      expect(result['buckets'].count { |b| b['value'] }).to eq(3)
      expect(result['truncated']).to be(false)
      expect(result['buckets'].last['label']).to eq(described_class::EMPTY_LABEL)
    end

    # A BLANK STRING IS THE SAME BUCKET AS NIL — the kernel's `blank_key?`
    # (`query_aggregator.rb:1738`), because engines disagree about which they return for a
    # NULL group key.
    it 'folds a blank string in with nil rather than making a bucket of it' do
      result = breakdown([[1, 5.0], [nil, 0.5], ['', 0.25]])
      empty = result['buckets'].select { |b| b['label'] == described_class::EMPTY_LABEL }

      expect(empty.length).to eq(1)
      expect(empty.first['count']).to eq(0.75)
    end

    it 'filters for the absence of a value, with the empty string the kernel uses' do
      result = breakdown([[1, 5.0], [nil, 0.5]])
      empty = result['buckets'].last

      expect(empty['filter']).to eq('field' => 'user_id', 'operator' => '!*', 'values' => [''])
    end
  end

  # --------------------------------------------------------------------------------
  # `(other)` CARRIES `values`, because the kernel's does (`query_aggregator.rb:1518`) and
  # because without it the bucket is indistinguishable from `(none)` — both have
  # `value: nil` — and its drill-through cannot be built at all.
  # --------------------------------------------------------------------------------

  describe 'the other bucket' do
    let(:folded) { breakdown([[1, 5.0], [2, 3.0], [3, 2.0]], limit: 1)['buckets'].last }

    it 'lists the keys it folded' do
      expect(folded['values']).to eq(%w[2 3])
    end

    it 'is distinguishable from the empty bucket, which carries no values list' do
      result = breakdown([[1, 5.0], [2, 3.0], [nil, 1.0]], limit: 1)
      other, empty = result['buckets'].last(2)

      expect(other).to have_key('values')
      expect(empty).not_to have_key('values')
    end

    it 'carries a drill-through over every key it folded, so the bucket is reachable' do
      expect(folded['filter']).to eq('field' => 'user_id', 'operator' => '=',
                                     'values' => %w[2 3])
    end
  end

  # --------------------------------------------------------------------------------
  # Labels, and the guards around them that mutation testing found unasserted.
  # --------------------------------------------------------------------------------

  describe 'labels' do
    Record = Struct.new(:id, :name, :subject) unless defined?(Record)

    let(:user_dimension) { described_class::DIMENSIONS.fetch('user') }
    let(:issue_dimension) { described_class::DIMENSIONS.fetch('issue') }

    it 'reads the label off the reader the dimension names' do
      expect(described_class.record_label(Record.new(7, 'Alice Adams', nil), user_dimension))
        .to eq('Alice Adams')
    end

    it 'prefixes an issue with its id' do
      expect(described_class.record_label(Record.new(42, nil, 'Fix the importer'),
                                          issue_dimension)).to eq('#42: Fix the importer')
    end

    # A BLANK READER FALLS BACK TO THE ID, and a surviving mutation deleted that fallback.
    # A bucket labelled with the empty string is a bucket a reader cannot act on.
    it 'falls back to the id when the reader answers blank' do
      expect(described_class.record_label(Record.new(7, '   ', nil), user_dimension))
        .to eq('User #7')
      expect(described_class.record_label(Record.new(42, nil, ''), issue_dimension))
        .to eq('#42')
    end

    # AND A RECORD THAT CANNOT ANSWER AT ALL falls back too rather than raising — the reader
    # is core's, so a Redmine that renamed `subject` must degrade to an id.
    it 'falls back when the record does not answer the reader' do
      mute = Object.new
      mute.define_singleton_method(:id) { 9 }

      expect(described_class.record_label(mute, user_dimension)).to eq('User #9')
      expect(described_class.record_label(mute, issue_dimension)).to eq('#9')
    end

    # `resolve_model` RESCUES A NameError, and a surviving mutation removed that rescue. This
    # process defines none of the models, so the rescue is the reason `breakdown` answers at
    # all here.
    it 'answers nil for a model this Redmine does not define' do
      expect(described_class.resolve_model('NoSuchModelExistsHere')).to be_nil
    end

    it 'labels a bucket with the fallback when the model cannot be resolved' do
      result = breakdown([[7, 1.0]])

      expect(result['buckets'].first['label']).to eq('User #7')
    end

    # THE VISIBILITY SCOPE FAILS CLOSED WITH NO ACTOR. Its positive half — a visible issue
    # keeping its subject — needs a real `Issue.visible` and lives in the adapter spec.
    it 'withholds a visibility-scoped label rather than reading it unscoped' do
      expect(described_class.visible_to(Object.new, issue_dimension, nil, nil)).to be_nil
    end

    it 'withholds it when the relation cannot answer .visible either' do
      expect(described_class.visible_to(Object.new, issue_dimension, Object.new, nil)).to be_nil
    end

    it 'passes an unscoped dimension\'s relation straight through' do
      relation = Object.new

      expect(described_class.visible_to(relation, user_dimension, nil, nil)).to be(relation)
    end

    # `labels_for`'s OWN RESCUE, which was a surviving mutation: `resolve_model` already
    # rescues `NameError`, so nothing in the suite reached this one and deleting it stayed
    # green. It is not decoration — a model whose table this Redmine no longer has raises
    # `StatementInvalid` from the label query, and an axis of correct figures with no labels
    # is worth infinitely more than a 500 on a report page.
    #
    # Driven by stubbing `resolve_model`, because the failure is in the relation the model
    # hands back and there is no model in this process to hand one back.
    describe 'a label query the engine refuses' do
      let(:raising_model) do
        model = Object.new
        model.define_singleton_method(:where) { |*| self }
        model.define_singleton_method(:map) do |&_block|
          raise ::ActiveRecord::StatementInvalid, 'relation "enumerations" does not exist'
        end
        model
      end

      it 'answers no labels rather than raising' do
        allow(described_class).to receive(:resolve_model).and_return(raising_model)

        expect(described_class.labels_for(user_dimension, [1, 2], nil, nil)).to eq({})
      end

      it 'says so in the log, because a silent unlabelled axis is a puzzle' do
        allow(described_class).to receive(:resolve_model).and_return(raising_model)
        logger = RrdRecordingLogger.new

        described_class.labels_for(user_dimension, [1], nil, logger)

        expect(logger.lines.join).to include('label lookup failed')
      end

      # AND THE BREAKDOWN STILL ANSWERS, with the fallback labels and the right figures.
      it 'still produces the axis, with fallback labels' do
        allow(described_class).to receive(:resolve_model).and_return(raising_model)
        result = breakdown([[7, 3.0]])

        expect(result['buckets'].first['label']).to eq('User #7')
        expect(result['buckets'].first['count']).to eq(3.0)
      end
    end
  end

  # --------------------------------------------------------------------------------
  # Refusals: both halves, every time.
  # --------------------------------------------------------------------------------

  describe 'refusals' do
    it 'refuses an unknown dimension and an unknown measure, visibly, and answers nil' do
      { { group_by: 'activty' } => :aggregation_dimension_unknown,
        { group_by: 'user', measure: 'median' } => :aggregation_measure_unknown }
        .each do |options, code|
        recorder = RrdDegradeRecorder.new

        expect(described_class.breakdown(relation([]), diagnostics: recorder, **options)).to be_nil
        expect(recorder.codes).to eq([code])
      end
    end

    # THE LOG HALF, which a surviving mutation deleted while every example stayed green. The
    # method's own comment says "both halves, in one place so neither can be forgotten"; this
    # is what makes that true rather than aspirational.
    it 'writes a log line as well as a degradation' do
      logger = RrdRecordingLogger.new
      described_class.breakdown(relation([]), group_by: 'activty', logger: logger)

      expect(logger.lines.length).to eq(1)
      expect(logger.lines.first).to include('[time_entry_aggregation]')
      expect(logger.lines.first).to include('activty')
    end

    it 'logs a degradation that is not a refusal too' do
      logger = RrdRecordingLogger.new
      described_class.breakdown(relation([[1, 1.0]]), group_by: 'user', sort: 'position',
                                                      logger: logger)

      expect(logger.lines.join("\n")).to include('sort:')
    end

    # AND IT SURVIVES A LOGGER THAT CANNOT LOG, which is the default (`logger: nil`).
    it 'does not raise when there is neither a logger nor diagnostics' do
      expect { described_class.breakdown(relation([]), group_by: 'activty') }.not_to raise_error
    end
  end

  # --------------------------------------------------------------------------------
  # The result vocabulary, at the structural level. Its agreement with a REAL
  # `dimension_breakdown` call is asserted in the adapter spec.
  # --------------------------------------------------------------------------------

  describe 'the result' do
    let(:result) { breakdown([[1, 2.0]]) }

    it 'names the measure and leaves field_name nil, as a core dimension does' do
      expect(result['measure']).to eq('hours')
      expect(result['measure_field']).to eq('hours')
      expect(result['field_name']).to be_nil
      expect(result['multi_value']).to be(false)
    end

    it 'reports a count measure as a count with no measure field' do
      counted = breakdown([[1, 2]], measure: 'count')

      expect(counted['measure']).to eq('count')
      expect(counted['measure_field']).to be_nil
      expect(counted['buckets'].first['count']).to eq(2)
      expect(counted['buckets'].first['count']).to be_an(Integer)
    end

    # A COUNTED TOTAL COSTS NO STATEMENT — it is the sum of its buckets, exactly as
    # `QueryAggregator.result_total` does it. Asserted on the CALLS, because the figures are
    # provably equal and only the statement count can tell the two apart.
    it 'reads no scalar for a counted axis, and does read one for a measured axis' do
      counted = relation([[1, 2], [2, 3]])
      described_class.breakdown(counted, group_by: 'user', measure: 'count')

      measured = relation([[1, 2.0], [2, 3.0]])
      described_class.breakdown(measured, group_by: 'user')

      expect(counted.calls.count { |name, args| name == :pluck && args.length == 1 }).to eq(0)
      expect(measured.calls.count { |name, args| name == :pluck && args.length == 1 }).to eq(1)
    end

    it 'totals a counted axis from its buckets, folded tail included' do
      counted = breakdown([[1, 5], [2, 3], [3, 2]], measure: 'count', limit: 1)

      expect(counted['total']).to eq(10)
    end
  end
end
