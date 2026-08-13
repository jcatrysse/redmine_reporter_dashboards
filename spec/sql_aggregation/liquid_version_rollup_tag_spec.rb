# frozen_string_literal: true

require 'logger'
require 'active_support'
require 'active_support/core_ext/enumerable' # index_by
require_relative '../spec_helper'

unless defined?(Rails)
  module Rails
    def self.logger
      @logger ||= Logger.new(File::NULL)
    end
  end
end

# Minimal Setting stub — VersionDrop reads it lazily when a url method is called
# (the tag only instantiates the drop, so this is just a safety net).
unless defined?(Setting)
  class Setting
    def self.protocol
      'https'
    end

    def self.host_name
      'redmine.test'
    end
  end
end

# `User.current` — needed since T-20, and its absence is the whole reason this comment
# exists. `Drops::VersionDrop` refuses a nil RenderContext (INV-1), so the tag now asks
# `Liquid::TagContext` for one, and on the legacy path that reads `User.current`. Redmine
# always defines it; a DB-less spec process does not, and the tag's rescue turned the
# resulting NameError into an EMPTY row list — a degradation that looks exactly like an
# aggregation returning nothing. Worth knowing before diagnosing an empty rollup.
class RollupTagUser
  def self.current
    @current ||= Object.new
  end
end

require_relative '../../lib/redmine_reporter_dashboards/aggregation/query_aggregator'
require_relative '../../lib/sql_aggregation/liquid_version_rollup_tag'
# S-30: the legacy resolution module is DELETED. These examples build every context
# from an owned `RenderContext` (see `owned_registers` below), which is how every render
# has been constructed since T-26a, so there is nothing left to require here.

# AR-scope stub that satisfies ar_scope? (where/group/count).
class RollupTagScope
  def where(*)
    self
  end

  def group(*)
    self
  end

  def count
    0
  end
end

# Version model stub: Version.where(id:).includes(:project).index_by(&:id)
class RollupTagVersion
  Ver = Struct.new(:id, :name, :project, :effective_date, :status)
  class << self
    attr_accessor :registry

    def where(id:)
      @filtered = Array(id).map { |i| registry[i] }.compact
      self
    end

    def includes(*)
      self
    end

    def index_by(&blk)
      @filtered.index_by(&blk)
    end
  end
end

