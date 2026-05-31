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

# Liquid must be available for this spec; stub it if not loaded
unless defined?(Liquid)
  module Liquid
    class Tag
      def initialize(tag_name, markup, tokens)
        @tag_name = tag_name
        @markup   = markup
      end
    end

    class Template
      def self.register_tag(*)
      end
    end

    class Context
      def initialize(env = {}, assigns = {}, registers = {})
        @scopes    = [assigns.dup]
        @env       = env
        @registers = registers
      end

      attr_reader :scopes, :registers

      def [](key)
        @scopes.reverse_each { |s| return s[key] if s.key?(key) }
        nil
      end
    end
  end
end

unless defined?(Rails)
  module Rails
    class << self
      attr_accessor :application

      def logger
        @logger ||= Logger.new(File::NULL)
      end

      def root
        @root ||= Pathname.new(Dir.tmpdir)
      end
    end
  end
end

require_relative '../../lib/sql_aggregation/query_aggregator'
require_relative '../../lib/sql_aggregation/liquid_aggregate_tag'

# AR-scope stub
class LiquidTagScopeStub
  def where(*); self; end
  def not(*);   self; end
  def group(*); self; end
  def unscope(*); self; end
  def count;    0;    end
  def base_scope; self; end
end

# Minimal IssueStatus stub
class LiquidTagIssueStatusStub
  def self.where(*); self; end
  def self.pluck(*); [3, 4]; end
end

# Minimal IssueQuery stub
class LiquidTagIssueQueryStub
  attr_reader :base_scope

  def initialize(scope)
    @base_scope = scope
  end

  def self.find_by(id:)
    @registry ||= {}
    @registry[id]
  end

  def self.register(id, scope)
    @registry ||= {}
    @registry[id] = new(scope)
  end
end

