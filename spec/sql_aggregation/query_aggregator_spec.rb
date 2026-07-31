# frozen_string_literal: true

require 'logger' # concurrent-ruby >= 1.3.5 no longer requires this; ActiveSupport needs Logger defined
require 'active_support'
require 'active_support/time'
require_relative '../spec_helper'

Time.zone ||= 'UTC'

unless defined?(ActiveRecord)
  module ActiveRecord
    class RecordNotFound < StandardError; end
  end
end

unless defined?(ActiveRecord::Base)
  module ActiveRecord
    # Minimal stand-in for Rails' bind-parameter substitution, enough for the
    # age dimension's CASE expression.
    class Base
      def self.sanitize_sql_array(array)
        sql, *binds = array
        binds.each { |bind| sql = sql.sub('?', "'#{bind}'") }
        sql
      end
    end
  end
end

unless defined?(Arel)
  module Arel
    def self.sql(string)
      string
    end
  end
end

unless defined?(Rails)
  module Rails
    def self.logger
      @logger ||= Logger.new(File::NULL)
    end
  end
end

require_relative '../../lib/sql_aggregation/query_aggregator'

# Chainable AR scope stub.
#
# Legacy fixtures (untouched):
#   breakdown_counts — keyed by field symbol, e.g. { status_id: {1=>42, nil=>5} }
#
# Dimension fixtures:
#   grouped_counts   — keyed by the group expression(s) as passed to #group:
#                        "NULLIF(rrd_cv_g.value, '')"                => {'415'=>3}
#                        ["NULLIF(...g...)", "NULLIF(...s...)"]      => {['415','345']=>3}
#                        :any                                        => matches any grouping
#   flag_counts      — keyed by the sorted filter symbols applied so far, e.g.
#                        { [] => 49, [:closed] => 2, [:open, :overdue] => 3 }
#   minimums / maximums — keyed by column symbol, for the flags path
#
# Recorders (joins_sql, group_expressions, count_columns) are shared with every
# derived copy, so a spec can assert on what the final chained scope received.
class ScopeStub
  attr_reader :last_group_field, :conditions, :joins_sql, :group_expressions, :count_columns

  def initialize(created_counts: {}, closed_counts: {}, open_count: 5, total: 10,
                 breakdown_counts: {}, grouped_counts: {}, flag_counts: nil,
                 minimums: {}, maximums: {})
    @created_counts    = created_counts
    @closed_counts     = closed_counts
    @open_count        = open_count
    @total             = total
    @breakdown_counts  = breakdown_counts
    @grouped_counts    = grouped_counts
    @flag_counts       = flag_counts
    @minimums          = minimums
    @maximums          = maximums
    @conditions        = {}
    @filters           = []
    @grouped           = false
    @group_fields      = []
    @excluded_ids      = false
    @joins_sql         = []
    @group_expressions = []
    @count_columns     = []
  end

  def unscope(*)
    self
  end

  def joins(*fragments)
    @joins_sql.concat(fragments)
    dup
  end

  def where(cond = nil, *_args)
    copy = dup
    copy.instance_variable_set(:@conditions, @conditions.merge(cond.is_a?(Hash) ? cond : {}))
    copy.instance_variable_set(:@filters, @filters + Array(filter_for(cond)))
    copy
  end

  def not(cond = nil)
    copy = dup
    if cond.nil? || (cond.is_a?(Hash) && cond.key?(:status_id))
      copy.instance_variable_set(:@excluded_ids, true)
    end
    copy.instance_variable_set(:@filters, @filters + Array(negated_filter_for(cond)))
    copy
  end

  def group(*fields)
    @group_expressions.concat(fields)
    copy = dup
    copy.instance_variable_set(:@grouped, true)
    copy.instance_variable_set(:@group_fields, fields)
    copy.instance_variable_set(:@last_group_field, fields.first)
    copy
  end

  def minimum(field)
    @minimums[field]
  end

  def maximum(field)
    @maximums[field]
  end

  def count(column = nil)
    @count_columns << column

    if @grouped
      grouped_count
    elsif @flag_counts
      @flag_counts.fetch(@filters.sort, 0)
    elsif @excluded_ids
      @open_count
    else
      @total
    end
  end

  private

  def grouped_count
    return @grouped_counts.fetch(@group_fields) if @grouped_counts.key?(@group_fields)
    if @group_fields.size == 1 && @grouped_counts.key?(@group_fields.first)
      return @grouped_counts.fetch(@group_fields.first)
    end
    return @grouped_counts.fetch(:any) if @grouped_counts.key?(:any)

    if @excluded_ids
      {}
    elsif @breakdown_counts.key?(@last_group_field)
      @breakdown_counts[@last_group_field]
    elsif @conditions[:status_id]
      @closed_counts
    else
      @created_counts
    end
  end

  def filter_for(cond)
    case cond
    when Hash
      return :closed      if cond.key?(:status_id)
      return :no_estimate if cond.key?(:estimated_hours)
    when String
      return :overdue       if cond.include?('due_date <')
      return :period_window if cond.include?('>=')
    end
    nil
  end

  def negated_filter_for(cond)
    return nil unless cond.is_a?(Hash)
    return :open      if cond.key?(:status_id)
    return :assigned  if cond.key?(:assigned_to_id)
    return :with_due  if cond.key?(:due_date)

    nil
  end
end

# Issue custom field stub: id / name / multiple? / possible_values / format.
# field_format defaults to 'list' — the format that must keep the documented
# cast_value-first label chain.
#
# `type` is the STI column, exactly as a real custom_fields row carries it. The
# stub deliberately does NOT respond to `customized_type`: that attribute does
# not exist on CustomField (only on custom_values, and in the REST API
# representation, where it is rendered lowercase). A stub that answered it would
# hide the very bug this suite must catch.
class CustomFieldStub
  attr_reader :id, :name, :type, :possible_values, :format, :field_format

  def initialize(id:, name:, type: 'IssueCustomField', multiple: false,
                 possible_values: [], format: nil, field_format: 'list',
                 visibility: '1=1')
    @id              = id
    @name            = name
    @type            = type
    @multiple        = multiple
    @possible_values = possible_values
    @format          = format
    @field_format    = field_format
    @visibility      = visibility
  end

  def multiple?
    @multiple
  end

  # Mirrors CustomField#visibility_by_project_condition.
  def visibility_by_project_condition
    raise StandardError, @visibility if @visibility == :raise

    @visibility
  end
end

# Stands in for Redmine::FieldFormat::Base#cast_value, and counts its calls:
# for an enumeration format Redmine runs one find_by_id per value, so the
# aggregator must not reach for it when a batched lookup answers the same.
class FormatStub
  attr_reader :calls

  def initialize(&block)
    @block = block
    @calls = 0
  end

  def cast_value(custom_field, raw)
    @calls += 1
    @block ? @block.call(custom_field, raw) : nil
  end
end

# CustomField.find_by(id:) over a fixed {id => CustomFieldStub} map.
module CustomFieldRegistryStub
  def self.build(map)
    Class.new do
      define_singleton_method(:_map) { map }
      define_singleton_method(:find_by) { |id:| _map[id.to_i] }
    end
  end
end

# CustomFieldEnumeration.where(id: ids).pluck(:id, :name | :position).
# Stateless: `where` returns a selection instead of mutating class state.
class EnumerationSelectionStub
  def initialize(records)
    @records = records
  end

  def pluck(_id_column, attribute)
    @records.map { |id, record| [id, record[attribute]] }
  end
end

module CustomFieldEnumerationStub
  def self.build(records)
    Class.new do
      define_singleton_method(:_records) { records }
      define_singleton_method(:where) do |id:|
        ids = Array(id).map(&:to_i)
        EnumerationSelectionStub.new(_records.select { |eid, _| ids.include?(eid) })
      end
    end
  end
end

# User.where(id: ids) supporting both .pluck(:id, :login) (legacy breakdown) and
# .to_a returning records that respond to #name (dimension breakdown).
UserRecordStub = Struct.new(:id, :login, :name)

class UserSelectionStub
  def initialize(records)
    @records = records
  end

  def to_a
    @records
  end

  def pluck(_id_column, attribute)
    @records.map { |record| [record.id, record.public_send(attribute)] }
  end
end

module UserRegistryStub
  def self.build(records)
    Class.new do
      define_singleton_method(:_records) { records }
      define_singleton_method(:where) do |id:|
        ids = Array(id)
        UserSelectionStub.new(_records.select { |record| ids.include?(record.id) })
      end
    end
  end
end

class CustomValueStub
  def self.table_name
    'custom_values'
  end
end

# cf 92 "Department" and cf 86 "Lesson Type" (enumeration ids, as Redmine stores them).
DEPARTMENT_ENUM_FIXTURE = {
  415 => { name: 'Survey',      position: 2 },
  416 => { name: 'Geotech',     position: 1 },
  417 => { name: 'Positioning', position: 3 }
}.freeze

LESSON_TYPE_ENUM_FIXTURE = {
  345 => { name: 'Positive',       position: 1 },
  346 => { name: 'Negative',       position: 2 },
  347 => { name: 'Recommendation', position: 3 }
}.freeze