RSpec.describe SqlAggregation::LiquidVersionRollupTag do
  let(:scope) { RollupTagScope.new }
  let(:rollup_rows) do
    [
      { 'version_id' => 2, 'total' => 2, 'open' => 2, 'closed' => 0, 'cost' => {} },
      { 'version_id' => 1, 'total' => 4, 'open' => 3, 'closed' => 1, 'cost' => { '20' => 30_000.0 } },
      { 'version_id' => nil, 'total' => 1, 'open' => 1, 'closed' => 0, 'cost' => {} }
    ]
  end

  before do
    stub_const('Version', RollupTagVersion)
    stub_const('User', RollupTagUser)
    RollupTagVersion.registry = {
      1 => RollupTagVersion::Ver.new(1, 'Beta 2.0', nil, nil, 'open'),
      2 => RollupTagVersion::Ver.new(2, 'Alpha 1.0', nil, nil, 'open')
    }
    allow(SqlAggregation::QueryAggregator).to receive(:version_rollup).and_return(rollup_rows)
  end

  def build_tag(markup)
    described_class.new('version_rollup', markup, [])
  end

  def build_context(assigns = {}, registers = {})
    Liquid::Context.new({}, assigns, registers)
  end

  # --- S-30 · THE OWNED HARNESS -------------------------------------------------------
  #
  # These examples used to hand the tag a scope through an `issues` drop, one of the six
  # sources `Glue::Legacy::ScopeResolution` resolved. That module is deleted, so the scope
  # arrives the way every production render has supplied it since T-26a: an explicit
  # `RenderContext` in the registers. `actor:` is mandatory, which is INV-1 working.
  SPEC_ACTOR = Struct.new(:id, :login).new(1, 'spec-actor').freeze

  def owned_registers(scope: nil)
    context = RedmineReporterDashboards::Liquid::RenderContext.new(
      actor: SPEC_ACTOR, scope: scope
    )
    { RedmineReporterDashboards::Liquid::RenderContext::REGISTER_KEY => context }
  end

  describe 'aggregation + decoration' do
    it 'assigns the rows to the default variable "versions"' do
      ctx = build_context({}, owned_registers(scope: scope))
      build_tag('from: issues').render(ctx)
      expect(ctx.scopes.last['versions']).to be_an(Array)
    end

    it 'decorates each row with a version name (None for a nil version_id)' do
      ctx = build_context({}, owned_registers(scope: scope))
      build_tag('from: issues, assign_to: versions').render(ctx)
      names = ctx.scopes.last['versions'].map { |r| r['name'] }
      expect(names).to eq(['Alpha 1.0', 'Beta 2.0', 'None']) # sorted case-insensitively
    end

    # T-20 changed the CLASS behind `row['version']` from the addon's own drop to the
    # owned `Drops::VersionDrop`. Asserted by class, because the accessor set is what a
    # template sees and the two answer the same names — a duck-typed assertion would
    # have passed the deleted class just as happily.
    it 'attaches the owned VersionDrop for real versions and nil for the None bucket' do
      ctx = build_context({}, owned_registers(scope: scope))
      build_tag('from: issues').render(ctx)
      rows = ctx.scopes.last['versions']
      real = rows.find { |r| r['version_id'] == 1 }
      none = rows.find { |r| r['version_id'].nil? }
      expect(real['version']).to be_a(RedmineReporterDashboards::Liquid::Drops::VersionDrop)
      expect(none['version']).to be_nil
    end

    # The accessors a shipped template actually reads off `row.version`
    # (`examples/version_status_dashboard.liquid` uses every one of these). T-20 is a
    # class swap and must not be a vocabulary change; `project_name` and
    # `project_identifier` in particular were only on the addon's drop until this task.
    it 'answers every accessor the retired drop published' do
      ctx = build_context({}, owned_registers(scope: scope))
      build_tag('from: issues').render(ctx)
      drop = ctx.scopes.last['versions'].find { |r| r['version_id'] == 1 }['version']

      expect(drop.name).to eq('Beta 2.0')
      expect(drop.url).to eq('https://redmine.test/versions/1')
      expect(drop.issues_url).to include('status_id=*')
      expect(drop.open_issues_url).to include('status_id=o')
      expect(drop.closed_issues_url).to include('status_id=c')
      expect(drop.time_url).to include('issue.fixed_version_id')
      expect(drop.roadmap_url).to include('/roadmap')
      # nil project on this fixture — the point is that it answers rather than raises.
      expect(drop.project_identifier).to be_nil
      expect(drop.project_name).to be_nil
    end

    # ONE context for the whole decoration, not one per row. Two rows have a version,
    # so a per-row build would read the ambient actor twice and hand out two Batches
    # for one render.
    it 'builds one render context for every row' do
      ctx = build_context({}, owned_registers(scope: scope))
      build_tag('from: issues').render(ctx)
      contexts = ctx.scopes.last['versions'].filter_map { |r| r['version'] }
                    .map { |d| d.instance_variable_get(:@render_context) }

      expect(contexts.length).to eq(2)
      expect(contexts.uniq(&:object_id).length).to eq(1)
    end

    # S-30 DELETED the example that used to sit here: *"renders under the legacy fallback
    # context when no owned renderer supplied one"*. Its subject was the seam itself — a
    # render arriving with NO `RenderContext`, where the actor came from the ambient
    # `User.current` via `TagContext`. There is no such render any more, so the example
    # asserted the behaviour of deleted code.
    #
    # What it was really protecting is INV-1 — that the drop carries an EXPLICIT actor
    # rather than reading an ambient one — and that is kept, pointed at the owned path,
    # by the example below.
    it 'carries the owning context\'s actor into every decorated version drop' do
      ctx = build_context({}, owned_registers(scope: scope))

      expect(RedmineReporterDashboards::Liquid::TagContext).to be_owned(ctx)

      build_tag('from: issues').render(ctx)
      drop = ctx.scopes.last['versions'].find { |r| r['version_id'] == 1 }['version']

      expect(drop.instance_variable_get(:@render_context).actor).to eq(SPEC_ACTOR)
    end

    it 'returns an empty string (side-effect tag)' do
      ctx = build_context({}, owned_registers(scope: scope))
      expect(build_tag('from: issues').render(ctx)).to eq('')
    end
  end

  describe 'parameter parsing' do
    it 'parses closed_statuses and cost_fields and forwards them to the aggregator' do
      ctx = build_context({}, owned_registers(scope: scope))
      expect(SqlAggregation::QueryAggregator).to receive(:version_rollup)
        .with(scope, closed_statuses: ['Closed', 'Rejected'], cost_field_ids: [20, 21])
        .and_return(rollup_rows)
      build_tag('from: issues, closed_statuses: "Closed;Rejected", cost_fields: "20,21"').render(ctx)
    end

    it 'defaults to empty closed_statuses and cost_field_ids' do
      ctx = build_context({}, owned_registers(scope: scope))
      expect(SqlAggregation::QueryAggregator).to receive(:version_rollup)
        .with(scope, closed_statuses: [], cost_field_ids: [])
        .and_return(rollup_rows)
      build_tag('from: issues').render(ctx)
    end

    it 'resolves a custom assign_to variable' do
      ctx = build_context({}, owned_registers(scope: scope))
      build_tag('from: issues, assign_to: my_versions').render(ctx)
      expect(ctx.scopes.last['my_versions']).to be_an(Array)
    end
  end

  describe 'error handling' do
    it 'assigns an empty array when no scope can be resolved' do
      ctx = build_context({}, owned_registers(scope: nil))
      expect { build_tag('from: issues').render(ctx) }.not_to raise_error
      expect(ctx.scopes.last['versions']).to eq([])
    end

    it 'assigns an empty array and does not raise when the aggregator fails' do
      allow(SqlAggregation::QueryAggregator).to receive(:version_rollup).and_raise(StandardError, 'db error')
      ctx = build_context({}, owned_registers(scope: scope))
      expect { build_tag('from: issues').render(ctx) }.not_to raise_error
      expect(ctx.scopes.last['versions']).to eq([])
    end
  end
end
