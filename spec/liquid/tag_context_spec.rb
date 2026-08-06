# frozen_string_literal: true

require 'logger'
require 'active_support'
require_relative '../spec_helper'

unless defined?(Rails)
  module Rails
    def self.logger
      @logger ||= Logger.new(File::NULL)
    end
  end
end

require_relative '../../lib/redmine_reporter_dashboards/liquid/tag_context'

class TagContextUser
  def self.current
    @current ||= Object.new
  end
end

# T-20 — the one place a tag reads `User.current`, and the reason it is allowed to.
#
# INV-1 is the invariant this file is about, and it is the easiest in the project to
# lose. So the examples are written to fail if the seam ever stops DISTINGUISHING the
# two branches: an assertion that merely says "a context came back" would pass whichever
# one answered, which is exactly the bug — a scheduled report rendering as whoever
# happened to run last.
RSpec.describe RedmineReporterDashboards::Liquid::TagContext do
  let(:owned_actor) { Object.new }
  let(:owned) { RedmineReporterDashboards::Liquid::RenderContext.new(actor: owned_actor) }

  before { stub_const('User', TagContextUser) }

  def context_with(registers = {})
    Liquid::Context.new({}, {}, registers)
  end

  def owned_registers
    { RedmineReporterDashboards::Liquid::RenderContext::REGISTER_KEY => owned }
  end

  describe 'when the owned renderer produced this render' do
    it 'returns the very context the renderer put in the registers' do
      expect(described_class.for(context_with(owned_registers))).to equal(owned)
    end

    it 'reports the actor the render is FOR' do
      expect(described_class.actor(context_with(owned_registers))).to equal(owned_actor)
    end

    it 'says it is owned' do
      expect(described_class).to be_owned(context_with(owned_registers))
    end

    # THE ONE THAT MATTERS. If the owned branch ever fell through to the fallback, every
    # assertion above except this one would still pass on an install where the two
    # actors happen to be the same person — which is every developer's machine.
    it 'never reads User.current' do
      expect(User).not_to receive(:current)

      described_class.for(context_with(owned_registers))
      described_class.actor(context_with(owned_registers))
    end
  end

  describe 'when the host plugin produced this render' do
    it 'builds a context around the ambient actor' do
      expect(described_class.for(context_with).actor).to equal(User.current)
    end

    it 'says it is NOT owned, so a caller can tell' do
      expect(described_class).not_to be_owned(context_with)
    end

    # An actor and NOTHING else. `HANDOVER.md` §6 forbids synthesising a scope here; the
    # fallback must not look like a render context that knows what it is rendering, or
    # a drop reading `scope` would get a plausible-looking answer that is not the
    # report's. nil is the honest one.
    it 'carries no scope and no query' do
      built = described_class.for(context_with)

      expect(built.scope).to be_nil
      expect(built.query).to be_nil
    end

    it 'is a real RenderContext, so a drop constructor accepts it' do
      expect(described_class.for(context_with))
        .to be_a(RedmineReporterDashboards::Liquid::RenderContext)
    end

    # A Liquid context with no `registers` at all — the shape a bare spec or an odd host
    # hands over. `RenderContext.from` must not raise on it, and this is where that is
    # asserted from the caller's side.
    it 'tolerates a context that has no registers' do
      expect(described_class.for(Object.new).actor).to equal(User.current)
    end

    # Something else living under the plugin's register key. `RenderContext.from`
    # type-checks rather than duck-types, and this is the case that check exists for:
    # the fallback must win, not a stranger's object.
    it 'ignores a foreign object squatting on the register key' do
      registers = { RedmineReporterDashboards::Liquid::RenderContext::REGISTER_KEY => 'not a context' }

      expect(described_class).not_to be_owned(context_with(registers))
      expect(described_class.for(context_with(registers)).actor).to equal(User.current)
    end
  end

  # Two renders are two contexts. Memoising here would serve the first viewer's actor to
  # the second — the same class of bug the thread-local's `ensure` exists to prevent, and
  # considerably harder to notice, because both renders succeed.
  it 'builds a fresh fallback per call rather than memoising one' do
    first = described_class.for(context_with)
    second = described_class.for(context_with)

    expect(first).not_to equal(second)
  end
end
