# frozen_string_literal: true
#
# T-31 `Accept:` clause 5 — THE GROUPED AGGREGATE IS READ BY POSITION, and this file is the
# mechanical control that says so. A comment would not be one (CLAUDE.md §3, phase 2: "a
# control that was specified as mechanical and implemented as a comment").
#
# --- THE DEFECT THIS EXISTS FOR ---
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
# what makes a spec the only available control, and it is why the assertion is over the
# module's own SOURCE rather than over an example it happens to have.
#
# --- WHY BOTH A SOURCE SCAN AND A BEHAVIOURAL DOUBLE ---
#
# The source scan catches the construct wherever it is added, including in a method no
# example calls. The double catches a reader that plucks but reads the WRONG position, and
# an accidental `relation.count` with no argument — which the scan can see only as text.
# Neither subsumes the other, and the length case itself is measured against a real engine in
# `spec/adapter/time_entry_aggregator_spec.rb`, where a 390-character group expression is run
# on PostgreSQL, MySQL 8 and MariaDB 11.

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

unless defined?(Arel)
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
  attr_reader :calls, :grouped_by

  def initialize(sql:, rows: [], total: 0.0, raise_on_pluck: false)
    @sql = sql
    @rows = rows
    @total = total
    @raise_on_pluck = raise_on_pluck
    @calls = []
    @grouped_by = nil
  end

  def to_sql
    @sql
  end

  def unscope(*args)
    @calls << [:unscope, args]
    self
  end

  def group(expression)
    @calls << [:group, expression]
    @grouped_by = expression
    self
  end

  def pluck(*expressions)
    @calls << [:pluck, expressions]
    raise ::ActiveRecord::StatementInvalid, 'column issues.tracker_id does not exist' if @raise_on_pluck

    expressions.length == 1 ? [@total] : @rows
  end
end