RSpec.describe SqlAggregation::LiquidAggregateTag do
  let(:scope)           { LiquidTagScopeStub.new }
  let(:agg_result)      { { 'labels' => ['2026-05'], 'created' => [3], 'closed' => [2], 'open_now' => 5, 'total' => 10, 'period' => 'month', 'periods' => 6 } }
  let(:breakdown_result){ { 'buckets' => [{ 'label' => 'Bug', 'count' => 42 }], 'total' => 42, 'group_by' => 'tracker' } }

  before do
    stub_const('IssueStatus', LiquidTagIssueStatusStub)
    stub_const('IssueQuery',  LiquidTagIssueQueryStub)
    allow(SqlAggregation::QueryAggregator).to receive(:aggregate).and_return(agg_result)
    allow(SqlAggregation::QueryAggregator).to receive(:breakdown).and_return(breakdown_result)
  end

  def build_tag(markup)
    described_class.new('sql_aggregate', markup, [])
  end

  def build_context(assigns = {}, registers = {})
    Liquid::Context.new({}, assigns, registers)
  end

  # ------------------------------------------------------------------
  # Scope resolution via `from: issues` (IssuesDrop path)
  # ------------------------------------------------------------------

  describe 'scope resolution from issues drop' do
    let(:drop_with_ivar) do
      obj = Object.new
      obj.instance_variable_set(:@issues, scope)
      obj
    end

    it 'extracts @issues ivar from the drop and runs aggregation' do
      ctx = build_context('issues' => drop_with_ivar)
      tag = build_tag('from: issues, periods: 6, closed_statuses: "Closed;Rejected", assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate).with(scope, anything).and_return(agg_result)

      tag.render(ctx)
    end

    it 'assigns result to the named variable in context' do
      ctx = build_context('issues' => drop_with_ivar)
      tag = build_tag('from: issues, assign_to: stats')

      tag.render(ctx)

      expect(ctx.scopes.last['stats']).to eq(agg_result)
    end

    it 'defaults assign_to to "stats" when omitted' do
      ctx = build_context('issues' => drop_with_ivar)
      tag = build_tag('from: issues')

      tag.render(ctx)

      expect(ctx.scopes.last['stats']).to eq(agg_result)
    end

    it 'returns empty string so no output appears in template' do
      ctx = build_context('issues' => drop_with_ivar)
      tag = build_tag('from: issues, assign_to: stats')

      expect(tag.render(ctx)).to eq('')
    end
  end

  # ------------------------------------------------------------------
  # Scope resolution via query_id
  # ------------------------------------------------------------------

  describe 'scope resolution from query_id' do
    before do
      LiquidTagIssueQueryStub.register(42, scope)
    end

    it 'finds the IssueQuery by id and uses base_scope' do
      ctx = build_context
      tag = build_tag('query_id: 42, periods: 6, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate).with(scope, anything).and_return(agg_result)

      tag.render(ctx)
    end

    it 'resolves query_id from Liquid context when it is a variable' do
      ctx = build_context('my_qid' => 42)
      tag = build_tag('query_id: my_qid, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate).with(scope, anything).and_return(agg_result)

      tag.render(ctx)
    end

    it 'assigns empty result when query_id is not found' do
      ctx = build_context
      tag = build_tag('query_id: 999, assign_to: stats')

      tag.render(ctx)

      expect(ctx.scopes.last['stats']['total']).to eq(0)
    end
  end

  # ------------------------------------------------------------------
  # Scope resolution via context.registers (fast path in production)
  # ------------------------------------------------------------------

  describe 'scope resolution from context registers' do
    it 'uses :sql_issue_query register when present (Reporter patch path)' do
      query = LiquidTagIssueQueryStub.new(scope)
      ctx = build_context({}, { sql_issue_query: query })
      tag = build_tag('from: issues, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate).with(scope, anything).and_return(agg_result)

      tag.render(ctx)
    end

    it 'uses :container register when it IS an IssueQuery (Reporter zero-patch path)' do
      query = LiquidTagIssueQueryStub.new(scope)
      ctx = build_context({}, { container: query })
      tag = build_tag('from: issues, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate).with(scope, anything).and_return(agg_result)

      tag.render(ctx)
    end

    it 'uses :container @query ivar when container wraps an IssueQuery' do
      query     = LiquidTagIssueQueryStub.new(scope)
      container = Object.new
      container.instance_variable_set(:@query, query)
      ctx = build_context({}, { container: container })
      tag = build_tag('from: issues, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate).with(scope, anything).and_return(agg_result)

      tag.render(ctx)
    end

    it 'uses :controller register @query when :sql_issue_query and :container absent' do
      query      = LiquidTagIssueQueryStub.new(scope)
      controller = double('controller')
      allow(controller).to receive(:instance_variable_get).with(:@query).and_return(query)
      ctx = build_context({}, { controller: controller })
      tag = build_tag('from: issues, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate).with(scope, anything).and_return(agg_result)

      tag.render(ctx)
    end

    it 'falls back to drop resolution when registers are empty' do
      drop = Object.new
      drop.instance_variable_set(:@issues, scope)
      ctx = build_context({ 'issues' => drop }, {})
      tag = build_tag('from: issues, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate).with(scope, anything).and_return(agg_result)

      tag.render(ctx)
    end

    it 'falls back to drop when :controller has no @query' do
      controller = double('controller')
      allow(controller).to receive(:instance_variable_get).with(:@query).and_return(nil)
      drop = Object.new
      drop.instance_variable_set(:@issues, scope)
      ctx = build_context({ 'issues' => drop }, { controller: controller })
      tag = build_tag('from: issues, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate).with(scope, anything).and_return(agg_result)

      tag.render(ctx)
    end

    it 'prefers :sql_issue_query over :container and :controller' do
      query1 = LiquidTagIssueQueryStub.new(scope)
      other_scope = LiquidTagScopeStub.new
      query2 = LiquidTagIssueQueryStub.new(other_scope)
      controller = double('controller')
      allow(controller).to receive(:instance_variable_get).with(:@query).and_return(query2)
      ctx = build_context({}, { sql_issue_query: query1, container: query2, controller: controller })
      tag = build_tag('from: issues, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate).with(scope, anything).and_return(agg_result)

      tag.render(ctx)
    end
  end

  # ------------------------------------------------------------------
  # Scope resolution via drop ivar inspection (@sql_base_scope patch path)
  # ------------------------------------------------------------------

  describe 'scope resolution from drop @sql_base_scope ivar' do
    it 'uses @sql_base_scope ivar when present on the drop (Strategy A patch)' do
      drop = Object.new
      drop.instance_variable_set(:@issues, [double('issue', id: 1)])
      drop.instance_variable_set(:@sql_base_scope, scope)
      ctx = build_context('issues' => drop)
      tag = build_tag('from: issues, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate).with(scope, anything).and_return(agg_result)

      tag.render(ctx)
    end
  end

  # ------------------------------------------------------------------
  # Parameter parsing
  # ------------------------------------------------------------------

  describe 'parameter parsing' do
    let(:drop) do
      obj = Object.new
      obj.instance_variable_set(:@issues, scope)
      obj
    end

    it 'parses period as a string' do
      ctx = build_context('issues' => drop)
      tag = build_tag('from: issues, period: week, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(scope, hash_including(period: 'week'))
        .and_return(agg_result)

      tag.render(ctx)
    end

    it 'defaults period to month when omitted' do
      ctx = build_context('issues' => drop)
      tag = build_tag('from: issues, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(scope, hash_including(period: 'month'))
        .and_return(agg_result)

      tag.render(ctx)
    end

    it 'passes period: day correctly' do
      ctx = build_context('issues' => drop)
      tag = build_tag('from: issues, period: day, periods: 30, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(scope, hash_including(period: 'day', periods: 30))
        .and_return(agg_result)

      tag.render(ctx)
    end

    it 'passes period: year correctly' do
      ctx = build_context('issues' => drop)
      tag = build_tag('from: issues, period: year, periods: 3, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(scope, hash_including(period: 'year', periods: 3))
        .and_return(agg_result)

      tag.render(ctx)
    end

    it 'parses periods as an integer' do
      ctx = build_context('issues' => drop)
      tag = build_tag('from: issues, period: month, periods: 12, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(scope, hash_including(periods: 12))
        .and_return(agg_result)

      tag.render(ctx)
    end

    it 'passes nil periods when omitted (letting aggregator use default)' do
      ctx = build_context('issues' => drop)
      tag = build_tag('from: issues, period: month, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(scope, hash_including(periods: nil))
        .and_return(agg_result)

      tag.render(ctx)
    end

    it 'accepts legacy months param as alias for periods when period is month' do
      ctx = build_context('issues' => drop)
      tag = build_tag('from: issues, months: 12, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(scope, hash_including(periods: 12, period: 'month'))
        .and_return(agg_result)

      tag.render(ctx)
    end

    it 'parses closed_statuses from double-quoted string' do
      ctx = build_context('issues' => drop)
      tag = build_tag('from: issues, closed_statuses: "Closed;Rejected", assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(scope, hash_including(closed_statuses: ['Closed', 'Rejected']))
        .and_return(agg_result)

      tag.render(ctx)
    end

    it 'parses closed_statuses from single-quoted string' do
      ctx = build_context('issues' => drop)
      tag = build_tag("from: issues, closed_statuses: 'Closed,Done', assign_to: stats")

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(scope, hash_including(closed_statuses: ['Closed', 'Done']))
        .and_return(agg_result)

      tag.render(ctx)
    end

    it 'passes empty closed_statuses when omitted' do
      ctx = build_context('issues' => drop)
      tag = build_tag('from: issues, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(scope, hash_including(closed_statuses: []))
        .and_return(agg_result)

      tag.render(ctx)
    end
  end

  # ------------------------------------------------------------------
  # Breakdown mode (group_by: param)
  # ------------------------------------------------------------------

  describe 'breakdown mode' do
    let(:drop) do
      obj = Object.new
      obj.instance_variable_set(:@issues, scope)
      obj
    end

    it 'calls QueryAggregator.breakdown when group_by is present' do
      ctx = build_context('issues' => drop)
      tag = build_tag('from: issues, group_by: tracker, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:breakdown)
        .with(scope, group_by: 'tracker')
        .and_return(breakdown_result)

      tag.render(ctx)
    end

    it 'does NOT call aggregate when group_by is present' do
      ctx = build_context('issues' => drop)
      tag = build_tag('from: issues, group_by: status, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).not_to receive(:aggregate)
      expect(SqlAggregation::QueryAggregator).to receive(:breakdown).and_return(breakdown_result)

      tag.render(ctx)
    end

    it 'assigns breakdown result to context variable' do
      ctx = build_context('issues' => drop)
      tag = build_tag('from: issues, group_by: tracker, assign_to: by_tracker')

      tag.render(ctx)

      expect(ctx.scopes.last['by_tracker']).to eq(breakdown_result)
    end

    it 'passes group_by: status correctly' do
      ctx = build_context('issues' => drop)
      tag = build_tag('from: issues, group_by: status, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:breakdown)
        .with(scope, group_by: 'status')
        .and_return(breakdown_result)

      tag.render(ctx)
    end

    it 'passes group_by: priority correctly' do
      ctx = build_context('issues' => drop)
      tag = build_tag('from: issues, group_by: priority, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:breakdown)
        .with(scope, group_by: 'priority')
        .and_return(breakdown_result)

      tag.render(ctx)
    end

    it 'passes group_by: assignee correctly' do
      ctx = build_context('issues' => drop)
      tag = build_tag('from: issues, group_by: assignee, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:breakdown)
        .with(scope, group_by: 'assignee')
        .and_return(breakdown_result)

      tag.render(ctx)
    end

    it 'uses aggregate (not breakdown) when group_by is absent' do
      ctx = build_context('issues' => drop)
      tag = build_tag('from: issues, period: month, periods: 6, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate).and_return(agg_result)
      expect(SqlAggregation::QueryAggregator).not_to receive(:breakdown)

      tag.render(ctx)
    end

    it 'assigns empty result and returns blank when breakdown raises' do
      allow(SqlAggregation::QueryAggregator).to receive(:breakdown).and_raise(StandardError, 'oops')

      ctx = build_context('issues' => drop)
      tag = build_tag('from: issues, group_by: tracker, assign_to: stats')

      expect { tag.render(ctx) }.not_to raise_error
      expect(ctx.scopes.last['stats']['total']).to eq(0)
    end

    it 'empty_result includes buckets key for safe template access' do
      ctx = build_context('issues' => nil)
      tag = build_tag('from: issues, group_by: status, assign_to: stats')

      tag.render(ctx)

      expect(ctx.scopes.last['stats']).to have_key('buckets')
    end
  end

  # ------------------------------------------------------------------
  # Error handling
  # ------------------------------------------------------------------

  describe 'error handling' do
    it 'assigns empty result and returns blank when no scope found' do
      ctx = build_context('issues' => nil)
      tag = build_tag('from: issues, assign_to: stats')

      expect { tag.render(ctx) }.not_to raise_error
      expect(ctx.scopes.last['stats']['total']).to eq(0)
    end

    it 'assigns empty result and returns blank when aggregator raises' do
      drop = Object.new
      drop.instance_variable_set(:@issues, scope)
      allow(SqlAggregation::QueryAggregator).to receive(:aggregate).and_raise(StandardError, 'db error')

      ctx = build_context('issues' => drop)
      tag = build_tag('from: issues, assign_to: stats')

      expect { tag.render(ctx) }.not_to raise_error
      expect(ctx.scopes.last['stats']['total']).to eq(0)
    end
  end
end
