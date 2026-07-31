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
  def count(*);  0;   end
  def base_scope; self; end
end

# Minimal User stub — the query_id path is visibility-scoped, which needs User.current.
class LiquidTagUserStub
  def self.current
    @current ||= Object.new
  end
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

  # Redmine's Query.visible is a class method returning a relation.
  def self.visible(*args)
    @visible_args = args
    self
  end

  def self.visible_args
    @visible_args
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
  let(:dimension_result){ { 'buckets' => [{ 'label' => 'Survey', 'count' => 18 }], 'total' => 18, 'group_by' => 'cf_92', 'dimension' => 'cf_92', 'field_name' => 'Department', 'multi_value' => false, 'truncated' => false } }
  let(:flags_result)    { { 'total' => 49, 'open' => 45, 'flags' => { 'total' => 49 }, 'group_by' => 'flags' } }

  before do
    stub_const('IssueStatus', LiquidTagIssueStatusStub)
    stub_const('IssueQuery',  LiquidTagIssueQueryStub)
    stub_const('User',        LiquidTagUserStub)
    allow(SqlAggregation::QueryAggregator).to receive(:aggregate).and_return(agg_result)
    allow(SqlAggregation::QueryAggregator).to receive(:breakdown).and_return(breakdown_result)
    allow(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown).and_return(dimension_result)
    allow(SqlAggregation::QueryAggregator).to receive(:flags).and_return(flags_result)
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

    it 'looks the query up through the visibility scope' do
      build_tag('query_id: 42, assign_to: stats').render(build_context)

      expect(LiquidTagIssueQueryStub.visible_args).to eq([User.current])
    end

    it 'assigns the empty result for a query the user may not see' do
      # visible(...) returns a relation that simply does not contain the id.
      allow(LiquidTagIssueQueryStub).to receive(:visible).and_return(
        Class.new { def self.find_by(id:); nil; end }
      )
      expect(SqlAggregation::QueryAggregator).not_to receive(:aggregate)

      ctx = build_context
      build_tag('query_id: 42, assign_to: stats').render(ctx)

      expect(ctx.scopes.last['stats']['total']).to eq(0)
    end

    it 'logs why an invisible query was skipped' do
      allow(LiquidTagIssueQueryStub).to receive(:visible).and_return(
        Class.new { def self.find_by(id:); nil; end }
      )
      allow(Rails.logger).to receive(:warn) # the tag also logs "no scope resolved"
      expect(Rails.logger).to receive(:warn).with(/not visible to the current user/)

      build_tag('query_id: 42, assign_to: stats').render(build_context)
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
  # Dimension mode — cf_<id>, split_by, period, age, flags
  # ------------------------------------------------------------------

  describe 'dimension mode' do
    let(:drop) do
      obj = Object.new
      obj.instance_variable_set(:@issues, scope)
      obj
    end

    def render(markup, assigns = {})
      ctx = build_context(assigns.merge('issues' => drop))
      build_tag(markup).render(ctx)
      ctx
    end

    context 'dispatch' do
      it 'keeps the legacy breakdown path for a core field with no new parameters' do
        expect(SqlAggregation::QueryAggregator).to receive(:breakdown).with(scope, group_by: 'status')
        expect(SqlAggregation::QueryAggregator).not_to receive(:dimension_breakdown)

        render('from: issues, group_by: status, assign_to: stats')
      end

      it 'keeps the legacy path for an unknown core-style group_by with no new parameters' do
        expect(SqlAggregation::QueryAggregator).to receive(:breakdown).with(scope, group_by: 'nonexistent')

        render('from: issues, group_by: nonexistent, assign_to: stats')
      end

      it 'switches to the dimension path for cf_<id>' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(group_by: 'cf_92'))
        expect(SqlAggregation::QueryAggregator).not_to receive(:breakdown)

        render('from: issues, group_by: cf_92, assign_to: stats')
      end

      it 'switches to the dimension path when a core field is combined with a new parameter' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(group_by: 'status', sort: 'label'))

        render('from: issues, group_by: status, sort: label, assign_to: stats')
      end

      it 'switches to the dimension path for period' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(group_by: 'period'))

        render('from: issues, group_by: period, assign_to: stats')
      end

      it 'switches to the dimension path for age' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(group_by: 'age'))

        render('from: issues, group_by: age, assign_to: stats')
      end

      it 'calls flags for group_by: flags' do
        expect(SqlAggregation::QueryAggregator).to receive(:flags)
          .with(scope, closed_statuses: ['Closed', 'Rejected'])

        render('from: issues, group_by: flags, closed_statuses: "Closed;Rejected", assign_to: kpi')
      end

      it 'assigns the flags result' do
        ctx = render('from: issues, group_by: flags, assign_to: kpi')
        expect(ctx.scopes.last['kpi']).to eq(flags_result)
      end

      it 'still runs the time series when neither group_by nor split_by is given' do
        expect(SqlAggregation::QueryAggregator).to receive(:aggregate).and_return(agg_result)
        expect(SqlAggregation::QueryAggregator).not_to receive(:dimension_breakdown)

        render('from: issues, period: month, periods: 6, assign_to: stats')
      end

      it 'works under the legacy geo_aggregate tag name' do
        ctx = build_context('issues' => drop)
        tag = described_class.new('geo_aggregate', 'from: issues, group_by: cf_92, assign_to: stats', [])

        expect(tag.render(ctx)).to eq('')
        expect(ctx.scopes.last['stats']).to eq(dimension_result)
      end
    end

    context 'parameter parsing' do
      it 'passes split_by' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(group_by: 'cf_92', split_by: 'cf_86'))

        render('from: issues, group_by: cf_92, split_by: cf_86, assign_to: stats')
      end

      it 'passes nil split_by when it is absent' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(split_by: nil))

        render('from: issues, group_by: cf_92, sort: label, assign_to: stats')
      end

      it 'passes sort' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(sort: 'position'))

        render('from: issues, group_by: cf_87, sort: position, assign_to: stats')
      end

      it 'defaults sort to count' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(sort: 'count'))

        render('from: issues, group_by: cf_92, assign_to: stats')
      end

      it 'passes an invalid sort through so the aggregator can warn and fall back' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(sort: 'banana'))

        render('from: issues, group_by: cf_92, sort: banana, assign_to: stats')
      end

      it 'passes limit as an integer' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(limit: 10))

        render('from: issues, group_by: cf_99, limit: 10, assign_to: stats')
      end

      it 'defaults limit to 0' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(limit: 0))

        render('from: issues, group_by: cf_92, assign_to: stats')
      end

      it 'parses a double-quoted other_label' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(other_label: 'All the rest'))

        render('from: issues, group_by: cf_99, limit: 5, other_label: "All the rest", assign_to: stats')
      end

      it 'parses a single-quoted empty_label' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(empty_label: 'No department'))

        render("from: issues, group_by: cf_92, empty_label: 'No department', assign_to: stats")
      end

      it 'passes nil empty_label when it is absent so each dimension keeps its own default' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(empty_label: nil))

        render('from: issues, group_by: cf_92, assign_to: stats')
      end

      it 'splits age_buckets on semicolons' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(age_buckets: ['7', '30', '90']))

        render('from: issues, group_by: age, age_buckets: "7;30;90", assign_to: stats')
      end

      it 'splits age_buckets on commas' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(age_buckets: ['7', '30']))

        render('from: issues, group_by: age, age_buckets: "7,30", assign_to: stats')
      end

      it 'passes nil age_buckets when absent' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(age_buckets: nil))

        render('from: issues, group_by: age, assign_to: stats')
      end

      it 'passes age_field' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(age_field: 'due'))

        render('from: issues, group_by: age, age_field: due, assign_to: stats')
      end

      it 'passes date_field' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(date_field: 'closed'))

        render('from: issues, group_by: period, date_field: closed, assign_to: stats')
      end

      it 'passes user_label' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(user_label: 'login'))

        render('from: issues, group_by: assignee, user_label: login, assign_to: stats')
      end

      it 'passes period and periods to the period dimension' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(period: 'week', periods: 13))

        render('from: issues, group_by: period, period: week, periods: 13, assign_to: stats')
      end

      it 'still honours the legacy months alias in dimension mode' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(period: 'month', periods: 12))

        render('from: issues, group_by: period, months: 12, assign_to: stats')
      end

      it 'resolves a dimension given as a Liquid variable' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(group_by: 'cf_92', split_by: 'cf_86'))

        render('from: issues, group_by: dim, split_by: split, assign_to: stats',
               'dim' => 'cf_92', 'split' => 'cf_86')
      end

      it 'resolves limit given as a Liquid variable' do
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .with(scope, hash_including(limit: 7))

        render('from: issues, group_by: cf_99, limit: top_n, assign_to: stats', 'top_n' => 7)
      end
    end

    context 'rejected combinations' do
      it 'rejects split_by without group_by' do
        expect(SqlAggregation::QueryAggregator).not_to receive(:dimension_breakdown)
        expect(SqlAggregation::QueryAggregator).not_to receive(:aggregate)

        ctx = render('from: issues, split_by: cf_86, assign_to: stats')
        expect(ctx.scopes.last['stats']['total']).to eq(0)
      end

      it 'logs a warning for split_by without group_by' do
        expect(Rails.logger).to receive(:warn).with(/split_by needs a group_by/)

        render('from: issues, split_by: cf_86, assign_to: stats')
      end

      it 'rejects split_by: flags' do
        expect(SqlAggregation::QueryAggregator).not_to receive(:dimension_breakdown)

        ctx = render('from: issues, group_by: cf_92, split_by: flags, assign_to: stats')
        expect(ctx.scopes.last['stats']['total']).to eq(0)
      end

      it 'logs a warning for split_by: flags' do
        expect(Rails.logger).to receive(:warn).with(/flags is not a valid split_by/)

        render('from: issues, group_by: cf_92, split_by: flags, assign_to: stats')
      end

      it 'assigns the empty result when the aggregator rejects the dimension' do
        allow(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown).and_return(nil)

        ctx = render('from: issues, group_by: cf_0, assign_to: stats')
        expect(ctx.scopes.last['stats']['buckets']).to eq([])
        expect(ctx.scopes.last['stats']['total']).to eq(0)
      end

      it 'returns an empty string even when the dimension is rejected' do
        allow(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown).and_return(nil)

        ctx = build_context('issues' => drop)
        expect(build_tag('from: issues, group_by: cf_0, assign_to: stats').render(ctx)).to eq('')
      end

      it 'never raises when the dimension aggregation blows up' do
        allow(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown).and_raise(StandardError, 'boom')

        ctx = build_context('issues' => drop)
        expect { build_tag('from: issues, group_by: cf_92, assign_to: stats').render(ctx) }.not_to raise_error
        expect(ctx.scopes.last['stats']['total']).to eq(0)
      end
    end

    context 'empty result' do
      let(:empty) do
        ctx = build_context('issues' => nil)
        build_tag('from: issues, group_by: cf_92, split_by: cf_86, assign_to: stats').render(ctx)
        ctx.scopes.last['stats']
      end

      it 'exposes every crosstab key as an empty array' do
        expect(empty.values_at('series', 'rows', 'matrix', 'columns')).to all(eq([]))
      end

      it 'exposes flags as an empty hash' do
        expect(empty['flags']).to eq({})
      end

      it 'exposes the dimension metadata as nil / false' do
        expect(empty['dimension']).to be_nil
        expect(empty['split_by']).to be_nil
        expect(empty['field_name']).to be_nil
        expect(empty['series_field_name']).to be_nil
        expect(empty['multi_value']).to be(false)
        expect(empty['truncated']).to be(false)
      end

      it 'keeps the historical time-series keys' do
        expect(empty.values_at('labels', 'created', 'closed')).to all(eq([]))
        expect(empty['open_now']).to eq(0)
        expect(empty['total']).to eq(0)
      end
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
