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

unless defined?(Rails)
  module Rails
    def self.logger
      @logger ||= Logger.new(File::NULL)
    end
  end
end

require_relative '../../lib/sql_aggregation/query_aggregator'

# Chainable AR scope stub.
# breakdown_counts: hash keyed by field symbol, e.g. { status_id: {1=>42, nil=>5} }
class ScopeStub
  attr_reader :last_group_field, :conditions

  def initialize(created_counts: {}, closed_counts: {}, open_count: 5, total: 10,
                 breakdown_counts: {})
    @created_counts   = created_counts
    @closed_counts    = closed_counts
    @open_count       = open_count
    @total            = total
    @breakdown_counts = breakdown_counts
    @conditions       = {}
    @grouped          = false
    @excluded_ids     = false
  end

  def unscope(*)
    self
  end

  def where(cond = nil, *_args)
    copy = dup
    copy.instance_variable_set(:@conditions, @conditions.merge(cond.is_a?(Hash) ? cond : {}))
    copy
  end

  def not(*)
    copy = dup
    copy.instance_variable_set(:@excluded_ids, true)
    copy
  end

  def group(field)
    copy = dup
    copy.instance_variable_set(:@grouped, true)
    copy.instance_variable_set(:@last_group_field, field)
    copy
  end

  def count
    if @grouped
      if @excluded_ids
        {}
      elsif @breakdown_counts.key?(@last_group_field)
        @breakdown_counts[@last_group_field]
      elsif @conditions[:status_id]
        @closed_counts
      else
        @created_counts
      end
    elsif @excluded_ids
      @open_count
    else
      @total
    end
  end
end

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
end
