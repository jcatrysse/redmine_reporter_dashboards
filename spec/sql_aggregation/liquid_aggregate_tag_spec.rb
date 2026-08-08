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

require_relative '../../lib/redmine_reporter_dashboards/aggregation/query_aggregator'
require_relative '../../lib/sql_aggregation/liquid_aggregate_tag'
# T-07: these examples exercise the LEGACY resolution path — a tag renders with no
# RenderContext in its registers, so Liquid::ScopeBinding falls back to
# Glue::Legacy::ScopeResolution. On a real install that module is loaded because
# reporter is present (REPORTER_GLUE_FILES); here it has to be required explicitly,
# and requiring it is the point: without it ScopeBinding correctly resolves nothing.
require_relative '../../lib/redmine_reporter_dashboards/glue/legacy/scope_resolution'

# AR-scope stub
class LiquidTagScopeStub
  def where(*); self; end
  def not(*);   self; end
  def group(*); self; end
  def unscope(*); self; end
  def count(*);  0;   end
  def base_scope; self; end
  # ScopeResolution intersects a drop-resolved scope with Issue.visible.
  def merge(*); self; end
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
  attr_writer :visible

  def initialize(scope)
    @base_scope = scope
    @visible    = true
  end

  def id
    42
  end

  # Query#visible? — the drill-through gate calls it for every source.
  def visible?(*)
    @visible
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

# Redmine's SortCriteria, reduced to the one method Query#as_params calls.
class DrillTagSortCriteria
  def initialize(param = 'priority:desc')
    @param = param
  end

  def to_param
    @param
  end
end

DrillTagProject = Struct.new(:id, :identifier)

# An IssueQuery stub that answers BOTH roles the tag needs: base_scope for the
# aggregation and the drill-through API (filters / columns / grouping / totals /
# sort / available_filters / as_params) for the URLs. #as_params is transcribed
# from Query#as_params, new_record? branch.
class DrillTagQueryStub
  class << self
    attr_accessor :available_filters_config

    # Redmine's Query.visible is a class method returning a relation.
    def visible(*)
      self
    end

    def registry
      @registry ||= {}
    end

    def find_by(id:)
      registry[id]
    end
  end
  self.available_filters_config = {
    'status_id'      => { type: :list_status },
    'assigned_to_id' => { type: :list_optional },
    'due_date'       => { type: :date },
    'created_on'     => { type: :date_past },
    'cf_92'          => { type: :list_optional },
    'cf_86'          => { type: :list_optional }
  }

  attr_accessor :filters, :column_names, :group_by, :totalable_names, :sort_criteria
  attr_reader :project, :base_scope

  def initialize(scope = nil, name: '_', project: nil)
    @base_scope      = scope
    @name            = name
    @project         = project
    @filters         = { 'status_id' => { operator: 'o', values: [''] } }
    @column_names    = %i[tracker status subject]
    @group_by        = nil
    @totalable_names = []
    @sort_criteria   = DrillTagSortCriteria.new
  end

  def available_filters
    self.class.available_filters_config
  end

  def id
    7
  end

  def visible?(*)
    true
  end

  def type_for(field)
    available_filters[field] && available_filters[field][:type]
  end

  # Query.operators_by_filter_type, transcribed for the types used here.
  def operators_by_filter_type
    {
      list: ['=', '!'],
      list_status: ['o', '=', '!', 'ev', '!ev', 'cf', 'c', '*'],
      list_optional: ['=', '!', '!*', '*'],
      date: ['=', '>=', '<=', '><', '!*', '*'],
      date_past: ['=', '>=', '<=', '><', '!*', '*']
    }
  end

  def as_params
    params = {}
    filters.each do |field, options|
      params[:f] ||= []
      params[:f] << field
      params[:op] ||= {}
      params[:op][field] = options[:operator]
      params[:v] ||= {}
      params[:v][field] = options[:values]
    end
    params[:c] = column_names
    params[:group_by] = group_by.to_s unless group_by.nil? || group_by.to_s.empty?
    params[:t] = totalable_names.map(&:to_s) if totalable_names.any?
    params[:sort] = sort_criteria.to_param
    params[:set_filter] = 1
    params
  end
end

