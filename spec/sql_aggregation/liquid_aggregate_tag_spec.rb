# frozen_string_literal: true

require 'logger' # concurrent-ruby >= 1.3.5 no longer requires this; ActiveSupport needs Logger defined
require 'active_support'
require 'active_support/time'
require_relative '../spec_helper'

Time.zone ||= 'UTC'

# PER-CONSTANT, NOT `unless defined?(ActiveRecord)`. MEASURED: T-31 added a DB-less spec
# that defines only `ActiveRecord::StatementInvalid`, and on the seeds where it loaded first
# the coarse guard here saw `ActiveRecord` already defined and skipped — leaving
# `RecordNotFound` undefined and this file red for a reason nothing in its own diff showed.
# A guard over a namespace cannot stand in for a guard over what is inside it.
module ActiveRecord; end unless defined?(ActiveRecord)

unless defined?(ActiveRecord::RecordNotFound)
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
# T-31 increment 2: the tag DISPATCHES a time-entry scope to this module, so it has to be
# loadable here. Required directly and not through `aggregation.rb`, which also assigns
# namespace constants a booted Redmine owns — the same reason spec/adapter does it this way.
require_relative '../../lib/redmine_reporter_dashboards/aggregation/time_entry_aggregator'
require_relative '../../lib/sql_aggregation/liquid_aggregate_tag'
# S-30: the legacy resolution module is DELETED. These examples build every context
# from an owned `RenderContext` (see `owned_registers` below), which is how every render
# has been constructed since T-26a, so there is nothing left to require here.

