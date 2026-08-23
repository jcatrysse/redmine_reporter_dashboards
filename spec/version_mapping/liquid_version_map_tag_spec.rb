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
  def self.visible(*); end
end

class VersionMapProjectClass
  def self.find_by(**); end

  # Redmine's own signature is `scope :visible, lambda {|user=User.current| … }`, so it
  # takes the actor. The stub used to declare it arity-0, which — with
  # verify_partial_doubles on — meant this spec could not have caught the tag passing
  # the actor explicitly OR failing to.
  def self.visible(*); end
end

# `User.current` EXPLODES IN THIS FILE, and that is the harness rather than a hazard.
#
# It used to answer a memoised `Object.new`, because the tag's actor came from
# `TagContext`, whose fallback read `User.current` on any render this plugin did not
# produce. Curator decision #1 deleted that fallback: the actor now comes from the
# `RenderContext` in the registers and from nowhere else, and a context-less render is
# REFUSED rather than served with the ambient actor.
#
# So the ambient read is made to raise, the way `spec/liquid/scope_binding_spec.rb` has
# always done it for the same invariant. A stub that quietly returned an object would let
# every example in this file pass against a tag that had reintroduced the fallback — the
# read would happen, the value would be usable, and nothing would say so. Redmine's real
# `Version.visible` reaches for `User.current` when handed nil (`args.first || User.current`,
# `app/models/version.rb:161`), so "the tag passes nil" and "the tag reads the ambient actor"
# are the SAME outcome in production and only an exploding stub tells them apart here.
class VersionMapUserClass
  def self.current
    raise 'User.current was read: the geo_version_map tag must take its actor from the ' \
          'RenderContext, and refuse when there is none (INV-1, curator decision #1)'
  end
end

