# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/redmine_reporter_dashboards/liquid/scope_binding'

# T-07's owned path, DB-less.
#
# The legacy path is covered where it always was — the 46-triple oracle in
# test/unit/golden_scope_fixture_test.rb and the two tag specs, which now reach it
# through this dispatch. What is asserted here is what the owned path is FOR: two
# sources, an explicit actor, and no way to reintroduce the third.
#
# The sharpest example in the file is `it 'never reads User.current'`. INV-1 is the
# easiest invariant in this project to lose silently, so it is tested by making the
# ambient read EXPLODE rather than by reading the code and believing it.
RSpec.describe RedmineReporterDashboards::Liquid::ScopeBinding do
  RC = RedmineReporterDashboards::Liquid::RenderContext unless defined?(RC)

  # A Liquid::Context stand-in: the two methods the owned path uses. `[]` for a
  # variable lookup (`query_id: some_var`) and `registers` for the render context.
  class FakeLiquidContext
    def initialize(registers: {}, assigns: {})
      @registers = registers
      @assigns = assigns
    end

    def [](key)
      @assigns[key]
    end

    attr_reader :registers
  end

  # A context with no registers at all — a bare Liquid::Context has them, but a
  # host stub might not, and `.from` must answer nil rather than raise.
  class RegisterlessContext
    def [](_key)
      nil
    end
  end

  let(:actor)  { double('User', login: 'alice') }
  let(:scope)  { double('AR::Relation') }
  let(:query)  { double('IssueQuery', id: 7) }

  def context_with(render_context, assigns = {})
    FakeLiquidContext.new(registers: { RC::REGISTER_KEY => render_context }, assigns: assigns)
  end

  # IssueQuery.visible(actor).find_by(id:) — the only DB call the owned path makes.
  # `visible` records the actor it was given, which is what the INV-1 examples read.
  def stub_issue_query(found:, visible_for: [])
    klass = Class.new do
      class << self
        attr_accessor :seen_actors, :found

        def visible(actor)
          (self.seen_actors ||= []) << actor
          scoped = self
          Class.new do
            define_singleton_method(:find_by) { |id:| scoped.found[id] }
          end
        end
      end
    end
    klass.found = found
    klass.seen_actors = visible_for
    stub_const('IssueQuery', klass)
    klass
  end

  # ------------------------------------------------------------------
  # RenderContext — INV-1 made mechanical
  # ------------------------------------------------------------------

  describe RedmineReporterDashboards::Liquid::RenderContext do
    it 'cannot be built without an actor' do
      expect { RC.new(actor: nil) }.to raise_error(ArgumentError, /needs an actor/)
    end

    it 'names INV-1 in the message, so the reason survives the stack trace' do
      expect { RC.new(actor: nil) }.to raise_error(/INV-1/)
    end

    it 'is frozen, so nothing downstream can swap the actor mid-render' do
      expect(RC.new(actor: actor)).to be_frozen
    end

    it 'accepts a nil scope and a nil query — both are supported answers' do
      render_context = RC.new(actor: actor)

      expect(render_context.scope).to be_nil
      expect(render_context.query).to be_nil
    end

    describe '.from' do
      it 'finds a render context in the register this plugin owns' do
        render_context = RC.new(actor: actor)

        expect(RC.from(context_with(render_context))).to be(render_context)
      end

      it 'is nil when the register is absent' do
        expect(RC.from(FakeLiquidContext.new)).to be_nil
      end

      it 'is nil when the context has no registers at all, rather than raising' do
        expect(RC.from(RegisterlessContext.new)).to be_nil
      end

      it 'is nil for something else parked under the key' do
        # Type-checked, not duck-typed. Something else answering to #scope is exactly
        # the accident the legacy module's ar_scope? duck test institutionalised.
        impostor = double('NotARenderContext', scope: scope, actor: actor, query: nil)

        expect(RC.from(context_with(impostor))).to be_nil
      end

      it 'is nil for a context that is not a context' do
        expect(RC.from(nil)).to be_nil
        expect(RC.from('a string')).to be_nil
      end
    end

    it 'logs the actor by login, never by display name' do
      # This string goes into log lines. A display name is personal data going
      # somewhere it is not needed.
      expect(RC.new(actor: actor).actor_label).to eq('alice')
    end

    it 'falls back to a class name for an actor with no login' do
      expect(RC.new(actor: double('AnonymousUser')).actor_label).to match(/Double|AnonymousUser/)
    end
  end

  # ------------------------------------------------------------------
  # Source 2 — the render context
  # ------------------------------------------------------------------

  describe 'binding from a render context' do
    it 'takes the scope and the query straight off it' do
      render_context = RC.new(actor: actor, scope: scope, query: query)
      binding = described_class.bind({}, context_with(render_context))

      expect(binding.scope).to be(scope)
      expect(binding.query).to be(query)
      expect(binding.source).to eq(:render_context)
    end

    it 'reports a nil scope as nil rather than searching for another one' do
      binding = described_class.bind({}, context_with(RC.new(actor: actor)))

      expect(binding.scope).to be_nil
      expect(binding.source).to eq(:render_context)
    end

    it 'never reads User.current' do
      # INV-1, mechanically. If any owned path reaches for the ambient user, this
      # explodes instead of quietly returning the wrong person's scope.
      exploding = Class.new do
        def self.current
          raise 'the owned path read User.current (INV-1)'
        end
      end
      stub_const('User', exploding)

      expect { described_class.bind({}, context_with(RC.new(actor: actor, scope: scope))) }
        .not_to raise_error
    end
  end

  # ------------------------------------------------------------------
  # Source 1 — an explicit query_id
  # ------------------------------------------------------------------

  describe 'binding from query_id' do
    it 'resolves through IssueQuery.visible and returns its base_scope' do
      base = double('base_scope')
      found = double('IssueQuery', id: 7, base_scope: base)
      stub_issue_query(found: { 7 => found })

      binding = described_class.bind({ 'query_id' => '7' },
                                     context_with(RC.new(actor: actor, scope: scope)))

      expect(binding.scope).to be(base)
      expect(binding.query).to be(found)
      expect(binding.source).to eq(:query_id)
    end

    it 'scopes the lookup to the RENDER CONTEXT actor, not to User.current' do
      found = double('IssueQuery', id: 7, base_scope: double)
      klass = stub_issue_query(found: { 7 => found })
      stub_const('User', Class.new do
        def self.current
          raise 'the owned path read User.current (INV-1)'
        end
      end)

      described_class.bind({ 'query_id' => '7' }, context_with(RC.new(actor: actor)))

      expect(klass.seen_actors).to eq([actor])
    end

    it 'resolves a query_id given as a template variable' do
      found = double('IssueQuery', id: 9, base_scope: double)
      stub_issue_query(found: { 9 => found })

      binding = described_class.bind({ 'query_id' => 'chosen' },
                                     context_with(RC.new(actor: actor), 'chosen' => 9))

      expect(binding.query).to be(found)
    end

    # The rule that matters most here.
    it 'does NOT fall back to the render context scope when the query is refused' do
      # A template that asked for query 7 and silently got the ambient scope would
      # report the wrong numbers under the right heading, which is worse than none.
      stub_issue_query(found: {})

      binding = described_class.bind({ 'query_id' => '7' },
                                     context_with(RC.new(actor: actor, scope: scope, query: query)))

      expect(binding.scope).to be_nil
      expect(binding.query).to be_nil
    end

    it 'treats an unusable query_id as no query at all' do
      stub_issue_query(found: {})

      %w[0 abc].each do |bad|
        binding = described_class.bind({ 'query_id' => bad }, context_with(RC.new(actor: actor)))
        expect(binding.scope).to be_nil, "query_id: #{bad.inspect} resolved to something"
      end
    end

    it 'does not rescue a broken lookup — the tag decides how to degrade' do
      # Fail closed and visibly. The tags already wrap render in a rescue that assigns
      # the empty result, so a raise here becomes an empty widget with a log line,
      # never a widget showing somebody else's issues (INV-3).
      exploding = Class.new do
        def self.visible(_actor)
          raise StandardError, 'connection lost'
        end
      end
      stub_const('IssueQuery', exploding)

      expect { described_class.bind({ 'query_id' => '7' }, context_with(RC.new(actor: actor))) }
        .to raise_error(StandardError, /connection lost/)
    end
  end

  # ------------------------------------------------------------------
  # No render context — the legacy dispatch
  # ------------------------------------------------------------------

  describe 'with no render context' do
    it 'resolves nothing when the legacy glue is not loaded' do
      # A standalone install: no reporter, so no legacy module, and these tags are
      # never invoked anyway (T-06 degrades the widgets). Answering "nothing" is the
      # honest outcome, and it is fail-closed.
      hide_const('RedmineReporterDashboards::Glue') if defined?(RedmineReporterDashboards::Glue)

      binding = described_class.bind({}, FakeLiquidContext.new)

      expect(binding.scope).to be_nil
      expect(binding.query).to be_nil
      expect(binding.source).to eq(:none)
    end

    it 'delegates to the legacy module when it IS loaded, carrying the raw params' do
      legacy = Module.new do
        def resolve_scope(_context)
          [:legacy_scope, @raw_params['from']]
        end

        def resolve_query(_context)
          :legacy_query
        end
      end
      stub_const('RedmineReporterDashboards::Glue::Legacy::ScopeResolution', legacy)

      binding = described_class.bind({ 'from' => 'widgets' }, FakeLiquidContext.new)

      expect(binding.scope).to eq([:legacy_scope, 'widgets'])
      expect(binding.query).to eq(:legacy_query)
      expect(binding.source).to eq(:legacy)
    end
  end

  # ------------------------------------------------------------------
  # The mixin the tags include
  # ------------------------------------------------------------------

  describe 'the mixin' do
    let(:host_class) do
      Class.new do
        include RedmineReporterDashboards::Liquid::ScopeBinding

        def initialize(raw_params)
          @raw_params = raw_params
        end
      end
    end

    it 'exposes the two method names the tags already called' do
      host = host_class.new({})
      render_context = RC.new(actor: actor, scope: scope, query: query)

      expect(host.resolve_scope(context_with(render_context))).to be(scope)
      expect(host.resolve_query(context_with(render_context))).to be(query)
    end

    # Liquid parses a template once and renders it many times, so a tag instance
    # outlives a render. A memoised binding would serve the first viewer's scope to
    # the second — the same class of bug the thread-local's ensure exists to prevent,
    # and much harder to notice.
    it 'resolves afresh on every render, so one tag cannot leak between viewers' do
      host = host_class.new({})
      first  = RC.new(actor: actor, scope: :alice_scope)
      second = RC.new(actor: double('User', login: 'bob'), scope: :bob_scope)

      expect(host.resolve_scope(context_with(first))).to eq(:alice_scope)
      expect(host.resolve_scope(context_with(second))).to eq(:bob_scope)
    end
  end

  it 'has no enforce_visibility to fail open with' do
    # The legacy module needs one because five of its six sources have unknown
    # provenance. Both sources here start from Issue.visible, so the method — and its
    # fail-open rescue — has nothing left to defend and was not ported. Asserted so
    # that reintroducing it is a deliberate act.
    expect(described_class).not_to respond_to(:enforce_visibility)
    expect(described_class.instance_methods).not_to include(:enforce_visibility)
  end
end