ALL_ENUM_FIXTURE = DEPARTMENT_ENUM_FIXTURE.merge(LESSON_TYPE_ENUM_FIXTURE).freeze

class IssueStatusStubClass
  class << self
    attr_accessor :closed_ids

    def where(*)
      self
    end

    def pluck(*)
      @closed_ids || [3, 4]
    end
  end
end

# Generic two-column stub used for breakdown lookups.
# Usage: stub_const('Tracker', LookupStub.build({2 => 'Bug', 5 => 'Feature'}))
module LookupStub
  def self.build(map)
    Class.new do
      define_singleton_method(:_map) { map }
      def self.where(*); self; end
      def self.pluck(id_col, name_col)
        _map.map { |id, name| [id, name] }
      end
    end
  end
end

RSpec.describe SqlAggregation::QueryAggregator do
  before do
    stub_const('IssueStatus', IssueStatusStubClass)
    IssueStatusStubClass.closed_ids = [3, 4]
  end

  # ------------------------------------------------------------------
  # build_labels
  # ------------------------------------------------------------------

  describe '.build_labels' do
    it 'returns YYYY-MM-DD labels for day period' do
      labels = described_class.send(:build_labels, 3, 'day')
      expect(labels.length).to eq(3)
      labels.each { |l| expect(l).to match(/\A\d{4}-\d{2}-\d{2}\z/) }
    end

    it 'returns labels in ascending order for day period' do
      expect(described_class.send(:build_labels, 5, 'day')).to eq(
        described_class.send(:build_labels, 5, 'day').sort
      )
    end

    it 'returns ISO week labels for week period' do
      labels = described_class.send(:build_labels, 4, 'week')
      expect(labels.length).to eq(4)
      labels.each { |l| expect(l).to match(/\A\d{4}-W\d{2}\z/) }
    end

    it 'returns labels in ascending order for week period' do
      expect(described_class.send(:build_labels, 5, 'week')).to eq(
        described_class.send(:build_labels, 5, 'week').sort
      )
    end

    it 'returns YYYY-MM labels for month period' do
      labels = described_class.send(:build_labels, 6, 'month')
      expect(labels.length).to eq(6)
      labels.each { |l| expect(l).to match(/\A\d{4}-\d{2}\z/) }
    end

    it 'returns labels in ascending order for month period' do
      expect(described_class.send(:build_labels, 6, 'month')).to eq(
        described_class.send(:build_labels, 6, 'month').sort
      )
    end

    it 'returns YYYY labels for year period' do
      labels = described_class.send(:build_labels, 3, 'year')
      expect(labels.length).to eq(3)
      labels.each { |l| expect(l).to match(/\A\d{4}\z/) }
    end

    it 'returns labels in ascending order for year period' do
      expect(described_class.send(:build_labels, 3, 'year')).to eq(
        described_class.send(:build_labels, 3, 'year').sort
      )
    end

    it 'falls back to monthly labels for unknown period' do
      described_class.send(:build_labels, 3, 'unknown').each do |l|
        expect(l).to match(/\A\d{4}-\d{2}\z/)
      end
    end
  end

  # ------------------------------------------------------------------
  # .aggregate — time-series
  # ------------------------------------------------------------------

  describe '.aggregate' do
    context 'period: month (default)' do
      let(:labels) { described_class.send(:build_labels, 6, 'month') }
      let(:scope) do
        ScopeStub.new(
          created_counts: { labels[5] => 10, labels[4] => 8 },
          closed_counts:  { labels[5] => 6,  labels[4] => 5 },
          open_count: 42, total: 100
        )
      end

      subject(:result) { described_class.aggregate(scope, period: 'month', periods: 6) }

      it 'returns expected keys including period and periods' do
        expect(result.keys).to match_array(%w[labels created closed open_now total period periods])
      end

      it 'echoes period type' do
        expect(result['period']).to eq('month')
      end

      it 'echoes periods count' do
        expect(result['periods']).to eq(6)
      end

      it 'returns exactly 6 labels' do
        expect(result['labels'].length).to eq(6)
      end

      it 'fills zero for periods with no data' do
        expect(result['created'].first(4)).to all(eq(0))
      end

      it 'maps fixture created counts correctly' do
        l = result['labels']
        expect(result['created'][l.length - 1]).to eq(10)
        expect(result['created'][l.length - 2]).to eq(8)
      end

      it 'returns open_now from scope' do
        expect(result['open_now']).to eq(42)
      end

      it 'returns total from scope' do
        expect(result['total']).to eq(100)
      end
    end

    context 'period: day' do
      let(:labels) { described_class.send(:build_labels, 7, 'day') }
      let(:scope) do
        ScopeStub.new(created_counts: { labels[6] => 3 }, closed_counts: { labels[6] => 1 },
                      open_count: 5, total: 20)
      end

      subject(:result) { described_class.aggregate(scope, period: 'day', periods: 7) }

      it 'returns 7 day labels' do
        expect(result['labels'].length).to eq(7)
      end

      it 'returns YYYY-MM-DD labels' do
        result['labels'].each { |l| expect(l).to match(/\A\d{4}-\d{2}-\d{2}\z/) }
      end

      it 'echoes period: day' do
        expect(result['period']).to eq('day')
      end

      it 'maps fixture count to last day' do
        expect(result['created'].last).to eq(3)
      end
    end

    context 'period: week' do
      let(:labels) { described_class.send(:build_labels, 4, 'week') }
      let(:scope) do
        ScopeStub.new(created_counts: { labels[3] => 5 }, closed_counts: {}, open_count: 2, total: 8)
      end

      subject(:result) { described_class.aggregate(scope, period: 'week', periods: 4) }

      it 'returns 4 week labels' do
        expect(result['labels'].length).to eq(4)
      end

      it 'returns ISO week labels' do
        result['labels'].each { |l| expect(l).to match(/\A\d{4}-W\d{2}\z/) }
      end

      it 'echoes period: week' do
        expect(result['period']).to eq('week')
      end
    end

    context 'period: year' do
      let(:labels) { described_class.send(:build_labels, 3, 'year') }
      let(:scope) do
        ScopeStub.new(created_counts: { labels[2] => 100 }, closed_counts: { labels[2] => 80 },
                      open_count: 20, total: 200)
      end

      subject(:result) { described_class.aggregate(scope, period: 'year', periods: 3) }

      it 'returns 3 year labels' do
        expect(result['labels'].length).to eq(3)
      end

      it 'returns YYYY labels' do
        result['labels'].each { |l| expect(l).to match(/\A\d{4}\z/) }
      end

      it 'echoes period: year' do
        expect(result['period']).to eq('year')
      end
    end

    context 'periods parameter validation' do
      let(:scope) { ScopeStub.new }

      it 'defaults to 6 when nil for month'  do
        expect(described_class.aggregate(scope, period: 'month',  periods: nil)['labels'].length).to eq(6)
      end

      it 'defaults to 30 when nil for day' do
        expect(described_class.aggregate(scope, period: 'day',    periods: nil)['labels'].length).to eq(30)
      end

      it 'defaults to 13 when nil for week' do
        expect(described_class.aggregate(scope, period: 'week',   periods: nil)['labels'].length).to eq(13)
      end

      it 'defaults to 3 when nil for year' do
        expect(described_class.aggregate(scope, period: 'year',   periods: nil)['labels'].length).to eq(3)
      end

      it 'caps at 24 for month' do
        expect(described_class.aggregate(scope, period: 'month',  periods: 30)['labels'].length).to eq(24)
      end

      it 'caps at 90 for day' do
        expect(described_class.aggregate(scope, period: 'day',    periods: 120)['labels'].length).to eq(90)
      end

      it 'caps at 52 for week' do
        expect(described_class.aggregate(scope, period: 'week',   periods: 100)['labels'].length).to eq(52)
      end

      it 'caps at 10 for year' do
        expect(described_class.aggregate(scope, period: 'year',   periods: 15)['labels'].length).to eq(10)
      end

      it 'uses default when periods is 0' do
        expect(described_class.aggregate(scope, period: 'month',  periods: 0)['labels'].length).to eq(6)
      end

      it 'uses default when periods is negative' do
        expect(described_class.aggregate(scope, period: 'month',  periods: -5)['labels'].length).to eq(6)
      end
    end

    context 'when no issues match' do
      let(:empty_scope) { ScopeStub.new(open_count: 0, total: 0) }

      it 'returns all-zero arrays' do
        r = described_class.aggregate(empty_scope, period: 'month', periods: 3)
        expect(r['created']).to eq([0, 0, 0])
        expect(r['closed']).to eq([0, 0, 0])
        expect(r['open_now']).to eq(0)
        expect(r['total']).to eq(0)
      end
    end
  end

  # ------------------------------------------------------------------
  # .breakdown — categorical grouping
  # ------------------------------------------------------------------

  describe '.breakdown' do
    let(:status_stub)   { LookupStub.build(1 => 'New', 3 => 'Closed', 5 => 'In Progress') }
    let(:priority_stub) { LookupStub.build(1 => 'Low', 2 => 'Normal', 3 => 'High') }
    let(:tracker_stub)  { LookupStub.build(1 => 'Bug', 2 => 'Feature') }
    let(:user_stub)     { LookupStub.build(10 => 'alice', 11 => 'bob') }
    let(:category_stub) { LookupStub.build(7 => 'Backend') }
    let(:version_stub)  { LookupStub.build(4 => 'v1.0', 5 => 'v2.0') }

    before do
      stub_const('IssuePriority', priority_stub)
      stub_const('Tracker',       tracker_stub)
      stub_const('User',          user_stub)
      stub_const('IssueCategory', category_stub)
      stub_const('Version',       version_stub)
    end

    context 'group_by: status' do
      before { stub_const('IssueStatus', status_stub) }

      let(:scope) do
        ScopeStub.new(total: 60,
                      breakdown_counts: { status_id: { 1 => 20, 3 => 30, 5 => 10 } })
      end

      subject(:result) { described_class.breakdown(scope, group_by: 'status') }

      it 'returns buckets, total, group_by keys' do
        expect(result.keys).to match_array(%w[buckets total group_by])
      end

      it 'echoes group_by' do
        expect(result['group_by']).to eq('status')
      end

      it 'returns one bucket per distinct value' do
        expect(result['buckets'].length).to eq(3)
      end

      it 'resolves status names' do
        labels = result['buckets'].map { |b| b['label'] }
        expect(labels).to include('New', 'Closed', 'In Progress')
      end

      it 'sorts buckets by count descending' do
        counts = result['buckets'].map { |b| b['count'] }
        expect(counts).to eq(counts.sort.reverse)
      end

      it 'returns correct total' do
        expect(result['total']).to eq(60)
      end
    end

    context 'group_by: priority' do
      let(:scope) do
        ScopeStub.new(breakdown_counts: { priority_id: { 1 => 5, 2 => 40, 3 => 15 } })
      end

      subject(:result) { described_class.breakdown(scope, group_by: 'priority') }

      it 'resolves priority names' do
        labels = result['buckets'].map { |b| b['label'] }
        expect(labels).to include('Low', 'Normal', 'High')
      end

      it 'echoes group_by: priority' do
        expect(result['group_by']).to eq('priority')
      end
    end

    context 'group_by: tracker' do
      let(:scope) do
        ScopeStub.new(breakdown_counts: { tracker_id: { 1 => 35, 2 => 25 } })
      end

      subject(:result) { described_class.breakdown(scope, group_by: 'tracker') }

      it 'resolves tracker names' do
        expect(result['buckets'].map { |b| b['label'] }).to include('Bug', 'Feature')
      end

      it 'echoes group_by: tracker' do
        expect(result['group_by']).to eq('tracker')
      end
    end

    context 'group_by: assignee' do
      let(:scope) do
        ScopeStub.new(breakdown_counts: { assigned_to_id: { 10 => 18, 11 => 12, nil => 5 } })
      end

      subject(:result) { described_class.breakdown(scope, group_by: 'assignee') }

      it 'resolves user logins' do
        labels = result['buckets'].map { |b| b['label'] }
        expect(labels).to include('alice', 'bob')
      end

      it 'uses Unassigned label for nil id' do
        expect(result['buckets'].map { |b| b['label'] }).to include('Unassigned')
      end

      it 'includes nil-id count in total' do
        expect(result['total']).to eq(35)
      end
    end

    context 'group_by: author' do
      let(:scope) do
        ScopeStub.new(breakdown_counts: { author_id: { 10 => 30, 11 => 10 } })
      end

      subject(:result) { described_class.breakdown(scope, group_by: 'author') }

      it 'resolves author logins' do
        expect(result['buckets'].map { |b| b['label'] }).to include('alice', 'bob')
      end
    end

    context 'group_by: category' do
      let(:scope) do
        ScopeStub.new(breakdown_counts: { category_id: { 7 => 22, nil => 8 } })
      end

      subject(:result) { described_class.breakdown(scope, group_by: 'category') }

      it 'resolves category names' do
        expect(result['buckets'].map { |b| b['label'] }).to include('Backend')
      end

      it 'uses None label for uncategorized issues' do
        expect(result['buckets'].map { |b| b['label'] }).to include('None')
      end
    end

    context 'group_by: version' do
      let(:scope) do
        ScopeStub.new(breakdown_counts: { fixed_version_id: { 4 => 15, 5 => 25, nil => 10 } })
      end

      subject(:result) { described_class.breakdown(scope, group_by: 'version') }

      it 'resolves version names' do
        labels = result['buckets'].map { |b| b['label'] }
        expect(labels).to include('v1.0', 'v2.0')
      end

      it 'uses None for unversioned issues' do
        expect(result['buckets'].map { |b| b['label'] }).to include('None')
      end
    end

    context 'with unknown group_by dimension' do
      let(:scope) { ScopeStub.new }

      it 'returns empty buckets and zero total' do
        r = described_class.breakdown(scope, group_by: 'nonexistent')
        expect(r['buckets']).to eq([])
        expect(r['total']).to eq(0)
        expect(r['group_by']).to eq('nonexistent')
      end
    end

    context 'when scope has no issues' do
      let(:scope) { ScopeStub.new(breakdown_counts: { status_id: {} }) }

      before { stub_const('IssueStatus', status_stub) }

      it 'returns empty buckets' do
        r = described_class.breakdown(scope, group_by: 'status')
        expect(r['buckets']).to eq([])
        expect(r['total']).to eq(0)
      end
    end

    context 'fallback label when name not found in lookup' do
      let(:scope) do
        ScopeStub.new(breakdown_counts: { tracker_id: { 99 => 7 } })
      end

      it 'uses "Tracker #99" as fallback' do
        r = described_class.breakdown(scope, group_by: 'tracker')
        expect(r['buckets'].first['label']).to eq('Tracker #99')
      end
    end
  end

  # ------------------------------------------------------------------
  # .monthly_flow — backward-compatible alias
  # ------------------------------------------------------------------

  describe '.monthly_flow' do
    let(:labels) { described_class.send(:build_labels, 6, 'month') }
    let(:scope) do
      ScopeStub.new(
        created_counts: { labels[5] => 10, labels[4] => 8 },
        closed_counts:  { labels[5] => 6,  labels[4] => 5 },
        open_count: 42, total: 100
      )
    end

    subject(:result) { described_class.monthly_flow(scope, months: 6) }

    it 'returns exactly months labels'                    do expect(result['labels'].length).to eq(6)         end
    it 'returns labels in ascending order (oldest first)' do expect(result['labels']).to eq(result['labels'].sort) end
    it 'returns YYYY-MM formatted labels'                 do result['labels'].each { |l| expect(l).to match(/\A\d{4}-\d{2}\z/) } end
    it 'returns created counts as integers'               do expect(result['created']).to all(be_a(Integer))  end
    it 'returns closed counts as integers'                do expect(result['closed']).to  all(be_a(Integer))  end
    it 'fills zero for months with no data'               do expect(result['created'].first(4)).to all(eq(0)) end
    it 'returns open_now from scope'                      do expect(result['open_now']).to eq(42)             end
    it 'returns total from scope'                         do expect(result['total']).to   eq(100)             end

    context 'months parameter validation' do
      it 'defaults to 6 when months is 0'       do expect(described_class.monthly_flow(scope, months:  0)['labels'].length).to eq(6)  end
      it 'defaults to 6 when months is negative' do expect(described_class.monthly_flow(scope, months: -3)['labels'].length).to eq(6)  end
      it 'caps at 24 months'                     do expect(described_class.monthly_flow(scope, months: 30)['labels'].length).to eq(24) end
      it 'accepts months=1'                      do expect(described_class.monthly_flow(scope, months:  1)['labels'].length).to eq(1)  end
    end

    context 'with named closed_statuses' do
      before do
        IssueStatusStubClass.closed_ids = [7, 8]
        allow(IssueStatus).to receive(:where).with(name: ['Closed', 'Rejected']).and_return(IssueStatus)
        allow(IssueStatus).to receive(:pluck).and_return([7, 8])
      end

      it 'looks up IDs by name' do
        r = described_class.monthly_flow(scope, months: 2, closed_statuses: ['Closed', 'Rejected'])
        expect(r.keys).to include('closed')
      end
    end

    context 'when no issues match' do
      let(:empty_scope) { ScopeStub.new(open_count: 0, total: 0) }

      it 'returns all-zero arrays' do
        r = described_class.monthly_flow(empty_scope, months: 3)
        expect(r['created']).to eq([0, 0, 0])
        expect(r['closed']).to eq([0, 0, 0])
      end
    end
  end

  # ------------------------------------------------------------------
  # .resolve_closed_ids (via monthly_flow)
  # ------------------------------------------------------------------

  describe '.resolve_closed_ids (via monthly_flow)' do
    let(:scope) { ScopeStub.new }

    it 'uses is_closed flag when no status names given' do
      expect(IssueStatus).to receive(:where).with(is_closed: true).and_return(IssueStatus)
      expect(IssueStatus).to receive(:pluck).and_return([3, 4])
      described_class.monthly_flow(scope, months: 1, closed_statuses: [])
    end

    it 'uses status names when provided' do
      expect(IssueStatus).to receive(:where).with(name: ['Done']).and_return(IssueStatus)
      expect(IssueStatus).to receive(:pluck).and_return([9])
      described_class.monthly_flow(scope, months: 1, closed_statuses: ['Done'])
    end

    it 'logs a warning when named statuses match nothing' do
      allow(IssueStatus).to receive(:where).with(name: ['Typo']).and_return(IssueStatus)
      allow(IssueStatus).to receive(:pluck).and_return([])
      expect(Rails.logger).to receive(:warn).with(/matched no IssueStatus records/)
      described_class.monthly_flow(scope, months: 1, closed_statuses: ['Typo'])
    end
  end

  describe '.aggregate with empty closed_ids' do
    let(:scope) { ScopeStub.new(open_count: 5, total: 5) }

    before do
      allow(IssueStatus).to receive(:where).with(is_closed: true).and_return(IssueStatus)
      allow(IssueStatus).to receive(:pluck).and_return([])
    end

    it 'treats all issues as open when no closed statuses exist' do
      r = described_class.aggregate(scope, period: 'month', periods: 1)
      expect(r['open_now']).to eq(5)
    end

    it 'returns all-zero closed array when no closed statuses exist' do
      r = described_class.aggregate(scope, period: 'month', periods: 1)
      expect(r['closed']).to eq([0])
    end
  end

  # ------------------------------------------------------------------
  # Database adapters
  # ------------------------------------------------------------------

  describe 'adapter support' do
    after { described_class.instance_variable_set(:@adapter_family, nil) }

    def group_expression(family)
      described_class.instance_variable_set(:@adapter_family, family)
      scope = ScopeStub.new
      described_class.aggregate(scope, period: 'month', periods: 1)
      scope.group_expressions.first
    end

    it 'formats periods with TO_CHAR on PostgreSQL' do
      expect(group_expression(:postgresql)).to eq("TO_CHAR(issues.created_on, 'YYYY-MM')")
    end

    it 'formats periods with DATE_FORMAT on MySQL' do
      expect(group_expression(:mysql)).to eq("DATE_FORMAT(issues.created_on, '%Y-%m')")
    end

    it 'fails loudly on an adapter it cannot speak, instead of emitting MySQL syntax' do
      described_class.instance_variable_set(:@adapter_family, :unsupported)
      expect { described_class.aggregate(ScopeStub.new, period: 'month', periods: 1) }
        .to raise_error(described_class::UnsupportedAdapterError, /PostgreSQL or MySQL/)
    end

    it 'raises a StandardError, so the tags still degrade to the empty result' do
      expect(described_class::UnsupportedAdapterError.ancestors).to include(StandardError)
    end

    it 'falls back to MySQL syntax when there is no connection to ask' do
      # :unknown is "could not read the adapter name", not "some other database".
      expect(group_expression(:unknown)).to start_with('DATE_FORMAT')
    end
  end

  # ------------------------------------------------------------------
  # period_from — the WHERE window must cover exactly the label axis
  # ------------------------------------------------------------------

  describe '.period_from' do
    it 'starts at the oldest month build_labels produces' do
      oldest = described_class.build_labels(6, 'month').first
      expect(described_class.send(:period_from, 6, 'month').strftime('%Y-%m')).to eq(oldest)
    end

    it 'starts at the oldest day build_labels produces' do
      oldest = described_class.build_labels(30, 'day').first
      expect(described_class.send(:period_from, 30, 'day').strftime('%Y-%m-%d')).to eq(oldest)
    end

    it 'starts at the oldest year build_labels produces' do
      oldest = described_class.build_labels(3, 'year').first
      expect(described_class.send(:period_from, 3, 'year').strftime('%Y')).to eq(oldest)
    end

    it 'starts inside the oldest ISO week build_labels produces' do
      from   = described_class.send(:period_from, 4, 'week')
      oldest = described_class.build_labels(4, 'week').first
      expect("#{from.to_date.cwyear}-W#{from.to_date.cweek.to_s.rjust(2, '0')}").to eq(oldest)
    end

    it 'covers the current period when only one is asked for' do
      expect(described_class.send(:period_from, 1, 'month').strftime('%Y-%m'))
        .to eq(Date.today.strftime('%Y-%m'))
    end

    it 'never reaches into the future for a zero or negative count' do
      expect(described_class.send(:period_from, 0, 'month')).to be <= Time.now
    end
  end

  # ==================================================================
  # Regression pins — the legacy .breakdown path must not drift
  # ==================================================================

  describe '.breakdown (regression pins)' do
    let(:scope) do
      ScopeStub.new(total: 60, breakdown_counts: { status_id: { 1 => 20, 3 => 30, 5 => 10 } })
    end

    before { stub_const('IssueStatus', LookupStub.build(1 => 'New', 3 => 'Closed', 5 => 'In Progress')) }

    it 'counts issues, not joined rows' do
      described_class.breakdown(scope, group_by: 'status')
      expect(scope.count_columns).to eq(['DISTINCT issues.id'])
    end

    it 'adds no join of its own' do
      described_class.breakdown(scope, group_by: 'status')
      expect(scope.joins_sql).to be_empty
    end

    it 'groups on the bare column symbol' do
      described_class.breakdown(scope, group_by: 'status')
      expect(scope.group_expressions).to eq([:status_id])
    end

    it 'returns exactly the historical hash' do
      expect(described_class.breakdown(scope, group_by: 'status')).to eq(
        'buckets' => [
          { 'label' => 'Closed',      'count' => 30 },
          { 'label' => 'New',         'count' => 20 },
          { 'label' => 'In Progress', 'count' => 10 }
        ],
        'total'    => 60,
        'group_by' => 'status'
      )
    end

    it 'keeps the login label for assignees' do
      user_scope = ScopeStub.new(breakdown_counts: { assigned_to_id: { 10 => 3, nil => 1 } })
      stub_const('User', LookupStub.build(10 => 'alice'))

      expect(described_class.breakdown(user_scope, group_by: 'assignee')['buckets']).to eq(
        [{ 'label' => 'alice', 'count' => 3 }, { 'label' => 'Unassigned', 'count' => 1 }]
      )
    end
  end

  # ==================================================================
  # Dimension mode
  # ==================================================================

  describe '.dimension_breakdown' do
    let(:group_g) { "NULLIF(rrd_cv_g.value, '')" }
    let(:group_s) { "NULLIF(rrd_cv_s.value, '')" }

    let(:enum_format) { FormatStub.new { |_cf, raw| ALL_ENUM_FIXTURE.dig(raw.to_i, :name) } }
    # cf 92 and cf 86 are enumeration fields in the target Redmine.
    let(:department) do
      CustomFieldStub.new(id: 92, name: 'Department', format: enum_format, field_format: 'enumeration')
    end
    let(:lesson_type) do
      CustomFieldStub.new(id: 86, name: 'Lesson Type', format: enum_format, field_format: 'enumeration')
    end
    let(:project_cf)  { CustomFieldStub.new(id: 77, name: 'Budget code', type: 'ProjectCustomField') }

    let(:custom_fields) { { 92 => department, 86 => lesson_type, 77 => project_cf } }

    # The custom field dimension adds an association join next to its raw
    # custom_values fragment; the assertions below target the raw one.
    def cv_join(scope, alias_name = 'rrd_cv_g')
      scope.joins_sql.grep(String).find { |fragment| fragment.include?(alias_name) }
    end

    before do
      stub_const('CustomField', CustomFieldRegistryStub.build(custom_fields))
      stub_const('CustomFieldEnumeration', CustomFieldEnumerationStub.build(ALL_ENUM_FIXTURE))
      stub_const('CustomValue', CustomValueStub)
    end

    after { described_class.instance_variable_set(:@adapter_family, nil) }

    # ----------------------------------------------------------------
    # Custom field dimension
    # ----------------------------------------------------------------

    context 'group_by: cf_92' do
      let(:scope) do
        ScopeStub.new(grouped_counts: { group_g => { '415' => 18, '416' => 9, nil => 5 } })
      end

      subject(:result) { described_class.dimension_breakdown(scope, group_by: 'cf_92') }

      it 'resolves enumeration ids to their names' do
        expect(result['buckets'].map { |b| b['label'] }).to eq(['Survey', 'Geotech', '(none)'])
      end

      it 'keeps the counts' do
        expect(result['buckets'].map { |b| b['count'] }).to eq([18, 9, 5])
      end

      it 'puts the no-value bucket last regardless of its count' do
        expect(result['buckets'].last).to eq('label' => '(none)', 'count' => 5)
      end

      it 'sums every bucket into total' do
        expect(result['total']).to eq(32)
      end

      it 'echoes the dimension' do
        expect(result['dimension']).to eq('cf_92')
      end

      it 'exposes the human field name' do
        expect(result['field_name']).to eq('Department')
      end

      it 'reports multi_value false for a single-valued field' do
        expect(result['multi_value']).to be(false)
      end

      it 'reports truncated false when nothing was collapsed' do
        expect(result['truncated']).to be(false)
      end

      it 'counts DISTINCT issues.id' do
        result
        expect(scope.count_columns).to eq(['DISTINCT issues.id'])
      end

      it 'LEFT OUTER JOINs custom_values on the issue' do
        result
        expect(cv_join(scope)).to include(
          "LEFT OUTER JOIN custom_values rrd_cv_g ON rrd_cv_g.customized_type = 'Issue'"
        )
      end

      it 'restricts the join to the requested field id' do
        result
        expect(cv_join(scope)).to include('rrd_cv_g.custom_field_id = 92')
      end

      it 'does not use the cf_<id> alias Redmine itself uses' do
        result
        expect(cv_join(scope)).not_to match(/\bcf_92\b/)
      end

      # IssueCustomField#visibility_by_project_condition always embeds
      # Issue.visible_condition, which reads projects.status and enabled_modules.
      # A scope rebuilt from a loaded Array (Issue.where(id: ids)) has no such
      # join, and PostgreSQL then rejects the query with a missing FROM-clause
      # entry for "projects".
      it 'joins projects, which the field visibility clause references' do
        result
        expect(scope.joins_sql).to include(:project)
      end

      it 'joins projects before the custom_values fragment that reads it' do
        result
        expect(scope.joins_sql.index(:project)).to be < scope.joins_sql.index(cv_join(scope))
      end

      it 'carries the custom field visibility condition, like Redmine core does' do
        result
        expect(cv_join(scope)).to end_with('AND (1=1)')
      end

      it 'applies a role-restricted field visibility condition' do
        restricted = 'issues.project_id IN (SELECT DISTINCT m.project_id FROM members m)'
        custom_fields[92] = CustomFieldStub.new(id: 92, name: 'Client', format: enum_format,
                                                field_format: 'enumeration', visibility: restricted)
        described_class.dimension_breakdown(scope, group_by: 'cf_92')
        expect(cv_join(scope)).to include("AND (#{restricted})")
      end

      it 'hides the values rather than leaking them when the condition cannot be built' do
        custom_fields[92] = CustomFieldStub.new(id: 92, name: 'Client', format: enum_format,
                                                field_format: 'enumeration', visibility: :raise)
        allow(Rails.logger).to receive(:warn)
        described_class.dimension_breakdown(scope, group_by: 'cf_92')
        expect(cv_join(scope)).to end_with('AND (1=0)')
      end

      it 'logs why it hid the values' do
        custom_fields[92] = CustomFieldStub.new(id: 92, name: 'Client', format: enum_format,
                                                field_format: 'enumeration', visibility: :raise)
        expect(Rails.logger).to receive(:warn).with(/hiding its values/)
        described_class.dimension_breakdown(scope, group_by: 'cf_92')
      end

      it 'groups on NULLIF so empty strings join the NULL bucket' do
        result
        expect(scope.group_expressions).to eq([group_g])
      end

      it 'reports multi_value true for a multi-valued field' do
        custom_fields[92] = CustomFieldStub.new(id: 92, name: 'Department',
                                                multiple: true, format: enum_format)
        expect(described_class.dimension_breakdown(scope, group_by: 'cf_92')['multi_value']).to be(true)
      end

      it 'uses a custom empty_label when given' do
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92', empty_label: 'No department')
        expect(r['buckets'].last['label']).to eq('No department')
      end
    end

    context 'with an invalid cf_ target' do
      let(:scope) { ScopeStub.new(grouped_counts: { any: {} }) }

      it 'rejects cf_0' do
        expect(described_class.dimension_breakdown(scope, group_by: 'cf_0')).to be_nil
      end

      it 'logs a warning for cf_0' do
        expect(Rails.logger).to receive(:warn).with(/not a usable custom field id/)
        described_class.dimension_breakdown(scope, group_by: 'cf_0')
      end

      it 'rejects cf_abc as an unknown dimension' do
        expect(described_class.dimension_breakdown(scope, group_by: 'cf_abc')).to be_nil
      end

      it 'logs a warning for cf_abc' do
        expect(Rails.logger).to receive(:warn).with(/unknown dimension "cf_abc"/)
        described_class.dimension_breakdown(scope, group_by: 'cf_abc')
      end

      it 'rejects an id with no CustomField' do
        expect(described_class.dimension_breakdown(scope, group_by: 'cf_4242')).to be_nil
      end

      it 'rejects a custom field that is not an issue custom field' do
        expect(described_class.dimension_breakdown(scope, group_by: 'cf_77')).to be_nil
      end

      it 'logs a warning for a non-issue custom field' do
        expect(Rails.logger).to receive(:warn).with(/is not an issue custom field/)
        described_class.dimension_breakdown(scope, group_by: 'cf_77')
      end

      it 'never raises when the lookup itself blows up' do
        allow(CustomField).to receive(:find_by).and_raise(StandardError, 'connection lost')
        expect { described_class.dimension_breakdown(scope, group_by: 'cf_92') }.not_to raise_error
      end
    end

    # An issue custom field is recognised by its STI class, not by an attribute:
    # CustomField has no customized_type column and no such method.
    context 'identifying an issue custom field' do
      let(:scope) { ScopeStub.new(grouped_counts: { group_g => { '415' => 3 } }) }

      # Regression pin. The guard used to ask for custom_field.customized_type;
      # respond_to? was always false, so EVERY cf_<id> dimension resolved to nil
      # and the dashboard silently rendered its no-data branch.
      it 'does not expect a customized_type attribute on the record' do
        expect(department).not_to respond_to(:customized_type)
        expect(described_class.dimension_breakdown(scope, group_by: 'cf_92')).not_to be_nil
      end

      it 'accepts an IssueCustomField instance whose STI type is a plugin subclass' do
        stub_const('IssueCustomField', CustomFieldStub)
        custom_fields[92] = Class.new(CustomFieldStub).new(
          id: 92, name: 'Department', type: 'GeoIssueCustomField',
          format: enum_format, field_format: 'enumeration'
        )
        expect(described_class.dimension_breakdown(scope, group_by: 'cf_92')).not_to be_nil
      end

      it 'accepts a field whose class reports Issue as its customized class' do
        stub_const('Issue', Class.new)
        klass = Class.new(CustomFieldStub) do
          def self.customized_class
            Issue
          end
        end
        custom_fields[92] = klass.new(id: 92, name: 'Department', type: 'GeoCustomField',
                                      format: enum_format, field_format: 'enumeration')
        expect(described_class.dimension_breakdown(scope, group_by: 'cf_92')).not_to be_nil
      end

      it 'rejects a field whose class reports another customized class' do
        stub_const('Project', Class.new)
        klass = Class.new(CustomFieldStub) do
          def self.customized_class
            Project
          end
        end
        custom_fields[92] = klass.new(id: 92, name: 'Budget code', type: 'GeoCustomField')
        expect(described_class.dimension_breakdown(scope, group_by: 'cf_92')).to be_nil
      end

      it 'rejects a field that identifies as nothing at all' do
        custom_fields[92] = CustomFieldStub.new(id: 92, name: 'Mystery', type: nil)
        expect(described_class.dimension_breakdown(scope, group_by: 'cf_92')).to be_nil
      end
    end

    context 'label lookups' do
      let(:scope) do
        ScopeStub.new(grouped_counts: {
                        group_g => { '415' => 3, '416' => 2, '417' => 1, '999' => 1 }
                      })
      end

      it 'resolves an enumeration field in a single batched query' do
        expect(CustomFieldEnumeration).to receive(:where).once.and_call_original
        described_class.dimension_breakdown(scope, group_by: 'cf_92')
      end

      it 'does not fall back to cast_value when the batch resolved the value' do
        described_class.dimension_breakdown(scope, group_by: 'cf_92')
        # Only the one id with no enumeration row may reach the per-value format.
        expect(enum_format.calls).to eq(1)
      end

      it 'still labels an enumeration field correctly through the batch' do
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92')
        # 417 and 999 tie on count, so the natural label order decides.
        expect(r['buckets'].map { |b| b['label'] }).to eq(['Survey', 'Geotech', '999', 'Positioning'])
      end

      it 'detects an enumeration-backed plugin format by its target class' do
        plugin_format = FormatStub.new { |_cf, _raw| nil }
        plugin_format.define_singleton_method(:target_class) { CustomFieldEnumeration }
        custom_fields[92] = CustomFieldStub.new(id: 92, name: 'Client', format: plugin_format,
                                                field_format: 'depending_enumeration')
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92')
        expect(r['buckets'].map { |b| b['label'] }).to include('Survey', 'Geotech')
      end

      it 'never resolves a plain list field against unrelated enumeration ids' do
        # A list field whose options happen to be numeric must be named by its
        # own format, not by CustomFieldEnumeration rows with those ids.
        custom_fields[92] = CustomFieldStub.new(id: 92, name: 'Bay number',
                                                format: FormatStub.new { |_cf, raw| "Bay #{raw}" })
        numeric = ScopeStub.new(grouped_counts: { group_g => { '415' => 3, '346' => 1 } })
        r = described_class.dimension_breakdown(numeric, group_by: 'cf_92')
        expect(r['buckets'].map { |b| b['label'] }).to contain_exactly('Bay 415', 'Bay 346')
      end
    end

    context 'label fallback chain' do
      let(:scope) do
        ScopeStub.new(grouped_counts: { group_g => { '345' => 3, 'free text' => 2 } })
      end

      it 'falls back to the enumeration name when cast_value returns blank' do
        custom_fields[92] = CustomFieldStub.new(id: 92, name: 'Department',
                                                format: FormatStub.new { |_cf, _raw| '' })
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92')
        expect(r['buckets'].map { |b| b['label'] }).to include('Positive')
      end

      it 'falls back to the raw value when nothing can name it' do
        custom_fields[92] = CustomFieldStub.new(id: 92, name: 'Department',
                                                format: FormatStub.new { |_cf, _raw| nil })
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92')
        expect(r['buckets'].map { |b| b['label'] }).to include('free text')
      end

      it 'falls back to the raw value when cast_value raises' do
        custom_fields[92] = CustomFieldStub.new(
          id: 92, name: 'Department',
          format: FormatStub.new { |_cf, _raw| raise StandardError, 'bad format' }
        )
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92')
        expect(r['buckets'].map { |b| b['label'] }).to contain_exactly('Positive', 'free text')
      end

      it 'never raises when the enumeration lookup fails' do
        custom_fields[92] = CustomFieldStub.new(id: 92, name: 'Department',
                                                format: FormatStub.new { |_cf, _raw| nil })
        allow(CustomFieldEnumeration).to receive(:where).and_raise(StandardError, 'no table')
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92')
        expect(r['buckets'].map { |b| b['label'] }).to contain_exactly('345', 'free text')
      end
    end

    # ----------------------------------------------------------------
    # Sorting and limiting
    # ----------------------------------------------------------------

    context 'sorting' do
      let(:scope) do
        ScopeStub.new(grouped_counts: { group_g => { '415' => 3, '416' => 9, '417' => 5, '999' => 9 } })
      end

      it 'sorts by count descending by default' do
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92')
        expect(r['buckets'].map { |b| b['count'] }).to eq([9, 9, 5, 3])
      end

      it 'breaks count ties by label so the order is deterministic' do
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92')
        expect(r['buckets'].first(2).map { |b| b['label'] }).to eq(['999', 'Geotech'])
      end

      it 'sorts by label ascending with sort: label' do
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92', sort: 'label')
        expect(r['buckets'].map { |b| b['label'] }).to eq(['999', 'Geotech', 'Positioning', 'Survey'])
      end

      it 'sorts numbers naturally, not lexicographically' do
        natural = ScopeStub.new(grouped_counts: { group_g => { 'Phase 10' => 1, 'Phase 2' => 1 } })
        custom_fields[92] = CustomFieldStub.new(id: 92, name: 'Phase',
                                                format: FormatStub.new { |_cf, raw| raw })
        r = described_class.dimension_breakdown(natural, group_by: 'cf_92', sort: 'label')
        expect(r['buckets'].map { |b| b['label'] }).to eq(['Phase 2', 'Phase 10'])
      end

      it 'sorts by the field-defined order with sort: position' do
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92', sort: 'position')
        expect(r['buckets'].first(3).map { |b| b['label'] }).to eq(['Geotech', 'Survey', 'Positioning'])
      end

      it 'puts values with no known position last' do
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92', sort: 'position')
        expect(r['buckets'].last['label']).to eq('999')
      end

      it 'uses possible_values order when the field is not an enumeration' do
        custom_fields[92] = CustomFieldStub.new(
          id: 92, name: 'Size', possible_values: %w[Large Medium Small],
          format: FormatStub.new { |_cf, raw| raw }
        )
        list = ScopeStub.new(grouped_counts: { group_g => { 'Small' => 9, 'Large' => 1, 'Medium' => 5 } })
        r = described_class.dimension_breakdown(list, group_by: 'cf_92', sort: 'position')
        expect(r['buckets'].map { |b| b['label'] }).to eq(%w[Large Medium Small])
      end

      it 'falls back to count for an unknown sort mode' do
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92', sort: 'banana')
        expect(r['buckets'].map { |b| b['count'] }).to eq([9, 9, 5, 3])
      end

      it 'logs a warning for an unknown sort mode' do
        expect(Rails.logger).to receive(:warn).with(/unknown sort "banana"/)
        described_class.dimension_breakdown(scope, group_by: 'cf_92', sort: 'banana')
      end
    end

    context 'limit' do
      let(:scope) do
        ScopeStub.new(grouped_counts: {
                        group_g => { '415' => 18, '416' => 9, '417' => 5, '999' => 2, nil => 4 }
                      })
      end

      subject(:result) { described_class.dimension_breakdown(scope, group_by: 'cf_92', limit: 3) }

      it 'keeps the top N rows and collapses the rest' do
        expect(result['buckets'].map { |b| b['label'] }).to eq(['Survey', 'Geotech', 'Positioning', 'Other', '(none)'])
      end

      it 'sums the collapsed rows into Other' do
        expect(result['buckets'][3]).to eq('label' => 'Other', 'count' => 2)
      end

      it 'keeps the empty bucket out of the collapse' do
        expect(result['buckets'].last).to eq('label' => '(none)', 'count' => 4)
      end

      it 'flags the result as truncated' do
        expect(result['truncated']).to be(true)
      end

      it 'keeps the grand total intact' do
        expect(result['total']).to eq(38)
      end

      it 'honours a custom other_label' do
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92', limit: 3, other_label: 'Rest')
        expect(r['buckets'][3]['label']).to eq('Rest')
      end

      it 'does not add an Other row when the limit is not reached' do
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92', limit: 10)
        expect(r['buckets'].map { |b| b['label'] }).not_to include('Other')
      end

      it 'caps the number of rows at 200 even without a limit' do
        wide = ScopeStub.new(grouped_counts: {
                               group_g => (1..250).each_with_object({}) { |i, h| h["v#{i}"] = i }
                             })
        custom_fields[92] = CustomFieldStub.new(id: 92, name: 'Free text',
                                                format: FormatStub.new { |_cf, raw| raw })
        r = described_class.dimension_breakdown(wide, group_by: 'cf_92')
        expect(r['buckets'].length).to eq(201)
        expect(r['buckets'].last['label']).to eq('Other')
        expect(r['truncated']).to be(true)
      end
    end

    # ----------------------------------------------------------------
    # Core dimensions through the new path
    # ----------------------------------------------------------------

    context 'core dimension through the dimension path' do
      let(:scope) { ScopeStub.new(grouped_counts: { assigned_to_id: { 10 => 3, 11 => 2, nil => 1 } }) }

      before do
        stub_const('User', UserRegistryStub.build([UserRecordStub.new(10, 'alice', 'Alice Adams'),
                                                   UserRecordStub.new(11, 'bob',   'Bob Brown')]))
      end

      it 'labels users with their display name' do
        r = described_class.dimension_breakdown(scope, group_by: 'assignee')
        expect(r['buckets'].map { |b| b['label'] }).to eq(['Alice Adams', 'Bob Brown', 'Unassigned'])
      end

      it 'can still ask for the login' do
        r = described_class.dimension_breakdown(scope, group_by: 'assignee', user_label: 'login')
        expect(r['buckets'].map { |b| b['label'] }).to eq(['alice', 'bob', 'Unassigned'])
      end

      it 'keeps the historical fallback label for a missing user' do
        gone = ScopeStub.new(grouped_counts: { assigned_to_id: { 99 => 1 } })
        r = described_class.dimension_breakdown(gone, group_by: 'assignee')
        expect(r['buckets'].first['label']).to eq('Assignee #99')
      end

      it 'reports no field_name for a core dimension' do
        expect(described_class.dimension_breakdown(scope, group_by: 'assignee')['field_name']).to be_nil
      end

      it 'counts DISTINCT issues.id' do
        described_class.dimension_breakdown(scope, group_by: 'assignee')
        expect(scope.count_columns).to eq(['DISTINCT issues.id'])
      end

      it 'adds no join at all — a core column needs neither custom_values nor projects' do
        described_class.dimension_breakdown(scope, group_by: 'assignee')
        expect(scope.joins_sql).to be_empty
      end
    end

    # ----------------------------------------------------------------
    # Crosstab
    # ----------------------------------------------------------------

    context 'crosstab (split_by)' do
      let(:pairs) do
        {
          ['415', '346'] => 8, ['415', '347'] => 10,
          ['416', '345'] => 1, ['416', '346'] => 4, ['416', '347'] => 4,
          [nil,   '345'] => 2
        }
      end
      let(:scope) { ScopeStub.new(grouped_counts: { [group_g, group_s] => pairs }) }

      subject(:result) { described_class.dimension_breakdown(scope, group_by: 'cf_92', split_by: 'cf_86') }

      it 'issues a single grouped query over both dimensions' do
        result
        expect(scope.group_expressions).to eq([group_g, group_s])
      end

      it 'joins both custom_values aliases without colliding' do
        result
        expect(scope.joins_sql.grep(String).length).to eq(2)
        expect(scope.joins_sql.grep(String).join).to include('rrd_cv_g').and include('rrd_cv_s')
      end

      it 'orders series by their own totals' do
        expect(result['series']).to eq(['Recommendation', 'Negative', 'Positive'])
      end

      it 'orders rows by their totals, empty bucket last' do
        expect(result['rows'].map { |r| r['label'] }).to eq(['Survey', 'Geotech', '(none)'])
      end

      it 'returns a dense matrix with explicit zeros' do
        expect(result['matrix']).to eq([[10, 8, 0], [4, 4, 1], [0, 0, 2]])
      end

      it 'gives every row exactly series.length counts' do
        expect(result['rows'].map { |r| r['counts'].length }.uniq).to eq([result['series'].length])
      end

      it 'never leaves a nil in the matrix' do
        expect(result['matrix'].flatten).to all(be_a(Integer))
      end

      it 'exposes cells keyed by series label' do
        expect(result['rows'].first['cells']).to eq('Recommendation' => 10, 'Negative' => 8, 'Positive' => 0)
      end

      it 'reports per-row totals' do
        expect(result['rows'].map { |r| r['total'] }).to eq([18, 9, 2])
      end

      it 'reports per-series totals aligned with series' do
        expect(result['columns']).to eq([14, 12, 3])
      end

      it 'mirrors the row totals in buckets' do
        expect(result['buckets']).to eq(result['rows'].map { |r| { 'label' => r['label'], 'count' => r['total'] } })
      end

      it 'totals the whole matrix' do
        expect(result['total']).to eq(29)
        expect(result['total']).to eq(result['matrix'].flatten.sum)
      end

      it 'echoes both dimensions' do
        expect(result['group_by']).to eq('cf_92')
        expect(result['split_by']).to eq('cf_86')
      end

      it 'names both fields' do
        expect(result['field_name']).to eq('Department')
        expect(result['series_field_name']).to eq('Lesson Type')
      end

      it 'orders series by position when asked' do
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92', split_by: 'cf_86', sort: 'position')
        expect(r['series']).to eq(['Positive', 'Negative', 'Recommendation'])
      end

      it 'keeps rows and matrix aligned when the row limit collapses rows' do
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92', split_by: 'cf_86', limit: 1)
        expect(r['rows'].map { |row| row['label'] }).to eq(['Survey', 'Other', '(none)'])
        expect(r['matrix']).to eq([[10, 8, 0], [4, 4, 1], [0, 0, 2]])
        expect(r['total']).to eq(29)
      end

      it 'rejects flags as a second dimension' do
        expect(described_class.dimension_breakdown(scope, group_by: 'cf_92', split_by: 'flags')).to be_nil
      end

      it 'logs a warning for split_by: flags' do
        expect(Rails.logger).to receive(:warn).with(/flags is only valid as group_by/)
        described_class.dimension_breakdown(scope, group_by: 'cf_92', split_by: 'flags')
      end

      it 'rejects an unknown second dimension' do
        expect(described_class.dimension_breakdown(scope, group_by: 'cf_92', split_by: 'nope')).to be_nil
      end
    end

    # ----------------------------------------------------------------
    # period dimension
    # ----------------------------------------------------------------

    context 'group_by: period' do
      let(:labels) { described_class.build_labels(6, 'month') }
      let(:scope) do
        ScopeStub.new(grouped_counts: { any: { labels[5] => 7, labels[3] => 2 } })
      end

      subject(:result) { described_class.dimension_breakdown(scope, group_by: 'period', periods: 6) }

      it 'returns one row per period in the window' do
        expect(result['buckets'].map { |b| b['label'] }).to eq(labels)
      end

      it 'fills gaps with zeros' do
        expect(result['buckets'].map { |b| b['count'] }).to eq([0, 0, 0, 2, 0, 7])
      end

      it 'ignores sort and limit' do
        r = described_class.dimension_breakdown(scope, group_by: 'period', periods: 6,
                                                       sort: 'count', limit: 2)
        expect(r['buckets'].map { |b| b['label'] }).to eq(labels)
        expect(r['truncated']).to be(false)
      end

      it 'buckets on created_on by default' do
        result
        expect(scope.group_expressions.first).to include('issues.created_on')
      end

      it 'adds no join — a date bucket reads issues alone' do
        result
        expect(scope.joins_sql).to be_empty
      end

      it 'buckets on closed_on with date_field: closed' do
        described_class.dimension_breakdown(scope, group_by: 'period', periods: 6, date_field: 'closed')
        expect(scope.group_expressions.first).to include('issues.closed_on')
      end

      it 'respects the period cap' do
        r = described_class.dimension_breakdown(scope, group_by: 'period', period: 'month', periods: 99)
        expect(r['buckets'].length).to eq(24)
      end

      it 'uses DATE_FORMAT on MySQL' do
        described_class.instance_variable_set(:@adapter_family, :mysql)
        described_class.dimension_breakdown(scope, group_by: 'period', periods: 6)
        expect(scope.group_expressions.first).to eq("DATE_FORMAT(issues.created_on, '%Y-%m')")
      end

      it 'uses TO_CHAR on PostgreSQL' do
        described_class.instance_variable_set(:@adapter_family, :postgresql)
        described_class.dimension_breakdown(scope, group_by: 'period', periods: 6)
        expect(scope.group_expressions.first).to eq("TO_CHAR(issues.created_on, 'YYYY-MM')")
      end

      it 'warns and falls back for an unknown date_field' do
        expect(Rails.logger).to receive(:warn).with(/unknown date_field/)
        described_class.dimension_breakdown(scope, group_by: 'period', date_field: 'banana')
      end
    end

    context 'group_by: period, split_by: cf_86' do
      let(:labels) { described_class.build_labels(3, 'month') }
      let(:scope) do
        ScopeStub.new(grouped_counts: {
                        any: { [labels[2], '345'] => 4, [labels[0], '346'] => 1 }
                      })
      end

      subject(:result) do
        described_class.dimension_breakdown(scope, group_by: 'period', split_by: 'cf_86', periods: 3)
      end

      it 'keeps the rows chronological, including empty periods' do
        expect(result['rows'].map { |r| r['label'] }).to eq(labels)
      end

      it 'returns a dense matrix' do
        expect(result['matrix']).to eq([[0, 1], [0, 0], [4, 0]])
      end

      it 'orders series by their totals' do
        expect(result['series']).to eq(['Positive', 'Negative'])
      end
    end

    # ----------------------------------------------------------------
    # age dimension
    # ----------------------------------------------------------------

    context 'group_by: age' do
      let(:scope) do
        ScopeStub.new(grouped_counts: { any: { '0-30' => 4, '91-180' => 2, nil => 1 } })
      end

      subject(:result) { described_class.dimension_breakdown(scope, group_by: 'age') }

      it 'returns the default buckets in ascending age order' do
        expect(result['buckets'].map { |b| b['label'] }).to eq(
          ['0-30', '31-60', '61-90', '91-180', '>180', '(none)']
        )
      end

      it 'fills empty buckets with zero' do
        expect(result['buckets'].map { |b| b['count'] }).to eq([4, 0, 0, 2, 0, 1])
      end

      it 'puts issues with no date in the empty bucket, not the oldest one' do
        expect(result['buckets'].last).to eq('label' => '(none)', 'count' => 1)
      end

      it 'ignores sort and limit' do
        r = described_class.dimension_breakdown(scope, group_by: 'age', sort: 'count', limit: 1)
        expect(r['buckets'].length).to eq(6)
        expect(r['truncated']).to be(false)
      end

      it 'accepts custom boundaries' do
        short = ScopeStub.new(grouped_counts: { any: { '0-7' => 3, nil => 1 } })
        r = described_class.dimension_breakdown(short, group_by: 'age', age_buckets: [7, 14])
        expect(r['buckets'].map { |b| b['label'] }).to eq(['0-7', '8-14', '>14', '(none)'])
      end

      it 'sorts and de-duplicates the boundaries it is given' do
        short = ScopeStub.new(grouped_counts: { any: { '0-7' => 3 } })
        r = described_class.dimension_breakdown(short, group_by: 'age', age_buckets: ['14', '7', '7'])
        expect(r['buckets'].map { |b| b['label'] }).to eq(['0-7', '8-14', '>14'])
      end

      it 'keeps counts for a value outside the expected bucket list rather than dropping them' do
        odd = ScopeStub.new(grouped_counts: { any: { '0-30' => 2, 'unexpected' => 5 } })
        r = described_class.dimension_breakdown(odd, group_by: 'age')
        expect(r['buckets'].last).to eq('label' => 'unexpected', 'count' => 5)
        expect(r['total']).to eq(7)
      end

      it 'falls back to the defaults for a garbage boundary list' do
        expect(Rails.logger).to receive(:warn).with(/age_buckets/)
        described_class.dimension_breakdown(scope, group_by: 'age', age_buckets: ['x'])
      end

      it 'caps a runaway boundary list instead of generating a huge CASE' do
        wide = ScopeStub.new(grouped_counts: { any: {} })
        r = described_class.dimension_breakdown(wide, group_by: 'age', age_buckets: (1..500).to_a)
        expect(r['buckets'].length).to eq(described_class::MAX_AGE_BUCKETS + 1)
      end

      it 'warns when it caps the boundary list' do
        wide = ScopeStub.new(grouped_counts: { any: {} })
        expect(Rails.logger).to receive(:warn).with(/keeping the first/)
        described_class.dimension_breakdown(wide, group_by: 'age', age_buckets: (1..500).to_a)
      end

      it 'generates portable SQL — no DATEDIFF' do
        result
        expect(scope.group_expressions.first).not_to match(/DATEDIFF/i)
      end

      it 'generates portable SQL — no CURRENT_DATE arithmetic' do
        result
        expect(scope.group_expressions.first).not_to match(/CURRENT_DATE|NOW\(\)|GETDATE/i)
      end

      it 'compares the date column against bound boundaries' do
        result
        expect(scope.group_expressions.first).to start_with('CASE WHEN issues.created_on IS NULL THEN NULL')
      end

      it 'buckets on due_date with age_field: due' do
        described_class.dimension_breakdown(scope, group_by: 'age', age_field: 'due')
        expect(scope.group_expressions.first).to include('issues.due_date')
      end

      it 'buckets on updated_on with age_field: updated' do
        described_class.dimension_breakdown(scope, group_by: 'age', age_field: 'updated')
        expect(scope.group_expressions.first).to include('issues.updated_on')
      end

      it 'warns and falls back for an unknown age_field' do
        expect(Rails.logger).to receive(:warn).with(/unknown age_field/)
        described_class.dimension_breakdown(scope, group_by: 'age', age_field: 'banana')
      end
    end

    context 'with an unknown dimension' do
      let(:scope) { ScopeStub.new }

      it 'returns nil' do
        expect(described_class.dimension_breakdown(scope, group_by: 'banana')).to be_nil
      end

      it 'returns nil for flags used as group_by here (the tag has its own path)' do
        expect(described_class.dimension_breakdown(scope, group_by: 'flags')).to be_nil
      end
    end

    # ----------------------------------------------------------------
    # Edge cases
    # ----------------------------------------------------------------

    context 'edge cases' do
      it 'accepts a dimension name in any case' do
        scope = ScopeStub.new(grouped_counts: { group_g => { '415' => 1 } })
        expect(described_class.dimension_breakdown(scope, group_by: 'CF_92')['buckets'].first['label'])
          .to eq('Survey')
      end

      it 'accepts PERIOD as well as period' do
        scope = ScopeStub.new(grouped_counts: { any: {} })
        expect(described_class.dimension_breakdown(scope, group_by: 'Period', periods: 2)['buckets'].length)
          .to eq(2)
      end

      it 'returns empty buckets for an empty scope' do
        scope = ScopeStub.new(grouped_counts: { group_g => {} })
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92')
        expect(r['buckets']).to eq([])
        expect(r['total']).to eq(0)
      end

      it 'returns an empty crosstab for an empty scope' do
        scope = ScopeStub.new(grouped_counts: { [group_g, group_s] => {} })
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92', split_by: 'cf_86')
        expect(r['series']).to eq([])
        expect(r['rows']).to eq([])
        expect(r['matrix']).to eq([])
        expect(r['columns']).to eq([])
        expect(r['total']).to eq(0)
      end

      it 'still returns every period row when a period crosstab has no data at all' do
        scope = ScopeStub.new(grouped_counts: { any: {} })
        r = described_class.dimension_breakdown(scope, group_by: 'period', split_by: 'cf_86', periods: 3)
        expect(r['rows'].length).to eq(3)
        expect(r['matrix']).to eq([[], [], []])
      end

      it 'does not treat the string "0" as an empty value' do
        scope = ScopeStub.new(grouped_counts: { group_g => { '0' => 3 } })
        custom_fields[92] = CustomFieldStub.new(id: 92, name: 'Count',
                                                format: FormatStub.new { |_cf, raw| raw })
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92')
        expect(r['buckets']).to eq([{ 'label' => '0', 'count' => 3 }])
      end

      it 'collapses whitespace-only values into the empty bucket' do
        scope = ScopeStub.new(grouped_counts: { group_g => { '  ' => 2, '415' => 1 } })
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92')
        expect(r['buckets'].last).to eq('label' => '(none)', 'count' => 2)
      end

      it 'produces the same order however the database returns the rows' do
        counts   = { '415' => 9, '416' => 9, '417' => 5, '999' => 5 }
        forward  = ScopeStub.new(grouped_counts: { group_g => counts })
        backward = ScopeStub.new(grouped_counts: { group_g => counts.to_a.reverse.to_h })

        expect(described_class.dimension_breakdown(forward, group_by: 'cf_92')['buckets'])
          .to eq(described_class.dimension_breakdown(backward, group_by: 'cf_92')['buckets'])
      end

      it 'caps a limit above the hard cap at the hard cap' do
        wide = ScopeStub.new(grouped_counts: {
                               group_g => (1..250).each_with_object({}) { |i, h| h["v#{i}"] = i }
                             })
        custom_fields[92] = CustomFieldStub.new(id: 92, name: 'Free text',
                                                format: FormatStub.new { |_cf, raw| raw })
        r = described_class.dimension_breakdown(wide, group_by: 'cf_92', limit: 5000)
        expect(r['buckets'].length).to eq(201)
      end

      it 'ignores a negative limit' do
        scope = ScopeStub.new(grouped_counts: { group_g => { '415' => 3, '416' => 1 } })
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92', limit: -5)
        expect(r['buckets'].length).to eq(2)
      end

      it 'allows the same custom field on both axes without an alias collision' do
        scope = ScopeStub.new(grouped_counts: { [group_g, group_s] => { ['415', '415'] => 3 } })
        r = described_class.dimension_breakdown(scope, group_by: 'cf_92', split_by: 'cf_92')
        expect(r['matrix']).to eq([[3]])
        expect(scope.joins_sql.grep(String).map { |j| j[/rrd_cv_\w/] }).to eq(['rrd_cv_g', 'rrd_cv_s'])
      end

      it 'never raises when the user lookup fails' do
        scope = ScopeStub.new(grouped_counts: { assigned_to_id: { 10 => 3 } })
        stub_const('User', Class.new { def self.where(*); raise StandardError, 'no db'; end })
        r = described_class.dimension_breakdown(scope, group_by: 'assignee')
        expect(r['buckets']).to eq([{ 'label' => 'Assignee #10', 'count' => 3 }])
      end
    end
  end

  # ==================================================================
  # .flags
  # ==================================================================

  describe '.flags' do
    let(:scope) do
      ScopeStub.new(
        flag_counts: { [] => 49, [:closed] => 4, [:assigned] => 24, [:with_due] => 7,
                       [:no_estimate] => 49, [:open, :overdue] => 3 },
        minimums: { created_on: (Date.today - 146).to_time },
        maximums: { created_on: (Date.today - 23).to_time }
      )
    end

    subject(:result) { described_class.flags(scope, closed_statuses: ['Closed', 'Rejected']) }

    before do
      allow(IssueStatus).to receive(:where).with(name: ['Closed', 'Rejected']).and_return(IssueStatus)
      allow(IssueStatus).to receive(:pluck).and_return([3, 4])
    end

    it 'exposes the counters under flags' do
      expect(result['flags']['total']).to eq(49)
    end

    it 'exposes the same counters at the top level' do
      expect(result['total']).to eq(49)
    end

    it 'derives open from total minus closed' do
      expect(result['open']).to eq(45)
      expect(result['closed']).to eq(4)
    end

    it 'splits assigned and unassigned into total' do
      expect(result['assigned'] + result['unassigned']).to eq(result['total'])
    end

    it 'splits due dates into total' do
      expect(result['with_due_date']).to eq(7)
      expect(result['without_due_date']).to eq(42)
    end

    it 'counts overdue over open issues only' do
      expect(result['overdue']).to eq(3)
    end

    it 'counts issues without an estimate' do
      expect(result['no_estimate']).to eq(49)
    end

    it 'derives oldest_open_days from MIN(created_on)' do
      expect(result['oldest_open_days']).to eq(146)
    end

    it 'derives newest_open_days from MAX(created_on)' do
      expect(result['newest_open_days']).to eq(23)
    end

    it 'echoes the dimension' do
      expect(result['group_by']).to eq('flags')
      expect(result['dimension']).to eq('flags')
    end

    it 'exposes an empty buckets array so breakdown templates still render' do
      expect(result['buckets']).to eq([])
    end

    it 'counts DISTINCT issues.id everywhere' do
      result
      expect(scope.count_columns.uniq).to eq(['DISTINCT issues.id'])
    end

    context 'when nothing is open' do
      let(:scope) do
        ScopeStub.new(flag_counts: { [] => 4, [:closed] => 4 }, minimums: {}, maximums: {})
      end

      it 'returns nil for oldest_open_days' do
        expect(result['oldest_open_days']).to be_nil
      end

      it 'returns nil for newest_open_days' do
        expect(result['newest_open_days']).to be_nil
      end

      it 'reports zero open' do
        expect(result['open']).to eq(0)
      end
    end

    context 'when no status is closed' do
      let(:scope) { ScopeStub.new(flag_counts: { [] => 6 }, minimums: {}, maximums: {}) }

      before do
        allow(IssueStatus).to receive(:where).with(is_closed: true).and_return(IssueStatus)
        allow(IssueStatus).to receive(:pluck).and_return([])
      end

      it 'treats every issue as open' do
        r = described_class.flags(scope)
        expect(r['open']).to eq(6)
        expect(r['closed']).to eq(0)
      end
    end
  end
end