RSpec.describe RedmineReporterDashboards::Aggregation::TimeEntryAggregator do
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
    # broken rather than the file clean. Mutation-testing this spec by hand proves the same
    # point once; this proves it on every run.
    it 'would catch the construct if it were added' do
      planted = [[1, "        scope.group(expr).sum(Arel.sql('SUM(x)'))\n"]]

      expect(planted.select { |_n, line| line.match?(RRD_GROUPED_CALCULATION) })
        .to eq(planted)
    end

    it 'permits the in-memory Enumerable form the cap uses' do
      permitted = [[1, "        folded = ordered.drop(limit).sum { |_, value| value }\n"]]

      expect(permitted.select { |_n, line| line.match?(RRD_GROUPED_CALCULATION) })
        .to eq([])
    end

    it 'groups in exactly one place, so there is one read to keep correct' do
      grouping = code_lines.select { |_number, line| line.match?(/\.group\(/) }

      expect(grouping.size).to eq(1)
    end

    it 'plucks wherever it groups' do
      expect(code_lines.count { |_number, line| line.match?(/\.pluck\(/) }).to be >= 1
    end
  end

  # --------------------------------------------------------------------------------
  # The behavioural half. A relation double that records what was asked of it.
  # --------------------------------------------------------------------------------

  let(:joined_sql) { 'SELECT time_entries.* FROM time_entries LEFT OUTER JOIN issues ON issues.id = time_entries.issue_id' }

  def relation(rows, sql: joined_sql)
    RrdRecordingRelation.new(sql: sql, rows: rows)
  end

  it 'reads the grouped rows as [key, measure] pairs by position' do
    scope = relation([[20, 3.0], [nil, 1.5]])
    described_class.breakdown(scope, group_by: 'activity')

    pluck = scope.calls.find { |name, _| name == :pluck }[1]
    expect(pluck.length).to eq(2)
    expect(pluck.first).to eq('time_entries.activity_id')
    expect(pluck.last).to eq('SUM(time_entries.hours)')
  end

  it 'drops the ORDER BY before grouping, which some engines reject and none needs' do
    scope = relation([[20, 3.0]])
    described_class.breakdown(scope, group_by: 'activity')

    expect(scope.calls.first).to eq([:unscope, [:order]])
  end

  # THE POSITIONS ARE NOT INTERCHANGEABLE, and a reader that swapped them would still pluck.
  # Distinguishable values, so a swap cannot pass: the key is an id and the measure is not.
  it 'takes the bucket key from the first column and the figure from the second' do
    result = described_class.breakdown(relation([[20, 7.25]]), group_by: 'activity')

    expect(result['buckets'].first['value']).to eq('20')
    expect(result['buckets'].first['count']).to eq(7.25)
  end

  it 'groups by the dimension\'s own column and not by the measure' do
    scope = relation([[20, 3.0]])
    described_class.breakdown(scope, group_by: 'activity')

    expect(scope.grouped_by).to eq('time_entries.activity_id')
  end

  # --------------------------------------------------------------------------------
  # `applicable?` IS A DECISION, NOT A RESCUE (mutation-tested, and it survived first).
  # --------------------------------------------------------------------------------
  #
  # The adapter spec asserted the issue dimensions are refused on a scope with no issues
  # join, and MEASURED: forcing `applicable?` to `true` — and separately forcing
  # `joined_to_issues?` to `true` — left every one of those examples green, because
  # PostgreSQL raised on `issues.tracker_id`, `measure_rows`'s rescue swallowed it and the
  # answer was nil either way. Two guards, provably dead, in a green run.
  #
  # HERE THE DOUBLE MAKES THE DIFFERENCE OBSERVABLE WITHOUT AN ENGINE AT ALL: a refusal
  # never calls `group`, while a rescue-shaped non-refusal calls it and then fails. No
  # database, no exception, no engine-specific behaviour in the middle.
  describe 'a scope whose SQL carries no issues join' do
    let(:unjoined_sql) { 'SELECT time_entries.* FROM time_entries INNER JOIN projects ON projects.id = time_entries.project_id' }

    %w[tracker status priority author assignee version category].each do |dimension|
      it "refuses #{dimension} without touching the relation" do
        scope = relation([[1, 1.0]], sql: unjoined_sql)

        expect(described_class.breakdown(scope, group_by: dimension)).to be_nil
        expect(scope.calls.map(&:first)).not_to include(:group)
        expect(scope.calls.map(&:first)).not_to include(:pluck)
      end
    end

    it 'still answers the own-table dimensions on that very same scope' do
      %w[activity user project issue].each do |dimension|
        scope = relation([[7, 2.5]], sql: unjoined_sql)

        expect(described_class.breakdown(scope, group_by: dimension)).not_to be_nil
        expect(scope.calls.map(&:first)).to include(:group)
      end
    end

    # AND THE JOIN IS RECOGNISED WHEN IT IS THERE, in both spellings a caller may hold:
    # Redmine's raw `left_join_issue` string and an association join, quoted or not. Without
    # this the guard could be refusing every issue dimension always and the examples above
    # would all still pass.
    [
      'SELECT time_entries.* FROM time_entries LEFT OUTER JOIN issues ON issues.id = time_entries.issue_id',
      'SELECT "time_entries".* FROM "time_entries" LEFT OUTER JOIN "issues" ON "issues"."id" = "time_entries"."issue_id"',
      'SELECT time_entries.* FROM time_entries INNER JOIN issues ON issues.id = time_entries.issue_id'
    ].each_with_index do |sql, index|
      it "accepts an issue dimension when the statement holds the join (spelling #{index + 1})" do
        scope = RrdRecordingRelation.new(sql: sql, rows: [[1, 3.0]])

        expect(described_class.breakdown(scope, group_by: 'tracker')).not_to be_nil
        expect(scope.grouped_by).to eq('issues.tracker_id')
      end
    end
  end

  # --------------------------------------------------------------------------------
  # THE RESCUE IS THE BACKSTOP BEHIND `applicable?`, AND IT MUST REFUSE RATHER THAN
  # ANSWER ZERO (mutation-tested, and it survived first).
  # --------------------------------------------------------------------------------
  #
  # With `applicable?` working, nothing in the suite reached the
  # `rescue ActiveRecord::StatementInvalid` at all — so replacing its `nil` with `[]` left
  # every run green. The two are not interchangeable: `nil` is a REFUSAL, which `breakdown`
  # turns into a degradation the author reads, while `[]` is "no rows", which produces a
  # complete-looking report with a total of 0 and nothing said. That is INV-4 and INV-5's
  # distinction exactly, on the path taken when a statement does not compile.
  #
  # Driven by a double that RAISES on `pluck`, on a scope whose SQL carries the join — so
  # `applicable?` passes and the rescue is the only thing left to answer.
  describe 'a statement the engine refuses' do
    it 'refuses the whole breakdown rather than answering an empty one' do
      scope = RrdRecordingRelation.new(sql: joined_sql, raise_on_pluck: true)

      expect(described_class.breakdown(scope, group_by: 'tracker')).to be_nil
    end

    it 'says so, so an author does not read a zero as an answer' do
      scope = RrdRecordingRelation.new(sql: joined_sql, raise_on_pluck: true)
      recorded = []
      recorder = Object.new
      recorder.define_singleton_method(:degrade) { |code, **| recorded << code }

      described_class.breakdown(scope, group_by: 'tracker', diagnostics: recorder)

      expect(recorded).to eq([:aggregation_dimension_unavailable])
    end
  end
end
