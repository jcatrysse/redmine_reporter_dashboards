# frozen_string_literal: true

require 'logger' # concurrent-ruby >= 1.3.5 no longer requires this; ActiveSupport needs Logger defined
require 'active_support'
require 'active_support/time'
require_relative '../spec_helper'

Time.zone ||= 'UTC'

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
      def logger
        @logger ||= Logger.new(File::NULL)
      end
    end
  end
end

require_relative '../../lib/version_mapping/liquid_version_map_tag'

# Lightweight stand-ins for Redmine's Version / Project so the spec runs without
# booting Rails. Structs give us .name/.id/.effective_date/.status/.project.
VersionMapVersion = Struct.new(:id, :name, :effective_date, :status, :project)
VersionMapProject = Struct.new(:identifier)

# Class stubs for the AR models. They declare the class methods the tag calls so
# that verify_partial_doubles (enabled in spec_helper) is satisfied; individual
# examples override them with `allow(...).to receive(...)`.
class VersionMapVersionClass
  def self.all; end
end

class VersionMapProjectClass
  def self.find_by(**); end
end

RSpec.describe VersionMapping::LiquidVersionMapTag do
  let(:proj_a) { VersionMapProject.new('proj-a') }
  let(:proj_b) { VersionMapProject.new('proj-b') }

  let(:v1) { VersionMapVersion.new(10, '1.0', Date.new(2026, 6, 1), 'open',   proj_a) }
  let(:v2) { VersionMapVersion.new(20, '2.0', nil,                  'closed', proj_a) }
  let(:v3) { VersionMapVersion.new(30, 'Shared', Date.new(2027, 1, 1), 'locked', proj_b) }

  before do
    stub_const('Version', VersionMapVersionClass)
    stub_const('Project', VersionMapProjectClass)
  end

  def build_tag(markup)
    described_class.new('geo_version_map', markup, [])
  end

  def build_context(assigns = {}, registers = {})
    Liquid::Context.new({}, assigns, registers)
  end

  # An AR-relation-ish stub: responds to includes(:project) (chainable) and each.
  def scope_stub(versions)
    scope = double('version_scope')
    allow(scope).to receive(:includes).with(:project).and_return(scope)
    allow(scope).to receive(:each) { |&blk| versions.each(&blk) }
    scope
  end

  # ------------------------------------------------------------------
  # Version.all path (no project: param)
  # ------------------------------------------------------------------

  describe 'without a project param (Version.all)' do
    before { allow(Version).to receive(:all).and_return(scope_stub([v1, v2])) }

    it 'builds a map keyed by version name with string-keyed metadata' do
      ctx = build_context
      build_tag('assign_to: geo_versions').render(ctx)

      map = ctx.scopes.last['geo_versions']
      expect(map.keys).to contain_exactly('1.0', '2.0')
      expect(map['1.0']).to eq(
        'id'             => 10,
        'effective_date' => Date.new(2026, 6, 1),
        'status'         => 'open',
        'project'        => 'proj-a'
      )
    end

    it 'preserves a nil effective_date' do
      ctx = build_context
      build_tag('assign_to: geo_versions').render(ctx)

      expect(ctx.scopes.last['geo_versions']['2.0']['effective_date']).to be_nil
    end

    it 'defaults assign_to to "geo_versions" when omitted' do
      ctx = build_context
      build_tag('').render(ctx)

      expect(ctx.scopes.last['geo_versions']).to be_a(Hash)
    end

    it 'honours a custom assign_to name' do
      ctx = build_context
      build_tag('assign_to: versions_by_name').render(ctx)

      expect(ctx.scopes.last).to have_key('versions_by_name')
      expect(ctx.scopes.last).not_to have_key('geo_versions')
    end

    it 'returns an empty string (side-effect tag)' do
      ctx = build_context
      expect(build_tag('assign_to: geo_versions').render(ctx)).to eq('')
    end

    it 'eager-loads :project to avoid an N+1' do
      scope = scope_stub([v1])
      allow(Version).to receive(:all).and_return(scope)

      expect(scope).to receive(:includes).with(:project).and_return(scope)

      build_tag('assign_to: geo_versions').render(build_context)
    end

    it 'assigns an empty hash when there are no versions' do
      allow(Version).to receive(:all).and_return(scope_stub([]))
      ctx = build_context
      build_tag('assign_to: geo_versions').render(ctx)

      expect(ctx.scopes.last['geo_versions']).to eq({})
    end
  end

  # ------------------------------------------------------------------
  # project: param path (shared_versions)
  # ------------------------------------------------------------------

  describe 'with a project param' do
    it 'resolves the project by identifier and uses shared_versions' do
      project = double('project', shared_versions: scope_stub([v1, v3]))
      allow(Project).to receive(:find_by).with(identifier: 'proj-a').and_return(project)

      ctx = build_context
      build_tag('project: proj-a, assign_to: geo_versions').render(ctx)

      map = ctx.scopes.last['geo_versions']
      expect(map.keys).to contain_exactly('1.0', 'Shared')
      # A shared version reports the project it actually belongs to.
      expect(map['Shared']['project']).to eq('proj-b')
    end

    it 'falls back to lookup by id when identifier is not found' do
      project = double('project', shared_versions: scope_stub([v1]))
      allow(Project).to receive(:find_by).with(identifier: '5').and_return(nil)
      allow(Project).to receive(:find_by).with(id: '5').and_return(project)

      ctx = build_context
      build_tag('project: 5, assign_to: geo_versions').render(ctx)

      expect(ctx.scopes.last['geo_versions'].keys).to contain_exactly('1.0')
    end

    it 'never touches Version.all when a project resolves' do
      project = double('project', shared_versions: scope_stub([v1]))
      allow(Project).to receive(:find_by).with(identifier: 'proj-a').and_return(project)

      expect(Version).not_to receive(:all)

      build_tag('project: proj-a, assign_to: geo_versions').render(build_context)
    end

    it 'assigns an empty hash without widening to Version.all when project cannot be resolved' do
      allow(Project).to receive(:find_by).and_return(nil)

      # project: was explicitly requested, so an unresolved project must NOT fall
      # back to the global version set.
      expect(Version).not_to receive(:all)

      ctx = build_context
      result = build_tag('project: does-not-exist, assign_to: geo_versions').render(ctx)

      expect(result).to eq('')
      expect(ctx.scopes.last['geo_versions']).to eq({})
    end
  end

  # ------------------------------------------------------------------
  # Error handling
  # ------------------------------------------------------------------

  describe 'error handling' do
    it 'assigns an empty hash and returns blank when the query raises' do
      allow(Version).to receive(:all).and_raise(StandardError, 'db error')

      ctx = build_context
      tag = build_tag('assign_to: geo_versions')

      expect { tag.render(ctx) }.not_to raise_error
      expect(tag.render(ctx)).to eq('')
      expect(ctx.scopes.last['geo_versions']).to eq({})
    end

    it 'uses the resolved assign_to name in the rescue path' do
      allow(Version).to receive(:all).and_raise(StandardError, 'boom')

      ctx = build_context
      build_tag('assign_to: custom_name').render(ctx)

      expect(ctx.scopes.last['custom_name']).to eq({})
    end
  end
end
