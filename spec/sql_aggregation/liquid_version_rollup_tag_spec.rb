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

require_relative '../../lib/sql_aggregation/query_aggregator'
require_relative '../../lib/sql_aggregation/liquid_version_rollup_tag'

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

  def drop_with(scope)
    obj = Object.new
    obj.instance_variable_set(:@issues, scope)
    obj
  end

  describe 'aggregation + decoration' do
    it 'assigns the rows to the default variable "versions"' do
      ctx = build_context('issues' => drop_with(scope))
      build_tag('from: issues').render(ctx)
      expect(ctx.scopes.last['versions']).to be_an(Array)
    end

    it 'decorates each row with a version name (None for a nil version_id)' do
      ctx = build_context('issues' => drop_with(scope))
      build_tag('from: issues, assign_to: versions').render(ctx)
      names = ctx.scopes.last['versions'].map { |r| r['name'] }
      expect(names).to eq(['Alpha 1.0', 'Beta 2.0', 'None']) # sorted case-insensitively
    end

    it 'attaches a VersionDrop for real versions and nil for the None bucket' do
      ctx = build_context('issues' => drop_with(scope))
      build_tag('from: issues').render(ctx)
      rows = ctx.scopes.last['versions']
      real = rows.find { |r| r['version_id'] == 1 }
      none = rows.find { |r| r['version_id'].nil? }
      expect(real['version']).to be_a(RedmineReporterDashboards::Liquid::VersionDrop)
      expect(none['version']).to be_nil
    end

    it 'returns an empty string (side-effect tag)' do
      ctx = build_context('issues' => drop_with(scope))
      expect(build_tag('from: issues').render(ctx)).to eq('')
    end
  end

  describe 'parameter parsing' do
    it 'parses closed_statuses and cost_fields and forwards them to the aggregator' do
      ctx = build_context('issues' => drop_with(scope))
      expect(SqlAggregation::QueryAggregator).to receive(:version_rollup)
        .with(scope, closed_statuses: ['Closed', 'Rejected'], cost_field_ids: [20, 21])
        .and_return(rollup_rows)
      build_tag('from: issues, closed_statuses: "Closed;Rejected", cost_fields: "20,21"').render(ctx)
    end

    it 'defaults to empty closed_statuses and cost_field_ids' do
      ctx = build_context('issues' => drop_with(scope))
      expect(SqlAggregation::QueryAggregator).to receive(:version_rollup)
        .with(scope, closed_statuses: [], cost_field_ids: [])
        .and_return(rollup_rows)
      build_tag('from: issues').render(ctx)
    end

    it 'resolves a custom assign_to variable' do
      ctx = build_context('issues' => drop_with(scope))
      build_tag('from: issues, assign_to: my_versions').render(ctx)
      expect(ctx.scopes.last['my_versions']).to be_an(Array)
    end
  end

  describe 'error handling' do
    it 'assigns an empty array when no scope can be resolved' do
      ctx = build_context('issues' => nil)
      expect { build_tag('from: issues').render(ctx) }.not_to raise_error
      expect(ctx.scopes.last['versions']).to eq([])
    end

    it 'assigns an empty array and does not raise when the aggregator fails' do
      allow(SqlAggregation::QueryAggregator).to receive(:version_rollup).and_raise(StandardError, 'db error')
      ctx = build_context('issues' => drop_with(scope))
      expect { build_tag('from: issues').render(ctx) }.not_to raise_error
      expect(ctx.scopes.last['versions']).to eq([])
    end
  end
end
