# frozen_string_literal: true

require_relative '../spec_helper'

# Regression guard for a subtle constant-shadowing bug.
#
# This plugin defines a RedmineReporterDashboards::Liquid namespace (the owned drop
# layer, the renderer, the filters). Inside `module RedmineReporterDashboards`, a *bare*
# `Liquid` constant therefore
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

  # The registration CALL moved into `Compat.register_liquid_tag` (Redmine 7 migration: Liquid
  # 5.14 deprecates `Template.register_tag`), so the namespace rule is asserted where the
  # constant is now named. A bare `Liquid::Environment` inside `module RedmineReporterDashboards`
  # is the same bug with a new name: `defined?` answers false and the fallback hides it.
  let(:compat) do
    File.read(File.expand_path('../../lib/redmine_reporter_dashboards/compat.rb', __dir__), encoding: 'UTF-8')
  end

  it 'registers every tag through the one compat method' do
    expect(source).not_to match(/Liquid::Template\.register_tag/)
    expect(source.scan(/Compat\.register_liquid_tag\(/).size).to be >= 3
  end

  it 'names only the top-level ::Liquid constants in that compat method' do
    body = compat[/def self\.register_liquid_tag.*?\n    end\n/m]
    expect(body).not_to be_nil
    expect(body).not_to match(/(?<!:)Liquid::(Template|Environment)/)
    expect(body).to include('::Liquid::Environment.default.register_tag')
    expect(body).to include('::Liquid::Template.register_tag')
  end
end