# AR-scope stub
class LiquidTagScopeStub
  def where(*); self; end
  def not(*);   self; end
  def group(*); self; end
  def unscope(*); self; end
  def count(*);  0;   end
  def base_scope; self; end
  # KEPT AFTER S-30 DELETED ITS REASON, deliberately. `ScopeResolution` used to intersect
  # a drop-resolved scope with `Issue.visible` and this stub answered that call; nothing
  # calls it now. It stays because a scope double that cannot answer `merge` would fail
  # for a confusing reason the first time any code legitimately merges a relation, and
  # one no-op method is cheaper than that debugging session.
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

  # --- S-30 · THE OWNED HARNESS -------------------------------------------------------
  #
  # Every example below that is about WHAT THE TAG DOES rather than about how a scope is
  # found gets its scope this way: an explicit `RenderContext` in the registers, which is
  # the only way a render is constructed in production after T-26a.
  #
  # It replaced a harness built on `Glue::Legacy::ScopeResolution`'s six sources — an
  # `issues` drop assign, a `sql_issue_query` register, `container`, `controller`, a
  # `@sql_base_scope` ivar and a thread-local. Those sources were how a tag got a scope
  # before T-07 and are deleted with the module. The examples whose SUBJECT was that
  # resolution went with it (listed in the deletion's commit message); everything else
  # merely used one of them to hand the tag a scope, and needs only this.
  #
  # `actor:` is mandatory and that is INV-1 working: a context cannot exist without a
  # named viewer, so a spec cannot accidentally assert against an ambient one.
  # A memoised METHOD, not a constant. `SPEC_ACTOR = ...` inside an `RSpec.describe` block
  # defines **`Object::SPEC_ACTOR`** for the whole process — the block's lexical scope is
  # the file's top level — so the first draft of S-30 gave this file and
  # `liquid_version_rollup_tag_spec.rb` one shared actor and Ruby printed
  # *"already initialized constant SPEC_ACTOR"*. Both suites still passed, because the two
  # Structs happened to be equivalent: a collision that passes is the version of this bug
  # HANDOVER §1 says costs a session.
  def spec_actor
    @spec_actor ||= Struct.new(:id, :login).new(1, 'spec-actor').freeze
  end

  def owned_registers(scope: nil, query: nil, source: :issues)
    context = RedmineReporterDashboards::Liquid::RenderContext.new(
      actor: spec_actor, scope: scope, query: query, source: source
    )
    { RedmineReporterDashboards::Liquid::RenderContext::REGISTER_KEY => context }
  end

  # The common case: a query stub that answers `base_scope`, exactly as `IssueQuery` does.
  # The context carries BOTH, because that is what production carries — the aggregation
  # reads the scope and the drill-through URLs read the query, and one object answering
  # both is what keeps them consistent.
  def owned_query_registers(query, source: :issues)
    owned_registers(scope: query.base_scope, query: query, source: source)
  end

  # ------------------------------------------------------------------
  # Scope resolution via `from: issues` (IssuesDrop path)
  # ------------------------------------------------------------------

  # ====================================================================================
  # S-30 · WHAT WAS DELETED HERE, AND WHAT COVERAGE WENT WITH IT
  # ====================================================================================
  #
  # Four describe blocks stood here and are gone with
  # `Glue::Legacy::ScopeResolution`. Their subject was HOW A TAG FINDS A SCOPE when the
  # render supplied no `RenderContext` — six sources, tried in order. After T-26a there is
  # no such render: every widget, preview, schedule, share and mail render constructs a
  # context from an explicit actor, and `ScopeBinding#bind` returns `render_context.scope`
  # without consulting any of them. So these examples asserted the behaviour of code that
  # no longer exists, and they could not be ported — there is nothing to port them ONTO.
  #
  # Deleted, with what each covered:
  #
  #   * `scope resolution from issues drop` (4) — an `issues` assign holding a drop with an
  #     `@issues` ivar. The `from:` parameter selected which assign to read. **THREE OF THE
  #     FOUR WERE HARNESS, NOT SUBJECT**, and deleting them lost real coverage: the
  #     `assign_to` default and the empty-string return are restored under
  #     `parameter parsing`, after a review caught it and a mutation confirmed it
  #     (`default: 'stats'` → `'MUTANT'` left the whole suite green).
  #   * `scope resolution from context registers` (7) — `:sql_issue_query`, `:container`
  #     and `:controller`, and the PRECEDENCE between them.
  #   * `scope resolution from drop @sql_base_scope ivar` (1) — the base plugin's
  #     "Strategy A" patch, which set that ivar on its own drop.
  #   * `a scope resolved from a drop` (5) — `enforce_visibility`: a drop-resolved scope was
  #     intersected with `Issue.visible(User.current)`, because a drop could hand over any
  #     relation at all. Two of its examples covered the register and query_id paths NOT
  #     doing that, which is finding F-2.
  #   * `#resolve_query` (19) — resolving an `IssueQuery` for drill-through from the same
  #     six sources plus a thread-local the base plugin's patch set.
  #   * `a scope over a table this kernel does not count` (1) — "the legacy path carries no
  #     source at all", a case that cannot arise without a context-less producer.
  #   * `drill: true > the query source` (1) — the thread-local as a query source.
  #
  # **38 examples, and that total is COUNTED FROM THE DIFF rather than estimated.** The
  # first version of this list said 32 and named two blocks at the wrong size (10 and 12
  # against a real 7 and 19). A justification artefact that does not add up is not a
  # justification, and this one is the whole argument for the deletion — so it is
  # reconciled: 206 `it` blocks before, 170 after, minus the 2 restored above = 38 gone.
  #
  # NONE OF THIS IS A VISIBILITY REGRESSION, and that is the load-bearing claim.
  # `enforce_visibility` existed because a legacy source could produce an arbitrary
  # relation. An owned context cannot: it is built with an explicit `actor:` (INV-1 —
  # the constructor refuses nil) and its scope is produced by `ReportScope.build` from
  # that actor's own visible scope. The intersection is not removed, it moved upstream and
  # became unconditional. `test/unit/multi_actor_visibility_test.rb` is where that is
  # asserted against a real `Role#issues_visibility` and a real private issue, which is
  # something no DB-less example here could ever have done.
  #
  # WHAT IS KEPT, pointed at the owned path instead: `query_id:` resolution, which is a
  # live feature (`ScopeBinding#from_query_id`) and is covered under
  # `scope resolution from query_id` below; and the tag's own behaviour with a scope in
  # hand, which is every other describe block in this file and now gets its scope from
  # `owned_registers`.
  #
  # `spec/golden/scope/scope.jsonl` — the frozen oracle recording what the six sources
  # answered — SURVIVES this deletion untouched. It is the one artefact in this repository
  # that cannot be regenerated, and it stays as the record of the behaviour that was here.

  # ------------------------------------------------------------------
  # Scope resolution via query_id
  # ------------------------------------------------------------------

  describe 'scope resolution from query_id' do
    before do
      LiquidTagIssueQueryStub.register(42, scope)
    end

    it 'finds the IssueQuery by id and uses base_scope' do
      ctx = build_context({}, owned_registers)
      tag = build_tag('query_id: 42, periods: 6, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate).with(scope, anything).and_return(agg_result)

      tag.render(ctx)
    end

    it 'resolves query_id from Liquid context when it is a variable' do
      ctx = build_context({ 'my_qid' => 42 }, owned_registers)
      tag = build_tag('query_id: my_qid, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate).with(scope, anything).and_return(agg_result)

      tag.render(ctx)
    end

    it 'assigns empty result when query_id is not found' do
      ctx = build_context({}, owned_registers)
      tag = build_tag('query_id: 999, assign_to: stats')

      tag.render(ctx)

      expect(ctx.scopes.last['stats']['total']).to eq(0)
    end

    # S-30 CHANGED WHAT THIS ASSERTS, AND THE CHANGE IS THE POINT. It used to expect
    # `User.current` — the ambient actor, which is all the legacy path had. The owned path
    # passes `render_context.actor`, so the visibility lookup is made as the NAMED viewer.
    # That is INV-1 holding one level deeper, and asserting the old value here would now be
    # asserting the defect.
    it 'looks the query up as the owning context\'s actor, not the ambient user' do
      build_tag('query_id: 42, assign_to: stats').render(build_context({}, owned_registers))

      expect(LiquidTagIssueQueryStub.visible_args).to eq([spec_actor])
      expect(LiquidTagIssueQueryStub.visible_args).not_to eq([User.current])
    end

    it 'assigns the empty result for a query the user may not see' do
      # visible(...) returns a relation that simply does not contain the id.
      allow(LiquidTagIssueQueryStub).to receive(:visible).and_return(
        Class.new { def self.find_by(id:); nil; end }
      )
      expect(SqlAggregation::QueryAggregator).not_to receive(:aggregate)

      ctx = build_context({}, owned_registers)
      build_tag('query_id: 42, assign_to: stats').render(ctx)

      expect(ctx.scopes.last['stats']['total']).to eq(0)
    end

    it 'logs why an invisible query was skipped' do
      allow(LiquidTagIssueQueryStub).to receive(:visible).and_return(
        Class.new { def self.find_by(id:); nil; end }
      )
      allow(Rails.logger).to receive(:warn) # the tag also logs "no scope resolved"
      expect(Rails.logger).to receive(:warn).with(/does not exist or is not visible to this actor/)

      build_tag('query_id: 42, assign_to: stats').render(build_context({}, owned_registers))
    end
  end

  # ------------------------------------------------------------------
  # T-31 / §Findings S-13 — this kernel counts issues, so a time-entry scope is DISPATCHED
  # ------------------------------------------------------------------
  #
  # INCREMENT 1 REFUSED HERE; INCREMENT 2 DISPATCHES. The refusal was never the goal — it was
  # the safe half of the fix, shipped first because answering with the issue kernel is the
  # defect. What has not changed, and is what every example below is really about, is that
  # `QueryAggregator` NEVER SEES A TIME-ENTRY SCOPE. What has changed is where it goes
  # instead: `Aggregation::TimeEntryAggregator`, which counts time entries and sums hours.
  #
  # The measurement that forced this: handed a `TimeEntryQuery#base_scope`, the aggregator
  # does NOT raise. That query calls `.left_join_issue`, so every issue column resolves and
  # the tag answers `COUNT(DISTINCT issues.id)` under time-entry labels — four time entries
  # over two issues came back as `2` in every bucket, and `spent_hours` answered nil. A
  # wrong number under a right heading is the outcome this whole guard exists to prevent.
  describe 'a scope over a table this kernel does not count' do
    # THE ACTOR IS A NAMED OBJECT, so an example can assert the tag handed THAT one to the
    # aggregator. `Object.new` inline made the actor unassertable, and a mutation replacing
    # `actor: render_context&.actor` with `actor: nil` stayed green — which is the wiring the
    # `issue` dimension's visibility scoping depends on entirely.
    let(:the_actor) { Object.new }

    def owned_context(source)
      render_context = RedmineReporterDashboards::Liquid::RenderContext.new(
        actor: the_actor, scope: scope, source: source
      )
      build_context({}, { RedmineReporterDashboards::Liquid::RenderContext::REGISTER_KEY =>
                          render_context })
    end

    def codes(ctx)
      render_context = ctx.registers[RedmineReporterDashboards::Liquid::RenderContext::REGISTER_KEY]
      # `to_a` answers Hashes — that is the serialised form the diagnostics panel reads, so
      # asserting on it is asserting on what a reader actually sees.
      render_context.diagnostics.to_a.map { |d| (d['code'] || d[:code]).to_s }
    end

    # THE INVARIANT THAT SURVIVED BOTH INCREMENTS. `QueryAggregator` counts
    # `DISTINCT issues.id`; it must not be handed a relation over another table under any
    # markup, with or without a dimension.
    it 'never reaches the issue kernel when the scope is over time entries' do
      expect(SqlAggregation::QueryAggregator).not_to receive(:aggregate)
      expect(SqlAggregation::QueryAggregator).not_to receive(:breakdown)
      expect(SqlAggregation::QueryAggregator).not_to receive(:dimension_breakdown)
      allow(RedmineReporterDashboards::Aggregation::TimeEntryAggregator)
        .to receive(:breakdown).and_return(dimension_result)

      build_tag('assign_to: stats').render(owned_context(:time_entries))
      build_tag('group_by: activity, assign_to: stats').render(owned_context(:time_entries))
    end

    # AND IT GOES TO THE OWNED AGGREGATOR, with the tag's arguments translated. Asserted on
    # the CALL and not only on the assignment: a dispatch that dropped `measure` would still
    # assign a plausible result.
    it 'dispatches a dimensioned aggregation to the time-entry aggregator' do
      ctx = owned_context(:time_entries)
      expect(RedmineReporterDashboards::Aggregation::TimeEntryAggregator)
        .to receive(:breakdown)
        .with(scope, hash_including(group_by: 'activity', measure: 'count', limit: 5,
                                    sort: 'label'))
        .and_return(dimension_result)

      build_tag('group_by: activity, measure: count, sort: label, limit: 5, assign_to: stats')
        .render(ctx)

      expect(ctx.scopes.last['stats']).to eq(dimension_result)
    end

    # THE ACTOR IS CARRIED, EXPLICITLY (INV-1). The aggregator needs it to scope the `issue`
    # dimension's labels by visibility, and `actor: nil` there means it withholds them — so a
    # dispatch that dropped the actor would silently stop labelling issues on every report.
    # MUTATION-TESTED: replacing it with `nil` left the whole suite green before this.
    it 'hands the render context\'s own actor to the aggregator' do
      expect(RedmineReporterDashboards::Aggregation::TimeEntryAggregator)
        .to receive(:breakdown).with(scope, hash_including(actor: the_actor))
        .and_return(dimension_result)

      build_tag('group_by: activity, assign_to: stats').render(owned_context(:time_entries))
    end

    # AND THE DEFAULTS ARE THE AGGREGATOR'S OWN, not a second copy the two can disagree
    # about. `limit: 0` in particular is "the author set none", which the aggregator answers
    # with its 200-bucket ceiling; a tag that substituted its own number would move the
    # ceiling without touching the module that documents it.
    it 'passes the aggregator\'s own defaults when the markup names none' do
      aggregator = RedmineReporterDashboards::Aggregation::TimeEntryAggregator
      expect(aggregator)
        .to receive(:breakdown)
        .with(scope, hash_including(measure: aggregator::DEFAULT_MEASURE,
                                    sort: aggregator::DEFAULT_SORT,
                                    limit: aggregator::DEFAULT_LIMIT,
                                    other_label: aggregator::DEFAULT_OTHER_LABEL,
                                    empty_label: nil))
        .and_return(dimension_result)

      build_tag('group_by: activity, assign_to: stats').render(owned_context(:time_entries))
    end

    # AN ARGUMENT THE TIME-ENTRY PATH CANNOT HONOUR IS NAMED, not dropped. An independent
    # review measured `drill: true` and `split_by:` vanishing in silence — no `bucket.url`, no
    # crosstab, nothing on the page — against a README that promised drill-through.
    %w[split_by period periods drill age_buckets of fields].each do |param|
      it "degrades visibly on #{param}, which it cannot use" do
        ctx = owned_context(:time_entries)
        allow(RedmineReporterDashboards::Aggregation::TimeEntryAggregator)
          .to receive(:breakdown).and_return(dimension_result)

        build_tag("group_by: activity, #{param}: x, assign_to: stats").render(ctx)

        expect(codes(ctx)).to include('aggregation_params_unsupported')
      end
    end

    it 'names WHICH arguments, so the author can remove them' do
      ctx = owned_context(:time_entries)
      allow(RedmineReporterDashboards::Aggregation::TimeEntryAggregator)
        .to receive(:breakdown).and_return(dimension_result)

      build_tag('group_by: activity, split_by: user, drill: true, assign_to: stats').render(ctx)

      recorded = ctx.registers[RedmineReporterDashboards::Liquid::RenderContext::REGISTER_KEY]
                    .diagnostics.to_a.to_s
      expect(recorded).to include('split_by')
      expect(recorded).to include('drill')
    end

    # `empty_label:` AND `logger:` ARE CARRIED. Both were surviving mutations, and both are
    # small on purpose: `empty_label` is the only way an author renames the unclassified
    # bucket, and the logger is the half of a refusal that reaches whoever is on call rather
    # than whoever is authoring. Asserted on the CALL, because a renamed bucket and a missing
    # log line are invisible in a result.
    it 'carries the author\'s own empty_label and a real logger' do
      expect(RedmineReporterDashboards::Aggregation::TimeEntryAggregator)
        .to receive(:breakdown)
        .with(scope, hash_including(empty_label: 'unclassified', logger: Rails.logger))
        .and_return(dimension_result)

      build_tag('group_by: activity, empty_label: unclassified, assign_to: stats')
        .render(owned_context(:time_entries))
    end

    it 'says nothing when every argument is one it can use' do
      ctx = owned_context(:time_entries)
      allow(RedmineReporterDashboards::Aggregation::TimeEntryAggregator)
        .to receive(:breakdown).and_return(dimension_result)

      build_tag('group_by: activity, measure: count, sort: label, limit: 5, ' \
                'other_label: rest, empty_label: none, assign_to: stats').render(ctx)

      expect(codes(ctx)).to eq([])
    end

    # AND THE ISSUE PATH IS UNTOUCHED BY ALL OF IT: `drill:` and `split_by:` are real there.
    it 'does not degrade those arguments on an issue-source template' do
      ctx = owned_context(:issues)
      allow(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
        .and_return(dimension_result)

      build_tag('group_by: status, split_by: tracker, assign_to: stats').render(ctx)

      expect(codes(ctx)).to eq([])
    end

    # A TIME-ENTRY AGGREGATION WITH NO DIMENSION IS STILL A REFUSAL. There is no time-entry
    # equivalent of `aggregate`'s created/closed flow — a time entry is not opened and closed
    # — so a tag with no dimension has nothing to ask for.
    it 'assigns the empty result rather than leaving the variable undefined' do
      ctx = owned_context(:time_entries)
      build_tag('assign_to: stats').render(ctx)

      expect(ctx.scopes.last['stats']).to eq(described_class.new('sql_aggregate', '', nil)
                                                            .send(:empty_result))
    end

    # VISIBLE, NOT SILENT (INV-4). A template that renders nothing and says nothing is the
    # same defect one layer up: the author has no way to learn why their figures are blank.
    # The code is NARROWER than increment 1's `aggregation_source_unsupported`, and that is
    # the improvement — the source is supported now; the ARGUMENT is what is missing.
    it 'records a degradation naming the argument it needs' do
      ctx = owned_context(:time_entries)
      build_tag('assign_to: stats').render(ctx)

      expect(codes(ctx)).to include('aggregation_group_by_required')
      expect(ctx.registers[RedmineReporterDashboards::Liquid::RenderContext::REGISTER_KEY]
               .diagnostics.to_a.to_s).to include('time_entries')
    end

    # AND THE AGGREGATOR'S OWN REFUSALS REACH THE AUTHOR TOO. MUTATION-TESTED and this is
    # why it exists: replacing the `diagnostics:` argument with `nil` left every other
    # example green, so the wiring that carries a mistyped `group_by` back to the page was
    # provably dead. `activty` is refused by the module, not by the tag — a different layer,
    # the same author, one panel (INV-4).
    it 'carries the aggregator\'s own refusal back to the author' do
      ctx = owned_context(:time_entries)

      build_tag('group_by: activty, assign_to: stats').render(ctx)

      expect(codes(ctx)).to include('aggregation_dimension_unknown')
      expect(ctx.scopes.last['stats']).to eq(described_class.new('sql_aggregate', '', nil)
                                                            .send(:empty_result))
    end

    it 'carries a refused MEASURE back too, which is a different code' do
      ctx = owned_context(:time_entries)

      build_tag('group_by: activity, measure: median, assign_to: stats').render(ctx)

      expect(codes(ctx)).to include('aggregation_measure_unknown')
    end

    # AND A SOURCE WITH NO AGGREGATOR AT ALL STILL FAILS CLOSED. Unreachable through
    # `RenderContext` today, whose `SOURCES` is a closed set of two — which is exactly why it
    # is driven here through `report_source`: §7 rule 5 makes "an install one minor behind
    # reading a newer row" routine, and the third source must land on the empty result and a
    # degradation rather than on whichever aggregator happens to be last in the method.
    it 'refuses a source it has no aggregator for, visibly' do
      ctx = owned_context(:time_entries)
      allow(RedmineReporterDashboards::Liquid::ScopeBinding)
        .to receive(:report_source).and_return(:invoices)

      build_tag('group_by: activity, assign_to: stats').render(ctx)

      expect(ctx.scopes.last['stats']).to eq(described_class.new('sql_aggregate', '', nil)
                                                            .send(:empty_result))
      expect(codes(ctx)).to include('aggregation_source_unsupported')
    end

    # AND THE ISSUE PATH IS UNTOUCHED. Without this the guard could be refusing
    # everything and all three examples above would still pass.
    it 'aggregates normally when the very same scope is declared as issues' do
      expect(SqlAggregation::QueryAggregator).to receive(:aggregate).and_return(agg_result)

      build_tag('assign_to: stats').render(owned_context(:issues))
    end

    # S-30 DELETED the example that sat here: *"aggregates on the legacy path, which
    # carries no source at all"*. `source` is the T-31 field naming which TABLE a scope is
    # over, and its whole point was that the legacy path predates it and therefore carries
    # none — the tag had to treat "no context" as "issues". There is no context-less render
    # any more, so the case cannot arise; `report_source` still defaults to `:issues` when
    # a context does not name one, and the two examples above cover that.
  end

  # ------------------------------------------------------------------
  # Scope resolution via context.registers (fast path in production)
  # ------------------------------------------------------------------

  # ------------------------------------------------------------------
  # Scope resolution via drop ivar inspection (@sql_base_scope patch path)
  # ------------------------------------------------------------------

  # ------------------------------------------------------------------
  # Parameter parsing
  # ------------------------------------------------------------------

  describe 'parameter parsing' do
    let(:drop) do
      obj = Object.new
      obj.instance_variable_set(:@issues, scope)
      obj
    end

    # --- S-30 RESTORED THIS, AND IT WAS A REAL LOSS ------------------------------------
    #
    # `assign_to` defaults to `'stats'`, and the example covering that lived in the
    # `scope resolution from issues drop` block — which S-30 deleted whole, on the stated
    # ground that every example in it had the deleted resolution as its SUBJECT. Three of
    # its four did not: they were about the TAG and merely used the drop as a harness.
    #
    # An independent review caught it and MUTATION CONFIRMED it: changing
    # `default: 'stats'` to `default: 'MUTANT'` in `liquid_aggregate_tag.rb:149` left
    # 2872 examples, 0 failures. Every markup string in this file carries an explicit
    # `assign_to:`, so nothing else could see it. A legacy template that omits the
    # parameter writes into `''` and renders nothing, silently.
    it 'defaults assign_to to "stats" when the parameter is omitted' do
      ctx = build_context({}, owned_registers(scope: scope))
      allow(SqlAggregation::QueryAggregator).to receive(:aggregate).and_return(agg_result)

      build_tag('from: issues').render(ctx)

      expect(ctx.scopes.last).to have_key('stats')
    end

    # The side-effect contract, also lost with that block: the tag ASSIGNS and emits
    # nothing, so `{% sql_aggregate %}` on its own line leaves no stray output.
    it 'returns an empty string, so no output appears in the template' do
      ctx = build_context({}, owned_registers(scope: scope))
      allow(SqlAggregation::QueryAggregator).to receive(:aggregate).and_return(agg_result)

      expect(build_tag('from: issues').render(ctx)).to eq('')
    end

    it 'parses period as a string' do
      ctx = build_context({}, owned_registers(scope: scope))
      tag = build_tag('from: issues, period: week, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(scope, hash_including(period: 'week'))
        .and_return(agg_result)

      tag.render(ctx)
    end

    it 'defaults period to month when omitted' do
      ctx = build_context({}, owned_registers(scope: scope))
      tag = build_tag('from: issues, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(scope, hash_including(period: 'month'))
        .and_return(agg_result)

      tag.render(ctx)
    end

    it 'passes period: day correctly' do
      ctx = build_context({}, owned_registers(scope: scope))
      tag = build_tag('from: issues, period: day, periods: 30, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(scope, hash_including(period: 'day', periods: 30))
        .and_return(agg_result)

      tag.render(ctx)
    end

    it 'passes period: year correctly' do
      ctx = build_context({}, owned_registers(scope: scope))
      tag = build_tag('from: issues, period: year, periods: 3, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(scope, hash_including(period: 'year', periods: 3))
        .and_return(agg_result)

      tag.render(ctx)
    end

    it 'parses periods as an integer' do
      ctx = build_context({}, owned_registers(scope: scope))
      tag = build_tag('from: issues, period: month, periods: 12, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(scope, hash_including(periods: 12))
        .and_return(agg_result)

      tag.render(ctx)
    end

    it 'passes nil periods when omitted (letting aggregator use default)' do
      ctx = build_context({}, owned_registers(scope: scope))
      tag = build_tag('from: issues, period: month, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(scope, hash_including(periods: nil))
        .and_return(agg_result)

      tag.render(ctx)
    end

    it 'accepts legacy months param as alias for periods when period is month' do
      ctx = build_context({}, owned_registers(scope: scope))
      tag = build_tag('from: issues, months: 12, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(scope, hash_including(periods: 12, period: 'month'))
        .and_return(agg_result)

      tag.render(ctx)
    end

    it 'parses closed_statuses from double-quoted string' do
      ctx = build_context({}, owned_registers(scope: scope))
      tag = build_tag('from: issues, closed_statuses: "Closed;Rejected", assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(scope, hash_including(closed_statuses: ['Closed', 'Rejected']))
        .and_return(agg_result)

      tag.render(ctx)
    end

    it 'parses closed_statuses from single-quoted string' do
      ctx = build_context({}, owned_registers(scope: scope))
      tag = build_tag("from: issues, closed_statuses: 'Closed,Done', assign_to: stats")

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate)
        .with(scope, hash_including(closed_statuses: ['Closed', 'Done']))
        .and_return(agg_result)

      tag.render(ctx)
    end

    it 'passes empty closed_statuses when omitted' do
      ctx = build_context({}, owned_registers(scope: scope))
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
      ctx = build_context({}, owned_registers(scope: scope))
      tag = build_tag('from: issues, group_by: tracker, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:breakdown)
        .with(scope, group_by: 'tracker')
        .and_return(breakdown_result)

      tag.render(ctx)
    end

    it 'does NOT call aggregate when group_by is present' do
      ctx = build_context({}, owned_registers(scope: scope))
      tag = build_tag('from: issues, group_by: status, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).not_to receive(:aggregate)
      expect(SqlAggregation::QueryAggregator).to receive(:breakdown).and_return(breakdown_result)

      tag.render(ctx)
    end

    it 'assigns breakdown result to context variable' do
      ctx = build_context({}, owned_registers(scope: scope))
      tag = build_tag('from: issues, group_by: tracker, assign_to: by_tracker')

      tag.render(ctx)

      expect(ctx.scopes.last['by_tracker']).to eq(breakdown_result)
    end

    it 'passes group_by: status correctly' do
      ctx = build_context({}, owned_registers(scope: scope))
      tag = build_tag('from: issues, group_by: status, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:breakdown)
        .with(scope, group_by: 'status')
        .and_return(breakdown_result)

      tag.render(ctx)
    end

    it 'passes group_by: priority correctly' do
      ctx = build_context({}, owned_registers(scope: scope))
      tag = build_tag('from: issues, group_by: priority, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:breakdown)
        .with(scope, group_by: 'priority')
        .and_return(breakdown_result)

      tag.render(ctx)
    end

    it 'passes group_by: assignee correctly' do
      ctx = build_context({}, owned_registers(scope: scope))
      tag = build_tag('from: issues, group_by: assignee, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:breakdown)
        .with(scope, group_by: 'assignee')
        .and_return(breakdown_result)

      tag.render(ctx)
    end

    it 'uses aggregate (not breakdown) when group_by is absent' do
      ctx = build_context({}, owned_registers(scope: scope))
      tag = build_tag('from: issues, period: month, periods: 6, assign_to: stats')

      expect(SqlAggregation::QueryAggregator).to receive(:aggregate).and_return(agg_result)
      expect(SqlAggregation::QueryAggregator).not_to receive(:breakdown)

      tag.render(ctx)
    end

    it 'assigns empty result and returns blank when breakdown raises' do
      allow(SqlAggregation::QueryAggregator).to receive(:breakdown).and_raise(StandardError, 'oops')

      ctx = build_context({}, owned_registers(scope: scope))
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

    # S-30: the scope arrives through the owned context, not through an `issues` drop.
    # `from: issues` stays in the markup because these examples are about the OTHER
    # parameters; on an owned render it selects nothing, which is what the README already
    # documents for a time-entry template and is true of every render since T-26a.
    def render(markup, assigns = {})
      ctx = build_context(assigns, owned_registers(scope: scope))
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
        ctx = build_context({}, owned_registers(scope: scope))
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

        ctx = build_context({}, owned_registers(scope: scope))
        expect(build_tag('from: issues, group_by: cf_0, assign_to: stats').render(ctx)).to eq('')
      end

      it 'never raises when the dimension aggregation blows up' do
        allow(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown).and_raise(StandardError, 'boom')

        ctx = build_context({}, owned_registers(scope: scope))
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

    # S-30: the scope arrives through the owned context, not through an `issues` drop.
    # `from: issues` stays in the markup because these examples are about the OTHER
    # parameters; on an owned render it selects nothing, which is what the README already
    # documents for a time-entry template and is true of every render since T-26a.
    def render(markup, assigns = {})
      ctx = build_context(assigns, owned_registers(scope: scope))
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
        ctx = build_context({}, owned_query_registers(query))
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

    # S-30: see the note on the identical helper above — owned context, not a drop.
    def render(markup)
      ctx = build_context({}, owned_registers(scope: scope))
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
      ctx = build_context({ 'm' => 'distinct' }, owned_registers(scope: scope))
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


  # ------------------------------------------------------------------
  # IssueQuery resolution (drill-through prerequisite)
  # ------------------------------------------------------------------


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

    # The context holds the query; the same object answers base_scope, so the
    # aggregation and the URLs come from one source, exactly as in production.
    def render(markup, result: dimension_with_filters, registers: nil)
      allow(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown).and_return(result)
      allow(SqlAggregation::QueryAggregator).to receive(:flags).and_return(result)
      ctx = build_context({}, registers.nil? ? owned_query_registers(query) : registers)
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

        ctx = build_context({}, owned_query_registers(query))
        build_tag('group_by: status, drill: true, assign_to: stats').render(ctx)
      end

      it 'keeps the legacy breakdown path for a falsy drill' do
        expect(SqlAggregation::QueryAggregator).to receive(:breakdown).and_return(breakdown_result)
        expect(SqlAggregation::QueryAggregator).not_to receive(:dimension_breakdown)

        ctx = build_context({}, owned_query_registers(query))
        build_tag('group_by: status, drill: false, assign_to: stats').render(ctx)
      end

      it 'accepts drill given as a Liquid boolean variable' do
        allow(SqlAggregation::QueryAggregator).to receive(:dimension_breakdown)
          .and_return(dimension_with_filters)
        ctx = build_context({ 'enabled' => true }, owned_query_registers(query))
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

        first = build_context({ 'enabled' => true }, owned_query_registers(query))
        tag.render(first)
        second = build_context({ 'enabled' => false }, owned_query_registers(query))
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
               registers: owned_registers(scope: scope))
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
        render('group_by: cf_92, drill: true, assign_to: stats',
               registers: owned_registers(scope: scope))
      end
    end

    describe 'the time series' do
      it 'reports drill-through as unavailable and points at group_by: period' do
        expect(Rails.logger).to receive(:warn).with(/use group_by: period/)
        ctx = build_context({}, owned_query_registers(query))
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

        ctx = build_context({}, owned_query_registers(query))
        build_tag('query_id: 42, group_by: cf_92, drill: true, assign_to: stats').render(ctx)

        expect(ctx.scopes.last['stats']['base_url']).to include('/projects/other/issues')
      end

      # S-30 DELETED the example that sat here: *"uses the thread-local when nothing else
      # holds a query"*. The base plugin's list patch set a thread-local so its own
      # `IssueQuery` could reach a Liquid tag that had no other channel to it — the whole
      # reason `no_thread_local.sh` carried two exemptions. Nothing sets that key now, and
      # an owned context carries the query as a field, which is the example above.
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
        ctx = build_context({}, owned_query_registers(query))
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
      ctx = build_context({}, owned_registers(scope: scope))
      build_tag('from: issues, assign_to: stats').render(ctx)
      expect(ctx.scopes.last['stats']).to eq(agg_result)
    end

    it 'returns the legacy core-field breakdown unchanged' do
      ctx = build_context({}, owned_registers(scope: scope))
      build_tag('from: issues, group_by: tracker, assign_to: stats').render(ctx)
      expect(ctx.scopes.last['stats']).to eq(breakdown_result)
    end

    it 'returns the dimension result unchanged' do
      ctx = build_context({}, owned_registers(scope: scope))
      build_tag('from: issues, group_by: cf_92, assign_to: stats').render(ctx)
      expect(ctx.scopes.last['stats']).to eq(dimension_result)
    end

    it 'returns the flags result unchanged' do
      ctx = build_context({}, owned_registers(scope: scope))
      build_tag('from: issues, group_by: flags, assign_to: kpi').render(ctx)
      expect(ctx.scopes.last['kpi']).to eq(flags_result)
    end

    it 'never resolves an IssueQuery for the URLs' do
      ctx = build_context({}, owned_registers(scope: scope))
      tag = build_tag('from: issues, group_by: cf_92, assign_to: stats')
      expect(tag).not_to receive(:resolve_query)
      tag.render(ctx)
    end

    it 'never builds a drill-through builder' do
      expect(SqlAggregation::DrillThrough).not_to receive(:build)
      ctx = build_context({}, owned_registers(scope: scope))
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

      ctx = build_context({}, owned_registers(scope: scope))
      tag = build_tag('from: issues, assign_to: stats')

      expect { tag.render(ctx) }.not_to raise_error
      expect(ctx.scopes.last['stats']['total']).to eq(0)
    end
  end
end
