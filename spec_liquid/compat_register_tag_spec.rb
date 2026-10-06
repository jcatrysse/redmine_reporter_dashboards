# frozen_string_literal: true

require 'stringio'
require_relative '../lib/redmine_reporter_dashboards/compat'

# `Compat.register_liquid_tag`, against the REAL Liquid gem (Redmine 7 migration, work item 5).
#
# The plugin's six tags used to be registered with `Liquid::Template.register_tag`, which on
# Liquid 5.14.0 — what Redmine 7.0 resolves to — prints a deprecation at every boot and is
# announced to go in Liquid 6. What has to hold after the move is the only thing a template
# author notices: a tag registered through the compat method is the tag `Template.parse`
# finds, on every Liquid this suite runs against (4.x and 5.x in CI).
RSpec.describe RedmineReporterDashboards::Compat do
  let(:probe) do
    Class.new(::Liquid::Tag) do
      def render(_context)
        'probe-rendered'
      end
    end
  end

  def capture_stderr
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end

  it 'registers a tag that Template.parse then resolves' do
    described_class.register_liquid_tag('rrd_compat_probe', probe)

    expect(::Liquid::Template.parse('a{% rrd_compat_probe %}b').render).to eq('aprobe-renderedb')
  end

  # Liquid warns ONCE PER PROCESS (`Liquid::Deprecations.warned`), and other spec_liquid files
  # call Template.register_tag first, so the set is cleared for the example: otherwise it
  # would pass with the old call in place (independent review).
  it 'says nothing on stderr while registering, where Template.register_tag warns on 5.5+' do
    ::Liquid::Deprecations.warned.clear if defined?(::Liquid::Deprecations)

    out = capture_stderr { described_class.register_liquid_tag('rrd_compat_quiet', probe) }

    expect(out).not_to include('DEPRECATION')
  end

  if defined?(::Liquid::Environment) && ::Liquid::Environment.respond_to?(:default)
    it 'writes the default Environment, the registry Template.parse reads (Liquid 5.5+)' do
      # Template.register_tag also lands in Environment.default, so the registry alone could
      # not tell the deprecated call from the new one: assert the deprecated one is not made.
      expect(::Liquid::Template).not_to receive(:register_tag)

      described_class.register_liquid_tag('rrd_compat_env', probe)

      expect(::Liquid::Environment.default.tags['rrd_compat_env']).to eq(probe)
    end
  else
    it 'falls back to Template.register_tag where Liquid has no Environment (4.x, 5.0-5.4)' do
      described_class.register_liquid_tag('rrd_compat_tpl', probe)

      expect(::Liquid::Template.tags['rrd_compat_tpl']).to eq(probe)
    end
  end
end