class DrillTagSettingStub
  def self.protocol
    'https'
  end

  def self.host_name
    'redmine.example'
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
  # T-31 / §Findings S-13 — this kernel counts issues, so it refuses anything else
  # ------------------------------------------------------------------
  #
  # The measurement that forced this: handed a `TimeEntryQuery#base_scope`, the aggregator
  # does NOT raise. That query calls `.left_join_issue`, so every issue column resolves and
  # the tag answers `COUNT(DISTINCT issues.id)` under time-entry labels — four time entries
  # over two issues came back as `2` in every bucket, and `spent_hours` answered nil. A
  # wrong number under a right heading is the outcome this whole guard exists to prevent.
  describe 'a scope over a table this kernel does not count' do
    def owned_context(source)
      render_context = RedmineReporterDashboards::Liquid::RenderContext.new(
        actor: Object.new, scope: scope, source: source
      )
      build_context({}, { RedmineReporterDashboards::Liquid::RenderContext::REGISTER_KEY =>
                          render_context })
    end

    it 'does not aggregate at all when the scope is over time entries' do
      expect(SqlAggregation::QueryAggregator).not_to receive(:aggregate)
      expect(SqlAggregation::QueryAggregator).not_to receive(:breakdown)
      expect(SqlAggregation::QueryAggregator).not_to receive(:dimension_breakdown)

      build_tag('assign_to: stats').render(owned_context(:time_entries))
    end

    it 'assigns the empty result rather than leaving the variable undefined' do
      ctx = owned_context(:time_entries)
      build_tag('assign_to: stats').render(ctx)

      expect(ctx.scopes.last['stats']).to eq(described_class.new('sql_aggregate', '', nil)
                                                            .send(:empty_result))
    end

    # VISIBLE, NOT SILENT (INV-4). A template that renders nothing and says nothing is the
    # same defect one layer up: the author has no way to learn why their figures are blank.
    it 'records a degradation naming the source it refused' do
      ctx = owned_context(:time_entries)
      render_context = ctx.registers[RedmineReporterDashboards::Liquid::RenderContext::REGISTER_KEY]

      build_tag('assign_to: stats').render(ctx)

      # `to_a` answers Hashes — that is the serialised form the diagnostics panel reads,
      # so asserting on it is asserting on what a reader actually sees.
      recorded = render_context.diagnostics.to_a
      expect(recorded.map { |d| d['code'] || d[:code] }.map(&:to_s))
        .to include('aggregation_source_unsupported')
      expect(recorded.to_s).to include('time_entries')
    end

    # AND THE ISSUE PATH IS UNTOUCHED. Without this the guard could be refusing
    # everything and all three examples above would still pass.
    it 'aggregates normally when the very same scope is declared as issues' do
      expect(SqlAggregation::QueryAggregator).to receive(:aggregate).and_return(agg_result)

      build_tag('assign_to: stats').render(owned_context(:issues))
    end

    # The legacy path has no render context at all, and it resolves issue scopes only —
    # so it must keep working with no annotation anywhere.
    it 'aggregates on the legacy path, which carries no source at all' do
      expect(SqlAggregation::QueryAggregator).to receive(:aggregate).and_return(agg_result)

      build_tag('from: issues, assign_to: stats')
        .render(build_context({}, { sql_issue_query: LiquidTagIssueQueryStub.new(scope) }))
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
  # group_by: completeness
  # ------------------------------------------------------------------

  describe 'group_by: completeness' do
    let(:drop) do
      obj = Object.new
      obj.instance_variable_set(:@issues, scope)
      obj
    end

    let(:completeness_result) do
      {
        'buckets' => [
          { 'label' => 'Vessel', 'count' => 34, 'empty' => 15, 'total' => 49, 'pct' => 69,
            'value' => 'cf_94',
            'filter'       => { 'field' => 'cf_94', 'operator' => '*',  'values' => [''] },
            'empty_filter' => { 'field' => 'cf_94', 'operator' => '!*', 'values' => [''] } },
          # status_id is :list_status, which offers * but NOT !* — the case where only
          # half of the pair can be linked.
          { 'label' => 'Status', 'count' => 49, 'empty' => 0, 'total' => 49, 'pct' => 100,
            'value' => 'status_id',
            'filter'       => { 'field' => 'status_id', 'operator' => '*',  'values' => [''] },
            'empty_filter' => { 'field' => 'status_id', 'operator' => '!*', 'values' => [''] } }
        ],
        'total' => 49, 'group_by' => 'completeness', 'dimension' => 'completeness',
        'fields' => %w[cf_94 status_id]
      }
    end

    before { allow(SqlAggregation::QueryAggregator).to receive(:completeness).and_return(completeness_result) }

    def render(markup, assigns = {})
      ctx = build_context(assigns.merge('issues' => drop))
      build_tag(markup).render(ctx)
      ctx
    end

    it 'splits the fields list on semicolons' do
      expect(SqlAggregation::QueryAggregator).to receive(:completeness)
        .with(scope, fields: %w[cf_94 cf_99 assigned_to_id])

      render('from: issues, group_by: completeness, fields: "cf_94;cf_99;assigned_to_id", assign_to: x')
    end

    it 'splits on commas as well' do
      expect(SqlAggregation::QueryAggregator).to receive(:completeness)
        .with(scope, fields: %w[cf_94 due_date])

      render('from: issues, group_by: completeness, fields: "cf_94,due_date", assign_to: x')
    end

    it 'passes nil when fields is absent, so the aggregator does the complaining' do
      expect(SqlAggregation::QueryAggregator).to receive(:completeness).with(scope, fields: nil)

      render('from: issues, group_by: completeness, assign_to: x')
    end

    it 'never calls the dimension path' do
      expect(SqlAggregation::QueryAggregator).not_to receive(:dimension_breakdown)
      expect(SqlAggregation::QueryAggregator).not_to receive(:breakdown)

      render('from: issues, group_by: completeness, fields: "due_date", assign_to: x')
    end

    it 'assigns the result' do
      ctx = render('from: issues, group_by: completeness, fields: "cf_94", assign_to: x')
      expect(ctx.scopes.last['x']['buckets'].first['pct']).to eq(69)
    end

    it 'assigns the empty result when the aggregator refuses' do
      allow(SqlAggregation::QueryAggregator).to receive(:completeness).and_return(nil)
      ctx = render('from: issues, group_by: completeness, assign_to: x')
      expect(ctx.scopes.last['x']['fields']).to eq([])
      expect(ctx.scopes.last['x']['total']).to eq(0)
    end

    it 'warns that completeness ignores the measure' do
      expect(Rails.logger).to receive(:warn).with(/measure: is ignored by group_by: completeness/)
      render('from: issues, group_by: completeness, fields: "due_date", measure: distinct, ' \
             'of: author, assign_to: x')
    end

    it 'is rejected as a split_by' do
      expect(Rails.logger).to receive(:warn).with(/completeness is not a valid split_by/)
      ctx = render('from: issues, group_by: cf_92, split_by: completeness, assign_to: x')
      expect(ctx.scopes.last['x']['total']).to eq(0)
    end

    describe 'with drill: true' do
      let(:project) { DrillTagProject.new(7, 'ops') }
      let(:query)   { DrillTagQueryStub.new(scope, project: project) }

      before do
        stub_const('IssueQuery', DrillTagQueryStub)
        stub_const('Setting', DrillTagSettingStub)
        DrillTagQueryStub.available_filters_config =
          DrillTagQueryStub.available_filters_config.merge('cf_94' => { type: :list_optional })
      end

      after do
        DrillTagQueryStub.available_filters_config =
          DrillTagQueryStub.available_filters_config.reject { |key, _| key == 'cf_94' }
      end

      subject(:res) do
        ctx = build_context({}, { sql_issue_query: query })
        build_tag('group_by: completeness, fields: "cf_94;status_id", drill: true, assign_to: x')
          .render(ctx)
        ctx.scopes.last['x']
      end

      it 'links the filled side with the is-set operator' do
        expect(res['buckets'].first['url']).to include('op%5Bcf_94%5D=%2A')
      end

      it 'links the empty side separately, with the is-not-set operator' do
        expect(res['buckets'].first['empty_url']).to include('op%5Bcf_94%5D=%21%2A')
      end

      it 'never puts the empty link in url' do
        expect(res['buckets'].first['url']).not_to include('%21%2A')
      end

      it 'leaves empty_url nil where Redmine does not allow the not-set operator' do
        expect(res['buckets'].last['empty_url']).to be_nil
      end

      it 'still links the filled side of that same field' do
        expect(res['buckets'].last['url']).to include('op%5Bstatus_id%5D=%2A')
      end

      it 'inherits the report query filters in both links' do
        expect(res['buckets'].first['url']).to include('f%5B%5D=status_id')
        expect(res['buckets'].first['empty_url']).to include('f%5B%5D=status_id')
      end
    end
  end

  # ------------------------------------------------------------------
  # measure: / of:
  # ------------------------------------------------------------------

  describe 'measure' do
    let(:drop) do
      obj = Object.new
      obj.instance_variable_set(:@issues, scope)
      obj
    end

    def render(markup)
      ctx = build_context('issues' => drop)
      build_tag(markup).render(ctx)
      ctx
    end

    it 'defaults to count' do
      expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
        .with(scope, hash_including(measure: 'count', of: ''))

      render('from: issues, group_by: cf_92, assign_to: stats')
    end

    it 'passes the measure and its field through' do
      expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
        .with(scope, hash_including(measure: 'distinct', of: 'author'))

      render('from: issues, group_by: period, measure: distinct, of: author, assign_to: stats')
    end

    it 'leaves the legacy breakdown path for a real measure' do
      expect(SqlAggregation::QueryAggregator).not_to receive(:breakdown)
      expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
        .with(scope, hash_including(measure: 'distinct'))

      render('from: issues, group_by: status, measure: distinct, of: author, assign_to: stats')
    end

    it 'keeps the legacy breakdown path for measure: count' do
      expect(SqlAggregation::QueryAggregator).to receive(:breakdown).with(scope, group_by: 'status')
      expect(SqlAggregation::QueryAggregator).not_to receive(:dimension_breakdown)

      render('from: issues, group_by: status, measure: count, assign_to: stats')
    end

    it 'switches to the dimension path for of: alone, so it is never silently ignored' do
      expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
        .with(scope, hash_including(of: 'author'))

      render('from: issues, group_by: status, of: author, assign_to: stats')
    end

    it 'resolves the measure from a Liquid variable' do
      ctx = build_context('issues' => drop, 'm' => 'distinct')
      expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
        .with(scope, hash_including(measure: 'distinct'))

      build_tag('from: issues, group_by: cf_92, measure: m, of: author, assign_to: stats').render(ctx)
    end

    it 'warns that the time series always counts issues' do
      expect(Rails.logger).to receive(:warn).with(/measure: needs a group_by/)

      render('from: issues, measure: distinct, of: author, assign_to: stats')
    end

    it 'warns that flags ignores the measure' do
      expect(Rails.logger).to receive(:warn).with(/measure: is ignored by group_by: flags/)

      render('from: issues, group_by: flags, measure: distinct, of: author, assign_to: kpi')
    end

    it 'assigns the empty result when the aggregator refuses the measure' do
      allow(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown).and_return(nil)

      ctx = render('from: issues, group_by: cf_92, measure: sum, of: cf_96, assign_to: stats')
      expect(ctx.scopes.last['stats']['total']).to eq(0)
      expect(ctx.scopes.last['stats']['measure']).to be_nil
    end
  end

  # ------------------------------------------------------------------
  # Visibility of a drop-resolved scope
  # ------------------------------------------------------------------

  describe 'a scope resolved from a drop' do
    # Issue.visible is the guarantee the register and query_id paths get for free from
    # base_scope; a drop is whatever the render context happens to hold.
    let(:visible_marker) { LiquidTagScopeStub.new }

    let(:issue_class) do
      marker = visible_marker
      Class.new do
        define_singleton_method(:_marker) { marker }
        define_singleton_method(:visible) { |_user| _marker }
      end
    end

    let(:drop) do
      obj = Object.new
      obj.instance_variable_set(:@issues, scope)
      obj
    end

    before { stub_const('Issue', issue_class) }

    it 'is intersected with what the current user may see' do
      merged = LiquidTagScopeStub.new
      expect(scope).to receive(:merge).with(visible_marker).and_return(merged)
      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(merged, anything).and_return(agg_result)

      build_tag('from: issues, assign_to: stats').render(build_context('issues' => drop))
    end

    it 'leaves the register path alone — base_scope is Issue.visible already' do
      query = LiquidTagIssueQueryStub.new(scope)
      expect(scope).not_to receive(:merge)
      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(scope, anything).and_return(agg_result)

      build_tag('from: issues, assign_to: stats')
        .render(build_context({}, { sql_issue_query: query }))
    end

    it 'leaves the query_id path alone for the same reason' do
      LiquidTagIssueQueryStub.register(42, scope)
      expect(scope).not_to receive(:merge)

      build_tag('query_id: 42, assign_to: stats').render(build_context)
    end

    it 'uses the scope as resolved when the intersection cannot be applied' do
      allow(scope).to receive(:merge).and_raise(StandardError, 'not a relation')
      expect(Rails.logger).to receive(:warn).with(/could not intersect the resolved scope/)
      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(scope, anything).and_return(agg_result)

      build_tag('from: issues, assign_to: stats').render(build_context('issues' => drop))
    end

    it 'still returns nil when the drop resolves to nothing' do
      ctx = build_context('issues' => nil)
      build_tag('from: issues, assign_to: stats').render(ctx)
      expect(ctx.scopes.last['stats']['total']).to eq(0)
    end
  end

  # ------------------------------------------------------------------
  # IssueQuery resolution (drill-through prerequisite)
  # ------------------------------------------------------------------

  describe '#resolve_query' do
    let(:query) { LiquidTagIssueQueryStub.new(scope) }

    def resolve(markup, assigns = {}, registers = {})
      build_tag(markup).resolve_query(build_context(assigns, registers))
    end

    after { Thread.current[RedmineReporterDashboards::Glue::Legacy::ScopeResolution::QUERY_THREAD_KEY] = nil }

    it 'resolves the query_id param through the visibility scope' do
      LiquidTagIssueQueryStub.register(42, scope)
      expect(resolve('query_id: 42')).to be(LiquidTagIssueQueryStub.find_by(id: 42))
      expect(LiquidTagIssueQueryStub.visible_args).to eq([User.current])
    end

    it 'resolves a query_id given as a Liquid variable' do
      LiquidTagIssueQueryStub.register(7, scope)
      expect(resolve('query_id: my_qid', 'my_qid' => 7)).not_to be_nil
    end

    it 'returns nil — never raises — for a query the user may not see' do
      allow(LiquidTagIssueQueryStub).to receive(:visible).and_return(
        Class.new { def self.find_by(id:); nil; end }
      )
      expect { resolve('query_id: 42') }.not_to raise_error
      expect(resolve('query_id: 42')).to be_nil
    end

    it 'does not fall back to the registers when an explicit query_id fails' do
      allow(LiquidTagIssueQueryStub).to receive(:visible).and_return(
        Class.new { def self.find_by(id:); nil; end }
      )
      expect(resolve('query_id: 999', {}, { sql_issue_query: query })).to be_nil
    end

    it 'resolves the :sql_issue_query register' do
      expect(resolve('from: issues', {}, { sql_issue_query: query })).to be(query)
    end

    it 'resolves the :container register when it IS an IssueQuery' do
      expect(resolve('from: issues', {}, { container: query })).to be(query)
    end

    it 'resolves the @query ivar of the :container register' do
      container = Object.new
      container.instance_variable_set(:@query, query)
      expect(resolve('from: issues', {}, { container: container })).to be(query)
    end

    it 'resolves the @query ivar of the :controller register' do
      controller = double('controller')
      allow(controller).to receive(:instance_variable_get).with(:@query).and_return(query)
      expect(resolve('from: issues', {}, { controller: controller })).to be(query)
    end

    it 'resolves the thread-local ReporterListPatch sets' do
      Thread.current[RedmineReporterDashboards::Glue::Legacy::ScopeResolution::QUERY_THREAD_KEY] = query
      expect(resolve('from: issues')).to be(query)
    end

    it 'prefers the registers over the thread-local' do
      other = LiquidTagIssueQueryStub.new(LiquidTagScopeStub.new)
      Thread.current[RedmineReporterDashboards::Glue::Legacy::ScopeResolution::QUERY_THREAD_KEY] = other
      expect(resolve('from: issues', {}, { sql_issue_query: query })).to be(query)
    end

    it 'prefers :sql_issue_query over :container and :controller' do
      other      = LiquidTagIssueQueryStub.new(LiquidTagScopeStub.new)
      controller = double('controller')
      allow(controller).to receive(:instance_variable_get).with(:@query).and_return(other)
      registers = { sql_issue_query: query, container: other, controller: controller }
      expect(resolve('from: issues', {}, registers)).to be(query)
    end

    it 'refuses a query the viewer may not see, whatever the source' do
      query.visible = false
      expect(resolve('from: issues', {}, { sql_issue_query: query })).to be_nil
    end

    it 'refuses an invisible query from the thread-local too' do
      # ReporterListPatch resolves it with a bare find_by, because that lookup also
      # feeds base_scope — so the gate has to sit on the reading side.
      query.visible = false
      Thread.current[RedmineReporterDashboards::Glue::Legacy::ScopeResolution::QUERY_THREAD_KEY] = query
      expect(resolve('from: issues')).to be_nil
    end

    it 'says why an invisible query was refused' do
      query.visible = false
      expect(Rails.logger).to receive(:warn).with(/not visible to the current user/)
      resolve('from: issues', {}, { sql_issue_query: query })
    end

    it 'never raises when the visibility check itself blows up' do
      allow(query).to receive(:visible?).and_raise(StandardError, 'no user')
      expect { resolve('from: issues', {}, { sql_issue_query: query }) }.not_to raise_error
      expect(resolve('from: issues', {}, { sql_issue_query: query })).to be_nil
    end

    it 'accepts a query object that has no visible? at all' do
      bare = Class.new(LiquidTagIssueQueryStub) { undef_method :visible? }.new(scope)
      stub_const('IssueQuery', bare.class)
      expect(resolve('from: issues', {}, { sql_issue_query: bare })).to be(bare)
    end

    it 'returns nil when nothing holds a query' do
      expect(resolve('from: issues')).to be_nil
    end

    it 'ignores a register that is not an IssueQuery' do
      expect(resolve('from: issues', {}, { container: scope, controller: Object.new })).to be_nil
    end

    it 'ignores a thread-local that is not an IssueQuery' do
      Thread.current[RedmineReporterDashboards::Glue::Legacy::ScopeResolution::QUERY_THREAD_KEY] = scope
      expect(resolve('from: issues')).to be_nil
    end
  end

  # ------------------------------------------------------------------
  # drill: true
  # ------------------------------------------------------------------

  describe 'drill: true' do
    let(:project) { DrillTagProject.new(7, 'ops') }
    let(:query)   { DrillTagQueryStub.new(scope, project: project) }

    let(:dimension_with_filters) do
      {
        'buckets' => [
          { 'label' => 'Survey', 'count' => 18, 'value' => '415',
            'filter' => { 'field' => 'cf_92', 'operator' => '=', 'values' => ['415'] } },
          { 'label' => 'Other', 'count' => 3, 'value' => nil, 'values' => %w[580 581],
            'filter' => { 'field' => 'cf_92', 'operator' => '=', 'values' => %w[580 581] } },
          { 'label' => '(none)', 'count' => 5, 'value' => nil,
            'filter' => { 'field' => 'cf_92', 'operator' => '!*', 'values' => [''] } },
          { 'label' => 'Unfilterable', 'count' => 1, 'value' => 'x', 'filter' => nil }
        ],
        'total' => 27, 'group_by' => 'cf_92', 'dimension' => 'cf_92'
      }
    end

    let(:crosstab_with_filters) do
      {
        'series' => ['Positive', 'Negative'],
        'series_entries' => [
          { 'label' => 'Positive', 'value' => '345',
            'filter' => { 'field' => 'cf_86', 'operator' => '=', 'values' => ['345'] } },
          { 'label' => 'Negative', 'value' => '346', 'filter' => nil }
        ],
        'rows' => [
          { 'label' => 'Survey', 'total' => 4, 'counts' => [4, 0], 'value' => '415',
            'filter' => { 'field' => 'cf_92', 'operator' => '=', 'values' => ['415'] } },
          { 'label' => '(none)', 'total' => 1, 'counts' => [0, 1], 'value' => nil,
            'filter' => { 'field' => 'cf_92', 'operator' => '!*', 'values' => [''] } }
        ],
        'matrix' => [[4, 0], [0, 1]],
        'buckets' => [], 'total' => 5, 'group_by' => 'cf_92', 'split_by' => 'cf_86'
      }
    end

    let(:flags_with_stages) do
      {
        'total' => 49, 'assigned' => 24, 'with_due_date' => 7, 'closed' => 4,
        'flags' => { 'total' => 49 }, 'buckets' => [], 'group_by' => 'flags',
        'stages' => [
          { 'key' => 'total', 'label' => 'Registered', 'count' => 49, 'filter' => nil },
          { 'key' => 'assigned', 'label' => 'Has assignee', 'count' => 24,
            'filter' => { 'field' => 'assigned_to_id', 'operator' => '*', 'values' => [''] } },
          { 'key' => 'with_due_date', 'label' => 'Has due date', 'count' => 7,
            'filter' => { 'field' => 'due_date', 'operator' => '*', 'values' => [''] } },
          { 'key' => 'closed', 'label' => 'Closed', 'count' => 4,
            'filter' => { 'field' => 'status_id', 'operator' => 'c', 'values' => [''] } }
        ]
      }
    end

    before do
      stub_const('IssueQuery', DrillTagQueryStub)
      stub_const('Setting', DrillTagSettingStub)
    end

    # registers hold the query; the same object answers base_scope, so the
    # aggregation and the URLs come from one source, exactly as in production.
    def render(markup, result: dimension_with_filters, registers: nil)
      allow(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown).and_return(result)
      allow(SqlAggregation::QueryAggregator).to receive(:flags).and_return(result)
      ctx = build_context({}, registers.nil? ? { sql_issue_query: query } : registers)
      build_tag(markup).render(ctx)
      ctx.scopes.last['stats']
    end

    describe 'a breakdown' do
      subject(:res) { render('group_by: cf_92, drill: true, assign_to: stats') }

      it 'reports drill-through as available' do
        expect(res['drill_available']).to be(true)
      end

      it 'exposes the report query itself as base_url' do
        expect(res['base_url']).to start_with('https://redmine.example/projects/ops/issues?')
        expect(res['base_url']).to include('set_filter=1')
      end

      it 'gives every expressible bucket a URL' do
        expect(res['buckets'][0]['url']).to include('v%5Bcf_92%5D%5B%5D=415')
      end

      it 'inherits the report filters in every element URL' do
        expect(res['buckets'][0]['url']).to include('f%5B%5D=status_id', 'op%5Bstatus_id%5D=o')
      end

      it 'links an Other row to the union of its collapsed values' do
        expect(res['buckets'][1]['url']).to include('v%5Bcf_92%5D%5B%5D=580', 'v%5Bcf_92%5D%5B%5D=581')
      end

      it 'links the empty bucket with the "none" operator' do
        expect(res['buckets'][2]['url']).to include('op%5Bcf_92%5D=%21%2A')
      end

      it 'leaves an inexpressible bucket without a URL' do
        expect(res['buckets'][3]['url']).to be_nil
      end

      it 'keeps the labels and counts it was given' do
        expect(res['buckets'].map { |b| b['label'] })
          .to eq(['Survey', 'Other', '(none)', 'Unfilterable'])
        expect(res['buckets'].map { |b| b['count'] }).to eq([18, 3, 5, 1])
      end

      it 'leaves the legacy breakdown path for drill: true' do
        expect(SqlAggregation::QueryAggregator).not_to receive(:breakdown)
        expect(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .and_return(dimension_with_filters)

        ctx = build_context({}, { sql_issue_query: query })
        build_tag('group_by: status, drill: true, assign_to: stats').render(ctx)
      end

      it 'keeps the legacy breakdown path for a falsy drill' do
        expect(SqlAggregation::QueryAggregator).to receive(:breakdown).and_return(breakdown_result)
        expect(SqlAggregation::QueryAggregator).not_to receive(:dimension_breakdown)

        ctx = build_context({}, { sql_issue_query: query })
        build_tag('group_by: status, drill: false, assign_to: stats').render(ctx)
      end

      it 'accepts drill given as a Liquid boolean variable' do
        allow(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .and_return(dimension_with_filters)
        ctx = build_context({ 'enabled' => true }, { sql_issue_query: query })
        build_tag('group_by: cf_92, drill: enabled, assign_to: stats').render(ctx)
        expect(ctx.scopes.last['stats']['drill_available']).to be(true)
      end

      # The base URL is ~186 characters and a filtered one ~241, so a 200 cap
      # keeps the base and refuses every element instead of truncating one.
      # Liquid parses a template once and renders the same tag instance again,
      # possibly concurrently and with different assigns, so nothing that depends
      # on the context may be cached on the tag.
      it 'reads drill from the context of every render, not just the first' do
        # A fresh result per call, exactly as the aggregator produces one.
        allow(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown) do
          Marshal.load(Marshal.dump(dimension_with_filters))
        end
        tag = build_tag('group_by: cf_92, drill: enabled, assign_to: stats')

        first = build_context({ 'enabled' => true }, { sql_issue_query: query })
        tag.render(first)
        second = build_context({ 'enabled' => false }, { sql_issue_query: query })
        tag.render(second)

        expect(first.scopes.last['stats']['drill_available']).to be(true)
        expect(second.scopes.last['stats']).not_to have_key('drill_available')
      end

      # A full element URL is ~241 characters here and ~194 without the inherited
      # columns, so a 200 cap keeps the link and sheds only the cosmetics.
      context 'with a drill_max_url that the full URL does not fit' do
        subject(:res) { render('group_by: cf_92, drill: true, drill_max_url: 200, assign_to: stats') }

        it 'keeps the link and drops the inherited columns instead' do
          expect(res['buckets'][0]['url']).not_to be_nil
          expect(res['buckets'][0]['url']).not_to include('c%5B%5D')
        end

        it 'keeps the filters, which are what makes the URL match the element' do
          expect(res['buckets'][0]['url']).to include('f%5B%5D=cf_92', 'f%5B%5D=status_id')
        end

        it 'reports the degradation so a template can explain the layout' do
          expect(res['drill_degraded']).to be(true)
        end

        it 'says so once in the log' do
          allow(Rails.logger).to receive(:warn) # the base URL logs its own degradation first
          expect(Rails.logger).to receive(:warn).once.with(/for cf_92 is \d+ characters, over the 200 cap/)
          render('group_by: cf_92, drill: true, drill_max_url: 200, assign_to: stats')
        end
      end

      context 'with a drill_max_url that not even the filters fit' do
        subject(:res) { render('group_by: cf_92, drill: true, drill_max_url: 170, assign_to: stats') }

        it 'gives up on the element URLs rather than truncating one' do
          expect(res['buckets'].map { |b| b['url'] }).to all(be_nil)
        end

        it 'still reports the base URL, which does fit' do
          expect(res['drill_available']).to be(true)
          expect(res['base_url']).not_to be_nil
        end

        it 'logs the real length and the cap' do
          allow(Rails.logger).to receive(:warn) # the degradation ladder logs on the way down
          expect(Rails.logger).to receive(:warn)
            .with(/still \d+ characters with filters alone, over the 170 cap/)
          render('group_by: cf_92, drill: true, drill_max_url: 170, assign_to: stats')
        end
      end

      it 'keeps the whole URL, columns and all, at the default cap' do
        res = render('group_by: cf_92, drill: true, assign_to: stats')
        expect(res['buckets'][0]['url']).to include('c%5B%5D=tracker')
        expect(res['drill_degraded']).to be(false)
      end

      describe 'drill_inherit' do
        it 'inherits everything by default' do
          res = render('group_by: cf_92, drill: true, assign_to: stats')
          expect(res['buckets'][0]['url']).to include('c%5B%5D=tracker', 'sort=priority%3Adesc')
        end

        it 'inherits the filters only when asked to' do
          res = render('group_by: cf_92, drill: true, drill_inherit: filters, assign_to: stats')
          url = res['buckets'][0]['url']
          expect(url).to include('f%5B%5D=cf_92', 'f%5B%5D=status_id', 'set_filter=1')
          expect(url).not_to include('c%5B%5D', 'sort=', 'group_by=')
        end

        it 'warns and inherits everything for an unknown value' do
          expect(Rails.logger).to receive(:warn).with(/unknown drill_inherit/)
          res = render('group_by: cf_92, drill: true, drill_inherit: banana, assign_to: stats')
          expect(res['buckets'][0]['url']).to include('c%5B%5D=tracker')
        end
      end
    end

    describe 'a crosstab' do
      subject(:res) do
        render('group_by: cf_92, split_by: cf_86, drill: true, assign_to: stats',
               result: crosstab_with_filters)
      end

      it 'keeps series an array of label strings' do
        expect(res['series']).to eq(['Positive', 'Negative'])
      end

      it 'gives every series entry a URL' do
        expect(res['series_entries'][0]['url']).to include('v%5Bcf_86%5D%5B%5D=345')
      end

      it 'gives every row a URL' do
        expect(res['rows'][0]['url']).to include('v%5Bcf_92%5D%5B%5D=415')
      end

      it 'builds cell_urls aligned with matrix' do
        expect(res['cell_urls'].length).to eq(res['matrix'].length)
        expect(res['cell_urls'].map(&:length)).to eq(res['matrix'].map(&:length))
      end

      it 'combines the row filter and the series filter in a cell URL' do
        expect(res['cell_urls'][0][0]).to include('v%5Bcf_92%5D%5B%5D=415', 'v%5Bcf_86%5D%5B%5D=345')
      end

      it 'reports the cell grid as complete' do
        expect(res['cell_urls_truncated']).to be(false)
      end

      it 'keeps the array dense where a filter is missing' do
        expect(res['cell_urls'][0][1]).to be_nil
        expect(res['cell_urls'][1][1]).to be_nil
      end

      it 'combines the empty-bucket row filter with a series filter' do
        expect(res['cell_urls'][1][0]).to include('op%5Bcf_92%5D=%21%2A', 'v%5Bcf_86%5D%5B%5D=345')
      end
    end

    describe 'flags' do
      subject(:res) { render('group_by: flags, drill: true, assign_to: stats', result: flags_with_stages) }

      it 'links the total stage to the report query unchanged' do
        expect(res['stages'][0]['url']).to eq(res['base_url'])
      end

      it 'links the assignee stage with the "is set" operator' do
        expect(res['stages'][1]['url']).to include('op%5Bassigned_to_id%5D=%2A')
      end

      it 'links the due date stage' do
        expect(res['stages'][2]['url']).to include('f%5B%5D=due_date')
      end

      it 'links the closed stage with the closed operator' do
        expect(res['stages'][3]['url']).to include('op%5Bstatus_id%5D=c')
      end

      it 'warns that an explicit closed_statuses can disagree with the closed stage' do
        expect(Rails.logger).to receive(:warn).with(/closed stage links to status_id=c/)
        render('group_by: flags, drill: true, closed_statuses: "Done", assign_to: stats',
               result: flags_with_stages)
      end

      it 'stays quiet without an explicit closed_statuses' do
        expect(Rails.logger).not_to receive(:warn).with(/closed stage links to status_id=c/)
        render('group_by: flags, drill: true, assign_to: stats', result: flags_with_stages)
      end
    end

    describe 'when no IssueQuery can be resolved' do
      subject(:res) do
        render('group_by: cf_92, drill: true, assign_to: stats',
               registers: { container: scope })
      end

      it 'reports drill-through as unavailable' do
        expect(res['drill_available']).to be(false)
      end

      it 'emits no base_url' do
        expect(res).not_to have_key('base_url')
      end

      it 'emits no element URLs at all' do
        expect(res['buckets'].map { |b| b.key?('url') }).to all(be(false))
      end

      it 'still returns the counts' do
        expect(res['total']).to eq(27)
      end

      it 'says why in the log' do
        expect(Rails.logger).to receive(:warn).with(/no IssueQuery could be resolved/)
        render('group_by: cf_92, drill: true, assign_to: stats', registers: { container: scope })
      end
    end

    describe 'the time series' do
      it 'reports drill-through as unavailable and points at group_by: period' do
        expect(Rails.logger).to receive(:warn).with(/use group_by: period/)
        ctx = build_context({}, { sql_issue_query: query })
        build_tag('drill: true, assign_to: stats').render(ctx)
        expect(ctx.scopes.last['stats']['drill_available']).to be(false)
        expect(ctx.scopes.last['stats']).not_to have_key('base_url')
      end
    end

    describe 'the query source' do
      after { DrillTagQueryStub.registry.clear }

      it 'uses the query named by query_id: for the URLs' do
        DrillTagQueryStub.registry[42] =
          DrillTagQueryStub.new(scope, project: DrillTagProject.new(9, 'other'))
        allow(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .and_return(dimension_with_filters)

        ctx = build_context({}, { sql_issue_query: query })
        build_tag('query_id: 42, group_by: cf_92, drill: true, assign_to: stats').render(ctx)

        expect(ctx.scopes.last['stats']['base_url']).to include('/projects/other/issues')
      end

      it 'uses the thread-local when nothing else holds a query' do
        Thread.current[RedmineReporterDashboards::Glue::Legacy::ScopeResolution::QUERY_THREAD_KEY] = query
        res = render('group_by: cf_92, drill: true, assign_to: stats', registers: { container: scope })
        expect(res['drill_available']).to be(true)
      ensure
        Thread.current[RedmineReporterDashboards::Glue::Legacy::ScopeResolution::QUERY_THREAD_KEY] = nil
      end
    end

    describe 'when even the base URL does not fit' do
      subject(:res) { render('group_by: cf_92, drill: true, drill_max_url: 50, assign_to: stats') }

      it 'reports drill-through as unavailable' do
        expect(res['drill_available']).to be(false)
      end

      it 'emits no base_url and no element URLs' do
        expect(res).not_to have_key('base_url')
        expect(res['buckets'].map { |b| b.key?('url') }).to all(be(false))
      end
    end

    describe 'a crosstab of one custom field against itself' do
      let(:same_field) do
        filter = ->(value) { { 'field' => 'cf_92', 'operator' => '=', 'values' => [value] } }
        {
          'series' => %w[Survey Geotech],
          'series_entries' => [{ 'label' => 'Survey', 'value' => '415', 'filter' => filter.call('415') },
                               { 'label' => 'Geotech', 'value' => '416', 'filter' => filter.call('416') }],
          'rows' => [{ 'label' => 'Survey', 'counts' => [3, 1], 'filter' => filter.call('415') },
                     { 'label' => 'Geotech', 'counts' => [1, 2], 'filter' => filter.call('416') }],
          'matrix' => [[3, 1], [1, 2]], 'total' => 7
        }
      end

      subject(:res) do
        render('group_by: cf_92, split_by: cf_92, drill: true, assign_to: stats', result: same_field)
      end

      it 'links the diagonal, where both filters agree' do
        expect(res['cell_urls'][0][0]).to include('v%5Bcf_92%5D%5B%5D=415')
        expect(res['cell_urls'][1][1]).to include('v%5Bcf_92%5D%5B%5D=416')
      end

      it 'refuses the off-diagonal, which Redmine cannot express as one filter' do
        expect(res['cell_urls'][0][1]).to be_nil
        expect(res['cell_urls'][1][0]).to be_nil
      end
    end

    describe 'a crosstab past the cell cap' do
      let(:huge) do
        filter = ->(i) { { 'field' => 'cf_92', 'operator' => '=', 'values' => [i.to_s] } }
        rows   = (1..71).map { |i| { 'label' => "r#{i}", 'counts' => [0], 'filter' => filter.call(i) } }
        series = (1..71).map { |i| { 'label' => "s#{i}", 'filter' => filter.call(i) } }
        { 'series' => series.map { |e| e['label'] }, 'series_entries' => series,
          'rows' => rows, 'matrix' => rows.map { [0] }, 'total' => 0 }
      end

      subject(:res) do
        render('group_by: cf_92, split_by: cf_86, drill: true, assign_to: stats', result: huge)
      end

      it 'keeps cell_urls dense and aligned' do
        expect(res['cell_urls'].length).to eq(71)
        expect(res['cell_urls'].map(&:length).uniq).to eq([71])
      end

      it 'leaves every entry nil rather than emitting megabytes of markup' do
        expect(res['cell_urls'].flatten.compact).to be_empty
      end

      it 'says so in the log' do
        expect(Rails.logger).to receive(:warn).with(/drill-through cell cap/)
        render('group_by: cf_92, split_by: cf_86, drill: true, assign_to: stats', result: huge)
      end

      it 'still links the rows themselves' do
        expect(res['rows'].first['url']).not_to be_nil
      end
    end

    describe 'when the aggregation itself fails' do
      it 'assigns the empty result, with drill-through reported unavailable' do
        allow(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown).and_return(nil)
        ctx = build_context({}, { sql_issue_query: query })
        build_tag('group_by: cf_0, drill: true, assign_to: stats').render(ctx)

        expect(ctx.scopes.last['stats']['drill_available']).to be(false)
        expect(ctx.scopes.last['stats']['base_url']).to be_nil
        expect(ctx.scopes.last['stats']['cell_urls']).to eq([])
      end
    end

    describe 'failure modes' do
      it 'keeps the counts when URL building blows up' do
        allow(SqlAggregation::DrillThrough).to receive(:build).and_raise(StandardError, 'boom')
        res = render('group_by: cf_92, drill: true, assign_to: stats')
        expect(res['total']).to eq(27)
        expect(res['drill_available']).to be(false)
      end

      it 'keeps cell_urls aligned with matrix even when an entry carries no filter' do
        broken = {
          'series' => %w[a b],
          'series_entries' => [{ 'label' => 'a' }, 'nonsense'],
          'rows' => [{ 'label' => 'r', 'counts' => [0, 0],
                       'filter' => { 'field' => 'cf_92', 'operator' => '=', 'values' => ['415'] } }],
          'matrix' => [[0, 0]], 'total' => 0
        }
        res = render('group_by: cf_92, split_by: cf_86, drill: true, assign_to: stats', result: broken)
        expect(res['cell_urls']).to eq([[nil, nil]])
      end

      it 'tolerates a result whose buckets are not hashes' do
        weird = { 'buckets' => ['nonsense'], 'total' => 0 }
        expect { render('group_by: cf_92, drill: true, assign_to: stats', result: weird) }
          .not_to raise_error
      end
    end
  end

  # ------------------------------------------------------------------
  # Regression: nothing changes without drill
  # ------------------------------------------------------------------

  describe 'without drill' do
    let(:drop) do
      obj = Object.new
      obj.instance_variable_set(:@issues, scope)
      obj
    end

    it 'returns the time series result unchanged' do
      ctx = build_context('issues' => drop)
      build_tag('from: issues, assign_to: stats').render(ctx)
      expect(ctx.scopes.last['stats']).to eq(agg_result)
    end

    it 'returns the legacy core-field breakdown unchanged' do
      ctx = build_context('issues' => drop)
      build_tag('from: issues, group_by: tracker, assign_to: stats').render(ctx)
      expect(ctx.scopes.last['stats']).to eq(breakdown_result)
    end

    it 'returns the dimension result unchanged' do
      ctx = build_context('issues' => drop)
      build_tag('from: issues, group_by: cf_92, assign_to: stats').render(ctx)
      expect(ctx.scopes.last['stats']).to eq(dimension_result)
    end

    it 'returns the flags result unchanged' do
      ctx = build_context('issues' => drop)
      build_tag('from: issues, group_by: flags, assign_to: kpi').render(ctx)
      expect(ctx.scopes.last['kpi']).to eq(flags_result)
    end

    it 'never resolves an IssueQuery for the URLs' do
      ctx = build_context('issues' => drop)
      tag = build_tag('from: issues, group_by: cf_92, assign_to: stats')
      expect(tag).not_to receive(:resolve_query)
      tag.render(ctx)
    end

    it 'never builds a drill-through builder' do
      expect(SqlAggregation::DrillThrough).not_to receive(:build)
      ctx = build_context('issues' => drop)
      build_tag('from: issues, group_by: cf_92, assign_to: stats').render(ctx)
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