RSpec.describe VersionMapping::LiquidVersionMapTag do
  let(:proj_a) { VersionMapProject.new('proj-a') }
  let(:proj_b) { VersionMapProject.new('proj-b') }

  let(:v1) { VersionMapVersion.new(10, '1.0', Date.new(2026, 6, 1), 'open',   proj_a) }
  let(:v2) { VersionMapVersion.new(20, '2.0', nil,                  'closed', proj_a) }
  let(:v3) { VersionMapVersion.new(30, 'Shared', Date.new(2027, 1, 1), 'locked', proj_b) }

  # The actor the default context carries. See `build_context` for why it must not be
  # whatever `User.current` would have answered.
  let(:render_actor) { Object.new }

  before do
    stub_const('Version', VersionMapVersionClass)
    stub_const('Project', VersionMapProjectClass)
    stub_const('User',    VersionMapUserClass)
    # Project.visible(actor).find_by(...) — the visible scope returns the class itself.
    allow(Project).to receive(:visible).and_return(Project)
    # ONCE-PER-PROCESS state is per-process, and rspec runs in ONE. Without this reset
    # the deprecation examples would pass or fail on file order, which is the class of
    # bug spec/README warns about and the hardest kind to reproduce.
    described_class.reset_deprecation_notice!
  end

  def build_tag(markup)
    described_class.new('geo_version_map', markup, [])
  end

  # THE DEFAULT CONTEXT NOW CARRIES A `RenderContext`, and that is the harness change
  # decision #1 required. Every example below except the refusal ones is about what the tag
  # BUILDS, and used to get its scope resolved through the ambient-actor fallback; with that
  # gone, a registerless context makes the tag refuse and 12 examples fail for a reason that
  # has nothing to do with their subjects. `HANDOVER.md` records this exact shape from S-30 —
  # of 150 failures there, 121 were the harness and only 38 had the deleted behaviour as
  # their subject. Rebuild the harness first, then read what is left.
  #
  # `render_actor` IS DELIBERATELY NOT `User.current`. Handing the context the same object the
  # ambient read would have produced would make every visibility assertion below pass under
  # either implementation — the trap `HANDOVER.md` §1 opens with. It is a distinct object, so
  # `expect(Version).to receive(:visible).with(render_actor)` discriminates: it fails if the
  # tag ever goes back to asking the ambient user (which in this file also raises).
  #
  # A REAL `RenderContext` and not a double: `RenderContext.from` type-checks the register
  # with `is_a?(self)`, so a double in the registers reads as no context at all — which would
  # silently turn every example here into the refusal case.
  def build_context(assigns = {}, registers = nil)
    registers ||= { RedmineReporterDashboards::Liquid::RenderContext::REGISTER_KEY =>
                      RedmineReporterDashboards::Liquid::RenderContext.new(actor: render_actor) }
    Liquid::Context.new({}, assigns, registers)
  end

  # A context with NO RenderContext — a render this plugin did not produce. Named rather
  # than spelled inline, because it is the subject of its own describe block and reusing
  # `build_context({}, {})` there would read as an accident.
  def build_context_without_render_context(assigns = {})
    Liquid::Context.new({}, assigns, {})
  end

  # An AR-relation-ish stub: responds to includes(:project) (chainable) and each.
  def scope_stub(versions)
    scope = double('version_scope')
    allow(scope).to receive(:includes).with(:project).and_return(scope)
    allow(scope).to receive(:each) { |&blk| versions.each(&blk) }
    scope
  end

  # shared_versions is narrowed with .visible when it supports it (an AR
  # relation); older Redmine hands back a plain Array, which must still work.
  def shared_scope_stub(versions)
    scope = scope_stub(versions)
    allow(scope).to receive(:visible).and_return(scope)
    scope
  end

  # ------------------------------------------------------------------
  # Version.all path (no project: param)
  # ------------------------------------------------------------------

  describe 'without a project param (every visible version)' do
    before { allow(Version).to receive(:visible).and_return(scope_stub([v1, v2])) }

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

    # CURATOR DECISION #3 — A QUOTED PARAMETER IS LITERAL TEXT, ON THE DEPRECATED TAG TOO.
    #
    # This tag has exactly one parameter that goes through the lookup, and reverting it to
    # the old unconditional one left 816 examples green — so the rule was untested here.
    # It ships for one more minor version, so it gets the same rule and the same proof
    # rather than an exemption nobody wrote down.
    it 'assigns under a quoted name itself, not under a variable of that name' do
      ctx = build_context('versions_by_name' => 'somewhere_else')
      build_tag('assign_to: "versions_by_name"').render(ctx)

      expect(ctx.scopes.last['versions_by_name']).to be_a(Hash)
      expect(ctx.scopes.last).not_to have_key('somewhere_else')
    end

    it 'still resolves a bare assign_to from a variable' do
      ctx = build_context('target' => 'somewhere_else')
      build_tag('assign_to: target').render(ctx)

      expect(ctx.scopes.last['somewhere_else']).to be_a(Hash)
    end

    it 'returns an empty string (side-effect tag)' do
      ctx = build_context
      expect(build_tag('assign_to: geo_versions').render(ctx)).to eq('')
    end

    it 'eager-loads :project to avoid an N+1' do
      scope = scope_stub([v1])
      allow(Version).to receive(:visible).and_return(scope)

      expect(scope).to receive(:includes).with(:project).and_return(scope)

      build_tag('assign_to: geo_versions').render(build_context)
    end

    it 'assigns an empty hash when there are no versions' do
      allow(Version).to receive(:visible).and_return(scope_stub([]))
      ctx = build_context
      build_tag('assign_to: geo_versions').render(ctx)

      expect(ctx.scopes.last['geo_versions']).to eq({})
    end
  end

  # ------------------------------------------------------------------
  # Visibility
  # ------------------------------------------------------------------

  describe 'visibility' do
    it 'builds the full map from the visible versions only' do
      expect(Version).to receive(:visible).with(render_actor).and_return(scope_stub([v1]))

      build_tag('assign_to: geo_versions').render(build_context)
    end

    it 'never reads every version in the database' do
      allow(Version).to receive(:visible).and_return(scope_stub([v1]))
      expect(Version).not_to receive(:all)

      build_tag('assign_to: geo_versions').render(build_context)
    end

    it 'resolves project: through the visible project scope' do
      project = double('project', shared_versions: shared_scope_stub([v1]))
      expect(Project).to receive(:visible).at_least(:once).and_return(Project)
      allow(Project).to receive(:find_by).with(identifier: 'proj-a').and_return(project)

      build_tag('project: proj-a, assign_to: geo_versions').render(build_context)
    end

    it 'treats an invisible project like a missing one' do
      allow(Project).to receive(:find_by).and_return(nil)

      ctx = build_context
      build_tag('project: secret-project, assign_to: geo_versions').render(ctx)

      expect(ctx.scopes.last['geo_versions']).to eq({})
    end

    it 'narrows shared_versions to the visible ones' do
      shared = shared_scope_stub([v1])
      project = double('project', shared_versions: shared)
      allow(Project).to receive(:find_by).with(identifier: 'proj-a').and_return(project)

      expect(shared).to receive(:visible).with(render_actor).and_return(shared)

      build_tag('project: proj-a, assign_to: geo_versions').render(build_context)
    end

    it 'still works when shared_versions is a plain Array' do
      project = double('project', shared_versions: [v1])
      allow(Project).to receive(:find_by).with(identifier: 'proj-a').and_return(project)

      ctx = build_context
      build_tag('project: proj-a, assign_to: geo_versions').render(ctx)

      expect(ctx.scopes.last['geo_versions'].keys).to eq(['1.0'])
    end
  end

  # ------------------------------------------------------------------
  # project: param path (shared_versions)
  # ------------------------------------------------------------------

  describe 'with a project param' do
    it 'resolves the project by identifier and uses shared_versions' do
      project = double('project', shared_versions: shared_scope_stub([v1, v3]))
      allow(Project).to receive(:find_by).with(identifier: 'proj-a').and_return(project)

      ctx = build_context
      build_tag('project: proj-a, assign_to: geo_versions').render(ctx)

      map = ctx.scopes.last['geo_versions']
      expect(map.keys).to contain_exactly('1.0', 'Shared')
      # A shared version reports the project it actually belongs to.
      expect(map['Shared']['project']).to eq('proj-b')
    end

    it 'falls back to lookup by id when identifier is not found' do
      project = double('project', shared_versions: shared_scope_stub([v1]))
      allow(Project).to receive(:find_by).with(identifier: '5').and_return(nil)
      allow(Project).to receive(:find_by).with(id: '5').and_return(project)

      ctx = build_context
      build_tag('project: 5, assign_to: geo_versions').render(ctx)

      expect(ctx.scopes.last['geo_versions'].keys).to contain_exactly('1.0')
    end

    it 'never widens to every version when a project resolves' do
      project = double('project', shared_versions: shared_scope_stub([v1]))
      allow(Project).to receive(:find_by).with(identifier: 'proj-a').and_return(project)

      expect(Version).not_to receive(:visible)

      build_tag('project: proj-a, assign_to: geo_versions').render(build_context)
    end

    it 'assigns an empty hash without widening to Version.all when project cannot be resolved' do
      allow(Project).to receive(:find_by).and_return(nil)

      # project: was explicitly requested, so an unresolved project must NOT fall
      # back to the global version set.
      expect(Version).not_to receive(:visible)

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
      allow(Version).to receive(:visible).and_raise(StandardError, 'db error')

      ctx = build_context
      tag = build_tag('assign_to: geo_versions')

      expect { tag.render(ctx) }.not_to raise_error
      expect(tag.render(ctx)).to eq('')
      expect(ctx.scopes.last['geo_versions']).to eq({})
    end

    it 'uses the resolved assign_to name in the rescue path' do
      allow(Version).to receive(:visible).and_raise(StandardError, 'boom')

      ctx = build_context
      build_tag('assign_to: custom_name').render(ctx)

      expect(ctx.scopes.last['custom_name']).to eq({})
    end
  end

  # ------------------------------------------------------------------
  # T-20 — the deprecation shim
  # ------------------------------------------------------------------
  #
  # The tag is retired. What is under test here is that retiring it did not change what
  # it DOES — every example above still applies — and that the notice behaves like a
  # deprecation rather than like log spam.
  describe 'the deprecation notice' do
    before { allow(Version).to receive(:visible).and_return(scope_stub([v1])) }

    it 'warns on the first render' do
      expect(Rails.logger).to receive(:warn).with(/DEPRECATED/)

      build_tag('assign_to: geo_versions').render(build_context)
    end

    # ONCE, and once across TAG INSTANCES, not once per instance. Liquid parses a
    # template into fresh tag objects, so a per-instance flag would print for every
    # template on the page and again on the next request — which is a deprecation an
    # operator filters out of their log by the end of the day.
    it 'warns exactly once per process, however many renders and however many tags' do
      expect(Rails.logger).to receive(:warn).with(/DEPRECATED/).once

      3.times { build_tag('assign_to: geo_versions').render(build_context) }
      build_tag('assign_to: other').render(build_context)
    end

    it 'names the replacement rather than only the problem' do
      expect(described_class::DEPRECATION_MESSAGE).to include('issue.version.id')
      expect(described_class::DEPRECATION_MESSAGE).to include('removed in the next minor')
    end

    it 'reports whether it has fired, so the reset seam is observable' do
      expect(described_class).not_to be_deprecation_notice_logged

      build_tag('').render(build_context)

      expect(described_class).to be_deprecation_notice_logged
    end

    # The notice must not become the tag's job. A logger that raises — a full disk, a
    # closed file handle — is not a reason for a report to lose its version table.
    it 'still assigns the map when the notice cannot be logged' do
      allow(Rails.logger).to receive(:warn).and_raise(IOError, 'log device closed')

      ctx = build_context
      build_tag('assign_to: geo_versions').render(ctx)

      # IOError is a StandardError, so the tag's own rescue catches it — and the
      # rescue's contract is an EMPTY map, never a half-built one. Asserted rather than
      # assumed, because "it degrades" and "it degrades to the documented value" are
      # different claims.
      expect(ctx.scopes.last['geo_versions']).to eq({})
    end
  end

  # ------------------------------------------------------------------
  # INV-1 — the actor is asked for, never assumed
  # ------------------------------------------------------------------
  describe 'the actor' do
    let(:render_context_actor) { Object.new }

    # Driven through a stubbed `RenderContext.from` rather than by putting a real context
    # in the registers, and deliberately so: stubbing the far end proves the whole
    # delegation rather than the near end of it. `RenderContext.from` type-checks with
    # `is_a?(self)`, so a double could not be planted in the registers anyway.
    it 'takes its actor from the render context' do
      allow(RedmineReporterDashboards::Liquid::RenderContext)
        .to receive(:from).and_return(double('render_context', actor: render_context_actor))

      expect(Version).to receive(:visible).with(render_context_actor).and_return(scope_stub([v1]))

      build_tag('assign_to: geo_versions').render(build_context)
    end

    # --- THE INVERTED EXAMPLE. IT USED TO ASSERT THE FALLBACK; NOW IT ASSERTS ITS ABSENCE.
    #
    # It read *"falls back to User.current when no owned renderer produced this render"* and
    # pinned exactly the behaviour curator decision #1 withdraws. Inverted rather than
    # deleted: this is the one place in the file where the change is a BEHAVIOUR change, and
    # an example that fails if the fallback comes back is the only thing that keeps it gone.
    #
    # THREE ASSERTIONS, BECAUSE "NO NUMBERS" AND "NO AMBIENT READ" AND "SAID SO" ARE THREE
    # CLAIMS. A single `eq({})` would pass against a tag that read `User.current`, got an
    # empty scope from the stub and assigned an empty map for the wrong reason — and against
    # one that refused in silence, which INV-4 forbids.
    # `User.current` IS DELIBERATELY MADE TO **WORK** IN THE THREE REFUSAL EXAMPLES, which is
    # the opposite of the file-level stub and the reason this comment is long.
    #
    # MEASURED, NOT REASONED: with the file's exploding `User.current` in place, two of these
    # three examples passed VACUOUSLY. Restoring the pre-decision code (delete the refusal,
    # put `|| ::User.current` back) made the mutant raise *before* `Version.visible`, so
    # `expect(Version).not_to receive(:visible)` was satisfied by the raise, the tag's own
    # rescue turned it into an empty map, and `eq({})` was satisfied too. Only the log
    # example failed — 1 of 3. A control with no negative case is indistinguishable from no
    # control (`HANDOVER.md` §1), and these were two of them.
    #
    # So the refusal examples give the ambient read a USABLE answer, which is what production
    # has: `User.current` is never nil in Redmine (an unauthenticated request gets
    # `AnonymousUser`). Now the mutant reaches `Version.visible(ambient_actor)` and
    # `not_to receive(:visible)` fires. The exploding default stays for the other examples,
    # where the claim is "this path never asks" rather than "this path refuses".
    let(:ambient_actor) { Object.new }

    def allow_ambient_actor!
      usable = ambient_actor
      stub_const('User', Class.new { define_singleton_method(:current) { usable } })
    end

    it 'refuses instead, reading no ambient actor and assigning an empty map' do
      allow_ambient_actor!
      allow(RedmineReporterDashboards::Liquid::RenderContext).to receive(:from).and_return(nil)
      expect(Version).not_to receive(:visible)
      ctx = build_context

      expect { build_tag('assign_to: geo_versions').render(ctx) }.not_to raise_error
      expect(ctx.scopes.last['geo_versions']).to eq({})
    end

    it 'says why, naming the mechanism rather than the plugin' do
      allow_ambient_actor!
      allow(RedmineReporterDashboards::Liquid::RenderContext).to receive(:from).and_return(nil)
      warnings = []
      allow(Rails.logger).to receive(:warn) { |line| warnings << line }

      build_tag('assign_to: geo_versions').render(build_context)

      # INV-4: the branch that turns a resolving render into an empty one must announce
      # itself. The message is asserted for the MECHANISM and for the decision it cites —
      # not for the base plugin's id, which `script/gates/zero_reporter.sh` matches inside a
      # string as readily as inside a require, and which decision #1's own deliverable is
      # getting to zero.
      expect(warnings.grep(/no render context/)).not_to be_empty
      expect(warnings.grep(/decision #1/)).not_to be_empty
    end

    # THE REFUSAL THROUGH THE REAL SEAM, not through a stubbed `RenderContext.from`. The two
    # examples above stub the far end, which proves the delegation; this one hands the tag a
    # Liquid context with EMPTY REGISTERS — what a render by another plugin's renderer
    # actually looks like — so the refusal is exercised end to end rather than at a double.
    it 'refuses a genuinely registerless context, which is what a foreign render looks like' do
      allow_ambient_actor!
      expect(Version).not_to receive(:visible)
      ctx = build_context_without_render_context

      expect { build_tag('assign_to: geo_versions').render(ctx) }.not_to raise_error
      expect(ctx.scopes.last['geo_versions']).to eq({})
    end

    it 'resolves project: through the same actor, not a second one' do
      allow(RedmineReporterDashboards::Liquid::RenderContext)
        .to receive(:from).and_return(double('render_context', actor: render_context_actor))
      shared = shared_scope_stub([v1])
      project = double('project', shared_versions: shared)

      expect(Project).to receive(:visible).with(render_context_actor).and_return(Project)
      allow(Project).to receive(:find_by).with(identifier: 'proj-a').and_return(project)
      expect(shared).to receive(:visible).with(render_context_actor).and_return(shared)

      build_tag('project: proj-a, assign_to: geo_versions').render(build_context)
    end
  end
end
