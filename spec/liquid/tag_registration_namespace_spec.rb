# frozen_string_literal: true

require_relative '../spec_helper'

# Regression guard for a subtle constant-shadowing bug.
#
# This plugin defines a RedmineReporterDashboards::Liquid namespace (VersionDrop).
# Inside `module RedmineReporterDashboards`, a *bare* `Liquid` constant therefore
# resolves to RedmineReporterDashboards::Liquid — NOT the top-level Liquid gem.
# When the tag registration used a bare `Liquid`, the guard
# `return unless defined?(Liquid::Tag)` silently returned early and the
# {% sql_aggregate %} / {% geo_aggregate %} / {% geo_version_map %} tags were
# never registered (with no error logged). The registration must use ::Liquid.
RSpec.describe 'Liquid tag registration namespace safety' do
  let(:source) do
    File.read(File.expand_path('../../lib/redmine_reporter_dashboards.rb', __dir__), encoding: 'UTF-8')
  end

  it 'never guards on a bare Liquid::Tag (would resolve to RedmineReporterDashboards::Liquid)' do
    expect(source).not_to match(/defined\?\(Liquid::Tag\)/)
    expect(source).to match(/defined\?\(::Liquid::Tag\)/)
  end

  it 'always calls register_tag on the top-level ::Liquid::Template' do
    # Any Liquid::Template.register_tag NOT preceded by "::" is the bug.
    expect(source).not_to match(/(?<!:)Liquid::Template\.register_tag/)
    expect(source.scan(/::Liquid::Template\.register_tag/).size).to be >= 3
  end
end
